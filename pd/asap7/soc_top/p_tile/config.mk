# ============================================================================
# P-tile: one P-core with its L1 caches (rtl/soc/p_tile.sv), ASAP7.
# Starts from the E-tile's final setup (../e_tile/config.mk).
# ============================================================================

# <top>_<block>: the top level finds the tile by this name.
# (No comments at the end of variable lines: make keeps the spaces before '#'.)
export DESIGN_NICKNAME = soc_top_p_tile
export DESIGN_NAME     = p_tile
export PLATFORM        = asap7

# ---- RTL: read as SystemVerilog directly (ORFS adds -D SYNTHESIS) ----
# The P-core's files as scripts/core_config.sh lists them: both packages
# first, the shared common files, the P-core, and the E-core's trap unit.
export SYNTH_HDL_FRONTEND = slang
export VERILOG_FILES = /workspace/rtl/common/e_core_pkg.sv \
                       /workspace/rtl/p_core/p_core_pkg.sv \
                       /workspace/rtl/cache/cache_pkg.sv \
                       $(filter-out %/e_core_pkg.sv,$(wildcard /workspace/rtl/common/*.sv)) \
                       $(filter-out %/p_core_pkg.sv,$(wildcard /workspace/rtl/p_core/*.sv)) \
                       /workspace/rtl/e_core/e_core_trap.sv \
                       /workspace/rtl/cache/sram_sp.sv \
                       /workspace/rtl/cache/l1_dcache.sv \
                       /workspace/rtl/cache/l1_pair.sv \
                       /workspace/rtl/power/clock_gate.sv \
                       /workspace/rtl/soc/p_tile.sv
export VERILOG_INCLUDE_DIRS = /workspace/rtl/common /workspace/rtl/e_core /workspace/rtl/p_core
export SDC_FILE = /workspace/pd/asap7/soc_top/p_tile/constraint.sdc

# ---- Cell libraries: regular-Vt, plus low-Vt for critical paths ----
# RVT stays the main library. LVT cells switch faster but leak more; with
# both loaded, timing repair swaps cells on failing paths to LVT (its
# vt_swap moves) and leaves the rest RVT. The big core spends some leakage
# for speed (pd/README.md, section 15); the E-tile does the same since
# section 18.
export ASAP7_USE_VT = RVT LVT

# ---- SRAM macros: outline and pins (.lef), timing (.lib) ----
# 256x256: cache line data. 256x32: cache tags. 2-way caches: one of each
# per way, so 8 macros.
export ADDITIONAL_LEFS = $(PLATFORM_DIR)/lef/fakeram7_256x256.lef \
                         $(PLATFORM_DIR)/lef/fakeram7_256x32.lef
export ADDITIONAL_LIBS = $(PLATFORM_DIR)/lib/NLDM/fakeram7_256x256.lib \
                         $(PLATFORM_DIR)/lib/NLDM/fakeram7_256x32.lib

# ---- Floorplan: the E-tile's, with a second way per cache ----
# Fixed size: 162 x 275 um, sized from synthesis (23,100 um2 of cells and
# SRAMs) for about the E-tile's 55% utilisation. Each cache's four SRAMs
# stack on one edge, so the tile is taller than wide. The core is inset by
# about 1 um, on the placement grid.
export DIE_AREA         = 0 0 162 275
export CORE_AREA        = 1.026 1.08 160.974 273.78
export PLACE_DENSITY    = 0.65

# Macros placed by hand (tags between their data, pins facing the logic),
# with a 5 um halo kept free of standard cells.
export MACRO_PLACEMENT_TCL = /workspace/pd/asap7/soc_top/p_tile/macro_place.tcl
export MACRO_PLACE_HALO    = 5 5

# Pins: the clock in the middle of the top edge; the rest automatic, on the
# top edge and the top 75 um of the two side edges (the bottom edge and the
# rest of the sides excluded). At the chip level that side faces the bus
# and the L2 (pd/README.md, section 20). The top edge alone is too short:
# 1,666 pins, and an M5 pin every 2 tracks gives about 1687.
export PLACE_PINS_ARGS = -exclude bottom:* -exclude left:0-200 -exclude right:0-200
export IO_CONSTRAINTS = /workspace/pd/asap7/soc_top/p_tile/io.tcl

# ---- Routing: M2 to M6; M7 and up belong to the chip ----
# The chip's power grid reaches the tile's M6 power stripes from M7, so the
# tile must leave M7 free: the abstract blocks every layer the tile uses,
# over its whole area. (The tiles used M7 for 0.1-0.5% of their wiring.)
export MAX_ROUTING_LAYER = M6
# Without M7 and with the pins on one side, global routing ended with one
# overflowing GCell on M3 at the platform's 25% layer adjustment (the share
# of each layer held back); 18%, as the router suggests (section 20).
export ROUTING_LAYER_ADJUSTMENT = 0.18
export PRE_GLOBAL_ROUTE_TCL = /workspace/pd/asap7/soc_top/p_tile/grt_adjust.tcl

# ---- Final run (the macro the top level uses): margins on repair ----
# Timing repair aims 30 ps past zero setup slack, and slew repair 20% under
# the limit, so the final tile ends with some room instead of a hair below
# zero (pd/README.md, section 17).
export SETUP_SLACK_MARGIN = 30
export SLEW_MARGIN        = 20
