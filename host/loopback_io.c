// SPDX-License-Identifier: BSD-2-Clause-Views
// Copyright (c) 2026 Yijie Yu
//
// loopback_io - packet I/O for udp_loopback_viewer.py, loaded with ctypes. Sending,
// receiving, frame reassembly and the byte-by-byte comparison run here, outside the
// Python GIL, so 4K video fits.
//
// Build: gcc -O2 -shared -fPIC -pthread -o libloopback_io.so loopback_io.c
// (udp_loopback_viewer.py builds it on first use.)

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAGIC 0x424C4652u      // "RFLB" little-endian
#define PROBE 0xFFFFFFFFu
#define HDR   16
#define BATCH 64
#define NSLOT 256              // frames sent but not yet compared
#define NEV   1024             // completion queue
#define GROUP 8                // consecutive packets per flow, so the board's UDP GRO can
                               // coalesce them (8 jumbo datagrams stay under 64 KB)

struct rxbuf {
	uint32_t fid;
	int used, count, done;
	uint8_t *data, *got;
};

struct slot {
	uint32_t fid;
	int valid;
	const uint8_t *data;
	uint64_t t_ns;
};

struct ev {
	uint32_t fid;
	int ok;
	double lat_ms;
};

typedef struct {
	int flows, payload, frame_bytes, pkt_count, nbuf, ephemeral;
	int *fd;
	struct sockaddr_in *dst;
	struct rxbuf *rb;
	struct slot slots[NSLOT];
	uint8_t *hdrs;
	pthread_mutex_t lock;
	pthread_cond_t cv;
	struct ev evq[NEV];
	int evh, evt;
	pthread_t rx;
	volatile int stop, rx_started;
	volatile uint64_t pkts_sent, bytes_sent, pkts_recv, bytes_recv, last_rx_ns;
	volatile uint64_t frames_ok, frames_bad, ev_dropped;
} lb_t;

static uint64_t now_ns(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}

static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void put16(uint8_t *p, uint16_t v) { memcpy(p, &v, 2); }
static uint32_t get32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint16_t get16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }

static void set_buf(int fd, int opt_force, int opt, int size)
{
	if (setsockopt(fd, SOL_SOCKET, opt_force, &size, sizeof(size)) < 0)
		setsockopt(fd, SOL_SOCKET, opt, &size, sizeof(size));
}

void lb_close(lb_t *c);

lb_t *lb_open(const char *ip, int port, int flows, int payload, int frame_bytes, int nbuf)
{
	lb_t *c = calloc(1, sizeof(*c));
	if (!c)
		return NULL;
	c->flows = flows;
	c->payload = payload;
	c->frame_bytes = frame_bytes;
	c->pkt_count = (frame_bytes + payload - 1) / payload;
	c->nbuf = nbuf;
	pthread_mutex_init(&c->lock, NULL);
	pthread_cond_init(&c->cv, NULL);
	c->fd = calloc(flows, sizeof(int));
	c->dst = calloc(flows, sizeof(*c->dst));
	c->rb = calloc(nbuf, sizeof(*c->rb));
	c->hdrs = malloc((size_t)c->pkt_count * HDR);
	if (c->fd)
		for (int f = 0; f < flows; f++)
			c->fd[f] = -1;
	if (!c->fd || !c->dst || !c->rb || !c->hdrs || c->pkt_count > 0xFFFF)
		goto fail;
	for (int f = 0; f < flows; f++) {
		int fd = socket(AF_INET, SOCK_DGRAM, 0);
		if (fd < 0)
			goto fail;
		c->fd[f] = fd;
		set_buf(fd, SO_RCVBUFFORCE, SO_RCVBUF, 256 << 20);
		set_buf(fd, SO_SNDBUFFORCE, SO_SNDBUF, 64 << 20);
		// Local port = remote port, so a reflector that only swaps MAC and IP addresses
		// (tools/tc_reflect.sh) returns each packet to the socket that sent it.
		struct sockaddr_in local = { .sin_family = AF_INET, .sin_port = htons(port + f) };
		if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
			local.sin_port = 0;
			if (bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0)
				goto fail;
			c->ephemeral = 1;
		}
		c->dst[f].sin_family = AF_INET;
		c->dst[f].sin_port = htons(port + f);
		if (inet_pton(AF_INET, ip, &c->dst[f].sin_addr) != 1)
			goto fail;
	}
	for (int i = 0; i < nbuf; i++) {
		c->rb[i].data = malloc(frame_bytes);
		c->rb[i].got = malloc(c->pkt_count);
		if (!c->rb[i].data || !c->rb[i].got)
			goto fail;
		// touch every page now: first-touch page faults inside the receive loop
		// slow it down enough to lose packets at 20+ Gbit/s
		memset(c->rb[i].data, 0, frame_bytes);
	}
	return c;
fail:
	lb_close(c);
	return NULL;
}

int lb_pkt_count(lb_t *c) { return c->pkt_count; }

// 1 if some flow could not bind its local port = remote port (only udp_echo can answer then)
int lb_ephemeral(lb_t *c) { return c->ephemeral; }

// One probe per flow before the receive thread starts. Returns 0, or flow index + 1 that did not answer.
int lb_probe(lb_t *c, int timeout_ms)
{
	uint8_t p[HDR] = {0}, r[2048];
	put32(p, MAGIC);
	put32(p + 4, PROBE);
	struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
	for (int f = 0; f < c->flows; f++) {
		setsockopt(c->fd[f], SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		int ok = 0;
		for (int a = 0; a < 5 && !ok; a++) {
			sendto(c->fd[f], p, HDR, 0, (struct sockaddr *)&c->dst[f], sizeof(c->dst[f]));
			ssize_t n = recv(c->fd[f], r, sizeof(r), 0);
			ok = n >= HDR && get32(r) == MAGIC && get32(r + 4) == PROBE;
		}
		if (!ok)
			return f + 1;
	}
	return 0;
}

static void complete(lb_t *c, struct rxbuf *b, uint64_t t)
{
	pthread_mutex_lock(&c->lock);
	struct slot *s = &c->slots[b->fid % NSLOT];
	int ok = 0;
	double lat = 0;
	if (s->valid && s->fid == b->fid) {
		ok = memcmp(s->data, b->data, c->frame_bytes) == 0;
		lat = (t - s->t_ns) / 1e6;
		s->valid = 0;
	}
	b->done = 1;
	if (ok)
		c->frames_ok++;
	else
		c->frames_bad++;
	int next = (c->evt + 1) % NEV;
	if (next == c->evh) {
		c->ev_dropped++;
	} else {
		c->evq[c->evt] = (struct ev){ b->fid, ok, lat };
		c->evt = next;
	}
	pthread_cond_signal(&c->cv);
	pthread_mutex_unlock(&c->lock);
}

static void handle(lb_t *c, const uint8_t *p, int n, uint64_t t)
{
	if (n < HDR || get32(p) != MAGIC)
		return;
	uint32_t fid = get32(p + 4), off = get32(p + 12);
	int idx = get16(p + 8), len = n - HDR;
	if (fid == PROBE || idx >= c->pkt_count || (uint64_t)off + len > (uint64_t)c->frame_bytes)
		return;
	c->pkts_recv++;
	c->bytes_recv += n;
	struct rxbuf *b = &c->rb[fid % c->nbuf];
	if (!b->used || b->fid != fid) {
		if (b->used && (int32_t)(b->fid - fid) > 0)
			return;                 // late packet of a frame whose buffer was reused
		pthread_mutex_lock(&c->lock);
		b->fid = fid;
		b->used = 1;
		b->count = 0;
		b->done = 0;
		pthread_mutex_unlock(&c->lock);
		memset(b->got, 0, c->pkt_count);
	}
	if (b->done || b->got[idx])
		return;
	b->got[idx] = 1;
	memcpy(b->data + off, p + HDR, len);
	if (++b->count == c->pkt_count)
		complete(c, b, t);
}

static void *rx_main(void *arg)
{
	lb_t *c = arg;
	int ep = epoll_create1(0);
	for (int f = 0; f < c->flows; f++) {
		struct epoll_event e = { .events = EPOLLIN, .data.u32 = f };
		epoll_ctl(ep, EPOLL_CTL_ADD, c->fd[f], &e);
	}
	int sz = HDR + c->payload + 64;
	uint8_t *buf = malloc((size_t)BATCH * sz);
	struct mmsghdr m[BATCH];
	struct iovec iov[BATCH];
	struct epoll_event evs[64];
	while (!c->stop) {
		int ne = epoll_wait(ep, evs, 64, 100);
		for (int e = 0; e < ne; e++) {
			int fd = c->fd[evs[e].data.u32];
			for (;;) {
				for (int i = 0; i < BATCH; i++) {
					iov[i] = (struct iovec){ buf + (size_t)i * sz, sz };
					memset(&m[i].msg_hdr, 0, sizeof(m[i].msg_hdr));
					m[i].msg_hdr.msg_iov = &iov[i];
					m[i].msg_hdr.msg_iovlen = 1;
				}
				int r = recvmmsg(fd, m, BATCH, MSG_DONTWAIT, NULL);
				if (r <= 0)
					break;
				uint64_t t = now_ns();
				c->last_rx_ns = t;
				for (int i = 0; i < r; i++)
					handle(c, iov[i].iov_base, m[i].msg_len, t);
				if (r < BATCH)
					break;
			}
		}
	}
	free(buf);
	close(ep);
	return NULL;
}

void lb_start(lb_t *c)
{
	c->stop = 0;
	c->rx_started = pthread_create(&c->rx, NULL, rx_main, c) == 0;
}

// Register the frame for comparison, then send it paced over spread_s seconds.
// The caller keeps frame alive until its completion event or lb_forget().
void lb_send_frame(lb_t *c, uint32_t fid, const uint8_t *frame, double spread_s)
{
	uint64_t t0 = now_ns();
	pthread_mutex_lock(&c->lock);
	c->slots[fid % NSLOT] = (struct slot){ fid, 1, frame, t0 };
	pthread_mutex_unlock(&c->lock);

	// pace in steps of BATCH packets in total (spread over the flows), not per flow:
	// with 16 flows a per-flow batch would be a 1024-packet burst
	int flows = c->flows, per = BATCH > flows ? BATCH : flows;
	struct mmsghdr *m = calloc((size_t)BATCH * flows, sizeof(*m));
	struct iovec *iov = calloc((size_t)BATCH * flows * 2, sizeof(*iov));
	int *cnt = calloc(flows, sizeof(int));
	double window = spread_s * 1e9;
	for (int p0 = 0; p0 < c->pkt_count && !c->stop; p0 += per) {
		uint64_t due = t0 + (uint64_t)(window * p0 / c->pkt_count);
		for (uint64_t t = now_ns(); t < due; t = now_ns()) {
			if (due - t > 200000) {
				struct timespec ts = { 0, 100000 };
				nanosleep(&ts, NULL);
			}
		}
		memset(cnt, 0, flows * sizeof(int));
		int end = p0 + per < c->pkt_count ? p0 + per : c->pkt_count;
		for (int p = p0; p < end; p++) {
			int f = (p / GROUP) % flows, k = f * BATCH + cnt[f]++;
			uint8_t *h = c->hdrs + (size_t)p * HDR;
			uint32_t off = (uint32_t)p * c->payload;
			int len = c->frame_bytes - (int)off < c->payload ? c->frame_bytes - (int)off : c->payload;
			put32(h, MAGIC);
			put32(h + 4, fid);
			put16(h + 8, p);
			put16(h + 10, c->pkt_count);
			put32(h + 12, off);
			iov[2 * k] = (struct iovec){ h, HDR };
			iov[2 * k + 1] = (struct iovec){ (void *)(frame + off), len };
			memset(&m[k].msg_hdr, 0, sizeof(m[k].msg_hdr));
			m[k].msg_hdr.msg_iov = &iov[2 * k];
			m[k].msg_hdr.msg_iovlen = 2;
			m[k].msg_hdr.msg_name = &c->dst[f];
			m[k].msg_hdr.msg_namelen = sizeof(c->dst[f]);
			c->bytes_sent += HDR + len;
		}
		for (int f = 0; f < flows; f++) {
			for (int done = 0; done < cnt[f];) {
				int r = sendmmsg(c->fd[f], m + f * BATCH + done, cnt[f] - done, 0);
				if (r < 0) {
					if (errno == EINTR)
						continue;
					struct timespec ts = { 0, 50000 };   // ENOBUFS / EAGAIN: let the queue drain
					nanosleep(&ts, NULL);
					continue;
				}
				done += r;
			}
			c->pkts_sent += cnt[f];
		}
	}
	free(cnt);
	free(iov);
	free(m);
}

// Drop the comparison entry of a frame the caller is about to free.
void lb_forget(lb_t *c, uint32_t fid)
{
	pthread_mutex_lock(&c->lock);
	struct slot *s = &c->slots[fid % NSLOT];
	if (s->valid && s->fid == fid)
		s->valid = 0;
	pthread_mutex_unlock(&c->lock);
}

// Wait for the next completed frame. Returns 1 with fid/ok/latency, 0 on timeout.
int lb_wait_event(lb_t *c, int timeout_ms, uint32_t *fid, int *ok, double *lat_ms)
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000;
	ts.tv_sec += timeout_ms / 1000 + ts.tv_nsec / 1000000000;
	ts.tv_nsec %= 1000000000;
	pthread_mutex_lock(&c->lock);
	while (c->evh == c->evt) {
		if (pthread_cond_timedwait(&c->cv, &c->lock, &ts) == ETIMEDOUT)
			break;
	}
	int got = c->evh != c->evt;
	if (got) {
		struct ev e = c->evq[c->evh];
		c->evh = (c->evh + 1) % NEV;
		*fid = e.fid;
		*ok = e.ok;
		*lat_ms = e.lat_ms;
	}
	pthread_mutex_unlock(&c->lock);
	return got;
}

// Copy a completed received frame. Returns 0 if its buffer has been reused since.
int lb_copy_frame(lb_t *c, uint32_t fid, uint8_t *dst)
{
	pthread_mutex_lock(&c->lock);
	struct rxbuf *b = &c->rb[fid % c->nbuf];
	int ok = b->used && b->fid == fid && b->done;
	if (ok)
		memcpy(dst, b->data, c->frame_bytes);
	pthread_mutex_unlock(&c->lock);
	return ok;
}

// pkts_sent bytes_sent pkts_recv bytes_recv last_rx_ns frames_ok frames_bad events_dropped
void lb_stats(lb_t *c, uint64_t *out)
{
	uint64_t v[8] = { c->pkts_sent, c->bytes_sent, c->pkts_recv, c->bytes_recv,
			  c->last_rx_ns, c->frames_ok, c->frames_bad, c->ev_dropped };
	memcpy(out, v, sizeof(v));
}

uint64_t lb_now_ns(void) { return now_ns(); }

void lb_stop(lb_t *c)
{
	c->stop = 1;
	if (c->rx_started)
		pthread_join(c->rx, NULL);
	c->rx_started = 0;
}

void lb_close(lb_t *c)
{
	if (!c)
		return;
	lb_stop(c);
	if (c->fd)
		for (int f = 0; f < c->flows; f++)
			if (c->fd[f] >= 0)
				close(c->fd[f]);
	if (c->rb)
		for (int i = 0; i < c->nbuf; i++) {
			free(c->rb[i].data);
			free(c->rb[i].got);
		}
	free(c->rb);
	free(c->fd);
	free(c->dst);
	free(c->hdrs);
	free(c);
}
