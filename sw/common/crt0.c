// ============================================================================
// crt0.c — the handful of C runtime helpers that freestanding test programs
// need. There is no libc: the build is -nostdlib -ffreestanding, so anything
// the compiler may emit a call to has to exist here.
//
// GCC is entitled to turn a struct copy or an array initialisation into a call
// to memcpy/memset even at -ffreestanding, so these must be present even
// though no test program calls them by name.
// ============================================================================
#include <stddef.h>
#include <stdint.h>

void *memcpy(void *dst, const void *src, size_t n) {
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  while (n--) {
    *d++ = *s++;
  }
  return dst;
}

void *memset(void *dst, int c, size_t n) {
  unsigned char *d = (unsigned char *)dst;
  while (n--) {
    *d++ = (unsigned char)c;
  }
  return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  if (d == s || n == 0) {
    return dst;
  }
  if (d < s) {
    while (n--) {
      *d++ = *s++;
    }
  } else {
    d += n;
    s += n;
    while (n--) {
      *--d = *--s;
    }
  }
  return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *pa = (const unsigned char *)a;
  const unsigned char *pb = (const unsigned char *)b;
  while (n--) {
    if (*pa != *pb) {
      return (int)*pa - (int)*pb;
    }
    ++pa;
    ++pb;
  }
  return 0;
}

size_t strlen(const char *s) {
  const char *p = s;
  while (*p) {
    ++p;
  }
  return (size_t)(p - s);
}
