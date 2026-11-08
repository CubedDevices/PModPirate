# Build the PModPirate processor schematic in the open project.
set root /home/kend/Development/FPGA/PModPirate

set_property ip_repo_paths [file join $root ip_repo] [current_project]
update_ip_catalog

set xdc [file join $root hw constraints cmod_s7.xdc]
if {[llength [get_files -quiet $xdc]] == 0} {
    add_files -fileset constrs_1 $xdc
}

if {[llength [get_bd_designs -quiet design_1]] != 0} {
    close_bd_design [get_bd_designs design_1]
}
if {[llength [get_files -quiet design_1.bd]] != 0} {
    remove_files [get_files design_1.bd]
}

create_bd_design design_1
open_bd_design [get_bd_designs design_1]

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
    CONFIG.PRIM_IN_FREQ {12.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_HIGH} \
    CONFIG.USE_LOCKED {true} \
] [get_bd_cells clk_wiz_0]

apply_bd_automation -rule xilinx.com:bd_rule:board -config {Manual_Source {Auto}} [get_bd_pins clk_wiz_0/clk_in1]
apply_bd_automation -rule xilinx.com:bd_rule:board -config {Manual_Source {Auto}} [get_bd_pins clk_wiz_0/reset]
set_property name clk [get_bd_ports clock_rtl]
set_property name reset [get_bd_ports reset_rtl]

create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze_riscv:1.0 microblaze_riscv_0
apply_bd_automation -rule xilinx.com:bd_rule:microblaze_riscv -config { \
    axi_intc {1} \
    axi_periph {Enabled} \
    cache {None} \
    clk {/clk_wiz_0/clk_out1 (100 MHz)} \
    debug_module {Debug Enabled} \
    ecc {None} \
    local_mem {64KB} \
    preset {Microcontroller} \
} [get_bd_cells microblaze_riscv_0]

# The board reset is active high. Point the processor reset at it.
set rst_pin [get_bd_pins -quiet rst_clk_wiz_0_100M/ext_reset_in]
if {$rst_pin eq ""} {
    set rst_pin [lindex [get_bd_pins -quiet -hier *ext_reset_in] 0]
}
if {$rst_pin ne ""} {
    set driven [get_bd_nets -quiet -of_objects $rst_pin]
    if {$driven ne ""} {
        disconnect_bd_net $driven $rst_pin
    }
    connect_bd_net [get_bd_ports reset] $rst_pin
}

save_bd_design
set cells [get_bd_cells]
return "OK cells=$cells"
