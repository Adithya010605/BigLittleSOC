# ============================================================================
# clock_gate_power.tcl
#
# Checks a finished tile's two clock gates (rtl/power/clock_gate.sv: the
# core's, u_cg.u_icg, and the L1 pair's, u_l1.u_cg.u_icg) and measures the
# power they save. Run from /OpenROAD-flow-scripts/flow in scripts/orfs_shell.sh:
#
#   make DESIGN_CONFIG=/workspace/pd/asap7/soc_top/p_tile/config.mk \
#        FLOW_VARIANT=final_1500_m6 RUN_LOG_NAME_STEM=clock_gate_power \
#        RUN_SCRIPT=/workspace/pd/asap7/soc_top/clock_gate_power.tcl run
#
# Power is OpenSTA's vectorless estimate (the same default activity as the
# flow's 6_finish report) with the routed parasitics, reported three times:
# both clocks running, the core's gated clock stopped (activity 0 on the
# gate's GCLK pin, which the tool propagates through the clock tree to every
# flip-flop and SRAM behind it), and both stopped.
# ============================================================================

source $::env(SCRIPTS_DIR)/load.tcl
load_design 6_final.odb 6_final.sdc
read_spef $::env(RESULTS_DIR)/6_final.spef
set_propagated_clock [all_clocks]

# The enable must settle while the clock is low: the gate's setup and hold
# checks against the clock.
foreach gate {u_cg.u_icg u_l1.u_cg.u_icg} {
  foreach delay {max min} {
    set path [lindex [find_timing_paths -to [get_pins $gate/ENA] -path_delay $delay] 0]
    puts [format "%-16s ENA %s slack %.1f ps" $gate $delay [get_property $path slack]]
  }
}

puts "\n== Both clocks running"
report_power

puts "\n== Core clock gated (sleep, parked)"
set_power_activity -pins [get_pins u_cg.u_icg/GCLK] -activity 0 -duty 0
report_power

puts "\n== Core and L1 clocks gated (cluster off)"
set_power_activity -pins [get_pins u_l1.u_cg.u_icg/GCLK] -activity 0 -duty 0
report_power
