# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "RX_SAMPLES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TX_WORDS" -parent ${Page_0}


}

proc update_PARAM_VALUE.RX_SAMPLES { PARAM_VALUE.RX_SAMPLES } {
	# Procedure called to update RX_SAMPLES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.RX_SAMPLES { PARAM_VALUE.RX_SAMPLES } {
	# Procedure called to validate RX_SAMPLES
	return true
}

proc update_PARAM_VALUE.TX_WORDS { PARAM_VALUE.TX_WORDS } {
	# Procedure called to update TX_WORDS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TX_WORDS { PARAM_VALUE.TX_WORDS } {
	# Procedure called to validate TX_WORDS
	return true
}


proc update_MODELPARAM_VALUE.TX_WORDS { MODELPARAM_VALUE.TX_WORDS PARAM_VALUE.TX_WORDS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TX_WORDS}] ${MODELPARAM_VALUE.TX_WORDS}
}

proc update_MODELPARAM_VALUE.RX_SAMPLES { MODELPARAM_VALUE.RX_SAMPLES PARAM_VALUE.RX_SAMPLES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.RX_SAMPLES}] ${MODELPARAM_VALUE.RX_SAMPLES}
}

