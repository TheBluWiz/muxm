#!/usr/bin/env bash
# =============================================================================
#  run_parallel.sh — parallel driver for test_muxm.sh
#
#  Runs the muxm test suites concurrently to cut wall-clock, WITHOUT modifying
#  test_muxm.sh. Each suite runs as its own `test_muxm.sh --suite NAME` process
#  with a private $TMPDIR, so the per-run mktemp $TESTDIR / isolated $HOME and
#  the suite's auto_cleanup never collide (external fan-out — no shared in-process state).
#
#  WHY SEGREGATED: running the fast config-printing
#  suites concurrently with the CPU-saturating real-encode suites starves the
#  config probes and produces intermittent false "output missing" failures. The
#  config suites parallelize cleanly among themselves; the encode suites do too.
#  So we run them in two separate phases instead of one big undifferentiated pool:
#    Phase 1: config/CLI/unit suites — fully parallel (they're fast, no encoding).
#    Phase 2: real-encode suites     — bounded concurrency (CAP) to leave CPU headroom.
#  The two phases never overlap, which is the exact condition that avoids the flakiness.
#
#  Usage:
#    ./run_parallel.sh [--muxm PATH] [--cap N]    # run with -h/--help for details
#    MUXM=/path/to/muxm CAP=8 ./run_parallel.sh   # same options via the environment
#
#  Exit status: 0 iff every suite passed; 1 if any suite failed; 2 on a config/usage error.
# =============================================================================

# ---- bash 4.3+ guard ----
# This script uses `wait -n` (bash 4.3+); muxm itself enforces the same floor. macOS ships
# /bin/bash 3.2, so check before anything depends on it and fail with a clear message.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "run_parallel.sh requires bash 4.3+ (uses 'wait -n'); running under bash ${BASH_VERSION:-?}." >&2
  echo "On macOS, install a newer bash (e.g. 'brew install bash') and invoke the script with it." >&2
  exit 2
fi

# No `-e`: a failing suite must NOT abort the run — every suite is launched and the full
# pass/fail table is reported. Failures are detected explicitly via per-suite exit codes.
set -uo pipefail

# ---- Colors (match test_muxm.sh: literal escapes, rendered with printf "%b") ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'

HERE="$(cd "$(dirname -- "$0")" && pwd)"
SCRIPT="$HERE/test_muxm.sh"

# ---- Help ----
show_help() {
  cat <<'EOF'

  run_parallel.sh — run the muxm test suites in parallel

  Usage: run_parallel.sh [--muxm PATH] [--cap N] [-h|--help]

  Options:
    --muxm PATH    Path to the muxm binary (default: ../muxm; or set $MUXM)
    --cap N        Max concurrent suites in the encode phase — positive integer
                   (default: half the CPU cores; or set $CAP)
    -h, --help     Show this help

  Runs the config/CLI/unit suites fully parallel, then the real-encode suites at
  bounded concurrency (two non-overlapping phases — see the header of this file).
  On a real terminal each phase shows muxm's spinner; piped/CI output prints a
  plain per-phase line. The work directory is removed on success and kept on
  failure so the per-suite logs survive for inspection.

  Exit status: 0 if every suite passes, 1 if any suite fails, 2 on a config/usage error.

EOF
  exit 0
}

# ---- Parse args (a flag always wins over its matching environment variable) ----
_cap_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --muxm) [[ $# -ge 2 ]] || { echo "Error: --muxm requires a PATH argument (try --help)" >&2; exit 2; }; MUXM="$2"; shift 2 ;;
    --cap)  [[ $# -ge 2 ]] || { echo "Error: --cap requires a number (try --help)" >&2; exit 2; };       _cap_arg="$2"; shift 2 ;;
    -h|--help) show_help ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ---- Resolve muxm (flag > $MUXM > default) to an absolute path ----
# (test_muxm.sh cds into $TESTDIR before invoking muxm, so a relative path would break.)
MUXM="${MUXM:-$HERE/../muxm}"
[[ "$MUXM" = /* ]] || MUXM="$(cd "$(dirname -- "$MUXM")" 2>/dev/null && pwd)/$(basename -- "$MUXM")"
[[ -x "$SCRIPT" ]] || { echo "ERROR: test runner not found or not executable: $SCRIPT" >&2; exit 2; }
[[ -x "$MUXM"  ]] || { echo "ERROR: muxm not found or not executable: $MUXM (use --muxm PATH)" >&2; exit 2; }

# ---- Resolve the encode-phase concurrency cap (flag > $CAP > cores/2) ----
_cores="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null) || echo 4 )"
[[ "$_cores" =~ ^[0-9]+$ ]] || _cores=4
CAP="${_cap_arg:-${CAP:-$(( _cores / 2 < 1 ? 1 : _cores / 2 ))}}"
[[ "$CAP" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --cap/CAP must be a positive integer (got '$CAP')" >&2; exit 2; }

# ---- Suite batches ----
# Phase 1 — fast, no real encodes (mirrors test_muxm.sh MEDIA_FREE_SUITES + cli).
CONFIG_SUITES=(unit cli toggles completions setup config profiles conflicts hw_accel dv_vt docs)
# Phase 2 — real-encode suites.
ENCODE_SUITES=(collision dryrun video hdr audio subs ext_subs output containers metadata edge e2e multi_profile regression_p5 dv_sw)

# ---- Partition guard ----
# The two batches must PARTITION the canonical suite set that `test_muxm.sh --suite all` runs
# (its run_suite_tracked calls): together they cover every canonical suite EXACTLY ONCE. That
# is stronger than the old set-equality check, which deduped a suite misfiled into BOTH batches
# and silently ran it twice (wasted CPU / coverage loss disguised as success). We assert three
# things: the batches are disjoint (no suite in both phases), their deduped union equals the
# canonical set (none missing, none extra — reported by name), and their non-deduped slot count
# equals the canonical count (no suite listed twice within ONE batch). Runs before the work
# directory is created, so a drift abort leaves nothing behind.
_canonical="$(grep -oE 'run_suite_tracked[[:space:]]+[A-Za-z0-9_]+' "$SCRIPT" | awk '{print $2}' | sort -u)"
if [[ -z "$_canonical" ]]; then
  printf '%bERROR: could not read the canonical suite list from %s (run_suite_tracked calls).%b\n' "$RED" "$SCRIPT" "$NC" >&2
  echo "  Refusing to run a partial suite. Check test_muxm.sh's run_suites()." >&2
  exit 2
fi
_canon_n="$(printf '%s\n' "$_canonical" | grep -c .)"

# (a) Disjoint: no suite may appear in BOTH phases — the misfiled-into-both case the old
#     deduped set-equality silently tolerated (running that suite twice).
_in_both="$(comm -12 <(printf '%s\n' "${CONFIG_SUITES[@]}" | sort -u) <(printf '%s\n' "${ENCODE_SUITES[@]}" | sort -u) | tr '\n' ' ')"
if [[ -n "${_in_both// }" ]]; then
  printf '%bERROR: suite(s) listed in BOTH phases of run_parallel.sh — they would run twice: %s%b\n' "$RED" "$_in_both" "$NC" >&2
  echo "  Each suite must live in exactly one of CONFIG_SUITES / ENCODE_SUITES." >&2
  exit 2
fi

# (b) Coverage: the deduped union must equal the canonical set (catches missing/extra, by name).
_mine="$(printf '%s\n' "${CONFIG_SUITES[@]}" "${ENCODE_SUITES[@]}" | sort -u)"
if [[ "$_canonical" != "$_mine" ]]; then
  printf '%bERROR: suite-list drift between run_parallel.sh and test_muxm.sh — refusing to run a partial suite.%b\n' "$RED" "$NC" >&2
  _missing="$(comm -23 <(printf '%s\n' "$_canonical") <(printf '%s\n' "$_mine") | tr '\n' ' ')"
  _extra="$(comm -13 <(printf '%s\n' "$_canonical") <(printf '%s\n' "$_mine") | tr '\n' ' ')"
  [[ -n "${_missing// }" ]] && echo "  in test_muxm.sh but NOT run here (add to a batch above): $_missing" >&2
  [[ -n "${_extra// }"   ]] && echo "  listed here but not a real suite (remove):               $_extra"   >&2
  exit 2
fi

# (c) Partition count: the non-deduped batch sizes must sum to the canonical count. With (a)+(b)
#     already proven, this additionally rejects a suite duplicated WITHIN a single batch — which
#     (a)'s cross-batch test and (b)'s deduped equality both miss.
_total=$(( ${#CONFIG_SUITES[@]} + ${#ENCODE_SUITES[@]} ))
if (( _total != _canon_n )); then
  printf '%bERROR: run_parallel.sh batches list %s suite slots but test_muxm.sh has %s canonical suites.%b\n' "$RED" "$_total" "$_canon_n" "$NC" >&2
  echo "  A suite is probably listed twice within one batch — each must appear exactly once across the two batches." >&2
  exit 2
fi

# ---- Work directory + cleanup ----
# Each worker gets a private subdir; logs/exit files live at the top. The directory is
# removed on success and on a clean early exit, but KEPT on failure or interrupt (like
# test_muxm.sh keeps its $TESTDIR) so the per-suite logs the report points at survive.
_tmpbase="${TMPDIR:-/tmp}"; _tmpbase="${_tmpbase%/}"

# Reclaim stale work dirs left by earlier failed/interrupted runs (the parent does the same
# via auto_cleanup_test_dirs). Mirror its liveness check: a dir whose .pid names a running
# process belongs to a concurrent run and is skipped, so we never wipe a live instance.
for _d in "$_tmpbase"/muxm-parallel.*; do
  [[ -d "$_d" ]] || continue
  _opid=""; [[ -r "$_d/.pid" ]] && read -r _opid < "$_d/.pid" 2>/dev/null
  [[ "$_opid" =~ ^[0-9]+$ ]] && kill -0 "$_opid" 2>/dev/null && continue   # still running → keep
  rm -rf "$_d"
done

WORKDIR="$(mktemp -d "$_tmpbase/muxm-parallel.XXXXXXXX")" || { echo "ERROR: could not create a work directory under $_tmpbase" >&2; exit 2; }
[[ -d "$WORKDIR" ]] || { echo "ERROR: work directory was not created: $WORKDIR" >&2; exit 2; }
echo "$$" > "$WORKDIR/.pid"                  # claim it so a concurrent run's sweep skips us

_keep_workdir=0
_driver=""                                   # PID of the in-flight phase driver (for the signal handler)
# _cleanup and _on_signal are invoked indirectly by the `trap` registrations below, never
# called directly. shellcheck's SC2329 stops crediting trap-registered functions as "used"
# once a script ends in an explicit `exit` (as this one does in its final if/else), so it
# misreports them as never invoked — they are NOT dead code; the EXIT trap fires on the
# explicit `exit 0`/`exit 1` and the workdir cleanup does run.
# shellcheck disable=SC2329
_cleanup() { (( _keep_workdir )) || rm -rf "$WORKDIR"; }
trap _cleanup EXIT
# shellcheck disable=SC2329  # see the note above _cleanup — invoked via `trap _on_signal INT TERM`
_on_signal() {
  trap '' INT TERM                           # don't re-enter while we tear down
  [[ -n "$_driver" ]] && kill "$_driver" 2>/dev/null
  _keep_workdir=1
  printf '\n%bInterrupted — work directory kept for inspection: %s%b\n' "$YELLOW" "$WORKDIR" "$NC" >&2
  exit 130
}
trap _on_signal INT TERM

# run_suite NAME — execute one suite in its own private TMPDIR, capturing log + exit code.
run_suite() {
  local name="$1" d="$WORKDIR/tmp.$1"
  mkdir -p "$d"
  TMPDIR="$d" "$SCRIPT" --muxm "$MUXM" --suite "$name" > "$WORKDIR/$name.log" 2>&1
  echo "$?" > "$WORKDIR/$name.exit"
}

# spinner PID MSG — animated progress indicator, ported from muxm's spinner() (same frames,
# cadence, and \r rendering). Polls PID with kill -0 (never waits); animates only when stderr
# is a TTY, and stays silent otherwise. The caller waits on PID afterward to collect status.
spinner() {
  local pid=$1 msg=$2 i=0
  local -a sym=( '|' '/' '—' $'\\' )
  local -i show=1
  [[ -t 2 ]] || show=0
  while kill -0 "$pid" 2>/dev/null; do
    (( show )) && printf '\r  %s  [ %s ]' "$msg" "${sym[i]}" >&2 || true
    i=$(( (i+1) % 4 ))
    sleep 0.2
  done
  (( show )) && printf '\r  %s  [ done ]\n' "$msg" >&2 || true
}

# run_phase CAP MSG SUITE... — run the suites (at most CAP concurrent) inside a backgrounded
# driver, and show the muxm spinner against that driver until the whole phase finishes.
run_phase() {
  local cap="$1" msg="$2"; shift 2
  local -a suites=("$@")
  # One backgrounded driver launches every suite (respecting the cap) and waits for them all,
  # giving the spinner a single PID to poll. The workers write their own logs, so the terminal
  # shows only the spinner line while the phase runs.
  ( for s in "${suites[@]}"; do
      while (( $(jobs -rp | wc -l) >= cap )); do wait -n 2>/dev/null || sleep 0.2; done
      run_suite "$s" &
    done
    wait
  ) &
  _driver=$!                                   # exposed so the INT/TERM handler can stop the phase
  [[ -t 2 ]] || printf '  %s …\n' "$msg" >&2   # non-TTY (CI/pipe): one-line announce, no animation
  spinner "$_driver" "$msg"
  wait "$_driver" 2>/dev/null || true          # reap; per-suite pass/fail comes from the .exit files
  _driver=""
}

# ---- Run ----
printf '%bmuxm parallel test run%b  (muxm: %s, encode-phase cap: %s)\n' "$BOLD" "$NC" "$MUXM" "$CAP"
t0=$SECONDS

run_phase "${#CONFIG_SUITES[@]}" "Phase 1 — config/CLI/unit suites (${#CONFIG_SUITES[@]}, parallel)" "${CONFIG_SUITES[@]}"
run_phase "$CAP" "Phase 2 — encode suites (${#ENCODE_SUITES[@]}, cap $CAP)" "${ENCODE_SUITES[@]}"

WALL=$(( SECONDS - t0 ))

# ---- Aggregate ----
total_fail=0 total_pass=0 total_skip=0 suites_failed=0
printf '\n%b%bPer-suite results:%b\n' "$BOLD" "$GREEN" "$NC"
for s in "${CONFIG_SUITES[@]}" "${ENCODE_SUITES[@]}"; do
  # grep -c prints the count (0 if none) but exits 1 when zero; `|| true` swallows that exit
  # without appending an extra line (a `|| echo 0` would make "0\n0" and break the arithmetic).
  log="$WORKDIR/$s.log"; ec="$(cat "$WORKDIR/$s.exit" 2>/dev/null || echo 1)"
  p="$(grep -c '✅ PASS' "$log" 2>/dev/null || true)"; p="${p:-0}"
  f="$(grep -c '❌ FAIL' "$log" 2>/dev/null || true)"; f="${f:-0}"
  k="$(grep -c '⏭'      "$log" 2>/dev/null || true)"; k="${k:-0}"
  total_pass=$(( total_pass + p )); total_fail=$(( total_fail + f )); total_skip=$(( total_skip + k ))
  if [[ "$ec" == 0 && "$f" == 0 ]]; then
    printf '  %b✅ %-16s%b pass=%s skip=%s\n' "$GREEN" "$s" "$NC" "$p" "$k"
  else
    suites_failed=$(( suites_failed + 1 ))
    printf '  %b❌ %-16s%b pass=%s fail=%s (exit %s) — see %s\n' "$RED" "$s" "$NC" "$p" "$f" "$ec" "$log"
  fi
done

printf '\n%bTotals:%b  pass=%s  fail=%s  skip=%s   wall=%ss\n' "$BOLD" "$NC" "$total_pass" "$total_fail" "$total_skip" "$WALL"
# (pass total exceeds a serial run's because each worker re-runs preflight/fixture-gen asserts.)

if (( suites_failed == 0 && total_fail == 0 )); then
  printf '%b%bRESULT: ALL SUITES PASSED%b\n' "$BOLD" "$GREEN" "$NC"
  exit 0
else
  _keep_workdir=1                              # keep logs so the "see …" paths above stay valid
  printf '%b%bRESULT: %s SUITE(S) FAILED%b — logs kept in %s\n' "$BOLD" "$RED" "$suites_failed" "$NC" "$WORKDIR"
  exit 1
fi
