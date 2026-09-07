// ============================================================================
// e_core_trap.sv — exception prioritisation and trap entry.
//
// Purely combinational. Collects every trap source reported by S3, picks the
// highest-priority one, and produces the cause, mtval and target PC that
// csr_unit and the IF stage need.
//
// Priority, highest first (RISC-V privileged spec, machine mode):
//
//   pri  cause  source
//    1     0    instruction address misaligned   (taken target not 4-aligned)
//    2     1    instruction access fault         (instr_err on the fetch)
//    3     2    illegal instruction              (decoder, or a bad CSR access)
//    4     3    breakpoint                       (EBREAK)
//    5     4    load address misaligned
//    6     5    load access fault                (data_err on a load)
//    7     6    store address misaligned
//    8     7    store access fault               (data_err on a store)
//    9    11    environment call from M-mode     (ECALL)
//
// Interrupts are checked separately and take precedence over any synchronous
// exception, because an interrupt is taken *instead of* the instruction rather
// than because of it: the instruction has not committed, so mepc points at it
// and it re-executes after MRET.
//
// That last property is exactly why a LOAD OR STORE IS NOT INTERRUPTIBLE here.
// A memory access commits at the bus when the request is granted, which is
// before the instruction reaches its completion cycle. Taking an interrupt at
// that point would leave the access already performed while mepc still pointed
// at the instruction, so MRET would perform it a second time. For an ordinary
// store that is a silent double-write; for a store to a device register it can
// livelock, which is how this was found -- an interrupt taken on the store that
// asserts a device's interrupt line re-ran that store after every MRET, so the
// handler cleared the source and the returning store immediately set it again.
//
// Excluding memory instructions costs nothing: instructions keep flowing, so
// the interrupt is simply taken on the next non-memory instruction instead.
// ============================================================================

module e_core_trap
  import e_core_pkg::*;
(
  // ---- the instruction in S3 ----
  input  logic        valid_i,          // S3 holds a real instruction
  input  logic        commit_i,         // ...and would complete this cycle
  input  logic [31:0] pc_i,
  input  logic [31:0] instr_i,

  // ---- synchronous exception sources ----
  input  logic        instr_err_i,      // the fetch itself faulted
  input  logic        illegal_i,        // decoder or CSR access
  input  logic        ecall_i,
  input  logic        ebreak_i,
  input  logic        instr_misaligned_i,
  input  logic [31:0] instr_target_i,   // the misaligned target address
  input  logic        mem_req_i,
  input  logic        mem_we_i,
  input  logic        mem_misaligned_i,
  input  logic        mem_err_i,        // bus error, valid with rvalid
  input  logic [31:0] mem_addr_i,

  // ---- interrupts ----
  input  logic        mstatus_mie_i,
  input  logic [31:0] mie_i,
  input  logic [31:0] mip_i,

  // ---- MRET ----
  input  logic        mret_i,
  input  logic [31:0] mepc_i,
  input  logic [31:0] mtvec_i,

  // ---- outputs ----
  output logic        trap_o,           // enter a trap this cycle
  output logic [4:0]  cause_o,
  output logic        is_irq_o,
  output logic [31:0] tval_o,
  output logic [31:1] epc_o,
  output logic        redirect_o,       // steer the PC (trap entry or MRET)
  output logic [31:0] redirect_pc_o
);

  // --------------------------------------------------------------------
  // Interrupts
  // --------------------------------------------------------------------
  logic [31:0] irq_pending;
  logic        irq_any;

  assign irq_pending = mie_i & mip_i;
  assign irq_any     = mstatus_mie_i & (|irq_pending);

  logic [4:0] irq_cause;
  always_comb begin
    // Fixed priority: external, then software, then timer, matching the order
    // the privileged spec recommends for simultaneous machine interrupts.
    if (irq_pending[IRQ_M_EXT_BIT]) begin
      irq_cause = IRQ_CAUSE_M_EXT;
    end else if (irq_pending[IRQ_M_SOFT_BIT]) begin
      irq_cause = IRQ_CAUSE_M_SOFT;
    end else begin
      irq_cause = IRQ_CAUSE_M_TIMER;
    end
  end

  // --------------------------------------------------------------------
  // Synchronous exceptions, in priority order
  // --------------------------------------------------------------------
  logic       exc_valid;
  logic [4:0] exc_cause;
  logic [31:0] exc_tval;

  always_comb begin
    exc_valid = 1'b1;

    if (instr_misaligned_i) begin
      exc_cause = EXC_INSTR_MISALIGNED;
      exc_tval  = instr_target_i;
    end else if (instr_err_i) begin
      exc_cause = EXC_INSTR_ACCESS;
      exc_tval  = pc_i;
    end else if (illegal_i) begin
      exc_cause = EXC_ILLEGAL_INSTR;
      exc_tval  = instr_i;             // the faulting instruction word
    end else if (ebreak_i) begin
      exc_cause = EXC_BREAKPOINT;
      exc_tval  = pc_i;
    end else if (mem_req_i && mem_misaligned_i && !mem_we_i) begin
      exc_cause = EXC_LOAD_MISALIGNED;
      exc_tval  = mem_addr_i;
    end else if (mem_req_i && mem_err_i && !mem_we_i) begin
      exc_cause = EXC_LOAD_ACCESS;
      exc_tval  = mem_addr_i;
    end else if (mem_req_i && mem_misaligned_i && mem_we_i) begin
      exc_cause = EXC_STORE_MISALIGNED;
      exc_tval  = mem_addr_i;
    end else if (mem_req_i && mem_err_i && mem_we_i) begin
      exc_cause = EXC_STORE_ACCESS;
      exc_tval  = mem_addr_i;
    end else if (ecall_i) begin
      exc_cause = EXC_ECALL_M;
      exc_tval  = 32'd0;
    end else begin
      exc_valid = 1'b0;
      exc_cause = EXC_ILLEGAL_INSTR;
      exc_tval  = 32'd0;
    end
  end

  // --------------------------------------------------------------------
  // Trap entry
  //
  // An interrupt is taken in preference to a synchronous exception, and only
  // at an instruction boundary -- commit_i is asserted only when S3 would
  // otherwise complete, so an interrupt never lands in the middle of a
  // multi-cycle memory access.
  // --------------------------------------------------------------------
  logic take_irq, take_exc;

  assign take_irq = valid_i & commit_i & irq_any & ~mem_req_i;
  assign take_exc = valid_i & exc_valid & ~take_irq;

  assign trap_o    = take_irq | take_exc;
  assign is_irq_o  = take_irq;
  assign cause_o   = take_irq ? irq_cause : exc_cause;
  assign tval_o    = take_irq ? 32'd0     : exc_tval;

  // mepc is the PC of the interrupted or faulting instruction, so that MRET
  // re-executes it. That is right for an interrupt and for every exception
  // here; ECALL and EBREAK handlers advance mepc by 4 themselves.
  assign epc_o = pc_i[31:1];

  // --------------------------------------------------------------------
  // Redirect: trap entry, or MRET
  // --------------------------------------------------------------------
  logic take_mret;
  assign take_mret = valid_i & commit_i & mret_i & ~trap_o;

  assign redirect_o    = trap_o | take_mret;
  assign redirect_pc_o = trap_o ? mtvec_i : mepc_i;

endmodule : e_core_trap
