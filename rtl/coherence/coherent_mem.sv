// ============================================================================
// coherent_mem.sv
//
// The coherent memory system without the cores: for every core a private L1
// data cache and a private L1 instruction cache, all on one snooping bus,
// with the shared, inclusive L2 behind it and one memory port out.
//
//   L1 index                 cache
//   0 .. NUM_WB-1            P-core data:        16 KB, 2-way, write-back MSI
//   NUM_WB .. NC-1           E-core data:         8 KB, direct, write-through
//   NC .. NC+NUM_WB-1        P-core instruction: 16 KB, 2-way, read-only
//   NC+NUM_WB .. 2*NC-1      E-core instruction:  8 KB, direct, read-only
//
// (NC = NUM_WB + NUM_WT, the number of cores.)
//
// An instruction cache is the write-through cache with its store path unused:
// lines are only ever S or I, it fills with BusRd and is invalidated by every
// write to the line, from any core. Instruction fetch is therefore coherent
// with every core's stores: a store takes ownership, which invalidates the
// line in every instruction cache, its own core's included, and the next fetch
// misses and gets the new code (from the writer's data cache, by a flush on
// the snooped BusRd). FENCE.I has nothing left to do but refetch.
//
// Each core port has the cores' valid/ready protocol, so soc_top.sv connects
// cores straight to it, and the coherence unit testbench drives it directly
// with synthetic traffic.
//
// Power (rtl/power/pmu.sv): core c's two L1s run on their own gated clock
// (l1_clk_en_i[c], off only while its power domain is off), take accesses
// only in the cycles core_en_i[c] says end with a core clock edge, and are
// flushed together by flush_i[c]. The performed-access monitors (perf_*)
// report each access in the cycle it takes effect.
//
// The debug probe looks up one address in every L1 and in the L2 at once. It
// has no effect on the design; the testbenches use it to check the protocol
// invariants (single writer, inclusion, the snoop filter, data values).
// ============================================================================

module coherent_mem
  import cache_pkg::*;
#(
  parameter int unsigned NUM_WB          = 2,
  parameter int unsigned NUM_WT          = 2,
  parameter int unsigned WB_WAYS         = 2,
  parameter int unsigned WB_SETS         = 256,    // 16 KB at 2 ways
  parameter int unsigned WT_SETS         = 256,    //  8 KB direct-mapped
  parameter int unsigned L2_SETS         = 512,    // 64 KB at 4 ways
  parameter logic [31:0] CACHEABLE_LIMIT = 32'h0003_0000,
  localparam int unsigned NC    = NUM_WB + NUM_WT,
  localparam int unsigned NL1   = 2 * NC,
  localparam int unsigned MID_W = (NL1 > 1) ? $clog2(NL1) : 1
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,

  // ---- Per core: clocks and flush ----
  input  logic [NC-1:0]                     core_en_i,
  input  logic [NC-1:0]                     l1_clk_en_i,
  input  logic [NC-1:0]                     flush_i,
  output logic [NC-1:0]                     flush_done_o,

  // ---- Core data ports ----
  input  logic [NC-1:0]                     core_req_i,
  input  logic [NC-1:0][31:0]               core_addr_i,
  input  logic [NC-1:0]                     core_we_i,
  input  logic [NC-1:0][3:0]                core_be_i,
  input  logic [NC-1:0][31:0]               core_wdata_i,
  output logic [NC-1:0]                     core_gnt_o,
  output logic [NC-1:0]                     core_rvalid_o,
  output logic [NC-1:0][31:0]               core_rdata_o,
  output logic [NC-1:0]                     core_err_o,

  // ---- Core instruction ports ----
  input  logic [NC-1:0]                     instr_req_i,
  input  logic [NC-1:0][31:0]               instr_addr_i,
  output logic [NC-1:0]                     instr_gnt_o,
  output logic [NC-1:0]                     instr_rvalid_o,
  output logic [NC-1:0][31:0]               instr_rdata_o,
  output logic [NC-1:0]                     instr_err_o,

  // ---- Memory side ----
  output logic                              mem_req_o,
  output logic                              mem_we_o,
  output logic                              mem_uncached_o,
  output logic [31:0]                       mem_addr_o,
  output logic [LINE_BITS-1:0]              mem_wdata_o,
  output logic [LINE_BYTES-1:0]             mem_be_o,
  input  logic                              mem_rvalid_i,
  input  logic [LINE_BITS-1:0]              mem_rdata_i,
  input  logic                              mem_err_i,

  // ---- Debug probe ----
  input  logic [31:0]                       dbg_addr_i,
  output msi_e [NL1-1:0]                    dbg_state_o,
  output logic [NL1-1:0][LINE_BITS-1:0]     dbg_data_o,
  output logic                              dbg_l2_present_o,
  output logic                              dbg_l2_dirty_o,
  output logic [NL1-1:0]                    dbg_l2_sharers_o,
  output logic [LINE_BITS-1:0]              dbg_l2_data_o,

  // ---- Accesses as performed, per L1 (numbered like the debug probe) ----
  output logic [NL1-1:0]                    perf_valid_o,
  output logic [NL1-1:0][31:0]              perf_addr_o,
  output logic [NL1-1:0]                    perf_we_o,
  output logic [NL1-1:0][3:0]               perf_be_o,
  output logic [NL1-1:0][31:0]              perf_wdata_o,
  output logic [NL1-1:0][31:0]              perf_rdata_o,
  output logic [NL1-1:0]                    perf_err_o,

  // ---- Statistics and bus monitor ----
  output logic [NL1-1:0][NUM_EV-1:0]        events_o,
  output logic [NUM_L2EV-1:0]               l2_events_o,
  output logic                              mon_done_o,
  output logic                              mon_busy_o,
  output logic [MID_W-1:0]                  mon_master_o,
  output bus_cmd_e                          mon_cmd_o,
  output logic [31:0]                       mon_addr_o,
  output logic                              mon_shared_o,
  output logic                              mon_dirty_o,
  output logic                              mon_vvalid_o,
  output logic [31:0]                       mon_vaddr_o
);

  // L1 <-> bus, every L1 in one array: data caches first, then instruction.
  logic     [NL1-1:0]                 bus_req;
  bus_cmd_e [NL1-1:0]                 bus_cmd;
  logic     [NL1-1:0][31:0]           bus_addr;
  logic     [NL1-1:0][LINE_BITS-1:0]  bus_wdata;
  logic     [NL1-1:0][LINE_BYTES-1:0] bus_be;
  logic     [NL1-1:0]                 bus_done;
  logic     [LINE_BITS-1:0]           bus_rdata;
  logic                               bus_err;

  logic     [NL1-1:0]                 snoop_valid;
  snoop_e                             snoop_type;
  logic     [31:0]                    snoop_addr;
  logic     [NL1-1:0]                 snoop_hit;
  logic     [NL1-1:0]                 snoop_dirty;
  logic     [NL1-1:0][LINE_BITS-1:0]  snoop_data;

  // Each core's two L1s (rtl/cache/l1_pair.sv): its data cache is L1 c, its
  // instruction cache L1 NC+c.
  for (genvar c = 0; c < int'(NC); c++) begin : g_l1
    localparam bit IS_P = (c < int'(NUM_WB));

    l1_pair #(
      .WAYS            (IS_P ? WB_WAYS : 1),
      .SETS            (IS_P ? WB_SETS : WT_SETS),
      .WRITE_BACK      (IS_P),
      .CACHEABLE_LIMIT (CACHEABLE_LIMIT)
    ) u_l1 (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .core_en_i     (core_en_i[c]),
      .l1_clk_en_i   (l1_clk_en_i[c]),
      .flush_i       (flush_i[c]),
      .flush_done_o  (flush_done_o[c]),
      .d_req_i       (core_req_i[c]),
      .d_addr_i      (core_addr_i[c]),
      .d_we_i        (core_we_i[c]),
      .d_be_i        (core_be_i[c]),
      .d_wdata_i     (core_wdata_i[c]),
      .d_gnt_o       (core_gnt_o[c]),
      .d_rvalid_o    (core_rvalid_o[c]),
      .d_rdata_o     (core_rdata_o[c]),
      .d_err_o       (core_err_o[c]),
      .i_req_i       (instr_req_i[c]),
      .i_addr_i      (instr_addr_i[c]),
      .i_gnt_o       (instr_gnt_o[c]),
      .i_rvalid_o    (instr_rvalid_o[c]),
      .i_rdata_o     (instr_rdata_o[c]),
      .i_err_o       (instr_err_o[c]),
      .bus_req_o     ({bus_req[NC+c],     bus_req[c]}),
      .bus_cmd_o     ({bus_cmd[NC+c],     bus_cmd[c]}),
      .bus_addr_o    ({bus_addr[NC+c],    bus_addr[c]}),
      .bus_wdata_o   ({bus_wdata[NC+c],   bus_wdata[c]}),
      .bus_be_o      ({bus_be[NC+c],      bus_be[c]}),
      .bus_done_i    ({bus_done[NC+c],    bus_done[c]}),
      .bus_rdata_i   (bus_rdata),
      .bus_err_i     (bus_err),
      .snoop_valid_i ({snoop_valid[NC+c], snoop_valid[c]}),
      .snoop_type_i  (snoop_type),
      .snoop_addr_i  (snoop_addr),
      .snoop_hit_o   ({snoop_hit[NC+c],   snoop_hit[c]}),
      .snoop_dirty_o ({snoop_dirty[NC+c], snoop_dirty[c]}),
      .snoop_data_o  ({snoop_data[NC+c],  snoop_data[c]}),
      .dbg_addr_i    (dbg_addr_i),
      .dbg_state_o   ({dbg_state_o[NC+c],  dbg_state_o[c]}),
      .dbg_data_o    ({dbg_data_o[NC+c],   dbg_data_o[c]}),
      .perf_valid_o  ({perf_valid_o[NC+c], perf_valid_o[c]}),
      .perf_addr_o   ({perf_addr_o[NC+c],  perf_addr_o[c]}),
      .perf_we_o     ({perf_we_o[NC+c],    perf_we_o[c]}),
      .perf_be_o     ({perf_be_o[NC+c],    perf_be_o[c]}),
      .perf_wdata_o  ({perf_wdata_o[NC+c], perf_wdata_o[c]}),
      .perf_rdata_o  ({perf_rdata_o[NC+c], perf_rdata_o[c]}),
      .perf_err_o    ({perf_err_o[NC+c],   perf_err_o[c]}),
      .events_o      ({events_o[NC+c],     events_o[c]})
    );
  end

  snoop_bus #(
    .N       (NL1),
    .L2_SETS (L2_SETS)
  ) u_bus (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .req_i            (bus_req),
    .cmd_i            (bus_cmd),
    .addr_i           (bus_addr),
    .wdata_i          (bus_wdata),
    .be_i             (bus_be),
    .done_o           (bus_done),
    .rdata_o          (bus_rdata),
    .err_o            (bus_err),
    .snoop_valid_o    (snoop_valid),
    .snoop_type_o     (snoop_type),
    .snoop_addr_o     (snoop_addr),
    .snoop_hit_i      (snoop_hit),
    .snoop_dirty_i    (snoop_dirty),
    .snoop_data_i     (snoop_data),
    .mem_req_o        (mem_req_o),
    .mem_we_o         (mem_we_o),
    .mem_uncached_o   (mem_uncached_o),
    .mem_addr_o       (mem_addr_o),
    .mem_wdata_o      (mem_wdata_o),
    .mem_be_o         (mem_be_o),
    .mem_rvalid_i     (mem_rvalid_i),
    .mem_rdata_i      (mem_rdata_i),
    .mem_err_i        (mem_err_i),
    .dbg_addr_i       (dbg_addr_i),
    .dbg_l2_present_o (dbg_l2_present_o),
    .dbg_l2_dirty_o   (dbg_l2_dirty_o),
    .dbg_l2_sharers_o (dbg_l2_sharers_o),
    .dbg_l2_data_o    (dbg_l2_data_o),
    .mon_done_o       (mon_done_o),
    .mon_busy_o       (mon_busy_o),
    .mon_master_o     (mon_master_o),
    .mon_cmd_o        (mon_cmd_o),
    .mon_addr_o       (mon_addr_o),
    .mon_shared_o     (mon_shared_o),
    .mon_dirty_o      (mon_dirty_o),
    .mon_vvalid_o     (mon_vvalid_o),
    .mon_vaddr_o      (mon_vaddr_o),
    .l2_events_o      (l2_events_o)
  );

endmodule
