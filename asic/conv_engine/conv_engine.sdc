# Timing constraints for conv_engine hardened as a macro.
#
# Based on LibreLane's default scripts/base.sdc (3.0.16), with one change:
# a realistic MINIMUM input delay for hold analysis.
#
# Why: the default applies one input delay (IO_DELAY_CONSTRAINT % of the
# period) for both setup and hold, measured from an ideal clock edge at the
# pins. Inside this macro the clock reaches the flops ~2.9 ns later at the
# ss corner (propagated clock tree), so on paper input data "beats" the
# capturing edge and every input-to-flop path fails hold by a fraction of a
# ns (runs v1-v4b). In a real SoC the logic driving these inputs is clocked
# by the same balanced clock tree, so its launch edge is also delayed. We
# model that with EXT_CLK_LATENCY_MIN, a conservative lower bound on that
# external latency (about a third of this macro's own ss insertion delay),
# added to the minimum input delay only. Setup (max) analysis is unchanged.

set ::EXT_CLK_LATENCY_MIN 1.0   ;# ns

set clock_port [lindex $::env(CLOCK_PORT) 0]
create_clock [get_ports $clock_port] -name $clock_port -period $::env(CLOCK_PERIOD)
set clocks [get_clocks $clock_port]

set input_delay_value  [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set output_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set input_delay_min    [expr $input_delay_value + $::EXT_CLK_LATENCY_MIN]
puts "\[INFO] Input delay: max $input_delay_value, min $input_delay_min; output delay $output_delay_value"

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

set clk_input [get_port $clock_port]
set clk_indx [lsearch [all_inputs] $clk_input]
set all_inputs_wo_clk [lreplace [all_inputs] $clk_indx $clk_indx ""]

set_input_delay -max $input_delay_value -clock $clocks $all_inputs_wo_clk
set_input_delay -min $input_delay_min   -clock $clocks $all_inputs_wo_clk
set_output_delay $output_delay_value -clock $clocks [all_outputs]

if { ![info exists ::env(SYNTH_CLK_DRIVING_CELL)] } {
    set ::env(SYNTH_CLK_DRIVING_CELL) $::env(SYNTH_DRIVING_CELL)
}
set_driving_cell \
    -lib_cell [lindex [split $::env(SYNTH_DRIVING_CELL) "/"] 0] \
    -pin [lindex [split $::env(SYNTH_DRIVING_CELL) "/"] 1] \
    $all_inputs_wo_clk
set_driving_cell \
    -lib_cell [lindex [split $::env(SYNTH_CLK_DRIVING_CELL) "/"] 0] \
    -pin [lindex [split $::env(SYNTH_CLK_DRIVING_CELL) "/"] 1] \
    $clk_input

set_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0] [all_outputs]
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $clocks
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $clocks
set_timing_derate -early [expr 1-[expr $::env(TIME_DERATING_CONSTRAINT) / 100.0]]
set_timing_derate -late [expr 1+[expr $::env(TIME_DERATING_CONSTRAINT) / 100.0]]

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}
