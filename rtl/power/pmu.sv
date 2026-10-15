// ============================================================================
// pmu.sv
//
// Power management and task migration (RISC-V_SoC_Project_Plan.md §2.3 and
// Phase 7): one block, because both act on the same per-core state -- which
// software context each core is running, and whether its clock may run.
//
// ---------------------------------------------------------------------------
// CONTEXTS AND CORES
// ---------------------------------------------------------------------------
// Software sees CONTEXTS, numbered 0..N-1: a context's number is what its
// mhartid reads, and its interrupts are the interrupt controller's block of
// that number. Each physical core either runs one context (active), or runs
// none (parked: halted, clock stopped). At reset core c runs context c.
//
// A context can MIGRATE to a parked core: the controller halts the source
// core at an instruction boundary, copies its architectural state into the
// migration buffer, moves the context's identity (mhartid) and interrupts to
// the destination, writes the state into it and lets it run. The source is
// left parked. Software is not involved and cannot tell, except by reading
// misa (the cores differ in the M extension) -- which is how the tests know.
//
//   state copied: x1..x31, pc, mstatus, mie, mtvec, mscratch, mepc, mcause,
//                 mtval (39 words). The performance counters are the
//                 core's own and are not moved.
//
// Migration FSM (plan §2.3):
//
//   IDLE -> QUIESCE   halt the source; wait until it is halted (pipeline
//                     drained, no fetch in flight)
//        -> SAVE      one item per cycle, source -> buffer
//        -> TRANSFER  the context's identity and interrupts move
//        -> RESTORE   one item per cycle, buffer -> destination
//        -> DONE      release the destination; the source stays parked
//
// About 2 x 39 + 4 cycles from the source halting to the destination
// running: inside the plan's 100-cycle budget.
//
// Triggers: a software write (MIG_CTRL); an IPC monitor (a P-core context
// whose instructions per window stay under LOW_THRESH for HYST windows moves
// to its E-core partner, an E-core context above HIGH_THRESH moves to its
// P-core partner); and a power budget (no more than BUDGET P-cores running:
// extra P-core contexts move to their E-core partners). Partners are P-core
// k and E-core k.
//
// ---------------------------------------------------------------------------
// POWER
// ---------------------------------------------------------------------------
//  * Per-core clock gating: a parked or sleeping core's clock stops once it
//    has halted.
//  * Sleep and wake-on-interrupt: a context asks to sleep (PWR_SLEEP); its
//    core halts at the next instruction boundary and its clock stops. Any of
//    its interrupt lines (or PWR_WAKE) restarts it, and it continues where it
//    stopped -- taking the interrupt if it has it enabled.
//  * DVFS stub: per cluster, the cores' clock runs at 1/1, 1/2 or 1/4 of the
//    system clock (a clock-enable divider); the caches and interconnect stay
//    at full speed, and the L1s hold a response for a core whose clock is
//    paused.
//  * Power domains: a cluster whose cores are all parked or asleep can be
//    switched off. Its L1 caches are flushed (modified lines written back,
//    everything invalidated) and then their clocks stop too. Waking a core,
//    or migrating a context, into a switched-off cluster switches it on.
//
// Register windows: power at 0x4000_0000, migration at 0x5000_0000 (plan
// §3.4). Both are listed in docs/power_migration.md.
// ============================================================================

module pmu
  import cache_pkg::*;
#(
  parameter int unsigned NUM_P = 2,
  parameter int unsigned NUM_E = 2,
  localparam int unsigned N      = NUM_P + NUM_E,
  localparam int unsigned CW     = (N > 1) ? $clog2(N) : 1,
  localparam int unsigned NITEMS = 39
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // ---- Power register window ----
  input  logic                    p_req_valid_i,
  output logic                    p_req_ready_o,
  input  logic [31:0]             p_req_addr_i,
  input  logic                    p_req_write_i,
  input  logic [LINE_BITS-1:0]    p_req_wdata_i,
  input  logic [LINE_BYTES-1:0]   p_req_wstrb_i,
  output logic                    p_rsp_valid_o,
  output logic [LINE_BITS-1:0]    p_rsp_rdata_o,
  output logic                    p_rsp_err_o,

  // ---- Migration register window ----
  input  logic                    m_req_valid_i,
  output logic                    m_req_ready_o,
  input  logic [31:0]             m_req_addr_i,
  input  logic                    m_req_write_i,
  input  logic [LINE_BITS-1:0]    m_req_wdata_i,
  input  logic [LINE_BYTES-1:0]   m_req_wstrb_i,
  output logic                    m_rsp_valid_o,
  output logic [LINE_BITS-1:0]    m_rsp_rdata_o,
  output logic                    m_rsp_err_o,

  // ---- Cores: halt/debug ports ----
  output logic [N-1:0]            halt_req_o,
  input  logic [N-1:0]            halted_i,
  input  logic [N-1:0]            retire_i,
  output logic [N-1:0][31:0]      hart_id_o,
  output logic [4:0]              dbg_rf_addr_o,      // shared by all cores
  output logic [11:0]             dbg_csr_addr_o,
  output logic [31:0]             dbg_wdata_o,
  output logic [N-1:0]            dbg_rf_we_o,        // per core
  output logic [N-1:0]            dbg_csr_we_o,
  output logic [N-1:0]            dbg_pc_we_o,
  input  logic [N-1:0][31:0]      dbg_rf_rdata_i,
  input  logic [N-1:0][31:0]      dbg_csr_rdata_i,
  input  logic [N-1:0][31:0]      dbg_pc_i,

  // ---- Clocks ----
  output logic [N-1:0]            core_clk_en_o,      // core's gated clock
  output logic [N-1:0]            l1_clk_en_o,        // its L1s' gated clock
  output logic [N-1:0]            l1_flush_o,
  input  logic [N-1:0]            l1_flush_done_i,

  // ---- Interrupts: per context in, per core out ----
  input  logic [N-1:0]            ctx_irq_timer_i,
  input  logic [N-1:0]            ctx_irq_software_i,
  input  logic [N-1:0]            ctx_irq_external_i,
  output logic [N-1:0]            irq_timer_o,
  output logic [N-1:0]            irq_software_o,
  output logic [N-1:0]            irq_external_o,

  output logic                    mig_busy_o
);

  // ====================================================================
  // Topology
  // ====================================================================
  function automatic logic is_p(input int c);
    return c < int'(NUM_P);
  endfunction
  // Partner core of c, or N if it has none.
  function automatic int partner(input int c);
    if (c < int'(NUM_P)) return (c < int'(NUM_E)) ? int'(NUM_P) + c : int'(N);
    return (c - int'(NUM_P) < int'(NUM_P)) ? c - int'(NUM_P) : int'(N);
  endfunction

  // The CSRs that travel with a context, in buffer order after x1..x31, pc.
  function automatic logic [11:0] item_csr(input int k);
    unique case (k)
      32:      return 12'h300;   // mstatus
      33:      return 12'h304;   // mie
      34:      return 12'h305;   // mtvec
      35:      return 12'h340;   // mscratch
      36:      return 12'h341;   // mepc
      37:      return 12'h342;   // mcause
      default: return 12'h343;   // mtval
    endcase
  endfunction

  // ====================================================================
  // Per-core state
  // ====================================================================
  logic [N-1:0]          active_q;
  logic [N-1:0][CW-1:0]  ctx_q;
  logic [N-1:0]          sleep_q;

  // DVFS: divider code per cluster (0: 1/1, 1: 1/2, 2+: 1/4) and its counter
  logic [1:0][1:0]       div_q;
  logic [1:0][1:0]       divcnt_q;
  logic [1:0]            pulse;
  always_comb begin
    for (int k = 0; k < 2; k++) pulse[k] = divcnt_q[k] == 2'd0;
  end

  // Power domains per cluster
  logic [1:0]            pd_req_off_q;   // software wants it off
  logic [1:0]            pd_off_q;       // it is off
  logic [1:0]            pd_flushing_q;  // its L1s are being flushed
  logic                  pd_refused_q;   // last request refused

  // ====================================================================
  // Migration state
  // ====================================================================
  typedef enum logic [2:0] { M_IDLE, M_QUIESCE, M_SAVE, M_TRANSFER, M_RESTORE, M_DONE } mstate_e;
  mstate_e               ms_q;
  logic [CW-1:0]         m_ctx_q, m_src_q, m_dst_q;
  logic [5:0]            m_k_q;
  logic [NITEMS-1:0][31:0] buf_q;
  logic [31:0]           m_lat_q, m_last_lat_q, m_count_q;
  logic                  m_err_q;
  logic [CW-1:0]         m_last_src_q, m_last_dst_q, m_last_ctx_q;

  logic m_busy;
  assign m_busy     = ms_q != M_IDLE;
  assign mig_busy_o = m_busy;

  // Auto-migration
  logic                  auto_en_q;
  logic [31:0]           window_q, low_q, high_q, win_cnt_q;
  logic [7:0]            hyst_q;
  logic [7:0]            budget_q;
  logic [N-1:0][31:0]    ipc_cnt_q, last_ipc_q;
  logic [N-1:0][7:0]     low_streak_q, high_streak_q;

  // Power report
  logic [N-1:0][31:0]    run_cyc_q, gated_cyc_q;

  // ====================================================================
  // Clock enables, halts, interrupt routing
  // ====================================================================
  logic [N-1:0] mig_force;   // source and destination run at full speed
  logic [N-1:0] mig_halt;
  always_comb begin
    for (int c = 0; c < int'(N); c++) begin
      mig_force[c] = m_busy && (CW'(c) == m_src_q || CW'(c) == m_dst_q);
      mig_halt[c]  = mig_force[c];
    end
  end

  always_comb begin
    for (int c = 0; c < int'(N); c++) begin
      automatic logic k = !is_p(c);
      halt_req_o[c]    = !active_q[c] || sleep_q[c] || mig_halt[c];
      l1_clk_en_o[c]   = !pd_off_q[k];
      core_clk_en_o[c] = !pd_off_q[k] &&
                         (mig_force[c] ||
                          (pulse[k] && !(halted_i[c] && (sleep_q[c] || !active_q[c]))));
      hart_id_o[c]     = 32'(ctx_q[c]);
      irq_timer_o[c]    = active_q[c] && ctx_irq_timer_i[ctx_q[c]];
      irq_software_o[c] = active_q[c] && ctx_irq_software_i[ctx_q[c]];
      irq_external_o[c] = active_q[c] && ctx_irq_external_i[ctx_q[c]];
      l1_flush_o[c]     = pd_flushing_q[k];
    end
  end

  // ====================================================================
  // Debug port, driven by the migration FSM
  // ====================================================================
  int item;
  assign item = int'(m_k_q);

  assign dbg_rf_addr_o  = (item < 31) ? 5'(item + 1) : 5'd0;
  assign dbg_csr_addr_o = item_csr(item);
  assign dbg_wdata_o    = buf_q[m_k_q < 6'(NITEMS) ? m_k_q : 6'd0];

  logic [31:0] item_rdata;
  always_comb begin
    if (item < 31)       item_rdata = dbg_rf_rdata_i[m_src_q];
    else if (item == 31) item_rdata = dbg_pc_i[m_src_q];
    else                 item_rdata = dbg_csr_rdata_i[m_src_q];
  end

  always_comb begin
    dbg_rf_we_o  = '0;
    dbg_csr_we_o = '0;
    dbg_pc_we_o  = '0;
    if (ms_q == M_RESTORE) begin
      if (item < 31)       dbg_rf_we_o[m_dst_q]  = 1'b1;
      else if (item == 31) dbg_pc_we_o[m_dst_q]  = 1'b1;
      else                 dbg_csr_we_o[m_dst_q] = 1'b1;
    end
  end

  // ====================================================================
  // Register access: one-cycle response on each window
  // ====================================================================
  logic [WORD_SEL_W-1:0] p_slot, m_slot;
  logic [31:0]           p_wword, m_wword;
  logic [11:0]           p_off, m_off;
  logic                  p_wr, m_wr;
  assign p_slot  = p_req_addr_i[2 +: WORD_SEL_W];
  assign m_slot  = m_req_addr_i[2 +: WORD_SEL_W];
  assign p_wword = line_word(p_req_wdata_i, p_slot);
  assign m_wword = line_word(m_req_wdata_i, m_slot);
  assign p_off   = p_req_addr_i[11:0];
  assign m_off   = m_req_addr_i[11:0];

  logic        p_pending_q, p_err_q, m_pending_q, m_err_rsp_q;
  logic [31:0] p_rword_q, m_rword_q;
  logic [WORD_SEL_W-1:0] p_rslot_q, m_rslot_q;

  assign p_req_ready_o = !p_pending_q;
  assign m_req_ready_o = !m_pending_q;
  assign p_rsp_valid_o = p_pending_q;
  assign m_rsp_valid_o = m_pending_q;
  assign p_rsp_rdata_o = LINE_BITS'(p_rword_q) << (32 * int'(p_rslot_q));
  assign m_rsp_rdata_o = LINE_BITS'(m_rword_q) << (32 * int'(m_rslot_q));
  assign p_rsp_err_o   = p_err_q;
  assign m_rsp_err_o   = m_err_rsp_q;

  logic p_acc, m_acc;
  assign p_acc = p_req_valid_i && p_req_ready_o;
  assign m_acc = m_req_valid_i && m_req_ready_o;
  assign p_wr  = p_acc && p_req_write_i && p_req_wstrb_i[4*int'(p_slot) +: 4] != '0;
  assign m_wr  = m_acc && m_req_write_i && m_req_wstrb_i[4*int'(m_slot) +: 4] != '0;

  // ---- power window ----
  logic        p_ok;
  logic [31:0] p_rword;
  always_comb begin
    p_ok    = p_off[1:0] == 2'b00;
    p_rword = '0;
    if (p_off == 12'h000)      p_rword = 32'h504D_5531;              // "PMU1"
    else if (p_off == 12'h004 || p_off == 12'h008 || p_off == 12'h00C) p_rword = '0;
    else if (p_off == 12'h010) p_rword = {28'd0, div_q[1], div_q[0]};
    else if (p_off == 12'h014) p_rword = {30'd0, pd_req_off_q};
    else if (p_off == 12'h018) p_rword = {21'd0, pd_refused_q, 4'd0, pd_flushing_q, 2'd0, pd_off_q};
    else if (p_off >= 12'h020 && p_off < 12'h020 + 12'(4 * N)) begin
      automatic int c = int'(p_off[11:2]) - 8;          // (off - 0x020) / 4
      p_rword = {20'd0, 4'(ctx_q[c]), 3'd0, l1_clk_en_o[c], core_clk_en_o[c], halted_i[c],
                 sleep_q[c], active_q[c]};
    end else if (p_off >= 12'h080 && p_off < 12'h080 + 12'(8 * N)) begin
      automatic int c = int'(p_off[11:3]) - 16;         // (off - 0x080) / 8
      p_rword = p_off[2] ? gated_cyc_q[c] : run_cyc_q[c];
    end else p_ok = 1'b0;
  end

  // ---- migration window ----
  logic        m_ok;
  logic [31:0] m_rword;
  always_comb begin
    m_ok    = m_off[1:0] == 2'b00;
    m_rword = '0;
    if (m_off == 12'h000)      m_rword = 32'h4D49_4731;              // "MIG1"
    else if (m_off == 12'h004) m_rword = '0;
    else if (m_off == 12'h008) m_rword = {16'd0, 5'd0, 3'(ms_q), 6'd0, m_err_q, m_busy};
    else if (m_off == 12'h00C) m_rword = m_count_q;
    else if (m_off == 12'h010) m_rword = m_last_lat_q;
    else if (m_off == 12'h014) m_rword = {20'd0, 4'(m_last_ctx_q), 4'(m_last_dst_q), 4'(m_last_src_q)};
    else if (m_off == 12'h020) m_rword = {31'd0, auto_en_q};
    else if (m_off == 12'h024) m_rword = window_q;
    else if (m_off == 12'h028) m_rword = low_q;
    else if (m_off == 12'h02C) m_rword = high_q;
    else if (m_off == 12'h030) m_rword = {24'd0, hyst_q};
    else if (m_off == 12'h034) m_rword = {24'd0, budget_q};
    else if (m_off >= 12'h040 && m_off < 12'h040 + 12'(4 * N)) begin
      automatic int c = int'(m_off[11:2]) - 16;         // (off - 0x040) / 4
      m_rword = {active_q[c], 27'd0, 4'(ctx_q[c])};
    end else if (m_off >= 12'h060 && m_off < 12'h060 + 12'(4 * N)) begin
      automatic int k = int'(m_off[11:2]) - 24;         // (off - 0x060) / 4
      for (int c = 0; c < int'(N); c++)
        if (active_q[c] && int'(ctx_q[c]) == k) m_rword = {1'b1, 27'd0, 4'(c)};
    end else if (m_off >= 12'h080 && m_off < 12'h080 + 12'(4 * N)) begin
      m_rword = last_ipc_q[(m_off - 12'h080) >> 2];
    end else if (m_off >= 12'h100 && m_off < 12'h100 + 12'(4 * NITEMS)) begin
      m_rword = buf_q[(m_off - 12'h100) >> 2];
    end else m_ok = 1'b0;
  end

  // ====================================================================
  // Migration requests: software, or the monitors
  // ====================================================================
  logic          req_go;
  logic [CW-1:0] req_ctx, req_dst;
  logic          req_dst_partner;
  logic          req_bad;          // a software request naming no such hart or core

  // Core c has a partner, and the partner is parked. (Written as a search, so
  // that no array is ever indexed by a partner number that may be N.)
  logic [N-1:0] partner_free;
  always_comb begin
    for (int c = 0; c < int'(N); c++) begin
      partner_free[c] = 1'b0;
      for (int d = 0; d < int'(N); d++)
        if (d == partner(c) && !active_q[d]) partner_free[c] = 1'b1;
    end
  end

  // Monitors' candidate, evaluated at the end of each window.
  logic          auto_go;
  logic [CW-1:0] auto_ctx, auto_dst;
  logic          win_end;
  assign win_end = win_cnt_q + 32'd1 >= window_q;

  always_comb begin
    automatic int np_active = 0;
    auto_go  = 1'b0;
    auto_ctx = '0;
    auto_dst = '0;
    for (int c = 0; c < int'(NUM_P); c++) if (active_q[c]) np_active++;
    // 1. power budget: too many P-cores running
    if (np_active > int'(budget_q)) begin
      for (int c = int'(NUM_P) - 1; c >= 0; c--) begin
        if (active_q[c] && !sleep_q[c] && partner_free[c]) begin
          auto_go  = 1'b1;
          auto_ctx = ctx_q[c];
          auto_dst = CW'(partner(c));
        end
      end
    end
    // 2. IPC: low on a P-core, high on an E-core
    if (!auto_go) begin
      for (int c = int'(N) - 1; c >= 0; c--) begin
        if (active_q[c] && !sleep_q[c] && partner_free[c] &&
            ((is_p(c) && low_streak_q[c] >= hyst_q) || (!is_p(c) && high_streak_q[c] >= hyst_q))) begin
          auto_go  = 1'b1;
          auto_ctx = ctx_q[c];
          auto_dst = CW'(partner(c));
        end
      end
    end
  end

  logic sw_go;
  assign sw_go = m_wr && m_off == 12'h004 && m_wword[31];

  always_comb begin
    req_go          = 1'b0;
    req_ctx         = '0;
    req_dst         = '0;
    req_dst_partner = 1'b0;
    req_bad         = 1'b0;
    if (sw_go) begin
      req_go          = 1'b1;
      req_ctx         = m_wword[CW-1:0];
      req_dst         = m_wword[4 +: CW];
      req_dst_partner = m_wword[7:4] == 4'hF;
      req_bad         = 32'(m_wword[3:0]) >= N ||
                        (!req_dst_partner && 32'(m_wword[7:4]) >= N);
    end else if (auto_en_q && win_end && auto_go) begin
      req_go  = 1'b1;
      req_ctx = auto_ctx;
      req_dst = auto_dst;
    end
  end

  // Source and destination of a request, and whether it can start.
  logic          req_src_found, req_ok;
  logic [CW-1:0] req_src, req_dst_eff;
  always_comb begin
    req_src_found = 1'b0;
    req_src       = '0;
    for (int c = 0; c < int'(N); c++) begin
      if (active_q[c] && ctx_q[c] == req_ctx && int'(req_ctx) < int'(N)) begin
        req_src_found = 1'b1;
        req_src       = CW'(c);
      end
    end
    req_dst_eff = req_dst;
    if (req_dst_partner) req_dst_eff = (partner(int'(req_src)) < int'(N)) ? CW'(partner(int'(req_src))) : req_src;
    req_ok = !req_bad && req_src_found && int'(req_dst_eff) < int'(N) && req_dst_eff != req_src &&
             !active_q[req_dst_eff] && !sleep_q[req_src] && pd_flushing_q == '0;
  end

  // ====================================================================
  // Sequential logic
  // ====================================================================
  logic [N-1:0] ctx_sel_sleep, ctx_sel_wake, ctx_sel_park;
  always_comb begin
    for (int c = 0; c < int'(N); c++) begin
      ctx_sel_sleep[c] = p_wr && p_off == 12'h004 && p_wword[5'(ctx_q[c])] && active_q[c];
      ctx_sel_wake[c]  = p_wr && p_off == 12'h008 && p_wword[5'(ctx_q[c])];
      ctx_sel_park[c]  = p_wr && p_off == 12'h00C && p_wword[5'(ctx_q[c])] && active_q[c] && !m_busy;
    end
  end

  logic [N-1:0] irq_any;
  always_comb begin
    for (int c = 0; c < int'(N); c++)
      irq_any[c] = irq_timer_o[c] | irq_software_o[c] | irq_external_o[c];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q      <= '1;
      for (int c = 0; c < int'(N); c++) ctx_q[c] <= CW'(c);
      sleep_q       <= '0;
      div_q         <= '0;
      divcnt_q      <= '0;
      pd_req_off_q  <= '0;
      pd_off_q      <= '0;
      pd_flushing_q <= '0;
      pd_refused_q  <= 1'b0;
      ms_q          <= M_IDLE;
      m_ctx_q       <= '0;
      m_src_q       <= '0;
      m_dst_q       <= '0;
      m_k_q         <= '0;
      buf_q         <= '0;
      m_lat_q       <= '0;
      m_last_lat_q  <= '0;
      m_count_q     <= '0;
      m_err_q       <= 1'b0;
      m_last_src_q  <= '0;
      m_last_dst_q  <= '0;
      m_last_ctx_q  <= '0;
      auto_en_q     <= 1'b0;
      window_q      <= 32'd1024;
      low_q         <= 32'd0;
      high_q        <= 32'hFFFF_FFFF;
      hyst_q        <= 8'd2;
      budget_q      <= 8'(NUM_P);
      win_cnt_q     <= '0;
      ipc_cnt_q     <= '0;
      last_ipc_q    <= '0;
      low_streak_q  <= '0;
      high_streak_q <= '0;
      run_cyc_q     <= '0;
      gated_cyc_q   <= '0;
      p_pending_q   <= 1'b0;
      p_err_q       <= 1'b0;
      p_rword_q     <= '0;
      p_rslot_q     <= '0;
      m_pending_q   <= 1'b0;
      m_err_rsp_q   <= 1'b0;
      m_rword_q     <= '0;
      m_rslot_q     <= '0;
    end else begin
      // ---- register responses ----
      if (p_pending_q) p_pending_q <= 1'b0;
      if (p_acc) begin
        p_pending_q <= 1'b1;
        p_err_q     <= !p_ok;
        p_rword_q   <= p_rword;
        p_rslot_q   <= p_slot;
      end
      if (m_pending_q) m_pending_q <= 1'b0;
      if (m_acc) begin
        m_pending_q <= 1'b1;
        m_err_rsp_q <= !m_ok;
        m_rword_q   <= m_rword;
        m_rslot_q   <= m_slot;
      end

      // ---- DVFS ----
      for (int k = 0; k < 2; k++) begin
        if (div_q[k] == 2'd0 || divcnt_q[k] == 2'd0)
          divcnt_q[k] <= (div_q[k] == 2'd0) ? 2'd0 : (div_q[k] == 2'd1 ? 2'd1 : 2'd3);
        else
          divcnt_q[k] <= divcnt_q[k] - 2'd1;
      end
      if (p_wr && p_off == 12'h010) begin
        div_q[0] <= p_wword[1:0];
        div_q[1] <= p_wword[3:2];
      end

      // ---- sleep, wake, park ----
      for (int c = 0; c < int'(N); c++) begin
        if (ctx_sel_sleep[c]) sleep_q[c] <= 1'b1;
        if (ctx_sel_wake[c] || (sleep_q[c] && irq_any[c])) sleep_q[c] <= 1'b0;
        if (ctx_sel_park[c]) begin
          active_q[c] <= 1'b0;
          sleep_q[c]  <= 1'b0;
        end
      end

      // ---- power domains ----
      if (p_wr && p_off == 12'h014) pd_req_off_q <= p_wword[1:0];
      for (int k = 0; k < 2; k++) begin
        automatic logic quiet = 1'b1;
        automatic logic flushed = 1'b1;
        automatic logic wake = 1'b0;
        for (int c = 0; c < int'(N); c++) begin
          if ((is_p(c) ? 0 : 1) == k) begin
            if (!(halted_i[c] && (sleep_q[c] || !active_q[c]))) quiet = 1'b0;
            if (!l1_flush_done_i[c]) flushed = 1'b0;
            if (sleep_q[c] && (irq_any[c] || ctx_sel_wake[c])) wake = 1'b1;
          end
        end
        if (m_busy && ((is_p(int'(m_dst_q)) ? 0 : 1) == k)) wake = 1'b1;
        if (pd_off_q[k]) begin
          if (!pd_req_off_q[k] || wake) begin
            pd_off_q[k] <= 1'b0;
            if (wake) pd_req_off_q[k] <= 1'b0;
          end
        end else if (pd_flushing_q[k]) begin
          if (wake || !pd_req_off_q[k]) begin
            pd_flushing_q[k] <= 1'b0;            // abandoned; caches stay valid
            pd_req_off_q[k]  <= 1'b0;
          end else if (flushed) begin
            pd_flushing_q[k] <= 1'b0;
            pd_off_q[k]      <= 1'b1;
          end
        end else if (pd_req_off_q[k]) begin
          if (quiet && !m_busy) begin
            pd_flushing_q[k] <= 1'b1;
            pd_refused_q     <= 1'b0;
          end else begin
            pd_req_off_q[k]  <= 1'b0;
            pd_refused_q     <= 1'b1;
          end
        end
      end

      // ---- IPC monitor and power report ----
      for (int c = 0; c < int'(N); c++) begin
        if (core_clk_en_o[c]) run_cyc_q[c]   <= run_cyc_q[c] + 32'd1;
        else                  gated_cyc_q[c] <= gated_cyc_q[c] + 32'd1;
      end
      if (win_end) begin
        win_cnt_q <= '0;
        for (int c = 0; c < int'(N); c++) begin
          automatic logic [31:0] n = ipc_cnt_q[c] + ((retire_i[c] && core_clk_en_o[c]) ? 32'd1 : 32'd0);
          last_ipc_q[c] <= n;
          ipc_cnt_q[c]  <= '0;
          if (active_q[c] && !sleep_q[c] && n < low_q)  low_streak_q[c] <= (low_streak_q[c] == 8'hFF) ? 8'hFF : low_streak_q[c] + 8'd1;
          else                                         low_streak_q[c] <= '0;
          if (active_q[c] && !sleep_q[c] && n > high_q) high_streak_q[c] <= (high_streak_q[c] == 8'hFF) ? 8'hFF : high_streak_q[c] + 8'd1;
          else                                         high_streak_q[c] <= '0;
        end
      end else begin
        win_cnt_q <= win_cnt_q + 32'd1;
        for (int c = 0; c < int'(N); c++)
          if (retire_i[c] && core_clk_en_o[c]) ipc_cnt_q[c] <= ipc_cnt_q[c] + 32'd1;
      end
      if (m_wr && m_off == 12'h020) auto_en_q <= m_wword[0];
      if (m_wr && m_off == 12'h024) window_q  <= (m_wword == '0) ? 32'd1 : m_wword;
      if (m_wr && m_off == 12'h028) low_q     <= m_wword;
      if (m_wr && m_off == 12'h02C) high_q    <= m_wword;
      if (m_wr && m_off == 12'h030) hyst_q    <= m_wword[7:0];
      if (m_wr && m_off == 12'h034) budget_q  <= m_wword[7:0];

      // ---- migration FSM ----
      if (m_busy) m_lat_q <= m_lat_q + 32'd1;
      unique case (ms_q)
        M_IDLE: begin
          if (req_go) begin
            if (req_ok) begin
              ms_q    <= M_QUIESCE;
              m_ctx_q <= req_ctx;
              m_src_q <= req_src;
              m_dst_q <= req_dst_eff;
              m_lat_q <= '0;
              m_err_q <= 1'b0;
              m_k_q   <= '0;
              // a monitor-triggered move restarts the streaks
              low_streak_q[req_src]  <= '0;
              high_streak_q[req_src] <= '0;
            end else if (sw_go) begin
              m_err_q <= 1'b1;
            end
          end
        end
        M_QUIESCE: if (halted_i[m_src_q] && !pd_off_q[is_p(int'(m_dst_q)) ? 0 : 1]) ms_q <= M_SAVE;
        M_SAVE: begin
          buf_q[m_k_q] <= item_rdata;
          if (m_k_q == 6'(NITEMS - 1)) begin
            ms_q  <= M_TRANSFER;
            m_k_q <= '0;
          end else begin
            m_k_q <= m_k_q + 6'd1;
          end
        end
        M_TRANSFER: begin
          ctx_q[m_dst_q]    <= m_ctx_q;
          active_q[m_dst_q] <= 1'b1;
          sleep_q[m_dst_q]  <= 1'b0;
          active_q[m_src_q] <= 1'b0;
          ms_q              <= M_RESTORE;
        end
        M_RESTORE: begin
          if (m_k_q == 6'(NITEMS - 1)) ms_q <= M_DONE;
          else                          m_k_q <= m_k_q + 6'd1;
        end
        M_DONE: begin
          ms_q         <= M_IDLE;
          m_count_q    <= m_count_q + 32'd1;
          m_last_lat_q <= m_lat_q + 32'd1;
          m_last_src_q <= m_src_q;
          m_last_dst_q <= m_dst_q;
          m_last_ctx_q <= m_ctx_q;
          m_k_q        <= '0;
        end
        default: ms_q <= M_IDLE;
      endcase
    end
  end

  logic unused;
  assign unused = ^{p_req_addr_i[31:12], m_req_addr_i[31:12], p_wword, m_wword};

endmodule
