// ============================================================================
// vl_bits.h — bit-field access to Verilated ports of any width.
//
// Verilator maps a port to uint8/16/32/64 up to 64 bits and to VlWide<N>
// beyond that, so the C++ type of a packed per-core array such as
// `logic [N-1:0][31:0] addr` changes with N. These helpers read and write a
// field by bit position whatever the underlying type is, which is what lets
// one harness drive a 1-core and a 4-core build of the same design.
// ============================================================================
#ifndef VL_BITS_H
#define VL_BITS_H

#include <algorithm>
#include <cstdint>
#include <type_traits>

#include "verilated.h"

namespace vlb {

// Reads `width` (<= 64) bits starting at bit `lsb`.
template <typename T>
inline uint64_t Get(const T& v, int lsb, int width) {
  if constexpr (std::is_integral_v<T>) {
    const uint64_t x = static_cast<uint64_t>(v) >> lsb;
    return width >= 64 ? x : (x & ((uint64_t{1} << width) - 1));
  } else {
    uint64_t r = 0;
    int b = 0;
    while (b < width) {
      const int bit = lsb + b;
      const int off = bit & 31;
      const int take = std::min(32 - off, width - b);
      const uint64_t mask = take == 32 ? 0xFFFFFFFFull : ((uint64_t{1} << take) - 1);
      r |= ((static_cast<uint64_t>(v[bit >> 5]) >> off) & mask) << b;
      b += take;
    }
    return r;
  }
}

// Writes `width` (<= 64) bits starting at bit `lsb`.
template <typename T>
inline void Set(T& v, int lsb, int width, uint64_t val) {
  if constexpr (std::is_integral_v<T>) {
    const uint64_t mask = (width >= 64 ? ~uint64_t{0} : ((uint64_t{1} << width) - 1)) << lsb;
    uint64_t x = static_cast<uint64_t>(v);
    x = (x & ~mask) | ((val << lsb) & mask);
    v = static_cast<T>(x);
  } else {
    int b = 0;
    while (b < width) {
      const int bit = lsb + b;
      const int off = bit & 31;
      const int take = std::min(32 - off, width - b);
      const uint32_t mask = take == 32 ? 0xFFFFFFFFu : (((1u << take) - 1) << off);
      const uint32_t chunk = static_cast<uint32_t>((val >> b) << off);
      v[bit >> 5] = (v[bit >> 5] & ~mask) | (chunk & mask);
      b += take;
    }
  }
}

inline bool Bit(uint64_t v, int i) { return ((v >> i) & 1u) != 0; }

template <typename T>
inline bool Bit(const T& v, int i) { return Get(v, i, 1) != 0; }

}  // namespace vlb

#endif  // VL_BITS_H
