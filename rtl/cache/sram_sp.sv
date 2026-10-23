// ============================================================================
// sram_sp.sv
//
// Single-port synchronous SRAM, one line (WIDTH bits) per word: what every
// cache data array and the system RAM are built from.
//
//   * One access per cycle (ce_i): a write (we_i) or a read.
//   * A read's data appears on rdata_o in the NEXT cycle, and only in that
//     cycle. Whatever needs it later must keep it in a register.
//   * A write writes the whole word: there are no byte enables. A partial
//     update is a read, a merge, and a write of the merged word.
//
// For synthesis it is built from ASAP7 fake-RAM macros, the platform's
// black-box SRAMs with a real outline, pins and timing: fakeram7_256x256 for
// line data (WIDTH 256), fakeram7_256x32 for up to 32 bits (cache tags).
// DEPTH must be a multiple of 256; deeper memories are banks of macros
// selected by the top address bits. WIDTH is at most 256.
//
// Simulation uses the behavioural model below. Like the macro, it gives valid
// read data only in the cycle after a read; in any other cycle rdata_o is a
// poison pattern, so a design that uses stale read data fails its tests
// instead of passing in simulation and breaking in silicon. The debug port
// reads the array directly, for the testbenches' invariant checks only, and
// is constant zero in synthesis.
// ============================================================================

module sram_sp #(
  parameter int unsigned DEPTH = 256,
  parameter int unsigned WIDTH = 256,
  localparam int unsigned AW   = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
  input  logic             clk_i,
  input  logic             ce_i,
  input  logic             we_i,
  input  logic [AW-1:0]    addr_i,
  input  logic [WIDTH-1:0] wdata_i,
  output logic [WIDTH-1:0] rdata_o,

  // Simulation-only probe
  input  logic [AW-1:0]    dbg_addr_i,
  output logic [WIDTH-1:0] dbg_rdata_o
);

`ifdef SYNTHESIS
  // ------------------------------------------------------------------------
  // ASAP7 fake-RAM macros: 256 words each, 256 bits wide for line data or 32
  // bits wide for anything up to 32 bits (cache tags, zero-padded).
  // ------------------------------------------------------------------------
  localparam int unsigned NB = DEPTH / 256;            // banks of 256 words
  localparam int unsigned MW = (WIDTH > 32) ? 256 : 32; // macro width

  logic [MW-1:0]           wd;
  logic [NB-1:0][MW-1:0]   bank_rdata;
  logic [NB-1:0]           bank_ce;
  logic [MW-1:0]           rd;

  assign wd = MW'(wdata_i);

  if (NB == 1) begin : g_one
    assign bank_ce[0] = ce_i;
    assign rd         = bank_rdata[0];
  end else begin : g_banks
    localparam int unsigned BW = $clog2(NB);
    logic [BW-1:0] bank, bank_q;
    assign bank = addr_i[AW-1 -: BW];
    for (genvar b = 0; b < int'(NB); b++) begin : g_ce
      assign bank_ce[b] = ce_i && bank == BW'(b);
    end
    always_ff @(posedge clk_i) begin
      if (ce_i && !we_i) bank_q <= bank;
    end
    assign rd = bank_rdata[bank_q];
  end

  for (genvar b = 0; b < int'(NB); b++) begin : g_bank
    if (MW == 256) begin : g_line
      fakeram7_256x256 u_ram (
        .clk     (clk_i),
        .ce_in   (bank_ce[b]),
        .we_in   (we_i),
        .addr_in (addr_i[7:0]),
        .wd_in   (wd),
        .rd_out  (bank_rdata[b])
      );
    end else begin : g_word
      fakeram7_256x32 u_ram (
        .clk     (clk_i),
        .ce_in   (bank_ce[b]),
        .we_in   (we_i),
        .addr_in (addr_i[7:0]),
        .wd_in   (wd),
        .rd_out  (bank_rdata[b])
      );
    end
  end

  assign rdata_o     = rd[WIDTH-1:0];
  assign dbg_rdata_o = '0;

  logic unused_dbg;
  assign unused_dbg = ^{dbg_addr_i, rd};

`else
  // ------------------------------------------------------------------------
  // Behavioural model
  // ------------------------------------------------------------------------
  logic [WIDTH-1:0] mem [DEPTH];
  logic [WIDTH-1:0] rd_q;
  logic             rd_valid_q;

  // Starts zeroed: the system RAM always did. (The caches never read a word
  // they have not written: their tags and states say which words are valid.)
  initial begin
    for (int i = 0; i < int'(DEPTH); i++) mem[i] = '0;
  end

  always_ff @(posedge clk_i) begin
    rd_valid_q <= ce_i && !we_i;
    if (ce_i) begin
      if (we_i) mem[addr_i] <= wdata_i;
      else      rd_q        <= mem[addr_i];
    end
  end

  localparam logic [255:0] POISON = {8{32'hDEAD_BEEF}};
  assign rdata_o     = rd_valid_q ? rd_q : POISON[WIDTH-1:0];
  assign dbg_rdata_o = mem[dbg_addr_i];
`endif

endmodule
