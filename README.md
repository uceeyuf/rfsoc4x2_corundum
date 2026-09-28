![语言](https://img.shields.io/badge/语言-verilog_(IEEE1364_2001)-9A90FD.svg) ![部署](https://img.shields.io/badge/部署-vivado_2020.2-FF1010.svg) ![板卡](https://img.shields.io/badge/板卡-RFSoC_4x2-blue.svg) ![速率](https://img.shields.io/badge/速率-25GbE-green.svg) ![基于](https://img.shields.io/badge/基于-Corundum-orange.svg)

[English](#en) | [中文](#cn)

　

<span id="en">Corundum 25G NIC on the RFSoC 4x2</span>
===========================

A port of [**Corundum**](https://github.com/corundum/corundum), the open-source FPGA NIC by
**Alex Forencich** (UC San Diego), to the RealDigital RFSoC 4x2 (XCZU48DR-FFVG1517-2-E):
25GBASE-R on the QSFP28 cage, DMA into PS DDR through the Zynq UltraScale+ HPC0 port, and the
standard `mqnic` Linux driver on the ARM cores.

Almost all of the design is Corundum, unmodified. It is included as a submodule pinned at
[`1ca0151`](https://github.com/corundum/corundum/commit/1ca0151b97af85aa5dd306d74b6bcec65904d2ce)
(2023-12-02), and this repository starts from Corundum's ZCU102 target (Alex Forencich and
MissingLinkElectronics). What this repository adds is the board-specific layer: the top level,
pins, PS configuration, the GTY transceiver setup, and the changes needed to go from 10G to 25G.

Result: with a kernel-space UDP reflector on the board, **22.15 Gbit/s in each direction at
the same time** (about 44.3 Gbit/s through the NIC): 4K120 RGB video, 1200/1200 frames
byte-exact, zero packet loss. The board alone transmits at 25G line rate (24.83 Gbit/s on the
wire, kernel pktgen). Timing met ([test report](docs/TEST_REPORT.md),
[test procedure](docs/TESTING.md)).

### Table of contents

- [Design](#en1)
- [Key problem: QSFP RX lanes reversed](#en2)
- [Build](#en3)
- [Run](#en4)
- [Loopback benchmark](#en7)
- [Layout](#en5)
- [License and acknowledgements](#en6)

　

# <span id="en1">Design</span>

```
QSFP28 lane 1 <-> GTY quad 128 (25.78125 Gb/s, refclk 156.25 MHz) <-> eth_phy_10g (64b/66b) <-> eth_mac_10g
                         64 bit @ 390.625 MHz  <->  async FIFO  <->  128 bit @ 300 MHz (pl_clk0)
                                                     mqnic_core_axi  <->  S_AXI_HPC0  <->  PS DDR
```

| File | Change from Corundum's ZCU102 target |
|---|---|
| `rtl/fpga.v` | 100 MHz LVDS clock + MMCM for 125 MHz; GTY instead of GTH; 25G PHY parameters; QSFP RX lane crossing; 128-bit sync datapath; ZCU102 LEDs, buttons, switches, DDR4 and SFP tx_disable removed |
| `rtl/fpga_core.v` | transceiver register block reports GTYE4 instead of GTHE4 |
| `constraints/fpga.xdc` | RFSoC 4x2 pins: QSFP28 (GTY quad 128), refclk, 100 MHz clock, QSFP sideband |
| `ip/eth_xcvr_gty.tcl` | GTY wizard at 25.78125 Gb/s from 156.25 MHz (fractional-N QPLL), 64-bit internal width |
| `ip/zynq_ps.tcl` | RFSoC 4x2 PS block design (exported from the working project) |
| `scripts/config.tcl` | Corundum configuration, with FPGA_ID and BOARD_ID for this board |

| Item | Value |
|---|---|
| Interfaces | 2 × 1 port; eth0 = QSFP lane 1 (tested), eth1 = QSFP lane 2 (untested) |
| Line | 25GBASE-R, no FEC, no auto-negotiation |
| Register space | `0xA000_0000` (control), `0xA800_0000` (application), 16 MB each |
| Clocks | core 300 MHz (pl_clk0), MAC/PHY 390.625 MHz, PTP 156.25 MHz |

# <span id="en2">Key problem: QSFP RX lanes reversed</span>

On the RFSoC 4x2 the QSFP RX lanes are reversed relative to TX. The board transmitted but
received nothing: with the peer on QSFP lane 1, its signal lands on GT channel 3, while eth0
receives on GT channel 0. This cannot be fixed in the XDC, because a GT channel's TX and RX pins
belong to the same site; the RX data streams are crossed in `fpga.v` instead, with TX left as is.
How it was found (`mqnic-dump`, eye scan with `mqnic-xcvr`) is in
[docs/PORTING_NOTES.md](docs/PORTING_NOTES.md).

The other changes are routine: the 25G settings (GTY, 128-bit sync datapath, `COUNT_125US`,
SERDES pipeline, GTYE4 register block) are the same as in Corundum's own Alveo 25G targets, and
the rest adapts to the board (100 MHz clock input, pins, PS block design). They are listed in
the porting notes too.

# <span id="en3">Build</span>

Vivado 2020.2 (no board files needed):

```
git clone --recursive https://github.com/uceeyuf/rfsoc4x2_corundum.git
cd rfsoc4x2_corundum
vivado -mode batch -source scripts/build.tcl -tclargs 8
```

Writes `build/fpga.bit`, `build/rfsoc4x2_mqnic.xsa` and `build/timing_summary.rpt`.

# <span id="en4">Run</span>

The FPGA side is Corundum's standard AXI (non-PCIe) configuration, so the software is Corundum's too:

- **Driver:** build `third_party/corundum/modules/mqnic` against the board's kernel and load
  `mqnic.ko`. On the 5.4 kernel of the Xilinx 2020.2 image it needs
  [`patches/0002`](patches/0002-mqnic-port-devlink-attrs-pre-5.9.patch) to build;
  [`patches/0001`](patches/0001-mqnic-rx-drop-sync-after-unmap.patch) removes a wrong
  per-packet DMA sync and cuts receive CPU time by 5-12 %. The driver oopses on `rmmod`, so
  load another version only after a reboot.
- **Device tree:** the register map and interrupts are the same as the ZCU102 target, so
  `third_party/corundum/fpga/mqnic/ZCU102/fpga/ps/overlay.dtsi` applies as is.
- **Bitstream:** boot with `fpga.bit` in BOOT.BIN, or load it at run time through the FPGA manager.
- **Peer:** 25G with FEC off. The FPGA side has no RS-FEC and no auto-negotiation.
- **Interrupts:** all `mqnic0-*` interrupts land on CPU0 by default, which caps transmit at
  about 1.25 Mpps. `scripts/test/board_setup.sh` sets the address and MTU and spreads them over
  the four CPUs.

The full bring-up and measurement procedure (ping, iperf3, pktgen in both directions, jumbo
frames) is in [docs/TESTING.md](docs/TESTING.md).

Corundum's `utils/mqnic-dump` and `utils/mqnic-xcvr` read the queue state and the transceiver
directly. They were what found the lane reversal; see the porting notes.

# <span id="en7">Loopback benchmark</span>

[`host/udp_loopback_viewer.py`](host/udp_loopback_viewer.py) sends RGB24 test video to the
board, the board sends every packet back, and the host reassembles each frame and compares it
byte by byte with what it sent (packet format of
[rfsoc4x2_25g_udp](https://github.com/uceeyuf/rfsoc4x2_25g_udp)'s loopback viewer). Two
reflectors on the board:

| Board side | Per direction | Result |
|---|---|---|
| [`tools/udp_echo`](tools/udp_echo.c): user-space socket echo | 5-6 Gbit/s | the four A53 cores saturate; 4K25 500/500 frames |
| [`tools/tc_reflect.sh`](tools/tc_reflect.sh): tc ingress swaps MAC and IP and sends the packet back out | **22.15 Gbit/s** | **4K120: 1200/1200 frames byte-exact, 0 packets lost** |

At 22.15 Gbit/s each way the NIC carries about 44.3 Gbit/s. 25GBASE-R carries at most
24.8 Gbit/s of this payload with 9000-byte frames. The board received and sent every packet
(tc dropped 0). Raw results: [docs/results/loopback_2026-09-28.txt](docs/results/loopback_2026-09-28.txt).

What it takes:

- **Jumbo frames**, MTU 9000 on both ends; viewer `--payload 8956 --flows 16`.
- **A kernel with BPF and tc.** The image's kernel has neither.
  [`kernel/build.sh`](kernel/build.sh) cross-compiles the same Xilinx 2020.2 kernel with the
  board's configuration plus [`kernel/bpf_tc.cfg`](kernel/bpf_tc.cfg), and mqnic for it.
- **Host receive capacity:** large socket buffers (`net.core.rmem_max`) and reassembly memory
  allocated before the run (the viewer does this). With a 4 MB `rmem_max` the host dropped
  0.45 % at 20 Gbit/s while every packet reached its NIC.
- **Pacing:** each frame is spread over the frame interval (`--spread`). Close to 25G, bursts
  above line rate occasionally drop packets (two of four 4K120 runs at `--spread 0.9` lost 3-3.6 %);
  this is not a fixed limit of the datapath.

```
# board, as root
scripts/test/board_setup.sh 192.168.100.1/24 9000
tools/tc_reflect.sh <host MAC> 192.168.100.2 1234 16        # or: tools/udp_echo 1234 16
# host
sudo ip link set enp2s0np0 mtu 9000
sudo sysctl -w net.core.rmem_max=268435456
host/udp_loopback_viewer.py --flows 16 --res 3840x2160 --fps 120 --payload 8956 --spread 1.0 --cycle 20
```

`--cycle 20` renders 20 frames up front and sends them in turn; every frame is still numbered
and compared on its own (rendering 4K in Python takes 14 ms a frame). `--nogui` runs in a
terminal. Packet I/O, reassembly and the comparison are in C (`host/loopback_io.c`, built with
gcc on first use); the GUI needs PyGObject (GTK 3) and Pillow.

What persists across reboots:

| | Setting | Persists |
|---|---|---|
| Board: kernel and boot | BOOT partition `Image` = the BPF/tc kernel `5.4.0-xilinx-v2020.2-bpf`, the original kept as `Image.orig`; its modules in `/lib/modules/5.4.0-xilinx-v2020.2-bpf` | yes. To go back, rename `Image.orig` to `Image` |
| Board: runtime | MTU 9000 and interrupt affinity (`board_setup.sh`), tc reflector (`tc_reflect.sh`), `udp_echo` | no, set again after every boot |
| Host: runtime | MTU 9000 on the 25G port, `net.core.rmem_max` | no, set again after every boot |

# <span id="en5">Layout</span>

```
rtl/          top level and core wrapper (from Corundum's ZCU102 target, modified)
constraints/  RFSoC 4x2 pins
ip/           GTY wizard and PS block design scripts
scripts/      build, project creation, Corundum configuration
scripts/test/ board setup, pktgen and iperf3 scripts
host/         loopback viewer (Python, GTK) and its C packet I/O
tools/        board tools: udp_echo, tc_reflect.sh, rx_measure.sh
patches/      mqnic driver patches against Corundum 1ca0151
kernel/       BPF/tc kernel configuration fragment and build script
docs/         porting notes, test procedure, test report, results
third_party/  Corundum (submodule, pinned)
```

# <span id="en6">License and acknowledgements</span>

BSD-2-Clause-Views, the same license as Corundum. The copyright of Corundum and of the ZCU102
target stays with The Regents of the University of California and MissingLinkElectronics; the
changes in this repository are Copyright (c) 2026, Yijie Yu. See [LICENSE](LICENSE).

This work stands on [Corundum](https://github.com/corundum/corundum) by Alex Forencich and its
contributors, including the `eth_phy_10g` PCS, the MAC, the DMA engine, the `mqnic` driver and
the diagnostic tools used to debug this port. The ZCU102 target it starts from is by
MissingLinkElectronics. Pin data comes from the RealDigital RFSoC 4x2 board files.

　

　

<span id="cn">Corundum 25G 网卡移植到 RFSoC 4x2</span>
===========================

把 **Alex Forencich**(UC San Diego)的开源 FPGA 网卡 [**Corundum**](https://github.com/corundum/corundum)
移植到 RealDigital RFSoC 4x2(XCZU48DR-FFVG1517-2-E):QSFP28 口跑 25GBASE-R,DMA 经 Zynq UltraScale+
的 HPC0 口直达 PS DDR,ARM 上跑标准的 `mqnic` Linux 驱动。

设计的绝大部分是 Corundum 原封不动的代码,以 submodule 形式引入,固定在
[`1ca0151`](https://github.com/corundum/corundum/commit/1ca0151b97af85aa5dd306d74b6bcec65904d2ce)
(2023-12-02)。本仓库以 Corundum 的 ZCU102 工程(Alex Forencich 与 MissingLinkElectronics)为起点,
只增加板级这一层:顶层、引脚、PS 配置、GTY 收发器配置,以及从 10G 升到 25G 所需的改动。

结果:板上用内核态 UDP 回送,**每个方向同时 22.15 Gbit/s**(经过网卡的总流量约 44.3 Gbit/s):
4K120 RGB 视频 1200/1200 帧逐字节正确,零丢包。板卡单独发送达到 25G 线速(内核 pktgen,线路速率
24.83 Gbit/s)。时序收敛([测试报告](docs/TEST_REPORT.md#cn),[测试步骤](docs/TESTING.md#cn))。

### 目录

- [设计](#cn1)
- [重点问题:QSFP RX lane 反序](#cn2)
- [构建](#cn3)
- [运行](#cn4)
- [回环测试](#cn7)
- [目录结构](#cn5)
- [许可与致谢](#cn6)

　

# <span id="cn1">设计</span>

```
QSFP28 lane 1 <-> GTY quad 128 (25.78125 Gb/s, refclk 156.25 MHz) <-> eth_phy_10g (64b/66b) <-> eth_mac_10g
                         64 bit @ 390.625 MHz  <->  异步 FIFO  <->  128 bit @ 300 MHz (pl_clk0)
                                                     mqnic_core_axi  <->  S_AXI_HPC0  <->  PS DDR
```

| 文件 | 相对 Corundum ZCU102 工程的改动 |
|---|---|
| `rtl/fpga.v` | 100 MHz LVDS 时钟经 MMCM 生成 125 MHz;GTH 换成 GTY;25G PHY 参数;QSFP RX lane 交叉;同步数据通路加宽到 128 bit;去掉 ZCU102 的 LED、按键、拨码、DDR4 和 SFP tx_disable |
| `rtl/fpga_core.v` | 收发器寄存器块的类型从 GTHE4 改为 GTYE4 |
| `constraints/fpga.xdc` | RFSoC 4x2 引脚:QSFP28(GTY quad 128)、参考时钟、100 MHz 时钟、QSFP 边带信号 |
| `ip/eth_xcvr_gty.tcl` | GTY wizard:156.25 MHz 参考时钟(QPLL 分数分频)生成 25.78125 Gb/s,内部位宽 64 |
| `ip/zynq_ps.tcl` | RFSoC 4x2 的 PS block design(从实际可用的工程导出) |
| `scripts/config.tcl` | Corundum 配置,FPGA_ID 和 BOARD_ID 改为本板 |

| 项目 | 取值 |
|---|---|
| 接口 | 2 个接口 × 1 端口;eth0 = QSFP lane 1(已测),eth1 = QSFP lane 2(未测) |
| 链路 | 25GBASE-R,无 FEC,无自协商 |
| 寄存器空间 | `0xA000_0000`(控制)、`0xA800_0000`(应用),各 16 MB |
| 时钟 | 核心 300 MHz(pl_clk0),MAC/PHY 390.625 MHz,PTP 156.25 MHz |

# <span id="cn2">重点问题:QSFP RX lane 反序</span>

RFSoC 4x2 板上 QSFP 的 RX lane 相对 TX 是反的。板子能发不能收:对端接在 QSFP lane 1 时,
它的信号落在 GT 通道 3,而 eth0 在 GT 通道 0 上收。这个问题改 XDC 解决不了,因为 GT 通道的
TX 和 RX 引脚属于同一个 site;改为在 `fpga.v` 里把 RX 数据流交叉连接,TX 保持不动。
排查过程(`mqnic-dump`、用 `mqnic-xcvr` 扫眼图)详见 [docs/PORTING_NOTES.md](docs/PORTING_NOTES.md#cn)。

其余改动都是常规的:25G 相关设置(GTY、128 bit 同步数据通路、`COUNT_125US`、SERDES 流水、
GTYE4 寄存器块)与 Corundum 官方 Alveo 25G 工程相同;其他是板卡适配(100 MHz 时钟输入、引脚、
PS block design)。这些也都列在移植笔记里。

# <span id="cn3">构建</span>

Vivado 2020.2(不需要安装板卡文件):

```
git clone --recursive https://github.com/uceeyuf/rfsoc4x2_corundum.git
cd rfsoc4x2_corundum
vivado -mode batch -source scripts/build.tcl -tclargs 8
```

生成 `build/fpga.bit`、`build/rfsoc4x2_mqnic.xsa` 和 `build/timing_summary.rpt`。

# <span id="cn4">运行</span>

FPGA 端是 Corundum 标准的 AXI(非 PCIe)配置,所以软件也直接用 Corundum 的:

- **驱动:** 针对板上内核编译 `third_party/corundum/modules/mqnic`,加载 `mqnic.ko`。Xilinx 2020.2
  镜像的 5.4 内核需要 [`patches/0002`](patches/0002-mqnic-port-devlink-attrs-pre-5.9.patch) 才能编译;
  [`patches/0001`](patches/0001-mqnic-rx-drop-sync-after-unmap.patch) 删掉一次错误的逐包 DMA sync,
  接收的 CPU 开销降低 5-12%。驱动 `rmmod` 时会 oops,所以换驱动版本要重启后再加载。
- **设备树:** 寄存器映射和中断与 ZCU102 工程相同,
  `third_party/corundum/fpga/mqnic/ZCU102/fpga/ps/overlay.dtsi` 可直接使用。
- **比特流:** 把 `fpga.bit` 打进 BOOT.BIN 启动,或运行时通过 FPGA manager 加载。
- **对端:** 25G,关闭 FEC。FPGA 端没有 RS-FEC,也没有自协商。
- **中断:** 默认情况下 `mqnic0-*` 中断全部落在 CPU0,发送会被卡在约 1.25 Mpps。
  `scripts/test/board_setup.sh` 负责配置地址和 MTU,并把中断分到四个 CPU。

完整的上板和测试步骤(ping、iperf3、双向 pktgen、巨帧)见 [docs/TESTING.md](docs/TESTING.md#cn)。

Corundum 的 `utils/mqnic-dump` 和 `utils/mqnic-xcvr` 可以直接读取队列状态和收发器,
lane 反序就是靠它们查出来的,详见移植笔记。

# <span id="cn7">回环测试</span>

[`host/udp_loopback_viewer.py`](host/udp_loopback_viewer.py) 把 RGB24 测试视频发给板卡,板卡把每个包
原样发回,主机重组每一帧并与发出的原帧逐字节比对(包格式与
[rfsoc4x2_25g_udp](https://github.com/uceeyuf/rfsoc4x2_25g_udp) 的回环查看器相同)。板上有两种回送方式:

| 板卡侧 | 每方向 | 结果 |
|---|---|---|
| [`tools/udp_echo`](tools/udp_echo.c):用户态 socket 回送 | 5-6 Gbit/s | 4 个 A53 核跑满;4K25 500/500 帧 |
| [`tools/tc_reflect.sh`](tools/tc_reflect.sh):tc ingress 对调 MAC 与 IP 后原口发回 | **22.15 Gbit/s** | **4K120:1200/1200 帧逐字节正确,0 丢包** |

每方向 22.15 Gbit/s 时,经过网卡的总流量约 44.3 Gbit/s;9000 字节帧下,25GBASE-R 能承载的这类净荷
最多 24.8 Gbit/s。板卡收发了每一个包(tc 丢包 0)。原始结果见
[docs/results/loopback_2026-09-28.txt](docs/results/loopback_2026-09-28.txt)。

前提条件:

- **巨帧**:两端 MTU 9000;查看器用 `--payload 8956 --flows 16`。
- **带 BPF 与 tc 的内核**:镜像自带的内核两者都没有。[`kernel/build.sh`](kernel/build.sh) 用板卡自己的配置
  加上 [`kernel/bpf_tc.cfg`](kernel/bpf_tc.cfg),交叉编译同一版 Xilinx 2020.2 内核及配套的 mqnic。
- **主机接收能力**:socket 缓冲要大(`net.core.rmem_max`),重组内存要在开始前分配好(查看器已处理)。
  `rmem_max` 为 4 MB 时,20 Gbit/s 下主机丢了 0.45%,而所有包其实都到了主机网卡。
- **发送节奏**:每帧的包均匀分布在帧间隔内(`--spread`)。接近 25G 时,超过线速的突发偶尔会丢包
  (4K120 `--spread 0.9` 四次中有两次丢了 3-3.6%),这不是数据通路的固定上限。

```
# 板卡,root
scripts/test/board_setup.sh 192.168.100.1/24 9000
tools/tc_reflect.sh <主机 MAC> 192.168.100.2 1234 16        # 或:tools/udp_echo 1234 16
# 主机
sudo ip link set enp2s0np0 mtu 9000
sudo sysctl -w net.core.rmem_max=268435456
host/udp_loopback_viewer.py --flows 16 --res 3840x2160 --fps 120 --payload 8956 --spread 1.0 --cycle 20
```

`--cycle 20` 预先渲染 20 帧轮流发送,每一帧仍单独编号、单独比对(Python 渲染一帧 4K 要 14 ms)。
`--nogui` 在终端里运行。收发包、重组和比对在 C 里完成(`host/loopback_io.c`,首次运行时用 gcc 编译);
图形界面需要 PyGObject(GTK 3)和 Pillow。

重启后哪些设置还在:

| | 设置 | 是否持久 |
|---|---|---|
| 板卡:内核与启动 | BOOT 分区的 `Image` 为带 BPF/tc 的内核 `5.4.0-xilinx-v2020.2-bpf`,原内核保留为 `Image.orig`;模块在 `/lib/modules/5.4.0-xilinx-v2020.2-bpf` | 是。回退:把 `Image.orig` 改名回 `Image` |
| 板卡:运行时 | MTU 9000 与中断绑核(`board_setup.sh`)、tc 回送(`tc_reflect.sh`)、`udp_echo` | 否,每次开机后重设 |
| 主机:运行时 | 25G 网口 MTU 9000、`net.core.rmem_max` | 否,每次开机后重设 |

# <span id="cn5">目录结构</span>

```
rtl/          顶层和核心封装(来自 Corundum ZCU102 工程,有改动)
constraints/  RFSoC 4x2 引脚约束
ip/           GTY wizard 与 PS block design 脚本
scripts/      构建、建工程、Corundum 配置
scripts/test/ 板卡配置、pktgen 和 iperf3 脚本
host/         回环查看器(Python、GTK)及其 C 收发库
tools/        板上工具:udp_echo、tc_reflect.sh、rx_measure.sh
patches/      针对 Corundum 1ca0151 的 mqnic 驱动补丁
kernel/       BPF/tc 内核配置片段与构建脚本
docs/         移植笔记、测试步骤、测试报告、原始结果
third_party/  Corundum(submodule,固定版本)
```

# <span id="cn6">许可与致谢</span>

采用与 Corundum 相同的 BSD-2-Clause-Views 许可。Corundum 和 ZCU102 工程的版权归
The Regents of the University of California 和 MissingLinkElectronics 所有;本仓库的改动
版权为 Copyright (c) 2026, Yijie Yu。详见 [LICENSE](LICENSE)。

本工作建立在 Alex Forencich 及其贡献者的 [Corundum](https://github.com/corundum/corundum) 之上,
包括 `eth_phy_10g` PCS、MAC、DMA 引擎、`mqnic` 驱动,以及调试本次移植用到的诊断工具。
起点 ZCU102 工程来自 MissingLinkElectronics。引脚数据来自 RealDigital RFSoC 4x2 的板卡文件。
