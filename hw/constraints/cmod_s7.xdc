## Cmod S7-25 constraints for PModPirate.
## Pin locations follow Digilent's Cmod-S7-25 master XDC.

set_property -dict {PACKAGE_PIN M9 IOSTANDARD LVCMOS33} [get_ports clk]
# clk_wiz already creates the 83.333 ns clock on this port and names it clk.
# A second create_clock named sys_clk_pin overrides that clock and drops the
# wizard constraints that still refer to clk.

set_property -dict {PACKAGE_PIN D2 IOSTANDARD LVCMOS33} [get_ports reset]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33} [get_ports status_led]

set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {pmod_io[0]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {pmod_io[1]}]
set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {pmod_io[2]}]
set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {pmod_io[3]}]
set_property -dict {PACKAGE_PIN H3 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {pmod_io[4]}]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {pmod_io[5]}]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {pmod_io[6]}]
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {pmod_io[7]}]

set_property -dict {PACKAGE_PIN L12 IOSTANDARD LVCMOS33} [get_ports uart_rtl_txd]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports uart_rtl_rxd]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
