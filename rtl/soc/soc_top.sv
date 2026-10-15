// ============================================================================
// soc_top.sv
//
// The big.LITTLE cluster: NUM_P P-cores and NUM_E E-cores, each with private
// L1 instruction and data caches, kept coherent by MSI snooping on one bus,
// with a shared, inclusive 64 KB L2 behind it (rtl/coherence/coherent_mem.sv).
//
//   hart 0 .. NUM_P-1    P-cores (RV32IM, 5-stage) + 16 KB 2-way L1D (WB) + L1I
//   hart NUM_P .. N-1    E-cores (RV32I,  3-stage) +  8 KB direct L1D (WT) + L1I
//
// Every core reads its hart number from mhartid, so one program image runs on
// all of them and each hart picks its own work.
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
//
// Masters 1-3 are brought out: the testbench loads programs through the
// debug port while the CPUs are held in reset (cpu_rst_ni), and drives the
// traffic ports as stand-ins for the plan's DMA and accelerator masters
// (QoS defaults: CPU 2, debug 0, A 1, B 3, as in plan §3.1).
//
// The core-side data ports are also brought out as a read-only monitor
// (dmon_*): they are what the coherence checker in the testbench watches.
// The RVFI trace of every core and the coherence system's debug probe and
// event counters are brought out for the same reason.
// ============================================================================

module soc_top
  import cache_pkg::*;
#(
  parameter int unsigned NUM_P = 2,
  parameter int unsigned NUM_E = 2,
  parameter bit          RVFI  = 1'b0,
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

  // ---- Core data port monitor (read-only copies) ----
  output logic [N-1:0]                 dmon_req_o,
  output logic [N-1:0][31:0]           dmon_addr_o,
  output logic [N-1:0]                 dmon_we_o,
  output logic [N-1:0][3:0]            dmon_be_o,
  output logic [N-1:0][31:0]           dmon_wdata_o,
  output logic [N-1:0]                 dmon_gnt_o,
  output logic [N-1:0]                 dmon_rvalid_o,
  output logic [N-1:0][31:0]           dmon_rdata_o,
  output logic [N-1:0]                 dmon_err_o,

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
  localparam int unsigned NS = 4;

  logic cpu_rst_n;
  assign cpu_rst_n = rst_ni & cpu_rst_ni;

  logic [N-1:0] irq_timer, irq_software, irq_external;

  // Core <-> L1 instruction ports
  logic [N-1:0]       i_req, i_gnt, i_rvalid, i_err;
  logic [N-1:0][31:0] i_addr, i_rdata;

  // Core <-> L1 data ports
  logic [N-1:0]       d_req, d_we, d_gnt, d_rvalid, d_err;
  logic [N-1:0][31:0] d_addr, d_wdata, d_rdata;
  logic [N-1:0][3:0]  d_be;

  assign dmon_req_o    = d_req;
  assign dmon_addr_o   = d_addr;
  assign dmon_we_o     = d_we;
  assign dmon_be_o     = d_be;
  assign dmon_wdata_o  = d_wdata;
  assign dmon_gnt_o    = d_gnt;
  assign dmon_rvalid_o = d_rvalid;
  assign dmon_rdata_o  = d_rdata;
  assign dmon_err_o    = d_err;

  // Every port of a core except its identity; both core types have the same
  // interface, which is the point.
  `define SOC_CORE_PORTS(i)                                        \
      .clk_i            (clk_i),                                   \
      .rst_ni           (cpu_rst_n),                               \
      .instr_req_o      (i_req[i]),                                \
      .instr_addr_o     (i_addr[i]),                               \
      .instr_gnt_i      (i_gnt[i]),                                \
      .instr_rvalid_i   (i_rvalid[i]),                             \
      .instr_rdata_i    (i_rdata[i]),                              \
      .instr_err_i      (i_err[i]),                                \
      .data_req_o       (d_req[i]),                                \
      .data_addr_o      (d_addr[i]),                               \
      .data_we_o        (d_we[i]),                                 \
      .data_be_o        (d_be[i]),                                 \
      .data_wdata_o     (d_wdata[i]),                              \
      .data_gnt_i       (d_gnt[i]),                                \
      .data_rvalid_i    (d_rvalid[i]),                             \
      .data_rdata_i     (d_rdata[i]),                              \
      .data_err_i       (d_err[i]),                                \
      .irq_timer_i      (irq_timer[i]),                            \
      .irq_software_i   (irq_software[i]),                         \
      .irq_external_i   (irq_external[i]),                         \
      .rvfi_valid_o     (rvfi_valid_o[i]),                         \
      .rvfi_order_o     (rvfi_order_o[i]),                         \
      .rvfi_insn_o      (rvfi_insn_o[i]),                          \
      .rvfi_trap_o      (rvfi_trap_o[i]),                          \
      .rvfi_halt_o      (rvfi_halt_o[i]),                          \
      .rvfi_intr_o      (rvfi_intr_o[i]),                          \
      .rvfi_mode_o      (rvfi_mode_o[i]),                          \
      .rvfi_ixl_o       (rvfi_ixl_o[i]),                           \
      .rvfi_rs1_addr_o  (rvfi_rs1_addr_o[i]),                      \
      .rvfi_rs2_addr_o  (rvfi_rs2_addr_o[i]),                      \
      .rvfi_rs1_rdata_o (rvfi_rs1_rdata_o[i]),                     \
      .rvfi_rs2_rdata_o (rvfi_rs2_rdata_o[i]),                     \
      .rvfi_rd_addr_o   (rvfi_rd_addr_o[i]),                       \
      .rvfi_rd_wdata_o  (rvfi_rd_wdata_o[i]),                      \
      .rvfi_pc_rdata_o  (rvfi_pc_rdata_o[i]),                      \
      .rvfi_pc_wdata_o  (rvfi_pc_wdata_o[i]),                      \
      .rvfi_mem_addr_o  (rvfi_mem_addr_o[i]),                      \
      .rvfi_mem_rmask_o (rvfi_mem_rmask_o[i]),                     \
      .rvfi_mem_wmask_o (rvfi_mem_wmask_o[i]),                     \
      .rvfi_mem_rdata_o (rvfi_mem_rdata_o[i]),                     \
      .rvfi_mem_wdata_o (rvfi_mem_wdata_o[i])

  for (genvar i = 0; i < int'(NUM_P); i++) begin : g_p
    p_core_top #(
      .HART_ID (32'(i)),
      .RVFI    (RVFI)
    ) u_core (
      `SOC_CORE_PORTS(i)
    );
  end

  for (genvar j = 0; j < int'(NUM_E); j++) begin : g_e
    e_core_top #(
      .HART_ID (32'(NUM_P + j)),
      .RVFI    (RVFI)
    ) u_core (
      `SOC_CORE_PORTS(NUM_P + j)
    );
  end

  `undef SOC_CORE_PORTS

  // The L2's memory port
  logic                  mem_req, mem_we, mem_uncached, mem_rvalid, mem_err;
  logic [31:0]           mem_addr;
  logic [LINE_BITS-1:0]  mem_wdata, mem_rdata;
  logic [LINE_BYTES-1:0] mem_be;

  coherent_mem #(
    .NUM_WB (NUM_P),
    .NUM_WT (NUM_E)
  ) u_mem (
    .clk_i          (clk_i),
    .rst_ni         (cpu_rst_n),
    .core_req_i     (d_req),
    .core_addr_i    (d_addr),
    .core_we_i      (d_we),
    .core_be_i      (d_be),
    .core_wdata_i   (d_wdata),
    .core_gnt_o     (d_gnt),
    .core_rvalid_o  (d_rvalid),
    .core_rdata_o   (d_rdata),
    .core_err_o     (d_err),
    .instr_req_i    (i_req),
    .instr_addr_i   (i_addr),
    .instr_gnt_o    (i_gnt),
    .instr_rvalid_o (i_rvalid),
    .instr_rdata_o  (i_rdata),
    .instr_err_o    (i_err),
    .mem_req_o      (mem_req),
    .mem_we_o       (mem_we),
    .mem_uncached_o (mem_uncached),
    .mem_addr_o     (mem_addr),
    .mem_wdata_o    (mem_wdata),
    .mem_be_o       (mem_be),
    .mem_rvalid_i   (mem_rvalid),
    .mem_rdata_i    (mem_rdata),
    .mem_err_i      (mem_err),
    .dbg_addr_i     (dbg_addr_i),
    .dbg_state_o    (dbg_state_o),
    .dbg_data_o     (dbg_data_o),
    .dbg_l2_present_o (dbg_l2_present_o),
    .dbg_l2_dirty_o   (dbg_l2_dirty_o),
    .dbg_l2_sharers_o (dbg_l2_sharers_o),
    .dbg_l2_data_o    (dbg_l2_data_o),
    .events_o       (events_o),
    .l2_events_o    (l2_events_o),
    .mon_done_o     (mon_done_o),
    .mon_busy_o     (mon_busy_o),
    .mon_master_o   (mon_master_o),
    .mon_cmd_o      (mon_cmd_o),
    .mon_addr_o     (mon_addr_o),
    .mon_shared_o   (mon_shared_o),
    .mon_dirty_o    (mon_dirty_o),
    .mon_vvalid_o   (mon_vvalid_o),
    .mon_vaddr_o    (mon_vaddr_o)
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
    .SLV_BASE  ({32'h1200_0000, 32'h1100_0000, 32'h1000_0000, 32'h0000_0000}),
    .SLV_LIMIT ({32'h1200_1000, 32'h1101_0000, 32'h1000_0100, 32'h0003_0000})
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

  sram_ctrl #(.SIZE(32'h0003_0000)) u_sram (
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
    .irq_timer_o    (irq_timer),
    .irq_software_o (irq_software),
    .irq_external_o (irq_external)
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

  // The interconnect routes by address; whether an access was cacheable is
  // implied by where it goes.
  logic unused_mem_uncached;
  assign unused_mem_uncached = mem_uncached;

endmodule
