// mc_lock.c — mutual exclusion from plain loads and stores.
//
// Every hart takes a bakery lock LOCKS times. Inside the critical section it
// checks that the four words of a shared record agree (a torn record means
// two harts were inside at once, or a stale copy was read), rewrites them
// with a new value one word at a time, and increments a shared counter.
//
// The bakery algorithm is only correct on a sequentially consistent memory,
// so this passing is a statement about the whole memory system, not just
// about single lines.
#include "soc.h"

#define LOCKS 40

static mc_bakery_t lock;
static volatile uint32_t record[4];
static volatile uint32_t counter;
static volatile uint32_t inside;

int main(int h) {
  for (int i = 0; i < LOCKS; ++i) {
    mc_lock(&lock, h);
    if (inside != 0) return 1;
    inside = 1;
    const uint32_t v = record[0];
    if (record[1] != v || record[2] != v || record[3] != v) return 2;
    const uint32_t nv = v * 1103515245u + 12345u + (uint32_t)h;
    for (int w = 0; w < 4; ++w) record[w] = nv;
    counter = counter + 1;
    inside = 0;
    mc_unlock(&lock, h);
  }
  mc_barrier(h);
  if (h == 0 && counter != LOCKS * NHARTS) return 3;
  return 0;
}
