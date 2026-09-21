// ============================================================================
// imm_gen.sv
//
// RV32I immediate extraction. Purely combinational: given an instruction word
// and the format selected by the decoder, produce the sign-extended (or, for
// the CSR uimm, zero-extended) 32-bit immediate.
//
// Encodings, from the RISC-V unprivileged spec:
//   I  imm[11:0]  = instr[31:20]                       sign-extended
//   S  imm[11:0]  = instr[31:25] | instr[11:7]         sign-extended
//   B  imm[12:1]  = instr[31] | instr[7] | instr[30:25] | instr[11:8]
//                   with imm[0] implicitly 0           sign-extended
//   U  imm[31:12] = instr[31:12] with imm[11:0] = 0
//   J  imm[20:1]  = instr[31] | instr[19:12] | instr[20] | instr[30:21]
//                   with imm[0] implicitly 0           sign-extended
//   Z  imm[4:0]   = instr[19:15]                       zero-extended (CSR uimm)
//
// The B and J formats carry no bit 0: branch and jump targets are always
// 2-byte aligned, so the encoding reuses that bit position and the hardware
// supplies the zero. Getting this wrong halves every branch displacement,
// which is why tb_regfile-style random comparison against an independent
// model is used here rather than a handful of directed vectors.
// ============================================================================

module imm_gen
  import e_core_pkg::*;
(
  // Only instr[31:7] participates in any immediate format; the opcode field
  // is consumed by the decoder alone. Taking the narrowed slice as the port
  // keeps this module free of bits it does not use.
  input  logic [31:7]     instr_i,
  input  imm_sel_e        imm_sel_i,
  output logic [XLEN-1:0] imm_o
);

  logic [XLEN-1:0] imm_i_type;
  logic [XLEN-1:0] imm_s_type;
  logic [XLEN-1:0] imm_b_type;
  logic [XLEN-1:0] imm_u_type;
  logic [XLEN-1:0] imm_j_type;
  logic [XLEN-1:0] imm_z_type;

  assign imm_i_type = {{20{instr_i[31]}}, instr_i[31:20]};
  assign imm_s_type = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
  assign imm_b_type = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                       instr_i[30:25], instr_i[11:8], 1'b0};
  assign imm_u_type = {instr_i[31:12], 12'b0};
  assign imm_j_type = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                       instr_i[20], instr_i[30:21], 1'b0};
  assign imm_z_type = {27'b0, instr_i[19:15]};

  always_comb begin
    unique case (imm_sel_i)
      IMM_S:   imm_o = imm_s_type;
      IMM_B:   imm_o = imm_b_type;
      IMM_U:   imm_o = imm_u_type;
      IMM_J:   imm_o = imm_j_type;
      IMM_Z:   imm_o = imm_z_type;
      default: imm_o = imm_i_type;   // IMM_I, and the unused encodings 6 and 7
    endcase
  end

endmodule : imm_gen
