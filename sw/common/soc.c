// soc.c — storage shared by the helpers in soc.h.
#include "soc.h"

volatile uint32_t mc_barrier_count[NHARTS];
