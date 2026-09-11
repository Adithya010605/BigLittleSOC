// ============================================================================
// e_core_hazard.sv  —  all stall, flush and forwarding control
//
// Purely combinational. Every decision about whether an instruction advances,
// whether a bubble is inserted, and where an operand comes from is made here.
// The stage modules contain no stall terms of their own; they expose what they
// are doing and obey the enables this unit produces. Keeping it in one place
// is what makes the stall behaviour reviewable and testable as a unit rather
// than an emergent property of five files.
//
// ---------------------------------------------------------------------------
// FORWARDING: S3 -> S2
// ---------------------------------------------------------------------------
// The S3 result is forwarded into the S2 operand muxes whenever S3 holds a
// valid instruction that writes a register other than x0 and S2 reads that
// register. The forwarded value feeds the ALU operands, the store data, the
// branch comparator and the JALR target adder alike.
//
// Forwarding is only possible when the S3 result actually exists during S3.
// It does for an ALU result and for a JAL/JALR link value; it does NOT for a
// load (the data has not returned) or for a CSR read (see below). Those two
// cases stall instead, which is what `load_use_hazard` and `csr_hazard`
// detect.
//
// Note that the register file is also write-first, so an S2 read of a register
// being written by S3 would return the new value anyway. The explicit muxes
// are still required, and are not redundant: the register file bypass is
// qualified by `rf_we_o`, which is only asserted in the cycle the instruction
// RETIRES. An instruction stalled in S3 waiting for memory has a valid ALU
// result long before it retires, and the forwarding path can deliver it while
// the write port is still idle.
//
// ---------------------------------------------------------------------------
// LOAD-USE HAZARD
// ---------------------------------------------------------------------------
// A load in S3 whose destination register is read by the instruction in S2
// cannot be forwarded: at the point S2 needs the operand, the load data has
// not come back from memory. S2 and S1 stall and a bubble is inserted into S3.
//
// With a memory that answers in the request cycle the stall lasts exactly one
// cycle: the load retires and writes the register file at the end of that
// cycle, so the dependent instruction reads the committed value on the next.
// With a slower memory the stall extends automatically, because the load does
// not retire until `rvalid` and therefore keeps `ex_ready_i` low. There is no
// separate multi-cycle case to get right — the same term covers both.
//
// ---------------------------------------------------------------------------
// CSR HAZARD
// ---------------------------------------------------------------------------
// A CSR instruction in S3 whose destination register is read by S2 is stalled
// rather than forwarded. The CSR read value is produced by csr_unit late in
// S3, after the address decode and the read-only/WARL checks, so routing it
// into the S2 operand muxes would put a CSR decode plus a mux in the branch
// comparator's path. CSR instructions are rare enough that a one-cycle stall
// costs nothing measurable, while the timing cost of forwarding them would be
// paid on every branch. The same one-cycle argument as the load-use case
// applies: the CSR instruction writes the register file when it retires, so
// the dependent instruction reads it on the following cycle.
// ============================================================================

module e_core_hazard
  import e_core_pkg::*;
(
  // ---- S2: the instruction in ID ----
  input  logic                  ifid_valid_i,
  input  logic [REG_ADDR_W-1:0] id_rs1_addr_i,
  input  logic [REG_ADDR_W-1:0] id_rs2_addr_i,
  input  logic                  id_rs1_used_i,
  input  logic                  id_rs2_used_i,

  // ---- S3: the instruction in EX ----
  // Only the four control bits that affect hazard resolution are passed in,
  // rather than the whole ctrl_t bundle. The dependency is then explicit in
  // the port list: adding a control signal cannot silently change stall
  // behaviour, and a reader can see at a glance exactly what this unit reacts
  // to.
  input  logic                  idex_valid_i,
  input  logic                  idex_rf_we_i,
  input  logic                  idex_mem_req_i,
  input  logic                  idex_mem_we_i,
  input  logic                  idex_csr_en_i,
  input  logic [REG_ADDR_W-1:0] idex_rd_i,
  input  logic                  ex_ready_i,     // S3 completes this cycle

  // ---- redirect and trap requests ----
  input  logic                  id_take_branch_i,
  // Asserted when the trap unit steers the PC (trap entry or MRET). The
  // instruction in S2 is on the wrong path and must not enter S3.
  input  logic                  flush_i,

  // ---- pipeline control ----
  output logic                  ifid_accept_o,  // S2 consumes the IF/ID entry
  output logic                  idex_en_o,      // ID/EX register updates
  output logic                  idex_valid_o,   // value loaded into its valid
  output logic                  if_redirect_o,  // flush S1 and steer the PC

  // ---- operand forwarding ----
  output logic                  fwd_rs1_o,
  output logic                  fwd_rs2_o,

  // ---- observability for the performance counters ----
  output logic                  stall_o         // S2 held back this cycle
);

  // --------------------------------------------------------------------
  // Does S3 hold a register write that S2 depends on?
  // --------------------------------------------------------------------
  logic ex_writes_reg;
  logic rs1_match, rs2_match;

  assign ex_writes_reg = idex_valid_i & idex_rf_we_i &
                         (idex_rd_i != {REG_ADDR_W{1'b0}});

  assign rs1_match = ex_writes_reg & id_rs1_used_i & (id_rs1_addr_i == idex_rd_i);
  assign rs2_match = ex_writes_reg & id_rs2_used_i & (id_rs2_addr_i == idex_rd_i);

  // A load's result is not available during S3; a CSR read's is available too
  // late to be worth routing into S2. Both stall instead of forwarding.
  logic ex_result_late;
  assign ex_result_late = (idex_mem_req_i & ~idex_mem_we_i) | idex_csr_en_i;

  logic dependency;
  assign dependency = rs1_match | rs2_match;

  logic data_hazard_stall;
  assign data_hazard_stall = ifid_valid_i & dependency & ex_result_late;

  // Forward only what is genuinely available this cycle.
  assign fwd_rs1_o = rs1_match & ~ex_result_late;
  assign fwd_rs2_o = rs2_match & ~ex_result_late;

  // --------------------------------------------------------------------
  // Pipeline advance
  //
  // S3 must be free before S2 can hand anything over, so every advance is
  // gated on ex_ready_i. When S3 is free but S2 is held back by a data
  // hazard, ID/EX is still written -- with valid cleared -- which is what
  // inserts the bubble.
  // --------------------------------------------------------------------
  logic id_advances;
  assign id_advances = ifid_valid_i & ex_ready_i & ~data_hazard_stall & ~flush_i;

  assign ifid_accept_o = id_advances;
  // The register is still written on a flush -- with valid cleared, which is
  // what drops the wrong-path instruction rather than letting it execute.
  assign idex_en_o     = ex_ready_i;
  assign idex_valid_o  = id_advances;

  // A taken branch or jump steers the PC only when the instruction actually
  // moves on to S3. Redirecting while it is stalled would flush S1 repeatedly
  // and re-fetch the same target for as long as the stall lasted.
  assign if_redirect_o = id_advances & id_take_branch_i;

  assign stall_o = ifid_valid_i & ~id_advances & ~flush_i;

endmodule : e_core_hazard
