# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2019-2023 The Regents of the University of California
# Copyright (c) 2026 Yijie Yu
#
# XDC constraints for the RealDigital RFSoC4x2 board
# Pin data from the RealDigital RFSoC 4x2 board files (QSFP28 on GTY quad 128).
# part: xczu48dr-ffvg1517-2-e

# General configuration
set_property BITSTREAM.GENERAL.COMPRESS true      [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP    [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN ENABLE [current_design]

# System clock
# 100 MHz LVDS PL clock (SYS_CLK_100M). Feed into an MMCM in fpga.v to generate the 125 MHz domain.
set_property -dict {LOC AM15 IOSTANDARD LVDS} [get_ports clk_100mhz_p]
set_property -dict {LOC AN15 IOSTANDARD LVDS} [get_ports clk_100mhz_n]
create_clock -period 10.000 -name clk_100mhz [get_ports clk_100mhz_p]

# QSFP28 Interface (GTY Quad 128)
# QSFP lane 1..4 -> corundum sfp0..3 (only _p/_n LOC, no IOSTANDARD for GT pins)
set_property -dict {LOC R38 } [get_ports sfp0_rx_p]         ;# QSFP_RX1_P
set_property -dict {LOC R39 } [get_ports sfp0_rx_n]         ;# QSFP_RX1_N
set_property -dict {LOC Y35 } [get_ports sfp0_tx_p]         ;# QSFP_TX1_P
set_property -dict {LOC Y36 } [get_ports sfp0_tx_n]         ;# QSFP_TX1_N
set_property -dict {LOC W38 } [get_ports sfp1_rx_p]         ;# QSFP_RX2_P
set_property -dict {LOC W39 } [get_ports sfp1_rx_n]         ;# QSFP_RX2_N
set_property -dict {LOC T35 } [get_ports sfp1_tx_p]         ;# QSFP_TX2_P
set_property -dict {LOC T36 } [get_ports sfp1_tx_n]         ;# QSFP_TX2_N
set_property -dict {LOC U38 } [get_ports sfp2_rx_p]         ;# QSFP_RX3_P
set_property -dict {LOC U39 } [get_ports sfp2_rx_n]         ;# QSFP_RX3_N
set_property -dict {LOC V35 } [get_ports sfp2_tx_p]         ;# QSFP_TX3_P
set_property -dict {LOC V36 } [get_ports sfp2_tx_n]         ;# QSFP_TX3_N
set_property -dict {LOC AA38} [get_ports sfp3_rx_p]         ;# QSFP_RX4_P
set_property -dict {LOC AA39} [get_ports sfp3_rx_n]         ;# QSFP_RX4_N
set_property -dict {LOC R33 } [get_ports sfp3_tx_p]         ;# QSFP_TX4_P
set_property -dict {LOC R34 } [get_ports sfp3_tx_n]         ;# QSFP_TX4_N

# 156.25 MHz MGT reference clock (GTY_128_REF_CLK_QSFP)
set_property -dict {LOC AA33} [get_ports sfp_mgt_refclk_0_p] ;# GTY_128_REF_CLK_QSFP_P
set_property -dict {LOC AA34} [get_ports sfp_mgt_refclk_0_n] ;# GTY_128_REF_CLK_QSFP_N
create_clock -period 6.400 -name sfp_mgt_refclk_0 [get_ports sfp_mgt_refclk_0_p]

# QSFP module sideband (LVCMOS18)
# NOTE: fpga.v currently has sfp0..3_tx_disable_b (ZCU102 SFP style) and NO qsfp module pins.
#       Add these ports to fpga.v (and drop the per-lane tx_disable_b) for these to take effect.
set_property -dict {LOC AL22 IOSTANDARD LVCMOS18} [get_ports qsfp0_modprsl] ;# MODULE PRESENT
set_property -dict {LOC AM22 IOSTANDARD LVCMOS18} [get_ports qsfp0_intl]    ;# MODULE INTERRUPT
set_property -dict {LOC AL21 IOSTANDARD LVCMOS18} [get_ports qsfp0_resetl]  ;# MODULE RESET
set_property -dict {LOC AN22 IOSTANDARD LVCMOS18} [get_ports qsfp0_lpmode]  ;# MODULE LOW POWER MODE
set_property -dict {LOC AK22 IOSTANDARD LVCMOS18} [get_ports qsfp0_modsell] ;# MODULE SELECT

set_false_path -to   [get_ports {qsfp0_resetl qsfp0_lpmode qsfp0_modsell}]
set_output_delay 0   [get_ports {qsfp0_resetl qsfp0_lpmode qsfp0_modsell}]
set_false_path -from [get_ports {qsfp0_modprsl qsfp0_intl}]
set_input_delay 0    [get_ports {qsfp0_modprsl qsfp0_intl}]

# =====================================================================
# LED / push button / DIP switch / DDR4 / sfp*_tx_disable_b were removed
# from fpga.v (not used on RFSoC4x2), so no constraints are needed here and
# no unconstrained-I/O DRC override is required.
# If you re-enable any of them later, add pins from the board files in
# C:\RFSoC4x2\4x2_PL_FULL_CONSTRAINTS\ (4x2_LED_PB__SW.xdc, 4x2_PL_DDR4.xdc).
# =====================================================================
