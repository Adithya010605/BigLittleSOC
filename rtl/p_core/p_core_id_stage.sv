// ============================================================================
// p_core_id_stage.sv  —  ID: decode, immediate, register read
//
// Purely combinational apart from the register file it instantiates. The ID/EX
// pipeline register lives in the EX stage, so this module describes what the
// instruction in IF/ID *would* carry into EX, and the hazard unit decides
// whether it advances.
//
// Unlike the E-core, nothing is resolved here: branches, jumps and operand
// forwarding all happen in EX. The only operand bypass in this stage is the
// register file's own write-first path, which covers an instruction in WB
// writing the register being read.
// ============================================================================

module p_core_id_stage
  import e_core_pkg::*;
  import p_core_pkg::*;
(
  input  logic                  clk_i,

  // ---- from IF/ID ----
  input  logic [31:0]           ifid_instr_i,

  // ---- register file write port, driven by WB ----
  input  logic                  rf_we_i,
  input  logic [REG_ADDR_W-1:0] rf_waddr_i,
  input  logic [31:0]           rf_wdata_i,

  // ---- decoded instruction ----
  output logic [REG_ADDR_W-1:0] rs1_addr_o,
  output logic [REG_ADDR_W-1:0] rs2_addr_o,
  output logic                  rs1_used_o,
  output logic                  rs2_used_o,
  output logic [REG_ADDR_W-1:0] rd_addr_o,
  output p_ctrl_t               ctrl_o,
  output logic [31:0]           rs1_data_o,
  output logic [31:0]           rs2_data_o,
  output logic [31:0]           imm_o
);

  // --------------------------------------------------------------------
  // Decode (RV32M = 1)
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
  logic       csr_en, csr_use_imm;
  csr_op_e    csr_op;
  logic       csr_read, csr_write;
  logic [CSR_ADDR_W-1:0] csr_addr;
  logic       md_en;
  logic [2:0] md_op;
  logic       ecall, ebreak, mret, wfi, fence, fence_i;
  logic       illegal_instr;

  decoder #(
    .RV32M (1'b1)
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
    .csr_addr_o      (csr_addr),
    .csr_use_imm_o   (csr_use_imm),
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

  assign ctrl_o.base.alu_op     = alu_op;
  assign ctrl_o.base.op_a_sel   = op_a_sel;
  assign ctrl_o.base.op_b_sel   = op_b_sel;
  assign ctrl_o.base.wb_sel     = wb_sel;
  assign ctrl_o.base.rf_we      = rf_we;
  assign ctrl_o.base.mem_req    = mem_req;
  assign ctrl_o.base.mem_we     = mem_we;
  assign ctrl_o.base.mem_size   = mem_size;
  assign ctrl_o.base.mem_signed = mem_signed;
  assign ctrl_o.base.csr_en     = csr_en;
  assign ctrl_o.base.csr_op     = csr_op;
  assign ctrl_o.base.csr_read   = csr_read;
  assign ctrl_o.base.csr_write  = csr_write;
  assign ctrl_o.base.is_branch  = is_branch;
  assign ctrl_o.base.is_jump    = is_jump;
  assign ctrl_o.base.illegal    = illegal_instr;
  assign ctrl_o.base.ecall      = ecall;
  assign ctrl_o.base.ebreak     = ebreak;
  assign ctrl_o.base.mret       = mret;
  assign ctrl_o.base.wfi        = wfi;
  assign ctrl_o.is_jalr         = is_jalr;
  assign ctrl_o.md_en           = md_en;
  assign ctrl_o.md_op           = md_op_e'(md_op);
  assign ctrl_o.fence_i         = fence_i;
  assign ctrl_o.csr_use_imm     = csr_use_imm;

  // --------------------------------------------------------------------
  // Immediate
  // --------------------------------------------------------------------
  imm_gen u_imm_gen (
    .instr_i   (ifid_instr_i[31:7]),
    .imm_sel_i (imm_sel),
    .imm_o     (imm_o)
  );

  // --------------------------------------------------------------------
  // Register file. Write-first, so a register written by WB this cycle is
  // read with its new value.
  // --------------------------------------------------------------------
  regfile u_regfile (
    .clk_i     (clk_i),
    .raddr_a_i (rs1_addr_o),
    .rdata_a_o (rs1_data_o),
    .raddr_b_i (rs2_addr_o),
    .rdata_b_o (rs2_data_o),
    .we_i      (rf_we_i),
    .waddr_i   (rf_waddr_i),
    .wdata_i   (rf_wdata_i)
  );

  // br_op is instr[14:12] and the CSR address is instr[31:20]; EX takes both
  // straight from the instruction word it carries, so the decoded copies are
  // not needed here. fence (plain FENCE) is an architectural NOP on this core,
  // which has no store buffer to drain.
  logic unused_id;
  assign unused_id = ^{br_op, csr_addr, fence};

endmodule : p_core_id_stage
