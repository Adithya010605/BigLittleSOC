// ============================================================================
// e_core_pkg.sv
//
// Shared types, enumerations and constants for the E-Core (RV32I_Zicsr,
// machine mode, 3-stage). Every magic number that would otherwise appear in
// stage logic is named here: opcodes, funct fields, CSR addresses, exception
// causes and the pipeline control bundle.
// ============================================================================

package e_core_pkg;

  // --------------------------------------------------------------------
  // Machine width
  // --------------------------------------------------------------------
  localparam int unsigned XLEN       = 32;
  localparam int unsigned REG_ADDR_W = 5;
  localparam int unsigned NUM_REGS   = 32;
  localparam int unsigned CSR_ADDR_W = 12;

  // --------------------------------------------------------------------
  // Major opcodes, instr[6:0]
  // --------------------------------------------------------------------
  localparam logic [6:0] OPCODE_LOAD     = 7'b000_0011;
  localparam logic [6:0] OPCODE_MISC_MEM = 7'b000_1111;  // FENCE, FENCE.I
  localparam logic [6:0] OPCODE_OP_IMM   = 7'b001_0011;
  localparam logic [6:0] OPCODE_AUIPC    = 7'b001_0111;
  localparam logic [6:0] OPCODE_STORE    = 7'b010_0011;
  localparam logic [6:0] OPCODE_OP       = 7'b011_0011;
  localparam logic [6:0] OPCODE_LUI      = 7'b011_0111;
  localparam logic [6:0] OPCODE_BRANCH   = 7'b110_0011;
  localparam logic [6:0] OPCODE_JALR     = 7'b110_0111;
  localparam logic [6:0] OPCODE_JAL      = 7'b110_1111;
  localparam logic [6:0] OPCODE_SYSTEM   = 7'b111_0011;

  // --------------------------------------------------------------------
  // funct3 encodings
  // --------------------------------------------------------------------
  // OP / OP-IMM
  localparam logic [2:0] F3_ADD_SUB = 3'b000;
  localparam logic [2:0] F3_SLL     = 3'b001;
  localparam logic [2:0] F3_SLT     = 3'b010;
  localparam logic [2:0] F3_SLTU    = 3'b011;
  localparam logic [2:0] F3_XOR     = 3'b100;
  localparam logic [2:0] F3_SRL_SRA = 3'b101;
  localparam logic [2:0] F3_OR      = 3'b110;
  localparam logic [2:0] F3_AND     = 3'b111;

  // LOAD / STORE width fields
  localparam logic [2:0] F3_LB  = 3'b000;
  localparam logic [2:0] F3_LH  = 3'b001;
  localparam logic [2:0] F3_LW  = 3'b010;
  localparam logic [2:0] F3_LBU = 3'b100;
  localparam logic [2:0] F3_LHU = 3'b101;
  localparam logic [2:0] F3_SB  = 3'b000;
  localparam logic [2:0] F3_SH  = 3'b001;
  localparam logic [2:0] F3_SW  = 3'b010;

  // MISC-MEM
  localparam logic [2:0] F3_FENCE   = 3'b000;
  localparam logic [2:0] F3_FENCE_I = 3'b001;

  // SYSTEM: funct3 == 0 selects the privileged/ECALL group, the rest are Zicsr
  localparam logic [2:0] F3_PRIV   = 3'b000;
  localparam logic [2:0] F3_CSRRW  = 3'b001;
  localparam logic [2:0] F3_CSRRS  = 3'b010;
  localparam logic [2:0] F3_CSRRC  = 3'b011;
  localparam logic [2:0] F3_CSRRWI = 3'b101;
  localparam logic [2:0] F3_CSRRSI = 3'b110;
  localparam logic [2:0] F3_CSRRCI = 3'b111;

  // funct7 values that distinguish ADD/SUB and SRL/SRA
  // Only these two funct7 values are legal in RV32I. Everything else -- most
  // notably 7'b000_0001, the M extension -- is rejected by the decoder.
  localparam logic [6:0] F7_ZERO = 7'b000_0000;
  localparam logic [6:0] F7_SUB  = 7'b010_0000;  // also SRA

  // Full 32-bit encodings of the privileged instructions (SYSTEM, funct3=0).
  localparam logic [31:0] INSN_ECALL  = 32'h0000_0073;
  localparam logic [31:0] INSN_EBREAK = 32'h0010_0073;
  localparam logic [31:0] INSN_MRET   = 32'h3020_0073;
  localparam logic [31:0] INSN_WFI    = 32'h1050_0073;

  // --------------------------------------------------------------------
  // ALU
  // --------------------------------------------------------------------
  // ALU_ADD is deliberately given the all-ones code so that it lands on the
  // `default` arm of the ALU result mux. The default arm is then exercised by
  // ordinary ADD instructions instead of being dead code that line coverage
  // could never reach.
  typedef enum logic [3:0] {
    ALU_SUB  = 4'b0000,
    ALU_SLL  = 4'b0001,
    ALU_SLT  = 4'b0010,
    ALU_SLTU = 4'b0011,
    ALU_XOR  = 4'b0100,
    ALU_SRL  = 4'b0101,
    ALU_OR   = 4'b0110,
    ALU_AND  = 4'b0111,
    ALU_SRA  = 4'b1000,
    ALU_ADD  = 4'b1111
  } alu_op_e;

  // ALU operand A source
  typedef enum logic [1:0] {
    OP_A_RS1  = 2'b00,   // register rs1
    OP_A_PC   = 2'b01,   // program counter (AUIPC)
    OP_A_ZERO = 2'b10    // constant zero (LUI)
  } op_a_sel_e;

  // ALU operand B source
  typedef enum logic [0:0] {
    OP_B_RS2 = 1'b0,
    OP_B_IMM = 1'b1
  } op_b_sel_e;

  // --------------------------------------------------------------------
  // Immediate formats
  // --------------------------------------------------------------------
  typedef enum logic [2:0] {
    IMM_I = 3'd0,
    IMM_S = 3'd1,
    IMM_B = 3'd2,
    IMM_U = 3'd3,
    IMM_J = 3'd4,
    IMM_Z = 3'd5   // 5-bit zero-extended CSR uimm (CSRRWI/CSRRSI/CSRRCI)
  } imm_sel_e;

  // --------------------------------------------------------------------
  // Writeback source
  // --------------------------------------------------------------------
  typedef enum logic [1:0] {
    WB_ALU = 2'b00,
    WB_MEM = 2'b01,
    WB_PC4 = 2'b10,   // JAL / JALR link value
    WB_CSR = 2'b11
  } wb_sel_e;

  // --------------------------------------------------------------------
  // Branch comparison. The encoding is instr[14:12] verbatim, so the decoder
  // passes funct3 straight through; 3'b010 and 3'b011 are not valid branch
  // funct3 values and the decoder raises illegal-instruction for them.
  // --------------------------------------------------------------------
  typedef enum logic [2:0] {
    BR_EQ  = 3'b000,
    BR_NE  = 3'b001,
    BR_LT  = 3'b100,
    BR_GE  = 3'b101,
    BR_LTU = 3'b110,
    BR_GEU = 3'b111
  } br_op_e;

  // --------------------------------------------------------------------
  // Memory access size (LSU)
  // --------------------------------------------------------------------
  typedef enum logic [1:0] {
    SZ_BYTE = 2'b00,
    SZ_HALF = 2'b01,
    SZ_WORD = 2'b10
  } mem_size_e;

  // --------------------------------------------------------------------
  // CSR read-modify-write operation
  // --------------------------------------------------------------------
  typedef enum logic [1:0] {
    CSR_OP_RW = 2'b00,   // CSRRW  / CSRRWI
    CSR_OP_RS = 2'b01,   // CSRRS  / CSRRSI
    CSR_OP_RC = 2'b10    // CSRRC  / CSRRCI
  } csr_op_e;

  // --------------------------------------------------------------------
  // CSR addresses (machine mode)
  // --------------------------------------------------------------------
  localparam logic [11:0] CSR_MSTATUS       = 12'h300;
  localparam logic [11:0] CSR_MISA          = 12'h301;
  localparam logic [11:0] CSR_MIE           = 12'h304;
  localparam logic [11:0] CSR_MTVEC         = 12'h305;
  localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] CSR_MSCRATCH      = 12'h340;
  localparam logic [11:0] CSR_MEPC          = 12'h341;
  localparam logic [11:0] CSR_MCAUSE        = 12'h342;
  localparam logic [11:0] CSR_MTVAL         = 12'h343;
  localparam logic [11:0] CSR_MIP           = 12'h344;

  localparam logic [11:0] CSR_MCYCLE        = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET      = 12'hB02;
  localparam logic [11:0] CSR_MHPMCOUNTER3  = 12'hB03;  // stall cycles
  localparam logic [11:0] CSR_MHPMCOUNTER4  = 12'hB04;  // branch instructions
  localparam logic [11:0] CSR_MHPMCOUNTER5  = 12'hB05;  // taken branches
  localparam logic [11:0] CSR_MHPMCOUNTER6  = 12'hB06;  // load/store count

  localparam logic [11:0] CSR_MCYCLEH       = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH     = 12'hB82;
  localparam logic [11:0] CSR_MHPMCOUNTER3H = 12'hB83;
  localparam logic [11:0] CSR_MHPMCOUNTER4H = 12'hB84;
  localparam logic [11:0] CSR_MHPMCOUNTER5H = 12'hB85;
  localparam logic [11:0] CSR_MHPMCOUNTER6H = 12'hB86;

  localparam logic [11:0] CSR_MVENDORID     = 12'hF11;
  localparam logic [11:0] CSR_MARCHID       = 12'hF12;
  localparam logic [11:0] CSR_MIMPID        = 12'hF13;
  localparam logic [11:0] CSR_MHARTID       = 12'hF14;

  // Custom performance counters, indexed within the mhpmcounter block.
  localparam int unsigned PERF_STALL    = 0;  // mhpmcounter3
  localparam int unsigned PERF_BRANCH   = 1;  // mhpmcounter4
  localparam int unsigned PERF_BR_TAKEN = 2;  // mhpmcounter5
  localparam int unsigned PERF_MEM      = 3;  // mhpmcounter6
  localparam int unsigned NUM_PERF      = 4;

  // misa: MXL = 1 (32-bit), extension bit 'I' (bit 8) only.
  localparam logic [31:0] MISA_VALUE = 32'h4000_0100;

  // mstatus field positions.
  localparam int unsigned MSTATUS_MIE_BIT  = 3;
  localparam int unsigned MSTATUS_MPIE_BIT = 7;
  localparam int unsigned MSTATUS_MPP_LSB  = 11;   // 2 bits, hardwired 2'b11

  // mie / mip bit positions.
  localparam int unsigned IRQ_M_SOFT_BIT  = 3;
  localparam int unsigned IRQ_M_TIMER_BIT = 7;
  localparam int unsigned IRQ_M_EXT_BIT   = 11;

  // --------------------------------------------------------------------
  // Exception causes (mcause with the interrupt bit clear), in priority
  // order highest first. See docs/e_core_microarchitecture.md section 6.
  // --------------------------------------------------------------------
  localparam logic [4:0] EXC_INSTR_MISALIGNED = 5'd0;
  localparam logic [4:0] EXC_INSTR_ACCESS     = 5'd1;
  localparam logic [4:0] EXC_ILLEGAL_INSTR    = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT       = 5'd3;
  localparam logic [4:0] EXC_LOAD_MISALIGNED  = 5'd4;
  localparam logic [4:0] EXC_LOAD_ACCESS      = 5'd5;
  localparam logic [4:0] EXC_STORE_MISALIGNED = 5'd6;
  localparam logic [4:0] EXC_STORE_ACCESS     = 5'd7;
  localparam logic [4:0] EXC_ECALL_M          = 5'd11;

  // Interrupt causes (mcause with bit 31 set).
  localparam logic [4:0] IRQ_CAUSE_M_SOFT  = 5'd3;
  localparam logic [4:0] IRQ_CAUSE_M_TIMER = 5'd7;
  localparam logic [4:0] IRQ_CAUSE_M_EXT   = 5'd11;

  // --------------------------------------------------------------------
  // Decoded control bundle carried in the ID/EX pipeline register.
  // The decoder exposes these as individual ports so that its unit testbench
  // does not depend on Verilator's packed-struct bit layout; the ID stage
  // packs them into this type for the pipeline register.
  // --------------------------------------------------------------------
  typedef struct packed {
    alu_op_e   alu_op;
    op_a_sel_e op_a_sel;
    op_b_sel_e op_b_sel;
    wb_sel_e   wb_sel;
    logic      rf_we;
    logic      mem_req;
    logic      mem_we;
    mem_size_e mem_size;
    logic      mem_signed;   // sign-extend a sub-word load
    logic      csr_en;
    csr_op_e   csr_op;
    logic      csr_read;     // the instruction actually reads the CSR
    logic      csr_write;    // the instruction actually writes the CSR
    logic      is_branch;
    logic      is_jump;
    logic      illegal;
    logic      ecall;
    logic      ebreak;
    logic      mret;
    logic      wfi;
  } ctrl_t;

  // --------------------------------------------------------------------
  // Bit-reversal helper, used by the ALU to build left shifts out of its
  // single right-shift barrel shifter.
  // --------------------------------------------------------------------
  function automatic logic [31:0] rev32(input logic [31:0] v);
    logic [31:0] r;
    for (int unsigned i = 0; i < 32; i++) begin
      r[i] = v[31-i];
    end
    return r;
  endfunction

endpackage : e_core_pkg
