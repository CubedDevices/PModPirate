# Package pmod_stream as a Vivado catalog IP.
set root /home/kend/Development/FPGA/PModPirate
set dest [file join $root ip_repo pmod_stream]
file delete -force $dest
file mkdir [file join $root ip_repo]

create_project pmod_stream_ip /tmp/pmod_stream_ip -part xc7s25csga225-1 -force
add_files [file join $root hw hdl pmod_stream.v]
set_property top pmod_stream [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $dest -vendor user.org -library user \
    -taxonomy /UserIP -import_files -force

set core [ipx::current_core]
set_property name pmod_stream $core
set_property display_name {Pmod Stream Player} $core
set_property description {Run-length 8-pin Pmod waveform player with capture} $core
set_property vendor_display_name {PModPirate} $core
set_property version 1.0 $core
set_property core_revision 1 $core
set_property supported_families { \
    spartan7 Production artix7 Production kintex7 Production \
    zynq Production virtex7 Production \
} $core

# AXI clock association. play_clk stays an independent clock.
set axi_clk [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]
if {$axi_clk ne ""} {
    ipx::associate_bus_interfaces -busif s_axi -clock s_axi_aclk $core
}

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core

set ifaces {}
foreach intf [ipx::get_bus_interfaces -of_objects $core] {
    lappend ifaces [get_property NAME $intf]
}
set ports {}
foreach p [ipx::get_ports -of_objects $core] {
    lappend ports [get_property NAME $p]
}

close_project
return "OK ifaces=$ifaces ports=$ports"
