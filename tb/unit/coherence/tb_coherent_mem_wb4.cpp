// UNIT-TOP: coherent_mem
// UNIT-RTL: rtl/power/clock_gate.sv rtl/cache/cache_pkg.sv rtl/cache/sram_sp.sv rtl/cache/l1_dcache.sv rtl/cache/l1_pair.sv rtl/cache/l2_cache.sv rtl/coherence/snoop_bus.sv rtl/coherence/coherent_mem.sv
// UNIT-VFLAGS: -GL2_SETS=4 -CFLAGS -DCOH_L2_SETS=4 -GNUM_WB=4 -GNUM_WT=0 -GWB_SETS=4 -CFLAGS -DCOH_NUM_WB=4 -CFLAGS -DCOH_NUM_WT=0 -CFLAGS -DCOH_WB_SETS=4
// ============================================================================
// tb_coherent_mem_wb4.cpp — MSI coherence among four write-back L1s.
//
// No write-through caches at all, so every store needs ownership: modified
// lines move from cache to cache (BusRdX forwarding) and are flushed to
// memory and shared (BusRd) far more often than in the mixed system. Four
// sets per L1 and a 16-line L2 keep evictions and back-invalidations racing
// those transfers.
// ============================================================================
#include "coh_harness.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  std::printf("tb_coherent_mem_wb4: %d write-back L1s, 4 sets each\n", COH_NUM_WB);
  const std::vector<uint32_t> pool = coh::ConflictPool(0x00010000u, 4, 6, 128);
  coh::RandomRun("wb4, zero latency", 31, false, 0, 300000, pool, 70);
  coh::RandomRun("wb4, 0-7 cycle memory", 32, true, 7, 400000, pool, 70);
  coh::RandomRun("wb4, slow cores + flushes", 33, true, 3, 400000, pool, 70, {2, 0, 4, 1}, 300);
  return tb::Report("coherent_mem_wb4");
}
