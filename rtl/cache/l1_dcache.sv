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
//   * a hit is answered combinationally, in the request cycle;
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
// coherent transaction. The response (hit, dirty, line data) is combinational
// from a second read port on the tag/state/data arrays; the state change
// happens at the end of that cycle. A core access is not accepted in a snoop
// cycle, so the core and the snoop never update the arrays in the same cycle.
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
  // Arrays. Only the state bits are reset; tags and data are qualified by
  // state, so they can be RAM.
  // ====================================================================
  tag_t                 tag_q   [WAYS][SETS];
  msi_e                 state_q [WAYS][SETS];
  logic [LINE_BITS-1:0] data_q  [WAYS][SETS];

  // ====================================================================
  // Lookups: core request, latched request, snoop, debug probe
  // ====================================================================
  idx_t c_idx;
  logic c_hit;
  way_t c_way;
  logic c_inv_found;
  way_t c_inv_way;

  always_comb begin
    c_idx       = `L1_IDX(core_addr_i);
    c_hit       = 1'b0;
    c_way       = '0;
    c_inv_found = 1'b0;
    c_inv_way   = '0;
    for (int w = 0; w < int'(WAYS); w++) begin
      if (state_q[w][c_idx] != MSI_I && tag_q[w][c_idx] == `L1_TAG(core_addr_i)) begin
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
  assign snoop_data_o  = data_q[s_way][s_idx];

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
  assign dbg_state_o = d_hit ? state_q[d_way][d_idx] : MSI_I;
  assign dbg_data_o  = data_q[d_way][d_idx];

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
  typedef enum logic [2:0] {
    C_IDLE,   // serving hits; a miss leaves for one of the states below
    C_WB,     // writing back the modified victim (BUS_WB)
    C_FILL,   // BUS_RD / BUS_RDX / BUS_UPGR for the requested line
    C_WT,     // write-through store (BUS_WR)
    C_UNC     // uncached access (BUS_UNC_RD / BUS_UNC_WR)
  } cstate_e;

  cstate_e     cs_q, cs_d;
  logic [31:0] rq_addr_q;
  logic        rq_we_q;
  logic [3:0]  rq_be_q;
  logic [31:0] rq_wdata_q;
  way_t        fill_way_q, fill_way_d;
  logic        accept;

  idx_t                  rq_idx;
  tag_t                  rq_tag;
  logic [WORD_SEL_W-1:0] rq_slot;
  assign rq_idx  = `L1_IDX(rq_addr_q);
  assign rq_tag  = `L1_TAG(rq_addr_q);
  assign rq_slot = `L1_SLOT(rq_addr_q);

  // Own copy of the latched request's line (write-through store update).
  logic r_hit;
  way_t r_way;
  always_comb begin
    r_hit = 1'b0;
    r_way = '0;
    for (int w = 0; w < int'(WAYS); w++) begin
      if (state_q[w][rq_idx] != MSI_I && tag_q[w][rq_idx] == rq_tag) begin
        r_hit = 1'b1;
        r_way = way_t'(w);
      end
    end
  end

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

  always_comb begin
    cs_d          = cs_q;
    fill_way_d    = fill_way_q;
    accept        = 1'b0;

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

    lru_upd       = 1'b0;
    lru_idx       = '0;
    lru_used      = '0;

    fsm_events    = '0;

    unique case (cs_q)
      // ------------------------------------------------------------------
      C_IDLE: begin
        if (core_req_i && !snoop_valid_i) begin
          if (!c_cacheable) begin
            accept = 1'b1;
            cs_d   = C_UNC;
            fsm_events[EV_UNCACHED] = 1'b1;
          end else if (!core_we_i) begin
            if (c_hit) begin
              // Load hit: answered now.
              core_gnt_o    = 1'b1;
              core_rvalid_o = 1'b1;
              core_rdata_o  = line_word(data_q[c_way][c_idx], `L1_SLOT(core_addr_i));
              lru_upd  = 1'b1;
              lru_idx  = c_idx;
              lru_used = c_way;
              fsm_events[EV_LD_HIT] = 1'b1;
            end else begin
              accept     = 1'b1;
              fill_way_d = c_victim;
              cs_d = (WRITE_BACK && state_q[c_victim][c_idx] == MSI_M) ? C_WB : C_FILL;
              fsm_events[EV_LD_MISS] = 1'b1;
            end
          end else if (WRITE_BACK) begin
            if (c_hit && state_q[c_way][c_idx] == MSI_M) begin
              // Store hit on a modified line: done in the cache.
              core_gnt_o    = 1'b1;
              core_rvalid_o = 1'b1;
              dt_we   = 1'b1;
              wr_way  = c_way;
              wr_idx  = c_idx;
              wr_data = line_merge(data_q[c_way][c_idx], word_to_line(core_wdata_i),
                                   word_be(core_be_i, `L1_SLOT(core_addr_i)));
              lru_upd  = 1'b1;
              lru_idx  = c_idx;
              lru_used = c_way;
              fsm_events[EV_ST_HIT] = 1'b1;
            end else if (c_hit) begin
              // Store to a shared line: upgrade in place.
              accept     = 1'b1;
              fill_way_d = c_way;
              cs_d       = C_FILL;
              fsm_events[EV_ST_MISS] = 1'b1;
            end else begin
              accept     = 1'b1;
              fill_way_d = c_victim;
              cs_d = (state_q[c_victim][c_idx] == MSI_M) ? C_WB : C_FILL;
              fsm_events[EV_ST_MISS] = 1'b1;
            end
          end else begin
            // Write-through store: always a bus write.
            accept = 1'b1;
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
          bus_wdata_o = data_q[fill_way_q][rq_idx];
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
          fill_line     = fill_upgrade ? data_q[fill_way_q][rq_idx] : bus_rdata_i;
          core_gnt_o    = 1'b1;
          core_rvalid_o = 1'b1;
          core_err_o    = bus_err_i;
          core_rdata_o  = line_word(fill_line, rq_slot);
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
          core_gnt_o    = 1'b1;
          core_rvalid_o = 1'b1;
          core_err_o    = bus_err_i;
          if (!bus_err_i && r_hit) begin
            // Keep this cache's own copy current. It stays S: memory was
            // written in the same transaction.
            dt_we   = 1'b1;
            wr_way  = r_way;
            wr_idx  = rq_idx;
            wr_data = line_merge(data_q[r_way][rq_idx], word_to_line(rq_wdata_q),
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
          core_gnt_o    = 1'b1;
          core_rvalid_o = 1'b1;
          core_err_o    = bus_err_i;
          core_rdata_o  = line_word(bus_rdata_i, rq_slot);
          cs_d          = C_IDLE;
        end
      end

      default: cs_d = C_IDLE;
    endcase
  end

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
      if (st_we)   state_q[wr_way][wr_idx] <= wr_state;
      if (snp_upd) state_q[s_way][s_idx]   <= snp_next;
    end
  end

  always_ff @(posedge clk_i) begin
    if (st_we) tag_q[wr_way][wr_idx]  <= wr_tag;
    if (dt_we) data_q[wr_way][wr_idx] <= wr_data;
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
