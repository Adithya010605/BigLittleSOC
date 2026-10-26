# ============================================================================
# P-tile timing constraints. Time unit: ps (ASAP7).
# The E-tile's constraints (../e_tile/constraint.sdc), unchanged: the two tiles
# have the same ports and sit on the same snooping bus and PMU.
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

# Except the PMU's debug port (dbg_*: register, CSR and PC access, used to
# move a task between cores): 20% outside. On the PMU side the address comes
# straight from a counter register and the read data passes two small muxes
# into a register (pmu.sv), so little of the cycle is spent outside. With
# 40% + 40%, a path from a debug input to an output gets only 20% of the
# cycle (E-tile, section 10 of pd/README.md). Still timed, and checked again
# at the top level.
set dbg_budget [expr {0.2 * $clk_period}]
set dbg_in  [get_ports dbg_*_i]
set dbg_out [get_ports dbg_*_o]

set other_in [delete_from_list [all_inputs] [concat [get_ports clk_i] $dbg_in]]
set_input_delay  $io_budget  -clock clk $other_in
set_input_delay  $dbg_budget -clock clk $dbg_in
set_output_delay $io_budget  -clock clk [delete_from_list [all_outputs] $dbg_out]
set_output_delay $dbg_budget -clock clk $dbg_out

# No driver may drive more than 32 inputs. Without a limit, one buffer in the
# E-tile drove 131 gate inputs (a wide cache select signal) and broke the
# slew limit; with it, timing repair builds a buffer tree for such nets.
set_max_fanout 32 [current_design]
