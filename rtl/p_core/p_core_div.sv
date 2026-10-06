// ============================================================================
// p_core_div.sv — iterative restoring divider, one quotient bit per cycle.
//
// Implements DIV, DIVU, REM and REMU.
//
// ---------------------------------------------------------------------------
// ALGORITHM
// ---------------------------------------------------------------------------
// Signed operations divide the magnitudes and fix the signs afterwards: the
// quotient is negative when exactly one operand is, the remainder takes the
// sign of the dividend. The core loop is plain unsigned restoring division:
//
//   repeat 32 times:
//     r = (r << 1) | next dividend bit
//     if r >= divisor: r -= divisor, quotient bit = 1  else quotient bit = 0
//
// The dividend register doubles as the quotient register: each iteration
// shifts one dividend bit out of the top and one quotient bit in at the
// bottom.
//
// The two special cases the ISA defines fall out of this with one exception:
//   * division by zero: the loop yields all-ones and the dividend's magnitude,
//     so REM/REMU get the dividend back after the sign fix, as required. The
//     quotient must be all-ones regardless of sign, which the sign fix would
//     break for a negative dividend, so it is forced.
//   * overflow (-2^31 / -1): magnitudes 2^31 / 1 give quotient 2^31 and
//     remainder 0; the signs agree so neither is negated, and 0x8000_0000 is
//     exactly the required quotient.
//
// ---------------------------------------------------------------------------
// TIMING
// ---------------------------------------------------------------------------
// The first cycle takes the operand magnitudes; the 32 iterations follow, and
// the result is available combinationally during the last. An operation
// therefore occupies EX for 33 cycles. It can be abandoned at any point with
// kill_i -- which is what makes a divide interruptible: an interrupt taken on
// the instruction ahead of it in MEM flushes EX, and the divide restarts from
// scratch after the handler returns.
//
// The handshake (start_i / done_o / ack_i / kill_i) is identical to
// p_core_mul's; see that file.
// ============================================================================

module p_core_div
  import e_core_pkg::*;
  import p_core_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        start_i,
  input  logic        kill_i,
  input  logic        ack_i,
  input  logic [1:0]  op_i,        // md_op_e[1:0]: DIV, DIVU, REM, REMU
  input  logic [31:0] a_i,         // dividend
  input  logic [31:0] b_i,         // divisor

  output logic        done_o,
  output logic [31:0] result_o
);

  // md_op_e[1:0] within the divide group: bit 0 = unsigned, bit 1 = remainder.
  logic op_signed, op_rem;
  assign op_signed = ~op_i[0];
  assign op_rem    =  op_i[1];

  // --------------------------------------------------------------------
  // State
  // --------------------------------------------------------------------
  logic        busy_q;
  logic [4:0]  cnt_q;
  logic [31:0] quo_q;      // dividend bits still to shift out / quotient in
  logic [31:0] rem_q;
  logic [31:0] divisor_q;
  logic        q_neg_q, r_neg_q, div_zero_q, rem_op_q;
  logic        done_q;
  logic [31:0] result_q;

  logic first, last;
  assign first = start_i & ~busy_q & ~done_q & ~kill_i;
  assign last  = busy_q & (cnt_q == 5'd31);

  // --------------------------------------------------------------------
  // Setup: magnitudes and result signs
  // --------------------------------------------------------------------
  logic a_neg, b_neg;
  assign a_neg = op_signed & a_i[31];
  assign b_neg = op_signed & b_i[31];

  logic [31:0] a_mag, b_mag;
  assign a_mag = a_neg ? (32'd0 - a_i) : a_i;
  assign b_mag = b_neg ? (32'd0 - b_i) : b_i;

  // --------------------------------------------------------------------
  // One restoring step
  // --------------------------------------------------------------------
  logic [32:0] rem_shift;
  logic [31:0] rem_diff;
  logic        rem_ge;
  logic [31:0] rem_next, quo_next;

  assign rem_shift = {rem_q, quo_q[31]};
  assign rem_ge    = (rem_shift >= {1'b0, divisor_q});
  // Either way the new remainder is below the divisor, so it fits 32 bits,
  // and the subtraction can be done at 32 bits: when rem_ge holds, the true
  // difference is below 2^32 and its low word is exact.
  assign rem_diff  = rem_shift[31:0] - divisor_q;
  assign rem_next  = rem_ge ? rem_diff : rem_shift[31:0];
  assign quo_next  = {quo_q[30:0], rem_ge};

  // --------------------------------------------------------------------
  // Result, from the final step
  // --------------------------------------------------------------------
  logic [31:0] quotient, remainder, result_now;
  assign quotient   = div_zero_q ? 32'hFFFF_FFFF
                                 : (q_neg_q ? (32'd0 - quo_next) : quo_next);
  assign remainder  = r_neg_q ? (32'd0 - rem_next) : rem_next;
  assign result_now = rem_op_q ? remainder : quotient;

  assign done_o   = last | done_q;
  assign result_o = done_q ? result_q : result_now;

  // --------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q     <= 1'b0;
      cnt_q      <= 5'd0;
      quo_q      <= 32'd0;
      rem_q      <= 32'd0;
      divisor_q  <= 32'd0;
      q_neg_q    <= 1'b0;
      r_neg_q    <= 1'b0;
      div_zero_q <= 1'b0;
      rem_op_q   <= 1'b0;
      done_q     <= 1'b0;
      result_q   <= 32'd0;
    end else if (kill_i) begin
      busy_q     <= 1'b0;
      done_q     <= 1'b0;
    end else if (first) begin
      busy_q     <= 1'b1;
      cnt_q      <= 5'd0;
      quo_q      <= a_mag;
      rem_q      <= 32'd0;
      divisor_q  <= b_mag;
      q_neg_q    <= a_neg ^ b_neg;
      r_neg_q    <= a_neg;
      div_zero_q <= (b_i == 32'd0);
      rem_op_q   <= op_rem;
    end else if (last) begin
      busy_q     <= 1'b0;
      done_q     <= ~ack_i;
      result_q   <= result_now;
    end else if (busy_q) begin
      cnt_q      <= cnt_q + 5'd1;
      quo_q      <= quo_next;
      rem_q      <= rem_next;
    end else if (done_q && ack_i) begin
      done_q     <= 1'b0;
    end
  end

endmodule : p_core_div
