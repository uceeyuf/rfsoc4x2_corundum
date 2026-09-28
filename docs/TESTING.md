[English](#en) | [中文](#cn)

　

<span id="en">Test procedure</span>
===========================

How the board was brought up and measured for the [test report](TEST_REPORT.md). The scripts are
in [`scripts/test/`](../scripts/test/).

## Setup

| | |
|---|---|
| Board | RFSoC 4x2, Ubuntu 22.04 on the PS, kernel `5.4.0-xilinx-v2020.2`, bitstream in BOOT.BIN |
| Driver | `mqnic.ko` installed in `/lib/modules/$(uname -r)/extra`, loaded at boot |
| Host | Linux PC with a Mellanox ConnectX-4 (`mlx5_core`), port `enp2s0np0` |
| Cable | 25G DAC from the host to the board's QSFP28 (lane 1 = `eth0`) |
| Console | the board's USB JTAG/UART: `/dev/ttyUSB1` on the host, 115200 8N1 |
| Addresses | board `192.168.100.1/24`, host `192.168.100.2/24` |

## 1. Console and driver

```
screen /dev/ttyUSB1 115200          # or: python3 -m serial.tools.miniterm /dev/ttyUSB1 115200
```

On the board:

```
lsmod | grep mqnic
dmesg | grep mqnic                  # ends with "Registered device mqnic0"
ip -br link                         # eth0 and eth1 appear, DOWN
mqnic-dump -d /dev/mqnic0 | grep -E "Board ID|Build date|Git hash"
```

If `mqnic` is not loaded, build it from `third_party/corundum/modules/mqnic` (needs the kernel
headers in `/lib/modules/$(uname -r)/build`) and `insmod` it. The driver gives `eth0` a random MAC
address on every load, so read it again before the host-side pktgen test.

## 2. Host link

```
sudo ip addr add 192.168.100.2/24 dev enp2s0np0
ethtool enp2s0np0 | grep -E "Speed|Link detected"      # 25000Mb/s, yes
ethtool --show-fec enp2s0np0                           # Active FEC encoding: Off
```

The FPGA has no RS-FEC and no auto-negotiation, so the host must end up at 25G with FEC off.
The link comes up before the board configures `eth0`; the host still receives nothing until
step 3.

## 3. Board interface

As root on the board:

```
scripts/test/board_setup.sh 192.168.100.1/24 1500
```

This sets the address and MTU, brings `eth0` up, and spreads the `mqnic0-*` interrupts over the
four CPUs. By default they all land on CPU0, which then does the TX completion work for every
queue and caps transmit at about 1.25 Mpps whatever the frame size or number of senders.
The setting does not survive a reboot or a driver reload.

## 4. ping

```
ping -c 10 192.168.100.1                               # from the host
```

## 5. iperf3

The board has no internet access, so iperf3 is installed from `.deb` files fetched by the host:

```
apt-get install --print-uris -y -qq iperf3             # on the board: lists the three .deb URLs
# on the host: download them, then serve the directory on the test link
python3 -m http.server 8000 --bind 192.168.100.2
# on the board: put them in apt's cache and install without downloading
cd /var/cache/apt/archives && wget http://192.168.100.2:8000/<file>.deb ...
apt-get install -y --no-download iperf3
```

On the host, four servers:

```
for p in 5201 5202 5203 5204; do iperf3 -s -p $p -B 192.168.100.2 & done
```

On the board:

```
iperf3 -c 192.168.100.2 -t 10                          # single stream, board -> host
iperf3 -c 192.168.100.2 -t 10 -R                       # single stream, host -> board
scripts/test/iperf_multi.sh 192.168.100.2              # 4 processes, board -> host
scripts/test/iperf_multi.sh 192.168.100.2 -R           # 4 processes, host -> board
```

iperf3 3.9 runs all streams of one process on one core, so `-P 4` does not add throughput on the
board. `iperf_multi.sh` starts one process per CPU instead.

## 6. Transmit at line rate (pktgen on the board)

TCP on the A53 cores is CPU-bound. The kernel packet generator (built into this kernel,
`CONFIG_NET_PKTGEN=y`) bypasses the stack and shows what the NIC itself can send:

```
# on the host: note the PHY counters
ethtool -S enp2s0np0 | grep -E "rx_packets_phy|rx_crc_errors_phy"
# on the board: 4 threads, 1514-byte frames, 3 million each, to the host's MAC
scripts/test/pktgen.sh eth0 <host MAC> 192.168.100.2 192.168.100.1 4 1514 3000000
# on the host: read the counters again; the difference is what arrived
```

`pktgen.sh` prints each thread's result. The rate is the total frame count divided by the
longest thread time; the host's `rx_packets_phy` difference confirms nothing was lost.

## 7. Receive (pktgen on the host)

```
# on the board: note the counter
cat /sys/class/net/eth0/statistics/rx_packets
# on the host, as root: 4 threads at line rate to the board's current eth0 MAC
sudo scripts/test/pktgen.sh enp2s0np0 <board MAC> 192.168.100.1 192.168.100.2 4 1514 3000000
# on the board: read the counter again
```

Frames the board cannot take are dropped in the FPGA when the receive queue has no free
descriptors, so the kernel's `rx_dropped` and `rx_missed_errors` stay at 0. The loss is the
difference between what the host sent and what `rx_packets` counted.

## 8. Jumbo frames

```
sudo ip link set enp2s0np0 mtu 9000                    # host
scripts/test/board_setup.sh 192.168.100.1/24 9000      # board
ping -M do -s 8972 192.168.100.1                       # host: full-size frame without fragmenting
```

Then repeat steps 5 and 7, with `9014` as the pktgen frame size.

## 9. Receive driver A/B

`tools/rx_measure.sh eth0 10` (root, on the board) samples receive rate, drops, per-CPU busy and
softirq time, mqnic interrupt rates, softnet counters and the interrupt affinity over 10 s while
the host sends. Four pktgen flows (`ports_per_thread` 1) land on two receive queues; 64 ports
per thread (`pktgen.sh ... 4 1514 8000000 64`) reach all four.

- Build the drivers on the host against the image's kernel: in a linux-xlnx `xilinx-v2020.2`
  tree with the board's `/proc/config.gz` as `.config`, run `make olddefconfig modules_prepare`
  and then `make M=<mqnic copy> modules` (the `make` variables are those in `kernel/build.sh`),
  once with `patches/0002` only (A) and once with `0001` + `0002` (B).
- `rmmod mqnic` oopses, so load one driver per boot: add `blacklist mqnic` to
  `/etc/modprobe.d/blacklist-mqnic.conf`, reboot, `insmod` the driver, check
  `/sys/module/mqnic/srcversion`, run `board_setup.sh` (the affinity is lost with the driver),
  then measure. Remove the blacklist afterwards. `insmod` does not read `/etc/modprobe.d`
  options, `modprobe` does.

## 10. Kernel with BPF and tc

The image's kernel has no BPF syscall and no traffic control, which `tools/tc_reflect.sh` needs.
On an x86 host (with `gcc-9-aarch64-linux-gnu flex bison bc libssl-dev`):

```
zcat /proc/config.gz > board.config                       # on the board; copy it to the host
kernel/build.sh board.config                              # on the host, a few minutes
```

This writes `kernel/out/Image.bpf` and `kernel/out/modules-bpf.tar.gz` (release
`5.4.0-xilinx-v2020.2-bpf`, with the patched `mqnic.ko` in `extra/`). On the board, as root:

```
tar -C /lib/modules -xzf modules-bpf.tar.gz && depmod -a 5.4.0-xilinx-v2020.2-bpf
mount /dev/mmcblk0p1 /mnt && cp Image.bpf /mnt/ && umount /mnt
```

Try it once from U-Boot (stop autoboot on the serial console):

```
fatload mmc 0:1 0x00200000 Image.bpf
fatload mmc 0:1 0x00100000 system.dtb
setenv bootargs 'earlycon console=ttyPS0,115200 clk_ignore_unused root=/dev/mmcblk0p2 rw rootwait'
booti 0x00200000 - 0x00100000
```

To make it the default, keep `boot.scr` and rename on the BOOT partition: `Image` to
`Image.orig`, `Image.bpf` to `Image`. To go back, rename `Image.orig` to `Image` (or load it
from U-Boot as above). The old modules in `/lib/modules/5.4.0-xilinx-v2020.2` stay untouched.

## 11. Loopback

On the board, as root, after `board_setup.sh 192.168.100.1/24 9000`, one of:

```
tools/tc_reflect.sh <host MAC> 192.168.100.2 1234 16     # kernel reflector (step 10's kernel)
gcc -O2 -pthread -o udp_echo tools/udp_echo.c && ./udp_echo 1234 16    # socket echo
```

On the host:

```
sudo ip link set enp2s0np0 mtu 9000
sudo sysctl -w net.core.rmem_max=268435456
host/udp_loopback_viewer.py --flows 16 --res 3840x2160 --fps 120 --payload 8956 --spread 1.0 --cycle 20
```

The viewer uses local port = remote port for each flow, which the tc reflector needs. For the
loss attribution compare the host's `rx_packets_phy` (`ethtool -S`) and UDP `RcvbufErrors`
(`/proc/net/snmp`) with the board's `rx_packets`, `tx_packets` and `tc -s filter show dev eth0
ingress`. `tools/tc_reflect.sh off` removes the reflector.

　

　

<span id="cn">测试步骤</span>
===========================

[测试报告](TEST_REPORT.md#cn)里的数据就是按下面的步骤测出来的。脚本在
[`scripts/test/`](../scripts/test/)。

## 环境

| | |
|---|---|
| 板卡 | RFSoC 4x2,PS 上跑 Ubuntu 22.04,内核 `5.4.0-xilinx-v2020.2`,比特流在 BOOT.BIN 里 |
| 驱动 | `mqnic.ko` 装在 `/lib/modules/$(uname -r)/extra`,开机自动加载 |
| 主机 | Linux PC,Mellanox ConnectX-4(`mlx5_core`),网口 `enp2s0np0` |
| 线缆 | 25G DAC,主机接板卡 QSFP28(lane 1 = `eth0`) |
| 串口 | 板卡的 USB JTAG/UART:主机上是 `/dev/ttyUSB1`,115200 8N1 |
| 地址 | 板卡 `192.168.100.1/24`,主机 `192.168.100.2/24` |

## 1. 串口和驱动

```
screen /dev/ttyUSB1 115200          # 或者: python3 -m serial.tools.miniterm /dev/ttyUSB1 115200
```

板卡上:

```
lsmod | grep mqnic
dmesg | grep mqnic                  # 最后一行是 "Registered device mqnic0"
ip -br link                         # 能看到 eth0 和 eth1,状态 DOWN
mqnic-dump -d /dev/mqnic0 | grep -E "Board ID|Build date|Git hash"
```

如果 `mqnic` 没有加载,就从 `third_party/corundum/modules/mqnic` 编译(需要
`/lib/modules/$(uname -r)/build` 下的内核头文件)再 `insmod`。驱动每次加载都会给 `eth0`
一个随机 MAC 地址,做主机侧 pktgen 测试前要重新读一次。

## 2. 主机链路

```
sudo ip addr add 192.168.100.2/24 dev enp2s0np0
ethtool enp2s0np0 | grep -E "Speed|Link detected"      # 25000Mb/s, yes
ethtool --show-fec enp2s0np0                           # Active FEC encoding: Off
```

FPGA 端没有 RS-FEC,也没有自协商,所以主机必须是 25G、FEC 关闭。板卡配置 `eth0` 之前链路就会
亮起来,但在第 3 步之前主机一个包也收不到。

## 3. 板卡网口

在板卡上以 root 执行:

```
scripts/test/board_setup.sh 192.168.100.1/24 1500
```

脚本会配置地址和 MTU、拉起 `eth0`,并把 `mqnic0-*` 中断分到四个 CPU 上。默认情况下这些中断
全部落在 CPU0,所有队列的 TX 完成处理都挤在这一个核上,发送被卡在约 1.25 Mpps,跟帧长和发送
线程数都无关。这个设置在重启或重新加载驱动后会失效。

## 4. ping

```
ping -c 10 192.168.100.1                               # 在主机上
```

## 5. iperf3

板卡不能上网,所以 iperf3 用主机下载的 `.deb` 安装:

```
apt-get install --print-uris -y -qq iperf3             # 板卡上: 列出需要的三个 .deb 地址
# 主机上: 下载这些文件,然后在测试链路上提供下载
python3 -m http.server 8000 --bind 192.168.100.2
# 板卡上: 放进 apt 缓存目录,不联网安装
cd /var/cache/apt/archives && wget http://192.168.100.2:8000/<file>.deb ...
apt-get install -y --no-download iperf3
```

主机上起四个服务端:

```
for p in 5201 5202 5203 5204; do iperf3 -s -p $p -B 192.168.100.2 & done
```

板卡上:

```
iperf3 -c 192.168.100.2 -t 10                          # 单流,板卡 -> 主机
iperf3 -c 192.168.100.2 -t 10 -R                       # 单流,主机 -> 板卡
scripts/test/iperf_multi.sh 192.168.100.2              # 4 个进程,板卡 -> 主机
scripts/test/iperf_multi.sh 192.168.100.2 -R           # 4 个进程,主机 -> 板卡
```

iperf3 3.9 一个进程的所有流都跑在同一个核上,所以在板卡上加 `-P 4` 不会提高吞吐。
`iperf_multi.sh` 改为每个 CPU 起一个进程。

## 6. 线速发送(板卡上跑 pktgen)

A53 上的 TCP 受 CPU 限制。内核自带的发包器(本内核已编入,`CONFIG_NET_PKTGEN=y`)绕过协议栈,
能测出网卡本身的发送能力:

```
# 主机上: 记下 PHY 计数
ethtool -S enp2s0np0 | grep -E "rx_packets_phy|rx_crc_errors_phy"
# 板卡上: 4 个线程,1514 字节帧,每个线程 300 万帧,发往主机的 MAC
scripts/test/pktgen.sh eth0 <主机 MAC> 192.168.100.2 192.168.100.1 4 1514 3000000
# 主机上: 再读一次计数,差值就是实际到达的帧数
```

`pktgen.sh` 会打印每个线程的结果。速率按总帧数除以最慢线程的用时计算;主机
`rx_packets_phy` 的差值用来确认没有丢包。

## 7. 接收(主机上跑 pktgen)

```
# 板卡上: 记下计数
cat /sys/class/net/eth0/statistics/rx_packets
# 主机上以 root 执行: 4 个线程,线速发往板卡当前的 eth0 MAC
sudo scripts/test/pktgen.sh enp2s0np0 <板卡 MAC> 192.168.100.1 192.168.100.2 4 1514 3000000
# 板卡上: 再读一次计数
```

板卡收不过来的帧,是在 FPGA 里因为接收队列没有空闲描述符被丢掉的,所以内核的 `rx_dropped` 和
`rx_missed_errors` 一直是 0。丢包数要用主机发出的帧数减去 `rx_packets` 的增量来算。

## 8. 巨帧

```
sudo ip link set enp2s0np0 mtu 9000                    # 主机
scripts/test/board_setup.sh 192.168.100.1/24 9000      # 板卡
ping -M do -s 8972 192.168.100.1                       # 主机: 发满长度且不分片的帧
```

然后重复第 5 步和第 7 步,pktgen 的帧长改为 `9014`。

## 9. 接收驱动 A/B

主机发包期间,在板卡上以 root 运行 `tools/rx_measure.sh eth0 10`,它在 10 秒内采样接收速率、丢包、
每个 CPU 的忙碌与软中断占比、mqnic 中断速率、softnet 计数以及中断绑核情况。pktgen 的 4 条流
(`ports_per_thread` 为 1)只落到 2 个接收队列;每线程 64 个端口(`pktgen.sh ... 4 1514 8000000 64`)
能用到全部 4 个。

- 在主机上针对镜像内核编译驱动:在 linux-xlnx `xilinx-v2020.2` 源码里用板卡的 `/proc/config.gz`
  作为 `.config`,执行 `make olddefconfig modules_prepare`,再 `make M=<mqnic 副本> modules`
  (`make` 的变量与 `kernel/build.sh` 相同);只打 `patches/0002` 为 A,打 `0001` + `0002` 为 B。
- `rmmod mqnic` 会 oops,所以每次开机只加载一种驱动:在 `/etc/modprobe.d/blacklist-mqnic.conf` 写入
  `blacklist mqnic`,重启,`insmod` 驱动,核对 `/sys/module/mqnic/srcversion`,运行 `board_setup.sh`
  (换驱动后绑核会丢失),然后测量。测完删除 blacklist。`insmod` 不读取 `/etc/modprobe.d` 里的参数,
  `modprobe` 会读取。

## 10. 带 BPF 与 tc 的内核

镜像内核没有 BPF 系统调用,也没有流量控制,而 `tools/tc_reflect.sh` 需要它们。在 x86 主机上
(需要 `gcc-9-aarch64-linux-gnu flex bison bc libssl-dev`):

```
zcat /proc/config.gz > board.config                       # 在板卡上执行,再拷到主机
kernel/build.sh board.config                              # 在主机上执行,几分钟
```

生成 `kernel/out/Image.bpf` 和 `kernel/out/modules-bpf.tar.gz`(版本 `5.4.0-xilinx-v2020.2-bpf`,
打过补丁的 `mqnic.ko` 在 `extra/` 下)。在板卡上以 root 执行:

```
tar -C /lib/modules -xzf modules-bpf.tar.gz && depmod -a 5.4.0-xilinx-v2020.2-bpf
mount /dev/mmcblk0p1 /mnt && cp Image.bpf /mnt/ && umount /mnt
```

先从 U-Boot 试启动一次(在串口上打断自动启动):

```
fatload mmc 0:1 0x00200000 Image.bpf
fatload mmc 0:1 0x00100000 system.dtb
setenv bootargs 'earlycon console=ttyPS0,115200 clk_ignore_unused root=/dev/mmcblk0p2 rw rootwait'
booti 0x00200000 - 0x00100000
```

要设为默认启动,`boot.scr` 不动,在 BOOT 分区上改名:`Image` 改为 `Image.orig`,`Image.bpf` 改为
`Image`。回退时把 `Image.orig` 改回 `Image`(或按上面的方法在 U-Boot 里加载它)。原来的模块目录
`/lib/modules/5.4.0-xilinx-v2020.2` 保持不变。

## 11. 回环测试

在板卡上以 root 先运行 `board_setup.sh 192.168.100.1/24 9000`,再选其一:

```
tools/tc_reflect.sh <主机 MAC> 192.168.100.2 1234 16     # 内核回送(第 10 步的内核)
gcc -O2 -pthread -o udp_echo tools/udp_echo.c && ./udp_echo 1234 16    # socket 回送
```

在主机上:

```
sudo ip link set enp2s0np0 mtu 9000
sudo sysctl -w net.core.rmem_max=268435456
host/udp_loopback_viewer.py --flows 16 --res 3840x2160 --fps 120 --payload 8956 --spread 1.0 --cycle 20
```

查看器每条流的本地端口与目标端口相同,这是 tc 回送所需要的。定位丢包时,把主机的 `rx_packets_phy`
(`ethtool -S`)和 UDP `RcvbufErrors`(`/proc/net/snmp`)与板卡的 `rx_packets`、`tx_packets` 以及
`tc -s filter show dev eth0 ingress` 对比。`tools/tc_reflect.sh off` 可以移除回送。
