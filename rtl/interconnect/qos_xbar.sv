// ============================================================================
// qos_xbar.sv
//
// QoS-aware crossbar: NM masters x NS slaves, plus a built-in decode-error
// responder for addresses no slave claims. This is the system interconnect of
// RISC-V_SoC_Project_Plan.md §3.1 (Phase 4, week 10).
//
// ---------------------------------------------------------------------------
// PROTOCOL (simplified AXI4-Lite)
// ---------------------------------------------------------------------------
// Two channels per port, each with a valid/ready handshake, one transaction
// outstanding per master:
//
//   request   addr, write, wdata, wstrb      (AXI's AW, W and AR merged)
//   response  rdata, err                     (AXI's R and B merged)
//
// The data path is one cache line (256 bits) wide with a byte strobe per
// byte, so an L2 fill or writeback is a single beat; a word access puts its
// word in its lane of the line and sets four strobes. A read returns the whole
// line (a word slave returns its word in the addressed lane). There are no
// IDs, bursts or out-of-order responses: one outstanding transaction per
// master makes them unnecessary.
//
// ---------------------------------------------------------------------------
// ARBITRATION (per slave, plan §3.1)
// ---------------------------------------------------------------------------
// Every slave has its own arbiter, so masters going to different slaves are
// granted in the same cycle. Among the masters requesting one slave:
//
//   1. anti-starvation: a master that has waited starve_limit_i cycles or
//      more is granted first (round-robin among such masters);
//   2. otherwise strict priority: the highest QoS level (qos_prio_i, 0..3,
//      programmable per master through the system-control registers) wins;
//   3. round-robin among masters at that level.
//
// A slave is granted again in the cycle its previous response arrives, so
// back-to-back transactions to one slave lose no arbitration cycle.
//
// ---------------------------------------------------------------------------
// TIMING
// ---------------------------------------------------------------------------
//   cycle t     master request granted (m_req_ready_o), request registered
//   cycle t+1   the slave sees it (s_req_valid_o) and accepts it
//   cycle t+k   the slave responds; the crossbar registers the response
//   cycle t+k+1 the master sees m_rsp_valid_o
// ============================================================================

module qos_xbar
  import cache_pkg::*;
#(
  parameter int unsigned NM = 4,
  parameter int unsigned NS = 4,
  // Slave j claims [SLV_BASE[j], SLV_LIMIT[j]).
  parameter logic [NS-1:0][31:0] SLV_BASE  = '0,
  parameter logic [NS-1:0][31:0] SLV_LIMIT = '0,
  localparam int unsigned MID_W = (NM > 1) ? $clog2(NM) : 1,
  localparam int unsigned SID_W = $clog2(NS + 1)       // NS = decode error
) (
  input  logic                             clk_i,
  input  logic                             rst_ni,

  // ---- QoS configuration ----
  input  logic [NM-1:0][1:0]               qos_prio_i,
  input  logic [7:0]                       starve_limit_i,

  // ---- Master ports ----
  input  logic [NM-1:0]                    m_req_valid_i,
  output logic [NM-1:0]                    m_req_ready_o,
  input  logic [NM-1:0][31:0]              m_req_addr_i,
  input  logic [NM-1:0]                    m_req_write_i,
  input  logic [NM-1:0][LINE_BITS-1:0]     m_req_wdata_i,
  input  logic [NM-1:0][LINE_BYTES-1:0]    m_req_wstrb_i,
  output logic [NM-1:0]                    m_rsp_valid_o,
  input  logic [NM-1:0]                    m_rsp_ready_i,
  output logic [NM-1:0][LINE_BITS-1:0]     m_rsp_rdata_o,
  output logic [NM-1:0]                    m_rsp_err_o,

  // ---- Slave ports ----
  output logic [NS-1:0]                    s_req_valid_o,
  input  logic [NS-1:0]                    s_req_ready_i,
  output logic [NS-1:0][31:0]              s_req_addr_o,
  output logic [NS-1:0]                    s_req_write_o,
  output logic [NS-1:0][LINE_BITS-1:0]     s_req_wdata_o,
  output logic [NS-1:0][LINE_BYTES-1:0]    s_req_wstrb_o,
  input  logic [NS-1:0]                    s_rsp_valid_i,
  input  logic [NS-1:0][LINE_BITS-1:0]     s_rsp_rdata_i,
  input  logic [NS-1:0]                    s_rsp_err_i,

  // ---- Statistics: per master, per cycle ----
  output logic [NM-1:0]                    grant_o,   // request granted
  output logic [NM-1:0]                    wait_o     // request waiting
);

  // --------------------------------------------------------------------
  // Address decode
  // --------------------------------------------------------------------
  logic [NM-1:0][SID_W-1:0] dec;
  always_comb begin
    for (int i = 0; i < int'(NM); i++) begin
      dec[i] = SID_W'(NS);
      for (int j = int'(NS) - 1; j >= 0; j--) begin
        if (m_req_addr_i[i] >= SLV_BASE[j] && m_req_addr_i[i] < SLV_LIMIT[j]) dec[i] = SID_W'(j);
      end
    end
  end

  // --------------------------------------------------------------------
  // Per-master state: one transaction outstanding, its response buffered
  // --------------------------------------------------------------------
  logic [NM-1:0]                outstanding_q;
  logic [NM-1:0]                rsp_valid_q;
  logic [NM-1:0][LINE_BITS-1:0] rsp_rdata_q;
  logic [NM-1:0]                rsp_err_q;
  logic [NM-1:0][7:0]           wait_q;

  logic [NM-1:0] free;           // may issue a new request
  assign free = ~outstanding_q;

  // --------------------------------------------------------------------
  // Per-slave state
  // --------------------------------------------------------------------
  logic [NS-1:0]                   busy_q;        // a transaction is in progress
  logic [NS-1:0][MID_W-1:0]        owner_q;
  logic [NS-1:0]                   sreq_valid_q;  // request not yet accepted by the slave
  logic [NS-1:0][31:0]             sreq_addr_q;
  logic [NS-1:0]                   sreq_write_q;
  logic [NS-1:0][LINE_BITS-1:0]    sreq_wdata_q;
  logic [NS-1:0][LINE_BYTES-1:0]   sreq_wstrb_q;
  logic [NS-1:0][MID_W-1:0]        rr_q;

  assign s_req_valid_o = sreq_valid_q;
  assign s_req_addr_o  = sreq_addr_q;
  assign s_req_write_o = sreq_write_q;
  assign s_req_wdata_o = sreq_wdata_q;
  assign s_req_wstrb_o = sreq_wstrb_q;

  // A slave is free for a new grant when idle, or in the cycle its response
  // arrives.
  logic [NS-1:0] slave_free;
  assign slave_free = ~busy_q | s_rsp_valid_i;

  // --------------------------------------------------------------------
  // Arbitration
  // --------------------------------------------------------------------
  logic [NS-1:0]            sgnt_any;
  logic [NS-1:0][MID_W-1:0] sgnt_id;

  // Round-robin pick among the set bits of `cand`, starting at `start`.
  function automatic logic [MID_W:0] rr_pick(input logic [NM-1:0] cand,
                                             input logic [MID_W-1:0] start);
    logic             found;
    logic [MID_W-1:0] id;
    found = 1'b0;
    id    = '0;
    for (int k = 0; k < int'(NM); k++) begin
      int c;
      c = int'(start) + k;
      if (c >= int'(NM)) c = c - int'(NM);
      if (!found && cand[c]) begin
        found = 1'b1;
        id    = MID_W'(c);
      end
    end
    return {found, id};
  endfunction

  always_comb begin
    for (int j = 0; j < int'(NS); j++) begin
      logic [NM-1:0] cand, starving, top;
      logic [1:0]    best;
      logic [MID_W:0] pick;
      cand     = '0;
      starving = '0;
      best     = '0;
      for (int i = 0; i < int'(NM); i++) begin
        cand[i] = m_req_valid_i[i] && free[i] && dec[i] == SID_W'(j);
        if (cand[i] && wait_q[i] >= starve_limit_i) starving[i] = 1'b1;
        if (cand[i] && qos_prio_i[i] > best) best = qos_prio_i[i];
      end
      top = '0;
      for (int i = 0; i < int'(NM); i++) top[i] = cand[i] && qos_prio_i[i] == best;
      pick = rr_pick(starving != '0 ? starving : top, rr_q[j]);
      sgnt_any[j] = slave_free[j] && pick[MID_W];
      sgnt_id[j]  = pick[MID_W-1:0];
    end
  end

  // Per-master grant: to its slave, or to the decode-error responder (which
  // needs no arbitration: it is not a shared resource).
  logic [NM-1:0] mgnt;
  always_comb begin
    mgnt = '0;
    for (int i = 0; i < int'(NM); i++) begin
      if (m_req_valid_i[i] && free[i] && dec[i] == SID_W'(NS)) mgnt[i] = 1'b1;
    end
    for (int j = 0; j < int'(NS); j++) begin
      if (sgnt_any[j]) mgnt[sgnt_id[j]] = 1'b1;
    end
  end

  assign m_req_ready_o = mgnt;
  assign grant_o       = mgnt;
  assign wait_o        = m_req_valid_i & free & ~mgnt;

  assign m_rsp_valid_o = rsp_valid_q;
  assign m_rsp_rdata_o = rsp_rdata_q;
  assign m_rsp_err_o   = rsp_err_q;

  // --------------------------------------------------------------------
  // Registers
  // --------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      outstanding_q <= '0;
      rsp_valid_q   <= '0;
      rsp_rdata_q   <= '0;
      rsp_err_q     <= '0;
      wait_q        <= '0;
      busy_q        <= '0;
      owner_q       <= '0;
      sreq_valid_q  <= '0;
      sreq_addr_q   <= '0;
      sreq_write_q  <= '0;
      sreq_wdata_q  <= '0;
      sreq_wstrb_q  <= '0;
      rr_q          <= '0;
    end else begin
      // Masters: waiting time, delivered responses, decode errors.
      for (int i = 0; i < int'(NM); i++) begin
        if (mgnt[i] || !(m_req_valid_i[i] && free[i])) wait_q[i] <= '0;
        else if (wait_q[i] != 8'hFF)                   wait_q[i] <= wait_q[i] + 8'd1;

        if (rsp_valid_q[i] && m_rsp_ready_i[i]) begin
          rsp_valid_q[i]   <= 1'b0;
          outstanding_q[i] <= 1'b0;
        end
        if (mgnt[i]) outstanding_q[i] <= 1'b1;
        if (mgnt[i] && dec[i] == SID_W'(NS)) begin
          rsp_valid_q[i] <= 1'b1;
          rsp_rdata_q[i] <= '0;
          rsp_err_q[i]   <= 1'b1;
        end
      end

      // Slaves: accept, respond, grant.
      for (int j = 0; j < int'(NS); j++) begin
        if (sreq_valid_q[j] && s_req_ready_i[j]) sreq_valid_q[j] <= 1'b0;
        if (busy_q[j] && s_rsp_valid_i[j]) begin
          busy_q[j]                <= 1'b0;
          rsp_valid_q[owner_q[j]]  <= 1'b1;
          rsp_rdata_q[owner_q[j]]  <= s_rsp_rdata_i[j];
          rsp_err_q[owner_q[j]]    <= s_rsp_err_i[j];
        end
        if (sgnt_any[j]) begin
          busy_q[j]       <= 1'b1;
          owner_q[j]      <= sgnt_id[j];
          sreq_valid_q[j] <= 1'b1;
          sreq_addr_q[j]  <= m_req_addr_i[sgnt_id[j]];
          sreq_write_q[j] <= m_req_write_i[sgnt_id[j]];
          sreq_wdata_q[j] <= m_req_wdata_i[sgnt_id[j]];
          sreq_wstrb_q[j] <= m_req_wstrb_i[sgnt_id[j]];
          rr_q[j]         <= (int'(sgnt_id[j]) == int'(NM) - 1) ? '0 : sgnt_id[j] + MID_W'(1);
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    for (int j = 0; j < int'(NS); j++) begin
      // A slave responds only to a transaction it has accepted.
      if (s_rsp_valid_i[j]) begin
        assert (busy_q[j] && !sreq_valid_q[j])
          else $error("qos_xbar: slave %0d responded with no transaction accepted", j);
      end
    end
  end
`endif

endmodule
