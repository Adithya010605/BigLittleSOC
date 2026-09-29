// ============================================================================
// p_core_ex_stage.sv  —  EX: execute, branch resolution, multiply / divide
//
// Owns the ID/EX pipeline register, the operand forwarding muxes, the main
// ALU, the branch comparator and target adder, the multiplier and the divider,
// and the check of every instruction's predicted next pc against its real
// one.
//
// ---------------------------------------------------------------------------
// FORWARDING
// ---------------------------------------------------------------------------
// Each source operand is taken, in priority order, from
//   1. MEM  the EX/MEM result of the instruction one ahead (EX -> EX path)
//   2. WB   the MEM/WB value of the instruction two ahead  (MEM -> EX path)
//   3. the value captured into ID/EX
// The selects are computed by the hazard unit. The forwarded operands feed the
// ALU, the branch comparator, the JALR target, the multiplier and divider, the
// CSR write value and the store data alike.
//
// OPERAND REFRESH. An instruction can sit in EX for several cycles -- behind a
// busy MEM stage or on the multiplier -- while the instructions ahead of it
// drain out of WB. A value it was receiving by forwarding would then vanish,
// because the producer has left the pipeline. So whenever the ID/EX register
// is not being loaded, the forwarded operands are written back into it: the
// held instruction keeps the most recent value of each source register, and a
// producer that has left is no longer needed.
//
// ---------------------------------------------------------------------------
// BRANCH RESOLUTION AND MISPREDICTION
// ---------------------------------------------------------------------------
// The actual next pc is computed for EVERY instruction -- pc + 4 unless it is
// a taken branch or a jump -- and compared with the next pc the fetch stage
// predicted. Any difference is a mispredict, which covers a wrong direction, a
// wrong target (a JALR to a new address, a BTB alias), and a BTB hit on an
// instruction that is not a branch at all (a stale entry). The redirect is
// raised by the hazard unit only when the instruction actually leaves EX, so a
// stalled branch does not flush the front end repeatedly.
//
// A control transfer to a misaligned target is NOT treated as a mispredict:
// the instruction raises instruction-address-misaligned when it reaches MEM,
// the trap redirects fetch to mtvec, and fetch never goes to the misaligned
// address in the meantime.
// ============================================================================

module p_core_ex_stage
  import e_core_pkg::*;
  import p_core_pkg::*;
(
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // ---- ID/EX register control, from the hazard unit ----
  input  logic                  idex_en_i,       // load from ID (else refresh)
  input  logic                  idex_valid_i,    // valid bit to load
  input  logic                  ex_advance_i,    // instruction leaves EX
  input  logic                  flush_i,         // trap / MRET / FENCE.I in MEM

  // ---- from IF/ID and ID ----
  input  logic [31:0]           id_pc_i,
  input  logic [31:0]           id_instr_i,
  input  logic                  id_instr_err_i,
  input  pred_t                 id_pred_i,
  input  p_ctrl_t               id_ctrl_i,
  input  logic [REG_ADDR_W-1:0] id_rd_i,
  input  logic [REG_ADDR_W-1:0] id_rs1_addr_i,
  input  logic [REG_ADDR_W-1:0] id_rs2_addr_i,
  input  logic                  id_rs1_used_i,
  input  logic                  id_rs2_used_i,
  input  logic [31:0]           id_rs1_data_i,
  input  logic [31:0]           id_rs2_data_i,
  input  logic [31:0]           id_imm_i,

  // ---- forwarding ----
  input  logic [1:0]            fwd_rs1_sel_i,   // 0 ID/EX, 1 MEM, 2 WB
  input  logic [1:0]            fwd_rs2_sel_i,
  input  logic [31:0]           fwd_mem_i,
  input  logic [31:0]           fwd_wb_i,

  // ---- state of the instruction in EX, to the hazard unit and MEM ----
  output logic                  valid_o,
  output logic                  ready_o,         // result available this cycle
  output p_ctrl_t               ctrl_o,
  output logic [REG_ADDR_W-1:0] rd_o,
  output logic [REG_ADDR_W-1:0] rs1_addr_o,
  output logic [REG_ADDR_W-1:0] rs2_addr_o,
  output logic                  rs1_used_o,
  output logic                  rs2_used_o,
  output logic [31:0]           pc_o,
  output logic [31:0]           instr_o,
  output logic                  instr_err_o,
  output logic [31:0]           rs1_o,           // forwarded operands
  output logic [31:0]           rs2_o,
  output logic [31:0]           result_o,        // ALU / link / MUL / DIV
  output logic [31:0]           csr_wdata_o,
  output logic [31:0]           npc_o,           // actual next pc
  output logic [31:0]           target_o,        // control-transfer target
  output logic                  taken_o,         // branch taken, or a jump
  output logic                  target_misaligned_o,
  output logic                  mispredict_o,
  output logic                  md_busy_o,       // waiting on MUL / DIV

  // ---- predictor training ----
  output logic                  bp_upd_en_o,
  output logic [1:0]            bp_upd_bht_o,
  output logic                  bp_upd_btb_hit_o
);

  // --------------------------------------------------------------------
  // ID/EX pipeline register
  // --------------------------------------------------------------------
  logic                  valid_q;
  logic [31:0]           pc_q, instr_q, imm_q;
  logic                  instr_err_q;
  pred_t                 pred_q;
  p_ctrl_t               ctrl_q;
  logic [REG_ADDR_W-1:0] rd_q, rs1_addr_q, rs2_addr_q;
  logic                  rs1_used_q, rs2_used_q;
  logic [31:0]           rs1_q, rs2_q;

  logic [31:0] rs1_fwd, rs2_fwd;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q     <= 1'b0;
      pc_q        <= 32'd0;
      instr_q     <= 32'd0;
      imm_q       <= 32'd0;
      instr_err_q <= 1'b0;
      pred_q      <= '0;
      ctrl_q      <= '0;
      rd_q        <= '0;
      rs1_addr_q  <= '0;
      rs2_addr_q  <= '0;
      rs1_used_q  <= 1'b0;
      rs2_used_q  <= 1'b0;
      rs1_q       <= 32'd0;
      rs2_q       <= 32'd0;
    end else if (idex_en_i) begin
      valid_q     <= idex_valid_i;
      pc_q        <= id_pc_i;
      instr_q     <= id_instr_i;
      imm_q       <= id_imm_i;
      instr_err_q <= id_instr_err_i;
      pred_q      <= id_pred_i;
      ctrl_q      <= id_ctrl_i;
      rd_q        <= id_rd_i;
      rs1_addr_q  <= id_rs1_addr_i;
      rs2_addr_q  <= id_rs2_addr_i;
      rs1_used_q  <= id_rs1_used_i;
      rs2_used_q  <= id_rs2_used_i;
      rs1_q       <= id_rs1_data_i;
      rs2_q       <= id_rs2_data_i;
    end else begin
      // Operand refresh; see the header.
      rs1_q       <= rs1_fwd;
      rs2_q       <= rs2_fwd;
    end
  end

  // --------------------------------------------------------------------
  // Forwarding muxes
  // --------------------------------------------------------------------
  always_comb begin
    unique case (fwd_rs1_sel_i)
      2'd1:    rs1_fwd = fwd_mem_i;
      2'd2:    rs1_fwd = fwd_wb_i;
      default: rs1_fwd = rs1_q;
    endcase
    unique case (fwd_rs2_sel_i)
      2'd1:    rs2_fwd = fwd_mem_i;
      2'd2:    rs2_fwd = fwd_wb_i;
      default: rs2_fwd = rs2_q;
    endcase
  end

  // --------------------------------------------------------------------
  // Main ALU
  // --------------------------------------------------------------------
  logic [31:0] alu_a, alu_b, alu_result;
  logic        alu_eq_unused, alu_lt_unused, alu_ltu_unused;

  always_comb begin
    unique case (ctrl_q.base.op_a_sel)
      OP_A_PC:   alu_a = pc_q;
      OP_A_ZERO: alu_a = 32'd0;
      default:   alu_a = rs1_fwd;   // OP_A_RS1
    endcase
  end
  assign alu_b = (ctrl_q.base.op_b_sel == OP_B_IMM) ? imm_q : rs2_fwd;

  alu u_alu (
    .operator_i  (ctrl_q.base.alu_op),
    .operand_a_i (alu_a),
    .operand_b_i (alu_b),
    .result_o    (alu_result),
    .cmp_eq_o    (alu_eq_unused),
    .cmp_lt_o    (alu_lt_unused),
    .cmp_ltu_o   (alu_ltu_unused)
  );

  // --------------------------------------------------------------------
  // Branch comparator: a second ALU instance driven as rs1 - rs2, exactly as
  // the E-core builds its comparator, so the comparison logic exists once in
  // the design and is verified once by tb_alu. The main ALU is busy with
  // rs1 + imm during a branch and cannot be shared.
  // --------------------------------------------------------------------
  logic        cmp_eq, cmp_lt, cmp_ltu;
  logic [31:0] cmp_result_unused;

  alu u_branch_cmp (
    .operator_i  (ALU_SUB),
    .operand_a_i (rs1_fwd),
    .operand_b_i (rs2_fwd),
    .result_o    (cmp_result_unused),
    .cmp_eq_o    (cmp_eq),
    .cmp_lt_o    (cmp_lt),
    .cmp_ltu_o   (cmp_ltu)
  );

  logic branch_cond;
  always_comb begin
    unique case (br_op_e'(instr_q[14:12]))
      BR_NE:   branch_cond = ~cmp_eq;
      BR_LT:   branch_cond = cmp_lt;
      BR_GE:   branch_cond = ~cmp_lt;
      BR_LTU:  branch_cond = cmp_ltu;
      BR_GEU:  branch_cond = ~cmp_ltu;
      // BR_EQ, plus the two reserved encodings the decoder has already made
      // illegal, which clears is_branch.
      default: branch_cond = cmp_eq;
    endcase
  end

  // --------------------------------------------------------------------
  // Control transfer
  // --------------------------------------------------------------------
  logic [31:0] pc_plus4, pc_rel_target, jalr_target, target;
  logic        taken;

  assign pc_plus4      = pc_q + 32'd4;
  assign pc_rel_target = pc_q + imm_q;                    // JAL, branches
  assign jalr_target   = {alu_result[31:1], 1'b0};        // (rs1 + imm) & ~1
  assign target        = ctrl_q.is_jalr ? jalr_target : pc_rel_target;
  assign taken         = ctrl_q.base.is_jump | (ctrl_q.base.is_branch & branch_cond);

  assign target_misaligned_o = taken & (|target[1:0]);
  assign npc_o               = taken ? target : pc_plus4;
  assign mispredict_o        = valid_q & ~target_misaligned_o & (npc_o != pred_q.npc);
  assign target_o            = target;
  assign taken_o             = taken;

  // --------------------------------------------------------------------
  // Multiply and divide
  // --------------------------------------------------------------------
  logic        is_mul, is_div;
  logic        mul_done, div_done;
  logic [31:0] mul_result, div_result;

  assign is_mul = valid_q & ctrl_q.md_en & ~ctrl_q.md_op[2];
  assign is_div = valid_q & ctrl_q.md_en &  ctrl_q.md_op[2];

  p_core_mul u_mul (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .start_i  (is_mul),
    .kill_i   (flush_i),
    .ack_i    (ex_advance_i),
    .op_i     (ctrl_q.md_op[1:0]),
    .a_i      (rs1_fwd),
    .b_i      (rs2_fwd),
    .done_o   (mul_done),
    .result_o (mul_result)
  );

  p_core_div u_div (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .start_i  (is_div),
    .kill_i   (flush_i),
    .ack_i    (ex_advance_i),
    .op_i     (ctrl_q.md_op[1:0]),
    .a_i      (rs1_fwd),
    .b_i      (rs2_fwd),
    .done_o   (div_done),
    .result_o (div_result)
  );

  logic md_done;
  assign md_done   = ctrl_q.md_op[2] ? div_done : mul_done;
  assign ready_o   = ~ctrl_q.md_en | md_done;
  assign md_busy_o = valid_q & ctrl_q.md_en & ~md_done;

  // --------------------------------------------------------------------
  // Result
  // --------------------------------------------------------------------
  always_comb begin
    if (ctrl_q.md_en) begin
      result_o = ctrl_q.md_op[2] ? div_result : mul_result;
    end else if (ctrl_q.base.wb_sel == WB_PC4) begin
      result_o = pc_plus4;
    end else begin
      result_o = alu_result;   // also the load/store address
    end
  end

  // CSRRWI/CSRRSI/CSRRCI use the zero-extended uimm, which imm_gen placed in
  // the immediate under the IMM_Z format.
  assign csr_wdata_o = ctrl_q.csr_use_imm ? imm_q : rs1_fwd;

  // --------------------------------------------------------------------
  // Predictor training, once, as the instruction leaves EX.
  // --------------------------------------------------------------------
  assign bp_upd_en_o      = ex_advance_i & ~target_misaligned_o;
  assign bp_upd_bht_o     = pred_q.bht;
  assign bp_upd_btb_hit_o = pred_q.btb_hit;

  // --------------------------------------------------------------------
  assign valid_o     = valid_q;
  assign ctrl_o      = ctrl_q;
  assign rd_o        = rd_q;
  assign rs1_addr_o  = rs1_addr_q;
  assign rs2_addr_o  = rs2_addr_q;
  assign rs1_used_o  = rs1_used_q;
  assign rs2_used_o  = rs2_used_q;
  assign pc_o        = pc_q;
  assign instr_o     = instr_q;
  assign instr_err_o = instr_err_q;
  assign rs1_o       = rs1_fwd;
  assign rs2_o       = rs2_fwd;

  logic unused_ex;
  assign unused_ex = ^{alu_eq_unused, alu_lt_unused, alu_ltu_unused,
                       cmp_result_unused};

endmodule : p_core_ex_stage
