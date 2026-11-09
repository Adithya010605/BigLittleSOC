# ============================================================================
# Chip pin constraints. The off-chip memory port (xmem_*, 581 pins) and the
# clock go on the bottom edge between the two E-tiles (x 175-400 um), next to
# the crossbar's slave 0; reset and the UART on the left edge, in the band
# between the E-tile and the P-tile (y 165-245 um). See macro_place.tcl.
# ============================================================================
set xmem {}
foreach bterm [[ord::get_db_block] getBTerms] {
  if {[string match xmem_* [$bterm getName]]} { lappend xmem [$bterm getName] }
}
set_io_pin_constraint -pin_names $xmem -region bottom:175-400
set_io_pin_constraint -pin_names {clk_i} -region bottom:285-290
set uart {}
foreach bterm [[ord::get_db_block] getBTerms] {
  if {[string match uart_* [$bterm getName]]} { lappend uart [$bterm getName] }
}
set_io_pin_constraint -pin_names [concat rst_ni $uart] -region left:165-245
