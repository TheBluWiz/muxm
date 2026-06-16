#!/usr/bin/env bash
# =============================================================================
#  run_parallel.sh — parallel driver for test_muxm.sh
#
#  Runs the muxm test suites concurrently to cut wall-clock, WITHOUT modifying
#  test_muxm.sh. Each suite runs as its own `test_muxm.sh --suite NAME` process
#  with a private $TMPDIR, so the per-run mktemp $TESTDIR / isolated $HOME and
#  the suite's auto_cleanup never collide (external fan-out; see Test_Review.md §4.5).
#
#  WHY SEGREGATED (Test_Review.md §4.1–4.2): running the fast config-printing
#  suites concurrently with the CPU-saturating real-encode suites starves the
#  config probes and produces intermittent false "output missing" failures. The
#  config suites parallelize cleanly among themselves; the encode suites do too.
#  So we run them in two separate phases instead of one big undifferentiated pool:
#    Phase 1: config/CLI/unit suites — fully parallel (they're fast, no encoding).
#    Phase 2: real-encode suites     — bounded concurrency (CAP) to leave CPU headroom.
#  The two phases never overlap, which is the exact condition that avoids the flakiness.
#
#  Usage:
#    ./run_parallel.sh                       # run everything, default CAP
#    MUXM=/path/to/muxm ./run_parallel.sh    # custom binary
#    CAP=8 ./run_parallel.sh                  # encode-phase concurrency (default: cores/2)
#
#  Exit status: 0 iff every suite passed; 1 otherwise. Per-suite results are printed.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname -- "$0")" && pwd)"
SCRIPT="$HERE/test_muxm.sh"
MUXM="${MUXM:-$HERE/../muxm}"

# Resolve MUXM to absolute (test_muxm.sh cds into $TESTDIR before invoking it).
[[ "$MUXM" = /* ]] || MUXM="$(cd "$(dirname -- "$MUXM")" && pwd)/$(basename -- "$MUXM")"

[[ -x "$SCRIPT" ]] || { echo "ERROR: test runner not found/executable: $SCRIPT" >&2; exit 1; }
[[ -f "$MUXM"  ]] || { echo "ERROR: muxm not found: $MUXM (set MUXM=/path/to/muxm)" >&2; exit 1; }

# Encode-phase concurrency cap: default to half the cores (real x265 encodes are
# multithreaded, so full fan-out oversubscribes). Never less than 1.
_cores="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null) || echo 4 )"
CAP="${CAP:-$(( _cores / 2 < 1 ? 1 : _cores / 2 ))}"

# Phase 1 — fast, no real encodes (mirrors test_muxm.sh MEDIA_FREE_SUITES + cli).
CONFIG_SUITES=(unit cli toggles completions setup config profiles conflicts hw_accel dv_vt)
# Phase 2 — real-encode suites.
ENCODE_SUITES=(collision dryrun video hdr audio subs ext_subs output containers metadata edge e2e multi_profile regression_p5)

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/muxm-parallel.XXXXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# ---- Drift guard ----
# The union of the two batches MUST equal the canonical set of suites that
# `test_muxm.sh --suite all` runs (its run_suite_tracked calls). If someone adds a suite to
# test_muxm.sh and forgets to add it here, fail loudly — never silently skip it and still
# report "ALL PASSED" (that would be coverage loss disguised as success).
_canonical="$(grep -oE 'run_suite_tracked[[:space:]]+[A-Za-z0-9_]+' "$SCRIPT" | awk '{print $2}' | sort -u)"
_mine="$(printf '%s\n' "${CONFIG_SUITES[@]}" "${ENCODE_SUITES[@]}" | sort -u)"
if [[ -z "$_canonical" ]]; then
  echo "${RED}ERROR: could not read the canonical suite list from $SCRIPT (run_suite_tracked calls).${NC}" >&2
  echo "  Refusing to run a partial suite. Check test_muxm.sh's run_suites()." >&2
  exit 2
fi
if [[ "$_canonical" != "$_mine" ]]; then
  echo "${RED}ERROR: suite-list drift between run_parallel.sh and test_muxm.sh — refusing to run a partial suite.${NC}" >&2
  _missing="$(comm -23 <(printf '%s\n' "$_canonical") <(printf '%s\n' "$_mine") | tr '\n' ' ')"
  _extra="$(comm -13 <(printf '%s\n' "$_canonical") <(printf '%s\n' "$_mine") | tr '\n' ' ')"
  [[ -n "${_missing// }" ]] && echo "  in test_muxm.sh but NOT run here (add to a batch below): $_missing" >&2
  [[ -n "${_extra// }"   ]] && echo "  listed here but not a real suite (remove):              $_extra"   >&2
  exit 2
fi

# run_suite NAME — execute one suite in its own private TMPDIR, capture to a log.
run_suite() {
  local name="$1" d="$WORKDIR/tmp.$1"
  mkdir -p "$d"
  TMPDIR="$d" "$SCRIPT" --muxm "$MUXM" --suite "$name" > "$WORKDIR/$name.log" 2>&1
  echo "$?" > "$WORKDIR/$name.exit"
}

# run_phase CAP SUITE... — run the given suites with at most CAP concurrent.
run_phase() {
  local cap="$1"; shift
  local s
  for s in "$@"; do
    while (( $(jobs -rp | wc -l) >= cap )); do wait -n 2>/dev/null || sleep 0.2; done
    run_suite "$s" &
  done
  wait
}

echo "${BOLD}muxm parallel test run${NC}  (muxm: $MUXM, encode-phase cap: $CAP)"
t0=$SECONDS

echo "── Phase 1: config/CLI/unit suites (fully parallel: ${#CONFIG_SUITES[@]}) ──"
run_phase "${#CONFIG_SUITES[@]}" "${CONFIG_SUITES[@]}"

echo "── Phase 2: encode suites (cap $CAP: ${#ENCODE_SUITES[@]}) ──"
run_phase "$CAP" "${ENCODE_SUITES[@]}"

WALL=$(( SECONDS - t0 ))

# ---- Aggregate ----
total_fail=0 total_pass=0 total_skip=0 suites_failed=0
printf '\n%s%sPer-suite results:%s\n' "$BOLD" "$GREEN" "$NC"
for s in "${CONFIG_SUITES[@]}" "${ENCODE_SUITES[@]}"; do
  # grep -c prints the count (0 if none) but exits 1 when zero; `|| true` swallows that exit
  # without appending an extra line (a `|| echo 0` would make "0\n0" and break the arithmetic).
  log="$WORKDIR/$s.log"; ec="$(cat "$WORKDIR/$s.exit" 2>/dev/null || echo 1)"
  p="$(grep -c '✅ PASS' "$log" 2>/dev/null || true)"; p="${p:-0}"
  f="$(grep -c '❌ FAIL' "$log" 2>/dev/null || true)"; f="${f:-0}"
  k="$(grep -c '⏭'      "$log" 2>/dev/null || true)"; k="${k:-0}"
  total_pass=$(( total_pass + p )); total_fail=$(( total_fail + f )); total_skip=$(( total_skip + k ))
  if [[ "$ec" == 0 && "$f" == 0 ]]; then
    printf '  %s✅ %-16s%s pass=%s skip=%s\n' "$GREEN" "$s" "$NC" "$p" "$k"
  else
    suites_failed=$(( suites_failed + 1 ))
    printf '  %s❌ %-16s%s pass=%s fail=%s (exit %s) — see %s\n' "$RED" "$s" "$NC" "$p" "$f" "$ec" "$log"
  fi
done

printf '\n%sTotals:%s  pass=%s  fail=%s  skip=%s   wall=%ss\n' "$BOLD" "$NC" "$total_pass" "$total_fail" "$total_skip" "$WALL"
# (pass total exceeds a serial run's because each worker re-runs preflight/fixture-gen asserts.)

if (( suites_failed == 0 && total_fail == 0 )); then
  printf '%s%sRESULT: ALL SUITES PASSED%s\n' "$BOLD" "$GREEN" "$NC"
  exit 0
else
  printf '%s%sRESULT: %s SUITE(S) FAILED%s\n' "$BOLD" "$RED" "$suites_failed" "$NC"
  exit 1
fi
