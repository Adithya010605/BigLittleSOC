// ============================================================================
// clock_gate.sv
//
// Integrated clock-gating cell: the enable is captured by a latch that is
// transparent while the clock is low, so it can only change while the clock
// is low and the gated clock never glitches. This is the standard ICG
// structure; a synthesis flow maps it onto the library's clock-gating cell.
//
// The power manager (pmu.sv) drives one per core (sleep, parking, the DVFS
// divider) and one per core's pair of L1 caches (cluster power domains).
// ============================================================================

module clock_gate (
  input  logic clk_i,
  input  logic en_i,
  output logic clk_o
);

  logic en_l;
  always_latch begin
    if (!clk_i) en_l = en_i;
  end
  assign clk_o = clk_i & en_l;

endmodule
