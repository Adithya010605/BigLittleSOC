# ============================================================================
# Chip (soc_top_pd) macro placement. Coordinates: lower-left corner in um, on
# the placement grid (x a multiple of 0.054, y of 0.27). Die 576.99 x 540.0 um.
#
#   +--------------------------------------------------------------+
#   | [P-tile 0]    L2 bank 0: tags         t  t   t  t [P-tile 1] |  y 339.12
#   |  MX: pins                data         D  D   D  D  R180      |  y 250.02
#   |  face down                       way  0  1   2  3            |
#   |        band (90 um): snooping bus, L2 control, crossbar, PMU |
#   |                                                              |
#   | [E-tile 0]    L2 bank 1: data         D  D   D  D [E-tile 1] |  y  76.14
#   |  R0: pins                tags         t  t   t  t  MY        |  y  29.16
#   |  face up            (memory pins, bottom edge, x 175-400)     |
#   +--------------------------------------------------------------+
#
# The tiles' pins are on their top edge and the top of their sides
# (PLACE_PINS_ARGS in the tile configs), so every tile faces the band. The
# right-hand tiles are mirrored left-right (P-tile 1 R180, E-tile 1 MY) so on
# both sides of the chip the tile's right side, the one with more pins (P 526
# vs 373, E 364 vs 313; bus and snoop data), faces the middle of the chip.
# Each L2 way's SRAMs are two banks of 256 sets (rtl/cache/sram_sp.sv): bank 0
# above the band, bank 1 below it, so both banks sit against the band where the
# L2 logic is. In each bank a way is one column, its data SRAM (84 um) next to
# the band and that bank's tag SRAM (42 um) on the far side of it. The SRAM
# pins are all on one side (M4), so ways 0 and 2 are mirrored (MY) to face
# ways 1 and 3 across a 20 um channel, and each tag is aligned with its data
# SRAM's pin edge. The two pairs of ways are 15 um apart, back to back. The
# SRAMs block only M1-M4, so the memory pins route over bank 1 on M5 and up.
# ============================================================================

place_macro -macro_name {u_soc.g_p\[0\].u_tile} \
  -location {15.012 250.02} -orientation MX
place_macro -macro_name {u_soc.g_p\[1\].u_tile} \
  -location {399.978 250.02} -orientation R180
place_macro -macro_name {u_soc.g_e\[0\].u_tile} \
  -location {15.012 15.12} -orientation R0
place_macro -macro_name {u_soc.g_e\[1\].u_tile} \
  -location {416.988 15.12} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[0\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {194.508 250.02} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[0\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {219.402 339.12} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[1\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {247.752 250.02} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[1\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {247.752 339.12} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[2\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {296.028 250.02} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[2\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {320.922 339.12} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[3\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {349.272 250.02} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[3\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {349.272 339.12} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[0\].u_data.g_bank\[1\].g_line.u_ram} \
  -location {194.508 76.14} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[0\].u_tag.g_bank\[1\].g_word.u_ram} \
  -location {219.402 29.16} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[1\].u_data.g_bank\[1\].g_line.u_ram} \
  -location {247.752 76.14} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[1\].u_tag.g_bank\[1\].g_word.u_ram} \
  -location {247.752 29.16} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[2\].u_data.g_bank\[1\].g_line.u_ram} \
  -location {296.028 76.14} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[2\].u_tag.g_bank\[1\].g_word.u_ram} \
  -location {320.922 29.16} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[3\].u_data.g_bank\[1\].g_line.u_ram} \
  -location {349.272 76.14} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[3\].u_tag.g_bank\[1\].g_word.u_ram} \
  -location {349.272 29.16} -orientation R0
