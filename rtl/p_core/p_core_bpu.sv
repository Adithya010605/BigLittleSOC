// ============================================================================
// p_core_bpu.sv — branch prediction unit: 2-bit BHT plus direct-mapped BTB.
//
//   BHT  256 x 2-bit saturating counters, indexed by pc[9:2]
//   BTB  64 entries, indexed by pc[7:2]; each holds a valid bit, the full
//        remaining tag pc[31:8], the target pc[31:2] and a jump flag
//
// Lookup is combinational on the fetch address. A pc is predicted taken when
// the BTB holds an entry for it AND either the entry is an unconditional jump
// or the BHT counter's MSB is set. Without a BTB hit there is no target to
// predict, so the prediction is always fall-through.
//
// ---------------------------------------------------------------------------
// PREDICTION NEVER AFFECTS CORRECTNESS
// ---------------------------------------------------------------------------
// The EX stage compares every instruction's actual next pc with the one the
// fetch stage used and redirects on any difference. A wrong prediction, a
// stale entry or uninitialised table contents therefore cost cycles, never
// correctness. That is what allows the tables to be RAM without a reset: only
// the BTB valid bits are reset, so a cold BTB predicts nothing at all rather
// than predicting noise.
//
// ---------------------------------------------------------------------------
// TRAINING (from EX, once per instruction that leaves EX)
// ---------------------------------------------------------------------------
//   conditional branch  BHT counter  <- saturate(counter read at prediction,
//                                                actual direction)
//                       BTB entry    <- {pc, taken target, jump = 0}, written
//                                       when the branch was taken or already
//                                       had an entry; a never-taken branch
//                                       does not claim a BTB slot
//   JAL / JALR          BTB entry    <- {pc, target, jump = 1}
//   anything else       BTB entry invalidated if it hit -- the entry is stale,
//                       e.g. after self-modifying code rewrote a branch
//
// Updating the BHT from the counter value carried down the pipeline, rather
// than re-reading the table in EX, needs no second read port. The cost is that
// two in-flight instances of the same branch train from the same old value;
// that loses at most one step of hysteresis and never affects correctness.
// ============================================================================

module p_core_bpu
  import e_core_pkg::*;
  import p_core_pkg::*;
(
  input  logic        clk_i,
  input  logic        rst_ni,

  // ---- lookup, from the fetch stage ----
  input  logic [31:0] lookup_pc_i,
  output logic        pred_taken_o,
  output logic [31:0] pred_target_o,
  output logic [1:0]  pred_bht_o,
  output logic        pred_btb_hit_o,

  // ---- training, from EX ----
  input  logic        upd_en_i,        // an instruction leaves EX this cycle
  input  logic [31:0] upd_pc_i,
  input  logic        upd_is_branch_i,
  input  logic        upd_is_jump_i,
  input  logic        upd_taken_i,     // actual direction
  input  logic [31:0] upd_target_i,    // taken target (branches: pc + imm)
  input  logic [1:0]  upd_bht_i,       // counter value used for the prediction
  input  logic        upd_btb_hit_i    // the prediction came from a BTB hit
);

  // --------------------------------------------------------------------
  // Storage
  // --------------------------------------------------------------------
  logic [1:0]           bht        [BHT_SIZE];
  logic [BTB_SIZE-1:0]  btb_valid_q;
  logic [BTB_TAG_W-1:0] btb_tag    [BTB_SIZE];
  logic [31:2]          btb_target [BTB_SIZE];
  logic                 btb_jump   [BTB_SIZE];

  // --------------------------------------------------------------------
  // Lookup
  // --------------------------------------------------------------------
  logic [BHT_IDX_W-1:0] l_bht_idx;
  logic [BTB_IDX_W-1:0] l_btb_idx;
  logic [BTB_TAG_W-1:0] l_tag;

  assign l_bht_idx = lookup_pc_i[BHT_IDX_W+1:2];
  assign l_btb_idx = lookup_pc_i[BTB_IDX_W+1:2];
  assign l_tag     = lookup_pc_i[31:BTB_IDX_W+2];

  assign pred_bht_o     = bht[l_bht_idx];
  assign pred_btb_hit_o = btb_valid_q[l_btb_idx] & (btb_tag[l_btb_idx] == l_tag);
  assign pred_taken_o   = pred_btb_hit_o & (btb_jump[l_btb_idx] | pred_bht_o[1]);
  assign pred_target_o  = {btb_target[l_btb_idx], 2'b00};

  // --------------------------------------------------------------------
  // Training
  // --------------------------------------------------------------------
  logic [BHT_IDX_W-1:0] u_bht_idx;
  logic [BTB_IDX_W-1:0] u_btb_idx;
  logic [BTB_TAG_W-1:0] u_tag;

  assign u_bht_idx = upd_pc_i[BHT_IDX_W+1:2];
  assign u_btb_idx = upd_pc_i[BTB_IDX_W+1:2];
  assign u_tag     = upd_pc_i[31:BTB_IDX_W+2];

  logic [1:0] bht_next;
  always_comb begin
    if (upd_taken_i) begin
      bht_next = (upd_bht_i == BHT_STRONG_T)  ? BHT_STRONG_T  : upd_bht_i + 2'd1;
    end else begin
      bht_next = (upd_bht_i == BHT_STRONG_NT) ? BHT_STRONG_NT : upd_bht_i - 2'd1;
    end
  end

  logic bht_we, btb_we, btb_inval;
  assign bht_we    = upd_en_i & upd_is_branch_i;
  assign btb_we    = upd_en_i & (upd_is_jump_i |
                                 (upd_is_branch_i & (upd_taken_i | upd_btb_hit_i)));
  assign btb_inval = upd_en_i & ~upd_is_jump_i & ~upd_is_branch_i & upd_btb_hit_i;

  // The tables are write-only from here and read only by the lookup above,
  // with no reset, so they can infer as distributed RAM.
  always_ff @(posedge clk_i) begin
    if (bht_we) begin
      bht[u_bht_idx] <= bht_next;
    end
    if (btb_we) begin
      btb_tag[u_btb_idx]    <= u_tag;
      btb_target[u_btb_idx] <= upd_target_i[31:2];
      btb_jump[u_btb_idx]   <= upd_is_jump_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      btb_valid_q <= '0;
    end else if (btb_we) begin
      btb_valid_q[u_btb_idx] <= 1'b1;
    end else if (btb_inval) begin
      btb_valid_q[u_btb_idx] <= 1'b0;
    end
  end

  // Instructions are word-aligned (there is no C extension), so the low two
  // bits of a pc carry no information. Only whole-word targets are ever
  // installed either: EX does not train on a control transfer whose target is
  // misaligned, because that instruction traps instead of transferring.
  logic unused_bpu;
  assign unused_bpu = ^{lookup_pc_i[1:0], upd_pc_i[1:0], upd_target_i[1:0]};

`ifndef SYNTHESIS
  // Simulation-only initial contents, for deterministic runs. Hardware
  // power-up contents affect only prediction quality: every BTB entry starts
  // invalid through the reset above, and a BHT counter is consulted only
  // after its BTB entry has been trained.
  initial begin
    for (int unsigned i = 0; i < BHT_SIZE; i++) begin
      bht[i] = BHT_WEAK_NT;
    end
    for (int unsigned i = 0; i < BTB_SIZE; i++) begin
      btb_tag[i]    = '0;
      btb_target[i] = '0;
      btb_jump[i]   = 1'b0;
    end
  end
`endif

endmodule : p_core_bpu
