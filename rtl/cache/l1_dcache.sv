// ============================================================================
// l1_dcache.sv
//
// Private L1 data cache with MSI snooping coherence. One module, two
// personalities, chosen by WRITE_BACK:
//
//   WRITE_BACK = 1  (P-core: 16 KB, 2-way, LRU)
//       write-back, write-allocate. Lines are I, S or M. A store needs M: a
//       store to an S line issues BUS_UPGR, a store miss BUS_RDX. A modified
//       victim is written back (BUS_WB) before its way is refilled.
//
//   WRITE_BACK = 0  (E-core: 8 KB, direct-mapped)
//       write-through, no-write-allocate. Lines are only I or S: every store
//       is a BUS_WR that updates memory and invalidates every other copy, and
//       also updates this cache's own copy if it has one. Victims are always
//       clean, so eviction is silent.
//
// Both personalities speak the same bus protocol and answer snoops the same
// way, which is what lets a write-back and a write-through cache share lines
// coherently (rtl/coherence/snoop_bus.sv).
//
// ---------------------------------------------------------------------------
// CORE SIDE
// ---------------------------------------------------------------------------
// The core's Ibex-style data port (see tb/integration/memory_model.h): the
// core holds req, addr, we, be and wdata stable until gnt. This cache only
// ever grants in the cycle it responds, so gnt and rvalid always rise
// together and each access is atomic at that cycle:
//
//   * a hit is answered in the cycle after the request: the request cycle
//     reads the set's data out of the SRAM (C_IDLE), the next one has it and
//     decides hit or miss from the tags and states (C_LOOK);
//   * a miss, an upgrade, a write-through store or an uncached access holds
//     gnt low until its bus transaction completes, then answers in the cycle
//     the bus reports done.
//
// The cycle in which a core sees gnt/rvalid is therefore exactly the cycle in
// which the access takes effect in the coherent memory system. That is the
// property the testbench's coherence checker relies on.
//
// Addresses at or above CACHEABLE_LIMIT (the MMIO region, and unmapped space)
// bypass the cache as uncached word accesses, so that peripherals see every
// access and access faults still reach the core.
//
// ---------------------------------------------------------------------------
// SNOOP SIDE
// ---------------------------------------------------------------------------
// The bus snoops every other cache, for one cycle, at the start of each
// coherent transaction. Hit and dirty are combinational, from a second read
// port on the tag and state arrays; the state change happens at the end of
// that cycle. A modified line's data is read out of the SRAM in that cycle
// and reaches the bus in the next one (snoop_data_o). A core access is not
// accepted in a snoop cycle, so the core and the snoop never use the arrays
// in the same cycle.
//
// ---------------------------------------------------------------------------
// THE DATA SRAM
// ---------------------------------------------------------------------------
// Tags and states are flip-flops, so every hit, miss and snoop decision is
// made in one cycle exactly as before. The line data is a single-port SRAM
// per way (sram_sp.sv): one access per cycle, read data valid in the next
// cycle only, whole-line writes. Its users never meet in one cycle:
//
//   * a read of the request's set (C_IDLE) or of a line to flush (C_FLUSH),
//     never in a snoop cycle;
//   * a snoop's read of a modified line, in the snoop cycle;
//   * a line write: a store hit (C_LOOK, never in a snoop cycle), a fill or
//     a write-through update (bus done, never in a snoop cycle).
//
// A line the controller needs while it waits for the bus -- a victim to
// write back, its own copy for an upgrade or a write-through update -- is
// kept in the line buffer (lb_q) from the cycle its read arrives.
//
// The bus is atomic: while this cache's own transaction is in flight, no
// snoop reaches this cache. A request that is still waiting for the bus can
// be overtaken by other caches' transactions, though, and the cache adapts:
//
//   * a victim waiting to be written back that a snoop has already flushed
//     (M -> S or M -> I) needs no writeback any more;
//   * an upgrade whose S copy a snoop has invalidated becomes a BUS_RDX.
//
// Both decisions are re-made every cycle from the current state, and the bus
// only grants while no snoop is in progress, so the command it latches is
// always consistent with the state of the cache at that moment.
//
// ---------------------------------------------------------------------------
// SLOW CORES, THE PERFORMED-ACCESS MONITOR, AND FLUSH (rtl/power/pmu.sv)
// ---------------------------------------------------------------------------
// The cache always runs on the system clock, but its core may not: the PMU
// can run a cluster's cores at 1/2 or 1/4 speed, or stop one. core_en_i is
// high in the cycles that end with a core clock edge, the only cycles in
// which the core can see a response. The cache therefore takes a new access
// only when core_en_i is high, and a bus transaction that completes when it
// is low has its response held (C_HOLD) until the next one.
//
// A held access has already taken effect -- a snoop may even have taken the
// line away again -- so the cycle the core sees gnt is no longer always the
// cycle the access was performed. The perf_* outputs report each access in
// the cycle it is performed, with the data it read; that is what the
// testbenches' coherence checkers follow. At full speed the two coincide.
//
// flush_i (held until flush_done_o) walks every line: a modified line is
// written back (BUS_WB), everything is invalidated. Snoops are still
// answered during the walk. The PMU only flushes the caches of halted cores,
// before switching their power domain off; flush_done_o stays high, and the
// cache idle, until flush_i is released.
// ============================================================================

module l1_dcache
  import cache_pkg::*;
#(
  parameter int unsigned WAYS            = 2,      // 1 or 2
  parameter int unsigned SETS            = 256,    // power of two, >= 2
  parameter bit          WRITE_BACK      = 1'b1,
  parameter logic [31:0] CACHEABLE_LIMIT = 32'h0003_0000
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  logic                  core_en_i,        // this cycle ends with a core clock edge

  // ---- Core data port ----
  input  logic                  core_req_i,
  input  logic [31:0]           core_addr_i,
  input  logic                  core_we_i,
  input  logic [3:0]            core_be_i,
  input  logic [31:0]           core_wdata_i,
  output logic                  core_gnt_o,
  output logic                  core_rvalid_o,
  output logic [31:0]           core_rdata_o,
  output logic                  core_err_o,

  // ---- Bus request (held until bus_done_i) ----
  output logic                  bus_req_o,
  output bus_cmd_e              bus_cmd_o,
  output logic [31:0]           bus_addr_o,
  output logic [LINE_BITS-1:0]  bus_wdata_o,
  output logic [LINE_BYTES-1:0] bus_be_o,
  input  logic                  bus_done_i,
  input  logic [LINE_BITS-1:0]  bus_rdata_i,
  input  logic                  bus_err_i,

  // ---- Snoop port ----
  input  logic                  snoop_valid_i,
  input  snoop_e                snoop_type_i,
  input  logic [31:0]           snoop_addr_i,
  output logic                  snoop_hit_o,
  output logic                  snoop_dirty_o,
  output logic [LINE_BITS-1:0]  snoop_data_o,

  // ---- Debug probe: state and data of the line holding dbg_addr_i ----
  input  logic [31:0]           dbg_addr_i,
  output msi_e                  dbg_state_o,
  output logic [LINE_BITS-1:0]  dbg_data_o,

  // ---- Performed-access monitor: one pulse per access, as it takes effect ----
  output logic                  perf_valid_o,
  output logic [31:0]           perf_addr_o,
  output logic                  perf_we_o,
  output logic [3:0]            perf_be_o,
  output logic [31:0]           perf_wdata_o,
  output logic [31:0]           perf_rdata_o,
  output logic                  perf_err_o,

  // ---- Flush (power-down) ----
  input  logic                  flush_i,
  output logic                  flush_done_o,

  // ---- Event pulses (cache_pkg::EV_*) ----
  output logic [NUM_EV-1:0]     events_o
);

  localparam int unsigned IDX_W = $clog2(SETS);
  localparam int unsigned TAG_W = 32 - IDX_W - OFFSET_W;
  localparam int unsigned WAY_W = (WAYS > 1) ? $clog2(WAYS) : 1;

  typedef logic [IDX_W-1:0] idx_t;
  typedef logic [TAG_W-1:0] tag_t;
  typedef logic [WAY_W-1:0] way_t;

  // Address fields: | tag | index | word slot | byte |
  `define L1_IDX(a)  a[OFFSET_W +: IDX_W]
  `define L1_TAG(a)  a[31 -: TAG_W]
  `define L1_SLOT(a) a[2 +: WORD_SEL_W]

  // ====================================================================
  // Arrays. Tags and states are flip-flops; only the states are reset, and
  // they qualify the tags. The data is an SRAM per way (below).
  // ====================================================================
  tag_t                 tag_q   [WAYS][SETS];
  msi_e                 state_q [WAYS][SETS];

  // ====================================================================
  // Lookups: the latched request, the snoop, the debug probe
  // ====================================================================
  // The request's lookup is made on the latched request (rq_addr_q), in
  // C_LOOK, the cycle its set's data arrives.
  idx_t c_idx;
  logic c_hit;
  way_t c_way;
  logic c_inv_found;
  way_t c_inv_way;

  logic [31:0] rq_addr_q;

  always_comb begin
    c_idx       = `L1_IDX(rq_addr_q);
    c_hit       = 1'b0;
    c_way       = '0;
    c_inv_found = 1'b0;
    c_inv_way   = '0;
    for (int w = 0; w < int'(WAYS); w++) begin
      if (state_q[w][c_idx] != MSI_I && tag_q[w][c_idx] == `L1_TAG(rq_addr_q)) begin
        c_hit = 1'b1;
        c_way = way_t'(w);
      end
      if (state_q[w][c_idx] == MSI_I && !c_inv_found) begin
        c_inv_found = 1'b1;
        c_inv_way   = way_t'(w);
      end
    end
  end

  logic c_cacheable;
  assign c_cacheable = core_addr_i < CACHEABLE_LIMIT;

  // Snoop lookup
  idx_t s_idx;
  logic s_hit;
  way_t s_way;
  always_comb begin
    s_idx = `L1_IDX(snoop_addr_i);
    s_hit = 1'b0;
    s_way = '0;
    for (int w = 0; w < int'(WAYS); w++) begin
      if (state_q[w][s_idx] != MSI_I && tag_q[w][s_idx] == `L1_TAG(snoop_addr_i)) begin
        s_hit = 1'b1;
        s_way = way_t'(w);
      end
    end
  end

  assign snoop_hit_o   = snoop_valid_i && s_hit;
  assign snoop_dirty_o = snoop_valid_i && s_hit && state_q[s_way][s_idx] == MSI_M;

  // Debug probe
  idx_t d_idx;
  logic d_hit;
  way_t d_way;
  always_comb begin
    d_idx = `L1_IDX(dbg_addr_i);
    d_hit = 1'b0;
    d_way = '0;
    for (int w = 0; w < int'(WAYS); w++) begin
      if (state_q[w][d_idx] != MSI_I && tag_q[w][d_idx] == `L1_TAG(dbg_addr_i)) begin
        d_hit = 1'b1;
        d_way = way_t'(w);
      end
    end
  end

  // ====================================================================
  // Replacement. Two ways: one LRU bit per set naming the way to evict
  // next. One way: always way 0.
  // ====================================================================
  logic lru_upd;
  idx_t lru_idx;
  way_t lru_used;
  way_t c_lru_way;

  if (WAYS == 2) begin : g_lru
    logic lru_q [SETS];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int s = 0; s < int'(SETS); s++) lru_q[s] <= 1'b0;
      end else if (lru_upd) begin
        lru_q[lru_idx] <= ~lru_used[0];
      end
    end
    assign c_lru_way = way_t'(lru_q[c_idx]);
  end else begin : g_no_lru
    // A single way has nothing to choose between. The update is still
    // produced by the shared control logic, so it is consumed here.
    logic unused_lru;
    assign unused_lru = lru_upd & (|lru_idx) & (|lru_used);
    assign c_lru_way  = '0;
  end

  way_t c_victim;
  assign c_victim = c_inv_found ? c_inv_way : c_lru_way;

  // ====================================================================
  // Request register: the access being worked on while the core waits.
  // ====================================================================
  typedef enum logic [3:0] {
    C_IDLE,    // take a request and read its set's data
    C_LOOK,    // the data has arrived: answer a hit; a miss leaves for...
    C_WB,      // writing back the modified victim (BUS_WB)
    C_FILL,    // BUS_RD / BUS_RDX / BUS_UPGR for the requested line
    C_WT,      // write-through store (BUS_WR)
    C_UNC,     // uncached access (BUS_UNC_RD / BUS_UNC_WR)
    C_HOLD,    // access performed; response waits for the core's clock
    C_FLUSH,   // flush walk: invalidate line {fl_idx, fl_way}, or...
    C_FRD,     // ...read it,
    C_FWB,     // ...and write it back first (BUS_WB)
    C_FLUSHED  // flush complete, until flush_i is released
  } cstate_e;

  cstate_e     cs_q, cs_d;
  logic        rq_we_q;
  logic [3:0]  rq_be_q;
  logic [31:0] rq_wdata_q;
  way_t        fill_way_q, fill_way_d;
  logic        accept;

  // Held response (C_HOLD)
  logic        hold_set;
  logic [31:0] hold_rdata_q, hold_rdata_d;
  logic        hold_err_q, hold_err_d;

  // Flush walk position
  idx_t        fl_idx_q;
  way_t        fl_way_q;
  logic        fl_step;      // advance to the next line
  logic        fl_last;
  assign fl_last = fl_idx_q == idx_t'(SETS - 1) && int'(fl_way_q) == int'(WAYS) - 1;

  idx_t                  rq_idx;
  tag_t                  rq_tag;
  logic [WORD_SEL_W-1:0] rq_slot;
  assign rq_idx  = `L1_IDX(rq_addr_q);
  assign rq_tag  = `L1_TAG(rq_addr_q);
  assign rq_slot = `L1_SLOT(rq_addr_q);

  // Own copy of the latched request's line (write-through store update).
  logic r_hit;
  way_t r_way;
  assign r_hit = c_hit;
  assign r_way = c_way;

  // The fill way still holds the requested line in S: a store can upgrade.
  logic fill_upgrade;
  assign fill_upgrade = WRITE_BACK && rq_we_q &&
                        state_q[fill_way_q][rq_idx] == MSI_S &&
                        tag_q[fill_way_q][rq_idx] == rq_tag;

  // ====================================================================
  // Control
  // ====================================================================
  logic [NUM_EV-1:0]    fsm_events;

  // Array write port (core side). The snoop side has its own, below.
  logic                 st_we;      // write state + tag
  logic                 dt_we;      // write data
  way_t                 wr_way;
  idx_t                 wr_idx;
  tag_t                 wr_tag;
  msi_e                 wr_state;
  logic [LINE_BITS-1:0] wr_data;
  logic [LINE_BITS-1:0] fill_line;

  // Data SRAM read port (the write port is dt_we above), and what it read.
  logic                           rd_en;      // read set rd_idx, every way
  idx_t                           rd_idx;
  logic                           snp_rd;     // a snoop's read of a modified line
  logic [WAYS-1:0][LINE_BITS-1:0] rd_line;    // valid the cycle after a read
  logic [WAYS-1:0][LINE_BITS-1:0] dbg_line;

  // Line buffer: the line a waiting request still needs (lb_load: from the
  // read that arrives this cycle, way lb_way).
  logic                 lb_load;
  way_t                 lb_way;
  logic [LINE_BITS-1:0] lb_q;

  // The access is complete: respond, or hold.
  logic                 done_resp;
  logic [31:0]          resp_rdata;
  logic                 resp_err;
  logic                 fl_clear;

  always_comb begin
    cs_d          = cs_q;
    fill_way_d    = fill_way_q;
    accept        = 1'b0;
    done_resp     = 1'b0;
    resp_rdata    = '0;
    resp_err      = 1'b0;
    hold_set      = 1'b0;
    hold_rdata_d  = hold_rdata_q;
    hold_err_d    = hold_err_q;
    fl_step       = 1'b0;
    fl_clear      = 1'b0;
    flush_done_o  = 1'b0;

    core_gnt_o    = 1'b0;
    core_rvalid_o = 1'b0;
    core_rdata_o  = '0;
    core_err_o    = 1'b0;

    bus_req_o     = 1'b0;
    bus_cmd_o     = BUS_RD;
    bus_addr_o    = '0;
    bus_wdata_o   = '0;
    bus_be_o      = '0;

    st_we         = 1'b0;
    dt_we         = 1'b0;
    wr_way        = '0;
    wr_idx        = '0;
    wr_tag        = '0;
    wr_state      = MSI_I;
    wr_data       = '0;
    fill_line     = '0;

    rd_en         = 1'b0;
    rd_idx        = '0;
    lb_load       = 1'b0;
    lb_way        = '0;

    lru_upd       = 1'b0;
    lru_idx       = '0;
    lru_used      = '0;

    fsm_events    = '0;

    unique case (cs_q)
      // ------------------------------------------------------------------
      C_IDLE: begin
        if (flush_i) begin
          cs_d     = C_FLUSH;
          fl_clear = 1'b1;
        end else if (core_req_i && core_en_i && !snoop_valid_i) begin
          accept = 1'b1;
          if (!c_cacheable) begin
            cs_d   = C_UNC;
            fsm_events[EV_UNCACHED] = 1'b1;
          end else begin
            // Read the set's data, every way; decide next cycle.
            rd_en  = 1'b1;
            rd_idx = `L1_IDX(core_addr_i);
            cs_d   = C_LOOK;
          end
        end
      end

      // ------------------------------------------------------------------
      // The request's set has been read: hit or miss, from the tags and
      // states. Whatever happens next, keep the line it works on: the hit
      // line, or the victim.
      C_LOOK: begin
        lb_load = 1'b1;
        lb_way  = c_hit ? c_way : c_victim;
        if (snoop_valid_i) begin
          // A snoop may change this set's states at the end of the cycle:
          // look again.
          cs_d = C_IDLE;
        end else begin
          if (!rq_we_q) begin
            if (c_hit) begin
              // Load hit.
              done_resp  = 1'b1;
              resp_rdata = line_word(rd_line[c_way], rq_slot);
              lru_upd  = 1'b1;
              lru_idx  = c_idx;
              lru_used = c_way;
              cs_d     = C_IDLE;
              fsm_events[EV_LD_HIT] = 1'b1;
            end else begin
              fill_way_d = c_victim;
              cs_d = (WRITE_BACK && state_q[c_victim][c_idx] == MSI_M) ? C_WB : C_FILL;
              fsm_events[EV_LD_MISS] = 1'b1;
            end
          end else if (WRITE_BACK) begin
            if (c_hit && state_q[c_way][c_idx] == MSI_M) begin
              // Store hit on a modified line: done in the cache.
              done_resp = 1'b1;
              dt_we   = 1'b1;
              wr_way  = c_way;
              wr_idx  = c_idx;
              wr_data = line_merge(rd_line[c_way], word_to_line(rq_wdata_q),
                                   word_be(rq_be_q, rq_slot));
              lru_upd  = 1'b1;
              lru_idx  = c_idx;
              lru_used = c_way;
              cs_d     = C_IDLE;
              fsm_events[EV_ST_HIT] = 1'b1;
            end else if (c_hit) begin
              // Store to a shared line: upgrade in place.
              fill_way_d = c_way;
              cs_d       = C_FILL;
              fsm_events[EV_ST_MISS] = 1'b1;
            end else begin
              fill_way_d = c_victim;
              cs_d = (state_q[c_victim][c_idx] == MSI_M) ? C_WB : C_FILL;
              fsm_events[EV_ST_MISS] = 1'b1;
            end
          end else begin
            // Write-through store: always a bus write.
            cs_d   = C_WT;
            fsm_events[EV_ST_MISS] = 1'b1;
          end
        end
      end

      // ------------------------------------------------------------------
      C_WB: begin
        if (state_q[fill_way_q][rq_idx] != MSI_M) begin
          // A snoop flushed the victim while it waited for the bus: memory
          // already has its data.
          cs_d = C_FILL;
        end else begin
          bus_req_o   = 1'b1;
          bus_cmd_o   = BUS_WB;
          bus_addr_o  = {tag_q[fill_way_q][rq_idx], rq_idx, OFFSET_W'(0)};
          bus_wdata_o = lb_q;
          bus_be_o    = '1;
          if (bus_done_i) begin
            st_we    = 1'b1;
            wr_way   = fill_way_q;
            wr_idx   = rq_idx;
            wr_tag   = tag_q[fill_way_q][rq_idx];
            wr_state = MSI_I;
            cs_d     = C_FILL;
            fsm_events[EV_WRITEBACK] = 1'b1;
          end
        end
      end

      // ------------------------------------------------------------------
      C_FILL: begin
        bus_req_o  = 1'b1;
        bus_cmd_o  = !rq_we_q ? BUS_RD : (fill_upgrade ? BUS_UPGR : BUS_RDX);
        bus_addr_o = {rq_addr_q[31:OFFSET_W], OFFSET_W'(0)};
        if (bus_done_i) begin
          // An upgrade keeps the data it already has; anything else takes
          // the line the bus delivered.
          fill_line  = fill_upgrade ? lb_q : bus_rdata_i;
          done_resp  = 1'b1;
          resp_err   = bus_err_i;
          resp_rdata = line_word(fill_line, rq_slot);
          if (!bus_err_i) begin
            st_we    = 1'b1;
            dt_we    = 1'b1;
            wr_way   = fill_way_q;
            wr_idx   = rq_idx;
            wr_tag   = rq_tag;
            wr_state = rq_we_q ? MSI_M : MSI_S;
            wr_data  = rq_we_q ? line_merge(fill_line, word_to_line(rq_wdata_q),
                                            word_be(rq_be_q, rq_slot))
                               : fill_line;
            lru_upd  = 1'b1;
            lru_idx  = rq_idx;
            lru_used = fill_way_q;
          end
          cs_d = C_IDLE;
        end
      end

      // ------------------------------------------------------------------
      C_WT: begin
        bus_req_o   = 1'b1;
        bus_cmd_o   = BUS_WR;
        bus_addr_o  = {rq_addr_q[31:2], 2'b00};
        bus_wdata_o = word_to_line(rq_wdata_q);
        bus_be_o    = word_be(rq_be_q, rq_slot);
        if (bus_done_i) begin
          done_resp = 1'b1;
          resp_err  = bus_err_i;
          if (!bus_err_i && r_hit) begin
            // Keep this cache's own copy current. It stays S: memory was
            // written in the same transaction.
            dt_we   = 1'b1;
            wr_way  = r_way;
            wr_idx  = rq_idx;
            wr_data = line_merge(lb_q, word_to_line(rq_wdata_q),
                                 word_be(rq_be_q, rq_slot));
          end
          cs_d = C_IDLE;
        end
      end

      // ------------------------------------------------------------------
      C_UNC: begin
        bus_req_o   = 1'b1;
        bus_cmd_o   = rq_we_q ? BUS_UNC_WR : BUS_UNC_RD;
        bus_addr_o  = {rq_addr_q[31:2], 2'b00};
        bus_wdata_o = word_to_line(rq_wdata_q);
        bus_be_o    = word_be(rq_be_q, rq_slot);
        if (bus_done_i) begin
          done_resp  = 1'b1;
          resp_err   = bus_err_i;
          resp_rdata = line_word(bus_rdata_i, rq_slot);
          cs_d       = C_IDLE;
        end
      end

      // ------------------------------------------------------------------
      C_HOLD: begin
        if (core_en_i) begin
          core_gnt_o    = 1'b1;
          core_rvalid_o = 1'b1;
          core_rdata_o  = hold_rdata_q;
          core_err_o    = hold_err_q;
          cs_d          = C_IDLE;
        end
      end

      // ------------------------------------------------------------------
      // Flush walk. Lines are only written outside snoop cycles, so the
      // snoop's own state update never collides with the walk's.
      C_FLUSH: begin
        if (!flush_i) begin
          cs_d = C_IDLE;                        // abandoned
        end else if (!snoop_valid_i) begin
          if (WRITE_BACK && state_q[fl_way_q][fl_idx_q] == MSI_M) begin
            cs_d = C_FRD;
            rd_en  = 1'b1;
            rd_idx = fl_idx_q;
          end else begin
            st_we    = state_q[fl_way_q][fl_idx_q] != MSI_I;
            wr_way   = fl_way_q;
            wr_idx   = fl_idx_q;
            wr_tag   = tag_q[fl_way_q][fl_idx_q];
            wr_state = MSI_I;
            fl_step  = 1'b1;
            if (fl_last) cs_d = C_FLUSHED;
          end
        end
      end

      C_FRD: begin
        lb_load = 1'b1;
        lb_way  = fl_way_q;
        cs_d    = C_FWB;
      end

      C_FWB: begin
        if (state_q[fl_way_q][fl_idx_q] != MSI_M) begin
          // A snoop took the line while the writeback waited for the bus.
          cs_d = C_FLUSH;
        end else begin
          bus_req_o   = 1'b1;
          bus_cmd_o   = BUS_WB;
          bus_addr_o  = {tag_q[fl_way_q][fl_idx_q], fl_idx_q, OFFSET_W'(0)};
          bus_wdata_o = lb_q;
          bus_be_o    = '1;
          if (bus_done_i) begin
            st_we    = 1'b1;
            wr_way   = fl_way_q;
            wr_idx   = fl_idx_q;
            wr_tag   = tag_q[fl_way_q][fl_idx_q];
            wr_state = MSI_I;
            fl_step  = 1'b1;
            cs_d     = fl_last ? C_FLUSHED : C_FLUSH;
            fsm_events[EV_WRITEBACK] = 1'b1;
          end
        end
      end

      C_FLUSHED: begin
        flush_done_o = flush_i;
        if (!flush_i) cs_d = C_IDLE;
      end

      default: cs_d = C_IDLE;
    endcase

    // A completed access is answered now if the core can see it, and held
    // for the core's next clock edge if not.
    if (done_resp) begin
      if (core_en_i) begin
        core_gnt_o    = 1'b1;
        core_rvalid_o = 1'b1;
        core_rdata_o  = resp_rdata;
        core_err_o    = resp_err;
      end else begin
        hold_set     = 1'b1;
        hold_rdata_d = resp_rdata;
        hold_err_d   = resp_err;
        cs_d         = C_HOLD;
      end
    end
  end

  // ====================================================================
  // Data SRAM, one per way. A write uses its way's SRAM; a read reads
  // every way's at one set.
  // ====================================================================
  assign snp_rd = snoop_dirty_o;

  for (genvar w = 0; w < int'(WAYS); w++) begin : g_data
    logic wr_this;
    assign wr_this = dt_we && wr_way == way_t'(w);
    sram_sp #(
      .DEPTH (SETS),
      .WIDTH (LINE_BITS)
    ) u_data (
      .clk_i       (clk_i),
      .ce_i        (wr_this || rd_en || snp_rd),
      .we_i        (wr_this),
      .addr_i      (wr_this ? wr_idx : (snp_rd ? s_idx : rd_idx)),
      .wdata_i     (wr_data),
      .rdata_o     (rd_line[w]),
      .dbg_addr_i  (d_idx),
      .dbg_rdata_o (dbg_line[w])
    );
  end

  // A snooped modified line reaches the bus in the cycle after the snoop.
  way_t s_way_q;
  always_ff @(posedge clk_i) begin
    if (snp_rd) s_way_q <= s_way;
  end
  assign snoop_data_o = rd_line[s_way_q];

  always_ff @(posedge clk_i) begin
    if (lb_load) lb_q <= rd_line[lb_way];
  end

`ifndef SYNTHESIS
  // Debug probe, and the performed-access monitor: every access is
  // performed in the cycle it completes.
  assign dbg_state_o  = d_hit ? state_q[d_way][d_idx] : MSI_I;
  assign dbg_data_o   = dbg_line[d_way];
  assign perf_valid_o = done_resp;
  assign perf_addr_o  = rq_addr_q;
  assign perf_we_o    = rq_we_q;
  assign perf_be_o    = rq_be_q;
  assign perf_wdata_o = rq_wdata_q;
  assign perf_rdata_o = resp_rdata;
  assign perf_err_o   = resp_err;
`else
  // Testbench-only outputs: nothing to build in silicon.
  assign dbg_state_o  = MSI_I;
  assign dbg_data_o   = '0;
  assign perf_valid_o = 1'b0;
  assign perf_addr_o  = '0;
  assign perf_we_o    = 1'b0;
  assign perf_be_o    = '0;
  assign perf_wdata_o = '0;
  assign perf_rdata_o = '0;
  assign perf_err_o   = 1'b0;
`endif

  // ====================================================================
  // Snoop state change
  // ====================================================================
  logic snp_upd;
  msi_e snp_next;
  always_comb begin
    snp_upd  = 1'b0;
    snp_next = MSI_I;
    if (snoop_valid_i && s_hit) begin
      if (snoop_type_i == SNP_INV) begin
        snp_upd  = 1'b1;
        snp_next = MSI_I;
      end else if (state_q[s_way][s_idx] == MSI_M) begin
        snp_upd  = 1'b1;
        snp_next = MSI_S;
      end
    end
  end

  logic [NUM_EV-1:0] snp_events;
  always_comb begin
    snp_events = '0;
    snp_events[EV_SNP_INV]   = snp_upd && snp_next == MSI_I;
    snp_events[EV_SNP_FLUSH] = snoop_dirty_o;
  end

  assign events_o = fsm_events | snp_events;

  // ====================================================================
  // Registers
  // ====================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cs_q       <= C_IDLE;
      fill_way_q <= '0;
      rq_addr_q  <= '0;
      rq_we_q    <= 1'b0;
      rq_be_q    <= '0;
      rq_wdata_q <= '0;
      hold_rdata_q <= '0;
      hold_err_q   <= 1'b0;
      fl_idx_q     <= '0;
      fl_way_q     <= '0;
      for (int w = 0; w < int'(WAYS); w++) begin
        for (int s = 0; s < int'(SETS); s++) state_q[w][s] <= MSI_I;
      end
    end else begin
      cs_q       <= cs_d;
      fill_way_q <= fill_way_d;
      if (accept) begin
        rq_addr_q  <= core_addr_i;
        rq_we_q    <= core_we_i;
        rq_be_q    <= core_be_i;
        rq_wdata_q <= core_wdata_i;
      end
      if (hold_set) begin
        hold_rdata_q <= hold_rdata_d;
        hold_err_q   <= hold_err_d;
      end
      if (fl_clear) begin
        fl_idx_q <= '0;
        fl_way_q <= '0;
      end else if (fl_step) begin
        if (int'(fl_way_q) == int'(WAYS) - 1) begin
          fl_way_q <= '0;
          fl_idx_q <= fl_idx_q + idx_t'(1);
        end else begin
          fl_way_q <= fl_way_q + way_t'(1);
        end
      end
      if (st_we)   state_q[wr_way][wr_idx] <= wr_state;
      if (snp_upd) state_q[s_way][s_idx]   <= snp_next;
    end
  end

  always_ff @(posedge clk_i) begin
    if (st_we) tag_q[wr_way][wr_idx]  <= wr_tag;
  end

`ifndef SYNTHESIS
  // ====================================================================
  // Simulation assertions
  // ====================================================================
  always_ff @(posedge clk_i) begin
    begin
      // The bus is atomic: this cache is never snooped during its own
      // transaction, so the two array write ports never collide.
      assert (!(snoop_valid_i && bus_done_i))
        else $error("l1_dcache: snooped in the cycle its own transaction completed");
      assert (!(snp_upd && (st_we || dt_we)))
        else $error("l1_dcache: snoop and core updated the arrays in one cycle");
      // The data SRAM has one port: its users never meet in one cycle.
      assert (!(rd_en && snp_rd) && !(rd_en && dt_we) && !(snp_rd && dt_we))
        else $error("l1_dcache: two accesses to the data SRAM in one cycle");
      // The PMU flushes only the caches of halted cores.
      assert (!(cs_q == C_IDLE && flush_i && core_req_i))
        else $error("l1_dcache: flush requested with a core access pending");
      // A write-through cache never owns a line.
      if (!WRITE_BACK) begin
        assert (!(st_we && wr_state == MSI_M))
          else $error("l1_dcache: write-through cache entered M");
      end
    end
  end
`endif

  // The low address bits are consumed only through idx_of/slot_of; the
  // remaining offset bits select bytes, which the byte enables already
  // carry.
  logic unused_addr_bits;
  assign unused_addr_bits = ^{core_addr_i[1:0], snoop_addr_i[OFFSET_W-1:0],
                              dbg_addr_i[OFFSET_W-1:0], rq_addr_q[1:0]};

  `undef L1_IDX
  `undef L1_TAG
  `undef L1_SLOT

endmodule
