#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2026 Yijie Yu
"""UDP loopback viewer for the RFSoC 4x2 Corundum NIC.

Generates test video, sends every frame as UDP packets to tools/udp_echo running on the
board (through the Corundum NIC), receives the echoed packets, reassembles the frames and
compares them byte by byte with what was sent. Shows the sent and the received frame side
by side with live statistics, saves a side-by-side PNG once per second and summary.txt.

Packet = 16-byte header + frame bytes (same format as rfsoc4x2_25g_udp's UdpLoopbackViewer):
  u32 magic 'RFLB' | u32 frame id | u16 packet index | u16 packet count | u32 byte offset
Packets go to ports port .. port+flows-1 in runs of 8 per flow (the board's RSS spreads
the flows over its receive queues), each from the same local port, so either answers:
tools/udp_echo (a socket echo) or tools/tc_reflect.sh (swaps MAC and IP in the kernel).
Each frame's packets are paced over --spread of the frame interval: the echo runs on the
A53 cores, not in the FPGA.
Packet I/O, reassembly and comparison are in loopback_io.c (built with gcc on first use).

Needs Python 3, gcc, Pillow and PyGObject (GTK 3); --nogui needs no GTK.
  udp_loopback_viewer.py [--ip 192.168.100.1] [--port 1234] [--flows 4] [--res 1280x720]
                         [--fps 30] [--seconds 5] [--payload 1456] [--spread 0.8]
                         [--out DIR] [--auto] [--exit] [--nogui]
4K30 is 6 Gbit/s each way: MTU 9000 on both ends, --payload 8176 --flows 16,
and udp_echo with 16 ports on the board.
"""

import argparse
import ctypes
import os
import queue
import subprocess
import threading
import time

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
KEEP_S = 2.0                # a frame not back after this long counts as incomplete
RX_WINDOW_S = 0.5           # reassembly buffers in loopback_io.c cover this much video ...
RX_BUFFERS_MIN = 16
RX_BUFFERS_MAX_BYTES = 2 << 30   # ... up to this much memory


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--ip", default="192.168.100.1")
    p.add_argument("--port", type=int, default=1234)
    p.add_argument("--flows", type=int, default=4)
    p.add_argument("--res", default="1280x720")
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--seconds", type=float, default=5)
    p.add_argument("--payload", type=int, default=1456, help="frame bytes per packet")
    p.add_argument("--spread", type=float, default=0.8, help="fraction of the frame interval to send a frame in")
    p.add_argument("--cycle", type=int, default=0,
                   help="render this many frames up front and send them in turn (for rates above what "
                        "rendering keeps up with); every frame is still numbered and compared")
    p.add_argument("--out", default=os.path.join(os.getcwd(), "loopback_out"))
    p.add_argument("--auto", action="store_true", help="start immediately")
    p.add_argument("--exit", action="store_true", help="close when done (implies --auto)")
    p.add_argument("--nogui", action="store_true", help="run in the terminal")
    a = p.parse_args(argv)
    a.width, a.height = (int(v) for v in a.res.lower().split("x"))
    a.auto = a.auto or a.exit
    return a


def load_io():
    src = os.path.join(HERE, "loopback_io.c")
    lib = os.path.join(HERE, "libloopback_io.so")
    if not os.path.exists(lib) or os.path.getmtime(lib) < os.path.getmtime(src):
        subprocess.run(["gcc", "-O2", "-shared", "-fPIC", "-pthread", "-o", lib, src], check=True)
    L = ctypes.CDLL(lib)
    vp, u32, u64, i, d = ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64, ctypes.c_int, ctypes.c_double
    for name, res, args in (
            ("lb_open", vp, [ctypes.c_char_p, i, i, i, i, i]),
            ("lb_pkt_count", i, [vp]),
            ("lb_ephemeral", i, [vp]),
            ("lb_probe", i, [vp, i]),
            ("lb_start", None, [vp]),
            ("lb_send_frame", None, [vp, u32, ctypes.c_char_p, d]),
            ("lb_forget", None, [vp, u32]),
            ("lb_wait_event", i, [vp, i, ctypes.POINTER(u32), ctypes.POINTER(i), ctypes.POINTER(d)]),
            ("lb_copy_frame", i, [vp, u32, ctypes.c_void_p]),
            ("lb_stats", None, [vp, ctypes.POINTER(u64)]),
            ("lb_now_ns", u64, []),
            ("lb_stop", None, [vp]),
            ("lb_close", None, [vp])):
        f = getattr(L, name)
        f.restype, f.argtypes = res, args
    return L


class FrameGenerator:
    """Moving colour gradient, moving bars, a bouncing ball and the frame number."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        strip = Image.new("RGB", (2 * w, 1))
        px = strip.load()
        for x in range(2 * w):
            px[x, 0] = hsv(x * 360 / w, 0.7, 0.45)
        self.bg = strip.resize((2 * w, h), Image.NEAREST)
        self.big = ImageFont.truetype(FONT, h // 8)
        self.small = ImageFont.truetype(FONT, h // 24)

    def render(self, n, fps):
        w, h = self.w, self.h
        t = n / fps
        off = int(t * w / 4) % w
        im = self.bg.crop((off, 0, off + w, h))
        d = ImageDraw.Draw(im)
        for i in range(8):
            x = int(i * w / 8 + t * w / 4) % w
            d.rectangle((x, 0, x + w // 16, h), fill=hsv(i * 45, 0.6, 0.8))
        bx, by = abs((t * 0.37) % 2 - 1), abs((t * 0.53) % 2 - 1)
        r = h // 7
        x0, y0 = int(bx * (w - 2 * r)), int(by * (h - 2 * r))
        d.ellipse((x0, y0, x0 + 2 * r, y0 + 2 * r), fill=(255, 210, 40))
        d.text((w * 0.05, h * 0.06), f"FRAME {n:04d}", font=self.big, fill=(255, 255, 255))
        d.text((w * 0.05, h * 0.24), f"t = {t:.3f} s   {w}x{h}   RFSoC 4x2 Corundum loopback",
               font=self.small, fill=(255, 255, 255))
        return im.tobytes()


def hsv(hue, s, v):
    hue %= 360
    i = int(hue // 60) % 6
    f = hue / 60 - int(hue // 60)
    p, q, u = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    r, g, b = [(v, u, p), (q, v, p), (p, v, u), (p, q, v), (u, p, v), (v, p, q)][i]
    return int(r * 255), int(g * 255), int(b * 255)


class LoopbackSession:
    def __init__(self, o):
        self.o = o
        self.io = load_io()
        self.frame_bytes = o.width * o.height * 3
        # A frame still missing packets when its buffer is needed again is lost, so keep
        # enough buffers for the frames in flight at high frame rates.
        nbuf = max(RX_BUFFERS_MIN, min(round(RX_WINDOW_S * o.fps), RX_BUFFERS_MAX_BYTES // self.frame_bytes))
        self.ctx = self.io.lb_open(o.ip.encode(), o.port, o.flows, o.payload, self.frame_bytes, nbuf)
        if not self.ctx:
            raise ValueError("cannot open sockets (or more than 65535 packets per frame; raise --payload)")
        self.pkt_count = self.io.lb_pkt_count(self.ctx)
        self.frames_sent = 0
        self.lat_sum = self.lat_max = 0.0
        self.frames_done = 0
        self.sent = {}                  # frame id -> (bytes, send time); alive until compared
        self.gate = threading.Lock()
        self.stop = False
        self.send_done = False
        self.finished = threading.Event()
        self.last_sent = None
        self.last_sent_id = self.last_recv_id = None
        self.save_q = queue.Queue()
        self.t0 = self.t_end = None
        self.recv_buf = bytearray(self.frame_bytes)

    def warm_up(self):
        bad = self.io.lb_probe(self.ctx, 300)
        if not bad:
            return None
        msg = f"no echo from {self.o.ip}:{self.o.port + bad - 1}"
        if self.io.lb_ephemeral(self.ctx):
            msg += f" (local ports {self.o.port}+ are in use, so a tc reflector cannot answer)"
        return msg

    def start(self):
        os.makedirs(self.o.out, exist_ok=True)
        self.gen = FrameGenerator(self.o.width, self.o.height)
        n = min(self.o.cycle, round(self.o.seconds * self.o.fps))
        self.cycle = [self.gen.render(k, self.o.fps) for k in range(n)]     # before the clock starts
        self.t0 = self.io.lb_now_ns()
        self.io.lb_start(self.ctx)
        self.frames = queue.Queue(maxsize=4)
        self.save_thread = threading.Thread(target=self.save_loop, daemon=True)
        for t in (threading.Thread(target=self.gen_loop, daemon=True),
                  threading.Thread(target=self.tx_loop, daemon=True),
                  threading.Thread(target=self.ev_loop, daemon=True), self.save_thread):
            t.start()

    def done(self):
        return self.finished.is_set() and not self.save_thread.is_alive()

    def stats(self):
        v = (ctypes.c_uint64 * 8)()
        self.io.lb_stats(self.ctx, v)
        return list(v)

    def elapsed(self):
        if self.t0 is None:
            return 0.0
        end = self.t_end if self.t_end is not None else self.io.lb_now_ns()
        return (end - self.t0) / 1e9

    def gen_loop(self):
        gen, cycle = self.gen, self.cycle
        for fid in range(round(self.o.seconds * self.o.fps)):
            frame = cycle[fid % len(cycle)] if cycle else gen.render(fid, self.o.fps)
            while not self.stop:
                try:
                    self.frames.put((fid, frame), timeout=0.1)
                    break
                except queue.Full:
                    pass
            if self.stop:
                return
        self.frames.put(None)

    def tx_loop(self):
        o = self.o
        interval_ns = 1e9 / o.fps
        spread = o.spread / o.fps
        while not self.stop:
            item = self.frames.get()
            if item is None:
                break
            fid, frame = item
            due = self.t0 + fid * interval_ns
            while not self.stop and self.io.lb_now_ns() < due:
                time.sleep(0.0005)
            with self.gate:
                self.sent[fid] = (frame, self.io.lb_now_ns())
            self.last_sent, self.last_sent_id = frame, fid
            self.io.lb_send_frame(self.ctx, fid, frame, spread)
            self.frames_sent += 1
        self.send_done = True

    def ev_loop(self):
        fid, ok, lat = ctypes.c_uint32(), ctypes.c_int(), ctypes.c_double()
        last_sweep = 0
        while not self.stop:
            if self.io.lb_wait_event(self.ctx, 100, ctypes.byref(fid), ctypes.byref(ok), ctypes.byref(lat)):
                f = fid.value
                with self.gate:
                    orig = self.sent.pop(f, (None, None))[0]
                self.frames_done += 1
                if orig is not None:
                    self.lat_sum += lat.value
                    self.lat_max = max(self.lat_max, lat.value)
                self.last_recv_id = f
                if ok.value and f % max(1, self.o.fps) == 0:
                    rb = bytearray(self.frame_bytes)
                    if self.io.lb_copy_frame(self.ctx, f, (ctypes.c_char * self.frame_bytes).from_buffer(rb)):
                        self.save_q.put((f, orig, rb))
            now = self.io.lb_now_ns()
            if now - last_sweep > 5e8:
                last_sweep = now
                with self.gate:
                    old = [k for k, v in self.sent.items() if now - v[1] > KEEP_S * 1e9]
                    for k in old:
                        self.io.lb_forget(self.ctx, k)
                        del self.sent[k]
            last_rx = self.stats()[4]
            if self.send_done and now - max(last_rx, self.t0) > 1e9 and not self.sent:
                break
            if self.send_done and now - max(last_rx, self.t0) > KEEP_S * 1e9:
                break
        self.t_end = max(self.stats()[4], self.t0)
        self.stop = True
        self.io.lb_stop(self.ctx)
        self.save_q.put(None)
        self.finished.set()

    def latest_recv(self):
        """The newest completed received frame, or None if its buffer was reused meanwhile."""
        f = self.last_recv_id
        if f is None:
            return None, None
        buf = (ctypes.c_char * self.frame_bytes).from_buffer(self.recv_buf)
        return (f, bytes(self.recv_buf)) if self.io.lb_copy_frame(self.ctx, f, buf) else (None, None)

    def save_loop(self):
        o = self.o
        while True:
            item = self.save_q.get()
            if item is None:
                return
            fid, sent, recv = item
            both = Image.new("RGB", (o.width * 2 + 8, o.height))
            both.paste(Image.frombytes("RGB", (o.width, o.height), sent), (0, 0))
            both.paste(Image.frombytes("RGB", (o.width, o.height), bytes(recv)), (o.width + 8, 0))
            both.save(os.path.join(o.out, f"frame_{fid:04d}_sent_vs_received.png"), compress_level=1)

    def summary(self):
        o = self.o
        ps, bs, pr, br, _, fok, fbad, _ = self.stats()
        el = max(1e-9, self.elapsed())
        lost = 100 * (ps - pr) / ps if ps else 0
        return (
            f"Board {o.ip}:{o.port}-{o.port + o.flows - 1} ({o.flows} flows)   {o.width}x{o.height} @ {o.fps} fps, "
            f"{o.seconds:g} s   ({self.pkt_count} packets/frame, {self.frame_bytes} B/frame)\n"
            f"Frames   sent {self.frames_sent}   received intact {fok}   corrupted {fbad}   "
            f"incomplete {self.frames_sent - fok - fbad}\n"
            f"Packets  sent {ps}   received {pr}   lost {lost:.4f} %\n"
            f"Rate     TX {bs * 8 / el / 1e6:.1f} Mbps   RX {br * 8 / el / 1e6:.1f} Mbps   "
            f"frame latency avg {self.lat_sum / self.frames_done if self.frames_done else 0:.2f} ms / "
            f"max {self.lat_max:.2f} ms")

    def write_summary(self):
        with open(os.path.join(self.o.out, "summary.txt"), "w") as f:
            f.write(self.summary() + "\n")

    def close(self):
        self.io.lb_close(self.ctx)
        self.ctx = None


def run_nogui(o):
    sess = LoopbackSession(o)
    err = sess.warm_up()
    if err:
        print(err + " - is tools/udp_echo running on the board?")
        return 1
    sess.start()
    while not sess.finished.wait(1.0):
        print(sess.summary().splitlines()[1], flush=True)
    sess.save_thread.join()
    sess.write_summary()
    print(sess.summary())
    print(f"Side-by-side PNGs and summary.txt in {o.out}")
    ok = sess.stats()[5] == sess.frames_sent
    sess.close()
    return 0 if ok else 2


def run_gui(o):
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import Gdk, GdkPixbuf, GLib, Gtk

    css = Gtk.CssProvider()
    css.load_from_data(b".picture { background-color: black; }")
    Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                             Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    class Picture(Gtk.EventBox):
        """Frame scaled to fit by GdkPixbuf (no pycairo needed), centred on black."""

        def __init__(self):
            super().__init__()
            self.get_style_context().add_class("picture")
            self.set_size_request(320, 180)
            self.image = Gtk.Image()
            self.add(self.image)

        def show_frame(self, data, w, h):
            aw, ah = self.get_allocated_width(), self.get_allocated_height()
            k = min(aw / w, ah / h)
            if k <= 0:
                return
            pix = GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(data), GdkPixbuf.Colorspace.RGB,
                                                  False, 8, w, h, w * 3)
            interp = GdkPixbuf.InterpType.BILINEAR if w * h <= 1920 * 1080 else GdkPixbuf.InterpType.TILES
            self.image.set_from_pixbuf(pix.scale_simple(max(1, int(w * k)), max(1, int(h * k)), interp))

    class MainWindow(Gtk.Window):
        def __init__(self):
            super().__init__(title="RFSoC 4x2 Corundum UDP Loopback Viewer")
            Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", True)
            self.set_default_size(1320, 640)
            self.sess = None
            self.shown_sent = self.shown_recv = None

            bar = Gtk.Box(spacing=6, margin=8)
            self.fields = {}
            for key, label, value, width in (("ip", "Board IP", o.ip, 14), ("port", "Port", o.port, 6),
                                             ("flows", "Flows", o.flows, 3), ("res", "Resolution", o.res, 10),
                                             ("fps", "FPS", o.fps, 4), ("seconds", "Seconds", f"{o.seconds:g}", 5),
                                             ("payload", "Payload", o.payload, 5)):
                bar.pack_start(Gtk.Label(label=label), False, False, 0)
                e = Gtk.Entry(text=str(value), width_chars=width)
                bar.pack_start(e, False, False, 0)
                self.fields[key] = e
            self.start_b = Gtk.Button(label="Start")
            self.stop_b = Gtk.Button(label="Stop", sensitive=False)
            self.start_b.connect("clicked", lambda _b: self.start_run())
            self.stop_b.connect("clicked", lambda _b: self.sess and setattr(self.sess, "stop", True))
            bar.pack_start(self.start_b, False, False, 12)
            bar.pack_start(self.stop_b, False, False, 0)

            grid = Gtk.Grid(column_spacing=8, row_spacing=4, margin=8, column_homogeneous=True)
            self.left_cap = Gtk.Label(label="Sent", xalign=0)
            self.right_cap = Gtk.Label(label="Received (echoed by the board)", xalign=0)
            self.left, self.right = Picture(), Picture()
            for p in (self.left, self.right):
                p.set_hexpand(True)
                p.set_vexpand(True)
            self.stats = Gtk.Label(xalign=0, selectable=True)
            self.stats.set_markup("<tt> </tt>")
            grid.attach(self.left_cap, 0, 0, 1, 1)
            grid.attach(self.right_cap, 1, 0, 1, 1)
            grid.attach(self.left, 0, 1, 1, 1)
            grid.attach(self.right, 1, 1, 1, 1)
            grid.attach(self.stats, 0, 2, 2, 1)

            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            box.pack_start(bar, False, False, 0)
            box.pack_start(grid, True, True, 0)
            self.add(box)
            self.connect("destroy", self.on_destroy)
            if o.auto:
                GLib.idle_add(self.start_run)

        def on_destroy(self, _w):
            if self.sess:
                self.sess.stop = True
            Gtk.main_quit()

        def set_stats(self, text):
            self.stats.set_markup("<tt>" + GLib.markup_escape_text(text) + "</tt>")

        def start_run(self):
            try:
                f = self.fields
                o.ip = f["ip"].get_text().strip()
                o.port, o.flows, o.fps = int(f["port"].get_text()), int(f["flows"].get_text()), int(f["fps"].get_text())
                o.payload = int(f["payload"].get_text())
                o.res = f["res"].get_text().strip()
                o.width, o.height = (int(v) for v in o.res.lower().split("x"))
                o.seconds = float(f["seconds"].get_text())
                if self.sess:
                    self.sess.close()
                self.sess = LoopbackSession(o)
            except (ValueError, OSError, subprocess.CalledProcessError) as e:
                self.set_stats(f"Invalid settings: {e}")
                return False
            err = self.sess.warm_up()
            if err:
                self.set_stats(err + " - is tools/udp_echo running on the board?")
                if o.exit:
                    Gtk.main_quit()
                return False
            self.start_b.set_sensitive(False)
            self.stop_b.set_sensitive(True)
            self.shown_sent = self.shown_recv = None
            self.sess.start()
            GLib.timeout_add(100 if o.width * o.height <= 1920 * 1080 else 200, self.refresh)
            return False

        def refresh(self):
            s = self.sess
            if s.last_sent is not None and s.last_sent_id != self.shown_sent:
                self.shown_sent = s.last_sent_id
                self.left.show_frame(s.last_sent, o.width, o.height)
                self.left_cap.set_text(f"Sent            frame {self.shown_sent}")
            if s.last_recv_id is not None and s.last_recv_id != self.shown_recv and not s.finished.is_set():
                fid, data = s.latest_recv()
                if data is not None:
                    self.shown_recv = fid
                    self.right.show_frame(data, o.width, o.height)
                    self.right_cap.set_text(f"Received (echoed by the board)            frame {fid}")
            if s.done():
                s.write_summary()
                self.set_stats(s.summary() + f"\nDone. Side-by-side PNGs and summary.txt in {o.out}")
                self.start_b.set_sensitive(True)
                self.stop_b.set_sensitive(False)
                if o.exit:
                    GLib.timeout_add(500, Gtk.main_quit)
                return False
            self.set_stats(s.summary())
            return True

    win = MainWindow()
    win.show_all()
    Gtk.main()
    return 0


def main():
    o = parse_args()
    return run_nogui(o) if o.nogui else run_gui(o)


if __name__ == "__main__":
    raise SystemExit(main())
