// ============================================================================
// e_core_top.sv
//
// E-Core: RV32I_Zicsr, machine mode, three-stage in-order pipeline.
//
//   S1  IF       PC, instruction fetch, skid buffer, redirect mux
//   S2  ID/RF    decode, register read, immediate, forwarding, branch
//                resolution
//   S3  EX/MEM/WB  ALU, data memory, load align/extend, register writeback
//
// Pipeline registers: IF/ID (inside e_core_if_stage) and ID/EX (inside
// e_core_ex_stage). Each carries a valid bit; a flush clears it.
//
// All stall, flush and forwarding decisions are made in e_core_hazard.sv.
// This module is wiring: it contains no control logic of its own beyond the
// RVFI trace assembly.
//
// Implemented: the full RV32I integer instruction set, Zicsr with a
// machine-mode CSR file and performance counters, the complete machine-mode
// exception set with correct priority, MRET, timer/software/external
// interrupts, FENCE/FENCE.I as architectural NOPs, EX->ID operand forwarding,
// load-use and CSR-use interlocks, branch and jump resolution in ID with a
// one-cycle penalty, and arbitrary-latency memory back-pressure on both ports.
// ============================================================================

module e_core_top
  import e_core_pkg::*;
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

  // ---- Interrupts (taken from M5) ----
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
  // S1 <-> S2
  // --------------------------------------------------------------------
  logic        ifid_valid, ifid_err;
  logic [31:0] ifid_pc, ifid_instr;
  logic        ifid_accept;
  logic        if_redirect;        // to the IF stage: steer the PC
  logic        branch_redirect;    // from the hazard unit: a taken branch/jump
  logic [31:0] if_redirect_pc;

  // --------------------------------------------------------------------
  // S2 <-> S3
  // --------------------------------------------------------------------
  logic [REG_ADDR_W-1:0] id_rs1_addr, id_rs2_addr, id_rd_addr;
  logic                  id_rs1_used, id_rs2_used;
  ctrl_t                 id_ctrl;
  logic [31:0]           id_rs1_data, id_rs2_data, id_imm;
  logic [CSR_ADDR_W-1:0] id_csr_addr;
  logic                  id_csr_use_imm;
  logic                  id_take_branch, id_is_branch, id_fence;
  logic [31:0]           id_branch_target;

  logic                  idex_valid;
  ctrl_t                 idex_ctrl;
  logic                  ex_commit;
  logic [31:0]           csr_rdata;
  logic                  csr_illegal;
  logic                  csr_en, csr_write, csr_commit;
  csr_op_e               csr_op;
  logic [CSR_ADDR_W-1:0] csr_addr;
  logic [31:0]           csr_wdata;
  logic                  exc_instr_err, exc_illegal, exc_ecall, exc_ebreak;
  logic                  exc_mret, exc_instr_misaligned;
  logic [31:0]           exc_instr_target;
  logic                  exc_mem_req, exc_mem_we, exc_mem_misaligned, exc_mem_err;
  logic [31:0]           exc_mem_addr;
  logic                  trap_taken, trap_is_irq;
  logic [4:0]            trap_cause;
  logic [31:0]           trap_tval;
  logic [31:1]           trap_epc;
  logic                  trap_redirect;
  logic [31:0]           trap_redirect_pc;
  logic [31:0]           mtvec, mepc, mip, mie;
  logic                  mstatus_mie;
  logic                  perf_branch, perf_branch_taken, perf_mem;
  logic [REG_ADDR_W-1:0] idex_rd;
  logic                  ex_ready, ex_retire;
  logic [31:0]           idex_pc, idex_instr, idex_pc_next;
  logic [REG_ADDR_W-1:0] idex_rs1_addr, idex_rs2_addr;
  logic [31:0]           idex_rs1_data, idex_rs2_data;
  logic [31:0]           ex_result;
  logic                  rf_we;
  logic [REG_ADDR_W-1:0] rf_waddr;
  logic [31:0]           rf_wdata;
  logic [3:0]            mem_rmask, mem_wmask;
  logic [31:0]           mem_rdata, mem_wdata;

  // --------------------------------------------------------------------
  // Hazard control
  // --------------------------------------------------------------------
  logic idex_en, idex_valid_next;
  logic fwd_rs1, fwd_rs2;
  logic id_stall;

  // --------------------------------------------------------------------
  // S1: instruction fetch
  // --------------------------------------------------------------------
  e_core_if_stage #(
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
    .redirect_i     (if_redirect),
    .redirect_pc_i  (if_redirect_pc),
    .ifid_accept_i  (ifid_accept),
    .ifid_valid_o   (ifid_valid),
    .ifid_pc_o      (ifid_pc),
    .ifid_instr_o   (ifid_instr),
    .ifid_err_o     (ifid_err)
  );

  // A trap or MRET steers the PC in preference to a taken branch, because the
  // branch is in S2 while the trapping instruction is in S3, one stage older.
  // Both the enable and the address have to be muxed: driving only the address
  // leaves a trap silently falling through to PC+4.
  assign if_redirect    = trap_redirect | branch_redirect;
  assign if_redirect_pc = trap_redirect ? trap_redirect_pc : id_branch_target;

  // --------------------------------------------------------------------
  // S2: decode and register read
  // --------------------------------------------------------------------
  e_core_id_stage u_id_stage (
    .clk_i            (clk_i),
    .ifid_valid_i     (ifid_valid),
    .ifid_pc_i        (ifid_pc),
    .ifid_instr_i     (ifid_instr),
    .fwd_rs1_i        (fwd_rs1),
    .fwd_rs2_i        (fwd_rs2),
    .ex_result_i      (ex_result),
    .rf_we_i          (rf_we),
    .rf_waddr_i       (rf_waddr),
    .rf_wdata_i       (rf_wdata),
    .rs1_addr_o       (id_rs1_addr),
    .rs2_addr_o       (id_rs2_addr),
    .rs1_used_o       (id_rs1_used),
    .rs2_used_o       (id_rs2_used),
    .ctrl_o           (id_ctrl),
    .rd_addr_o        (id_rd_addr),
    .rs1_data_o       (id_rs1_data),
    .rs2_data_o       (id_rs2_data),
    .imm_o            (id_imm),
    .csr_addr_o       (id_csr_addr),
    .csr_use_imm_o    (id_csr_use_imm),
    .take_branch_o    (id_take_branch),
    .branch_target_o  (id_branch_target),
    .is_branch_o      (id_is_branch),
    .fence_o          (id_fence)
  );

  // --------------------------------------------------------------------
  // S3: execute, memory, writeback
  // --------------------------------------------------------------------
  e_core_ex_stage u_ex_stage (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .idex_en_i          (idex_en),
    .idex_valid_i       (idex_valid_next),
    .id_pc_i            (ifid_pc),
    .id_instr_i         (ifid_instr),
    .id_ctrl_i          (id_ctrl),
    .id_rd_i            (id_rd_addr),
    .id_rs1_addr_i      (id_rs1_addr),
    .id_rs2_addr_i      (id_rs2_addr),
    .id_rs1_data_i      (id_rs1_data),
    .id_rs2_data_i      (id_rs2_data),
    .id_imm_i           (id_imm),
    .id_instr_err_i     (ifid_err),
    .id_branch_target_i (id_branch_target),
    .id_take_branch_i   (id_take_branch),
    .id_csr_addr_i      (id_csr_addr),
    .id_csr_use_imm_i   (id_csr_use_imm),
    .data_req_o         (data_req_o),
    .data_addr_o        (data_addr_o),
    .data_we_o          (data_we_o),
    .data_be_o          (data_be_o),
    .data_wdata_o       (data_wdata_o),
    .data_gnt_i         (data_gnt_i),
    .data_rvalid_i      (data_rvalid_i),
    .data_rdata_i       (data_rdata_i),
    .data_err_i         (data_err_i),
    .csr_rdata_i        (csr_rdata),
    .csr_illegal_i      (csr_illegal),
    .csr_en_o           (csr_en),
    .csr_write_o        (csr_write),
    .csr_op_o           (csr_op),
    .csr_addr_o         (csr_addr),
    .csr_wdata_o        (csr_wdata),
    .csr_commit_o       (csr_commit),
    .trap_i             (trap_taken),
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
    .ex_ready_o         (ex_ready),
    .idex_valid_o       (idex_valid),
    .idex_ctrl_o        (idex_ctrl),
    .idex_rd_o          (idex_rd),
    .ex_result_o        (ex_result),
    .rf_we_o            (rf_we),
    .rf_waddr_o         (rf_waddr),
    .rf_wdata_o         (rf_wdata),
    .commit_o           (ex_commit),
    .retire_o           (ex_retire),
    .idex_pc_o          (idex_pc),
    .idex_instr_o       (idex_instr),
    .idex_rs1_addr_o    (idex_rs1_addr),
    .idex_rs2_addr_o    (idex_rs2_addr),
    .idex_rs1_data_o    (idex_rs1_data),
    .idex_rs2_data_o    (idex_rs2_data),
    .idex_pc_next_o     (idex_pc_next),
    .perf_branch_o       (perf_branch),
    .perf_branch_taken_o (perf_branch_taken),
    .perf_mem_o          (perf_mem),
    .mem_rmask_o        (mem_rmask),
    .mem_wmask_o        (mem_wmask),
    .mem_rdata_o        (mem_rdata),
    .mem_wdata_o        (mem_wdata)
  );

  // --------------------------------------------------------------------
  // Hazard, stall and forwarding control
  // --------------------------------------------------------------------
  e_core_hazard u_hazard (
    .ifid_valid_i     (ifid_valid),
    .id_rs1_addr_i    (id_rs1_addr),
    .id_rs2_addr_i    (id_rs2_addr),
    .id_rs1_used_i    (id_rs1_used),
    .id_rs2_used_i    (id_rs2_used),
    .idex_valid_i     (idex_valid),
    .idex_rf_we_i     (idex_ctrl.rf_we),
    .idex_mem_req_i   (idex_ctrl.mem_req),
    .idex_mem_we_i    (idex_ctrl.mem_we),
    .idex_csr_en_i    (idex_ctrl.csr_en),
    .idex_rd_i        (idex_rd),
    .ex_ready_i       (ex_ready),
    .id_take_branch_i (id_take_branch),
    .flush_i          (trap_redirect),
    .ifid_accept_o    (ifid_accept),
    .idex_en_o        (idex_en),
    .idex_valid_o     (idex_valid_next),
    .if_redirect_o    (branch_redirect),
    .fwd_rs1_o        (fwd_rs1),
    .fwd_rs2_o        (fwd_rs2),
    .stall_o          (id_stall)
  );

  // --------------------------------------------------------------------
  // Machine-mode CSR file
  // --------------------------------------------------------------------
  logic [NUM_PERF-1:0] hpm_event;
  assign hpm_event[PERF_STALL]    = id_stall;
  assign hpm_event[PERF_BRANCH]   = perf_branch;
  assign hpm_event[PERF_BR_TAKEN] = perf_branch_taken;
  assign hpm_event[PERF_MEM]      = perf_mem;

  csr_unit #(
    .HART_ID (HART_ID),
    .MISA    (MISA_VALUE),
    .NUM_HPM (NUM_PERF)
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
    .instr_retired_i (ex_retire),
    .hpm_event_i     (hpm_event)
  );

  // --------------------------------------------------------------------
  // Exception prioritisation and trap entry
  // --------------------------------------------------------------------
  e_core_trap u_trap (
    .valid_i            (idex_valid),
    .commit_i           (ex_commit),
    .pc_i               (idex_pc),
    .instr_i            (idex_instr),
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

  // --------------------------------------------------------------------
  // RVFI trace port
  // --------------------------------------------------------------------
  logic [63:0] rvfi_order_q;
  logic        rvfi_event;

  assign rvfi_event = ex_retire | trap_taken;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvfi_order_q <= 64'd0;
    end else if (rvfi_event) begin
      rvfi_order_q <= rvfi_order_q + 64'd1;
    end
  end

  if (RVFI) begin : gen_rvfi
    // The trace reports the instruction in S3, which is the only stage where
    // an instruction is architecturally complete. rs1/rs2 values are the ones
    // captured into the ID/EX register, so they already reflect any forwarding
    // that took place in S2.
    assign rvfi_valid_o     = rvfi_event;
    assign rvfi_order_o     = rvfi_order_q;
    assign rvfi_insn_o      = idex_instr;
    assign rvfi_trap_o      = trap_taken;
    assign rvfi_halt_o      = 1'b0;   // this core never stops fetching
    assign rvfi_intr_o      = trap_is_irq;
    assign rvfi_mode_o      = 2'b11;   // machine mode
    assign rvfi_ixl_o       = 2'b01;   // XLEN = 32
    assign rvfi_rs1_addr_o  = idex_rs1_addr;
    assign rvfi_rs2_addr_o  = idex_rs2_addr;
    assign rvfi_rs1_rdata_o = idex_rs1_data;
    assign rvfi_rs2_rdata_o = idex_rs2_data;
    assign rvfi_rd_addr_o   = rf_we ? rf_waddr : 5'd0;
    assign rvfi_rd_wdata_o  = (rf_we && rf_waddr != 5'd0) ? rf_wdata : 32'd0;
    assign rvfi_pc_rdata_o  = idex_pc;
    assign rvfi_pc_wdata_o  = trap_redirect ? trap_redirect_pc : idex_pc_next;
    assign rvfi_mem_addr_o  = data_addr_o;
    assign rvfi_mem_rmask_o = mem_rmask;
    assign rvfi_mem_wmask_o = mem_wmask;
    assign rvfi_mem_rdata_o = mem_rdata;
    assign rvfi_mem_wdata_o = mem_wdata;
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

  // --------------------------------------------------------------------
  // Signals decoded now and consumed at M5 by csr_unit.sv / e_core_trap.sv,
  // and counters consumed by the performance counters. Sunk explicitly so
  // the intent is visible rather than hidden behind a lint waiver.
  // --------------------------------------------------------------------
  // The RVFI-only signals are also listed: they are consumed exclusively by
  // the gen_rvfi arm, so they are genuinely unused in the default RVFI=0
  // elaboration that `make lint` checks.
  logic unused_m5;
  assign unused_m5 = ^{id_is_branch, id_fence,
                       idex_ctrl.alu_op, idex_ctrl.op_a_sel, idex_ctrl.op_b_sel,
                       idex_ctrl.wb_sel, idex_ctrl.mem_size,
                       idex_ctrl.mem_signed, idex_ctrl.csr_op,
                       idex_ctrl.csr_read, idex_ctrl.csr_write,
                       idex_ctrl.is_branch, idex_ctrl.is_jump,
                       idex_ctrl.illegal, idex_ctrl.ecall, idex_ctrl.ebreak,
                       idex_ctrl.mret, idex_ctrl.wfi,
                       idex_pc_next,
                       idex_rs1_addr, idex_rs2_addr,
                       idex_rs1_data, idex_rs2_data,
                       mem_rmask, mem_wmask, mem_rdata, mem_wdata};

endmodule : e_core_top
