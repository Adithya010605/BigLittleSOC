# ============================================================================
# P-tile pin constraints. As in the E-tile: only the clock is placed by hand,
# in the middle of the top edge (the tile is 162 um wide), towards the two
# clock gates in the middle. Every other pin is placed by the tool.
# ============================================================================
set_io_pin_constraint -pin_names {clk_i} -region top:79-84
