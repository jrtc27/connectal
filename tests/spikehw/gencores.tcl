
set ipdir {cores}

set boardname {nfsume}
#set boardname {miniitx100}

if {$boardname == {nfsume}} {
    set partname {xc7vx690tffg1761-2}
    set databuswidth 32
}
if {$boardname == {miniitx100}} {
    set partname {xc7z100ffg900-2}
    set databuswidth 64
}

file mkdir $ipdir/$boardname

create_project -name local_synthesized_ip -in_memory -part $partname
set_property board_part xilinx.com:vc709:part0:1.0 [current_project]

proc fpgamake_ipcore {core_name core_version ip_name params} {
    global ipdir boardname

    set generate_ip 0

    if [file exists $ipdir/$boardname/$ip_name/$ip_name.xci] {
    } else {
	puts "no xci file $ip_name.xci"
	set generate_ip 1
    }
    if [file exists $ipdir/$boardname/$ip_name/vivadoversion.txt] {
	gets [open $ipdir/$boardname/$ip_name/vivadoversion.txt r] generated_version
	set current_version [version -short]
	puts "core was generated by vivado $generated_version, currently running vivado $current_version"
	if {$current_version != $generated_version} {
	    puts "vivado version does not match"
	    set generate_ip 1
	}
    } else {
	puts "no vivado version recorded"
	set generate_ip 1
    }

    ## check requested core version and parameters
    if [file exists $ipdir/$boardname/$ip_name/coreversion.txt] {
	gets [open $ipdir/$boardname/$ip_name/coreversion.txt r] generated_version
	set current_version "$core_name $core_version $params"
	puts "Core generated: $generated_version"
	puts "Core requested: $current_version"
	if {$current_version != $generated_version} {
	    puts "core version or params does not match"
	    set generate_ip 1
	}
    } else {
	puts "no core version recorded"
	set generate_ip 1
    }

    if $generate_ip {
	file delete -force $ipdir/$boardname/$ip_name
	file mkdir $ipdir/$boardname
	create_ip -name $core_name -version $core_version -vendor xilinx.com -library ip -module_name $ip_name -dir $ipdir/$boardname
	if [llength $params] {
	    set_property -dict $params [get_ips $ip_name]
	}
        report_property -file $ipdir/$boardname/$ip_name.properties.log [get_ips $ip_name]
	
	generate_target all [get_files $ipdir/$boardname/$ip_name/$ip_name.xci]

	set versionfd [open $ipdir/$boardname/$ip_name/vivadoversion.txt w]
	puts $versionfd [version -short]
	close $versionfd

	set corefd [open $ipdir/$boardname/$ip_name/coreversion.txt w]
	puts $corefd "$core_name $core_version $params"
	close $corefd
    } else {
	read_ip $ipdir/$boardname/$ip_name/$ip_name.xci
    }
    if [file exists $ipdir/$boardname/$ip_name/$ip_name.dcp] {
    } else {
	synth_ip [get_ips $ip_name]
    }
}

if {[version -short] == "2014.2"} {
    fpgamake_ipcore axi_ethernet_buffer 2.0 eth_buf [ list CONFIG.C_AVB {0} CONFIG.C_PHYADDR {1} CONFIG.C_PHY_TYPE {5} CONFIG.C_STATS {1} CONFIG.C_TYPE {1} CONFIG.ENABLE_LVDS {0} CONFIG.HAS_SGMII {true} CONFIG.MCAST_EXTEND {false} CONFIG.RXCSUM {None} CONFIG.RXMEM {4k} CONFIG.RXVLAN_STRP {false} CONFIG.RXVLAN_TAG {false} CONFIG.RXVLAN_TRAN {false} CONFIG.SIMULATION_MODE {false} CONFIG.TXCSUM {None} CONFIG.TXMEM {4k} CONFIG.TXVLAN_STRP {false} CONFIG.TXVLAN_TAG {false} CONFIG.TXVLAN_TRAN {false} CONFIG.USE_BOARD_FLOW {true}  ]
}

fpgamake_ipcore axi_uart16550 2.0  axi_uart16550_1 [list CONFIG.USE_BOARD_FLOW {true} CONFIG.UART_BOARD_INTERFACE {rs232_uart} CONFIG.C_HAS_EXTERNAL_XIN {1} CONFIG.C_HAS_EXTERNAL_RCLK {0} CONFIG.C_EXTERNAL_XIN_CLK_HZ_d {3.686400}  CONFIG.C_EXTERNAL_XIN_CLK_HZ {3686400}]

if {[version -short] == "2014.2"} {
    fpgamake_ipcore axi_intc 4.1 axi_intc_0 [list CONFIG.C_NUM_INTR_INPUTS {16} CONFIG.C_NUM_SW_INTR {0} CONFIG.C_HAS_ILR {1}]
} else {
    fpgamake_ipcore axi_intc 4.1 axi_intc_0 [list CONFIG.C_NUM_INTR_INPUTS {16} CONFIG.C_NUM_SW_INTR {0} CONFIG.C_HAS_ILR {1} CONFIG.C_S_AXI_ACLK_FREQ_MHZ  {250}]
}

fpgamake_ipcore fifo_generator 13.0 dual_clock_axis_fifo_32x1024 [list CONFIG.INTERFACE_TYPE {AXI_STREAM} CONFIG.Clock_Type_AXI {Independent_Clock} CONFIG.TDATA_NUM_BYTES {4} CONFIG.TUSER_WIDTH {0} CONFIG.Enable_TLAST {true} CONFIG.HAS_TKEEP {true} CONFIG.FIFO_Application_Type_axis {Data_FIFO} CONFIG.Reset_Type {Asynchronous_Reset} CONFIG.Full_Flags_Reset_Value {1} CONFIG.TSTRB_WIDTH {4} CONFIG.TKEEP_WIDTH {4} CONFIG.FIFO_Implementation_wach {Independent_Clocks_Distributed_RAM} CONFIG.Full_Threshold_Assert_Value_wach {15} CONFIG.Empty_Threshold_Assert_Value_wach {13} CONFIG.FIFO_Implementation_wdch {Independent_Clocks_Block_RAM} CONFIG.Empty_Threshold_Assert_Value_wdch {1021} CONFIG.FIFO_Implementation_wrch {Independent_Clocks_Distributed_RAM} CONFIG.Full_Threshold_Assert_Value_wrch {15} CONFIG.Empty_Threshold_Assert_Value_wrch {13} CONFIG.FIFO_Implementation_rach {Independent_Clocks_Distributed_RAM} CONFIG.Full_Threshold_Assert_Value_rach {15} CONFIG.Empty_Threshold_Assert_Value_rach {13} CONFIG.FIFO_Implementation_rdch {Independent_Clocks_Block_RAM} CONFIG.Empty_Threshold_Assert_Value_rdch {1021} CONFIG.FIFO_Implementation_axis {Independent_Clocks_Block_RAM} CONFIG.Empty_Threshold_Assert_Value_axis {1021}]

fpgamake_ipcore axi_dma 7.1 axi_dma_0 [list CONFIG.c_m_axi_mm2s_data_width $databuswidth CONFIG.c_m_axi_s2mm_data_width $databuswidth CONFIG.c_mm2s_burst_size {8} CONFIG.c_s2mm_burst_size {8} CONFIG.c_include_mm2s_dre {1} CONFIG.c_include_s2mm_dre {1}]

fpgamake_ipcore axi_iic 2.0 axi_iic_0 [list CONFIG.AXI_ACLK_FREQ_MHZ {250} CONFIG.C_GPO_WIDTH {8}]

fpgamake_ipcore axi_quad_spi 3.2 axi_spi_0 [list CONFIG.C_USE_STARTUP {0} CONFIG.C_SPI_MODE {0} CONFIG.C_XIP_MODE {0} CONFIG.C_USE_STARTUP_INT {0} CONFIG.C_SCK_RATIO {16} CONFIG.C_FIFO_DEPTH {16} CONFIG.C_TYPE_OF_AXI4_INTERFACE {0}]

## does not exist with vivado 2014.2
if {[version -short] > "2014.2"} {
    fpgamake_ipcore axi_ethernet 7.0 axi_ethernet_1000basex [list CONFIG.ETHERNET_BOARD_INTERFACE {sfp1} CONFIG.processor_mode {true} CONFIG.DIFFCLK_BOARD_INTERFACE {sfp_mgt_clk} CONFIG.axiliteclkrate {250.0} CONFIG.PHY_TYPE {1000BaseX}]

    fpgamake_ipcore tri_mode_ethernet_mac 9.0 tri_mode_ethernet_mac_0 [list CONFIG.Physical_Interface {Internal}  CONFIG.MAC_Speed {1000_Mbps} CONFIG.SupportLevel {1}]

    ## 2014.2: 14.2
    ## 2015.4: 15.1
    fpgamake_ipcore gig_ethernet_pcs_pma 15.1 gig_ethernet_pcs_pma_0 [list  CONFIG.USE_BOARD_FLOW {true} CONFIG.Management_Interface {true} CONFIG.ETHERNET_BOARD_INTERFACE {sfp1} CONFIG.DIFFCLK_BOARD_INTERFACE {sfp_mgt_clk} CONFIG.Standard {1000BASEX} CONFIG.SupportLevel {Include_Shared_Logic_in_Core}]

} else {
    ## 2014.2: 8.2
    ## 2015.4: 9.0
    fpgamake_ipcore tri_mode_ethernet_mac 8.2 tri_mode_ethernet_mac_0 [list CONFIG.Physical_Interface {Internal}  CONFIG.MAC_Speed {1000_Mbps} CONFIG.SupportLevel {1}]

    ## 2014.2: 14.2
    ## 2015.4: 15.1
    fpgamake_ipcore gig_ethernet_pcs_pma 14.2 gig_ethernet_pcs_pma_0 [list  CONFIG.USE_BOARD_FLOW {true} CONFIG.Management_Interface {true} CONFIG.ETHERNET_BOARD_INTERFACE {sfp1} CONFIG.DIFFCLK_BOARD_INTERFACE {sfp_mgt_clk} CONFIG.Standard {1000BASEX} CONFIG.SupportLevel {Include_Shared_Logic_in_Core}]
}

if {[version -short] > "2014.2"} {
    fpgamake_ipcore mig_7series 2.1 ddr3_v2_1 [list CONFIG.XML_INPUT_FILE [pwd]/mig_a.prj CONFIG.RESET_BOARD_INTERFACE {Custom} CONFIG.MIG_DONT_TOUCH_PARAM {Custom} CONFIG.BOARD_MIG_PARAM {Custom}]
}

