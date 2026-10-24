# ============================================================================
# E-tile macro placement (run 2). Coordinates: lower-left corner in um, on the
# placement grid (x a multiple of 0.054, y of 0.27). Core: (1.026, 1.08) to
# (143.964, 143.91).
#
# Each cache's tag SRAM is stacked directly above its data SRAM, on the same
# edge, with both sets of pins facing the logic in the middle: the tag and
# the data of a cache are read together by the same controller.
#
#   west edge: L1 data cache   (g_l1[0])   mirrored (MY): pins face east
#   east edge: L1 instr. cache (g_l1[1])   R0:            pins face west
#
#   data SRAM fakeram7_256x256: 33.25 x 84 um, y 2.16 .. 86.16
#   tag  SRAM fakeram7_256x32 :  8.36 x 42 um, y 91.26 .. 133.26 (5.1 um above)
#   The tags sit on the pin side, so their pins line up with the data's.
# ============================================================================

# ---- West: L1 data cache ----
place_macro -macro_name {u_l1.g_l1\[0\].u_l1.g_way\[0\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {2.052 2.16} -orientation MY
place_macro -macro_name {u_l1.g_l1\[0\].u_l1.g_way\[0\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {26.946 91.26} -orientation MY

# ---- East: L1 instruction cache ----
place_macro -macro_name {u_l1.g_l1\[1\].u_l1.g_way\[0\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {109.674 2.16} -orientation R0
place_macro -macro_name {u_l1.g_l1\[1\].u_l1.g_way\[0\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {109.674 91.26} -orientation R0
