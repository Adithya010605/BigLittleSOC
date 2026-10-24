# ============================================================================
# E-tile timing constraints. Time unit: ps (ASAP7).
# ============================================================================

# Clock period, in ps. Keep it a plain number on this first line: ORFS reads
# the period for timing-driven synthesis from the first `set clk_period <n>`
# line (scripts/variables.mk). The clock sweep overrides it with
# CLK_PERIOD_PS, and must then also pass ABC_CLOCK_PERIOD_IN_PS=<n> to make.
set clk_period 1000
if {[info exists ::env(CLK_PERIOD_PS)]} { set clk_period $::env(CLK_PERIOD_PS) }
create_clock -name clk -period $clk_period [get_ports clk_i]

# Signals entering or leaving the tile have 40% of the cycle outside it
# (the top-level wiring and logic); the tile gets the other 60%.
set io_budget [expr {0.4 * $clk_period}]
set_input_delay  $io_budget -clock clk [delete_from_list [all_inputs] [get_ports clk_i]]
set_output_delay $io_budget -clock clk [all_outputs]

# No driver may drive more than 32 inputs. Without a limit, one buffer drove
# 131 gate inputs (a wide cache select signal): its edges took about 456 ps
# against the 320 ps slew limit, 350 max-slew violations. With the limit,
# timing repair builds a buffer tree for such nets.
set_max_fanout 32 [current_design]
