# Add the UART, the 200 MHz reset, and the Pmod player to design_1.
open_bd_design [get_bd_designs design_1]

if {[llength [get_bd_cells -quiet rst_clk_wiz_0_200M]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_clk_wiz_0_200M
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins rst_clk_wiz_0_200M/slowest_sync_clk]
    connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins rst_clk_wiz_0_200M/dcm_locked]
    connect_bd_net [get_bd_ports reset] [get_bd_pins rst_clk_wiz_0_200M/ext_reset_in]
}

if {[llength [get_bd_cells -quiet axi_uartlite_0]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0
    set_property CONFIG.C_BAUDRATE {115200} [get_bd_cells axi_uartlite_0]
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { \
        Clk_master {/clk_wiz_0/clk_out1 (100 MHz)} \
        Clk_slave {Auto} \
        Clk_xbar {/clk_wiz_0/clk_out1 (100 MHz)} \
        Master {/microblaze_riscv_0 (Periph)} \
        Slave {/axi_uartlite_0/S_AXI} \
        ddr_seg {Auto} \
        intc_ip {/microblaze_riscv_0_axi_periph} \
        master_apm {0}} [get_bd_intf_pins axi_uartlite_0/S_AXI]
    apply_bd_automation -rule xilinx.com:bd_rule:board -config {Manual_Source {Auto}} \
        [get_bd_intf_pins axi_uartlite_0/UART]
}

if {[llength [get_bd_cells -quiet pmod_stream_0]] == 0} {
    create_bd_cell -type ip -vlnv user.org:user:pmod_stream:1.0 pmod_stream_0
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { \
        Clk_master {/clk_wiz_0/clk_out1 (100 MHz)} \
        Clk_slave {Auto} \
        Clk_xbar {/clk_wiz_0/clk_out1 (100 MHz)} \
        Master {/microblaze_riscv_0 (Periph)} \
        Slave {/pmod_stream_0/s_axi} \
        ddr_seg {Auto} \
        intc_ip {/microblaze_riscv_0_axi_periph} \
        master_apm {0}} [get_bd_intf_pins pmod_stream_0/s_axi]
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins pmod_stream_0/play_clk]
    connect_bd_net [get_bd_pins rst_clk_wiz_0_200M/peripheral_aresetn] [get_bd_pins pmod_stream_0/play_aresetn]
}

set_property CONFIG.NUM_PORTS {2} [get_bd_cells microblaze_riscv_0_xlconcat]
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_uartlite_0/interrupt]]] == 0} {
    connect_bd_net [get_bd_pins axi_uartlite_0/interrupt] [get_bd_pins microblaze_riscv_0_xlconcat/In0]
}
if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins pmod_stream_0/irq]]] == 0} {
    connect_bd_net [get_bd_pins pmod_stream_0/irq] [get_bd_pins microblaze_riscv_0_xlconcat/In1]
}

if {[llength [get_bd_ports -quiet pmod_io]] == 0} {
    set ext [make_bd_pins_external [get_bd_pins pmod_stream_0/pmod_io]]
    set_property name pmod_io $ext
}
if {[llength [get_bd_ports -quiet status_led]] == 0} {
    set ext [make_bd_pins_external [get_bd_pins pmod_stream_0/status_led]]
    set_property name status_led $ext
}

assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design

set ports [get_bd_ports]
set addrs {}
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces microblaze_riscv_0/Data]] {
    lappend addrs "[get_property NAME $seg]=[get_property OFFSET $seg]/[get_property RANGE $seg]"
}
return "OK ports=$ports addrs=$addrs"
