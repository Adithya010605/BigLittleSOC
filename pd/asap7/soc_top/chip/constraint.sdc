# ============================================================================
# Chip (soc_top_pd) timing constraints. Time unit: ps (ASAP7).
# ============================================================================

# The chip clock: 1650 ps (606 MHz). The tiles close at 1500 ps inside;
# the chip at 1500 ps missed by 40 ps after routing (run 1), on paths that
# leave a tile: the tiles use their whole 60% of the cycle, and their flops
# get the clock about 230 ps after the chip's own (the tile's clock tree),
# which leaves the bus arbiter, the 256-bit muxes and the wires too little.
# 1650 leaves about 110 ps of margin (pd/README.md, section 20). Keep it a
# plain number on this first line: ORFS reads the period for timing-driven
# synthesis from the first `set clk_period <n>` line.
set clk_period 1650
if {[info exists ::env(CLK_PERIOD_PS)]} { set clk_period $::env(CLK_PERIOD_PS) }
create_clock -name clk -period $clk_period [get_ports clk_i]

# Chip pins: the off-chip memory port (xmem_*), the UART and reset. Each has
# 40% of the cycle outside the chip, as the tiles' I/O had; the paths
# between tiles are inside this design now and fully timed.
set io_budget [expr {0.4 * $clk_period}]
set_input_delay  $io_budget -clock clk [delete_from_list [all_inputs] [get_ports clk_i]]
set_output_delay $io_budget -clock clk [all_outputs]

# As in the tiles: no driver drives more than 32 inputs.
set_max_fanout 32 [current_design]
