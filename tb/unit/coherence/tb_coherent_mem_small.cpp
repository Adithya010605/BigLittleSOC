// UNIT-TOP: coherent_mem
// UNIT-RTL: rtl/power/clock_gate.sv rtl/cache/cache_pkg.sv rtl/cache/l1_dcache.sv rtl/cache/l2_cache.sv rtl/coherence/snoop_bus.sv rtl/coherence/coherent_mem.sv
// UNIT-VFLAGS: -GL2_SETS=4 -CFLAGS -DCOH_L2_SETS=4 -GWB_SETS=4 -GWT_SETS=4 -CFLAGS -DCOH_WB_SETS=4 -CFLAGS -DCOH_WT_SETS=4
// ============================================================================
// tb_coherent_mem_small.cpp — MSI coherence with 4-set caches.
//
// The same hierarchy as tb_coherent_mem, with every L1 and the L2 cut down to
// four sets: the L1s together hold three times more lines than the L2, so
// almost every L2 fill evicts a line that some L1 still holds (a
// back-invalidation), and almost every eviction races a snoop. The protocol does not depend on the
// geometry; the races it has to survive happen thousands of times more often
// here than at full size.
// ============================================================================
#include "coh_harness.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  std::printf("tb_coherent_mem_small: %d write-back + %d write-through L1s, 4 sets each\n",
              COH_NUM_WB, COH_NUM_WT);
  // One way is 4 x 32 = 128 bytes. 4 sets x 6 tags = 24 lines over caches
  // that hold 8 (write-back) and 4 (write-through) lines.
  const std::vector<uint32_t> pool = coh::ConflictPool(0x00010000u, 4, 6, 128);
  // Wider pool: some lines that only conflict occasionally.
  const std::vector<uint32_t> wide = coh::ConflictPool(0x00010000u, 4, 16, 128);
  coh::RandomRun("small, zero latency", 21, false, 0, 300000, pool, 70);
  coh::RandomRun("small, 1-cycle memory", 22, false, 1, 300000, pool, 70);
  coh::RandomRun("small, 0-7 cycle memory", 23, true, 7, 400000, pool, 70);
  coh::RandomRun("small, wide pool, 0-3 cycles", 24, true, 3, 300000, wide, 50);
  coh::RandomRun("small, slow cores + flushes", 25, true, 3, 400000, pool, 70, {4, 0, 2, 1}, 300);
  return tb::Report("coherent_mem_small");
}
