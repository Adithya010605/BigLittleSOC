# ============================================================================
# Chip (soc_top_pd) macro placement. Coordinates: lower-left corner in um, on
# the placement grid (x a multiple of 0.054, y of 0.27). Die 576.99 x 540.0 um.
#
#   +--------------------------------------------------------------+
#   | [P-tile 0]    L2 tags, bank 1         t  t   t  t [P-tile 1] |  y 475.2
#   |  MX: pins          tags, bank 0       t  t   t  t  R180      |  y 428.22
#   |  face down         data, bank 1       D  D   D  D            |  y 339.12
#   |                    data, bank 0       D  D   D  D            |  y 250.02
#   |                                  way  0  1   2  3            |
#   |        band (90 um): snooping bus, L2 control, crossbar, PMU |
#   |                                                              |
#   | [E-tile 0]                                        [E-tile 1] |
#   |  R0: pins           (memory pins, bottom edge, x 175-400)  MY |
#   +--------------------------------------------------------------+
#
# The tiles' pins are on their top edge and the top of their sides
# (PLACE_PINS_ARGS in the tile configs), so every tile faces the band. The
# right-hand tiles are mirrored left-right (P-tile 1 R180, E-tile 1 MY) so on
# both sides of the chip the tile's right side, the one with more pins (P 526
# vs 373, E 364 vs 313; bus and snoop data), faces the middle of the chip.
# All 16 L2 SRAMs sit between the P-tiles, one column per way, data next to
# the band and tags above (run 2's layout). The SRAM pins are all on one side
# (M4), so ways 0 and 2 are mirrored (MY) to face ways 1 and 3 across a
# channel. The area between the E-tiles is left free for the logic that drives
# the memory pins.
#
# Run 3 split the L2 by bank, bank 1 between the E-tiles (pd/README.md,
# section 21). Global placement then diverged (GPL-0305): the SRAMs sat on top
# of the memory pins, the cells that drive them had only the narrow channels
# between the SRAMs, and routability inflation grew to +83% (run 2: +37%).
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
  -location {196.992 250.02} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[0\].u_data.g_bank\[1\].g_line.u_ram} \
  -location {196.992 339.12} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[0\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {221.886 428.22} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[0\].u_tag.g_bank\[1\].g_word.u_ram} \
  -location {221.886 475.2} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[1\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {250.236 250.02} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[1\].u_data.g_bank\[1\].g_line.u_ram} \
  -location {250.236 339.12} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[1\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {250.236 428.22} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[1\].u_tag.g_bank\[1\].g_word.u_ram} \
  -location {250.236 475.2} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[2\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {293.49 250.02} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[2\].u_data.g_bank\[1\].g_line.u_ram} \
  -location {293.49 339.12} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[2\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {318.384 428.22} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[2\].u_tag.g_bank\[1\].g_word.u_ram} \
  -location {318.384 475.2} -orientation MY
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[3\].u_data.g_bank\[0\].g_line.u_ram} \
  -location {346.734 250.02} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[3\].u_data.g_bank\[1\].g_line.u_ram} \
  -location {346.734 339.12} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[3\].u_tag.g_bank\[0\].g_word.u_ram} \
  -location {346.734 428.22} -orientation R0
place_macro -macro_name {u_soc.u_bus.u_l2.g_way\[3\].u_tag.g_bank\[1\].g_word.u_ram} \
  -location {346.734 475.2} -orientation R0
