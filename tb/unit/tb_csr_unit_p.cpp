// ============================================================================
// tb_csr_unit_p.cpp — tb_csr_unit.cpp, run against the P-core's elaboration
// of rtl/common/csr_unit.sv: misa advertises RV32IM and seven event counters
// (mhpmcounter3..9) exist instead of four.
// ============================================================================
// UNIT-TOP: csr_unit
// UNIT-VFLAGS: -GMISA=32'h40001100 -GNUM_HPM=7
#define TB_NUM_HPM 7
#define TB_MISA 0x40001100u
#define TB_NAME "csr_unit (P-core parameters)"
#include "tb_csr_unit.cpp"
