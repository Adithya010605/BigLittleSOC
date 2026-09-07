// ============================================================================
// e_core_top.sv
//
// E-Core: RV32I_Zicsr, machine mode.
//
// ---------------------------------------------------------------------------
// MILESTONE M2 IMPLEMENTATION — SINGLE-CYCLE DATAPATH, NO PIPELINE REGISTERS
// ---------------------------------------------------------------------------
// This is the non-pipelined datapath called for by milestone M2. Exactly one
// instruction is in flight at a time, sequenced by a three-state machine that
// drives the two valid/ready memory ports. Its purpose is to prove out the
// memory protocol, the shared datapath modules and the testbench harness
// before pipeline registers and hazard logic are introduced at M3, which is
// when the body of this module is replaced by the IF/ID/EX stage
// instantiations. The PORT LIST below is final and does not change at M3.
//
// Scope of this version, stated precisely so nothing is silently missing:
//   * implemented: the full RV32I integer instruction set (LUI, AUIPC, JAL,
//     JALR, all branches, all loads and stores, all register-immediate and
//     register-register ALU operations) and FENCE/FENCE.I as architectural
//     NOPs;
//   * NOT implemented in this version: Zicsr, trap entry and MRET, and
//     interrupts. Those arrive with csr_unit.sv and e_core_trap.sv at M5.
//     Rather than mis-executing them, an instruction this version cannot
//     execute architecturally -- any SYSTEM instruction, or any word the
//     decoder rejects -- stops the core in a defined HALTED state and reports
//     itself on the RVFI trace port with rvfi_trap and rvfi_halt asserted.
//     The core issues no further memory requests and changes no architectural
//     state once halted. The testbench treats a halt as a test failure and
//     prints the offending PC and instruction word.
//
// Memory protocol: `*_req_o` is asserted until `*_gnt_i` is seen and never
// depends combinationally on `*_gnt_i`; `*_rvalid_i` may arrive in the same
// cycle as the grant or arbitrarily later.
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

  // ---- Interrupts (taken from M5; the pins exist from M2 so the SoC-level
  //      wiring and the timer model are stable across milestones) ----
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
  // Sequencer
  // --------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_FETCH,   // requesting and awaiting the instruction word
    ST_EXEC,    // instruction latched: decode, execute, and for non-memory
                // instructions retire in this same cycle
    ST_MEM,     // load or store outstanding on the data port
    ST_HALTED   // architecturally unimplementable instruction; see header
  } state_e;

  state_e state_q, state_d;

  // Port handshake bookkeeping: `*_gnt_q` records that the in-flight request
  // has already been accepted, so `*_req_o` drops while the response is still
  // outstanding and a second transaction is never issued by accident.
  logic instr_gnt_q, instr_gnt_d;
  logic data_gnt_q,  data_gnt_d;

  logic [31:0] pc_q, pc_d;
  logic [31:0] instr_q, instr_d;
  logic        instr_err_q, instr_err_d;

  // --------------------------------------------------------------------
  // Instruction fetch
  // --------------------------------------------------------------------
  assign instr_req_o  = (state_q == ST_FETCH) & ~instr_gnt_q;
  assign instr_addr_o = pc_q;

  // --------------------------------------------------------------------
  // Decode
  // --------------------------------------------------------------------
  logic [REG_ADDR_W-1:0] rs1_addr, rs2_addr, rd_addr;
  logic                  rs1_used, rs2_used;
  imm_sel_e              imm_sel;
  alu_op_e               alu_op;
  op_a_sel_e             op_a_sel;
  op_b_sel_e             op_b_sel;
  logic                  rf_we;
  wb_sel_e               wb_sel;
  logic                  mem_req, mem_we;
  mem_size_e             mem_size;
  logic                  mem_signed;
  logic                  is_branch, is_jump, is_jalr;
  logic [2:0]            br_op;
  logic                  csr_en;
  csr_op_e               csr_op;
  logic [CSR_ADDR_W-1:0] csr_addr;
  logic                  csr_use_imm, csr_read, csr_write;
  logic                  ecall, ebreak, mret, wfi, fence;
  logic                  illegal_instr;

  decoder u_decoder (
    .instr_i         (instr_q),
    .rs1_addr_o      (rs1_addr),
    .rs2_addr_o      (rs2_addr),
    .rd_addr_o       (rd_addr),
    .rs1_used_o      (rs1_used),
    .rs2_used_o      (rs2_used),
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
    .ecall_o         (ecall),
    .ebreak_o        (ebreak),
    .mret_o          (mret),
    .wfi_o           (wfi),
    .fence_o         (fence),
    .illegal_instr_o (illegal_instr)
  );

  logic [31:0] imm;
  imm_gen u_imm_gen (
    .instr_i   (instr_q[31:7]),
    .imm_sel_i (imm_sel),
    .imm_o     (imm)
  );

  // --------------------------------------------------------------------
  // Register file
  // --------------------------------------------------------------------
  logic [31:0] rs1_data, rs2_data;
  logic [31:0] rf_wdata;

  // The regfile write port is driven from registers, never combinationally
  // from this instruction's own result.
  //
  // Two reasons, and both matter. Correctness first: `regfile.sv` implements a
  // WRITE-FIRST bypass, which is exactly right when the writer (S3) and the
  // reader (S2) are different instructions, as they are once the pipeline
  // exists at M3. In a single-cycle datapath the writer and the reader are the
  // SAME instruction, so a bypass would make `add x1, x1, x2` read the value
  // it is in the middle of computing instead of the old x1. Second, it would
  // close a real combinational loop: the bypass makes rdata depend on we_i,
  // while we_i depends on whether the instruction commits, which depends on
  // the branch comparator and the JALR target, which depend on rdata.
  //
  // Committing through registers breaks both problems at once. The write lands
  // in the cycle after ST_EXEC (or after ST_MEM), which is always at or before
  // the next instruction's own ST_EXEC, so no instruction ever observes stale
  // architectural state.
  logic                  wb_we_q,   wb_we_d;
  logic [REG_ADDR_W-1:0] wb_addr_q, wb_addr_d;
  logic [31:0]           wb_data_q, wb_data_d;

  regfile u_regfile (
    .clk_i     (clk_i),
    .raddr_a_i (rs1_addr),
    .rdata_a_o (rs1_data),
    .raddr_b_i (rs2_addr),
    .rdata_b_o (rs2_data),
    .we_i      (wb_we_q),
    .waddr_i   (wb_addr_q),
    .wdata_i   (wb_data_q)
  );

  // --------------------------------------------------------------------
  // ALU
  // --------------------------------------------------------------------
  logic [31:0] alu_a, alu_b, alu_result;
  logic        cmp_eq, cmp_lt, cmp_ltu;

  always_comb begin
    unique case (op_a_sel)
      OP_A_PC:   alu_a = pc_q;
      OP_A_ZERO: alu_a = 32'd0;
      default:   alu_a = rs1_data;   // OP_A_RS1
    endcase
  end

  assign alu_b = (op_b_sel == OP_B_IMM) ? imm : rs2_data;

  alu u_alu (
    .operator_i  (alu_op),
    .operand_a_i (alu_a),
    .operand_b_i (alu_b),
    .result_o    (alu_result),
    .cmp_eq_o    (cmp_eq),
    .cmp_lt_o    (cmp_lt),
    .cmp_ltu_o   (cmp_ltu)
  );

  // --------------------------------------------------------------------
  // Branch comparator.
  // The ALU's own comparison outputs are only valid when it is driven as a
  // subtraction, which is not the case for a branch (the ALU is unused). A
  // dedicated comparator instance is therefore used, fed directly with rs1
  // and rs2. At M3 this becomes the ID-stage comparator that resolves
  // branches one stage earlier than the ALU.
  // --------------------------------------------------------------------
  logic br_eq, br_lt, br_ltu;
  logic [31:0] br_cmp_unused;

  alu u_branch_cmp (
    .operator_i  (ALU_SUB),
    .operand_a_i (rs1_data),
    .operand_b_i (rs2_data),
    .result_o    (br_cmp_unused),
    .cmp_eq_o    (br_eq),
    .cmp_lt_o    (br_lt),
    .cmp_ltu_o   (br_ltu)
  );

  logic branch_taken;
  always_comb begin
    unique case (br_op)
      BR_NE:   branch_taken = ~br_eq;
      BR_LT:   branch_taken = br_lt;
      BR_GE:   branch_taken = ~br_lt;
      BR_LTU:  branch_taken = br_ltu;
      BR_GEU:  branch_taken = ~br_ltu;
      default: branch_taken = br_eq;   // BR_EQ, and the two reserved encodings
                                       // which the decoder has already
                                       // rejected as illegal
    endcase
  end

  // --------------------------------------------------------------------
  // Control transfer targets
  // --------------------------------------------------------------------
  logic [31:0] pc_plus_4, pc_target, jalr_target, next_pc;

  assign pc_plus_4   = pc_q + 32'd4;
  assign pc_target   = pc_q + imm;                  // JAL and branches
  assign jalr_target = (rs1_data + imm) & ~32'd1;   // JALR clears bit 0

  always_comb begin
    if (is_jalr) begin
      next_pc = jalr_target;
    end else if (is_jump || (is_branch && branch_taken)) begin
      next_pc = pc_target;
    end else begin
      next_pc = pc_plus_4;
    end
  end

  // --------------------------------------------------------------------
  // Load/store unit
  // --------------------------------------------------------------------
  logic [3:0]  lsu_be;
  logic [31:0] lsu_wdata, lsu_rdata_ext;
  logic        lsu_misaligned;

  lsu u_lsu (
    .size_i           (mem_size),
    .sign_i           (mem_signed),
    .addr_lsb_i       (alu_result[1:0]),
    .wdata_i          (rs2_data),
    .be_o             (lsu_be),
    .wdata_aligned_o  (lsu_wdata),
    .rdata_i          (data_rdata_i),
    .rdata_ext_o      (lsu_rdata_ext),
    .misaligned_o     (lsu_misaligned)
  );

  assign data_req_o   = (state_q == ST_MEM) & ~data_gnt_q;
  assign data_addr_o  = {alu_result[31:2], 2'b00};
  assign data_we_o    = mem_we;
  assign data_be_o    = lsu_be;
  assign data_wdata_o = lsu_wdata;

  // --------------------------------------------------------------------
  // Writeback value
  // --------------------------------------------------------------------
  always_comb begin
    unique case (wb_sel)
      WB_MEM:  rf_wdata = lsu_rdata_ext;
      WB_PC4:  rf_wdata = pc_plus_4;
      WB_CSR:  rf_wdata = 32'd0;   // unreachable: CSR instructions halt in
                                   // this version, see the header
      default: rf_wdata = alu_result;   // WB_ALU
    endcase
  end

  // --------------------------------------------------------------------
  // What this version cannot execute architecturally.
  // Grouping the condition in one signal keeps the halt reason explicit and
  // means the M3 rewrite has a single place to replace with trap entry.
  // --------------------------------------------------------------------
  logic unimplemented;
  assign unimplemented = illegal_instr | ecall | ebreak | mret | wfi | csr_en |
                         instr_err_q | (mem_req & lsu_misaligned) |
                         (is_branch & branch_taken & |pc_target[1:0]) |
                         (is_jump & |next_pc[1:0]);

  // --------------------------------------------------------------------
  // Sequencer next-state and retirement
  // --------------------------------------------------------------------
  logic retire;          // an instruction completes architecturally this cycle
  logic mem_retire;      // it completes out of ST_MEM (a load or a store)

  always_comb begin
    state_d      = state_q;
    pc_d         = pc_q;
    instr_d      = instr_q;
    instr_err_d  = instr_err_q;
    instr_gnt_d  = instr_gnt_q;
    data_gnt_d   = data_gnt_q;
    retire       = 1'b0;
    mem_retire   = 1'b0;
    // The writeback register is a one-shot: it holds for exactly the cycle
    // after retirement, so each instruction writes the register file once.
    wb_we_d      = 1'b0;
    wb_addr_d    = rd_addr;
    wb_data_d    = rf_wdata;

    unique case (state_q)
      ST_FETCH: begin
        if (instr_rvalid_i) begin
          instr_d     = instr_rdata_i;
          instr_err_d = instr_err_i;
          instr_gnt_d = 1'b0;
          state_d     = ST_EXEC;
        end else if (instr_req_o && instr_gnt_i) begin
          instr_gnt_d = 1'b1;
        end
      end

      ST_EXEC: begin
        if (unimplemented) begin
          state_d = ST_HALTED;
        end else if (mem_req) begin
          data_gnt_d = 1'b0;
          state_d    = ST_MEM;
        end else begin
          wb_we_d = rf_we;
          pc_d    = next_pc;
          retire  = 1'b1;
          state_d = ST_FETCH;
        end
      end

      ST_MEM: begin
        if (data_rvalid_i) begin
          // A bus error on a load or store is an access fault, which needs
          // the trap machinery that arrives at M5.
          if (data_err_i) begin
            state_d = ST_HALTED;
          end else begin
            wb_we_d    = rf_we;
            pc_d       = next_pc;
            retire     = 1'b1;
            mem_retire = 1'b1;
            state_d    = ST_FETCH;
          end
        end else if (data_req_o && data_gnt_i) begin
          data_gnt_d = 1'b1;
        end
      end

      default: begin   // ST_HALTED: nothing further happens
        state_d = ST_HALTED;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= ST_FETCH;
      pc_q        <= RESET_VECTOR;
      instr_q     <= 32'd0;
      instr_err_q <= 1'b0;
      instr_gnt_q <= 1'b0;
      data_gnt_q  <= 1'b0;
      wb_we_q     <= 1'b0;
      wb_addr_q   <= {REG_ADDR_W{1'b0}};
      wb_data_q   <= 32'd0;
    end else begin
      state_q     <= state_d;
      pc_q        <= pc_d;
      instr_q     <= instr_d;
      instr_err_q <= instr_err_d;
      instr_gnt_q <= instr_gnt_d;
      data_gnt_q  <= data_gnt_d;
      wb_we_q     <= wb_we_d;
      wb_addr_q   <= wb_addr_d;
      wb_data_q   <= wb_data_d;
    end
  end

  // --------------------------------------------------------------------
  // RVFI trace port
  // --------------------------------------------------------------------
  logic [63:0] rvfi_order_q;
  logic        halting;

  assign halting = (state_q == ST_EXEC && unimplemented) ||
                   (state_q == ST_MEM && data_rvalid_i && data_err_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvfi_order_q <= 64'd0;
    end else if (retire || halting) begin
      rvfi_order_q <= rvfi_order_q + 64'd1;
    end
  end

  if (RVFI) begin : gen_rvfi
    assign rvfi_valid_o     = retire | halting;
    assign rvfi_order_o     = rvfi_order_q;
    assign rvfi_insn_o      = instr_q;
    assign rvfi_trap_o      = halting;
    assign rvfi_halt_o      = halting;
    assign rvfi_intr_o      = 1'b0;
    assign rvfi_mode_o      = 2'b11;          // machine mode
    assign rvfi_ixl_o       = 2'b01;          // XLEN = 32
    assign rvfi_rs1_addr_o  = rs1_used ? rs1_addr : 5'd0;
    assign rvfi_rs2_addr_o  = rs2_used ? rs2_addr : 5'd0;
    assign rvfi_rs1_rdata_o = rs1_used ? rs1_data : 32'd0;
    assign rvfi_rs2_rdata_o = rs2_used ? rs2_data : 32'd0;
    assign rvfi_rd_addr_o   = wb_we_d ? rd_addr : 5'd0;
    assign rvfi_rd_wdata_o  = (wb_we_d && rd_addr != 5'd0) ? rf_wdata : 32'd0;
    assign rvfi_pc_rdata_o  = pc_q;
    assign rvfi_pc_wdata_o  = next_pc;
    assign rvfi_mem_addr_o  = data_addr_o;
    assign rvfi_mem_rmask_o = (mem_retire && !mem_we) ? lsu_be : 4'd0;
    assign rvfi_mem_wmask_o = (mem_retire &&  mem_we) ? lsu_be : 4'd0;
    assign rvfi_mem_rdata_o = data_rdata_i;
    assign rvfi_mem_wdata_o = lsu_wdata;
  end else begin : gen_no_rvfi
    // Tied off so synthesis prunes the trace logic entirely when RVFI is
    // disabled, which is the point of putting it behind a parameter.
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
  // Signals that this M2 version decodes but does not yet act on. They are
  // consumed here so that the intent is explicit rather than hidden behind a
  // lint waiver; every one of them is wired up for real at M5.
  // --------------------------------------------------------------------
  logic unused_m5;
  // rs1_used/rs2_used/mem_retire are consumed only by the RVFI generate arm,
  // so they are unused in the default RVFI=0 elaboration that `make lint`
  // checks; sinking them here keeps that elaboration warning-free without a
  // lint waiver.
  assign unused_m5 = ^{csr_op, csr_addr, csr_use_imm, csr_read, csr_write,
                       fence, irq_timer_i, irq_software_i, irq_external_i,
                       HART_ID, imm_sel, alu_op, cmp_eq, cmp_lt, cmp_ltu,
                       rs1_used, rs2_used, mem_retire, br_cmp_unused,
                       lsu_misaligned, is_jalr};

endmodule : e_core_top
