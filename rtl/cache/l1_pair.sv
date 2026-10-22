// ============================================================================
// l1_pair.sv
//
// One core's private caches: its L1 data cache and L1 instruction cache
// (both l1_dcache.sv) and the clock gate they share. Used by every tile
// (rtl/soc/p_tile.sv, e_tile.sv) and by the coherence unit testbench's
// coherent_mem.sv, so that a core's caches are configured in one place.
//
//   P-core (WRITE_BACK = 1): data cache write-back MSI; instruction cache
//                            read-only; both WAYS x SETS.
//   E-core (WRITE_BACK = 0): both caches write-through (the instruction
//                            cache's store path is unused); both WAYS x SETS.
//
// Each cache has its own bus and snoop port: index 0 is the data cache, 1 the
// instruction cache. The instruction cache is a cache that never stores: its
// lines are only S or I, and any store to a line, by any core, invalidates it
// (see coherent_mem.sv).
//
// The pair runs on its own gated clock (l1_clk_en_i: off only while the
// core's power domain is off), takes accesses only in cycles core_en_i says
// end with a core clock edge, and flushes as a pair: flush_done_o when both
// have finished.
// ============================================================================

module l1_pair
  import cache_pkg::*;
#(
  parameter int unsigned WAYS            = 1,
  parameter int unsigned SETS            = 256,
  parameter bit          WRITE_BACK      = 1'b0,
  parameter logic [31:0] CACHEABLE_LIMIT = 32'h0003_0000
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  input  logic                        core_en_i,
  input  logic                        l1_clk_en_i,
  input  logic                        flush_i,
  output logic                        flush_done_o,

  // ---- The core's data port ----
  input  logic                        d_req_i,
  input  logic [31:0]                 d_addr_i,
  input  logic                        d_we_i,
  input  logic [3:0]                  d_be_i,
  input  logic [31:0]                 d_wdata_i,
  output logic                        d_gnt_o,
  output logic                        d_rvalid_o,
  output logic [31:0]                 d_rdata_o,
  output logic                        d_err_o,

  // ---- The core's instruction port ----
  input  logic                        i_req_i,
  input  logic [31:0]                 i_addr_i,
  output logic                        i_gnt_o,
  output logic                        i_rvalid_o,
  output logic [31:0]                 i_rdata_o,
  output logic                        i_err_o,

  // ---- Bus and snoop ports: [0] data cache, [1] instruction cache ----
  output logic     [1:0]                 bus_req_o,
  output bus_cmd_e [1:0]                 bus_cmd_o,
  output logic     [1:0][31:0]           bus_addr_o,
  output logic     [1:0][LINE_BITS-1:0]  bus_wdata_o,
  output logic     [1:0][LINE_BYTES-1:0] bus_be_o,
  input  logic     [1:0]                 bus_done_i,
  input  logic     [LINE_BITS-1:0]       bus_rdata_i,
  input  logic                           bus_err_i,
  input  logic     [1:0]                 snoop_valid_i,
  input  snoop_e                         snoop_type_i,
  input  logic     [31:0]                snoop_addr_i,
  output logic     [1:0]                 snoop_hit_o,
  output logic     [1:0]                 snoop_dirty_o,
  output logic     [1:0][LINE_BITS-1:0]  snoop_data_o,

  // ---- Testbench probes and monitors, and event pulses ----
  input  logic     [31:0]                dbg_addr_i,
  output msi_e     [1:0]                 dbg_state_o,
  output logic     [1:0][LINE_BITS-1:0]  dbg_data_o,
  output logic     [1:0]                 perf_valid_o,
  output logic     [1:0][31:0]           perf_addr_o,
  output logic     [1:0]                 perf_we_o,
  output logic     [1:0][3:0]            perf_be_o,
  output logic     [1:0][31:0]           perf_wdata_o,
  output logic     [1:0][31:0]           perf_rdata_o,
  output logic     [1:0]                 perf_err_o,
  output logic     [1:0][NUM_EV-1:0]     events_o
);

  logic l1_clk;
  clock_gate u_cg (.clk_i(clk_i), .en_i(l1_clk_en_i), .clk_o(l1_clk));

  // Core-side ports of the two caches: [0] data, [1] instruction.
  logic [1:0]       req, we, gnt, rvalid, err, fdone;
  logic [1:0][31:0] addr, wdata, rdata;
  logic [1:0][3:0]  be;

  assign req[0]   = d_req_i;
  assign addr[0]  = d_addr_i;
  assign we[0]    = d_we_i;
  assign be[0]    = d_be_i;
  assign wdata[0] = d_wdata_i;
  assign d_gnt_o    = gnt[0];
  assign d_rvalid_o = rvalid[0];
  assign d_rdata_o  = rdata[0];
  assign d_err_o    = err[0];

  assign req[1]   = i_req_i;
  assign addr[1]  = i_addr_i;
  assign we[1]    = 1'b0;
  assign be[1]    = 4'hF;
  assign wdata[1] = '0;
  assign i_gnt_o    = gnt[1];
  assign i_rvalid_o = rvalid[1];
  assign i_rdata_o  = rdata[1];
  assign i_err_o    = err[1];

  assign flush_done_o = fdone[0] & fdone[1];

  for (genvar k = 0; k < 2; k++) begin : g_l1
    l1_dcache #(
      .WAYS            (WAYS),
      .SETS            (SETS),
      .WRITE_BACK      (WRITE_BACK && k == 0),
      .CACHEABLE_LIMIT (CACHEABLE_LIMIT)
    ) u_l1 (
      .clk_i          (l1_clk),
      .rst_ni         (rst_ni),
      .core_en_i      (core_en_i),
      .core_req_i     (req[k]),
      .core_addr_i    (addr[k]),
      .core_we_i      (we[k]),
      .core_be_i      (be[k]),
      .core_wdata_i   (wdata[k]),
      .core_gnt_o     (gnt[k]),
      .core_rvalid_o  (rvalid[k]),
      .core_rdata_o   (rdata[k]),
      .core_err_o     (err[k]),
      .bus_req_o      (bus_req_o[k]),
      .bus_cmd_o      (bus_cmd_o[k]),
      .bus_addr_o     (bus_addr_o[k]),
      .bus_wdata_o    (bus_wdata_o[k]),
      .bus_be_o       (bus_be_o[k]),
      .bus_done_i     (bus_done_i[k]),
      .bus_rdata_i    (bus_rdata_i),
      .bus_err_i      (bus_err_i),
      .snoop_valid_i  (snoop_valid_i[k]),
      .snoop_type_i   (snoop_type_i),
      .snoop_addr_i   (snoop_addr_i),
      .snoop_hit_o    (snoop_hit_o[k]),
      .snoop_dirty_o  (snoop_dirty_o[k]),
      .snoop_data_o   (snoop_data_o[k]),
      .dbg_addr_i     (dbg_addr_i),
      .dbg_state_o    (dbg_state_o[k]),
      .dbg_data_o     (dbg_data_o[k]),
      .perf_valid_o   (perf_valid_o[k]),
      .perf_addr_o    (perf_addr_o[k]),
      .perf_we_o      (perf_we_o[k]),
      .perf_be_o      (perf_be_o[k]),
      .perf_wdata_o   (perf_wdata_o[k]),
      .perf_rdata_o   (perf_rdata_o[k]),
      .perf_err_o     (perf_err_o[k]),
      .flush_i        (flush_i),
      .flush_done_o   (fdone[k]),
      .events_o       (events_o[k])
    );
  end

endmodule
