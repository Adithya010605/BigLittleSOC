// ============================================================================
// lsu.sv
//
// Load/store alignment unit. Purely combinational; it owns every byte-lane
// decision in the core so that no stage logic has to reason about addresses
// modulo four.
//
// Responsibilities:
//   * byte-enable generation for stores      (be_o)
//   * store-data lane placement              (wdata_aligned_o)
//   * load-data lane extraction plus sign or zero extension (rdata_ext_o)
//   * misalignment detection                 (misaligned_o)
//
// The data memory port is word-addressed with byte enables, so a sub-word
// store places its data in the addressed lane by replicating it across the
// word: every lane that `be_o` enables then holds the correct bytes, and the
// lanes it does not enable are ignored by the memory. Replication is cheaper
// than a shifter and gives the same result.
//
// Misaligned accesses are NOT fixed up in hardware. A word access must be
// 4-byte aligned and a halfword access 2-byte aligned; anything else asserts
// misaligned_o, and the trap unit turns that into a load or store address
// misaligned exception (mcause 4 or 6). This matches the spec decision to
// trap rather than to split the access into multiple bus transactions.
// ============================================================================

module lsu
  import e_core_pkg::*;
(
  // Request description, from the decoded instruction in S3
  input  mem_size_e       size_i,
  input  logic            sign_i,        // 1 = sign-extend a sub-word load
  input  logic [1:0]      addr_lsb_i,    // low two bits of the byte address
  input  logic [XLEN-1:0] wdata_i,       // rs2, the value being stored

  // To the data memory port
  output logic [3:0]      be_o,
  output logic [XLEN-1:0] wdata_aligned_o,

  // From the data memory port
  input  logic [XLEN-1:0] rdata_i,
  output logic [XLEN-1:0] rdata_ext_o,

  output logic            misaligned_o
);

  // --------------------------------------------------------------------
  // Byte enables.
  // SZ_WORD is placed on `default` so that the arm is exercised by ordinary
  // word accesses rather than being unreachable code; the encoding 2'b11 is
  // never produced by the decoder and is treated as a word access here.
  // --------------------------------------------------------------------
  always_comb begin
    unique case (size_i)
      SZ_BYTE: be_o = 4'b0001 << addr_lsb_i;
      SZ_HALF: be_o = addr_lsb_i[1] ? 4'b1100 : 4'b0011;
      default: be_o = 4'b1111;   // SZ_WORD
    endcase
  end

  // --------------------------------------------------------------------
  // Store data placement by replication.
  // --------------------------------------------------------------------
  always_comb begin
    unique case (size_i)
      SZ_BYTE: wdata_aligned_o = {4{wdata_i[7:0]}};
      SZ_HALF: wdata_aligned_o = {2{wdata_i[15:0]}};
      default: wdata_aligned_o = wdata_i;   // SZ_WORD
    endcase
  end

  // --------------------------------------------------------------------
  // Load data extraction and extension.
  // --------------------------------------------------------------------
  logic [7:0]  byte_sel;
  logic [15:0] half_sel;

  always_comb begin
    unique case (addr_lsb_i)
      2'b00:   byte_sel = rdata_i[7:0];
      2'b01:   byte_sel = rdata_i[15:8];
      2'b10:   byte_sel = rdata_i[23:16];
      default: byte_sel = rdata_i[31:24];   // 2'b11
    endcase
  end

  assign half_sel = addr_lsb_i[1] ? rdata_i[31:16] : rdata_i[15:0];

  always_comb begin
    unique case (size_i)
      SZ_BYTE: rdata_ext_o = {{24{sign_i & byte_sel[7]}}, byte_sel};
      SZ_HALF: rdata_ext_o = {{16{sign_i & half_sel[15]}}, half_sel};
      default: rdata_ext_o = rdata_i;   // SZ_WORD: no extension needed
    endcase
  end

  // --------------------------------------------------------------------
  // Misalignment. Byte accesses can never be misaligned.
  // --------------------------------------------------------------------
  always_comb begin
    unique case (size_i)
      SZ_BYTE: misaligned_o = 1'b0;
      SZ_HALF: misaligned_o = addr_lsb_i[0];
      default: misaligned_o = |addr_lsb_i;   // SZ_WORD
    endcase
  end

endmodule : lsu
