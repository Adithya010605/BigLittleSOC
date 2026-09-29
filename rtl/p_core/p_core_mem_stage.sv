// ============================================================================
// p_core_mem_stage.sv  —  MEM: data access, CSR access, commit; and WB
//
// Owns the EX/MEM and MEM/WB pipeline registers, the load/store unit, the
// data-port handshake and the CSR access, and reports every trap source to
// the trap unit (the E-core's e_core_trap, reused unchanged).
//
// ---------------------------------------------------------------------------
// MEM IS THE COMMIT POINT
// ---------------------------------------------------------------------------
// An instruction is architecturally complete when it leaves MEM without
// trapping. Everything with a side effect outside the pipeline happens here
// and nowhere earlier: the data access, the CSR write, trap entry, MRET, and
// the FENCE.I refetch. That is what makes every trap precise -- anything
// younger is still in EX, ID or IF, has done nothing observable, and is simply
// flushed. WB only writes the register file with a value MEM has already
// committed, so the RVFI trace is taken here too.
//
// Everything that makes an instruction trap, apart from a bus error, is known
// before its access is issued, so a faulting access never reaches the bus. A
// bus error arrives with rvalid and is handled when the access completes.
//
// data_req_o is a function of registers only and never depends
// combinationally on data_gnt_i or data_rvalid_i.
//
// ---------------------------------------------------------------------------
// STORE DATA: THE MEM -> MEM FORWARDING PATH
// ---------------------------------------------------------------------------
// A store whose data comes from the load (or CSR read) immediately ahead of it
// is NOT stalled in ID. It moves on with a stale rs2, and when it reaches MEM
// the load has reached WB, so the store data is taken from MEM/WB instead.
// The same path covers a store that was held in EX while the load waited on
// memory. As with the EX operands, the forwarded value is written back into
// EX/MEM while the store waits here, which also keeps data_wdata_o stable
// from request to grant as the protocol requires.
// ============================================================================

module p_core_mem_stage
  import e_core_pkg::*;
  import p_core_pkg::*;
(
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // ---- EX/MEM register control, from the hazard unit ----
  input  logic                  exmem_en_i,
  input  logic                  exmem_valid_i,

  // ---- from EX ----
  input  logic [31:0]           ex_pc_i,
  input  logic [31:0]           ex_instr_i,
  input  logic                  ex_instr_err_i,
  input  p_ctrl_t               ex_ctrl_i,
  input  logic [REG_ADDR_W-1:0] ex_rd_i,
  input  logic [REG_ADDR_W-1:0] ex_rs1_addr_i,
  input  logic [REG_ADDR_W-1:0] ex_rs2_addr_i,
  input  logic [31:0]           ex_rs1_i,
  input  logic [31:0]           ex_rs2_i,
  input  logic [31:0]           ex_result_i,
  input  logic [31:0]           ex_csr_wdata_i,
  input  logic [31:0]           ex_npc_i,
  input  logic [31:0]           ex_target_i,
  input  logic                  ex_taken_i,
  input  logic                  ex_target_misaligned_i,
  input  logic                  ex_mispredict_i,

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

  // ---- CSR file ----
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

  // ---- the instruction in MEM, to the hazard unit ----
  output logic                  valid_o,
  output logic                  ready_o,         // completes this cycle
  output logic                  rf_we_o,         // it writes a register...
  output logic                  late_o,          // ...with a value made here
  output logic [REG_ADDR_W-1:0] rd_o,
  output logic [31:0]           fwd_o,           // its EX result, for EX

  // ---- commit ----
  output logic                  commit_o,        // would complete this cycle
  output logic                  retire_o,        // ...and did not trap
  output logic                  fence_i_o,       // a FENCE.I retires
  output logic [31:0]           pc_o,
  output logic [31:0]           npc_o,

  // ---- WB: the MEM/WB register drives the register file write port ----
  output logic                  wb_valid_o,
  output logic                  wb_rf_we_o,
  output logic [REG_ADDR_W-1:0] wb_rd_o,
  output logic [31:0]           wb_data_o,

  // ---- performance events ----
  output logic                  perf_branch_o,
  output logic                  perf_branch_taken_o,
  output logic                  perf_mem_o,
  output logic                  perf_mispredict_o,

  // ---- RVFI ----
  output logic [31:0]           rvfi_insn_o,
  output logic [REG_ADDR_W-1:0] rvfi_rs1_addr_o,
  output logic [REG_ADDR_W-1:0] rvfi_rs2_addr_o,
  output logic [31:0]           rvfi_rs1_rdata_o,
  output logic [31:0]           rvfi_rs2_rdata_o,
  output logic [REG_ADDR_W-1:0] rvfi_rd_addr_o,
  output logic [31:0]           rvfi_rd_wdata_o,
  output logic [3:0]            rvfi_mem_rmask_o,
  output logic [3:0]            rvfi_mem_wmask_o,
  output logic [31:0]           rvfi_mem_rdata_o,
  output logic [31:0]           rvfi_mem_wdata_o
);

  // --------------------------------------------------------------------
  // EX/MEM pipeline register
  // --------------------------------------------------------------------
  logic                  valid_q;
  logic [31:0]           pc_q, instr_q;
  logic                  instr_err_q;
  p_ctrl_t               ctrl_q;
  logic [REG_ADDR_W-1:0] rd_q, rs1_addr_q, rs2_addr_q;
  logic [31:0]           rs1_q, rs2_q;
  logic [31:0]           result_q, csr_wdata_q, npc_q, target_q;
  logic                  taken_q, target_misaligned_q, mispredict_q;
  logic                  mem_gnt_q;

  logic [31:0] store_data;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q             <= 1'b0;
      pc_q                <= 32'd0;
      instr_q             <= 32'd0;
      instr_err_q         <= 1'b0;
      ctrl_q              <= '0;
      rd_q                <= '0;
      rs1_addr_q          <= '0;
      rs2_addr_q          <= '0;
      rs1_q               <= 32'd0;
      rs2_q               <= 32'd0;
      result_q            <= 32'd0;
      csr_wdata_q         <= 32'd0;
      npc_q               <= 32'd0;
      target_q            <= 32'd0;
      taken_q             <= 1'b0;
      target_misaligned_q <= 1'b0;
      mispredict_q        <= 1'b0;
      mem_gnt_q           <= 1'b0;
    end else if (exmem_en_i) begin
      valid_q             <= exmem_valid_i;
      pc_q                <= ex_pc_i;
      instr_q             <= ex_instr_i;
      instr_err_q         <= ex_instr_err_i;
      ctrl_q              <= ex_ctrl_i;
      rd_q                <= ex_rd_i;
      rs1_addr_q          <= ex_rs1_addr_i;
      rs2_addr_q          <= ex_rs2_addr_i;
      rs1_q               <= ex_rs1_i;
      rs2_q               <= ex_rs2_i;
      result_q            <= ex_result_i;
      csr_wdata_q         <= ex_csr_wdata_i;
      npc_q               <= ex_npc_i;
      target_q            <= ex_target_i;
      taken_q             <= ex_taken_i;
      target_misaligned_q <= ex_target_misaligned_i;
      mispredict_q        <= ex_mispredict_i;
      // A newly accepted instruction has not yet had its request granted.
      mem_gnt_q           <= 1'b0;
    end else begin
      // Store-data refresh; see the header.
      rs2_q               <= store_data;
      if (data_req_o && data_gnt_i) begin
        mem_gnt_q         <= 1'b1;
      end
    end
  end

  // --------------------------------------------------------------------
  // MEM/WB pipeline register (declared early: it feeds the store-data path)
  // --------------------------------------------------------------------
  logic                  wb_valid_q, wb_rf_we_q;
  logic [REG_ADDR_W-1:0] wb_rd_q;
  logic [31:0]           wb_data_q;

  // MEM -> MEM: the store data comes from the instruction in WB when that
  // instruction wrote the store's rs2.
  logic st_fwd;
  assign st_fwd     = wb_valid_q & wb_rf_we_q & (wb_rd_q != '0) & (wb_rd_q == rs2_addr_q);
  assign store_data = st_fwd ? wb_data_q : rs2_q;

  // --------------------------------------------------------------------
  // Load/store unit
  // --------------------------------------------------------------------
  logic [3:0]  lsu_be;
  logic [31:0] lsu_wdata, lsu_rdata_ext;
  logic        lsu_misaligned;

  lsu u_lsu (
    .size_i          (ctrl_q.base.mem_size),
    .sign_i          (ctrl_q.base.mem_signed),
    .addr_lsb_i      (result_q[1:0]),
    .wdata_i         (store_data),
    .be_o            (lsu_be),
    .wdata_aligned_o (lsu_wdata),
    .rdata_i         (data_rdata_i),
    .rdata_ext_o     (lsu_rdata_ext),
    .misaligned_o    (lsu_misaligned)
  );

  // --------------------------------------------------------------------
  // CSR access
  // --------------------------------------------------------------------
  assign csr_en_o    = valid_q & ctrl_q.base.csr_en;
  assign csr_write_o = ctrl_q.base.csr_write;
  assign csr_op_o    = ctrl_q.base.csr_op;
  assign csr_addr_o  = instr_q[31:20];
  assign csr_wdata_o = csr_wdata_q;

  // --------------------------------------------------------------------
  // Trap sources
  // --------------------------------------------------------------------
  logic pre_exception;
  assign pre_exception = target_misaligned_q | instr_err_q |
                         ctrl_q.base.illegal | csr_illegal_i |
                         ctrl_q.base.ecall | ctrl_q.base.ebreak |
                         (ctrl_q.base.mem_req & lsu_misaligned);

  logic mem_active;
  assign mem_active = valid_q & ctrl_q.base.mem_req & ~pre_exception;

  assign exc_instr_err_o        = instr_err_q;
  assign exc_illegal_o          = ctrl_q.base.illegal | csr_illegal_i;
  assign exc_ecall_o            = ctrl_q.base.ecall;
  assign exc_ebreak_o           = ctrl_q.base.ebreak;
  assign exc_mret_o             = ctrl_q.base.mret;
  assign exc_instr_misaligned_o = target_misaligned_q;
  assign exc_instr_target_o     = target_q;
  assign exc_mem_req_o          = ctrl_q.base.mem_req;
  assign exc_mem_we_o           = ctrl_q.base.mem_we;
  assign exc_mem_misaligned_o   = lsu_misaligned;
  assign exc_mem_err_o          = mem_active & data_rvalid_i & data_err_i;
  assign exc_mem_addr_o         = result_q;

  // --------------------------------------------------------------------
  // Data request
  // --------------------------------------------------------------------
  assign data_req_o   = mem_active & ~mem_gnt_q;
  assign data_addr_o  = {result_q[31:2], 2'b00};
  assign data_we_o    = ctrl_q.base.mem_we;
  assign data_be_o    = lsu_be;
  assign data_wdata_o = lsu_wdata;

  // --------------------------------------------------------------------
  // Completion and commit
  // --------------------------------------------------------------------
  assign ready_o  = ~mem_active | data_rvalid_i;
  assign commit_o = valid_q & ready_o;
  assign retire_o = commit_o & ~trap_i;

  logic [31:0] value;
  always_comb begin
    unique case (ctrl_q.base.wb_sel)
      WB_MEM:  value = lsu_rdata_ext;
      WB_CSR:  value = csr_rdata_i;
      default: value = result_q;      // ALU, link, multiply, divide
    endcase
  end

  assign csr_commit_o = retire_o;
  assign fence_i_o    = retire_o & ctrl_q.fence_i;
  assign pc_o         = pc_q;
  assign npc_o        = npc_q;

  // --------------------------------------------------------------------
  // To the hazard unit. A load's or a CSR read's value is produced during
  // MEM, so it cannot be forwarded from here to EX; the hazard unit keeps a
  // dependent instruction out of EX until it can come from WB instead.
  // --------------------------------------------------------------------
  assign valid_o = valid_q;
  assign rf_we_o = ctrl_q.base.rf_we;
  assign late_o  = (ctrl_q.base.mem_req & ~ctrl_q.base.mem_we) | ctrl_q.base.csr_en;
  assign rd_o    = rd_q;
  assign fwd_o   = result_q;

  // --------------------------------------------------------------------
  // MEM/WB pipeline register
  // --------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_valid_q <= 1'b0;
      wb_rf_we_q <= 1'b0;
      wb_rd_q    <= '0;
      wb_data_q  <= 32'd0;
    end else begin
      wb_valid_q <= retire_o;
      wb_rf_we_q <= retire_o & ctrl_q.base.rf_we;
      wb_rd_q    <= rd_q;
      wb_data_q  <= value;
    end
  end

  assign wb_valid_o = wb_valid_q;
  assign wb_rf_we_o = wb_rf_we_q;
  assign wb_rd_o    = wb_rd_q;
  assign wb_data_o  = wb_data_q;

  // --------------------------------------------------------------------
  // Performance events, all at retirement
  // --------------------------------------------------------------------
  assign perf_branch_o       = retire_o & ctrl_q.base.is_branch;
  assign perf_branch_taken_o = retire_o & ctrl_q.base.is_branch & taken_q;
  assign perf_mem_o          = retire_o & ctrl_q.base.mem_req;
  assign perf_mispredict_o   = retire_o & mispredict_q;

  // --------------------------------------------------------------------
  // RVFI
  // --------------------------------------------------------------------
  assign rvfi_insn_o      = instr_q;
  assign rvfi_rs1_addr_o  = rs1_addr_q;
  assign rvfi_rs2_addr_o  = rs2_addr_q;
  assign rvfi_rs1_rdata_o = rs1_q;
  assign rvfi_rs2_rdata_o = store_data;
  assign rvfi_rd_addr_o   = (retire_o & ctrl_q.base.rf_we) ? rd_q : '0;
  assign rvfi_rd_wdata_o  = (retire_o & ctrl_q.base.rf_we & (rd_q != '0)) ? value : 32'd0;
  assign rvfi_mem_rmask_o = (retire_o & mem_active & ~ctrl_q.base.mem_we) ? lsu_be : 4'd0;
  assign rvfi_mem_wmask_o = (retire_o & mem_active &  ctrl_q.base.mem_we) ? lsu_be : 4'd0;
  assign rvfi_mem_rdata_o = data_rdata_i;
  assign rvfi_mem_wdata_o = lsu_wdata;

  // Decoded fields consumed in earlier stages, or not at all on this core.
  logic unused_mem;
  assign unused_mem = ^{ctrl_q.base.alu_op, ctrl_q.base.op_a_sel,
                        ctrl_q.base.op_b_sel, ctrl_q.base.csr_read,
                        ctrl_q.base.is_jump, ctrl_q.base.wfi,
                        ctrl_q.is_jalr, ctrl_q.md_en, ctrl_q.md_op,
                        ctrl_q.csr_use_imm};

endmodule : p_core_mem_stage
