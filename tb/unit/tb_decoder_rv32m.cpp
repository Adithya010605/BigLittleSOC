// ============================================================================
// tb_decoder_rv32m.cpp — tb_decoder.cpp, run against the P-core's elaboration
// of rtl/common/decoder.sv (RV32M = 1).
// ============================================================================
// UNIT-TOP: decoder
// UNIT-VFLAGS: -GRV32M=1
#define TB_RV32M 1
#define TB_NAME "decoder (RV32M = 1)"
#include "tb_decoder.cpp"
