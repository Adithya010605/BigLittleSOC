// ============================================================================
// soc_top_pd.sv
//
// The SoC as a chip, for physical design: the 2P+2E soc_top with only its real
// pins -- clock, reset and the UART. Everything else soc_top brings out is for
// the testbench (the loader and traffic masters, the SRAM latency knob, the
// coherence probes, monitors and RVFI trace); here it is tied off or left
// unconnected, and synthesis removes whatever drove it.
//
// The system RAM is 64 KB here (192 KB in simulation): it is a stand-in for
// off-chip memory, and its size does not change the design around it.
// ============================================================================

// The testbench-only outputs are left unconnected on purpose.
/* verilator lint_off PINCONNECTEMPTY */
module soc_top_pd (
  input  logic       clk_i,
  input  logic       rst_ni,
  output logic       uart_tx_valid_o,
  output logic [7:0] uart_tx_byte_o
);

  soc_top #(
    .NUM_P     (2),
    .NUM_E     (2),
    .RVFI      (1'b0),
    .SRAM_SIZE (32'h0001_0000)
  ) u_soc (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
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
