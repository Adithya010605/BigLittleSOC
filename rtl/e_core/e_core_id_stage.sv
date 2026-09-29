// ============================================================================
// e_core_id_stage.sv  —  Stage S2: decode, register read, branch resolution
//
// Purely combinational apart from the register file it instantiates. The ID/EX
// pipeline register lives in the EX stage, so this module describes what the
// instruction in IF/ID *would* do, and the hazard unit decides whether it
// advances.
//
// ---------------------------------------------------------------------------
// BRANCHES AND JUMPS RESOLVE HERE, NOT IN EX
// ---------------------------------------------------------------------------
// The comparator and the target adder in this stage are dedicated hardware,
// separate from the main ALU in S3. That is deliberate: resolving a branch in
// S2 means only the instruction in S1 is on the wrong path, so a taken branch
// costs one flushed cycle. Resolving it in S3 instead would reuse the main ALU
// and save a comparator and an adder, but two instructions would then be
// wrong-path and every taken branch would cost two cycles. With static
// not-taken prediction and no BTB, taken branches are common enough that the
// second adder is worth its area. The trade-off is written up in
// docs/e_core_microarchitecture.md.
//
// ---------------------------------------------------------------------------
// FORWARDING
// ---------------------------------------------------------------------------
// The operand muxes select between the register file output and the S3 result.
// They feed the ALU operands, the store data, the branch comparator AND the
// JALR target adder — a branch or a JALR that depends on the immediately
// preceding instruction is exactly the case that would otherwise read a stale
// register, and it is resolved in this stage where the forwarded value is
// needed earliest.
// ============================================================================

module e_core_id_stage
  import e_core_pkg::*;
(
  input  logic                  clk_i,

  // ---- from IF ----
  input  logic                  ifid_valid_i,
  input  logic [31:0]           ifid_pc_i,
  input  logic [31:0]           ifid_instr_i,

  // ---- forwarding from S3 ----
  input  logic                  fwd_rs1_i,      // 1 = take ex_result_i
  input  logic                  fwd_rs2_i,
  input  logic [31:0]           ex_result_i,

  // ---- register file write port, driven by S3 ----
  input  logic                  rf_we_i,
  input  logic [REG_ADDR_W-1:0] rf_waddr_i,
  input  logic [31:0]           rf_wdata_i,

  // ---- to the hazard unit ----
  output logic [REG_ADDR_W-1:0] rs1_addr_o,
  output logic [REG_ADDR_W-1:0] rs2_addr_o,
  output logic                  rs1_used_o,
  output logic                  rs2_used_o,

  // ---- to the ID/EX register ----
  output ctrl_t                 ctrl_o,
  output logic [REG_ADDR_W-1:0] rd_addr_o,
  output logic [31:0]           rs1_data_o,     // forwarded
  output logic [31:0]           rs2_data_o,     // forwarded
  output logic [31:0]           imm_o,
  output logic [CSR_ADDR_W-1:0] csr_addr_o,
  output logic                  csr_use_imm_o,

  // ---- control transfer, resolved in this stage ----
  output logic                  take_branch_o,  // jump, or branch with the
                                                // condition true; NOT yet
                                                // qualified by whether the
                                                // instruction advances
  output logic [31:0]           branch_target_o,
  output logic                  is_branch_o,    // for the perf counters
  output logic                  fence_o
);

  // --------------------------------------------------------------------
  // Decode
  // --------------------------------------------------------------------
  imm_sel_e   imm_sel;
  alu_op_e    alu_op;
  op_a_sel_e  op_a_sel;
  op_b_sel_e  op_b_sel;
  logic       rf_we;
  wb_sel_e    wb_sel;
  logic       mem_req, mem_we;
  mem_size_e  mem_size;
  logic       mem_signed;
  logic       is_branch, is_jump, is_jalr;
  logic [2:0] br_op;
  logic       csr_en;
  csr_op_e    csr_op;
  logic       csr_read, csr_write;
  logic       ecall, ebreak, mret, wfi, fence, fence_i;
  logic       md_en;
  logic [2:0] md_op;
  logic       illegal_instr;

  // RV32M = 0: this core has no multiplier or divider, so the decoder rejects
  // the M extension and md_en is constant zero.
  decoder #(
    .RV32M (1'b0)
  ) u_decoder (
    .instr_i         (ifid_instr_i),
    .rs1_addr_o      (rs1_addr_o),
    .rs2_addr_o      (rs2_addr_o),
    .rd_addr_o       (rd_addr_o),
    .rs1_used_o      (rs1_used_o),
    .rs2_used_o      (rs2_used_o),
    .imm_sel_o       (imm_sel),
    .alu_op_o        (alu_op),
    .op_a_sel_o      (op_a_sel),
    .op_b_sel_o      (op_b_sel),
    .rf_we_o         (rf_we),
    .wb_sel_o        (wb_sel),
    .mem_req_o       (mem_req),
    .mem_we_o        (mem_we),
    .mem_size_o      (mem_size),
    .mem_signed_o    (mem_signed),
    .is_branch_o     (is_branch),
    .br_op_o         (br_op),
    .is_jump_o       (is_jump),
    .is_jalr_o       (is_jalr),
    .csr_en_o        (csr_en),
    .csr_op_o        (csr_op),
    .csr_addr_o      (csr_addr_o),
    .csr_use_imm_o   (csr_use_imm_o),
    .csr_read_o      (csr_read),
    .csr_write_o     (csr_write),
    .md_en_o         (md_en),
    .md_op_o         (md_op),
    .ecall_o         (ecall),
    .ebreak_o        (ebreak),
    .mret_o          (mret),
    .wfi_o           (wfi),
    .fence_o         (fence),
    .fence_i_o       (fence_i),
    .illegal_instr_o (illegal_instr)
  );

  assign ctrl_o.alu_op     = alu_op;
  assign ctrl_o.op_a_sel   = op_a_sel;
  assign ctrl_o.op_b_sel   = op_b_sel;
  assign ctrl_o.wb_sel     = wb_sel;
  assign ctrl_o.rf_we      = rf_we;
  assign ctrl_o.mem_req    = mem_req;
  assign ctrl_o.mem_we     = mem_we;
  assign ctrl_o.mem_size   = mem_size;
  assign ctrl_o.mem_signed = mem_signed;
  assign ctrl_o.csr_en     = csr_en;
  assign ctrl_o.csr_op     = csr_op;
  assign ctrl_o.csr_read   = csr_read;
  assign ctrl_o.csr_write  = csr_write;
  assign ctrl_o.is_branch  = is_branch;
  assign ctrl_o.is_jump    = is_jump;
  assign ctrl_o.illegal    = illegal_instr;
  assign ctrl_o.ecall      = ecall;
  assign ctrl_o.ebreak     = ebreak;
  assign ctrl_o.mret       = mret;
  assign ctrl_o.wfi        = wfi;

  assign is_branch_o = is_branch;
  assign fence_o     = fence;

  // --------------------------------------------------------------------
  // Immediate
  // --------------------------------------------------------------------
  imm_gen u_imm_gen (
    .instr_i   (ifid_instr_i[31:7]),
    .imm_sel_i (imm_sel),
    .imm_o     (imm_o)
  );

  // --------------------------------------------------------------------
  // Register file and operand forwarding
  // --------------------------------------------------------------------
  logic [31:0] rf_rdata_a, rf_rdata_b;

  regfile u_regfile (
    .clk_i     (clk_i),
    .raddr_a_i (rs1_addr_o),
    .rdata_a_o (rf_rdata_a),
    .raddr_b_i (rs2_addr_o),
    .rdata_b_o (rf_rdata_b),
    .we_i      (rf_we_i),
    .waddr_i   (rf_waddr_i),
    .wdata_i   (rf_wdata_i)
  );

  assign rs1_data_o = fwd_rs1_i ? ex_result_i : rf_rdata_a;
  assign rs2_data_o = fwd_rs2_i ? ex_result_i : rf_rdata_b;

  // --------------------------------------------------------------------
  // Branch comparator.
  //
  // Built from an `alu` instance driven as a subtraction, which is how that
  // module exports cmp_eq/cmp_lt/cmp_ltu. Reusing the ALU description rather
  // than writing a second comparator means the signed/unsigned comparison
  // logic exists once in the design and is covered once by tb_alu.
  // --------------------------------------------------------------------
  logic        cmp_eq, cmp_lt, cmp_ltu;
  logic [31:0] cmp_result_unused;

  alu u_branch_cmp (
    .operator_i  (ALU_SUB),
    .operand_a_i (rs1_data_o),
    .operand_b_i (rs2_data_o),
    .result_o    (cmp_result_unused),
    .cmp_eq_o    (cmp_eq),
    .cmp_lt_o    (cmp_lt),
    .cmp_ltu_o   (cmp_ltu)
  );

  logic branch_cond;
  always_comb begin
    unique case (br_op)
      BR_NE:   branch_cond = ~cmp_eq;
      BR_LT:   branch_cond = cmp_lt;
      BR_GE:   branch_cond = ~cmp_lt;
      BR_LTU:  branch_cond = cmp_ltu;
      BR_GEU:  branch_cond = ~cmp_ltu;
      // BR_EQ, plus the two reserved funct3 encodings that the decoder has
      // already flagged illegal and which therefore never reach the redirect.
      default: branch_cond = cmp_eq;
    endcase
  end

  // --------------------------------------------------------------------
  // Target computation. A dedicated adder, not the main ALU.
  // JALR clears bit 0 of the computed target, per the ISA.
  // --------------------------------------------------------------------
  logic [31:0] pc_rel_target, jalr_target;

  assign pc_rel_target = ifid_pc_i + imm_o;               // JAL and branches
  assign jalr_target   = (rs1_data_o + imm_o) & ~32'd1;   // JALR

  assign branch_target_o = is_jalr ? jalr_target : pc_rel_target;
  assign take_branch_o   = ifid_valid_i & (is_jump | (is_branch & branch_cond));

  // --------------------------------------------------------------------
  // Decoded signals that this stage produces for the ID/EX register but does
  // not itself consume.
  // --------------------------------------------------------------------
  logic unused_id;
  // md_en/md_op are always zero here (RV32M = 0). FENCE.I is left an
  // architectural NOP on this core, as it always has been; the resulting
  // rv32ui fence_i exclusion is documented in e_core_verification_plan.md.
  assign unused_id = ^{cmp_result_unused, md_en, md_op, fence_i};

endmodule : e_core_id_stage
