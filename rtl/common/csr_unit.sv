// ============================================================================
// csr_unit.sv — machine-mode control and status registers.
//
// Holds the architectural CSR state, performs the Zicsr read-modify-write,
// enforces read-only and WARL behaviour, and maintains the counters.
//
// Access rules:
//   * a write to a read-only CSR raises illegal-instruction;
//   * an access to an unimplemented CSR raises illegal-instruction;
//   * CSRRS/CSRRC with rs1 == x0 do not write, so they are legal against a
//     read-only CSR; the decoder computes that distinction and passes it in
//     as csr_write_i.
//
// There is no csr_read enable: none of the registers here has a read side
// effect, so whether an instruction architecturally "reads" the CSR changes
// nothing. Only the write side is qualified.
// ============================================================================

module csr_unit
  import e_core_pkg::*;
#(
  parameter logic [31:0] HART_ID = 32'h0000_0000
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // ---- Zicsr access from S3 ----
  input  logic                  csr_en_i,        // a CSR instruction is here
  input  logic                  csr_write_i,     // it writes the CSR
  input  csr_op_e               csr_op_i,
  input  logic [CSR_ADDR_W-1:0] csr_addr_i,
  input  logic [31:0]           csr_wdata_i,     // rs1 value or zero-ext uimm
  input  logic                  csr_commit_i,    // the access actually retires
  output logic [31:0]           csr_rdata_o,
  output logic                  csr_illegal_o,

  // ---- trap entry and return ----
  input  logic                  trap_i,
  // mepc has bit 0 hardwired to zero, so only the upper bits are carried.
  input  logic [31:1]           trap_pc_i,
  input  logic [4:0]            trap_cause_i,
  input  logic                  trap_is_irq_i,
  input  logic [31:0]           trap_tval_i,
  input  logic                  mret_i,

  output logic [31:0]           mtvec_o,
  output logic [31:0]           mepc_o,
  output logic                  mstatus_mie_o,
  output logic [31:0]           mip_o,
  output logic [31:0]           mie_o,

  // ---- interrupt pins ----
  input  logic                  irq_timer_i,
  input  logic                  irq_software_i,
  input  logic                  irq_external_i,

  // ---- counter events ----
  input  logic                  instr_retired_i,
  input  logic                  stall_i,
  input  logic                  branch_i,
  input  logic                  branch_taken_i,
  input  logic                  mem_access_i
);

  // --------------------------------------------------------------------
  // Architectural state
  // --------------------------------------------------------------------
  logic        mstatus_mie_q,  mstatus_mie_d;
  logic        mstatus_mpie_q, mstatus_mpie_d;
  logic [31:0] mtvec_q,    mtvec_d;
  logic [31:0] mscratch_q, mscratch_d;
  logic [31:0] mepc_q,     mepc_d;
  logic [31:0] mcause_q,   mcause_d;
  logic [31:0] mtval_q,    mtval_d;
  logic [31:0] mie_q,      mie_d;
  logic        inhibit_cy_q, inhibit_cy_d;
  logic        inhibit_ir_q, inhibit_ir_d;

  logic [63:0] mcycle_q,   mcycle_d;
  logic [63:0] minstret_q, minstret_d;
  logic [63:0] mhpm_q [NUM_PERF];
  logic [63:0] mhpm_d [NUM_PERF];

  // mip is a read-only view of the interrupt pins.
  logic [31:0] mip;
  always_comb begin
    mip = 32'd0;
    mip[IRQ_M_SOFT_BIT]  = irq_software_i;
    mip[IRQ_M_TIMER_BIT] = irq_timer_i;
    mip[IRQ_M_EXT_BIT]   = irq_external_i;
  end

  logic [31:0] mstatus;
  always_comb begin
    mstatus = 32'd0;
    mstatus[MSTATUS_MIE_BIT]           = mstatus_mie_q;
    mstatus[MSTATUS_MPIE_BIT]          = mstatus_mpie_q;
    mstatus[MSTATUS_MPP_LSB +: 2]      = 2'b11;   // hardwired machine mode
  end

  assign mtvec_o       = mtvec_q;
  assign mepc_o        = mepc_q;
  assign mstatus_mie_o = mstatus_mie_q;
  assign mip_o         = mip;
  assign mie_o         = mie_q;

  // --------------------------------------------------------------------
  // Read
  // --------------------------------------------------------------------
  logic exists;      // the address names an implemented CSR
  logic read_only;   // ...and it cannot be written

  always_comb begin
    csr_rdata_o = 32'd0;
    exists      = 1'b1;
    read_only   = 1'b0;

    unique case (csr_addr_i)
      CSR_MSTATUS:       csr_rdata_o = mstatus;
      CSR_MISA:          begin csr_rdata_o = MISA_VALUE;  read_only = 1'b1; end
      CSR_MIE:           csr_rdata_o = mie_q;
      CSR_MTVEC:         csr_rdata_o = mtvec_q;
      CSR_MCOUNTINHIBIT: csr_rdata_o = {29'd0, inhibit_ir_q, 1'b0, inhibit_cy_q};
      CSR_MSCRATCH:      csr_rdata_o = mscratch_q;
      CSR_MEPC:          csr_rdata_o = mepc_q;
      CSR_MCAUSE:        csr_rdata_o = mcause_q;
      CSR_MTVAL:         csr_rdata_o = mtval_q;
      CSR_MIP:           begin csr_rdata_o = mip;         read_only = 1'b1; end

      CSR_MCYCLE:        csr_rdata_o = mcycle_q[31:0];
      CSR_MCYCLEH:       csr_rdata_o = mcycle_q[63:32];
      CSR_MINSTRET:      csr_rdata_o = minstret_q[31:0];
      CSR_MINSTRETH:     csr_rdata_o = minstret_q[63:32];

      CSR_MHPMCOUNTER3:  csr_rdata_o = mhpm_q[PERF_STALL][31:0];
      CSR_MHPMCOUNTER4:  csr_rdata_o = mhpm_q[PERF_BRANCH][31:0];
      CSR_MHPMCOUNTER5:  csr_rdata_o = mhpm_q[PERF_BR_TAKEN][31:0];
      CSR_MHPMCOUNTER6:  csr_rdata_o = mhpm_q[PERF_MEM][31:0];
      CSR_MHPMCOUNTER3H: csr_rdata_o = mhpm_q[PERF_STALL][63:32];
      CSR_MHPMCOUNTER4H: csr_rdata_o = mhpm_q[PERF_BRANCH][63:32];
      CSR_MHPMCOUNTER5H: csr_rdata_o = mhpm_q[PERF_BR_TAKEN][63:32];
      CSR_MHPMCOUNTER6H: csr_rdata_o = mhpm_q[PERF_MEM][63:32];

      CSR_MVENDORID,
      CSR_MARCHID,
      CSR_MIMPID:        begin csr_rdata_o = 32'd0;   read_only = 1'b1; end
      CSR_MHARTID:       begin csr_rdata_o = HART_ID; read_only = 1'b1; end

      default:           exists = 1'b0;
    endcase
  end

  // A CSR instruction is illegal if the register does not exist, or if it
  // would write a read-only register. CSRRS/CSRRC with rs1 == x0 do not write
  // and so remain legal against a read-only register.
  assign csr_illegal_o = csr_en_i & (~exists | (read_only & csr_write_i));

  // --------------------------------------------------------------------
  // Write value
  // --------------------------------------------------------------------
  logic [31:0] wdata;
  always_comb begin
    unique case (csr_op_i)
      CSR_OP_RS: wdata = csr_rdata_o |  csr_wdata_i;
      CSR_OP_RC: wdata = csr_rdata_o & ~csr_wdata_i;
      default:   wdata = csr_wdata_i;   // CSR_OP_RW
    endcase
  end

  // The write happens only when the instruction actually retires, so a CSR
  // access that is squashed by a trap in the same cycle leaves no trace.
  logic wr_en;
  assign wr_en = csr_en_i & csr_write_i & csr_commit_i & exists & ~read_only;

  // --------------------------------------------------------------------
  // Next-state
  // --------------------------------------------------------------------
  always_comb begin
    mstatus_mie_d  = mstatus_mie_q;
    mstatus_mpie_d = mstatus_mpie_q;
    mtvec_d        = mtvec_q;
    mscratch_d     = mscratch_q;
    mepc_d         = mepc_q;
    mcause_d       = mcause_q;
    mtval_d        = mtval_q;
    mie_d          = mie_q;
    inhibit_cy_d   = inhibit_cy_q;
    inhibit_ir_d   = inhibit_ir_q;

    // ---- explicit CSR writes ----
    if (wr_en) begin
      unique case (csr_addr_i)
        CSR_MSTATUS: begin
          mstatus_mie_d  = wdata[MSTATUS_MIE_BIT];
          mstatus_mpie_d = wdata[MSTATUS_MPIE_BIT];
          // MPP is WARL and hardwired to machine mode: writes are ignored.
        end
        CSR_MIE: begin
          mie_d = 32'd0;
          mie_d[IRQ_M_SOFT_BIT]  = wdata[IRQ_M_SOFT_BIT];
          mie_d[IRQ_M_TIMER_BIT] = wdata[IRQ_M_TIMER_BIT];
          mie_d[IRQ_M_EXT_BIT]   = wdata[IRQ_M_EXT_BIT];
        end
        // Direct mode only: the WARL mode field is forced to zero, and the
        // vector base is 4-byte aligned.
        CSR_MTVEC:         mtvec_d    = {wdata[31:2], 2'b00};
        CSR_MSCRATCH:      mscratch_d = wdata;
        CSR_MEPC:          mepc_d     = {wdata[31:1], 1'b0};   // bit 0 is 0
        CSR_MCAUSE:        mcause_d   = wdata;
        CSR_MTVAL:         mtval_d    = wdata;
        CSR_MCOUNTINHIBIT: begin
          inhibit_cy_d = wdata[0];
          inhibit_ir_d = wdata[2];
        end
        default: ;   // counters are handled in their own always_ff below
      endcase
    end

    // ---- trap entry overrides an explicit write in the same cycle ----
    if (trap_i) begin
      mepc_d         = {trap_pc_i, 1'b0};
      mcause_d       = {trap_is_irq_i, 26'd0, trap_cause_i};
      mtval_d        = trap_tval_i;
      mstatus_mpie_d = mstatus_mie_q;
      mstatus_mie_d  = 1'b0;
    end else if (mret_i) begin
      mstatus_mie_d  = mstatus_mpie_q;
      mstatus_mpie_d = 1'b1;
    end
  end

  // --------------------------------------------------------------------
  // Counters
  //
  // mcycle counts every cycle unless inhibited. minstret counts only retired
  // instructions -- never a flushed instruction and never a stall bubble.
  // The four custom counters feed the P-core comparison in Phase 2; their
  // semantics are fixed here and documented in docs/e_core_results.md:
  //   3  cycles in which S2 held an instruction back
  //   4  branch instructions retired (conditional branches only, not jumps)
  //   5  branch instructions retired with the condition true
  //   6  loads and stores retired
  // --------------------------------------------------------------------
  logic cyc_wr, cych_wr, ins_wr, insh_wr;
  assign cyc_wr  = wr_en & (csr_addr_i == CSR_MCYCLE);
  assign cych_wr = wr_en & (csr_addr_i == CSR_MCYCLEH);
  assign ins_wr  = wr_en & (csr_addr_i == CSR_MINSTRET);
  assign insh_wr = wr_en & (csr_addr_i == CSR_MINSTRETH);

  always_comb begin
    mcycle_d = mcycle_q + (inhibit_cy_q ? 64'd0 : 64'd1);
    if (cyc_wr)  mcycle_d[31:0]  = wdata;
    if (cych_wr) mcycle_d[63:32] = wdata;

    minstret_d = minstret_q +
                 ((instr_retired_i & ~inhibit_ir_q) ? 64'd1 : 64'd0);
    if (ins_wr)  minstret_d[31:0]  = wdata;
    if (insh_wr) minstret_d[63:32] = wdata;
  end

  logic [NUM_PERF-1:0] perf_event;
  assign perf_event[PERF_STALL]    = stall_i;
  assign perf_event[PERF_BRANCH]   = branch_i;
  assign perf_event[PERF_BR_TAKEN] = branch_taken_i;
  assign perf_event[PERF_MEM]      = mem_access_i;

  always_comb begin
    for (int unsigned i = 0; i < NUM_PERF; i++) begin
      mhpm_d[i] = mhpm_q[i] + (perf_event[i] ? 64'd1 : 64'd0);
    end
    if (wr_en) begin
      unique case (csr_addr_i)
        CSR_MHPMCOUNTER3:  mhpm_d[PERF_STALL][31:0]     = wdata;
        CSR_MHPMCOUNTER4:  mhpm_d[PERF_BRANCH][31:0]    = wdata;
        CSR_MHPMCOUNTER5:  mhpm_d[PERF_BR_TAKEN][31:0]  = wdata;
        CSR_MHPMCOUNTER6:  mhpm_d[PERF_MEM][31:0]       = wdata;
        CSR_MHPMCOUNTER3H: mhpm_d[PERF_STALL][63:32]    = wdata;
        CSR_MHPMCOUNTER4H: mhpm_d[PERF_BRANCH][63:32]   = wdata;
        CSR_MHPMCOUNTER5H: mhpm_d[PERF_BR_TAKEN][63:32] = wdata;
        CSR_MHPMCOUNTER6H: mhpm_d[PERF_MEM][63:32]      = wdata;
        default: ;
      endcase
    end
  end

  // --------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_mie_q  <= 1'b0;
      mstatus_mpie_q <= 1'b0;
      mtvec_q        <= 32'd0;
      mscratch_q     <= 32'd0;
      mepc_q         <= 32'd0;
      mcause_q       <= 32'd0;
      mtval_q        <= 32'd0;
      mie_q          <= 32'd0;
      inhibit_cy_q   <= 1'b0;
      inhibit_ir_q   <= 1'b0;
      mcycle_q       <= 64'd0;
      minstret_q     <= 64'd0;
      for (int unsigned i = 0; i < NUM_PERF; i++) begin
        mhpm_q[i] <= 64'd0;
      end
    end else begin
      mstatus_mie_q  <= mstatus_mie_d;
      mstatus_mpie_q <= mstatus_mpie_d;
      mtvec_q        <= mtvec_d;
      mscratch_q     <= mscratch_d;
      mepc_q         <= mepc_d;
      mcause_q       <= mcause_d;
      mtval_q        <= mtval_d;
      mie_q          <= mie_d;
      inhibit_cy_q   <= inhibit_cy_d;
      inhibit_ir_q   <= inhibit_ir_d;
      mcycle_q       <= mcycle_d;
      minstret_q     <= minstret_d;
      for (int unsigned i = 0; i < NUM_PERF; i++) begin
        mhpm_q[i] <= mhpm_d[i];
      end
    end
  end

endmodule : csr_unit
