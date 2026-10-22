// ============================================================================
// clock_gate.sv
//
// Integrated clock-gating cell: the enable is captured by a latch that is
// transparent while the clock is low, so it can only change while the clock
// is low and the gated clock never glitches. This is the standard ICG
// structure.
//
// For synthesis it is the library's own clock-gating cell (ASAP7's
// ICGx1_ASAP7_75t_R), so that timing analysis and clock-tree synthesis see a
// clock gate rather than a loose latch and AND gate. Simulation keeps the
// behavioural model below, which does the same thing.
//
// The power manager (pmu.sv) drives one per core (sleep, parking, the DVFS
// divider) and one per core's pair of L1 caches (cluster power domains).
// ============================================================================

module clock_gate (
  input  logic clk_i,
  input  logic en_i,
  output logic clk_o
);

`ifdef SYNTHESIS
  ICGx1_ASAP7_75t_R u_icg (
    .CLK  (clk_i),
    .ENA  (en_i),
    .SE   (1'b0),
    .GCLK (clk_o)
  );
`else
  logic en_l;
  always_latch begin
    if (!clk_i) en_l = en_i;
  end
  assign clk_o = clk_i & en_l;
`endif

endmodule
