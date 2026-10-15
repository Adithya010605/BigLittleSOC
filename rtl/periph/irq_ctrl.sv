// ============================================================================
// irq_ctrl.sv
//
// Per-hart interrupt controller: hart h's block of registers is at
// +0x100 * h, with the semantics the single-core testbench model has always
// had (so every interrupt test runs unchanged):
//
//   +0x0  W  arm the timer: raise the timer interrupt after N more cycles
//         R  1 while the timer interrupt is raised
//   +0x4  W  clear the timer interrupt (and disarm)
//   +0x8  W  bit 0 drives the software interrupt
//   +0xC  W  bit 0 drives the external interrupt
//
// The timer interrupt stays raised until cleared, as a real timer's does: a
// handler that forgets to clear it shows up as a hang, not as one spurious
// trap. Any other offset, or a hart that does not exist, answers with an
// error.
// ============================================================================

module irq_ctrl
  import cache_pkg::*;
#(
  parameter int unsigned NH = 4
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  input  logic                  req_valid_i,
  output logic                  req_ready_o,
  input  logic [31:0]           req_addr_i,
  input  logic                  req_write_i,
  input  logic [LINE_BITS-1:0]  req_wdata_i,
  input  logic [LINE_BYTES-1:0] req_wstrb_i,
  output logic                  rsp_valid_o,
  output logic [LINE_BITS-1:0]  rsp_rdata_o,
  output logic                  rsp_err_o,

  output logic [NH-1:0]         irq_timer_o,
  output logic [NH-1:0]         irq_software_o,
  output logic [NH-1:0]         irq_external_o
);

  localparam int unsigned HID_W = (NH > 1) ? $clog2(NH) : 1;

  logic [NH-1:0][31:0] count_q;      // cycles to go; 0 = disarmed
  logic                pending_q, err_q;
  logic [LINE_BITS-1:0] rdata_q;

  logic [WORD_SEL_W-1:0] slot;
  logic [31:0]           wword;
  logic [7:0]            reg_off;
  logic [7:0]            hart;
  assign slot    = req_addr_i[2 +: WORD_SEL_W];
  assign wword   = line_word(req_wdata_i, slot);
  assign reg_off = req_addr_i[7:0];
  assign hart    = req_addr_i[15:8];

  logic [HID_W-1:0] hid;
  assign hid = hart[HID_W-1:0];

  logic valid_reg;
  // The interconnect delivers only addresses inside this slave's 64 KB
  // window, so the offset alone identifies the register.
  assign valid_reg = int'(hart) < int'(NH) &&
                     (reg_off == 8'h0 || reg_off == 8'h4 || reg_off == 8'h8 || reg_off == 8'hC);

  assign req_ready_o = !pending_q;
  assign rsp_valid_o = pending_q;
  assign rsp_rdata_o = rdata_q;
  assign rsp_err_o   = err_q;

  logic accept;
  assign accept = req_valid_i && req_ready_o;

  logic wr;
  assign wr = accept && valid_reg && req_write_i && req_wstrb_i[4*int'(slot) +: 4] != '0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      count_q        <= '0;
      irq_timer_o    <= '0;
      irq_software_o <= '0;
      irq_external_o <= '0;
      pending_q      <= 1'b0;
      err_q          <= 1'b0;
      rdata_q        <= '0;
    end else begin
      for (int h = 0; h < int'(NH); h++) begin
        if (count_q[h] == 32'd1) irq_timer_o[h] <= 1'b1;
        if (count_q[h] != '0)    count_q[h]     <= count_q[h] - 32'd1;
      end
      if (pending_q) pending_q <= 1'b0;
      if (accept) begin
        pending_q <= 1'b1;
        err_q     <= !valid_reg;
        rdata_q   <= '0;
        if (valid_reg && !req_write_i && reg_off == 8'h0)
          rdata_q <= LINE_BITS'(irq_timer_o[hid]) << (32 * int'(slot));
      end
      if (wr) begin
        unique case (reg_off)
          8'h0: begin
            count_q[hid]     <= wword;
            irq_timer_o[hid] <= 1'b0;
          end
          8'h4: begin
            count_q[hid]     <= '0;
            irq_timer_o[hid] <= 1'b0;
          end
          8'h8: irq_software_o[hid] <= wword[0];
          default: irq_external_o[hid] <= wword[0];   // 8'hC
        endcase
      end
    end
  end

  logic unused_addr;
  assign unused_addr = ^req_addr_i[31:16];

endmodule
