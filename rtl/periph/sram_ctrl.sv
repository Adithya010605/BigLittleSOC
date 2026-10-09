// ============================================================================
// sram_ctrl.sv
//
// The system RAM behind the interconnect: SIZE bytes of single-port SRAM,
// one cache line (32 bytes) wide, with a byte strobe per byte (plan §3.4,
// "simple SRAM controller, 1-cycle access").
//
// A request is accepted when the controller is idle; the write (if any) is
// performed at the end of that cycle, and the response follows one cycle
// later. A read returns the whole line holding the address.
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

  logic [LINE_BITS-1:0] mem [LINES];

`ifndef SYNTHESIS
  initial begin
    for (int i = 0; i < int'(LINES); i++) mem[i] = '0;
  end
`endif

  function automatic logic [LIDX_W-1:0] lidx(input logic [31:0] a);
    return LIDX_W'(a >> OFFSET_W);
  endfunction

  logic                 pending_q;     // a response is owed
  logic [LINE_BITS-1:0] rdata_q;
  logic                 err_q;

  logic in_range;
  assign in_range = req_addr_i < SIZE;

  assign req_ready_o = !pending_q && !stall_i;
  assign rsp_valid_o = pending_q && !stall_i;
  assign rsp_rdata_o = rdata_q;
  assign rsp_err_o   = err_q;

  logic accept;
  assign accept = req_valid_i && req_ready_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q <= 1'b0;
      rdata_q   <= '0;
      err_q     <= 1'b0;
    end else begin
      if (rsp_valid_o) pending_q <= 1'b0;
      if (accept) begin
        pending_q <= 1'b1;
        err_q     <= !in_range;
        rdata_q   <= in_range ? mem[lidx(req_addr_i)] : '0;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (accept && req_write_i && in_range) begin
      mem[lidx(req_addr_i)] <= line_merge(mem[lidx(req_addr_i)], req_wdata_i, req_wstrb_i);
    end
  end

  assign dbg_line_o = (dbg_addr_i < SIZE) ? mem[lidx(dbg_addr_i)] : '0;

endmodule
