// ============================================================================
// alu.sv
//
// RV32I arithmetic/logic unit. Purely combinational.
//
// Area notes (this core targets < 5K LUTs):
//  * ADD, SUB, SLT and SLTU share ONE 33-bit adder. SUB/SLT/SLTU drive the
//    adder as a - b by inverting b and forcing carry-in; the comparison
//    results are then read out of that same subtraction rather than needing
//    dedicated comparators.
//  * SLL, SRL and SRA share ONE 33-bit right-shift barrel shifter. A left
//    shift is performed by bit-reversing the operand into the shifter and
//    bit-reversing the result on the way out, which costs wiring rather than
//    a second shifter.
// ============================================================================

module alu
  import e_core_pkg::*;
(
  input  alu_op_e           operator_i,
  input  logic [XLEN-1:0]   operand_a_i,
  input  logic [XLEN-1:0]   operand_b_i,

  output logic [XLEN-1:0]   result_o,
  // Comparison outputs, exported so the ID stage's branch comparator can be
  // built from an instance of this same adder rather than a second one.
  output logic              cmp_eq_o,
  output logic              cmp_lt_o,    // signed   operand_a <  operand_b
  output logic              cmp_ltu_o    // unsigned operand_a <  operand_b
);

  // --------------------------------------------------------------------
  // Shared adder: computes a + b, or a - b when `do_sub` is set.
  // --------------------------------------------------------------------
  logic                do_sub;
  logic [XLEN-1:0]     adder_b;
  logic [XLEN:0]       adder_result;

  always_comb begin
    unique case (operator_i)
      ALU_SUB, ALU_SLT, ALU_SLTU: do_sub = 1'b1;
      default:                    do_sub = 1'b0;
    endcase
  end

  assign adder_b      = do_sub ? ~operand_b_i : operand_b_i;
  // The extra bit captures carry-out, which is the unsigned comparison result.
  assign adder_result = {1'b0, operand_a_i} + {1'b0, adder_b} + {{XLEN{1'b0}}, do_sub};

  // --------------------------------------------------------------------
  // Comparisons, derived from the same subtraction.
  //  * equal            : the difference is zero
  //  * unsigned less-than: no carry out of a + ~b + 1  (i.e. a borrow occurred)
  //  * signed less-than : differing sign bits => a is smaller iff a is negative;
  //                       equal sign bits => the difference's sign bit decides
  // --------------------------------------------------------------------
  logic diff_is_zero;
  logic signs_differ;

  assign diff_is_zero = (adder_result[XLEN-1:0] == {XLEN{1'b0}});
  assign signs_differ = operand_a_i[XLEN-1] ^ operand_b_i[XLEN-1];

  assign cmp_eq_o  = diff_is_zero;
  assign cmp_ltu_o = ~adder_result[XLEN];
  assign cmp_lt_o  = signs_differ ? operand_a_i[XLEN-1] : adder_result[XLEN-1];

  // --------------------------------------------------------------------
  // Shared right-shift barrel shifter.
  // The 33rd bit carries the sign for SRA and is zero otherwise, so one
  // arithmetic right shift covers SRL and SRA both.
  // --------------------------------------------------------------------
  logic            shift_left;
  logic            shift_arith;
  logic [4:0]      shift_amt;
  logic [XLEN-1:0] shift_operand;
  logic [XLEN:0]   shift_input;
  logic [XLEN-1:0] shift_result;

  assign shift_left  = (operator_i == ALU_SLL);
  assign shift_arith = (operator_i == ALU_SRA);
  assign shift_amt   = operand_b_i[4:0];

  assign shift_operand = shift_left ? rev32(operand_a_i) : operand_a_i;
  assign shift_input   = {shift_arith & shift_operand[XLEN-1], shift_operand};
  // The 33-bit shift produces a redundant MSB (it only ever reproduces the
  // sign bit at shift amount zero), so the size cast discards it explicitly
  // rather than leaving a partially-unused signal behind.
  assign shift_result  = XLEN'($signed(shift_input) >>> shift_amt);

  // --------------------------------------------------------------------
  // Result mux. ALU_ADD is encoded 4'b1111 precisely so that it lands here on
  // `default`, keeping that arm live for coverage.
  // --------------------------------------------------------------------
  always_comb begin
    unique case (operator_i)
      ALU_SUB:  result_o = adder_result[XLEN-1:0];
      ALU_SLL:  result_o = rev32(shift_result);
      ALU_SRL,
      ALU_SRA:  result_o = shift_result;
      ALU_SLT:  result_o = {{(XLEN-1){1'b0}}, cmp_lt_o};
      ALU_SLTU: result_o = {{(XLEN-1){1'b0}}, cmp_ltu_o};
      ALU_XOR:  result_o = operand_a_i ^ operand_b_i;
      ALU_OR:   result_o = operand_a_i | operand_b_i;
      ALU_AND:  result_o = operand_a_i & operand_b_i;
      default:  result_o = adder_result[XLEN-1:0];   // ALU_ADD
    endcase
  end

endmodule : alu
