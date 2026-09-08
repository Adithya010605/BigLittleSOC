// ============================================================================
// elf_loader.h — minimal ELF32 little-endian RISC-V loader.
//
// Parses an ELF by hand rather than linking libelf, so the testbench has no
// dependency beyond a C++17 compiler. It provides exactly what the harness
// needs: the loadable segments, the entry point, and the symbol table (so
// `tohost` can be located by name instead of hard-coded to an address that a
// linker-script change would silently invalidate).
// ============================================================================
#ifndef ELF_LOADER_H
#define ELF_LOADER_H

#include <cstdint>
#include <map>
#include <string>
#include <vector>

struct ElfSegment {
  uint32_t paddr = 0;               // physical load address
  std::vector<uint8_t> data;        // file contents for this segment
  uint32_t memsz = 0;               // >= data.size(); the excess is .bss, zeroed
};

class ElfImage {
 public:
  // Loads `path`. On failure returns false and fills `error`.
  bool Load(const std::string& path, std::string* error);

  uint32_t entry() const { return entry_; }
  const std::vector<ElfSegment>& segments() const { return segments_; }

  // Returns true and writes the address if the symbol exists.
  bool Symbol(const std::string& name, uint32_t* addr) const;

  // Name of the function or object containing `addr`, or an empty string.
  // Used to make failure reports readable.
  std::string SymbolAt(uint32_t addr) const;

  const std::string& path() const { return path_; }

 private:
  std::string path_;
  uint32_t entry_ = 0;
  std::vector<ElfSegment> segments_;
  std::map<std::string, uint32_t> symbols_;
  // Sorted (address, size, name) for reverse lookup.
  struct SymSpan {
    uint32_t addr;
    uint32_t size;
    std::string name;
  };
  std::vector<SymSpan> spans_;
};

#endif  // ELF_LOADER_H
