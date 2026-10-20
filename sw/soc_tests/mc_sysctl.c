// mc_sysctl.c — the system-control block from software.
//
// Checks what a program can see of the hardware it runs on:
//   * the ID and configuration registers;
//   * the interconnect's QoS registers, written and read back;
//   * the performance counters: a pass over a buffer larger than an L1 must
//     raise this hart's L1D miss count, a second pass over a small buffer
//     must hit, the L2 and interconnect counters must move, and the clear
//     bit must zero them.
// Hart 0 does the register work; the others idle at the barrier.
#include "soc.h"

#define SYSCTL 0x12000000u
#define REG(off) (*(volatile uint32_t*)(SYSCTL + (off)))

#define ID            0x000
#define CONFIG        0x004
#define CTRL          0x008
#define QOS_PRIO      0x010
#define STARVE_LIMIT  0x014
#define L1_HITS(c)    (0x100 + 8 * (c))
#define L1_MISSES(c)  (0x104 + 8 * (c))
#define L2_HITS       0x200
#define L2_MISSES     0x204
#define FAB_GRANTS(m) (0x300 + 8 * (m))

#define BIG_WORDS (32 * 1024 / 4)   // 32 KB: twice the P-core L1D
// volatile: the stores are the point, and nothing reads them back.
static volatile uint32_t big[BIG_WORDS] __attribute__((aligned(32)));
static volatile uint32_t small[64] __attribute__((aligned(32)));

static int checks(void) {
  if (REG(ID) != 0x534F4331u) return 1;
  const uint32_t cfg = REG(CONFIG);
  if ((cfg & 0xFF) != NUM_P || ((cfg >> 8) & 0xFF) != NHARTS - NUM_P || ((cfg >> 16) & 0xFF) != 4) return 2;

  // QoS: reset values (CPU 2, debug 0, A 1, B 3), then a new setting.
  if (REG(QOS_PRIO) != (2u | (0u << 2) | (1u << 4) | (3u << 6))) return 3;
  if (REG(STARVE_LIMIT) != 16) return 4;
  REG(QOS_PRIO) = 3u | (1u << 2) | (2u << 4) | (0u << 6);
  REG(STARVE_LIMIT) = 24;
  if (REG(QOS_PRIO) != (3u | (1u << 2) | (2u << 4))) return 5;
  if (REG(STARVE_LIMIT) != 24) return 6;
  REG(QOS_PRIO) = 2u | (0u << 2) | (1u << 4) | (3u << 6);   // restore
  REG(STARVE_LIMIT) = 16;

  // Counters: clear, stream through 32 KB, then re-read a small buffer.
  REG(CTRL) = 1;
  if (REG(L1_MISSES(0)) > 4) return 7;            // only the clear's own traffic
  for (int i = 0; i < BIG_WORDS; i += 8) big[i] = (uint32_t)i;
  const uint32_t miss_big = REG(L1_MISSES(0));
  if (miss_big < BIG_WORDS / 8) return 8;         // at least one miss per line
  for (int i = 0; i < 64; ++i) small[i] = (uint32_t)i;
  const uint32_t hits_before = REG(L1_HITS(0));
  const uint32_t miss_before = REG(L1_MISSES(0));
  uint32_t sum = 0;
  for (int i = 0; i < 64; ++i) sum += small[i];
  if (sum != 64 * 63 / 2) return 9;
  if (REG(L1_HITS(0)) - hits_before < 64) return 10;      // all hits
  if (REG(L1_MISSES(0)) - miss_before > 2) return 11;
  if (REG(L2_MISSES) == 0 || REG(L2_HITS) + REG(L2_MISSES) == 0) return 12;
  if (REG(FAB_GRANTS(0)) == 0) return 13;          // the CPU cluster used the interconnect
  REG(CTRL) = 1;
  if (REG(L2_MISSES) > 4) return 14;
  return 0;
}

int main(int h) {
  int rc = 0;
  if (h == 0) rc = checks();
  mc_barrier(h);
  return rc;
}
