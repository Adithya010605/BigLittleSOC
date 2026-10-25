// ============================================================================
// p_tile.sv
//
// One P-core with its private caches, under one roof: the unit that is laid
// out once as a hard block and placed twice in the SoC.
//
//   p_core_top   RV32IM, 5-stage, branch prediction        (rtl/p_core)
//   l1_pair      16 KB 2-way L1 data cache (write-back MSI)
//                + 16 KB 2-way L1 instruction cache          (rtl/cache)
//   clock_gate   the core's clock; the caches have their own (in l1_pair)
//
// Everything outside the tile reaches it through its ports: the PMU (clock
// enables, flush, hart number, halt and debug port, interrupts), the snooping
// bus (one bus and snoop port per cache: [0] data, [1] instruction), and, in
// simulation only, the testbench's probes and RVFI trace. In synthesis those
// are not ports at all: the tile is laid out on its own as a hard block, so a
// port it has becomes a pin of every copy, even when nothing outside uses it.
//
// e_tile.sv is the same tile around an E-core.
// ============================================================================

module p_tile
  import cache_pkg::*;
#(
  parameter bit          RVFI            = 1'b0,
  parameter int unsigned WAYS            = 2,
  parameter int unsigned SETS            = 256,
  parameter logic [31:0] CACHEABLE_LIMIT = 32'h0003_0000
) (
  input  logic                           clk_i,
  input  logic                           rst_ni,

  // ---- Power (PMU) ----
  input  logic                           core_clk_en_i,  // core's clock edge ends this cycle
  input  logic                           l1_clk_en_i,
  input  logic                           flush_i,
  output logic                           flush_done_o,

  // ---- Hart number, halt and debug port, interrupts (PMU) ----
  input  logic [31:0]                    hart_id_i,
  input  logic                           halt_req_i,
  output logic                           halted_o,
  output logic                           retire_o,
  input  logic [4:0]                     dbg_rf_addr_i,
  input  logic                           dbg_rf_we_i,
  output logic [31:0]                    dbg_rf_rdata_o,
  input  logic [11:0]                    dbg_csr_addr_i,
  input  logic                           dbg_csr_we_i,
  output logic [31:0]                    dbg_csr_rdata_o,
  output logic [31:0]                    dbg_pc_o,
  input  logic                           dbg_pc_we_i,
  input  logic [31:0]                    dbg_wdata_i,
  input  logic                           irq_timer_i,
  input  logic                           irq_software_i,
  input  logic                           irq_external_i,

  // ---- Snooping bus: [0] data cache, [1] instruction cache ----
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
  output logic     [1:0][NUM_EV-1:0]     events_o
`ifndef SYNTHESIS
  ,
  // ---- Testbench: cache probe, performed-access monitor, RVFI ----
  input  logic     [31:0]                l1_dbg_addr_i,
  output msi_e     [1:0]                 l1_dbg_state_o,
  output logic     [1:0][LINE_BITS-1:0]  l1_dbg_data_o,
  output logic     [1:0]                 perf_valid_o,
  output logic     [1:0][31:0]           perf_addr_o,
  output logic     [1:0]                 perf_we_o,
  output logic     [1:0][3:0]            perf_be_o,
  output logic     [1:0][31:0]           perf_wdata_o,
  output logic     [1:0][31:0]           perf_rdata_o,
  output logic     [1:0]                 perf_err_o,
  output logic                           rvfi_valid_o,
  output logic [63:0]                    rvfi_order_o,
  output logic [31:0]                    rvfi_insn_o,
  output logic                           rvfi_trap_o,
  output logic                           rvfi_halt_o,
  output logic                           rvfi_intr_o,
  output logic [1:0]                     rvfi_mode_o,
  output logic [1:0]                     rvfi_ixl_o,
  output logic [4:0]                     rvfi_rs1_addr_o,
  output logic [4:0]                     rvfi_rs2_addr_o,
  output logic [31:0]                    rvfi_rs1_rdata_o,
  output logic [31:0]                    rvfi_rs2_rdata_o,
  output logic [4:0]                     rvfi_rd_addr_o,
  output logic [31:0]                    rvfi_rd_wdata_o,
  output logic [31:0]                    rvfi_pc_rdata_o,
  output logic [31:0]                    rvfi_pc_wdata_o,
  output logic [31:0]                    rvfi_mem_addr_o,
  output logic [3:0]                     rvfi_mem_rmask_o,
  output logic [3:0]                     rvfi_mem_wmask_o,
  output logic [31:0]                    rvfi_mem_rdata_o,
  output logic [31:0]                    rvfi_mem_wdata_o
`endif
);

`ifdef SYNTHESIS
  // The testbench ports, as local signals: the core and caches still drive
  // them (constants in synthesis: RVFI is off and l1_dcache ties its probe
  // and monitor), and synthesis removes them, as nothing reads them.
  logic     [31:0]                l1_dbg_addr_i;
  msi_e     [1:0]                 l1_dbg_state_o;
  logic     [1:0][LINE_BITS-1:0]  l1_dbg_data_o;
  logic     [1:0]                 perf_valid_o;
  logic     [1:0][31:0]           perf_addr_o;
  logic     [1:0]                 perf_we_o;
  logic     [1:0][3:0]            perf_be_o;
  logic     [1:0][31:0]           perf_wdata_o;
  logic     [1:0][31:0]           perf_rdata_o;
  logic     [1:0]                 perf_err_o;
  logic                           rvfi_valid_o;
  logic [63:0]                    rvfi_order_o;
  logic [31:0]                    rvfi_insn_o;
  logic                           rvfi_trap_o;
  logic                           rvfi_halt_o;
  logic                           rvfi_intr_o;
  logic [1:0]                     rvfi_mode_o;
  logic [1:0]                     rvfi_ixl_o;
  logic [4:0]                     rvfi_rs1_addr_o;
  logic [4:0]                     rvfi_rs2_addr_o;
  logic [31:0]                    rvfi_rs1_rdata_o;
  logic [31:0]                    rvfi_rs2_rdata_o;
  logic [4:0]                     rvfi_rd_addr_o;
  logic [31:0]                    rvfi_rd_wdata_o;
  logic [31:0]                    rvfi_pc_rdata_o;
  logic [31:0]                    rvfi_pc_wdata_o;
  logic [31:0]                    rvfi_mem_addr_o;
  logic [3:0]                     rvfi_mem_rmask_o;
  logic [3:0]                     rvfi_mem_wmask_o;
  logic [31:0]                    rvfi_mem_rdata_o;
  logic [31:0]                    rvfi_mem_wdata_o;
  assign l1_dbg_addr_i = '0;
  logic unused_tb;
  assign unused_tb = ^{l1_dbg_state_o, l1_dbg_data_o, perf_valid_o, perf_addr_o,
                       perf_we_o, perf_be_o, perf_wdata_o, perf_rdata_o, perf_err_o,
                       rvfi_valid_o, rvfi_order_o, rvfi_insn_o, rvfi_trap_o,
                       rvfi_halt_o, rvfi_intr_o, rvfi_mode_o, rvfi_ixl_o,
                       rvfi_rs1_addr_o, rvfi_rs2_addr_o, rvfi_rs1_rdata_o,
                       rvfi_rs2_rdata_o, rvfi_rd_addr_o, rvfi_rd_wdata_o,
                       rvfi_pc_rdata_o, rvfi_pc_wdata_o, rvfi_mem_addr_o,
                       rvfi_mem_rmask_o, rvfi_mem_wmask_o, rvfi_mem_rdata_o,
                       rvfi_mem_wdata_o};
`endif

  // The core's clock: stopped by the PMU while the core sleeps or is parked,
  // and divided by it for DVFS.
  logic core_clk;
  clock_gate u_cg (.clk_i(clk_i), .en_i(core_clk_en_i), .clk_o(core_clk));

  // Core <-> its L1s
  logic        i_req, i_gnt, i_rvalid, i_err;
  logic [31:0] i_addr, i_rdata;
  logic        d_req, d_we, d_gnt, d_rvalid, d_err;
  logic [31:0] d_addr, d_wdata, d_rdata;
  logic [3:0]  d_be;

  p_core_top #(
    .RVFI (RVFI)
  ) u_core (
    .clk_i            (core_clk),
    .rst_ni           (rst_ni),
    .instr_req_o      (i_req),
    .instr_addr_o     (i_addr),
    .instr_gnt_i      (i_gnt),
    .instr_rvalid_i   (i_rvalid),
    .instr_rdata_i    (i_rdata),
    .instr_err_i      (i_err),
    .data_req_o       (d_req),
    .data_addr_o      (d_addr),
    .data_we_o        (d_we),
    .data_be_o        (d_be),
    .data_wdata_o     (d_wdata),
    .data_gnt_i       (d_gnt),
    .data_rvalid_i    (d_rvalid),
    .data_rdata_i     (d_rdata),
    .data_err_i       (d_err),
    .irq_timer_i      (irq_timer_i),
    .irq_software_i   (irq_software_i),
    .irq_external_i   (irq_external_i),
    .hart_id_i        (hart_id_i),
    .halt_req_i       (halt_req_i),
    .halted_o         (halted_o),
    .retire_o         (retire_o),
    .dbg_rf_addr_i    (dbg_rf_addr_i),
    .dbg_rf_we_i      (dbg_rf_we_i),
    .dbg_rf_rdata_o   (dbg_rf_rdata_o),
    .dbg_csr_addr_i   (dbg_csr_addr_i),
    .dbg_csr_we_i     (dbg_csr_we_i),
    .dbg_csr_rdata_o  (dbg_csr_rdata_o),
    .dbg_pc_o         (dbg_pc_o),
    .dbg_pc_we_i      (dbg_pc_we_i),
    .dbg_wdata_i      (dbg_wdata_i),
    .rvfi_valid_o     (rvfi_valid_o),
    .rvfi_order_o     (rvfi_order_o),
    .rvfi_insn_o      (rvfi_insn_o),
    .rvfi_trap_o      (rvfi_trap_o),
    .rvfi_halt_o      (rvfi_halt_o),
    .rvfi_intr_o      (rvfi_intr_o),
    .rvfi_mode_o      (rvfi_mode_o),
    .rvfi_ixl_o       (rvfi_ixl_o),
    .rvfi_rs1_addr_o  (rvfi_rs1_addr_o),
    .rvfi_rs2_addr_o  (rvfi_rs2_addr_o),
    .rvfi_rs1_rdata_o (rvfi_rs1_rdata_o),
    .rvfi_rs2_rdata_o (rvfi_rs2_rdata_o),
    .rvfi_rd_addr_o   (rvfi_rd_addr_o),
    .rvfi_rd_wdata_o  (rvfi_rd_wdata_o),
    .rvfi_pc_rdata_o  (rvfi_pc_rdata_o),
    .rvfi_pc_wdata_o  (rvfi_pc_wdata_o),
    .rvfi_mem_addr_o  (rvfi_mem_addr_o),
    .rvfi_mem_rmask_o (rvfi_mem_rmask_o),
    .rvfi_mem_wmask_o (rvfi_mem_wmask_o),
    .rvfi_mem_rdata_o (rvfi_mem_rdata_o),
    .rvfi_mem_wdata_o (rvfi_mem_wdata_o)
  );

  l1_pair #(
    .WAYS            (WAYS),
    .SETS            (SETS),
    .WRITE_BACK      (1'b1),
    .CACHEABLE_LIMIT (CACHEABLE_LIMIT)
  ) u_l1 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .core_en_i     (core_clk_en_i),
    .l1_clk_en_i   (l1_clk_en_i),
    .flush_i       (flush_i),
    .flush_done_o  (flush_done_o),
    .d_req_i       (d_req),
    .d_addr_i      (d_addr),
    .d_we_i        (d_we),
    .d_be_i        (d_be),
    .d_wdata_i     (d_wdata),
    .d_gnt_o       (d_gnt),
    .d_rvalid_o    (d_rvalid),
    .d_rdata_o     (d_rdata),
    .d_err_o       (d_err),
    .i_req_i       (i_req),
    .i_addr_i      (i_addr),
    .i_gnt_o       (i_gnt),
    .i_rvalid_o    (i_rvalid),
    .i_rdata_o     (i_rdata),
    .i_err_o       (i_err),
    .bus_req_o     (bus_req_o),
    .bus_cmd_o     (bus_cmd_o),
    .bus_addr_o    (bus_addr_o),
    .bus_wdata_o   (bus_wdata_o),
    .bus_be_o      (bus_be_o),
    .bus_done_i    (bus_done_i),
    .bus_rdata_i   (bus_rdata_i),
    .bus_err_i     (bus_err_i),
    .snoop_valid_i (snoop_valid_i),
    .snoop_type_i  (snoop_type_i),
    .snoop_addr_i  (snoop_addr_i),
    .snoop_hit_o   (snoop_hit_o),
    .snoop_dirty_o (snoop_dirty_o),
    .snoop_data_o  (snoop_data_o),
    .dbg_addr_i    (l1_dbg_addr_i),
    .dbg_state_o   (l1_dbg_state_o),
    .dbg_data_o    (l1_dbg_data_o),
    .perf_valid_o  (perf_valid_o),
    .perf_addr_o   (perf_addr_o),
    .perf_we_o     (perf_we_o),
    .perf_be_o     (perf_be_o),
    .perf_wdata_o  (perf_wdata_o),
    .perf_rdata_o  (perf_rdata_o),
    .perf_err_o    (perf_err_o),
    .events_o      (events_o)
  );

endmodule
