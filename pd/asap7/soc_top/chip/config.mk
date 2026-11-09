# ============================================================================
# The chip: soc_top_pd (rtl/soc/soc_top_pd.sv), ASAP7. Two P-tiles and two
# E-tiles placed as hard macros (pd/macros/<tile>/), with the snooping bus,
# the L2 (16 SRAM macros), the crossbar, the PMU and the peripherals as
# standard cells around them. Main memory is off chip (xmem_* pins).
# ============================================================================

# (No comments at the end of variable lines: make keeps the spaces before '#'.)
export DESIGN_NICKNAME = soc_top_chip
export DESIGN_NAME     = soc_top_pd
export PLATFORM        = asap7

# ---- RTL: everything outside the tiles, read as SystemVerilog ----
# (ORFS adds -D SYNTHESIS.) The tiles' RTL (rtl/soc/*_tile.sv, the cores,
# the L1s) is not read: p_tile and e_tile are unknown modules to slang
# (--ignore-unknown-modules), and Yosys resolves them to the tile .lib cells
# below. Reading the RTL with the module black-boxed doesn't work: slang
# keeps every parameter and localparam of a black box on its instances, and a
# .lib cell has none.
export SYNTH_HDL_FRONTEND = slang
export VERILOG_FILES = /workspace/rtl/common/e_core_pkg.sv \
                       /workspace/rtl/p_core/p_core_pkg.sv \
                       /workspace/rtl/cache/cache_pkg.sv \
                       /workspace/rtl/cache/sram_sp.sv \
                       /workspace/rtl/cache/l2_cache.sv \
                       /workspace/rtl/coherence/snoop_bus.sv \
                       $(wildcard /workspace/rtl/interconnect/*.sv) \
                       $(wildcard /workspace/rtl/periph/*.sv) \
                       $(wildcard /workspace/rtl/power/*.sv) \
                       /workspace/rtl/soc/soc_top.sv \
                       /workspace/rtl/soc/soc_top_pd.sv
export VERILOG_INCLUDE_DIRS = /workspace/rtl/common /workspace/rtl/e_core /workspace/rtl/p_core
export SDC_FILE = /workspace/pd/asap7/soc_top/chip/constraint.sdc

# ---- Cell libraries: regular-Vt, plus low-Vt for critical paths ----
# As in both tiles (pd/README.md, sections 15 and 18).
export ASAP7_USE_VT = RVT LVT

# ---- Macros: the tiles and the L2's SRAMs ----
# Tiles: outline, pins and blockages (.lef), timing model (.lib), layout
# (.gds.gz, merged into the chip GDS). L2: per way, two 256x256 data SRAMs
# and two 256x32 tag SRAMs (512 sets).
export ADDITIONAL_LEFS = $(PLATFORM_DIR)/lef/fakeram7_256x256.lef \
                         $(PLATFORM_DIR)/lef/fakeram7_256x32.lef \
                         /workspace/pd/macros/p_tile/p_tile.lef \
                         /workspace/pd/macros/e_tile/e_tile.lef
export ADDITIONAL_LIBS = $(PLATFORM_DIR)/lib/NLDM/fakeram7_256x256.lib \
                         $(PLATFORM_DIR)/lib/NLDM/fakeram7_256x32.lib \
                         /workspace/pd/macros/p_tile/p_tile.lib \
                         /workspace/pd/macros/e_tile/e_tile.lib
export ADDITIONAL_GDS  = /workspace/pd/macros/p_tile/p_tile.gds.gz \
                         /workspace/pd/macros/e_tile/e_tile.gds.gz

# ---- Floorplan ----
# 577 x 540 um: the four tiles in the corners, the L2's SRAMs between the
# P-tiles, a 90 um band in the middle for the glue logic (synthesis: about
# 10,000 um2 of cells, 9,500 flip-flops). Drawing and coordinates in
# macro_place.tcl. The core is inset by about 1 um, on the placement grid.
export DIE_AREA         = 0 0 576.99 540
export CORE_AREA        = 1.026 1.08 575.91 538.92
export PLACE_DENSITY    = 0.55

export MACRO_PLACEMENT_TCL = /workspace/pd/asap7/soc_top/chip/macro_place.tcl
export MACRO_PLACE_HALO    = 5 5
export IO_CONSTRAINTS      = /workspace/pd/asap7/soc_top/chip/io.tcl

# ---- Power grid: the standard one plus M7 straps for the tiles ----
export PDN_TCL = /workspace/pd/asap7/soc_top/chip/pdn.tcl

# ---- Routing: M2 to M9. The tiles use up to M6; over them the chip
# routes on M7 (between the power straps), M8 and M9. ----
export MAX_ROUTING_LAYER = M9

# ---- Repair margins, as in the tiles' final runs ----
# Run 1 (no margins) ended with 368 slew violations (worst 517 ps against
# the 320 ps limit), on long nets across the chip.
export SETUP_SLACK_MARGIN = 30
export SLEW_MARGIN        = 20
