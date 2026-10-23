# ============================================================================
# E-tile timing constraints. Time unit: ps (ASAP7).
# ============================================================================

# Clock period: 1000 ps (1 GHz) by default; the clock sweep sets CLK_PERIOD_PS.
set clk_period [expr {[info exists ::env(CLK_PERIOD_PS)] ? $::env(CLK_PERIOD_PS) : 1000}]
create_clock -name clk -period $clk_period [get_ports clk_i]

# Signals entering or leaving the tile have 40% of the cycle outside it
# (the top-level wiring and logic); the tile gets the other 60%.
set io_budget [expr {0.4 * $clk_period}]
set_input_delay  $io_budget -clock clk [delete_from_list [all_inputs] [get_ports clk_i]]
set_output_delay $io_budget -clock clk [all_outputs]
