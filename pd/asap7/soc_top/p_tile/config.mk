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

# Pins: the clock in the middle of the top edge; the rest automatic.
export IO_CONSTRAINTS = /workspace/pd/asap7/soc_top/p_tile/io.tcl
