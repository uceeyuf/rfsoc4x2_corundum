[English](#en) | [中文](#cn)

　

<span id="en">Test report</span>
===========================

## Setup

| | |
|---|---|
| Board | RealDigital RFSoC 4x2 (XCZU48DR-FFVG1517-2-E), Linux on the PS, Corundum `mqnic` driver |
| Link | QSFP28 lane 1 (eth0), 25GBASE-R, FEC off, no auto-negotiation |
| Peer | Linux host with a Mellanox 25G NIC, 25G, FEC off |
| Addresses | board 192.168.100.1, host 192.168.100.2 |
| Bitstream | built 2026-07-05 from the same sources as this repository |

## Results, 2026-07-05

Board to host, raw output in [results/ping_iperf.txt](results/ping_iperf.txt). The MTU was not
recorded.

| Test | Result |
|---|---|
| ping, 10 packets | 0% loss, rtt 0.134 / 0.212 / 0.257 ms (min / avg / max) |
| iperf3 TCP, 1 stream, 5 s | **9.15 Gbit/s**, 39 retransmissions |
| iperf3 UDP, 10 Gbit/s offered, 5 s | 6.46 Gbit/s received, 35% of datagrams lost |

Without the RX lane crossing described in [PORTING_NOTES.md](PORTING_NOTES.md), the same setup
received nothing at all. Without the 128-bit sync datapath used by Corundum's 25G targets, frames
above about 1 KB were lost. With both, full-size frames pass and single-stream TCP runs at
9 Gbit/s with few retransmissions.

The UDP loss has not been investigated yet. The sender reports no loss, so the datagrams are
dropped either on their way out of the board (driver or transmit ring) or in the receiving
host's stack.

## Retest, 2026-09-28

Procedure in [TESTING.md](TESTING.md), raw output in
[results/retest_2026-09-28.txt](results/retest_2026-09-28.txt). Same board, same host (ConnectX-4,
25G, FEC off). The bitstream on the board reports Corundum git hash `1ca0151b` and build date
2026-06-14 00:18:47 UTC (`mqnic-dump`), not the 2026-07-05 build above; 1514-byte and 9014-byte
frames pass in both directions with it. pktgen rates are the total frame count over the longest
thread time, checked against the receiver's counters.

### Transmit reaches line rate

| Board to host, pktgen | mqnic interrupts on CPU0 (default) | interrupts spread over 4 CPUs |
|---|---|---|
| 1514 B, 4 threads | 1.08 Mpps, 13.1 Gbit/s | **2.018 Mpps, 24.83 Gbit/s on the wire (99.3% of 25G)** |
| 1514 B, 1 thread | 1.15 Mpps, 13.9 Gbit/s | 1.15 Mpps, 14.0 Gbit/s |
| 512 B, 4 threads | 1.22 Mpps, 5.0 Gbit/s | |
| 60 B, 4 threads | 1.26 Mpps | 4.74 Mpps |

Every frame arrived, with no CRC errors on the host. By default all `mqnic0-*` interrupts are
served by CPU0, so the TX completions of every queue are processed on that one core, and the
transmit rate stops at about 1.25 Mpps whatever the frame size and the number of sending threads.
Spreading the interrupts over the four CPUs (`scripts/test/board_setup.sh`) removes that limit.

### Receive is limited by the board's CPUs

| Host to board, pktgen at line rate | Received by the board |
|---|---|
| 1514 B, 2.03 Mpps offered | 15.9%: 0.32 Mpps, 3.9 Gbit/s |
| 9014 B, 0.346 Mpps offered | 58.3%: 0.202 Mpps, **14.56 Gbit/s** |

The rest is dropped in the FPGA when the receive queues have no free descriptors, so the
kernel's drop counters stay at 0. The four flows of this test (one UDP source port per pktgen
thread) hash to only two of the four receive queues: CPU2 and CPU3 ran at 100 % softirq, each
handling about 160 000 frames/s at 1514 bytes, while CPU0 and CPU1 idled. This was measured in
the [RX driver A/B test](#en-ab) below; an earlier version of this report assumed four CPUs at
80 000 frames/s. The device-tree node has no `dma-coherent` property, so every buffer needs
cache maintenance, and the A/B test found one of those per-packet operations to be wrong.

### TCP

| iperf3, interrupts spread | MTU 1500 | MTU 9000 |
|---|---|---|
| 1 stream, board to host | 5.19 Gbit/s | 10.9 Gbit/s |
| 1 stream, host to board | 2.34 Gbit/s | 5.92 Gbit/s |
| 4 processes, board to host | 9.79 Gbit/s | **19.55 Gbit/s** |
| 4 processes, host to board | 5.25 Gbit/s | 11.78 Gbit/s |

With the interrupts on CPU0 a single stream at MTU 1500 ran at 2.93 Gbit/s, with the sending
core at 98% (almost all in the kernel). The 9.15 Gbit/s single stream of the first test was not
reached at MTU 1500; a single stream above 9 Gbit/s was only seen at MTU 9000. The UDP test at
MTU 1500 offered 10 Gbit/s but iperf3 on the board sent only 953 Mbit/s, all of which arrived.

### Next steps

- Make the HPC0 path cache-coherent (coherent AXI transactions from the FPGA and
  `dma-coherent` in the device tree) to remove per-buffer cache maintenance on receive.
- DPDK: the existing Corundum PMD (MissingLinkElectronics, `dpdk-stable` 20.11-22.11) binds
  only to PCIe devices and targets an older Corundum register layout; it would need a platform
  bus binding and the `1ca0151` queue layout to run here.
- Replace the reflector with a data source in the PL (for example RFDC samples through a FIFO
  and a packetizer into mqnic) to carry acquisition data over the same 22 Gbit/s path.

## <span id="en-ab">RX driver A/B, 2026-09-28</span>

Raw output in [results/rx_ab_2026-09-28.txt](results/rx_ab_2026-09-28.txt), patches in
[../patches](../patches). The driver oopses on `rmmod` (NULL pointer in
`mqnic_common_remove`), so each driver was loaded in its own boot:

| | Driver | srcversion |
|---|---|---|
| A0 | the image's own `mqnic.ko` | `D64E6CCD58AB04BEF0476DA` |
| A | Corundum `1ca0151` + `patches/0002` (5.4 build fix), cross-compiled with gcc 9.5 against linux-xlnx `xilinx-v2020.2` and the board's `/proc/config.gz` | `FA31C0F39896E6167CD0BD4` |
| B | A + `patches/0001` (drops `dma_sync_single_range_for_cpu()` after `dma_unmap_page()`) | `8FC1798FD4A307D0B3E328F` |

The host sent at line rate with `scripts/test/pktgen.sh` (4 threads, 4 flows on 2 receive queues
or 256 flows on all 4), and `tools/rx_measure.sh` sampled the board for 10 s. The main measure
is CPU time per received frame (busy CPUs / frame rate), which does not depend on how busy
the CPUs happened to be. Two rounds each:

| CPU time per frame | A | B | |
|---|---|---|---|
| 1514 B, 4 flows | 6.16 / 6.15 µs | 5.84 / 5.86 µs | -5 % |
| 1514 B, 256 flows | 6.10 / 6.16 µs | 5.81 / 5.81 µs | -5 % |
| 9014 B, 4 flows | 9.69 / 9.68 µs | 8.60 / 8.64 µs | -11 % |
| 9014 B, 256 flows | 8.61 µs (other round an outlier) | 7.50 / 7.69 µs | -12 % |

With 4 flows the two receiving CPUs are saturated, so throughput follows: 3.94 to 4.15 Gbit/s
at 1514 B and 14.90 to 16.76 Gbit/s at 9014 B. With 256 flows and 9014 B, B received up to
20.5 Gbit/s. A0 and A differ by less than 1 %, so the host-built driver stands in for the
image's.

- The saving grows with frame size (0.31 µs at 1514 B, 1.06 µs at 9014 B): the removed call is
  cache maintenance line by line.
- The removed call passes the DMA handle that was cleared on the line before, i.e. address 0.
  Without an IOMMU that is physical address 0, so it invalidates the cache lines of whatever
  memory lives there: potentially a corruption, not only lost time. This follows from the code
  path; it was not observed.
- At 256 flows and 9014 B the CPUs were about 55 % busy and frames were still dropped
  (`time_squeeze` counts in softnet): arrivals are bursty. This is not a fixed hardware ceiling,
  since B received more at the same CPU load.

## Loopback benchmark, 2026-09-28

Raw output in [results/loopback_2026-09-28.txt](results/loopback_2026-09-28.txt).
`host/udp_loopback_viewer.py` sends RGB24 test video, the board sends every packet back, and
the host compares every frame byte by byte. MTU 9000, 16 flows, 8956 bytes of video per packet,
driver B.

| Board side | Kernel | Result |
|---|---|---|
| `tools/udp_echo`, socket echo | image kernel | 4K25 (4.99 Gbit/s each way): 500/500 frames; 4K30 (6 Gbit/s): 0.0002-4 % loss from run to run |
| `tools/tc_reflect.sh`, tc ingress reflector | `5.4.0-xilinx-v2020.2-bpf` ([../kernel](../kernel)) | 4K60 (11.66 Gbit/s): 600/600; 4K110 (21.93 Gbit/s): 1100/1100; **4K120 (22.15 Gbit/s): 1200/1200, 0 packets lost** |

- **Socket echo** is limited by the board: at 4K30 all four A53 cores were 90-100 % busy
  (`udp_echo` 272 % CPU, 59 % system, 35 % softirq). Moving each echo thread to the CPU that
  receives its flow (`SO_INCOMING_CPU`), the largest datagrams, UDP GRO/GSO and sending 8
  packets per flow in a row raised it from 5.3 to about 6 Gbit/s.
- **The tc reflector** keeps packets in the receive softirq: no socket, no copy, and the
  checksums stay valid because only addresses are swapped. The image's kernel has neither BPF
  nor tc, so `kernel/build.sh` builds the same Xilinx 2020.2 kernel with `kernel/bpf_tc.cfg`;
  its boot log shows no warning that the image kernel does not.
- **Where packets were lost** at 20 Gbit/s with the host's default 4 MB `rmem_max`: the board
  received and sent all 2 779 017 packets (tc dropped 0), the host NIC received all of them, and
  the 15 201 missing ones equal the host's UDP `RcvbufErrors`. With `rmem_max` at 256 MB and the
  viewer's reassembly memory allocated before the run, nothing was lost.
- **Pacing:** at 4K120 the frames are spread over the frame interval. With `--spread 0.9` the
  sender bursts above line rate; two of four such runs lost 3.0-3.6 % before the host NIC, the
  other two lost nothing. With `--spread 1.0` nothing was lost.

## Timing

A clean build from this repository (`scripts/build.tcl`, Vivado 2020.2) meets timing:

| | WNS | TNS | WHS | THS |
|---|---|---|---|---|
| All clocks | +0.051 ns | 0 | +0.010 ns | 0 |

Report: [results/timing_summary.rpt](results/timing_summary.rpt) (summary sections).

The PS initialisation (`psu_init.c`) in the XSA from this clean build is identical to the one in
the bitstream that was tested on the board, so the exported block design reproduces the tested
PS configuration.

　

　

<span id="cn">测试报告</span>
===========================

## 测试环境

| | |
|---|---|
| 板卡 | RealDigital RFSoC 4x2(XCZU48DR-FFVG1517-2-E),PS 上跑 Linux,Corundum `mqnic` 驱动 |
| 链路 | QSFP28 lane 1(eth0),25GBASE-R,关闭 FEC,无自协商 |
| 对端 | 装有 Mellanox 25G 网卡的 Linux 主机,25G,关闭 FEC |
| 地址 | 板卡 192.168.100.1,主机 192.168.100.2 |
| 比特流 | 2026-07-05 用与本仓库相同的源码构建 |

## 结果(2026-07-05)

方向为板卡到主机,原始输出见 [results/ping_iperf.txt](results/ping_iperf.txt)。当时没有记录 MTU。

| 测试 | 结果 |
|---|---|
| ping,10 个包 | 0% 丢包,rtt 0.134 / 0.212 / 0.257 ms(最小 / 平均 / 最大) |
| iperf3 TCP,单流,5 秒 | **9.15 Gbit/s**,重传 39 次 |
| iperf3 UDP,发送 10 Gbit/s,5 秒 | 接收 6.46 Gbit/s,丢失 35% 的数据报 |

没有 [PORTING_NOTES.md](PORTING_NOTES.md#cn) 所述的 RX lane 交叉时,同样的环境一个包都收不到;
没有 Corundum 25G 工程所用的 128 bit 同步数据通路时,约 1 KB 以上的帧会丢失。两者都有之后,
满长度帧可以正常通过,单流 TCP 跑到 9 Gbit/s,重传很少。

UDP 丢包还没有排查。发送端报告无丢失,所以数据报要么丢在板卡发出的路上(驱动或发送环),
要么丢在接收主机的协议栈里。

## 复测(2026-09-28)

步骤见 [TESTING.md](TESTING.md#cn),原始输出见
[results/retest_2026-09-28.txt](results/retest_2026-09-28.txt)。板卡和主机与上面相同(ConnectX-4,
25G,关闭 FEC)。板上比特流通过 `mqnic-dump` 读到的 Corundum git hash 是 `1ca0151b`,构建时间是
2026-06-14 00:18:47 UTC,不是上面 2026-07-05 那一版;用这版比特流,1514 字节和 9014 字节的帧
双向都能正常通过。pktgen 的速率按总帧数除以最慢线程的用时计算,并用接收端计数核对。

### 发送达到线速

| 板卡到主机,pktgen | mqnic 中断全在 CPU0(默认) | 中断分到 4 个 CPU |
|---|---|---|
| 1514 B,4 线程 | 1.08 Mpps,13.1 Gbit/s | **2.018 Mpps,线路速率 24.83 Gbit/s(25G 的 99.3%)** |
| 1514 B,1 线程 | 1.15 Mpps,13.9 Gbit/s | 1.15 Mpps,14.0 Gbit/s |
| 512 B,4 线程 | 1.22 Mpps,5.0 Gbit/s | |
| 60 B,4 线程 | 1.26 Mpps | 4.74 Mpps |

所有帧都收到了,主机侧没有 CRC 错误。默认情况下 `mqnic0-*` 中断全部由 CPU0 处理,所有队列的
TX 完成都挤在这一个核上,发送速率停在约 1.25 Mpps,跟帧长和发送线程数都无关。把中断分到四个
CPU(`scripts/test/board_setup.sh`)后,这个限制就没有了。

### 接收受板卡 CPU 限制

| 主机线速发往板卡,pktgen | 板卡收到 |
|---|---|
| 1514 B,发送 2.03 Mpps | 15.9%:0.32 Mpps,3.9 Gbit/s |
| 9014 B,发送 0.346 Mpps | 58.3%:0.202 Mpps,**14.56 Gbit/s** |

其余的帧在 FPGA 里因为接收队列没有空闲描述符被丢掉,所以内核的丢包计数一直是 0。这次测试的
4 条流(每个 pktgen 线程一个 UDP 源端口)经哈希只落到 4 个接收队列中的 2 个上:CPU2 和 CPU3 的
软中断占满 100%,每核每秒处理约 16 万个 1514 字节的帧,CPU0 和 CPU1 基本空闲。这是在下面的
[接收驱动 A/B 测试](#cn-ab)里测到的;本报告的早先版本误以为是 4 个核、每核 8 万帧。设备树节点没有
`dma-coherent` 属性,每个缓冲区都要做 cache 维护,A/B 测试发现其中一次逐包操作本身就是错的。

### TCP

| iperf3,中断已分散 | MTU 1500 | MTU 9000 |
|---|---|---|
| 单流,板卡到主机 | 5.19 Gbit/s | 10.9 Gbit/s |
| 单流,主机到板卡 | 2.34 Gbit/s | 5.92 Gbit/s |
| 4 进程,板卡到主机 | 9.79 Gbit/s | **19.55 Gbit/s** |
| 4 进程,主机到板卡 | 5.25 Gbit/s | 11.78 Gbit/s |

中断全在 CPU0 时,MTU 1500 单流只有 2.93 Gbit/s,发送核占用 98%(几乎全在内核态)。第一次测试
的单流 9.15 Gbit/s 在 MTU 1500 下没有复现;单流超过 9 Gbit/s 只在 MTU 9000 下出现过。MTU 1500
的 UDP 测试设定 10 Gbit/s,但板卡上的 iperf3 只发出了 953 Mbit/s,全部收到。

### 下一步

- 让 HPC0 通路 cache 一致(FPGA 发出一致性 AXI 事务,设备树加 `dma-coherent`),去掉接收时
  每个缓冲区的 cache 维护。
- DPDK:现有的 Corundum PMD(MissingLinkElectronics,`dpdk-stable` 20.11 到 22.11)只绑定
  PCIe 设备,对应的是较早的 Corundum 寄存器布局;要在这里使用,需要增加平台总线绑定,并适配
  `1ca0151` 的队列布局。
- 把回送换成 PL 里的数据源(例如 RFDC 采样经 FIFO 和打包模块送入 mqnic),用同一条 22 Gbit/s
  通路传输采集数据。

## <span id="cn-ab">接收驱动 A/B 测试(2026-09-28)</span>

原始输出见 [results/rx_ab_2026-09-28.txt](results/rx_ab_2026-09-28.txt),补丁在 [../patches](../patches)。
驱动 `rmmod` 时会 oops(`mqnic_common_remove` 里的空指针),所以每种驱动都在单独一次开机里加载:

| | 驱动 | srcversion |
|---|---|---|
| A0 | 镜像自带的 `mqnic.ko` | `D64E6CCD58AB04BEF0476DA` |
| A | Corundum `1ca0151` + `patches/0002`(5.4 编译修正),用 gcc 9.5 针对 linux-xlnx `xilinx-v2020.2` 和板卡的 `/proc/config.gz` 交叉编译 | `FA31C0F39896E6167CD0BD4` |
| B | A + `patches/0001`(删掉 `dma_unmap_page()` 之后的 `dma_sync_single_range_for_cpu()`) | `8FC1798FD4A307D0B3E328F` |

主机用 `scripts/test/pktgen.sh` 线速发送(4 个线程;4 条流只用到 2 个接收队列,256 条流用到全部 4 个),
板上用 `tools/rx_measure.sh` 采样 10 秒。主要指标是每收一帧的 CPU 时间(忙碌的 CPU 数 ÷ 帧率),
它不受 CPU 当时有多忙的影响。每项测两轮:

| 每帧 CPU 时间 | A | B | |
|---|---|---|---|
| 1514 B,4 条流 | 6.16 / 6.15 µs | 5.84 / 5.86 µs | -5% |
| 1514 B,256 条流 | 6.10 / 6.16 µs | 5.81 / 5.81 µs | -5% |
| 9014 B,4 条流 | 9.69 / 9.68 µs | 8.60 / 8.64 µs | -11% |
| 9014 B,256 条流 | 8.61 µs(另一轮为异常值) | 7.50 / 7.69 µs | -12% |

4 条流时两个接收核是满载的,所以吞吐随之提高:1514 B 从 3.94 到 4.15 Gbit/s,9014 B 从 14.90 到
16.76 Gbit/s。256 条流、9014 B 时 B 最高收到 20.5 Gbit/s。A0 与 A 相差不到 1%,所以主机编译的驱动
可以代表镜像自带的驱动。

- 省下的时间随帧长增加(1514 B 省 0.31 µs,9014 B 省 1.06 µs):被删掉的调用是逐 cache line 的维护操作。
- 被删掉的调用用的 DMA 地址在上一行刚被清零,也就是地址 0。没有 IOMMU 时这就是物理地址 0,它会让那里
  不管是什么内存的 cache line 失效:可能造成内存损坏,不只是浪费时间。这是从代码路径推出来的,没有实际观察到。
- 256 条流、9014 B 时 CPU 只忙了约 55%,仍然有丢帧(softnet 里有 `time_squeeze` 计数):到达是突发的。
  这不是固定的硬件上限,因为 B 在同样的 CPU 负载下收到了更多。

## 回环测试(2026-09-28)

原始输出见 [results/loopback_2026-09-28.txt](results/loopback_2026-09-28.txt)。`host/udp_loopback_viewer.py`
发送 RGB24 测试视频,板卡把每个包发回,主机逐帧逐字节比对。MTU 9000,16 条流,每包 8956 字节视频数据,
驱动 B。

| 板卡侧 | 内核 | 结果 |
|---|---|---|
| `tools/udp_echo`,socket 回送 | 镜像内核 | 4K25(每方向 4.99 Gbit/s):500/500 帧;4K30(6 Gbit/s):每轮丢包 0.0002-4% 不等 |
| `tools/tc_reflect.sh`,tc ingress 回送 | `5.4.0-xilinx-v2020.2-bpf`([../kernel](../kernel)) | 4K60(11.66 Gbit/s):600/600;4K110(21.93 Gbit/s):1100/1100;**4K120(22.15 Gbit/s):1200/1200,0 丢包** |

- **socket 回送**受板卡限制:4K30 时 4 个 A53 核都忙到 90-100%(`udp_echo` 占 272% CPU,系统态 59%,
  软中断 35%)。把回送线程移到接收该流的 CPU 上(`SO_INCOMING_CPU`)、用最大的数据报、UDP GRO/GSO、
  每条流连续发 8 个包,把它从 5.3 提到约 6 Gbit/s。
- **tc 回送**让包留在接收软中断里:不经过 socket,不拷贝;只对调地址,所以校验和仍然正确。镜像内核既没有
  BPF 也没有 tc,所以用 `kernel/build.sh` 带上 `kernel/bpf_tc.cfg` 编译同一版 Xilinx 2020.2 内核;它的启动
  日志里没有任何镜像内核没有的警告。
- **包丢在哪里**(20 Gbit/s,主机默认 `rmem_max` 4 MB):板卡收发了全部 2 779 017 个包(tc 丢包 0),主机
  网卡也全部收到,缺少的 15 201 个正好等于主机 UDP 的 `RcvbufErrors`。`rmem_max` 调到 256 MB、查看器在
  开始前分配好重组内存之后,一个包也没丢。
- **发送节奏**:4K120 时每帧的包分散在帧间隔内。`--spread 0.9` 会出现超过线速的突发,四次中有两次在主机
  网卡之前丢了 3.0-3.6%,另外两次没有丢包。`--spread 1.0` 时没有丢包。

## 时序

从本仓库干净构建(`scripts/build.tcl`,Vivado 2020.2)时序收敛:

| | WNS | TNS | WHS | THS |
|---|---|---|---|---|
| 全部时钟 | +0.051 ns | 0 | +0.010 ns | 0 |

报告:[results/timing_summary.rpt](results/timing_summary.rpt)(汇总部分)。

这次干净构建得到的 XSA 里,PS 初始化代码(`psu_init.c`)与上板测试那版比特流完全一致,
说明导出的 block design 复现了测试时的 PS 配置。
