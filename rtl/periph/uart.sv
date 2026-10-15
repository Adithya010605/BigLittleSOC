// ============================================================================
// uart.sv
//
// Transmit-only UART, at the addresses the test programs have always used:
//
//   +0x0  W  transmit the byte in the lowest enabled lane    R  0
//   +0x4  R  status: bit 0 = transmitter busy (never: the line is ideal)
//
// Each transmitted byte appears for one cycle on tx_valid_o / tx_byte_o,
// which is where a real serialiser would sit and where the testbench collects
// the output. Any other offset in the UART's window answers with an error,
// as the testbench's memory model did, so access-fault tests still fault.
// ============================================================================

module uart
  import cache_pkg::*;
(
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

  output logic                  tx_valid_o,
  output logic [7:0]            tx_byte_o
);

  logic pending_q, err_q;

  logic [WORD_SEL_W-1:0] slot;
  logic [31:0]           wword;
  logic [3:0]            wbe;
  logic [7:0]            off;
  assign slot  = req_addr_i[2 +: WORD_SEL_W];
  assign wword = line_word(req_wdata_i, slot);
  assign wbe   = req_wstrb_i[4*int'(slot) +: 4];
  assign off   = req_addr_i[7:0];

  logic valid_reg;
  assign valid_reg = (off == 8'h00) || (off == 8'h04);

  assign req_ready_o = !pending_q;
  assign rsp_valid_o = pending_q;
  assign rsp_rdata_o = '0;            // both registers read as zero
  assign rsp_err_o   = err_q;

  logic accept;
  assign accept = req_valid_i && req_ready_o;

  // The lowest enabled byte lane carries the character.
  logic [7:0] tx_byte;
  always_comb begin
    tx_byte = wword[7:0];
    for (int l = 3; l >= 0; l--) if (wbe[l]) tx_byte = wword[8*l +: 8];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q  <= 1'b0;
      err_q      <= 1'b0;
      tx_valid_o <= 1'b0;
      tx_byte_o  <= '0;
    end else begin
      tx_valid_o <= 1'b0;
      if (pending_q) pending_q <= 1'b0;
      if (accept) begin
        pending_q <= 1'b1;
        err_q     <= !valid_reg;
        if (req_write_i && off == 8'h00 && wbe != '0) begin
          tx_valid_o <= 1'b1;
          tx_byte_o  <= tx_byte;
        end
      end
    end
  end

  logic unused_addr;
  assign unused_addr = ^{req_addr_i[31:8]};

endmodule
