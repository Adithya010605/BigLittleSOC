// ============================================================================
// disasm.h — RV32IM_Zicsr disassembler for testbench diagnostics.
//
// Exists so that a failure report can say `addi x5, x5, -1` instead of
// `0xfff28293`. Diagnostics only: it is never used to decide pass or fail.
// ============================================================================
#ifndef DISASM_H
#define DISASM_H

#include <cstdint>
#include <string>

std::string Disassemble(uint32_t insn, uint32_t pc);

#endif  // DISASM_H
