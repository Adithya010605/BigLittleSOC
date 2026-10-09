// ============================================================================
// sysctl.sv
//
// System control: identification, the interconnect's QoS registers, and the
// performance counters that make cache miss rates and interconnect
// contention measurable from software (plan §5 Phase 3 exit criterion,
// "miss rates measurable"; §3.1 "QoS registers").
//
//   0x000  R   ID           0x534F_4331 ("SOC1")
//   0x004  R   CONFIG       [7:0] P-cores, [15:8] E-cores, [23:16] masters
//   0x008  W   CTRL         bit 0: clear every counter
//   0x010  RW  QOS_PRIO     2 bits per interconnect master (bits 2m+1:2m)
//   0x014  RW  STARVE_LIMIT cycles a waiting master may be passed over
//   0x100  R   L1 counters, 8 bytes per L1 (data caches by hart, then
//              instruction caches by hart):  +0 hits  +4 misses
//   0x200  R   L2:  +0 hits  +4 misses  +8 writebacks  +C back-invalidations
//   0x300  R   interconnect, 8 bytes per master:  +0 grants  +4 wait cycles
//
// Counters are 32 bits and wrap. Any other offset answers with an error.
// ============================================================================

module sysctl
  import cache_pkg::*;
#(
  parameter int unsigned  NUM_P     = 2,
  parameter int unsigned  NUM_E     = 2,
  parameter int unsigned  NM        = 4,
  parameter logic [NM-1:0][1:0] QOS_RESET = '0,
  parameter logic [7:0]   STARVE_RESET = 8'd16,
  localparam int unsigned NL1 = 2 * (NUM_P + NUM_E)
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic                         req_valid_i,
  output logic                         req_ready_o,
  input  logic [31:0]                  req_addr_i,
  input  logic                         req_write_i,
  input  logic [LINE_BITS-1:0]         req_wdata_i,
  input  logic [LINE_BYTES-1:0]        req_wstrb_i,
  output logic                         rsp_valid_o,
  output logic [LINE_BITS-1:0]         rsp_rdata_o,
  output logic                         rsp_err_o,

  output logic [NM-1:0][1:0]           qos_prio_o,
  output logic [7:0]                   starve_limit_o,

  input  logic [NL1-1:0][NUM_EV-1:0]   l1_events_i,
  input  logic [NUM_L2EV-1:0]          l2_events_i,
  input  logic [NM-1:0]                fab_grant_i,
  input  logic [NM-1:0]                fab_wait_i
);

  logic [NL1-1:0][31:0] l1_hit_q, l1_miss_q;
  logic [3:0][31:0]     l2_q;
  logic [NM-1:0][31:0]  grant_q, wait_q;
  logic                 pending_q, err_q;
  logic [31:0]          rword_q;
  logic [WORD_SEL_W-1:0] rslot_q;

  logic [WORD_SEL_W-1:0] slot;
  logic [31:0]           wword;
  logic [11:0]           off;
  assign slot  = req_addr_i[2 +: WORD_SEL_W];
  assign wword = line_word(req_wdata_i, slot);
  assign off   = req_addr_i[11:0];

  // Register read and validity, combinational on the request.
  logic        rvalid_reg;
  logic [31:0] rword;
  always_comb begin
    rvalid_reg = 1'b1;
    rword      = '0;
    // The interconnect delivers only addresses inside this slave's 4 KB
    // window, so the offset alone identifies the register.
    if (off[1:0] != 2'b00) begin
      rvalid_reg = 1'b0;
    end else if (off == 12'h000) begin
      rword = 32'h534F_4331;
    end else if (off == 12'h004) begin
      rword = {8'd0, 8'(NM), 8'(NUM_E), 8'(NUM_P)};
    end else if (off == 12'h008) begin
      rword = '0;
    end else if (off == 12'h010) begin
      rword = 32'(qos_prio_o);
    end else if (off == 12'h014) begin
      rword = {24'd0, starve_limit_o};
    end else if (off >= 12'h100 && off < 12'h100 + 12'(8 * NL1)) begin
      rword = off[2] ? l1_miss_q[(off - 12'h100) >> 3] : l1_hit_q[(off - 12'h100) >> 3];
    end else if (off >= 12'h200 && off < 12'h210) begin
      rword = l2_q[off[3:2]];
    end else if (off >= 12'h300 && off < 12'h300 + 12'(8 * NM)) begin
      rword = off[2] ? wait_q[(off - 12'h300) >> 3] : grant_q[(off - 12'h300) >> 3];
    end else begin
      rvalid_reg = 1'b0;
    end
  end

  assign req_ready_o = !pending_q;
  assign rsp_valid_o = pending_q;
  assign rsp_rdata_o = LINE_BITS'(rword_q) << (32 * int'(rslot_q));
  assign rsp_err_o   = err_q;

  logic accept, wr, clear;
  assign accept = req_valid_i && req_ready_o;
  assign wr     = accept && rvalid_reg && req_write_i && req_wstrb_i[4*int'(slot) +: 4] != '0;
  assign clear  = wr && off == 12'h008 && wword[0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      l1_hit_q       <= '0;
      l1_miss_q      <= '0;
      l2_q           <= '0;
      grant_q        <= '0;
      wait_q         <= '0;
      qos_prio_o     <= QOS_RESET;
      starve_limit_o <= STARVE_RESET;
      pending_q      <= 1'b0;
      err_q          <= 1'b0;
      rword_q        <= '0;
      rslot_q        <= '0;
    end else begin
      for (int c = 0; c < int'(NL1); c++) begin
        if (clear) begin
          l1_hit_q[c]  <= '0;
          l1_miss_q[c] <= '0;
        end else begin
          if (l1_events_i[c][EV_LD_HIT] || l1_events_i[c][EV_ST_HIT])   l1_hit_q[c]  <= l1_hit_q[c] + 32'd1;
          if (l1_events_i[c][EV_LD_MISS] || l1_events_i[c][EV_ST_MISS]) l1_miss_q[c] <= l1_miss_q[c] + 32'd1;
        end
      end
      for (int e = 0; e < 4; e++) begin
        if (clear)               l2_q[e] <= '0;
        else if (l2_events_i[e]) l2_q[e] <= l2_q[e] + 32'd1;
      end
      for (int m = 0; m < int'(NM); m++) begin
        if (clear) begin
          grant_q[m] <= '0;
          wait_q[m]  <= '0;
        end else begin
          if (fab_grant_i[m]) grant_q[m] <= grant_q[m] + 32'd1;
          if (fab_wait_i[m])  wait_q[m]  <= wait_q[m] + 32'd1;
        end
      end

      if (pending_q) pending_q <= 1'b0;
      if (accept) begin
        pending_q <= 1'b1;
        err_q     <= !rvalid_reg;
        rword_q   <= rword;
        rslot_q   <= slot;
      end
      if (wr && off == 12'h010) qos_prio_o     <= wword[2*NM-1:0];
      if (wr && off == 12'h014) starve_limit_o <= wword[7:0];
    end
  end

  logic unused_wword;
  assign unused_wword = ^{wword, req_addr_i[31:12]};

  logic unused_ev;
  always_comb begin
    unused_ev = 1'b0;
    for (int c = 0; c < int'(NL1); c++)
      unused_ev = unused_ev ^ (^{l1_events_i[c][EV_WRITEBACK], l1_events_i[c][EV_SNP_INV],
                                 l1_events_i[c][EV_SNP_FLUSH], l1_events_i[c][EV_UNCACHED]});
  end

endmodule
