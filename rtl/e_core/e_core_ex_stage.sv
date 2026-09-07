// ============================================================================
// e_core_ex_stage.sv  —  Stage S3: execute, memory access, writeback
//
// Owns the ID/EX pipeline register, the main ALU, the load/store unit and the
// data-port handshake, and drives the register file write port back in S2.
//
// ---------------------------------------------------------------------------
// COMPLETION AND BACK-PRESSURE
// ---------------------------------------------------------------------------
// A non-memory instruction completes in the cycle it occupies this stage, so
// `ex_ready_o` is high and the ID/EX register accepts a new instruction every
// cycle. A load or store completes when `data_rvalid_i` arrives, which may be
// the same cycle as the request (a cache hit, or a zero-wait-state memory) or
// arbitrarily later. `ex_ready_o` is low until then, which back-pressures ID
// and, through it, IF.
//
// `data_req_o` is a function of the ID/EX register and `mem_gnt_q` only. It
// never depends combinationally on `data_gnt_i` or `data_rvalid_i`, which is
// the contract the memory model relies on. `mem_gnt_q` is cleared whenever a
// new instruction is accepted, so each memory instruction issues exactly one
// request and holds it until granted.
//
// ---------------------------------------------------------------------------
// THE M3 HALT
// ---------------------------------------------------------------------------
// As at M2, an instruction this milestone cannot execute architecturally —
// any Zicsr access, ECALL/EBREAK/MRET/WFI, an illegal encoding, a misaligned
// or faulting access — stops the core in a defined halted state and reports
// itself on the RVFI port with rvfi_trap and rvfi_halt set, rather than being
// mis-executed. Trap entry replaces this at M5, at which point `halt_o`
// becomes the trap request into e_core_trap.sv.
// ============================================================================

module e_core_ex_stage
  import e_core_pkg::*;
(
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // ---- ID/EX pipeline register control, from the hazard unit ----
  input  logic                  idex_en_i,      // update the register
  input  logic                  idex_valid_i,   // value to load into `valid`

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

  // ---- to the hazard unit ----
  output logic                  ex_ready_o,     // can accept a new instruction
  output logic                  idex_valid_o,
  output ctrl_t                 idex_ctrl_o,
  output logic [REG_ADDR_W-1:0] idex_rd_o,

  // ---- forwarding value and register file write port ----
  output logic [31:0]           ex_result_o,
  output logic                  rf_we_o,
  output logic [REG_ADDR_W-1:0] rf_waddr_o,
  output logic [31:0]           rf_wdata_o,

  // ---- retirement, for RVFI and the performance counters ----
  output logic                  retire_o,
  output logic                  halt_o,
  output logic [31:0]           idex_pc_o,
  output logic [31:0]           idex_instr_o,
  // The source operands as captured into ID/EX, so the trace port reports the
  // values the instruction actually executed with -- already forwarded, if
  // forwarding took place in S2. Exporting them keeps the top level free of
  // hierarchical references into this module.
  output logic [REG_ADDR_W-1:0] idex_rs1_addr_o,
  output logic [REG_ADDR_W-1:0] idex_rs2_addr_o,
  output logic [31:0]           idex_rs1_data_o,
  output logic [31:0]           idex_rs2_data_o,
  output logic [31:0]           idex_pc_next_o,
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
  logic [REG_ADDR_W-1:0] rd_q;
  logic [31:0]           rs1_q, rs2_q, imm_q;
  logic [REG_ADDR_W-1:0] rs1_addr_q, rs2_addr_q;
  logic                  instr_err_q;
  logic [31:0]           branch_target_q;
  logic                  take_branch_q;
  logic                  mem_gnt_q;

  assign idex_valid_o   = valid_q;
  assign idex_ctrl_o    = ctrl_q;
  assign idex_rd_o      = rd_q;
  assign idex_pc_o      = pc_q;
  assign idex_instr_o   = instr_q;
  assign idex_pc_next_o = take_branch_q ? branch_target_q : (pc_q + 32'd4);

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
      rs1_q           <= 32'd0;
      rs2_q           <= 32'd0;
      imm_q           <= 32'd0;
      rs1_addr_q      <= {REG_ADDR_W{1'b0}};
      rs2_addr_q      <= {REG_ADDR_W{1'b0}};
      instr_err_q     <= 1'b0;
      branch_target_q <= 32'd0;
      take_branch_q   <= 1'b0;
      mem_gnt_q       <= 1'b0;
    end else if (idex_en_i) begin
      valid_q         <= idex_valid_i;
      pc_q            <= id_pc_i;
      instr_q         <= id_instr_i;
      ctrl_q          <= id_ctrl_i;
      rd_q            <= id_rd_i;
      rs1_q           <= id_rs1_data_i;
      rs2_q           <= id_rs2_data_i;
      imm_q           <= id_imm_i;
      rs1_addr_q      <= id_rs1_addr_i;
      rs2_addr_q      <= id_rs2_addr_i;
      instr_err_q     <= id_instr_err_i;
      branch_target_q <= id_branch_target_i;
      take_branch_q   <= id_take_branch_i;
      // A newly accepted instruction has not yet had its memory request
      // granted, whatever the previous instruction did.
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
  // What this milestone cannot execute architecturally.
  // --------------------------------------------------------------------
  logic unimplemented;
  assign unimplemented = ctrl_q.illegal | ctrl_q.ecall | ctrl_q.ebreak |
                         ctrl_q.mret | ctrl_q.wfi | ctrl_q.csr_en |
                         instr_err_q |
                         (ctrl_q.mem_req & lsu_misaligned) |
                         (take_branch_q & (|branch_target_q[1:0]));

  // A memory request is suppressed for an instruction that is going to halt,
  // so a misaligned or otherwise faulting access never reaches the bus.
  logic mem_active;
  assign mem_active = valid_q & ctrl_q.mem_req & ~unimplemented;

  assign data_req_o   = mem_active & ~mem_gnt_q;
  assign data_addr_o  = {alu_result[31:2], 2'b00};
  assign data_we_o    = ctrl_q.mem_we;
  assign data_be_o    = lsu_be;
  assign data_wdata_o = lsu_wdata;

  // --------------------------------------------------------------------
  // Completion
  // --------------------------------------------------------------------
  assign ex_ready_o = ~mem_active | data_rvalid_i;

  assign halt_o = valid_q & (unimplemented |
                             (mem_active & data_rvalid_i & data_err_i));

  assign retire_o = valid_q & ex_ready_o & ~halt_o;

  // --------------------------------------------------------------------
  // Writeback
  // --------------------------------------------------------------------
  always_comb begin
    unique case (ctrl_q.wb_sel)
      WB_MEM:  ex_result_o = lsu_rdata_ext;
      WB_PC4:  ex_result_o = pc_q + 32'd4;
      // WB_CSR is unreachable at this milestone: a CSR instruction halts
      // above. csr_unit.sv drives this arm from M5.
      WB_CSR:  ex_result_o = 32'd0;
      default: ex_result_o = alu_result;   // WB_ALU
    endcase
  end

  assign rf_we_o    = retire_o & ctrl_q.rf_we;
  assign rf_waddr_o = rd_q;
  assign rf_wdata_o = ex_result_o;

  // --------------------------------------------------------------------
  // Memory access reporting for RVFI
  // --------------------------------------------------------------------
  assign mem_rmask_o = (retire_o & mem_active & ~ctrl_q.mem_we) ? lsu_be : 4'd0;
  assign mem_wmask_o = (retire_o & mem_active &  ctrl_q.mem_we) ? lsu_be : 4'd0;
  assign mem_rdata_o = data_rdata_i;
  assign mem_wdata_o = lsu_wdata;

  logic unused_ex;
  assign unused_ex = ^{cmp_eq_unused, cmp_lt_unused, cmp_ltu_unused,
                       ctrl_q.csr_op, ctrl_q.csr_read, ctrl_q.csr_write,
                       ctrl_q.is_branch, ctrl_q.is_jump};

endmodule : e_core_ex_stage
