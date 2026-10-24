# ============================================================================
# E-tile pin constraints (run 2). Only the clock is placed by hand for now:
# the middle of the top edge (the tile is 145 um wide), close to the two clock
# gates near the centre. Every other pin is still placed by the tool.
# ============================================================================
set_io_pin_constraint -pin_names {clk_i} -region top:70-75
