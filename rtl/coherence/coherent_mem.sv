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

  // Every L1 as one array of ports: data caches first, then instruction.
  logic [NL1-1:0]       l1_req, l1_we, l1_gnt, l1_rvalid, l1_err;
  logic [NL1-1:0][31:0] l1_addr, l1_wdata, l1_rdata;
  logic [NL1-1:0][3:0]  l1_be;

  for (genvar i = 0; i < int'(NC); i++) begin : g_ports
    assign l1_req[i]        = core_req_i[i];
    assign l1_addr[i]       = core_addr_i[i];
    assign l1_we[i]         = core_we_i[i];
    assign l1_be[i]         = core_be_i[i];
    assign l1_wdata[i]      = core_wdata_i[i];
    assign core_gnt_o[i]    = l1_gnt[i];
    assign core_rvalid_o[i] = l1_rvalid[i];
    assign core_rdata_o[i]  = l1_rdata[i];
    assign core_err_o[i]    = l1_err[i];

    assign l1_req[NC+i]      = instr_req_i[i];
    assign l1_addr[NC+i]     = instr_addr_i[i];
    assign l1_we[NC+i]       = 1'b0;
    assign l1_be[NC+i]       = 4'hF;
    assign l1_wdata[NC+i]    = '0;
    assign instr_gnt_o[i]    = l1_gnt[NC+i];
    assign instr_rvalid_o[i] = l1_rvalid[NC+i];
    assign instr_rdata_o[i]  = l1_rdata[NC+i];
    assign instr_err_o[i]    = l1_err[NC+i];
  end

  // L1 <-> bus
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

  for (genvar i = 0; i < int'(NL1); i++) begin : g_l1
    localparam int unsigned CORE   = (i < int'(NC)) ? i : i - NC;
    localparam bit          IS_P   = (CORE < int'(NUM_WB));
    localparam bit          IS_D   = (i < int'(NC));
    localparam int unsigned WAYS   = IS_P ? WB_WAYS : 1;
    localparam int unsigned SETS   = IS_P ? WB_SETS : WT_SETS;

    l1_dcache #(
      .WAYS            (WAYS),
      .SETS            (SETS),
      .WRITE_BACK      (IS_P && IS_D),
      .CACHEABLE_LIMIT (CACHEABLE_LIMIT)
    ) u_l1 (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .core_req_i     (l1_req[i]),
      .core_addr_i    (l1_addr[i]),
      .core_we_i      (l1_we[i]),
      .core_be_i      (l1_be[i]),
      .core_wdata_i   (l1_wdata[i]),
      .core_gnt_o     (l1_gnt[i]),
      .core_rvalid_o  (l1_rvalid[i]),
      .core_rdata_o   (l1_rdata[i]),
      .core_err_o     (l1_err[i]),
      .bus_req_o      (bus_req[i]),
      .bus_cmd_o      (bus_cmd[i]),
      .bus_addr_o     (bus_addr[i]),
      .bus_wdata_o    (bus_wdata[i]),
      .bus_be_o       (bus_be[i]),
      .bus_done_i     (bus_done[i]),
      .bus_rdata_i    (bus_rdata),
      .bus_err_i      (bus_err),
      .snoop_valid_i  (snoop_valid[i]),
      .snoop_type_i   (snoop_type),
      .snoop_addr_i   (snoop_addr),
      .snoop_hit_o    (snoop_hit[i]),
      .snoop_dirty_o  (snoop_dirty[i]),
      .snoop_data_o   (snoop_data[i]),
      .dbg_addr_i     (dbg_addr_i),
      .dbg_state_o    (dbg_state_o[i]),
      .dbg_data_o     (dbg_data_o[i]),
      .events_o       (events_o[i])
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
