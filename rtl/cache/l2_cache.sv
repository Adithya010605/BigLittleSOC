// ============================================================================
// l2_cache.sv
//
// Storage for the shared L2: 64 KB, 4-way set-associative, 32-byte lines,
// tree pseudo-LRU, write-back. Each line also carries the snoop filter: one
// bit per L1 cache that may hold a copy.
//
// This module is the arrays and the replacement state only. The L2 is
// controlled by the snooping bus (rtl/coherence/snoop_bus.sv), which owns the
// transaction that reads and writes it, because every L2 action is part of a
// coherence transaction: a fill must first evict a victim and invalidate its
// L1 copies (inclusion), and a hit decides which L1s to snoop.
//
// Tags, valid, dirty, sharer bits and the pseudo-LRU state are flip-flops;
// the line data is a single-port SRAM per way (sram_sp.sv).
//
// Ports:
//   lookup  combinational: does the L2 hold lk_addr_i's line, in which way,
//           with which sharers, dirty or not. Also the victim way for that
//           set (an invalid way first, else pseudo-LRU) and everything about
//           the line in it. The two lines' data (lk_data_o, vc_data_o) come
//           from the data SRAM: rd_en_i reads lk_addr_i's set, and the data
//           is there in the next cycle, for the same lk_addr_i.
//   write   one write per cycle: tag/valid/dirty/sharers of one way, and
//           optionally its data; optionally marks the way most recently used.
//   probe   a third lookup for the testbench's invariant checks.
//
// Sharer bits are conservative: an L1 that drops a clean line silently keeps
// its bit until the next invalidation clears it. A stale bit only costs a
// snoop that finds nothing; a missing bit would be a coherence bug, and the
// testbenches check that every L1 copy has its bit set.
// ============================================================================

module l2_cache
  import cache_pkg::*;
#(
  parameter int unsigned SETS = 512,     // 64 KB at 4 ways
  parameter int unsigned NC   = 8        // L1 caches tracked by the filter
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // ---- Lookup ----
  input  logic [31:0]           lk_addr_i,
  input  logic                  rd_en_i,
  output logic                  lk_hit_o,
  output logic [1:0]            lk_way_o,
  output logic [NC-1:0]         lk_sharers_o,
  output logic                  lk_dirty_o,
  output logic [LINE_BITS-1:0]  lk_data_o,
  // victim for lk_addr_i's set
  output logic [1:0]            vc_way_o,
  output logic                  vc_valid_o,
  output logic                  vc_dirty_o,
  output logic [31:0]           vc_addr_o,
  output logic [NC-1:0]         vc_sharers_o,
  output logic [LINE_BITS-1:0]  vc_data_o,

  // ---- Write ----
  input  logic                  wr_en_i,
  input  logic [1:0]            wr_way_i,
  input  logic [31:0]           wr_addr_i,
  input  logic                  wr_valid_i,
  input  logic                  wr_dirty_i,
  input  logic [NC-1:0]         wr_sharers_i,
  input  logic                  wr_data_en_i,
  input  logic [LINE_BITS-1:0]  wr_data_i,
  input  logic                  wr_touch_i,

  // ---- Probe ----
  input  logic [31:0]           dbg_addr_i,
  output logic                  dbg_present_o,
  output logic                  dbg_dirty_o,
  output logic [NC-1:0]         dbg_sharers_o,
  output logic [LINE_BITS-1:0]  dbg_data_o
);

  localparam int unsigned WAYS  = 4;
  localparam int unsigned IDX_W = $clog2(SETS);
  localparam int unsigned TAG_W = 32 - IDX_W - OFFSET_W;

  typedef logic [IDX_W-1:0] idx_t;
  typedef logic [TAG_W-1:0] tag_t;

  `define L2_IDX(a) a[OFFSET_W +: IDX_W]
  `define L2_TAG(a) a[31 -: TAG_W]

  tag_t                 tag_q     [WAYS][SETS];
  logic                 valid_q   [WAYS][SETS];
  logic                 dirty_q   [WAYS][SETS];
  logic [NC-1:0]        sharers_q [WAYS][SETS];
  logic [2:0]           plru_q    [SETS];

  logic [WAYS-1:0][LINE_BITS-1:0] rd_line;    // valid the cycle after rd_en_i
  logic [WAYS-1:0][LINE_BITS-1:0] dbg_line;

  // --------------------------------------------------------------------
  // Lookup and victim
  // --------------------------------------------------------------------
  idx_t       l_idx;
  logic       l_inv_found;
  logic [1:0] l_inv_way;
  always_comb begin
    l_idx       = `L2_IDX(lk_addr_i);
    lk_hit_o    = 1'b0;
    lk_way_o    = '0;
    l_inv_found = 1'b0;
    l_inv_way   = '0;
    for (int w = 0; w < int'(WAYS); w++) begin
      if (valid_q[w][l_idx] && tag_q[w][l_idx] == `L2_TAG(lk_addr_i)) begin
        lk_hit_o = 1'b1;
        lk_way_o = 2'(w);
      end
      if (!valid_q[w][l_idx] && !l_inv_found) begin
        l_inv_found = 1'b1;
        l_inv_way   = 2'(w);
      end
    end
  end
  assign lk_sharers_o = sharers_q[lk_way_o][l_idx];
  assign lk_dirty_o   = dirty_q[lk_way_o][l_idx];
  assign lk_data_o    = rd_line[lk_way_o];

  assign vc_way_o     = l_inv_found ? l_inv_way : plru4_victim(plru_q[l_idx]);
  assign vc_valid_o   = valid_q[vc_way_o][l_idx];
  assign vc_dirty_o   = dirty_q[vc_way_o][l_idx];
  assign vc_addr_o    = {tag_q[vc_way_o][l_idx], l_idx, OFFSET_W'(0)};
  assign vc_sharers_o = sharers_q[vc_way_o][l_idx];
  assign vc_data_o    = rd_line[vc_way_o];

  // --------------------------------------------------------------------
  // Probe
  // --------------------------------------------------------------------
  idx_t       d_idx;
  logic [1:0] d_way;
  always_comb begin
    d_idx         = `L2_IDX(dbg_addr_i);
    dbg_present_o = 1'b0;
    d_way         = '0;
    for (int w = 0; w < int'(WAYS); w++) begin
      if (valid_q[w][d_idx] && tag_q[w][d_idx] == `L2_TAG(dbg_addr_i)) begin
        dbg_present_o = 1'b1;
        d_way         = 2'(w);
      end
    end
  end
  assign dbg_dirty_o   = dirty_q[d_way][d_idx];
  assign dbg_sharers_o = sharers_q[d_way][d_idx];
  assign dbg_data_o    = dbg_line[d_way];

  // --------------------------------------------------------------------
  // Write
  // --------------------------------------------------------------------
  idx_t w_idx;
  assign w_idx = `L2_IDX(wr_addr_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int w = 0; w < int'(WAYS); w++) begin
        for (int s = 0; s < int'(SETS); s++) valid_q[w][s] <= 1'b0;
      end
      for (int s = 0; s < int'(SETS); s++) plru_q[s] <= '0;
    end else begin
      if (wr_en_i) valid_q[wr_way_i][w_idx] <= wr_valid_i;
      if (wr_en_i && wr_touch_i) plru_q[w_idx] <= plru4_touch(plru_q[w_idx], wr_way_i);
    end
  end

  always_ff @(posedge clk_i) begin
    if (wr_en_i) begin
      tag_q[wr_way_i][w_idx]     <= `L2_TAG(wr_addr_i);
      dirty_q[wr_way_i][w_idx]   <= wr_dirty_i;
      sharers_q[wr_way_i][w_idx] <= wr_sharers_i;
    end
  end

  // --------------------------------------------------------------------
  // Data SRAM, one per way: a line write uses its way's SRAM; a read reads
  // every way's at lk_addr_i's set. The bus never does both in one cycle.
  // --------------------------------------------------------------------
  for (genvar w = 0; w < int'(WAYS); w++) begin : g_data
    logic wr_this;
    assign wr_this = wr_en_i && wr_data_en_i && wr_way_i == 2'(w);
    sram_sp #(
      .DEPTH (SETS),
      .WIDTH (LINE_BITS)
    ) u_data (
      .clk_i       (clk_i),
      .ce_i        (wr_this || rd_en_i),
      .we_i        (wr_this),
      .addr_i      (wr_this ? w_idx : l_idx),
      .wdata_i     (wr_data_i),
      .rdata_o     (rd_line[w]),
      .dbg_addr_i  (d_idx),
      .dbg_rdata_o (dbg_line[w])
    );
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    assert (!(rd_en_i && wr_en_i && wr_data_en_i))
      else $error("l2_cache: read and write of the data SRAM in one cycle");
  end
`endif

  logic unused_addr_bits;
  assign unused_addr_bits = ^{lk_addr_i[OFFSET_W-1:0], dbg_addr_i[OFFSET_W-1:0],
                              wr_addr_i[OFFSET_W-1:0]};

  `undef L2_IDX
  `undef L2_TAG

endmodule
