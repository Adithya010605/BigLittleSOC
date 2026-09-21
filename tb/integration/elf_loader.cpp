#include "elf_loader.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>

namespace {

// ---- ELF32 structures, little-endian, as laid out in the file --------------
constexpr uint32_t kPtLoad = 1;
constexpr uint32_t kShtSymtab = 2;

uint16_t Rd16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}
uint32_t Rd32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

}  // namespace

bool ElfImage::Load(const std::string& path, std::string* error) {
  path_ = path;
  std::ifstream f(path, std::ios::binary);
  if (!f) {
    *error = "cannot open " + path;
    return false;
  }
  std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                           std::istreambuf_iterator<char>());
  if (buf.size() < 52) {
    *error = path + ": too small to be an ELF file";
    return false;
  }

  // ---- header checks ----
  if (std::memcmp(buf.data(), "\x7F" "ELF", 4) != 0) {
    *error = path + ": not an ELF file";
    return false;
  }
  if (buf[4] != 1) {
    *error = path + ": not ELF32 (this core is RV32)";
    return false;
  }
  if (buf[5] != 1) {
    *error = path + ": not little-endian";
    return false;
  }
  const uint16_t e_machine = Rd16(&buf[18]);
  if (e_machine != 243) {  // EM_RISCV
    *error = path + ": e_machine is not EM_RISCV";
    return false;
  }

  entry_ = Rd32(&buf[24]);
  const uint32_t e_phoff = Rd32(&buf[28]);
  const uint32_t e_shoff = Rd32(&buf[32]);
  const uint16_t e_phentsize = Rd16(&buf[42]);
  const uint16_t e_phnum = Rd16(&buf[44]);
  const uint16_t e_shentsize = Rd16(&buf[46]);
  const uint16_t e_shnum = Rd16(&buf[48]);

  // ---- program headers: the loadable image ----
  for (uint16_t i = 0; i < e_phnum; ++i) {
    const size_t off = e_phoff + static_cast<size_t>(i) * e_phentsize;
    if (off + 32 > buf.size()) {
      *error = path + ": program header table runs past end of file";
      return false;
    }
    const uint8_t* ph = &buf[off];
    if (Rd32(ph + 0) != kPtLoad) continue;

    const uint32_t p_offset = Rd32(ph + 4);
    const uint32_t p_paddr = Rd32(ph + 12);
    const uint32_t p_filesz = Rd32(ph + 16);
    const uint32_t p_memsz = Rd32(ph + 20);
    if (static_cast<size_t>(p_offset) + p_filesz > buf.size()) {
      *error = path + ": PT_LOAD segment runs past end of file";
      return false;
    }
    ElfSegment seg;
    seg.paddr = p_paddr;
    seg.memsz = p_memsz;
    seg.data.assign(buf.begin() + p_offset, buf.begin() + p_offset + p_filesz);
    segments_.push_back(std::move(seg));
  }
  if (segments_.empty()) {
    *error = path + ": no PT_LOAD segments";
    return false;
  }

  // ---- section headers: the symbol table ----
  for (uint16_t i = 0; i < e_shnum; ++i) {
    const size_t off = e_shoff + static_cast<size_t>(i) * e_shentsize;
    if (off + 40 > buf.size()) break;
    const uint8_t* sh = &buf[off];
    if (Rd32(sh + 4) != kShtSymtab) continue;

    const uint32_t sh_offset = Rd32(sh + 16);
    const uint32_t sh_size = Rd32(sh + 20);
    const uint32_t sh_link = Rd32(sh + 24);   // index of the string table
    const uint32_t sh_entsize = Rd32(sh + 36);
    if (sh_entsize == 0) continue;

    // Locate the associated string table.
    const size_t str_off_hdr = e_shoff + static_cast<size_t>(sh_link) * e_shentsize;
    if (str_off_hdr + 40 > buf.size()) continue;
    const uint32_t str_off = Rd32(&buf[str_off_hdr] + 16);
    const uint32_t str_size = Rd32(&buf[str_off_hdr] + 20);
    if (static_cast<size_t>(str_off) + str_size > buf.size()) continue;

    for (uint32_t s = 0; s + sh_entsize <= sh_size; s += sh_entsize) {
      const size_t so = sh_offset + s;
      if (so + 16 > buf.size()) break;
      const uint8_t* sym = &buf[so];
      const uint32_t st_name = Rd32(sym + 0);
      const uint32_t st_value = Rd32(sym + 4);
      const uint32_t st_size = Rd32(sym + 8);
      if (st_name == 0 || st_name >= str_size) continue;
      const char* nm = reinterpret_cast<const char*>(&buf[str_off + st_name]);
      const std::string name(nm);
      if (name.empty()) continue;
      symbols_.emplace(name, st_value);
      spans_.push_back({st_value, st_size, name});
    }
  }

  std::sort(spans_.begin(), spans_.end(),
            [](const SymSpan& a, const SymSpan& b) { return a.addr < b.addr; });
  return true;
}

bool ElfImage::Symbol(const std::string& name, uint32_t* addr) const {
  auto it = symbols_.find(name);
  if (it == symbols_.end()) return false;
  *addr = it->second;
  return true;
}

std::string ElfImage::SymbolAt(uint32_t addr) const {
  // Last symbol whose address is <= addr, preferring one whose size covers it.
  auto it = std::upper_bound(
      spans_.begin(), spans_.end(), addr,
      [](uint32_t a, const SymSpan& s) { return a < s.addr; });
  if (it == spans_.begin()) return std::string();
  --it;
  // Walk back over zero-sized symbols (labels) at the same address to prefer
  // a sized one, which is usually the enclosing function.
  auto best = it;
  while (best != spans_.begin() && best->size == 0 &&
         (best - 1)->addr == best->addr) {
    --best;
  }
  if (best->size != 0 && addr >= best->addr + best->size) {
    // Past the end of the nearest sized symbol: report it anyway with an
    // offset, since it is still the most useful anchor.
  }
  char buf[256];
  std::snprintf(buf, sizeof(buf), "%s+0x%x", best->name.c_str(),
                addr - best->addr);
  return std::string(buf);
}
