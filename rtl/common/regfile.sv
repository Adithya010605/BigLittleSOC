// ============================================================================
// regfile.sv
//
// RV32I integer register file: 32 x 32-bit, two read ports, one write port.
//
// Two properties matter to the rest of the core:
//
//  1. x0 is hardwired to zero. It is never written (the write enable is masked
//     against waddr_i == 0) and never read from the array (both read paths mux
//     in a constant zero). Masking the write as well as the read means a
//     stray write to x0 cannot corrupt storage that some later change might
//     start reading.
//
//  2. WRITE-FIRST behaviour. A read in S2 of the register being written by S3
//     in the same cycle returns the NEW value. This is implemented as an
//     explicit combinational bypass around the array, not by relying on a
//     memory model's read-during-write semantics, because those semantics
//     differ between simulation, FPGA block RAM and ASIC compilers. Making
//     the bypass explicit means the behaviour is identical everywhere and is
//     directly testable — see tb/unit/tb_regfile.cpp.
//
// The array is deliberately NOT reset. Resetting 1024 flip-flops would prevent
// the array from being inferred as distributed RAM (LUTRAM on Xilinx), which
// is the single biggest factor in hitting the < 5K LUT target for this core.
// Determinism in simulation is instead provided by a zero-initialisation that
// is excluded from synthesis.
// ============================================================================

module regfile
  import e_core_pkg::*;
(
  input  logic                  clk_i,

  // Read port A
  input  logic [REG_ADDR_W-1:0] raddr_a_i,
  output logic [XLEN-1:0]       rdata_a_o,

  // Read port B
  input  logic [REG_ADDR_W-1:0] raddr_b_i,
  output logic [XLEN-1:0]       rdata_b_o,

  // Write port
  input  logic                  we_i,
  input  logic [REG_ADDR_W-1:0] waddr_i,
  input  logic [XLEN-1:0]       wdata_i
);

  logic [XLEN-1:0] mem [NUM_REGS-1:0];

  // x0 is never written, whatever the caller asks for.
  logic we_qual;
  assign we_qual = we_i & (waddr_i != {REG_ADDR_W{1'b0}});

  always_ff @(posedge clk_i) begin
    if (we_qual) begin
      mem[waddr_i] <= wdata_i;
    end
  end

  // Write-first bypass, one per read port.
  logic bypass_a, bypass_b;
  assign bypass_a = we_qual & (waddr_i == raddr_a_i);
  assign bypass_b = we_qual & (waddr_i == raddr_b_i);

  always_comb begin
    if (raddr_a_i == {REG_ADDR_W{1'b0}}) begin
      rdata_a_o = {XLEN{1'b0}};
    end else if (bypass_a) begin
      rdata_a_o = wdata_i;
    end else begin
      rdata_a_o = mem[raddr_a_i];
    end
  end

  always_comb begin
    if (raddr_b_i == {REG_ADDR_W{1'b0}}) begin
      rdata_b_o = {XLEN{1'b0}};
    end else if (bypass_b) begin
      rdata_b_o = wdata_i;
    end else begin
      rdata_b_o = mem[raddr_b_i];
    end
  end

`ifndef SYNTHESIS
  // Simulation-only storage initialisation. Excluded from synthesis so the
  // array stays reset-free and RAM-inferable; present in simulation so that
  // reading an architecturally-undefined register gives a deterministic zero
  // instead of X, which keeps lockstep comparison against the golden ISS
  // meaningful from the first instruction.
  initial begin
    for (int unsigned i = 0; i < NUM_REGS; i++) begin
      mem[i] = {XLEN{1'b0}};
    end
  end
`endif

endmodule : regfile
