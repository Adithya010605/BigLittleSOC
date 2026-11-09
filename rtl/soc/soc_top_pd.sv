// ============================================================================
// soc_top_pd.sv
//
// The SoC as a chip, for physical design: the 2P+2E soc_top with only its real
// pins -- clock, reset, the UART and the main-memory port. Everything else
// soc_top brings out is for the testbench (the loader and traffic masters, the
// SRAM latency knob, the coherence probes, monitors and RVFI trace); here it
// is tied off or left unconnected, and synthesis removes whatever drove it.
//
// Main memory is off chip (EXT_MEM), as on any real SoC: the chip has the
// cores, their L1s, the L2 and the peripherals, and reaches its memory through
// the xmem_* pins, the interconnect's line-wide port for slave 0 (32-bit
// address, 256-bit data each way, a byte strobe per byte). A production chip
// would put a DRAM controller and PHY there instead.
//
// Reset is asserted asynchronously and released synchronously: rst_ni goes
// through a two-flop synchronizer, and the SoC gets its output. The release
// then starts at a clock edge, with the whole cycle to reach the ~10k
// asynchronously reset flops, instead of the 60% the pin's input delay
// leaves (chip run 2 missed by 2 ps on exactly that path, rst_ni -> an L2
// valid bit's reset pin).
// ============================================================================

// The testbench-only outputs are left unconnected on purpose.
/* verilator lint_off PINCONNECTEMPTY */
module soc_top_pd (
  input  logic       clk_i,
  input  logic       rst_ni,
  output logic       uart_tx_valid_o,
  output logic [7:0] uart_tx_byte_o,

  // ---- Off-chip main memory ----
  output logic         xmem_req_valid_o,
  input  logic         xmem_req_ready_i,
  output logic [31:0]  xmem_req_addr_o,
  output logic         xmem_req_write_o,
  output logic [255:0] xmem_req_wdata_o,
  output logic [31:0]  xmem_req_wstrb_o,
  input  logic         xmem_rsp_valid_i,
  input  logic [255:0] xmem_rsp_rdata_i,
  input  logic         xmem_rsp_err_i
);

  logic rst_meta_q, rst_sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rst_meta_q <= 1'b0;
      rst_sync_q <= 1'b0;
    end else begin
      rst_meta_q <= 1'b1;
      rst_sync_q <= rst_meta_q;
    end
  end

  soc_top #(
    .NUM_P     (2),
    .NUM_E     (2),
    .RVFI      (1'b0),
    .EXT_MEM   (1'b1)
  ) u_soc (
    .clk_i           (clk_i),
    .rst_ni          (rst_sync_q),
    .cpu_rst_ni      (1'b1),
    .tbm_req_valid_i ('0),
    .tbm_req_ready_o (),
    .tbm_req_addr_i  ('0),
    .tbm_req_write_i ('0),
    .tbm_req_wdata_i ('0),
    .tbm_req_wstrb_i ('0),
    .tbm_rsp_valid_o (),
    .tbm_rsp_ready_i ('1),
    .tbm_rsp_rdata_o (),
    .tbm_rsp_err_o   (),
    .xmem_req_valid_o(xmem_req_valid_o),
    .xmem_req_ready_i(xmem_req_ready_i),
    .xmem_req_addr_o (xmem_req_addr_o),
    .xmem_req_write_o(xmem_req_write_o),
    .xmem_req_wdata_o(xmem_req_wdata_o),
    .xmem_req_wstrb_o(xmem_req_wstrb_o),
    .xmem_rsp_valid_i(xmem_rsp_valid_i),
    .xmem_rsp_rdata_i(xmem_rsp_rdata_i),
    .xmem_rsp_err_i  (xmem_rsp_err_i),
    .mem_stall_i     (1'b0),
    .uart_tx_valid_o (uart_tx_valid_o),
    .uart_tx_byte_o  (uart_tx_byte_o),
    .dmon_valid_o    (),
    .dmon_addr_o     (),
    .dmon_we_o       (),
    .dmon_be_o       (),
    .dmon_wdata_o    (),
    .dmon_rdata_o    (),
    .dmon_err_o      (),
    .core_en_o       (),
    .hart_id_o       (),
    .mig_busy_o      (),
    .dbg_addr_i      ('0),
    .dbg_state_o     (),
    .dbg_data_o      (),
    .dbg_l2_present_o(),
    .dbg_l2_dirty_o  (),
    .dbg_l2_sharers_o(),
    .dbg_l2_data_o   (),
    .dbg_sram_line_o (),
    .events_o        (),
    .l2_events_o     (),
    .mon_done_o      (),
    .mon_busy_o      (),
    .mon_master_o    (),
    .mon_cmd_o       (),
    .mon_addr_o      (),
    .mon_shared_o    (),
    .mon_dirty_o     (),
    .mon_vvalid_o    (),
    .mon_vaddr_o     (),
    .fab_grant_o     (),
    .fab_wait_o      (),
    .rvfi_valid_o    (),
    .rvfi_order_o    (),
    .rvfi_insn_o     (),
    .rvfi_trap_o     (),
    .rvfi_halt_o     (),
    .rvfi_intr_o     (),
    .rvfi_mode_o     (),
    .rvfi_ixl_o      (),
    .rvfi_rs1_addr_o (),
    .rvfi_rs2_addr_o (),
    .rvfi_rs1_rdata_o(),
    .rvfi_rs2_rdata_o(),
    .rvfi_rd_addr_o  (),
    .rvfi_rd_wdata_o (),
    .rvfi_pc_rdata_o (),
    .rvfi_pc_wdata_o (),
    .rvfi_mem_addr_o (),
    .rvfi_mem_rmask_o(),
    .rvfi_mem_wmask_o(),
    .rvfi_mem_rdata_o(),
    .rvfi_mem_wdata_o()
  );

endmodule
/* verilator lint_on PINCONNECTEMPTY */
