// ============================================================================
// p_core_hazard.sv  —  all stall, flush and forwarding control
//
// Purely combinational. As in the E-core, every decision about whether an
// instruction advances, whether a bubble is inserted, and where an operand
// comes from is made here; the stage modules expose their state and obey the
// enables this unit produces.
//
// ---------------------------------------------------------------------------
// ADVANCE
// ---------------------------------------------------------------------------
// The pipeline drains from the back. WB always completes. MEM completes when
// its access does (mem_ready). EX completes when its result exists (ex_ready:
// immediately, or when the multiplier / divider finishes). Each stage hands
// on only when the stage after it will be free at the end of the cycle:
//
//   mem_free   = MEM empty, or MEM completes
//   ex_advance = EX valid & EX ready & mem_free & no flush
//   ex_free    = EX empty, or EX advances
//   id_advance = IF/ID valid & ex_free & no interlock & no flush
//
// A stage that is free but receives nothing is loaded with a bubble.
//
// ---------------------------------------------------------------------------
// FLUSHES
// ---------------------------------------------------------------------------
//   flush_mem   (trap entry, MRET, or a FENCE.I retiring, all in MEM)
//               kills EX, ID and IF; the instruction in MEM is the one taking
//               the trap or is complete.
//   flush_ex    (a mispredicted instruction leaving EX)
//               kills ID and IF; the mispredicted instruction itself is
//               correct and moves on to MEM.
// flush_mem wins, because the instruction in MEM is older.
//
// ---------------------------------------------------------------------------
// FORWARDING (into EX)
// ---------------------------------------------------------------------------
//   EX -> EX   from the instruction in MEM, when its value was made in EX
//   MEM -> EX  from the instruction in WB
// The instruction in MEM takes priority: it is the younger of the two, so it
// holds the newer value of the register.
//
// ---------------------------------------------------------------------------
// INTERLOCK (the only data-hazard stall)
// ---------------------------------------------------------------------------
// A load's data and a CSR read's value are produced during MEM, too late to
// be forwarded from MEM into EX. An instruction that needs such a value is
// held in ID until the producer is at least as far as WB at the time the
// consumer is in EX:
//
//   * the producer is in EX: hold. Next cycle it is in MEM at best.
//   * the producer is in MEM and does not complete this cycle: hold.
//   * the producer is in MEM and completes this cycle: release. Next cycle
//     it is in WB and the consumer in EX, and MEM -> EX supplies the value.
//
// With a single-cycle memory that is exactly the classic one-cycle load-use
// bubble; a slower memory extends it automatically.
//
// One consumer is exempt: the DATA operand (rs2) of a store. It does not need
// the value until the store is in MEM, by which time the load is in WB, and
// the MEM stage's own WB -> MEM path supplies it. A load followed by a store
// of the loaded value -- a copy loop -- therefore runs without a bubble.
// ============================================================================

module p_core_hazard
  import e_core_pkg::*;
(
  // ---- ID: the instruction in IF/ID ----
  input  logic                  ifid_valid_i,
  input  logic [REG_ADDR_W-1:0] id_rs1_addr_i,
  input  logic [REG_ADDR_W-1:0] id_rs2_addr_i,
  input  logic                  id_rs1_used_i,
  input  logic                  id_rs2_used_i,
  input  logic                  id_is_store_i,

  // ---- EX ----
  input  logic                  ex_valid_i,
  input  logic                  ex_ready_i,
  input  logic                  ex_rf_we_i,
  input  logic                  ex_late_i,
  input  logic [REG_ADDR_W-1:0] ex_rd_i,
  input  logic [REG_ADDR_W-1:0] ex_rs1_addr_i,
  input  logic [REG_ADDR_W-1:0] ex_rs2_addr_i,
  input  logic                  ex_mispredict_i,

  // ---- MEM ----
  input  logic                  mem_valid_i,
  input  logic                  mem_ready_i,
  input  logic                  mem_rf_we_i,
  input  logic                  mem_late_i,
  input  logic [REG_ADDR_W-1:0] mem_rd_i,
  input  logic                  flush_mem_i,     // trap / MRET / FENCE.I

  // ---- WB ----
  input  logic                  wb_valid_i,
  input  logic                  wb_rf_we_i,
  input  logic [REG_ADDR_W-1:0] wb_rd_i,

  // ---- pipeline control ----
  output logic                  ifid_accept_o,   // ID consumes IF/ID
  output logic                  idex_en_o,       // ID/EX loads (else refresh)
  output logic                  idex_valid_o,
  output logic                  ex_advance_o,
  output logic                  exmem_en_o,
  output logic                  exmem_valid_o,
  output logic                  flush_ex_o,      // EX redirects fetch

  // ---- forwarding into EX: 0 ID/EX, 1 MEM, 2 WB ----
  output logic [1:0]            fwd_rs1_sel_o,
  output logic [1:0]            fwd_rs2_sel_o,

  // ---- observability ----
  output logic                  id_stall_o,      // ID held a valid instruction
  output logic                  interlock_o      // ...because of the interlock
);

  // --------------------------------------------------------------------
  // Register dependencies of the instruction in ID
  // --------------------------------------------------------------------
  logic ex_writes, mem_writes;
  assign ex_writes  = ex_valid_i  & ex_rf_we_i  & (ex_rd_i  != '0);
  assign mem_writes = mem_valid_i & mem_rf_we_i & (mem_rd_i != '0);

  logic rs1_on_ex, rs2_on_ex, rs1_on_mem, rs2_on_mem;
  assign rs1_on_ex  = ex_writes  & id_rs1_used_i & (id_rs1_addr_i == ex_rd_i);
  assign rs2_on_ex  = ex_writes  & id_rs2_used_i & (id_rs2_addr_i == ex_rd_i);
  assign rs1_on_mem = mem_writes & id_rs1_used_i & (id_rs1_addr_i == mem_rd_i);
  assign rs2_on_mem = mem_writes & id_rs2_used_i & (id_rs2_addr_i == mem_rd_i);

  // A store's rs2 is exempt: MEM supplies it from WB (see the header).
  logic rs2_needed_in_ex;
  assign rs2_needed_in_ex = ~id_is_store_i;

  logic interlock;
  assign interlock = ifid_valid_i & (
      (ex_late_i                 & (rs1_on_ex  | (rs2_on_ex  & rs2_needed_in_ex))) |
      (mem_late_i & ~mem_ready_i & (rs1_on_mem | (rs2_on_mem & rs2_needed_in_ex))));

  // --------------------------------------------------------------------
  // Advance and flush
  // --------------------------------------------------------------------
  logic mem_free, ex_free, id_advance;

  assign mem_free     = ~mem_valid_i | mem_ready_i;
  assign ex_advance_o = ex_valid_i & ex_ready_i & mem_free & ~flush_mem_i;
  assign ex_free      = ~ex_valid_i | ex_advance_o;
  assign flush_ex_o   = ex_advance_o & ex_mispredict_i;
  assign id_advance   = ifid_valid_i & ex_free & ~interlock &
                        ~flush_mem_i & ~flush_ex_o;

  // EX/MEM loads whenever MEM will be free; it takes a bubble unless EX
  // advances. A flush from MEM always coincides with MEM completing, so
  // mem_free already covers it.
  assign exmem_en_o    = mem_free;
  assign exmem_valid_o = ex_advance_o;

  // ID/EX loads whenever EX will be free, and on a flush -- which is what
  // removes an instruction held in EX, a running multiply or divide
  // included. Otherwise it keeps its instruction and refreshes the operands.
  assign idex_en_o     = ex_free | flush_mem_i;
  assign idex_valid_o  = id_advance;
  assign ifid_accept_o = id_advance;

  // --------------------------------------------------------------------
  // Forwarding into EX
  // --------------------------------------------------------------------
  // From MEM only when the value was made in EX; a late producer in MEM with
  // a consumer in EX is exactly what the interlock prevents (apart from a
  // store's data operand, which MEM repairs itself).
  logic mem_fwd_ok, wb_writes;
  assign mem_fwd_ok = mem_writes & ~mem_late_i;
  assign wb_writes  = wb_valid_i & wb_rf_we_i & (wb_rd_i != '0);

  always_comb begin
    if (mem_fwd_ok && ex_rs1_addr_i == mem_rd_i) begin
      fwd_rs1_sel_o = 2'd1;
    end else if (wb_writes && ex_rs1_addr_i == wb_rd_i) begin
      fwd_rs1_sel_o = 2'd2;
    end else begin
      fwd_rs1_sel_o = 2'd0;
    end
    if (mem_fwd_ok && ex_rs2_addr_i == mem_rd_i) begin
      fwd_rs2_sel_o = 2'd1;
    end else if (wb_writes && ex_rs2_addr_i == wb_rd_i) begin
      fwd_rs2_sel_o = 2'd2;
    end else begin
      fwd_rs2_sel_o = 2'd0;
    end
  end

  // --------------------------------------------------------------------
  // Observability
  // --------------------------------------------------------------------
  assign id_stall_o  = ifid_valid_i & ~id_advance & ~flush_mem_i & ~flush_ex_o;
  assign interlock_o = interlock & ~flush_mem_i & ~flush_ex_o;

endmodule : p_core_hazard
