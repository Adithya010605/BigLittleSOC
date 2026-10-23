// ============================================================================
// snoop_bus.sv
//
// Atomic snooping bus for N L1 caches, with the shared L2 behind it: the bus
// side of MSI, the L2 controller and the snoop filter in one transaction
// engine.
//
// One transaction is in flight at a time and runs to completion before the
// next is granted, so no cache ever sees a transient coherence state: an L1
// is never snooped for a line it is in the middle of filling, and the L2
// never changes underneath a transaction.
//
// ---------------------------------------------------------------------------
// THE L2 (rtl/cache/l2_cache.sv)
// ---------------------------------------------------------------------------
// 64 KB, 4-way, write-back, write-allocate, and INCLUSIVE: every line held by
// any L1 is also held by the L2. Each L2 line carries a sharer bit per L1,
// which is the snoop filter: a coherent request snoops only the L1s whose bit
// is set, instead of broadcasting to all of them. Inclusion is what makes the
// filter sound: a line missing from the L2 is held by no L1, so a miss needs
// no snoop at all.
//
// Keeping inclusion means that when the L2 evicts a line to make room, it
// first invalidates every L1 copy of it (a BACK-INVALIDATION), taking the
// line from the L1 that holds it modified, if any, and then writes the line
// to memory if it is dirty.
//
// ---------------------------------------------------------------------------
// TRANSACTION
// ---------------------------------------------------------------------------
//
//   B_IDLE    round-robin grant; latch the request
//   B_LOOKUP  start reading the line's set out of the L2's data SRAM
//     uncached: straight to memory (B_MEM)
//   B_LDATA   the data has arrived: look the line up in the L2
//     hit:    snoop the sharers other than the requester if there are any
//             (B_SNOOP, B_SDATA), then act (B_ACT)
//     miss:   evict the victim way: back-invalidate its sharers (B_BINV,
//             B_BDATA), write it back if dirty (B_VWB); then fetch the line
//             (B_FILL), which also completes the request
//   B_SNOOP   one cycle: the sharers read the line's set out of their tag and
//             data SRAMs
//   B_SDATA   they answer: record whether any held a copy, and capture the
//             line from the one that held it M
//   B_ACT     update the L2 line (data, dirty, sharers) and respond
//
// Per command, on an L2 hit:
//
//   BUS_RD    snoop SNP_RD.   Data: the M owner's line if any (also written
//                             into the L2, owner -> S), else the L2's.
//                             Sharers |= requester.
//   BUS_RDX   snoop SNP_INV.  Data as BUS_RD.  Sharers = requester.
//   BUS_UPGR  snoop SNP_INV.  No data.         Sharers = requester.
//   BUS_WR    snoop SNP_INV.  The word is merged into the line (the owner's
//                             if any) and written into the L2, dirty.
//                             Sharers = requester only, if it had a copy.
//   BUS_WB    no snoop.       Line written into the L2, dirty; the writer's
//                             sharer bit cleared (its copy is now invalid).
//   BUS_UNC_* no snoop, no L2: uncached word access to memory.
//
// On an L2 miss the line is held by no L1, so no snoop is needed: after the
// victim is dealt with, the line is fetched from memory, installed (with the
// word merged and dirty for BUS_WR), and the requester answered in the same
// cycle. BUS_UPGR and BUS_WB always hit (the requester holds the line).
//
// Latency at zero memory wait states: an L2 hit is 4 cycles (grant, lookup,
// data, act), 6 with a snoop; an L2 miss with a clean victim is 4.
//
// ---------------------------------------------------------------------------
// MEMORY SIDE
// ---------------------------------------------------------------------------
// Fills, victim writebacks and uncached accesses. mem_req_o and its fields are
// driven from registers and held until mem_rvalid_i, which may arrive in the
// request cycle. Line accesses are line-aligned with 32 byte enables;
// uncached accesses (mem_uncached_o) are word accesses at mem_addr_o, with the
// word in its lane of the line.
// ============================================================================

module snoop_bus
  import cache_pkg::*;
#(
  parameter int unsigned N       = 8,
  parameter int unsigned L2_SETS = 512,
  localparam int unsigned MID_W  = (N > 1) ? $clog2(N) : 1
) (
  input  logic                             clk_i,
  input  logic                             rst_ni,

  // ---- From / to the L1 caches ----
  input  logic     [N-1:0]                 req_i,
  input  bus_cmd_e [N-1:0]                 cmd_i,
  input  logic     [N-1:0][31:0]           addr_i,
  input  logic     [N-1:0][LINE_BITS-1:0]  wdata_i,
  input  logic     [N-1:0][LINE_BYTES-1:0] be_i,
  output logic     [N-1:0]                 done_o,
  output logic     [LINE_BITS-1:0]         rdata_o,
  output logic                             err_o,

  // ---- Snoops ----
  output logic     [N-1:0]                 snoop_valid_o,
  output snoop_e                           snoop_type_o,
  output logic     [31:0]                  snoop_addr_o,
  input  logic     [N-1:0]                 snoop_hit_i,
  input  logic     [N-1:0]                 snoop_dirty_i,
  input  logic     [N-1:0][LINE_BITS-1:0]  snoop_data_i,

  // ---- Memory side ----
  output logic                             mem_req_o,
  output logic                             mem_we_o,
  output logic                             mem_uncached_o,
  output logic     [31:0]                  mem_addr_o,
  output logic     [LINE_BITS-1:0]         mem_wdata_o,
  output logic     [LINE_BYTES-1:0]        mem_be_o,
  input  logic                             mem_rvalid_i,
  input  logic     [LINE_BITS-1:0]         mem_rdata_i,
  input  logic                             mem_err_i,

  // ---- L2 probe (testbench invariant checks) ----
  input  logic     [31:0]                  dbg_addr_i,
  output logic                             dbg_l2_present_o,
  output logic                             dbg_l2_dirty_o,
  output logic     [N-1:0]                 dbg_l2_sharers_o,
  output logic     [LINE_BITS-1:0]         dbg_l2_data_o,

  // ---- Transaction monitor ----
  // mon_done_o pulses in the cycle a transaction completes. While one is in
  // flight (mon_busy_o), mon_addr_o is its line and, once an L2 victim has
  // been chosen (mon_vvalid_o), mon_vaddr_o is the victim's.
  output logic                             mon_done_o,
  output logic                             mon_busy_o,
  output logic     [MID_W-1:0]             mon_master_o,
  output bus_cmd_e                         mon_cmd_o,
  output logic     [31:0]                  mon_addr_o,
  output logic                             mon_shared_o,
  output logic                             mon_dirty_o,
  output logic                             mon_vvalid_o,
  output logic     [31:0]                  mon_vaddr_o,
  output logic     [NUM_L2EV-1:0]          l2_events_o
);

  typedef enum logic [3:0] {
    B_IDLE, B_LOOKUP, B_LDATA, B_BINV, B_BDATA, B_VWB, B_FILL, B_SNOOP, B_SDATA,
    B_ACT, B_MEM
  } bstate_e;

  bstate_e               bs_q, bs_d;
  logic [MID_W-1:0]      m_q;
  bus_cmd_e              cmd_q;
  logic [31:0]           addr_q;
  logic [LINE_BITS-1:0]  wdata_q;
  logic [LINE_BYTES-1:0] be_q;
  logic [MID_W-1:0]      rr_q;

  logic [1:0]            way_q;       // L2 way of the line (hit) or victim (miss)
  logic [N-1:0]          sharers_q;   // the line's sharers, at lookup
  logic                  vvalid_q;    // a victim is being evicted
  logic [31:0]           vaddr_q;
  logic [N-1:0]          vsharers_q;
  logic                  vdirty_q;
  logic [LINE_BITS-1:0]  vline_q;
  logic                  dirty_q;     // the snoop found a modified copy...
  logic [LINE_BITS-1:0]  line_q;      // ...and this is its line
  logic                  shared_q;    // the snoop found any copy
  logic [N-1:0]          starget_q;   // the L1s snooped in the last cycle
  logic [LINE_BITS-1:0]  lk_data;     // the L2's copy of the hit line

  logic [31:0] line_addr;
  assign line_addr = {addr_q[31:OFFSET_W], OFFSET_W'(0)};

  logic [N-1:0] m_bit;
  always_comb begin
    m_bit      = '0;
    m_bit[m_q] = 1'b1;
  end

  // --------------------------------------------------------------------
  // The L2
  // --------------------------------------------------------------------
  logic                 lk_hit, lk_dirty, vc_valid, vc_dirty;
  logic [1:0]           lk_way, vc_way;
  logic [N-1:0]         lk_sharers, vc_sharers;
  logic [LINE_BITS-1:0] lk_rdata, vc_data;    // valid in B_LDATA
  logic [31:0]          vc_addr;
  logic                 l2_rd;

  logic                 l2_we, l2_wvalid, l2_wdirty, l2_wdata_en, l2_touch;
  logic [1:0]           l2_wway;
  logic [31:0]          l2_waddr;
  logic [N-1:0]         l2_wsharers;
  logic [LINE_BITS-1:0] l2_wdata;

  l2_cache #(
    .SETS (L2_SETS),
    .NC   (N)
  ) u_l2 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .lk_addr_i     (line_addr),
    .rd_en_i       (l2_rd),
    .lk_hit_o      (lk_hit),
    .lk_way_o      (lk_way),
    .lk_sharers_o  (lk_sharers),
    .lk_dirty_o    (lk_dirty),
    .lk_data_o     (lk_rdata),
    .vc_way_o      (vc_way),
    .vc_valid_o    (vc_valid),
    .vc_dirty_o    (vc_dirty),
    .vc_addr_o     (vc_addr),
    .vc_sharers_o  (vc_sharers),
    .vc_data_o     (vc_data),
    .wr_en_i       (l2_we),
    .wr_way_i      (l2_wway),
    .wr_addr_i     (l2_waddr),
    .wr_valid_i    (l2_wvalid),
    .wr_dirty_i    (l2_wdirty),
    .wr_sharers_i  (l2_wsharers),
    .wr_data_en_i  (l2_wdata_en),
    .wr_data_i     (l2_wdata),
    .wr_touch_i    (l2_touch),
    .dbg_addr_i    (dbg_addr_i),
    .dbg_present_o (dbg_l2_present_o),
    .dbg_dirty_o   (dbg_l2_dirty_o),
    .dbg_sharers_o (dbg_l2_sharers_o),
    .dbg_data_o    (dbg_l2_data_o)
  );

  // --------------------------------------------------------------------
  // Round-robin arbitration
  // --------------------------------------------------------------------
  logic             gnt_any;
  logic [MID_W-1:0] gnt_id;
  always_comb begin
    gnt_any = 1'b0;
    gnt_id  = '0;
    for (int k = 0; k < int'(N); k++) begin
      int c;
      c = int'(rr_q) + k;
      if (c >= int'(N)) c = c - int'(N);
      if (!gnt_any && req_i[c]) begin
        gnt_any = 1'b1;
        gnt_id  = MID_W'(c);
      end
    end
  end

  // --------------------------------------------------------------------
  // Snoops: the line's other sharers (B_SNOOP), or every sharer of the
  // victim, the requester included (B_BINV)
  // --------------------------------------------------------------------
  logic [N-1:0] snoop_targets;
  always_comb begin
    unique case (bs_q)
      B_SNOOP: snoop_targets = sharers_q & ~m_bit;
      B_BINV:  snoop_targets = vsharers_q;
      default: snoop_targets = '0;
    endcase
  end
  assign snoop_valid_o = snoop_targets;
  assign snoop_type_o  = (bs_q == B_SNOOP && cmd_q == BUS_RD) ? SNP_RD : SNP_INV;
  assign snoop_addr_o  = (bs_q == B_BINV) ? vaddr_q : line_addr;

  // The snooped L1s answer in the cycle after the snoop (B_SDATA, B_BDATA):
  // did any hold the line, and the line of the one that held it modified.
  logic                 snp_shared;
  logic [N-1:0]         snp_dmask;
  assign snp_shared = (starget_q & snoop_hit_i) != '0;
  assign snp_dmask  = starget_q & snoop_dirty_i;

  logic                 snp_dirty;
  logic [LINE_BITS-1:0] snp_line;
  always_comb begin
    snp_dirty = 1'b0;
    snp_line  = '0;
    for (int i = 0; i < int'(N); i++) begin
      if (snp_dmask[i]) begin
        snp_dirty = 1'b1;
        snp_line  = snoop_data_i[i];
      end
    end
  end

  // --------------------------------------------------------------------
  // Control
  // --------------------------------------------------------------------
  logic                 complete;
  logic [LINE_BITS-1:0] base;     // current data of the line in B_ACT
  logic [N-1:0]         hit_targets;
  assign hit_targets = lk_sharers & ~m_bit;
  assign base        = dirty_q ? line_q : lk_data;

  always_comb begin
    bs_d           = bs_q;
    complete       = 1'b0;
    done_o         = '0;
    rdata_o        = mem_rdata_i;
    err_o          = 1'b0;

    mem_req_o      = 1'b0;
    mem_we_o       = 1'b0;
    mem_uncached_o = 1'b0;
    mem_addr_o     = line_addr;
    mem_wdata_o    = wdata_q;
    mem_be_o       = be_q;

    l2_we          = 1'b0;
    l2_wway        = way_q;
    l2_waddr       = line_addr;
    l2_wvalid      = 1'b1;
    l2_wdirty      = 1'b0;
    l2_wsharers    = '0;
    l2_wdata_en    = 1'b0;
    l2_wdata       = '0;
    l2_touch       = 1'b0;
    l2_rd          = 1'b0;

    l2_events_o    = '0;

    unique case (bs_q)
      // ------------------------------------------------------------------
      B_IDLE: if (gnt_any) bs_d = B_LOOKUP;

      // ------------------------------------------------------------------
      B_LOOKUP: begin
        if (cmd_q == BUS_UNC_RD || cmd_q == BUS_UNC_WR) begin
          bs_d = B_MEM;
        end else begin
          l2_rd = 1'b1;           // the set's data, every way, next cycle
          bs_d  = B_LDATA;
        end
      end

      // ------------------------------------------------------------------
      B_LDATA: begin
        if (lk_hit) begin
          l2_events_o[L2EV_HIT] = 1'b1;
          bs_d = (cmd_q != BUS_WB && hit_targets != '0) ? B_SNOOP : B_ACT;
        end else begin
          l2_events_o[L2EV_MISS] = 1'b1;
          if (vc_valid && vc_sharers != '0) bs_d = B_BINV;
          else if (vc_valid && vc_dirty)    bs_d = B_VWB;
          else                              bs_d = B_FILL;
        end
      end

      // ------------------------------------------------------------------
      B_BINV: begin
        l2_events_o[L2EV_BACKINV] = 1'b1;
        bs_d = B_BDATA;
      end

      B_BDATA: bs_d = (vdirty_q || snp_dirty) ? B_VWB : B_FILL;

      // ------------------------------------------------------------------
      B_VWB: begin
        mem_req_o   = 1'b1;
        mem_we_o    = 1'b1;
        mem_addr_o  = vaddr_q;
        mem_wdata_o = vline_q;
        mem_be_o    = '1;
        if (mem_rvalid_i) begin
          l2_events_o[L2EV_WRITEBACK] = 1'b1;
          bs_d = B_FILL;
        end
      end

      // ------------------------------------------------------------------
      B_FILL: begin
        mem_req_o = 1'b1;
        if (mem_rvalid_i) begin
          complete    = 1'b1;
          done_o[m_q] = 1'b1;
          rdata_o     = mem_rdata_i;
          err_o       = mem_err_i;
          // Install the line in the victim's way, which the L1s no longer
          // hold. A failed fill leaves the way empty.
          l2_we       = 1'b1;
          l2_wvalid   = !mem_err_i;
          l2_wdata_en = 1'b1;
          l2_touch    = 1'b1;
          if (cmd_q == BUS_WR) begin
            l2_wdata    = line_merge(mem_rdata_i, wdata_q, be_q);
            l2_wdirty   = 1'b1;
          end else begin
            l2_wdata    = mem_rdata_i;
            l2_wsharers = m_bit;          // BUS_RD / BUS_RDX
          end
          bs_d = B_IDLE;
        end
      end

      // ------------------------------------------------------------------
      B_SNOOP: bs_d = B_SDATA;

      B_SDATA: bs_d = B_ACT;

      // ------------------------------------------------------------------
      B_ACT: begin
        complete    = 1'b1;
        done_o[m_q] = 1'b1;
        rdata_o     = base;
        l2_we       = 1'b1;
        l2_touch    = 1'b1;
        l2_wdirty   = lk_dirty | dirty_q;
        l2_wdata_en = dirty_q;
        l2_wdata    = line_q;
        unique case (cmd_q)
          BUS_RD:   l2_wsharers = sharers_q | m_bit;
          BUS_RDX:  l2_wsharers = m_bit;
          BUS_UPGR: l2_wsharers = m_bit;
          BUS_WR: begin
            l2_wsharers = sharers_q & m_bit;
            l2_wdirty   = 1'b1;
            l2_wdata_en = 1'b1;
            l2_wdata    = line_merge(base, wdata_q, be_q);
          end
          BUS_WB: begin
            l2_wsharers = sharers_q & ~m_bit;
            l2_wdirty   = 1'b1;
            l2_wdata_en = 1'b1;
            l2_wdata    = wdata_q;
          end
          default: ;
        endcase
        bs_d = B_IDLE;
      end

      // ------------------------------------------------------------------
      B_MEM: begin
        mem_req_o      = 1'b1;
        mem_uncached_o = 1'b1;
        mem_we_o       = cmd_q == BUS_UNC_WR;
        mem_addr_o     = addr_q;
        if (mem_rvalid_i) begin
          complete    = 1'b1;
          done_o[m_q] = 1'b1;
          rdata_o     = mem_rdata_i;
          err_o       = mem_err_i;
          bs_d        = B_IDLE;
        end
      end

      default: bs_d = B_IDLE;
    endcase
  end

  assign mon_done_o   = complete;
  assign mon_busy_o   = bs_q != B_IDLE;
  assign mon_master_o = m_q;
  assign mon_cmd_o    = cmd_q;
  assign mon_addr_o   = addr_q;
  assign mon_shared_o = shared_q;
  assign mon_dirty_o  = dirty_q;
  assign mon_vvalid_o = vvalid_q;
  assign mon_vaddr_o  = vaddr_q;

  // --------------------------------------------------------------------
  // Registers
  // --------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bs_q       <= B_IDLE;
      m_q        <= '0;
      cmd_q      <= BUS_RD;
      addr_q     <= '0;
      wdata_q    <= '0;
      be_q       <= '0;
      rr_q       <= '0;
      way_q      <= '0;
      sharers_q  <= '0;
      vvalid_q   <= 1'b0;
      vaddr_q    <= '0;
      vsharers_q <= '0;
      vdirty_q   <= 1'b0;
      vline_q    <= '0;
      dirty_q    <= 1'b0;
      line_q     <= '0;
      shared_q   <= 1'b0;
      starget_q  <= '0;
      lk_data    <= '0;
    end else begin
      bs_q <= bs_d;
      unique case (bs_q)
        B_IDLE: if (gnt_any) begin
          m_q      <= gnt_id;
          cmd_q    <= cmd_i[gnt_id];
          addr_q   <= addr_i[gnt_id];
          wdata_q  <= wdata_i[gnt_id];
          be_q     <= be_i[gnt_id];
          rr_q     <= (int'(gnt_id) == int'(N) - 1) ? '0 : gnt_id + MID_W'(1);
          dirty_q  <= 1'b0;
          shared_q <= 1'b0;
          vvalid_q <= 1'b0;
        end
        B_LDATA: begin
          if (lk_hit) begin
            way_q     <= lk_way;
            sharers_q <= lk_sharers;
            lk_data   <= lk_rdata;
          end else begin
            way_q      <= vc_way;
            vvalid_q   <= vc_valid;
            vaddr_q    <= vc_addr;
            vsharers_q <= vc_sharers;
            vdirty_q   <= vc_dirty;
            vline_q    <= vc_data;
          end
        end
        B_BINV: starget_q <= snoop_valid_o;
        B_BDATA: if (snp_dirty) begin
          vdirty_q <= 1'b1;
          vline_q  <= snp_line;    // the L1's modified copy is the newest
        end
        B_SNOOP: starget_q <= snoop_valid_o;
        B_SDATA: begin
          dirty_q  <= snp_dirty;
          shared_q <= snp_shared;
          line_q   <= snp_line;
        end
        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  // --------------------------------------------------------------------
  // Simulation assertions
  // --------------------------------------------------------------------
  // (The snooped L1s answer in B_SDATA / B_BDATA.)
  logic [N-1:0] a_dirty;
  assign a_dirty = snp_dmask;
  always_ff @(posedge clk_i) begin
    if (bs_q == B_SDATA || bs_q == B_BDATA) begin
      assert ((a_dirty & (a_dirty - N'(1))) == '0)
        else $error("snoop_bus: more than one cache holds line %08x modified", snoop_addr_o);
    end
    if (bs_q == B_SDATA) begin
      assert (!(cmd_q == BUS_UPGR && a_dirty != '0))
        else $error("snoop_bus: BUS_UPGR found a modified copy of %08x", line_addr);
    end
    if (bs_q == B_LDATA) begin
      // The requester of an upgrade or a writeback holds the line, so an
      // inclusive L2 must hold it too.
      assert (lk_hit || !(cmd_q == BUS_UPGR || cmd_q == BUS_WB))
        else $error("snoop_bus: inclusion broken: %s of %08x missed in the L2",
                    cmd_q.name(), line_addr);
    end
  end
`endif

endmodule
