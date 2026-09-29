// ============================================================================
// p_core_if_stage.sv  —  IF: predicted instruction fetch
//
// Owns the fetch address, the instruction-port handshake and the IF/ID
// pipeline register. Structurally this is the E-core's fetch stage -- the same
// skid buffer, the same separation of the in-flight request address from the
// next-fetch address, the same wrong-path discard -- with one change: the
// address fetched next is PREDICTED instead of always being +4.
//
// ---------------------------------------------------------------------------
// WHERE THE PREDICTION IS MADE
// ---------------------------------------------------------------------------
// The branch predictor is looked up with fetch_addr_q, the address of the
// request in flight. That is a register, so the lookup starts at the clock
// edge rather than at the end of a redirect mux. The prediction is consumed in
// the cycle the response arrives, when it becomes both
//   * the next fetch address (pc_q), and
//   * the predicted next pc recorded beside the instruction in IF/ID, which EX
//     later checks against the real next pc.
// Taking both from the same lookup in the same cycle is what guarantees that
// the prediction EX checks is exactly the one that steered fetch, even if the
// predictor is retrained while the request is outstanding.
//
// With a zero-latency memory the response arrives in the cycle the request is
// presented, so a predicted-taken branch costs no fetch bubble at all.
//
// ---------------------------------------------------------------------------
// pc_q
// ---------------------------------------------------------------------------
// pc_q is the address the NEXT request will use, and is meaningful whenever no
// request is outstanding. While one is outstanding it is overwritten either by
// the response (with the prediction) or by a redirect (with the redirect
// target, in which case the response, when it comes, is discarded).
//
// instr_req_o is a function of this stage's own registers alone; it never
// depends combinationally on instr_gnt_i or instr_rvalid_i.
// ============================================================================

module p_core_if_stage
  import e_core_pkg::*;
  import p_core_pkg::*;
#(
  parameter logic [31:0] RESET_VECTOR = 32'h0000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // ---- instruction memory port ----
  output logic        instr_req_o,
  output logic [31:0] instr_addr_o,
  input  logic        instr_gnt_i,
  input  logic        instr_rvalid_i,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,

  // ---- branch predictor ----
  output logic [31:0] bp_lookup_pc_o,
  input  logic        bp_taken_i,
  input  logic [31:0] bp_target_i,
  input  logic [1:0]  bp_bht_i,
  input  logic        bp_btb_hit_i,

  // ---- redirect: a mispredict from EX, or a trap / MRET / FENCE.I from MEM ----
  input  logic        redirect_i,
  input  logic [31:0] redirect_pc_i,

  // ---- IF/ID pipeline register ----
  input  logic        ifid_accept_i,   // ID consumes the contents this cycle
  output logic        ifid_valid_o,
  output logic [31:0] ifid_pc_o,
  output logic [31:0] ifid_instr_o,
  output logic        ifid_err_o,      // the fetch itself faulted
  output pred_t       ifid_pred_o
);

  // ---- fetch state ----
  logic        fetch_active_q, fetch_active_d;   // a request is in flight
  logic        fetch_gnt_q,    fetch_gnt_d;      // ...and has been granted
  logic        discard_q,      discard_d;        // ...but is on the wrong path
  logic [31:0] fetch_addr_q,   fetch_addr_d;     // address of that request
  logic [31:0] pc_q,           pc_d;             // address to fetch next

  // ---- IF/ID register ----
  logic        ifid_valid_q, ifid_valid_d;
  logic [31:0] ifid_pc_q,    ifid_pc_d;
  logic [31:0] ifid_instr_q, ifid_instr_d;
  logic        ifid_err_q,   ifid_err_d;
  pred_t       ifid_pred_q,  ifid_pred_d;

  // ---- skid buffer ----
  logic        skid_valid_q, skid_valid_d;
  logic [31:0] skid_pc_q,    skid_pc_d;
  logic [31:0] skid_instr_q, skid_instr_d;
  logic        skid_err_q,   skid_err_d;
  pred_t       skid_pred_q,  skid_pred_d;

  assign instr_req_o    = fetch_active_q & ~fetch_gnt_q;
  assign instr_addr_o   = fetch_addr_q;
  assign bp_lookup_pc_o = fetch_addr_q;

  assign ifid_valid_o = ifid_valid_q;
  assign ifid_pc_o    = ifid_pc_q;
  assign ifid_instr_o = ifid_instr_q;
  assign ifid_err_o   = ifid_err_q;
  assign ifid_pred_o  = ifid_pred_q;

  // The prediction for the instruction at fetch_addr_q.
  pred_t pred;
  assign pred.npc     = bp_taken_i ? bp_target_i : (fetch_addr_q + 32'd4);
  assign pred.bht     = bp_bht_i;
  assign pred.btb_hit = bp_btb_hit_i;

  always_comb begin
    fetch_active_d = fetch_active_q;
    fetch_gnt_d    = fetch_gnt_q;
    discard_d      = discard_q;
    fetch_addr_d   = fetch_addr_q;
    pc_d           = pc_q;

    ifid_valid_d = ifid_valid_q & ~ifid_accept_i;
    ifid_pc_d    = ifid_pc_q;
    ifid_instr_d = ifid_instr_q;
    ifid_err_d   = ifid_err_q;
    ifid_pred_d  = ifid_pred_q;

    skid_valid_d = skid_valid_q;
    skid_pc_d    = skid_pc_q;
    skid_instr_d = skid_instr_q;
    skid_err_d   = skid_err_q;
    skid_pred_d  = skid_pred_q;

    // ---- 1. record the grant --------------------------------------------
    if (instr_req_o && instr_gnt_i) begin
      fetch_gnt_d = 1'b1;
    end

    // ---- 2. drain the skid buffer into IF/ID if there is room -----------
    if (!ifid_valid_d && skid_valid_q) begin
      ifid_valid_d = 1'b1;
      ifid_pc_d    = skid_pc_q;
      ifid_instr_d = skid_instr_q;
      ifid_err_d   = skid_err_q;
      ifid_pred_d  = skid_pred_q;
      skid_valid_d = 1'b0;
    end

    // ---- 3. accept the instruction memory response ----------------------
    if (fetch_active_q && instr_rvalid_i) begin
      fetch_active_d = 1'b0;
      fetch_gnt_d    = 1'b0;
      if (discard_q) begin
        // Wrong-path fetch issued before a redirect: consume the response and
        // throw it away. pc_q already holds the redirect target.
        discard_d = 1'b0;
      end else begin
        pc_d = pred.npc;
        if (!ifid_valid_d) begin
          ifid_valid_d = 1'b1;
          ifid_pc_d    = fetch_addr_q;
          ifid_instr_d = instr_rdata_i;
          ifid_err_d   = instr_err_i;
          ifid_pred_d  = pred;
        end else begin
          skid_valid_d = 1'b1;
          skid_pc_d    = fetch_addr_q;
          skid_instr_d = instr_rdata_i;
          skid_err_d   = instr_err_i;
          skid_pred_d  = pred;
        end
      end
    end

    // ---- 4. redirect ----------------------------------------------------
    // Everything fetched after the redirecting instruction is wrong-path, so
    // both buffers are cleared and any still-outstanding request is marked for
    // discard. The request itself is left alone: dropping `req` before `gnt`
    // would break the memory protocol.
    if (redirect_i) begin
      ifid_valid_d = 1'b0;
      skid_valid_d = 1'b0;
      pc_d         = redirect_pc_i;
      if (fetch_active_d) begin
        discard_d = 1'b1;
      end
    end

    // ---- 5. issue the next fetch ----------------------------------------
    // One request in flight at most, and only when the skid buffer is free,
    // so a response always has somewhere to land.
    if (!fetch_active_d && !skid_valid_d) begin
      fetch_active_d = 1'b1;
      fetch_gnt_d    = 1'b0;
      fetch_addr_d   = pc_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_active_q <= 1'b0;
      fetch_gnt_q    <= 1'b0;
      discard_q      <= 1'b0;
      fetch_addr_q   <= RESET_VECTOR;
      pc_q           <= RESET_VECTOR;
      ifid_valid_q   <= 1'b0;
      ifid_pc_q      <= RESET_VECTOR;
      ifid_instr_q   <= 32'd0;
      ifid_err_q     <= 1'b0;
      ifid_pred_q    <= '0;
      skid_valid_q   <= 1'b0;
      skid_pc_q      <= 32'd0;
      skid_instr_q   <= 32'd0;
      skid_err_q     <= 1'b0;
      skid_pred_q    <= '0;
    end else begin
      fetch_active_q <= fetch_active_d;
      fetch_gnt_q    <= fetch_gnt_d;
      discard_q      <= discard_d;
      fetch_addr_q   <= fetch_addr_d;
      pc_q           <= pc_d;
      ifid_valid_q   <= ifid_valid_d;
      ifid_pc_q      <= ifid_pc_d;
      ifid_instr_q   <= ifid_instr_d;
      ifid_err_q     <= ifid_err_d;
      ifid_pred_q    <= ifid_pred_d;
      skid_valid_q   <= skid_valid_d;
      skid_pc_q      <= skid_pc_d;
      skid_instr_q   <= skid_instr_d;
      skid_err_q     <= skid_err_d;
      skid_pred_q    <= skid_pred_d;
    end
  end

endmodule : p_core_if_stage
