#!/usr/bin/env python3
# ============================================================================
# mutation_coherence.py — do the coherence tests detect broken coherence?
#
# The companion of mutation_test.sh for the memory system. Each mutation is
# one realistic defect in rtl/cache or rtl/coherence -- a snoop that forgets
# to invalidate, a flush that never reaches memory, a race the RTL stops
# handling. For each, the script rebuilds and runs:
#
#   unit  the coherence unit testbenches (tb/unit/coherence): small geometry
#         first, then full size with the directed MSI scenarios;
#   soc   the 2P+2E SoC on multi-core programs (sw/soc_tests), whose only
#         oracle for racing accesses is the harness's coherence checker, one
#         of them under checked background traffic and one with its UART
#         output compared; then a one-core cached P-core on the directed
#         tests that exercise access faults, self-modifying code and timer
#         interrupts.
#
# Every `kill` mutation must be killed in both columns (the unit column only
# where the block has a unit testbench). A mutation that breaks only
# performance or fairness is marked `perf`: the unit testbench must kill it
# (it checks every arbitration decision and replacement choice exactly); the
# SoC column is not run for it.
#
# Usage: mutation_soc.py [name ...]   (after `make soc-tests` and
#                                      `make CACHED=1 CORE=p_core asm-tests`)
# ============================================================================
import os
import shutil
import subprocess
import sys

ROOT = os.environ.get("ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.environ.get("BUILD") or os.path.join(ROOT, "build")
VERILATOR = os.environ.get("VERILATOR", "verilator")
WORK = os.path.join(BUILD, "mutation_soc")

L1 = "cache/l1_dcache.sv"
BUS = "coherence/snoop_bus.sv"
XBAR = "interconnect/qos_xbar.sv"
SRAM = "periph/sram_ctrl.sv"
IRQ = "periph/irq_ctrl.sv"
SYSCTL = "periph/sysctl.sv"
UART = "periph/uart.sv"

# name, expect, file (under rtl/), search, replace. The unit testbench is
# chosen by the file: the coherence harnesses for rtl/cache and
# rtl/coherence, the crossbar's for rtl/interconnect, none for rtl/periph.
MUTATIONS = [
    # ---- snoop response ---------------------------------------------------
    ("snoop_inv_keeps_S", "kill", L1,
     "      if (snoop_type_i == SNP_INV) begin\n        snp_upd  = 1'b1;",
     "      if (snoop_type_i == SNP_INV && state_q[s_way][s_idx] == MSI_M) begin\n        snp_upd  = 1'b1;"),
    ("snoop_rd_keeps_M", "kill", L1,
     "        snp_next = MSI_S;", "        snp_next = MSI_M;"),
    ("snoop_inv_leaves_S", "kill", L1,
     "        snp_upd  = 1'b1;\n        snp_next = MSI_I;\n      end else if",
     "        snp_upd  = 1'b1;\n        snp_next = MSI_S;\n      end else if"),
    ("core_ignores_snoop_cycle", "kill", L1,
     "        if (core_req_i && !snoop_valid_i) begin", "        if (core_req_i) begin"),
    # ---- requester side ---------------------------------------------------
    ("store_hit_on_S", "kill", L1,
     "            if (c_hit && state_q[c_way][c_idx] == MSI_M) begin",
     "            if (c_hit) begin"),
    ("upgrade_ignores_lost_copy", "kill", L1,
     "                        state_q[fill_way_q][rq_idx] == MSI_S &&",
     "                        state_q[fill_way_q][rq_idx] != MSI_M &&"),
    ("writeback_not_rechecked", "kill", L1,
     "        if (state_q[fill_way_q][rq_idx] != MSI_M) begin\n          // A snoop flushed",
     "        if (1'b0) begin\n          // A snoop flushed"),
    ("wt_store_skips_own_copy", "kill", L1,
     "          if (!bus_err_i && r_hit) begin", "          if (1'b0) begin"),
    ("uncached_error_dropped", "kill", L1,
     "          core_err_o    = bus_err_i;\n          core_rdata_o  = line_word(bus_rdata_i, rq_slot);",
     "          core_err_o    = 1'b0;\n          core_rdata_o  = line_word(bus_rdata_i, rq_slot);"),
    # ---- bus, L2 and snoop filter -------------------------------------------
    ("filter_never_snoops", "kill", BUS,
     "  assign hit_targets = lk_sharers & ~m_bit;", "  assign hit_targets = '0;"),
    ("filter_misses_reader", "kill", BUS,
     "          BUS_RD:   l2_wsharers = sharers_q | m_bit;", "          BUS_RD:   l2_wsharers = sharers_q;"),
    ("fill_records_no_sharer", "kill", BUS,
     "            l2_wsharers = m_bit;          // BUS_RD / BUS_RDX",
     "            l2_wsharers = '0;             // BUS_RD / BUS_RDX"),
    ("owner_data_ignored", "kill", BUS,
     "  assign base        = dirty_q ? line_q : lk_data;", "  assign base        = lk_data;"),
    ("flush_not_into_l2", "kill", BUS,
     "        l2_wdata_en = dirty_q;", "        l2_wdata_en = 1'b0;"),
    ("wr_not_merged", "kill", BUS,
     "            l2_wdata    = line_merge(base, wdata_q, be_q);", "            l2_wdata    = base;"),
    ("no_back_invalidation", "kill", BUS,
     "          if (vc_valid && vc_sharers != '0) bs_d = B_BINV;",
     "          if (1'b0) bs_d = B_BINV;"),
    ("back_invalidation_drops_dirty", "kill", BUS,
     "          vdirty_q <= 1'b1;\n          vline_q  <= snp_line;",
     "          vdirty_q <= 1'b1;"),
    ("dirty_victim_not_written", "kill", BUS,
     "          else if (vc_valid && vc_dirty)    bs_d = B_VWB;",
     "          else if (1'b0)                    bs_d = B_VWB;"),
    # ---- performance only: killed by the directed tests that measure it ----
    ("victim_ignores_invalid_way", "perf", L1,
     "  assign c_victim = c_inv_found ? c_inv_way : c_lru_way;", "  assign c_victim = c_lru_way;"),
    ("lru_never_updated", "perf", L1,
     "        lru_q[lru_idx] <= ~lru_used[0];", "        lru_q[lru_idx] <= lru_q[lru_idx];"),
    # ---- interconnect ---------------------------------------------------------
    ("xbar_response_misrouted", "kill", XBAR,
     "          rsp_rdata_q[owner_q[j]]  <= s_rsp_rdata_i[j];", "          rsp_rdata_q[owner_q[j]]  <= s_rsp_rdata_i[0];"),
    ("xbar_decode_off_by_one", "kill", XBAR,
     "m_req_addr_i[i] < SLV_LIMIT[j]", "m_req_addr_i[i] <= SLV_LIMIT[j]"),
    ("xbar_strobes_dropped", "kill", XBAR,
     "          sreq_wstrb_q[j] <= m_req_wstrb_i[sgnt_id[j]];", "          sreq_wstrb_q[j] <= '1;"),
    ("xbar_decode_error_silent", "kill", XBAR,
     "          rsp_err_q[i]   <= 1'b1;", "          rsp_err_q[i]   <= 1'b0;"),
    ("xbar_priority_ignored", "perf", XBAR,
     "      for (int i = 0; i < int'(NM); i++) top[i] = cand[i] && qos_prio_i[i] == best;",
     "      for (int i = 0; i < int'(NM); i++) top[i] = cand[i];"),
    ("xbar_no_anti_starvation", "perf", XBAR,
     "      pick = rr_pick(starving != '0 ? starving : top, rr_q[j]);",
     "      pick = rr_pick(top, rr_q[j]);"),
    ("xbar_round_robin_frozen", "perf", XBAR,
     "          rr_q[j]         <= (int'(sgnt_id[j]) == int'(NM) - 1) ? '0 : sgnt_id[j] + MID_W'(1);",
     "          rr_q[j]         <= rr_q[j];"),
    ("xbar_idle_cycle_between_grants", "perf", XBAR,
     "  assign slave_free = ~busy_q | s_rsp_valid_i;", "  assign slave_free = ~busy_q;"),
    # ---- peripherals (no unit testbench: the system level must catch them) ----
    ("sram_ignores_strobes", "kill", SRAM,
     "line_merge(mem[lidx(req_addr_i)], req_wdata_i, req_wstrb_i)", "req_wdata_i"),
    ("irq_timer_cannot_clear", "kill", IRQ,
     "          8'h4: begin\n            count_q[hid]     <= '0;\n            irq_timer_o[hid] <= 1'b0;",
     "          8'h4: begin\n            count_q[hid]     <= '0;"),
    ("sysctl_miss_counter_dead", "kill", SYSCTL,
     "l1_miss_q[c] <= l1_miss_q[c] + 32'd1;", "l1_miss_q[c] <= l1_miss_q[c];"),
    ("uart_wrong_lane", "kill", UART,
     "    for (int l = 3; l >= 0; l--) if (wbe[l]) tx_byte = wword[8*l +: 8];",
     "    for (int l = 0; l < 4; l++) if (wbe[l]) tx_byte = wword[8*l +: 8];"),
]

UNIT_RTL = ["cache/cache_pkg.sv", "cache/l1_dcache.sv", "cache/l2_cache.sv",
            "coherence/snoop_bus.sv", "coherence/coherent_mem.sv"]
XBAR_UNIT = ("unit/xbar", "interconnect", "tb_qos_xbar.cpp", "qos_xbar",
             ["cache/cache_pkg.sv", "interconnect/qos_xbar.sv"])
UNIT_RUNS = [  # (label, harness, extra verilator flags)
    ("unit/small", "tb_coherent_mem_small.cpp",
     ["-GWB_SETS=4", "-GWT_SETS=4", "-GL2_SETS=4", "-CFLAGS", "-DCOH_WB_SETS=4",
      "-CFLAGS", "-DCOH_WT_SETS=4", "-CFLAGS", "-DCOH_L2_SETS=4"]),
    ("unit/full", "tb_coherent_mem.cpp", []),
]
# (program, extra simulator flags, compare UART with its .expected)
SOC_RUNS = [("mc_hello", [], True), ("mc_sysctl", [], False), ("mc_bus_errors", [], False),
            ("mc_pingpong", [], False),
            ("mc_pingpong", ["--traffic=40"], False), ("mc_lock", [], False),
            ("mc_l2_thrash", [], False), ("mc_stress_s1", [], False), ("mc_stress_s2", [], False),
            ("mc_stress_s3", [], False), ("mc_stress_s4", [], False)]
SOC_PROGRAMS = sorted({r[0] for r in SOC_RUNS})
CACHED_TESTS = ["trap_exceptions", "mem_align", "fence_i", "irq_timer"]   # build/cached_p_core/asm


def first_failure(text):
    for line in text.splitlines():
        if line.startswith("[FAIL]") or "COHERENCE VIOLATION" in line or "Assertion failed" in line \
                or "PROGRAM FAILED" in line or "TIMEOUT" in line:
            return line.strip()[:100]
    lines = [l for l in text.strip().splitlines() if l.strip()]
    return lines[-1][:100] if lines else "?"


def build_and_run(d, label, harness_dir, harness, top, rtl, flags):
    obj = os.path.join(d, "obj_" + label.replace("/", "_"))
    exe = os.path.join(d, label.replace("/", "_"))
    cmd = [VERILATOR, "--cc", "--exe", "--build", "-j", "0", "-Wno-fatal",
           "--Mdir", obj, "--top-module", top] + flags + \
          ["-CFLAGS", "-std=c++17 -O2 -I" + os.path.join(ROOT, "tb/unit"), "-o", exe] + \
          [os.path.join(d, "rtl", f) for f in rtl] + \
          [os.path.join(ROOT, "tb/unit", harness_dir, harness)]
    b = subprocess.run(cmd, capture_output=True, text=True)
    if b.returncode != 0:
        return "BUILD FAIL"
    r = subprocess.run([exe], capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        return "KILLED by %s: %s" % (label, first_failure(r.stdout + r.stderr))
    return None


def run_unit(d, f):
    if f.startswith("periph/"):
        return "(no unit testbench)"
    if f.startswith("interconnect/"):
        label, hdir, harness, top, rtl = XBAR_UNIT
        flags = []
        src = open(os.path.join(ROOT, "tb/unit", hdir, harness)).read()
        for line in src.splitlines():
            if line.startswith("// UNIT-VFLAGS:"):
                flags = line.split(":", 1)[1].split()
        return build_and_run(d, label, hdir, harness, top, rtl, flags) or "SURVIVED"
    for label, harness, flags in UNIT_RUNS:
        res = build_and_run(d, label, "coherence", harness, "coherent_mem", UNIT_RTL, flags)
        if res:
            return res
    return "SURVIVED"


def run_soc(d):
    env = dict(os.environ, BUILD=d, SOC_RTL_ROOT=os.path.join(d, "rtl"), SOC_VFLAGS="-Wno-fatal")
    builds = [("soc_mut_sim", "2", "2"), ("cached_mut_sim", "1", "0")]
    for name, np_, ne in builds:
        b = subprocess.run([os.path.join(ROOT, "scripts/build_soc.sh"), np_, ne, name],
                           capture_output=True, text=True, env=env)
        if b.returncode != 0:
            return "BUILD FAIL (%s)" % name
    runs = []
    for prog, extra, uart in SOC_RUNS:
        label = prog + ("+" + extra[0].lstrip("-") if extra else "")
        runs.append((os.path.join(d, "soc_mut_sim"), os.path.join(BUILD, "soc_2p2e", prog + ".elf"),
                     label, extra, os.path.join(ROOT, "sw/soc_tests", prog + ".expected") if uart else None))
    runs += [(os.path.join(d, "cached_mut_sim"), os.path.join(BUILD, "cached_p_core/asm", t + ".elf"),
              "cached:" + t, [], None) for t in CACHED_TESTS]
    uart_out = os.path.join(d, "uart.txt")
    for sim, elf, label, extra, expected in runs:
        for waits in ("0", "random:7"):
            r = subprocess.run([sim, "--elf=" + elf, "--waits=" + waits, "--max-cycles=4000000",
                                "--uart-out=" + uart_out] + extra,
                               capture_output=True, text=True, timeout=1800)
            if r.returncode != 0:
                return "KILLED by %s@%s: %s" % (label, waits, first_failure(r.stdout + r.stderr))
            if expected and open(uart_out).read() != open(expected).read():
                return "KILLED by %s@%s: UART output differs from %s" % (label, waits,
                                                                        os.path.basename(expected))
    return "SURVIVED"


def main():
    select = set(sys.argv[1:])
    needed = [os.path.join(BUILD, "soc_2p2e", p + ".elf") for p in SOC_PROGRAMS] + \
             [os.path.join(BUILD, "cached_p_core/asm", t + ".elf") for t in CACHED_TESTS]
    for elf in needed:
        if not os.path.exists(elf):
            print("mutation_soc: %s missing; run `make soc-tests` and "
                  "`make CACHED=1 CORE=p_core asm-tests` first" % os.path.relpath(elf, ROOT))
            return 2
    os.makedirs(WORK, exist_ok=True)
    bad = 0
    print("==> SoC mutation testing (%d mutations)" % len(MUTATIONS))
    for name, expect, f, old, new in MUTATIONS:
        if select and name not in select:
            continue
        d = os.path.join(WORK, name)
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(os.path.join(ROOT, "rtl"), os.path.join(d, "rtl"))
        p = os.path.join(d, "rtl", f)
        src = open(p).read()
        if src.count(old) != 1:
            print("  %-28s PATTERN NOT FOUND (%d matches)" % (name, src.count(old)))
            bad += 1
            continue
        open(p, "w").write(src.replace(old, new))
        unit = run_unit(d, f)
        soc = run_soc(d) if expect == "kill" else "(not run: performance only)"
        unit_ok = unit.startswith("KILLED") or (unit == "(no unit testbench)" and expect == "kill")
        ok = unit_ok and (expect != "kill" or soc.startswith("KILLED"))
        bad += 0 if ok else 1
        print("  %-28s %-5s %s\n  %-28s       %s" % (name, expect, unit, "", soc))
        if ok:
            shutil.rmtree(d, ignore_errors=True)
    print("    SoC mutation: %s" % ("all detected" if bad == 0 else "%d NOT detected" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
