# SPDX-License-Identifier: BSD-2-Clause-Views
# Creates the Vivado project in the current directory. Called by scripts/build.tcl.
# Only rtl/, constraints/, ip/ and scripts/ are specific to this port; every other
# source comes unmodified from Corundum (third_party/corundum, pinned submodule).

set repo [file normalize [file join [file dirname [info script]] ..]]
set cor  $repo/third_party/corundum

create_project -force -part xczu48dr-ffvg1517-2-e fpga

close [open defines.v w]
add_files -fileset sources_1 [list defines.v \
    $cor/fpga/lib/axi/rtl/arbiter.v \
    $cor/fpga/lib/axi/rtl/axil_crossbar.v \
    $cor/fpga/lib/axi/rtl/axil_crossbar_addr.v \
    $cor/fpga/lib/axi/rtl/axil_crossbar_rd.v \
    $cor/fpga/lib/axi/rtl/axil_crossbar_wr.v \
    $cor/fpga/lib/axi/rtl/axil_interconnect.v \
    $cor/fpga/lib/axi/rtl/axil_reg_if.v \
    $cor/fpga/lib/axi/rtl/axil_reg_if_rd.v \
    $cor/fpga/lib/axi/rtl/axil_reg_if_wr.v \
    $cor/fpga/lib/axi/rtl/axil_register_rd.v \
    $cor/fpga/lib/axi/rtl/axil_register_wr.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_adapter.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_arb_mux.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_async_fifo.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_async_fifo_adapter.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_demux.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_fifo.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_fifo_adapter.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_pipeline_fifo.v \
    $cor/fpga/lib/eth/rtl/axis_xgmii_rx_64.v \
    $cor/fpga/lib/eth/rtl/axis_xgmii_tx_64.v \
    $cor/fpga/common/rtl/cpl_op_mux.v \
    $cor/fpga/common/rtl/cpl_queue_manager.v \
    $cor/fpga/common/rtl/cpl_write.v \
    $cor/fpga/mqnic/ZCU102/fpga/rtl/debounce_switch.v \
    $cor/fpga/common/rtl/desc_fetch.v \
    $cor/fpga/common/rtl/desc_op_mux.v \
    $cor/fpga/lib/pcie/rtl/dma_client_axis_sink.v \
    $cor/fpga/lib/pcie/rtl/dma_client_axis_source.v \
    $cor/fpga/lib/pcie/rtl/dma_if_axi.v \
    $cor/fpga/lib/pcie/rtl/dma_if_axi_rd.v \
    $cor/fpga/lib/pcie/rtl/dma_if_axi_wr.v \
    $cor/fpga/lib/pcie/rtl/dma_if_desc_mux.v \
    $cor/fpga/lib/pcie/rtl/dma_if_mux.v \
    $cor/fpga/lib/pcie/rtl/dma_if_mux_rd.v \
    $cor/fpga/lib/pcie/rtl/dma_if_mux_wr.v \
    $cor/fpga/lib/pcie/rtl/dma_psdpram.v \
    $cor/fpga/lib/pcie/rtl/dma_ram_demux_rd.v \
    $cor/fpga/lib/pcie/rtl/dma_ram_demux_wr.v \
    $cor/fpga/lib/eth/rtl/eth_mac_10g.v \
    $cor/fpga/lib/eth/rtl/eth_phy_10g.v \
    $cor/fpga/lib/eth/rtl/eth_phy_10g_rx.v \
    $cor/fpga/lib/eth/rtl/eth_phy_10g_rx_ber_mon.v \
    $cor/fpga/lib/eth/rtl/eth_phy_10g_rx_frame_sync.v \
    $cor/fpga/lib/eth/rtl/eth_phy_10g_rx_if.v \
    $cor/fpga/lib/eth/rtl/eth_phy_10g_rx_watchdog.v \
    $cor/fpga/lib/eth/rtl/eth_phy_10g_tx.v \
    $cor/fpga/lib/eth/rtl/eth_phy_10g_tx_if.v \
    $cor/fpga/common/rtl/eth_xcvr_phy_10g_gty_quad_wrapper.v \
    $cor/fpga/common/rtl/eth_xcvr_phy_10g_gty_wrapper.v \
    $repo/rtl/fpga_core.v \
    $cor/fpga/lib/pcie/rtl/irq_rate_limit.v \
    $cor/fpga/lib/eth/rtl/lfsr.v \
    $cor/fpga/lib/eth/rtl/mac_ctrl_rx.v \
    $cor/fpga/lib/eth/rtl/mac_ctrl_tx.v \
    $cor/fpga/lib/eth/rtl/mac_pause_ctrl_rx.v \
    $cor/fpga/lib/eth/rtl/mac_pause_ctrl_tx.v \
    $cor/fpga/common/rtl/mqnic_core.v \
    $cor/fpga/common/rtl/mqnic_core_axi.v \
    $cor/fpga/common/rtl/mqnic_dram_if.v \
    $cor/fpga/common/rtl/mqnic_egress.v \
    $cor/fpga/common/rtl/mqnic_ingress.v \
    $cor/fpga/common/rtl/mqnic_interface.v \
    $cor/fpga/common/rtl/mqnic_interface_rx.v \
    $cor/fpga/common/rtl/mqnic_interface_tx.v \
    $cor/fpga/common/rtl/mqnic_l2_egress.v \
    $cor/fpga/common/rtl/mqnic_l2_ingress.v \
    $cor/fpga/common/rtl/mqnic_port.v \
    $cor/fpga/common/rtl/mqnic_port_map_phy_xgmii.v \
    $cor/fpga/common/rtl/mqnic_port_rx.v \
    $cor/fpga/common/rtl/mqnic_port_tx.v \
    $cor/fpga/common/rtl/mqnic_ptp.v \
    $cor/fpga/common/rtl/mqnic_ptp_clock.v \
    $cor/fpga/common/rtl/mqnic_ptp_perout.v \
    $cor/fpga/common/rtl/mqnic_rb_clk_info.v \
    $cor/fpga/common/rtl/mqnic_rx_queue_map.v \
    $cor/fpga/common/rtl/mqnic_tx_scheduler_block_rr.v \
    $cor/fpga/lib/axi/rtl/priority_encoder.v \
    $cor/fpga/lib/eth/rtl/ptp_perout.v \
    $cor/fpga/lib/eth/rtl/ptp_td_leaf.v \
    $cor/fpga/lib/eth/rtl/ptp_td_phc.v \
    $cor/fpga/common/rtl/queue_manager.v \
    $cor/fpga/common/rtl/rb_drp.v \
    $cor/fpga/common/rtl/rx_checksum.v \
    $cor/fpga/common/rtl/rx_engine.v \
    $cor/fpga/common/rtl/rx_fifo.v \
    $cor/fpga/common/rtl/rx_hash.v \
    $cor/fpga/common/rtl/stats_collect.v \
    $cor/fpga/common/rtl/stats_counter.v \
    $cor/fpga/common/rtl/stats_dma_if_axi.v \
    $cor/fpga/common/rtl/stats_dma_latency.v \
    $cor/fpga/lib/eth/lib/axis/rtl/sync_reset.v \
    $cor/fpga/common/rtl/tdma_ber.v \
    $cor/fpga/common/rtl/tdma_ber_ch.v \
    $cor/fpga/common/rtl/tdma_scheduler.v \
    $cor/fpga/common/rtl/tx_checksum.v \
    $cor/fpga/common/rtl/tx_engine.v \
    $cor/fpga/common/rtl/tx_fifo.v \
    $cor/fpga/common/rtl/tx_req_mux.v \
    $cor/fpga/common/rtl/tx_scheduler_rr.v \
    $cor/fpga/lib/eth/rtl/xgmii_baser_dec_64.v \
    $cor/fpga/lib/eth/rtl/xgmii_baser_enc_64.v \
    $repo/rtl/fpga.v \
    $cor/fpga/lib/eth/lib/axis/rtl/axis_register.v \
]
set_property top fpga [current_fileset]

add_files -fileset constrs_1 [list \
    $repo/constraints/fpga.xdc \
    $cor/fpga/lib/eth/lib/axis/syn/vivado/axis_async_fifo.tcl \
    $cor/fpga/lib/eth/lib/axis/syn/vivado/sync_reset.tcl \
    $cor/fpga/lib/eth/syn/vivado/ptp_td_leaf.tcl \
    $cor/fpga/common/syn/vivado/mqnic_port.tcl \
    $cor/fpga/common/syn/vivado/mqnic_ptp_clock.tcl \
    $cor/fpga/common/syn/vivado/mqnic_rb_clk_info.tcl \
    $cor/fpga/common/syn/vivado/rb_drp.tcl \
    $cor/fpga/common/syn/vivado/eth_xcvr_phy_10g_gty_wrapper.tcl \
    $cor/fpga/common/syn/vivado/tdma_ber_ch.tcl \
]

source $repo/ip/zynq_ps.tcl
source $repo/ip/eth_xcvr_gty.tcl
source $repo/scripts/config.tcl
