// ============================================================================
// decoder.sv
//
// RV32I_Zicsr instruction decoder. Purely combinational.
//
// Outputs are individual named ports rather than a packed `ctrl_t` struct so
// that the unit testbench can observe each control signal directly instead of
// depending on Verilator's packed-struct bit layout. The ID stage packs them
// into ctrl_t for the ID/EX pipeline register.
//
// DECODING IS EXHAUSTIVE AND CLOSED. Every 32-bit word either matches one of
// the encodings below or asserts illegal_instr_o -- there is no silent-NOP
// fallback. In particular:
//   * the M extension (funct7 = 0000001 under OP) is rejected, since this core
//     implements multiply and divide in software;
//   * compressed instructions (instr[1:0] != 2'b11) are rejected;
//   * reserved funct3 values within otherwise-valid opcodes are rejected
//     (e.g. LOAD funct3 = 3'b011, BRANCH funct3 = 3'b010);
//   * FENCE and FENCE.I decode to an architectural NOP rather than trapping,
//     because this core has no caches and no store buffer to order, but they
//     must not be treated as unknown either.
// ============================================================================

module decoder
  import e_core_pkg::*;
(
  input  logic [31:0]           instr_i,

  // Register operands
  output logic [REG_ADDR_W-1:0] rs1_addr_o,
  output logic [REG_ADDR_W-1:0] rs2_addr_o,
  output logic [REG_ADDR_W-1:0] rd_addr_o,
  // Whether the instruction actually reads each source register. The hazard
  // unit needs this: forwarding or stalling on an operand the instruction
  // never reads would cost correctness (a false load-use stall) or, worse,
  // hide a genuine one.
  output logic                  rs1_used_o,
  output logic                  rs2_used_o,

  // Immediate and ALU control
  output imm_sel_e              imm_sel_o,
  output alu_op_e               alu_op_o,
  output op_a_sel_e             op_a_sel_o,
  output op_b_sel_e             op_b_sel_o,

  // Writeback
  output logic                  rf_we_o,
  output wb_sel_e               wb_sel_o,

  // Data memory
  output logic                  mem_req_o,
  output logic                  mem_we_o,
  output mem_size_e             mem_size_o,
  output logic                  mem_signed_o,

  // Control transfer
  output logic                  is_branch_o,
  output logic [2:0]            br_op_o,      // br_op_e encoding == funct3
  output logic                  is_jump_o,    // JAL or JALR
  output logic                  is_jalr_o,    // JALR specifically

  // CSR access
  output logic                  csr_en_o,
  output csr_op_e               csr_op_o,
  output logic [CSR_ADDR_W-1:0] csr_addr_o,
  output logic                  csr_use_imm_o,  // operand is uimm, not rs1
  output logic                  csr_read_o,     // the CSR is actually read
  output logic                  csr_write_o,    // the CSR is actually written

  // System / privileged
  output logic                  ecall_o,
  output logic                  ebreak_o,
  output logic                  mret_o,
  output logic                  wfi_o,
  output logic                  fence_o,

  output logic                  illegal_instr_o
);

  // --------------------------------------------------------------------
  // Instruction field extraction
  // --------------------------------------------------------------------
  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [4:0] rs1_addr, rs2_addr, rd_addr;

  assign opcode   = instr_i[6:0];
  assign funct3   = instr_i[14:12];
  assign funct7   = instr_i[31:25];
  assign rs1_addr = instr_i[19:15];
  assign rs2_addr = instr_i[24:20];
  assign rd_addr  = instr_i[11:7];

  assign rs1_addr_o = rs1_addr;
  assign rs2_addr_o = rs2_addr;
  assign rd_addr_o  = rd_addr;
  assign csr_addr_o = instr_i[31:20];

  // A 32-bit RISC-V instruction always has instr[1:0] == 2'b11. Anything else
  // is a 16-bit compressed encoding, which this core does not implement.
  logic is_32bit_encoding;
  assign is_32bit_encoding = (instr_i[1:0] == 2'b11);

  // --------------------------------------------------------------------
  // Shared sub-decodes
  // --------------------------------------------------------------------
  // funct7 legality for register-register ALU ops: only 0000000 is allowed,
  // except SUB and SRA which use 0100000. 0000001 is the M extension.
  logic funct7_is_zero, funct7_is_alt;
  assign funct7_is_zero = (funct7 == F7_ZERO);
  assign funct7_is_alt  = (funct7 == F7_SUB);

  // ALU operation for the OP / OP-IMM group. `alt` selects SUB in place of ADD
  // and SRA in place of SRL; it is only ever set for encodings where the
  // legality checks below have already permitted funct7 = 0100000.
  function automatic alu_op_e AluFromFunct3(input logic [2:0] f3,
                                            input logic alt);
    unique case (f3)
      F3_SLL:     return ALU_SLL;
      F3_SLT:     return ALU_SLT;
      F3_SLTU:    return ALU_SLTU;
      F3_XOR:     return ALU_XOR;
      F3_SRL_SRA: return alt ? ALU_SRA : ALU_SRL;
      F3_OR:      return ALU_OR;
      F3_AND:     return ALU_AND;
      default:    return alt ? ALU_SUB : ALU_ADD;   // F3_ADD_SUB
    endcase
  endfunction

  // --------------------------------------------------------------------
  // Main decode
  // --------------------------------------------------------------------
  always_comb begin
    // Defaults: an instruction that matches nothing is illegal and has no
    // architectural side effects whatsoever. Every arm below overrides only
    // what it needs, so a missing assignment can never create a latch or
    // silently enable a write.
    rs1_used_o      = 1'b0;
    rs2_used_o      = 1'b0;
    imm_sel_o       = IMM_I;
    alu_op_o        = ALU_ADD;
    op_a_sel_o      = OP_A_RS1;
    op_b_sel_o      = OP_B_IMM;
    rf_we_o         = 1'b0;
    wb_sel_o        = WB_ALU;
    mem_req_o       = 1'b0;
    mem_we_o        = 1'b0;
    mem_size_o      = SZ_WORD;
    mem_signed_o    = 1'b0;
    is_branch_o     = 1'b0;
    br_op_o         = funct3;
    is_jump_o       = 1'b0;
    is_jalr_o       = 1'b0;
    csr_en_o        = 1'b0;
    csr_op_o        = CSR_OP_RW;
    csr_use_imm_o   = 1'b0;
    csr_read_o      = 1'b0;
    csr_write_o     = 1'b0;
    ecall_o         = 1'b0;
    ebreak_o        = 1'b0;
    mret_o          = 1'b0;
    wfi_o           = 1'b0;
    fence_o         = 1'b0;
    illegal_instr_o = 1'b0;

    if (!is_32bit_encoding) begin
      // 16-bit compressed encoding: not implemented.
      illegal_instr_o = 1'b1;
    end else begin
      unique case (opcode)

        // ---------------- LUI: rd = imm[31:12] << 12 ----------------
        OPCODE_LUI: begin
          imm_sel_o  = IMM_U;
          op_a_sel_o = OP_A_ZERO;
          op_b_sel_o = OP_B_IMM;
          alu_op_o   = ALU_ADD;
          rf_we_o    = 1'b1;
          wb_sel_o   = WB_ALU;
        end

        // ---------------- AUIPC: rd = pc + (imm[31:12] << 12) ------------
        OPCODE_AUIPC: begin
          imm_sel_o  = IMM_U;
          op_a_sel_o = OP_A_PC;
          op_b_sel_o = OP_B_IMM;
          alu_op_o   = ALU_ADD;
          rf_we_o    = 1'b1;
          wb_sel_o   = WB_ALU;
        end

        // ---------------- JAL: rd = pc+4, pc = pc + imm ----------------
        OPCODE_JAL: begin
          imm_sel_o = IMM_J;
          rf_we_o   = 1'b1;
          wb_sel_o  = WB_PC4;
          is_jump_o = 1'b1;
        end

        // ---------------- JALR: rd = pc+4, pc = (rs1 + imm) & ~1 --------
        OPCODE_JALR: begin
          if (funct3 != 3'b000) begin
            illegal_instr_o = 1'b1;
          end else begin
            imm_sel_o  = IMM_I;
            rs1_used_o = 1'b1;
            rf_we_o    = 1'b1;
            wb_sel_o   = WB_PC4;
            is_jump_o  = 1'b1;
            is_jalr_o  = 1'b1;
          end
        end

        // ---------------- BRANCH ----------------
        // funct3 3'b010 and 3'b011 are reserved and must trap.
        OPCODE_BRANCH: begin
          if (funct3 == 3'b010 || funct3 == 3'b011) begin
            illegal_instr_o = 1'b1;
          end else begin
            imm_sel_o   = IMM_B;
            rs1_used_o  = 1'b1;
            rs2_used_o  = 1'b1;
            is_branch_o = 1'b1;
            br_op_o     = funct3;
          end
        end

        // ---------------- LOAD ----------------
        OPCODE_LOAD: begin
          unique case (funct3)
            F3_LB, F3_LH, F3_LW, F3_LBU, F3_LHU: begin
              imm_sel_o    = IMM_I;
              rs1_used_o   = 1'b1;
              op_a_sel_o   = OP_A_RS1;
              op_b_sel_o   = OP_B_IMM;
              alu_op_o     = ALU_ADD;      // address = rs1 + imm
              rf_we_o      = 1'b1;
              wb_sel_o     = WB_MEM;
              mem_req_o    = 1'b1;
              mem_we_o     = 1'b0;
              // funct3[1:0] is the width field; funct3[2] clears sign extension
              // (LBU/LHU). The mapping is exact for all five legal encodings.
              mem_size_o   = mem_size_e'(funct3[1:0]);
              mem_signed_o = ~funct3[2];
            end
            default: illegal_instr_o = 1'b1;
          endcase
        end

        // ---------------- STORE ----------------
        OPCODE_STORE: begin
          unique case (funct3)
            F3_SB, F3_SH, F3_SW: begin
              imm_sel_o  = IMM_S;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;          // rs2 is the value being stored
              op_a_sel_o = OP_A_RS1;
              op_b_sel_o = OP_B_IMM;
              alu_op_o   = ALU_ADD;       // address = rs1 + imm
              rf_we_o    = 1'b0;
              mem_req_o  = 1'b1;
              mem_we_o   = 1'b1;
              mem_size_o = mem_size_e'(funct3[1:0]);
            end
            default: illegal_instr_o = 1'b1;
          endcase
        end

        // ---------------- OP-IMM ----------------
        OPCODE_OP_IMM: begin
          imm_sel_o  = IMM_I;
          rs1_used_o = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_IMM;
          rf_we_o    = 1'b1;
          wb_sel_o   = WB_ALU;
          // Only SRAI may be selected by instr[31:25]. For every other OP-IMM
          // encoding those bits are the top of the 12-bit immediate, NOT a
          // funct7: ADDI with an immediate whose bits 11:5 happen to equal
          // 0100000 (i.e. any immediate in [-2048,-1985]) is still an add.
          // Gating on funct3 here rather than passing funct7_is_alt straight
          // through is what keeps that case correct.
          alu_op_o   = AluFromFunct3(funct3,
                                     funct7_is_alt && (funct3 == F3_SRL_SRA));

          // The shift-immediate encodings carry a 5-bit shamt in instr[24:20]
          // and a fixed funct7. SLLI and SRLI require 0000000; SRAI requires
          // 0100000. Any other funct7 (including the M-extension value) is a
          // reserved encoding and must trap, so it is checked here rather than
          // being masked off and ignored.
          if (funct3 == F3_SLL) begin
            if (!funct7_is_zero) illegal_instr_o = 1'b1;
          end else if (funct3 == F3_SRL_SRA) begin
            if (!(funct7_is_zero || funct7_is_alt)) illegal_instr_o = 1'b1;
          end
          // The non-shift OP-IMM encodings use the whole instr[31:20] as an
          // immediate, so no funct7 check applies to them.
        end

        // ---------------- OP (register-register) ----------------
        OPCODE_OP: begin
          rs1_used_o = 1'b1;
          rs2_used_o = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_RS2;
          rf_we_o    = 1'b1;
          wb_sel_o   = WB_ALU;
          alu_op_o   = AluFromFunct3(funct3, funct7_is_alt);

          // Only ADD/SUB and SRL/SRA may use funct7 = 0100000. Everything else
          // demands 0000000. funct7 = 0000001 is the M extension and lands in
          // the else-branch below, which is exactly the required behaviour:
          // MUL, MULH, DIV, REM and friends raise illegal-instruction.
          if (funct7_is_alt) begin
            if (!(funct3 == F3_ADD_SUB || funct3 == F3_SRL_SRA)) begin
              illegal_instr_o = 1'b1;
            end
          end else if (!funct7_is_zero) begin
            illegal_instr_o = 1'b1;
          end
        end

        // ---------------- MISC-MEM: FENCE / FENCE.I ----------------
        // No caches and no store buffer exist at this stage, so both are
        // architecturally correct as a NOP. They must not trap.
        OPCODE_MISC_MEM: begin
          unique case (funct3)
            F3_FENCE, F3_FENCE_I: fence_o = 1'b1;
            default:              illegal_instr_o = 1'b1;
          endcase
        end

        // ---------------- SYSTEM: privileged ops and Zicsr ----------------
        OPCODE_SYSTEM: begin
          if (funct3 == F3_PRIV) begin
            // The privileged instructions are fully-specified 32-bit words:
            // every field outside the opcode is fixed, so compare the whole
            // instruction rather than decoding fields that must be zero.
            unique case (instr_i)
              INSN_ECALL:  ecall_o  = 1'b1;
              INSN_EBREAK: ebreak_o = 1'b1;
              INSN_MRET:   mret_o   = 1'b1;
              INSN_WFI:    wfi_o    = 1'b1;
              default:     illegal_instr_o = 1'b1;
            endcase
          end else begin
            unique case (funct3)
              F3_CSRRW, F3_CSRRS, F3_CSRRC,
              F3_CSRRWI, F3_CSRRSI, F3_CSRRCI: begin
                csr_en_o      = 1'b1;
                rf_we_o       = 1'b1;
                wb_sel_o      = WB_CSR;
                imm_sel_o     = IMM_Z;
                // funct3[2] distinguishes the immediate forms; funct3[1:0]
                // selects read-write, read-set or read-clear.
                csr_use_imm_o = funct3[2];
                rs1_used_o    = ~funct3[2];

                unique case (funct3[1:0])
                  2'b01:   csr_op_o = CSR_OP_RW;
                  2'b10:   csr_op_o = CSR_OP_RS;
                  default: csr_op_o = CSR_OP_RC;   // 2'b11
                endcase

                // Read/write side effects, per the Zicsr chapter:
                //  * CSRRW/CSRRWI write unconditionally, and read only when
                //    rd != x0;
                //  * CSRRS/CSRRC/CSRRSI/CSRRCI read unconditionally, and write
                //    only when the source operand (rs1 or uimm) is non-zero.
                // This distinction is not cosmetic: a CSRRS with rs1 = x0
                // targeting a read-only CSR is legal, while a CSRRW to the
                // same CSR is not.
                if (funct3[1:0] == 2'b01) begin
                  csr_write_o = 1'b1;
                  csr_read_o  = (rd_addr != 5'd0);
                end else begin
                  csr_read_o  = 1'b1;
                  csr_write_o = (rs1_addr != 5'd0);
                end
              end
              default: illegal_instr_o = 1'b1;   // funct3 == 3'b100
            endcase
          end
        end

        // ---------------- everything else ----------------
        default: illegal_instr_o = 1'b1;

      endcase
    end

    // An illegal instruction must have no architectural effect at all: the
    // trap replaces it. Squashing here rather than in each arm above means a
    // future decode addition cannot forget to do it.
    if (illegal_instr_o) begin
      rf_we_o     = 1'b0;
      mem_req_o   = 1'b0;
      mem_we_o    = 1'b0;
      is_branch_o = 1'b0;
      is_jump_o   = 1'b0;
      is_jalr_o   = 1'b0;
      csr_en_o    = 1'b0;
      csr_read_o  = 1'b0;
      csr_write_o = 1'b0;
      ecall_o     = 1'b0;
      ebreak_o    = 1'b0;
      mret_o      = 1'b0;
      wfi_o       = 1'b0;
      fence_o     = 1'b0;
      rs1_used_o  = 1'b0;
      rs2_used_o  = 1'b0;
    end
  end

endmodule : decoder
