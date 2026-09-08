// ============================================================================
// e_core_if_stage.sv  —  Stage S1: instruction fetch
//
// Owns the program counter, the instruction-port handshake, and the IF/ID
// pipeline register.
//
// ---------------------------------------------------------------------------
// WHY THERE IS A SKID BUFFER
// ---------------------------------------------------------------------------
// The instruction port may answer in the same cycle as the request or many
// cycles later, and the ID stage may stall at any time. Those two facts
// together mean a returning instruction can arrive in a cycle when the IF/ID
// register is still occupied.
//
// Refusing to issue a fetch until IF/ID is empty would avoid the problem but
// costs half the throughput: the response cannot arrive before the cycle after
// the request, so IF/ID would be filled only every other cycle and the core
// would run at 0.5 IPC even with a zero-latency memory. A single-entry skid
// buffer removes that restriction — a fetch is issued whenever the skid is
// free, and a response that finds IF/ID occupied waits in the skid until it
// drains — which restores 1 IPC while keeping at most one request in flight.
//
// ---------------------------------------------------------------------------
// WHY THE FETCH ADDRESS IS A SEPARATE REGISTER FROM THE PC
// ---------------------------------------------------------------------------
// `instr_addr_o` must stay stable from the cycle a request is asserted until
// it is granted. A branch resolving in ID can redirect the PC in the middle of
// that window. `fetch_addr_q` therefore holds the address of the request
// actually in flight, while `pc_q` holds the address to fetch next; a redirect
// changes `pc_q` only, so the outstanding request keeps presenting the address
// the memory already saw. The wrong-path response is then discarded via
// `discard_q` rather than by yanking the address out from under the memory.
//
// `instr_req_o` is a function of this stage's own registers alone. It never
// depends combinationally on `instr_gnt_i` or `instr_rvalid_i`, which is the
// contract the testbench's memory model relies on.
// ============================================================================

module e_core_if_stage
  import e_core_pkg::*;
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

  // ---- redirect from ID (taken branch, jump) or from the trap unit ----
  input  logic        redirect_i,
  input  logic [31:0] redirect_pc_i,

  // ---- IF/ID pipeline register ----
  input  logic        ifid_accept_i,   // ID consumes the contents this cycle
  output logic        ifid_valid_o,
  output logic [31:0] ifid_pc_o,
  output logic [31:0] ifid_instr_o,
  output logic        ifid_err_o       // the fetch itself faulted
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

  // ---- skid buffer ----
  logic        skid_valid_q, skid_valid_d;
  logic [31:0] skid_pc_q,    skid_pc_d;
  logic [31:0] skid_instr_q, skid_instr_d;
  logic        skid_err_q,   skid_err_d;

  assign instr_req_o  = fetch_active_q & ~fetch_gnt_q;
  assign instr_addr_o = fetch_addr_q;

  assign ifid_valid_o = ifid_valid_q;
  assign ifid_pc_o    = ifid_pc_q;
  assign ifid_instr_o = ifid_instr_q;
  assign ifid_err_o   = ifid_err_q;

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

    skid_valid_d = skid_valid_q;
    skid_pc_d    = skid_pc_q;
    skid_instr_d = skid_instr_q;
    skid_err_d   = skid_err_q;

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
      skid_valid_d = 1'b0;
    end

    // ---- 3. accept the instruction memory response ----------------------
    if (fetch_active_q && instr_rvalid_i) begin
      fetch_active_d = 1'b0;
      fetch_gnt_d    = 1'b0;
      if (discard_q) begin
        // Wrong-path fetch issued before a redirect: consume the response and
        // throw it away. pc_q already points at the redirect target.
        discard_d = 1'b0;
      end else begin
        if (!ifid_valid_d) begin
          ifid_valid_d = 1'b1;
          ifid_pc_d    = fetch_addr_q;
          ifid_instr_d = instr_rdata_i;
          ifid_err_d   = instr_err_i;
        end else begin
          skid_valid_d = 1'b1;
          skid_pc_d    = fetch_addr_q;
          skid_instr_d = instr_rdata_i;
          skid_err_d   = instr_err_i;
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
    // Only one request is ever in flight, and only when the skid buffer is
    // free, so a response always has somewhere to land.
    if (!fetch_active_d && !skid_valid_d) begin
      fetch_active_d = 1'b1;
      fetch_gnt_d    = 1'b0;
      fetch_addr_d   = pc_d;
      pc_d           = pc_d + 32'd4;
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
      skid_valid_q   <= 1'b0;
      skid_pc_q      <= 32'd0;
      skid_instr_q   <= 32'd0;
      skid_err_q     <= 1'b0;
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
      skid_valid_q   <= skid_valid_d;
      skid_pc_q      <= skid_pc_d;
      skid_instr_q   <= skid_instr_d;
      skid_err_q     <= skid_err_d;
    end
  end

endmodule : e_core_if_stage
