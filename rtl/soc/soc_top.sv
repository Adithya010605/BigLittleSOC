// ============================================================================
// soc_top.sv
//
// The big.LITTLE cluster: NUM_P P-cores and NUM_E E-cores, each with private
// L1 instruction and data caches, kept coherent by MSI snooping on one bus,
// with a shared, inclusive 64 KB L2 behind it (rtl/coherence/snoop_bus.sv).
// Each core and its two L1s form a tile (rtl/soc/p_tile.sv, e_tile.sv): the
// block that is laid out once and placed once per core.
//
//   core 0 .. NUM_P-1    P-cores (RV32IM, 5-stage) + 16 KB 2-way L1D (WB) + L1I
//   core NUM_P .. N-1    E-cores (RV32I,  3-stage) +  8 KB direct L1D (WT) + L1I
//
// Software runs as N contexts (harts). A hart reads its number from mhartid,
// so one program image runs on all of them and each hart picks its own work.
// At reset core c runs hart c; the PMU (rtl/power/pmu.sv) can migrate a hart
// to another core, put it to sleep, slow a cluster's clock, and switch a
// cluster's power domain off. It drives each core's hart number, halt and
// debug ports, routes each hart's interrupts to the core running it, and
// gates each core's clock and its L1s' clock.
//
// ---------------------------------------------------------------------------
// WHAT IS OUTSIDE
// ---------------------------------------------------------------------------
// Behind the L2 is the system interconnect (rtl/interconnect/qos_xbar.sv), a
// QoS-arbitrated crossbar with four masters and four slaves:
//
//   masters                         slaves
//   0  the CPU cluster (the L2)     0  SRAM, 192 KB        0x0000_0000
//   1  debug / loader   (testbench) 1  UART                0x1000_0000
//   2  traffic port A   (testbench) 2  interrupt control   0x1100_0000
//   3  traffic port B   (testbench) 3  system control      0x1200_0000
//                                      (QoS registers, performance counters)
//                                   4  PMU: power          0x4000_0000
//                                   5  PMU: migration      0x5000_0000
//
// Masters 1-3 are brought out: the testbench loads programs through the
// debug port while the CPUs are held in reset (cpu_rst_ni), and drives the
// traffic ports as stand-ins for the plan's DMA and accelerator masters
// (QoS defaults: CPU 2, debug 0, A 1, B 3, as in plan §3.1).
//
// Each core's data accesses are also brought out as the L1s perform them
// (dmon_*): they are what the coherence checker in the testbench watches.
// The RVFI trace of every core (valid only in cycles core_en_o is high: each
// core's clock is gated), the coherence system's debug probe and event
// counters are brought out for the same reason.
// ============================================================================

module soc_top
  import cache_pkg::*;
#(
  parameter int unsigned NUM_P = 2,
  parameter int unsigned NUM_E = 2,
  parameter bit          RVFI  = 1'b0,
  parameter int unsigned SRAM_SIZE = 32'h0003_0000,   // bytes
  localparam int unsigned N     = NUM_P + NUM_E,
  localparam int unsigned NL1   = 2 * N,
  localparam int unsigned MID_W = (NL1 > 1) ? $clog2(NL1) : 1
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,       // everything
  input  logic                         cpu_rst_ni,   // also holds cores + caches

  // ---- Testbench masters on the interconnect (1: debug, 2-3: traffic) ----
  input  logic [2:0]                   tbm_req_valid_i,
  output logic [2:0]                   tbm_req_ready_o,
  input  logic [2:0][31:0]             tbm_req_addr_i,
  input  logic [2:0]                   tbm_req_write_i,
  input  logic [2:0][LINE_BITS-1:0]    tbm_req_wdata_i,
  input  logic [2:0][LINE_BYTES-1:0]   tbm_req_wstrb_i,
  output logic [2:0]                   tbm_rsp_valid_o,
  input  logic [2:0]                   tbm_rsp_ready_i,
  output logic [2:0][LINE_BITS-1:0]    tbm_rsp_rdata_o,
  output logic [2:0]                   tbm_rsp_err_o,

  // ---- Peripherals ----
  input  logic                         mem_stall_i,  // SRAM latency injection
  output logic                         uart_tx_valid_o,
  output logic [7:0]                   uart_tx_byte_o,

  // ---- Data accesses, as performed by each core's L1 ----
  output logic [N-1:0]                 dmon_valid_o,
  output logic [N-1:0][31:0]           dmon_addr_o,
  output logic [N-1:0]                 dmon_we_o,
  output logic [N-1:0][3:0]            dmon_be_o,
  output logic [N-1:0][31:0]           dmon_wdata_o,
  output logic [N-1:0][31:0]           dmon_rdata_o,
  output logic [N-1:0]                 dmon_err_o,

  // ---- Power and migration state ----
  output logic [N-1:0]                 core_en_o,    // core's clock edge ends this cycle
  output logic [N-1:0][31:0]           hart_id_o,    // hart each core runs
  output logic                         mig_busy_o,

  // ---- Coherence debug probe, statistics, bus monitor ----
  input  logic [31:0]                  dbg_addr_i,
  output msi_e [NL1-1:0]               dbg_state_o,
  output logic [NL1-1:0][LINE_BITS-1:0] dbg_data_o,
  output logic                         dbg_l2_present_o,
  output logic                         dbg_l2_dirty_o,
  output logic [NL1-1:0]               dbg_l2_sharers_o,
  output logic [LINE_BITS-1:0]         dbg_l2_data_o,
  output logic [LINE_BITS-1:0]         dbg_sram_line_o,
  output logic [NL1-1:0][NUM_EV-1:0]   events_o,
  output logic [NUM_L2EV-1:0]          l2_events_o,
  output logic                         mon_done_o,
  output logic                         mon_busy_o,
  output logic [MID_W-1:0]             mon_master_o,
  output bus_cmd_e                     mon_cmd_o,
  output logic [31:0]                  mon_addr_o,
  output logic                         mon_shared_o,
  output logic                         mon_dirty_o,
  output logic                         mon_vvalid_o,
  output logic [31:0]                  mon_vaddr_o,
  output logic [3:0]                   fab_grant_o,
  output logic [3:0]                   fab_wait_o,

  // ---- RVFI, one per hart (active when RVFI == 1) ----
  output logic [N-1:0]                 rvfi_valid_o,
  output logic [N-1:0][63:0]           rvfi_order_o,
  output logic [N-1:0][31:0]           rvfi_insn_o,
  output logic [N-1:0]                 rvfi_trap_o,
  output logic [N-1:0]                 rvfi_halt_o,
  output logic [N-1:0]                 rvfi_intr_o,
  output logic [N-1:0][1:0]            rvfi_mode_o,
  output logic [N-1:0][1:0]            rvfi_ixl_o,
  output logic [N-1:0][4:0]            rvfi_rs1_addr_o,
  output logic [N-1:0][4:0]            rvfi_rs2_addr_o,
  output logic [N-1:0][31:0]           rvfi_rs1_rdata_o,
  output logic [N-1:0][31:0]           rvfi_rs2_rdata_o,
  output logic [N-1:0][4:0]            rvfi_rd_addr_o,
  output logic [N-1:0][31:0]           rvfi_rd_wdata_o,
  output logic [N-1:0][31:0]           rvfi_pc_rdata_o,
  output logic [N-1:0][31:0]           rvfi_pc_wdata_o,
  output logic [N-1:0][31:0]           rvfi_mem_addr_o,
  output logic [N-1:0][3:0]            rvfi_mem_rmask_o,
  output logic [N-1:0][3:0]            rvfi_mem_wmask_o,
  output logic [N-1:0][31:0]           rvfi_mem_rdata_o,
  output logic [N-1:0][31:0]           rvfi_mem_wdata_o
);

  localparam int unsigned NM = 4;
  localparam int unsigned NS = 6;

  logic cpu_rst_n;
  assign cpu_rst_n = rst_ni & cpu_rst_ni;

  // Interrupts per hart (from the controller) and per core (from the PMU)
  logic [N-1:0] hirq_timer, hirq_software, hirq_external;
  logic [N-1:0] irq_timer, irq_software, irq_external;

  // PMU <-> cores and caches
  logic [N-1:0]       core_clk_en, l1_clk_en, l1_flush, l1_flush_done;
  logic [N-1:0]       halt_req, halted, retire;
  logic [N-1:0][31:0] hart_id;
  logic [4:0]         dbg_rf_addr;
  logic [11:0]        dbg_csr_addr;
  logic [31:0]        dbg_wdata;
  logic [N-1:0]       dbg_rf_we, dbg_csr_we, dbg_pc_we;
  logic [N-1:0][31:0] dbg_rf_rdata, dbg_csr_rdata, dbg_pc;

  assign core_en_o = core_clk_en;
  assign hart_id_o = hart_id;

  // Performed-access monitors of every L1; the data caches' come out.
  logic [NL1-1:0]       pf_valid, pf_we, pf_err;
  logic [NL1-1:0][31:0] pf_addr, pf_wdata, pf_rdata;
  logic [NL1-1:0][3:0]  pf_be;
  for (genvar c = 0; c < int'(N); c++) begin : g_dmon
    assign dmon_valid_o[c] = pf_valid[c];
    assign dmon_addr_o[c]  = pf_addr[c];
    assign dmon_we_o[c]    = pf_we[c];
    assign dmon_be_o[c]    = pf_be[c];
    assign dmon_wdata_o[c] = pf_wdata[c];
    assign dmon_rdata_o[c] = pf_rdata[c];
    assign dmon_err_o[c]   = pf_err[c];
  end
  logic unused_ipf;
  assign unused_ipf = ^{pf_valid[NL1-1:N], pf_we[NL1-1:N], pf_err[NL1-1:N], pf_addr[NL1-1:N],
                        pf_wdata[NL1-1:N], pf_rdata[NL1-1:N], pf_be[NL1-1:N]};

  // ====================================================================
  // The tiles: each core with its L1 caches (rtl/soc/p_tile.sv, e_tile.sv)
  // ====================================================================
  // L1 <-> bus, every L1 in one array: the data caches first (L1 c), then the
  // instruction caches (L1 N+c), as the debug probe, the event counters and
  // the snoop filter number them.
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

  // Every port of a tile; both tiles have the same ones, which is the point.
  `define SOC_TILE_PORTS(c)                                                  \
      .clk_i            (clk_i),                                             \
      .rst_ni           (cpu_rst_n),                                         \
      .core_clk_en_i    (core_clk_en[c]),                                    \
      .l1_clk_en_i      (l1_clk_en[c]),                                      \
      .flush_i          (l1_flush[c]),                                       \
      .flush_done_o     (l1_flush_done[c]),                                  \
      .hart_id_i        (hart_id[c]),                                        \
      .halt_req_i       (halt_req[c]),                                       \
      .halted_o         (halted[c]),                                         \
      .retire_o         (retire[c]),                                         \
      .dbg_rf_addr_i    (dbg_rf_addr),                                       \
      .dbg_rf_we_i      (dbg_rf_we[c]),                                      \
      .dbg_rf_rdata_o   (dbg_rf_rdata[c]),                                   \
      .dbg_csr_addr_i   (dbg_csr_addr),                                      \
      .dbg_csr_we_i     (dbg_csr_we[c]),                                     \
      .dbg_csr_rdata_o  (dbg_csr_rdata[c]),                                  \
      .dbg_pc_o         (dbg_pc[c]),                                         \
      .dbg_pc_we_i      (dbg_pc_we[c]),                                      \
      .dbg_wdata_i      (dbg_wdata),                                         \
      .irq_timer_i      (irq_timer[c]),                                      \
      .irq_software_i   (irq_software[c]),                                   \
      .irq_external_i   (irq_external[c]),                                   \
      .bus_req_o        ({bus_req[N+(c)],     bus_req[c]}),                  \
      .bus_cmd_o        ({bus_cmd[N+(c)],     bus_cmd[c]}),                  \
      .bus_addr_o       ({bus_addr[N+(c)],    bus_addr[c]}),                 \
      .bus_wdata_o      ({bus_wdata[N+(c)],   bus_wdata[c]}),                \
      .bus_be_o         ({bus_be[N+(c)],      bus_be[c]}),                   \
      .bus_done_i       ({bus_done[N+(c)],    bus_done[c]}),                 \
      .bus_rdata_i      (bus_rdata),                                         \
      .bus_err_i        (bus_err),                                           \
      .snoop_valid_i    ({snoop_valid[N+(c)], snoop_valid[c]}),              \
      .snoop_type_i     (snoop_type),                                        \
      .snoop_addr_i     (snoop_addr),                                        \
      .snoop_hit_o      ({snoop_hit[N+(c)],   snoop_hit[c]}),                \
      .snoop_dirty_o    ({snoop_dirty[N+(c)], snoop_dirty[c]}),              \
      .snoop_data_o     ({snoop_data[N+(c)],  snoop_data[c]}),               \
      .events_o         ({events_o[N+(c)],    events_o[c]}),                 \
      .l1_dbg_addr_i    (dbg_addr_i),                                        \
      .l1_dbg_state_o   ({dbg_state_o[N+(c)], dbg_state_o[c]}),              \
      .l1_dbg_data_o    ({dbg_data_o[N+(c)],  dbg_data_o[c]}),               \
      .perf_valid_o     ({pf_valid[N+(c)],    pf_valid[c]}),                 \
      .perf_addr_o      ({pf_addr[N+(c)],     pf_addr[c]}),                  \
      .perf_we_o        ({pf_we[N+(c)],       pf_we[c]}),                    \
      .perf_be_o        ({pf_be[N+(c)],       pf_be[c]}),                    \
      .perf_wdata_o     ({pf_wdata[N+(c)],    pf_wdata[c]}),                 \
      .perf_rdata_o     ({pf_rdata[N+(c)],    pf_rdata[c]}),                 \
      .perf_err_o       ({pf_err[N+(c)],      pf_err[c]}),                   \
      .rvfi_valid_o     (rvfi_valid_o[c]),                                   \
      .rvfi_order_o     (rvfi_order_o[c]),                                   \
      .rvfi_insn_o      (rvfi_insn_o[c]),                                    \
      .rvfi_trap_o      (rvfi_trap_o[c]),                                    \
      .rvfi_halt_o      (rvfi_halt_o[c]),                                    \
      .rvfi_intr_o      (rvfi_intr_o[c]),                                    \
      .rvfi_mode_o      (rvfi_mode_o[c]),                                    \
      .rvfi_ixl_o       (rvfi_ixl_o[c]),                                     \
      .rvfi_rs1_addr_o  (rvfi_rs1_addr_o[c]),                                \
      .rvfi_rs2_addr_o  (rvfi_rs2_addr_o[c]),                                \
      .rvfi_rs1_rdata_o (rvfi_rs1_rdata_o[c]),                               \
      .rvfi_rs2_rdata_o (rvfi_rs2_rdata_o[c]),                               \
      .rvfi_rd_addr_o   (rvfi_rd_addr_o[c]),                                 \
      .rvfi_rd_wdata_o  (rvfi_rd_wdata_o[c]),                                \
      .rvfi_pc_rdata_o  (rvfi_pc_rdata_o[c]),                                \
      .rvfi_pc_wdata_o  (rvfi_pc_wdata_o[c]),                                \
      .rvfi_mem_addr_o  (rvfi_mem_addr_o[c]),                                \
      .rvfi_mem_rmask_o (rvfi_mem_rmask_o[c]),                               \
      .rvfi_mem_wmask_o (rvfi_mem_wmask_o[c]),                               \
      .rvfi_mem_rdata_o (rvfi_mem_rdata_o[c]),                               \
      .rvfi_mem_wdata_o (rvfi_mem_wdata_o[c])

  for (genvar i = 0; i < int'(NUM_P); i++) begin : g_p
    p_tile #(
      .RVFI (RVFI)
    ) u_tile (
      `SOC_TILE_PORTS(i)
    );
  end

  for (genvar j = 0; j < int'(NUM_E); j++) begin : g_e
    e_tile #(
      .RVFI (RVFI)
    ) u_tile (
      `SOC_TILE_PORTS(NUM_P + j)
    );
  end

  `undef SOC_TILE_PORTS

  // ====================================================================
  // The snooping bus and the shared L2 (rtl/coherence/snoop_bus.sv)
  // ====================================================================
  // The L2's memory port
  logic                  mem_req, mem_we, mem_uncached, mem_rvalid, mem_err;
  logic [31:0]           mem_addr;
  logic [LINE_BITS-1:0]  mem_wdata, mem_rdata;
  logic [LINE_BYTES-1:0] mem_be;

  snoop_bus #(
    .N (NL1)
  ) u_bus (
    .clk_i            (clk_i),
    .rst_ni           (cpu_rst_n),
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
    .mem_req_o        (mem_req),
    .mem_we_o         (mem_we),
    .mem_uncached_o   (mem_uncached),
    .mem_addr_o       (mem_addr),
    .mem_wdata_o      (mem_wdata),
    .mem_be_o         (mem_be),
    .mem_rvalid_i     (mem_rvalid),
    .mem_rdata_i      (mem_rdata),
    .mem_err_i        (mem_err),
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

  // ====================================================================
  // Interconnect
  // ====================================================================
  logic [NM-1:0]                 m_req_valid, m_req_ready, m_req_write, m_rsp_valid, m_rsp_ready, m_rsp_err;
  logic [NM-1:0][31:0]           m_req_addr;
  logic [NM-1:0][LINE_BITS-1:0]  m_req_wdata, m_rsp_rdata;
  logic [NM-1:0][LINE_BYTES-1:0] m_req_wstrb;

  logic [NS-1:0]                 s_req_valid, s_req_ready, s_req_write, s_rsp_valid, s_rsp_err;
  logic [NS-1:0][31:0]           s_req_addr;
  logic [NS-1:0][LINE_BITS-1:0]  s_req_wdata, s_rsp_rdata;
  logic [NS-1:0][LINE_BYTES-1:0] s_req_wstrb;

  logic [NM-1:0][1:0]            qos_prio;
  logic [7:0]                    starve_limit;

  // Master 0: the L2. Its memory port holds a request until the response;
  // the interconnect takes it once.
  logic m0_sent_q;
  always_ff @(posedge clk_i or negedge cpu_rst_n) begin
    if (!cpu_rst_n)                         m0_sent_q <= 1'b0;
    else if (m_rsp_valid[0])                m0_sent_q <= 1'b0;
    else if (m_req_valid[0] && m_req_ready[0]) m0_sent_q <= 1'b1;
  end
  assign m_req_valid[0] = mem_req && !m0_sent_q;
  assign m_req_addr[0]  = mem_addr;
  assign m_req_write[0] = mem_we;
  assign m_req_wdata[0] = mem_wdata;
  assign m_req_wstrb[0] = mem_we ? mem_be : '0;
  assign m_rsp_ready[0] = 1'b1;
  assign mem_rvalid     = m_rsp_valid[0];
  assign mem_rdata      = m_rsp_rdata[0];
  assign mem_err        = m_rsp_err[0];

  // Masters 1-3: the testbench.
  for (genvar k = 0; k < 3; k++) begin : g_tbm
    assign m_req_valid[k+1]    = tbm_req_valid_i[k];
    assign m_req_addr[k+1]     = tbm_req_addr_i[k];
    assign m_req_write[k+1]    = tbm_req_write_i[k];
    assign m_req_wdata[k+1]    = tbm_req_wdata_i[k];
    assign m_req_wstrb[k+1]    = tbm_req_wstrb_i[k];
    assign m_rsp_ready[k+1]    = tbm_rsp_ready_i[k];
    assign tbm_req_ready_o[k]  = m_req_ready[k+1];
    assign tbm_rsp_valid_o[k]  = m_rsp_valid[k+1];
    assign tbm_rsp_rdata_o[k]  = m_rsp_rdata[k+1];
    assign tbm_rsp_err_o[k]    = m_rsp_err[k+1];
  end

  qos_xbar #(
    .NM        (NM),
    .NS        (NS),
    .SLV_BASE  ({32'h5000_0000, 32'h4000_0000, 32'h1200_0000, 32'h1100_0000,
                 32'h1000_0000, 32'h0000_0000}),
    .SLV_LIMIT ({32'h5000_1000, 32'h4000_1000, 32'h1200_1000, 32'h1101_0000,
                 32'h1000_0100, 32'h0003_0000})
  ) u_xbar (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .qos_prio_i     (qos_prio),
    .starve_limit_i (starve_limit),
    .m_req_valid_i  (m_req_valid),
    .m_req_ready_o  (m_req_ready),
    .m_req_addr_i   (m_req_addr),
    .m_req_write_i  (m_req_write),
    .m_req_wdata_i  (m_req_wdata),
    .m_req_wstrb_i  (m_req_wstrb),
    .m_rsp_valid_o  (m_rsp_valid),
    .m_rsp_ready_i  (m_rsp_ready),
    .m_rsp_rdata_o  (m_rsp_rdata),
    .m_rsp_err_o    (m_rsp_err),
    .s_req_valid_o  (s_req_valid),
    .s_req_ready_i  (s_req_ready),
    .s_req_addr_o   (s_req_addr),
    .s_req_write_o  (s_req_write),
    .s_req_wdata_o  (s_req_wdata),
    .s_req_wstrb_o  (s_req_wstrb),
    .s_rsp_valid_i  (s_rsp_valid),
    .s_rsp_rdata_i  (s_rsp_rdata),
    .s_rsp_err_i    (s_rsp_err),
    .grant_o        (fab_grant_o),
    .wait_o         (fab_wait_o)
  );

  // ====================================================================
  // Slaves
  // ====================================================================
  `define SOC_SLAVE_PORTS(j)                  \
      .clk_i         (clk_i),                 \
      .rst_ni        (rst_ni),                \
      .req_valid_i   (s_req_valid[j]),        \
      .req_ready_o   (s_req_ready[j]),        \
      .req_addr_i    (s_req_addr[j]),         \
      .req_write_i   (s_req_write[j]),        \
      .req_wdata_i   (s_req_wdata[j]),        \
      .req_wstrb_i   (s_req_wstrb[j]),        \
      .rsp_valid_o   (s_rsp_valid[j]),        \
      .rsp_rdata_o   (s_rsp_rdata[j]),        \
      .rsp_err_o     (s_rsp_err[j])

  sram_ctrl #(.SIZE(SRAM_SIZE)) u_sram (
    `SOC_SLAVE_PORTS(0),
    .stall_i      (mem_stall_i),
    .dbg_addr_i   (dbg_addr_i),
    .dbg_line_o   (dbg_sram_line_o)
  );

  uart u_uart (
    `SOC_SLAVE_PORTS(1),
    .tx_valid_o   (uart_tx_valid_o),
    .tx_byte_o    (uart_tx_byte_o)
  );

  irq_ctrl #(.NH(N)) u_irq (
    `SOC_SLAVE_PORTS(2),
    .irq_timer_o    (hirq_timer),
    .irq_software_o (hirq_software),
    .irq_external_o (hirq_external)
  );

  sysctl #(
    .NUM_P        (NUM_P),
    .NUM_E        (NUM_E),
    .NM           (NM),
    // CPU 2, debug 0, traffic A 1, traffic B 3 (plan §3.1)
    .QOS_RESET    ({2'd3, 2'd1, 2'd0, 2'd2}),
    .STARVE_RESET (8'd16)
  ) u_sysctl (
    `SOC_SLAVE_PORTS(3),
    .qos_prio_o     (qos_prio),
    .starve_limit_o (starve_limit),
    .l1_events_i    (events_o),
    .l2_events_i    (l2_events_o),
    .fab_grant_i    (fab_grant_o),
    .fab_wait_i     (fab_wait_o)
  );

  `undef SOC_SLAVE_PORTS

  // ====================================================================
  // Power management and task migration: slaves 4 (power) and 5
  // (migration). Reset with the CPUs, like everything they control.
  // ====================================================================
  pmu #(
    .NUM_P (NUM_P),
    .NUM_E (NUM_E)
  ) u_pmu (
    .clk_i              (clk_i),
    .rst_ni             (cpu_rst_n),
    .p_req_valid_i      (s_req_valid[4]),
    .p_req_ready_o      (s_req_ready[4]),
    .p_req_addr_i       (s_req_addr[4]),
    .p_req_write_i      (s_req_write[4]),
    .p_req_wdata_i      (s_req_wdata[4]),
    .p_req_wstrb_i      (s_req_wstrb[4]),
    .p_rsp_valid_o      (s_rsp_valid[4]),
    .p_rsp_rdata_o      (s_rsp_rdata[4]),
    .p_rsp_err_o        (s_rsp_err[4]),
    .m_req_valid_i      (s_req_valid[5]),
    .m_req_ready_o      (s_req_ready[5]),
    .m_req_addr_i       (s_req_addr[5]),
    .m_req_write_i      (s_req_write[5]),
    .m_req_wdata_i      (s_req_wdata[5]),
    .m_req_wstrb_i      (s_req_wstrb[5]),
    .m_rsp_valid_o      (s_rsp_valid[5]),
    .m_rsp_rdata_o      (s_rsp_rdata[5]),
    .m_rsp_err_o        (s_rsp_err[5]),
    .halt_req_o         (halt_req),
    .halted_i           (halted),
    .retire_i           (retire),
    .hart_id_o          (hart_id),
    .dbg_rf_addr_o      (dbg_rf_addr),
    .dbg_csr_addr_o     (dbg_csr_addr),
    .dbg_wdata_o        (dbg_wdata),
    .dbg_rf_we_o        (dbg_rf_we),
    .dbg_csr_we_o       (dbg_csr_we),
    .dbg_pc_we_o        (dbg_pc_we),
    .dbg_rf_rdata_i     (dbg_rf_rdata),
    .dbg_csr_rdata_i    (dbg_csr_rdata),
    .dbg_pc_i           (dbg_pc),
    .core_clk_en_o      (core_clk_en),
    .l1_clk_en_o        (l1_clk_en),
    .l1_flush_o         (l1_flush),
    .l1_flush_done_i    (l1_flush_done),
    .ctx_irq_timer_i    (hirq_timer),
    .ctx_irq_software_i (hirq_software),
    .ctx_irq_external_i (hirq_external),
    .irq_timer_o        (irq_timer),
    .irq_software_o     (irq_software),
    .irq_external_o     (irq_external),
    .mig_busy_o         (mig_busy_o)
  );

  // The interconnect routes by address; whether an access was cacheable is
  // implied by where it goes.
  logic unused_mem_uncached;
  assign unused_mem_uncached = mem_uncached;

endmodule
