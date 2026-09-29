// ============================================================================
// p_core_mul.sv — iterative radix-4 Booth multiplier, 4 cycles.
//
// Implements MUL, MULH, MULHSU and MULHU. Every variant is the same 64-bit
// product; they differ only in how each operand is extended and which half is
// returned:
//
//   op       rs1       rs2       result
//   MUL      signed    signed    product[31:0]   (identical for any signedness)
//   MULH     signed    signed    product[63:32]
//   MULHSU   signed    unsigned  product[63:32]
//   MULHU    unsigned  unsigned  product[63:32]
//
// ---------------------------------------------------------------------------
// ALGORITHM
// ---------------------------------------------------------------------------
// The multiplicand a is extended to 64 bits (sign- or zero-). The multiplier
// b is radix-4 Booth recoded AS A SIGNED 32-BIT NUMBER into 16 digits in
// {-2,-1,0,+1,+2}, digit i taken from bits {b[2i+1], b[2i], b[2i-1]} with
// b[-1] = 0. The product is sum(digit_i * a * 4^i) modulo 2^64.
//
// An unsigned b with its top bit set is worth 2^32 more than its signed
// reading, so for MULHSU/MULHU that correction, a << 32, is loaded into the
// accumulator as its starting value. The Booth datapath itself therefore only
// ever sees a signed multiplier.
//
// Four digits are consumed per cycle, so the 16 digits take exactly 4 cycles:
// the first iteration runs in the cycle the operation starts, straight from
// the operands, and the product is available combinationally in the fourth.
//
// ---------------------------------------------------------------------------
// HANDSHAKE WITH EX
// ---------------------------------------------------------------------------
//   start_i  EX holds a valid multiply. Sampled only when the unit is idle.
//   done_o   the result is on result_o this cycle.
//   ack_i    EX has passed the result on (the instruction leaves EX).
//   kill_i   the instruction in EX is flushed: abandon the operation.
//
// If EX cannot pass the result on in the cycle it appears (MEM is busy), the
// result is held in result_q and done_o stays high until ack_i. Operands are
// captured when the operation starts, so the forwarded values in EX may be
// refreshed underneath a running operation without affecting it.
// ============================================================================

module p_core_mul
  import e_core_pkg::*;
  import p_core_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        start_i,
  input  logic        kill_i,
  input  logic        ack_i,
  input  logic [1:0]  op_i,        // md_op_e[1:0]: MUL, MULH, MULHSU, MULHU
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,

  output logic        done_o,
  output logic [31:0] result_o
);

  // --------------------------------------------------------------------
  // Operand extension, from md_op_e[1:0]. The comparisons are made on the
  // full 3-bit operation (multiplies have bit 2 clear) rather than on a
  // part-select of the enum constants, which sv2v would lower into a
  // part-select of a literal -- legal SystemVerilog, but not Verilog-2005.
  // --------------------------------------------------------------------
  md_op_e op;
  assign op = md_op_e'({1'b0, op_i});

  logic a_signed, b_signed;
  assign a_signed = (op != MD_MULHU);                    // MUL MULH MULHSU
  assign b_signed = (op == MD_MUL) | (op == MD_MULH);

  logic [63:0] a_ext;
  logic [63:0] correction;
  assign a_ext      = {{32{a_signed & a_i[31]}}, a_i};
  assign correction = (~b_signed & b_i[31]) ? {a_ext[31:0], 32'd0} : 64'd0;

  // --------------------------------------------------------------------
  // State
  // --------------------------------------------------------------------
  logic        busy_q;
  logic [1:0]  cnt_q;         // iteration now in progress while busy
  logic [63:0] acc_q;
  logic [63:0] mcand_q;       // multiplicand, pre-shifted to the next digit
  logic [32:0] mplier_q;      // remaining multiplier bits; [0] is b[2i-1]
  logic        hi_q;          // return the upper word
  logic        done_q;
  logic [31:0] result_q;

  logic first, last;
  assign first = start_i & ~busy_q & ~done_q & ~kill_i;
  assign last  = busy_q & (cnt_q == 2'd3);

  // --------------------------------------------------------------------
  // One iteration: four Booth digits
  // --------------------------------------------------------------------
  logic [63:0] src_acc, src_mcand;
  logic [32:0] src_mplier;

  assign src_acc    = first ? correction    : acc_q;
  assign src_mcand  = first ? a_ext         : mcand_q;
  assign src_mplier = first ? {b_i, 1'b0}   : mplier_q;

  // Booth partial product for one digit, given the three recoding bits and
  // the multiplicand already shifted into that digit's position.
  function automatic logic [63:0] booth_pp(input logic [2:0] bits,
                                           input logic [63:0] m);
    unique case (bits)
      3'b001, 3'b010: booth_pp = m;               // +1
      3'b011:         booth_pp = m << 1;          // +2
      3'b100:         booth_pp = -(m << 1);       // -2
      3'b101, 3'b110: booth_pp = -m;              // -1
      default:        booth_pp = 64'd0;           // 000, 111
    endcase
  endfunction

  logic [63:0] pp0, pp1, pp2, pp3, acc_next;
  assign pp0 = booth_pp(src_mplier[2:0], src_mcand);
  assign pp1 = booth_pp(src_mplier[4:2], src_mcand << 2);
  assign pp2 = booth_pp(src_mplier[6:4], src_mcand << 4);
  assign pp3 = booth_pp(src_mplier[8:6], src_mcand << 6);
  assign acc_next = src_acc + pp0 + pp1 + pp2 + pp3;

  logic [31:0] result_now;
  assign result_now = hi_q ? acc_next[63:32] : acc_next[31:0];

  assign done_o   = last | done_q;
  assign result_o = done_q ? result_q : result_now;

  // --------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q   <= 1'b0;
      cnt_q    <= 2'd0;
      acc_q    <= 64'd0;
      mcand_q  <= 64'd0;
      mplier_q <= 33'd0;
      hi_q     <= 1'b0;
      done_q   <= 1'b0;
      result_q <= 32'd0;
    end else if (kill_i) begin
      busy_q   <= 1'b0;
      done_q   <= 1'b0;
    end else if (first) begin
      busy_q   <= 1'b1;
      cnt_q    <= 2'd1;
      acc_q    <= acc_next;
      mcand_q  <= src_mcand << 8;
      mplier_q <= src_mplier >> 8;
      hi_q     <= (op != MD_MUL);
    end else if (last) begin
      busy_q   <= 1'b0;
      // Hold the result if EX cannot hand it on this cycle.
      done_q   <= ~ack_i;
      result_q <= result_now;
    end else if (busy_q) begin
      cnt_q    <= cnt_q + 2'd1;
      acc_q    <= acc_next;
      mcand_q  <= src_mcand << 8;
      mplier_q <= src_mplier >> 8;
    end else if (done_q && ack_i) begin
      done_q   <= 1'b0;
    end
  end

endmodule : p_core_mul
