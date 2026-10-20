// mc_pingpong.c — a token passed round the ring of harts.
//
// Hart h waits for token == h, increments a shared counter with a plain
// load and store (safe: only the token holder touches it), records what it
// saw, and passes the token on. The counter and token lines migrate from
// cache to cache every step: modified lines move between the P-cores by
// BusRdX, and every E-core write-through invalidates whoever held them.
//
// Checks: every hart sees the counter advance by exactly NHARTS between its
// turns, and the final count is ROUNDS * NHARTS.
#include "soc.h"

#define ROUNDS 150

static volatile uint32_t token;
static volatile uint32_t counter;
static uint32_t seen[NHARTS][ROUNDS];

int main(int h) {
  for (int r = 0; r < ROUNDS; ++r) {
    while (token != (uint32_t)h) {
    }
    const uint32_t c = counter;
    seen[h][r] = c;
    counter = c + 1;
    token = (uint32_t)(h + 1 == NHARTS ? 0 : h + 1);
  }
  mc_barrier(h);
  for (int r = 0; r < ROUNDS; ++r) {
    if (seen[h][r] != (uint32_t)(r * NHARTS + h)) return 1;
  }
  if (h == 0 && counter != ROUNDS * NHARTS) return 2;
  return 0;
}
