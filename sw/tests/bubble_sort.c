// bubble_sort.c — the pipeline hazard exercise from the project plan.
//
// Bubble sort is deliberately hazard-heavy: the inner loop is a load, a load,
// a compare, a branch and two stores, with almost every instruction depending
// on the one before it. That makes it a load-use interlock and branch-penalty
// workload rather than an arithmetic one.
#include "uart.h"

#define N 24

static void print_array(const int *a, int n) {
  for (int i = 0; i < n; ++i) {
    uart_put_dec(a[i]);
    uart_putc(i == n - 1 ? '\n' : ' ');
  }
}

static void bubble_sort(int *a, int n) {
  for (int i = 0; i < n - 1; ++i) {
    int swapped = 0;
    for (int j = 0; j < n - 1 - i; ++j) {
      if (a[j] > a[j + 1]) {
        const int t = a[j];
        a[j] = a[j + 1];
        a[j + 1] = t;
        swapped = 1;
      }
    }
    if (!swapped) break;
  }
}

int main(void) {
  // A fixed pseudo-random permutation with duplicates and negatives, so the
  // comparison path sees both signs and equal elements.
  int a[N] = {42, -7, 19, 0, 88, -1, 19, 5, -100, 63, 7, 7,
              -42, 91, 12, -63, 31, 0, 55, -19, 74, 26, -88, 3};
  const int expected[N] = {-100, -88, -63, -42, -19, -7, -1, 0, 0, 3, 5, 7,
                           7, 12, 19, 19, 26, 31, 42, 55, 63, 74, 88, 91};

  uart_puts("unsorted: ");
  print_array(a, N);

  bubble_sort(a, N);

  uart_puts("sorted:   ");
  print_array(a, N);

  for (int i = 0; i < N; ++i) {
    if (a[i] != expected[i]) {
      uart_puts("bubble_sort: MISMATCH\n");
      return 1;
    }
  }
  // Sortedness is implied by matching `expected`, but checking it directly
  // means the test still means something if `expected` is ever edited.
  for (int i = 0; i < N - 1; ++i) {
    if (a[i] > a[i + 1]) {
      uart_puts("bubble_sort: NOT SORTED\n");
      return 2;
    }
  }
  uart_puts("bubble_sort: OK\n");
  return 0;
}
