// ============================================================================
// sram_ctrl.sv
//
// The system RAM behind the interconnect: SIZE bytes of single-port SRAM
// (sram_sp.sv), one cache line (32 bytes) wide, with a byte strobe per byte
// (plan §3.4, "simple SRAM controller, 1-cycle access").
//
// A request is accepted when the controller is idle and the response follows
// one cycle later. A read returns the whole line holding the address. A write
// of a whole line (every strobe set) is performed in the accept cycle. The
// SRAM has no byte enables, so a partial write is a read of the line in the
// accept cycle and a write of the merged line in the next one; its response
// follows one cycle after that.
//
// stall_i delays the response, and the next acceptance, while it is high.
// Nothing in the SoC drives it: it is the testbench's latency knob, which is
// how every regression runs the whole system against slow memory as well as
// fast, the way the single-core regressions always have.
//
// The array starts zeroed in simulation (the testbench's memory always did);
// the debug probe reads the line holding dbg_addr_i for the testbench's
// coherence checks.
// ============================================================================

module sram_ctrl
  import cache_pkg::*;
#(
  parameter int unsigned SIZE = 32'h0003_0000      // bytes
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  logic                  stall_i,

  input  logic                  req_valid_i,
  output logic                  req_ready_o,
  input  logic [31:0]           req_addr_i,
  input  logic                  req_write_i,
  input  logic [LINE_BITS-1:0]  req_wdata_i,
  input  logic [LINE_BYTES-1:0] req_wstrb_i,
  output logic                  rsp_valid_o,
  output logic [LINE_BITS-1:0]  rsp_rdata_o,
  output logic                  rsp_err_o,

  input  logic [31:0]           dbg_addr_i,
  output logic [LINE_BITS-1:0]  dbg_line_o
);

  localparam int unsigned LINES  = SIZE / LINE_BYTES;
  localparam int unsigned LIDX_W = $clog2(LINES);

  function automatic logic [LIDX_W-1:0] lidx(input logic [31:0] a);
    return LIDX_W'(a >> OFFSET_W);
  endfunction

  logic                  pending_q;     // a response is owed
  logic                  merge_q;       // a partial write's merge is due now
  logic                  fresh_q;       // a read's data arrives now
  logic [LINE_BITS-1:0]  rdata_q;
  logic                  err_q;
  logic [LIDX_W-1:0]     widx_q;
  logic [LINE_BITS-1:0]  wdata_q;
  logic [LINE_BYTES-1:0] wstrb_q;

  logic in_range;
  assign in_range = req_addr_i < SIZE;

  assign req_ready_o = !pending_q && !stall_i;
  assign rsp_valid_o = pending_q && !merge_q && !stall_i;
  assign rsp_err_o   = err_q;

  logic accept;
  assign accept = req_valid_i && req_ready_o;

  logic full_write;
  assign full_write = req_write_i && req_wstrb_i == '1;

  // The SRAM: a whole-line write when accepted, the merge of a partial write
  // in the next cycle, a read for anything else accepted in range.
  logic                 ram_ce, ram_we;
  logic [LIDX_W-1:0]    ram_addr;
  logic [LINE_BITS-1:0] ram_wdata, ram_rdata;
  logic [LINE_BITS-1:0] dbg_line;

  always_comb begin
    ram_ce    = 1'b0;
    ram_we    = 1'b0;
    ram_addr  = lidx(req_addr_i);
    ram_wdata = req_wdata_i;
    if (merge_q) begin
      ram_ce    = 1'b1;
      ram_we    = 1'b1;
      ram_addr  = widx_q;
      ram_wdata = line_merge(ram_rdata, wdata_q, wstrb_q);
    end else if (accept && in_range) begin
      ram_ce    = 1'b1;
      ram_we    = full_write;
    end
  end

  sram_sp #(
    .DEPTH (LINES),
    .WIDTH (LINE_BITS)
  ) u_ram (
    .clk_i       (clk_i),
    .ce_i        (ram_ce),
    .we_i        (ram_we),
    .addr_i      (ram_addr),
    .wdata_i     (ram_wdata),
    .rdata_o     (ram_rdata),
    .dbg_addr_i  (lidx(dbg_addr_i)),
    .dbg_rdata_o (dbg_line)
  );

  assign dbg_line_o = (dbg_addr_i < SIZE) ? dbg_line : '0;

  // A read's line is used in the cycle it arrives, and kept in case the
  // response is stalled.
  assign rsp_rdata_o = fresh_q ? ram_rdata : rdata_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q <= 1'b0;
      merge_q   <= 1'b0;
      fresh_q   <= 1'b0;
      rdata_q   <= '0;
      err_q     <= 1'b0;
      widx_q    <= '0;
      wdata_q   <= '0;
      wstrb_q   <= '0;
    end else begin
      merge_q <= 1'b0;
      fresh_q <= 1'b0;
      if (fresh_q)     rdata_q   <= ram_rdata;
      if (rsp_valid_o) pending_q <= 1'b0;
      if (accept) begin
        pending_q <= 1'b1;
        err_q     <= !in_range;
        rdata_q   <= '0;
        fresh_q   <= in_range && !req_write_i;
        merge_q   <= in_range && req_write_i && !full_write;
        widx_q    <= lidx(req_addr_i);
        wdata_q   <= req_wdata_i;
        wstrb_q   <= req_wstrb_i;
      end
    end
  end

endmodule
