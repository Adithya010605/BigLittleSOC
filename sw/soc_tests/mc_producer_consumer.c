// mc_producer_consumer.c — producer/consumer across core types.
//
// Two single-producer single-consumer ring buffers run at once:
//   hart 0 (P-core) -> hart 2 (E-core)
//   hart 3 (E-core) -> hart 1 (P-core)
// Each queue's head is written only by its producer and its tail only by its
// consumer (Lamport's lock-free queue), so no atomics are needed.
//
// Then a bulk hand-off in each direction: the producer fills a 2 KB block,
// raises a flag, and the consumer checks every word. From a P-core the block
// sits modified in its L1 and reaches the consumer through flushes on
// snooped BusRd; from an E-core it is already in memory.
#include "soc.h"

#define QLEN 8
#define ITEMS 400
#define BLOCK_WORDS 512

typedef struct {
  volatile uint32_t head;          // written by the producer
  uint32_t pad0[7];                // keep head and tail on different lines
  volatile uint32_t tail;          // written by the consumer
  uint32_t pad1[7];
  volatile uint32_t slot[QLEN];
} queue_t;

static queue_t q[2];
static uint32_t block[2][BLOCK_WORDS];
static volatile uint32_t block_ready[2];

static uint32_t value(int qi, uint32_t i) { return (i * 2654435761u) ^ (0x51ED0000u + qi); }

static void produce(queue_t* qu, int qi) {
  for (uint32_t i = 0; i < ITEMS; ++i) {
    while (qu->head - qu->tail == QLEN) {
    }
    qu->slot[qu->head % QLEN] = value(qi, i);
    qu->head = qu->head + 1;
  }
  for (int w = 0; w < BLOCK_WORDS; ++w) block[qi][w] = value(qi, 1000u + (uint32_t)w);
  block_ready[qi] = 1;
}

static int consume(queue_t* qu, int qi) {
  for (uint32_t i = 0; i < ITEMS; ++i) {
    while (qu->head == qu->tail) {
    }
    if (qu->slot[qu->tail % QLEN] != value(qi, i)) return 10 + qi;
    qu->tail = qu->tail + 1;
  }
  while (!block_ready[qi]) {
  }
  for (int w = 0; w < BLOCK_WORDS; ++w)
    if (block[qi][w] != value(qi, 1000u + (uint32_t)w)) return 20 + qi;
  return 0;
}

int main(int h) {
  int rc = 0;
  if (NHARTS < 4) return h == 0 ? 99 : 0;   // needs two P- and two E-cores
  switch (h) {
    case 0: produce(&q[0], 0); break;
    case 2: rc = consume(&q[0], 0); break;
    case 3: produce(&q[1], 1); break;
    case 1: rc = consume(&q[1], 1); break;
    default: break;
  }
  return rc;
}
