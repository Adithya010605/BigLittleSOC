// ============================================================================
// p_core_pkg.sv
//
// Types and constants specific to the P-Core (RV32IM_Zicsr, machine mode,
// 5-stage). Everything the two cores share -- opcodes, CSR addresses, cause
// codes, the ALU and immediate encodings, ctrl_t -- stays in e_core_pkg, which
// this package builds on; only what the P-core adds is defined here.
// ============================================================================

package p_core_pkg;

  import e_core_pkg::*;

  // misa: MXL = 1 (32-bit), extensions 'I' (bit 8) and 'M' (bit 12).
  localparam logic [31:0] MISA_RV32IM = 32'h4000_1100;

  // --------------------------------------------------------------------
  // M extension. The encoding is funct3 verbatim, as the decoder reports it:
  // bit 2 separates divide from multiply, which is how the EX stage steers an
  // operation to the right unit.
  // --------------------------------------------------------------------
  typedef enum logic [2:0] {
    MD_MUL    = 3'b000,
    MD_MULH   = 3'b001,
    MD_MULHSU = 3'b010,
    MD_MULHU  = 3'b011,
    MD_DIV    = 3'b100,
    MD_DIVU   = 3'b101,
    MD_REM    = 3'b110,
    MD_REMU   = 3'b111
  } md_op_e;

  // --------------------------------------------------------------------
  // Branch prediction geometry (project plan, Phase 2, week 6).
  //   BHT: 256 two-bit saturating counters, indexed by pc[9:2]
  //   BTB: 64 direct-mapped entries, indexed by pc[7:2], full tag pc[31:8]
  // --------------------------------------------------------------------
  localparam int unsigned BHT_IDX_W = 8;
  localparam int unsigned BHT_SIZE  = 1 << BHT_IDX_W;
  localparam int unsigned BTB_IDX_W = 6;
  localparam int unsigned BTB_SIZE  = 1 << BTB_IDX_W;
  localparam int unsigned BTB_TAG_W = 32 - 2 - BTB_IDX_W;

  // Two-bit counter values. The counter's MSB is the predicted direction;
  // the remaining value, 2'b10, is weakly taken.
  localparam logic [1:0] BHT_STRONG_NT = 2'b00;
  localparam logic [1:0] BHT_WEAK_NT   = 2'b01;   // the initial state
  localparam logic [1:0] BHT_STRONG_T  = 2'b11;

  // --------------------------------------------------------------------
  // What the fetch stage predicted for an instruction, carried beside it
  // down to EX, where the prediction is checked and the predictor trained.
  // --------------------------------------------------------------------
  typedef struct packed {
    logic [31:0] npc;       // the address fetched after this instruction
    logic [1:0]  bht;       // the BHT counter as read at prediction time
    logic        btb_hit;   // the BTB held an entry for this pc
  } pred_t;

  // --------------------------------------------------------------------
  // Decoded control, extended with what the P-core needs beyond ctrl_t.
  // --------------------------------------------------------------------
  typedef struct packed {
    ctrl_t      base;
    logic       is_jalr;
    logic       md_en;       // multiply or divide
    md_op_e     md_op;
    logic       fence_i;     // refetch after commit
    logic       csr_use_imm; // CSR operand is the zero-extended uimm
  } p_ctrl_t;

  // --------------------------------------------------------------------
  // Event counters. The first four are the E-core's, unchanged, so the two
  // cores are directly comparable; the P-core adds three.
  //   mhpmcounter3  PERF_STALL       cycles ID held a valid instruction back
  //   mhpmcounter4  PERF_BRANCH      conditional branches retired
  //   mhpmcounter5  PERF_BR_TAKEN    ...of which taken
  //   mhpmcounter6  PERF_MEM         loads and stores retired
  //   mhpmcounter7  PPERF_MISPREDICT instructions retired that redirected
  //                                  fetch from EX (branch or jump mispredict)
  //   mhpmcounter8  PPERF_MD_BUSY    cycles EX waited on the multiplier or
  //                                  divider
  //   mhpmcounter9  PPERF_LOAD_USE   cycles the load-use / CSR-use interlock
  //                                  held ID
  // --------------------------------------------------------------------
  localparam int unsigned PPERF_MISPREDICT = 4;
  localparam int unsigned PPERF_MD_BUSY    = 5;
  localparam int unsigned PPERF_LOAD_USE   = 6;
  localparam int unsigned NUM_PPERF        = 7;

endpackage : p_core_pkg
