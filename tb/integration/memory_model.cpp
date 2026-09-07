#include "memory_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

// ---------------------------------------------------------------------------
// WaitConfig
// ---------------------------------------------------------------------------
bool WaitConfig::Parse(const std::string& spec, WaitConfig* out,
                       std::string* error) {
  if (spec.rfind("random", 0) == 0) {
    out->mode = kRandom;
    out->seed = 1;
    const size_t colon = spec.find(':');
    if (colon != std::string::npos) {
      char* end = nullptr;
      const unsigned long long v =
          std::strtoull(spec.c_str() + colon + 1, &end, 0);
      if (end == spec.c_str() + colon + 1 || *end != '\0') {
        *error = "malformed seed in --waits=" + spec;
        return false;
      }
      out->seed = v ? v : 1;
    }
    return true;
  }
  char* end = nullptr;
  const unsigned long v = std::strtoul(spec.c_str(), &end, 0);
  if (end == spec.c_str() || *end != '\0') {
    *error = "--waits must be a number or random[:SEED], got '" + spec + "'";
    return false;
  }
  out->mode = kFixed;
  out->fixed = static_cast<uint32_t>(v);
  return true;
}

std::string WaitConfig::Describe() const {
  char buf[64];
  if (mode == kRandom) {
    std::snprintf(buf, sizeof(buf), "random(seed=%llu,max=%u)",
                  static_cast<unsigned long long>(seed), max_random);
  } else {
    std::snprintf(buf, sizeof(buf), "fixed(%u)", fixed);
  }
  return std::string(buf);
}

// ---------------------------------------------------------------------------
// MemoryModel
// ---------------------------------------------------------------------------
MemoryModel::MemoryModel() : mem_(kRamSize / 4, 0u) {
  SetWaits(WaitConfig{});
}

void MemoryModel::SetWaits(const WaitConfig& cfg) {
  waits_ = cfg;
  // Give the two ports independent random streams so that instruction and
  // data latency vary independently, which is what shakes out ordering bugs
  // between fetch and load/store.
  iport_ = Port{};
  dport_ = Port{};
  iport_.rng = cfg.seed * 6364136223846793005ULL + 1442695040888963407ULL;
  dport_.rng = cfg.seed * 2862933555777941757ULL + 3037000493ULL;
  DrawDelays(&iport_);
  DrawDelays(&dport_);
}

uint32_t MemoryModel::NextRandom(Port* p) const {
  p->rng ^= p->rng >> 12;
  p->rng ^= p->rng << 25;
  p->rng ^= p->rng >> 27;
  return static_cast<uint32_t>((p->rng * 0x2545F4914F6CDD1DULL) >> 33);
}

void MemoryModel::DrawDelays(Port* p) {
  if (waits_.mode == WaitConfig::kRandom) {
    p->gnt_wait = static_cast<int>(NextRandom(p) % (waits_.max_random + 1));
    p->rv_wait = static_cast<int>(NextRandom(p) % (waits_.max_random + 1));
  } else {
    p->gnt_wait = static_cast<int>(waits_.fixed);
    p->rv_wait = static_cast<int>(waits_.fixed);
  }
}

bool MemoryModel::LoadElf(const ElfImage& elf, std::string* error) {
  for (const ElfSegment& seg : elf.segments()) {
    if (seg.paddr + seg.memsz > kRamSize) {
      char buf[256];
      std::snprintf(buf, sizeof(buf),
                    "segment at 0x%08x size 0x%x runs past the end of the "
                    "192 KiB memory (0x%x)",
                    seg.paddr, seg.memsz, kRamSize);
      *error = buf;
      return false;
    }
    if (seg.paddr & 3u) {
      *error = "segment is not word-aligned";
      return false;
    }
    // Loadable bytes first...
    for (size_t i = 0; i < seg.data.size(); ++i) {
      const uint32_t a = seg.paddr + static_cast<uint32_t>(i);
      uint32_t& w = mem_[a >> 2];
      const int sh = 8 * static_cast<int>(a & 3u);
      w = (w & ~(0xFFu << sh)) | (static_cast<uint32_t>(seg.data[i]) << sh);
    }
    // ...then the .bss tail, which has no file contents.
    for (uint32_t i = static_cast<uint32_t>(seg.data.size()); i < seg.memsz; ++i) {
      const uint32_t a = seg.paddr + i;
      uint32_t& w = mem_[a >> 2];
      const int sh = 8 * static_cast<int>(a & 3u);
      w &= ~(0xFFu << sh);
    }
  }

  uint32_t th = 0;
  if (elf.Symbol("tohost", &th)) {
    tohost_known_ = true;
    tohost_addr_ = th;
  } else {
    *error =
        "the ELF has no `tohost` symbol, so the simulation would have no way "
        "to terminate; check the linker script";
    return false;
  }
  return true;
}

uint32_t MemoryModel::ReadWordBackdoor(uint32_t addr) const {
  if (addr + 3 >= kRamSize) return 0u;
  return mem_[addr >> 2];
}

void MemoryModel::WriteWordBackdoor(uint32_t addr, uint32_t value) {
  if (addr + 3 >= kRamSize) return;
  mem_[addr >> 2] = value;
}

// ---------------------------------------------------------------------------
void MemoryModel::ReadFor(const MemRequest& q, uint32_t* rdata,
                          bool* err) const {
  *rdata = 0;
  *err = false;
  const uint32_t addr = q.addr & ~3u;

  if (addr < kRamSize) {
    *rdata = mem_[addr >> 2];
    return;
  }
  if (addr == kUartData) {
    *rdata = 0u;
    return;
  }
  if (addr == kUartStatus) {
    // Bit 0 is "transmitter busy". This model drains instantly, so it always
    // reads ready; the polling loop in uart.c therefore exercises the load
    // path against a peripheral without adding nondeterministic delay.
    *rdata = 0u;
    return;
  }
  // Unmapped. This is what drives the core's access-fault exceptions.
  *err = true;
}

void MemoryModel::CommitAccess(const MemRequest& q, bool is_instr) {
  uint32_t rdata = 0;
  bool err = false;
  ReadFor(q, &rdata, &err);

  if (is_instr) {
    ++instr_fetches_;
    return;   // the instruction port never writes
  }

  if (!q.we) {
    ++data_reads_;
    return;
  }

  ++data_writes_;
  if (err) return;   // a faulting store changes nothing

  const uint32_t addr = q.addr & ~3u;

  if (addr == kUartData) {
    // Byte-wide transmitter: the enabled lane carries the character.
    for (int lane = 0; lane < 4; ++lane) {
      if (q.be & (1u << lane)) {
        uart_out_.push_back(static_cast<char>((q.wdata >> (8 * lane)) & 0xFFu));
        break;
      }
    }
    return;
  }
  if (addr == kUartStatus) {
    return;   // status is read-only; writes are dropped
  }

  if (addr < kRamSize) {
    uint32_t w = mem_[addr >> 2];
    for (int lane = 0; lane < 4; ++lane) {
      if (q.be & (1u << lane)) {
        const uint32_t byte = (q.wdata >> (8 * lane)) & 0xFFu;
        w = (w & ~(0xFFu << (8 * lane))) | (byte << (8 * lane));
      }
    }
    mem_[addr >> 2] = w;

    // The exit mailbox. riscv-tests convention: bit 0 signals completion and
    // the remaining bits carry the code, so 1 means pass and (n<<1)|1 means
    // failing test n.
    if (tohost_known_ && addr == (tohost_addr_ & ~3u) && w != 0u) {
      tohost_raw_ = w;
      exit_code_ = w >> 1;
      exited_ = true;
    }
  }
}

// ---------------------------------------------------------------------------
MemResponse MemoryModel::Evaluate(const Port& p, const MemRequest& q) const {
  MemResponse r;
  if (p.phase == kAwaitRvalid) {
    // A response is outstanding: no new request can be granted, and rvalid
    // fires once the drawn latency has elapsed.
    if (p.rv_wait == 0) {
      r.rvalid = true;
      r.rdata = p.held_rdata;
      r.err = p.held_err;
    }
    return r;
  }
  if (!q.req) return r;
  if (p.gnt_wait != 0) return r;   // still counting down to the grant

  r.gnt = true;
  if (p.rv_wait == 0) {
    // Same-cycle response: what a cache hit looks like.
    ReadFor(q, &r.rdata, &r.err);
    r.rvalid = true;
  }
  return r;
}

void MemoryModel::Tick(Port* p, const MemRequest& q, bool is_instr) {
  if (p->phase == kAwaitRvalid) {
    if (p->rv_wait == 0) {
      p->phase = kIdle;
      DrawDelays(p);
    } else {
      --p->rv_wait;
    }
    return;
  }
  if (!q.req) return;
  if (p->gnt_wait > 0) {
    --p->gnt_wait;
    return;
  }

  // Granted this cycle: the request is accepted exactly once, here.
  CommitAccess(q, is_instr);
  ReadFor(q, &p->held_rdata, &p->held_err);

  if (p->rv_wait == 0) {
    p->phase = kIdle;
    DrawDelays(p);
  } else {
    p->phase = kAwaitRvalid;
    --p->rv_wait;
  }
}

MemResponse MemoryModel::EvaluateInstr(const MemRequest& q) const {
  return Evaluate(iport_, q);
}
MemResponse MemoryModel::EvaluateData(const MemRequest& q) const {
  return Evaluate(dport_, q);
}
void MemoryModel::TickInstr(const MemRequest& q) { Tick(&iport_, q, true); }
void MemoryModel::TickData(const MemRequest& q) { Tick(&dport_, q, false); }
