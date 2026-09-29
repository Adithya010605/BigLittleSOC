// ============================================================================
// p_core_top.sv
//
// P-Core: RV32IM_Zicsr, machine mode, five-stage in-order pipeline with
// dynamic branch prediction.
//
//   IF   predicted fetch: BTB + BHT lookup, skid buffer, redirect
//   ID   decode, immediate, register read, load-use interlock
//   EX   forwarding, ALU, branch resolution and mispredict check, 4-cycle
//        Booth multiplier, 33-cycle restoring divider
//   MEM  data access, CSR access, trap entry, commit
//   WB   register file write
//
// Pipeline registers: IF/ID (in the IF stage), ID/EX (in EX), EX/MEM and
// MEM/WB (in MEM). Each carries a valid bit; a flush clears it.
//
// All stall, flush and forwarding decisions are made in p_core_hazard.sv, and
// trap prioritisation in the E-core's e_core_trap.sv, reused unchanged. This
// module is wiring plus the RVFI trace and the simulation-only protocol and
// pipeline assertions.
//
// The external interface -- both memory ports, the interrupt pins and the
// RVFI trace -- is identical to e_core_top's, so either core drops into the
// same testbench, and later into the same SoC slot.
// ============================================================================

module p_core_top
  import e_core_pkg::*;
  import p_core_pkg::*;
#(
  parameter logic [31:0] RESET_VECTOR = 32'h0000_0000,
  parameter logic [31:0] HART_ID      = 32'h0000_0000,
  parameter bit          RVFI         = 1'b0
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // ---- Instruction memory port ----
  output logic        instr_req_o,
  output logic [31:0] instr_addr_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,

  // ---- Data memory port ----
  output logic        data_req_o,
  output logic [31:0] data_addr_o,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_wdata_o,
  input  logic        data_gnt_i,
  input  logic        data_rvalid_i,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,

  // ---- Interrupts ----
  input  logic        irq_timer_i,
  input  logic        irq_software_i,
  input  logic        irq_external_i,

  // ---- RVFI trace port, active when RVFI == 1 ----
  output logic        rvfi_valid_o,
  output logic [63:0] rvfi_order_o,
  output logic [31:0] rvfi_insn_o,
  output logic        rvfi_trap_o,
  output logic        rvfi_halt_o,
  output logic        rvfi_intr_o,
  output logic [1:0]  rvfi_mode_o,
  output logic [1:0]  rvfi_ixl_o,
  output logic [4:0]  rvfi_rs1_addr_o,
  output logic [4:0]  rvfi_rs2_addr_o,
  output logic [31:0] rvfi_rs1_rdata_o,
  output logic [31:0] rvfi_rs2_rdata_o,
  output logic [4:0]  rvfi_rd_addr_o,
  output logic [31:0] rvfi_rd_wdata_o,
  output logic [31:0] rvfi_pc_rdata_o,
  output logic [31:0] rvfi_pc_wdata_o,
  output logic [31:0] rvfi_mem_addr_o,
  output logic [3:0]  rvfi_mem_rmask_o,
  output logic [3:0]  rvfi_mem_wmask_o,
  output logic [31:0] rvfi_mem_rdata_o,
  output logic [31:0] rvfi_mem_wdata_o
);

  // --------------------------------------------------------------------
  // IF <-> BPU, IF -> ID
  // --------------------------------------------------------------------
  logic [31:0] bp_lookup_pc, bp_target;
  logic        bp_taken, bp_btb_hit;
  logic [1:0]  bp_bht;

  logic        ifid_valid, ifid_err, ifid_accept;
  logic [31:0] ifid_pc, ifid_instr;
  pred_t       ifid_pred;
  logic        if_redirect;
  logic [31:0] if_redirect_pc;

  // --------------------------------------------------------------------
  // ID
  // --------------------------------------------------------------------
  logic [REG_ADDR_W-1:0] id_rs1_addr, id_rs2_addr, id_rd;
  logic                  id_rs1_used, id_rs2_used;
  p_ctrl_t               id_ctrl;
  logic [31:0]           id_rs1_data, id_rs2_data, id_imm;

  // --------------------------------------------------------------------
  // EX
  // --------------------------------------------------------------------
  logic                  ex_valid, ex_ready, ex_instr_err;
  p_ctrl_t               ex_ctrl;
  logic [REG_ADDR_W-1:0] ex_rd, ex_rs1_addr, ex_rs2_addr;
  logic                  ex_rs1_used, ex_rs2_used;
  logic [31:0]           ex_pc, ex_instr, ex_rs1, ex_rs2, ex_result;
  logic [31:0]           ex_csr_wdata, ex_npc, ex_target;
  logic                  ex_taken, ex_target_misaligned, ex_mispredict;
  logic                  ex_md_busy;
  logic                  bp_upd_en, bp_upd_btb_hit;
  logic [1:0]            bp_upd_bht;

  // --------------------------------------------------------------------
  // MEM / WB
  // --------------------------------------------------------------------
  logic                  mem_valid, mem_ready, mem_rf_we, mem_late;
  logic [REG_ADDR_W-1:0] mem_rd;
  logic [31:0]           mem_fwd;
  logic                  mem_commit, mem_retire, mem_fence_i;
  logic [31:0]           mem_pc, mem_npc;
  logic                  wb_valid, wb_rf_we;
  logic [REG_ADDR_W-1:0] wb_rd;
  logic [31:0]           wb_data;

  logic [31:0]           csr_rdata, csr_wdata;
  logic                  csr_illegal, csr_en, csr_write, csr_commit;
  csr_op_e               csr_op;
  logic [CSR_ADDR_W-1:0] csr_addr;

  logic                  exc_instr_err, exc_illegal, exc_ecall, exc_ebreak;
  logic                  exc_mret, exc_instr_misaligned;
  logic [31:0]           exc_instr_target;
  logic                  exc_mem_req, exc_mem_we, exc_mem_misaligned, exc_mem_err;
  logic [31:0]           exc_mem_addr;

  logic                  trap_taken, trap_is_irq, trap_redirect;
  logic [4:0]            trap_cause;
  logic [31:0]           trap_tval, trap_redirect_pc;
  logic [31:1]           trap_epc;
  logic [31:0]           mtvec, mepc, mip, mie;
  logic                  mstatus_mie;

  logic                  perf_branch, perf_branch_taken, perf_mem, perf_mispredict;

  logic [REG_ADDR_W-1:0] rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
  logic [31:0]           rvfi_insn, rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata;
  logic [3:0]            rvfi_mem_rmask, rvfi_mem_wmask;
  logic [31:0]           rvfi_mem_rdata, rvfi_mem_wdata;

  // --------------------------------------------------------------------
  // Hazard control
  // --------------------------------------------------------------------
  logic       idex_en, idex_valid, ex_advance, exmem_en, exmem_valid;
  logic       flush_ex, flush_mem;
  logic [1:0] fwd_rs1_sel, fwd_rs2_sel;
  logic       id_stall, interlock;

  // A trap, MRET or retiring FENCE.I in MEM redirects fetch and flushes
  // everything younger. FENCE.I resumes at the next instruction, fetched anew
  // after every older store has been performed.
  assign flush_mem      = trap_redirect | mem_fence_i;
  assign if_redirect    = flush_mem | flush_ex;
  assign if_redirect_pc = trap_redirect ? trap_redirect_pc :
                          mem_fence_i   ? mem_npc          : ex_npc;

  // ====================================================================
  // IF
  // ====================================================================
  p_core_bpu u_bpu (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .lookup_pc_i     (bp_lookup_pc),
    .pred_taken_o    (bp_taken),
    .pred_target_o   (bp_target),
    .pred_bht_o      (bp_bht),
    .pred_btb_hit_o  (bp_btb_hit),
    .upd_en_i        (bp_upd_en),
    .upd_pc_i        (ex_pc),
    .upd_is_branch_i (ex_ctrl.base.is_branch),
    .upd_is_jump_i   (ex_ctrl.base.is_jump),
    .upd_taken_i     (ex_taken),
    .upd_target_i    (ex_target),
    .upd_bht_i       (bp_upd_bht),
    .upd_btb_hit_i   (bp_upd_btb_hit)
  );

  p_core_if_stage #(
    .RESET_VECTOR (RESET_VECTOR)
  ) u_if_stage (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .instr_req_o    (instr_req_o),
    .instr_addr_o   (instr_addr_o),
    .instr_gnt_i    (instr_gnt_i),
    .instr_rvalid_i (instr_rvalid_i),
    .instr_rdata_i  (instr_rdata_i),
    .instr_err_i    (instr_err_i),
    .bp_lookup_pc_o (bp_lookup_pc),
    .bp_taken_i     (bp_taken),
    .bp_target_i    (bp_target),
    .bp_bht_i       (bp_bht),
    .bp_btb_hit_i   (bp_btb_hit),
    .redirect_i     (if_redirect),
    .redirect_pc_i  (if_redirect_pc),
    .ifid_accept_i  (ifid_accept),
    .ifid_valid_o   (ifid_valid),
    .ifid_pc_o      (ifid_pc),
    .ifid_instr_o   (ifid_instr),
    .ifid_err_o     (ifid_err),
    .ifid_pred_o    (ifid_pred)
  );

  // ====================================================================
  // ID
  // ====================================================================
  p_core_id_stage u_id_stage (
    .clk_i        (clk_i),
    .ifid_instr_i (ifid_instr),
    .rf_we_i      (wb_rf_we),
    .rf_waddr_i   (wb_rd),
    .rf_wdata_i   (wb_data),
    .rs1_addr_o   (id_rs1_addr),
    .rs2_addr_o   (id_rs2_addr),
    .rs1_used_o   (id_rs1_used),
    .rs2_used_o   (id_rs2_used),
    .rd_addr_o    (id_rd),
    .ctrl_o       (id_ctrl),
    .rs1_data_o   (id_rs1_data),
    .rs2_data_o   (id_rs2_data),
    .imm_o        (id_imm)
  );

  // ====================================================================
  // EX
  // ====================================================================
  p_core_ex_stage u_ex_stage (
    .clk_i               (clk_i),
    .rst_ni              (rst_ni),
    .idex_en_i           (idex_en),
    .idex_valid_i        (idex_valid),
    .ex_advance_i        (ex_advance),
    .flush_i             (flush_mem),
    .id_pc_i             (ifid_pc),
    .id_instr_i          (ifid_instr),
    .id_instr_err_i      (ifid_err),
    .id_pred_i           (ifid_pred),
    .id_ctrl_i           (id_ctrl),
    .id_rd_i             (id_rd),
    .id_rs1_addr_i       (id_rs1_addr),
    .id_rs2_addr_i       (id_rs2_addr),
    .id_rs1_used_i       (id_rs1_used),
    .id_rs2_used_i       (id_rs2_used),
    .id_rs1_data_i       (id_rs1_data),
    .id_rs2_data_i       (id_rs2_data),
    .id_imm_i            (id_imm),
    .fwd_rs1_sel_i       (fwd_rs1_sel),
    .fwd_rs2_sel_i       (fwd_rs2_sel),
    .fwd_mem_i           (mem_fwd),
    .fwd_wb_i            (wb_data),
    .valid_o             (ex_valid),
    .ready_o             (ex_ready),
    .ctrl_o              (ex_ctrl),
    .rd_o                (ex_rd),
    .rs1_addr_o          (ex_rs1_addr),
    .rs2_addr_o          (ex_rs2_addr),
    .rs1_used_o          (ex_rs1_used),
    .rs2_used_o          (ex_rs2_used),
    .pc_o                (ex_pc),
    .instr_o             (ex_instr),
    .instr_err_o         (ex_instr_err),
    .rs1_o               (ex_rs1),
    .rs2_o               (ex_rs2),
    .result_o            (ex_result),
    .csr_wdata_o         (ex_csr_wdata),
    .npc_o               (ex_npc),
    .target_o            (ex_target),
    .taken_o             (ex_taken),
    .target_misaligned_o (ex_target_misaligned),
    .mispredict_o        (ex_mispredict),
    .md_busy_o           (ex_md_busy),
    .bp_upd_en_o         (bp_upd_en),
    .bp_upd_bht_o        (bp_upd_bht),
    .bp_upd_btb_hit_o    (bp_upd_btb_hit)
  );

  // ====================================================================
  // MEM and WB
  // ====================================================================
  p_core_mem_stage u_mem_stage (
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),
    .exmem_en_i             (exmem_en),
    .exmem_valid_i          (exmem_valid),
    .ex_pc_i                (ex_pc),
    .ex_instr_i             (ex_instr),
    .ex_instr_err_i         (ex_instr_err),
    .ex_ctrl_i              (ex_ctrl),
    .ex_rd_i                (ex_rd),
    .ex_rs1_addr_i          (ex_rs1_addr),
    .ex_rs2_addr_i          (ex_rs2_addr),
    .ex_rs1_i               (ex_rs1),
    .ex_rs2_i               (ex_rs2),
    .ex_result_i            (ex_result),
    .ex_csr_wdata_i         (ex_csr_wdata),
    .ex_npc_i               (ex_npc),
    .ex_target_i            (ex_target),
    .ex_taken_i             (ex_taken),
    .ex_target_misaligned_i (ex_target_misaligned),
    .ex_mispredict_i        (ex_mispredict),
    .data_req_o             (data_req_o),
    .data_addr_o            (data_addr_o),
    .data_we_o              (data_we_o),
    .data_be_o              (data_be_o),
    .data_wdata_o           (data_wdata_o),
    .data_gnt_i             (data_gnt_i),
    .data_rvalid_i          (data_rvalid_i),
    .data_rdata_i           (data_rdata_i),
    .data_err_i             (data_err_i),
    .csr_rdata_i            (csr_rdata),
    .csr_illegal_i          (csr_illegal),
    .csr_en_o               (csr_en),
    .csr_write_o            (csr_write),
    .csr_op_o               (csr_op),
    .csr_addr_o             (csr_addr),
    .csr_wdata_o            (csr_wdata),
    .csr_commit_o           (csr_commit),
    .trap_i                 (trap_taken),
    .exc_instr_err_o        (exc_instr_err),
    .exc_illegal_o          (exc_illegal),
    .exc_ecall_o            (exc_ecall),
    .exc_ebreak_o           (exc_ebreak),
    .exc_mret_o             (exc_mret),
    .exc_instr_misaligned_o (exc_instr_misaligned),
    .exc_instr_target_o     (exc_instr_target),
    .exc_mem_req_o          (exc_mem_req),
    .exc_mem_we_o           (exc_mem_we),
    .exc_mem_misaligned_o   (exc_mem_misaligned),
    .exc_mem_err_o          (exc_mem_err),
    .exc_mem_addr_o         (exc_mem_addr),
    .valid_o                (mem_valid),
    .ready_o                (mem_ready),
    .rf_we_o                (mem_rf_we),
    .late_o                 (mem_late),
    .rd_o                   (mem_rd),
    .fwd_o                  (mem_fwd),
    .commit_o               (mem_commit),
    .retire_o               (mem_retire),
    .fence_i_o              (mem_fence_i),
    .pc_o                   (mem_pc),
    .npc_o                  (mem_npc),
    .wb_valid_o             (wb_valid),
    .wb_rf_we_o             (wb_rf_we),
    .wb_rd_o                (wb_rd),
    .wb_data_o              (wb_data),
    .perf_branch_o          (perf_branch),
    .perf_branch_taken_o    (perf_branch_taken),
    .perf_mem_o             (perf_mem),
    .perf_mispredict_o      (perf_mispredict),
    .rvfi_insn_o            (rvfi_insn),
    .rvfi_rs1_addr_o        (rvfi_rs1_addr),
    .rvfi_rs2_addr_o        (rvfi_rs2_addr),
    .rvfi_rs1_rdata_o       (rvfi_rs1_rdata),
    .rvfi_rs2_rdata_o       (rvfi_rs2_rdata),
    .rvfi_rd_addr_o         (rvfi_rd_addr),
    .rvfi_rd_wdata_o        (rvfi_rd_wdata),
    .rvfi_mem_rmask_o       (rvfi_mem_rmask),
    .rvfi_mem_wmask_o       (rvfi_mem_wmask),
    .rvfi_mem_rdata_o       (rvfi_mem_rdata),
    .rvfi_mem_wdata_o       (rvfi_mem_wdata)
  );

  // ====================================================================
  // Hazard, stall and forwarding control
  // ====================================================================
  p_core_hazard u_hazard (
    .ifid_valid_i    (ifid_valid),
    .id_rs1_addr_i   (id_rs1_addr),
    .id_rs2_addr_i   (id_rs2_addr),
    .id_rs1_used_i   (id_rs1_used),
    .id_rs2_used_i   (id_rs2_used),
    .id_is_store_i   (id_ctrl.base.mem_req & id_ctrl.base.mem_we),
    .ex_valid_i      (ex_valid),
    .ex_ready_i      (ex_ready),
    .ex_rf_we_i      (ex_ctrl.base.rf_we),
    .ex_late_i       ((ex_ctrl.base.mem_req & ~ex_ctrl.base.mem_we) |
                      ex_ctrl.base.csr_en),
    .ex_rd_i         (ex_rd),
    .ex_rs1_addr_i   (ex_rs1_addr),
    .ex_rs2_addr_i   (ex_rs2_addr),
    .ex_mispredict_i (ex_mispredict),
    .mem_valid_i     (mem_valid),
    .mem_ready_i     (mem_ready),
    .mem_rf_we_i     (mem_rf_we),
    .mem_late_i      (mem_late),
    .mem_rd_i        (mem_rd),
    .flush_mem_i     (flush_mem),
    .wb_valid_i      (wb_valid),
    .wb_rf_we_i      (wb_rf_we),
    .wb_rd_i         (wb_rd),
    .ifid_accept_o   (ifid_accept),
    .idex_en_o       (idex_en),
    .idex_valid_o    (idex_valid),
    .ex_advance_o    (ex_advance),
    .exmem_en_o      (exmem_en),
    .exmem_valid_o   (exmem_valid),
    .flush_ex_o      (flush_ex),
    .fwd_rs1_sel_o   (fwd_rs1_sel),
    .fwd_rs2_sel_o   (fwd_rs2_sel),
    .id_stall_o      (id_stall),
    .interlock_o     (interlock)
  );

  // ====================================================================
  // Machine-mode CSR file
  // ====================================================================
  logic [NUM_PPERF-1:0] hpm_event;
  assign hpm_event[PERF_STALL]       = id_stall;
  assign hpm_event[PERF_BRANCH]      = perf_branch;
  assign hpm_event[PERF_BR_TAKEN]    = perf_branch_taken;
  assign hpm_event[PERF_MEM]         = perf_mem;
  assign hpm_event[PPERF_MISPREDICT] = perf_mispredict;
  assign hpm_event[PPERF_MD_BUSY]    = ex_md_busy;
  assign hpm_event[PPERF_LOAD_USE]   = interlock;

  csr_unit #(
    .HART_ID (HART_ID),
    .MISA    (MISA_RV32IM),
    .NUM_HPM (NUM_PPERF)
  ) u_csr (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .csr_en_i        (csr_en),
    .csr_write_i     (csr_write),
    .csr_op_i        (csr_op),
    .csr_addr_i      (csr_addr),
    .csr_wdata_i     (csr_wdata),
    .csr_commit_i    (csr_commit),
    .csr_rdata_o     (csr_rdata),
    .csr_illegal_o   (csr_illegal),
    .trap_i          (trap_taken),
    .trap_pc_i       (trap_epc),
    .trap_cause_i    (trap_cause),
    .trap_is_irq_i   (trap_is_irq),
    .trap_tval_i     (trap_tval),
    .mret_i          (trap_redirect & ~trap_taken),
    .mtvec_o         (mtvec),
    .mepc_o          (mepc),
    .mstatus_mie_o   (mstatus_mie),
    .mip_o           (mip),
    .mie_o           (mie),
    .irq_timer_i     (irq_timer_i),
    .irq_software_i  (irq_software_i),
    .irq_external_i  (irq_external_i),
    .instr_retired_i (mem_retire),
    .hpm_event_i     (hpm_event)
  );

  // ====================================================================
  // Exception prioritisation and trap entry, at MEM
  // ====================================================================
  e_core_trap u_trap (
    .valid_i            (mem_valid),
    .commit_i           (mem_commit),
    .pc_i               (mem_pc),
    .instr_i            (rvfi_insn),
    .instr_err_i        (exc_instr_err),
    .illegal_i          (exc_illegal),
    .ecall_i            (exc_ecall),
    .ebreak_i           (exc_ebreak),
    .instr_misaligned_i (exc_instr_misaligned),
    .instr_target_i     (exc_instr_target),
    .mem_req_i          (exc_mem_req),
    .mem_we_i           (exc_mem_we),
    .mem_misaligned_i   (exc_mem_misaligned),
    .mem_err_i          (exc_mem_err),
    .mem_addr_i         (exc_mem_addr),
    .mstatus_mie_i      (mstatus_mie),
    .mie_i              (mie),
    .mip_i              (mip),
    .mret_i             (exc_mret),
    .mepc_i             (mepc),
    .mtvec_i            (mtvec),
    .trap_o             (trap_taken),
    .cause_o            (trap_cause),
    .is_irq_o           (trap_is_irq),
    .tval_o             (trap_tval),
    .epc_o              (trap_epc),
    .redirect_o         (trap_redirect),
    .redirect_pc_o      (trap_redirect_pc)
  );

  // ====================================================================
  // RVFI trace port: one event per instruction that leaves MEM, retiring
  // or trapping.
  // ====================================================================
  logic [63:0] rvfi_order_q;
  logic        rvfi_event;

  assign rvfi_event = mem_retire | trap_taken;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvfi_order_q <= 64'd0;
    end else if (rvfi_event) begin
      rvfi_order_q <= rvfi_order_q + 64'd1;
    end
  end

  if (RVFI) begin : gen_rvfi
    assign rvfi_valid_o     = rvfi_event;
    assign rvfi_order_o     = rvfi_order_q;
    assign rvfi_insn_o      = rvfi_insn;
    assign rvfi_trap_o      = trap_taken;
    assign rvfi_halt_o      = 1'b0;   // this core never stops fetching
    assign rvfi_intr_o      = trap_is_irq;
    assign rvfi_mode_o      = 2'b11;  // machine mode
    assign rvfi_ixl_o       = 2'b01;  // XLEN = 32
    assign rvfi_rs1_addr_o  = rvfi_rs1_addr;
    assign rvfi_rs2_addr_o  = rvfi_rs2_addr;
    assign rvfi_rs1_rdata_o = rvfi_rs1_rdata;
    assign rvfi_rs2_rdata_o = rvfi_rs2_rdata;
    assign rvfi_rd_addr_o   = rvfi_rd_addr;
    assign rvfi_rd_wdata_o  = rvfi_rd_wdata;
    assign rvfi_pc_rdata_o  = mem_pc;
    assign rvfi_pc_wdata_o  = trap_redirect ? trap_redirect_pc : mem_npc;
    assign rvfi_mem_addr_o  = data_addr_o;
    assign rvfi_mem_rmask_o = rvfi_mem_rmask;
    assign rvfi_mem_wmask_o = rvfi_mem_wmask;
    assign rvfi_mem_rdata_o = rvfi_mem_rdata;
    assign rvfi_mem_wdata_o = rvfi_mem_wdata;
  end else begin : gen_no_rvfi
    assign rvfi_valid_o     = 1'b0;
    assign rvfi_order_o     = 64'd0;
    assign rvfi_insn_o      = 32'd0;
    assign rvfi_trap_o      = 1'b0;
    assign rvfi_halt_o      = 1'b0;
    assign rvfi_intr_o      = 1'b0;
    assign rvfi_mode_o      = 2'b00;
    assign rvfi_ixl_o       = 2'b00;
    assign rvfi_rs1_addr_o  = 5'd0;
    assign rvfi_rs2_addr_o  = 5'd0;
    assign rvfi_rs1_rdata_o = 32'd0;
    assign rvfi_rs2_rdata_o = 32'd0;
    assign rvfi_rd_addr_o   = 5'd0;
    assign rvfi_rd_wdata_o  = 32'd0;
    assign rvfi_pc_rdata_o  = 32'd0;
    assign rvfi_pc_wdata_o  = 32'd0;
    assign rvfi_mem_addr_o  = 32'd0;
    assign rvfi_mem_rmask_o = 4'd0;
    assign rvfi_mem_wmask_o = 4'd0;
    assign rvfi_mem_rdata_o = 32'd0;
    assign rvfi_mem_wdata_o = 32'd0;
  end

`ifndef SYNTHESIS
  // ====================================================================
  // Simulation assertions. Each states an invariant the design depends on
  // but that no single test necessarily observes, and stops the simulation
  // the cycle it breaks rather than letting it surface, if at all, as a
  // wrong value many instructions later.
  // ====================================================================
  logic        a_ireq_q, a_dreq_q;
  logic [31:0] a_iaddr_q, a_daddr_q, a_dwdata_q;
  logic        a_dwe_q;
  logic [3:0]  a_dbe_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_ireq_q <= 1'b0;
      a_dreq_q <= 1'b0;
    end else begin
      // Memory protocol: a request is held, unchanged, until granted.
      if (a_ireq_q) begin
        assert (instr_req_o && instr_addr_o == a_iaddr_q)
          else $error("p_core: instruction request dropped or changed before grant");
      end
      if (a_dreq_q) begin
        assert (data_req_o && data_addr_o == a_daddr_q && data_we_o == a_dwe_q &&
                data_be_o == a_dbe_q && data_wdata_o == a_dwdata_q)
          else $error("p_core: data request dropped or changed before grant");
      end
      a_ireq_q   <= instr_req_o & ~instr_gnt_i;
      a_iaddr_q  <= instr_addr_o;
      a_dreq_q   <= data_req_o & ~data_gnt_i;
      a_daddr_q  <= data_addr_o;
      a_dwe_q    <= data_we_o;
      a_dbe_q    <= data_be_o;
      a_dwdata_q <= data_wdata_o;

      // The interlock's guarantee: an operand EX actually uses never depends
      // on a value that is still being produced in MEM. (A store's data
      // operand is exempt; MEM supplies it.)
      if (ex_valid && mem_valid && mem_late && mem_rf_we && mem_rd != '0) begin
        assert (!(ex_rs1_used && ex_rs1_addr == mem_rd))
          else $error("p_core: EX consumes rs1 from an incomplete load/CSR in MEM");
        assert (!(ex_rs2_used && ex_rs2_addr == mem_rd &&
                  !(ex_ctrl.base.mem_req && ex_ctrl.base.mem_we)))
          else $error("p_core: EX consumes rs2 from an incomplete load/CSR in MEM");
      end

      // A branch redirect and a trap redirect are never both acted on.
      assert (!(flush_ex && flush_mem))
        else $error("p_core: EX and MEM redirect in the same cycle");

      // Only one instruction leaves MEM per cycle, and only a valid one.
      assert (!(mem_commit && !mem_valid))
        else $error("p_core: commit without a valid instruction in MEM");

      // A register write reaches the register file only from a retired
      // instruction.
      assert (!(wb_rf_we && !wb_valid))
        else $error("p_core: register write from an invalid WB slot");
    end
  end
`endif

  // Signals needed only by the assertions, which are compiled out of
  // synthesis, and fields the RVFI-off elaboration leaves unread.
  logic unused_top;
  assign unused_top = ^{ex_rs1_used, ex_rs2_used, mem_commit,
                        rvfi_insn, rvfi_rs1_addr, rvfi_rs2_addr,
                        rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_addr,
                        rvfi_rd_wdata, rvfi_mem_rmask, rvfi_mem_wmask,
                        rvfi_mem_rdata, rvfi_mem_wdata};

endmodule : p_core_top
