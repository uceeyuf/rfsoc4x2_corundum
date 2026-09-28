[English](#en) | [中文](#cn)

　

<span id="en">Porting notes: Corundum ZCU102 (10G, GTH) to RFSoC 4x2 (25G, GTY)</span>
===========================

Starting point: Corundum's `fpga/mqnic/ZCU102/fpga` target at commit `1ca0151`. Most changes
either follow Corundum's own 25G targets or adapt to the board. One problem is specific to the
RFSoC 4x2 and took real debugging: the QSFP RX lane order.

## Key problem: the QSFP RX lanes are reversed on the board

**Symptom.** The board transmitted: the peer received its ARP requests and answered them, and
the peer's link was up at 25G with no errors. The board received nothing: `rx_packets` stayed
0, the error, CRC and FIFO counters also stayed 0, and there were no RX interrupts.

**Cause.** `mqnic-dump` showed the DMA path working (TX descriptors fetched and completed,
completions and events written, interrupts delivered, RX rings full of buffers that were never
used), but the port's RX side never became ready and its recovered clock was not locked:

```
Port TX ctrl: 0x00010001   status (bit 16) = 1
Port RX ctrl: 0x00000001   status (bit 16) = 0, RX never ready
IF0 TX clk:   390.625 MHz
IF0 RX clk:   318.2 MHz    free-running: no signal on this channel's pins
```

An eye scan with `mqnic-xcvr` over all four channels of the quad, with the peer transmitting,
found an open eye on **GT channel 3** and nothing on channel 0. With the peer on QSFP lane 1, the
board transmits on GT channel 0 but the peer's signal comes back on GT channel 3: TX is routed
straight and RX is reversed.

**Fix.** It cannot be done in the XDC. A GT channel's TX and RX pins belong to one site, so
moving only `sfp0`'s RX pins to another channel's pins cannot be placed. Instead `rtl/fpga.v`
crosses the RX-side signals of the quad wrapper (clock, reset, XGMII data and control, block
lock, status, error count, PRBS enable) and leaves TX alone:

| Interface | TX from GT channel | RX from GT channel |
|---|---|---|
| eth0 (`sfp0`) | 0 | 3 (measured) |
| eth1 (`sfp1`) | 1 | 2 (inferred, not tested) |

This works because the TX and RX halves of a channel have independent clocks and resets; the MAC
only sees one TX clock domain and one RX clock domain. The pin constraints stay as the board files
give them.

## 25G settings from Corundum's own 25G targets

The ZCU102 target is 10G. For 25G, these settings are taken as they are in Corundum's Alveo
`fpga_25g` targets:

| Setting | ZCU102 (10G) | This port (25G), same as Alveo 25G |
|---|---|---|
| Transceiver | GTH, `GT_GTH(1)` | GTY, `GT_GTH(0)`, `GT_USP(1)` |
| Line rate | 10.3125 Gb/s | 25.78125 Gb/s, internal data width 64 |
| `AXIS_ETH_SYNC_DATA_WIDTH` | 64 bit | 128 bit (`AXIS_ETH_SYNC_DATA_WIDTH_DOUBLE`) |
| `COUNT_125US` | `125000/6.4` | `125000/2.56` |
| `TX_SERDES_PIPELINE`, `RX_SERDES_PIPELINE` | 0 | 1 |
| Transceiver register block `DRP_INFO` | `8'h02` (GTHE4) | `8'h03` (GTYE4) |

Why they matter at 25G: the MAC and PCS run 64 bit at 390.625 MHz instead of 156.25 MHz. A
64-bit sync datapath on the 300 MHz core clock carries only 19.2 Gbit/s, so without the 128-bit
setting frames above about 1 KB ran dry mid-frame and were lost. `COUNT_125US` is the RX
watchdog and BER monitor time base in PHY clock cycles, and the pipeline registers are what let
the 390.625 MHz domain meet timing. `mqnic-xcvr` uses `DRP_INFO` to choose the transceiver
register map.

The one difference from the Alveo script in `ip/eth_xcvr_gty.tcl`: the RFSoC 4x2 QSFP reference
clock is 156.25 MHz, not 161.1328125 MHz, so QPLL0 runs fractional-N (25781.25 / 2 / 156.25 =
82.5). The script creates `eth_xcvr_gty_full` (with the QPLL, for the first channel of the quad)
and `eth_xcvr_gty_channel` (the other three).

## Board differences

**Clocks.** The ZCU102 has a 125 MHz clock input; the RFSoC 4x2 has 100 MHz (`SYS_CLK_100M`,
LVDS on AM15/AN15). The MMCM runs its VCO at 1000 MHz (M = 10, D = 1) and divides by 8 for
125 MHz, with `CLKIN1_PERIOD = 10.0`. The 125 MHz must be exact: it is the transceiver's
free-running and DRP clock, and the GT wizard times its reset sequence from
`FREERUN_FREQUENCY = 125`.

| Clock | Source | Used for |
|---|---|---|
| 100 MHz | `SYS_CLK_100M`, LVDS on AM15/AN15 | MMCM input |
| 125 MHz | MMCM | transceiver free-running clock, DRP |
| 156.25 MHz | QSFP refclk, GTY quad 128 (AA33/AA34) | QPLL reference, PTP clock |
| 300 MHz | PS `pl_clk0` | Corundum core, AXI, DMA |
| 390.625 MHz | transceiver TX/RX user clocks | MAC and PCS |

**PS block design.** `ip/zynq_ps.tcl` is a `write_bd_tcl` export of the working RFSoC 4x2
project, replacing the ZCU102 PS settings (DDR, MIO, clocks). `pl_clk0` is 300 MHz, as Corundum
expects (`clk_300mhz`, `CLK_PERIOD_NS = 10/3`). The interface ports keep Corundum's names
(`m_axil_ctrl` at `0xA000_0000`, `m_axil_app_ctrl` at `0xA800_0000`, `s_axi_dma` on HPC0,
`pl_ps_irq0`), so `config.tcl` and the ZCU102 device tree overlay work unchanged.

**Pins.** `constraints/fpga.xdc` holds the 100 MHz clock, QSFP28 lanes 1-4 on GTY quad 128, the
QSFP refclk and the QSFP sideband pins.

**Removed ports.** The ZCU102 LEDs, buttons, switches, PL DDR4 and per-lane SFP `tx_disable`
outputs are gone from the top level. `fpga_core`'s LED and `tx_disable` outputs are left
unconnected and its button and switch inputs are tied to 0. The DDR4 controller branch in
`fpga.v` is commented out even though `DDR_ENABLE = 0`: with `` `default_nettype none ``,
Vivado 2020.2 still reports undeclared nets in the branch that is not taken.

**Identification.** `config.tcl` sets `FPGA_ID = 0x047FB093`, the XCZU48DR JTAG IDCODE from
Vivado's BSDL file. `BOARD_ID = 0x10ee:0x9042` is a placeholder, not an assigned ID.

　

　

<span id="cn">移植笔记:Corundum ZCU102(10G,GTH)→ RFSoC 4x2(25G,GTY)</span>
===========================

起点:Corundum 的 `fpga/mqnic/ZCU102/fpga` 工程,commit `1ca0151`。大部分改动要么是照 Corundum
自己的 25G 工程配置,要么是适配板卡。真正是 RFSoC 4x2 独有、花了功夫排查的问题只有一个:
QSFP 的 RX lane 顺序。

## 重点问题:板上 QSFP 的 RX lane 是反的

**现象。** 板子能发:对端收到了板子的 ARP 请求并回复,对端链路在 25G 上 up 且无错误。
板子收不到:`rx_packets` 一直是 0,错误、CRC、FIFO 计数也全是 0,没有任何 RX 中断。

**原因。** `mqnic-dump` 显示 DMA 通路是好的(TX 描述符被取走并完成,完成队列和事件正常写回,
中断正常送达,RX 环里填满了从没被用过的空缓冲区),但端口 RX 侧始终没有就绪,恢复时钟也没锁:

```
Port TX ctrl: 0x00010001   status (bit 16) = 1
Port RX ctrl: 0x00000001   status (bit 16) = 0,RX 从未就绪
IF0 TX clk:   390.625 MHz
IF0 RX clk:   318.2 MHz    自由振荡:这个通道的引脚上没有信号
```

在对端持续发送的情况下,用 `mqnic-xcvr` 对 quad 的四个通道做眼图扫描:**GT 通道 3** 眼图张开,
通道 0 什么都没有。也就是说,对端接在 QSFP lane 1 时,板子从 GT 通道 0 发(对端收得到),
但对端的信号回到的是 GT 通道 3:TX 是直连的,RX 是反的。

**修法。** 改 XDC 行不通。GT 通道的 TX 和 RX 引脚属于同一个 site,只把 `sfp0` 的 RX 引脚挪到
另一个通道的引脚上是布局不出来的。改为在 `rtl/fpga.v` 里把 quad wrapper 的 RX 侧信号交叉连接
(时钟、复位、XGMII 数据与控制、block lock、状态、错误计数、PRBS 使能),TX 侧不动:

| 接口 | TX 来自 GT 通道 | RX 来自 GT 通道 |
|---|---|---|
| eth0(`sfp0`) | 0 | 3(实测) |
| eth1(`sfp1`) | 1 | 2(推断,未测) |

这样做是合法的:一个通道的 TX 和 RX 两半各有独立的时钟和复位,MAC 看到的只是一个 TX 时钟域和一个
RX 时钟域。引脚约束保持和板卡文件一致。

## 按 Corundum 官方 25G 工程配置的参数

ZCU102 工程是 10G 的。升到 25G 时,下面这些设置直接照搬 Corundum Alveo `fpga_25g` 工程:

| 设置 | ZCU102(10G) | 本移植(25G),与 Alveo 25G 相同 |
|---|---|---|
| 收发器 | GTH,`GT_GTH(1)` | GTY,`GT_GTH(0)`、`GT_USP(1)` |
| 线速率 | 10.3125 Gb/s | 25.78125 Gb/s,内部位宽 64 |
| `AXIS_ETH_SYNC_DATA_WIDTH` | 64 bit | 128 bit(`AXIS_ETH_SYNC_DATA_WIDTH_DOUBLE`) |
| `COUNT_125US` | `125000/6.4` | `125000/2.56` |
| `TX_SERDES_PIPELINE`、`RX_SERDES_PIPELINE` | 0 | 1 |
| 收发器寄存器块 `DRP_INFO` | `8'h02`(GTHE4) | `8'h03`(GTYE4) |

这些设置在 25G 下为什么必要:MAC 和 PCS 以 64 bit 跑在 390.625 MHz,而不是 156.25 MHz。
300 MHz 核心时钟下 64 bit 的同步通路只有 19.2 Gbit/s,不改成 128 bit 的话,约 1 KB 以上的帧会在
中途断粮而丢失。`COUNT_125US` 是 RX 看门狗和 BER 监视器以 PHY 时钟周期计的时间基准;流水寄存器
让 390.625 MHz 时钟域能收敛时序。`mqnic-xcvr` 靠 `DRP_INFO` 选择收发器的寄存器映射。

`ip/eth_xcvr_gty.tcl` 与 Alveo 脚本唯一的区别:RFSoC 4x2 的 QSFP 参考时钟是 156.25 MHz,
不是 161.1328125 MHz,所以 QPLL0 工作在分数分频模式(25781.25 / 2 / 156.25 = 82.5)。
脚本生成 `eth_xcvr_gty_full`(带 QPLL,用于 quad 的第一个通道)和 `eth_xcvr_gty_channel`(其余三个)。

## 板卡差异

**时钟。** ZCU102 有 125 MHz 时钟输入,RFSoC 4x2 是 100 MHz(`SYS_CLK_100M`,LVDS,AM15/AN15)。
MMCM 的 VCO 跑在 1000 MHz(M = 10,D = 1),除以 8 得到 125 MHz,`CLKIN1_PERIOD = 10.0`。
125 MHz 必须准确:它是收发器的自由运行时钟和 DRP 时钟,GT wizard 按 `FREERUN_FREQUENCY = 125`
给复位时序计时。

| 时钟 | 来源 | 用途 |
|---|---|---|
| 100 MHz | `SYS_CLK_100M`,LVDS,AM15/AN15 | MMCM 输入 |
| 125 MHz | MMCM | 收发器自由运行时钟、DRP |
| 156.25 MHz | QSFP 参考时钟,GTY quad 128(AA33/AA34) | QPLL 参考、PTP 时钟 |
| 300 MHz | PS `pl_clk0` | Corundum 核心、AXI、DMA |
| 390.625 MHz | 收发器 TX/RX 用户时钟 | MAC 和 PCS |

**PS block design。** `ip/zynq_ps.tcl` 是从实际可用的 RFSoC 4x2 工程用 `write_bd_tcl` 导出的,
替换了 ZCU102 的 PS 设置(DDR、MIO、时钟)。`pl_clk0` 为 300 MHz,符合 Corundum 的要求
(`clk_300mhz`、`CLK_PERIOD_NS = 10/3`)。接口端口保留 Corundum 原来的名字(`m_axil_ctrl` 在
`0xA000_0000`,`m_axil_app_ctrl` 在 `0xA800_0000`,`s_axi_dma` 接 HPC0,`pl_ps_irq0`),
所以 `config.tcl` 和 ZCU102 的设备树 overlay 都不用改。

**引脚。** `constraints/fpga.xdc` 包含 100 MHz 时钟、GTY quad 128 上的 QSFP28 lane 1~4、
QSFP 参考时钟和 QSFP 边带信号。

**去掉的端口。** ZCU102 的 LED、按键、拨码、PL DDR4 和每路 SFP 的 `tx_disable` 输出都从顶层去掉了。
`fpga_core` 的 LED 和 `tx_disable` 输出悬空,按键和拨码输入接 0。即使 `DDR_ENABLE = 0`,`fpga.v`
里的 DDR4 控制器分支也要注释掉:在 `` `default_nettype none `` 下,Vivado 2020.2 仍会对未选中的
分支报未声明线网的错误。

**标识。** `config.tcl` 设 `FPGA_ID = 0x047FB093`,即 Vivado BSDL 文件里 XCZU48DR 的 JTAG IDCODE。
`BOARD_ID = 0x10ee:0x9042` 只是占位值,不是正式分配的 ID。
