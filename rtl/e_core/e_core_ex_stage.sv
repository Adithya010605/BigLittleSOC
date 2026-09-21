// ============================================================================
// e_core_ex_stage.sv  —  Stage S3: execute, memory access, writeback
//
// Owns the ID/EX pipeline register, the main ALU, the load/store unit and the
// data-port handshake, drives the register file write port back in S2, and
// reports every trap source to e_core_trap.
//
// COMPLETION AND BACK-PRESSURE
//   A non-memory instruction completes in the cycle it occupies this stage. A
//   load or store completes when data_rvalid_i arrives, which may be the same
//   cycle as the request or arbitrarily later; ex_ready_o is low until then,
//   which back-pressures ID and, through it, IF.
//
//   data_req_o is a function of the ID/EX register and mem_gnt_q only. It never
//   depends combinationally on data_gnt_i or data_rvalid_i, which is the
//   contract the memory model relies on.
//
// TRAPS
//   An instruction that will trap for a reason known before the access -- an
//   illegal encoding, a misaligned address, ECALL, EBREAK, a faulting fetch --
//   never issues its memory request, so a faulting access does not reach the
//   bus. Access faults reported by the bus itself arrive with rvalid and are
//   handled once the access completes. A trapping instruction does not write
//   the register file and does not commit its CSR write.
// ============================================================================

module e_core_ex_stage
  import e_core_pkg::*;
(
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // ---- ID/EX pipeline register control, from the hazard unit ----
  input  logic                  idex_en_i,
  input  logic                  idex_valid_i,

  // ---- from ID ----
  input  logic [31:0]           id_pc_i,
  input  logic [31:0]           id_instr_i,
  input  ctrl_t                 id_ctrl_i,
  input  logic [REG_ADDR_W-1:0] id_rd_i,
  input  logic [REG_ADDR_W-1:0] id_rs1_addr_i,
  input  logic [REG_ADDR_W-1:0] id_rs2_addr_i,
  input  logic [31:0]           id_rs1_data_i,
  input  logic [31:0]           id_rs2_data_i,
  input  logic [31:0]           id_imm_i,
  input  logic                  id_instr_err_i,
  input  logic [31:0]           id_branch_target_i,
  input  logic                  id_take_branch_i,
  input  logic [CSR_ADDR_W-1:0] id_csr_addr_i,
  input  logic                  id_csr_use_imm_i,

  // ---- data memory port ----
  output logic                  data_req_o,
  output logic [31:0]           data_addr_o,
  output logic                  data_we_o,
  output logic [3:0]            data_be_o,
  output logic [31:0]           data_wdata_o,
  input  logic                  data_gnt_i,
  input  logic                  data_rvalid_i,
  input  logic [31:0]           data_rdata_i,
  input  logic                  data_err_i,

  // ---- CSR file, instantiated at the top level ----
  input  logic [31:0]           csr_rdata_i,
  input  logic                  csr_illegal_i,
  output logic                  csr_en_o,
  output logic                  csr_write_o,
  output csr_op_e               csr_op_o,
  output logic [CSR_ADDR_W-1:0] csr_addr_o,
  output logic [31:0]           csr_wdata_o,
  output logic                  csr_commit_o,

  // ---- trap unit ----
  input  logic                  trap_i,          // a trap is taken this cycle
  output logic                  exc_instr_err_o,
  output logic                  exc_illegal_o,
  output logic                  exc_ecall_o,
  output logic                  exc_ebreak_o,
  output logic                  exc_mret_o,
  output logic                  exc_instr_misaligned_o,
  output logic [31:0]           exc_instr_target_o,
  output logic                  exc_mem_req_o,
  output logic                  exc_mem_we_o,
  output logic                  exc_mem_misaligned_o,
  output logic                  exc_mem_err_o,
  output logic [31:0]           exc_mem_addr_o,

  // ---- to the hazard unit ----
  output logic                  ex_ready_o,
  output logic                  idex_valid_o,
  output ctrl_t                 idex_ctrl_o,
  output logic [REG_ADDR_W-1:0] idex_rd_o,

  // ---- forwarding value and register file write port ----
  output logic [31:0]           ex_result_o,
  output logic                  rf_we_o,
  output logic [REG_ADDR_W-1:0] rf_waddr_o,
  output logic [31:0]           rf_wdata_o,

  // ---- retirement, for RVFI and the performance counters ----
  output logic                  commit_o,        // would complete this cycle
  output logic                  retire_o,        // ...and did not trap
  output logic [31:0]           idex_pc_o,
  output logic [31:0]           idex_instr_o,
  output logic [31:0]           idex_pc_next_o,
  output logic [REG_ADDR_W-1:0] idex_rs1_addr_o,
  output logic [REG_ADDR_W-1:0] idex_rs2_addr_o,
  output logic [31:0]           idex_rs1_data_o,
  output logic [31:0]           idex_rs2_data_o,
  output logic                  perf_branch_o,
  output logic                  perf_branch_taken_o,
  output logic                  perf_mem_o,
  output logic [3:0]            mem_rmask_o,
  output logic [3:0]            mem_wmask_o,
  output logic [31:0]           mem_rdata_o,
  output logic [31:0]           mem_wdata_o
);

  // --------------------------------------------------------------------
  // ID/EX pipeline register
  // --------------------------------------------------------------------
  logic                  valid_q;
  logic [31:0]           pc_q, instr_q;
  ctrl_t                 ctrl_q;
  logic [REG_ADDR_W-1:0] rd_q, rs1_addr_q, rs2_addr_q;
  logic [31:0]           rs1_q, rs2_q, imm_q;
  logic                  instr_err_q;
  logic [31:0]           branch_target_q;
  logic                  take_branch_q;
  logic [CSR_ADDR_W-1:0] csr_addr_q;
  logic                  csr_use_imm_q;
  logic                  mem_gnt_q;

  assign idex_valid_o    = valid_q;
  assign idex_ctrl_o     = ctrl_q;
  assign idex_rd_o       = rd_q;
  assign idex_pc_o       = pc_q;
  assign idex_instr_o    = instr_q;
  assign idex_pc_next_o  = take_branch_q ? branch_target_q : (pc_q + 32'd4);
  assign idex_rs1_addr_o = rs1_addr_q;
  assign idex_rs2_addr_o = rs2_addr_q;
  assign idex_rs1_data_o = rs1_q;
  assign idex_rs2_data_o = rs2_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q         <= 1'b0;
      pc_q            <= 32'd0;
      instr_q         <= 32'd0;
      ctrl_q          <= '0;
      rd_q            <= {REG_ADDR_W{1'b0}};
      rs1_addr_q      <= {REG_ADDR_W{1'b0}};
      rs2_addr_q      <= {REG_ADDR_W{1'b0}};
      rs1_q           <= 32'd0;
      rs2_q           <= 32'd0;
      imm_q           <= 32'd0;
      instr_err_q     <= 1'b0;
      branch_target_q <= 32'd0;
      take_branch_q   <= 1'b0;
      csr_addr_q      <= {CSR_ADDR_W{1'b0}};
      csr_use_imm_q   <= 1'b0;
      mem_gnt_q       <= 1'b0;
    end else if (idex_en_i) begin
      valid_q         <= idex_valid_i;
      pc_q            <= id_pc_i;
      instr_q         <= id_instr_i;
      ctrl_q          <= id_ctrl_i;
      rd_q            <= id_rd_i;
      rs1_addr_q      <= id_rs1_addr_i;
      rs2_addr_q      <= id_rs2_addr_i;
      rs1_q           <= id_rs1_data_i;
      rs2_q           <= id_rs2_data_i;
      imm_q           <= id_imm_i;
      instr_err_q     <= id_instr_err_i;
      branch_target_q <= id_branch_target_i;
      take_branch_q   <= id_take_branch_i;
      csr_addr_q      <= id_csr_addr_i;
      csr_use_imm_q   <= id_csr_use_imm_i;
      // A newly accepted instruction has not yet had its request granted.
      mem_gnt_q       <= 1'b0;
    end else if (data_req_o && data_gnt_i) begin
      mem_gnt_q       <= 1'b1;
    end
  end

  // --------------------------------------------------------------------
  // ALU
  // --------------------------------------------------------------------
  logic [31:0] alu_a, alu_b, alu_result;
  logic        cmp_eq_unused, cmp_lt_unused, cmp_ltu_unused;

  always_comb begin
    unique case (ctrl_q.op_a_sel)
      OP_A_PC:   alu_a = pc_q;
      OP_A_ZERO: alu_a = 32'd0;
      default:   alu_a = rs1_q;   // OP_A_RS1
    endcase
  end

  assign alu_b = (ctrl_q.op_b_sel == OP_B_IMM) ? imm_q : rs2_q;

  alu u_alu (
    .operator_i  (ctrl_q.alu_op),
    .operand_a_i (alu_a),
    .operand_b_i (alu_b),
    .result_o    (alu_result),
    .cmp_eq_o    (cmp_eq_unused),
    .cmp_lt_o    (cmp_lt_unused),
    .cmp_ltu_o   (cmp_ltu_unused)
  );

  // --------------------------------------------------------------------
  // Load/store unit
  // --------------------------------------------------------------------
  logic [3:0]  lsu_be;
  logic [31:0] lsu_wdata, lsu_rdata_ext;
  logic        lsu_misaligned;

  lsu u_lsu (
    .size_i          (ctrl_q.mem_size),
    .sign_i          (ctrl_q.mem_signed),
    .addr_lsb_i      (alu_result[1:0]),
    .wdata_i         (rs2_q),
    .be_o            (lsu_be),
    .wdata_aligned_o (lsu_wdata),
    .rdata_i         (data_rdata_i),
    .rdata_ext_o     (lsu_rdata_ext),
    .misaligned_o    (lsu_misaligned)
  );

  // --------------------------------------------------------------------
  // CSR access
  // --------------------------------------------------------------------
  assign csr_en_o    = valid_q & ctrl_q.csr_en;
  assign csr_write_o = ctrl_q.csr_write;
  assign csr_op_o    = ctrl_q.csr_op;
  assign csr_addr_o  = csr_addr_q;
  // CSRRWI/CSRRSI/CSRRCI use the zero-extended 5-bit uimm, which imm_gen has
  // already placed in the immediate under the IMM_Z format.
  assign csr_wdata_o = csr_use_imm_q ? imm_q : rs1_q;

  // --------------------------------------------------------------------
  // Trap sources
  //
  // Everything except a bus error is known before the memory access is
  // issued, which is what allows a faulting access to be suppressed entirely.
  // --------------------------------------------------------------------
  logic instr_misaligned;
  assign instr_misaligned = take_branch_q & (|branch_target_q[1:0]);

  logic pre_exception;
  assign pre_exception = instr_misaligned | instr_err_q |
                         ctrl_q.illegal | csr_illegal_i |
                         ctrl_q.ecall | ctrl_q.ebreak |
                         (ctrl_q.mem_req & lsu_misaligned);

  logic mem_active;
  assign mem_active = valid_q & ctrl_q.mem_req & ~pre_exception;

  assign exc_instr_err_o        = instr_err_q;
  assign exc_illegal_o          = ctrl_q.illegal | csr_illegal_i;
  assign exc_ecall_o            = ctrl_q.ecall;
  assign exc_ebreak_o           = ctrl_q.ebreak;
  assign exc_mret_o             = ctrl_q.mret;
  assign exc_instr_misaligned_o = instr_misaligned;
  assign exc_instr_target_o     = branch_target_q;
  assign exc_mem_req_o          = ctrl_q.mem_req;
  assign exc_mem_we_o           = ctrl_q.mem_we;
  assign exc_mem_misaligned_o   = lsu_misaligned;
  assign exc_mem_err_o          = mem_active & data_rvalid_i & data_err_i;
  assign exc_mem_addr_o         = alu_result;

  // --------------------------------------------------------------------
  // Memory request
  // --------------------------------------------------------------------
  assign data_req_o   = mem_active & ~mem_gnt_q;
  assign data_addr_o  = {alu_result[31:2], 2'b00};
  assign data_we_o    = ctrl_q.mem_we;
  assign data_be_o    = lsu_be;
  assign data_wdata_o = lsu_wdata;

  // --------------------------------------------------------------------
  // Completion
  //
  // WFI is architecturally a hint. With no low-power state to enter, the
  // correct and simplest implementation is a NOP: the core keeps running and
  // an enabled interrupt is taken by the normal path.
  // --------------------------------------------------------------------
  assign ex_ready_o = ~mem_active | data_rvalid_i;
  assign commit_o   = valid_q & ex_ready_o;
  assign retire_o   = commit_o & ~trap_i;

  // --------------------------------------------------------------------
  // Writeback
  // --------------------------------------------------------------------
  always_comb begin
    unique case (ctrl_q.wb_sel)
      WB_MEM:  ex_result_o = lsu_rdata_ext;
      WB_PC4:  ex_result_o = pc_q + 32'd4;
      WB_CSR:  ex_result_o = csr_rdata_i;
      default: ex_result_o = alu_result;   // WB_ALU
    endcase
  end

  assign rf_we_o     = retire_o & ctrl_q.rf_we;
  assign rf_waddr_o  = rd_q;
  assign rf_wdata_o  = ex_result_o;
  assign csr_commit_o = retire_o;

  // --------------------------------------------------------------------
  // Performance counter events and RVFI memory reporting
  // --------------------------------------------------------------------
  assign perf_branch_o       = retire_o & ctrl_q.is_branch;
  assign perf_branch_taken_o = retire_o & ctrl_q.is_branch & take_branch_q;
  assign perf_mem_o          = retire_o & ctrl_q.mem_req;

  assign mem_rmask_o = (retire_o & mem_active & ~ctrl_q.mem_we) ? lsu_be : 4'd0;
  assign mem_wmask_o = (retire_o & mem_active &  ctrl_q.mem_we) ? lsu_be : 4'd0;
  assign mem_rdata_o = data_rdata_i;
  assign mem_wdata_o = lsu_wdata;

  logic unused_ex;
  assign unused_ex = ^{cmp_eq_unused, cmp_lt_unused, cmp_ltu_unused,
                       ctrl_q.csr_read, ctrl_q.is_jump, ctrl_q.wfi};

endmodule : e_core_ex_stage
