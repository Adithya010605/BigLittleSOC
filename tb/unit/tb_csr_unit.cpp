// ============================================================================
// tb_csr_unit.cpp — unit testbench for rtl/common/csr_unit.sv
//
// Coverage: read/write/set/clear semantics, read-only enforcement, the
// unimplemented-address trap, WARL masking, trap entry and MRET side effects,
// and counter increment/inhibit/writability.
// ============================================================================
#include "Vcsr_unit.h"
#include "tb_common.h"

#include <cinttypes>

enum : uint8_t { CSR_OP_RW = 0, CSR_OP_RS = 1, CSR_OP_RC = 2 };

enum : uint16_t {
  MSTATUS = 0x300, MISA = 0x301, MIE = 0x304, MTVEC = 0x305,
  MCOUNTINHIBIT = 0x320, MSCRATCH = 0x340, MEPC = 0x341, MCAUSE = 0x342,
  MTVAL = 0x343, MIP = 0x344, MCYCLE = 0xB00, MINSTRET = 0xB02,
  MHPM3 = 0xB03, MHPM4 = 0xB04, MHPM5 = 0xB05, MHPM6 = 0xB06,
  MCYCLEH = 0xB80, MINSTRETH = 0xB82,
  MVENDORID = 0xF11, MARCHID = 0xF12, MIMPID = 0xF13, MHARTID = 0xF14,
};

static Vcsr_unit* g_dut = nullptr;

static void Idle() {
  g_dut->csr_en_i = 0;
  g_dut->csr_write_i = 0;
  g_dut->csr_commit_i = 0;
  g_dut->trap_i = 0;
  g_dut->mret_i = 0;
  g_dut->instr_retired_i = 0;
  g_dut->stall_i = 0;
  g_dut->branch_i = 0;
  g_dut->branch_taken_i = 0;
  g_dut->mem_access_i = 0;
}

static void Tick() {
  g_dut->clk_i = 0;
  g_dut->eval();
  g_dut->clk_i = 1;
  g_dut->eval();
}

// Presents a CSR access and returns the value read. `commit` false models an
// access squashed by a trap in the same cycle.
static uint32_t Access(uint16_t addr, uint8_t op, uint32_t wdata, bool write,
                       bool commit = true) {
  g_dut->csr_en_i = 1;
  g_dut->csr_write_i = write ? 1 : 0;
  g_dut->csr_op_i = op;
  g_dut->csr_addr_i = addr;
  g_dut->csr_wdata_i = wdata;
  g_dut->csr_commit_i = commit ? 1 : 0;
  g_dut->eval();
  const uint32_t rd = g_dut->csr_rdata_o;
  Tick();
  Idle();
  g_dut->eval();
  return rd;
}

// Reads without writing (CSRRS with rs1 = x0).
static uint32_t Read(uint16_t addr) {
  g_dut->csr_en_i = 1;
  g_dut->csr_write_i = 0;
  g_dut->csr_op_i = CSR_OP_RS;
  g_dut->csr_addr_i = addr;
  g_dut->csr_wdata_i = 0;
  g_dut->csr_commit_i = 1;
  g_dut->eval();
  const uint32_t rd = g_dut->csr_rdata_o;
  Idle();
  g_dut->eval();
  return rd;
}

static bool IllegalFor(uint16_t addr, bool write) {
  g_dut->csr_en_i = 1;
  g_dut->csr_write_i = write ? 1 : 0;
  g_dut->csr_op_i = CSR_OP_RW;
  g_dut->csr_addr_i = addr;
  g_dut->csr_wdata_i = 0;
  g_dut->csr_commit_i = 0;   // do not actually commit while probing
  g_dut->eval();
  const bool bad = g_dut->csr_illegal_o != 0;
  Idle();
  g_dut->eval();
  return bad;
}

int main(int argc, char** argv) {
  const uint64_t seed = (argc > 1) ? std::strtoull(argv[1], nullptr, 0) : 0xC5Fu;
  std::printf("tb_csr_unit: seed=0x%" PRIx64 "\n", seed);

  Vcsr_unit dut;
  g_dut = &dut;
  dut.clk_i = 0;
  dut.rst_ni = 0;
  dut.irq_timer_i = 0;
  dut.irq_software_i = 0;
  dut.irq_external_i = 0;
  dut.trap_pc_i = 0;
  dut.trap_cause_i = 0;
  dut.trap_is_irq_i = 0;
  dut.trap_tval_i = 0;
  Idle();
  for (int i = 0; i < 3; ++i) Tick();
  dut.rst_ni = 1;
  Tick();

  // ---------------- read/write round trip ----------------
  Access(MSCRATCH, CSR_OP_RW, 0xDEADBEEFu, true);
  tb::CheckEq<uint32_t>("mscratch readback", Read(MSCRATCH), 0xDEADBEEFu);

  // CSRRW returns the OLD value while writing the new one.
  tb::CheckEq<uint32_t>("csrrw returns old",
                        Access(MSCRATCH, CSR_OP_RW, 0x12345678u, true),
                        0xDEADBEEFu);
  tb::CheckEq<uint32_t>("csrrw wrote new", Read(MSCRATCH), 0x12345678u);
  tb::Group("CSRRW read/write round trip");

  // ---------------- set and clear ----------------
  Access(MSCRATCH, CSR_OP_RW, 0x0F0F0000u, true);
  tb::CheckEq<uint32_t>("csrrs returns old",
                        Access(MSCRATCH, CSR_OP_RS, 0x00000F0Fu, true),
                        0x0F0F0000u);
  tb::CheckEq<uint32_t>("csrrs set bits", Read(MSCRATCH), 0x0F0F0F0Fu);
  tb::CheckEq<uint32_t>("csrrc returns old",
                        Access(MSCRATCH, CSR_OP_RC, 0x00000F0Fu, true),
                        0x0F0F0F0Fu);
  tb::CheckEq<uint32_t>("csrrc cleared bits", Read(MSCRATCH), 0x0F0F0000u);
  tb::Group("CSRRS / CSRRC set and clear");

  // ---------------- write suppressed when the access does not commit ------
  Access(MSCRATCH, CSR_OP_RW, 0xAAAAAAAAu, true, /*commit=*/false);
  tb::CheckEq<uint32_t>("squashed access does not write", Read(MSCRATCH),
                        0x0F0F0000u);
  // ...and when csr_write_i is low, as for CSRRS with rs1 = x0.
  Access(MSCRATCH, CSR_OP_RS, 0xFFFFFFFFu, /*write=*/false);
  tb::CheckEq<uint32_t>("no write when csr_write_i low", Read(MSCRATCH),
                        0x0F0F0000u);
  tb::Group("writes gated by commit and by csr_write_i");

  // ---------------- read-only registers ----------------
  tb::CheckEq<uint32_t>("misa value", Read(MISA), 0x40000100u);
  tb::CheckEq<uint32_t>("mvendorid", Read(MVENDORID), 0u);
  tb::CheckEq<uint32_t>("marchid", Read(MARCHID), 0u);
  tb::CheckEq<uint32_t>("mimpid", Read(MIMPID), 0u);
  tb::CheckEq<uint32_t>("mhartid", Read(MHARTID), 0u);

  for (uint16_t ro : {MISA, MVENDORID, MARCHID, MIMPID, MHARTID, MIP}) {
    tb::Check(IllegalFor(ro, /*write=*/true),
              "writing a read-only CSR must be illegal");
    tb::Check(!IllegalFor(ro, /*write=*/false),
              "reading a read-only CSR must be legal");
  }
  tb::Group("read-only enforcement");

  // ---------------- unimplemented addresses ----------------
  for (uint16_t bad : {0x7C0, 0x000, 0x100, 0x3A0, 0xC00, 0xFFF}) {
    tb::Check(IllegalFor(bad, false),
              "an unimplemented CSR must be illegal to read");
    tb::Check(IllegalFor(bad, true),
              "an unimplemented CSR must be illegal to write");
  }
  tb::Group("unimplemented addresses trap");

  // ---------------- WARL masking ----------------
  // mtvec is direct mode only: the low two bits are forced to zero.
  Access(MTVEC, CSR_OP_RW, 0x80001003u, true);
  tb::CheckEq<uint32_t>("mtvec mode bits forced to 0", Read(MTVEC),
                        0x80001000u);
  // mepc has bit 0 hardwired to zero.
  Access(MEPC, CSR_OP_RW, 0x00001235u, true);
  tb::CheckEq<uint32_t>("mepc bit 0 hardwired 0", Read(MEPC), 0x00001234u);
  // mstatus.MPP is hardwired to machine mode, and only MIE/MPIE are writable.
  Access(MSTATUS, CSR_OP_RW, 0x00000000u, true);
  tb::CheckEq<uint32_t>("mstatus MPP hardwired 2'b11", Read(MSTATUS) & 0x1800u,
                        0x1800u);
  Access(MSTATUS, CSR_OP_RW, 0x00000088u, true);   // MIE | MPIE
  tb::CheckEq<uint32_t>("mstatus MIE/MPIE writable", Read(MSTATUS) & 0x88u,
                        0x88u);
  // mie accepts only the three machine-interrupt bits.
  Access(MIE, CSR_OP_RW, 0xFFFFFFFFu, true);
  tb::CheckEq<uint32_t>("mie masks to MSIE/MTIE/MEIE", Read(MIE), 0x00000888u);
  tb::Group("WARL masking");

  // ---------------- mip mirrors the interrupt pins ----------------
  dut.irq_timer_i = 1;
  dut.eval();
  tb::CheckEq<uint32_t>("mip MTIP follows the pin", Read(MIP) & 0x80u, 0x80u);
  dut.irq_timer_i = 0;
  dut.irq_software_i = 1;
  dut.eval();
  tb::CheckEq<uint32_t>("mip MSIP follows the pin", Read(MIP) & 0x8u, 0x8u);
  dut.irq_software_i = 0;
  dut.irq_external_i = 1;
  dut.eval();
  tb::CheckEq<uint32_t>("mip MEIP follows the pin", Read(MIP) & 0x800u, 0x800u);
  dut.irq_external_i = 0;
  dut.eval();
  tb::CheckEq<uint32_t>("mip clears with the pins", Read(MIP), 0u);
  tb::Group("mip mirrors the interrupt pins");

  // ---------------- trap entry and MRET ----------------
  Access(MSTATUS, CSR_OP_RW, 0x8u, true);   // MIE = 1, MPIE = 0
  dut.trap_i = 1;
  dut.trap_pc_i = 0x00001000u >> 1;   // the port carries pc[31:1]
  dut.trap_cause_i = 11;              // ECALL from M-mode
  dut.trap_is_irq_i = 0;
  dut.trap_tval_i = 0xABCDu;
  dut.eval();
  Tick();
  Idle();
  dut.eval();

  tb::CheckEq<uint32_t>("trap set mepc", Read(MEPC), 0x00001000u);
  tb::CheckEq<uint32_t>("trap set mcause", Read(MCAUSE), 11u);
  tb::CheckEq<uint32_t>("trap set mtval", Read(MTVAL), 0xABCDu);
  tb::CheckEq<uint32_t>("trap cleared MIE", Read(MSTATUS) & 0x8u, 0u);
  tb::CheckEq<uint32_t>("trap set MPIE from old MIE", Read(MSTATUS) & 0x80u,
                        0x80u);

  dut.mret_i = 1;
  dut.eval();
  Tick();
  Idle();
  dut.eval();
  tb::CheckEq<uint32_t>("mret restored MIE from MPIE", Read(MSTATUS) & 0x8u,
                        0x8u);
  tb::CheckEq<uint32_t>("mret set MPIE", Read(MSTATUS) & 0x80u, 0x80u);
  tb::Group("trap entry and MRET");

  // ---------------- interrupt cause encoding ----------------
  dut.trap_i = 1;
  dut.trap_pc_i = 0x2000u >> 1;
  dut.trap_cause_i = 7;
  dut.trap_is_irq_i = 1;
  dut.trap_tval_i = 0;
  dut.eval();
  Tick();
  Idle();
  dut.eval();
  tb::CheckEq<uint32_t>("interrupt sets mcause bit 31", Read(MCAUSE),
                        0x80000007u);
  tb::Group("interrupt cause encoding");

  // ---------------- counters ----------------
  Access(MCOUNTINHIBIT, CSR_OP_RW, 0u, true);   // everything enabled
  const uint32_t c0 = Read(MCYCLE);
  for (int i = 0; i < 10; ++i) Tick();
  const uint32_t c1 = Read(MCYCLE);
  tb::Check(c1 > c0, "mcycle must advance");

  Access(MINSTRET, CSR_OP_RW, 0u, true);
  for (int i = 0; i < 5; ++i) {
    dut.instr_retired_i = 1;
    dut.eval();
    Tick();
    Idle();
    dut.eval();
  }
  tb::CheckEq<uint32_t>("minstret counts retirements", Read(MINSTRET), 5u);

  // A cycle with no retirement must not increment it.
  for (int i = 0; i < 5; ++i) Tick();
  tb::CheckEq<uint32_t>("minstret ignores non-retiring cycles", Read(MINSTRET),
                        5u);

  // mcountinhibit.IR freezes minstret while mcycle keeps running.
  Access(MCOUNTINHIBIT, CSR_OP_RW, 0x4u, true);
  const uint32_t cyc_before = Read(MCYCLE);
  for (int i = 0; i < 5; ++i) {
    dut.instr_retired_i = 1;
    dut.eval();
    Tick();
    Idle();
    dut.eval();
  }
  tb::CheckEq<uint32_t>("mcountinhibit.IR freezes minstret", Read(MINSTRET), 5u);
  tb::Check(Read(MCYCLE) > cyc_before, "mcycle keeps running under IR inhibit");

  // mcountinhibit.CY freezes mcycle.
  Access(MCOUNTINHIBIT, CSR_OP_RW, 0x1u, true);
  const uint32_t frozen = Read(MCYCLE);
  for (int i = 0; i < 5; ++i) Tick();
  tb::CheckEq<uint32_t>("mcountinhibit.CY freezes mcycle", Read(MCYCLE), frozen);
  Access(MCOUNTINHIBIT, CSR_OP_RW, 0u, true);

  // Counters are writable, including the high halves.
  Access(MCYCLE, CSR_OP_RW, 0x1000u, true);
  tb::Check(Read(MCYCLE) >= 0x1000u, "mcycle is writable");
  Access(MCYCLEH, CSR_OP_RW, 0x7u, true);
  tb::CheckEq<uint32_t>("mcycleh is writable", Read(MCYCLEH), 7u);
  Access(MINSTRETH, CSR_OP_RW, 0x9u, true);
  tb::CheckEq<uint32_t>("minstreth is writable", Read(MINSTRETH), 9u);
  tb::Group("mcycle / minstret / mcountinhibit");

  // ---------------- custom performance counters ----------------
  Access(MHPM3, CSR_OP_RW, 0u, true);
  Access(MHPM4, CSR_OP_RW, 0u, true);
  Access(MHPM5, CSR_OP_RW, 0u, true);
  Access(MHPM6, CSR_OP_RW, 0u, true);
  for (int i = 0; i < 3; ++i) {
    dut.stall_i = 1;
    dut.branch_i = 1;
    dut.branch_taken_i = (i == 0) ? 1 : 0;
    dut.mem_access_i = 1;
    dut.eval();
    Tick();
    Idle();
    dut.eval();
  }
  tb::CheckEq<uint32_t>("mhpmcounter3 counts stalls", Read(MHPM3), 3u);
  tb::CheckEq<uint32_t>("mhpmcounter4 counts branches", Read(MHPM4), 3u);
  tb::CheckEq<uint32_t>("mhpmcounter5 counts taken branches", Read(MHPM5), 1u);
  tb::CheckEq<uint32_t>("mhpmcounter6 counts memory accesses", Read(MHPM6), 3u);
  tb::Group("custom performance counters");

  return tb::Report("csr_unit");
}
