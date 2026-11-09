# ============================================================================
# Chip power grid. The ASAP7 standard grid (grid_strategy-M1-M2-M5-M6.tcl:
# M1/M2 rails, M5 and M6 straps), plus M7 straps over the whole chip.
#
# The tiles are hard macros with their own grid, its M6 straps their power
# pins, and they use no layer above M6 (MAX_ROUTING_LAYER in the tile
# configs). The chip's M7 straps cross them and drop vias onto those pins.
# The L2 SRAMs have their power pins on M4, reached from the M5 straps, as
# inside the tiles.
# ============================================================================
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDD$} -power
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^VSS$} -ground
global_connect

set_voltage_domain -name {CORE} -power {VDD} -ground {VSS}

define_pdn_grid -name {top} -voltage_domains {CORE} -pins {M7}
add_pdn_stripe -grid {top} -layer {M1} -width {0.018} -pitch {0.54} -offset {0} -followpins
add_pdn_stripe -grid {top} -layer {M2} -width {0.018} -pitch {0.54} -offset {0} -followpins
add_pdn_stripe -grid {top} -layer {M5} -width {0.12} -spacing {0.072} -pitch {5.4} -offset {0.300}
add_pdn_stripe -grid {top} -layer {M6} -width {0.288} -spacing {0.096} -pitch {5.4} -offset {0.513}
add_pdn_stripe -grid {top} -layer {M7} -width {0.288} -spacing {0.096} -pitch {10.8} -offset {2.0}
add_pdn_connect -grid {top} -layers {M1 M2}
add_pdn_connect -grid {top} -layers {M2 M5}
add_pdn_connect -grid {top} -layers {M5 M6}
add_pdn_connect -grid {top} -layers {M6 M7}

# Tiles: M7 straps onto their M6 power pins
define_pdn_grid -name {tiles} -voltage_domains {CORE} -macro \
  -cells {p_tile e_tile} -halo {2.0 2.0 2.0 2.0}
add_pdn_connect -grid {tiles} -layers {M6 M7}

# L2 SRAMs: M5 straps onto their M4 power pins
define_pdn_grid -name {srams} -voltage_domains {CORE} -macro \
  -cells {fakeram7_256x256 fakeram7_256x32} -halo {2.0 2.0 2.0 2.0}
add_pdn_connect -grid {srams} -layers {M4 M5}
