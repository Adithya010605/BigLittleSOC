#!/usr/bin/env bash
# ============================================================================
# mutation_test.sh — does the test suite actually detect broken hardware?
#
# A regression that passes tells you nothing on its own: it might be passing
# because the design is correct, or because the tests do not exercise the thing
# that is broken. This script answers the question directly. It injects a
# specific, realistic RTL defect, rebuilds the core, runs the directed assembly
# suite, and reports whether any test noticed.
#
#   KILLED   — at least one test failed. The suite covers this defect.
#   SURVIVED — every test still passed. The suite has a hole, and the mutation
#              names exactly what is not covered.
#
# Every mutation below is a plausible mistake, not a random character swap:
# forgetting to forward an operand, forwarding one that is not ready yet,
# dropping the x0 write mask, losing the JALR LSB clear, mishandling a
# wrong-path fetch. These are the bugs this microarchitecture actually invites.
#
# Usage: mutation_test.sh [--waits=SPEC] [name ...]
# ============================================================================
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
BUILD=${BUILD:-$ROOT/build}
VERILATOR=${VERILATOR:-verilator}
WORK="$BUILD/mutation"

WAITS_LIST=(0 2 "random:7")
SELECT=()
for a in "$@"; do
  case "$a" in
    --waits=*) WAITS_LIST=("${a#--waits=}") ;;
    *) SELECT+=("$a") ;;
  esac
done

# --- mutation table: name @@ expect @@ file @@ search @@ replace -------------
# Fields are separated by '@@' rather than '|', because several RTL patterns
# contain '|' as the SystemVerilog OR operator and would otherwise be split in
# half -- which silently truncated two patterns on the first run and produced
# syntax errors instead of mutations.
#
# `expect` is `kill` or `equiv`:
#
#   kill   The defect changes architectural behaviour and a test MUST catch it.
#          A surviving `kill` mutation is a genuine coverage gap and fails this
#          script.
#
#   equiv  The defect is an EQUIVALENT MUTANT: this core implements the
#          affected behaviour by two independent mechanisms, so disabling one
#          leaves the other covering it and no test can possibly tell. Marking
#          these explicitly is what stops "it survived" from being confused
#          with "we do not test it". Each one is justified below, and each is
#          paired with a combined mutation that disables BOTH mechanisms and is
#          expected to be killed -- which is the actual proof that the
#          behaviour is tested at all. An `equiv` mutation that unexpectedly
#          gets killed also fails this script, since that means the
#          justification is wrong.
MUTATIONS=(
# ---- forwarding -------------------------------------------------------------
# The write-first register file and the explicit S3->S2 forward muxes deliver
# the same value in the same cycle: both are qualified by rf_we_o and both
# carry rf_wdata. Either alone is therefore sufficient, and disabling one is
# undetectable. no_fwd_no_bypass_all removes both and must be killed.
"no_fwd_rs1@@equiv@@e_core/e_core_hazard.sv@@assign fwd_rs1_o = rs1_match & ~ex_result_late;@@assign fwd_rs1_o = 1'b0;"
"no_fwd_rs2@@equiv@@e_core/e_core_hazard.sv@@assign fwd_rs2_o = rs2_match & ~ex_result_late;@@assign fwd_rs2_o = 1'b0;"
"no_regfile_bypass@@equiv@@common/regfile.sv@@assign bypass_a = we_qual & (waddr_i == raddr_a_i);@@assign bypass_a = 1'b0;"
"no_fwd_no_bypass_all@@kill@@common/regfile.sv@@assign bypass_a = we_qual & (waddr_i == raddr_a_i);\n  assign bypass_b = we_qual & (waddr_i == raddr_b_i);@@assign bypass_a = 1'b0;\n  assign bypass_b = 1'b0;"

# ---- load-use interlock -----------------------------------------------------
# By the cycle the interlock would apply, the load has already asserted rf_we_o
# with valid data (ex_ready_o implies data_rvalid_i), so the write-first
# register file supplies the value and the stall is not required for
# correctness. It is retained because it keeps memory read data out of the S2
# operand path; see docs/e_core_microarchitecture.md.
#
# Two different edits both remove the stall, and they are NOT equivalent to
# each other:
#   no_load_use_stall clears ex_result_late, which removes the stall but also
#     un-gates the forward muxes, so load data is then forwarded explicitly.
#   no_stall_term clears data_hazard_stall alone, leaving the forward muxes
#     still excluding loads, so only the register file bypass remains.
# The second is the one to pair with the bypass removal: no_stall_no_bypass
# does both, leaving the load value genuinely unavailable, and must be killed.
"no_load_use_stall@@equiv@@e_core/e_core_hazard.sv@@assign ex_result_late = (idex_mem_req_i & ~idex_mem_we_i) | idex_csr_en_i;@@assign ex_result_late = 1'b0;"
"no_stall_term@@equiv@@e_core/e_core_hazard.sv@@assign data_hazard_stall = ifid_valid_i & dependency & ex_result_late;@@assign data_hazard_stall = 1'b0;"
"no_stall_no_bypass@@kill@@common/regfile.sv@@assign bypass_a = we_qual & (waddr_i == raddr_a_i);\n  assign bypass_b = we_qual & (waddr_i == raddr_b_i);@@assign bypass_a = 1'b0;\n  assign bypass_b = 1'b0;"

# ---- x0 ---------------------------------------------------------------------
# x0 is protected twice: the write enable is masked, and both read paths mux in
# a constant zero. Removing either leaves the other holding x0 at zero.
# x0_fully_writable removes both and must be killed.
"no_x0_write_mask@@equiv@@common/regfile.sv@@assign we_qual = we_i & (waddr_i != {REG_ADDR_W{1'b0}});@@assign we_qual = we_i;"
"x0_reads_storage@@equiv@@common/regfile.sv@@    if (raddr_a_i == {REG_ADDR_W{1'b0}}) begin\n      rdata_a_o = {XLEN{1'b0}};\n    end else if (bypass_a) begin@@    if (bypass_a) begin"
"x0_fully_writable@@kill@@common/regfile.sv@@assign we_qual = we_i & (waddr_i != {REG_ADDR_W{1'b0}});@@assign we_qual = we_i;"
"fwd_ignores_x0@@kill@@e_core/e_core_hazard.sv@@(idex_rd_i != {REG_ADDR_W{1'b0}});@@1'b1;"

# ---- control transfer -------------------------------------------------------
"jalr_keeps_lsb@@kill@@e_core/e_core_id_stage.sv@@assign jalr_target   = (rs1_data_o + imm_o) & ~32'd1;@@assign jalr_target   = (rs1_data_o + imm_o);"
"branch_always_taken@@kill@@e_core/e_core_id_stage.sv@@assign take_branch_o   = ifid_valid_i & (is_jump | (is_branch & branch_cond));@@assign take_branch_o   = ifid_valid_i & (is_jump | is_branch);"
"branch_never_taken@@kill@@e_core/e_core_id_stage.sv@@assign take_branch_o   = ifid_valid_i & (is_jump | (is_branch & branch_cond));@@assign take_branch_o   = ifid_valid_i & is_jump;"
"branch_target_no_jalr@@kill@@e_core/e_core_id_stage.sv@@assign branch_target_o = is_jalr ? jalr_target : pc_rel_target;@@assign branch_target_o = pc_rel_target;"

# ---- fetch and back-pressure ------------------------------------------------
"no_wrongpath_discard@@kill@@e_core/e_core_if_stage.sv@@        discard_d = 1'b1;@@        discard_d = 1'b0;"
"redirect_keeps_ifid@@kill@@e_core/e_core_if_stage.sv@@      ifid_valid_d = 1'b0;\n      skid_valid_d = 1'b0;\n      pc_d         = redirect_pc_i;@@      pc_d         = redirect_pc_i;"
"no_skid_buffer@@kill@@e_core/e_core_if_stage.sv@@          skid_valid_d = 1'b1;\n          skid_pc_d    = fetch_addr_q;@@          skid_valid_d = 1'b0;\n          skid_pc_d    = fetch_addr_q;"
"stall_ignores_ex_ready@@kill@@e_core/e_core_hazard.sv@@assign id_advances = ifid_valid_i & ex_ready_i & ~data_hazard_stall & ~flush_i;@@assign id_advances = ifid_valid_i & ~data_hazard_stall & ~flush_i;"
"ex_ready_ignores_rvalid@@kill@@e_core/e_core_ex_stage.sv@@assign ex_ready_o = ~mem_active | data_rvalid_i;@@assign ex_ready_o = 1'b1;"
"mem_gnt_not_cleared@@kill@@e_core/e_core_ex_stage.sv@@      mem_gnt_q       <= 1'b0;\n    end else if (data_req_o && data_gnt_i) begin@@      mem_gnt_q       <= mem_gnt_q;\n    end else if (data_req_o && data_gnt_i) begin"

# ---- load/store unit --------------------------------------------------------
"lsu_be_always_word@@kill@@common/lsu.sv@@      SZ_BYTE: be_o = 4'b0001 << addr_lsb_i;@@      SZ_BYTE: be_o = 4'b1111;"
"lsu_no_sign_extend@@kill@@common/lsu.sv@@      SZ_BYTE: rdata_ext_o = {{24{sign_i & byte_sel[7]}}, byte_sel};@@      SZ_BYTE: rdata_ext_o = {24'd0, byte_sel};"
)

# Mutations needing a second edit, applied on top of the first.
# name @@ file @@ search @@ replace
EXTRA_EDITS=(
"no_fwd_no_bypass_all@@e_core/e_core_hazard.sv@@assign fwd_rs1_o = rs1_match & ~ex_result_late;\n  assign fwd_rs2_o = rs2_match & ~ex_result_late;@@assign fwd_rs1_o = 1'b0;\n  assign fwd_rs2_o = 1'b0;"
"no_stall_no_bypass@@e_core/e_core_hazard.sv@@assign data_hazard_stall = ifid_valid_i & dependency & ex_result_late;@@assign data_hazard_stall = 1'b0;"
"x0_fully_writable@@common/regfile.sv@@    if (raddr_a_i == {REG_ADDR_W{1'b0}}) begin\n      rdata_a_o = {XLEN{1'b0}};\n    end else if (bypass_a) begin@@    if (bypass_a) begin"
)

TESTS=(m2_basic hazard_raw hazard_load_use branch_basic branch_hazard jump_link mem_align x0_writes)

# The ELFs are built by run_asm.sh; make sure they exist.
for t in "${TESTS[@]}"; do
  if [ ! -f "$BUILD/asm/$t.elf" ]; then
    echo "mutation_test: build the assembly tests first (make asm-tests)" >&2
    exit 2
  fi
done

mkdir -p "$WORK"
printf "==> mutation testing: %d tests x %d latency configs (%s) per mutation\n" \
       "${#TESTS[@]}" "${#WAITS_LIST[@]}" "${WAITS_LIST[*]}"

killed=0; survived=0; broken=0; equiv=0
declare -a survivors

for entry in "${MUTATIONS[@]}"; do
  IFS=$'\x01' read -r name expect file search replace <<< "${entry//@@/$'\x01'}"
  if [ ${#SELECT[@]} -gt 0 ]; then
    found=0
    for s in "${SELECT[@]}"; do [ "$s" = "$name" ] && found=1; done
    [ $found -eq 0 ] && continue
  fi

  rm -rf "$WORK/rtl"
  cp -r "$ROOT/rtl" "$WORK/rtl"

  # Apply the mutation. Fails loudly if the pattern no longer matches, which
  # is what keeps this table honest as the RTL evolves.
  if ! python3 - "$WORK/rtl/$file" "$search" "$replace" <<'PY'
import sys
path, search, replace = sys.argv[1], sys.argv[2], sys.argv[3]
search = search.replace('\\n', '\n').replace('\\&', '&')
replace = replace.replace('\\n', '\n').replace('\\&', '&')
s = open(path).read()
if search not in s:
    sys.stderr.write("pattern not found in %s:\n  %r\n" % (path, search))
    sys.exit(1)
open(path, 'w').write(s.replace(search, replace, 1))
PY
  then
    printf "  %-24s \033[33mSTALE\033[0m   (pattern no longer matches; update the table)\n" "$name"
    broken=$((broken+1)); continue
  fi

  for extra in "${EXTRA_EDITS[@]}"; do
    IFS=$'\x01' read -r ename efile esearch ereplace <<< "${extra//@@/$'\x01'}"
    [ "$ename" = "$name" ] || continue
    if ! python3 - "$WORK/rtl/$efile" "$esearch" "$ereplace" <<'PY'
import sys
path, search, replace = sys.argv[1], sys.argv[2], sys.argv[3]
search = search.replace('\\n', '\n'); replace = replace.replace('\\n', '\n')
s = open(path).read()
if search not in s:
    sys.stderr.write("extra-edit pattern not found in %s\n" % path); sys.exit(1)
open(path, 'w').write(s.replace(search, replace, 1))
PY
    then
      printf "  %-24s \033[33mSTALE\033[0m   (extra-edit pattern no longer matches)\n" "$name"
      broken=$((broken+1)); continue 2
    fi
  done

  objdir="$WORK/obj_$name"
  rm -rf "$objdir"
  RTL=("$WORK/rtl/common/e_core_pkg.sv")
  for f in "$WORK"/rtl/common/*.sv "$WORK"/rtl/e_core/*.sv; do
    [ "$f" = "$WORK/rtl/common/e_core_pkg.sv" ] && continue
    RTL+=("$f")
  done

  # A mutation frequently leaves a signal unread or a parameter unused. That
  # is a lint concern, not a behavioural one, so those checks are relaxed here
  # only -- 'make lint' still holds the real design to zero warnings.
  if ! "$VERILATOR" --cc --exe --build -j 0 \
        -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-WIDTHEXPAND \
        -I"$WORK/rtl/common" -I"$WORK/rtl/e_core" \
        --Mdir "$objdir" --top-module e_core_top -GRVFI=1 \
        --x-assign unique --x-initial unique \
        -CFLAGS "-std=c++17 -O1 -I$ROOT/tb/integration" \
        -o "$WORK/sim_$name" \
        "${RTL[@]}" "$ROOT"/tb/integration/*.cpp \
        > "$WORK/$name.build.log" 2>&1; then
    # A mutation that will not even compile has been detected, just by the
    # compiler rather than by the tests. Report it separately so it is not
    # mistaken for test coverage.
    printf "  %-24s \033[33mNO-BUILD\033[0m (mutation does not compile)\n" "$name"
    broken=$((broken+1)); continue
  fi

  # A defect only reachable under memory back-pressure -- a mishandled
  # wrong-path fetch, a stall term that ignores ex_ready -- is invisible at
  # zero wait states, because the situation it breaks never arises there. Each
  # mutation is therefore run across several latency configurations and counts
  # as killed if ANY of them detects it.
  detected_by=""
  for t in "${TESTS[@]}"; do
    for w in "${WAITS_LIST[@]}"; do
      if ! "$WORK/sim_$name" --elf "$BUILD/asm/$t.elf" --waits="$w" \
            --max-cycles=500000 --quiet > /dev/null 2>&1; then
        detected_by="$detected_by $t@$w"
        break
      fi
    done
  done

  n=$(wc -w <<< "$detected_by")
  first=$(awk '{print $1}' <<< "$detected_by")
  if [ -n "$detected_by" ] && [ "$expect" = "kill" ]; then
    printf "  %-24s \033[32mKILLED\033[0m    by %2d test(s), first: %s\n" "$name" "$n" "$first"
    killed=$((killed+1))
  elif [ -z "$detected_by" ] && [ "$expect" = "equiv" ]; then
    printf "  %-24s \033[36mEQUIVALENT\033[0m survived as documented\n" "$name"
    equiv=$((equiv+1))
  elif [ -z "$detected_by" ]; then
    printf "  %-24s \033[31mSURVIVED\033[0m  COVERAGE GAP: no test detected this defect\n" "$name"
    survived=$((survived+1)); survivors+=("$name")
  else
    printf "  %-24s \033[31mUNEXPECTED\033[0m killed although marked equivalent (%s)\n" "$name" "$first"
    survived=$((survived+1)); survivors+=("$name(bad-justification)")
  fi
  rm -rf "$objdir" "$WORK/sim_$name"
done

echo
echo "    mutations: $killed killed, $equiv equivalent (documented), $survived unexpected, $broken not evaluated"
if [ $survived -gt 0 ] || [ $broken -gt 0 ]; then
  [ $survived -gt 0 ] && echo "    PROBLEMS: ${survivors[*]}"
  exit 1
fi
exit 0
