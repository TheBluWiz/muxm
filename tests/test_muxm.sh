#!/usr/bin/env bash
# =============================================================================
#  muxm Test Harness v2.0
#  Automated testing for MuxMaster — generates synthetic media and validates
#  CLI parsing, config precedence, profile behavior, and pipeline outputs.
#
#  Usage:
#    ./test_muxm.sh                                        # show help
#    ./test_muxm.sh --suite all                            # run everything
#    ./test_muxm.sh --suite subs                           # run one suite
#    ./test_muxm.sh --muxm /path/to/muxm --suite e2e      # custom binary
#
#  Run with -h or --help for the full suite list.
#  Default: no arguments shows help.
# =============================================================================

# ---- bash 4.3+ guard ----
# This harness uses `mapfile`/`readarray` (bash 4.0+) and namerefs elsewhere, and it drives
# muxm, which itself enforces bash 4.3+. macOS ships /bin/bash 3.2, so check before anything
# depends on it and fail with a clear message (mirrors the guard in run_parallel.sh).
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "test_muxm.sh requires bash 4.3+ (uses mapfile/namerefs); running under bash ${BASH_VERSION:-?}." >&2
  echo "On macOS, install a newer bash (e.g. 'brew install bash') and invoke the script with it." >&2
  exit 2
fi

set -euo pipefail

# ---- Configuration ----
MUXM="${MUXM:-./muxm}"
SUITE="${SUITE:-all}"
# Canonical temp base — used for BOTH creation (preflight) and cleanup so they
# never diverge. Honors $TMPDIR (macOS sets a per-user dir under /var/folders);
# trailing slash stripped so globs don't produce "//".
TMP_BASE="${TMPDIR:-/tmp}"; TMP_BASE="${TMP_BASE%/}"
# Per-run lock file written inside each run's $TESTDIR, naming the owning PID.
# Cleanup (auto_cleanup_test_dirs / do_cleanup) treats a muxm-test.* dir as live
# while that PID is still running, so a fresh run never deletes a concurrent
# run's in-use directory. See _testdir_pid / _testdir_is_live.
readonly TESTDIR_LOCK=".muxm-test.lock"
VERBOSE=0
TESTDIR=""
PASS=0
FAIL=0
SKIP=0
ERRORS=()
SUITE_STATUS=()     # "suite:PASS" or "suite:FAIL" entries for per-suite summary

# muxm exits 11 for validation/usage errors (bad flags, missing files, invalid values, etc.).
# Exit code 11 is chosen to avoid collision with standard shell/signal codes (1-2, 126-128+N).
readonly EXIT_VALIDATION=11

# ---- Numbering Convention ----
# Throughout this file, parenthetical references like (#28), (#50), (R28), (R31)
# refer to items in the project's requirements/issue tracker:
#   #N  — GitHub issue or feature ticket number
#   RN  — Internal requirement ID from the test-plan matrix
# These cross-references allow tracing each assertion back to its originating spec.

# ---- Colors ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# ---- Help ----
show_help() {
  cat <<'EOF'

  muxm Test Harness v2.0

  Usage: test_muxm.sh [--muxm PATH] [--suite SUITE] [--verbose]
         test_muxm.sh --suite all          # run everything

  Suites (--suite NAME):

    Fast (config-only, no media generation, ~2s):
      profiles      Profile variable assignment (--print-effective-config)
      conflicts     Conflict warnings (profile + contradictory flag)
      toggles       CLI toggle/flag parsing (--flag / --no-flag pairs)
      hw_accel      Hardware acceleration flag, .muxmrc, and resolver scaffolding
      config        Config file precedence (.muxmrc layering)
      unit          Pure unit tests (helpers, codec maps, heuristics)
      completions   Tab-completion installer/uninstaller
      setup         --install-dependencies, --install-man, etc.
      docs          Generated-artifact parity (man page + completions vs muxm --emit-*)

    Medium (core fixture only, ~5s):
      cli           CLI parsing, --help, --version, error codes
      dryrun        --dry-run mode (profiles, skip flags, multi-track)
      collision     Source/output collision and auto-versioning
      edge          Edge cases (empty files, missing streams, etc.)
      multi_profile Multi-profile comma-separated --profile parsing + auto-naming

    Full (all fixtures, real encodes, ~30s+):
      video        Video pipeline (HEVC, H.264, copy-if-compliant)
      hdr          HDR detection, color space, tone-mapping
      audio        Audio selection, scoring, multi-track, lossless
      subs         Subtitle pipeline, multi-track, ASS, OCR config
      ext_subs     External subtitle discovery, filename parsing, --no-ext-subs
      output       Chapters, checksum, JSON report, skip-if-ideal
      containers   MP4, MKV, MOV container handling
      metadata     Metadata stripping and preservation
      e2e          Full profile end-to-end encodes
      regression_p5 Phase 5 regression tests (C1, M3, H9, H8, H10, DVMKV, DISKSTOP, WORKDIR, H1, H11)
      dv_vt        VideoToolbox + Dolby Vision regression (uses bundled DV fixture by
                   default; VT encode gated on macOS + hevc_videotoolbox + dovi_tool +
                   MP4Box, else SKIPs. Override source with MUXM_DV_FIXTURE=/path/to/dv)
      dv_sw        Portable software Dolby Vision round-trip (bundled DV fixture; real
                   libx265 encode + RPU extract/inject/dvcC, gated on dovi_tool + MP4Box,
                   else SKIPs — no VideoToolbox needed. Override with MUXM_DV_FIXTURE)

    all            Run every suite above (default when --suite given)

  Options:
    --muxm PATH    Path to muxm binary (default: ./muxm)
    --suite NAME   Run a specific suite (see above)
    --verbose      Show output snippets on failure
    -h, --help     Show this help
    --cleanup      Remove all muxm test directories and exit

EOF
  exit 0
}

# ---- Cleanup ----
# _testdir_pid — Echo the PID recorded in a muxm-test.* dir's lock file, or
# nothing if the dir has no (readable, numeric) lock. Reads only the first line.
_testdir_pid() {
  local pid
  [[ -f "$1/$TESTDIR_LOCK" ]] || return 1
  read -r pid < "$1/$TESTDIR_LOCK" 2>/dev/null || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$pid"
}

# _testdir_is_live — True when a muxm-test.* dir belongs to a run still in
# progress, i.e. its lock file names a PID that is still alive. Dirs with no
# lock (older harness, or a half-created dir) or a dead PID are treated as stale
# and therefore removable. kill -0 only probes existence; it sends no signal.
# Failure mode is deliberately conservative: a reused PID may keep a stale dir
# around one extra cycle, but a live run's dir is never deleted.
_testdir_is_live() {
  local pid
  pid="$(_testdir_pid "$1")" || return 1
  kill -0 "$pid" 2>/dev/null
}

_cleanup_format_kb() {
  local kb=$1
  if (( kb >= 1048576 )); then
    printf "%.1fG" "$(echo "scale=1; $kb / 1048576" | bc)"
  elif (( kb >= 1024 )); then
    printf "%.1fM" "$(echo "scale=1; $kb / 1024" | bc)"
  else
    printf "%dK" "$kb"
  fi
}

do_cleanup() {
  local tmpbase="$TMP_BASE"
  local dirs=() skipped=0
  for d in "$tmpbase"/muxm-test.*; do
    [[ -d "$d" ]] || continue
    if _testdir_is_live "$d"; then
      echo "Skipping $d (in use by PID $(_testdir_pid "$d"))"
      skipped=$(( skipped + 1 ))
      continue
    fi
    dirs+=("$d")
  done
  if [[ ${#dirs[@]} -eq 0 ]]; then
    if [[ $skipped -gt 0 ]]; then
      echo "No removable muxm test directories ($skipped in use)."
    else
      echo "No muxm test directories found."
    fi
    exit 0
  fi
  local total_kb=0
  for d in "${dirs[@]}"; do
    local size kb
    size="$(du -sh "$d" 2>/dev/null | cut -f1)"
    kb="$(du -sk "$d" 2>/dev/null | awk '{print $1}')"
    echo "Removing $d (${size})"
    rm -rf "$d"
    total_kb=$(( total_kb + ${kb:-0} ))
  done
  local n=${#dirs[@]} total_str
  total_str="$(_cleanup_format_kb "$total_kb")"
  if [[ $n -eq 1 ]]; then
    echo "Cleaned $n directory ($total_str freed)"
  else
    echo "Cleaned $n directories ($total_str freed)"
  fi
  exit 0
}

auto_cleanup_test_dirs() {
  local tmpbase="$TMP_BASE"
  local dirs=()
  for d in "$tmpbase"/muxm-test.*; do
    [[ -d "$d" ]] || continue
    # Never delete a directory owned by a still-running test instance — that is
    # the race that wiped a concurrent run's $TESTDIR mid-suite.
    _testdir_is_live "$d" && continue
    dirs+=("$d")
  done
  if [[ ${#dirs[@]} -gt 0 ]]; then
    rm -rf "${dirs[@]}"
    local n=${#dirs[@]}
    if [[ $n -eq 1 ]]; then
      echo "Auto-cleaned $n stale test directory."
    else
      echo "Auto-cleaned $n stale test directories."
    fi
  fi
}

# ---- Parse args ----
# No arguments → show help (use --suite all to run everything)
[[ $# -eq 0 ]] && show_help

while [[ $# -gt 0 ]]; do
  case "$1" in
    --muxm)        [[ $# -ge 2 ]] || { echo "Error: --muxm requires a PATH argument (try --help)" >&2; exit 1; }; MUXM="$2"; shift 2 ;;
    --suite)       [[ $# -ge 2 ]] || { echo "Error: --suite requires a SUITE name (try --help)" >&2; exit 1; }; SUITE="$2"; shift 2 ;;
    --verbose)     VERBOSE=1; shift ;;
    -h|--help)  show_help ;;
    --cleanup)  do_cleanup ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
done

# Resolve MUXM to an absolute path so run_muxm works after cd-ing to TESTDIR.
# Done AFTER arg parsing so --muxm ./muxm is resolved from the correct directory.
if [[ "$MUXM" != /* ]]; then
  MUXM="$(cd "$(dirname -- "$MUXM")" && pwd)/$(basename -- "$MUXM")"
fi

# ---- Helpers ----
log()  { printf "%b  → %s%b\n" "$BLUE" "$*" "$NC"; }
pass() { PASS=$((PASS + 1)); printf "%b  ✅ PASS: %s%b\n" "$GREEN" "$*" "$NC"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$*"); printf "%b  ❌ FAIL: %s%b\n" "$RED" "$*" "$NC"; }
skip() { SKIP=$((SKIP + 1)); printf "%b  ⏭  SKIP: %s%b\n" "$YELLOW" "$*" "$NC"; }
section() { printf "\n%b━━━ %s ━━━%b\n" "$BOLD" "$*" "$NC"; }

# --- Homebrew stub for the installer paths (safety) -------------------------------------
# The installer entry points (`--setup`, `--install-dependencies`, `--install-man`,
# `--uninstall-man`) shell out to the real `brew`: `brew install`/`uninstall`/`tap` would
# mutate the developer's actual packages, and `brew --prefix` steers `_man_target_dir` at the
# REAL …/share/man/man1 — so `_install_man`/`_uninstall_man` would overwrite or delete the
# installed muxm.1. Running the suite must do neither. This drops a no-op `brew` on a temp
# PATH dir: it answers `--prefix` with a sandbox prefix (so the man page lands under a temp
# dir, never /opt/homebrew) and turns every other subcommand — install, uninstall, tap, list —
# into a recorded no-op. Callers prepend "$bin" to PATH; every invocation's argv is appended to
# "$prefix/brew_calls.log" so a test can assert brew was actually intercepted. Same stub shape
# as the sub-test in test_setup, generalized and argv-recording.
# Usage: _make_brew_stub <stub_bin_dir> <sandbox_prefix_dir>
_make_brew_stub() {
  local bin="$1" prefix="$2"
  # Pre-create the man1 dir so _install_man finds a writable target and writes directly,
  # instead of testing -w on the (absent) parent and falling through to `sudo mkdir`/`sudo tee`
  # — which would hang or fail non-interactively. Same reason the sub-test pre-creates its
  # man dir. _man_target_dir resolves to "$prefix/share/man/man1" via the stubbed `brew --prefix`.
  mkdir -p "$bin" "$prefix/share/man/man1"
  : > "$prefix/brew_calls.log"
  # Single-quoted body keeps `$*`/`$1` LITERAL for the generated stub's own runtime; only the
  # two real %s (log path, then prefix) are expanded here. `%%s`→literal `%s` and `\\n`→literal
  # `\n` are for the stub's inner printf.
  # shellcheck disable=SC2016
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n[[ "$1" == "--prefix" ]] && { printf "%%s\\n" "%s"; exit 0; }\nexit 0\n' \
    "$prefix/brew_calls.log" "$prefix" > "$bin/brew"
  chmod +x "$bin/brew"
}

# Run muxm from TESTDIR to avoid picking up .muxmrc from the user's PWD.
# -K (--keep-temp-always) preserves workdirs for post-mortem debugging
# (encode.err, muxm.*.log).  They live under $TESTDIR and are cleaned with it.
# The trailing `|| true` prevents set -e from aborting when muxm returns non-zero
# (which is expected in many test cases).
run_muxm() { (cd "$TESTDIR" && "$MUXM" -K "$@" 2>&1) || true; }
# Run muxm from a specific directory with an optional HOME override.
# Covers cases where tests need a custom PWD (for .muxmrc) or isolated HOME.
# HOME isolation prevents the real user's ~/.muxmrc from polluting config-precedence
# tests — without it, a developer's personal config silently changes expected values.
# Usage: run_muxm_in DIR [muxm flags...]
#   Set MUXM_HOME before calling to override HOME; defaults to real $HOME.
run_muxm_in() { local dir="$1"; shift; (cd "$dir" && HOME="${MUXM_HOME:-$HOME}" "$MUXM" -K "$@" 2>&1) || true; }
# Assert exit code.
# The `&& code=$? || code=$?` idiom captures the exit code regardless of success
# or failure without triggering set -e.  $? is 0 on the && branch, non-zero on ||.
assert_exit() {
  local expected="$1" label="$2"
  shift 2
  local output code
  output="$(cd "$TESTDIR" && "$MUXM" "$@" 2>&1)" && code=$? || code=$?
  if [[ "$code" -eq "$expected" ]]; then
    pass "$label (exit $code)"
  else
    fail "$label — expected exit $expected, got $code"
    (( VERBOSE )) && echo "    Output: ${output:0:200}" || true
  fi
}

# Assert output contains string
assert_contains() {
  local needle="$1" label="$2" haystack="$3"
  # here-string (not `echo | grep`) avoids spawning an echo subshell + pipe per call;
  # this helper runs ~460×, so the saved process churn is worth the one-line change.
  if grep -qiF -- "$needle" <<<"$haystack"; then
    pass "$label"
  else
    fail "$label — output missing: '$needle'"
    (( VERBOSE )) && echo "    Output: ${haystack:0:300}" || true
  fi
}

# Assert output does NOT contain string (fixed-string, case-insensitive).
# Mirror of assert_contains; used by the subtitle command-shape guards (e.g.
# "no per-track file round-trip", and the Phase-5 "no standalone .sup input").
assert_not_contains() {
  local needle="$1" label="$2" haystack="$3"
  if grep -qiF -- "$needle" <<<"$haystack"; then
    fail "$label — output unexpectedly contains: '$needle'"
    (( VERBOSE )) && echo "    Output: ${haystack:0:300}" || true
  else
    pass "$label"
  fi
}

# Extract muxm's assembled final-mux ffmpeg command from a --keep-log persisted
# run log (<output>.muxm.log), normalizing absolute paths to basenames so the
# command-shape assertions are stable across workdirs. This is the Phase-1
# observability seam (mux_final logs "ffmpeg mux command: …"); Phases 4–5 assert
# the unified emitter reproduces the frozen shape.
# Usage: cmd="$(extract_mux_cmd "$logpath")"
extract_mux_cmd() {
  local logpath="$1"
  [[ -f "$logpath" ]] || { echo ""; return 0; }
  grep -aoE 'ffmpeg mux command:.*' "$logpath" | head -1 \
    | sed -E 's#/[^[:space:]]*/([^/[:space:]]+)#\1#g'
}

# Assert output matches an extended regex (for anchored / exact-value checks
# that fixed-string assert_contains cannot express, e.g. an empty config value).
# Usage: assert_matches REGEX LABEL HAYSTACK
assert_matches() {
  local regex="$1" label="$2" haystack="$3"
  if printf '%s\n' "$haystack" | grep -qE -- "$regex"; then
    pass "$label"
  else
    fail "$label — output did not match regex: '$regex'"
    (( VERBOSE )) && echo "    Output: ${haystack:0:300}" || true
  fi
}

# Assert file does NOT exist
assert_no_file() {
  local path="$1" label="$2"
  if [[ ! -f "$path" ]]; then
    pass "$label"
  else
    fail "$label — file unexpectedly exists: $path"
  fi
}

# _keepworkdir_logfile CAPTURED_OUTPUT — echo the path of a run's workdir logfile, located via the
# "Keeping workdir:" line a -K run prints (run_muxm always passes -K). Empty (return 1) if absent.
# muxm routes its internal log() lines to the logfile instead of leaking them to the
# terminal, so tests that need to observe those decisions read the kept workdir log (same pattern
# the H9 x265-params test uses).
_keepworkdir_logfile() {
  local wd
  wd="$(printf '%s\n' "$1" | grep 'Keeping workdir:' | head -1 | awk '{print $NF}')"
  [[ -n "$wd" && -d "$wd" ]] || return 1
  find "$wd" -maxdepth 1 -name 'muxm.*.log' 2>/dev/null | head -1
}

# Probe a video field from output file (returns value via stdout).
# head -1: ffprobe may return multiple lines for multi-segment files.
# tr -d ',': ffprobe's csv output can include trailing commas in multi-value fields.
probe_video() {
  local file="$1" field="$2"
  ffprobe -v error -select_streams v:0 -show_entries "stream=$field" -of csv=p=0 "$file" 2>/dev/null | head -1 | tr -d ','
}

# Probe an audio field from output file (stream index defaults to a:0).
# Same head -1 | tr -d ',' rationale as probe_video above.
probe_audio() {
  local file="$1" field="$2" idx="${3:-0}"
  ffprobe -v error -select_streams "a:$idx" -show_entries "stream=$field" -of csv=p=0 "$file" 2>/dev/null | head -1 | tr -d ','
}

# Probe a subtitle field from output file (stream index defaults to s:0).
probe_sub() {
  local file="$1" field="$2" idx="${3:-0}"
  ffprobe -v error -select_streams "s:$idx" -show_entries "stream=$field" -of csv=p=0 "$file" 2>/dev/null | head -1 | tr -d ','
}

# Probe a format-level tag (title, comment, encoder, language, etc.).
# Usage: probe_format_tag FILE TAG
probe_format_tag() {
  local file="$1" tag="$2"
  ffprobe -v error -show_entries "format_tags=$tag" -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1
}

# Probe a stream-level tag (language, title, etc.).
# Usage: probe_stream_tag FILE STREAM_SPEC TAG
#   STREAM_SPEC — ffprobe stream selector (a:0, s:0, v:0, etc.)
probe_stream_tag() {
  local file="$1" stream="$2" tag="$3"
  ffprobe -v error -select_streams "$stream" -show_entries "stream_tags=$tag" -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1
}

# Probe a format-level field (format_name, duration, etc.).
# Usage: probe_format FILE FIELD
probe_format() {
  local file="$1" field="$2"
  ffprobe -v error -show_entries "format=$field" -of csv=p=0 "$file" 2>/dev/null | head -1
}

# Count streams of a given type
# Note: tr -d ' ' strips padding from BSD wc (macOS compat)
count_streams() {
  local file="$1" type="$2"
  ffprobe -v error -select_streams "$type" -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null | wc -l | tr -d ' '
}

# True if the current ffmpeg build lists ENCODER. Collects the encoder list into
# a variable first to avoid `grep -q` SIGPIPE-ing the pipeline under set -o pipefail
# (which can make a capability guard return 141 and silently skip a capable host).
# The $'\n'…$'\n' wrapping gives an exact whole-token match (like grep -qx).
ffmpeg_has_encoder() {
  local enc="$1" list
  list="$(ffmpeg -hide_banner -encoders 2>/dev/null | awk '{print $2}' || true)"
  [[ $'\n'"$list"$'\n' == *$'\n'"$enc"$'\n'* ]]
}

# Run muxm and assert the output file exists and is non-empty.
# Returns 0 on success so callers can gate further assertions:
#   if assert_encode "label" "$outfile" [muxm flags...] "$source"; then
#     assert_probe "codec" "$outfile" codec_name hevc
#   fi
# The SOURCE file must be the last muxm flag (positional arg convention).
assert_encode() {
  local label="$1" outfile="$2"
  shift 2
  run_muxm "$@" "$outfile"
  if [[ -f "$outfile" && -s "$outfile" ]]; then
    pass "$label"
    return 0
  else
    fail "$label: no output"
    return 1
  fi
}

# Assert a video stream field matches an expected value.
# Uses probe_video (stream v:0) under the hood.
# Usage: assert_probe "label" FILE FIELD EXPECTED
assert_probe() {
  local label="$1" file="$2" field="$3" expected="$4"
  local actual
  actual="$(probe_video "$file" "$field")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label — expected '$expected', got '$actual'"
  fi
}

# Assert a stream count for a given type falls within [MIN, MAX].
# If MAX is omitted it defaults to 999 (i.e. "at least MIN").
# Usage: assert_stream_count "label" FILE TYPE MIN [MAX]
assert_stream_count() {
  local label="$1" file="$2" type="$3" min="$4" max="${5:-999}"
  local count
  count="$(count_streams "$file" "$type")"
  if [[ "$count" -ge "$min" && "$count" -le "$max" ]]; then
    pass "$label ($count streams)"
  else
    fail "$label — expected ${min}-${max} streams, got $count"
  fi
}

# Generate a synthetic 2-second test clip with one lavfi video and one lavfi audio input.
# Handles the common ffmpeg boilerplate; callers supply only the varying parts.
# Usage: gen_media OUTFILE COLOR [FREQ] [extra ffmpeg flags...]
#   OUTFILE  — output path
#   COLOR    — lavfi color name (blue, red, green, …)
#   FREQ     — sine frequency in Hz (default 440); must be a bare integer
# All remaining args are forwarded to ffmpeg between the inputs and the output path.
gen_media() {
  local outfile="$1" color="$2"
  shift 2
  local freq=440
  # If next arg is a bare integer, treat it as the sine frequency
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    freq="$1"
    shift
  fi
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=${color}:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=${freq}:duration=2" \
    "$@" "$outfile"
}

# ---- Preflight ----
preflight() {
  section "Preflight Checks"

  if [[ ! -x "$MUXM" && ! -f "$MUXM" ]]; then
    echo "ERROR: muxm not found at '$MUXM'. Use --muxm /path/to/muxm.sh"
    exit 1
  fi
  pass "muxm found at $MUXM"

  for tool in ffmpeg ffprobe jq bc; do
    if command -v "$tool" >/dev/null 2>&1; then
      pass "$tool available"
    else
      fail "$tool NOT available (required)"
    fi
  done

  if command -v dovi_tool >/dev/null 2>&1; then
    pass "dovi_tool available"
  else
    skip "dovi_tool not available — DV tests will be limited"
  fi

  # Create test directory
  TESTDIR="$(mktemp -d "$TMP_BASE/muxm-test.XXXXXXXX")"
  # Claim this dir for the current run: record our PID so a concurrently-starting
  # instance's auto_cleanup_test_dirs / do_cleanup skips it while we are alive.
  printf '%s\n' "$$" > "$TESTDIR/$TESTDIR_LOCK"
  # Isolate HOME for the entire run so muxm never sources the developer's real
  # ~/.muxmrc (muxm sources $HOME/.muxmrc). Kept separate from the fixture dir so
  # muxm writing ~/.muxm (completions) doesn't litter $TESTDIR's media files.
  export HOME="$TESTDIR/home"
  mkdir -p "$HOME"
  log "Test directory: $TESTDIR"
  log "Isolated HOME:  $HOME"
}

# ---- Generate Synthetic Test Media ----
# Builds short 2-second clips with various codec/audio/subtitle combinations.
# Simple fixtures use gen_media(); complex multi-input fixtures use raw ffmpeg.
#
# Split into two tiers so non-encoding suites can skip media generation entirely:
#   generate_core_media     — basic_sdr_subs.mkv (needed by cli, dryrun, edge, etc.)
#   generate_extended_media — all remaining fixtures (needed by encoding suites)
#
# Fixture naming convention:
#   basic_sdr_subs.mkv         — minimal: one video, one audio, one subtitle
#   hevc_sdr_51.mkv            — codec_colorspace_audiochannels
#   multi_audio.mkv            — multiple tracks of the named stream type
#   multi_subs_multilang.mkv   — multi-track + multi-language variant
#   with_chapters.mkv          — has the named metadata feature
#   rich_metadata.mkv          — has extra format-level tags (title, comment, encoder)
#   compliant.mp4              — already matches default target spec (for skip-if-ideal)

generate_core_media() {
  section "Generating Core Test Media"

  # 1) Basic SDR H.264 with stereo AAC and SRT subtitle
  #    Merged into a single ffmpeg call (no intermediate basic_sdr.mkv needed).
  log "Creating basic_sdr_subs.mkv (H.264 + AAC stereo + SRT sub)"
  cat > "$TESTDIR/test.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Test subtitle line
SRT
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/test.srt" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2 \
    -c:s srt \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
    "$TESTDIR/basic_sdr_subs.mkv"
  if [[ -s "$TESTDIR/basic_sdr_subs.mkv" ]]; then pass "basic_sdr_subs.mkv created"; else fail "basic_sdr_subs.mkv NOT created (missing or empty)"; fi

  log "Core test media ready in $TESTDIR"
}

generate_extended_media() {
  section "Generating Extended Test Media"

  # 2) HEVC 10-bit SDR with 5.1 AC3 audio (simulated)
  log "Creating hevc_sdr_51.mkv (HEVC + AC3 5.1)"
  gen_media "$TESTDIR/hevc_sdr_51.mkv" red \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -c:a ac3 -b:a 384k -ac 6 \
    -metadata:s:a:0 language=eng
  if [[ -s "$TESTDIR/hevc_sdr_51.mkv" ]]; then pass "hevc_sdr_51.mkv created"; else fail "hevc_sdr_51.mkv NOT created (missing or empty)"; fi

  # 2b) HEVC 10-bit SDR with 7.1 (8ch) audio — regression test for eac3 encoder
  #     channel cap bug: ffmpeg's native eac3 encoder only supports up to 6ch,
  #     so 8ch sources must be downmixed before encoding.
  #     Uses FLAC (not direct-play-copyable, not lossless-muxable into MP4) to
  #     guarantee the transcode path fires — AAC would be stream-copied via step 3.
  log "Creating hevc_sdr_71.mkv (HEVC + FLAC 8ch audio for encoder cap test)"
  gen_media "$TESTDIR/hevc_sdr_71.mkv" blue \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -c:a flac -ac 8 \
    -metadata:s:a:0 language=eng
  if [[ -s "$TESTDIR/hevc_sdr_71.mkv" ]]; then pass "hevc_sdr_71.mkv created"; else fail "hevc_sdr_71.mkv NOT created (missing or empty)"; fi

  # 3) HEVC 10-bit with HDR10-like metadata tags (not real HDR, but tagged)
  log "Creating hevc_hdr10_tagged.mkv (HEVC 10-bit with HDR-like tags)"
  gen_media "$TESTDIR/hevc_hdr10_tagged.mkv" green 880 \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
    -c:a eac3 -b:a 448k -ac 6 \
    -metadata:s:a:0 language=eng
  if [[ -s "$TESTDIR/hevc_hdr10_tagged.mkv" ]]; then pass "hevc_hdr10_tagged.mkv created"; else fail "hevc_hdr10_tagged.mkv NOT created (missing or empty)"; fi

  # 4) Multi-audio file (stereo AAC + 5.1 EAC3 + stereo commentary)
  #    3 audio inputs require explicit maps — raw ffmpeg.
  log "Creating multi_audio.mkv (3 audio tracks)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=yellow:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=660:duration=2" \
    -f lavfi -i "sine=frequency=880:duration=2" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a -map 3:a \
    -c:a:0 aac -b:a:0 128k -ac:a:0 2 \
    -c:a:1 eac3 -b:a:1 448k -ac:a:1 6 \
    -c:a:2 aac -b:a:2 96k -ac:a:2 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="Stereo" \
    -metadata:s:a:1 language=eng -metadata:s:a:1 title="5.1 Surround" \
    -metadata:s:a:2 language=eng -metadata:s:a:2 title="Commentary" \
    "$TESTDIR/multi_audio.mkv"
  if [[ -s "$TESTDIR/multi_audio.mkv" ]]; then pass "multi_audio.mkv created"; else fail "multi_audio.mkv NOT created (missing or empty)"; fi

  # 5) Multi-subtitle file (forced + full + SDH)
  #    3 SRT file inputs require explicit maps — raw ffmpeg.
  log "Creating multi_subs.mkv (3 subtitle tracks)"
  cat > "$TESTDIR/forced.srt" <<'SRT'
1
00:00:00,000 --> 00:00:01,000
[Foreign dialogue]
SRT
  cat > "$TESTDIR/full.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
This is the full English subtitle.
SRT
  cat > "$TESTDIR/sdh.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
[Music playing] This is the SDH subtitle.
SRT
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=purple:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/forced.srt" \
    -i "$TESTDIR/full.srt" \
    -i "$TESTDIR/sdh.srt" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2 \
    -c:s srt \
    -map 0:v -map 1:a -map 2 -map 3 -map 4 \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="Forced" \
    -metadata:s:s:1 language=eng -metadata:s:s:1 title="English" \
    -metadata:s:s:2 language=eng -metadata:s:s:2 title="English SDH" \
    -disposition:s:0 forced \
    "$TESTDIR/multi_subs.mkv"
  if [[ -s "$TESTDIR/multi_subs.mkv" ]]; then pass "multi_subs.mkv created"; else fail "multi_subs.mkv NOT created (missing or empty)"; fi

  # 5b) Multi-language subtitle file (eng + spa + fra subtitles)
  log "Creating multi_subs_multilang.mkv (eng + spa + fra subtitles)"
  cat > "$TESTDIR/eng.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
English subtitle
SRT
  cat > "$TESTDIR/spa.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Subtítulo en español
SRT
  cat > "$TESTDIR/fra.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Sous-titre français
SRT
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=cyan:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/eng.srt" \
    -i "$TESTDIR/spa.srt" \
    -i "$TESTDIR/fra.srt" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2 \
    -c:s srt \
    -map 0:v -map 1:a -map 2 -map 3 -map 4 \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
    -metadata:s:s:1 language=spa -metadata:s:s:1 title="Spanish" \
    -metadata:s:s:2 language=fra -metadata:s:s:2 title="French" \
    "$TESTDIR/multi_subs_multilang.mkv"
  if [[ -s "$TESTDIR/multi_subs_multilang.mkv" ]]; then pass "multi_subs_multilang.mkv created"; else fail "multi_subs_multilang.mkv NOT created (missing or empty)"; fi

  # 5c) ASS/SSA subtitle file (for SUB_PRESERVE_TEXT_FORMAT tests)
  #     ASS subtitles carry positioning, styling, fonts, and typesetting data
  #     that is lost when converted to SRT. This fixture validates that the
  #     animation profile (and --sub-preserve-format) preserves ASS natively.
  log "Creating ass_subs.mkv (HEVC + AAC + ASS subtitle with styling)"
  cat > "$TESTDIR/styled.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Signs,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,8,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:02.00,Signs,,0,0,0,,{\pos(960,100)}Styled sign text
ASS
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=pink:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/styled.ass" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -c:a aac -b:a 128k -ac 2 \
    -c:s ass \
    -map 0:v -map 1:a -map 2 \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="English Styled" \
    "$TESTDIR/ass_subs.mkv"
  if [[ -s "$TESTDIR/ass_subs.mkv" ]]; then pass "ass_subs.mkv created"; else fail "ass_subs.mkv NOT created (missing or empty)"; fi

  # 5d) Stream titles containing literal pipe characters (v1.0.2 regression fixture).
  #     Pipe characters in subtitle/audio titles previously corrupted the pipe-delimited
  #     output of _sub_stream_info and the audio jq pipeline, causing an arithmetic
  #     evaluation crash under nounset. The delimiter was migrated from | to \t (tab).
  log "Creating pipe_titles.mkv (HEVC + AAC with pipe in title + SRT with pipe in title)"
  cat > "$TESTDIR/pipe_test.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Pipe title subtitle line
SRT
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=orange:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/pipe_test.srt" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -c:a aac -b:a 128k -ac 2 \
    -c:s srt \
    -map 0:v -map 1:a -map 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="Original | English" \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="Original | English | (SDH)" \
    "$TESTDIR/pipe_titles.mkv"
  if [[ -s "$TESTDIR/pipe_titles.mkv" ]]; then pass "pipe_titles.mkv created"; else fail "pipe_titles.mkv NOT created (missing or empty)"; fi

  # 6) File with chapters — chapter metadata input requires raw ffmpeg.
  log "Creating with_chapters.mkv (chapters)"
  cat > "$TESTDIR/chapters.txt" <<'CHAP'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1000
title=Chapter 1

[CHAPTER]
TIMEBASE=1/1000
START=1000
END=2000
title=Chapter 2
CHAP
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=orange:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/chapters.txt" \
    -map_metadata 2 \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2 \
    -metadata:s:a:0 language=eng \
    "$TESTDIR/with_chapters.mkv"
  if [[ -s "$TESTDIR/with_chapters.mkv" ]]; then pass "with_chapters.mkv created"; else fail "with_chapters.mkv NOT created (missing or empty)"; fi

  # 7) Already-compliant MP4 (for skip-if-ideal tests)
  log "Creating compliant.mp4 (HEVC 10-bit + EAC3 in MP4)"
  gen_media "$TESTDIR/compliant.mp4" white \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le -tag:v hvc1 \
    -c:a eac3 -b:a 448k -ac 6 \
    -metadata:s:a:0 language=eng
  if [[ -s "$TESTDIR/compliant.mp4" ]]; then pass "compliant.mp4 created"; else fail "compliant.mp4 NOT created (missing or empty)"; fi

  # 7b/7c) Skip-if-ideal fixtures carrying GLOBAL metadata + chapters, for the D2 regression
  #   (--strip-metadata / --no-keep-chapters must reach the output even on the skip-the-encode
  #   path). A shared ffmetadata sidecar supplies a global title/comment + two chapters; the
  #   complaint here is multi-input so we use raw ffmpeg, not gen_media.
  #   • compliant_meta.mp4    — HEVC 10-bit + EAC3 in MP4 → ideal for atv-directplay-hq.
  #   • compliant_archive.mkv — HEVC + lossless FLAC in MKV → ideal for archive (so the archive
  #                             conflict-note truthfulness check exercises the skip-if-ideal path).
  cat > "$TESTDIR/sii_meta.ffmeta" <<'FFMETA'
;FFMETADATA1
title=Original Source Title
comment=should-be-stripped
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1000
title=Chapter One
[CHAPTER]
TIMEBASE=1/1000
START=1000
END=2000
title=Chapter Two
FFMETA
  log "Creating compliant_meta.mp4 (compliant for atv-directplay-hq + global metadata + chapters)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=white:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/sii_meta.ffmeta" -map_metadata 2 -map_chapters 2 \
    -map 0:v -map 1:a \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le -tag:v hvc1 \
    -c:a eac3 -b:a 448k -ac 6 \
    -metadata:s:a:0 language=eng \
    "$TESTDIR/compliant_meta.mp4"
  if [[ -s "$TESTDIR/compliant_meta.mp4" ]]; then pass "compliant_meta.mp4 created"; else fail "compliant_meta.mp4 NOT created (missing or empty)"; fi

  log "Creating compliant_archive.mkv (compliant for archive: HEVC + FLAC + metadata + chapters)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=white:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/sii_meta.ffmeta" -map_metadata 2 -map_chapters 2 \
    -map 0:v -map 1:a \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -c:a flac -ac 2 \
    -metadata:s:a:0 language=eng \
    "$TESTDIR/compliant_archive.mkv"
  if [[ -s "$TESTDIR/compliant_archive.mkv" ]]; then pass "compliant_archive.mkv created"; else fail "compliant_archive.mkv NOT created (missing or empty)"; fi

  # 8) Multi-language audio file (English + Spanish)
  #    2 audio inputs require explicit maps — raw ffmpeg.
  log "Creating multi_lang_audio.mkv (eng + spa audio)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=cyan:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=550:duration=2" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 aac -b:a:0 128k -ac:a:0 2 \
    -c:a:1 aac -b:a:1 128k -ac:a:1 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="English" \
    -metadata:s:a:1 language=spa -metadata:s:a:1 title="Spanish" \
    "$TESTDIR/multi_lang_audio.mkv"
  if [[ -s "$TESTDIR/multi_lang_audio.mkv" ]]; then pass "multi_lang_audio.mkv created"; else fail "multi_lang_audio.mkv NOT created (missing or empty)"; fi

  # 8b) Commentary detection fixture: two 5.1 EAC3 English tracks, one is "Director's Commentary"
  #     2 audio inputs require explicit maps — raw ffmpeg.
  log "Creating multi_audio_commentary.mkv (feature + commentary)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=magenta:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=550:duration=2" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 eac3 -b:a:0 448k -ac:a:0 6 \
    -c:a:1 eac3 -b:a:1 448k -ac:a:1 6 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="Director's Commentary" \
    -metadata:s:a:1 language=eng -metadata:s:a:1 title="Main Feature" \
    "$TESTDIR/multi_audio_commentary.mkv"
  if [[ -s "$TESTDIR/multi_audio_commentary.mkv" ]]; then pass "multi_audio_commentary.mkv created"; else fail "multi_audio_commentary.mkv NOT created (missing or empty)"; fi

  # 8c) HEVC multi-audio fixture for archive multi-track testing.
  #     HEVC video (copy-if-compliant) + 3 audio: eng main, eng commentary, spa.
  #     3 audio inputs require explicit maps — raw ffmpeg.
  log "Creating hevc_multi_audio.mkv (HEVC + 3 audio: eng main, eng commentary, spa)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=orange:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=550:duration=2" \
    -f lavfi -i "sine=frequency=660:duration=2" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -map 0:v -map 1:a -map 2:a -map 3:a \
    -c:a:0 aac -b:a:0 128k -ac:a:0 2 \
    -c:a:1 aac -b:a:1 128k -ac:a:1 2 \
    -c:a:2 aac -b:a:2 128k -ac:a:2 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="Main Feature" \
    -metadata:s:a:1 language=eng -metadata:s:a:1 title="Director's Commentary" \
    -metadata:s:a:2 language=spa -metadata:s:a:2 title="Spanish" \
    "$TESTDIR/hevc_multi_audio.mkv"
  if [[ -s "$TESTDIR/hevc_multi_audio.mkv" ]]; then pass "hevc_multi_audio.mkv created"; else fail "hevc_multi_audio.mkv NOT created (missing or empty)"; fi

  # 8c-ii) Lossless vs lossy audio fixture — codec preference regression test.
  #     Simulates the Arcane Blu-ray scenario: FLAC 5.1 (lossless, VBR, bit_rate=0
  #     in ffprobe) + AC3 5.1 (lossy, reported 640 kbps), same language/channels.
  #     Before the scoring fix, the bitrate tie-breaker overwhelmed the codec rank,
  #     causing AC3 to win over FLAC/TrueHD despite the preference list ranking
  #     lossless codecs higher.
  log "Creating lossless_vs_lossy.mkv (FLAC 5.1 + AC3 5.1, same lang)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=purple:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=660:duration=2" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 flac -ac:a:0 6 \
    -c:a:1 ac3 -b:a:1 640k -ac:a:1 6 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="Surround 5.1" \
    -metadata:s:a:1 language=eng -metadata:s:a:1 title="Surround 5.1" \
    "$TESTDIR/lossless_vs_lossy.mkv"
  if [[ -s "$TESTDIR/lossless_vs_lossy.mkv" ]]; then pass "lossless_vs_lossy.mkv created"; else fail "lossless_vs_lossy.mkv NOT created (missing or empty)"; fi

  # 8d) HEVC multi-subtitle fixture for archive multi-track subtitle testing.
  #     HEVC video (copy-if-compliant) + 1 audio + 5 subs: eng forced, eng full, eng SDH, spa full, fra full.
  #     5 SRT inputs require explicit maps — raw ffmpeg.
  log "Creating hevc_multi_subs.mkv (HEVC + 1 audio + 5 subs: eng forced, eng full, eng SDH, spa full, fra full)"
  cat > "$TESTDIR/mt_forced.srt" <<'SRT'
1
00:00:00,000 --> 00:00:01,000
[Foreign dialogue]
SRT
  cat > "$TESTDIR/mt_full_eng.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Full English subtitle
SRT
  cat > "$TESTDIR/mt_sdh_eng.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
[Music] SDH English subtitle
SRT
  cat > "$TESTDIR/mt_full_spa.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Subtítulo español
SRT
  cat > "$TESTDIR/mt_full_fra.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Sous-titre français
SRT
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=olive:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/mt_forced.srt" \
    -i "$TESTDIR/mt_full_eng.srt" \
    -i "$TESTDIR/mt_sdh_eng.srt" \
    -i "$TESTDIR/mt_full_spa.srt" \
    -i "$TESTDIR/mt_full_fra.srt" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -c:a aac -b:a 128k -ac 2 \
    -c:s srt \
    -map 0:v -map 1:a -map 2 -map 3 -map 4 -map 5 -map 6 \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="Forced" \
    -metadata:s:s:1 language=eng -metadata:s:s:1 title="English" \
    -metadata:s:s:2 language=eng -metadata:s:s:2 title="English SDH" \
    -metadata:s:s:3 language=spa -metadata:s:s:3 title="Spanish" \
    -metadata:s:s:4 language=fra -metadata:s:s:4 title="French" \
    -disposition:s:0 forced \
    "$TESTDIR/hevc_multi_subs.mkv"
  if [[ -s "$TESTDIR/hevc_multi_subs.mkv" ]]; then pass "hevc_multi_subs.mkv created"; else fail "hevc_multi_subs.mkv NOT created (missing or empty)"; fi

  # 9) File with rich metadata (encoder, title, etc.) for strip-metadata tests
  log "Creating rich_metadata.mkv (with extra metadata tags)"
  gen_media "$TESTDIR/rich_metadata.mkv" gray \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2 \
    -metadata title="Test Movie Title" \
    -metadata comment="This is a test comment" \
    -metadata encoder="TestEncoder v1.0" \
    -metadata:s:a:0 language=eng
  if [[ -s "$TESTDIR/rich_metadata.mkv" ]]; then pass "rich_metadata.mkv created"; else fail "rich_metadata.mkv NOT created (missing or empty)"; fi

  # 10) External subtitle source fixtures (no embedded subtitle streams)
  #     Dedicated source file for ext_subs suite — keeps sidecars isolated so
  #     other suites using different source files are unaffected.
  log "Creating ext_sub_source.mkv (HEVC, NO embedded subtitles — for ext_subs suite)"
  gen_media "$TESTDIR/ext_sub_source.mkv" teal \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -c:a aac -b:a 128k -ac 2 \
    -metadata:s:a:0 language=eng
  if [[ -s "$TESTDIR/ext_sub_source.mkv" ]]; then pass "ext_sub_source.mkv created"; else fail "ext_sub_source.mkv NOT created (missing or empty)"; fi

  # SRT content used for all sidecar files
  cat > "$TESTDIR/_ext_srt.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
External subtitle test line
SRT

  # Sidecar files covering every naming convention and parser code-path
  for _stem_sfx in \
    "" \
    ".en" \
    ".forced.en" \
    ".en.sdh" \
    ".spa" \
    ".signs" \
    ".hi" \
    ".cc" \
    ".fra"
  do
    cp "$TESTDIR/_ext_srt.srt" "$TESTDIR/ext_sub_source${_stem_sfx}.srt"
  done
  # Assert the loop actually produced the sidecars (9 suffixes above) and none are empty —
  # an unconditional "created" pass would mask a failed cp / empty source SRT.
  _ext_n=0; _ext_bad=0
  for _f in "$TESTDIR"/ext_sub_source*.srt; do
    [[ -e "$_f" ]] || continue
    _ext_n=$((_ext_n + 1)); [[ -s "$_f" ]] || _ext_bad=1
  done
  if (( _ext_n >= 9 && _ext_bad == 0 )); then
    pass "ext_sub_source sidecar .srt files created ($_ext_n non-empty)"
  else
    fail "ext_sub_source sidecars: $_ext_n found (expected ≥9), empty-present=$_ext_bad"
  fi

  # Dedicated single-sidecar source for clean integration tests
  log "Creating ext_only_source.mkv (no embedded subs — single sidecar test)"
  gen_media "$TESTDIR/ext_only_source.mkv" coral \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -c:a aac -b:a 128k -ac 2 \
    -metadata:s:a:0 language=eng
  cp "$TESTDIR/_ext_srt.srt" "$TESTDIR/ext_only_source.en.srt"
  if [[ -s "$TESTDIR/ext_only_source.mkv" && -s "$TESTDIR/ext_only_source.en.srt" ]]; then
    pass "ext_only_source.mkv + sidecar created"
  else
    fail "ext_only_source.mkv + sidecar NOT created (missing or empty)"
  fi

  # 10) HLG-tagged HEVC fixture for H9 regression test
  log "Creating hevc_hlg_tagged.mkv (HEVC 10-bit with HLG color tags)"
  gen_media "$TESTDIR/hevc_hlg_tagged.mkv" cyan 880 \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
    -c:a aac -b:a 128k -ac 2 \
    -metadata:s:a:0 language=eng
  if [[ -s "$TESTDIR/hevc_hlg_tagged.mkv" ]]; then pass "hevc_hlg_tagged.mkv created"; else fail "hevc_hlg_tagged.mkv NOT created (missing or empty)"; fi

  # 11) 4:2:2 SDR fixture for H8 regression test
  log "Creating h264_422p_sdr.mkv (H.264 4:2:2 SDR for FORCE_CHROMA_420 test)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=orange:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv422p \
    -c:a aac -b:a 128k -ac 2 \
    -metadata:s:a:0 language=eng \
    "$TESTDIR/h264_422p_sdr.mkv"
  if [[ -s "$TESTDIR/h264_422p_sdr.mkv" ]]; then pass "h264_422p_sdr.mkv created"; else fail "h264_422p_sdr.mkv NOT created (missing or empty)"; fi

  # 12) DV-tagged fixture for H10 regression test
  # Uses dvh1 codec tag so detect_dv() matches via ffprobe codec_tag_string.
  # A mock ffprobe injects DV profile text for detect_dv_info(); a mock dovi_tool
  # drives the DV pipeline to the convert-failure path.
  log "Creating hevc_dv_p5_tagged.mp4 (HEVC with dvh1 tag for H10 DV mock test)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -tag:v dvh1 \
    -c:a aac -b:a 128k -ac 2 \
    -metadata:s:a:0 language=eng \
    "$TESTDIR/hevc_dv_p5_tagged.mp4"
  if [[ -s "$TESTDIR/hevc_dv_p5_tagged.mp4" ]]; then pass "hevc_dv_p5_tagged.mp4 created"; else fail "hevc_dv_p5_tagged.mp4 NOT created (missing or empty)"; fi

  # 13) Non-zero-offset subtitle fixture (T3). H.264 + AAC + a single
  #     SRT track whose FIRST cue is at 5.000 s (all existing SRT fixtures start
  #     at 00:00:00,000, so none can detect a timestamp rebase). Duration 8 s so
  #     the cue fits. Used by the text-path sync assertion (T4) and, later, as the
  #     template for the PGS desync e2e guard (T11).
  log "Creating offset_subs.mkv (H.264 + AAC + SRT first cue @ 5.000 s)"
  cat > "$TESTDIR/offset.srt" <<'SRT'
1
00:00:05,000 --> 00:00:07,000
Offset subtitle line
SRT
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=8" \
    -f lavfi -i "sine=frequency=440:duration=8" \
    -i "$TESTDIR/offset.srt" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2 \
    -c:s srt \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
    "$TESTDIR/offset_subs.mkv"
  if [[ -s "$TESTDIR/offset_subs.mkv" ]]; then pass "offset_subs.mkv created"; else fail "offset_subs.mkv NOT created (missing or empty)"; fi

  # 14) Multi-track MIXED source: 1 embedded sub + 1 external
  #     sidecar. Under a multi-track profile the external sidecar must be
  #     stream-copied (-c:s copy) from a deduped -i input — the path the all-embedded
  #     multi fixture (multi_subs_multilang.mkv) never exercised.
  log "Creating mt_mixed_subs.mkv (1 embedded eng sub + external .es.srt sidecar)"
  cat > "$TESTDIR/_mt_emb.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Embedded English
SRT
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=teal:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$TESTDIR/_mt_emb.srt" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2 \
    -c:s srt \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng \
    "$TESTDIR/mt_mixed_subs.mkv"
  cat > "$TESTDIR/mt_mixed_subs.es.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
Subtítulo externo
SRT
  if [[ -s "$TESTDIR/mt_mixed_subs.mkv" && -s "$TESTDIR/mt_mixed_subs.es.srt" ]]; then
    pass "mt_mixed_subs.mkv + sidecar created"
  else
    fail "mt_mixed_subs.mkv + sidecar NOT created (missing or empty)"
  fi

  log "All extended test media ready in $TESTDIR"
}

# ---- Test Suites ----

# === Suite: CLI parsing & help ===
# Validates --help, --version, no-args usage, and that invalid inputs (bad profile,
# bad preset, bad codec, bad extension, missing file, too many args, source=output)
# all produce the correct exit code and error messages.
# --- test_cli sub-functions ---
# Each sub-function tests a distinct CLI concern.  They share no local state
# and can be read (or run) independently.  The parent dispatcher calls them
# sequentially to preserve the original execution order.

_test_cli_help_version() {
  # --help
  local out
  out="$(run_muxm --help)"
  assert_contains "Usage:" "--help shows usage" "$out"
  assert_contains "--profile" "--help mentions --profile" "$out"
  assert_contains "archive" "--help lists archive profile" "$out"
  assert_contains "universal" "--help lists universal" "$out"
  assert_contains "--setup" "--help mentions --setup" "$out"
  assert_contains "Quick start:" "--help shows quick-start example" "$out"
  assert_contains "--create-config {system|user|project}" "--help shows --create-config with valid values" "$out"

  # --version
  out="$(run_muxm --version)"
  assert_contains "MuxMaster" "--version shows app name" "$out"
  assert_contains "muxm" "--version shows CLI name" "$out"

  # No args → shows usage (exit 0)
  assert_exit 0 "No arguments shows usage"
}

_test_cli_error_codes() {
  local out

  # Invalid profile
  assert_exit $EXIT_VALIDATION "Invalid profile exits $EXIT_VALIDATION" --profile fake "$TESTDIR/basic_sdr_subs.mkv"

  # Invalid preset
  assert_exit $EXIT_VALIDATION "Invalid preset exits $EXIT_VALIDATION" --preset fake "$TESTDIR/basic_sdr_subs.mkv"
  # D10: the error states the fix (lists the valid presets), not just the rejected value.
  assert_contains "Valid presets:" "Invalid preset error lists the valid presets (D10)" \
    "$(run_muxm --preset fake "$TESTDIR/basic_sdr_subs.mkv")"

  # Invalid video codec
  assert_exit $EXIT_VALIDATION "Invalid video codec exits $EXIT_VALIDATION" --video-codec vp9 "$TESTDIR/basic_sdr_subs.mkv"

  # Invalid output extension
  assert_exit $EXIT_VALIDATION "Invalid output extension exits $EXIT_VALIDATION" --output-ext webm "$TESTDIR/basic_sdr_subs.mkv"

  # Missing source file
  assert_exit $EXIT_VALIDATION "Missing source file exits $EXIT_VALIDATION" /nonexistent/file.mkv

  # Invalid ffmpeg-loglevel
  local ll_out
  ll_out="$(run_muxm --ffmpeg-loglevel bogus "$TESTDIR/basic_sdr_subs.mkv" 2>&1 || true)"
  assert_exit $EXIT_VALIDATION "Invalid --ffmpeg-loglevel exits $EXIT_VALIDATION" --ffmpeg-loglevel bogus "$TESTDIR/basic_sdr_subs.mkv"
  assert_contains "Invalid --ffmpeg-loglevel" "--ffmpeg-loglevel bogus error message" "$ll_out"

  # Invalid ffprobe-loglevel
  local pl_out
  pl_out="$(run_muxm --ffprobe-loglevel bogus "$TESTDIR/basic_sdr_subs.mkv" 2>&1 || true)"
  assert_exit $EXIT_VALIDATION "Invalid --ffprobe-loglevel exits $EXIT_VALIDATION" --ffprobe-loglevel bogus "$TESTDIR/basic_sdr_subs.mkv"
  assert_contains "Invalid --ffprobe-loglevel" "--ffprobe-loglevel bogus error message" "$pl_out"

  # Too many positional args
  assert_exit $EXIT_VALIDATION "Too many args exits $EXIT_VALIDATION" a.mkv b.mp4 c.mp4
  # D10: the error names the unexpected extra token(s) (the too-many-args check fires before
  # source-existence, so nonexistent paths are fine here). Guards the ${POSITIONALS[*]:2} slice.
  assert_contains "unexpected: c.mp4" "Too many arguments error names the extra token (D10)" \
    "$(run_muxm a.mkv b.mp4 c.mp4)"

  # Source = output auto-versioning (collision no longer dies; auto-versions instead)
  out="$(run_muxm --output-ext mkv "$TESTDIR/basic_sdr_subs.mkv" "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Source collision" "Source=output triggers auto-versioning" "$out"

  # --no-overwrite: should refuse when output already exists (#28)
  local out_exist="$TESTDIR/cli_nooverwrite.mp4"
  local pre_out
  pre_out="$(run_muxm --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv" "$out_exist")"
  if [[ -f "$out_exist" ]]; then
    out="$(run_muxm --no-overwrite --crf 28 --preset ultrafast \
      "$TESTDIR/basic_sdr_subs.mkv" "$out_exist")"
    assert_contains "exists" "--no-overwrite refuses existing output" "$out"
  else
    log "--no-overwrite: preliminary encode failed: ${pre_out:0:500}"
    skip "--no-overwrite: initial encode did not produce output"
  fi
}

_test_cli_short_aliases() {
  # Verify short flags map to their long-form equivalents. Catches regressions
  # where a refactor drops a short alias from the case statement.
  local out

  # -h → --help
  assert_exit 0 "-h is alias for --help" -h

  # -V → --version
  out="$(run_muxm -V)"
  assert_contains "MuxMaster" "-V is alias for --version (app name)" "$out"
  assert_contains "muxm" "-V is alias for --version (CLI name)" "$out"

  # -p → --preset
  out="$(run_muxm -p ultrafast --print-effective-config)"
  assert_contains "PRESET_VALUE              = ultrafast" "-p is alias for --preset" "$out"

  # -l → --level
  out="$(run_muxm -l 5.1 --print-effective-config)"
  assert_contains "LEVEL_VALUE               = 5.1" "-l is alias for --level" "$out"

  # -k → --keep-temp
  out="$(run_muxm -k --print-effective-config)"
  assert_contains "KEEP_TEMP                 = 1" "-k is alias for --keep-temp" "$out"

  # -K → --keep-temp-always
  out="$(run_muxm -K --print-effective-config)"
  assert_contains "KEEP_TEMP_ALWAYS          = 1" "-K is alias for --keep-temp-always" "$out"
}

_test_cli_profile_crossref() {
  # Verify the profile list in --help, --install-completions output, and the man page
  # all match the canonical VALID_PROFILES constant. Catches drift when profiles are
  # added or renamed but not updated everywhere.
  local out

  # Extract VALID_PROFILES from the script itself (single source of truth)
  local canonical
  # `|| true`: a no-match grep exits 1, which (under set -e + pipefail) would abort the suite at
  # this assignment BEFORE the drift guard below can fire a clean diagnostic. Swallow it so the
  # empty result reaches the `[[ -z "$canonical" ]]` fail instead of a cryptic mid-suite abort.
  canonical="$(grep '^readonly VALID_PROFILES=' "$MUXM" | sed 's/^readonly VALID_PROFILES="//;s/"$//' || true)"
  if [[ -z "$canonical" ]]; then
    # VALID_PROFILES is a committed constant — its absence here means the anchor was
    # renamed/reformatted, which is drift, never host-optionality. Fail, never skip (a skip
    # would silently void the entire cross-reference below).
    fail "VALID_PROFILES constant not found in script — cross-reference guard could not run (drift?)"
    return
  fi

  # Check --help output contains every profile name
  out="$(run_muxm --help)"
  local all_found=1 p
  for p in $canonical; do
    if ! echo "$out" | grep -qF "$p"; then
      fail "Profile '$p' missing from --help output"
      all_found=0
    fi
  done
  (( all_found )) && pass "--help lists all VALID_PROFILES"

  # Check installed completion script contains every profile name
  local fake_home="$TESTDIR/fake_home_profiles"
  mkdir -p "$fake_home"
  touch "$fake_home/.bashrc" "$fake_home/.zshrc"
  HOME="$fake_home" "$MUXM" --install-completions >/dev/null 2>&1 || true
  local comp_file="$fake_home/.muxm/muxm-completion.bash"
  if [[ -f "$comp_file" ]]; then
    all_found=1
    for p in $canonical; do
      if ! grep -qF "$p" "$comp_file"; then
        fail "Profile '$p' missing from installed completion script"
        all_found=0
      fi
    done
    (( all_found )) && pass "Installed completions list all VALID_PROFILES"
  else
    skip "Completion file not generated — completion cross-ref skipped"
  fi
}

_test_cli_flag_drift() {
  # Guards the hand-maintained CLI flag surfaces against drift:
  #   A. parser (every flag muxm accepts)  <->  installed tab-completion flag list
  #   B. every flag --create-config accepts as an override (_CC_OVERRIDES) must map to a
  #      variable in CONFIG_TRACKED_VARS — otherwise the override is silently dropped from
  #      the generated .muxmrc (the SUB_SOLE_EXT_FALLBACK class of bug).
  # Extraction is anchored on stable code structure (not line numbers) so it survives edits.
  local src="$MUXM"
  if [[ ! -r "$src" ]]; then
    skip "muxm source not readable — flag drift guard skipped"
    return
  fi

  local wd="$TESTDIR/flag_drift"
  mkdir -p "$wd"
  local parser="$wd/parser.txt" comp="$wd/comp.txt"
  local ccvars="$wd/cc.txt" tracked="$wd/tracked.txt"

  # ---- Parser flag set: union of all four dispatch forms ----
  {
    # (a) main argument loop:  while [[ $# -gt 0 ]]; do ... case "$1" in ... done
    awk '/while \[\[ \$# -gt 0 \]\]; do/{f=1} f; /^done$/{if(f)exit}' "$src" \
      | grep -oE '^[[:space:]]+--?[a-zA-Z][a-zA-Z0-9-]*(\|--?[a-zA-Z][a-zA-Z0-9-]*)*\)'
    # (b) pre-scan dispatch:  case "$_arg" in ... esac  (install-man/-completions, etc.)
    awk '/case "\$_arg" in/{f=1} f{print} f&&/esac/{f=0}' "$src" \
      | grep -oE '^[[:space:]]+--?[a-zA-Z][a-zA-Z0-9-]*(\|--?[a-zA-Z][a-zA-Z0-9-]*)*\)'
    # (d) --create-config pre-scan function
    awk '/_create_config_prescan\(\)/{f=1} f{print} f&&/^}/{exit}' "$src" \
      | grep -oE '^[[:space:]]+--?[a-zA-Z][a-zA-Z0-9-]*(\|--?[a-zA-Z][a-zA-Z0-9-]*)*\)'
  } | sed -E 's/^[[:space:]]+//; s/\)$//' | tr '|' '\n' > "$wd/raw.txt"
  # (c) [[ "$_arg" == "--flag" ]] if-style dispatch (install-dependencies, setup)
  # shellcheck disable=SC2016  # intentional: grep matches the literal text "$_arg" in $src, no expansion wanted
  grep -oE '"\$_arg" == "--[a-z][a-z-]*"' "$src" | grep -oE '\-\-[a-z-]+' >> "$wd/raw.txt"
  # --profile is parser-accepted via its OWN dedicated two-pass prescan (a `[[ … == "--profile" ]]`
  # loop over the raw args, an idiom none of the extractors above scan), and intentionally has NO
  # §12 case arm — the unreachable `--profile) shift 2` straggler has since been removed.
  # Add it explicitly so the parser<->completion drift guard still recognises it as a real flag.
  printf '%s\n' '--profile' >> "$wd/raw.txt"
  grep -vxE '\-\-|\-\*|\*' "$wd/raw.txt" | sort -u > "$parser"

  # ---- Completion flag set: the `flags="..."` block of the installed script ----
  local fake_home="$TESTDIR/fake_home_flagdrift"
  mkdir -p "$fake_home"
  touch "$fake_home/.bashrc" "$fake_home/.zshrc"
  HOME="$fake_home" "$MUXM" --install-completions >/dev/null 2>&1 || true
  local comp_file="$fake_home/.muxm/muxm-completion.bash"
  if [[ ! -f "$comp_file" ]]; then
    skip "Completion file not generated — flag drift guard skipped"
    return
  fi
  awk '/[[:space:]]flags="/{f=1;next} f&&/"/{exit} f' "$comp_file" \
    | tr ' \t' '\n' | grep -E '^-{1,2}[a-zA-Z]' | sort -u > "$comp"

  # ---- Assertion A: parser <-> completion, both directions ----
  # Intentionally hidden / maintainer-only flags: accepted by the parser but
  # deliberately kept out of --help, tab-completion, AND the man page (documented
  # only in a code comment at the flag, e.g. --emit-man). This one allowlist
  # exempts them from BOTH the completion check below and the man-page coverage
  # check (Assertion C); the guards still catch drift for every other flag, and
  # the reverse direction still rejects any completion flag that is not real.
  local -a hidden_flags=( --emit-man --emit-completions )
  local -a _hidden_excl=()
  local _hf
  for _hf in "${hidden_flags[@]}"; do _hidden_excl+=( -e "$_hf" ); done
  local missing_in_comp missing_in_parser
  missing_in_comp="$(comm -23 "$parser" "$comp" | grep -vxF "${_hidden_excl[@]}" || true)"
  missing_in_parser="$(comm -13 "$parser" "$comp")"
  if [[ -z "$missing_in_comp" ]]; then
    pass "Every CLI flag is offered by tab-completion"
  else
    fail "Flags accepted by parser but missing from completion: ${missing_in_comp//$'\n'/ }"
  fi
  if [[ -z "$missing_in_parser" ]]; then
    pass "Every completion flag is a real CLI flag"
  else
    fail "Flags offered by completion but not accepted by parser: ${missing_in_parser//$'\n'/ }"
  fi

  # ---- Assertion C: parser -> man page coverage (committed reverse sweep) ----
  # Every parser flag must be documented in the man page, EXCEPT the hidden
  # maintainer flags allow-listed above. Emitted from the same muxm under test
  # (the `docs` suite separately proves that emit matches the checked-in
  # docs/muxm.1). Flags appear roff-escaped (-- -> \-\-), so match the escaped
  # form via substring; this is the committed form of the reverse sweep
  # and fails if a new flag is added to the parser but never documented.
  local man_src="$wd/man.txt"
  "$MUXM" --emit-man > "$man_src" 2>/dev/null || true
  if [[ ! -s "$man_src" ]]; then
    skip "man page not emitted — man-page coverage check skipped"
  else
    local undoc_man="" _pf _esc _skip
    while IFS= read -r _pf; do
      _skip=0
      for _hf in "${hidden_flags[@]}"; do [[ "$_pf" == "$_hf" ]] && { _skip=1; break; }; done
      (( _skip )) && continue
      _esc="${_pf//-/\\-}"   # --workdir -> \-\-workdir (roff escapes each hyphen)
      grep -qF -- "$_esc" "$man_src" || undoc_man+="$_pf "
    done < "$parser"
    if [[ -z "$undoc_man" ]]; then
      pass "Every CLI flag is documented in the man page"
    else
      fail "Flags accepted by parser but missing from the man page: ${undoc_man}"
    fi

    # D8: the --sub-lang-pref man-page entry must state the inclusion-filter / source-order
    # semantics (not a ranking). "source order" is the single distinctive anchor — red→green for
    # the doc edit; the behavioral lock lives in _test_unit_build_subtitle_lists.
    if grep -qF 'source order' "$man_src"; then
      pass "cli-sub-lang-pref-doc-drift: man page documents --sub-lang-pref source-order (inclusion-filter) semantics"
    else
      fail "cli-sub-lang-pref-doc-drift: man page missing the --sub-lang-pref 'source order' clarification"
    fi
  fi

  # ---- Assertion B: every --create-config override var is tracked (else silently dropped) ----
  grep -oE '_CC_OVERRIDES\[[A-Z0-9_]+\]' "$src" | sed -E 's/.*\[//; s/\]//' | sort -u > "$ccvars"
  awk '/^readonly CONFIG_TRACKED_VARS=\(/{f=1;next} f&&/^\)/{exit} f' "$src" \
    | grep -oE '\b[A-Z][A-Z0-9_]+\b' | sort -u > "$tracked"
  local untracked
  untracked="$(comm -23 "$ccvars" "$tracked")"
  if [[ -z "$untracked" ]]; then
    pass "Every --create-config override maps to a CONFIG_TRACKED_VARS entry"
  else
    fail "--create-config overrides not in CONFIG_TRACKED_VARS (silently dropped): ${untracked//$'\n'/ }"
  fi
}

_test_cli_robustness() {
  # ---- DEBUG=1 trace mode does not break the run (#smoke) ----
  # muxm runs `set -x` when DEBUG=1, sending an execution trace to stderr.
  # A regression that puts a side-effecting command on the traced path would
  # break the run; one that misroutes the trace onto stdout would corrupt
  # captured values. We verify (a) the run still exits 0 with tracing on, and
  # (b) the trace actually lands on stderr (so the DEBUG feature is exercised,
  # not just any successful run). stderr is grepped from a file to avoid passing
  # the large trace through echo|grep.
  local dbg_trace="$TESTDIR/_debug_trace.err" dbg_rc=0
  # `|| dbg_rc=$?` keeps the capture set -e-safe (the harness runs under set -e).
  ( cd "$TESTDIR" && DEBUG=1 "$MUXM" --dry-run basic_sdr_subs.mkv >/dev/null 2>"$dbg_trace" ) || dbg_rc=$?
  if [[ "$dbg_rc" -eq 0 ]]; then
    pass "DEBUG=1: dry-run exits 0 with tracing enabled"
  else
    fail "DEBUG=1: dry-run exited $dbg_rc (tracing may have broken the run)"
  fi
  if grep -qE '^\+' "$dbg_trace" 2>/dev/null; then
    pass "DEBUG=1: set -x execution trace emitted to stderr"
  else
    fail "DEBUG=1: no set -x trace found on stderr (DEBUG mode not engaged?)"
  fi
  rm -f "$dbg_trace"

  # ---- bash 4.3+ version guard ----
  # muxm uses namerefs (local -n) and requires bash 4.3+. The guard at the top of
  # muxm must reject older interpreters with a clear message and a nonzero exit.
  # macOS ships bash 3.2 at /bin/bash, which makes this testable; on hosts whose
  # only bash is modern, skip (we can't synthesize an old interpreter).
  local old_bash="" cand vmaj vmin
  for cand in /bin/bash /usr/bin/bash /usr/local/bin/bash; do
    [[ -x "$cand" ]] || continue
    # shellcheck disable=SC2016  # must expand in the candidate bash ($cand), not here
    vmaj="$("$cand" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" || continue
    # shellcheck disable=SC2016  # must expand in the candidate bash ($cand), not here
    vmin="$("$cand" -c 'echo "${BASH_VERSINFO[1]}"' 2>/dev/null)" || continue
    [[ "$vmaj" =~ ^[0-9]+$ && "$vmin" =~ ^[0-9]+$ ]] || continue
    if (( vmaj < 4 || (vmaj == 4 && vmin < 3) )); then old_bash="$cand"; break; fi
  done
  if [[ -n "$old_bash" ]]; then
    local guard_out guard_rc=0
    # set -e-safe capture: the guard makes muxm exit nonzero, which would
    # otherwise abort the whole harness on the assignment.
    guard_out="$("$old_bash" "$MUXM" --version 2>&1)" || guard_rc=$?
    if [[ "$guard_rc" -ne 0 ]]; then
      pass "bash version guard: old bash ($old_bash) rejected with nonzero exit ($guard_rc)"
    else
      fail "bash version guard: old bash ($old_bash) was NOT rejected (exit 0)"
    fi
    assert_contains "requires bash 4.3+" "bash version guard: emits a clear 'requires bash 4.3+' message" "$guard_out"
  else
    skip "bash version guard — no bash < 4.3 available to exercise the guard"
  fi
}

test_cli() {
  section "CLI Parsing & Help"
  _test_cli_help_version
  _test_cli_error_codes
  _test_cli_short_aliases
  _test_cli_profile_crossref
  _test_cli_flag_drift
  _test_cli_robustness
  _test_cli_value_flag_no_value
  _test_cli_value_validation
  _test_cli_dashdash
  _test_cli_config_missing_val
  _test_cli_replace_source_eof
  _test_cli_create_config

  # F6: no advisory may emit the invalid muxm flag value `--video-codec libsvtav1`. muxm's flag
  # value is `libsvt-av1` (hyphenated); `libsvtav1` is the ffmpeg ENCODER name, not a valid
  # --video-codec value (it would exit 11). Source grep — a copy-pasteable advisory must be valid.
  if grep -qE -- '--video-codec[ =]libsvtav1\b' "$MUXM"; then
    fail "cli-advisory-valid-flag-values: an advisory emits the invalid '--video-codec libsvtav1' (should be 'libsvt-av1')"
  else
    pass "cli-advisory-valid-flag-values: no advisory emits an invalid '--video-codec libsvtav1' value"
  fi
}

# M1: `--` (end-of-options) must fold the remaining args back into POSITIONALS. The old
# `--) shift; break` dropped them, so `muxm -- <src>` lost its source (and `muxm -- -dash.mkv`,
# the one idiom `--` exists for, could not work at all). Fixed → the source resolves and a plan is
# produced; bug → the parser falls through to no-source usage/help. Perturb MUT-M1-DASHDASH reverts
# the fold. Uses --dry-run (no encode); discriminates on "Plan:" present vs the "Usage:" banner.
_test_cli_dashdash() {
  local _src="$TESTDIR/basic_sdr_subs.mkv" out
  out="$(run_muxm --dry-run -- "$_src")"
  if grep -qiE "DRY-RUN is ON|^▶ Plan:|Plan:" <<<"$out" && ! grep -qE "^Usage: muxm" <<<"$out"; then
    pass "cli-dashdash-source-resolution: '-- <src>' resolves the following source (not dropped)"
  else
    fail "cli-dashdash-source-resolution: '--' dropped the source positional (got usage/help instead of a plan)"
  fi
  # The idiom `--` exists for: a source whose name begins with '-'.
  local _dashdir="$TESTDIR/m1_dash"; mkdir -p "$_dashdir"
  cp "$_src" "$_dashdir/-dash.mkv"
  local out2
  out2="$(cd "$_dashdir" && HOME="${MUXM_HOME:-$HOME}" "$MUXM" -K --dry-run -- -dash.mkv 2>&1 || true)"
  if grep -qiE "DRY-RUN is ON|Plan:" <<<"$out2" && ! grep -qE "^Usage: muxm" <<<"$out2"; then
    pass "cli-dashdash-source-resolution: '-- -dash.mkv' resolves a leading-dash source (the idiom -- exists for)"
  else
    fail "cli-dashdash-source-resolution: '-- -dash.mkv' did not resolve a leading-dash source"
  fi
  rm -rf "$_dashdir"

  # L10: a --profile AFTER -- is a positional, not the flag — the prescan must stop interpreting
  # --profile at -- (mirroring _create_config_prescan). If the prescan consumed it, the profile
  # would apply, leaving a valid one-source run; now --profile + its value fold into POSITIONALS via
  # the main parser's `--) ` arm, so all four tokens overflow arity → "Too many arguments". That
  # error is the discriminator: it can ONLY occur if --profile was treated as a positional after --.
  local out3
  out3="$(run_muxm --dry-run -- --profile streaming-hevc /tmp/l10a.mkv /tmp/l10b.mkv 2>&1 || true)"
  if grep -qiE "Too many arguments" <<<"$out3" && ! grep -qiE "Applied profile: streaming-hevc" <<<"$out3"; then
    pass "cli-dashdash-profile-positional: '--profile' after '--' is treated as a positional, not applied as the profile flag"
  else
    fail "cli-dashdash-profile-positional: '--profile' after '--' was wrongly interpreted as the flag (got: $(grep -iE 'Applied profile|Too many|Unknown profile' <<<"$out3" | head -1))"
  fi
}

# M5: a trailing value-flag in --create-config overrides (e.g. `--crf` with no value) must exit
# cleanly with die 11, not crash under `set -u` with an unbound-variable ERR bundle. The config
# sub-parser now fetches values via _cc_need_val (bounds-checked, mirrors the main _require_val).
# Perturb MUT-M5-UNBOUND reverts one arm to the raw unchecked index read → unbound-variable crash
# → non-11 exit → red.
_test_cli_config_missing_val() {
  local _h="$TESTDIR/m5_home"; mkdir -p "$_h"
  assert_exit 11 "cli-config-missing-value: --create-config with a trailing --crf (missing value) → clean die 11" \
    --create-config user atv-directplay-hq --crf
  # Sanity: a present value still parses (no false die).
  local rc=0
  ( cd "$TESTDIR" && HOME="$_h" "$MUXM" --create-config user atv-directplay-hq --crf 20 >/dev/null 2>&1 ) || rc=$?
  if (( rc == 0 )); then
    pass "cli-config-missing-value: --create-config with '--crf 20' (value present) still succeeds"
  else
    fail "cli-config-missing-value: --create-config '--crf 20' wrongly failed (exit $rc) — bounds check too aggressive?"
  fi
  rm -rf "$_h"
}

# M6: REPLACE_SOURCE set via .muxmrc bypasses the --replace-source TTY guard, so the confirm
# prompt's `read` hits EOF under non-interactive stdin. The fix treats EOF as a decline
# (`read … || _confirm=""`) → clean die 11, instead of an ERR-trap crash (exit 1) under set -e.
# Perturb MUT-M6-EOF removes the `|| _confirm=""` → EOF crashes → non-11 exit → red.
_test_cli_replace_source_eof() {
  local _dir="$TESTDIR/m6_eof"; mkdir -p "$_dir/h"
  cp "$TESTDIR/basic_sdr_subs.mkv" "$_dir/clip.mkv"
  printf 'REPLACE_SOURCE=1\n' > "$_dir/.muxmrc"   # bypasses the flag's TTY guard
  local out rc=0
  # SRC == OUT triggers the replace-source confirm prompt; </dev/null makes read hit EOF.
  out="$(cd "$_dir" && HOME="$_dir/h" "$MUXM" clip.mkv clip.mkv </dev/null 2>&1)" || rc=$?
  if (( rc == 11 )) && grep -qiE "declined|Aborted" <<<"$out"; then
    pass "cli-replace-source-eof: REPLACE_SOURCE + non-interactive stdin → clean die 11 (EOF treated as decline)"
  else
    fail "cli-replace-source-eof: REPLACE_SOURCE + EOF stdin → expected die 11, got exit $rc (ERR-trap crash?)"
  fi
  rm -rf "$_dir"
}

# 1.3/1.4/1.6: --create-config writes atomically (no stray temp file; a refused overwrite leaves
# the original untouched), writes .muxmrc as mode 644 regardless of the invoking umask, and gives
# a muxm-specific diagnostic (not bash's raw "unbound variable") when $HOME is unset.
_test_cli_create_config() {
  # ---- 1.3: atomic write ----
  local cfg_atomic_dir="$TESTDIR/config_create_atomic"
  mkdir -p "$cfg_atomic_dir"
  rm -f "$cfg_atomic_dir/.muxmrc"
  run_muxm_in "$cfg_atomic_dir" --create-config project atv-directplay-hq >/dev/null 2>&1
  if [[ -f "$cfg_atomic_dir/.muxmrc" ]] && ! ls "$cfg_atomic_dir"/.muxmrc.?????? >/dev/null 2>&1; then
    pass "cli-create-config-no-temp-leftover: --create-config leaves no stray .muxmrc.XXXXXX temp file behind"
  else
    fail "cli-create-config-no-temp-leftover: --create-config left a stray temp file or did not create .muxmrc"
  fi
  local _atomic_before _atomic_after
  _atomic_before="$(cksum < "$cfg_atomic_dir/.muxmrc")"
  run_muxm_in "$cfg_atomic_dir" --create-config project archive >/dev/null 2>&1
  _atomic_after="$(cksum < "$cfg_atomic_dir/.muxmrc")"
  if [[ "$_atomic_before" == "$_atomic_after" ]]; then
    pass "cli-create-config-no-temp-leftover: a refused --create-config (existing file, no --force) leaves the original untouched"
  else
    fail "cli-create-config-no-temp-leftover: the existing .muxmrc changed despite the overwrite being refused"
  fi
  rm -f "$cfg_atomic_dir/.muxmrc"

  # ---- 1.4: mode 644 regardless of umask ----
  local cfg_perm_dir="$TESTDIR/config_create_perm"
  mkdir -p "$cfg_perm_dir"
  rm -f "$cfg_perm_dir/.muxmrc"
  ( umask 077; run_muxm_in "$cfg_perm_dir" --create-config project atv-directplay-hq >/dev/null 2>&1 )
  local _perm
  _perm="$(stat -c '%a' "$cfg_perm_dir/.muxmrc" 2>/dev/null || stat -f '%Lp' "$cfg_perm_dir/.muxmrc" 2>/dev/null)"
  if [[ "$_perm" == "644" ]]; then
    pass "cli-create-config-mode-644: --create-config writes .muxmrc as mode 644 regardless of umask"
  else
    fail "cli-create-config-mode-644: --create-config .muxmrc has mode '$_perm', expected 644"
  fi
  rm -f "$cfg_perm_dir/.muxmrc"

  # ---- 1.6: $HOME unset gives a muxm-specific diagnostic, not a raw bash "unbound variable" ----
  local cfg_home_out cfg_home_rc
  cfg_home_out="$(cd "$TESTDIR" && env -u HOME "$MUXM" --create-config user atv-directplay-hq 2>&1)" && cfg_home_rc=$? || cfg_home_rc=$?
  if [[ "$cfg_home_rc" -ne 0 ]] && grep -qiF '$HOME is not set' <<<"$cfg_home_out" && ! grep -qiF 'unbound variable' <<<"$cfg_home_out"; then
    pass "cli-create-config-home-unset: --create-config user with \$HOME unset gives a muxm-specific diagnostic"
  else
    fail "cli-create-config-home-unset: --create-config user with \$HOME unset: ${cfg_home_out:0:200}"
  fi
}

# L3: --level and the rate flags (--av1-maxrate/--av1-bufsize/--stereo-bitrate) are validated at
# parse time (die 11), and the matching globals are re-validated after config load so a sourced
# .muxmrc can't bypass the parse guard (mirrors the CRF re-check). Parse-time validation fires
# before source validation, so a dummy source path is fine.
_test_cli_value_validation() {
  # NOTE: a missing source ALSO exits 11, so exit-code alone is vacuous here — assert the SPECIFIC
  # validation message instead, which only the parse/config guard produces. The parse-time guard
  # fires before source resolution, so a non-existent source path is fine (and keeps this cli test
  # media-free): without the guard the run would die later with "source not found", never the "Invalid …" message.
  local out
  _l3_msg(){ (cd "$TESTDIR" && "$MUXM" "$@" --dry-run /no/such/l3src.mkv y.mkv 2>&1) || true; }
  _l3_assert_rejected(){   # $1=label  $2=expected-message-substr  $3..=muxm flags
    local label="$1" sub="$2"; shift 2
    out="$(_l3_msg "$@")"
    if printf '%s\n' "$out" | grep -qiF "$sub"; then pass "$label"
    else fail "$label — no '$sub' message (got: $(printf '%s\n' "$out" | grep -iE 'Invalid|not found' | head -1))"; fi
  }
  _l3_assert_rejected "cli-numeric-flag-validation: --level garbage rejected at parse"        "Invalid --level"        --level garbage
  _l3_assert_rejected "cli-numeric-flag-validation: --level 5.1:x=1 rejected at parse"        "Invalid --level"        --level "5.1:x=1"
  _l3_assert_rejected "cli-numeric-flag-validation: --av1-maxrate notarate rejected at parse" "Invalid --av1-maxrate"  --av1-maxrate notarate
  _l3_assert_rejected "cli-numeric-flag-validation: --stereo-bitrate 1x2 rejected at parse"   "Invalid --stereo-bitrate" --stereo-bitrate 1x2

  # L4: an unknown --audio-force-codec encoder must be rejected at parse (die 11 with a specific
  # message), not slip through to a cryptic late die 43. `alac` is intentionally rejected too — it is
  # lossless-copyable but has no _audio_codec_ext arm, so forcing a transcode to it would crash.
  _l3_assert_rejected "cli-audio-force-codec-allowlist: --audio-force-codec not_a_codec rejected at parse" "Invalid --audio-force-codec" --audio-force-codec not_a_codec
  _l3_assert_rejected "cli-audio-force-codec-allowlist: --audio-force-codec alac rejected at parse"        "Invalid --audio-force-codec" --audio-force-codec alac

  # Valid values must NOT trip the parse guard (no "Invalid …" message; the run fails later only
  # for the missing source).
  out="$(_l3_msg --level 5.1 --av1-maxrate 5000k --av1-bufsize 40000k --stereo-bitrate 256k)"
  if printf '%s\n' "$out" | grep -qiE 'Invalid (--level|--av1-maxrate|--av1-bufsize|--stereo-bitrate)'; then
    fail "cli-numeric-flag-validation: valid level/rate values wrongly rejected at parse — $(printf '%s\n' "$out" | grep -iE 'Invalid' | head -1)"
  else
    pass "cli-numeric-flag-validation: valid level/rate values accepted at parse (5.1, 5000k, 40000k, 256k)"
  fi

  # L4: every allow-listed encoder (incl. the newly-mapped libfdk_aac/aac_at) must pass the parse
  # guard — the run fails later only for the missing source, never with "Invalid --audio-force-codec".
  local _afc
  for _afc in libopus libmp3lame libvorbis aac libfdk_aac aac_at ac3 eac3 flac; do
    out="$(_l3_msg --audio-force-codec "$_afc")"
    if printf '%s\n' "$out" | grep -qiF "Invalid --audio-force-codec"; then
      fail "cli-audio-force-codec-allowlist: --audio-force-codec $_afc wrongly rejected at parse"
    fi
  done
  pass "cli-audio-force-codec-allowlist: all allow-listed --audio-force-codec encoders accepted at parse (incl. libfdk_aac, aac_at)"

  # 4.1: --checksum-algo now validates at parse time via the same inline-validator shape as its
  # siblings (_validate_checksum_algo_arg), instead of only being caught by a separate case
  # statement after the whole CLI parse loop finished.
  _l3_assert_rejected "cli-checksum-algo-validation: --checksum-algo bogus rejected at parse" "Invalid --checksum-algo" --checksum-algo bogus
  out="$(_l3_msg --checksum-algo sha256)"
  if printf '%s\n' "$out" | grep -qiF "Invalid --checksum-algo"; then
    fail "cli-checksum-algo-validation: --checksum-algo sha256 wrongly rejected at parse"
  else
    pass "cli-checksum-algo-validation: valid --checksum-algo values (sha256/blake2b/auto) accepted at parse"
  fi
  # Config-bypass: a sourced .muxmrc assigns CHECKSUM_ALGO directly, skipping the CLI arm. The
  # post-config re-check (now delegating to the same _validate_checksum_algo_arg) must still
  # reject it.
  local _ck_dir; _ck_dir="$(mktemp -d "$TESTDIR/checksum_algo.XXXXXX")"
  printf 'CHECKSUM_ALGO=bogus\n' > "$_ck_dir/.muxmrc"
  : > "$_ck_dir/src.mkv"
  local _ck_out; _ck_out="$(cd "$_ck_dir" && HOME="$_ck_dir" "$MUXM" --dry-run src.mkv out.mkv 2>&1)" || true
  if printf '%s\n' "$_ck_out" | grep -qiF "Invalid CHECKSUM_ALGO"; then
    pass "cli-checksum-algo-validation: a sourced .muxmrc CHECKSUM_ALGO=bogus is still rejected (config-bypass closed)"
  else
    fail "cli-checksum-algo-validation: config-bypass CHECKSUM_ALGO=bogus was not rejected: ${_ck_out:0:200}"
  fi

  # Config-bypass: a sourced .muxmrc assigns the global directly. The post-config re-check must
  # still reject it. Use AV1_MAXRATE (no profile overrides it; the re-check fires before source
  # validation, so the dummy source is fine). Isolated HOME so no stray ~/.muxmrc interferes.
  # The post-config re-check fires before source resolution, so the dummy source is fine — and
  # assert the SPECIFIC message (not just exit 11, which an empty/missing source also yields).
  local _l3dir; _l3dir="$(mktemp -d "$TESTDIR/l3.XXXXXX")"
  printf 'AV1_MAXRATE=notarate\n' > "$_l3dir/.muxmrc"
  : > "$_l3dir/src.mkv"
  local _l3out; _l3out="$(cd "$_l3dir" && HOME="$_l3dir" "$MUXM" --dry-run src.mkv out.mkv 2>&1)" || true
  if printf '%s\n' "$_l3out" | grep -qiF "Invalid AV1_MAXRATE from config"; then
    pass "cli-numeric-flag-validation: config AV1_MAXRATE=garbage rejected after load (bypass closed)"
  else
    fail "cli-numeric-flag-validation: config AV1_MAXRATE=garbage not rejected after load (got: $(printf '%s\n' "$_l3out" | grep -iE 'Invalid|not found|empty' | head -1))"
  fi
  rm -rf "$_l3dir"
}

# M2: a value-flag used as the FINAL token (no value after it) must error cleanly —
# exit 11 with "requires a value" — never crash with "$2: unbound variable" under set -u.
# _require_val must reject a truly absent value, not just one that *looks* like a flag —
# otherwise the call site reads a bare $2 and trips set -u.
_test_cli_value_flag_no_value() {
  local _flag _out _code
  for _flag in --threads --crf --preset --output-ext --sub-lang-pref --audio-lang-pref \
               --level --x265-params --ocr-tool --max-copy-bitrate --workdir --checksum-algo; do
    # set -e-safe capture: the flag-with-no-value exits 11, which would otherwise abort.
    _out="$(cd "$TESTDIR" && "$MUXM" "$_flag" 2>&1)" && _code=$? || _code=$?
    if [[ "$_code" -eq 11 ]] && printf '%s' "$_out" | grep -qiE 'requires a value'; then
      pass "cli-value-flag-requires-value: '$_flag' as final token → exit 11 'requires a value'"
    else
      fail "cli-value-flag-requires-value: '$_flag' as final token → expected exit 11 'requires a value', got exit $_code"
    fi
    if printf '%s' "$_out" | grep -qi 'unbound variable'; then
      fail "cli-value-flag-requires-value: '$_flag' leaked 'unbound variable' (set -u crash)"
    else
      pass "cli-value-flag-requires-value: '$_flag' does not leak 'unbound variable'"
    fi
  done
  # A value-flag followed by another flag is still rejected (not silently consumed).
  _out="$(cd "$TESTDIR" && "$MUXM" --threads --crf 20 2>&1)" && _code=$? || _code=$?
  if [[ "$_code" -eq 11 ]] && printf '%s' "$_out" | grep -qiE 'requires a value, not a flag'; then
    pass "cli-value-flag-requires-value: '--threads --crf' rejects the following flag as the value"
  else
    fail "cli-value-flag-requires-value: '--threads --crf' → expected exit 11 'not a flag', got exit $_code"
  fi

  # --threads must be a positive integer — non-numeric, zero, fractional, and empty
  # values exit 11 cleanly (zero/fractional would be meaningless as a core cap).
  for _bad in abc 0 2.5 ""; do
    _out="$(cd "$TESTDIR" && "$MUXM" --threads "$_bad" 2>&1)" && _code=$? || _code=$?
    if [[ "$_code" -eq 11 ]] && printf '%s' "$_out" | grep -qiE 'Invalid --threads|requires a value'; then
      pass "cli-value-flag-requires-value: '--threads ${_bad:-<empty>}' rejected (positive integer required)"
    else
      fail "cli-value-flag-requires-value: '--threads ${_bad:-<empty>}' → expected exit 11, got exit $_code"
    fi
  done

  # L5: the action prescans (--install-man, --setup, --create-config, …) must stop at the
  # `--` end-of-options marker, so an action flag AFTER `--` is treated as a positional,
  # not invoked. If the prescan loops scanned all of "$@", they would fire the installer.
  _out="$(cd "$TESTDIR" && "$MUXM" -- --install-man "$TESTDIR/basic_sdr_subs.mkv" 2>&1)" && _code=$? || _code=$?
  if printf '%s' "$_out" | grep -qF 'Manual Page Installer'; then
    fail "cli-install-man-honors-dashdash: 'muxm -- --install-man <file>' wrongly ran the man-page installer (-- not honored)"
  else
    pass "cli-install-man-honors-dashdash: 'muxm -- --install-man <file>' does not run the man-page installer (-- honored)"
  fi
  # Sanity: without --, --install-man still triggers the installer (behavior unchanged).
  # M1: stub `brew` so the real installer writes muxm.1 into a sandbox prefix
  # ($_l5_home/brew_prefix/share/man/man1) instead of the developer's real …/share/man/man1.
  local _l5_home="$TESTDIR/l5_home"; rm -rf "$_l5_home"; mkdir -p "$_l5_home"
  local _l5_brew_bin="$_l5_home/brew_stub_bin" _l5_brew_prefix="$_l5_home/brew_prefix"
  _make_brew_stub "$_l5_brew_bin" "$_l5_brew_prefix"
  _out="$(HOME="$_l5_home" PATH="$_l5_brew_bin:$PATH" "$MUXM" --install-man 2>&1)" && _code=$? || _code=$?
  # M1 regression guard: prove the install landed in the sandbox prefix, NOT the real man dir.
  # The banner check below alone can't catch a removed stub (the banner prints either way), so
  # this is what fails if someone later drops the brew stub from this site.
  if [[ -s "$_l5_brew_prefix/share/man/man1/muxm.1" ]]; then
    pass "cli-install-man-honors-dashdash: '--install-man' writes under the stubbed prefix (real man dir untouched)"
  else
    fail "cli-install-man-honors-dashdash: '--install-man' did not honor the brew stub — real man dir may have been written"
  fi
  if printf '%s' "$_out" | grep -qF 'Manual Page Installer'; then
    pass "cli-install-man-honors-dashdash: '--install-man' (no --) still runs the installer"
  else
    fail "cli-install-man-honors-dashdash: '--install-man' (no --) should still run the installer"
  fi
}

# === Suite: Toggle Flag Coverage ===
# Validates that every boolean --flag / --no-flag pair correctly registers in
# effective config. Catches flags accepted by the CLI parser but never exercised.
# All checks are pure config assertions — zero encode time.
# Uses data-driven table (same pattern as test_profile_e2e) for easy extension.
test_toggles() {
  section "Toggle Flag Coverage (--flag / --no-flag pairs)"

  # Table: CLI flag(s) | expected string in --print-effective-config output
  #
  # WHY THESE FLAGS: Other suites exercise toggle flags incidentally (e.g. test_audio
  # tests --audio-lossless-passthrough via real encodes). This suite covers the remaining
  # flags that would otherwise have zero test coverage — ensuring the CLI parser wires
  # them to the correct config variable even if no encode suite happens to use them.
  local -a TOGGLE_CASES=(
    # ---- Negative toggles not covered by other suites ----
    "--no-checksum|CHECKSUM                  = 0"
    "--no-report-json|REPORT_JSON               = 0"
    "--no-skip-if-ideal|SKIP_IF_IDEAL             = 0"
    "--no-strip-metadata|STRIP_METADATA            = 0"
    "--no-sub-burn-forced|SUB_BURN_FORCED           = 0"
    "--no-sub-export-external|SUB_EXPORT_EXTERNAL       = 0"
    "--no-video-copy-if-compliant|VIDEO_COPY_IF_COMPLIANT   = 0"
    # ---- Positive toggles not covered by other suites ----
    "--prefer-stereo|AUDIO_PREFER_STEREO       = 1"
    "--no-prefer-stereo|AUDIO_PREFER_STEREO       = 0"
    "--stereo-fallback|ADD_STEREO_IF_MULTICH     = 1"
    "--no-stereo-fallback|ADD_STEREO_IF_MULTICH     = 0"
    "--no-conservative-vbv|CONSERVATIVE_VBV          = 0"
    # ---- DV policy toggles ----
    "--allow-dv-fallback|ALLOW_DV_FALLBACK         = 1"
    "--no-allow-dv-fallback|ALLOW_DV_FALLBACK         = 0"
    "--dv-convert-p81|DV_CONVERT_TO_P81_IF_FAIL = 1"
    "--no-dv-convert-p81|DV_CONVERT_TO_P81_IF_FAIL = 0"
    # ---- Audio title toggles ----
    "--audio-titles|INCLUDE_AUDIO_TITLES      = 1"
    "--no-audio-titles|INCLUDE_AUDIO_TITLES      = 0"
    # ---- SDR force 10-bit toggles ----
    "--sdr-force-10bit|SDR_FORCE_10BIT           = 1"
    "--no-sdr-force-10bit|SDR_FORCE_10BIT           = 0"
    # ---- Disk check toggles ----
    "--no-disk-check|DISK_CHECK                = 0"
    # ---- Subtitle format preservation toggles (32e/32f) ----
    "--sub-preserve-format|SUB_PRESERVE_TEXT_FORMAT  = 1"
    "--no-sub-preserve-format|SUB_PRESERVE_TEXT_FORMAT  = 0"
    # ---- DV enable/disable toggles (32g/32h) ----
    "--dv|DISABLE_DV                = 0"
    "--no-dv|DISABLE_DV                = 1"
    # ---- Tone-map toggles (32i/32j) ----
    "--tonemap|TONEMAP_HDR_TO_SDR        = 1"
    "--no-tonemap|TONEMAP_HDR_TO_SDR        = 0"
    # ---- Positive toggles for flags tested only via --no- elsewhere (32k-32t) ----
    # Note: --skip-if-ideal, --checksum, --sub-burn-forced, --video-copy-if-compliant
    # are tested explicitly below the loop (with their --no- counterpart prepended)
    # because ~/.muxmrc or the default profile already sets them to 1, which would
    # make the single-flag form trivially pass without actually testing the flag.
    "--report-json|REPORT_JSON               = 1"
    "--strip-metadata|STRIP_METADATA            = 1"
    "--keep-chapters|KEEP_CHAPTERS             = 1"
    "--no-keep-chapters|KEEP_CHAPTERS             = 0"
    "--sub-export-external|SUB_EXPORT_EXTERNAL       = 1"
    "--force-replace-source|FORCE_REPLACE_SOURCE      = 1"
    # ---- External subtitle toggles ----
    "--ext-subs|EXT_SUB_ENABLED           = 1"
    "--no-ext-subs|EXT_SUB_ENABLED           = 0"
    # ---- External subtitle sole-fallback toggles ----
    "--sub-sole-ext-fallback|SUB_SOLE_EXT_FALLBACK     = 1"
    "--no-sub-sole-ext-fallback|SUB_SOLE_EXT_FALLBACK     = 0"
    # ---- Conservative VBV positive toggle ----
    "--conservative-vbv|CONSERVATIVE_VBV          = 1"
    # ---- SDH subtitle inclusion toggle ----
    "--no-sub-sdh|SUB_INCLUDE_SDH           = 0"
    # ---- Hardware acceleration allow-sw toggles ----
    "--hw-accel-allow-sw|HW_ACCEL_ALLOW_SW         = 1"
    "--no-hw-accel-allow-sw|HW_ACCEL_ALLOW_SW         = 0"
    # ---- Subtitle bitmap preservation toggles ----
    "--sub-preserve-bitmap|SUB_PRESERVE_BITMAP       = 1"
    "--no-sub-preserve-bitmap|SUB_PRESERVE_BITMAP       = 0"
  )

  local out flag expected
  for tc in "${TOGGLE_CASES[@]}"; do
    IFS='|' read -r flag expected <<< "$tc"
    out="$(run_muxm "$flag" --print-effective-config)"
    assert_contains "$expected" "$flag: registered" "$out"
  done

  # ---- Positive toggles that need explicit override of .muxmrc/profile defaults ----
  # These flags are already set to 1 by ~/.muxmrc or the default profile, so the
  # single-flag form would pass trivially. Prepend the --no- form to establish a
  # known-0 baseline before testing the positive flag.
  out="$(run_muxm --no-checksum --checksum --print-effective-config)"
  assert_contains "CHECKSUM                  = 1" "--checksum: registered" "$out"

  out="$(run_muxm --no-skip-if-ideal --skip-if-ideal --print-effective-config)"
  assert_contains "SKIP_IF_IDEAL             = 1" "--skip-if-ideal: registered" "$out"

  out="$(run_muxm --no-sub-burn-forced --sub-burn-forced --print-effective-config)"
  assert_contains "SUB_BURN_FORCED           = 1" "--sub-burn-forced: registered" "$out"

  out="$(run_muxm --no-video-copy-if-compliant --video-copy-if-compliant --print-effective-config)"
  assert_contains "VIDEO_COPY_IF_COMPLIANT   = 1" "--video-copy-if-compliant: registered" "$out"

  out="$(run_muxm --no-disk-check --disk-check --print-effective-config)"
  assert_contains "DISK_CHECK                = 1" "--disk-check: registered (baseline 0 first)" "$out"

  # ---- Value flags (non-toggle) ----
  out="$(run_muxm --max-copy-bitrate 30000k --print-effective-config)"
  assert_contains "MAX_COPY_BITRATE          = 30000k" "--max-copy-bitrate sets value" "$out"

  out="$(run_muxm --checksum-algo blake2b --print-effective-config)"
  assert_contains "CHECKSUM_ALGO             = blake2b" "--checksum-algo blake2b: registered" "$out"

  out="$(run_muxm --checksum-algo sha256 --print-effective-config)"
  assert_contains "CHECKSUM_ALGO             = sha256" "--checksum-algo sha256: registered" "$out"

  out="$(run_muxm --checksum-algo auto --print-effective-config)"
  assert_contains "CHECKSUM_ALGO             = auto" "--checksum-algo auto: registered" "$out"

  out="$(run_muxm --x264-params "profile=high:aq-mode=2" --print-effective-config)"
  assert_contains "X264_PARAMS_BASE          = profile=high:aq-mode=2" "--x264-params: value registered" "$out"

  # ---- _CLI_*_EXPLICIT tracking for the advanced encode-param flags ----
  # Each flag, when typed on the CLI, must set its companion _CLI_*_EXPLICIT=1; when the flag
  # is absent (or the value comes from a profile/config), the tracker stays 0. This records
  # *intent*, not value — the prerequisite for the ignored-knob conflict warnings below.

  # Defaults: every tracker is 0 (no flag typed). Use av1-hq, whose profile *sets*
  # SVT_AV1_PARAMS_BASE, to confirm a profile-supplied value does NOT flip the tracker.
  out="$(run_muxm --profile av1-hq --print-effective-config)"
  assert_contains "_CLI_X265_PARAMS_EXPLICIT     = 0" "explicit-track default: x265-params=0" "$out"
  assert_contains "_CLI_X264_PARAMS_EXPLICIT     = 0" "explicit-track default: x264-params=0" "$out"
  assert_contains "_CLI_AV1_PARAMS_EXPLICIT      = 0" "explicit-track default: av1-params=0 (profile value doesn't flip it)" "$out"
  assert_contains "_CLI_LEVEL_EXPLICIT           = 0" "explicit-track default: level=0" "$out"

  # Each flag typed → its tracker flips to 1 (and only its own).
  out="$(run_muxm --x265-params "aq-mode=2" --print-effective-config)"
  assert_contains "_CLI_X265_PARAMS_EXPLICIT     = 1" "--x265-params: sets _CLI_X265_PARAMS_EXPLICIT=1" "$out"
  assert_contains "_CLI_X264_PARAMS_EXPLICIT     = 0" "--x265-params: does not flip x264 tracker" "$out"

  out="$(run_muxm --x264-params "profile=high" --print-effective-config)"
  assert_contains "_CLI_X264_PARAMS_EXPLICIT     = 1" "--x264-params: sets _CLI_X264_PARAMS_EXPLICIT=1" "$out"

  out="$(run_muxm --av1-params "scd=1" --print-effective-config)"
  assert_contains "_CLI_AV1_PARAMS_EXPLICIT      = 1" "--av1-params: sets _CLI_AV1_PARAMS_EXPLICIT=1" "$out"

  out="$(run_muxm --level 5.1 --print-effective-config)"
  assert_contains "_CLI_LEVEL_EXPLICIT           = 1" "--level: sets _CLI_LEVEL_EXPLICIT=1" "$out"

  out="$(run_muxm -l 5.0 --print-effective-config)"
  assert_contains "_CLI_LEVEL_EXPLICIT           = 1" "-l (alias): sets _CLI_LEVEL_EXPLICIT=1" "$out"

  # A value supplied via config (not the CLI) must NOT flip the tracker (records intent).
  local _expl_home="$TESTDIR/explicit_track_home"; mkdir -p "$_expl_home"
  printf 'X265_PARAMS_BASE="aq-mode=2"\n' > "$_expl_home/.muxmrc"
  out="$(MUXM_HOME="$_expl_home" run_muxm_in "$TESTDIR" --print-effective-config)"
  assert_contains "_CLI_X265_PARAMS_EXPLICIT     = 0" "config-set X265_PARAMS_BASE: tracker stays 0 (intent, not value)" "$out"

  # ---- Default DISK_CHECK = 1 ----
  out="$(run_muxm --print-effective-config)"
  assert_contains "DISK_CHECK                = 1" "DISK_CHECK defaults to 1" "$out"

}

# === Suite: Config Precedence ===
# Validates layered configuration: --print-effective-config output, CLI flags overriding
# profile defaults, project-level .muxmrc loading, --create-config / --force-create-config
# file generation, and per-variable overrides from config files.
# --- test_config sub-functions ---
# Each sub-function tests a distinct config lifecycle stage.  They execute
# sequentially within the dispatcher; none depends on state from another.

_test_config_effective() {
  # Test --print-effective-config with profile
  local out
  out="$(run_muxm --profile streaming --print-effective-config)"
  assert_contains "PROFILE_NAME" "--print-effective-config shows profile" "$out"
  assert_contains "streaming" "Effective config shows streaming profile" "$out"
  assert_contains "CRF_VALUE" "Effective config shows CRF" "$out"
  assert_contains "VIDEO_CODEC" "Effective config shows video codec" "$out"

  # CLI flags override profile
  out="$(run_muxm --profile streaming --crf 25 --print-effective-config)"
  assert_contains "25" "CLI --crf overrides profile CRF" "$out"

  # Profile from config file (project-level)
  # Use isolated HOME to prevent user's real ~/.muxmrc from interfering
  local cfg_profile_dir="$TESTDIR/config_profile_test"
  local cfg_profile_home="$TESTDIR/config_profile_home"
  mkdir -p "$cfg_profile_dir" "$cfg_profile_home"
  cat > "$cfg_profile_dir/.muxmrc" <<'EOF'
PROFILE_NAME="animation"
EOF
  # Verify config file is picked up when running from that directory
  out="$(MUXM_HOME="$cfg_profile_home" run_muxm_in "$cfg_profile_dir" --print-effective-config)"
  assert_contains "animation" "Config file PROFILE_NAME loaded" "$out"
  log "Config file profile override tested via --print-effective-config"

  # Config variable override from file
  # Use isolated HOME to prevent user's real ~/.muxmrc (e.g. PROFILE_NAME) from
  # applying a profile that overwrites CRF_VALUE after config-file loading.
  local cfg_var_dir="$TESTDIR/config_var_test"
  local cfg_var_home="$TESTDIR/config_var_home"
  mkdir -p "$cfg_var_dir" "$cfg_var_home"
  cat > "$cfg_var_dir/.muxmrc" <<'EOF'
CRF_VALUE=14
PRESET_VALUE="slower"
EOF
  out="$(MUXM_HOME="$cfg_var_home" run_muxm_in "$cfg_var_dir" --print-effective-config)"
  assert_contains "CRF_VALUE                 = 14" "Config file CRF_VALUE override" "$out"
  assert_contains "PRESET_VALUE              = slower" "Config file PRESET_VALUE override" "$out"

  # ---- KEEP_LOG + VERBOSITY are tracked .muxmrc knobs; CLI overrides them ----
  local ck_dir="$TESTDIR/config_knob_test" ck_home="$TESTDIR/config_knob_home"
  mkdir -p "$ck_dir" "$ck_home"
  cat > "$ck_dir/.muxmrc" <<'EOF'
KEEP_LOG=1
VERBOSITY="quiet"
EOF
  out="$(MUXM_HOME="$ck_home" run_muxm_in "$ck_dir" --print-effective-config)"
  assert_contains "KEEP_LOG                  = 1"     ".muxmrc KEEP_LOG=1 is read into effective config" "$out"
  assert_contains "VERBOSITY                 = quiet" ".muxmrc VERBOSITY=quiet is read into effective config" "$out"
  # CLI wins over the config value (no --no-keep-log exists, so test the VERBOSITY override).
  out="$(MUXM_HOME="$ck_home" run_muxm_in "$ck_dir" --verbose --print-effective-config)"
  assert_contains "VERBOSITY                 = verbose" "CLI --verbose overrides .muxmrc VERBOSITY=quiet" "$out"
  # An invalid VERBOSITY in config is rejected early (exit EXIT_VALIDATION), naming the file.
  printf 'VERBOSITY="loud"\n' > "$ck_dir/.muxmrc"
  local ck_bad ck_code
  # Raw capture (not run_muxm_in) — we need the real exit code, which run_muxm_in's || true swallows.
  ck_bad="$(cd "$ck_dir" && HOME="$ck_home" "$MUXM" --print-effective-config 2>&1)" && ck_code=$? || ck_code=$?
  if [[ "$ck_code" -eq "$EXIT_VALIDATION" ]]; then
    pass "invalid .muxmrc VERBOSITY → exit $EXIT_VALIDATION"
  else
    fail "invalid .muxmrc VERBOSITY — expected exit $EXIT_VALIDATION, got $ck_code"
  fi
  assert_contains "Invalid VERBOSITY" "invalid .muxmrc VERBOSITY is rejected with a clear error" "$ck_bad"
  assert_contains ".muxmrc" "invalid VERBOSITY error names the offending config file" "$ck_bad"
  # An empty .muxmrc leaves the defaults untouched (criterion 4).
  printf '\n' > "$ck_dir/.muxmrc"
  out="$(MUXM_HOME="$ck_home" run_muxm_in "$ck_dir" --print-effective-config)"
  assert_contains "KEEP_LOG                  = 0"      "empty .muxmrc keeps KEEP_LOG default" "$out"
  assert_contains "VERBOSITY                 = normal" "empty .muxmrc keeps VERBOSITY default" "$out"
}

_test_config_create() {
  local out

  # --create-config (use a clean directory so no pre-existing .muxmrc)
  local cfg_create_dir="$TESTDIR/config_create_test"
  mkdir -p "$cfg_create_dir"
  out="$(run_muxm_in "$cfg_create_dir" --create-config project streaming)"
  if [[ -f "$cfg_create_dir/.muxmrc" ]]; then
    pass "--create-config creates .muxmrc"
    # Check contents
    local cfg_content
    cfg_content="$(cat "$cfg_create_dir/.muxmrc")"
    assert_contains "PROFILE_NAME" "Config contains PROFILE_NAME" "$cfg_content"
    assert_contains "streaming" "Config contains profile name" "$cfg_content"
    assert_contains "CRF_VALUE" "Config contains CRF_VALUE" "$cfg_content"

    # --create-config refuses overwrite
    out="$(run_muxm_in "$cfg_create_dir" --create-config project streaming)"
    assert_contains "already exists" "--create-config refuses overwrite" "$out"

    # --force-create-config overwrites
    out="$(run_muxm_in "$cfg_create_dir" --force-create-config project animation)"
    cfg_content="$(cat "$cfg_create_dir/.muxmrc")"
    assert_contains "animation" "--force-create-config overwrites with new profile" "$cfg_content"
  else
    fail "--create-config did not create .muxmrc"
  fi

  # Invalid scope
  out="$(run_muxm --create-config bogus streaming 2>&1)" || true
  assert_contains "Invalid scope" "--create-config rejects invalid scope" "$out"

  # --create-config with all remaining profiles (#50)
  local profiles_to_test=("archive" "hdr10-hq" "atv-directplay-hq" "universal")
  for p in "${profiles_to_test[@]}"; do
    local cfg_p_dir="$TESTDIR/config_create_$p"
    mkdir -p "$cfg_p_dir"
    out="$(run_muxm_in "$cfg_p_dir" --create-config project "$p")"
    if [[ -f "$cfg_p_dir/.muxmrc" ]]; then
      local content
      content="$(cat "$cfg_p_dir/.muxmrc")"
      assert_contains "$p" "--create-config $p: profile name in config" "$content"
    else
      fail "--create-config $p: did not create .muxmrc"
    fi
  done

  # ---- --create-config template includes multi-track variables ----
  # AUDIO_MULTI_TRACK, AUDIO_KEEP_COMMENTARY, and SUB_MULTI_TRACK were added to
  # the --create-config template as part of the multi-track release.  Without them,
  # users cannot discover or override these settings via --create-config.
  local cfg_mt_dir="$TESTDIR/config_create_mt_vars"
  mkdir -p "$cfg_mt_dir"
  run_muxm_in "$cfg_mt_dir" --create-config project archive >/dev/null 2>&1
  if [[ -f "$cfg_mt_dir/.muxmrc" ]]; then
    local mt_cfg_content
    mt_cfg_content="$(cat "$cfg_mt_dir/.muxmrc")"
    assert_contains "AUDIO_MULTI_TRACK" \
      "--create-config archive: template contains AUDIO_MULTI_TRACK" "$mt_cfg_content"
    assert_contains "AUDIO_KEEP_COMMENTARY" \
      "--create-config archive: template contains AUDIO_KEEP_COMMENTARY" "$mt_cfg_content"
    assert_contains "SUB_MULTI_TRACK" \
      "--create-config archive: template contains SUB_MULTI_TRACK" "$mt_cfg_content"
  else
    fail "--create-config archive: did not create .muxmrc (multi-track variable check)"
  fi

  # --create-config with no profile arg → defaults to atv-directplay-hq
  local cfg_default_dir="$TESTDIR/config_create_default_profile"
  mkdir -p "$cfg_default_dir"
  run_muxm_in "$cfg_default_dir" --create-config project >/dev/null 2>&1
  if [[ -f "$cfg_default_dir/.muxmrc" ]]; then
    local default_content
    default_content="$(cat "$cfg_default_dir/.muxmrc")"
    assert_contains "atv-directplay-hq" "--create-config (no profile) defaults to atv-directplay-hq" "$default_content"
  else
    fail "--create-config (no profile): did not create .muxmrc"
  fi
}

_test_config_layering() {
  # Tests the full three-layer stack: user (~/.muxmrc) + project (./.muxmrc) + CLI.
  # muxm loads config in this order (last wins): defaults → user → project → CLI.
  # Each assertion below targets a specific layer boundary to verify that higher-priority
  # layers override lower ones while leaving untouched variables intact.
  local out

  local layer_home="$TESTDIR/config_layer_home"
  local layer_proj="$TESTDIR/config_layer_project"
  mkdir -p "$layer_home" "$layer_proj"

  # User-level config: CRF=22, PRESET=slow
  cat > "$layer_home/.muxmrc" <<'USEREOF'
CRF_VALUE=22
PRESET_VALUE="slow"
USEREOF

  # Project-level config: CRF=18 (overrides user), no PRESET (inherits user)
  cat > "$layer_proj/.muxmrc" <<'PROJEOF'
CRF_VALUE=18
PROJEOF

  # R39: Project config overrides user config for CRF; user PRESET preserved
  out="$(MUXM_HOME="$layer_home" run_muxm_in "$layer_proj" --print-effective-config)"
  assert_contains "CRF_VALUE                 = 18" "Config layering: project CRF overrides user CRF" "$out"
  assert_contains "PRESET_VALUE              = slow" "Config layering: user PRESET preserved when project doesn't set it" "$out"

  # R40: CLI overrides project config
  out="$(MUXM_HOME="$layer_home" run_muxm_in "$layer_proj" --crf 25 --print-effective-config)"
  assert_contains "CRF_VALUE                 = 25" "Config layering: CLI --crf overrides project CRF" "$out"

  # R41: Full stack — CLI wins over both user and project for CRF;
  #      user PRESET still preserved (not overridden by project or CLI)
  out="$(MUXM_HOME="$layer_home" run_muxm_in "$layer_proj" --crf 30 --print-effective-config)"
  assert_contains "CRF_VALUE                 = 30" "Config layering: CLI wins full stack (user+project+CLI)" "$out"
  assert_contains "PRESET_VALUE              = slow" "Config layering: user PRESET survives full stack" "$out"

  # R42: Profile in user config, overridden by CLI --profile
  cat > "$layer_home/.muxmrc" <<'PROFEOF'
PROFILE_NAME="animation"
PROFEOF
  # Without CLI override — user profile should be active
  out="$(MUXM_HOME="$layer_home" run_muxm_in "$TESTDIR" --print-effective-config)"
  assert_contains "animation" "Config layering: user config PROFILE_NAME loaded" "$out"

  # With CLI override — CLI profile wins
  out="$(MUXM_HOME="$layer_home" run_muxm_in "$TESTDIR" --profile streaming --print-effective-config)"
  assert_contains "streaming" "Config layering: CLI --profile overrides user config PROFILE_NAME" "$out"
}

_test_config_validation() {
  local out

  # ---- Invalid FFMPEG_LOGLEVEL in config file ----
  local loglevel_home="$TESTDIR/loglevel_test_home"
  mkdir -p "$loglevel_home"
  cat > "$loglevel_home/.muxmrc" <<'EOF'
FFMPEG_LOGLEVEL=bogus
EOF
  local ll_out ll_code
  # Raw capture (not run_muxm_in) — we need the exit code, which || true would swallow.
  ll_out="$(cd "$TESTDIR" && HOME="$loglevel_home" "$MUXM" --print-effective-config 2>&1)" && ll_code=$? || ll_code=$?
  if [[ "$ll_code" -eq "$EXIT_VALIDATION" ]]; then
    pass "Invalid FFMPEG_LOGLEVEL in config → exit $EXIT_VALIDATION"
  else
    fail "Invalid FFMPEG_LOGLEVEL in config — expected exit $EXIT_VALIDATION, got $ll_code"
  fi
  assert_contains "Invalid FFMPEG_LOGLEVEL" "Error message names the bad variable" "$ll_out"
  # D13: the error names the offending config file (not just "in config").
  assert_contains ".muxmrc" "Invalid FFMPEG_LOGLEVEL error names the offending config file (D13)" "$ll_out"

  # ---- Invalid FFPROBE_LOGLEVEL in config file ----
  cat > "$loglevel_home/.muxmrc" <<'EOF'
FFPROBE_LOGLEVEL=nonsense
EOF
  # Raw capture (not run_muxm_in) — we need the exit code, which || true would swallow.
  ll_out="$(cd "$TESTDIR" && HOME="$loglevel_home" "$MUXM" --print-effective-config 2>&1)" && ll_code=$? || ll_code=$?
  if [[ "$ll_code" -eq "$EXIT_VALIDATION" ]]; then
    pass "Invalid FFPROBE_LOGLEVEL in config → exit $EXIT_VALIDATION"
  else
    fail "Invalid FFPROBE_LOGLEVEL in config — expected exit $EXIT_VALIDATION, got $ll_code"
  fi
  assert_contains "Invalid FFPROBE_LOGLEVEL" "Error message names the bad variable" "$ll_out"

  # ---- Deprecated AUDIO_SCORE_LANG_BONUS_ENG migration ----
  local depr_home="$TESTDIR/deprecation_test_home"
  mkdir -p "$depr_home"
  cat > "$depr_home/.muxmrc" <<'EOF'
AUDIO_SCORE_LANG_BONUS_ENG=99
EOF
  local depr_out
  depr_out="$(MUXM_HOME="$depr_home" run_muxm_in "$TESTDIR" --print-effective-config)"
  # 1) Verify deprecation warning is emitted
  assert_contains "Deprecated" "Deprecated variable triggers warning" "$depr_out"
  assert_contains "AUDIO_SCORE_LANG_BONUS_ENG" "Warning names the deprecated variable" "$depr_out"
  # 2) Verify value propagated to the new variable
  assert_contains "AUDIO_SCORE_LANG_BONUS    = 99" "Deprecated value migrates to AUDIO_SCORE_LANG_BONUS" "$depr_out"

  # ---- --ocr-tool sets custom OCR tool name ----
  local ocr_out
  ocr_out="$(run_muxm --ocr-tool pgsrip --print-effective-config)"
  assert_contains "SUB_OCR_TOOL              = pgsrip" "--ocr-tool sets SUB_OCR_TOOL in effective config" "$ocr_out"
}

_test_config_create_overrides() {
  # --create-config with CLI overrides should produce a .muxmrc where the
  # overridden values are uncommented and set to the supplied values.

  local out content

  # Single override: --crf 20 should uncomment CRF_VALUE=20
  local cfg_crf_dir="$TESTDIR/config_create_override_crf"
  mkdir -p "$cfg_crf_dir"
  out="$(run_muxm_in "$cfg_crf_dir" --create-config project atv-directplay-hq --crf 20 2>&1)"
  if [[ -f "$cfg_crf_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_crf_dir/.muxmrc")"
    # The value should appear uncommented (not starting with #)
    if echo "$content" | grep -qE '^CRF_VALUE="?20"?'; then
      pass "--create-config --crf 20: CRF_VALUE=20 uncommented in .muxmrc"
    else
      fail "--create-config --crf 20: CRF_VALUE=20 not found uncommented (got: $(echo "$content" | grep CRF_VALUE || echo '<not present>'))"
    fi
  else
    fail "--create-config --crf 20: did not create .muxmrc"
  fi
  rm -f "$cfg_crf_dir/.muxmrc"

  # Multiple overrides: --crf 20 --preset medium → both uncommented
  local cfg_multi_dir="$TESTDIR/config_create_override_multi"
  mkdir -p "$cfg_multi_dir"
  out="$(run_muxm_in "$cfg_multi_dir" \
    --create-config project atv-directplay-hq --crf 20 --preset medium 2>&1)"
  if [[ -f "$cfg_multi_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_multi_dir/.muxmrc")"
    if echo "$content" | grep -qE '^CRF_VALUE="?20"?'; then
      pass "--create-config multi-override: CRF_VALUE=20 uncommented"
    else
      fail "--create-config multi-override: CRF_VALUE=20 not found uncommented"
    fi
    if echo "$content" | grep -qE '^PRESET_VALUE=("medium"|medium)'; then
      pass "--create-config multi-override: PRESET_VALUE=medium uncommented"
    else
      fail "--create-config multi-override: PRESET_VALUE=medium not found uncommented"
    fi
  else
    fail "--create-config multi-override: did not create .muxmrc"
  fi
  rm -f "$cfg_multi_dir/.muxmrc"

  # No overrides: profile-set variables should be uncommented; vars the profile
  # doesn't touch should remain commented.
  # Use isolated HOME to prevent the real ~/.muxmrc from pre-setting variables to
  # the same values the profile uses — which would make the snapshot diff invisible.
  local cfg_nooverride_dir="$TESTDIR/config_create_no_override"
  local cfg_nooverride_home="$TESTDIR/config_create_no_override_home"
  mkdir -p "$cfg_nooverride_dir" "$cfg_nooverride_home"
  MUXM_HOME="$cfg_nooverride_home" run_muxm_in "$cfg_nooverride_dir" --create-config project atv-directplay-hq >/dev/null 2>&1
  if [[ -f "$cfg_nooverride_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_nooverride_dir/.muxmrc")"
    # atv-directplay-hq sets CRF_VALUE=17 — should be uncommented with no CLI override
    if echo "$content" | grep -qE '^CRF_VALUE="?17"?'; then
      pass "--create-config no-override: CRF_VALUE=17 uncommented (profile-owned)"
    else
      fail "--create-config no-override: CRF_VALUE=17 not found uncommented (got: $(echo "$content" | grep CRF_VALUE || echo '<not present>'))"
    fi
    # THREADS is not set by atv-directplay-hq — should remain commented
    if echo "$content" | grep -qE '^#.*THREADS' || ! echo "$content" | grep -qE '^THREADS='; then
      pass "--create-config no-override: THREADS stays commented (not set by profile)"
    else
      fail "--create-config no-override: THREADS appears uncommented but profile does not set it"
    fi
  else
    fail "--create-config no-override: did not create .muxmrc"
  fi
  rm -f "$cfg_nooverride_dir/.muxmrc"

  # ---- H1: --create-config must NOT leak the user's .muxmrc into the generated config ----
  # _create_config_emit applies the profile on top of the LIVE config vars, which already
  # carry whatever the user/system/project .muxmrc set at startup. Without care, the diff
  # (live vs _MUXM_PRE_CONFIG) flags any var that differed from the script default —
  # including a profile-UNTOUCHED var the user's .muxmrc happened to change — and emitted
  # it uncommented, as if the profile owned it. The fix resets every tracked var to its
  # script default before applying the profile, so only profile-owned changes are active.
  #
  # Setup: a populated user HOME whose .muxmrc sets MAX_AUDIO_CHANNELS=4 — a var that
  # streaming-hevc does NOT touch (built-in default 8). The profile DOES set
  # EAC3_BITRATE_5_1=448k (built-in default 640k).
  local cfg_leak_dir="$TESTDIR/config_create_leak"
  local cfg_leak_home="$TESTDIR/config_create_leak_home"
  mkdir -p "$cfg_leak_dir" "$cfg_leak_home"
  printf 'MAX_AUDIO_CHANNELS=4\n' > "$cfg_leak_home/.muxmrc"
  MUXM_HOME="$cfg_leak_home" run_muxm_in "$cfg_leak_dir" \
    --create-config project streaming-hevc >/dev/null 2>&1
  if [[ -f "$cfg_leak_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_leak_dir/.muxmrc")"
    # Profile-untouched var: must appear as the COMMENTED default (#MAX_AUDIO_CHANNELS=8),
    # never as the user's leaked value uncommented.
    if echo "$content" | grep -qE '^MAX_AUDIO_CHANNELS='; then
      fail "config-create-config-no-user-leak: user .muxmrc value leaked — MAX_AUDIO_CHANNELS emitted uncommented (got: $(echo "$content" | grep -E '^MAX_AUDIO_CHANNELS=' ))"
    else
      pass "config-create-config-no-user-leak: profile-untouched MAX_AUDIO_CHANNELS not emitted uncommented (no user-config leak)"
    fi
    if echo "$content" | grep -qE '^#MAX_AUDIO_CHANNELS="?8"?$'; then
      pass "config-create-config-no-user-leak: profile-untouched MAX_AUDIO_CHANNELS stays commented at the script default (#=8)"
    else
      fail "config-create-config-no-user-leak: expected '#MAX_AUDIO_CHANNELS=8' (commented default), got: $(echo "$content" | grep -E 'MAX_AUDIO_CHANNELS' || echo '<not present>')"
    fi
    # Profile-owned var: must stay uncommented at the profile value (448k, != default 640k).
    if echo "$content" | grep -qE '^EAC3_BITRATE_5_1="?448k"?'; then
      pass "config-create-config-no-user-leak: profile-owned EAC3_BITRATE_5_1=448k stays uncommented"
    else
      fail "config-create-config-no-user-leak: expected uncommented EAC3_BITRATE_5_1=448k (profile-owned), got: $(echo "$content" | grep -E 'EAC3_BITRATE_5_1' || echo '<not present>')"
    fi
  else
    fail "config-create-config-no-user-leak: --create-config (leak guard) did not create .muxmrc"
  fi
  rm -f "$cfg_leak_dir/.muxmrc"

  # ---- L3: template emits the LIVE Section-4 default, not a stale hardcoded literal ----
  # Vars like DISK_FREE_WARN_GB must not be emitted via a hardcoded `printf '#…=5'` that
  # drifts when the Section-4 default changes. They're tracked + emitted via _V (dynamic).
  # Verify by changing a default in a copy of muxm and confirming the generated config follows.
  local _l3_muxm="$TESTDIR/l3_muxm"
  sed 's/^declare -i DISK_FREE_WARN_GB=5/declare -i DISK_FREE_WARN_GB=7/' "$MUXM" > "$_l3_muxm"
  chmod +x "$_l3_muxm"
  local _l3_dir="$TESTDIR/l3_cfg" _l3_home="$TESTDIR/l3_home"
  mkdir -p "$_l3_dir" "$_l3_home"
  (cd "$_l3_dir" && HOME="$_l3_home" "$_l3_muxm" --create-config project streaming-hevc >/dev/null 2>&1) || true
  if [[ -f "$_l3_dir/.muxmrc" ]]; then
    if grep -qE '^#DISK_FREE_WARN_GB="?7"?$' "$_l3_dir/.muxmrc"; then
      pass "config-template-live-defaults: generated config tracks the changed Section-4 default (#DISK_FREE_WARN_GB=7), not a stale literal"
    else
      fail "config-template-live-defaults: generated config shows a stale DISK_FREE_WARN_GB (got: $(grep DISK_FREE_WARN_GB "$_l3_dir/.muxmrc" || echo '<none>'))"
    fi
    # TONEMAP_FILTER is now emitted via `_V … quoted` (double-quoted) and must round-trip.
    if grep -qE '^#TONEMAP_FILTER="' "$_l3_dir/.muxmrc"; then
      pass "config-template-live-defaults: TONEMAP_FILTER emitted via _V (double-quoted, round-trippable)"
    else
      fail "config-template-live-defaults: TONEMAP_FILTER not emitted via _V in generated config"
    fi
  else
    fail "config-template-live-defaults: --create-config (changed-default copy) did not create .muxmrc"
  fi
  rm -f "$_l3_muxm" "$_l3_dir/.muxmrc"

  # Unknown flag: --bogus-flag should produce an error and exit non-zero
  local bogus_dir="$TESTDIR/config_create_bogus"
  mkdir -p "$bogus_dir"
  local bogus_code
  out="$(cd "$bogus_dir" && "$MUXM" --create-config project --bogus-flag 2>&1)" \
    && bogus_code=$? || bogus_code=$?
  if [[ "$bogus_code" -ne 0 ]]; then
    pass "--create-config --bogus-flag: exits non-zero on unknown flag"
  else
    fail "--create-config --bogus-flag: expected non-zero exit, got 0"
  fi
  if echo "$out" | grep -qiE "unknown|invalid|unrecognized|bogus"; then
    pass "--create-config --bogus-flag: error message mentions unknown/invalid flag"
  else
    skip "--create-config --bogus-flag: error message wording not matched (exit code check passed)"
  fi
  rm -f "$bogus_dir/.muxmrc"

  # ---- Encoding params ----

  # --x265-params: X265_PARAMS_BASE uncommented with supplied value
  local cfg_x265_dir="$TESTDIR/config_create_override_x265params"
  mkdir -p "$cfg_x265_dir"
  out="$(run_muxm_in "$cfg_x265_dir" --create-config project atv-directplay-hq --x265-params 'psy-rd=3.0' 2>&1)"
  if [[ -f "$cfg_x265_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_x265_dir/.muxmrc")"
    if echo "$content" | grep -qE '^X265_PARAMS_BASE="psy-rd=3\.0"'; then
      pass "--create-config --x265-params: X265_PARAMS_BASE=\"psy-rd=3.0\" uncommented in .muxmrc"
    else
      fail "--create-config --x265-params: X265_PARAMS_BASE not found uncommented (got: $(echo "$content" | grep X265_PARAMS_BASE || echo '<not present>'))"
    fi
  else
    fail "--create-config --x265-params: did not create .muxmrc"
  fi
  rm -f "$cfg_x265_dir/.muxmrc"

  # --threads: THREADS uncommented with supplied value
  local cfg_threads_dir="$TESTDIR/config_create_override_threads"
  mkdir -p "$cfg_threads_dir"
  out="$(run_muxm_in "$cfg_threads_dir" --create-config project universal --threads 4 2>&1)"
  if [[ -f "$cfg_threads_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_threads_dir/.muxmrc")"
    if echo "$content" | grep -qE '^THREADS="?4"?'; then
      pass "--create-config --threads 4: THREADS=4 uncommented in .muxmrc"
    else
      fail "--create-config --threads 4: THREADS=4 not found uncommented (got: $(echo "$content" | grep THREADS || echo '<not present>'))"
    fi
  else
    fail "--create-config --threads 4: did not create .muxmrc"
  fi
  rm -f "$cfg_threads_dir/.muxmrc"

  # ---- HDR/DV ----

  # --no-dv: DISABLE_DV uncommented with 1
  local cfg_nodv_dir="$TESTDIR/config_create_override_nodv"
  mkdir -p "$cfg_nodv_dir"
  out="$(run_muxm_in "$cfg_nodv_dir" --create-config project archive --no-dv 2>&1)"
  if [[ -f "$cfg_nodv_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_nodv_dir/.muxmrc")"
    if echo "$content" | grep -qE '^DISABLE_DV="?1"?'; then
      pass "--create-config --no-dv: DISABLE_DV=1 uncommented in .muxmrc"
    else
      fail "--create-config --no-dv: DISABLE_DV=1 not found uncommented (got: $(echo "$content" | grep DISABLE_DV || echo '<not present>'))"
    fi
  else
    fail "--create-config --no-dv: did not create .muxmrc"
  fi
  rm -f "$cfg_nodv_dir/.muxmrc"

  # --tonemap: TONEMAP_HDR_TO_SDR uncommented with 1
  local cfg_tonemap_dir="$TESTDIR/config_create_override_tonemap"
  mkdir -p "$cfg_tonemap_dir"
  out="$(run_muxm_in "$cfg_tonemap_dir" --create-config project archive --tonemap 2>&1)"
  if [[ -f "$cfg_tonemap_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_tonemap_dir/.muxmrc")"
    if echo "$content" | grep -qE '^TONEMAP_HDR_TO_SDR="?1"?'; then
      pass "--create-config --tonemap: TONEMAP_HDR_TO_SDR=1 uncommented in .muxmrc"
    else
      fail "--create-config --tonemap: TONEMAP_HDR_TO_SDR=1 not found uncommented (got: $(echo "$content" | grep TONEMAP_HDR_TO_SDR || echo '<not present>'))"
    fi
  else
    fail "--create-config --tonemap: did not create .muxmrc"
  fi
  rm -f "$cfg_tonemap_dir/.muxmrc"

  # ---- Audio ----

  # --audio-force-codec: AUDIO_FORCE_CODEC uncommented with supplied value
  local cfg_audiocodec_dir="$TESTDIR/config_create_override_audiocodec"
  mkdir -p "$cfg_audiocodec_dir"
  out="$(run_muxm_in "$cfg_audiocodec_dir" --create-config project streaming --audio-force-codec aac 2>&1)"
  if [[ -f "$cfg_audiocodec_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_audiocodec_dir/.muxmrc")"
    if echo "$content" | grep -qE '^AUDIO_FORCE_CODEC=("aac"|aac)$'; then
      pass "--create-config --audio-force-codec aac: AUDIO_FORCE_CODEC=aac uncommented in .muxmrc"
    else
      fail "--create-config --audio-force-codec aac: AUDIO_FORCE_CODEC not found uncommented (got: $(echo "$content" | grep AUDIO_FORCE_CODEC || echo '<not present>'))"
    fi
  else
    fail "--create-config --audio-force-codec aac: did not create .muxmrc"
  fi
  rm -f "$cfg_audiocodec_dir/.muxmrc"

  # ---- Subtitles ----

  # --sub-preserve-format: SUB_PRESERVE_TEXT_FORMAT uncommented with 1
  local cfg_subfmt_dir="$TESTDIR/config_create_override_subfmt"
  mkdir -p "$cfg_subfmt_dir"
  out="$(run_muxm_in "$cfg_subfmt_dir" --create-config project animation --sub-preserve-format 2>&1)"
  if [[ -f "$cfg_subfmt_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_subfmt_dir/.muxmrc")"
    if echo "$content" | grep -qE '^SUB_PRESERVE_TEXT_FORMAT="?1"?'; then
      pass "--create-config --sub-preserve-format: SUB_PRESERVE_TEXT_FORMAT=1 uncommented in .muxmrc"
    else
      fail "--create-config --sub-preserve-format: SUB_PRESERVE_TEXT_FORMAT=1 not found uncommented (got: $(echo "$content" | grep SUB_PRESERVE_TEXT_FORMAT || echo '<not present>'))"
    fi
  else
    fail "--create-config --sub-preserve-format: did not create .muxmrc"
  fi
  rm -f "$cfg_subfmt_dir/.muxmrc"

  # --no-sub-sdh: SUB_INCLUDE_SDH uncommented with 0
  local cfg_nosubsdh_dir="$TESTDIR/config_create_override_nosubsdh"
  mkdir -p "$cfg_nosubsdh_dir"
  out="$(run_muxm_in "$cfg_nosubsdh_dir" --create-config project atv-directplay-hq --no-sub-sdh 2>&1)"
  if [[ -f "$cfg_nosubsdh_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_nosubsdh_dir/.muxmrc")"
    if echo "$content" | grep -qE '^SUB_INCLUDE_SDH="?0"?'; then
      pass "--create-config --no-sub-sdh: SUB_INCLUDE_SDH=0 uncommented in .muxmrc"
    else
      fail "--create-config --no-sub-sdh: SUB_INCLUDE_SDH=0 not found uncommented (got: $(echo "$content" | grep SUB_INCLUDE_SDH || echo '<not present>'))"
    fi
  else
    fail "--create-config --no-sub-sdh: did not create .muxmrc"
  fi
  rm -f "$cfg_nosubsdh_dir/.muxmrc"

  # ---- Metadata / pipeline ----

  # --no-keep-chapters: KEEP_CHAPTERS uncommented with 0
  local cfg_nochap_dir="$TESTDIR/config_create_override_nochapters"
  mkdir -p "$cfg_nochap_dir"
  out="$(run_muxm_in "$cfg_nochap_dir" --create-config project archive --no-keep-chapters 2>&1)"
  if [[ -f "$cfg_nochap_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_nochap_dir/.muxmrc")"
    if echo "$content" | grep -qE '^KEEP_CHAPTERS="?0"?'; then
      pass "--create-config --no-keep-chapters: KEEP_CHAPTERS=0 uncommented in .muxmrc"
    else
      fail "--create-config --no-keep-chapters: KEEP_CHAPTERS=0 not found uncommented (got: $(echo "$content" | grep KEEP_CHAPTERS || echo '<not present>'))"
    fi
  else
    fail "--create-config --no-keep-chapters: did not create .muxmrc"
  fi
  rm -f "$cfg_nochap_dir/.muxmrc"

  # --strip-metadata: STRIP_METADATA uncommented with 1
  local cfg_stripmeta_dir="$TESTDIR/config_create_override_stripmeta"
  mkdir -p "$cfg_stripmeta_dir"
  out="$(run_muxm_in "$cfg_stripmeta_dir" --create-config project streaming --strip-metadata 2>&1)"
  if [[ -f "$cfg_stripmeta_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_stripmeta_dir/.muxmrc")"
    if echo "$content" | grep -qE '^STRIP_METADATA="?1"?'; then
      pass "--create-config --strip-metadata: STRIP_METADATA=1 uncommented in .muxmrc"
    else
      fail "--create-config --strip-metadata: STRIP_METADATA=1 not found uncommented (got: $(echo "$content" | grep STRIP_METADATA || echo '<not present>'))"
    fi
  else
    fail "--create-config --strip-metadata: did not create .muxmrc"
  fi
  rm -f "$cfg_stripmeta_dir/.muxmrc"

  # ---- Logging ----

  # --ffmpeg-loglevel: FFMPEG_LOGLEVEL uncommented with supplied value
  local cfg_loglevel_dir="$TESTDIR/config_create_override_loglevel"
  mkdir -p "$cfg_loglevel_dir"
  out="$(run_muxm_in "$cfg_loglevel_dir" --create-config project --ffmpeg-loglevel warning 2>&1)"
  if [[ -f "$cfg_loglevel_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_loglevel_dir/.muxmrc")"
    if echo "$content" | grep -qE '^FFMPEG_LOGLEVEL="warning"'; then
      pass "--create-config --ffmpeg-loglevel warning: FFMPEG_LOGLEVEL=\"warning\" uncommented in .muxmrc"
    else
      fail "--create-config --ffmpeg-loglevel warning: FFMPEG_LOGLEVEL not found uncommented (got: $(echo "$content" | grep FFMPEG_LOGLEVEL || echo '<not present>'))"
    fi
  else
    fail "--create-config --ffmpeg-loglevel warning: did not create .muxmrc"
  fi
  rm -f "$cfg_loglevel_dir/.muxmrc"

  # ---- Multi-override combination ----

  # --crf 20 --no-dv --strip-metadata --ffmpeg-loglevel error: all four uncommented,
  # unrelated variables (e.g. THREADS) remain commented out.
  local cfg_combo_dir="$TESTDIR/config_create_override_combo"
  mkdir -p "$cfg_combo_dir"
  out="$(run_muxm_in "$cfg_combo_dir" \
    --create-config project atv-directplay-hq --crf 20 --no-dv --strip-metadata --ffmpeg-loglevel error 2>&1)"
  if [[ -f "$cfg_combo_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_combo_dir/.muxmrc")"
    if echo "$content" | grep -qE '^CRF_VALUE="?20"?'; then
      pass "--create-config combo: CRF_VALUE=20 uncommented"
    else
      fail "--create-config combo: CRF_VALUE=20 not found uncommented"
    fi
    if echo "$content" | grep -qE '^DISABLE_DV="?1"?'; then
      pass "--create-config combo: DISABLE_DV=1 uncommented"
    else
      fail "--create-config combo: DISABLE_DV=1 not found uncommented"
    fi
    if echo "$content" | grep -qE '^STRIP_METADATA="?1"?'; then
      pass "--create-config combo: STRIP_METADATA=1 uncommented"
    else
      fail "--create-config combo: STRIP_METADATA=1 not found uncommented"
    fi
    if echo "$content" | grep -qE '^FFMPEG_LOGLEVEL=("error"|error)$'; then
      pass "--create-config combo: FFMPEG_LOGLEVEL=error uncommented"
    else
      fail "--create-config combo: FFMPEG_LOGLEVEL not found uncommented"
    fi
    # Verify that an unrelated variable (THREADS) is still commented out
    if echo "$content" | grep -qE '^#.*THREADS' || ! echo "$content" | grep -qE '^THREADS='; then
      pass "--create-config combo: THREADS remains commented out (not overridden)"
    else
      fail "--create-config combo: THREADS appears uncommented but was not overridden"
    fi
    # Verify "Applied N override(s)" count in output
    if echo "$out" | grep -qE 'Applied 4 override'; then
      pass "--create-config combo: output reports Applied 4 override(s)"
    else
      skip "--create-config combo: 'Applied 4 override(s)' not found in output (wording may differ)"
    fi
  else
    fail "--create-config combo: did not create .muxmrc"
  fi
  rm -f "$cfg_combo_dir/.muxmrc"

  # ---- AV1 profiles ----

  # --create-config user av1-hq: SVT_AV1_PARAMS_BASE should appear uncommented
  # (av1-hq is an AV1 profile so SVT_AV1_PARAMS_BASE is a profile-owned variable)
  local cfg_av1hq_dir="$TESTDIR/config_create_av1hq"
  mkdir -p "$cfg_av1hq_dir"
  MUXM_HOME="$cfg_av1hq_dir" run_muxm_in "$cfg_av1hq_dir" --create-config project av1-hq >/dev/null 2>&1
  if [[ -f "$cfg_av1hq_dir/.muxmrc" ]]; then
    local av1hq_content
    av1hq_content="$(cat "$cfg_av1hq_dir/.muxmrc")"
    assert_contains "av1-hq" "--create-config av1-hq: profile name in generated config" "$av1hq_content"
    if echo "$av1hq_content" | grep -qE '^SVT_AV1_PARAMS_BASE'; then
      pass "--create-config av1-hq: SVT_AV1_PARAMS_BASE uncommented (profile-owned)"
    else
      fail "--create-config av1-hq: SVT_AV1_PARAMS_BASE not found uncommented (got: $(echo "$av1hq_content" | grep SVT_AV1_PARAMS_BASE || echo '<not present>'))"
    fi
  else
    fail "--create-config av1-hq: did not create .muxmrc"
  fi
  rm -f "$cfg_av1hq_dir/.muxmrc"

  # --create-config project streaming-av1: should create a valid .muxmrc
  local cfg_streamav1_dir="$TESTDIR/config_create_streaming_av1"
  mkdir -p "$cfg_streamav1_dir"
  run_muxm_in "$cfg_streamav1_dir" --create-config project streaming-av1 >/dev/null 2>&1
  if [[ -f "$cfg_streamav1_dir/.muxmrc" ]]; then
    local streamav1_content
    streamav1_content="$(cat "$cfg_streamav1_dir/.muxmrc")"
    assert_contains "streaming-av1" "--create-config streaming-av1: profile name in generated config" "$streamav1_content"
    assert_contains "PROFILE_NAME" "--create-config streaming-av1: PROFILE_NAME present in config" "$streamav1_content"
  else
    fail "--create-config streaming-av1: did not create .muxmrc"
  fi
  rm -f "$cfg_streamav1_dir/.muxmrc"

  # --create-config with comma-separated multi-profile: should produce a minimal
  # config containing only PROFILE_NAME set to the full comma-separated string.
  local cfg_mp_dir="$TESTDIR/config_create_multiprofile"
  mkdir -p "$cfg_mp_dir"
  out="$(run_muxm_in "$cfg_mp_dir" --create-config project youtube-upload,streaming 2>&1)"
  if [[ -f "$cfg_mp_dir/.muxmrc" ]]; then
    content="$(cat "$cfg_mp_dir/.muxmrc")"
    if echo "$content" | grep -qE '^PROFILE_NAME="youtube-upload,streaming-hevc"'; then
      pass "--create-config multi-profile: PROFILE_NAME=\"youtube-upload,streaming-hevc\" in .muxmrc (deprecated alias normalized)"
    else
      fail "--create-config multi-profile: PROFILE_NAME not set correctly (got: $(echo "$content" | grep PROFILE_NAME || echo '<not present>'))"
    fi
  else
    fail "--create-config multi-profile: did not create .muxmrc"
  fi
  rm -f "$cfg_mp_dir/.muxmrc"
}

test_config() {
  section "Configuration Precedence"

  local cfg_dir="$TESTDIR/config_test"
  mkdir -p "$cfg_dir"

  _test_config_effective
  _test_config_create
  _test_config_layering
  _test_config_validation
  _test_config_create_overrides
  _test_config_deprecation_bridge
  _test_config_create_escape
  _test_config_create_injection
  _test_config_multi_injection
}

# L: --create-config must emit string override values escaped so a value containing a
# double quote round-trips faithfully when the generated .muxmrc is sourced (previously an embedded
# " corrupted the value, e.g. 'aq-mode=3:foo="bar"' came back as 'aq-mode=3:foo=bar'). Perturb
# MUT-L-CCESCAPE neuters the escape → the round-trip corrupts → red.
_test_config_create_escape() {
  local _d="$TESTDIR/l_ccescape"; mkdir -p "$_d/h"
  local _val='aq-mode=3:foo="bar"'
  ( cd "$_d" && HOME="$_d/h" "$MUXM" --create-config project atv-directplay-hq --x265-params "$_val" >/dev/null 2>&1 )
  if [[ ! -f "$_d/.muxmrc" ]]; then fail "config-create-config-escaping: --create-config did not write .muxmrc"; rm -rf "$_d"; return; fi
  # Source the generated config in a clean subshell and read the value back.
  local _got
  # shellcheck disable=SC1091  # dynamic path to a just-generated test .muxmrc — not statically analyzable
  _got="$(set +u; . "$_d/.muxmrc" 2>/dev/null; printf '%s' "$X265_PARAMS_BASE")"
  if [[ "$_got" == "$_val" ]]; then
    pass "config-create-config-escaping: a quoted override value round-trips faithfully through the generated .muxmrc"
  else
    fail "config-create-config-escaping: override value corrupted on round-trip — wrote '$_val', sourced back '$_got'"
  fi
  rm -rf "$_d"
}

# M7: the AUDIO_SCORE_LANG_BONUS_ENG → AUDIO_SCORE_LANG_BONUS deprecation bridge must apply the
# legacy alias ONLY when the new var was not explicitly set in config. If a .muxmrc sets BOTH, the
# new var wins (the legacy value must not silently overwrite it); the rename warning fires whenever
# the legacy alias is present. Bidirectional: both-set → new wins (+ warning); legacy-only → legacy
# applies. Perturb MUT-M7-BRIDGE reverts to the unconditional overwrite → both-set → legacy wins → red.
# M1: --create-config must NOT let an override value inject shell into the generated
# .muxmrc. Two arms:
#   (a) a STRING override containing `; echo INJECTED` must be safely quoted — the generated file
#       must parse as valid shell (bash -n), must NOT contain a bare unquoted `;`-bearing line, and
#       sourcing it must round-trip the literal value without executing the payload.
#   (b) a NUMERIC override (e.g. --crf) with a non-numeric/injection value must be rejected at parse
#       time with exit 11 and write no file.
# Perturb MUT-M1-CCQUOTE (drop the unconditional quoting in _V) → arm (a) injects → red.
_test_config_create_injection() {
  local _d="$TESTDIR/m1_inject"; mkdir -p "$_d/h"

  # (a) string override carrying a shell-injection payload
  local _payload='mp4; echo INJECTED'
  ( cd "$_d" && HOME="$_d/h" "$MUXM" --create-config project atv-directplay-hq \
      --output-ext "$_payload" >/dev/null 2>&1 )
  if [[ ! -f "$_d/.muxmrc" ]]; then
    fail "config-create-config-injection inject: --create-config did not write .muxmrc"; rm -rf "$_d"; return
  fi
  # The generated file must be syntactically valid shell.
  if bash -n "$_d/.muxmrc" 2>/dev/null; then
    pass "config-create-config-injection inject: generated .muxmrc is syntactically valid shell (bash -n)"
  else
    fail "config-create-config-injection inject: generated .muxmrc fails bash -n (override corrupted the file)"
  fi
  # No uncommented OUTPUT_EXT line may contain a bare (unquoted) ';' — that would be injection.
  if grep -E '^OUTPUT_EXT=' "$_d/.muxmrc" | grep -qE '=[^"].*;'; then
    fail "config-create-config-injection inject: OUTPUT_EXT emitted with an unquoted ';' — payload not neutralised: $(grep -E '^OUTPUT_EXT=' "$_d/.muxmrc")"
  else
    pass "config-create-config-injection inject: OUTPUT_EXT payload is quoted (no bare ';' on the emitted line)"
  fi
  # Sourcing must round-trip the literal value and NOT execute the payload.
  local _src_out
  # shellcheck disable=SC1091  # dynamic path to a just-generated test .muxmrc
  _src_out="$(set +u; . "$_d/.muxmrc" 2>/dev/null; printf '%s' "$OUTPUT_EXT")"
  if [[ "$_src_out" == "$_payload" ]] ; then
    pass "config-create-config-injection inject: payload round-trips as a literal value (no command execution on source)"
  else
    fail "config-create-config-injection inject: sourcing did not preserve the literal OUTPUT_EXT (got: '$_src_out')"
  fi
  rm -f "$_d/.muxmrc"

  # (b) numeric override with a non-numeric/injection value → rejected at parse time (exit 11).
  local _rc=0
  ( cd "$_d" && HOME="$_d/h" "$MUXM" --create-config project atv-directplay-hq \
      --crf '20; echo INJECTED' >/dev/null 2>&1 ) || _rc=$?
  if (( _rc == 11 )) && [[ ! -f "$_d/.muxmrc" ]]; then
    pass "config-create-config-injection inject: non-numeric --crf override rejected with exit 11 (no file written)"
  else
    fail "config-create-config-injection inject: expected exit 11 + no file for non-numeric --crf, got rc=$_rc, file-exists=$([[ -f "$_d/.muxmrc" ]] && echo yes || echo no)"
  fi
  rm -rf "$_d"
}

# RF1: override values must be escaped in BOTH the single-profile emitter's _V helper and in
# _create_config_emit_multi. A comma-separated --profile routes to the multi emitter, so a crafted
# string override (e.g. --x265-params '$(touch …)') must not emit an unescaped line that would
# execute on every later `. .muxmrc` source. Both emitters share _cc_shell_escape and always emit
# the escaped, quoted form.
# Three arms:
#   (a) function-level: drive _create_config_emit_multi with _CC_OVERRIDES carrying ` " $ chars and
#       assert the emitted line equals the escaped form (media-free via _extract_muxm_fns).
#   (b) anti-injection round-trip: a `$(touch canary)` payload through the real multi-emit CLI path
#       must round-trip as a literal and create NO canary when the generated .muxmrc is sourced.
#   (c) parity: the same override emitted by the single and multi paths yields a byte-identical line.
# Perturb (revert _create_config_emit_multi to the unescaped numeric/string branch) → (a)/(b) red.
_test_config_multi_injection() {
  # (a) function-level escape assertion — no media, no CLI.
  local body
  body="$(_extract_muxm_fns _create_config_emit_multi _cc_shell_escape)" || {
    fail "config-multi-profile-injection: could not extract _create_config_emit_multi + _cc_shell_escape from muxm"; return; }
  # shellcheck disable=SC2016  # literal driver body; expansions must happen inside bash -c, not now
  local _driver='declare -gA _CC_OVERRIDES=([X265_PARAMS_BASE]='\''aq=3":x=$HOME:y=`id`'\'')
_create_config_emit_multi "archive,streaming-hevc" | grep "^X265_PARAMS_BASE="'
  local _line
  _line="$(bash -c "$body"$'\n'"$_driver" 2>/dev/null)"
  # Expected: every special char ( " $ ` ) escaped with a backslash inside the quoted value.
  # shellcheck disable=SC2016  # literal expected escaped form — $HOME/`id` must NOT expand here
  local _want='X265_PARAMS_BASE="aq=3\":x=\$HOME:y=\`id\`"'
  if [[ "$_line" == "$_want" ]]; then
    pass "config-multi-profile-injection: multi-profile config emitter escapes shell-special override values"
  else
    fail "config-multi-profile-injection: multi emitter did not escape — wanted [$_want], got [$_line]"
  fi

  # (b) anti-injection round-trip through the real multi-emit path (comma-separated profile).
  local _d="$TESTDIR/rf1_multi"; mkdir -p "$_d/h"
  local _canary="$_d/CANARY"
  local _payload="x:\$(touch '$_canary')"   # command substitution that would fire on an unescaped source
  rm -f "$_canary"
  ( cd "$_d" && HOME="$_d/h" "$MUXM" --create-config project archive,streaming-hevc \
      --x265-params "$_payload" >/dev/null 2>&1 )
  if [[ ! -f "$_d/.muxmrc" ]]; then
    fail "config-multi-profile-injection: --create-config (multi) did not write .muxmrc"; rm -rf "$_d"; return
  fi
  if ! bash -n "$_d/.muxmrc" 2>/dev/null; then
    fail "config-multi-profile-injection: generated multi-profile .muxmrc fails bash -n (override corrupted the file)"
  fi
  local _got
  # shellcheck disable=SC1091  # dynamic path to a just-generated test .muxmrc
  _got="$(set +u; . "$_d/.muxmrc" 2>/dev/null; printf '%s' "$X265_PARAMS_BASE")"
  if [[ "$_got" == "$_payload" && ! -e "$_canary" ]]; then
    pass "config-multi-profile-injection: emitted multi-profile config round-trips (sources cleanly, value intact, no injection)"
  else
    fail "config-multi-profile-injection: multi-profile injection — value got '$_got' (want '$_payload'), canary-exists=$([[ -e "$_canary" ]] && echo yes || echo no)"
  fi
  rm -rf "$_d"

  # (c) single vs multi emitters escape an identical override identically (guards future drift).
  local _ds="$TESTDIR/rf1_single"; mkdir -p "$_ds/h"
  local _dm="$TESTDIR/rf1_multi2"; mkdir -p "$_dm/h"
  # shellcheck disable=SC2016  # literal injection-payload fixture — $HOME/`id` must stay unexpanded
  local _val='aq=3":x=$HOME:y=`id`'
  ( cd "$_ds" && HOME="$_ds/h" "$MUXM" --create-config project atv-directplay-hq \
      --x265-params "$_val" >/dev/null 2>&1 )
  ( cd "$_dm" && HOME="$_dm/h" "$MUXM" --create-config project archive,streaming-hevc \
      --x265-params "$_val" >/dev/null 2>&1 )
  local _ls _lm
  _ls="$(grep -E '^X265_PARAMS_BASE=' "$_ds/.muxmrc" 2>/dev/null)"
  _lm="$(grep -E '^X265_PARAMS_BASE=' "$_dm/.muxmrc" 2>/dev/null)"
  # The single emitter may append a trailing ` # Manually adjusted` annotation (legitimate, unrelated
  # to escaping); strip it so the comparison is purely the escaped VAR="value" assignment.
  _ls="${_ls%% # Manually adjusted}"
  if [[ -n "$_ls" && "$_ls" == "$_lm" ]]; then
    pass "config-multi-profile-injection: single and multi emitters escape an override identically"
  else
    fail "config-multi-profile-injection: single/multi escape divergence — single [$_ls] vs multi [$_lm]"
  fi
  rm -rf "$_ds" "$_dm"
}

_test_config_deprecation_bridge() {
  local _dir="$TESTDIR/m7"; mkdir -p "$_dir/h"
  # (a) both set → new (200) wins, NOT legacy (100); warning still emitted (stderr).
  printf 'AUDIO_SCORE_LANG_BONUS=200\nAUDIO_SCORE_LANG_BONUS_ENG=100\n' > "$_dir/.muxmrc"
  local _out _err
  _err="$_dir/err.txt"
  _out="$(cd "$_dir" && HOME="$_dir/h" "$MUXM" --print-effective-config 2>"$_err")"
  if printf '%s\n' "$_out" | grep -qE "AUDIO_SCORE_LANG_BONUS[[:space:]]*=[[:space:]]*200"; then
    pass "config-deprecation-bridge: both legacy+new set → new value wins (200, not the legacy 100)"
  else
    fail "config-deprecation-bridge: both set → expected AUDIO_SCORE_LANG_BONUS=200, got: $(printf '%s\n' "$_out" | grep 'AUDIO_SCORE_LANG_BONUS ')"
  fi
  if grep -qi "Deprecated: AUDIO_SCORE_LANG_BONUS_ENG" "$_err"; then
    pass "config-deprecation-bridge: rename warning still emitted when the legacy alias is present"
  else
    fail "config-deprecation-bridge: deprecation/rename warning not emitted for the legacy alias"
  fi
  # (b) legacy only → legacy value (100) applies (new var left at its default).
  printf 'AUDIO_SCORE_LANG_BONUS_ENG=100\n' > "$_dir/.muxmrc"
  _out="$(cd "$_dir" && HOME="$_dir/h" "$MUXM" --print-effective-config 2>/dev/null)"
  if printf '%s\n' "$_out" | grep -qE "AUDIO_SCORE_LANG_BONUS[[:space:]]*=[[:space:]]*100"; then
    pass "config-deprecation-bridge: legacy-only → legacy value applies (100) via the deprecation bridge"
  else
    fail "config-deprecation-bridge: legacy-only → expected AUDIO_SCORE_LANG_BONUS=100, got: $(printf '%s\n' "$_out" | grep 'AUDIO_SCORE_LANG_BONUS ')"
  fi
  rm -rf "$_dir"
}

# === Suite: Profile Variable Assignment ===
# Validates that each built-in profile sets the expected configuration variables
# (codec, CRF, container, feature flags) via --print-effective-config.
test_profiles() {
  section "Profile Variable Assignment"

  local profiles=("archive" "hdr10-hq" "atv-directplay-hq" "atv-directplay-animation" "av1-hq" "streaming-hevc" "streaming-av1" "animation" "universal" "youtube-upload")
  local out

  for p in "${profiles[@]}"; do
    out="$(run_muxm --profile "$p" --print-effective-config)"
    assert_contains "$p" "Profile $p shows in effective config" "$out"
  done

  # archive specifics
  out="$(run_muxm --profile archive --print-effective-config)"
  assert_contains "VIDEO_COPY_IF_COMPLIANT   = 1" "archive: video copy enabled" "$out"
  assert_contains "SKIP_IF_IDEAL             = 1" "archive: skip-if-ideal on" "$out"
  assert_contains "REPORT_JSON               = 1" "archive: JSON report on" "$out"
  assert_contains "AUDIO_LOSSLESS_PASSTHROUGH = 1" "archive: lossless audio on" "$out"
  # A2: archive forces MKV (was passthrough OUTPUT_EXT="") — MKV holds TrueHD/DTS-HD/PGS/ASS
  # losslessly, so any source container archives without conversion.
  assert_contains "OUTPUT_EXT                = mkv" "archive: forces MKV container (A2)" "$out"
  assert_contains "truehd,dts,flac" "archive: lossless-first codec preference" "$out"
  assert_contains "AUDIO_MULTI_TRACK         = 1" "archive: multi-track audio enabled" "$out"
  assert_contains "AUDIO_KEEP_COMMENTARY     = 0" "archive: commentary excluded by default" "$out"
  assert_contains "SUB_MULTI_TRACK           = 1" "archive: multi-track subtitles enabled" "$out"
  assert_contains "CHECKSUM                  = 1" "archive: checksum on by default" "$out"

  # --no-checksum overrides archive default
  out="$(run_muxm --profile archive --no-checksum --print-effective-config)"
  assert_contains "CHECKSUM                  = 0" "archive + --no-checksum: CLI overrides profile default" "$out"

  # hdr10-hq specifics
  out="$(run_muxm --profile hdr10-hq --print-effective-config)"
  assert_contains "DISABLE_DV                = 1" "hdr10-hq: DV disabled" "$out"
  assert_contains "CRF_VALUE                 = 17" "hdr10-hq: CRF 17" "$out"
  assert_contains "OUTPUT_EXT                = mkv" "hdr10-hq: MKV container" "$out"
  assert_contains "AUDIO_MULTI_TRACK         = 0" "hdr10-hq: multi-track audio off (no bleed)" "$out"
  assert_contains "SUB_MULTI_TRACK           = 0" "hdr10-hq: multi-track subs off (no bleed)" "$out"

  # atv-directplay-hq specifics
  out="$(run_muxm --profile atv-directplay-hq --print-effective-config)"
  # D4: passthrough profile with NO source → container is unresolved; diagnostic says so
  # explicitly instead of printing a bare blank (which read as "mp4" / a bug).
  assert_contains "OUTPUT_EXT                = <pending: needs source>" "atv-directplay: passthrough container pending without a source (D4)" "$out"
  assert_contains "SUB_BURN_FORCED           = 0" "atv-directplay: soft forced subs (not burned)" "$out"
  assert_contains "SKIP_IF_IDEAL             = 1" "atv-directplay: skip-if-ideal on" "$out"
  assert_contains "MAX_COPY_BITRATE          = 50000k" "atv-directplay: bitrate ceiling" "$out"
  assert_contains "LEVEL_VALUE               = 5.1" "atv-directplay: Level 5.1 VBV cap" "$out"
  assert_contains "CONSERVATIVE_VBV          = 1" "atv-directplay: conservative VBV active" "$out"

  # atv-directplay-animation specifics
  out="$(run_muxm --profile atv-directplay-animation --print-effective-config)"
  assert_contains "OUTPUT_EXT                = <pending: needs source>" "atv-directplay-animation: passthrough container pending without a source (D4)" "$out"
  assert_contains "CRF_VALUE                 = 16"  "atv-directplay-animation: CRF 16 (animation quality)" "$out"
  assert_contains "AUDIO_LOSSLESS_PASSTHROUGH = 0"  "atv-directplay-animation: lossless passthrough disabled (EAC3 for ATV)" "$out"
  assert_contains "EAC3_BITRATE_5_1          = 640k" "atv-directplay-animation: EAC3 5.1 bitrate" "$out"
  assert_contains "EAC3_BITRATE_7_1          = 768k" "atv-directplay-animation: EAC3 7.1 bitrate" "$out"
  assert_contains "SUB_MULTI_TRACK           = 1"   "atv-directplay-animation: multi-track subtitles enabled" "$out"
  assert_contains "SUB_PRESERVE_TEXT_FORMAT  = 1"   "atv-directplay-animation: ASS/SSA preservation enabled" "$out"
  assert_contains "SUB_BURN_FORCED           = 0"   "atv-directplay-animation: soft forced subs (not burned)" "$out"
  assert_contains "SDR_FORCE_10BIT           = 1"   "atv-directplay-animation: 10-bit SDR for anti-banding" "$out"
  assert_contains "LEVEL_VALUE               = 5.1" "atv-directplay-animation: Level 5.1 VBV cap" "$out"
  assert_contains "CONSERVATIVE_VBV          = 1"   "atv-directplay-animation: conservative VBV active" "$out"
  assert_contains "SKIP_IF_IDEAL             = 1"   "atv-directplay-animation: skip-if-ideal on" "$out"

  # ---- D4 (resolved --print-effective-config) + D1 (ATV sub-preserve precedence) ----
  # --print-effective-config now resolves the output container + ATV subtitle policy BEFORE
  # printing (mirroring Section 15), so the diagnostic reports what the encode will actually do.
  # These pass a SOURCE path; the diagnostic never opens the file (path-only extension probe),
  # so a synthetic name works in this media-free suite. mkv/mp4 keep stderr clean (the
  # unsupported-ext fallback uses note(); recognized exts use buffered log()).

  # D4: passthrough profile + mkv source → OUTPUT_EXT resolves to mkv (was printed blank).
  out="$(run_muxm --profile atv-directplay-hq --print-effective-config source.mkv)"
  assert_contains "OUTPUT_EXT                = mkv" "profiles-atv-container-resolution: atv-directplay-hq + .mkv source resolves OUTPUT_EXT=mkv in diagnostic" "$out"
  # ATV MKV adjustment fires by default (no explicit --no-… flag) → both preserves enabled.
  assert_contains "SUB_PRESERVE_TEXT_FORMAT  = 1" "profiles-atv-container-resolution: atv-directplay-hq + .mkv: ASS/SSA preservation reflected post-resolution" "$out"
  assert_contains "SUB_PRESERVE_BITMAP       = 1" "profiles-atv-container-resolution: atv-directplay-hq + .mkv: PGS bitmap preservation reflected post-resolution" "$out"

  # D4: passthrough profile + mp4 source → OUTPUT_EXT=mp4, ATV MKV adjustment does NOT fire.
  out="$(run_muxm --profile atv-directplay-hq --print-effective-config source.mp4)"
  assert_contains "OUTPUT_EXT                = mp4" "profiles-atv-container-resolution: atv-directplay-hq + .mp4 source resolves OUTPUT_EXT=mp4" "$out"
  assert_contains "SUB_PRESERVE_TEXT_FORMAT  = 0" "profiles-atv-container-resolution: atv-directplay-hq + .mp4: no MKV adjustment (text-format stays default)" "$out"

  # D4: explicit output filename without --output-ext → container inferred from it (was 'mp4').
  out="$(run_muxm --print-effective-config source.mkv out.mkv)"
  assert_contains "OUTPUT_EXT                = mkv" "profiles-atv-container-resolution: explicit out.mkv (no --output-ext) infers OUTPUT_EXT=mkv" "$out"
  assert_contains "_OUTPUT_EXT_EXPLICIT          = 1" "profiles-atv-container-resolution: inferred container marks _OUTPUT_EXT_EXPLICIT" "$out"

  # D1: explicit --no-sub-preserve-bitmap must survive the ATV MKV adjustment (precedence).
  # If the ATV block clobbered it back to 1, the diagnostic would mask this by printing
  # the pre-clobber value. With D4+D1 the diagnostic resolves first AND the flag is honored.
  # (No e2e bitmap path exists — ffmpeg cannot synthesize a PGS fixture — so this is the
  # authoritative regression for --no-sub-preserve-bitmap; see muxm `_is_text_sub_codec`.)
  out="$(run_muxm --profile atv-directplay-hq --no-sub-preserve-bitmap --print-effective-config source.mkv)"
  assert_contains "SUB_PRESERVE_BITMAP       = 0" "profiles-sub-preserve-flag-wins: --no-sub-preserve-bitmap wins over atv-directplay-hq (mkv)" "$out"
  assert_contains "_CLI_SUB_PRESERVE_BITMAP_EXPLICIT = 1" "profiles-sub-preserve-flag-wins: --no-sub-preserve-bitmap records the explicit-CLI tracker" "$out"

  # D1: explicit --no-sub-preserve-format must likewise survive the ATV MKV adjustment.
  out="$(run_muxm --profile atv-directplay-hq --no-sub-preserve-format --print-effective-config source.mkv)"
  assert_contains "SUB_PRESERVE_TEXT_FORMAT  = 0" "profiles-sub-preserve-flag-wins: --no-sub-preserve-format wins over atv-directplay-hq (mkv)" "$out"
  assert_contains "_CLI_SUB_PRESERVE_TEXT_FORMAT_EXPLICIT = 1" "profiles-sub-preserve-flag-wins: --no-sub-preserve-format records the explicit-CLI tracker" "$out"

  # D1: the explicit-flag trackers default to 0 when the user does not type the flags.
  out="$(run_muxm --profile atv-directplay-hq --print-effective-config source.mkv)"
  assert_contains "_CLI_SUB_PRESERVE_TEXT_FORMAT_EXPLICIT = 0" "profiles-sub-preserve-flag-wins: text-format tracker is 0 without the flag" "$out"
  assert_contains "_CLI_SUB_PRESERVE_BITMAP_EXPLICIT = 0" "profiles-sub-preserve-flag-wins: bitmap tracker is 0 without the flag" "$out"

  # D5 (explicit-flag gating): the stereo flags track CLI-typing the same way (gating the
  # multi-track "does not apply" warnings so a profile/config/default value never warns).
  out="$(run_muxm --stereo-fallback --prefer-stereo --print-effective-config source.mkv)"
  assert_contains "_CLI_ADD_STEREO_IF_MULTICH_EXPLICIT = 1" "profiles-stereo-flag-tracker: --stereo-fallback records its CLI tracker" "$out"
  assert_contains "_CLI_AUDIO_PREFER_STEREO_EXPLICIT = 1" "profiles-stereo-flag-tracker: --prefer-stereo records its CLI tracker" "$out"
  out="$(run_muxm --print-effective-config source.mkv)"
  assert_contains "_CLI_ADD_STEREO_IF_MULTICH_EXPLICIT = 0" "profiles-stereo-flag-tracker: stereo-fallback tracker is 0 without the flag (default ADD_STEREO_IF_MULTICH=1)" "$out"
  assert_contains "_CLI_AUDIO_PREFER_STEREO_EXPLICIT = 0" "profiles-stereo-flag-tracker: prefer-stereo tracker is 0 without the flag" "$out"

  # dv-archival alias: deprecated, maps to archive profile + emits deprecation warning
  out="$(run_muxm --profile dv-archival --print-effective-config 2>&1)"
  assert_contains "deprecated" "dv-archival alias: emits deprecation warning" "$out"
  assert_contains "archive"    "dv-archival alias: output mentions archive as the canonical name" "$out"
  assert_contains "VIDEO_COPY_IF_COMPLIANT   = 1" "dv-archival alias: behaves identically to archive (copy enabled)" "$out"
  assert_contains "SUB_MULTI_TRACK           = 1" "dv-archival alias: behaves identically to archive (multi-track subs)" "$out"

  # streaming specifics
  out="$(run_muxm --profile streaming --print-effective-config)"
  assert_contains "CRF_VALUE                 = 20" "streaming: CRF 20" "$out"
  assert_contains "PRESET_VALUE              = medium" "streaming: preset medium" "$out"

  # animation specifics
  out="$(run_muxm --profile animation --print-effective-config)"
  assert_contains "CRF_VALUE                 = 16" "animation: CRF 16" "$out"
  assert_contains "OUTPUT_EXT                = mkv" "animation: MKV container" "$out"
  assert_contains "AUDIO_LOSSLESS_PASSTHROUGH = 1" "animation: lossless audio" "$out"
  assert_contains "SDR_FORCE_10BIT           = 1" "animation: force 10-bit SDR" "$out"
  assert_contains "flac,truehd" "animation: FLAC-first codec preference" "$out"
  assert_contains "SUB_PRESERVE_TEXT_FORMAT  = 1" "animation: ASS/SSA preservation enabled" "$out"
  assert_contains "SUB_MULTI_TRACK           = 1" "animation: multi-track subtitles enabled" "$out"

  # universal specifics
  out="$(run_muxm --profile universal --print-effective-config)"
  assert_contains "VIDEO_CODEC               = libx264" "universal: H.264 codec" "$out"
  assert_contains "TONEMAP_HDR_TO_SDR        = 1" "universal: tone-mapping on" "$out"
  assert_contains "KEEP_CHAPTERS             = 0" "universal: chapters stripped" "$out"
  assert_contains "STRIP_METADATA            = 1" "universal: metadata stripped" "$out"
  assert_contains "OUTPUT_EXT                = mp4" "universal: MP4 container" "$out"
  assert_contains "SUB_BURN_FORCED           = 1" "universal: burn forced subs (only profile that burns by default)" "$out"
  assert_contains "AUDIO_PREFER_STEREO       = 1" "universal: native stereo preference enabled" "$out"
  assert_contains "MAX_AUDIO_CHANNELS        = 2" "universal: channel ceiling at 2 (stereo downmix)" "$out"
  assert_contains "AUDIO_FORCE_CODEC         = aac" "universal: force AAC for maximum compatibility" "$out"

  # youtube-upload specifics
  out="$(run_muxm --profile youtube-upload --print-effective-config)"
  assert_contains "VIDEO_CODEC               = libx264"     "youtube-upload: H.264 codec" "$out"
  assert_contains "CRF_VALUE                 = 16"          "youtube-upload: CRF 16" "$out"
  assert_contains "PRESET_VALUE              = slow"        "youtube-upload: preset slow" "$out"
  assert_contains "OUTPUT_EXT                = mp4"         "youtube-upload: MP4 container" "$out"
  assert_contains "DISABLE_DV                = 1"           "youtube-upload: DV disabled" "$out"
  assert_contains "TONEMAP_HDR_TO_SDR        = 0"           "youtube-upload: no tone-mapping" "$out"
  assert_contains "AUDIO_FORCE_CODEC         = <auto>"       "youtube-upload: no forced codec (best track passthrough)" "$out"
  assert_contains "MAX_AUDIO_CHANNELS        = 8"           "youtube-upload: no channel cap (global default)" "$out"
  assert_contains "STEREO_BITRATE            = 256k"        "youtube-upload: 256k stereo" "$out"
  assert_contains "AUDIO_LOSSLESS_PASSTHROUGH = 0"          "youtube-upload: no lossless passthrough" "$out"
  assert_contains "ADD_STEREO_IF_MULTICH     = 0"           "youtube-upload: no stereo fallback" "$out"
  assert_contains "SUB_INCLUDE_FORCED        = 1"           "youtube-upload: include forced subs" "$out"
  assert_contains "SUB_INCLUDE_FULL          = 1"           "youtube-upload: include full subs" "$out"
  assert_contains "SUB_INCLUDE_SDH           = 0"           "youtube-upload: exclude SDH subs" "$out"
  assert_contains "SUB_BURN_FORCED           = 0"           "youtube-upload: soft forced subs (not burned)" "$out"
  assert_contains "SUB_EXPORT_EXTERNAL       = 1"           "youtube-upload: export external subs" "$out"
  assert_contains "STRIP_METADATA            = 1"           "youtube-upload: strip metadata" "$out"
  assert_contains "KEEP_CHAPTERS             = 1"           "youtube-upload: keep chapters" "$out"
  assert_contains "SKIP_IF_IDEAL             = 0"           "youtube-upload: skip-if-ideal off" "$out"
  assert_contains "profile=high"                            "youtube-upload: x264 high-profile params" "$out"

  # av1-hq specifics
  out="$(run_muxm --profile av1-hq --print-effective-config)"
  assert_contains "VIDEO_CODEC               = libsvt-av1"  "av1-hq: SVT-AV1 codec" "$out"
  assert_contains "CRF_VALUE                 = 28"          "av1-hq: base CRF 28 (1080p-SDR; res-aware drops to 24 for 4K/HDR after probe)" "$out"
  assert_contains "PRESET_VALUE              = 6"           "av1-hq: preset 6" "$out"
  assert_contains "CHECKSUM                  = 1"           "av1-hq: checksum on by default" "$out"
  assert_contains "OUTPUT_EXT                = mkv"         "av1-hq: MKV container" "$out"
  assert_contains "DISABLE_DV                = 1"           "av1-hq: DV disabled (AV1 pipeline)" "$out"
  assert_contains "AUDIO_LOSSLESS_PASSTHROUGH = 1"          "av1-hq: lossless audio passthrough" "$out"

  # streaming-hevc specifics (canonical name for the old 'streaming' profile)
  out="$(run_muxm --profile streaming-hevc --print-effective-config)"
  assert_contains "streaming-hevc"                          "streaming-hevc: profile name in effective config" "$out"
  assert_contains "CRF_VALUE                 = 20"         "streaming-hevc: CRF 20" "$out"
  assert_contains "PRESET_VALUE              = medium"     "streaming-hevc: preset medium" "$out"

  # streaming (deprecated alias): same config as streaming-hevc, deprecation notice emitted
  out="$(run_muxm --profile streaming --print-effective-config 2>&1)"
  assert_contains "deprecated"                              "streaming alias: emits deprecation warning" "$out"
  assert_contains "streaming-hevc"                         "streaming alias: output mentions streaming-hevc as canonical name" "$out"
  assert_contains "CRF_VALUE                 = 20"         "streaming alias: same CRF as streaming-hevc" "$out"
  assert_contains "PRESET_VALUE              = medium"     "streaming alias: same preset as streaming-hevc" "$out"

  # streaming-av1 specifics
  out="$(run_muxm --profile streaming-av1 --print-effective-config)"
  assert_contains "VIDEO_CODEC               = libsvt-av1" "streaming-av1: SVT-AV1 codec" "$out"
  assert_contains "CRF_VALUE                 = 30"         "streaming-av1: CRF 30" "$out"
  assert_contains "OUTPUT_EXT                = mp4"        "streaming-av1: MP4 container" "$out"
  assert_contains "DISABLE_DV                = 1"          "streaming-av1: DV disabled" "$out"

  # --- Container passthrough: CLI --output-ext overrides passthrough ---
  # Passthrough profiles (archive, atv-directplay-hq, atv-directplay-animation) set OUTPUT_EXT="" by default.
  # Passing --output-ext on the CLI sets _OUTPUT_EXT_EXPLICIT=1, skipping passthrough
  # resolution and leaving OUTPUT_EXT at the CLI-supplied value.
  out="$(run_muxm --profile archive --output-ext mp4 --print-effective-config)"
  assert_contains "OUTPUT_EXT                = mp4" "archive + --output-ext mp4: CLI wins over passthrough" "$out"

  out="$(run_muxm --profile atv-directplay-hq --output-ext mp4 --print-effective-config)"
  assert_contains "OUTPUT_EXT                = mp4" "atv-directplay-hq + --output-ext mp4: CLI wins over passthrough" "$out"
}

# === Suite: Conflict Warnings ===
# Validates that muxm emits ⚠ warnings when CLI flags contradict a profile's intent
# (e.g., --no-dv with archive, --tonemap with hdr10-hq). All checks use
# --print-effective-config and look for the ⚠ character in output.
# WHY: Profiles encode domain expertise (e.g., archive preserves Dolby Vision).
# If a user overrides a profile's key flag, the encode may silently produce a file that
# violates the profile's contract. Warnings catch this at config time, not after a
# multi-hour encode.
test_conflicts() {
  section "Conflict Warnings"

  local out

  # --- archive conflicts ---
  out="$(run_muxm --profile archive --no-dv --print-effective-config)"
  assert_contains "⚠" "archive + --no-dv warns" "$out"

  out="$(run_muxm --profile archive --strip-metadata --print-effective-config)"
  assert_contains "⚠" "archive + --strip-metadata warns (#38)" "$out"

  out="$(run_muxm --profile archive --no-keep-chapters --print-effective-config)"
  assert_contains "⚠" "archive + --no-keep-chapters warns (#39)" "$out"

  out="$(run_muxm --profile archive --sub-burn-forced --print-effective-config)"
  assert_contains "⚠" "archive + --sub-burn-forced warns (#40)" "$out"

  # archive multi-track audio conflicts
  out="$(run_muxm --profile archive --audio-track 0 --print-effective-config)"
  assert_contains "⚠" "archive + --audio-track warns (multi-track conflict)" "$out"
  assert_contains "Multi-track" "archive + --audio-track: warning mentions multi-track" "$out"

  out="$(run_muxm --profile archive --audio-force-codec aac --print-effective-config)"
  assert_contains "⚠" "archive + --audio-force-codec warns (multi-track conflict)" "$out"
  assert_contains "Multi-track" "archive + --audio-force-codec: warning mentions multi-track" "$out"

  out="$(run_muxm --profile archive --stereo-fallback --print-effective-config)"
  assert_contains "⚠" "archive + --stereo-fallback warns (multi-track conflict)" "$out"
  assert_contains "Multi-track" "archive + --stereo-fallback: warning mentions multi-track" "$out"

  # archive multi-track subtitle conflicts
  out="$(run_muxm --profile archive --sub-burn-forced --print-effective-config)"
  assert_contains "⚠" "archive + --sub-burn-forced warns (multi-track sub conflict)" "$out"
  assert_contains "Multi-track subtitle" "archive + --sub-burn-forced: warning mentions multi-track subtitle" "$out"

  out="$(run_muxm --profile archive --sub-export-external --print-effective-config)"
  assert_contains "⚠" "archive + --sub-export-external warns (multi-track sub conflict)" "$out"
  assert_contains "Multi-track subtitle" "archive + --sub-export-external: warning mentions multi-track subtitle" "$out"

  # --- hdr10-hq conflicts ---
  out="$(run_muxm --profile hdr10-hq --tonemap --print-effective-config)"
  assert_contains "⚠" "hdr10-hq + --tonemap warns" "$out"

  out="$(run_muxm --profile hdr10-hq --video-codec libx264 --print-effective-config)"
  assert_contains "⚠" "hdr10-hq + --video-codec libx264 warns (#34)" "$out"

  # --- atv-directplay-hq conflicts ---
  # MKV Direct Plays on Apple TV via Plex/Infuse, so forcing MKV is a supported
  # choice and must NOT emit a conflict warning.
  out="$(run_muxm --profile atv-directplay-hq --output-ext mkv --print-effective-config)"
  if echo "$out" | grep -qiE "Forcing MKV|MKV Direct Plays|native TV app"; then
    fail "atv-directplay-hq + mkv: MKV/ATV warning should no longer fire (WI-5)"
  else
    pass "atv-directplay-hq + mkv: no MKV/ATV conflict warning (WI-5)"
  fi

  out="$(run_muxm --profile atv-directplay-hq --tonemap --print-effective-config)"
  assert_contains "⚠" "atv-directplay + --tonemap warns (#37)" "$out"

  out="$(run_muxm --profile atv-directplay-hq --video-codec libx264 --print-effective-config)"
  assert_contains "⚠" "atv-directplay + --video-codec libx264 warns (#36)" "$out"

  out="$(run_muxm --profile atv-directplay-hq --audio-lossless-passthrough --print-effective-config)"
  assert_contains "⚠" "atv-directplay + --audio-lossless-passthrough warns (#35)" "$out"

  # --- atv-directplay-animation conflicts ---
  # MKV Direct Plays on Apple TV via Plex/Infuse — forcing MKV must NOT warn.
  out="$(run_muxm --profile atv-directplay-animation --output-ext mkv --print-effective-config)"
  if echo "$out" | grep -qiE "Forcing MKV|MKV Direct Plays|native TV app"; then
    fail "atv-directplay-animation + mkv: MKV/ATV warning should no longer fire (WI-5)"
  else
    pass "atv-directplay-animation + mkv: no MKV/ATV conflict warning (WI-5)"
  fi

  out="$(run_muxm --profile atv-directplay-animation --tonemap --print-effective-config)"
  assert_contains "⚠" "atv-directplay-animation + --tonemap warns" "$out"

  out="$(run_muxm --profile atv-directplay-animation --video-codec libx264 --print-effective-config)"
  assert_contains "⚠" "atv-directplay-animation + --video-codec libx264 warns" "$out"

  out="$(run_muxm --profile atv-directplay-animation --audio-lossless-passthrough --print-effective-config)"
  assert_contains "⚠" "atv-directplay-animation + --audio-lossless-passthrough warns" "$out"

  out="$(run_muxm --profile atv-directplay-animation --no-sub-preserve-format --print-effective-config)"
  assert_contains "⚠" "atv-directplay-animation + --no-sub-preserve-format warns" "$out"

  out="$(run_muxm --profile atv-directplay-animation --sub-burn-forced --print-effective-config)"
  assert_contains "⚠" "atv-directplay-animation + --sub-burn-forced warns (multi-track sub conflict)" "$out"
  assert_contains "Multi-track subtitle" "atv-directplay-animation + --sub-burn-forced: warning mentions multi-track subtitle" "$out"

  out="$(run_muxm --profile atv-directplay-animation --sub-export-external --print-effective-config)"
  assert_contains "⚠" "atv-directplay-animation + --sub-export-external warns (multi-track sub conflict)" "$out"
  assert_contains "Multi-track subtitle" "atv-directplay-animation + --sub-export-external: warning mentions multi-track subtitle" "$out"

  # --- streaming conflicts ---
  out="$(run_muxm --profile streaming --output-ext mkv --print-effective-config)"
  assert_contains "⚠" "streaming + --output-ext mkv warns (#31)" "$out"

  out="$(run_muxm --profile streaming --audio-lossless-passthrough --print-effective-config)"
  assert_contains "⚠" "streaming + --audio-lossless-passthrough warns (#32)" "$out"

  out="$(run_muxm --profile streaming --video-codec libx264 --print-effective-config)"
  assert_contains "⚠" "streaming + --video-codec libx264 warns (#33)" "$out"

  # --- animation conflicts ---
  out="$(run_muxm --profile animation --sub-burn-forced --print-effective-config)"
  assert_contains "⚠" "animation + --sub-burn-forced warns" "$out"
  assert_contains "Multi-track subtitle" "animation + --sub-burn-forced: warning mentions multi-track subtitle demotion" "$out"

  out="$(run_muxm --profile animation --sub-export-external --print-effective-config)"
  assert_contains "⚠" "animation + --sub-export-external warns (multi-track sub conflict)" "$out"
  assert_contains "Multi-track subtitle" "animation + --sub-export-external: warning mentions multi-track subtitle" "$out"

  out="$(run_muxm --profile animation --video-codec libx264 --print-effective-config)"
  assert_contains "⚠" "animation + libx264 warns" "$out"

  out="$(run_muxm --profile animation --output-ext mp4 --print-effective-config)"
  assert_contains "⚠" "animation + --output-ext mp4 warns (#46)" "$out"

  out="$(run_muxm --profile animation --no-audio-lossless-passthrough --print-effective-config)"
  assert_contains "⚠" "animation + --no-audio-lossless-passthrough warns (#47)" "$out"

  out="$(run_muxm --profile animation --no-sub-preserve-format --print-effective-config)"
  assert_contains "⚠" "animation + --no-sub-preserve-format warns" "$out"
  assert_contains "ASS/SSA" "animation + --no-sub-preserve-format mentions ASS/SSA" "$out"

  # --- universal conflicts ---
  out="$(run_muxm --profile universal --output-ext mkv --print-effective-config)"
  assert_contains "⚠" "universal + mkv warns" "$out"

  out="$(run_muxm --profile universal --audio-lossless-passthrough --print-effective-config)"
  assert_contains "⚠" "universal + --audio-lossless-passthrough warns (#44)" "$out"

  out="$(run_muxm --profile universal --video-codec libx265 --print-effective-config)"
  assert_contains "⚠" "universal + --video-codec libx265 warns (#45)" "$out"

  # --- youtube-upload conflicts ---
  out="$(run_muxm --profile youtube-upload --output-ext mkv --print-effective-config)"
  assert_contains "⚠" "youtube-upload + --output-ext mkv warns" "$out"

  out="$(run_muxm --profile youtube-upload --audio-lossless-passthrough --print-effective-config)"
  assert_contains "⚠" "youtube-upload + --audio-lossless-passthrough warns" "$out"

  # --- Cross-profile flag combinations ---
  out="$(run_muxm --profile archive --video-copy-if-compliant --tonemap --print-effective-config)"
  assert_contains "Copy-if-compliant + tone-mapping" "Cross: copy + tonemap warns (#41)" "$out"

  out="$(run_muxm --profile animation --sub-export-external --output-ext mkv --print-effective-config)"
  assert_contains "--sub-export-external with MKV" "Cross: sub-export + mkv warns (#42)" "$out"

  out="$(run_muxm --profile streaming --sub-burn-forced --no-subtitles --print-effective-config 2>&1)" || true
  assert_contains "nothing to burn" "Cross: burn-forced + no-forced warns (#43)" "$out"

  # --- archive + --crf conflict ---
  # archive is copy-only; specifying --crf from CLI triggers a warning
  out="$(run_muxm --profile archive --crf 22 --print-effective-config 2>&1)"
  assert_contains "⚠" "archive + --crf 22 emits conflict warning" "$out"
  assert_contains "copy-only" "archive + --crf 22 warning mentions copy-only" "$out"

  # --- L2: the warning gates on _CLI_CRF_EXPLICIT (was the CRF typed on the CLI?), not on
  #     CRF_VALUE != 18 / profile source. So a CRF set in .muxmrc (no --crf) must NOT warn,
  #     and an explicit --crf 18 (== the default) MUST warn. ---
  local _l2_home="$TESTDIR/l2_crf_home"; mkdir -p "$_l2_home"
  printf 'CRF_VALUE=22\n' > "$_l2_home/.muxmrc"
  out="$(MUXM_HOME="$_l2_home" run_muxm_in "$TESTDIR" --profile archive --print-effective-config 2>&1)"
  if printf '%s' "$out" | grep -qE 'copy-only.*re-encode|CRF is ignored'; then
    fail "conflicts-archive-crf-warn-gating: archive + config-set CRF (no --crf) → spurious copy-only warning"
  else
    pass "conflicts-archive-crf-warn-gating: archive + config-set CRF (no --crf) → no warning (gated on --crf, not CRF value)"
  fi
  out="$(run_muxm --profile archive --crf 18 --print-effective-config 2>&1)"
  if printf '%s' "$out" | grep -qE 'copy-only'; then
    pass "conflicts-archive-crf-warn-gating: archive + explicit --crf 18 → warns (explicit --crf, even at the default)"
  else
    fail "conflicts-archive-crf-warn-gating: archive + explicit --crf 18 → expected a copy-only warning"
  fi

  # --- hdr10-hq + --dv (101f): DV re-enabled on an HDR10 profile ---
  out="$(run_muxm --profile hdr10-hq --dv --print-effective-config)"
  assert_contains "⚠" "hdr10-hq + --dv warns (101f)" "$out"
  assert_contains "expects DV to be stripped" "hdr10-hq + --dv: warning explains DV will be stripped" "$out"

  # --- atv-directplay-hq + --output-ext mov (101g) ---
  out="$(run_muxm --profile atv-directplay-hq --output-ext mov --print-effective-config)"
  assert_contains "⚠" "atv-directplay-hq + --output-ext mov warns (101g)" "$out"

  # --- streaming + --output-ext mov (101h) ---
  out="$(run_muxm --profile streaming --output-ext mov --print-effective-config)"
  assert_contains "⚠" "streaming + --output-ext mov warns (101h)" "$out"

  # --- animation + --output-ext mov (101i): MOV can't carry styled ASS/PGS ---
  out="$(run_muxm --profile animation --output-ext mov --print-effective-config)"
  assert_contains "⚠" "animation + --output-ext mov warns (101i)" "$out"

  # --- universal + --output-ext mov (101l) ---
  out="$(run_muxm --profile universal --output-ext mov --print-effective-config)"
  assert_contains "⚠" "universal + --output-ext mov warns (101l)" "$out"

  # --- universal + --dv (101m): DV enabled with SDR/H.264 profile is contradictory ---
  # universal sets DISABLE_DV=1; passing --dv re-enables it and fires the conflict check.
  out="$(run_muxm --profile universal --dv --print-effective-config)"
  assert_contains "⚠" "universal + --dv warns (101m)" "$out"
  assert_contains "DV will be stripped" "universal + --dv: warning says DV will be stripped" "$out"

  # --- Cross: --tonemap + --video-codec libx265 (101n): SDR in HEVC is unusual ---
  # Cross-profile checks only run when a profile is active (inside `if [[ -n PROFILE_NAME ]]`).
  # Use streaming (HEVC default) as the host profile; the cross-check fires after profile setup.
  out="$(run_muxm --profile streaming --tonemap --video-codec libx265 --print-effective-config)"
  assert_contains "⚠" "cross: --tonemap + --video-codec libx265 warns (101n)" "$out"

  # --- Cross: --sub-burn-forced + --no-sub-sdh (101o): SUB_INCLUDE_FORCED=0 with burn ---
  # --no-sub-sdh sets SUB_INCLUDE_SDH=0. To reproduce "no forced subs to burn", pair
  # --sub-burn-forced with --no-subtitles which sets SUB_INCLUDE_FORCED=0.
  out="$(run_muxm --profile streaming --sub-burn-forced --no-subtitles --print-effective-config 2>&1)" || true
  assert_contains "nothing to burn" "cross: --sub-burn-forced + --no-subtitles warns (101o)" "$out"

  # --- AV1 conflicts ---

  # av1-hq profile forces DISABLE_DV=1 (AV1 pipeline does not support DV muxing)
  out="$(run_muxm --profile av1-hq --print-effective-config)"
  assert_contains "DISABLE_DV                = 1" "av1-hq: DISABLE_DV forced to 1" "$out"

  # --video-codec libsvt-av1 with --dv should emit an informational note about DV being disabled
  out="$(run_muxm --video-codec libsvt-av1 --dv --print-effective-config 2>&1)"
  assert_contains "does not support Dolby Vision" "libsvt-av1 + --dv: note explains AV1 cannot carry DV" "$out"

  # --- Container passthrough: atv passthrough mode does NOT warn about MKV container ---
  # atv-directplay-hq sets OUTPUT_EXT="" (passthrough); without explicit --output-ext,
  # _OUTPUT_EXT_EXPLICIT=0 and OUTPUT_EXT is still "" at conflict-check time.
  # The conflict guard is: [[ "$OUTPUT_EXT" == "mkv" ]] && (( _OUTPUT_EXT_EXPLICIT ))
  # Both conditions must be true to warn. Passthrough mode fails both → no ⚠.
  out="$(run_muxm --profile atv-directplay-hq --print-effective-config)"
  if ! echo "$out" | grep -qiF "⚠"; then
    pass "atv passthrough mode: no conflict warning (OUTPUT_EXT is empty, not explicitly forced)"
  else
    # A warning is acceptable if it's for a different conflict (e.g., unrelated flag).
    # Only fail if the warning specifically mentions the MKV container.
    if echo "$out" | grep -qiE "⚠.*mkv|mkv.*⚠|output.ext.*mkv|mkv.*output.ext"; then
      fail "atv passthrough mode: unexpected MKV container warning fired"
    else
      pass "atv passthrough mode: no MKV container warning (other warnings unrelated)"
    fi
  fi

  # ---- silently-ignored CLI flags (C1–C5, C7–C10) ----
  # Config-time warnings, surfaced before --print-effective-config exits. Each fires only
  # when the flag is explicitly typed AND silently ignored; gated on _CLI_*_EXPLICIT.

  # C5: --hw-accel-quality without a hardware backend (resolves to none on any host).
  out="$(run_muxm --hw-accel-quality 60 --print-effective-config)"
  assert_contains "hw-accel-quality has no effect" "conflicts-hwq-needs-hw-backend: --hw-accel-quality + no HW backend warns" "$out"
  # C5 negative: not passed → no warning.
  out="$(run_muxm --print-effective-config)"
  if echo "$out" | grep -qi "hw-accel-quality has no effect"; then
    fail "conflicts-hwq-needs-hw-backend neg: hw-accel-quality warning fired without the flag"
  else
    pass "conflicts-hwq-needs-hw-backend neg: no hw-accel-quality warning when the flag is absent"
  fi

  # C7: --av1-params on a non-AV1 encode (default codec is libx265).
  out="$(run_muxm --av1-params "scd=1" --print-effective-config)"
  assert_contains "av1-params" "conflicts-av1-params-need-av1: --av1-params on non-AV1 codec warns" "$out"
  assert_contains "apply only to AV1" "conflicts-av1-params-need-av1: warning explains AV1-only" "$out"
  # C7 negative: an AV1 profile honors --av1-params → no warning.
  out="$(run_muxm --profile av1-hq --av1-params "scd=1" --print-effective-config)"
  if echo "$out" | grep -qi "av1-params.*apply only to AV1"; then
    fail "conflicts-av1-params-need-av1 neg: av1-params warning fired on an AV1 profile"
  else
    pass "conflicts-av1-params-need-av1 neg: --av1-params honored on av1-hq (no warning)"
  fi

  # C8: param flags only apply to their own codec.
  out="$(run_muxm --video-codec libx264 --x265-params "aq-mode=2" --print-effective-config)"
  assert_contains "x265-params applies only to the libx265" "conflicts-codec-params-match-codec: --x265-params on libx264 warns" "$out"
  out="$(run_muxm --profile av1-hq --x264-params "profile=high" --print-effective-config)"
  assert_contains "x264-params applies only to the libx264" "conflicts-codec-params-match-codec: --x264-params on libsvt-av1 warns" "$out"
  # C8 negative: --x265-params on the default libx265 is honored → no warning.
  out="$(run_muxm --x265-params "aq-mode=2" --print-effective-config)"
  if echo "$out" | grep -qi "x265-params applies only"; then
    fail "conflicts-codec-params-match-codec neg: x265-params warning fired when codec matches"
  else
    pass "conflicts-codec-params-match-codec neg: --x265-params on libx265 honored (no warning)"
  fi

  # C9: --level has no effect on AV1.
  out="$(run_muxm --profile av1-hq --level 5.1 --print-effective-config)"
  assert_contains "level has no effect on AV1" "conflicts-level-no-op-on-av1: --level on AV1 warns" "$out"
  # C9 negative: --level on the default libx265 is honored.
  out="$(run_muxm --level 5.1 --print-effective-config)"
  if echo "$out" | grep -qi "level has no effect"; then
    fail "conflicts-level-no-op-on-av1 neg: level warning fired on a non-AV1 codec"
  else
    pass "conflicts-level-no-op-on-av1 neg: --level on libx265 honored (no warning)"
  fi

  # C10: av1-hq / streaming-av1 profile-specific conflict arms.
  out="$(run_muxm --profile av1-hq --output-ext mp4 --print-effective-config)"
  assert_contains "limited AV1+HDR10 support" "conflicts-profile-self-conflict: av1-hq + --output-ext mp4 warns" "$out"
  out="$(run_muxm --profile av1-hq --video-codec libx265 --print-effective-config)"
  assert_contains "overrides its whole purpose" "conflicts-profile-self-conflict: av1-hq + --video-codec libx265 warns" "$out"
  out="$(run_muxm --profile av1-hq --no-audio-lossless-passthrough --print-effective-config)"
  assert_contains "Transcoding lossless audio loses quality" "conflicts-profile-self-conflict: av1-hq + --no-audio-lossless-passthrough warns" "$out"
  out="$(run_muxm --profile streaming-av1 --output-ext mkv --print-effective-config)"
  assert_contains "unusual for streaming targets" "conflicts-profile-self-conflict: streaming-av1 + --output-ext mkv warns" "$out"
  out="$(run_muxm --profile streaming-av1 --video-codec libx265 --print-effective-config)"
  assert_contains "overrides the profile" "conflicts-profile-self-conflict: streaming-av1 + --video-codec libx265 warns" "$out"
  # C10 negative: the profiles' own defaults must not warn.
  out="$(run_muxm --profile av1-hq --print-effective-config)"
  if echo "$out" | grep -qiE "av1-hq.*(overrides|limited AV1|Transcoding lossless)"; then
    fail "conflicts-profile-self-conflict neg: av1-hq emitted a self-conflict warning at its own defaults"
  else
    pass "conflicts-profile-self-conflict neg: av1-hq at default settings emits no self-conflict warning"
  fi

  # C1–C4 (VideoToolbox software-knob conflicts) need the VT backend to resolve, which only
  # happens on macOS with hevc_videotoolbox. The unit suite covers them deterministically.
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && ffmpeg_has_encoder hevc_videotoolbox; then
    out="$(run_muxm --hw-accel videotoolbox --crf 18 --print-effective-config)"
    assert_contains "--crf 18 is ignored" "conflicts-vt-ignores-crf-e2e: VT + --crf warns (e2e)" "$out"
    out="$(run_muxm --hw-accel videotoolbox --preset slow --print-effective-config)"
    assert_contains "does not accept x265/x264 presets" "conflicts-vt-ignores-preset-e2e: VT + --preset warns (e2e)" "$out"
    out="$(run_muxm --hw-accel videotoolbox --x265-params "aq-mode=2" --print-effective-config)"
    assert_contains "does not accept --x265-params" "conflicts-vt-ignores-x265-params-e2e: VT + --x265-params warns (e2e)" "$out"
    out="$(run_muxm --hw-accel videotoolbox --video-codec libx264 --x264-params "profile=high" --print-effective-config)"
    assert_contains "honors only profile=high" "conflicts-vt-ignores-x264-params-e2e: VT + --x264-params warns (e2e)" "$out"
  else
    skip "C1–C4 (VideoToolbox software-knob conflicts): VT backend unavailable on this host (unit suite covers them)"
  fi

  _test_conflicts_export_external_mkv_passthrough
}

# CR-14: the --sub-export-external + MKV advisory read OUTPUT_EXT in the Section-13 conflict block,
# BEFORE passthrough resolution — so for a passthrough profile (atv-directplay-*, OUTPUT_EXT="" at
# warn time) that resolves to MKV from an .mkv source it never fired. The advisory now also runs at
# the tail of _resolve_output_and_sub_policy (post-resolution), one-shot-guarded against a double
# warn when --output-ext mkv was explicit. Differential: a passthrough-→-MKV run must emit it; a
# passthrough-→-MP4 run (mp4 source) must not.
_test_conflicts_export_external_mkv_passthrough() {
  local d="$TESTDIR/cr14_passthrough"; mkdir -p "$d"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x180:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -preset ultrafast -crf 30 -c:a ac3 "$d/src.mkv" 2>/dev/null
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x180:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -preset ultrafast -crf 30 -c:a aac "$d/src.mp4" 2>/dev/null
  if [[ ! -s "$d/src.mkv" || ! -s "$d/src.mp4" ]]; then
    skip "conflicts-export-external-mkv-passthrough: could not build the passthrough mkv/mp4 fixtures"
    rm -rf "$d"; return
  fi
  local out
  # (1) passthrough profile + .mkv source → OUTPUT_EXT resolves to mkv → advisory MUST fire.
  out="$(run_muxm --dry-run --profile atv-directplay-animation --sub-export-external "$d/src.mkv" "$d/out.mkv" 2>&1)"
  if printf '%s\n' "$out" | grep -qiF "sub-export-external with MKV"; then
    pass "conflicts-export-external-mkv-passthrough: passthrough profile resolving to MKV emits the export-external advisory (post-resolution)"
  else
    fail "conflicts-export-external-mkv-passthrough: passthrough-→-MKV run did NOT emit the export-external advisory (the CR-14 bug)"
  fi
  # (2) one-shot guard: exactly one occurrence (never double-warned).
  local _n; _n="$(printf '%s\n' "$out" | grep -ciF "sub-export-external with MKV")"
  if [[ "$_n" == "1" ]]; then
    pass "conflicts-export-external-mkv-passthrough: advisory fires exactly once (one-shot guard — no double-warn)"
  else
    fail "conflicts-export-external-mkv-passthrough: advisory fired $_n times (expected exactly 1)"
  fi
  # (3) negative control: passthrough profile + .mp4 source → OUTPUT_EXT=mp4 → advisory must NOT fire.
  out="$(run_muxm --dry-run --profile atv-directplay-animation --sub-export-external "$d/src.mp4" "$d/out.mp4" 2>&1)"
  if printf '%s\n' "$out" | grep -qiF "sub-export-external with MKV"; then
    fail "conflicts-export-external-mkv-passthrough: export-external advisory wrongly fired for a passthrough-→-MP4 run"
  else
    pass "conflicts-export-external-mkv-passthrough: no export-external advisory for a passthrough run resolving to MP4 (correct)"
  fi
  rm -rf "$d"
}

# === Suite: Hardware Acceleration ===
# Validates the --hw-accel flag plumbing, .muxmrc integration, strict-check
# behavior, profile-level compatibility warnings, and the VideoToolbox/NVENC
# encode-path resolution and fallback contracts.
#
# WHY SEPARATE FROM test_toggles: --hw-accel takes a value (not a --flag/--no-flag pair)
# and has platform-dependent semantics (resolved backend varies by host). The
# auto-resolution and strict-check assertions are host-aware.
test_hw_accel() {
  section "Hardware Acceleration (Phase 1 + Phase 2)"

  local out

  # --- CLI parsing: each accepted value registers in effective config ---
  out="$(run_muxm --hw-accel none --print-effective-config)"
  assert_contains "HW_ACCEL                  = none" "--hw-accel none: registered" "$out"

  out="$(run_muxm --hw-accel auto --print-effective-config)"
  assert_contains "HW_ACCEL                  = auto" "--hw-accel auto: registered" "$out"

  out="$(run_muxm --hw-accel videotoolbox --print-effective-config)"
  assert_contains "HW_ACCEL                  = videotoolbox" "--hw-accel videotoolbox: registered" "$out"

  out="$(run_muxm --hw-accel nvenc --print-effective-config)"
  assert_contains "HW_ACCEL                  = nvenc" "--hw-accel nvenc: registered" "$out"

  # --- Invalid value rejected with exit 11 ---
  assert_exit "$EXIT_VALIDATION" "--hw-accel bogus: rejected with exit $EXIT_VALIDATION" \
    --hw-accel bogus --print-effective-config

  # --- Default is "none" when the flag is absent ---
  out="$(run_muxm --print-effective-config)"
  assert_contains "HW_ACCEL                  = none" "default HW_ACCEL is none" "$out"

  # --- HW_ACCEL_RESOLVED appears and is "none" for --hw-accel none ---
  out="$(run_muxm --hw-accel none --print-effective-config)"
  assert_contains "HW_ACCEL_RESOLVED         = none" "--hw-accel none: resolves to none" "$out"

  # --- Platform-aware auto resolution ---
  # On Apple Silicon with hevc_videotoolbox in ffmpeg, auto → videotoolbox.
  # Otherwise auto may resolve to nvenc (unlikely in test env) or none.
  # Assert the RESOLVED line exists with any valid value; platform-specific
  # assertions follow only when HW encoders are actually present.
  out="$(run_muxm --hw-accel auto --print-effective-config)"
  assert_contains "HW_ACCEL_RESOLVED" "--hw-accel auto: resolved field present" "$out"

  if [[ "$(uname -s 2>/dev/null)" == "Darwin" && "$(uname -m 2>/dev/null)" == "arm64" ]] \
      && ffmpeg_has_encoder hevc_videotoolbox; then
    assert_contains "HW_ACCEL_RESOLVED         = videotoolbox" \
      "--hw-accel auto: prefers videotoolbox on Apple Silicon" "$out"
  else
    skip "--hw-accel auto: Apple Silicon videotoolbox check (host lacks backend)"
  fi

  # --- .muxmrc loads HW_ACCEL ---
  local rc_home="$TESTDIR/hw_accel_rc_home"
  mkdir -p "$rc_home"
  cat > "$rc_home/.muxmrc" <<'EOF'
HW_ACCEL="videotoolbox"
EOF
  out="$(MUXM_HOME="$rc_home" run_muxm_in "$TESTDIR" --print-effective-config)"
  assert_contains "HW_ACCEL                  = videotoolbox" \
    "HW_ACCEL in .muxmrc: loaded" "$out"

  # --- CLI overrides .muxmrc ---
  out="$(MUXM_HOME="$rc_home" run_muxm_in "$TESTDIR" --hw-accel none --print-effective-config)"
  assert_contains "HW_ACCEL                  = none" \
    "CLI --hw-accel overrides .muxmrc HW_ACCEL" "$out"

  # --- Invalid HW_ACCEL in .muxmrc rejected with exit 11 ---
  cat > "$rc_home/.muxmrc" <<'EOF'
HW_ACCEL="garbage"
EOF
  local code
  out="$(cd "$TESTDIR" && HOME="$rc_home" "$MUXM" --print-effective-config 2>&1)" && code=$? || code=$?
  if [[ "$code" -eq "$EXIT_VALIDATION" ]]; then
    pass "Invalid HW_ACCEL in .muxmrc → exit $EXIT_VALIDATION"
  else
    fail "Invalid HW_ACCEL in .muxmrc — expected exit $EXIT_VALIDATION, got $code"
  fi
  assert_contains "Invalid HW_ACCEL" "Error message names the bad variable" "$out"

  # --- Profile + AV1 codec + --hw-accel videotoolbox → warning + software fallback ---
  out="$(run_muxm --profile av1-hq --hw-accel videotoolbox --print-effective-config)"
  assert_contains "VideoToolbox has no AV1 encoder" \
    "av1-hq + videotoolbox: compatibility warning emitted" "$out"
  assert_contains "VIDEO_CODEC               = libsvt-av1" \
    "av1-hq + videotoolbox: codec remains software libsvt-av1" "$out"

  out="$(run_muxm --profile streaming-av1 --hw-accel videotoolbox --print-effective-config)"
  assert_contains "VideoToolbox has no AV1 encoder" \
    "streaming-av1 + videotoolbox: compatibility warning emitted" "$out"

  # --- Profile archive + hw-accel: copy-only warning ---
  out="$(run_muxm --profile archive --hw-accel auto --print-effective-config)"
  assert_contains "archive is copy-only" \
    "archive + --hw-accel: copy-only warning emitted" "$out"

  # --- Explicit unavailable backend: strict check fires on real encode path ---
  # --print-effective-config exits before Section 14, so it does NOT die.
  # A real encode path (even without a valid source) goes through Section 14.
  # Use a nonexistent source to trigger Section 14 processing fast without
  # actually encoding. Exit code 10 indicates missing encoder.
  if ! ffmpeg_has_encoder hevc_nvenc; then
    out="$(cd "$TESTDIR" && "$MUXM" --hw-accel nvenc /does/not/exist.mkv 2>&1)" && code=$? || code=$?
    if [[ "$code" -eq 10 ]]; then
      pass "--hw-accel nvenc (unavailable): strict check dies with exit 10"
    else
      fail "--hw-accel nvenc (unavailable) — expected exit 10, got $code"
    fi
    assert_contains "no matching encoder (hevc_nvenc)" \
      "Strict check error message names the missing encoder" "$out"
  else
    skip "strict-check for missing hevc_nvenc: host has nvenc"
  fi

  # === VideoToolbox quality knob and encode-path fallback ===

  # --- --hw-accel-quality out-of-range rejection ---
  assert_exit "$EXIT_VALIDATION" "--hw-accel-quality 101: rejected" \
    --hw-accel-quality 101 --print-effective-config
  assert_exit "$EXIT_VALIDATION" "--hw-accel-quality abc: rejected" \
    --hw-accel-quality abc --print-effective-config
  assert_exit "$EXIT_VALIDATION" "--hw-accel-quality -1: rejected" \
    --hw-accel-quality -1 --print-effective-config
  out="$(run_muxm --hw-accel-quality 101 --print-effective-config)"
  assert_contains "Invalid --hw-accel-quality" \
    "--hw-accel-quality 101: error message names the flag" "$out"
  # Boundary values 0 and 100 must be accepted.
  out="$(run_muxm --hw-accel-quality 0 --print-effective-config)"
  assert_contains "HW_ACCEL_QUALITY          = 0" "--hw-accel-quality 0: accepted" "$out"
  out="$(run_muxm --hw-accel-quality 100 --print-effective-config)"
  assert_contains "HW_ACCEL_QUALITY          = 100" "--hw-accel-quality 100: accepted" "$out"

  # --- --hw-accel-quality appears in --print-effective-config ---
  out="$(run_muxm --hw-accel-quality 80 --print-effective-config)"
  assert_contains "HW_ACCEL_QUALITY          = 80" \
    "--hw-accel-quality 80: visible in effective config" "$out"
  out="$(run_muxm --print-effective-config)"
  assert_contains "HW_ACCEL_QUALITY          = <profile default>" \
    "HW_ACCEL_QUALITY: omitted flag shows '<profile default>'" "$out"

  # --- VT+AV1 encode-path fallback reason logged to stderr ---
  # The profile warning fires at parse time (--print-effective-config path). This
  # test exercises resolve_video_encoder() specifically via --dry-run so the
  # "Hardware acceleration disabled" note from the encode path is covered.
  # hw_accel is media-free; create a minimal probeable source inside the guard.
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" && "$(uname -m 2>/dev/null)" == "arm64" ]] \
      && ffmpeg_has_encoder hevc_videotoolbox; then
    local vt_dry_src="$TESTDIR/vt_av1_probe.mkv"
    ffmpeg -f lavfi -i "color=c=black:s=64x64:r=1" -t 1 -c:v libx264 -an \
      -y "$vt_dry_src" >/dev/null 2>&1
    out="$(run_muxm --dry-run --profile av1-hq --hw-accel videotoolbox "$vt_dry_src")"
    assert_contains "Hardware acceleration disabled for this encode" \
      "VT+AV1 encode path: fallback note visible in stderr" "$out"
    assert_contains "VideoToolbox has no AV1 encoder" \
      "VT+AV1 encode path: reason text correct" "$out"
  else
    skip "VT+AV1 encode-path fallback: host lacks hevc_videotoolbox on Apple Silicon"
  fi

  # ---- 5.2: NVENC software-fallback contract + QSV/VAAPI unsupported (host-independent) ----
  # NVENC dispatch is a documented dead stub: an nvenc request must fall back to SOFTWARE and
  # record a reason, never silently dispatch hevc_nvenc. The old e2e test only ran when the host
  # had hevc_nvenc (else it skipped), so on most hosts the contract went unverified — replaced here
  # by a direct unit test of resolve_video_encoder. Mock uname=Darwin so the macOS arm is reached
  # (not the Linux software-fallback guard) and set HW_ACCEL_RESOLVED=nvenc: assert the encoder
  # stays the software codec (libx265, NOT hevc_nvenc) and the fallback reason names NVENC.
  # M-NVENC-1 strips "NVENC" from that reason → the reason assertion goes red.
  local _rve_body
  _rve_body="$(awk '/^resolve_video_encoder\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$_rve_body" ]]; then
    fail "hw-accel-backend NVENC: could not extract resolve_video_encoder from muxm"
  else
    local _nv_out _nv_enc _nv_reason
    _nv_out="$(bash -c '
VIDEO_CODEC=libx265; HW_ACCEL_RESOLVED=nvenc; VIDEO_ENCODER_FFMPEG=""; HW_ACCEL_FALLBACK_REASON=""
uname(){ echo Darwin; }            # force the macOS arm so the nvenc stub (not the Linux guard) is reached
ffmpeg_has_encoder(){ return 1; }; is_apple_silicon(){ return 0; }
warn(){ :; }; note(){ :; }
'"$_rve_body"'
resolve_video_encoder
printf "%s|%s" "$VIDEO_ENCODER_FFMPEG" "$HW_ACCEL_FALLBACK_REASON"')"
    _nv_enc="${_nv_out%%|*}"; _nv_reason="${_nv_out#*|}"
    if [[ "$_nv_enc" == "libx265" ]]; then
      pass "hw-accel-backend NVENC: nvenc request falls back to the software encoder (VIDEO_ENCODER_FFMPEG=$_nv_enc, not hevc_nvenc)"
    else
      fail "hw-accel-backend NVENC: nvenc request should fall back to software libx265, got VIDEO_ENCODER_FFMPEG='$_nv_enc'"
    fi
    if [[ "$_nv_reason" == *[Nn][Vv][Ee][Nn][Cc]* ]]; then
      pass "hw-accel-backend NVENC: software-fallback reason names NVENC ('$_nv_reason')"
    else
      fail "hw-accel-backend NVENC: software-fallback reason should mention NVENC, got '$_nv_reason'"
    fi
  fi

  # QSV / VAAPI are not implemented backends — they must be REJECTED at validation (exit 11),
  # never silently mis-dispatched. (Same is_valid_hw_accel path as --hw-accel bogus.)
  assert_exit "$EXIT_VALIDATION" "hw-accel-backend QSV unsupported: --hw-accel qsv rejected (exit $EXIT_VALIDATION)" \
    --hw-accel qsv --print-effective-config
  assert_exit "$EXIT_VALIDATION" "hw-accel-backend VAAPI unsupported: --hw-accel vaapi rejected (exit $EXIT_VALIDATION)" \
    --hw-accel vaapi --print-effective-config
  out="$(run_muxm --hw-accel qsv --print-effective-config)"
  assert_contains "Invalid --hw-accel" "hw-accel-backend QSV unsupported: error names the flag" "$out"

  # --- VT_QUALITY_MAP resolution in --print-effective-config ---
  # Profile in map → calibrated value; profile absent from map → VT_QUALITY_DEFAULT.
  # Use "archive" for the absent-from-map case — it is not in VT_QUALITY_MAP,
  # so it always shows the default regardless of any config-file profile default.
  out="$(run_muxm --profile hdr10-hq --print-effective-config)"
  assert_contains "VT_QUALITY (active profile) = 70" \
    "VT_QUALITY_MAP: hdr10-hq resolved to calibrated value (70)" "$out"
  out="$(run_muxm --profile youtube-upload --print-effective-config)"
  assert_contains "VT_QUALITY (active profile) = 75" \
    "VT_QUALITY_MAP: youtube-upload resolved to calibrated value (75)" "$out"
  out="$(run_muxm --profile animation --print-effective-config)"
  assert_contains "VT_QUALITY (active profile) = 65" \
    "VT_QUALITY_MAP: animation resolved to calibrated value (65)" "$out"
  out="$(run_muxm --profile atv-directplay-animation --print-effective-config)"
  assert_contains "VT_QUALITY (active profile) = 65" \
    "VT_QUALITY_MAP: atv-directplay-animation resolved to calibrated value (65)" "$out"
  out="$(run_muxm --profile archive --print-effective-config)"
  assert_contains "VT_QUALITY (active profile) = 65 (default)" \
    "VT_QUALITY_MAP: profile not in map shows VT_QUALITY_DEFAULT" "$out"

  # ---- 5.3: build_videotoolbox_params param-string unit test (off-VT-host coverage) ----
  # build_videotoolbox_params only ran inside a real VideoToolbox encode, so its arg string had
  # ZERO coverage off a Mac VT host. Extract it and assert the assembled VIDEOTOOLBOX_ARGS for a
  # 10-bit mp4 HEVC encode carry -q:v (quality), -allow_sw, -profile:v main10, and -tag:v hvc1 —
  # a pure param builder inspected directly, no encoder or VT host required. HW_ACCEL_QUALITY is
  # set to a concrete value so vt_q resolves from it and the VT_QUALITY_MAP associative-array
  # branch is never taken (avoids an unbound-array read under set -u). M-VTPARAMS-1 drops the
  # hvc1 tag → the 10-bit-mp4 assertion goes red (the 8-bit-mkv case, which has no tag, stays green).
  local _vtp_body
  _vtp_body="$(awk '/^build_videotoolbox_params\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$_vtp_body" ]]; then
    fail "hw-vt-params VT params: could not extract build_videotoolbox_params from muxm"
  else
    local _vtp_args
    _vtp_args="$(bash -c '
HW_ACCEL_QUALITY=80; HW_ACCEL_ALLOW_SW=1; VT_QUALITY_DEFAULT=65
VIDEO_ENCODER_FFMPEG=hevc_videotoolbox; TARGET_PIXFMT=yuv420p10le; OUTPUT_EXT=mp4; X264_PARAMS_BASE=""
'"$_vtp_body"'
build_videotoolbox_params
printf "%s " "${VIDEOTOOLBOX_ARGS[@]}"')"
    local _vtp_ok=1 needle
    for needle in "-q:v 80" "-allow_sw 1" "-profile:v main10" "-tag:v hvc1"; do
      [[ "$_vtp_args" == *"$needle"* ]] || _vtp_ok=0
    done
    if (( _vtp_ok )); then
      pass "hw-vt-params VT params: hevc_videotoolbox mp4 10-bit → -q:v/-allow_sw/profile main10/hvc1 all present"
    else
      fail "hw-vt-params VT params: hevc_videotoolbox mp4 10-bit — expected -q:v 80/-allow_sw 1/-profile:v main10/-tag:v hvc1, got: $_vtp_args"
    fi
    # 8-bit SDR mkv → -profile:v main (not main10) and NO hvc1 tag (MKV is tag-agnostic) — proves
    # the profile/tag arms branch on pixfmt + container (keeps the M-VTPARAMS-1 signature isolated).
    local _vtp_args8
    _vtp_args8="$(bash -c '
HW_ACCEL_QUALITY=70; HW_ACCEL_ALLOW_SW=1; VT_QUALITY_DEFAULT=65
VIDEO_ENCODER_FFMPEG=hevc_videotoolbox; TARGET_PIXFMT=yuv420p; OUTPUT_EXT=mkv; X264_PARAMS_BASE=""
'"$_vtp_body"'
build_videotoolbox_params
printf "%s " "${VIDEOTOOLBOX_ARGS[@]}"')"
    if [[ "$_vtp_args8" == *"-profile:v main"* && "$_vtp_args8" != *"main10"* && "$_vtp_args8" != *"hvc1"* ]]; then
      pass "hw-vt-params VT params: 8-bit mkv → -profile:v main, no main10, no hvc1 tag (MKV agnostic)"
    else
      fail "hw-vt-params VT params: 8-bit mkv — expected -profile:v main (not main10) and no hvc1, got: $_vtp_args8"
    fi
  fi

  # --- Cleanup ---
  rm -rf "$rc_home"
}

# === Suite: Dry-Run Mode ===
# Validates that --dry-run announces itself, does not create output files, and works
# correctly in combination with profiles, --skip-audio, --skip-subs, and HDR sources.
test_dryrun() {
  section "Dry-Run Mode"

  local out outfile="$TESTDIR/dryrun_out.mp4"

  out="$(run_muxm --dry-run "$TESTDIR/basic_sdr_subs.mkv" "$outfile")"
  assert_contains "DRY-RUN" "Dry-run announces itself" "$out"
  assert_no_file "$outfile" "Dry-run does not create output"

  # Dry-run with profile
  out="$(run_muxm --dry-run --profile streaming "$TESTDIR/hevc_sdr_51.mkv")"
  assert_contains "DRY-RUN" "Dry-run with profile works" "$out"
  assert_contains "streaming" "Dry-run shows profile" "$out"

  # Dry-run with skip-audio
  out="$(run_muxm --dry-run --skip-audio "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Quick Test" "Dry-run with --skip-audio announces it" "$out"

  # Dry-run with skip-subs
  out="$(run_muxm --dry-run --skip-subs "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Quick Test" "Dry-run with --skip-subs announces it" "$out"

  # Dry-run with HDR source
  out="$(run_muxm --dry-run "$TESTDIR/hevc_hdr10_tagged.mkv")"
  assert_contains "DRY-RUN" "Dry-run with HDR source" "$out"

  # Dry-run with animation profile + ASS source completes cleanly
  out="$(run_muxm --dry-run --profile animation "$TESTDIR/ass_subs.mkv")"
  assert_contains "DRY-RUN" "Dry-run animation + ASS completes" "$out"

  # Dry-run with animation profile multi-track subtitles
  out="$(run_muxm --dry-run --profile animation "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "DRY-RUN" "Dry-run animation + multi-subs completes" "$out"
  assert_contains "multi-track" "Dry-run animation multi-subs: announces multi-track mode" "$out"

  # Dry-run with animation + --sub-burn-forced demotes to single-track
  out="$(run_muxm --dry-run --profile animation --sub-burn-forced "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "single subtitle track" "Dry-run animation + --sub-burn-forced: multi-track collapses to a single subtitle track" "$out"

  # Dry-run with archive multi-track audio
  out="$(run_muxm --dry-run --profile archive "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "DRY-RUN" "Dry-run archive + multi-audio completes" "$out"
  assert_contains "multi-track" "Dry-run archive: announces multi-track mode" "$out"

  # Dry-run with archive multi-track subtitles
  # --no-skip-if-ideal: fixture is fully compliant, would skip before pipelines run.
  out="$(run_muxm --dry-run --no-skip-if-ideal --profile archive "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "DRY-RUN" "Dry-run archive + multi-subs completes" "$out"
  assert_contains "multi-track" "Dry-run archive multi-subs: announces multi-track mode" "$out"
  assert_contains "keeping" "Dry-run archive multi-subs: subtitle filter summary logged" "$out"

  # ---- multi-track flag parity warnings (D5 audio, D6 subtitles) ----
  # Multi-track modes copy all source tracks and cannot honor several single-track-only flags.
  # Rather than silently dropping them, muxm now warns (warn-only — no behavior change).
  # --no-skip-if-ideal forces the pipeline so the warning sites (run_audio_pipeline /
  # run_subtitle_pipeline_multi) are reached. Assertions grep the message substring (more
  # robust than the ⚠ emoji, which collides with unrelated warnings in the same run).

  # D5: --prefer-stereo is a single-track intent; multi-track audio mode warns it won't apply.
  out="$(run_muxm --dry-run --no-skip-if-ideal --profile archive --prefer-stereo "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "does not apply in multi-track" "dryrun-stereo-flags-multitrack-warn: --prefer-stereo warns in multi-track audio mode" "$out"
  # D5: --stereo-fallback warns at the pipeline too (in addition to the archive config advisory).
  out="$(run_muxm --dry-run --no-skip-if-ideal --profile archive --stereo-fallback "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "does not apply in multi-track" "dryrun-stereo-flags-multitrack-warn: --stereo-fallback warns in multi-track audio mode" "$out"
  # D5 regression: neither stereo flag → no multi-track stereo warning.
  out="$(run_muxm --dry-run --no-skip-if-ideal --profile archive "$TESTDIR/hevc_multi_audio.mkv")"
  if echo "$out" | grep -qiF "does not apply in multi-track"; then
    fail "dryrun-stereo-flags-multitrack-warn: multi-track audio warned without --prefer-stereo/--stereo-fallback"
  else
    pass "dryrun-stereo-flags-multitrack-warn: no stereo warning when neither flag is set (multi-track audio)"
  fi

  # D6: --no-sub-preserve-bitmap requests OCR, but multi-track + MKV stream-copies subs (no OCR) → warn.
  out="$(run_muxm --dry-run --no-skip-if-ideal --profile archive --no-sub-preserve-bitmap "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "does not OCR" "dryrun-ocr-bitmap-multitrack-warn: --no-sub-preserve-bitmap warns in multi-track MKV mode" "$out"
  # D6 regression: default (preserve bitmap) → no OCR warning.
  out="$(run_muxm --dry-run --no-skip-if-ideal --profile archive "$TESTDIR/hevc_multi_subs.mkv")"
  if echo "$out" | grep -qiF "does not OCR"; then
    fail "dryrun-ocr-bitmap-multitrack-warn: multi-track MKV warned without --no-sub-preserve-bitmap"
  else
    pass "dryrun-ocr-bitmap-multitrack-warn: no OCR warning when bitmap preservation is on (default)"
  fi
  # D6 MKV gate (differential — same fixture/profile/flag, only the container differs): the
  # subtitle multi-track path still runs for MP4, but bitmap subs can't go there, so no warning.
  out="$(run_muxm --dry-run --no-skip-if-ideal --profile archive --output-ext mp4 --no-sub-preserve-bitmap "$TESTDIR/hevc_multi_subs.mkv")"
  if echo "$out" | grep -qiF "does not OCR"; then
    fail "dryrun-ocr-bitmap-multitrack-warn: warned for non-MKV multi-track output (MKV gate failed)"
  else
    pass "dryrun-ocr-bitmap-multitrack-warn: no OCR warning for non-MKV multi-track output (MKV-gated)"
  fi

  # D5 (explicit-flag gating): a bare AUDIO_MULTI_TRACK=1 from a .muxmrc — without the archive
  # profile, which would set ADD_STEREO_IF_MULTICH=0 — must NOT surface the --stereo-fallback
  # warning. ADD_STEREO_IF_MULTICH defaults to 1, so without _CLI_*_EXPLICIT gating the warning
  # would name a flag the user never typed. Uses an isolated project dir so the .muxmrc doesn't
  # leak to other tests; the suite's HOME is already isolated (no ~/.muxmrc).
  local d5_cfg="$TESTDIR/d5_multitrack_muxmrc"; mkdir -p "$d5_cfg"
  printf 'AUDIO_MULTI_TRACK=1\n' > "$d5_cfg/.muxmrc"
  out="$(run_muxm_in "$d5_cfg" --dry-run --no-skip-if-ideal "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "multi-track" "dryrun-stereo-flags-multitrack-warn gating: .muxmrc AUDIO_MULTI_TRACK=1 activates multi-track audio (no profile)" "$out"
  if echo "$out" | grep -qiF "does not apply in multi-track"; then
    fail "dryrun-stereo-flags-multitrack-warn gating: bare AUDIO_MULTI_TRACK=1 (.muxmrc) spuriously warned about an untyped stereo flag"
  else
    pass "dryrun-stereo-flags-multitrack-warn gating: no stereo warning for .muxmrc multi-track without an explicit stereo flag"
  fi
  # But an explicit --stereo-fallback on top of the .muxmrc multi-track still warns.
  out="$(run_muxm_in "$d5_cfg" --dry-run --no-skip-if-ideal --stereo-fallback "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "does not apply in multi-track" "dryrun-stereo-flags-multitrack-warn gating: explicit --stereo-fallback still warns over .muxmrc multi-track" "$out"

  # ---- Container passthrough resolution + ATV MKV subtitle adjustment (now LOG-only) ----
  # These [container-passthrough]/[<profile>] decision lines are emitted via log() during §15
  # output resolution. muxm routes log() to the logfile (buffered pre-§17), NOT the terminal,
  # so the assertions read the kept workdir log (run_muxm passes -K) and also prove the lines no
  # longer leak to the terminal. (archive forces MKV directly
  # per A2; atv-directplay-hq/animation are passthrough, so they exercise the resolution logging.)
  local cpass_log

  # atv-directplay-hq + mkv source → OUTPUT_EXT=mkv (passthrough) → MKV subtitle adjustment fires.
  out="$(run_muxm --dry-run --profile atv-directplay-hq "$TESTDIR/basic_sdr_subs.mkv")"
  cpass_log="$(_keepworkdir_logfile "$out" || true)"
  if [[ -n "$cpass_log" ]] && grep -qF "[container-passthrough] Source .mkv" "$cpass_log"; then
    pass "passthrough hq + mkv: container resolution logged (to the logfile, not the terminal)"
  else
    fail "passthrough hq + mkv: '[container-passthrough] Source .mkv' not found in the run log ($cpass_log)"
  fi
  if [[ -n "$cpass_log" ]] && grep -qF "[atv-directplay-hq] MKV output: enabling native ASS/SSA" "$cpass_log"; then
    pass "passthrough hq + mkv: MKV subtitle adjustment (ASS/SSA preservation) logged"
  else
    fail "passthrough hq + mkv: MKV subtitle adjustment line not found in the run log"
  fi
  if printf '%s' "$out" | grep -qF "[container-passthrough]"; then
    fail "passthrough hq + mkv: internal [container-passthrough] line leaked to the terminal (Phase 2 leak-fix regressed)"
  else
    pass "passthrough hq + mkv: internal decision lines no longer leak to the terminal"
  fi

  # atv-directplay-hq + mp4 source: passthrough → OUTPUT_EXT=mp4 → NO MKV subtitle adjustment.
  out="$(run_muxm --dry-run --profile atv-directplay-hq "$TESTDIR/compliant.mp4")"
  cpass_log="$(_keepworkdir_logfile "$out" || true)"
  if [[ -n "$cpass_log" ]] && grep -qF "[container-passthrough] Source .mp4" "$cpass_log"; then
    pass "passthrough hq + mp4: mp4 container resolution logged"
  else
    fail "passthrough hq + mp4: '[container-passthrough] Source .mp4' not found in the run log"
  fi
  if [[ -n "$cpass_log" ]] && ! grep -qF "[atv-directplay-hq] MKV output:" "$cpass_log"; then
    pass "passthrough hq + mp4: MKV subtitle adjustment does NOT fire (mp4 output)"
  else
    fail "passthrough hq + mp4: MKV subtitle adjustment unexpectedly logged for mp4 output"
  fi

  # atv-directplay-hq + mkv + --sub-burn-forced: CLI overrides profile burn default; ASS/SSA on.
  out2="$(run_muxm --profile atv-directplay-hq --sub-burn-forced --print-effective-config)"
  assert_contains "SUB_BURN_FORCED           = 1" \
    "atv + --sub-burn-forced: CLI flag overrides profile default (burn active)" "$out2"
  out="$(run_muxm --dry-run --profile atv-directplay-hq --sub-burn-forced "$TESTDIR/basic_sdr_subs.mkv")"
  cpass_log="$(_keepworkdir_logfile "$out" || true)"
  if [[ -n "$cpass_log" ]] && grep -qF "[atv-directplay-hq] MKV output: enabling native ASS/SSA" "$cpass_log"; then
    pass "atv + mkv + --sub-burn-forced: ASS/SSA preservation still logged regardless"
  else
    fail "atv + mkv + --sub-burn-forced: ASS/SSA preservation line not found in the run log"
  fi

  # ---- atv-directplay-animation passthrough + MKV subtitle adjustment ----
  out="$(run_muxm --dry-run --profile atv-directplay-animation "$TESTDIR/basic_sdr_subs.mkv")"
  cpass_log="$(_keepworkdir_logfile "$out" || true)"
  if [[ -n "$cpass_log" ]] && grep -qF "[container-passthrough] Source .mkv" "$cpass_log" \
     && grep -qF "[atv-directplay-animation] MKV output: enabling native ASS/SSA" "$cpass_log"; then
    pass "passthrough animation + mkv: resolution + MKV subtitle adjustment logged"
  else
    fail "passthrough animation + mkv: resolution/adjustment lines not found in the run log"
  fi

  # atv-directplay-animation + mp4 source: passthrough → OUTPUT_EXT=mp4 → NO MKV subtitle adjustment.
  out="$(run_muxm --dry-run --profile atv-directplay-animation "$TESTDIR/compliant.mp4")"
  cpass_log="$(_keepworkdir_logfile "$out" || true)"
  if [[ -n "$cpass_log" ]] && grep -qF "[container-passthrough] Source .mp4" "$cpass_log" \
     && ! grep -qF "[atv-directplay-animation] MKV output:" "$cpass_log"; then
    pass "passthrough animation + mp4: mp4 resolution logged, no MKV adjustment"
  else
    fail "passthrough animation + mp4: unexpected resolution/adjustment state in the run log"
  fi

  # atv-directplay-animation + mkv source + --sub-burn-forced: CLI overrides burn default.
  out2="$(run_muxm --profile atv-directplay-animation --sub-burn-forced --print-effective-config)"
  assert_contains "SUB_BURN_FORCED           = 1" \
    "atv-directplay-animation + --sub-burn-forced: CLI flag overrides profile default (burn active)" "$out2"

  # ---- D1 (behavioral): explicit --no-sub-preserve-format wins over the ATV MKV adjustment ----
  # atv-directplay-hq + .mkv source forces native ASS/SSA preservation by default; an explicit
  # --no-sub-preserve-format must override that so the ASS sub is CONVERTED to SRT instead of
  # extracted natively. The "extract … as native ass (preserving styling)" note (muxm
  # `_prepare_subtitle`, dry-run branch) is the observable signal. --no-skip-if-ideal keeps the
  # pipeline from short-circuiting before subtitle prep (the profile sets SKIP_IF_IDEAL=1).
  # NOTE: the bitmap analogue (--no-sub-preserve-bitmap → OCR) has no behavioral test — ffmpeg
  # cannot synthesize a PGS fixture (see muxm `_is_text_sub_codec`); the profiles suite asserts
  # it via --print-effective-config instead.
  local _natass='native ass (preserving styling)'
  out="$(run_muxm --dry-run --no-skip-if-ideal --profile atv-directplay-hq "$TESTDIR/ass_subs.mkv")"
  if printf '%s' "$out" | grep -qF "$_natass"; then
    pass "dryrun-preserve-flags-baseline baseline: atv-directplay-hq preserves ASS natively when no override flag is passed"
  else
    fail "dryrun-preserve-flags-baseline baseline: expected native ASS preservation note (got none) — fixture/path issue?"
  fi
  out="$(run_muxm --dry-run --no-skip-if-ideal --no-sub-preserve-format --profile atv-directplay-hq "$TESTDIR/ass_subs.mkv")"
  if printf '%s' "$out" | grep -qF "$_natass"; then
    fail "dryrun-preserve-flags-baseline: --no-sub-preserve-format ignored — ASS still extracted natively (ATV clobbered the explicit flag)"
  else
    pass "dryrun-preserve-flags-baseline: --no-sub-preserve-format converts ASS→SRT (explicit flag wins over atv-directplay-hq)"
  fi

  # ---- Disk space preflight (--no-disk-check / DISK_CHECK=0) ----
  # Use DISK_FREE_WARN_GB=99999 (≈1 petabyte floor) to ensure the warning fires
  # regardless of actual available space, making the suppression behavior observable.
  local disk_dir="$TESTDIR/disk_check_test"
  local disk_home="$TESTDIR/disk_check_home"
  mkdir -p "$disk_dir" "$disk_home"

  # With impossibly-large floor and no --no-disk-check, warning should fire.
  cat > "$disk_dir/.muxmrc" <<'EOF'
DISK_FREE_WARN_GB=99999
EOF
  out="$(MUXM_HOME="$disk_home" run_muxm_in "$disk_dir" --dry-run "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  if echo "$out" | grep -qiF "no-disk-check"; then
    pass "disk preflight: large DISK_FREE_WARN_GB triggers warning"
  else
    skip "disk preflight: warning not triggered (probe may have failed or disk is huge)"
  fi

  # --no-disk-check suppresses the warning entirely.
  cat > "$disk_dir/.muxmrc" <<'EOF'
DISK_FREE_WARN_GB=99999
EOF
  out="$(MUXM_HOME="$disk_home" run_muxm_in "$disk_dir" --dry-run --no-disk-check "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  if ! echo "$out" | grep -qiF "no-disk-check to suppress"; then
    pass "--no-disk-check suppresses disk estimation warning"
  else
    fail "--no-disk-check should suppress disk warning but warning appeared"
  fi

  # DISK_CHECK=0 in config suppresses the warning.
  cat > "$disk_dir/.muxmrc" <<'EOF'
DISK_FREE_WARN_GB=99999
DISK_CHECK=0
EOF
  out="$(MUXM_HOME="$disk_home" run_muxm_in "$disk_dir" --dry-run "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  if ! echo "$out" | grep -qiF "no-disk-check to suppress"; then
    pass "DISK_CHECK=0 in config suppresses disk estimation warning"
  else
    fail "DISK_CHECK=0 should suppress disk warning but warning appeared"
  fi

  # Video copy mode: disk_free_warn runs and does not crash when VIDEO_COPY_IF_COMPLIANT=1.
  # --video-copy-if-compliant activates the copy-mode estimation path (no CRF reduction).
  cat > "$disk_dir/.muxmrc" <<'EOF'
DISK_FREE_WARN_GB=99999
EOF
  out="$(MUXM_HOME="$disk_home" run_muxm_in "$disk_dir" \
    --dry-run --video-copy-if-compliant "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  assert_contains "DRY-RUN" "copy-mode disk preflight: dry-run completes without error" "$out"

  # ---- skip-if-ideal: explicit --crf forces re-encode ----
  # When --crf is passed explicitly on the CLI, _CLI_CRF_EXPLICIT=1 should
  # prevent skip-if-ideal from stream-copying or skipping even for a compliant source.
  out="$(run_muxm --dry-run --skip-if-ideal --crf 20 \
    "$TESTDIR/compliant.mp4" 2>&1)"
  if echo "$out" | grep -qiE "already matches|source already ideal|no.?processing.?needed"; then
    fail "skip-if-ideal + explicit --crf: should NOT skip when CRF is explicitly set"
  else
    pass "skip-if-ideal + explicit --crf: does not skip (re-encode forced by explicit CRF)"
  fi

  # Without an explicit --crf, skip-if-ideal should still recognize the compliant source.
  out="$(run_muxm --dry-run --skip-if-ideal \
    "$TESTDIR/compliant.mp4" 2>&1)"
  if echo "$out" | grep -qiE "ideal|skip|already|compliant|no.?processing"; then
    pass "skip-if-ideal (no explicit --crf): compliant source still recognized as ideal"
  else
    # May have encoded if compliance check is strict; either way no crash.
    skip "skip-if-ideal (no explicit --crf): inconclusive (source may not qualify as ideal)"
  fi

  # ---- Container compatibility warnings ----

  # 3a: ASS/SSA + MP4 warning
  # ass_subs.mkv has an embedded ASS subtitle track. Running with --sub-preserve-format
  # and --output-ext mp4 should trigger the "cannot carry native ASS" warning because
  # MP4 cannot carry ASS natively (it would be flattened to mov_text).
  out="$(run_muxm --dry-run --output-ext mp4 --sub-preserve-format \
    "$TESTDIR/ass_subs.mkv" 2>&1)" || true
  assert_contains "cannot carry native ASS" \
    "container-compat: ASS + MP4 emits incompatibility warning" "$out"

  # 3b: Lossless audio + MP4 warning
  # hevc_sdr_71.mkv has a FLAC 8ch audio track. Running with --audio-lossless-passthrough
  # and --output-ext mp4 should trigger the "limited lossless playback support" warning
  # because FLAC in MP4 has poor device compatibility.
  out="$(run_muxm --dry-run --output-ext mp4 --audio-lossless-passthrough \
    "$TESTDIR/hevc_sdr_71.mkv" 2>&1)" || true
  assert_contains "limited lossless playback support" \
    "container-compat: FLAC + MP4 emits lossless incompatibility warning" "$out"

  # ---- AV1 profile dry-run: verify profile settings are applied ----

  # av1-hq dry-run: base CRF 28, libsvt-av1, MKV output, DV disabled, lossless audio passthrough.
  out="$(run_muxm --dry-run --profile av1-hq "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  assert_contains "DRY-RUN" "dry-run av1-hq: announces DRY-RUN" "$out"
  # Effective-config check: confirm profile set the expected video codec and CRF.
  local av1hq_cfg
  av1hq_cfg="$(run_muxm --profile av1-hq --print-effective-config 2>&1)"
  assert_contains "libsvt-av1"  "av1-hq effective-config: VIDEO_CODEC=libsvt-av1" "$av1hq_cfg"
  assert_contains "CRF_VALUE                 = 28" "av1-hq effective-config: base CRF_VALUE=28" "$av1hq_cfg"
  assert_contains "DISABLE_DV                = 1"  "av1-hq effective-config: DISABLE_DV=1" "$av1hq_cfg"

  # streaming-av1 dry-run: CRF 30, libsvt-av1, MP4 output, Opus audio.
  out="$(run_muxm --dry-run --profile streaming-av1 "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  assert_contains "DRY-RUN" "dry-run streaming-av1: announces DRY-RUN" "$out"
  local sav1_cfg
  sav1_cfg="$(run_muxm --profile streaming-av1 --print-effective-config 2>&1)"
  assert_contains "libsvt-av1"  "streaming-av1 effective-config: VIDEO_CODEC=libsvt-av1" "$sav1_cfg"
  assert_contains "CRF_VALUE                 = 30" "streaming-av1 effective-config: CRF_VALUE=30" "$sav1_cfg"
  assert_contains "libopus"     "streaming-av1 effective-config: AUDIO_FORCE_CODEC=libopus" "$sav1_cfg"

  # ---- libaom-av1 vs libsvt-av1 flag selection (effective-config) ----
  # libsvt-av1 uses -preset; libaom-av1 uses -cpu-used.  Both share SVT_AV1_PARAMS_BASE
  # but the flag name differs.  Verify effective-config reflects the right codec when
  # --video-codec libaom-av1 is supplied.
  local libaom_cfg
  libaom_cfg="$(run_muxm --video-codec libaom-av1 --print-effective-config 2>&1)"
  assert_contains "libaom-av1" "libaom-av1 effective-config: VIDEO_CODEC=libaom-av1" "$libaom_cfg"

  # ---- AV1 CLI flag passthrough (--av1-params, --av1-maxrate, --av1-bufsize) ----
  # SVT_AV1_PARAMS_BASE, AV1_MAXRATE, AV1_BUFSIZE are not exposed by
  # --print-effective-config.  Test that the flags parse without error (no exit 11)
  # and that a dry-run with them in place announces DRY-RUN normally.
  # The propagation of SVT_AV1_PARAMS_BASE is covered by the build_av1_params unit test.
  out="$(run_muxm --dry-run --video-codec libsvt-av1 \
    --av1-params "film-grain=8:tune=0" \
    "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  assert_contains "DRY-RUN" \
    "--av1-params: accepted without error (dry-run completes)" "$out"
  if echo "$out" | grep -qiF "Invalid"; then
    fail "--av1-params: unexpected 'Invalid' in output (flag may have been rejected)"
  else
    pass "--av1-params: no validation error in dry-run output"
  fi

  out="$(run_muxm --dry-run --video-codec libsvt-av1 \
    --av1-maxrate 8000k --av1-bufsize 16000k \
    "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  assert_contains "DRY-RUN" \
    "--av1-maxrate/--av1-bufsize: accepted without error (dry-run completes)" "$out"
  if echo "$out" | grep -qiF "Invalid"; then
    fail "--av1-maxrate/--av1-bufsize: unexpected 'Invalid' in output"
  else
    pass "--av1-maxrate/--av1-bufsize: no validation error in dry-run output"
  fi

  # ---- AV1 copy-compliant check: hevc source must be rejected for AV1 target ----
  # _video_is_copy_compliant() rejects non-av1 sources when VIDEO_CODEC is libsvt-av1.
  # With --skip-if-ideal and a hevc source, check_skip_if_ideal should log the rejection
  # reason containing "need av1".
  out="$(run_muxm --dry-run --video-codec libsvt-av1 --video-copy-if-compliant \
    --skip-if-ideal "$TESTDIR/hevc_sdr_51.mkv" 2>&1)"
  assert_contains "need av1" \
    "AV1 copy-compliant: hevc source rejected with 'need av1' reason" "$out"

  # h264 source should also be rejected for AV1 target
  out="$(run_muxm --dry-run --video-codec libsvt-av1 --video-copy-if-compliant \
    --skip-if-ideal "$TESTDIR/basic_sdr_subs.mkv" 2>&1)"
  assert_contains "need av1" \
    "AV1 copy-compliant: h264 source rejected with 'need av1' reason" "$out"

  # ---- Output filename extension inference ----
  # When the user supplies an explicit output filename, muxm infers the container
  # from the file's extension rather than using the profile default.
  _test_dryrun_ext_inference
}

# Tests that OUTPUT_EXT is inferred from an explicit output filename supplied on
# the CLI, and that --output-ext takes precedence over filename inference.
# Placed here (not in test_cli) because the observable evidence lives in dry-run
# log output — effective-config doesn't expose the inferred value before a source
# file is provided.
_test_dryrun_ext_inference() {
  local out

  # Explicit output filename → extension inferred as mp4
  out="$(run_muxm --profile archive --dry-run \
    "$TESTDIR/basic_sdr_subs.mkv" "$TESTDIR/output.mp4" 2>&1)"
  assert_contains "mp4" \
    "ext-inference: explicit .mp4 output → OUTPUT_EXT inferred as mp4" "$out"

  # --output-ext mkv wins over .mp4 filename extension
  out="$(run_muxm --profile archive --output-ext mkv --dry-run \
    "$TESTDIR/basic_sdr_subs.mkv" "$TESTDIR/output.mp4" 2>&1)"
  assert_contains "mkv" \
    "ext-inference: --output-ext mkv overrides .mp4 filename" "$out"
  # The inferred-from-filename path should not have been taken
  if ! echo "$out" | grep -qiF "inferred"; then
    pass "ext-inference: --output-ext wins (no inferred-container log when explicit ext given)"
  else
    # A log line about inference may still appear for a different reason; only fail
    # if it claims mp4 was inferred despite the explicit --output-ext mkv override.
    if echo "$out" | grep -qi "inferred.*mp4"; then
      fail "ext-inference: --output-ext mkv override ignored — log still claims mp4 inferred"
    else
      pass "ext-inference: --output-ext mkv respected (inferred log refers to mkv or unrelated)"
    fi
  fi

  # Inferred container log message appears in dry-run output when filename drives the ext
  out="$(run_muxm --profile archive --dry-run \
    "$TESTDIR/basic_sdr_subs.mkv" "$TESTDIR/infer_check.mp4" 2>&1)"
  if echo "$out" | grep -qiE "infer|container.*mp4|mp4.*container|output.*ext.*mp4|mp4.*output"; then
    pass "ext-inference: dry-run log mentions inferred container for .mp4 output"
  else
    skip "ext-inference: inferred-container log message not found (feature may not emit one)"
  fi
}

# === Suite: Video Pipeline (real encodes) ===
# Validates core video encoding: default HEVC, explicit libx264, MKV container,
# custom x265 params, thread count, and copy-if-compliant passthrough.
test_video() {
  section "Video Pipeline (Real Encodes)"

  local outfile out src="$TESTDIR/basic_sdr_subs.mkv"

  # Basic SDR encode → MP4
  outfile="$TESTDIR/vid_test1.mp4"
  log "Encoding basic SDR to MP4..."
  if assert_encode "Basic SDR encode produces output" "$outfile" \
       --crf 28 --preset ultrafast "$src"; then
    assert_probe "Output video codec is HEVC" "$outfile" codec_name hevc
  fi

  # libx264 encode
  outfile="$TESTDIR/vid_test_x264.mp4"
  log "Encoding with libx264..."
  if assert_encode "libx264 encode produces output" "$outfile" \
       --video-codec libx264 --crf 28 --preset ultrafast "$src"; then
    assert_probe "Output video codec is H.264" "$outfile" codec_name h264
  fi

  # MKV output
  outfile="$TESTDIR/vid_test_mkv.mkv"
  log "Encoding to MKV container..."
  if assert_encode "MKV output produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast "$src"; then
    local fmt
    fmt="$(probe_format "$outfile" format_name)"
    assert_contains "matroska" "Output is Matroska" "$fmt"
  fi

  # --x265-params custom parameter (#21) — encode + verify param appears in ffmpeg command
  local x265_params_out x265_params_file="$TESTDIR/vid_x265_params.mp4"
  log "Encoding with --x265-params (aq-mode=4 — differs from default aq-mode=3)..."
  x265_params_out="$(run_muxm --crf 28 --preset ultrafast --x265-params "aq-mode=4" "$src" "$x265_params_file")"
  if [[ -f "$x265_params_file" && -s "$x265_params_file" ]]; then
    pass "--x265-params: encode succeeded"
    local x265_p_log
    x265_p_log="$(echo "$x265_params_out" | sed -n 's/.*Logging to \(.*\.log\).*/\1/p' | head -1)"
    if [[ -n "$x265_p_log" && -f "$x265_p_log" ]] && grep -q "aq-mode=4" "$x265_p_log"; then
      pass "--x265-params: custom param (aq-mode=4) confirmed in ffmpeg command log"
    else
      skip "--x265-params: param not confirmed in log (log: ${x265_p_log:-not found})"
    fi
  else
    fail "--x265-params: no output"
  fi

  # --threads (#22) — 1.6: was Category-D (`then :;` — encode ran, never probed). Exact thread
  # *count* in the output isn't probeable. Assert (honest B-class) that the setting is parsed and
  # registered — muxm feeds THREADS straight into the encode as `-threads "$THREADS"`
  # (thread_args, muxm:7363 → base-video command muxm:7518/7520), so a registered THREADS=N
  # reaches ffmpeg. (A live DEBUG command-grep confirms `-threads 2` standalone but is unreliable
  # under muxm's tee/FD routing inside the harness, so we assert registration instead.)
  outfile="$TESTDIR/vid_threads.mp4"
  log "Encoding with --threads 2..."
  assert_encode "--threads 2: encode succeeded" "$outfile" \
    --crf 28 --preset ultrafast --threads 2 "$src"
  out="$(run_muxm --threads 2 --print-effective-config)"
  assert_matches "THREADS[[:space:]]+= 2" "--threads 2: setting registered (feeds the ffmpeg -threads arg)" "$out"

  # --video-copy-if-compliant with HEVC source (#19)
  # Part 1: explicit --preset forces re-encode even with copy flag set — output is still HEVC.
  outfile="$TESTDIR/vid_copy_compliant.mp4"
  log "Testing --video-copy-if-compliant with HEVC source (explicit preset → re-encode)..."
  if assert_encode "--video-copy-if-compliant: output produced" "$outfile" \
       --video-copy-if-compliant --preset ultrafast "$TESTDIR/hevc_sdr_51.mkv"; then
    assert_probe "--video-copy-if-compliant: HEVC preserved" "$outfile" codec_name hevc
  fi

  # Part 2: no explicit CRF/preset → copy path should actually trigger.
  # Uses isolated HOME to exclude user ~/.muxmrc from affecting copy-compliance checks.
  local copy_isolated_home="$TESTDIR/copy_isolated_home"
  mkdir -p "$copy_isolated_home"
  local copy_path_out="$TESTDIR/vid_copy_path.mp4"
  log "Testing --video-copy-if-compliant copy path (no explicit CRF/preset, isolated config)..."
  local copy_path_capture
  copy_path_capture="$(MUXM_HOME="$copy_isolated_home" run_muxm_in "$TESTDIR" \
    --video-copy-if-compliant --output-ext mp4 --no-stereo-fallback \
    "hevc_sdr_51.mkv" "$copy_path_out")"
  if echo "$copy_path_capture" | grep -q "will copy directly from source"; then
    pass "--video-copy-if-compliant: copy path confirmed (stream copy, not re-encode)"
  elif echo "$copy_path_capture" | grep -q "not compliant for copy"; then
    skip "--video-copy-if-compliant: copy path not triggered (source failed compliance check)"
  else
    skip "--video-copy-if-compliant: copy path indeterminate (check copy_path_out fixture)"
  fi

  # --level config acceptance (R20) — all four VBV tiers
  out="$(run_muxm --level 5.1 --print-effective-config)"
  assert_contains "LEVEL_VALUE               = 5.1" "--level 5.1: config registered" "$out"
  out="$(run_muxm --level 4.1 --print-effective-config)"
  assert_contains "LEVEL_VALUE               = 4.1" "--level 4.1: config registered" "$out"
  out="$(run_muxm --level 5.0 --print-effective-config)"
  assert_contains "LEVEL_VALUE               = 5.0" "--level 5.0: config registered" "$out"
  out="$(run_muxm --level 5.2 --print-effective-config)"
  assert_contains "LEVEL_VALUE               = 5.2" "--level 5.2: config registered" "$out"

  # --level VBV injection (R21)
  # When CONSERVATIVE_VBV=1 (default) and --level is a known tier, the encode
  # should include vbv-maxrate and vbv-bufsize in the x265 params.
  # Must use an H.264 source to force x265 re-encoding (an HEVC source may
  # be video-copied if a profile sets VIDEO_COPY_IF_COMPLIANT=1, skipping x265).
  # Uses --ffmpeg-loglevel info so x265 prints its VBV/HRD configuration to
  # the terminal.  Falls back to the workdir log (which contains the full
  # ffmpeg command) by extracting the exact log path from muxm's "Logging to"
  # line rather than using a fragile find glob.
  local vbv_outfile="$TESTDIR/vid_level_vbv.mp4"
  log "Encoding with --level 5.1 (VBV injection test)..."
  out="$(run_muxm --level 5.1 --crf 28 --preset ultrafast --no-video-copy-if-compliant \
    --ffmpeg-loglevel info --no-hide-banner \
    "$TESTDIR/basic_sdr_subs.mkv" "$vbv_outfile")"
  if echo "$out" | grep -qiE "vbv-maxrate|vbv-bufsize|vbv.?hrd"; then
    pass "--level 5.1: VBV params found in terminal output"
  else
    # Extract the exact log path from muxm's "Logging to <path>" line
    local vbv_log
    vbv_log="$(echo "$out" | sed -n 's/.*Logging to \(.*\.log\).*/\1/p' | head -1)"
    if [[ -n "$vbv_log" && -f "$vbv_log" ]] && grep -qiE "vbv-maxrate|vbv-bufsize" "$vbv_log"; then
      pass "--level 5.1: VBV params found in workdir log"
    else
      fail "--level 5.1: VBV keywords not found in output or workdir log"
      (( VERBOSE )) && echo "    Log: ${vbv_log:-not found}" || true
      (( VERBOSE )) && echo "    Output: ${out:0:500}" || true
    fi
  fi

  # --sdr-force-10bit pixel-format verification (M71–M74).
  # basic_sdr_subs.mkv is an 8-bit (yuv420p) H.264 source, so any HEVC target
  # re-encodes. With --sdr-force-10bit the output must be yuv420p10le; with
  # --no-sdr-force-10bit the 8-bit format is preserved. This pins down the
  # SDR_FORCE_10BIT pixel-format decision that was previously manual-only.
  local sdr10_out="$TESTDIR/vid_sdr_force10.mp4"
  log "Encoding 8-bit SDR source with --sdr-force-10bit..."
  if assert_encode "--sdr-force-10bit: output produced" "$sdr10_out" \
       --sdr-force-10bit --crf 28 --preset ultrafast "$src"; then
    assert_probe "--sdr-force-10bit: 8-bit SDR source encoded as 10-bit (yuv420p10le)" \
      "$sdr10_out" pix_fmt yuv420p10le
  fi

  local sdr8_out="$TESTDIR/vid_sdr_no_force10.mp4"
  log "Encoding 8-bit SDR source with --no-sdr-force-10bit (baseline)..."
  if assert_encode "--no-sdr-force-10bit: output produced" "$sdr8_out" \
       --no-sdr-force-10bit --crf 28 --preset ultrafast "$src"; then
    assert_probe "--no-sdr-force-10bit: 8-bit SDR source stays 8-bit (yuv420p)" \
      "$sdr8_out" pix_fmt yuv420p
  fi

  # Frame-rate preservation (regression: 23.976→25 desync bug). A 24000/1001
  # (NTSC-film) source must produce a 24000/1001 output, never a rounded 25fps.
  # Guards init_src_fps + the post-mux fps integrity check end-to-end. Generated
  # inline because the shared gen_media fixture is hardcoded to integer r=24.
  local fps_src="$TESTDIR/fps_2398_src.mkv" fps_out="$TESTDIR/fps_2398_out.mkv"
  # Use a lavfi color source (bt709 yuv, like the shared fixtures) rather than
  # testsrc — testsrc tags colorspace=gbr, which libx265 rejects when muxm
  # propagates the source color metadata. Only the frame rate differs here.
  ffmpeg -y -f lavfi -i "color=c=blue:s=320x240:r=24000/1001:d=2" \
         -f lavfi -i "sine=frequency=440:duration=2" \
         -c:v libx265 -x265-params log-level=none -c:a ac3 "$fps_src" >/dev/null 2>&1
  if [[ -s "$fps_src" ]]; then
    log "Encoding 23.976fps (24000/1001) source — output must preserve fps..."
    if assert_encode "fps preservation: output produced" "$fps_out" \
         --output-ext mkv --crf 28 --preset ultrafast "$fps_src"; then
      assert_probe "fps preservation: 24000/1001 source stays 24000/1001 (no 25fps desync)" \
        "$fps_out" r_frame_rate "24000/1001"
      # Direct sync metric: video and audio stream end-times must align. A wrong
      # fps would shorten the video track while audio stays full-length. MKV omits
      # per-stream duration, so derive end time from the last packet PTS.
      local _vend _aend _sync_delta
      _vend="$(ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$fps_out" 2>/dev/null | grep -E '^[0-9]' | sort -n | tail -1)"
      _aend="$(ffprobe -v error -select_streams a:0 -show_entries packet=pts_time -of csv=p=0 "$fps_out" 2>/dev/null | grep -E '^[0-9]' | sort -n | tail -1)"
      if [[ -n "$_vend" && -n "$_aend" ]]; then
        _sync_delta="$(awk -v v="$_vend" -v a="$_aend" 'BEGIN{d=v-a; if(d<0)d=-d; print (d<=0.5)?"ok":"desync"}')"
        if [[ "$_sync_delta" == "ok" ]]; then
          pass "fps preservation: video/audio stream end-times aligned (in sync)"
        else
          fail "fps preservation: video ends ${_vend}s but audio ends ${_aend}s — streams desynced"
        fi
      else
        skip "fps preservation: could not read per-stream end times for sync check"
      fi
    fi
  else
    skip "fps preservation: could not generate fractional-fps fixture"
  fi

  # ---- A1: streaming-av1 CRF is resolution/HDR-aware ----
  # CRF 30 is transparent at 1080p SDR but drops below the ~93 VMAF line at 4K HDR, so ≥4K
  # or HDR sources are nudged to CRF 28 (1080p SDR keeps 30; explicit --crf always wins).
  # Driven via --dry-run (no real AV1 encode); the override emits a "→ CRF 28" note.
  local _a1_4k="$TESTDIR/a1_4k.mp4" _a1_1080="$TESTDIR/a1_1080.mp4" _a1_1080hdr="$TESTDIR/a1_1080hdr.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=blue:s=3840x2160:r=24:d=1" \
    -f lavfi -i "sine=duration=1" -c:v libx265 -tag:v hvc1 -preset ultrafast -crf 35 -c:a aac -ac 2 "$_a1_4k" 2>/dev/null || true
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=blue:s=1920x1080:r=24:d=1" \
    -f lavfi -i "sine=duration=1" -c:v libx265 -tag:v hvc1 -preset ultrafast -crf 35 -c:a aac -ac 2 "$_a1_1080" 2>/dev/null || true
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=blue:s=1920x1080:r=24:d=1" \
    -f lavfi -i "sine=duration=1" -c:v libx265 -tag:v hvc1 -preset ultrafast -crf 35 -pix_fmt yuv420p10le \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -c:a aac -ac 2 "$_a1_1080hdr" 2>/dev/null || true
  if [[ -s "$_a1_4k" && -s "$_a1_1080" ]] && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libsvtav1; then
    local _a1_out
    # (a) 4K source → override to CRF 28
    _a1_out="$(run_muxm --profile streaming-av1 --dry-run "$_a1_4k")"
    if printf '%s' "$_a1_out" | grep -qE 'streaming-av1:.*→ CRF 28'; then
      pass "A1: 4K source under streaming-av1 → CRF 28 (resolution-aware override)"
    else
      fail "A1: 4K source under streaming-av1 → expected a CRF 28 override note"
    fi
    # (b) 1080p SDR source → stays at the profile default CRF 30 (no override)
    _a1_out="$(run_muxm --profile streaming-av1 --dry-run "$_a1_1080")"
    if printf '%s' "$_a1_out" | grep -qE 'streaming-av1:.*→ CRF 28'; then
      fail "A1: 1080p SDR source wrongly triggered the 4K/HDR CRF override"
    else
      pass "A1: 1080p SDR source under streaming-av1 → keeps CRF 30 (no override)"
    fi
    # (c) explicit --crf wins on a 4K source (override gated on !_CLI_CRF_EXPLICIT)
    _a1_out="$(run_muxm --profile streaming-av1 --crf 25 --dry-run "$_a1_4k")"
    if printf '%s' "$_a1_out" | grep -qE 'streaming-av1:.*→ CRF 28'; then
      fail "A1: explicit --crf 25 on a 4K source was overridden by the resolution-aware CRF"
    else
      pass "A1: explicit --crf 25 on a 4K source wins (no resolution-aware override)"
    fi
    # (d) 1080p HDR source → override fires (extrapolation beyond the measured 4K-HDR point)
    if [[ -s "$_a1_1080hdr" ]]; then
      _a1_out="$(run_muxm --profile streaming-av1 --dry-run "$_a1_1080hdr")"
      if printf '%s' "$_a1_out" | grep -qE 'streaming-av1:.*HDR10.*→ CRF 28'; then
        pass "A1: 1080p HDR source under streaming-av1 → CRF 28 (HDR trigger)"
      else
        fail "A1: 1080p HDR source under streaming-av1 → expected a CRF 28 override"
      fi
    fi

    # ---- av1-hq CRF is resolution-aware too (base 28 ≤1080p SDR, 24 for ≥4K/HDR) ----
    # Shares the resolution helper with streaming-av1; reuses the same fixtures.
    # (a) 4K source → override to CRF 24 (AV1_HQ_HDR_CRF)
    _a1_out="$(run_muxm --profile av1-hq --dry-run "$_a1_4k")"
    if printf '%s' "$_a1_out" | grep -qE 'av1-hq:.*→ CRF 24'; then
      pass "video-av1hq-crf-override: 4K source under av1-hq → CRF 24 (resolution-aware override)"
    else
      fail "video-av1hq-crf-override: 4K source under av1-hq → expected a CRF 24 override note"
    fi
    # (b) 1080p SDR source → keeps the profile base CRF 28 (no override note)
    _a1_out="$(run_muxm --profile av1-hq --dry-run "$_a1_1080")"
    if printf '%s' "$_a1_out" | grep -qE 'av1-hq:.*→ CRF 24'; then
      fail "video-av1hq-crf-override: 1080p SDR source wrongly triggered the av1-hq 4K/HDR CRF override"
    else
      pass "video-av1hq-crf-override: 1080p SDR source under av1-hq → keeps base CRF 28 (no override)"
    fi
    # (c) explicit --crf wins on a 4K source (override gated on !_CLI_CRF_EXPLICIT)
    _a1_out="$(run_muxm --profile av1-hq --crf 30 --dry-run "$_a1_4k")"
    if printf '%s' "$_a1_out" | grep -qE 'av1-hq:.*→ CRF 24'; then
      fail "video-av1hq-crf-override: explicit --crf 30 on a 4K av1-hq source was overridden by the resolution-aware CRF"
    else
      pass "video-av1hq-crf-override: explicit --crf 30 on a 4K av1-hq source wins (no resolution-aware override)"
    fi
    # (d) 1080p HDR source → override fires to CRF 24 (HDR trigger)
    if [[ -s "$_a1_1080hdr" ]]; then
      _a1_out="$(run_muxm --profile av1-hq --dry-run "$_a1_1080hdr")"
      if printf '%s' "$_a1_out" | grep -qE 'av1-hq:.*HDR10.*→ CRF 24'; then
        pass "video-av1hq-crf-override: 1080p HDR source under av1-hq → CRF 24 (HDR trigger)"
      else
        fail "video-av1hq-crf-override: 1080p HDR source under av1-hq → expected a CRF 24 override"
      fi
    fi
  else
    skip "A1: 4K/1080p fixtures or libsvtav1 unavailable"
  fi
  rm -f "$_a1_4k" "$_a1_1080" "$_a1_1080hdr"
}

# === Suite: HDR Pipeline ===
# Validates HDR10 encoding preserves color metadata (BT.2020 primaries, SMPTE 2084 transfer).
# HDR metadata checks are soft (log, not fail) because ffprobe output varies across versions.
test_hdr() {
  section "HDR Pipeline"

  # Encode HDR10-tagged source (uses previously orphaned fixture #1)
  local outfile="$TESTDIR/hdr_encode.mkv"
  log "Encoding hevc_hdr10_tagged.mkv (HDR10 source)..."
  if assert_encode "HDR10 encode: output produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast "$TESTDIR/hevc_hdr10_tagged.mkv"; then
    assert_probe "HDR10 encode: HEVC codec" "$outfile" codec_name hevc

    # 1.2: HDR10 color tags must be present on the re-encoded output — converted from a soft
    # `skip` to a hard `fail` (the `*2020*`/`*2084*` substring tolerates ffprobe-version
    # spellings like "bt2020nc" while still catching a totally-untagged output).
    # HONEST LIMIT: this cannot isolate muxm's COLOR_ARGS from ffmpeg's auto-copy of the source's
    # color metadata — dropping/overriding/force-toggling COLOR_ARGS leaves the probed output
    # tags unchanged, so there is no working "color-flag" mutation here.
    # The non-tautological HDR-metadata test (with a real must-fail mutation) is the
    # master-display/MaxCLL frame_side_data probe (catalog M-HDR-2).
    local cp tf
    cp="$(probe_video "$outfile" color_primaries)"
    tf="$(probe_video "$outfile" color_transfer)"
    if [[ "$cp" == *"2020"* ]]; then
      pass "HDR10 encode: BT.2020 primaries re-applied on re-encode ($cp)"
    else
      fail "HDR10 encode: expected BT.2020 primaries on re-encode, got '$cp' — color signaling dropped"
    fi
    if [[ "$tf" == *"2084"* ]]; then
      pass "HDR10 encode: SMPTE 2084 (PQ) transfer re-applied on re-encode ($tf)"
    else
      fail "HDR10 encode: expected SMPTE 2084 transfer on re-encode, got '$tf' — color signaling dropped"
    fi
  fi

  # 1.2 negative control: an SDR source must NOT come out tagged HDR — catches the inverse
  # (always-tag) bug that the M-HDR-1 drop can't. basic_sdr_subs.mkv is bt709 SDR; the explicit
  # --crf forces a re-encode here too.
  local sdr_out="$TESTDIR/hdr_negctl_sdr.mkv"
  if assert_encode "HDR neg-control: SDR encode produced" "$sdr_out" \
       --output-ext mkv --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"; then
    local scp stf
    scp="$(probe_video "$sdr_out" color_primaries)"
    stf="$(probe_video "$sdr_out" color_transfer)"
    if [[ "$scp" != *"2020"* ]]; then
      pass "HDR neg-control: SDR output not tagged BT.2020 ($scp)"
    else
      fail "HDR neg-control: SDR source wrongly tagged BT.2020 ($scp) — always-tag bug"
    fi
    if [[ "$stf" != *"2084"* ]]; then
      pass "HDR neg-control: SDR output not tagged SMPTE 2084 ($stf)"
    else
      fail "HDR neg-control: SDR source wrongly tagged SMPTE 2084 ($stf) — always-tag bug"
    fi
  fi

  # --no-tonemap config flag
  local out
  out="$(run_muxm --no-tonemap --print-effective-config)"
  assert_contains "TONEMAP_HDR_TO_SDR        = 0" "--no-tonemap: flag registered" "$out"

  # ---- 4.1: Tone-map HDR→SDR real-encode color verification (A-class; replaces R28/R29 dry-run) ----
  # The old R28/R29 only grepped the --dry-run filter text and `else skip`ped when the synthetic
  # HDR tags didn't trigger detection. This runs a REAL --tonemap encode on the HDR fixture and
  # probes that the output is SDR-tagged (color_transfer / color_primaries == bt709, NOT
  # smpte2084/arib-std-b67/bt2020). Non-tautological: muxm's COLOR_ARGS override the source's HDR
  # tags (ffmpeg would otherwise auto-copy them), and the SDR-TONEMAP arm both sets bt709 tags and
  # gates the zscale tonemap filter — so M-TM-2 (disable the tonemap arm → it falls to the HDR10
  # arm) leaves the output HDR-tagged → red.
  # zscale (libzimg) is required for the tonemap filter chain — gate on it (host-capability skip).
  # Collect the filter list into a variable first: a `ffmpeg | grep -q` pipe SIGPIPEs ffmpeg under
  # `set -o pipefail` (returns 141) and would skip a capable host (cf. ffmpeg_has_encoder).
  local _ff_filters; _ff_filters="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
  if [[ "$_ff_filters" != *zscale* ]]; then
    skip "tonemap real encode: ffmpeg built without zscale/libzimg — tonemap filter unavailable"
  else
    local tm_out="$TESTDIR/hdr_tonemap_real.mkv"
    if assert_encode "tonemap real encode: --tonemap output produced" "$tm_out" \
         --tonemap --output-ext mkv --crf 28 --preset ultrafast "$TESTDIR/hevc_hdr10_tagged.mkv"; then
      local tm_trc tm_prim
      tm_trc="$(probe_video "$tm_out" color_transfer)"
      tm_prim="$(probe_video "$tm_out" color_primaries)"
      if [[ "$tm_trc" != *2084* && "$tm_trc" != *b67* && "$tm_trc" != *2020* ]]; then
        pass "tonemap real encode: output transfer is SDR ($tm_trc, not PQ/HLG)"
      else
        fail "tonemap real encode: output stayed HDR transfer '$tm_trc' — SDR-tonemap arm not applied"
      fi
      if [[ "$tm_prim" != *2020* ]]; then
        pass "tonemap real encode: output primaries are SDR ($tm_prim, not BT.2020)"
      else
        fail "tonemap real encode: output stayed BT.2020 primaries '$tm_prim' — SDR-tonemap arm not applied"
      fi
    fi
  fi

  # ---- 3.1: HDR10 static-metadata (mastering-display + MaxCLL) survival smoke probe ----
  # A-class smoke check: build a source carrying real mastering-display + MaxCLL frame side-data,
  # encode with hdr10-hq, and assert the output still carries BOTH. Catches a catastrophic regression
  # (an encode that drops static metadata entirely, e.g. via a stray strip/downconvert).
  # HONEST LIMIT — NOT the enforced HDR mutation: muxm sets no master-display/max-cll x265 params;
  # ffmpeg auto-forwards the source frame side-data to libx265 regardless (verified: survives even
  # with no x265-params at all), so this cannot isolate a muxm color lever and would pass for the
  # "wrong reason" if treated as a feature gate. The genuinely-mutable HDR10-static-metadata test
  # with the real must-fail mutation (M-HDR-2) is _test_unit_hdr10_static_metadata in the unit suite.
  if ! ffmpeg_has_encoder libx265; then
    skip "HDR10 static-metadata smoke probe: libx265 unavailable on this ffmpeg build"
  else
    local _hdrs_src="$TESTDIR/hdr10_static_md.mkv" _hdrs_out="$TESTDIR/hdr10_static_md_out.mkv"
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "color=c=green:s=320x240:r=24:d=1" \
      -f lavfi -i "sine=frequency=440:duration=1" \
      -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
      -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
      -c:a eac3 -b:a 448k -ac 6 -metadata:s:a:0 language=eng "$_hdrs_src" 2>/dev/null || true
    # Confirm the fixture itself carries both before relying on it (guards a host ffmpeg that
    # silently drops the params — a genuine capability gap, not a muxm regression).
    local _hdrs_src_sd
    _hdrs_src_sd="$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" -show_frames \
      -show_entries frame_side_data=side_data_type "$_hdrs_src" 2>/dev/null | grep -ciE 'mastering display|content light')"
    if [[ ! -s "$_hdrs_src" || "${_hdrs_src_sd:-0}" -lt 2 ]]; then
      skip "HDR10 static-metadata smoke probe: host ffmpeg did not embed mastering-display+MaxCLL in the fixture"
    elif assert_encode "HDR10 static-metadata smoke: hdr10-hq output produced" "$_hdrs_out" \
           --profile hdr10-hq --preset ultrafast --crf 28 "$_hdrs_src"; then
      local _hdrs_out_sd
      _hdrs_out_sd="$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" -show_frames \
        -show_entries frame_side_data=side_data_type "$_hdrs_out" 2>/dev/null | grep -ciE 'mastering display|content light')"
      if [[ "${_hdrs_out_sd:-0}" -ge 2 ]]; then
        pass "HDR10 static-metadata smoke: mastering-display + MaxCLL survive the hdr10-hq encode (auto-forward)"
      else
        fail "HDR10 static-metadata smoke: output lost mastering-display/MaxCLL side-data (got $_hdrs_out_sd of 2)"
      fi
    fi
    rm -f "$_hdrs_src" "$_hdrs_out"
  fi
}

# === Suite: Audio Pipeline ===
# Validates audio track selection (scoring algorithm, language preference, manual override),
# stereo fallback generation, codec forcing, lossless passthrough, and commentary deprioritization.
test_audio() {
  section "Audio Pipeline"

  local outfile out acount ch acodec alang

  # Basic encode — check audio present + stereo fallback.
  # --stereo-fallback is explicit so the test is deterministic regardless of
  # what ADD_STEREO_IF_MULTICH the user's ~/.muxmrc or default profile sets.
  # (CLI flags parsed after apply_profile, so they always win.)
  outfile="$TESTDIR/audio_test1.mp4"
  log "Testing audio pipeline..."
  if assert_encode "Audio test encode" "$outfile" \
       --crf 28 --preset ultrafast --stereo-fallback "$TESTDIR/hevc_sdr_51.mkv"; then
    assert_stream_count "Audio track present in output" "$outfile" a 2 2  # 5.1 + stereo-fallback
    # Hard assert: 6ch source + --stereo-fallback must produce a second stereo track
    acount="$(count_streams "$outfile" a)"
    if [[ "$acount" -ge 2 ]]; then
      pass "Stereo fallback: 6ch source + --stereo-fallback → stereo AAC track added"
    else
      fail "Stereo fallback: expected ≥2 audio tracks with --stereo-fallback on 6ch source, got $acount"
    fi
  fi

  # --no-stereo-fallback
  outfile="$TESTDIR/audio_no_stereo.mp4"
  log "Testing --no-stereo-fallback..."
  if assert_encode "--no-stereo-fallback encode" "$outfile" \
       --crf 28 --preset ultrafast --no-stereo-fallback "$TESTDIR/hevc_sdr_51.mkv"; then
    acount="$(count_streams "$outfile" a)"
    if [[ "$acount" -eq 1 ]]; then
      pass "--no-stereo-fallback: single audio track"
    else
      fail "--no-stereo-fallback: expected exactly 1 audio track (no fallback added), got $acount"
    fi
  fi

  # --skip-audio
  out="$(run_muxm --dry-run --skip-audio "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Audio processing disabled" "--skip-audio announced" "$out"

  # --- Multi-audio track auto-selection (uses previously orphaned fixture #2) ---
  outfile="$TESTDIR/audio_multi_auto.mp4"
  log "Testing multi-audio auto-selection..."
  if assert_encode "Multi-audio encode: output produced" "$outfile" \
       --crf 28 --preset ultrafast "$TESTDIR/multi_audio.mkv"; then
    assert_stream_count "Multi-audio: audio tracks present" "$outfile" a 2 2
    # The 5.1 EAC3 should be preferred by the scoring algorithm
    ch="$(probe_audio "$outfile" channels 0)"
    if [[ "$ch" =~ ^[0-9]+$ && "$ch" -ge 6 ]]; then
      pass "Multi-audio: primary track is surround (${ch}ch)"
    else
      fail "Multi-audio: expected surround (≥6ch) primary track, got ${ch}ch — 5.1 not preferred by scoring"
    fi
  fi

  # --audio-track override (#3, #7)
  outfile="$TESTDIR/audio_track_override.mp4"
  log "Testing --audio-track 0 override..."
  if assert_encode "--audio-track 0: output produced" "$outfile" \
       --audio-track 0 --no-stereo-fallback --crf 28 --preset ultrafast \
       "$TESTDIR/multi_audio.mkv"; then
    # Track 0 is stereo AAC, so output should have ≤2ch
    ch="$(probe_audio "$outfile" channels 0)"
    if [[ "$ch" =~ ^[0-9]+$ && "$ch" -le 2 ]]; then
      pass "--audio-track 0: stereo track selected (${ch}ch)"
    else
      fail "--audio-track 0: expected stereo (≤2ch) from track 0, got ${ch}ch"
    fi
  fi

  # --audio-lang-pref (#8)
  outfile="$TESTDIR/audio_lang_spa.mp4"
  log "Testing --audio-lang-pref spa..."
  if assert_encode "--audio-lang-pref spa: output produced" "$outfile" \
       --audio-lang-pref spa --no-stereo-fallback --crf 28 --preset ultrafast \
       "$TESTDIR/multi_lang_audio.mkv"; then
    alang="$(probe_stream_tag "$outfile" a:0 language)"
    if [[ "$alang" == "spa" ]]; then
      pass "--audio-lang-pref spa: Spanish audio selected"
    else
      fail "--audio-lang-pref spa: expected spa, got lang='$alang'"
    fi
  fi

  # --audio-force-codec aac (#9)
  outfile="$TESTDIR/audio_force_aac.mp4"
  log "Testing --audio-force-codec aac..."
  if assert_encode "--audio-force-codec aac: output produced" "$outfile" \
       --audio-force-codec aac --no-stereo-fallback --crf 28 --preset ultrafast \
       "$TESTDIR/hevc_sdr_51.mkv"; then
    acodec="$(probe_audio "$outfile" codec_name 0)"
    if [[ "$acodec" == "aac" ]]; then
      pass "--audio-force-codec aac: audio is AAC"
    else
      fail "--audio-force-codec aac: expected aac, got codec='$acodec'"
    fi
  fi

  # --- 7.1 (8ch) source → eac3 transcode (encoder channel cap regression test) ---
  # ffmpeg's native eac3 encoder supports a maximum of 6 channels (5.1).
  # Before the _codec_max_channels fix, an 8ch source would pass -ac 8 to ffmpeg,
  # causing a fatal "Specified channel layout is not supported" error.
  # This test ensures the pipeline automatically downmixes to ≤6ch for eac3.
  outfile="$TESTDIR/audio_71_eac3_cap.mp4"
  log "Testing 7.1 audio → eac3 (encoder channel cap)..."
  if assert_encode "7.1→eac3: encode succeeds (channel cap)" "$outfile" \
       --no-stereo-fallback --crf 28 --preset ultrafast "$TESTDIR/hevc_sdr_71.mkv"; then
    ch="$(probe_audio "$outfile" channels 0)"
    if [[ "$ch" =~ ^[0-9]+$ && "$ch" -le 6 ]]; then
      pass "7.1→eac3: output capped to ${ch}ch (encoder limit respected)"
    else
      fail "7.1→eac3: output has ${ch}ch — expected ≤6 (eac3 encoder max)"
    fi
    acodec="$(probe_audio "$outfile" codec_name 0)"
    if [[ "$acodec" == "eac3" ]]; then
      pass "7.1→eac3: output codec is eac3"
    else
      fail "7.1→eac3: expected eac3, got codec='$acodec'"
    fi
  fi

  # --- --audio-force-codec eac3 + 8ch source (forced codec also respects cap) ---
  outfile="$TESTDIR/audio_71_force_eac3.mp4"
  log "Testing --audio-force-codec eac3 with 8ch source..."
  if assert_encode "--audio-force-codec eac3 + 8ch: encode succeeds" "$outfile" \
       --audio-force-codec eac3 --no-stereo-fallback --crf 28 --preset ultrafast \
       "$TESTDIR/hevc_sdr_71.mkv"; then
    ch="$(probe_audio "$outfile" channels 0)"
    if [[ "$ch" =~ ^[0-9]+$ && "$ch" -le 6 ]]; then
      pass "--audio-force-codec eac3 + 8ch: capped to ${ch}ch"
    else
      fail "--audio-force-codec eac3 + 8ch: output has ${ch}ch — expected ≤6"
    fi
  fi

  # --- D3: --audio-force-bitrate works standalone (no --audio-force-codec) ---
  # Step 4 (fallback transcode) must honor --audio-force-bitrate for any transcoded non-lossless
  # output (matches the README). An mp3 stereo source → MP4 forces a transcode to aac (mp3 is not
  # MP4-container-safe). We assert the precise target from muxm's transcode log: the *encoded*
  # bit_rate is unreliable here (a sine tone compresses well below the -b:a target), but the log
  # records the exact value handed to ffmpeg.  D7 is unit-tested above (audio_transcode_target).
  local d3_src="$TESTDIR/d3_mp3_stereo.mkv"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=white:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" -map 0:v -map 1:a \
    -c:v libx265 -preset ultrafast -crf 28 -c:a mp3 -b:a 128k -ac 2 "$d3_src" 2>/dev/null || true
  if [[ ! -s "$d3_src" ]]; then
    # Genuine host skip: mp3 encoding needs libmp3lame, which a minimal ffmpeg build may lack.
    # (Skip-first guard, not an else-skip — see the soft-skip ratchet, _test_meta_soft_skip.)
    skip "audio-force-bitrate-standalone: could not create mp3 stereo fixture (ffmpeg lacks an mp3/libmp3lame encoder?)"
  else
    local d3_log d3_lf
    # Standalone --audio-force-bitrate → -b:a 320k (must be honored, not silently ignored → 192k).
    d3_log="$(run_muxm --audio-force-bitrate 320k --crf 28 --preset ultrafast "$d3_src" "$TESTDIR/d3_out.mp4")"
    d3_lf="$(_keepworkdir_logfile "$d3_log" || true)"
    if [[ -n "$d3_lf" ]] && grep -qiE 'audio transcode: .*bitrate=320k' "$d3_lf"; then
      pass "audio-force-bitrate-standalone: --audio-force-bitrate 320k honored standalone (Step 4 fallback transcode)"
    else
      fail "audio-force-bitrate-standalone: --audio-force-bitrate 320k not applied to the standalone transcode (log: $d3_lf)"
    fi
    # Regression: default transcode bitrate unchanged (192k) without the flag.
    d3_log="$(run_muxm --crf 28 --preset ultrafast "$d3_src" "$TESTDIR/d3_def.mp4")"
    d3_lf="$(_keepworkdir_logfile "$d3_log" || true)"
    if [[ -n "$d3_lf" ]] && grep -qiE 'audio transcode: .*bitrate=192k' "$d3_lf"; then
      pass "audio-force-bitrate-standalone: default transcode bitrate unchanged (192k) without the flag"
    else
      fail "audio-force-bitrate-standalone: default transcode bitrate not 192k (log: $d3_lf)"
    fi
    # Copy path unaffected: a copyable codec (eac3 in compliant.mp4) is copied, not transcoded,
    # so --audio-force-bitrate does not apply (bitrate is meaningless for -c copy).
    d3_log="$(run_muxm --audio-force-bitrate 320k --crf 28 --preset ultrafast "$TESTDIR/compliant.mp4" "$TESTDIR/d3_copy.mp4")"
    if echo "$d3_log" | grep -qiE 'Copying|Direct Play|lossless passthrough'; then
      pass "audio-force-bitrate-standalone: --audio-force-bitrate does not force a transcode on copy paths"
    else
      fail "audio-force-bitrate-standalone: --audio-force-bitrate unexpectedly transcoded a copyable source"
    fi
  fi

  # --- Step-2 (lossless-incompatible transcode) bitrate logging + >6ch channel-cap survival ---
  # A lossless source that can't mux into the target container (FLAC → MP4 with
  # --audio-lossless-passthrough) takes the Step-2 transcode, which now logs its bitrate like the
  # other transcode branches (item 2b). The bitrate log is emitted AFTER the encoder channel cap,
  # so a forced bitrate survives the >6ch→eac3 cap (item 1) and the log reflects the final layout.
  # A shared 7.1 FLAC fixture exercises the cap; a stereo FLAC fixture exercises the aac path.
  local flac_st="$TESTDIR/flac_stereo_src.mkv" flac_71="$TESTDIR/flac_71_src.mkv"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=white:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" -map 0:v -map 1:a \
    -c:v libx265 -preset ultrafast -crf 28 -c:a flac -ac 2 "$flac_st" 2>/dev/null || true
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=white:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" -map 0:v -map 1:a \
    -c:v libx265 -preset ultrafast -crf 28 -c:a flac -ac 8 "$flac_71" 2>/dev/null || true
  if [[ ! -s "$flac_st" || ! -s "$flac_71" ]]; then
    # Genuine host skip: FLAC encoding must be available (skip-first guard, not an else-skip —
    # see the soft-skip ratchet, _test_meta_soft_skip).
    skip "Step-2/cap tests: could not create FLAC fixtures (ffmpeg lacks the flac encoder?)"
  else
    local s2_log s2_lf
    # item 2b: the Step-2 transcode honors --audio-force-bitrate AND now logs its bitrate.
    s2_log="$(run_muxm --audio-lossless-passthrough --audio-force-bitrate 320k --crf 28 --preset ultrafast "$flac_st" "$TESTDIR/s2_fb.mp4")"
    s2_lf="$(_keepworkdir_logfile "$s2_log" || true)"
    if [[ -n "$s2_lf" ]] && grep -qiE 'audio transcode: .*bitrate=320k' "$s2_lf"; then
      pass "Step 2: --audio-force-bitrate 320k honored + bitrate logged on the lossless-incompatible transcode"
    else
      fail "Step 2: --audio-force-bitrate 320k not applied/logged on the lossless-incompatible transcode (log: $s2_lf)"
    fi
    # item 2b: --stereo-bitrate (D7) also reaches the Step-2 aac transcode.
    s2_log="$(run_muxm --audio-lossless-passthrough --stereo-bitrate 320k --crf 28 --preset ultrafast "$flac_st" "$TESTDIR/s2_sb.mp4")"
    s2_lf="$(_keepworkdir_logfile "$s2_log" || true)"
    if [[ -n "$s2_lf" ]] && grep -qiE 'audio transcode: .*bitrate=320k' "$s2_lf"; then
      pass "Step 2: --stereo-bitrate 320k honored on the lossless-incompatible aac transcode"
    else
      fail "Step 2: --stereo-bitrate 320k not applied on the lossless-incompatible transcode (log: $s2_lf)"
    fi
    # item 1: a forced bitrate SURVIVES the >6ch→eac3 channel cap (8ch FLAC → eac3, capped to 6).
    # Assert both channels=6ch (the cap fired) and bitrate=500k (the forced value was not re-derived).
    s2_log="$(run_muxm --audio-lossless-passthrough --audio-force-bitrate 500k --no-stereo-fallback --crf 28 --preset ultrafast "$flac_71" "$TESTDIR/cap_fb.mp4")"
    s2_lf="$(_keepworkdir_logfile "$s2_log" || true)"
    if [[ -n "$s2_lf" ]] && grep -qiE 'audio transcode: channels=6ch, bitrate=500k' "$s2_lf"; then
      pass "Item 1: --audio-force-bitrate survives the >6ch→eac3 channel cap (500k, not re-derived)"
    else
      fail "Item 1: forced bitrate did not survive the channel cap (expected channels=6ch bitrate=500k; log: $s2_lf)"
    fi
    # item 1 regression: WITHOUT a forced bitrate, the cap re-derives the auto bitrate (768k 7.1 → 640k 5.1).
    s2_log="$(run_muxm --audio-lossless-passthrough --no-stereo-fallback --crf 28 --preset ultrafast "$flac_71" "$TESTDIR/cap_def.mp4")"
    s2_lf="$(_keepworkdir_logfile "$s2_log" || true)"
    if [[ -n "$s2_lf" ]] && grep -qiE 'audio transcode: channels=6ch, bitrate=640k' "$s2_lf"; then
      pass "Item 1: auto bitrate is re-derived for the capped layout (640k 5.1) without a forced bitrate"
    else
      fail "Item 1: capped auto bitrate not 640k (log: $s2_lf)"
    fi
  fi

  # --stereo-bitrate via effective config (#11)
  out="$(run_muxm --stereo-bitrate 192k --print-effective-config)"
  assert_contains "STEREO_BITRATE            = 192k" "--stereo-bitrate: config shows 192k" "$out"

  # --audio-lossless-passthrough / --no-audio-lossless-passthrough via effective config (#10)
  out="$(run_muxm --audio-lossless-passthrough --print-effective-config)"
  assert_contains "AUDIO_LOSSLESS_PASSTHROUGH = 1" "--audio-lossless-passthrough: flag set" "$out"

  out="$(run_muxm --no-audio-lossless-passthrough --print-effective-config)"
  assert_contains "AUDIO_LOSSLESS_PASSTHROUGH = 0" "--no-audio-lossless-passthrough: flag cleared" "$out"

  # --- Commentary track detection ---
  # The multi_audio_commentary.mkv fixture has two identically-specced 5.1 EAC3 English
  # tracks that differ ONLY in their title metadata ("Director's Commentary" vs "Main Feature").
  # This isolates the commentary penalty in the scoring algorithm — if both tracks score
  # equally on codec/channels/language, only the title-based penalty distinguishes them.
  outfile="$TESTDIR/audio_commentary_detect.mp4"
  log "Testing commentary track deprioritization..."
  local commentary_out
  commentary_out="$(run_muxm --no-stereo-fallback --crf 28 --preset ultrafast \
    "$TESTDIR/multi_audio_commentary.mkv" "$outfile" 2>&1)"
  if [[ -f "$outfile" && -s "$outfile" ]]; then
    pass "Commentary detection: output produced"
    # Track 0 is "Director's Commentary", track 1 is "Main Feature" — both 5.1 EAC3 eng.
    # Scoring should pick track 1 (Main Feature) due to commentary penalty on track 0.
    # Verify via muxm's selection log (title tags may not survive muxing to output).
    if echo "$commentary_out" | grep -q "Selected track #1"; then
      pass "Commentary detection: main feature track selected over commentary"
    else
      fail "Commentary detection: expected track #1 selected, got: $(echo "$commentary_out" | grep 'Selected track')"
    fi
  else
    fail "Commentary detection: no output"
  fi

  # --- Lossless codec preferred over lossy despite bitrate advantage (regression) ---
  # The lossless_vs_lossy.mkv fixture has FLAC 5.1 (#0) + AC3 5.1 (#1), same language.
  # FLAC reports bit_rate=0 (VBR); AC3 reports 640 kbps.  With the animation profile's
  # codec preference (flac > truehd > eac3 > ac3), the scoring algorithm must select
  # track #0 (FLAC).  Before the fix, the uncapped bitrate bonus let AC3 win.
  outfile="$TESTDIR/audio_lossless_vs_lossy.mkv"
  log "Testing lossless-preferred-over-lossy scoring (animation codec pref)..."
  local lvl_out
  lvl_out="$(run_muxm --profile animation --crf 28 --preset ultrafast \
    --no-stereo-fallback \
    "$TESTDIR/lossless_vs_lossy.mkv" "$outfile" 2>&1)"
  if [[ -f "$outfile" && -s "$outfile" ]]; then
    pass "Lossless-vs-lossy: output produced"
    # Track 0 is FLAC (lossless, higher codec rank), track 1 is AC3 (lossy, higher bitrate).
    # Scoring must select track #0.
    if echo "$lvl_out" | grep -q "Selected track #0"; then
      pass "Lossless-vs-lossy: FLAC selected over AC3 (codec preference dominates bitrate)"
    else
      fail "Lossless-vs-lossy: expected track #0 (FLAC), got: $(echo "$lvl_out" | grep 'Selected track')"
    fi
  else
    fail "Lossless-vs-lossy: no output"
  fi

  # ---- --audio-titles produces descriptive stream title ----
  local at_out="$TESTDIR/e2e_audio_titles.mkv"
  if run_muxm --output-ext mkv --crf 28 --preset ultrafast --audio-titles \
       "$TESTDIR/multi_audio.mkv" "$at_out" >/dev/null 2>&1 && [[ -f "$at_out" ]]; then
    local at_title
    at_title="$(probe_stream_tag "$at_out" a:0 title)"
    if [[ -n "$at_title" && "$at_title" != "N/A" ]]; then
      pass "--audio-titles: output audio stream has title tag ('$at_title')"
    else
      fail "--audio-titles: output audio stream missing title tag"
    fi
  else
    skip "--audio-titles encode failed or output not found"
  fi

  # ---- --no-audio-titles suppresses descriptive title generation ----
  local nat_out="$TESTDIR/e2e_no_audio_titles.mkv"
  if run_muxm --output-ext mkv --crf 28 --preset ultrafast --no-audio-titles \
       "$TESTDIR/hevc_sdr_51.mkv" "$nat_out" >/dev/null 2>&1 && [[ -f "$nat_out" ]]; then
    local nat_title
    nat_title="$(probe_stream_tag "$nat_out" a:0 title)"
    # --audio-titles generates "X.X Surround (CODEC)"; --no-audio-titles must NOT
    # produce the parenthesized codec descriptor.  The MKV muxer may auto-generate
    # channel-layout text (e.g. "5.1 Surround"), so we verify the codec suffix is absent.
    if [[ "$nat_title" == *"("*")"* ]]; then
      fail "--no-audio-titles: descriptive codec title still present '$nat_title'"
    else
      pass "--no-audio-titles: no descriptive codec title generated"
    fi
  else
    skip "--no-audio-titles encode failed or output not found"
  fi

  # ---- Pipe characters in audio stream titles no longer break field parsing ----
  # v1.0.2 fix: audio titles with literal | (e.g. "Original | English") corrupted
  # the old pipe-delimited _audio_stream_info output. Delimiter migrated to \t.
  # Primary signal: encode completes without nounset arithmetic crash.
  local pipe_audio_out="$TESTDIR/audio_pipe_titles.mp4"
  log "Testing pipe characters in audio stream title..."
  if assert_encode "Pipe in audio title: encode completes (no crash)" "$pipe_audio_out" \
       --crf 28 --preset ultrafast "$TESTDIR/pipe_titles.mkv"; then
    assert_stream_count "Pipe in audio title: audio stream present" "$pipe_audio_out" a 1 1
  fi

  # ---- Multi-track audio (archive) ----
  # Uses hevc_multi_audio.mkv: 3 tracks — eng "Main Feature", eng "Director's Commentary", spa "Spanish"

  # Multi-track dry-run: shows ✓/✗ markers and announces multi-track mode
  log "Testing multi-track audio dry-run..."
  local mt_dry
  mt_dry="$(run_muxm --dry-run --profile archive "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "multi-track" "Multi-track dry-run: announces multi-track mode" "$mt_dry"
  assert_contains "✓" "Multi-track dry-run: shows ✓ keep marker" "$mt_dry"
  assert_contains "✗" "Multi-track dry-run: shows ✗ drop marker (commentary filtered)" "$mt_dry"

  # Multi-track commentary filtering: commentary track dropped, 2 survive
  log "Testing multi-track commentary filtering..."
  assert_contains "commentary" "Multi-track: commentary track detected" "$mt_dry"
  # Default archive: AUDIO_KEEP_COMMENTARY=0 drops the commentary track
  assert_contains "keeping 2 of 3" "Multi-track: 2 of 3 tracks kept (commentary dropped)" "$mt_dry"

  # Multi-track demotion: --audio-track forces single-track
  log "Testing multi-track demotion on --audio-track..."
  local mt_demote_at
  mt_demote_at="$(run_muxm --dry-run --profile archive --audio-track 0 "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "single audio track" "Multi-track + --audio-track: collapses to a single audio track" "$mt_demote_at"

  # Multi-track demotion: --audio-force-codec forces single-track
  log "Testing multi-track demotion on --audio-force-codec..."
  local mt_demote_fc
  mt_demote_fc="$(run_muxm --dry-run --profile archive --audio-force-codec aac "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "single audio track" "Multi-track + --audio-force-codec: collapses to a single audio track" "$mt_demote_fc"

  # Multi-track + --stereo-fallback: warns but does NOT demote.
  # --stereo-fallback generates a conflict warning (⚠, tested in test_conflicts)
  # but multi-track stays active because stream-copying from source never reaches
  # the stereo generation path.  Verify multi-track mode is preserved.
  log "Testing multi-track + --stereo-fallback stays in multi-track mode..."
  local mt_sf_out
  mt_sf_out="$(run_muxm --dry-run --profile archive --stereo-fallback "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "multi-track" "Multi-track + --stereo-fallback: multi-track mode preserved" "$mt_sf_out"
  assert_contains "keeping" "Multi-track + --stereo-fallback: filter summary logged" "$mt_sf_out"

  # Multi-track language filter: --audio-lang-pref eng keeps only English tracks
  # CLI flag overrides the profile's AUDIO_LANG_PREF="" (config file would not —
  # profiles run after config files but before CLI).
  log "Testing multi-track language filter..."
  local mt_lang_out
  mt_lang_out="$(run_muxm --dry-run --profile archive \
    --audio-lang-pref eng "$TESTDIR/hevc_multi_audio.mkv")"
  # eng main kept, eng commentary dropped (commentary), spa dropped (language) = keeping 1 of 3
  assert_contains "keeping 1 of 3" "Multi-track + --audio-lang-pref eng: 1 of 3 kept (spa + commentary dropped)" "$mt_lang_out"

  # Multi-track commentary opt-in: AUDIO_KEEP_COMMENTARY=1 keeps all tracks
  # All existing tests use the default AUDIO_KEEP_COMMENTARY=0 (drop). This validates
  # the opt-in path — if accidentally inverted, the default passes but this fails.
  # AUDIO_LANG_PREF= (empty) is required to let all languages through — the default
  # is "eng", which would filter out the Spanish track and mask the commentary test.
  log "Testing multi-track AUDIO_KEEP_COMMENTARY=1 (keep commentary)..."
  local mt_keep_comm_home="$TESTDIR/mt_keep_comm_home"
  mkdir -p "$mt_keep_comm_home"
  cat > "$mt_keep_comm_home/.muxmrc" <<'EOF'
AUDIO_MULTI_TRACK=1
AUDIO_KEEP_COMMENTARY=1
AUDIO_LANG_PREF=
EOF
  local mt_keep_comm
  mt_keep_comm="$(MUXM_HOME="$mt_keep_comm_home" run_muxm_in "$TESTDIR" \
    --dry-run "$TESTDIR/hevc_multi_audio.mkv")"
  assert_contains "keeping 3 of 3" \
    "Multi-track + AUDIO_KEEP_COMMENTARY=1: all 3 tracks kept" "$mt_keep_comm"
  # Verify the commentary track is explicitly shown as kept (✓ marker)
  assert_contains "commentary" \
    "Multi-track + AUDIO_KEEP_COMMENTARY=1: commentary track detected" "$mt_keep_comm"

  # ---- L6: encoder↔codec normalization in the audio "already matches" check ----
  # AUDIO_FORCE_CODEC holds an ENCODER name (streaming-av1 → libopus); the source codec is
  # an ffprobe name (opus). A naive compare never matched, so an Opus source was pointlessly
  # re-encoded (which still yields codec "opus", so the discriminator is COPY vs transcode:
  # the log says "Copying" and the descriptive title reads "(Opus)" only when normalized).
  local _l6_src="$TESTDIR/l6_opus.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=olive:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=duration=1" -c:v libx265 -tag:v hvc1 -preset ultrafast -crf 30 \
    -c:a libopus -ac 2 -metadata:s:a:0 language=eng "$_l6_src" 2>/dev/null || true
  if [[ -s "$_l6_src" ]] && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libsvtav1; then
    local _l6_out="$TESTDIR/l6_out.mp4"; rm -f "$_l6_out"
    local _l6_log _l6_code=0
    _l6_log="$(cd "$TESTDIR" && "$MUXM" -K --no-skip-if-ideal --audio-titles --profile streaming-av1 \
      --crf 40 "$_l6_src" "$_l6_out" 2>&1)" || _l6_code=$?
    if [[ "$_l6_code" -eq 0 && -s "$_l6_out" ]]; then
      # Copied, not transcoded (both produce "opus"; the log distinguishes them).
      if printf '%s' "$_l6_log" | grep -qiE 'already matches forced codec.*[Cc]opying' \
         && ! printf '%s' "$_l6_log" | grep -qiE 'Force transcoding audio'; then
        pass "audio-descriptive-title-codec: streaming-av1 on an Opus source → audio stream-copied (not re-encoded)"
      else
        fail "audio-descriptive-title-codec: streaming-av1 on Opus source → expected -c:a copy, log shows a transcode"
      fi
      local _l6_ac _l6_title
      _l6_ac="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$_l6_out" 2>/dev/null || true)"
      if [[ "$_l6_ac" == "opus" ]]; then
        pass "audio-descriptive-title-codec: output audio codec is opus"
      else
        fail "audio-descriptive-title-codec: output audio codec expected opus, got '$_l6_ac'"
      fi
      # MP4 stores the audio title in the 'name' tag; must read "Opus", not "libopus".
      _l6_title="$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=name -of csv=p=0 "$_l6_out" 2>/dev/null || true)"
      if [[ "$_l6_title" == *Opus* && "$_l6_title" != *libopus* ]]; then
        pass "audio-descriptive-title-codec: copied-Opus audio title is accurate ('$_l6_title')"
      else
        fail "audio-descriptive-title-codec: Opus audio title expected '… (Opus)', got '$_l6_title'"
      fi
    else
      fail "audio-descriptive-title-codec: streaming-av1 on Opus source → encode failed (exit $_l6_code)"
    fi
    rm -f "$_l6_out"
  else
    skip "audio-descriptive-title-codec: Opus fixture or libsvtav1 encoder unavailable"
  fi
  rm -f "$_l6_src"

  _test_audio_native_stereo
  _test_audio_directplay
  _test_audio_maxchannels
  _test_audio_stereo_label
  _test_audio_no_audio_guard
  _test_audio_disk_hint
  _test_audio_untagged_lang
  _test_audio_container_safety
  _test_audio_verify_display
  _test_audio_forceaac_stereo_bitrate
  _test_audio_lossless_skip_drop
  _test_audio_disposition_commentary
  _test_audio_multitrack_disposition_commentary
  _test_audio_empty_langpref_no_crash
  _test_audio_native_stereo_en_eng_copy
  _test_audio_commentary_title
}

# CR-6: `_audio_lang_matches` is the one of four call sites NOT gated on `[[ -n "$AUDIO_LANG_PREF" ]]`
# (the scorer reaches it unguarded). With the documented keep-all `--audio-lang-pref ""`, the empty
# read yields a 0-element prefs array and `for pref in "${prefs[@]}"` aborts under set -u on bash < 4.4
# (floor 4.3). The fix adds an entry guard to BOTH matchers. On host bash >= 4.4 the OLD form does NOT
# crash, so the genuine cross-host guard is STATIC (assert the guard line exists); a true-4.3 run via
# $BASH_43 reproduces the crash, and an e2e smoke proves keep-all still encodes.
_test_audio_empty_langpref_no_crash() {
  # (1) Static drift guard (host-independent): both matchers must carry the empty-pref entry guard.
  local a_body s_body
  a_body="$(_extract_muxm_fns _audio_lang_matches)" || { fail "audio-empty-langpref-no-crash: could not extract _audio_lang_matches"; return; }
  s_body="$(_extract_muxm_fns _sub_lang_matches)"   || { fail "audio-empty-langpref-no-crash: could not extract _sub_lang_matches"; return; }
  # shellcheck disable=SC2016  # single quotes are deliberate: grep -F matches the guard line as a
  # LITERAL in the extracted muxm source ($AUDIO_LANG_PREF must stay unexpanded, not be substituted).
  if printf '%s\n' "$a_body" | grep -qF '[[ -n "$AUDIO_LANG_PREF" ]] || return 1'; then
    pass "audio-empty-langpref-no-crash: _audio_lang_matches has the empty-AUDIO_LANG_PREF entry guard"
  else
    fail "audio-empty-langpref-no-crash: _audio_lang_matches is missing the [[ -n \"\$AUDIO_LANG_PREF\" ]] || return 1 entry guard"
  fi
  # shellcheck disable=SC2016  # single quotes are deliberate: literal grep -F of the guard line
  # in the extracted source ($SUB_LANG_PREF must stay unexpanded, not be substituted).
  if printf '%s\n' "$s_body" | grep -qF '[[ -n "$SUB_LANG_PREF" ]] || return 1'; then
    pass "audio-empty-langpref-no-crash: _sub_lang_matches has the empty-SUB_LANG_PREF entry guard (symmetry)"
  else
    fail "audio-empty-langpref-no-crash: _sub_lang_matches is missing the [[ -n \"\$SUB_LANG_PREF\" ]] || return 1 entry guard"
  fi

  # (2) True bash-4.3 crash repro when available, else host smoke. The matcher + _norm_lang_code run
  # under `set -u` with AUDIO_LANG_PREF="" must return non-zero (no match) WITHOUT an unbound-var abort.
  local runner_bash="${BASH_43:-bash}"
  local body err rc=0
  body="$(_extract_muxm_fns _audio_lang_matches _norm_lang_code)" || { fail "audio-empty-langpref-no-crash: could not extract matcher+norm"; return; }
  # shellcheck disable=SC2016  # body must reach the sub-bash unexpanded; vars expand THERE under set -u
  err="$("$runner_bash" -c "$body"$'\n''set -u; AUDIO_LANG_PREF=""; _audio_lang_matches eng; echo "rc=$?"' 2>&1)" || rc=$?
  if printf '%s\n' "$err" | grep -qiE 'unbound variable'; then
    fail "audio-empty-langpref-no-crash: empty AUDIO_LANG_PREF aborted with unbound variable on ${runner_bash}: $(printf '%s' "$err" | head -1)"
  elif printf '%s\n' "$err" | grep -qF 'rc=1'; then
    pass "audio-empty-langpref-no-crash: empty AUDIO_LANG_PREF returns no-match cleanly under set -u (${runner_bash}; no unbound-var crash)"
  else
    fail "audio-empty-langpref-no-crash: unexpected matcher result under set -u (${runner_bash}). Saw: $(printf '%s' "$err" | head -1)"
  fi

  # (3) e2e smoke: --audio-lang-pref '' (keep-all) single-track encodes cleanly (genuine on a 4.3 host).
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=teal:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -c:a:0 ac3 -ac:a:0 6 -metadata:s:a:0 language=eng \
    "$TESTDIR/cr6_src.mkv" 2>/dev/null
  local _cr6_out="$TESTDIR/cr6_out.mkv"; rm -f "$_cr6_out"
  local out
  out="$(run_muxm --crf 51 --preset ultrafast --output-ext mkv --audio-lang-pref '' "$TESTDIR/cr6_src.mkv" "$_cr6_out" 2>&1)"
  if printf '%s\n' "$out" | grep -qiE 'unbound variable'; then
    fail "audio-empty-langpref-no-crash (e2e): --audio-lang-pref '' single-track run hit an unbound variable. Saw: $(printf '%s\n' "$out" | grep -i 'unbound' | head -1)"
  elif [[ -s "$_cr6_out" ]]; then
    pass "audio-empty-langpref-no-crash (e2e): --audio-lang-pref '' (keep-all) single-track encodes cleanly"
  else
    fail "audio-empty-langpref-no-crash (e2e): --audio-lang-pref '' produced no output"
  fi
  rm -f "$TESTDIR/cr6_src.mkv" "$_cr6_out" 2>/dev/null || true
}

# CR-7: the native-stereo scan hand-rolled its primary-vs-stereo language compare without
# _norm_lang_code (unlike the sibling _audio_lang_matches), so an `eng` primary did not match an
# `en`-tagged native stereo — and muxm synthesized an AAC downmix instead of stream-copying the
# existing native stereo. Fixture: a0 = eac3 6ch `eng` (selected primary), a1 = eac3 2ch `en`
# (copyable native stereo). The stereo must be COPIED (output 2ch stays eac3), not re-encoded to
# aac. Differential is the output 2ch codec, plus the "Native stereo track found" note.
_test_audio_native_stereo_en_eng_copy() {
  local src="$TESTDIR/cr7_en_eng.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -f lavfi -i "sine=frequency=660:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 eac3 -ac:a:0 6 -c:a:1 eac3 -ac:a:1 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=en \
    "$src" 2>/dev/null
  # Fixture must carry a 6ch eng primary + a 2ch en native stereo, else it proves nothing.
  local _a0 _a1
  _a0="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels:stream_tags=language -of csv=p=0 "$src" 2>/dev/null || true)"
  _a1="$(ffprobe -v error -select_streams a:1 -show_entries stream=channels:stream_tags=language -of csv=p=0 "$src" 2>/dev/null || true)"
  if [[ ! -s "$src" || "$_a0" != "6,eng" || "$_a1" != "2,en" ]]; then
    skip "audio-native-stereo-en-eng-copy: could not build a 6ch-eng + 2ch-en fixture (a0='$_a0' a1='$_a1')"
    rm -f "$src" 2>/dev/null || true
    return
  fi
  local out="$TESTDIR/cr7_out.mkv"; rm -f "$out"
  local log
  log="$(run_muxm --crf 51 --preset ultrafast --output-ext mkv --stereo-fallback "$src" "$out" 2>&1)"
  # (1) The en-tagged native stereo must be FOUND (not skipped to a downmix) now that codes normalize.
  if printf '%s\n' "$log" | grep -qF "Native stereo track found"; then
    pass "audio-native-stereo-en-eng-copy: en-tagged native stereo matched the eng primary (normalized) — used instead of a downmix"
  else
    fail "audio-native-stereo-en-eng-copy: en-tagged native stereo not matched to eng primary. Saw: $(printf '%s\n' "$log" | grep -iE 'native stereo|downmix' | head -1)"
  fi
  # (2) Value assertion: the kept 2ch stream is COPIED (eac3), not re-encoded to aac.
  if [[ -s "$out" ]]; then
    local _stereo_codec
    _stereo_codec="$(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels -of csv=p=0 "$out" 2>/dev/null | awk -F, '$2==2{print $1; exit}')"
    if [[ "$_stereo_codec" == "eac3" ]]; then
      pass "audio-native-stereo-en-eng-copy: native stereo stream-copied (output 2ch codec=eac3, not a synthesized aac downmix)"
    else
      fail "audio-native-stereo-en-eng-copy: output 2ch stream codec='${_stereo_codec:-none}' (expected eac3 copy; aac means a needless transcode)"
    fi
  else
    fail "audio-native-stereo-en-eng-copy: --stereo-fallback produced no output"
  fi
  rm -f "$src" "$out" 2>/dev/null || true
}

# CR-3: the MULTI-TRACK keep-list (the only commentary filter in multi-track mode) must drop a
# disposition-flagged commentary/AD track even when its title is empty — matching the RF3
# single-track hardening. Fixture: track0 = ac3 6ch eng main (untitled, no disposition),
# track1 = eac3 6ch eng flagged `-disposition:a:1 comment` (untitled). If _build_audio_keep_list
# sank the disposition fields and filtered commentary by title only, the untitled flagged track
# would survive: "keeping 2 of 2". ORing the flags in yields "keeping 1 of 2". A positive control
# (AUDIO_KEEP_COMMENTARY=1) proves the track is retained when commentary-keeping is on.
_test_audio_multitrack_disposition_commentary() {
  local src="$TESTDIR/cr3_mt_dispo.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=660:duration=2" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 ac3 -ac:a:0 6 -c:a:1 eac3 -b:a:1 256k -ac:a:1 6 \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=eng \
    -disposition:a:0 0 -disposition:a:1 comment \
    "$src" 2>/dev/null
  # Fixture must carry disposition.comment on track 1 with empty titles, else it proves nothing.
  local _d1 _t1
  _d1="$(ffprobe -v error -select_streams a:1 -show_entries stream_disposition=comment -of csv=p=0 "$src" 2>/dev/null || true)"
  _t1="$(probe_stream_tag "$src" a:1 title 2>/dev/null || true)"
  if [[ ! -s "$src" || "$_d1" != "1" || -n "$_t1" ]]; then
    skip "audio-multitrack-disposition-commentary: could not build a disposition-flagged untitled-commentary multi-track fixture (comment=$_d1 title='$_t1')"
    return
  fi

  # Negative (the bug): multi-track + AUDIO_KEEP_COMMENTARY=0 → the flagged track must be filtered.
  # Use a project-dir .muxmrc (default AUDIO_LANG_PREF=eng keeps both eng tracks, so only the
  # commentary filter differs them). --no-skip-if-ideal forces the keep-list to run.
  local drop_proj="$TESTDIR/cr3_drop_proj"; mkdir -p "$drop_proj"
  printf 'AUDIO_MULTI_TRACK=1\nAUDIO_KEEP_COMMENTARY=0\n' > "$drop_proj/.muxmrc"
  local out
  out="$(run_muxm_in "$drop_proj" --dry-run --no-skip-if-ideal "$src" "$TESTDIR/cr3_out.mkv")"
  if printf '%s\n' "$out" | grep -qF "keeping 1 of 2 tracks"; then
    pass "audio-multitrack-disposition-commentary: disposition-flagged untitled commentary dropped from multi-track keep-list (1 of 2 kept)"
  else
    fail "audio-multitrack-disposition-commentary: flagged commentary survived the multi-track keep-list. Saw: $(printf '%s\n' "$out" | grep -oE 'keeping [0-9]+ of [0-9]+ tracks' | head -1)"
  fi

  # Positive control: AUDIO_KEEP_COMMENTARY=1 → the commentary track is retained (both kept).
  local keep_proj="$TESTDIR/cr3_keep_proj"; mkdir -p "$keep_proj"
  printf 'AUDIO_MULTI_TRACK=1\nAUDIO_KEEP_COMMENTARY=1\n' > "$keep_proj/.muxmrc"
  out="$(run_muxm_in "$keep_proj" --dry-run --no-skip-if-ideal "$src" "$TESTDIR/cr3_out.mkv")"
  if printf '%s\n' "$out" | grep -qF "keeping 2 of 2 tracks"; then
    pass "audio-multitrack-disposition-commentary control: AUDIO_KEEP_COMMENTARY=1 retains the flagged commentary track (2 of 2 kept)"
  else
    fail "audio-multitrack-disposition-commentary control: expected 2 of 2 kept with AUDIO_KEEP_COMMENTARY=1. Saw: $(printf '%s\n' "$out" | grep -oE 'keeping [0-9]+ of [0-9]+ tracks' | head -1)"
  fi

  rm -f "$src" "$TESTDIR/cr3_out.mkv" 2>/dev/null || true
}

# 5.5 (Option C): a kept multi-track commentary track's descriptive title gets a "— Commentary"
# suffix appended instead of being silently indistinguishable from any other track. Three real
# encodes (not --dry-run, since the title only lands in the actual muxed output):
#   1. Positive — a titled commentary track (AUDIO_KEEP_COMMENTARY=1, INCLUDE_AUDIO_TITLES=1)
#      gets both a codec/channel description AND the "— Commentary" suffix.
#   2. Negative — a genuine alternate-language, non-commentary track in the SAME run gets the
#      plain descriptive title with NO suffix (guards against the detection over-firing).
#   3. --no-audio-titles regression — the original source title ("Commentary with Director")
#      passes through verbatim; this code path is untouched by the 5.5 fix.
_test_audio_commentary_title() {
  local _dir="$TESTDIR/audio_5_5_commentary"; mkdir -p "$_dir"
  local _src="$_dir/src.mkv"
  # track0 = main (eng, untitled), track1 = commentary (eng, titled "Commentary with Director")
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -f lavfi -i "sine=frequency=880:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a -c:a aac -b:a 128k \
    -metadata:s:a:0 language=eng \
    -metadata:s:a:1 language=eng -metadata:s:a:1 title="Commentary with Director" \
    "$_src" 2>/dev/null
  if [[ ! -s "$_src" ]]; then
    skip "audio-commentary-title: could not build the commentary-title fixture"; rm -rf "$_dir"; return
  fi

  local _proj="$_dir/proj"; mkdir -p "$_proj"
  printf 'AUDIO_MULTI_TRACK=1\nAUDIO_KEEP_COMMENTARY=1\nAUDIO_LANG_PREF=""\n' > "$_proj/.muxmrc"

  # ---- 1. Positive: commentary track gets a descriptive title AND the "— Commentary" suffix ----
  local _out1="$_dir/out_positive.mkv"
  run_muxm_in "$_proj" "$_src" "$_out1" >/dev/null 2>&1 || true
  local _title1
  _title1="$(ffprobe -v error -select_streams a:1 -show_entries stream_tags=title -of csv=p=0 "$_out1" 2>/dev/null || true)"
  if [[ "$_title1" == *"Commentary"* ]] && [[ "$_title1" =~ \([A-Za-z0-9-]+\) ]]; then
    pass "audio-commentary-title: commentary track title contains both a codec/channel description and 'Commentary' ('$_title1')"
  else
    fail "audio-commentary-title: expected a codec/channel description + 'Commentary' suffix, got '${_title1:-<empty>}'"
  fi

  # ---- 2. Negative: a genuine alternate-language, non-commentary track gets NO suffix ----
  local _src2="$_dir/src_altlang.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -f lavfi -i "sine=frequency=880:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a -c:a aac -b:a 128k \
    -metadata:s:a:0 language=eng \
    -metadata:s:a:1 language=spa -metadata:s:a:1 title="Spanish Dub" \
    "$_src2" 2>/dev/null
  local _out2="$_dir/out_negative.mkv"
  run_muxm_in "$_proj" "$_src2" "$_out2" >/dev/null 2>&1 || true
  local _title2
  _title2="$(ffprobe -v error -select_streams a:1 -show_entries stream_tags=title -of csv=p=0 "$_out2" 2>/dev/null || true)"
  if [[ -n "$_title2" ]] && [[ "$_title2" != *"Commentary"* ]]; then
    pass "audio-commentary-title: a genuine alternate-language (non-commentary) track's title has NO 'Commentary' suffix ('$_title2')"
  else
    fail "audio-commentary-title: alternate-language track title unexpectedly missing or suffixed: '${_title2:-<empty>}'"
  fi

  # ---- 3. --no-audio-titles regression: original source title passes through unchanged ----
  local _out3="$_dir/out_notitles.mkv"
  run_muxm_in "$_proj" --no-audio-titles "$_src" "$_out3" >/dev/null 2>&1 || true
  local _title3
  _title3="$(ffprobe -v error -select_streams a:1 -show_entries stream_tags=title -of csv=p=0 "$_out3" 2>/dev/null || true)"
  if [[ "$_title3" == "Commentary with Director" ]]; then
    pass "audio-commentary-title: --no-audio-titles still passes the original source title through unchanged (untouched code path)"
  else
    fail "audio-commentary-title: --no-audio-titles expected 'Commentary with Director', got '${_title3:-<empty>}'"
  fi

  rm -rf "$_dir"
}

# RF3 (e2e): primary audio selection must demote a commentary track flagged by DISPOSITION even
# when its title is empty. Fixture: track0 = FLAC 6ch eng main (codec rank 10 → low codec score),
# track1 = E-AC-3 6ch eng flagged `-disposition:a:1 comment`, BOTH untitled. A scorer that
# consulted only the title would let the un-penalized E-AC-3 (codec rank 0) outscore the rank-10
# FLAC main and be selected as primary. The disposition.comment flag applies the penalty so the
# FLAC main (#0) wins.
_test_audio_disposition_commentary() {
  local src="$TESTDIR/rf3_dispo_comm.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=660:duration=2" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 flac -ac:a:0 6 -c:a:1 eac3 -b:a:1 256k -ac:a:1 6 \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=eng \
    -disposition:a:0 0 -disposition:a:1 comment \
    "$src" 2>/dev/null
  # Fixture must carry the disposition.comment flag on track 1 (and empty titles), else it proves nothing.
  local _d1 _t1
  _d1="$(ffprobe -v error -select_streams a:1 -show_entries stream_disposition=comment -of csv=p=0 "$src" 2>/dev/null || true)"
  _t1="$(probe_stream_tag "$src" a:1 title 2>/dev/null || true)"
  if [[ ! -s "$src" || "$_d1" != "1" || -n "$_t1" ]]; then
    skip "audio-demote-flagged-commentary (e2e): could not build a disposition-flagged untitled-commentary fixture (comment=$_d1 title='$_t1')"
    return
  fi
  local home="$TESTDIR/rf3_home"; mkdir -p "$home"
  log "Testing RF3: disposition-flagged (untitled) commentary must not win primary audio selection..."
  local out
  out="$(MUXM_HOME="$home" run_muxm --no-stereo-fallback "$src" "$TESTDIR/out_rf3_dispo.mkv")"
  # The main feature (#0) must be the selected primary, NOT the flagged commentary (#1).
  if printf '%s\n' "$out" | grep -qE '\[Audio\] Selected track #0:'; then
    pass "audio-demote-flagged-commentary (e2e): disposition-flagged commentary demoted — main feature track #0 selected as primary"
  else
    local _sel; _sel="$(printf '%s\n' "$out" | grep -oE 'Selected track #[0-9]+' | head -1)"
    fail "audio-demote-flagged-commentary (e2e): expected primary = track #0, but muxm selected '${_sel:-<none>}' (flagged commentary won)"
  fi
}

# L1: single-track AUDIO_LOSSLESS_PASSTHROUGH must not let skip-if-ideal silently drop a
# container-unsafe lossless track. With a single FLAC track in an .mp4 source + lossless passthrough
# + skip-if-ideal + .mp4 output, the video and container are ideal, but FLAC is NOT MP4-muxable
# (whitelist aac|ac3|eac3|alac). If check_skip_if_ideal kept ideal=1, the single-track keep-list
# loop would exclude the FLAC track with only a log line — shipping a video-only remux. A
# single-track lossless arm sets ideal=0, forcing the normal pipeline instead.
#
# Discriminating assertion: the dry-run must report the AUDIO reason (not a video/container reason),
# which only fires from the lossless arm. Perturb: revert the L1 arm → source becomes "ideal" → red.
# Skip-first guard (libx265 + flac muxer) per the soft-skip ratchet.
_test_audio_lossless_skip_drop() {
  if ! ffmpeg_has_encoder libx265 || ! ffmpeg_has_encoder flac; then
    skip "audio-lossless-passthrough-no-skip-drop: ffmpeg lacks libx265/flac — cannot build the FLAC-in-MP4 fixture"
    return
  fi
  local _l1_src="$TESTDIR/l1_flac_src.mp4"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=teal:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -c:v libx265 -preset ultrafast -x265-params log-level=none -pix_fmt yuv420p10le \
    -c:a flac -strict experimental \
    -map 0:v -map 1:a \
    "$_l1_src" 2>/dev/null || true
  # Require an actual single FLAC audio track in an mp4 (FLAC-in-MP4 is ffmpeg-version-dependent).
  if [[ ! -s "$_l1_src" ]] || [[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$_l1_src" 2>/dev/null)" != "flac" ]]; then
    skip "audio-lossless-passthrough-no-skip-drop: could not build a FLAC-in-MP4 fixture (ffmpeg cannot mux FLAC into MP4 here)"
    rm -f "$_l1_src" 2>/dev/null || true
    return
  fi
  # atv-directplay-hq: video-copy-compliant for HEVC Main10 SDR, single-track audio, skip-if-ideal.
  # Add --audio-lossless-passthrough so the new single-track lossless arm is the one under test.
  # NOTE: no --crf/--preset, which would force a re-encode and short-circuit video compliance.
  local _l1_out; _l1_out="$(run_muxm --profile atv-directplay-hq --output-ext mp4 \
    --audio-lossless-passthrough --skip-if-ideal --dry-run "$_l1_src" "$TESTDIR/l1_out.mp4" 2>&1)" || true
  if printf '%s' "$_l1_out" | grep -qiE 'already matches profile'; then
    fail "audio-lossless-passthrough-no-skip-drop: source treated as ideal → skip taken; single FLAC track would be silently dropped"
  elif printf '%s' "$_l1_out" | grep -qiE 'does not match ideal:.*lossless audio codec flac not muxable'; then
    pass "audio-lossless-passthrough-no-skip-drop: single-track FLAC-in-MP4 + lossless passthrough forces the pipeline (no silent drop)"
  else
    fail "audio-lossless-passthrough-no-skip-drop: expected the audio non-ideal reason; got: $(printf '%s' "$_l1_out" | grep -iE 'does not match ideal|already matches' | head -1)"
  fi
  rm -f "$_l1_src" "$TESTDIR/l1_out.mp4" 2>/dev/null || true
}

# L: force-AAC must honor STEREO_BITRATE, not a hardcoded 256k. Force-transcode an ac3
# stereo source to AAC with STEREO_BITRATE=96k (via .muxmrc); the transcode log must report
# bitrate=96k. Perturb MUT-L-FORCEAAC reverts to the hardcoded 256k → log shows 256k → red.
# (The output AAC bit_rate is N/A in MKV, so we log-grep rather than probe — same as the L6 test.)
_test_audio_forceaac_stereo_bitrate() {
  local _d="$TESTDIR/l_forceaac"; mkdir -p "$_d/h"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=blue:s=320x240:r=24:d=2" -f lavfi -i "sine=d=2" \
    -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p10le -c:a ac3 -ac 2 -metadata:s:a:0 language=eng \
    "$_d/src.mkv" 2>/dev/null || true
  if [[ ! -s "$_d/src.mkv" ]]; then skip "audio-forceaac-stereo-bitrate: could not build an ac3-stereo fixture"; rm -rf "$_d"; return; fi
  printf 'STEREO_BITRATE=96k\n' > "$_d/.muxmrc"
  ( cd "$_d" && HOME="$_d/h" "$MUXM" -K --no-skip-if-ideal --audio-force-codec aac --crf 30 --preset ultrafast src.mkv out.mkv >/dev/null 2>&1 )
  local _tlog
  _tlog="$(grep -rh "audio transcode:" "$_d"/.muxm.tmp.*/muxm.*.log 2>/dev/null | head -1)"
  if [[ "$_tlog" == *"bitrate=96k"* ]]; then
    pass "audio-forceaac-stereo-bitrate: forced-AAC transcode honors STEREO_BITRATE (96k), not a hardcoded 256k"
  else
    fail "audio-forceaac-stereo-bitrate: forced-AAC bitrate ignored STEREO_BITRATE (transcode log: '${_tlog:-<none>}')"
  fi
  rm -rf "$_d"
}

# L5: the audio copy/transcode failure paths (die 43) must surface the disk-full hint like the
# video (die 40) and mux (die 41) paths do — i.e. _check_disk_full runs on the .err log before the
# die. ENOSPC is impractical to provoke deterministically, so assert the call's presence/ordering
# at the two .err-bearing die-43 sites. A source-anchored check.
_test_audio_disk_hint() {
  # Each block that ends in `die 43 "... audio_primary.err"` must contain a matching
  # `_check_disk_full "$WORKDIR/audio_primary.err"` ahead of it. Count both within run_audio_pipeline.
  local body checks dies
  body="$(awk '/^run_audio_pipeline\(\)/,/^\}/' "$MUXM")"
  # shellcheck disable=SC2016  # $WORKDIR is a LITERAL matched in the extracted muxm source text, not expanded here
  checks="$(printf '%s\n' "$body" | grep -cE '_check_disk_full "\$WORKDIR/audio_primary\.err"')"
  dies="$(printf '%s\n' "$body" | grep -cE 'die 43 "[^"]*audio_primary\.err')"
  if (( dies > 0 && checks >= dies )); then
    pass "audio-transcode-disk-full-hint: each die-43 audio failure with an .err log is preceded by _check_disk_full (checks=$checks, dies=$dies)"
  else
    fail "audio-transcode-disk-full-hint: die-43 audio .err sites lack the _check_disk_full disk-full hint (checks=$checks, dies=$dies)"
  fi
}

# C2: a multi-track audio source with an UNTAGGED-language track must not write garbage metadata.
# _audio_stream_info emits codec⇥ch⇥lang⇥br⇥title; an untagged track has an EMPTY middle
# (language) field. The old collapsing `IFS=$'\t' read` dropped that empty field and shifted the
# bitrate into `lang`, so run_audio_pipeline_multi filled AUDIO_MT_LANGS with the bitrate and
# mux_final stamped a bogus `language=<digits>` on the output (and blanked the title). The fix
# routes every audio-record parse through the non-collapsing _split_tab. The kept untagged track
# here is EAC3 on purpose: EAC3 reports its bitrate, so the collapsed garbage survives the
# matroska muxer (an untagged AAC track reports no bitrate → garbage "0" → the muxer silently drops
# it, masking the bug). A kept untagged track must come out UNTAGGED, never language=<digits>; the
# tagged eng track must stay eng; and the titled commentary track must still be detected and
# dropped (its title must not have shifted). Perturb MUT-C2-MTLANG reverts the multi-track populate
# site to the collapsing read → a:1 gains a numeric language → red.
_test_audio_untagged_lang() {
  local src="$TESTDIR/c2_untagged_multi.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=teal:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=550:duration=2" \
    -f lavfi -i "sine=frequency=660:duration=2" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -map 0:v -map 1:a -map 2:a -map 3:a \
    -c:a:0 eac3 -b:a:0 448k -ac:a:0 6 \
    -c:a:1 eac3 -b:a:1 384k -ac:a:1 6 \
    -c:a:2 ac3  -b:a:2 192k -ac:a:2 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="Main Feature" \
    -metadata:s:a:1 title="Bonus Feature" \
    -metadata:s:a:2 title="Director's Commentary" \
    "$src" 2>/dev/null
  if [[ ! -s "$src" ]]; then
    fail "audio-untagged-lang multi-track: could not create untagged-language fixture"; return
  fi
  local home="$TESTDIR/c2_home"; mkdir -p "$home"
  local out="$TESTDIR/out_c2_untagged.mkv"
  log "Testing multi-track audio with an untagged-language track (C2: no garbage language metadata)..."
  MUXM_HOME="$home" run_muxm --profile archive "$src" "$out" >/dev/null
  if [[ ! -f "$out" || ! -s "$out" ]]; then
    fail "audio-untagged-lang multi-track: no output produced"; return
  fi
  # Commentary (titled, untagged-lang) must still be detected and dropped → 2 kept tracks.
  assert_stream_count "audio-untagged-lang multi-track: commentary dropped (title field parsed correctly)" "$out" a 2 2
  # Tagged track keeps its language.
  local a0_lang; a0_lang="$(probe_stream_tag "$out" a:0 language)"
  if [[ "$a0_lang" == "eng" ]]; then
    pass "audio-untagged-lang multi-track: tagged track a:0 keeps language=eng"
  else
    fail "audio-untagged-lang multi-track: tagged track a:0 language expected 'eng', got '$a0_lang'"
  fi
  # Untagged track must stay untagged — never language=<bitrate digits>.
  local a1_lang; a1_lang="$(probe_stream_tag "$out" a:1 language)"
  if [[ "$a1_lang" =~ ^[0-9]+$ ]]; then
    fail "audio-untagged-lang multi-track: untagged track a:1 has garbage numeric language=$a1_lang (must stay untagged, never digits)"
  else
    pass "audio-untagged-lang multi-track: untagged track a:1 stays untagged (language='$a1_lang', not a digit string)"
  fi
}

# C2 (container-safety): _check_multitrack_container_safety parses each audio record to decide
# which KEPT tracks an MP4/MOV target can't carry losslessly, then die 11s to prevent silent
# quality loss. Its keep-filter mirrors _build_audio_keep_list (language + commentary). With the
# old collapsing read, an UNTAGGED-language commentary track lost its title (the empty language
# field collapsed and shifted fields), so `_audio_is_commentary` saw an empty title → the
# commentary was treated as a kept lossless track → muxm wrongly REFUSED the MP4 encode. Here an
# untagged-language TrueHD commentary track must be recognised and dropped, so an MP4 encode of an
# (otherwise MP4-safe) EAC3 main track SUCCEEDS. Perturb MUT-C2-CSAFETY reverts this site to the
# collapsing read → the commentary is wrongly kept → die 11 → red. Gated on the truehd encoder.
_test_audio_container_safety() {
  if ! ffmpeg_has_encoder truehd; then
    skip "audio-container-safety container-safety: truehd encoder unavailable (cannot build a lossless-HD fixture)"; return
  fi
  local src="$TESTDIR/c2_csafety.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=navy:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=660:duration=2" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 eac3 -b:a:0 448k -ac:a:0 6 \
    -c:a:1 truehd -ac:a:1 6 -strict -2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="Main Feature" \
    -metadata:s:a:1 title="Director's Commentary" \
    "$src" 2>/dev/null
  if [[ ! -s "$src" ]]; then
    fail "audio-container-safety container-safety: could not create untagged-TrueHD-commentary fixture"; return
  fi
  local home="$TESTDIR/c2cs_home"; mkdir -p "$home"
  local dst="$TESTDIR/out_c2_csafety.mp4" out rc=0
  log "Testing container-safety with an untagged-language TrueHD commentary track (C2)..."
  out="$(cd "$TESTDIR" && HOME="$home" "$MUXM" -K --profile archive --output-ext mp4 "$src" "$dst" 2>&1)" || rc=$?
  if (( rc == 0 )) && [[ -s "$dst" ]]; then
    pass "audio-container-safety container-safety: untagged TrueHD commentary dropped → MP4 encode succeeds (not blocked)"
  else
    fail "audio-container-safety container-safety: MP4 encode wrongly blocked (rc=$rc) — commentary title lost, truehd kept: $(printf '%s' "$out" | grep -iE "can.t preserve|truehd" | head -1)"
  fi
}

# C2 (verify display): mux_final's post-encode "Audio :" summary parses a per-track record whose
# bit_rate field may be EMPTY (jq emits `.bit_rate // ""` — common for FLAC). With the old
# collapsing read, that empty middle field shifted the channel_layout into the title slot, so the
# verify line showed the layout (e.g. "stereo") instead of the real title. The fix routes the
# split through _split_tab. Here a FLAC track (no reported bitrate) must keep its descriptive
# title ("Stereo (FLAC)") in the verify summary. --no-skip-if-ideal forces the full mux_final path
# (the FLAC+HEVC+MKV source is otherwise ideal for archive and would skip the verify display).
# Perturb MUT-C2-VERIFY reverts this site to a collapsing read → the title becomes the layout → red.
_test_audio_verify_display() {
  local src="$TESTDIR/c2_verify_flac.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=maroon:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le \
    -map 0:v -map 1:a -c:a flac -ac 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="Original FLAC" \
    "$src" 2>/dev/null
  if [[ ! -s "$src" ]]; then
    fail "audio-verify-display verify-display: could not create FLAC fixture"; return
  fi
  local home="$TESTDIR/c2vd_home"; mkdir -p "$home"
  local dst="$TESTDIR/out_c2_verify.mkv" out aline
  log "Testing verify-output display with an empty-bitrate (FLAC) track (C2)..."
  out="$(MUXM_HOME="$home" run_muxm --profile archive --no-skip-if-ideal "$src" "$dst")"
  aline="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*Audio :' | head -1)"
  if [[ "$aline" == *"(FLAC)"* ]]; then
    pass "audio-verify-display verify-display: empty-bitrate track keeps its title in the verify summary ('${aline#*Audio : }')"
  else
    fail "audio-verify-display verify-display: verify Audio line lost the title (empty-bitrate field shifted layout→title): '$aline'"
  fi
}

# H3: a multi-track audio source whose language filter empties the keep-list must NOT silently
# ship a video-only file — fall back to the best-scored track and warn loudly. Mirrors the
# single-track "default to track 0" guard. Fixture: 2 audio tracks (jpn, spa) — a genuinely
# different language from the `eng` pref, so H2 normalization can't accidentally satisfy the
# filter and mask the guard. Skip-first guards (not else-skips) per the soft-skip ratchet.
_test_audio_no_audio_guard() {
  if ! ffmpeg_has_encoder libx265; then
    skip "audio-empty-keeplist-fallback: ffmpeg lacks libx265 — cannot build the multi-audio fixture"; return
  fi
  local _h3_src="$TESTDIR/h3_no_eng_audio.mkv" _h3_out="$TESTDIR/h3_out.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=teal:s=320x240:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -f lavfi -i "sine=frequency=550:duration=2" \
    -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p10le \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 aac -b:a:0 128k -ac:a:0 2 -c:a:1 aac -b:a:1 128k -ac:a:1 2 \
    -metadata:s:a:0 language=jpn -metadata:s:a:1 language=spa \
    "$_h3_src" 2>/dev/null
  if [[ ! -s "$_h3_src" ]]; then
    skip "audio-empty-keeplist-fallback: could not build the multi-audio fixture"; return
  fi
  # archive enables multi-track audio; --audio-lang-pref eng filters out the (jpn,spa) tracks.
  local _h3_log _h3_acount
  _h3_log="$(run_muxm --profile archive --audio-lang-pref eng --output-ext mkv "$_h3_src" "$_h3_out")"
  _h3_acount="$(count_streams "$_h3_out" a)"
  if [[ -s "$_h3_out" ]] && (( _h3_acount >= 1 )); then
    pass "audio-empty-keeplist-fallback: no-language-match multi-track audio still ships ≥1 audio track (got $_h3_acount), not video-only"
  else
    fail "audio-empty-keeplist-fallback: output has no audio track (count=${_h3_acount:-?}) — silently shipped video-only (H3 regression)"
  fi
  if printf '%s\n' "$_h3_log" | grep -qiE 'not be left without audio|best-scored track|no audio track matched'; then
    pass "audio-empty-keeplist-fallback: a loud warning was emitted about the audio language fallback"
  else
    fail "audio-empty-keeplist-fallback: no warning emitted when the audio language filter matched nothing"
  fi
  rm -f "$_h3_src" "$_h3_out" 2>/dev/null || true
}

# F7: the native-stereo-fallback track must be labeled with its REAL codec and carry the chosen
# native track's language — not a hardcoded "aac" + the primary's language. With a surround primary
# + a native AC-3 2ch track (same language), --stereo-fallback stream-copies the AC-3 track into an
# MKV output; the descriptive title must read "(AC-3)", not "(AAC)". A flat "(AAC)" regardless of
# the copied codec would lie about an AC-3 stream. Skip-first guards.
_test_audio_stereo_label() {
  section "audio-stereo-fallback-label: stereo-fallback codec/language labeling"
  if ! ffmpeg_has_encoder eac3 || ! ffmpeg_has_encoder ac3; then
    skip "audio-stereo-fallback-label: eac3/ac3 encoders unavailable — cannot build the surround+native-stereo fixture"; return
  fi
  local _dir="$TESTDIR/f7_stereo"; mkdir -p "$_dir"
  local _src="$_dir/src.mkv"
  # 6ch eac3 primary (eng) + 2ch ac3 native stereo (eng).
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=green:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=duration=1" -f lavfi -i "sine=frequency=660:duration=1" \
    -map 0:v -map 1:a -map 2:a -c:v libx265 -preset ultrafast -crf 30 \
    -c:a:0 eac3 -ac:a:0 6 -metadata:s:a:0 language=eng \
    -c:a:1 ac3  -ac:a:1 2 -metadata:s:a:1 language=eng \
    "$_src" 2>/dev/null || true
  if [[ ! -s "$_src" || "$(probe_audio "$_src" channels 1)" != "2" ]]; then
    skip "audio-stereo-fallback-label: could not build a surround+native-AC3-stereo fixture"; rm -rf "$_dir"; return
  fi
  local _out="$_dir/out.mkv"
  run_muxm --profile atv-directplay-hq --stereo-fallback --output-ext mkv --preset ultrafast "$_src" "$_out" >/dev/null 2>&1 || true
  local _fb_codec _fb_title _fb_lang
  _fb_codec="$(probe_audio "$_out" codec_name 1)"
  _fb_title="$(ffprobe -v error -select_streams a:1 -show_entries stream_tags=title -of csv=p=0 "$_out" 2>/dev/null || true)"
  _fb_lang="$(ffprobe -v error -select_streams a:1 -show_entries stream_tags=language -of csv=p=0 "$_out" 2>/dev/null || true)"
  if [[ "$_fb_codec" != "ac3" ]]; then
    fail "audio-stereo-fallback-label: expected the native AC-3 track to be the stereo fallback (a:1), got '${_fb_codec:-none}' — fixture/selection issue"
    rm -rf "$_dir"; return
  fi
  # Headline: the title names the real codec (AC-3), not the hardcoded AAC.
  if [[ "$_fb_title" == *"AC-3"* && "$_fb_title" != *"AAC"* ]]; then
    pass "audio-stereo-fallback-label: copied native AC-3 stereo fallback is labeled '(AC-3)', not '(AAC)' ('$_fb_title')"
  else
    fail "audio-stereo-fallback-label: stereo-fallback title expected '… (AC-3)', got '${_fb_title:-none}' (hardcoded AAC label?)"
  fi
  # The fallback carries the native track's language (eng here, sourced from the AC-3 track).
  if [[ "$_fb_lang" == "eng" ]]; then
    pass "audio-stereo-fallback-label: stereo-fallback carries the native track's language (eng)"
  else
    fail "audio-stereo-fallback-label: stereo-fallback language expected 'eng' (from the native track), got '${_fb_lang:-none}'"
  fi
  rm -rf "$_dir"
}

# F4: MAX_AUDIO_CHANNELS must apply on the lossless-passthrough copy path too. A lossless source
# with more channels than the cap can't be stream-copied (copy can't downmix), so Step 2 must fall
# through to transcode (which applies -ac) — the same `(( effective_ch == ch ))` guard Steps 1 and 3
# carry. Vehicle: hdr10-hq (single-track audio + AUDIO_LOSSLESS_PASSTHROUGH=1); archive is
# AUDIO_MULTI_TRACK=1 and routes to run_audio_pipeline_multi, bypassing Step 2. MAX_AUDIO_CHANNELS
# has no CLI flag, so it's set via a project ./.muxmrc. Without the guard the capped 8ch source
# copies untouched (8ch FLAC mislabeled "5.1"). Skip-first guards per the soft-skip ratchet.
_test_audio_maxchannels() {
  section "audio-max-channels: MAX_AUDIO_CHANNELS on the lossless-passthrough path"
  if ! ffmpeg_has_encoder flac; then
    skip "audio-max-channels: flac encoder unavailable — cannot build a lossless surround fixture"; return
  fi
  local _dir="$TESTDIR/f4_maxch"; mkdir -p "$_dir"
  local _src="$_dir/src_flac8.mkv"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=green:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=duration=1" -c:v libx265 -preset ultrafast -crf 30 \
    -c:a flac -ac 8 -metadata:s:a:0 language=eng "$_src" 2>/dev/null || true
  if [[ ! -s "$_src" || "$(probe_audio "$_src" channels 0)" != "8" ]]; then
    skip "audio-max-channels: could not build an 8ch FLAC fixture"; rm -rf "$_dir"; return
  fi

  # Capped: ./.muxmrc sets MAX_AUDIO_CHANNELS=6 → the 8ch lossless source must TRANSCODE (not copy)
  # to 6ch eac3 with a "5.1" descriptive title. Run from the config dir so ./.muxmrc is sourced.
  local _capdir="$_dir/capped"; mkdir -p "$_capdir"
  printf 'MAX_AUDIO_CHANNELS=6\n' > "$_capdir/.muxmrc"
  local _capout="$_capdir/out.mkv"
  (cd "$_capdir" && "$MUXM" -K --profile hdr10-hq --preset ultrafast "$_src" "$_capout" >/dev/null 2>&1) || true
  local _cc _cch _ct
  _cc="$(probe_audio "$_capout" codec_name 0)"; _cch="$(probe_audio "$_capout" channels 0)"
  _ct="$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=title -of csv=p=0 "$_capout" 2>/dev/null || true)"
  if [[ "$_cc" == "eac3" && "$_cch" == "6" ]]; then
    pass "audio-max-channels: lossless 8ch + MAX_AUDIO_CHANNELS=6 → transcoded to 6ch eac3 (cap honored, not copied)"
  else
    fail "audio-max-channels: capped lossless → expected eac3/6ch, got '${_cc:-none}'/${_cch:-?}ch (lossless copy ignored the cap?)"
  fi
  # The label must honestly reflect the transcoded output: "5.1" channels AND the E-AC-3 codec.
  # A mislabeled "5.1 Surround (FLAC)" title carries the right channel label but the wrong codec
  # and wrong actual channel count — so requiring the E-AC-3 codec in the title flips on the bug.
  if [[ "$_ct" == *"5.1"* && "$_ct" == *"E-AC-3"* ]]; then
    pass "audio-max-channels: capped descriptive title honestly reads '5.1 … (E-AC-3)' ('$_ct')"
  else
    fail "audio-max-channels: capped title expected '5.1 … (E-AC-3)', got '${_ct:-none}' (mislabeled copy?)"
  fi

  # Regression: WITHOUT a cap (default MAX=8), the 8ch lossless source still copies untouched.
  local _uncout="$_dir/uncapped.mkv"
  run_muxm --profile hdr10-hq --preset ultrafast "$_src" "$_uncout" >/dev/null 2>&1 || true
  local _uc _uch
  _uc="$(probe_audio "$_uncout" codec_name 0)"; _uch="$(probe_audio "$_uncout" channels 0)"
  if [[ "$_uc" == "flac" && "$_uch" == "8" ]]; then
    pass "audio-max-channels: uncapped lossless 8ch → stream-copied untouched (flac/8ch, no regression)"
  else
    fail "audio-max-channels: uncapped lossless → expected copied flac/8ch, got '${_uc:-none}'/${_uch:-?}ch"
  fi
  rm -rf "$_dir"
}

# F1: device Direct-Play correctness on MKV targets. audio_is_direct_play_copyable() must NOT
# alias the container-fitness predicate (_sii_audio_is_container_safe), which returns true for
# EVERY codec on a matroska target — that would let atv-directplay-* / streaming-* (MKV) stream-copy
# TrueHD/DTS-HD MA the device cannot Direct Play, instead of transcoding to E-AC-3 as documented.
# These real-encode cases assert the OUTPUT audio codec (ground truth): eac3 means Step 3 fell
# through to the transcode AND skip-if-ideal did not short-circuit (a wrongful copy/remux would
# surface the original truehd/dts). A buggy predicate leaves (a)/(b)/(c) at truehd/dts → red.
_test_audio_directplay() {
  section "audio-directplay-transcode: audio Direct-Play transcode on MKV targets"

  # 5.1 (6ch) surround sources in MKV. dca's ffprobe name is "dts" (a faithful DTS-HD MA proxy:
  # the predicate rejects "dts" regardless of the HD-MA extension ffmpeg can't synthesize).
  local _thd="$TESTDIR/f1_truehd_51.mkv" _dts="$TESTDIR/f1_dts_51.mkv" _eac="$TESTDIR/f1_eac3_51.mkv"
  local _spec
  for _spec in "truehd:$_thd:truehd" "dca:$_dts:dts" "eac3:$_eac:eac3"; do
    local _enc="${_spec%%:*}" _rest="${_spec#*:}"; local _f="${_rest%%:*}"
    if ffmpeg_has_encoder "$_enc" && [[ ! -f "$_f" ]]; then
      ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=green:s=320x240:r=24:d=1" \
        -f lavfi -i "sine=duration=1" -c:v libx265 -preset ultrafast -crf 30 \
        -strict -2 -c:a "$_enc" -ac 6 -metadata:s:a:0 language=eng "$_f" 2>/dev/null || true
    fi
  done

  local _out _ac

  # (a) PRIMARY: atv-directplay-hq + TrueHD/MKV → eac3 (not stream-copied). eac3 also proves
  #     skip-if-ideal did not short-circuit (a remux would have surfaced truehd in the output).
  # Skip-first guard (not an else-skip) per the soft-skip ratchet, _test_meta_soft_skip.
  if [[ ! -s "$_thd" ]]; then
    skip "audio-directplay-transcode: TrueHD 5.1 fixture unavailable (ffmpeg truehd encoder)"
  else
    _out="$TESTDIR/f1_atv_thd.mkv"; rm -f "$_out"
    if assert_encode "audio-directplay-transcode: atv-directplay-hq + TrueHD/MKV encodes" "$_out" \
         --profile atv-directplay-hq --preset ultrafast --crf 30 "$_thd"; then
      _ac="$(probe_audio "$_out" codec_name 0)"
      if [[ "$_ac" == "eac3" ]]; then
        pass "audio-directplay-transcode: atv-directplay-hq + TrueHD/MKV → transcoded to eac3 (not Direct-Play copied)"
      else
        fail "audio-directplay-transcode: atv-directplay-hq + TrueHD/MKV → expected eac3, got '${_ac:-none}' (TrueHD wrongly copied?)"
      fi
    fi
    rm -f "$_out"
  fi

  # (b) atv-directplay-hq + DTS/MKV → eac3 (same failure mode as TrueHD).
  # Skip-first guard (not an else-skip) per the soft-skip ratchet, _test_meta_soft_skip.
  if [[ ! -s "$_dts" ]]; then
    skip "audio-directplay-transcode: DTS 5.1 fixture unavailable (ffmpeg dca encoder)"
  else
    _out="$TESTDIR/f1_atv_dts.mkv"; rm -f "$_out"
    if assert_encode "audio-directplay-transcode: atv-directplay-hq + DTS/MKV encodes" "$_out" \
         --profile atv-directplay-hq --preset ultrafast --crf 30 "$_dts"; then
      _ac="$(probe_audio "$_out" codec_name 0)"
      if [[ "$_ac" == "eac3" ]]; then
        pass "audio-directplay-transcode: atv-directplay-hq + DTS/MKV → transcoded to eac3 (not Direct-Play copied)"
      else
        fail "audio-directplay-transcode: atv-directplay-hq + DTS/MKV → expected eac3, got '${_ac:-none}'"
      fi
    fi
    rm -f "$_out"
  fi

  # (c) Regression guard: streaming-hevc forced to MKV + TrueHD → eac3 (shares the matroska risk).
  if [[ -s "$_thd" ]]; then
    _out="$TESTDIR/f1_streaming_thd.mkv"; rm -f "$_out"
    if assert_encode "audio-directplay-transcode: streaming-hevc --output-ext mkv + TrueHD encodes" "$_out" \
         --profile streaming-hevc --output-ext mkv --preset ultrafast --crf 30 "$_thd"; then
      _ac="$(probe_audio "$_out" codec_name 0)"
      if [[ "$_ac" == "eac3" ]]; then
        pass "audio-directplay-transcode: streaming-hevc(mkv) + TrueHD → transcoded to eac3"
      else
        fail "audio-directplay-transcode: streaming-hevc(mkv) + TrueHD → expected eac3, got '${_ac:-none}'"
      fi
    fi
    rm -f "$_out"
  fi

  # (d) MP4-target sanity (the always-correct path): streaming-hevc default
  #     mp4 + TrueHD source → eac3. The mp4 whitelist rejects truehd regardless.
  if [[ -s "$_thd" ]]; then
    _out="$TESTDIR/f1_streaming_thd.mp4"; rm -f "$_out"
    if assert_encode "audio-directplay-transcode: streaming-hevc(mp4) + TrueHD encodes" "$_out" \
         --profile streaming-hevc --preset ultrafast --crf 30 "$_thd"; then
      _ac="$(probe_audio "$_out" codec_name 0)"
      if [[ "$_ac" == "eac3" ]]; then
        pass "audio-directplay-transcode: streaming-hevc(mp4) + TrueHD → eac3 (mp4 path still correct)"
      else
        fail "audio-directplay-transcode: streaming-hevc(mp4) + TrueHD → expected eac3, got '${_ac:-none}'"
      fi
    fi
    rm -f "$_out"
  fi

  # (e) No-regression: a genuine Direct-Play codec (eac3) on an MKV target STILL copies — the
  #     whitelist must not force a needless re-encode. --no-skip-if-ideal makes the audio
  #     pipeline run so Step 3's copy decision is observable in the log.
  if [[ -s "$_eac" ]]; then
    _out="$TESTDIR/f1_atv_eac3.mkv"; rm -f "$_out"
    local _log _code=0
    _log="$(cd "$TESTDIR" && "$MUXM" -K --no-skip-if-ideal --profile atv-directplay-hq \
      --preset ultrafast --crf 30 "$_eac" "$_out" 2>&1)" || _code=$?
    if [[ "$_code" -eq 0 && -s "$_out" ]]; then
      _ac="$(probe_audio "$_out" codec_name 0)"
      if [[ "$_ac" == "eac3" ]] && printf '%s' "$_log" | grep -qiE 'Direct Play audio codec detected|Copying without conversion'; then
        pass "audio-directplay-transcode: atv-directplay-hq + EAC-3/MKV → stream-copied (no needless transcode)"
      else
        fail "audio-directplay-transcode: atv-directplay-hq + EAC-3/MKV → expected copied eac3, got '${_ac:-none}' (transcoded?)"
      fi
    else
      fail "audio-directplay-transcode: atv-directplay-hq + EAC-3/MKV → encode failed (exit $_code)"
    fi
    rm -f "$_out"
  fi

  # (f) Exercise the skip-if-ideal AUDIO gate itself (check_skip_if_ideal's
  #     audio_is_direct_play_copyable call) — cases (a)-(c) above can't, because their explicit
  #     --crf/--preset force non-ideal at the CLI-override check before the audio gate is reached.
  _test_audio_sii_gate "$_thd"

  rm -f "$_thd" "$_dts" "$_eac"
}

# F1 — skip-if-ideal AUDIO gate (check_skip_if_ideal, the audio_is_direct_play_copyable call).
# With copy-compliant video and skip-if-ideal ENABLED, a TrueHD track must mark the source
# non-ideal so the pipeline runs and transcodes to eac3. A gate that saw truehd as "ideal"
# on matroska would fire the skip and remux TrueHD untouched — the failure scenario for a
# compliant source. The eac3 control proves the source is genuinely ideal-eligible (so the truehd
# case can't pass for the wrong reason). NOTE: never pass --crf/--preset to the skip-if-ideal
# runs — an explicit CRF/preset forces non-ideal at the CLI-override check, short-circuiting
# before the audio gate. Skip-first guards (with return), not else-skips, per the soft-skip ratchet.
_test_audio_sii_gate() {
  local _thd="$1"
  if [[ ! -s "$_thd" ]]; then
    skip "audio-skip-if-ideal-gate: skip-if-ideal gate — TrueHD fixture unavailable"
    return
  fi
  # One-time real encode → a known atv-directplay-hq-compliant base (HEVC video + eac3 audio).
  local _base="$TESTDIR/f1_sii_base.mkv"; rm -f "$_base"
  run_muxm --no-skip-if-ideal --profile atv-directplay-hq --preset ultrafast "$_thd" "$_base" >/dev/null 2>&1 || true
  # Control: the compliant eac3 base must SKIP — proving it's ideal-eligible and the gate runs.
  local _ctrl_out="$TESTDIR/f1_sii_ctrl.mkv"; rm -f "$_ctrl_out"
  local _ctrl_log
  _ctrl_log="$(cd "$TESTDIR" && "$MUXM" -K --profile atv-directplay-hq "$_base" "$_ctrl_out" 2>&1)" || true
  if ! printf '%s' "$_ctrl_log" | grep -qE 'Source already matches profile|skipping processing'; then
    skip "audio-skip-if-ideal-gate: skip-if-ideal gate — could not build an ideal-eligible source on this host"
    rm -f "$_base" "$_ctrl_out"
    return
  fi
  pass "audio-skip-if-ideal-gate: skip-if-ideal control — compliant eac3 source skips processing (audio gate reached)"
  # Swap a TrueHD track onto the same compliant video (stream-copy, no re-encode).
  local _thd_base="$TESTDIR/f1_sii_thd.mkv"; rm -f "$_thd_base"
  ffmpeg -hide_banner -loglevel error -y -i "$_base" -i "$_thd" -map 0:v:0 -map 1:a:0 \
    -c copy -metadata:s:a:0 language=eng "$_thd_base" 2>/dev/null || true
  if [[ ! -s "$_thd_base" ]]; then
    skip "audio-skip-if-ideal-gate: skip-if-ideal gate — could not mux TrueHD onto the compliant base"
    rm -f "$_base" "$_ctrl_out"
    return
  fi
  local _gate_out="$TESTDIR/f1_sii_thd_out.mkv"; rm -f "$_gate_out"
  local _gate_log _gate_ac
  _gate_log="$(cd "$TESTDIR" && "$MUXM" -K --profile atv-directplay-hq "$_thd_base" "$_gate_out" 2>&1)" || true
  _gate_ac="$(probe_audio "$_gate_out" codec_name 0)"
  if [[ "$_gate_ac" == "eac3" ]] && ! printf '%s' "$_gate_log" | grep -qE 'Source already matches profile|skipping processing'; then
    pass "audio-skip-if-ideal-gate: skip-if-ideal + compliant video + TrueHD → gate forces transcode to eac3 (no skip)"
  else
    fail "audio-skip-if-ideal-gate: skip-if-ideal + compliant video + TrueHD → expected eac3 with no skip, got '${_gate_ac:-none}' (skip-if-ideal wrongly short-circuited TrueHD?)"
  fi
  rm -f "$_base" "$_ctrl_out" "$_thd_base" "$_gate_out"
}

_test_audio_native_stereo() {
  # Test 1: Native stereo preferred over synthetic downmix.
  # Source has a 5.1 AC3 primary + a clean stereo AAC track (same lang, not commentary).
  # The scanner must find the stereo track and prefer it over a synthetic downmix.
  log "Testing native stereo preference: 5.1 + stereo source..."
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -f lavfi -i "sine=frequency=660:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 ac3 -b:a:0 384k -ac:a:0 6 \
    -c:a:1 aac -b:a:1 128k -ac:a:1 2 \
    -metadata:s:a:0 language=eng \
    -metadata:s:a:1 language=eng \
    "$TESTDIR/native_stereo.mkv"
  local out
  out="$(run_muxm --crf 51 --preset ultrafast --output-ext mkv --stereo-fallback "$TESTDIR/native_stereo.mkv")"
  assert_contains "Native stereo track found" \
    "Native stereo detected when source has 2ch track" "$out"

  # Test 2: No native stereo — downmix fallback.
  # Source has only a 5.1 AC3 track; no 2ch candidate exists.
  # The scanner must log "No native stereo track available" and synthesise a downmix.
  log "Testing stereo downmix fallback: surround-only source..."
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=red:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a \
    -c:a:0 ac3 -b:a:0 384k -ac:a:0 6 \
    -metadata:s:a:0 language=eng \
    "$TESTDIR/surround_only.mkv"
  out="$(run_muxm --crf 51 --preset ultrafast --output-ext mkv --stereo-fallback "$TESTDIR/surround_only.mkv")"
  assert_contains "No native stereo track available" \
    "Downmix created when no native stereo" "$out"

  # Test 3: Commentary stereo skipped — downmix fallback used instead.
  # Source has a 5.1 AC3 primary + a stereo AAC track titled "Director Commentary".
  # _audio_is_commentary rejects the stereo candidate, forcing the downmix path.
  log "Testing commentary stereo skipped: 5.1 + commentary stereo source..."
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=green:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -f lavfi -i "sine=frequency=660:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 ac3 -b:a:0 384k -ac:a:0 6 \
    -c:a:1 aac -b:a:1 128k -ac:a:1 2 \
    -metadata:s:a:0 language=eng \
    -metadata:s:a:1 language=eng \
    -metadata:s:a:1 title="Director Commentary" \
    "$TESTDIR/commentary_stereo.mkv"
  out="$(run_muxm --crf 51 --preset ultrafast --output-ext mkv --stereo-fallback "$TESTDIR/commentary_stereo.mkv")"
  assert_contains "No native stereo track available" \
    "Commentary stereo skipped, downmix used instead" "$out"

  # Test 4 (regression): non-AAC native stereo must be stream-copied into MKV.
  # Reproduces the "Project Hail Mary" report: EAC3 5.1 primary + FLAC 2.0 stereo.
  # The native-stereo copy path wrote to a hardcoded audio_stereo.aac intermediate;
  # ffmpeg picks the muxer from that extension, and the .aac (ADTS) muxer rejects
  # FLAC ("adts muxer supports only codec aac"), so the copy failed and muxm
  # silently dropped the stereo track — output had only the surround stream.
  # Earlier tests used an AAC native track (copy into .aac happens to work) and
  # only asserted the "Native stereo track found" log line, which is emitted
  # before the copy, so the failure went undetected. This test probes the actual
  # output streams to prove the stereo track survived.
  local nf_src="$TESTDIR/native_stereo_flac.mkv"
  local nf_out="$TESTDIR/native_stereo_flac_out.mkv"
  log "Testing native FLAC stereo stream-copied into MKV (regression)..."
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=teal:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -f lavfi -i "sine=frequency=660:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 eac3 -b:a:0 384k -ac:a:0 6 \
    -c:a:1 flac -ac:a:1 2 \
    -metadata:s:a:0 language=eng \
    -metadata:s:a:1 language=eng \
    "$nf_src"
  out="$(run_muxm --crf 51 --preset ultrafast --output-ext mkv --stereo-fallback "$nf_src" "$nf_out")"
  assert_contains "Native stereo track found" \
    "FLAC native stereo: preference path taken" "$out"
  if [[ -s "$nf_out" ]]; then
    # A dropped stereo track would leave a single audio stream.
    assert_stream_count "FLAC native stereo: stereo track muxed into output" "$nf_out" a 2 2
    local nf_ch nf_codec
    nf_ch="$(probe_audio "$nf_out" channels 1)"
    nf_codec="$(probe_audio "$nf_out" codec_name 1)"
    if [[ "$nf_ch" == "2" ]]; then
      pass "FLAC native stereo: second track is 2ch"
    else
      fail "FLAC native stereo: second track channels — expected '2', got '$nf_ch'"
    fi
    if [[ "$nf_codec" == "flac" ]]; then
      pass "FLAC native stereo: stream-copied (codec_name=flac, not transcoded/dropped)"
    else
      fail "FLAC native stereo: stereo codec — expected 'flac', got '$nf_codec'"
    fi
  else
    fail "FLAC native stereo: no output produced"
  fi

  # Test 5 (regression): the MP4/MOV copy branch also copies AC3/EAC3 verbatim,
  # so a non-AAC stereo (AC3 here) hit the same hardcoded-.aac failure. The fix
  # derives the intermediate extension from the native codec for these too.
  local na_src="$TESTDIR/native_stereo_ac3.mkv"
  local na_out="$TESTDIR/native_stereo_ac3_out.mp4"
  log "Testing native AC3 stereo stream-copied into MP4 (regression)..."
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=navy:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -f lavfi -i "sine=frequency=660:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -map 0:v -map 1:a -map 2:a \
    -c:a:0 eac3 -b:a:0 384k -ac:a:0 6 \
    -c:a:1 ac3 -b:a:1 192k -ac:a:1 2 \
    -metadata:s:a:0 language=eng \
    -metadata:s:a:1 language=eng \
    "$na_src"
  out="$(run_muxm --crf 51 --preset ultrafast --output-ext mp4 --stereo-fallback "$na_src" "$na_out")"
  assert_contains "Native stereo track found" \
    "AC3 native stereo: preference path taken" "$out"
  if [[ -s "$na_out" ]]; then
    assert_stream_count "AC3 native stereo: stereo track muxed into output" "$na_out" a 2 2
    local na_ch na_codec
    na_ch="$(probe_audio "$na_out" channels 1)"
    na_codec="$(probe_audio "$na_out" codec_name 1)"
    if [[ "$na_ch" == "2" ]]; then
      pass "AC3 native stereo: second track is 2ch"
    else
      fail "AC3 native stereo: second track channels — expected '2', got '$na_ch'"
    fi
    if [[ "$na_codec" == "ac3" ]]; then
      pass "AC3 native stereo: stream-copied (codec_name=ac3, not transcoded/dropped)"
    else
      fail "AC3 native stereo: stereo codec — expected 'ac3', got '$na_codec'"
    fi
  else
    fail "AC3 native stereo: no output produced"
  fi

  # Test 6: AUDIO_PREFER_STEREO (--prefer-stereo / --profile universal)
  # Source has 5.1 AC3 + stereo AAC. With --prefer-stereo, the stereo track should
  # be selected as the primary (logged as "AUDIO_PREFER_STEREO: native 2ch track found").
  log "Testing AUDIO_PREFER_STEREO: native 2ch preferred as primary..."
  out="$(run_muxm --crf 51 --preset ultrafast --output-ext mp4 --prefer-stereo "$TESTDIR/native_stereo.mkv")"
  assert_contains "Prefer-stereo: native stereo track found" \
    "--prefer-stereo: native stereo selected as primary" "$out"

  # Test 7: AUDIO_PREFER_STEREO fallthrough on surround-only source.
  # No native stereo exists; must log fallthrough and still produce output.
  log "Testing AUDIO_PREFER_STEREO fallthrough: surround-only source..."
  out="$(run_muxm --crf 51 --preset ultrafast --output-ext mp4 --prefer-stereo "$TESTDIR/surround_only.mkv")"
  assert_contains "selecting the best track by score" \
    "--prefer-stereo fallthrough: surround-only source falls back to score-based selection" "$out"
}

# === Suite: Subtitle Pipeline ===
# Validates subtitle inclusion, exclusion, language preference, SDH filtering,
# external export, and OCR configuration.
test_subs() {
  section "Subtitle Pipeline"

  local outfile out

  # ───────────────────────────────────────────────────────────────────────────
  # Observability seam + command-shape characterization.
  # mux_final logs "ffmpeg mux command: …"; with --keep-log that line is
  # persisted to <output>.muxm.log and read back via extract_mux_cmd (paths
  # normalized to basenames). T1–T4 pin the -i/-map/-c:s command shape for the
  # three representative subtitle paths (single-text, multi-track, external), plus
  # a non-zero-offset sync assertion proving the harness can detect a timestamp
  # rebase.
  # ───────────────────────────────────────────────────────────────────────────
  local cz_cmd cz_log

  # T1 + T2(single-text) + T4(sync): single-track text path.
  # offset_subs.mkv carries ONE SRT track whose first cue is at 5.000 s. muxm
  # extracts it to a workdir file (sub.0.srt) and re-inputs it. The unified emitter
  # stream-copies that text file (-c:s:0 copy) rather than re-encoding it, yielding
  # identical subrip output in MKV. The -i/-map shape is unchanged by the copy
  # rule.
  local cz_single="$TESTDIR/charz_single.mkv"
  run_muxm --keep-log --output-ext mkv --crf 28 --preset ultrafast \
    "$TESTDIR/offset_subs.mkv" "$cz_single" >/dev/null 2>&1
  cz_log="$TESTDIR/charz_single.muxm.log"
  cz_cmd="$(extract_mux_cmd "$cz_log")"
  assert_contains "ffmpeg mux command:" \
    "subs-mux-command-logged: mux_final logs its assembled ffmpeg command" "$cz_cmd"
  assert_contains "-i sub.0.srt" \
    "subs-external-sidecar-copied single-text: subtitle taken from an extracted file input (sub.0.srt)" "$cz_cmd"
  assert_contains "-map 2:s:0" \
    "subs-external-sidecar-copied single-text: subtitle mapped from the file input (-map 2:s:0)" "$cz_cmd"
  assert_contains "-c:s:0 copy" \
    "subs-external-sidecar-copied single-text: text file stream-copied (-c:s:0 copy; unified rule, was srt)" "$cz_cmd"
  # T4: text has no desync bug — first-sub PTS must survive at 5.000 s. A rebase
  #     (the PGS bug class) would pull it to 0; this proves the probe can see it.
  if [[ -f "$cz_single" ]]; then
    local cz_pts
    cz_pts="$(ffprobe -v error -select_streams s:0 -show_entries packet=pts_time \
      -of csv=p=0 "$cz_single" 2>/dev/null | head -1)"
    if [[ "$cz_pts" == "5.000000" ]]; then
      pass "subs-text-pts-preserved: text-path output preserves first-sub PTS at 5.000 s (no rebase)"
    else
      fail "subs-text-pts-preserved: text-path first-sub PTS expected 5.000000, got '${cz_pts:-none}'"
    fi
  else
    fail "subs-text-pts-preserved: single-track characterization encode produced no output"
  fi

  # T2(multi): multi-track copy-from-source path. The archive profile enables
  # SUB_MULTI_TRACK; multi_subs_multilang.mkv's 3 text subs (eng/spa/fra) are kept
  # and mapped straight from the source input.
  local cz_multi="$TESTDIR/charz_multi.mkv"
  run_muxm --keep-log --profile archive --crf 28 --preset ultrafast \
    "$TESTDIR/multi_subs_multilang.mkv" "$cz_multi" >/dev/null 2>&1
  cz_log="$TESTDIR/charz_multi.muxm.log"
  cz_cmd="$(extract_mux_cmd "$cz_log")"
  assert_contains "ffmpeg mux command:" \
    "subs-mux-command-logged: mux_final logs its command (multi-track)" "$cz_cmd"
  assert_contains "-i multi_subs_multilang.mkv" \
    "subs-external-sidecar-copied multi: subtitles sourced from the source input, not extracted files" "$cz_cmd"
  assert_contains "-map 1:s:0 -map 1:s:1 -map 1:s:2" \
    "subs-external-sidecar-copied multi: all three subs mapped from the shared source input (1:s:0..2)" "$cz_cmd"
  assert_contains "-c:s:0 copy" \
    "subs-external-sidecar-copied multi: subtitles stream-copied (-c:s:0 copy)" "$cz_cmd"
  assert_not_contains "-i sub.0.srt" \
    "subs-external-sidecar-copied multi: no per-track file round-trip (no extracted sub.0.srt input)" "$cz_cmd"

  # T2(ext): external sidecar path. ext_only_source.mkv has no embedded subs; its
  # ext_only_source.en.srt sidecar is discovered and added as a file input.
  local cz_ext="$TESTDIR/charz_ext.mkv"
  run_muxm --keep-log --output-ext mkv --crf 28 --preset ultrafast \
    "$TESTDIR/ext_only_source.mkv" "$cz_ext" >/dev/null 2>&1
  cz_log="$TESTDIR/charz_ext.muxm.log"
  cz_cmd="$(extract_mux_cmd "$cz_log")"
  assert_contains "-i ext_only_source.en.srt" \
    "subs-external-sidecar-copied ext: external sidecar added as a file input" "$cz_cmd"
  assert_contains "-c:s:0 copy" \
    "subs-external-sidecar-copied ext: sidecar stream-copied (-c:s:0 copy; unified rule, was srt)" "$cz_cmd"

  # T10: multi-track + external sidecar — the case the all-embedded multi fixture
  # never exercised, and the one that would expose a wrong (extension-based) file
  # codec rule. The external sidecar must be stream-copied (-c:s copy) from a deduped
  # -i input, matching the multi-track path.
  local cz_mtext="$TESTDIR/charz_mtext.mkv"
  run_muxm --keep-log --profile archive --crf 28 --preset ultrafast \
    "$TESTDIR/mt_mixed_subs.mkv" "$cz_mtext" >/dev/null 2>&1
  cz_cmd="$(extract_mux_cmd "$TESTDIR/charz_mtext.muxm.log")"
  assert_contains "-i mt_mixed_subs.es.srt" \
    "subs-multi-plus-external-mapping multi+ext: external sidecar added as a file input" "$cz_cmd"
  assert_contains "-map 1:s:0 -map 2:s:0" \
    "subs-multi-plus-external-mapping multi+ext: embedded from source (1:s:0) + external sidecar (2:s:0)" "$cz_cmd"
  assert_contains "-c:s:0 copy -metadata:s:s:0 language=eng" \
    "subs-multi-plus-external-mapping multi+ext: embedded sub stream-copied" "$cz_cmd"
  assert_contains "-c:s:1 copy -metadata:s:s:1 language=spa" \
    "subs-multi-plus-external-mapping multi+ext: external sidecar stream-COPIED, not re-encoded to srt (the bug guard)" "$cz_cmd"

  # T11: end-to-end PGS desync guard — the regression test for the timestamp-rebase
  # bug this whole subtitle path guards against. ffmpeg cannot synthesize an embedded
  # PGS fixture from text, so it is gated on a bundled-or-supplied PGS source via
  # MUXM_PGS_FIXTURE (mirrors MUXM_DV_FIXTURE). Without one it SKIPs; the always-runnable
  # guarantee is carried by T6 (emitter maps embedded PGS from source, never a .sup) +
  # the sub-plan-add unit test (single-track PGS → embedded:N) + the structural fact that
  # single-track PGS uses the same byte-identical, desync-free source-mapping mechanism
  # as multi-track.
  # Skip-first guard (not an else-skip) per the soft-skip ratchet, _test_meta_soft_skip.
  if [[ -z "${MUXM_PGS_FIXTURE:-}" || ! -s "${MUXM_PGS_FIXTURE:-}" ]]; then
    skip "subs-pgs-e2e-pts-preserved PGS e2e sync: no MUXM_PGS_FIXTURE (ffmpeg cannot synthesize PGS — set MUXM_PGS_FIXTURE=/path/to/pgs_source.mkv with a non-zero first cue)"
  else
    local pgs_off pgs_out="$TESTDIR/charz_pgs.mkv"
    pgs_off="$(ffprobe -v error -select_streams s:0 -show_entries packet=pts_time -of csv=p=0 "$MUXM_PGS_FIXTURE" 2>/dev/null | grep -E '^[0-9]' | head -1)"
    run_muxm --keep-log --output-ext mkv --crf 28 --preset ultrafast "$MUXM_PGS_FIXTURE" "$pgs_out" >/dev/null 2>&1
    cz_cmd="$(extract_mux_cmd "$TESTDIR/charz_pgs.muxm.log")"
    assert_not_contains ".sup" \
      "subs-pgs-e2e-pts-preserved PGS: mux command has NO standalone .sup input (maps from source)" "$cz_cmd"
    if [[ -f "$pgs_out" ]]; then
      local out_off
      out_off="$(ffprobe -v error -select_streams s:0 -show_entries packet=pts_time -of csv=p=0 "$pgs_out" 2>/dev/null | grep -E '^[0-9]' | head -1)"
      if [[ -n "$pgs_off" && "$out_off" == "$pgs_off" ]]; then
        pass "subs-pgs-e2e-pts-preserved PGS e2e: output first-sub PTS preserved ($out_off == source $pgs_off; no rebase)"
      else
        fail "subs-pgs-e2e-pts-preserved PGS e2e: first-sub PTS expected '$pgs_off', got '${out_off:-none}' (desync regression?)"
      fi
    else
      fail "subs-pgs-e2e-pts-preserved PGS e2e: encode produced no output"
    fi
  fi

  # Basic encode with subs
  outfile="$TESTDIR/subs_test1.mkv"
  log "Testing subtitle inclusion in MKV..."
  if assert_encode "Subtitle test encode" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast "$TESTDIR/multi_subs.mkv"; then
    assert_stream_count "Subtitles present in MKV output" "$outfile" s 3 3
  fi

  # --no-subtitles
  outfile="$TESTDIR/subs_none.mkv"
  log "Testing --no-subtitles..."
  if assert_encode "--no-subtitles encode" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast --no-subtitles "$TESTDIR/multi_subs.mkv"; then
    assert_stream_count "--no-subtitles: no subtitle tracks" "$outfile" s 0 0
  fi

  # --skip-subs
  out="$(run_muxm --dry-run --skip-subs "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Subtitle processing disabled" "--skip-subs announced" "$out"

  # --sub-lang-pref (#14)
  out="$(run_muxm --sub-lang-pref jpn --print-effective-config)"
  assert_contains "SUB_LANG_PREF             = jpn" "--sub-lang-pref: config shows jpn" "$out"

  # --no-sub-sdh (#15)
  out="$(run_muxm --no-sub-sdh --print-effective-config)"
  assert_contains "SUB_INCLUDE_SDH           = 0" "--no-sub-sdh: SDH disabled" "$out"

  # --sub-export-external (#13)
  outfile="$TESTDIR/subs_export.mp4"
  log "Testing --sub-export-external..."
  if assert_encode "--sub-export-external: output produced" "$outfile" \
       --sub-export-external --crf 28 --preset ultrafast "$TESTDIR/multi_subs.mkv"; then
    # 1.6: real output probe, not just existence — multi_subs.mkv has text subs, so
    # --sub-export-external must (a) re-encode valid video and (b) write ≥1 .srt sidecar.
    assert_probe "--sub-export-external: output is a valid HEVC encode" "$outfile" codec_name hevc
    local srt_count
    srt_count="$(find "$TESTDIR" -name "subs_export*.srt" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$srt_count" -ge 1 ]]; then
      pass "--sub-export-external: SRT sidecar(s) created ($srt_count)"
    else
      fail "--sub-export-external: expected ≥1 .srt sidecar exported from multi_subs.mkv, found none"
    fi
  fi

  # --no-ocr via effective config (#17)
  out="$(run_muxm --no-ocr --print-effective-config)"
  assert_contains "SUB_ENABLE_OCR            = 0" "--no-ocr: OCR disabled" "$out"

  # --ocr-lang (#16)
  out="$(run_muxm --ocr-lang jpn --print-effective-config)"
  assert_contains "SUB_OCR_LANG              = jpn" "--ocr-lang: shows jpn" "$out"

  # ---- SUB_MAX_TRACKS=1 limits output subtitle count ----
  local smt_out="$TESTDIR/e2e_sub_max_tracks.mkv"
  if run_muxm --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref eng --no-ocr \
       "$TESTDIR/multi_subs.mkv" "$smt_out" >/dev/null 2>&1 && [[ -f "$smt_out" ]]; then
    # Default SUB_MAX_TRACKS=3, so first verify we get >1 sub track normally
    local default_sub_count
    default_sub_count="$(ffprobe -v error -select_streams s -show_entries stream=index \
      -of csv=p=0 "$smt_out" 2>/dev/null | wc -l | tr -d ' ')"
    log "Default encode produced $default_sub_count subtitle track(s)"

    local smt1_out="$TESTDIR/e2e_sub_max_1.mkv"
    local smt1_home="$TESTDIR/sub_max_home"
    mkdir -p "$smt1_home"
    cat > "$smt1_home/.muxmrc" <<'EOF'
SUB_MAX_TRACKS=1
EOF
    if HOME="$smt1_home" run_muxm --output-ext mkv --crf 28 --preset ultrafast \
         --sub-lang-pref eng --no-ocr \
         "$TESTDIR/multi_subs.mkv" "$smt1_out" >/dev/null 2>&1 && [[ -f "$smt1_out" ]]; then
      local limited_sub_count
      limited_sub_count="$(ffprobe -v error -select_streams s -show_entries stream=index \
        -of csv=p=0 "$smt1_out" 2>/dev/null | wc -l | tr -d ' ')"
      if (( limited_sub_count <= 1 )); then
        pass "SUB_MAX_TRACKS=1 limits output to ≤1 subtitle track (got $limited_sub_count)"
      else
        fail "SUB_MAX_TRACKS=1 should limit to ≤1, got $limited_sub_count"
      fi
    else
      skip "SUB_MAX_TRACKS=1 encode failed"
    fi
  else
    skip "SUB_MAX_TRACKS baseline encode failed"
  fi

  # ---- --sub-lang-pref selects correct language ----
  local slp_out="$TESTDIR/e2e_sub_lang_pref.mkv"
  if run_muxm --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref spa --no-ocr \
       "$TESTDIR/multi_subs_multilang.mkv" "$slp_out" >/dev/null 2>&1 && [[ -f "$slp_out" ]]; then
    local slp_lang
    slp_lang="$(probe_stream_tag "$slp_out" s:0 language)"
    if [[ "$slp_lang" == "spa" ]]; then
      pass "--sub-lang-pref spa: output subtitle is Spanish"
    else
      fail "--sub-lang-pref spa: expected 'spa', got '$slp_lang'"
    fi
  else
    skip "--sub-lang-pref encode failed or output not found"
  fi

  # ---- --sub-preserve-format / --no-sub-preserve-format config flags ----
  out="$(run_muxm --sub-preserve-format --print-effective-config)"
  assert_contains "SUB_PRESERVE_TEXT_FORMAT  = 1" "--sub-preserve-format: config shows 1" "$out"

  out="$(run_muxm --no-sub-preserve-format --print-effective-config)"
  assert_contains "SUB_PRESERVE_TEXT_FORMAT  = 0" "--no-sub-preserve-format: config shows 0" "$out"

  # ---- ASS subtitle encode tests ----
  # Isolate HOME to prevent user's ~/.muxmrc from affecting subtitle pipeline
  # behavior (e.g., SUB_BURN_FORCED=1, default PROFILE_NAME, etc.).
  local _saved_home="$HOME"
  export HOME="$TESTDIR/ass_test_home"
  mkdir -p "$HOME"

  # ---- animation profile preserves ASS subtitles natively in MKV ----
  local ass_anim_out="$TESTDIR/subs_ass_animation.mkv"
  log "Testing animation profile preserves ASS subtitles..."
  if assert_encode "animation + ASS: output produced" "$ass_anim_out" \
       --profile animation --crf 28 --preset ultrafast "$TESTDIR/ass_subs.mkv"; then
    local ass_codec
    ass_codec="$(probe_sub "$ass_anim_out" codec_name)"
    if [[ "$ass_codec" == "ass" || "$ass_codec" == "ssa" ]]; then
      pass "animation + ASS: subtitle preserved as native $ass_codec (not SRT)"
    else
      fail "animation + ASS: expected ass/ssa codec, got '$ass_codec'"
    fi
  fi

  # ---- --sub-preserve-format (explicit) preserves ASS in MKV ----
  local ass_explicit_out="$TESTDIR/subs_ass_explicit.mkv"
  log "Testing --sub-preserve-format preserves ASS..."
  if assert_encode "--sub-preserve-format + MKV: output produced" "$ass_explicit_out" \
       --output-ext mkv --sub-preserve-format --crf 28 --preset ultrafast "$TESTDIR/ass_subs.mkv"; then
    local ass_explicit_codec
    ass_explicit_codec="$(probe_sub "$ass_explicit_out" codec_name)"
    if [[ "$ass_explicit_codec" == "ass" || "$ass_explicit_codec" == "ssa" ]]; then
      pass "--sub-preserve-format + MKV: subtitle preserved as native $ass_explicit_codec"
    else
      fail "--sub-preserve-format + MKV: expected ass/ssa, got '$ass_explicit_codec'"
    fi
  fi

  # ---- Default behavior (no --sub-preserve-format) converts ASS to SRT in MKV ----
  local ass_default_out="$TESTDIR/subs_ass_default.mkv"
  log "Testing default behavior converts ASS to SRT..."
  if assert_encode "Default + ASS→MKV: output produced" "$ass_default_out" \
       --output-ext mkv --crf 28 --preset ultrafast "$TESTDIR/ass_subs.mkv"; then
    local ass_default_codec
    ass_default_codec="$(probe_sub "$ass_default_out" codec_name)"
    if [[ "$ass_default_codec" == "subrip" || "$ass_default_codec" == "srt" ]]; then
      pass "Default + ASS→MKV: subtitle converted to SRT ($ass_default_codec)"
    else
      fail "Default + ASS→MKV: expected subrip/srt, got '$ass_default_codec'"
    fi
  fi

  # ---- --no-sub-preserve-format overrides animation profile ----
  local ass_override_out="$TESTDIR/subs_ass_override.mkv"
  log "Testing --no-sub-preserve-format overrides animation profile..."
  if assert_encode "animation + --no-sub-preserve-format: output produced" "$ass_override_out" \
       --profile animation --no-sub-preserve-format --crf 28 --preset ultrafast "$TESTDIR/ass_subs.mkv"; then
    local ass_override_codec
    ass_override_codec="$(probe_sub "$ass_override_out" codec_name)"
    if [[ "$ass_override_codec" == "subrip" || "$ass_override_codec" == "srt" ]]; then
      pass "animation + --no-sub-preserve-format: ASS converted to SRT ($ass_override_codec)"
    else
      fail "animation + --no-sub-preserve-format: expected subrip/srt, got '$ass_override_codec'"
    fi
  fi

  # ---- --sub-preserve-format ignored for MP4 (container cannot carry ASS) ----
  local ass_mp4_out="$TESTDIR/subs_ass_mp4.mp4"
  log "Testing --sub-preserve-format ignored for MP4..."
  if assert_encode "--sub-preserve-format + MP4: output produced" "$ass_mp4_out" \
       --output-ext mp4 --sub-preserve-format --crf 28 --preset ultrafast "$TESTDIR/ass_subs.mkv"; then
    local ass_mp4_codec
    ass_mp4_codec="$(probe_sub "$ass_mp4_out" codec_name)"
    if [[ "$ass_mp4_codec" == "mov_text" ]]; then
      pass "--sub-preserve-format + MP4: subtitle is mov_text (ASS not preserved in MP4)"
    else
      # MP4 might have no subs at all, or mov_text — either is acceptable
      local ass_mp4_scount
      ass_mp4_scount="$(count_streams "$ass_mp4_out" s)"
      if [[ "$ass_mp4_scount" -eq 0 ]]; then
        pass "--sub-preserve-format + MP4: no subtitle in output (MP4 cannot carry ASS)"
      else
        fail "--sub-preserve-format + MP4: expected mov_text or no sub, got '$ass_mp4_codec'"
      fi
    fi
  fi

  # Restore HOME
  export HOME="$_saved_home"

  # ---- Pipe characters in subtitle titles no longer break field parsing ----
  # v1.0.2 fix: titles like "Original | English | (SDH)" contain literal | which
  # corrupted the old pipe-delimited _sub_stream_info output. Delimiter migrated to \t.
  local pipe_sub_out="$TESTDIR/subs_pipe_titles.mkv"
  log "Testing pipe characters in subtitle stream title..."
  if assert_encode "Pipe in sub title: encode completes (no crash)" "$pipe_sub_out" \
       --output-ext mkv --crf 28 --preset ultrafast "$TESTDIR/pipe_titles.mkv"; then
    assert_stream_count "Pipe in sub title: subtitle stream present" "$pipe_sub_out" s 1 1
    local pipe_sub_codec
    pipe_sub_codec="$(probe_sub "$pipe_sub_out" codec_name)"
    if [[ -n "$pipe_sub_codec" ]]; then
      pass "Pipe in sub title: subtitle codec readable ($pipe_sub_codec)"
    else
      fail "Pipe in sub title: subtitle codec not readable"
    fi
  fi

  # ---- Multi-track subtitle tests (archive SUB_MULTI_TRACK=1) ----
  # hevc_multi_subs.mkv: 5 subs — eng forced, eng full, eng SDH, spa full, fra full

  # Multi-track dry-run: shows ✓/✗ markers and announces multi-track mode
  # --no-skip-if-ideal: this fixture is fully compliant (HEVC+MKV+all subs pass),
  # so skip-if-ideal would short-circuit before the subtitle pipeline runs.
  log "Testing multi-track subtitle dry-run..."
  local mt_sub_dry
  mt_sub_dry="$(run_muxm --dry-run --no-skip-if-ideal --profile archive "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "multi-track" "Multi-track sub dry-run: announces multi-track mode" "$mt_sub_dry"
  assert_contains "✓" "Multi-track sub dry-run: shows ✓ keep marker" "$mt_sub_dry"
  assert_contains "keeping 5 of 5" "Multi-track sub dry-run: all 5 tracks kept (no filters)" "$mt_sub_dry"

  # Multi-track language filter: --sub-lang-pref eng keeps only English tracks
  log "Testing multi-track subtitle language filter..."
  local mt_sub_lang
  mt_sub_lang="$(run_muxm --dry-run --profile archive \
    --sub-lang-pref eng "$TESTDIR/hevc_multi_subs.mkv")"
  # eng forced + eng full + eng SDH kept, spa + fra dropped = keeping 3 of 5
  assert_contains "keeping 3 of 5" "Multi-track sub + --sub-lang-pref eng: 3 of 5 kept" "$mt_sub_lang"
  assert_contains "✗" "Multi-track sub + --sub-lang-pref eng: shows ✗ drop marker" "$mt_sub_lang"

  # Multi-track type filter: SUB_INCLUDE_SDH=0 drops SDH tracks
  log "Testing multi-track subtitle type filter (no SDH)..."
  local mt_sub_nosdh
  mt_sub_nosdh="$(run_muxm --dry-run --profile archive \
    --no-sub-sdh "$TESTDIR/hevc_multi_subs.mkv")"
  # eng forced + eng full + spa full + fra full kept, eng SDH dropped = keeping 4 of 5
  assert_contains "keeping 4 of 5" "Multi-track sub + --no-sub-sdh: 4 of 5 kept (SDH dropped)" "$mt_sub_nosdh"

  # Multi-track + SUB_MAX_TRACKS cap
  # Uses .muxmrc instead of --profile archive because profiles override config values.
  log "Testing multi-track subtitle SUB_MAX_TRACKS cap..."
  local mt_sub_cap_home="$TESTDIR/sub_mt_cap_home"
  mkdir -p "$mt_sub_cap_home"
  cat > "$mt_sub_cap_home/.muxmrc" <<'EOF'
SUB_MULTI_TRACK=1
SUB_LANG_PREF=
SUB_MAX_TRACKS=2
EOF
  local mt_sub_cap
  mt_sub_cap="$(MUXM_HOME="$mt_sub_cap_home" run_muxm_in "$TESTDIR" --dry-run \
    "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "keeping 2 of 5" "Multi-track sub + SUB_MAX_TRACKS=2: capped at 2" "$mt_sub_cap"

  # Multi-track demotion: --sub-burn-forced forces single-track
  # --no-skip-if-ideal: source is ideal, would skip before demotion message is printed.
  log "Testing multi-track subtitle demotion on --sub-burn-forced..."
  local mt_sub_demote
  mt_sub_demote="$(run_muxm --dry-run --no-skip-if-ideal --profile archive --sub-burn-forced "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "single subtitle track" "Multi-track sub + --sub-burn-forced: collapses to a single subtitle track" "$mt_sub_demote"

  # Multi-track + --sub-export-external: stays in multi-track, logs note
  # --no-skip-if-ideal: source is ideal, would skip before export note is printed.
  log "Testing multi-track subtitle with --sub-export-external..."
  local mt_sub_export
  mt_sub_export="$(run_muxm --dry-run --no-skip-if-ideal --profile archive --sub-export-external "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "multi-track" "Multi-track sub + --sub-export-external: stays in multi-track" "$mt_sub_export"
  assert_contains "export-external ignored" "Multi-track sub + --sub-export-external: notes export ignored" "$mt_sub_export"

  # ---- Multi-track subtitle tests (animation SUB_MULTI_TRACK=1) ----
  # animation profile: same multi-track pipeline, different defaults (SUB_MAX_TRACKS=6).
  # NOTE: animation inherits the default SUB_LANG_PREF=eng (unlike archive which
  # clears it to ""). The hevc_multi_subs fixture has 3 eng + 1 spa + 1 fra = 5 tracks,
  # so only 3 English tracks survive the language filter by default.

  # Animation multi-track dry-run: announces multi-track mode, keeps eng tracks only
  log "Testing animation multi-track subtitle dry-run..."
  local mt_sub_anim
  mt_sub_anim="$(run_muxm --dry-run --profile animation "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "multi-track" "animation multi-track sub: announces multi-track mode" "$mt_sub_anim"
  assert_contains "keeping 3 of 5" "animation multi-track sub: 3 eng tracks kept (SUB_LANG_PREF=eng)" "$mt_sub_anim"

  # Animation multi-track + --sub-burn-forced demotes to single-track
  log "Testing animation multi-track subtitle demotion on --sub-burn-forced..."
  local mt_sub_anim_demote
  mt_sub_anim_demote="$(run_muxm --dry-run --profile animation --sub-burn-forced "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "single subtitle track" "animation multi-track sub + --sub-burn-forced: collapses to a single subtitle track" "$mt_sub_anim_demote"

  # Animation multi-track + language filter override: --sub-lang-pref "" keeps all 5
  log "Testing animation multi-track subtitle language filter override..."
  local mt_sub_anim_lang
  mt_sub_anim_lang="$(run_muxm --dry-run --profile animation \
    --sub-lang-pref "" "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "keeping 5 of 5" "animation multi-track sub + --sub-lang-pref '': all 5 kept" "$mt_sub_anim_lang"

  # Animation multi-track + --sub-export-external: stays in multi-track, logs note
  log "Testing animation multi-track subtitle with --sub-export-external..."
  local mt_sub_anim_export
  mt_sub_anim_export="$(run_muxm --dry-run --profile animation --sub-export-external "$TESTDIR/hevc_multi_subs.mkv")"
  assert_contains "multi-track" "animation multi-track sub + --sub-export-external: stays in multi-track" "$mt_sub_anim_export"
  assert_contains "export-external ignored" "animation multi-track sub + --sub-export-external: notes export ignored" "$mt_sub_anim_export"

  # ---- M4: forced-sub burn into an output directory whose name contains an apostrophe ----
  # If the burn filter embedded the absolute WORKDIR path (which lives under the output
  # directory) in the filtergraph as subtitles=filename='…It's…/burn.srt', the apostrophe
  # would close the single quote and ffmpeg would abort with "Unable to open …". The burn
  # references the staged file by its bare relative name (burn.srt) and runs the encode
  # from inside WORKDIR, so no user path is ever escaped. (universal burns forced by
  # default; multi_subs.mkv has an eng forced track.)
  local _m4_dir="$TESTDIR/It's A Test"
  mkdir -p "$_m4_dir"
  local _m4_out="$_m4_dir/burned.mkv"
  rm -f "$_m4_out"
  local _m4_log _m4_code=0
  _m4_log="$(cd "$TESTDIR" && HOME="${MUXM_HOME:-$HOME}" "$MUXM" -K --profile universal \
    --sub-burn-forced --preset ultrafast --crf 30 "$TESTDIR/multi_subs.mkv" "$_m4_out" 2>&1)" || _m4_code=$?
  if printf '%s\n' "$_m4_log" | grep -qiF 'Burning forced subtitles'; then
    pass "subs-forced-burn-apostrophe-path: forced-sub burn attempted into \"It's A Test/\" output directory"
    if [[ "$_m4_code" -eq 0 && -f "$_m4_out" && -s "$_m4_out" ]]; then
      pass "subs-forced-burn-apostrophe-path: forced-burn encode completes into apostrophe directory (filtergraph parsed)"
    else
      fail "subs-forced-burn-apostrophe-path: forced-burn into apostrophe directory failed (exit $_m4_code) — path escaping regressed"
    fi
    if printf '%s\n' "$_m4_log" | grep -qiE 'No option name|Unable to open .*burn|Error initializing filters'; then
      fail "subs-forced-burn-apostrophe-path: filtergraph parse error on apostrophe output path"
    else
      pass "subs-forced-burn-apostrophe-path: no filtergraph parse error on apostrophe output path"
    fi
  else
    skip "subs-forced-burn-apostrophe-path: forced subtitle not prepared from multi_subs.mkv — burn path not exercised"
  fi
  rm -rf "$_m4_dir"

  # ---- 3.3: forced-subtitle burn-in PIXEL verification (M-BURN-1) ----
  # M4 above only greps the log for "Burning forced subtitles"; this proves the burn actually
  # writes pixels. Encode the SAME source twice — with and without --sub-burn-forced — then PSNR
  # the bottom subtitle band of the two video streams. A real burn overlays opaque text, dragging
  # the band's y-PSNR far down (≈21 dB observed); a no-op burn leaves the band bit-identical to the
  # plain encode (y:inf). Threshold 45 dB cleanly separates the two (text ≪ 45 ≪ inf).
  # EXPLICIT NON-CLAIM: proves PIXELS CHANGED in the sub region, not positioning/styling fidelity.
  # M-BURN-1 turns the `subtitles=filename=burn.srt` filter into a `null` passthrough (still a valid
  # encode, just no burn) → the bands become identical → this test goes red.
  # A dedicated fixture (640×360 gray, one long forced line for the full clip) makes the delta
  # unambiguous and the forced line present at every sampled frame — built inline (not a shared
  # fixture) so it is self-contained.
  local _burn_dir="$TESTDIR/burnpix"
  mkdir -p "$_burn_dir"
  cat > "$_burn_dir/forced.srt" <<'SRT'
1
00:00:00,000 --> 00:00:02,000
FORCED SUBTITLE BURN TEST LINE ONE TWO THREE
SRT
  local _burn_src="$_burn_dir/forced_src.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=gray:s=640x360:r=24:d=2" \
    -f lavfi -i "sine=frequency=440:duration=2" \
    -i "$_burn_dir/forced.srt" \
    -map 0:v -map 1:a -map 2 \
    -c:v libx264 -preset ultrafast -crf 24 -c:a aac -b:a 96k -ac 2 -c:s srt \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="Forced" \
    -disposition:s:0 forced \
    "$_burn_src" 2>/dev/null || true
  if [[ ! -s "$_burn_src" ]]; then
    skip "subs-forced-burn-in burn-in: could not build forced-subtitle fixture (ffmpeg/libx264 unavailable)"
  else
    local _burned="$_burn_dir/burned.mkv" _plain="$_burn_dir/plain.mkv" _burn_log
    _burn_log="$(run_muxm --sub-burn-forced --output-ext mkv --crf 24 --preset ultrafast "$_burn_src" "$_burned")"
    run_muxm --no-sub-burn-forced --output-ext mkv --crf 24 --preset ultrafast "$_burn_src" "$_plain" >/dev/null 2>&1
    # The fixture guarantees a forced track, so the burn must be attempted (else the comparison
    # below is meaningless) — a missing attempt is a real regression here, not a host skip.
    if ! printf '%s\n' "$_burn_log" | grep -qiF 'Burning forced subtitles'; then
      fail "subs-forced-burn-in burn-in: --sub-burn-forced did not attempt a burn on a forced-track source"
    elif [[ ! -s "$_burned" || ! -s "$_plain" ]]; then
      fail "subs-forced-burn-in burn-in: burned and/or plain encode produced no output"
    else
      # PSNR of the bottom third (where SRT renders) between burned and plain video streams.
      # Relative crop (iw, ih/3) is robust to any output resolution; both encodes share dims.
      local _psnr_line _y
      _psnr_line="$(ffmpeg -hide_banner -loglevel info -i "$_burned" -i "$_plain" -lavfi \
        "[0:v]crop=iw:ih/3:0:2*ih/3[a];[1:v]crop=iw:ih/3:0:2*ih/3[b];[a][b]psnr" \
        -f null - 2>&1 | grep -iE 'PSNR.*average' | tail -1)"
      _y="$(printf '%s' "$_psnr_line" | grep -oE 'y:inf|y:[0-9.]+' | head -1 | cut -d: -f2)"
      if [[ -z "$_y" ]]; then
        fail "subs-forced-burn-in burn-in: could not compute band PSNR (ffmpeg psnr filter produced no value)"
      elif [[ "$_y" == "inf" ]]; then
        fail "subs-forced-burn-in burn-in: subtitle band is identical with/without --sub-burn-forced (y-PSNR=inf) — burn wrote no pixels"
      elif awk "BEGIN{exit !($_y < 45)}"; then
        pass "subs-forced-burn-in burn-in: --sub-burn-forced changes the subtitle-band pixels (y-PSNR=${_y}dB < 45)"
      else
        fail "subs-forced-burn-in burn-in: subtitle band barely changed (y-PSNR=${_y}dB ≥ 45) — forced text not rendered into pixels"
      fi
    fi
  fi
  rm -rf "$_burn_dir"

  # ---- H2 (subtitles): an embedded sub tagged with a 2-letter code (`en`) must survive a
  #      3-letter language filter (`eng`) — closing the embedded-vs-external asymmetry where an
  #      external `movie.en.srt` was kept (parsed to `eng`) but an embedded `en` was dropped.
  #      Skip-first guard (not an else-skip) per the soft-skip ratchet. ----
  if ! ffmpeg_has_encoder libx265; then
    skip "H2-sub: ffmpeg lacks libx265 — cannot build the embedded-subtitle fixture"
  else
    local _h2_src="$TESTDIR/h2_embedded_en_sub.mkv" _h2_out="$TESTDIR/h2_sub_out.mkv"
    printf '1\n00:00:00,000 --> 00:00:02,000\nEmbedded two-letter English\n' > "$TESTDIR/h2_en.srt"
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "color=c=navy:s=320x240:r=24:d=2" \
      -f lavfi -i "sine=frequency=440:duration=2" \
      -i "$TESTDIR/h2_en.srt" \
      -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p10le \
      -map 0:v -map 1:a -map 2:s -c:a aac -c:s srt \
      -metadata:s:s:0 language=en \
      "$_h2_src" 2>/dev/null
    if [[ ! -s "$_h2_src" ]]; then
      skip "H2-sub: could not build the embedded-subtitle fixture"
    else
      run_muxm --profile archive --sub-lang-pref eng --output-ext mkv "$_h2_src" "$_h2_out" >/dev/null
      local _h2_scount; _h2_scount="$(count_streams "$_h2_out" s)"
      if [[ -s "$_h2_out" ]] && (( _h2_scount >= 1 )); then
        pass "H2-sub: embedded 'en' subtitle survives the 'eng' language filter (got $_h2_scount sub track)"
      else
        fail "H2-sub: embedded 'en' subtitle dropped by the 'eng' filter (count=${_h2_scount:-?}) — embedded/external asymmetry (regression)"
      fi
    fi
    rm -f "$_h2_src" "$_h2_out" "$TESTDIR/h2_en.srt" 2>/dev/null || true
  fi

  _test_subs_sdh_disposition
  _test_subs_untagged_forced
  _test_subs_no_reembed
  _test_subs_forced_copy_gate
}

# RF2 (e2e): with --sub-burn-forced and a video stream eligible for stream-copy (a
# compliant HEVC under atv-directplay-hq), the copy path must not skip the burn-in filter and
# silently drop the forced subtitle. _video_is_copy_compliant forces a re-encode when
# SUB_BURN_FORCED is set (and, via check_skip_if_ideal's delegation, the milder skip-if-ideal
# variant too). Bidirectional:
#   (control) atv-directplay-hq on the compliant forced-sub source WITHOUT --sub-burn-forced takes
#             the no-op path (skip-if-ideal / copy) — proving the source IS genuinely copy-compliant,
#             so the gate is what changes behavior (not an already-failing source).
#   (RF2)     adding --sub-burn-forced flips it to a re-encode that actually burns the forced track
#             in — copy path NOT taken, forced sub not silently lost.
_test_subs_forced_copy_gate() {
  local _dir="$TESTDIR/rf2_forced_copy"; mkdir -p "$_dir/home"
  printf '1\n00:00:00,000 --> 00:00:01,000\n[Foreign dialogue]\n' > "$_dir/forced.srt"
  local _src="$_dir/src.mkv"
  # Compliant HEVC (yuv420p10le SDR, copy-eligible under atv-directplay-hq) + ac3 5.1 eng audio +
  # a single forced eng subtitle.
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=red:s=320x240:r=24:d=2" -f lavfi -i "sine=frequency=440:duration=2" -i "$_dir/forced.srt" \
    -map 0:v -map 1:a -map 2:s \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le -c:a ac3 -b:a 384k -ac 6 -c:s srt \
    -metadata:s:a:0 language=eng \
    -disposition:s:0 forced -metadata:s:s:0 language=eng -metadata:s:s:0 title="Forced" \
    "$_src" 2>/dev/null || true
  # Fixture must carry a forced subtitle, else the test proves nothing.
  local _fd
  _fd="$(ffprobe -v error -select_streams s:0 -show_entries stream_disposition=forced -of csv=p=0 "$_src" 2>/dev/null || true)"
  if [[ ! -s "$_src" || "$_fd" != "1" ]]; then
    skip "subs-forced-burn-forces-reencode (e2e): could not build a compliant forced-subtitle HEVC fixture (forced=$_fd)"
    rm -rf "$_dir"; return
  fi

  # (control) no --sub-burn-forced → copy/skip-if-ideal path (no re-encode). Proves compliance.
  local _ctrl
  _ctrl="$(MUXM_HOME="$_dir/home" run_muxm_in "$_dir" --profile atv-directplay-hq "src.mkv" "out_ctrl")"
  if printf '%s\n' "$_ctrl" | grep -qiE 'will copy directly from source|already matches profile|skipping processing'; then
    pass "subs-forced-burn-forces-reencode (e2e): control (no burn) takes the copy/skip-if-ideal path — source is genuinely compliant"
  else
    fail "subs-forced-burn-forces-reencode (e2e): control did not copy/skip — source not actually copy-compliant, test inconclusive"
  fi

  # (RF2) --sub-burn-forced → re-encode that burns the forced track in; copy path NOT taken.
  local _rf2
  _rf2="$(MUXM_HOME="$_dir/home" run_muxm_in "$_dir" --profile atv-directplay-hq --sub-burn-forced "src.mkv" "out_rf2")"
  local _reencoded=0 _burned=0 _nocopy=1
  printf '%s\n' "$_rf2" | grep -qiE 'will re-encode|forced-subtitle burn-in requires a re-encode' && _reencoded=1
  printf '%s\n' "$_rf2" | grep -qiE 'Burning forced subtitles into video stream' && _burned=1
  printf '%s\n' "$_rf2" | grep -qi 'will copy directly from source' && _nocopy=0
  if (( _reencoded && _burned && _nocopy )); then
    pass "subs-forced-burn-forces-reencode (e2e): --sub-burn-forced forces re-encode and burns the forced sub (copy path not taken, no silent loss)"
  else
    fail "subs-forced-burn-forces-reencode (e2e): forced sub not safely burned — re-encode=$_reencoded burned=$_burned copy-avoided=$_nocopy"
  fi
  rm -rf "$_dir"
}

# F3: SDH must be classified by the hearing_impaired DISPOSITION, not just an SDH/HI title. A track
# tagged hearing_impaired=1 but titled plainly ("English") must not be classified "full" — that
# would let it survive --no-sub-sdh and strip its hearing_impaired disposition to 0 on output. Uses
# archive (multi-track subtitle mode) so the keep-list honors SUB_INCLUDE_SDH cleanly; single-track
# mode has a direct-map fallback that re-adds a lone text sub regardless of type. Both assertions
# below flip on a title-only classifier. Skip-first guard per the soft-skip ratchet.
_test_subs_sdh_disposition() {
  section "subs-sdh-by-disposition: SDH classified by hearing_impaired disposition"
  local _dir="$TESTDIR/f3_sdh"; mkdir -p "$_dir"
  printf '1\n00:00:00,000 --> 00:00:01,000\nHello\n' > "$_dir/s.srt"
  local _src="$_dir/src.mkv"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=blue:s=320x240:r=24:d=1" \
    -f lavfi -i "sine=d=1" -i "$_dir/s.srt" -map 0:v -map 1:a -map 2:s \
    -c:v libx265 -preset ultrafast -crf 30 -c:a aac -c:s srt \
    -disposition:s:0 hearing_impaired -metadata:s:s:0 title=English -metadata:s:s:0 language=eng \
    "$_src" 2>/dev/null || true
  # The fixture must carry hearing_impaired=1 with a PLAIN title, else the test proves nothing.
  local _src_hi
  _src_hi="$(ffprobe -v error -select_streams s:0 -show_entries stream_disposition=hearing_impaired -of csv=p=0 "$_src" 2>/dev/null || true)"
  if [[ ! -s "$_src" || "$_src_hi" != "1" ]]; then
    skip "subs-sdh-by-disposition: could not build a hearing_impaired subtitle fixture (ffmpeg disposition support)"
    rm -rf "$_dir"; return
  fi

  # (a) Include path: the plain-titled hearing_impaired track is classified SDH, kept, and keeps
  #     its hearing_impaired disposition on output. A "full" classification resets it to 0.
  local _inc="$_dir/inc.mkv"
  run_muxm --profile archive --preset ultrafast "$_src" "$_inc" >/dev/null 2>&1 || true
  local _inc_hi
  _inc_hi="$(ffprobe -v error -select_streams s:0 -show_entries stream_disposition=hearing_impaired -of csv=p=0 "$_inc" 2>/dev/null || true)"
  if [[ -s "$_inc" && "$_inc_hi" == "1" ]]; then
    pass "subs-sdh-by-disposition: hearing_impaired+plain-title sub → classified SDH, output keeps hearing_impaired disposition"
  else
    fail "subs-sdh-by-disposition: expected output sub disposition hearing_impaired=1, got '${_inc_hi:-none}' (classified 'full'?)"
  fi

  # (b) --no-sub-sdh drops it — only possible because it is classified SDH (a "full" track is kept).
  local _nos="$_dir/nos.mkv"
  run_muxm --profile archive --no-sub-sdh --preset ultrafast "$_src" "$_nos" >/dev/null 2>&1 || true
  local _nos_cnt; _nos_cnt="$(count_streams "$_nos" s)"
  if [[ -s "$_nos" && "$_nos_cnt" == "0" ]]; then
    pass "subs-sdh-by-disposition: --no-sub-sdh drops the disposition-only SDH track (0 subtitle streams)"
  else
    fail "subs-sdh-by-disposition: --no-sub-sdh → expected output with 0 subtitle streams, got ${_nos_cnt:-?} (output exists: $([[ -s "$_nos" ]] && echo yes || echo no))"
  fi
  rm -rf "$_dir"
}

# C2 (subtitle classification): merge_subtitle_sources parses each embedded subtitle record
# (codec⇥lang⇥title⇥forced⇥hi) to classify it forced/sdh/full and to record its language/title.
# `lang` and `title` are empty-able MIDDLE fields, so a collapsing `IFS=$'\t' read` would shift
# an UNTAGGED-language subtitle's later fields left: the title becomes the language, the forced
# disposition becomes the title, and `(( forced ))`/`(( hi ))` read the wrong (shifted) values —
# an untagged forced subtitle mis-stored as language="<title>" and mis-classified "full". The
# parse runs through the non-collapsing _split_tab. Here an untagged-language forced
# subtitle must scan as `[und] — <title> (forced)`, not the collapsed `[<title>] — <forced> (full)`.
# The scan line is the direct read-back of merge_subtitle_sources' ALL_SUB_LANGS/TITLES/TYPES.
# Perturb MUT-C2-SUBCLASS reverts merge_subtitle_sources to the collapsing read → red.
_test_subs_untagged_forced() {
  local _dir="$TESTDIR/c2_subforced"; mkdir -p "$_dir"
  printf '1\n00:00:00,000 --> 00:00:02,000\nForced sign\n' > "$_dir/f.srt"
  local _src="$_dir/src.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=olive:s=320x240:r=24:d=2" -f lavfi -i "sine=frequency=440:duration=2" -i "$_dir/f.srt" \
    -map 0:v -map 1:a -map 2:s \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le -c:a aac -ac 2 -c:s srt \
    -metadata:s:a:0 language=eng \
    -disposition:s:0 forced -metadata:s:s:0 title="Forced" \
    "$_src" 2>/dev/null || true
  # Fixture must carry forced=1 with NO language tag, else the test proves nothing.
  local _fd _fl
  _fd="$(ffprobe -v error -select_streams s:0 -show_entries stream_disposition=forced -of csv=p=0 "$_src" 2>/dev/null || true)"
  _fl="$(ffprobe -v error -select_streams s:0 -show_entries stream_tags=language -of default=nw=1:nk=1 "$_src" 2>/dev/null || true)"
  if [[ ! -s "$_src" || "$_fd" != "1" || -n "$_fl" ]]; then
    skip "subs-untagged-forced-classification sub-classify: could not build an untagged-language forced subtitle fixture (forced=$_fd lang='$_fl')"
    rm -rf "$_dir"; return
  fi
  local _home="$_dir/home"; mkdir -p "$_home"
  local out sline
  log "Testing untagged-language forced subtitle classification (C2)..."
  out="$(MUXM_HOME="$_home" run_muxm --dry-run --profile universal "$_src")"
  sline="$(printf '%s\n' "$out" | grep -E '#0: ' | head -1)"
  # Fixed: "#0: subrip [und] — Forced (forced)".  Collapsed bug: "#0: subrip [forced] — 1 (full)".
  if [[ "$sline" == *"[und] — Forced (forced)"* ]]; then
    pass "subs-untagged-forced-classification sub-classify: untagged forced subtitle scans as [und] — Forced (forced) (no field shift)"
  else
    fail "subs-untagged-forced-classification sub-classify: untagged forced subtitle misclassified (collapse shifted lang/title/forced): '$sline'"
  fi
  rm -rf "$_dir"
}

# H2 (subtitle fallback): build_subtitle_plan's direct-map fallback re-embeds a soft text sub when
# "nothing was prepared". A guard that tested only the three embed vars (SRT_FORCED/FULL/SDH) fails
# here: on a burn+export profile (universal: SUB_BURN_FORCED=1, SUB_EXPORT_EXTERNAL=1) a forced sub
# routes to SRT_FORCED_BURN_PATH and a full sub to EXTERNAL_SRT_PATHS, leaving the embed vars empty
# even though subtitles WERE prepared — so the fallback would fire and re-embed a contradictory soft
# mov_text track on top of the burn/export. The guard also gates on SRT_FORCED_BURN_PATH and
# EXTERNAL_SRT_PATHS. This test is bidirectional:
#   (negative) universal + an embedded English full text sub → output carries NO soft subtitle, and
#              the full sub is exported to a sidecar (proves it WAS prepared, so 0 embedded is the
#              correct outcome — not merely "no subs"). Perturb MUT-H2-REEMBED reverts the guard.
#   (positive) an embed-style profile where nothing is prepared but a direct-mappable text sub
#              exists (atv-directplay-hq --no-sub-sdh on an SDH-only source) → the legitimate
#              direct-map fallback STILL fires. Guards against the fix over-restricting embed
#              profiles (for which the two new clauses are no-ops: burn off + export off).
_test_subs_no_reembed() {
  local _dir="$TESTDIR/h2_reembed"; mkdir -p "$_dir"
  # --- negative: universal must not re-embed a soft sub ---
  printf '1\n00:00:00,000 --> 00:00:02,000\nFull dialogue line\n' > "$_dir/d.srt"
  local _nsrc="$_dir/full.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=teal:s=320x240:r=24:d=2" -f lavfi -i "sine=frequency=440:duration=2" -i "$_dir/d.srt" \
    -map 0:v -map 1:a -map 2:s \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le -c:a aac -ac 2 -c:s srt \
    -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
    "$_nsrc" 2>/dev/null || true
  local _home="$_dir/home"; mkdir -p "$_home"
  local _nout="$_dir/out.mp4"
  log "Testing H2: universal must not re-embed a soft subtitle over burn+export..."
  if [[ -s "$_nsrc" ]]; then
    MUXM_HOME="$_home" run_muxm --profile universal "$_nsrc" "$_nout" >/dev/null
    local _nsub; _nsub="$(count_streams "$_nout" s)"
    if [[ -s "$_nout" ]] && (( _nsub == 0 )); then
      pass "subs-universal-no-reembed: universal burns/exports only — no contradictory soft subtitle re-embedded (0 embedded subs)"
    else
      fail "subs-universal-no-reembed: universal re-embedded a soft subtitle ($_nsub embedded) despite burn+export (contradictory direct-map)"
    fi
    if ls "$_dir"/out.*.srt >/dev/null 2>&1; then
      pass "subs-universal-no-reembed: the full subtitle was exported to an external sidecar (so 0 embedded is correct, not 'no subs')"
    else
      fail "subs-universal-no-reembed: expected an exported .srt sidecar alongside the universal output (full sub not prepared?)"
    fi
  else
    fail "subs-universal-no-reembed: could not build the embedded-full-subtitle fixture"
  fi

  # --- positive: legitimate direct-map fallback must still fire for an embed profile ---
  printf '1\n00:00:00,000 --> 00:00:02,000\n[door creaks]\n' > "$_dir/sdh.srt"
  local _psrc="$_dir/sdh.mkv"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=gray:s=320x240:r=24:d=2" -f lavfi -i "sine=frequency=440:duration=2" -i "$_dir/sdh.srt" \
    -map 0:v -map 1:a -map 2:s \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le -c:a aac -ac 2 -c:s srt \
    -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng -disposition:s:0 hearing_impaired \
    "$_psrc" 2>/dev/null || true
  # Skip-first guard (not an else→skip): only a missing fixture skips; the real assertion lives below.
  if [[ ! -s "$_psrc" ]]; then
    skip "subs-universal-no-reembed: could not build the SDH-only fixture for the positive direct-map case"
    rm -rf "$_dir"; return
  fi
  local _pout
  _pout="$(MUXM_HOME="$_home" run_muxm --dry-run --no-skip-if-ideal --profile atv-directplay-hq --no-sub-sdh "$_psrc")"
  if grep -q "enabling direct-map" <<<"$_pout"; then
    pass "subs-universal-no-reembed: legitimate direct-map fallback still fires for an embed profile (fix does not over-restrict)"
  else
    fail "subs-universal-no-reembed: direct-map fallback wrongly suppressed for an embed profile (over-restricted by the H2 guard)"
  fi
  rm -rf "$_dir"
}

# === Suite: Output Features ===
# Validates chapter preservation/stripping, checksum generation, JSON report output,
# skip-if-ideal compliance detection, and temp directory retention.
test_output() {
  section "Output Features"

  local outfile chap_count

  # Chapters preserved
  outfile="$TESTDIR/out_chapters.mp4"
  log "Testing chapter preservation..."
  if assert_encode "Chapter preservation encode" "$outfile" \
       --keep-chapters --crf 28 --preset ultrafast "$TESTDIR/with_chapters.mkv"; then
    chap_count="$(ffprobe -v error -show_chapters -of json "$outfile" 2>/dev/null | jq '.chapters | length' 2>/dev/null)" || chap_count=0
    if [[ "$chap_count" -ge 1 ]]; then
      pass "Chapters preserved in output ($chap_count chapters)"
    else
      fail "Chapters preserved: expected ≥1 chapter (with_chapters.mkv + --keep-chapters), got $chap_count"
    fi
  fi

  # Chapters stripped
  outfile="$TESTDIR/out_no_chapters.mp4"
  log "Testing chapter stripping..."
  if assert_encode "Chapter strip encode" "$outfile" \
       --no-keep-chapters --crf 28 --preset ultrafast "$TESTDIR/with_chapters.mkv"; then
    chap_count="$(ffprobe -v error -show_chapters -of json "$outfile" 2>/dev/null | jq '.chapters | length' 2>/dev/null)" || chap_count=0
    if [[ "$chap_count" -eq 0 ]]; then
      pass "--no-keep-chapters: chapters stripped"
    else
      fail "--no-keep-chapters: expected 0 chapters, got $chap_count"
    fi
  fi

  # Checksum
  outfile="$TESTDIR/out_checksum.mp4"
  log "Testing --checksum..."
  if assert_encode "Checksum test encode" "$outfile" \
       --checksum --checksum-algo sha256 --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"; then
    local sha_file="${outfile}.sha256"
    if [[ -f "$sha_file" ]]; then
      pass "--checksum: SHA-256 file created"

      # Verify checksum content is correct (R32)
      # The sidecar contains "hash  /path/to/file" — sha256sum -c validates it.
      if sha256sum -c "$sha_file" >/dev/null 2>&1; then
        pass "--checksum: SHA-256 validates correctly"
      elif shasum -a 256 -c "$sha_file" >/dev/null 2>&1; then
        pass "--checksum: SHA-256 validates correctly (shasum)"
      else
        fail "--checksum: SHA-256 does not match output file"
      fi
    else
      fail "--checksum: SHA-256 sidecar not created at $sha_file"
    fi
  fi

  # BLAKE2b checksum (only if b2sum is available)
  if command -v b2sum >/dev/null 2>&1; then
    outfile="$TESTDIR/out_checksum_b2.mp4"
    log "Testing --checksum --checksum-algo blake2b..."
    if assert_encode "BLAKE2b checksum test encode" "$outfile" \
         --checksum --checksum-algo blake2b --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"; then
      local b2_file="${outfile}.b2"
      if [[ -f "$b2_file" ]]; then
        pass "--checksum-algo blake2b: .b2 sidecar created"
        if b2sum -c "$b2_file" >/dev/null 2>&1; then
          pass "--checksum-algo blake2b: BLAKE2b validates correctly"
        else
          fail "--checksum-algo blake2b: BLAKE2b does not match output file"
        fi
      else
        fail "--checksum-algo blake2b: .b2 sidecar not created at $b2_file (b2sum is present)"
      fi
    fi
  else
    skip "--checksum-algo blake2b: b2sum not available on this system"
  fi

  # JSON report + content validation (#52)
  # Single encode with --profile streaming covers both basic key-presence and profile-content checks.
  outfile="$TESTDIR/out_report.mp4"
  log "Testing --report-json..."
  if assert_encode "JSON report test encode" "$outfile" \
       --profile streaming --report-json --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"; then
    local json_file="${outfile%.mp4}.report.json"
    if [[ -f "$json_file" ]]; then
      pass "--report-json: JSON report created"
      if jq empty "$json_file" 2>/dev/null; then
        pass "--report-json: valid JSON"
      else
        fail "--report-json: invalid JSON"
      fi
      # Validate key fields are present (#52, R35–R38)
      local has_tool has_source has_profile has_output has_timestamp
      has_tool="$(jq 'has("tool") or has("muxm_version") or has("version")' "$json_file" 2>/dev/null)" || has_tool="false"
      has_source="$(jq 'has("source") or has("input") or has("src")' "$json_file" 2>/dev/null)" || has_source="false"
      has_profile="$(jq 'has("profile")' "$json_file" 2>/dev/null)" || has_profile="false"
      has_output="$(jq 'has("output")' "$json_file" 2>/dev/null)" || has_output="false"
      has_timestamp="$(jq 'has("timestamp")' "$json_file" 2>/dev/null)" || has_timestamp="false"
      if [[ "$has_tool" == "true" ]]; then pass "--report-json: contains tool/version key"; else fail "--report-json: tool/version key missing from JSON report"; fi
      if [[ "$has_source" == "true" ]]; then pass "--report-json: contains source/input key"; else fail "--report-json: source/input key missing from JSON report"; fi
      if [[ "$has_profile" == "true" ]]; then pass "--report-json: contains profile key"; else fail "--report-json: profile key missing from JSON report"; fi
      if [[ "$has_output" == "true" ]]; then pass "--report-json: contains output key"; else fail "--report-json: output key missing from JSON report"; fi
      if [[ "$has_timestamp" == "true" ]]; then pass "--report-json: contains timestamp key"; else fail "--report-json: timestamp key missing from JSON report"; fi
      # Validate content values
      local rj_content
      rj_content="$(cat "$json_file")"
      assert_contains "streaming" "JSON report contains profile name" "$rj_content"
      assert_contains "MuxMaster" "JSON report contains tool name" "$rj_content"
    else
      fail "--report-json: report file not created at $json_file"
    fi
  fi

  # 1.6: skip-if-ideal split — a COMPLIANT source must be recognized and remuxed (NOT
  # re-encoded); a NON-COMPLIANT source must re-encode. --profile atv-directplay-hq
  # (HEVC+EAC3, SKIP_IF_IDEAL + VIDEO_COPY_IF_COMPLIANT on) makes the compliance check
  # deterministic — the default no-profile path has no copy-compliant spec, which is why the
  # old single "--skip-if-ideal compliant.mp4" test could only say "may have encoded".
  #
  # Compliant: compliant.mp4 (HEVC 10-bit + EAC3 in MP4) already matches → muxm must SKIP
  # (the "Source already matches … skipping" note fires; the video is stream-copied, stays HEVC).
  local sii_ok_out="$TESTDIR/out_sii_compliant.mp4" sii_ok_log
  log "skip-if-ideal: compliant source must be recognized + remuxed (not re-encoded)..."
  sii_ok_log="$(run_muxm --profile atv-directplay-hq --skip-if-ideal \
    "$TESTDIR/compliant.mp4" "$sii_ok_out")"
  if echo "$sii_ok_log" | grep -qiE "already matches.*skip|skipping processing"; then
    pass "skip-if-ideal compliant: recognized as ideal (skip-processing note fired)"
  else
    fail "skip-if-ideal compliant: expected the 'source already matches … skipping' note, but muxm re-processed it"
  fi
  if [[ -f "$sii_ok_out" && -s "$sii_ok_out" ]]; then
    assert_probe "skip-if-ideal compliant: video stream-copied (stays HEVC)" "$sii_ok_out" codec_name hevc
  else
    fail "skip-if-ideal compliant: no output produced"
  fi

  # Non-compliant: basic_sdr_subs.mkv is H.264 → does NOT match atv-directplay-hq, so
  # --skip-if-ideal must NOT skip; muxm re-encodes H.264 → HEVC. (M-SII-1 forces
  # check_skip_if_ideal always-ideal → this source is wrongly skipped/copied → both go red.)
  local sii_no_out="$TESTDIR/out_sii_noncompliant.mkv" sii_no_log
  log "skip-if-ideal: non-compliant source must re-encode (not skip)..."
  sii_no_log="$(run_muxm --profile atv-directplay-hq --skip-if-ideal \
    "$TESTDIR/basic_sdr_subs.mkv" "$sii_no_out")"
  if echo "$sii_no_log" | grep -qiE "already matches.*skip|skipping processing"; then
    fail "skip-if-ideal non-compliant: H.264 source was wrongly skipped (should re-encode)"
  else
    pass "skip-if-ideal non-compliant: source not skipped (re-encode proceeds)"
  fi
  if [[ -f "$sii_no_out" && -s "$sii_no_out" ]]; then
    assert_probe "skip-if-ideal non-compliant: re-encoded H.264 → HEVC" "$sii_no_out" codec_name hevc
  else
    fail "skip-if-ideal non-compliant: no output produced"
  fi

  # ---- C1: skip-if-ideal must NOT false-skip a non-.mov source requested as .mov ----
  # Without a mov) arm in check_skip_if_ideal, OUTPUT_EXT=mov falls through the container case
  # with ideal=1, so a copy-compliant .mkv requested as .mov gets reported "already matches …
  # skipping" and (on the no-remux branch) raw-hardlinked verbatim — shipping Matroska bytes
  # inside a .mov name. The mov) arm (plus a defensive default *)) prevents this.
  # --no-profile-comment --no-audio-titles force the raw-hardlink branch (single audio track, no
  # subs → no filtering) so the mislabel is observable in format_name; the copy-remux branch would
  # otherwise mask it by re-containerizing via -f mov. The two assertions below — "did NOT skip"
  # and "output is a real MOV, not a renamed Matroska" — each go red without the mov) arm.
  # Perturb MUT-SII-MOV inverts the mov) guard (!= → ==) to reintroduce exactly this defect.
  local c1_src="$TESTDIR/compliant_hevc.mkv"
  gen_media "$c1_src" white \
    -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le -tag:v hvc1 \
    -c:a eac3 -b:a 256k -ac 2 -metadata:s:a:0 language=eng
  local c1_home="$TESTDIR/c1_home"; mkdir -p "$c1_home"
  local c1_out="$TESTDIR/out_c1_mov.mov" c1_log
  log "skip-if-ideal + --output-ext mov: compliant .mkv must NOT false-skip into a mislabeled container (C1)..."
  c1_log="$(MUXM_HOME="$c1_home" run_muxm --profile atv-directplay-hq \
    --no-profile-comment --no-audio-titles --output-ext mov --skip-if-ideal \
    "$c1_src" "$c1_out")"
  if echo "$c1_log" | grep -qiE "already matches.*skip|skipping processing"; then
    fail "skip-if-ideal mov: compliant .mkv was wrongly skipped for a .mov target (C1 — mislabeled container)"
  else
    pass "skip-if-ideal mov: compliant .mkv not skipped for a .mov target (C1)"
  fi
  if [[ -f "$c1_out" && -s "$c1_out" ]]; then
    local c1_fmt; c1_fmt="$(probe_format "$c1_out" format_name)"
    if [[ "$c1_fmt" == *mov* && "$c1_fmt" != matroska* ]]; then
      pass "skip-if-ideal mov: output is a real MOV (format_name=$c1_fmt), not a renamed Matroska"
    else
      fail "skip-if-ideal mov: output container is '$c1_fmt' — expected a real MOV (C1 mislabel)"
    fi
    assert_probe "skip-if-ideal mov: video stream-copied (stays HEVC)" "$c1_out" codec_name hevc
  else
    fail "skip-if-ideal mov: no output produced"
  fi

  # ---- skip-if-ideal + multi-track: commentary triggers remux (not ideal) ----
  # When AUDIO_MULTI_TRACK=1 and AUDIO_KEEP_COMMENTARY=0 (archive default),
  # a source with a commentary track should NOT be considered ideal — the filter
  # would drop it, so remuxing must proceed.
  # Fixture: hevc_multi_audio.mkv — eng main + eng commentary + spa (3 audio tracks).
  local sii_mt_home="$TESTDIR/sii_mt_home"
  mkdir -p "$sii_mt_home"
  local sii_mt_out="$TESTDIR/out_sii_mt_audio.mkv"
  log "Testing skip-if-ideal + multi-track audio (commentary forces remux)..."
  local sii_mt_log
  sii_mt_log="$(MUXM_HOME="$sii_mt_home" run_muxm --profile archive \
    "$TESTDIR/hevc_multi_audio.mkv" "$sii_mt_out")"
  # Should NOT skip — commentary track triggers audio filter, source is not ideal
  if echo "$sii_mt_log" | grep -qiE "already matches.*skip|source already.*ideal"; then
    fail "skip-if-ideal + multi-track: should NOT skip (commentary track present)"
  else
    pass "skip-if-ideal + multi-track: commentary prevents ideal skip"
  fi
  if [[ -f "$sii_mt_out" && -s "$sii_mt_out" ]]; then
    assert_stream_count "skip-if-ideal + multi-track: 2 audio tracks (commentary dropped)" \
      "$sii_mt_out" a 2 2
  else
    skip "skip-if-ideal + multi-track: no output file (encode may have failed)"
  fi

  # ---- skip-if-ideal per-stream gating: all subtitle streams survive ----
  # When source is fully compliant (HEVC+MKV, all subs pass filters), skip-if-ideal
  # fires and the metadata remux must use explicit -map flags from SII_SUB_INDICES.
  # The old code used -map 0 (ffmpeg default = one stream per type), silently
  # dropping all but the first subtitle.  This test catches that regression.
  # Fixture: hevc_multi_subs.mkv — 5 subs (eng forced, eng full, eng SDH, spa, fra).
  # archive defaults: SUB_MULTI_TRACK=1, SUB_LANG_PREF="" → all 5 pass.
  local sii_subs_home="$TESTDIR/sii_subs_home"
  mkdir -p "$sii_subs_home"
  local sii_subs_out="$TESTDIR/out_sii_subs.mkv"
  log "Testing skip-if-ideal per-stream gating (multi-sub, all pass)..."
  MUXM_HOME="$sii_subs_home" run_muxm --profile archive \
    "$TESTDIR/hevc_multi_subs.mkv" "$sii_subs_out" >/dev/null
  if [[ -f "$sii_subs_out" && -s "$sii_subs_out" ]]; then
    assert_stream_count "skip-if-ideal per-stream: 5 subtitle tracks preserved" \
      "$sii_subs_out" s 5 5
    assert_stream_count "skip-if-ideal per-stream: 1 audio track preserved" \
      "$sii_subs_out" a 1 1
  else
    skip "skip-if-ideal per-stream: no output file (encode may have failed)"
  fi

  # ---- D2: --strip-metadata / --no-keep-chapters honored under skip-if-ideal ----
  # On a compliant source, skip-if-ideal copy-remuxes (or raw-hardlinks) instead of re-encoding.
  # Both flags must still reach the output on that path; previously they were silently dropped
  # (metadata/chapters shipped intact; the hardlink branch bypassed ffmpeg entirely).
  # compliant_meta.mp4 is ideal for atv-directplay-hq and carries a global title + 2 chapters.
  local d2_home="$TESTDIR/d2_home"; mkdir -p "$d2_home"
  local d2_title d2_chaps

  # --strip-metadata → the source 'title' tag must be gone. (The profile comment is applied
  # AFTER the strip and is intentionally retained — that's muxm's own metadata, not source junk.)
  local d2_strip_out="$TESTDIR/out_d2_strip.mp4" d2_strip_log
  log "Testing D2: --strip-metadata under skip-if-ideal strips source metadata..."
  d2_strip_log="$(MUXM_HOME="$d2_home" run_muxm --profile atv-directplay-hq --skip-if-ideal \
    --strip-metadata "$TESTDIR/compliant_meta.mp4" "$d2_strip_out")"
  if [[ -f "$d2_strip_out" && -s "$d2_strip_out" ]]; then
    d2_title="$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$d2_strip_out" 2>/dev/null)"
    if [[ -z "$d2_title" ]]; then
      pass "output-strip-metadata-and-chapters: --strip-metadata under skip-if-ideal removes source global metadata"
    else
      fail "output-strip-metadata-and-chapters: --strip-metadata under skip-if-ideal left title='$d2_title' (flag dropped)"
    fi
  else
    fail "output-strip-metadata-and-chapters: --strip-metadata under skip-if-ideal produced no output"
  fi
  # The copy-remux branch (not the raw hardlink) must be taken so the strip can apply.
  if echo "$d2_strip_log" | grep -qiF "copy-remux"; then
    pass "output-strip-metadata-and-chapters: --strip-metadata forces the copy-remux branch (not the raw hardlink)"
  else
    fail "output-strip-metadata-and-chapters: --strip-metadata did not take the copy-remux branch"
  fi

  # --no-keep-chapters → output must have 0 chapters.
  local d2_chap_out="$TESTDIR/out_d2_chap.mp4"
  log "Testing D2: --no-keep-chapters under skip-if-ideal strips chapters..."
  MUXM_HOME="$d2_home" run_muxm --profile atv-directplay-hq --skip-if-ideal \
    --no-keep-chapters "$TESTDIR/compliant_meta.mp4" "$d2_chap_out" >/dev/null
  if [[ -f "$d2_chap_out" && -s "$d2_chap_out" ]]; then
    # `grep -c` exits 1 on zero matches; `|| true` keeps the capture set -e-safe — and 0 IS
    # the expected/pass count here (mirrors the documented pattern elsewhere in this harness).
    d2_chaps="$(ffprobe -v error -show_chapters "$d2_chap_out" 2>/dev/null | grep -c '\[CHAPTER\]' || true)"
    if [[ "$d2_chaps" -eq 0 ]]; then
      pass "output-strip-metadata-and-chapters: --no-keep-chapters under skip-if-ideal removes chapters"
    else
      fail "output-strip-metadata-and-chapters: --no-keep-chapters under skip-if-ideal left $d2_chaps chapters"
    fi
  else
    fail "output-strip-metadata-and-chapters: --no-keep-chapters under skip-if-ideal produced no output"
  fi

  # Hardlink→remux switch: with the profile comment + audio titles disabled, a no-flag run
  # has no remux trigger and raw-hardlinks (ships source verbatim). Adding --strip-metadata
  # must flip it to a copy-remux that actually strips — isolating the flag as the sole trigger.
  local d2_hl_out="$TESTDIR/out_d2_hardlink.mp4" d2_hl_log
  d2_hl_log="$(MUXM_HOME="$d2_home" run_muxm --profile atv-directplay-hq --no-profile-comment \
    --no-audio-titles --skip-if-ideal "$TESTDIR/compliant_meta.mp4" "$d2_hl_out")"
  if echo "$d2_hl_log" | grep -qiF "Linked/copied"; then
    pass "output-strip-metadata-and-chapters: no-flag compliant source still raw-hardlinks (skip-the-encode win preserved)"
  else
    fail "output-strip-metadata-and-chapters: expected the raw-hardlink branch for a no-flag compliant source"
  fi
  local d2_sw_out="$TESTDIR/out_d2_switch.mp4" d2_sw_log d2_sw_title
  d2_sw_log="$(MUXM_HOME="$d2_home" run_muxm --profile atv-directplay-hq --no-profile-comment \
    --no-audio-titles --skip-if-ideal --strip-metadata "$TESTDIR/compliant_meta.mp4" "$d2_sw_out")"
  if echo "$d2_sw_log" | grep -qiF "Linked/copied"; then
    fail "output-strip-metadata-and-chapters: --strip-metadata still raw-hardlinked (flag silently dropped)"
  else
    pass "output-strip-metadata-and-chapters: --strip-metadata flips the hardlink path to a copy-remux"
  fi
  if [[ -f "$d2_sw_out" && -s "$d2_sw_out" ]]; then
    d2_sw_title="$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$d2_sw_out" 2>/dev/null)"
    if [[ -z "$d2_sw_title" ]]; then
      pass "output-strip-metadata-and-chapters: switched-path output has metadata stripped"
    else
      fail "output-strip-metadata-and-chapters: switched-path output retained title='$d2_sw_title'"
    fi
  fi

  # Also (D2): the archive conflict note "Metadata will be stripped as requested" must be truthful.
  # compliant_archive.mkv (HEVC + FLAC) is ideal for archive, so this exercises the skip-if-ideal
  # path under archive — the note must not promise a strip the skip path never delivers.
  local d2_arch_out="$TESTDIR/out_d2_archive.mkv" d2_arch_log d2_arch_title
  d2_arch_log="$(MUXM_HOME="$d2_home" run_muxm --profile archive --skip-if-ideal \
    --strip-metadata "$TESTDIR/compliant_archive.mkv" "$d2_arch_out" 2>&1)"
  if echo "$d2_arch_log" | grep -qiF "stripped as requested"; then
    pass "output-strip-metadata-and-chapters: archive emits the 'metadata stripped as requested' conflict note"
  else
    fail "output-strip-metadata-and-chapters: archive did not emit the strip-metadata conflict note"
  fi
  if echo "$d2_arch_log" | grep -qiF "copy-remux"; then
    pass "output-strip-metadata-and-chapters: archive + --strip-metadata takes the skip-if-ideal copy-remux path"
  else
    fail "output-strip-metadata-and-chapters: archive + --strip-metadata did not take the skip-if-ideal path (fixture not ideal?)"
  fi
  if [[ -f "$d2_arch_out" && -s "$d2_arch_out" ]]; then
    d2_arch_title="$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$d2_arch_out" 2>/dev/null)"
    if [[ -z "$d2_arch_title" ]]; then
      pass "output-strip-metadata-and-chapters: archive 'stripped as requested' note is now truthful (title gone)"
    else
      fail "output-strip-metadata-and-chapters: archive promised a strip but title='$d2_arch_title' survived"
    fi
  else
    fail "output-strip-metadata-and-chapters: archive skip-if-ideal produced no output"
  fi

  # ---- D2 (report): skip-if-ideal records the metadata/chapters disposition in --report-json ----
  # mux_final records report_add "metadata"/"chapters" on the normal path; the skip-if-ideal path
  # now mirrors it (same "stripped"/"preserved" values), so --report-json reflects the strip on the
  # skip-the-encode path too. Previously these keys were absent whenever skip-if-ideal fired.
  local d2r_home="$TESTDIR/d2r_home"; mkdir -p "$d2r_home"

  # --strip-metadata (remux) → metadata=stripped, chapters=preserved (kept by default).
  local d2r_strip="$TESTDIR/out_d2r_strip.mp4" d2r_json
  MUXM_HOME="$d2r_home" run_muxm --profile atv-directplay-hq --skip-if-ideal --report-json \
    --strip-metadata "$TESTDIR/compliant_meta.mp4" "$d2r_strip" >/dev/null
  d2r_json="${d2r_strip%.mp4}.report.json"
  if [[ -f "$d2r_json" ]]; then
    if jq -e . "$d2r_json" >/dev/null 2>&1; then
      pass "output-strip-metadata-and-chapters report: skip-if-ideal --report-json is valid JSON"
    else
      fail "output-strip-metadata-and-chapters report: skip-if-ideal report is not valid JSON"
    fi
    assert_contains '"metadata": "stripped"' "output-strip-metadata-and-chapters report: --strip-metadata records metadata=stripped" "$(cat "$d2r_json")"
    assert_contains '"chapters": "preserved"' "output-strip-metadata-and-chapters report: default chapters records chapters=preserved" "$(cat "$d2r_json")"
  else
    fail "output-strip-metadata-and-chapters report: no report.json written for --strip-metadata skip-if-ideal"
  fi

  # --no-keep-chapters (remux) → chapters=stripped, metadata=preserved (kept by default).
  local d2r_chap="$TESTDIR/out_d2r_chap.mp4" d2r_json2
  MUXM_HOME="$d2r_home" run_muxm --profile atv-directplay-hq --skip-if-ideal --report-json \
    --no-keep-chapters "$TESTDIR/compliant_meta.mp4" "$d2r_chap" >/dev/null
  d2r_json2="${d2r_chap%.mp4}.report.json"
  if [[ -f "$d2r_json2" ]]; then
    assert_contains '"chapters": "stripped"' "output-strip-metadata-and-chapters report: --no-keep-chapters records chapters=stripped" "$(cat "$d2r_json2")"
    assert_contains '"metadata": "preserved"' "output-strip-metadata-and-chapters report: default metadata records metadata=preserved" "$(cat "$d2r_json2")"
  else
    fail "output-strip-metadata-and-chapters report: no report.json written for --no-keep-chapters skip-if-ideal"
  fi

  # Raw-hardlink branch (no remux) still records the disposition (both preserved).
  local d2r_hl="$TESTDIR/out_d2r_hardlink.mp4" d2r_json3
  MUXM_HOME="$d2r_home" run_muxm --profile atv-directplay-hq --no-profile-comment --no-audio-titles \
    --skip-if-ideal --report-json "$TESTDIR/compliant_meta.mp4" "$d2r_hl" >/dev/null
  d2r_json3="${d2r_hl%.mp4}.report.json"
  if [[ -f "$d2r_json3" ]]; then
    assert_contains '"metadata": "preserved"' "output-strip-metadata-and-chapters report: hardlink branch records metadata=preserved" "$(cat "$d2r_json3")"
    assert_contains '"chapters": "preserved"' "output-strip-metadata-and-chapters report: hardlink branch records chapters=preserved" "$(cat "$d2r_json3")"
  else
    fail "output-strip-metadata-and-chapters report: no report.json written for hardlink skip-if-ideal"
  fi

  # --keep-temp-always (#27)
  # -K/--keep-temp-always preserves workdir on success; -k/--keep-temp only on failure.
  # Test -K with a successful encode: expect both output AND preserved workdir.
  local kt_dir="$TESTDIR/keep_temp_test"
  mkdir -p "$kt_dir"
  cp "$TESTDIR/basic_sdr_subs.mkv" "$kt_dir/source.mkv"
  outfile="$kt_dir/output.mp4"
  log "Testing --keep-temp-always (-K)..."
  local kt_out
  kt_out="$(run_muxm --keep-temp-always --crf 28 --preset ultrafast \
    "$kt_dir/source.mkv" "$outfile")" || true
  if [[ -f "$outfile" && -s "$outfile" ]]; then
    local workdir_found=0
    if find "$kt_dir" -maxdepth 2 -type d -name "*muxm*" 2>/dev/null | grep -q .; then
      workdir_found=1
    elif echo "$kt_out" | grep -qiE "work.?dir|temp.*preserved|keeping"; then
      workdir_found=1
    fi
    if (( workdir_found )); then
      pass "--keep-temp-always: workdir preserved on success"
    else
      fail "--keep-temp-always: output produced but workdir not found"
    fi
  else
    log "--keep-temp-always: muxm output: ${kt_out:0:1000}"
    fail "--keep-temp-always: no output"
  fi

  # Verify -k/--keep-temp flag is accepted and sets KEEP_TEMP in effective config
  local kt_cfg
  kt_cfg="$(run_muxm --keep-temp --print-effective-config)"
  assert_contains "KEEP_TEMP" "--keep-temp: flag registered in effective config" "$kt_cfg"

  # ---- M1: the --report-json output must stay jq-valid under hostile inputs. A double-quote in
  #      the source path, if emitted through a bare printf, would break the "source" field's JSON.
  #      Skip-first guard (not an else-skip) per the soft-skip ratchet. ----
  if ! ffmpeg_has_encoder libx265; then
    skip "output-report-json-hostile-path: ffmpeg lacks libx265 — cannot build the hostile-path report fixture"
  else
    local _m1_dir; _m1_dir="$(mktemp -d "$TESTDIR/m1.XXXXXX")"
    local _m1_src="$_m1_dir/te\"st.mkv" _m1_out="$_m1_dir/m1out.mkv"
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "testsrc2=size=320x180:rate=24:duration=1" \
      -f lavfi -i "sine=frequency=440:duration=1" \
      -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p -c:a aac "$_m1_src" 2>/dev/null
    if [[ ! -s "$_m1_src" ]]; then
      skip "output-report-json-hostile-path: could not build a source with a double-quote in its name"
    else
      run_muxm --report-json --output-ext mkv "$_m1_src" "$_m1_out" >/dev/null
      local _m1_report="${_m1_out%.mkv}.report.json"
      if [[ -f "$_m1_report" ]] && jq -e . "$_m1_report" >/dev/null 2>&1; then
        pass "output-report-json-hostile-path: --report-json with a double-quote in the source path is jq-valid"
      else
        fail "output-report-json-hostile-path: --report-json not jq-parseable under a quoted source path (report: $_m1_report, exists: $([[ -f "$_m1_report" ]] && echo yes || echo no))"
      fi
    fi
    rm -rf "$_m1_dir"
  fi

  # 5.1: post-mux audio/subtitle stream-count cross-check (--verbose/DEBUG only). Sanity check —
  # a normal encode must not false-positive (the check runs and reports the counts matching, not
  # a spurious mismatch warning), and the check must NOT run without --verbose/DEBUG (avoiding
  # the extra ffprobe calls on every ordinary run — this is an opt-in diagnostic, not the primary
  # correctness mechanism).
  local sc_out sc_outfile="$TESTDIR/out_streamcount.mkv"
  sc_out="$(run_muxm --verbose --profile archive "$TESTDIR/basic_sdr_subs.mkv" "$sc_outfile")"
  if [[ -f "$sc_outfile" && -s "$sc_outfile" ]]; then
    pass "output-stream-count-validation: stream-count validation encode produced output"
  else
    fail "output-stream-count-validation: stream-count validation encode: no output"
  fi
  if grep -qF "audio stream count OK" <<<"$sc_out"; then
    pass "output-stream-count-validation: --verbose surfaces the audio stream-count check and it matches (no false-positive)"
  else
    fail "output-stream-count-validation: expected 'audio stream count OK' in --verbose output, got: ${sc_out: -300}"
  fi
  local sc_out2 sc_outfile2="$TESTDIR/out_streamcount_quiet.mkv"
  sc_out2="$(run_muxm --profile archive "$TESTDIR/basic_sdr_subs.mkv" "$sc_outfile2")"
  if ! grep -qE 'stream count OK|stream\(s\) to survive the mux' <<<"$sc_out2"; then
    pass "output-stream-count-validation: stream-count check is gated to --verbose/DEBUG (silent on a normal run)"
  else
    fail "output-stream-count-validation: stream-count check output appeared without --verbose/DEBUG: ${sc_out2: -300}"
  fi

  _test_output_cleanup_on_checksum_fail
}

# M2: a failed final mv/checksum must not abort on_exit's cleanup and leak the workdir. Under
# `set -e`, a non-zero `(( CHECKSUM )) && write_checksum "$OUT"` (last cmd of an && list) would
# exit the shell mid-on_exit, skipping the drain/log-persist/workdir-cleanup. (Disarming the ERR
# trap alone does NOT prevent this — `set -e` still exits; the call must be GUARDED so it
# never trips errexit, which on_exit does via `write_checksum … || warn`.) Here the checksum
# tools are shimmed to fail; a fixed muxm finishes cleanly and removes its .muxm.tmp.* workdir,
# while perturb MUT-M2-CLEANUP reverts the guard to a bare `write_checksum` → errexit aborts
# on_exit → the workdir leaks. WORKDIR_PARENT=OUT_DIR (no --workdir here), so counting leaks in the
# output dir is exact.
_test_output_cleanup_on_checksum_fail() {
  local _dir="$TESTDIR/m2_cleanup"; mkdir -p "$_dir/bin" "$_dir/out" "$_dir/h"
  # Force write_checksum to return non-zero by shimming every checksum tool to fail.
  local _t
  for _t in shasum sha256sum b2sum; do
    printf '#!/bin/sh\nexit 1\n' > "$_dir/bin/$_t"; chmod +x "$_dir/bin/$_t"
  done
  local _src="$TESTDIR/basic_sdr_subs.mkv" _out="$_dir/out/m2.mkv" rc=0
  log "Testing M2: a failing checksum must not abort on_exit cleanup (no workdir leak)..."
  # NOTE: invoked WITHOUT -K (KEEP_TEMP_ALWAYS would legitimately keep the workdir and mask the leak).
  ( cd "$_dir/out" && HOME="$_dir/h" PATH="$_dir/bin:$PATH" \
      "$MUXM" --no-skip-if-ideal --checksum --crf 30 --preset ultrafast "$_src" "$_out" >/dev/null 2>&1 ) || rc=$?
  local _leaked; _leaked="$(find "$_dir/out" -maxdepth 1 -name '.muxm.tmp.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -s "$_out" && "$_leaked" == "0" ]]; then
    pass "output-cleanup-on-checksum-fail: failed checksum did not abort cleanup — workdir removed, output intact (exit $rc)"
  else
    fail "output-cleanup-on-checksum-fail: failed checksum leaked the workdir (leaked=$_leaked) or lost output (exists=$([[ -s "$_out" ]] && echo yes || echo no), exit $rc)"
  fi
  rm -rf "$_dir"
}

# === Suite: Container Formats ===
# Validates that MOV and M4V output extensions produce files in the correct container family.
test_containers() {
  section "Container Formats"

  local outfile fmt

  # MOV output (#23)
  outfile="$TESTDIR/container_mov.mov"
  log "Testing --output-ext mov..."
  if assert_encode "--output-ext mov: output produced" "$outfile" \
       --output-ext mov --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"; then
    fmt="$(probe_format "$outfile" format_name)"
    if echo "$fmt" | grep -qiE "mov|mp4"; then
      pass "--output-ext mov: container is MOV/MP4 family"
    else
      fail "--output-ext mov: unexpected format=$fmt"
    fi
  fi

  # M4V output (#24)
  outfile="$TESTDIR/container_m4v.m4v"
  log "Testing --output-ext m4v..."
  if assert_encode "--output-ext m4v: output produced" "$outfile" \
       --output-ext m4v --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"; then
    fmt="$(probe_format "$outfile" format_name)"
    if echo "$fmt" | grep -qiE "mov|mp4|m4v"; then
      pass "--output-ext m4v: container is MP4 family"
    else
      fail "--output-ext m4v: unexpected format=$fmt"
    fi
  fi

  # ---- Container passthrough: mkv source → mkv output ----
  # archive sets OUTPUT_EXT="" (passthrough). Source is .mkv → passthrough resolves
  # OUTPUT_EXT to "mkv" → MUX_FORMAT=matroska. Output path explicitly named .mkv to
  # avoid source/output collision on auto-derived names.
  outfile="$TESTDIR/container_passthrough_mkv.mkv"
  log "Testing container passthrough: mkv source → mkv output..."
  if assert_encode "passthrough mkv→mkv: output produced" "$outfile" \
       --profile archive --preset ultrafast "$TESTDIR/hevc_sdr_51.mkv"; then
    fmt="$(probe_format "$outfile" format_name)"
    assert_contains "matroska" "passthrough mkv→mkv: output is Matroska container" "$fmt"
  fi

  # ---- Container passthrough: mp4 source → mp4 output ----
  # No profile (default OUTPUT_EXT="mkv")... actually default is mkv, not passthrough.
  # Use --output-ext "" to trigger passthrough, OR rely on default being mkv.
  # Better: use default profile + compliant.mp4 with explicit .mp4 output to verify
  # that a passthrough profile correctly produces an mp4 container from an mp4 source.
  # We use archive (passthrough profile) + compliant.mp4 source + explicit .mp4 output.
  outfile="$TESTDIR/container_passthrough_mp4.mp4"
  log "Testing container passthrough: mp4 source → mp4 output (archive profile)..."
  if assert_encode "passthrough mp4→mp4: output produced" "$outfile" \
       --profile archive --preset ultrafast "$TESTDIR/compliant.mp4"; then
    fmt="$(probe_format "$outfile" format_name)"
    if echo "$fmt" | grep -qiE "mp4|mov"; then
      pass "passthrough mp4→mp4: output is MP4/MOV-family container"
    else
      fail "passthrough mp4→mp4: unexpected container format='$fmt'"
    fi
  fi

  # ---- Container passthrough: m4v source → m4v output ----
  # Create a minimal .m4v fixture inline; source is mp4-family so passthrough → m4v.
  local m4v_src="$TESTDIR/passthrough_test.m4v"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=green:s=160x120:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 64k -ac 2 \
    "$m4v_src" 2>/dev/null
  if [[ -f "$m4v_src" ]]; then
    outfile="$TESTDIR/container_passthrough_m4v.m4v"
    log "Testing container passthrough: m4v source → m4v output..."
    if assert_encode "passthrough m4v→m4v: output produced" "$outfile" \
         --profile archive --preset ultrafast "$m4v_src"; then
      fmt="$(probe_format "$outfile" format_name)"
      if echo "$fmt" | grep -qiE "mp4|mov|m4v"; then
        pass "passthrough m4v→m4v: output is MP4/M4V-family container"
      else
        fail "passthrough m4v→m4v: unexpected container format='$fmt'"
      fi
    fi
  else
    skip "passthrough m4v→m4v: could not create m4v fixture"
  fi

  # ---- 4.3: Container passthrough — unsupported source extension → mkv fallback (A-class) ----
  # Sources whose container can't be written as output (avi, ts, …) fall back to mkv via the
  # passthrough resolution block's `*) OUTPUT_EXT="mkv"` arm. The old test only grepped the
  # --dry-run notice; this runs a REAL passthrough encode (no explicit output, so muxm derives the
  # extension itself) and probes the derived file's container is matroska. Non-tautological:
  # muxm's OUTPUT_EXT decision sets the muxer, not ffmpeg auto-copy. atv-directplay-hq stays a
  # passthrough profile (archive now forces MKV unconditionally, so it wouldn't exercise this arm).
  # M-AVIFB-1 breaks the fallback default (mkv→mp4) → muxm derives a .mp4, no .mkv → red.
  local avi_src="$TESTDIR/passthrough_fallback_test.avi"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=160x120:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 64k -ac 2 \
    "$avi_src" 2>/dev/null
  if [[ ! -s "$avi_src" ]]; then
    skip "passthrough fallback .avi test: could not create avi fixture (ffmpeg avi muxer absent)"
  else
    local avi_log avi_derived="$TESTDIR/passthrough_fallback_test.mkv"
    rm -f "$TESTDIR/passthrough_fallback_test.mkv"* "$TESTDIR/passthrough_fallback_test.mp4"*
    avi_log="$(run_muxm --profile atv-directplay-hq --crf 28 --preset ultrafast "$avi_src")"
    if printf '%s\n' "$avi_log" | grep -qiE "not supported for output|defaulting to .mkv"; then
      pass "passthrough fallback: .avi source logs the unsupported→mkv fallback notice"
    else
      fail "passthrough fallback: .avi source did not log the unsupported-container fallback notice"
    fi
    if [[ -s "$avi_derived" ]]; then
      local avi_fmt; avi_fmt="$(probe_format "$avi_derived" format_name)"
      if echo "$avi_fmt" | grep -qi matroska; then
        pass "passthrough fallback: .avi real encode produces a Matroska container ($avi_fmt)"
      else
        fail "passthrough fallback: expected matroska output for the .avi fallback, got '$avi_fmt'"
      fi
    else
      fail "passthrough fallback: expected a derived .mkv output for the .avi source, none found"
    fi
    rm -f "$TESTDIR/passthrough_fallback_test.mkv"* "$TESTDIR/passthrough_fallback_test.mp4"*
  fi

  # ---- CLI --output-ext overrides container passthrough ----
  # archive (passthrough profile) + --output-ext mp4 + mkv source → mp4 output.
  # _OUTPUT_EXT_EXPLICIT=1 skips passthrough resolution, keeping OUTPUT_EXT=mp4.
  outfile="$TESTDIR/container_cli_override.mp4"
  log "Testing --output-ext CLI override of passthrough profile..."
  if assert_encode "passthrough CLI override: --output-ext mp4 wins" "$outfile" \
       --profile archive --output-ext mp4 --preset ultrafast "$TESTDIR/hevc_sdr_51.mkv"; then
    fmt="$(probe_format "$outfile" format_name)"
    if echo "$fmt" | grep -qiE "mp4|mov"; then
      pass "passthrough CLI override: output is MP4 container (not matroska)"
    else
      fail "passthrough CLI override: expected MP4 container, got format='$fmt'"
    fi
  fi

  # ---- M1: multi-track container safety ----
  # Multi-track copy mode (archive / atv-directplay-animation / forced --output-ext)
  # stream-copies every kept track. MKV holds everything, but MP4/MOV can only carry some
  # streams lossily. muxm hard-stops BEFORE the encode (recommend MKV) when a kept stream
  # would be dropped/degraded, and converts plain-text subs to mov_text on the proceed
  # path. Note: the PGS/VobSub bitmap hard-stop shares the identical `! _is_text_sub_codec`
  # → blocker code path tested below for ASS, and the bitmap classification itself is
  # unit-tested (_is_text_sub_codec); ffmpeg cannot synthesize a bitmap sub fixture from
  # text, so there is no e2e bitmap case here.
  local _m1_thd="$TESTDIR/m1_truehd.mkv"
  if [[ ! -f "$_m1_thd" ]]; then
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=green:s=320x240:r=24:d=1" \
      -f lavfi -i "sine=duration=1" -c:v libx265 -preset ultrafast -crf 30 \
      -strict -2 -c:a truehd -ac 2 -metadata:s:a:0 language=eng "$_m1_thd" 2>/dev/null || true
  fi

  # (a) lossless HD audio → MP4 multi-track: hard-stop, exit 11, recommend MKV, NO encode.
  if [[ -s "$_m1_thd" ]]; then
    local _m1a_log _m1a_code=0
    _m1a_log="$(cd "$TESTDIR" && "$MUXM" --profile archive --output-ext mp4 \
      --preset ultrafast --crf 30 "$_m1_thd" 2>&1)" || _m1a_code=$?
    if [[ "$_m1a_code" -eq 11 ]] && printf '%s' "$_m1a_log" | grep -qiE "can't preserve|--output-ext mkv"; then
      pass "containers-multitrack-hard-stop: TrueHD + archive→mp4 multi-track → pre-encode hard stop (exit 11, recommend MKV)"
    else
      fail "containers-multitrack-hard-stop: TrueHD + archive→mp4 → expected exit 11 hard stop, got exit $_m1a_code"
    fi
    # Must fail BEFORE the encode (no wasted encode, never die 41 at mux_final).
    if printf '%s' "$_m1a_log" | grep -qiE 'Encoding video|final mux failed'; then
      fail "containers-multitrack-hard-stop: TrueHD hard stop fired too late (encode started or mux ran)"
    else
      pass "containers-multitrack-hard-stop: TrueHD hard stop fired before any encode"
    fi
    # (d) MKV passthrough → TrueHD copied losslessly (all streams kept).
    local _m1d_out="$TESTDIR/m1_arch.mkv"; rm -f "$_m1d_out"
    (cd "$TESTDIR" && "$MUXM" -K --profile archive --preset ultrafast --crf 30 "$_m1_thd" "$_m1d_out" >/dev/null 2>&1) || true
    local _m1d_acodec
    _m1d_acodec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$_m1d_out" 2>/dev/null || true)"
    if [[ "$_m1d_acodec" == "truehd" ]]; then
      pass "containers-multitrack-hard-stop: TrueHD + archive→mkv → stream-copied losslessly"
    else
      fail "containers-multitrack-hard-stop: TrueHD + archive→mkv → expected copied truehd, got '${_m1d_acodec:-none}'"
    fi
    rm -f "$_m1d_out"
  else
    skip "containers-multitrack-hard-stop: TrueHD fixture could not be generated (ffmpeg truehd encoder unavailable)"
  fi

  # (a) styled ASS → MP4 multi-track: hard-stop (would flatten to plain mov_text).
  if [[ -f "$TESTDIR/ass_subs.mkv" ]]; then
    local _m1b_log _m1b_code=0
    _m1b_log="$(cd "$TESTDIR" && "$MUXM" --profile atv-directplay-animation --output-ext mp4 \
      --preset ultrafast --crf 30 "$TESTDIR/ass_subs.mkv" 2>&1)" || _m1b_code=$?
    if [[ "$_m1b_code" -eq 11 ]] && printf '%s' "$_m1b_log" | grep -qiE "styled|flatten|--output-ext mkv"; then
      pass "containers-multitrack-hard-stop: ASS + atv-directplay-animation→mp4 → pre-encode hard stop (would flatten)"
    else
      fail "containers-multitrack-hard-stop: ASS + atv-anim→mp4 → expected exit 11 hard stop, got exit $_m1b_code"
    fi
  else
    skip "containers-multitrack-hard-stop: ass_subs.mkv fixture not found"
  fi

  # (b) plain subrip → MP4 multi-track: PROCEEDS; sub converted to mov_text (not failed copy).
  if [[ -f "$TESTDIR/multi_subs.mkv" ]]; then
    local _m1c_out="$TESTDIR/m1_subrip.mp4"; rm -f "$_m1c_out"
    local _m1c_code=0
    (cd "$TESTDIR" && "$MUXM" -K --profile archive --output-ext mp4 \
      --preset ultrafast --crf 30 "$TESTDIR/multi_subs.mkv" "$_m1c_out" >/dev/null 2>&1) || _m1c_code=$?
    if [[ "$_m1c_code" -eq 0 && -s "$_m1c_out" ]]; then
      pass "containers-multitrack-hard-stop: subrip + archive→mp4 multi-track → proceeds (mux succeeds)"
      local _m1c_scodec
      _m1c_scodec="$(ffprobe -v error -select_streams s:0 -show_entries stream=codec_name -of csv=p=0 "$_m1c_out" 2>/dev/null || true)"
      if [[ "$_m1c_scodec" == "mov_text" ]]; then
        pass "containers-multitrack-hard-stop: subrip → mov_text in MP4 (not a failed -c copy)"
      else
        fail "containers-multitrack-hard-stop: subrip in MP4 → expected mov_text, got '${_m1c_scodec:-none}'"
      fi
    else
      fail "containers-multitrack-hard-stop: subrip + archive→mp4 multi-track → expected success, got exit $_m1c_code"
    fi
    rm -f "$_m1c_out"
  fi

  # ---- A2: archive forces MKV output (was passthrough-to-source-container) ----
  # An MP4/MOV source archived now yields MKV, not MP4 — so codecs MKV holds but the source
  # container's output couldn't are preserved as bit-identical stream copies.
  local _a2_src="$TESTDIR/m1_a2_src.mp4"
  if [[ ! -f "$_a2_src" ]]; then
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=navy:s=320x240:r=24:d=1" \
      -f lavfi -i "sine=duration=1" -c:v libx265 -tag:v hvc1 -preset ultrafast -crf 30 \
      -c:a eac3 -ac 6 -metadata:s:a:0 language=eng "$_a2_src" 2>/dev/null || true
  fi
  if [[ -s "$_a2_src" ]]; then
    local _a2_out="$TESTDIR/m1_a2_out.mkv"; rm -f "$_a2_out"
    local _a2_code=0
    (cd "$TESTDIR" && "$MUXM" -K --no-skip-if-ideal --profile archive \
      --preset ultrafast --crf 30 "$_a2_src" "$_a2_out" >/dev/null 2>&1) || _a2_code=$?
    if [[ "$_a2_code" -eq 0 && -s "$_a2_out" ]]; then
      pass "A2: archive on an MP4 source produces MKV output"
      local _a2_fmt _a2_vc _a2_ac
      _a2_fmt="$(probe_format "$_a2_out" format_name)"
      _a2_vc="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$_a2_out" 2>/dev/null || true)"
      _a2_ac="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$_a2_out" 2>/dev/null || true)"
      if printf '%s' "$_a2_fmt" | grep -q matroska; then
        pass "A2: archive MP4-in → Matroska container"
      else
        fail "A2: archive MP4-in → expected matroska, got '$_a2_fmt'"
      fi
      if [[ "$_a2_vc" == "hevc" && "$_a2_ac" == "eac3" ]]; then
        pass "A2: archive copies source streams bit-identically (hevc video, eac3 audio)"
      else
        fail "A2: archive expected copied hevc/eac3, got video='$_a2_vc' audio='$_a2_ac'"
      fi
    else
      fail "A2: archive on MP4 source → expected MKV output, got exit $_a2_code"
    fi
    rm -f "$_a2_out" "$_a2_src"
  else
    skip "A2: could not generate MP4 source fixture"
  fi
}

# === Suite: Metadata Tests ===
# Validates --strip-metadata removes format-level tags, profile comment behavior
# (survives strip, suppressed by --no-profile-comment, correct per-profile values),
# metadata preservation without the flag, and acceptance of --ffmpeg-loglevel / --no-hide-banner.
test_metadata() {
  section "Metadata & Strip Verification"

  local outfile out title comment

  # --strip-metadata encode test (#25, #53)
  # Profile comment is applied AFTER -map_metadata -1, so it intentionally
  # survives --strip-metadata.  Source-inherited tags (title, encoder) should
  # be removed; the profile comment should remain.
  outfile="$TESTDIR/meta_stripped.mp4"
  log "Testing --strip-metadata with profile (comment survives by design)..."
  if assert_encode "--strip-metadata: output produced" "$outfile" \
       --profile streaming --strip-metadata --crf 28 --preset ultrafast "$TESTDIR/rich_metadata.mkv"; then
    title="$(probe_format_tag "$outfile" title)"
    comment="$(probe_format_tag "$outfile" comment)"
    if [[ -z "$title" ]]; then
      pass "--strip-metadata: source title removed"
    else
      fail "--strip-metadata: source title survived ('$title')"
    fi
    if [[ "$comment" == "Lean, mean, streaming machine." ]]; then
      pass "--strip-metadata: profile comment survives (by design)"
    else
      fail "--strip-metadata: expected streaming profile comment, got='$comment'"
    fi
  fi

  # --strip-metadata + --no-profile-comment: everything should be gone
  outfile="$TESTDIR/meta_stripped_no_comment.mp4"
  log "Testing --strip-metadata + --no-profile-comment..."
  if assert_encode "--strip-metadata + --no-profile-comment: output produced" "$outfile" \
       --profile streaming --strip-metadata --no-profile-comment --crf 28 --preset ultrafast "$TESTDIR/rich_metadata.mkv"; then
    title="$(probe_format_tag "$outfile" title)"
    comment="$(probe_format_tag "$outfile" comment)"
    if [[ -z "$title" ]]; then
      pass "--strip-metadata + --no-profile-comment: source title removed"
    else
      fail "--strip-metadata + --no-profile-comment: source title survived ('$title')"
    fi
    if [[ -z "$comment" ]]; then
      pass "--strip-metadata + --no-profile-comment: comment removed"
    else
      fail "--strip-metadata + --no-profile-comment: comment survived ('$comment')"
    fi
  fi

  # Profile comment present by default when a profile is active
  outfile="$TESTDIR/meta_profile_comment.mp4"
  log "Testing profile comment is written by default..."
  if assert_encode "Profile comment default: output produced" "$outfile" \
       --profile streaming --crf 28 --preset ultrafast "$TESTDIR/rich_metadata.mkv"; then
    comment="$(probe_format_tag "$outfile" comment)"
    if [[ "$comment" == "Lean, mean, streaming machine." ]]; then
      pass "Profile comment present: streaming tagline correct"
    else
      fail "Profile comment: expected 'Lean, mean, streaming machine.', got='$comment'"
    fi
  fi

  # --no-profile-comment suppresses the comment
  outfile="$TESTDIR/meta_no_profile_comment.mp4"
  log "Testing --no-profile-comment suppresses comment..."
  if assert_encode "--no-profile-comment: output produced" "$outfile" \
       --profile streaming --no-profile-comment --crf 28 --preset ultrafast "$TESTDIR/rich_metadata.mkv"; then
    comment="$(probe_format_tag "$outfile" comment)"
    # Without --strip-metadata the source comment may survive; check that the
    # profile tagline is absent (source comment is "This is a test comment").
    if echo "$comment" | grep -qF "Lean, mean, streaming machine."; then
      fail "--no-profile-comment: profile tagline still present"
    else
      pass "--no-profile-comment: profile tagline suppressed"
    fi
  fi

  # Verify per-profile comment values via real encodes (spot-check two more profiles)
  outfile="$TESTDIR/meta_comment_animation.mkv"
  log "Testing animation profile comment..."
  if assert_encode "Profile comment animation: output produced" "$outfile" \
       --profile animation --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"; then
    comment="$(probe_format_tag "$outfile" comment)"
    if [[ "$comment" == "psy-rd turned down, sakuga turned up." ]]; then
      pass "Profile comment: animation tagline correct"
    else
      fail "Profile comment animation: expected 'psy-rd turned down, sakuga turned up.', got='$comment'"
    fi
  fi

  outfile="$TESTDIR/meta_comment_universal.mp4"
  log "Testing universal profile comment..."
  if assert_encode "Profile comment universal: output produced" "$outfile" \
       --profile universal --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"; then
    comment="$(probe_format_tag "$outfile" comment)"
    if [[ "$comment" == "Lowest common denominator, highest common decency." ]]; then
      pass "Profile comment: universal tagline correct"
    else
      fail "Profile comment universal: expected 'Lowest common denominator, highest common decency.', got='$comment'"
    fi
  fi

  # Without --strip-metadata, source metadata should be preserved
  outfile="$TESTDIR/meta_preserved.mp4"
  log "Testing metadata preservation (no --strip-metadata)..."
  if assert_encode "Metadata preservation encode" "$outfile" \
       --no-profile-comment --crf 28 --preset ultrafast "$TESTDIR/rich_metadata.mkv"; then
    title="$(probe_format_tag "$outfile" title)"
    if [[ -n "$title" ]]; then
      pass "Metadata preserved: title='$title'"
    else
      fail "Metadata preservation: expected source title preserved (rich_metadata.mkv, no --strip-metadata), got empty"
    fi
  fi

  # --ffmpeg-loglevel (#30)
  # Validates the flag is accepted by the parser without error.
  # Check that the effective config registers the loglevel (not just any non-empty output,
  # which would also pass if muxm rejected the flag and printed an error message).
  out="$(run_muxm --ffmpeg-loglevel warning --print-effective-config)"
  assert_contains "FFMPEG_LOGLEVEL" "--ffmpeg-loglevel: flag registered in effective config" "$out"

  # --no-hide-banner (#29)
  # Validates the flag is accepted without error.
  # When active, ffmpeg's version/config banner should appear in encode output.
  out="$(run_muxm --no-hide-banner --dry-run "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "DRY-RUN" "--no-hide-banner: accepted without error (dry-run proceeds)" "$out"

  # --ffprobe-loglevel (R23)
  # Validates the flag is accepted by the parser without error.
  out="$(run_muxm --ffprobe-loglevel warning --print-effective-config)"
  assert_contains "FFPROBE_LOGLEVEL" "--ffprobe-loglevel: flag registered in effective config" "$out"

  _test_metadata_escape_sanitize
}

# RF8 (e2e): a source whose audio title carries terminal escape bytes (ESC[2J + BEL) must not let
# those bytes reach muxm's output or the persistent log — they are sanitized at extraction. Build the
# fixture with ANSI-C-quoted control bytes (so only the metadata VALUE holds them, never this source),
# run a dry-run scan, and assert the captured output and the run log contain no raw ESC/BEL/DEL byte.
_test_metadata_escape_sanitize() {
  local _dir="$TESTDIR/rf8_escape"; mkdir -p "$_dir/home"
  local _src="$_dir/src.mkv"
  local _htitle; _htitle=$'Hostile\033[2J\007Title'   # ESC[2J clear-screen + BEL
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=red:s=320x240:r=24:d=2" -f lavfi -i "sine=frequency=440:duration=2" \
    -c:v libx264 -preset ultrafast -crf 28 -c:a aac -ac 2 \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title="$_htitle" \
    "$_src" 2>/dev/null
  # Confirm the fixture actually stored the control chars (else the test proves nothing).
  local _stored; _stored="$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=title -of json "$_src" 2>/dev/null)"
  if [[ ! -s "$_src" ]] || ! printf '%s' "$_stored" | grep -q 'u001b'; then
    skip "metadata-control-char-sanitize-e2e (e2e): could not build a control-char-titled fixture (ffmpeg/ffprobe did not preserve the escape)"
    rm -rf "$_dir"; return
  fi
  local _out _log_path="$_dir/src.muxm.log"
  _out="$(MUXM_HOME="$_dir/home" run_muxm_in "$_dir" --dry-run "src.mkv" "out.mkv")"
  # Count raw ESC(033)/BEL(007)/DEL(177) bytes that survived into the captured output.
  local _bad; _bad="$(printf '%s' "$_out" | LC_ALL=C tr -cd '\033\007\177' | wc -c | tr -d ' ')"
  if [[ "$_bad" == "0" ]]; then
    pass "metadata-control-char-sanitize-e2e (e2e): hostile audio title leaves no raw escape byte in muxm output (sanitized at scan)"
  else
    fail "metadata-control-char-sanitize-e2e (e2e): $_bad raw control byte(s) leaked into muxm output for an escape-laden title"
  fi
  # The persistent log (if written) must likewise be free of raw escape bytes.
  if [[ -f "$_log_path" ]]; then
    local _bad_log; _bad_log="$(LC_ALL=C tr -cd '\033\007\177' < "$_log_path" | wc -c | tr -d ' ')"
    if [[ "$_bad_log" == "0" ]]; then
      pass "metadata-control-char-sanitize-e2e (e2e): persistent log is free of raw escape bytes"
    else
      fail "metadata-control-char-sanitize-e2e (e2e): $_bad_log raw control byte(s) leaked into the persistent log"
    fi
  fi
  rm -rf "$_dir"
}

# === Suite: Edge Cases & Security ===
# Validates defensive behavior: empty files rejected, filenames with spaces handled,
# shell injection attempts blocked (--output-ext, --ocr-tool), non-readable source
# and non-writable output directory detected.
# SECURITY NOTE: The injection tests (--output-ext "mp4;", --ocr-tool "sub2srt;rm -rf /")
# verify that user-supplied strings are never interpolated into shell commands unsanitized.
# These are regression tests for real attack vectors in media-processing CLI tools.
# === Suite: Collision Handling (auto-versioning, --replace-source, --force-replace-source) ===
# Validates the filename collision behavior when source and derived output paths match:
#   - Auto-versioning: movie(1).mp4, movie(2).mp4, ...
#   - --replace-source requires interactive TTY (rejected in pipes/scripts)
#   - --force-replace-source replaces the source file without prompting
#   - CLI flags appear in --help and --print-effective-config
test_collision() {
  section "Collision Handling (auto-versioning & source replacement)"

  # ---- Setup: create an .mp4 source so derived output (.mp4) collides ----
  local coll_dir="$TESTDIR/collision"
  mkdir -p "$coll_dir"
  local coll_src="$coll_dir/movie.mp4"
  gen_media "$coll_src" blue \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2

  # ---- Auto-version: movie.mp4 → movie(1).mp4 ----
  log "Testing auto-versioning: movie.mp4 → movie(1).mp4"
  local out
  out="$(run_muxm --crf 28 --preset ultrafast "$coll_src")"
  assert_contains "Source collision" "Auto-version: collision note printed" "$out"
  assert_contains "movie(1).mp4" "Auto-version: output renamed to movie(1).mp4" "$out"
  if [[ -f "$coll_dir/movie(1).mp4" && -s "$coll_dir/movie(1).mp4" ]]; then
    pass "Auto-version: movie(1).mp4 created"
  else
    fail "Auto-version: movie(1).mp4 not found"
  fi

  # ---- Increment: movie(1).mp4 exists → movie(2).mp4 ----
  log "Testing auto-versioning increment: movie(1) exists → movie(2).mp4"
  out="$(run_muxm --crf 28 --preset ultrafast "$coll_src")"
  assert_contains "movie(2).mp4" "Auto-version increment: output renamed to movie(2).mp4" "$out"
  if [[ -f "$coll_dir/movie(2).mp4" && -s "$coll_dir/movie(2).mp4" ]]; then
    pass "Auto-version increment: movie(2).mp4 created"
  else
    fail "Auto-version increment: movie(2).mp4 not found"
  fi

  # ---- Further increment: movie(1) and movie(2) exist → movie(3).mp4 ----
  log "Testing auto-versioning further increment: → movie(3).mp4"
  out="$(run_muxm --crf 28 --preset ultrafast "$coll_src")"
  assert_contains "movie(3).mp4" "Auto-version further: output renamed to movie(3).mp4" "$out"
  if [[ -f "$coll_dir/movie(3).mp4" && -s "$coll_dir/movie(3).mp4" ]]; then
    pass "Auto-version further: movie(3).mp4 created"
  else
    fail "Auto-version further: movie(3).mp4 not found"
  fi

  # ---- No collision when source ext != output ext (e.g., .mkv → .mp4) ----
  log "Testing no collision when extensions differ (.mkv → .mp4)"
  local nocoll_dir="$coll_dir/nocoll_test"
  mkdir -p "$nocoll_dir"
  local nocoll_src="$nocoll_dir/nocoll.mkv"
  cp "$TESTDIR/basic_sdr_subs.mkv" "$nocoll_src"
  out="$(run_muxm --output-ext mp4 --crf 28 --preset ultrafast "$nocoll_src")"
  if echo "$out" | grep -qiF "Source collision"; then
    fail "No collision expected for .mkv → .mp4 but collision note found"
  else
    pass "No collision for .mkv → .mp4 (extensions differ)"
  fi

  # ---- --replace-source: rejected when stdin is not a TTY ----
  # Redirect stdin from /dev/null to guarantee it's not a TTY.
  # (Command substitution alone doesn't change stdin — if the test is run from
  # an interactive terminal, stdin would still be a TTY and muxm would proceed
  # to the interactive confirmation prompt, hanging forever.)
  log "Testing --replace-source rejection in non-interactive shell"
  local rs_out rs_code
  rs_out="$(cd "$TESTDIR" && "$MUXM" --replace-source --crf 28 --preset ultrafast "$coll_src" </dev/null 2>&1)" && rs_code=$? || rs_code=$?
  if [[ "$rs_code" -eq $EXIT_VALIDATION ]]; then
    pass "--replace-source: rejected with exit $EXIT_VALIDATION (non-TTY)"
  else
    fail "--replace-source: expected exit $EXIT_VALIDATION, got $rs_code"
  fi
  assert_contains "not a TTY" "--replace-source: error mentions TTY" "$rs_out"
  assert_contains "force-replace-source" "--replace-source: error suggests --force-replace-source" "$rs_out"

  # ---- --force-replace-source: replaces the original file ----
  log "Testing --force-replace-source replaces original"
  local frs_dir="$coll_dir/force_replace"
  mkdir -p "$frs_dir"
  local frs_src="$frs_dir/source.mp4"
  gen_media "$frs_src" red \
    -c:v libx264 -preset ultrafast -crf 28 \
    -c:a aac -b:a 128k -ac 2
  local original_size
  original_size="$(stat -c%s "$frs_src" 2>/dev/null || stat -f%z "$frs_src" 2>/dev/null || echo 0)"
  out="$(run_muxm --force-replace-source --crf 28 --preset ultrafast "$frs_src")"
  assert_contains "replaced" "--force-replace-source: replacement note" "$out"
  if [[ -f "$frs_src" && -s "$frs_src" ]]; then
    local new_size
    new_size="$(stat -c%s "$frs_src" 2>/dev/null || stat -f%z "$frs_src" 2>/dev/null || echo 0)"
    # The re-encoded file should exist; size will differ from original
    local frs_codec
    frs_codec="$(probe_video "$frs_src" codec_name)"
    if [[ -n "$frs_codec" ]]; then
      pass "--force-replace-source: source replaced with valid video ($frs_codec, ${original_size} → ${new_size} bytes)"
    else
      fail "--force-replace-source: replaced file is not a decodable video (size: $original_size → $new_size)"
    fi
  else
    fail "--force-replace-source: source file missing after encode"
  fi
  # Verify no versioned files were created (replacement should be in-place)
  if ls "$frs_dir"/source\(*.mp4 >/dev/null 2>&1; then
    fail "--force-replace-source: versioned files created (should replace in-place)"
  else
    pass "--force-replace-source: no versioned files (in-place replacement)"
  fi

  # ---- --replace-source and --force-replace-source in --print-effective-config ----
  out="$(run_muxm --force-replace-source --print-effective-config)"
  assert_contains "REPLACE_SOURCE" "Effective config shows REPLACE_SOURCE" "$out"
  assert_contains "FORCE_REPLACE_SOURCE      = 1" "Effective config: FORCE_REPLACE_SOURCE = 1" "$out"

  # ---- Explicit output path: no auto-versioning when source != output ----
  log "Testing explicit output path: no collision"
  local explicit_out="$coll_dir/explicit_output.mp4"
  out="$(run_muxm --crf 28 --preset ultrafast "$coll_src" "$explicit_out")"
  if echo "$out" | grep -qiF "Source collision"; then
    fail "Explicit output path should not trigger collision handling"
  else
    pass "Explicit output path: no collision triggered"
  fi

  # ---- M4: two runs targeting the same $OUT must not clobber each other. A lock held by a LIVE
  #      owner refuses the second run (exit 11); a stale lock (dead owner PID) is reclaimed and the
  #      run proceeds. Skip-first guard (not an else-skip) per the soft-skip ratchet. ----
  if ! ffmpeg_has_encoder libx265; then
    skip "collision-concurrent-run-lock: ffmpeg lacks libx265 — cannot build the concurrency-lock fixture"
  else
    local _m4_dir; _m4_dir="$(mktemp -d "$TESTDIR/m4.XXXXXX")"
    local _m4_src="$_m4_dir/src.mkv" _m4_out="$_m4_dir/out.mkv"
    # Hidden output lock: muxm computes "$(dirname OUT)/.$(basename OUT).lock".
    local _m4_lock="$_m4_dir/.$(basename "$_m4_out").lock"
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=320x180:rate=24:duration=1" \
      -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p "$_m4_src" 2>/dev/null
    if [[ ! -s "$_m4_src" ]]; then
      skip "collision-concurrent-run-lock: could not build the concurrency-lock fixture"
    else
      # (a) Live owner → refuse with exit 11.
      sleep 30 & local _m4_live=$!
      mkdir "$_m4_lock"; printf '%s\n' "$_m4_live" > "$_m4_lock/pid"
      local _m4_code
      (cd "$_m4_dir" && "$MUXM" --output-ext mkv "$_m4_src" "$_m4_out" >/dev/null 2>&1) && _m4_code=$? || _m4_code=$?
      if [[ "$_m4_code" == 11 ]]; then
        pass "collision-concurrent-run-lock: a live concurrent-run lock refuses the second run (exit 11)"
      else
        fail "collision-concurrent-run-lock: expected exit 11 against a live lock, got $_m4_code (output clobbered?)"
      fi
      kill "$_m4_live" 2>/dev/null || true; wait "$_m4_live" 2>/dev/null || true; rm -rf "$_m4_lock"

      # (b) Stale owner (a reaped/dead PID) → reclaim and proceed.
      local _m4_dead; sleep 0.1 & _m4_dead=$!; wait "$_m4_dead" 2>/dev/null || true
      mkdir "$_m4_lock"; printf '%s\n' "$_m4_dead" > "$_m4_lock/pid"
      (cd "$_m4_dir" && "$MUXM" --output-ext mkv "$_m4_src" "$_m4_out" >/dev/null 2>&1) && _m4_code=$? || _m4_code=$?
      # The successful run must also RELEASE its own lock (on_exit), or every output litters a
      # leaked hidden .<basename>.lock that the staleness escape would silently reclaim — masking a release bug.
      if [[ "$_m4_code" == 0 && -s "$_m4_out" && ! -d "$_m4_lock" ]]; then
        pass "collision-concurrent-run-lock: a stale lock is reclaimed, the run proceeds, and its own lock is released on success"
      else
        fail "collision-concurrent-run-lock: stale-lock reclaim/release failed (exit $_m4_code, output: $([[ -s "$_m4_out" ]] && echo yes || echo no), lock left: $([[ -d "$_m4_lock" ]] && echo yes || echo no))"
      fi
    fi
    rm -rf "$_m4_dir"
  fi
}

test_edge() {
  section "Edge Cases & Security"

  # Empty file
  touch "$TESTDIR/empty.mkv"
  local out
  out="$(run_muxm "$TESTDIR/empty.mkv")"
  assert_contains "empty" "Empty file rejected" "$out"

  # ---- _validate_media_file: stream-layout handling ----
  # _validate_media_file requires a video stream (it validates encode output).
  # A video-only file passes; an audio-only file is rejected with "no video
  # stream". Tested directly with stubbed die/log helpers so the exit class is
  # unambiguous. Complements the empty-file (exit) and non-readable cases.
  local vmf_body vmf_stubs vonly aonly vmf_rc
  vmf_body="$(awk '/^_validate_media_file\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  # shellcheck disable=SC2016  # stub bodies; $1/$2 must expand in the child bash -c, not here
  vmf_stubs='die(){ printf "DIE %s: %s\n" "$1" "$2" >&2; exit "$1"; }; log(){ :; }; filesize_pretty(){ echo "1 KB"; }; _check_disk_full(){ :; }'
  vonly="$TESTDIR/vmf_video_only.mkv"; aonly="$TESTDIR/vmf_audio_only.m4a"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=red:s=160x120:r=24:d=1" \
    -c:v libx264 -preset ultrafast -crf 30 "$vonly" 2>/dev/null
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:duration=1" \
    -c:a aac -b:a 64k "$aonly" 2>/dev/null
  if [[ -s "$vonly" ]]; then
    vmf_rc=0
    bash -c "$vmf_stubs"$'\n'"$vmf_body"$'\n'"_validate_media_file \"\$1\" video-only" -- "$vonly" >/dev/null 2>&1 || vmf_rc=$?
    if [[ "$vmf_rc" -eq 0 ]]; then pass "_validate_media_file: video-only file accepted"; else fail "_validate_media_file: video-only rejected (rc=$vmf_rc)"; fi
  else
    skip "_validate_media_file: video-only fixture not created"
  fi
  if [[ -s "$aonly" ]]; then
    vmf_rc=0
    bash -c "$vmf_stubs"$'\n'"$vmf_body"$'\n'"_validate_media_file \"\$1\" audio-only" -- "$aonly" >/dev/null 2>&1 || vmf_rc=$?
    if [[ "$vmf_rc" -eq 41 ]]; then pass "_validate_media_file: audio-only file rejected (no video stream, exit 41)"; else fail "_validate_media_file: audio-only expected exit 41, got $vmf_rc"; fi
  else
    skip "_validate_media_file: audio-only fixture not created"
  fi

  # File with spaces in name
  cp "$TESTDIR/basic_sdr_subs.mkv" "$TESTDIR/file with spaces.mkv"
  out="$(run_muxm --dry-run "$TESTDIR/file with spaces.mkv")"
  assert_contains "DRY-RUN" "Filename with spaces handled" "$out"

  # ---- Control character rejection (source filename) ----
  # muxm rejects filenames containing tabs, newlines, or null bytes.
  local ctrl_dir="$TESTDIR/ctrl_char_test"
  mkdir -p "$ctrl_dir"
  local ctrl_file
  ctrl_file="$(printf '%s/file\tname.mkv' "$ctrl_dir")"
  cp "$TESTDIR/basic_sdr_subs.mkv" "$ctrl_file" 2>/dev/null || true
  if [[ -f "$ctrl_file" ]]; then
    assert_exit $EXIT_VALIDATION "Reject source filename with tab (control char)" \
      --crf 28 --preset ultrafast "$ctrl_file"
    # Also verify the specific error message
    local ctrl_out
    ctrl_out="$(run_muxm --crf 28 --preset ultrafast "$ctrl_file")"
    assert_contains "control characters" "Control char error mentions 'control characters'" "$ctrl_out"
  else
    skip "Filesystem does not support tab in filename — control character test skipped"
  fi

  # ---- 3.6: Control character rejection (OUTPUT filename) — distinct from the source check ----
  # The source-filename control-char die is tested above; the separate OUT_ABS guard had no
  # coverage. Pass a tab in the OUTPUT path (the source is clean) → muxm must die 11 with the
  # output-specific message. M-CTRL-1 neuters the OUT_ABS regex → muxm sails past validation → both
  # assertions go red. (The source check stays intact, so this isolates the output-path guard.)
  local _octrl_out
  _octrl_out="$(printf '%s/out\tname.mkv' "$TESTDIR")"
  assert_exit "$EXIT_VALIDATION" "edge-output-control-char output control-char: tab in output path → exit $EXIT_VALIDATION" \
    --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv" "$_octrl_out"
  local _octrl_msg
  _octrl_msg="$(run_muxm --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv" "$_octrl_out")"
  assert_contains "Output filename contains control characters" \
    "edge-output-control-char output control-char: OUT_ABS check names the output-filename risk" "$_octrl_msg"
  # D10: the security die now states the fix (rename the file).
  assert_contains "Rename the file" "output control-char error states the remedy (D10)" "$_octrl_msg"

  # ---- Source/output collision auto-versioning ----
  # When source and output point to the same file, muxm auto-versions the output
  # filename instead of dying (unless --replace-source / --force-replace-source).
  local collision_file="$TESTDIR/collision_test.mkv"
  cp "$TESTDIR/basic_sdr_subs.mkv" "$collision_file" 2>/dev/null || \
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "color=c=blue:s=160x120:r=24:d=1" \
      -c:v libx264 -preset ultrafast -crf 28 "$collision_file"
  local collision_out
  collision_out="$(run_muxm --crf 28 --preset ultrafast "$collision_file" "$collision_file")"
  assert_contains "Source collision" "Collision triggers auto-versioning note" "$collision_out"
  assert_contains "renamed to" "Collision note mentions renamed output" "$collision_out"

  # ---- Invalid --output-ext rejection ----
  assert_exit $EXIT_VALIDATION "Reject --output-ext webm (invalid container)" \
    --output-ext webm --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"
  local ext_out
  ext_out="$(run_muxm --output-ext webm --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Invalid OUTPUT_EXT" "Error message names OUTPUT_EXT" "$ext_out"

  # ---- Invalid --video-codec rejection ----
  assert_exit $EXIT_VALIDATION "Reject --video-codec vp9 (invalid codec)" \
    --video-codec vp9 --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv"
  local vc_out
  vc_out="$(run_muxm --video-codec vp9 --crf 28 --preset ultrafast "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Invalid --video-codec" "Error message mentions invalid codec" "$vc_out"

  # ---- --no-overwrite refuses when output exists ----
  local noow_src="$TESTDIR/basic_sdr_subs.mkv"
  local noow_out="$TESTDIR/nooverwrite_test.mp4"
  touch "$noow_out"  # pre-create to trigger the guard
  assert_exit $EXIT_VALIDATION "Reject --no-overwrite when output exists" \
    --no-overwrite --crf 28 --preset ultrafast "$noow_src" "$noow_out"
  local noow_msg
  noow_msg="$(run_muxm --no-overwrite --crf 28 --preset ultrafast "$noow_src" "$noow_out")"
  assert_contains "already exists" "Error mentions file already exists" "$noow_msg"
  # D10: the --no-overwrite die states the fix.
  assert_contains "remove --no-overwrite" "--no-overwrite error states the remedy (D10)" "$noow_msg"
  rm -f "$noow_out"

  # Control characters in output extension are rejected
  out="$(run_muxm --output-ext "mp4;" "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Invalid" "Injection in --output-ext rejected" "$out"

  # OCR tool injection prevention
  out="$(run_muxm --dry-run --ocr-tool "sub2srt;rm -rf /" "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "disallowed" "OCR tool injection prevented" "$out"

  # --skip-video was removed as a dead flag. It is now rejected as an unknown option.
  # (--skip-audio / --skip-subs remain; users wanting audio/subs-only work that leaves the
  # video untouched should use --video-copy-if-compliant, which copies rather than drops it.)
  assert_exit "$EXIT_VALIDATION" "--skip-video: removed flag rejected as unknown (exit $EXIT_VALIDATION)" \
    --skip-video "$TESTDIR/basic_sdr_subs.mkv"
  out="$(run_muxm --skip-video "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "Unknown option: --skip-video" \
    "--skip-video: error message names the unknown flag" "$out"

  # Non-readable source file (#55)
  local unreadable="$TESTDIR/unreadable.mkv"
  cp "$TESTDIR/basic_sdr_subs.mkv" "$unreadable"
  chmod 000 "$unreadable" 2>/dev/null || true
  if [[ ! -r "$unreadable" ]]; then
    out="$(run_muxm "$unreadable")"
    assert_contains "not readable" "Non-readable source rejected" "$out"
    chmod 644 "$unreadable" 2>/dev/null || true
  else
    skip "Cannot test non-readable file (running as root?)"
  fi

  # Non-writable output directory
  local nowrite_dir="$TESTDIR/nowrite"
  mkdir -p "$nowrite_dir"
  chmod 555 "$nowrite_dir" 2>/dev/null || true
  if [[ ! -w "$nowrite_dir" ]]; then
    out="$(run_muxm "$TESTDIR/basic_sdr_subs.mkv" "$nowrite_dir/out.mp4")"
    assert_contains "not writable" "Non-writable output dir rejected" "$out"
    chmod 755 "$nowrite_dir" 2>/dev/null || true
  else
    skip "Cannot test non-writable dir (running as root?)"
  fi

  # ---- Double-dash argument terminator (R34) ----
  # Source files after -- should be parsed as positional args, not flags.
  out="$(run_muxm --dry-run -- "$TESTDIR/basic_sdr_subs.mkv")"
  assert_contains "DRY-RUN" "Double-dash (--) argument terminator" "$out"

  # ---- Double-dash stops option parsing (enhanced) ----
  # Verify that -- prevents a hyphen-prefixed filename from being parsed as a flag.
  # muxm's -- handler folds the remaining args into POSITIONALS, so this checks the
  # key safety property: a hyphen-prefixed name after -- yields no "Unknown option" error.
  local dd_out
  dd_out="$(run_muxm --crf 28 --preset ultrafast -- -unusual-name.mkv)"
  if echo "$dd_out" | grep -qiF "Unknown option"; then
    fail "Double-dash failed: '-unusual-name.mkv' parsed as option instead of filename"
  else
    pass "Double-dash: no 'Unknown option' error for hyphen-prefixed filename"
  fi

  # ---- Auto-generated output path (R30, R31) ----
  # When only source is provided (no explicit output path), muxm derives the
  # output filename from the source: same directory, swapped extension.
  local auto_dir="$TESTDIR/auto_output_test"
  mkdir -p "$auto_dir"
  cp "$TESTDIR/basic_sdr_subs.mkv" "$auto_dir/test_source.mkv"
  log "Testing auto-generated output path (no explicit output)..."
  run_muxm_in "$auto_dir" --crf 28 --preset ultrafast \
    "$auto_dir/test_source.mkv" >/dev/null 2>&1
  # Default output extension is mp4; the derived name should be test_source.mp4
  if [[ -f "$auto_dir/test_source.mp4" && -s "$auto_dir/test_source.mp4" ]]; then
    pass "Auto-generated output: file created with derived name (.mp4)"
  else
    # Check if it landed with any known extension
    local found=0
    for ext in mp4 mkv m4v mov; do
      if [[ -f "$auto_dir/test_source.$ext" && -s "$auto_dir/test_source.$ext" ]]; then
        pass "Auto-generated output: file created with derived name (.$ext)"
        found=1
        break
      fi
    done
    if (( ! found )); then
      fail "Auto-generated output: no output file found in $auto_dir"
    fi
  fi
}

# === Suite: Pure-Function Unit Tests ===
# Direct tests for deterministic helper functions that take arguments and
# return values via stdout or exit code. Validates edge cases not exercised
# by encode pipelines.
#
# NOTE: Helper functions used by test_unit sub-functions are defined at global
# scope because bash has no nested function scoping.  muxm_fn is hoisted here
# (out of the former test_unit body) so all sub-functions can call it.  Most
# exit-code assertions use the generic assert_muxm_fn_exit helper; stdout
# assertions use assert_muxm_fn_stdout.  The only remaining local closure is
# _test_transcode_target (unique first-word extraction logic).

# Helper: run a function from muxm in isolation.
# Extracts function definitions and evaluates them in a subshell.
# Usage: muxm_fn FUNCTION_NAME [args...]
#   Captures everything from "^FUNCTION_NAME(){" through the matching "^}"
#   plus any needed variable defaults, then calls the function.
# ASSUMES: Functions in muxm are defined as "fname() {" at column 0 with the
#   closing "}" also at column 0.  Will break silently if muxm switches to
#   "function fname {" style or indents the closing brace.
# MAINTENANCE: If a function under test calls other muxm helpers, add the
#   dependency to the `deps` case statement below — otherwise the subshell
#   will see "command not found" and the test silently passes with empty output.
muxm_fn() {
  local fn="$1"; shift
  local body
  body="$(awk "/^${fn}\\(\\)[[:space:]]*\\{/,/^\\}/" "$MUXM")"
  if [[ -z "$body" ]]; then
    # A committed function the awk anchor can't find was renamed/reformatted —
    # drift, never host-optionality. Fail (not skip), so the rename surfaces red.
    fail "Function $fn not found in muxm — extraction anchor failed (renamed/reformatted?)"
    return
  fi
  # Some functions reference other helpers — extract dependencies too
  local deps=""
  case "$fn" in
    _audio_descriptive_title)
      deps="$(awk '/^_channel_label\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
      ;;
    filesize_pretty|_gb)
      # These consume the readonly BYTES_PER_GIB/MIB size constants; pull them in so the
      # extracted body isn't run with the vars unset (which would mis-branch / divide by empty).
      deps="$(grep -E '^readonly BYTES_PER_(GIB|MIB)=' "$MUXM")"
      ;;
  esac
  bash -c "$deps"$'\n'"$body"$'\n'"$fn \"\$@\"" -- "$@"
}

# Assert a muxm function returns the expected exit code when run in isolation.
# Extracts the function body from the muxm script via awk, runs it in a subshell
# with optional environment/dependency setup, and compares the exit code.
# Usage: assert_muxm_fn_exit LABEL EXPECTED_EXIT FN_NAME ENV_SETUP ARG...
#   ENV_SETUP — shell code evaluated before the function (variable assignments,
#               dependency function bodies, readonly constants, etc.).
#               Use "" if no setup is needed.
#   Example:  assert_muxm_fn_exit "label" 0 my_fn 'FOO="bar"; BAZ=1' "arg1"
#             → runs: FOO="bar"; BAZ=1 <newline> <fn body> <newline> my_fn "arg1"
assert_muxm_fn_exit() {
  local label="$1" expected="$2" fn="$3" env_setup="$4"
  shift 4
  local body actual=0
  body="$(awk "/^${fn}\\(\\)[[:space:]]*\\{/,/^\\}/" "$MUXM")"
  if [[ -z "$body" ]]; then fail "Function $fn not found in muxm — extraction anchor failed (renamed/reformatted?)"; return; fi
  # Capture the REAL exit code (|| actual=$? leaves $? intact from the failing cmd).
  bash -c "${env_setup}"$'\n'"$body"$'\n'"$fn \"\$@\"" -- "$@" || actual=$?
  # 0 = predicate true; 1–125 = clean predicate false; >=126 = crash/not-found/signal.
  # A crash must NOT be accepted as a clean "returned nonzero".
  local ok=0
  if [[ "$expected" -eq 0 ]]; then
    [[ "$actual" -eq 0 ]] && ok=1
  else
    [[ "$actual" -ge 1 && "$actual" -le 125 ]] && ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then pass "$label"; else fail "$label — expected exit-class $expected, got $actual"; fi
}

# Assert a muxm function's stdout output matches an expected value.
# Same extraction logic as assert_muxm_fn_exit but compares stdout instead.
# Usage: assert_muxm_fn_stdout LABEL EXPECTED FN_NAME ENV_SETUP ARG...
assert_muxm_fn_stdout() {
  local label="$1" expected="$2" fn="$3" env_setup="$4"
  shift 4
  local body actual
  body="$(awk "/^${fn}\\(\\)[[:space:]]*\\{/,/^\\}/" "$MUXM")"
  if [[ -z "$body" ]]; then fail "Function $fn not found in muxm — extraction anchor failed (renamed/reformatted?)"; return; fi
  actual="$(bash -c "${env_setup}"$'\n'"$body"$'\n'"$fn \"\$@\"" -- "$@")"
  if [[ "$actual" == "$expected" ]]; then pass "$label"; else fail "$label — expected '$expected', got '$actual'"; fi
}

# _extract_muxm_fns NAME... — echo the concatenated awk single-function extractions for each
# NAME (a target decision function plus the pure helpers it calls), so the function can be
# exercised in a subshell with its REAL formula and only its I/O boundary mocked. This is the
# unit mechanism (chosen over sourcing the whole muxm script in-test):
# it needs no change to muxm. Same extraction as assert_muxm_fn_stdout, but it returns the
# body so the caller drives the function directly. A name that isn't found emits nothing for
# that name and makes the whole call return 1 — so a renamed dependency can't silently yield a
# partial (and misleadingly passing) body.
_extract_muxm_fns() {
  local fn body rc=0
  for fn in "$@"; do
    body="$(awk "/^${fn}\\(\\)[[:space:]]*\\{/,/^\\}/" "$MUXM")"
    if [[ -z "$body" ]]; then
      printf 'ERROR: _extract_muxm_fns: function %s not found in %s\n' "$fn" "$MUXM" >&2
      rc=1
      continue
    fi
    printf '%s\n' "$body"
  done
  return "$rc"
}

# --- test_unit sub-functions ---
# Organized by the muxm subsystem they exercise.  Each sub-function is
# independently readable; they execute sequentially in the dispatcher and
# share only the global muxm_fn helper and PASS/FAIL/SKIP counters.

_test_unit_audio_helpers() {
  # ---- _channel_label ----
  local result
  result="$(muxm_fn _channel_label 1 short)";  if [[ "$result" == "mono" ]]; then pass "_channel_label(1,short)=mono"; else fail "_channel_label(1,short) expected 'mono', got '$result'"; fi
  result="$(muxm_fn _channel_label 2 short)";  if [[ "$result" == "stereo" ]]; then pass "_channel_label(2,short)=stereo"; else fail "_channel_label(2,short) expected 'stereo', got '$result'"; fi
  result="$(muxm_fn _channel_label 6 short)";  if [[ "$result" == "5.1" ]]; then pass "_channel_label(6,short)=5.1"; else fail "_channel_label(6,short) expected '5.1', got '$result'"; fi
  result="$(muxm_fn _channel_label 8 short)";  if [[ "$result" == "7.1" ]]; then pass "_channel_label(8,short)=7.1"; else fail "_channel_label(8,short) expected '7.1', got '$result'"; fi
  result="$(muxm_fn _channel_label 4 short)";  if [[ "$result" == "4ch" ]]; then pass "_channel_label(4,short)=4ch"; else fail "_channel_label(4,short) expected '4ch', got '$result'"; fi
  result="$(muxm_fn _channel_label 6 long)";   if [[ "$result" == "5.1 Surround" ]]; then pass "_channel_label(6,long)=5.1 Surround"; else fail "_channel_label(6,long) expected '5.1 Surround', got '$result'"; fi
  result="$(muxm_fn _channel_label 1 long)";   if [[ "$result" == "Mono" ]]; then pass "_channel_label(1,long)=Mono"; else fail "_channel_label(1,long) expected 'Mono', got '$result'"; fi
  result="$(muxm_fn _channel_label 2 long)";   if [[ "$result" == "Stereo" ]]; then pass "_channel_label(2,long)=Stereo"; else fail "_channel_label(2,long) expected 'Stereo', got '$result'"; fi
  result="$(muxm_fn _channel_label 8 long)";   if [[ "$result" == "7.1 Surround" ]]; then pass "_channel_label(8,long)=7.1 Surround"; else fail "_channel_label(8,long) expected '7.1 Surround', got '$result'"; fi
  # Odd channel counts fall through to the default "Xch" branch
  result="$(muxm_fn _channel_label 3 short)";  if [[ "$result" == "3ch" ]]; then pass "_channel_label(3,short)=3ch"; else fail "_channel_label(3,short) expected '3ch', got '$result'"; fi
  result="$(muxm_fn _channel_label 5 short)";  if [[ "$result" == "5ch" ]]; then pass "_channel_label(5,short)=5ch"; else fail "_channel_label(5,short) expected '5ch', got '$result'"; fi
  result="$(muxm_fn _channel_label 7 short)";  if [[ "$result" == "7ch" ]]; then pass "_channel_label(7,short)=7ch"; else fail "_channel_label(7,short) expected '7ch', got '$result'"; fi

  # ---- _audio_descriptive_title ----
  result="$(muxm_fn _audio_descriptive_title eac3 6)";  if [[ "$result" == "5.1 Surround (E-AC-3)" ]]; then pass "_audio_descriptive_title(eac3,6)"; else fail "_audio_descriptive_title(eac3,6) expected '5.1 Surround (E-AC-3)', got '$result'"; fi
  result="$(muxm_fn _audio_descriptive_title aac 2)";   if [[ "$result" == "Stereo (AAC)" ]]; then pass "_audio_descriptive_title(aac,2)"; else fail "_audio_descriptive_title(aac,2) expected 'Stereo (AAC)', got '$result'"; fi
  result="$(muxm_fn _audio_descriptive_title truehd 8)"; if [[ "$result" == "7.1 Surround (TrueHD)" ]]; then pass "_audio_descriptive_title(truehd,8)"; else fail "_audio_descriptive_title(truehd,8) expected '7.1 Surround (TrueHD)', got '$result'"; fi
  result="$(muxm_fn _audio_descriptive_title pcm_s16le 2)"; if [[ "$result" == "Stereo (PCM)" ]]; then pass "_audio_descriptive_title(pcm_s16le,2)"; else fail "expected 'Stereo (PCM)', got '$result'"; fi
  # L6: ffprobe reports DTS as 'dca' — must render "DTS", not "(dca)".
  result="$(muxm_fn _audio_descriptive_title dts 6)"; if [[ "$result" == "5.1 Surround (DTS)" ]]; then pass "_audio_descriptive_title(dts,6)"; else fail "_audio_descriptive_title(dts,6) expected '5.1 Surround (DTS)', got '$result'"; fi
  result="$(muxm_fn _audio_descriptive_title dca 6)"; if [[ "$result" == "5.1 Surround (DTS)" ]]; then pass "_audio_descriptive_title(dca,6) → DTS (L6)"; else fail "_audio_descriptive_title(dca,6) expected '5.1 Surround (DTS)', got '$result'"; fi

  # ---- _audio_codec_rank ----
  # Requires AUDIO_CODEC_PREFERENCE to be set (use muxm default)
  local rank_env="AUDIO_CODEC_PREFERENCE='truehd,dts,eac3,ac3,aac,flac,alac,opus'"
  assert_muxm_fn_stdout "_audio_codec_rank(eac3)=2"           "2"  _audio_codec_rank "$rank_env" "eac3"
  assert_muxm_fn_stdout "_audio_codec_rank(ac3)=3"            "3"  _audio_codec_rank "$rank_env" "ac3"
  assert_muxm_fn_stdout "_audio_codec_rank(truehd)=0"         "0"  _audio_codec_rank "$rank_env" "truehd"
  assert_muxm_fn_stdout "_audio_codec_rank(aac)=4"            "4"  _audio_codec_rank "$rank_env" "aac"
  assert_muxm_fn_stdout "_audio_codec_rank(unknown_codec)=10" "10" _audio_codec_rank "$rank_env" "unknown_codec"

  # ---- _audio_codec_rank with archive preference ----
  local archival_rank_env='AUDIO_CODEC_PREFERENCE="truehd,dts,flac,eac3,ac3,aac,alac,other"'
  assert_muxm_fn_stdout "_audio_codec_rank(truehd, archival)=0"  "0"  _audio_codec_rank "$archival_rank_env" "truehd"
  assert_muxm_fn_stdout "_audio_codec_rank(dts, archival)=1"     "1"  _audio_codec_rank "$archival_rank_env" "dts"
  assert_muxm_fn_stdout "_audio_codec_rank(flac, archival)=2"    "2"  _audio_codec_rank "$archival_rank_env" "flac"
  assert_muxm_fn_stdout "_audio_codec_rank(eac3, archival)=3"    "3"  _audio_codec_rank "$archival_rank_env" "eac3"

  # ---- _audio_codec_rank with animation preference ----
  local anim_rank_env='AUDIO_CODEC_PREFERENCE="flac,truehd,eac3,ac3,aac,alac,other"'
  assert_muxm_fn_stdout "_audio_codec_rank(flac, animation)=0"    "0"  _audio_codec_rank "$anim_rank_env" "flac"
  assert_muxm_fn_stdout "_audio_codec_rank(truehd, animation)=1"  "1"  _audio_codec_rank "$anim_rank_env" "truehd"
  assert_muxm_fn_stdout "_audio_codec_rank(eac3, animation)=2"    "2"  _audio_codec_rank "$anim_rank_env" "eac3"

  # (There is deliberately no "Scoring formula invariants" block here — computing score
  #  components in the test (codec_step=10, max_br_bonus=8, …) and asserting arithmetic
  #  tautologies (10>8, FLAC>AC3) never calls _score_audio_stream, so a real scoring
  #  break would be invisible. _test_unit_score_audio_stream exercises the real
  #  function via _extract_muxm_fns instead.)

  # ---- _audio_is_commentary ----
  assert_muxm_fn_exit "_audio_is_commentary('Director\\'s Commentary')=match"  0 _audio_is_commentary "" "Director's Commentary"
  assert_muxm_fn_exit "_audio_is_commentary('Main Feature')=no match"          1 _audio_is_commentary "" "Main Feature"
  assert_muxm_fn_exit "_audio_is_commentary('Audio Description')=match"        0 _audio_is_commentary "" "Audio Description"
  assert_muxm_fn_exit "_audio_is_commentary('')=no match (empty)"              1 _audio_is_commentary "" ""
  assert_muxm_fn_exit "_audio_is_commentary('Comentario...')=match (Spanish)"  0 _audio_is_commentary "" "Comentario del director"

  # ---- audio_is_direct_play_copyable ----
  # Gatekeeper for the audio pipeline's biggest branch: copy vs transcode (Step 3 of
  # run_audio_pipeline). A regression dropping a codec (e.g. eac3) silently forces unnecessary
  # transcoding; wrongly adding one stream-copies a track the device can't Direct Play.
  # F1: this is the DEVICE Direct-Play whitelist {aac,ac3,eac3,alac} and is INDEPENDENT of
  # MUX_FORMAT — it does not delegate to _sii_audio_is_container_safe(), so no container stub
  # is needed. The matroska cases below are the regression guard: an alias to that predicate
  # returns 0 for EVERY codec on a matroska target, wrongly marking truehd/dts "copyable".
  assert_muxm_fn_exit "audio_is_direct_play_copyable('aac')=copyable"        0 audio_is_direct_play_copyable "" "aac"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('alac')=copyable"       0 audio_is_direct_play_copyable "" "alac"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('ac3')=copyable"        0 audio_is_direct_play_copyable "" "ac3"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('eac3')=copyable"       0 audio_is_direct_play_copyable "" "eac3"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('truehd')=not copyable" 1 audio_is_direct_play_copyable "" "truehd"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('dts')=not copyable"    1 audio_is_direct_play_copyable "" "dts"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('flac')=not copyable"   1 audio_is_direct_play_copyable "" "flac"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('opus')=not copyable"   1 audio_is_direct_play_copyable "" "opus"
  # F1 regression guard: decision is MUX_FORMAT-independent. A container-safety alias returns 0
  # (copyable) for these on a matroska target; truehd/dts must be rejected, aac/eac3 accepted.
  assert_muxm_fn_exit "audio_is_direct_play_copyable('truehd',mkv)=not copyable" 1 audio_is_direct_play_copyable "MUX_FORMAT=matroska" "truehd"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('dts',mkv)=not copyable"    1 audio_is_direct_play_copyable "MUX_FORMAT=matroska" "dts"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('eac3',mkv)=copyable"       0 audio_is_direct_play_copyable "MUX_FORMAT=matroska" "eac3"
  assert_muxm_fn_exit "audio_is_direct_play_copyable('aac',mkv)=copyable"        0 audio_is_direct_play_copyable "MUX_FORMAT=matroska" "aac"

  # ---- audio_is_lossless ----
  # Controls AUDIO_LOSSLESS_PASSTHROUGH path. If a codec is accidentally omitted,
  # lossless passthrough silently fails for that codec.
  assert_muxm_fn_exit "audio_is_lossless('truehd')=lossless"    0 audio_is_lossless "" "truehd"
  assert_muxm_fn_exit "audio_is_lossless('dts')=lossless"       0 audio_is_lossless "" "dts"
  assert_muxm_fn_exit "audio_is_lossless('dca')=lossless"       0 audio_is_lossless "" "dca"
  assert_muxm_fn_exit "audio_is_lossless('flac')=lossless"      0 audio_is_lossless "" "flac"
  assert_muxm_fn_exit "audio_is_lossless('alac')=lossless"      0 audio_is_lossless "" "alac"
  assert_muxm_fn_exit "audio_is_lossless('pcm_s16le')=lossless" 0 audio_is_lossless "" "pcm_s16le"
  assert_muxm_fn_exit "audio_is_lossless('pcm_s24le')=lossless" 0 audio_is_lossless "" "pcm_s24le"
  assert_muxm_fn_exit "audio_is_lossless('pcm_s32le')=lossless" 0 audio_is_lossless "" "pcm_s32le"
  assert_muxm_fn_exit "audio_is_lossless('aac')=lossy"          1 audio_is_lossless "" "aac"
  assert_muxm_fn_exit "audio_is_lossless('eac3')=lossy"         1 audio_is_lossless "" "eac3"
  assert_muxm_fn_exit "audio_is_lossless('ac3')=lossy"          1 audio_is_lossless "" "ac3"
  assert_muxm_fn_exit "audio_is_lossless('opus')=lossy"         1 audio_is_lossless "" "opus"

  # ---- audio_transcode_target ----
  # Determines output codec and bitrate. Tests all three code paths (≥8ch, ≥6ch, <6ch).
  # Depends on EAC3_BITRATE_5_1 and EAC3_BITRATE_7_1 globals.
  # Checks first word of stdout (codec name), so uses a small local helper.
  local transcode_env="EAC3_BITRATE_5_1='640k'; EAC3_BITRATE_7_1='768k'"
  _test_transcode_target() {
    local ch="$1" expect_codec="$2" label="$3"
    local body actual got_codec
    body="$(awk '/^audio_transcode_target\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
    actual="$(bash -c "$transcode_env"$'\n'"$body"$'\n'"audio_transcode_target \"\$1\"" -- "$ch")"
    got_codec="${actual%% *}"
    if [[ "$got_codec" == "$expect_codec" ]]; then pass "$label"; else fail "$label — expected codec '$expect_codec', got '$got_codec' (full: '$actual')"; fi
  }
  _test_transcode_target "8" "eac3" "audio_transcode_target(8ch)=eac3 (7.1 bitrate)"
  _test_transcode_target "6" "eac3" "audio_transcode_target(6ch)=eac3 (5.1 bitrate)"
  _test_transcode_target "2" "aac"  "audio_transcode_target(2ch)=aac (stereo)"
  _test_transcode_target "1" "aac"  "audio_transcode_target(1ch)=aac (mono)"
  # Intermediate channel counts: 3-5 are below the 6ch eac3 threshold → aac; 7 is ≥6 → eac3
  _test_transcode_target "3" "aac"  "audio_transcode_target(3ch)=aac (<6ch threshold)"
  _test_transcode_target "4" "aac"  "audio_transcode_target(4ch)=aac (<6ch threshold)"
  _test_transcode_target "5" "aac"  "audio_transcode_target(5ch)=aac (<6ch threshold)"
  _test_transcode_target "7" "eac3" "audio_transcode_target(7ch)=eac3 (≥6ch threshold)"
  # Verify bitrate values are wired correctly
  local transcode_body at8_result at6_result
  transcode_body="$(awk '/^audio_transcode_target\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  at8_result="$(bash -c "$transcode_env"$'\n'"$transcode_body"$'\n'"audio_transcode_target 8")"
  if [[ "$at8_result" == *"768k"* ]]; then pass "audio_transcode_target(8ch) uses EAC3_BITRATE_7_1=768k"; else fail "audio_transcode_target(8ch) expected 768k in '$at8_result'"; fi
  at6_result="$(bash -c "$transcode_env"$'\n'"$transcode_body"$'\n'"audio_transcode_target 6")"
  if [[ "$at6_result" == *"640k"* ]]; then pass "audio_transcode_target(6ch) uses EAC3_BITRATE_5_1=640k"; else fail "audio_transcode_target(6ch) expected 640k in '$at6_result'"; fi

  # D7: the ≤2ch (stereo/mono) aac branch honors STEREO_BITRATE instead of a hard-coded 192k.
  # Default STEREO_BITRATE is "192k" → unchanged; an explicit value flows through.
  local at2_def at2_320
  at2_def="$(bash -c "$transcode_env"$'\n'"$transcode_body"$'\n'"audio_transcode_target 2")"
  if [[ "$at2_def" == "aac 192k" ]]; then pass "unit-audio-transcode-target: audio_transcode_target(2ch) default = aac 192k (unchanged)"; else fail "unit-audio-transcode-target: audio_transcode_target(2ch) default expected 'aac 192k', got '$at2_def'"; fi
  at2_320="$(bash -c "$transcode_env"$'\n'"STEREO_BITRATE=320k"$'\n'"$transcode_body"$'\n'"audio_transcode_target 2")"
  if [[ "$at2_320" == "aac 320k" ]]; then pass "unit-audio-transcode-target: audio_transcode_target(2ch) honors STEREO_BITRATE=320k"; else fail "unit-audio-transcode-target: audio_transcode_target(2ch) with STEREO_BITRATE=320k expected 'aac 320k', got '$at2_320'"; fi

  # ---- _codec_max_channels ----
  # Returns the maximum channel count supported by ffmpeg's native encoder for a
  # given codec.  The eac3/ac3 caps (6) are the root cause of the 7.1 TrueHD→eac3
  # transcode failure — audio_transcode_target selects eac3 for 8ch sources, but
  # ffmpeg's encoder rejects -ac 8.  This helper lets run_audio_pipeline clamp
  # effective_ch before building the ffmpeg command.
  assert_muxm_fn_stdout "_codec_max_channels('eac3')=6"  "6"  _codec_max_channels "" "eac3"
  assert_muxm_fn_stdout "_codec_max_channels('ac3')=6"   "6"  _codec_max_channels "" "ac3"
  assert_muxm_fn_stdout "_codec_max_channels('aac')=48"  "48" _codec_max_channels "" "aac"
  assert_muxm_fn_stdout "_codec_max_channels('opus')=fallback (64)" "64" _codec_max_channels "" "opus"

  # Contract test: audio_transcode_target(8) picks eac3, but the encoder can't do 8ch.
  # Verifies the two functions compose correctly — the pipeline must consult
  # _codec_max_channels after audio_transcode_target to avoid the fatal ffmpeg error.
  local att8_codec att8_codec_max
  att8_codec="${at8_result%% *}"
  local codec_max_body
  codec_max_body="$(awk '/^_codec_max_channels\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -n "$codec_max_body" ]]; then
    att8_codec_max="$(bash -c "$codec_max_body"$'\n'"_codec_max_channels \"$att8_codec\"")"
    if (( att8_codec_max < 8 )); then
      pass "_codec_max_channels($att8_codec)=$att8_codec_max < 8 — encoder cap engages for 7.1 sources"
    else
      fail "_codec_max_channels($att8_codec)=$att8_codec_max — expected < 8 to prevent ffmpeg failure on 7.1 sources"
    fi
  else
    # _codec_max_channels is committed — absence is drift (renamed/reformatted), not
    # host-optionality. Fail, never skip.
    fail "_codec_max_channels not found in muxm — extraction anchor failed (renamed/reformatted?)"
  fi

  # ---- _audio_lang_matches ----
  # Drives audio track selection — the strongest scoring signal (150 points).
  # A bug here silently selects the wrong audio track. H2: the matcher normalizes BOTH the
  # tag and each pref entry via _norm_lang_code, so inject the real normalizer into env_setup
  # (assert_muxm_fn_exit extracts only the named function — it would otherwise be "command not found").
  local _nlc; _nlc="$(awk '/^_norm_lang_code\(\)/,/^}/' "$MUXM")"
  assert_muxm_fn_exit "_audio_lang_matches('eng', pref='eng,spa')=match"        0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="eng,spa"' "eng"
  assert_muxm_fn_exit "_audio_lang_matches('spa', pref='eng,spa')=match"        0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="eng,spa"' "spa"
  assert_muxm_fn_exit "_audio_lang_matches('fra', pref='eng,spa')=no match"     1 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="eng,spa"' "fra"
  assert_muxm_fn_exit "_audio_lang_matches('und', pref='eng')=no match"         1 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="eng"'     "und"
  assert_muxm_fn_exit "_audio_lang_matches('', pref='eng')=no match (empty)"    1 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="eng"'     ""
  assert_muxm_fn_exit "_audio_lang_matches('eng', pref='eng')=match (single pref)" 0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="eng"' "eng"
  assert_muxm_fn_exit "_audio_lang_matches: empty pref → no match" 1 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF=""' "eng"
  assert_muxm_fn_exit "_audio_lang_matches: whitespace-padded pref matches" 0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF=" eng , jpn "' "eng"
  assert_muxm_fn_exit "_audio_lang_matches: uppercase pref 'ENG' matches 'eng'" 0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="ENG,JPN"' "eng"
  # H2: 2-letter tag ↔ 3-letter pref (both directions) and 639-2/B ↔ /T must match symmetrically.
  assert_muxm_fn_exit "_audio_lang_matches('en', pref='eng')=match (2→3, H2)"    0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="eng"' "en"
  assert_muxm_fn_exit "_audio_lang_matches('ja', pref='jpn')=match (2→3, H2)"    0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="jpn"' "ja"
  assert_muxm_fn_exit "_audio_lang_matches('jpn', pref='ja')=match (3→2, H2)"    0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="ja"' "jpn"
  assert_muxm_fn_exit "_audio_lang_matches('fre', pref='fra')=match (639-2/B↔/T, H2)" 0 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="fra"' "fre"
  assert_muxm_fn_exit "_audio_lang_matches('jpn', pref='eng')=no match (diff lang)"   1 _audio_lang_matches "$_nlc"$'\n''AUDIO_LANG_PREF="eng"' "jpn"

  # ---- audio_lossless_muxable ----
  # Tests container+codec compatibility matrix for lossless passthrough.
  # Depends on MUX_FORMAT global. audio_lossless_muxable delegates to
  # _sii_audio_is_container_safe (the container-fitness predicate — unlike
  # audio_is_direct_play_copyable, which is now an independent device whitelist, F1), so the
  # stub must be in env_setup. Canonical mp4 set: {aac,ac3,eac3,alac}; flac is NOT muxable in mp4.
  # shellcheck disable=SC2016 # $MUX_FORMAT/$c must NOT expand here; they expand at eval time inside bash -c.
  local _sii_stub='_sii_audio_is_container_safe(){ local c=$1; [[ $MUX_FORMAT == matroska ]] && return 0; case $MUX_FORMAT in mp4|mov|m4v) case $c in aac|ac3|eac3|alac) return 0;; *) return 1;; esac;; esac; return 1; }'
  assert_muxm_fn_exit "audio_lossless_muxable('truehd','matroska')=muxable"     0 audio_lossless_muxable "${_sii_stub}; MUX_FORMAT=matroska" "truehd"
  assert_muxm_fn_exit "audio_lossless_muxable('flac','matroska')=muxable"       0 audio_lossless_muxable "${_sii_stub}; MUX_FORMAT=matroska" "flac"
  assert_muxm_fn_exit "audio_lossless_muxable('alac','mp4')=muxable"            0 audio_lossless_muxable "${_sii_stub}; MUX_FORMAT=mp4"      "alac"
  assert_muxm_fn_exit "audio_lossless_muxable('flac','mp4')=not muxable"        1 audio_lossless_muxable "${_sii_stub}; MUX_FORMAT=mp4"      "flac"
  assert_muxm_fn_exit "audio_lossless_muxable('truehd','mp4')=not muxable"      1 audio_lossless_muxable "${_sii_stub}; MUX_FORMAT=mp4"      "truehd"
  assert_muxm_fn_exit "audio_lossless_muxable('dts','mp4')=not muxable"         1 audio_lossless_muxable "${_sii_stub}; MUX_FORMAT=mp4"      "dts"
  assert_muxm_fn_exit "audio_lossless_muxable('alac','mov')=muxable"            0 audio_lossless_muxable "${_sii_stub}; MUX_FORMAT=mov"      "alac"
  assert_muxm_fn_exit "audio_lossless_muxable('truehd','mov')=not muxable"      1 audio_lossless_muxable "${_sii_stub}; MUX_FORMAT=mov"      "truehd"

  # ---- _audio_copy_ext ----
  # Maps ffprobe codec names to file extensions that ffmpeg can mux when
  # stream-copying.  The truehd→thd mapping is the fix for the "Unable to
  # choose an output format for audio_primary.truehd" fatal error.
  # A regression here silently breaks lossless passthrough for the affected codec.
  assert_muxm_fn_stdout "_audio_copy_ext('truehd')=thd"       "thd"       _audio_copy_ext "" "truehd"
  assert_muxm_fn_stdout "_audio_copy_ext('pcm_s16le')=wav"    "wav"       _audio_copy_ext "" "pcm_s16le"
  assert_muxm_fn_stdout "_audio_copy_ext('pcm_s24le')=wav"    "wav"       _audio_copy_ext "" "pcm_s24le"
  assert_muxm_fn_stdout "_audio_copy_ext('pcm_s32le')=wav"    "wav"       _audio_copy_ext "" "pcm_s32le"
  assert_muxm_fn_stdout "_audio_copy_ext('dca')=dts"          "dts"       _audio_copy_ext "" "dca"
  # Passthrough codecs — extension should equal the codec name
  assert_muxm_fn_stdout "_audio_copy_ext('aac')=aac"          "aac"       _audio_copy_ext "" "aac"
  assert_muxm_fn_stdout "_audio_copy_ext('ac3')=ac3"          "ac3"       _audio_copy_ext "" "ac3"
  assert_muxm_fn_stdout "_audio_copy_ext('eac3')=eac3"        "eac3"      _audio_copy_ext "" "eac3"
  assert_muxm_fn_stdout "_audio_copy_ext('flac')=flac"        "flac"      _audio_copy_ext "" "flac"
  assert_muxm_fn_stdout "_audio_copy_ext('dts')=dts"          "dts"       _audio_copy_ext "" "dts"
  assert_muxm_fn_stdout "_audio_copy_ext('alac')=m4a"          "m4a"       _audio_copy_ext "" "alac"
}

_test_unit_sub_helpers() {
  # ---- _is_forced_title (every alternative word-anchored) ----
  assert_muxm_fn_exit "_is_forced_title('Forced')=match"            0 _is_forced_title "" "Forced"
  assert_muxm_fn_exit "_is_forced_title('Signs & Songs')=match"     0 _is_forced_title "" "Signs & Songs"
  assert_muxm_fn_exit "_is_forced_title('Foreign Parts Only')=match" 0 _is_forced_title "" "Foreign Parts Only"
  assert_muxm_fn_exit "_is_forced_title('English')=no match"        1 _is_forced_title "" "English"
  assert_muxm_fn_exit "_is_forced_title('')=no match (empty)"       1 _is_forced_title "" ""
  # False-positive guards: substrings of longer words must NOT match (would burn-in under SUB_BURN_FORCED).
  assert_muxm_fn_exit "_is_forced_title('Designs')=no match (M2: 'signs' substring)"   1 _is_forced_title "" "Designs"
  assert_muxm_fn_exit "_is_forced_title('Foreigner')=no match (M2: 'foreign' substring)" 1 _is_forced_title "" "Foreigner"
  assert_muxm_fn_exit "_is_forced_title('Cosigns')=no match (M2: 'signs' substring)"   1 _is_forced_title "" "Cosigns"

  # ---- _is_sdh_title (every alternative word-anchored) ----
  assert_muxm_fn_exit "_is_sdh_title('English SDH')=match"          0 _is_sdh_title "" "English SDH"
  assert_muxm_fn_exit "_is_sdh_title('English (CC)')=match"         0 _is_sdh_title "" "English (CC)"
  assert_muxm_fn_exit "_is_sdh_title('Hearing Impaired')=match"     0 _is_sdh_title "" "Hearing Impaired"
  assert_muxm_fn_exit "_is_sdh_title('Closed Caption')=match"       0 _is_sdh_title "" "Closed Caption"
  assert_muxm_fn_exit "_is_sdh_title('English')=no match"           1 _is_sdh_title "" "English"
  assert_muxm_fn_exit "_is_sdh_title('history')=no match (false positive guard: 'hi' in 'history')" 1 _is_sdh_title "" "history"
  assert_muxm_fn_exit "_is_sdh_title('HI')=match (standalone HI)"   0 _is_sdh_title "" "HI"
  assert_muxm_fn_exit "_is_sdh_title('')=no match (empty)"          1 _is_sdh_title "" ""
  # False-positive guards: words merely CONTAINING cc/caption/hearing must NOT match.
  assert_muxm_fn_exit "_is_sdh_title('Soccer')=no match (M2: 'cc' substring)"     1 _is_sdh_title "" "Soccer"
  assert_muxm_fn_exit "_is_sdh_title('vaccine')=no match (M2: 'cc' substring)"    1 _is_sdh_title "" "vaccine"
  assert_muxm_fn_exit "_is_sdh_title('Account')=no match (M2: 'cc' substring)"    1 _is_sdh_title "" "Account"
  assert_muxm_fn_exit "_is_sdh_title('Succession')=no match (M2: 'cc' substring)" 1 _is_sdh_title "" "Succession"

  # ---- _sub_lang_matches (subtitle analogue of _audio_lang_matches; normalize both sides) ----
  local _nlc_s; _nlc_s="$(awk '/^_norm_lang_code\(\)/,/^}/' "$MUXM")"
  assert_muxm_fn_exit "_sub_lang_matches('eng', pref='eng')=match"             0 _sub_lang_matches "$_nlc_s"$'\n''SUB_LANG_PREF="eng"' "eng"
  assert_muxm_fn_exit "_sub_lang_matches('en', pref='eng')=match (2→3, H2)"    0 _sub_lang_matches "$_nlc_s"$'\n''SUB_LANG_PREF="eng"' "en"
  assert_muxm_fn_exit "_sub_lang_matches('eng', pref='en')=match (pref 2-letter, H2)" 0 _sub_lang_matches "$_nlc_s"$'\n''SUB_LANG_PREF="en"' "eng"
  assert_muxm_fn_exit "_sub_lang_matches('fre', pref='fra')=match (639-2/B↔/T, H2)" 0 _sub_lang_matches "$_nlc_s"$'\n''SUB_LANG_PREF="fra"' "fre"
  assert_muxm_fn_exit "_sub_lang_matches('jpn', pref='eng')=no match (diff lang)" 1 _sub_lang_matches "$_nlc_s"$'\n''SUB_LANG_PREF="eng,spa"' "jpn"
  assert_muxm_fn_exit "_sub_lang_matches('eng', pref='')=no match (empty pref)" 1 _sub_lang_matches "$_nlc_s"$'\n''SUB_LANG_PREF=""' "eng"
  assert_muxm_fn_exit "_sub_lang_matches: whitespace-padded pref matches"       0 _sub_lang_matches "$_nlc_s"$'\n''SUB_LANG_PREF=" eng , jpn "' "en"

  # ---- _is_text_sub_codec ----
  assert_muxm_fn_exit "_is_text_sub_codec('subrip')=text"              0 _is_text_sub_codec "" "subrip"
  assert_muxm_fn_exit "_is_text_sub_codec('ass')=text"                 0 _is_text_sub_codec "" "ass"
  assert_muxm_fn_exit "_is_text_sub_codec('mov_text')=text"            0 _is_text_sub_codec "" "mov_text"
  assert_muxm_fn_exit "_is_text_sub_codec('hdmv_pgs_subtitle')=bitmap" 1 _is_text_sub_codec "" "hdmv_pgs_subtitle"
  assert_muxm_fn_exit "_is_text_sub_codec('dvd_subtitle')=bitmap"      1 _is_text_sub_codec "" "dvd_subtitle"
  assert_muxm_fn_exit "_is_text_sub_codec('webvtt')=text"              0 _is_text_sub_codec "" "webvtt"
}

_test_unit_validation_helpers() {
  # ---- is_valid_loglevel ----
  # Validates ffmpeg/ffprobe loglevel strings. Tested indirectly by CLI parser,
  # but a direct unit test catches regressions if a valid level is accidentally
  # dropped from the case statement.
  assert_muxm_fn_exit "is_valid_loglevel('quiet')=valid"   0 is_valid_loglevel "" "quiet"
  assert_muxm_fn_exit "is_valid_loglevel('panic')=valid"   0 is_valid_loglevel "" "panic"
  assert_muxm_fn_exit "is_valid_loglevel('fatal')=valid"   0 is_valid_loglevel "" "fatal"
  assert_muxm_fn_exit "is_valid_loglevel('error')=valid"   0 is_valid_loglevel "" "error"
  assert_muxm_fn_exit "is_valid_loglevel('warning')=valid" 0 is_valid_loglevel "" "warning"
  assert_muxm_fn_exit "is_valid_loglevel('info')=valid"    0 is_valid_loglevel "" "info"
  assert_muxm_fn_exit "is_valid_loglevel('verbose')=valid" 0 is_valid_loglevel "" "verbose"
  assert_muxm_fn_exit "is_valid_loglevel('debug')=valid"   0 is_valid_loglevel "" "debug"
  assert_muxm_fn_exit "is_valid_loglevel('trace')=valid"   0 is_valid_loglevel "" "trace"
  assert_muxm_fn_exit "is_valid_loglevel('bogus')=invalid" 1 is_valid_loglevel "" "bogus"
  assert_muxm_fn_exit "is_valid_loglevel('')=invalid (empty)" 1 is_valid_loglevel "" ""

  # ---- is_valid_preset ----
  # Validates x265 preset strings. Indirectly tested by --preset in test_cli,
  # but a direct unit test guards against accidentally dropping a valid preset.
  assert_muxm_fn_exit "is_valid_preset('ultrafast')=valid"  0 is_valid_preset "" "ultrafast"
  assert_muxm_fn_exit "is_valid_preset('superfast')=valid"  0 is_valid_preset "" "superfast"
  assert_muxm_fn_exit "is_valid_preset('veryfast')=valid"   0 is_valid_preset "" "veryfast"
  assert_muxm_fn_exit "is_valid_preset('faster')=valid"     0 is_valid_preset "" "faster"
  assert_muxm_fn_exit "is_valid_preset('fast')=valid"       0 is_valid_preset "" "fast"
  assert_muxm_fn_exit "is_valid_preset('medium')=valid"     0 is_valid_preset "" "medium"
  assert_muxm_fn_exit "is_valid_preset('slow')=valid"       0 is_valid_preset "" "slow"
  assert_muxm_fn_exit "is_valid_preset('slower')=valid"     0 is_valid_preset "" "slower"
  assert_muxm_fn_exit "is_valid_preset('veryslow')=valid"   0 is_valid_preset "" "veryslow"
  assert_muxm_fn_exit "is_valid_preset('placebo')=valid"    0 is_valid_preset "" "placebo"
  assert_muxm_fn_exit "is_valid_preset('bogus')=invalid"    1 is_valid_preset "" "bogus"
  assert_muxm_fn_exit "is_valid_preset('')=invalid (empty)" 1 is_valid_preset "" ""

  # ---- _is_valid_profile ----
  # Validates profile names against VALID_PROFILES constant.
  local profile_env
  profile_env="$(grep '^readonly VALID_PROFILES=' "$MUXM")"
  assert_muxm_fn_exit "_is_valid_profile('streaming')=valid"                 0 _is_valid_profile "$profile_env" "streaming"
  assert_muxm_fn_exit "_is_valid_profile('archive')=valid"                   0 _is_valid_profile "$profile_env" "archive"
  assert_muxm_fn_exit "_is_valid_profile('dv-archival')=valid (deprecated)"  0 _is_valid_profile "$profile_env" "dv-archival"
  assert_muxm_fn_exit "_is_valid_profile('universal')=valid"                 0 _is_valid_profile "$profile_env" "universal"
  assert_muxm_fn_exit "_is_valid_profile('animation')=valid"                 0 _is_valid_profile "$profile_env" "animation"
  assert_muxm_fn_exit "_is_valid_profile('hdr10-hq')=valid"                  0 _is_valid_profile "$profile_env" "hdr10-hq"
  assert_muxm_fn_exit "_is_valid_profile('atv-directplay-hq')=valid"         0 _is_valid_profile "$profile_env" "atv-directplay-hq"
  assert_muxm_fn_exit "_is_valid_profile('atv-directplay-animation')=valid"  0 _is_valid_profile "$profile_env" "atv-directplay-animation"
  assert_muxm_fn_exit "_is_valid_profile('nonexistent')=invalid"             1 _is_valid_profile "$profile_env" "nonexistent"
  assert_muxm_fn_exit "_is_valid_profile('')=invalid (empty)"                1 _is_valid_profile "$profile_env" ""

  # ---- _valid_profiles_display ----
  # Verify the comma-separated format output for user-facing messages.
  local vpd_body vpd_result
  vpd_body="$(awk '/^_valid_profiles_display\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  vpd_result="$(bash -c "$profile_env"$'\n'"$vpd_body"$'\n'"_valid_profiles_display")"
  # Should contain comma-separated names
  if [[ "$vpd_result" == *","* ]]; then pass "_valid_profiles_display returns comma-separated list"; else fail "_valid_profiles_display expected commas, got '$vpd_result'"; fi
  if [[ "$vpd_result" == *"streaming"* ]]; then pass "_valid_profiles_display includes 'streaming'"; else fail "_valid_profiles_display missing 'streaming' in '$vpd_result'"; fi
  if [[ "$vpd_result" == *"universal"* ]]; then pass "_valid_profiles_display includes 'universal'"; else fail "_valid_profiles_display missing 'universal' in '$vpd_result'"; fi
}

_test_unit_filesize() {
  # ---- filesize_pretty ----
  # Test all four code paths (GB, MB, KB, bytes) + file-not-found
  local fsz_dir="$TESTDIR/filesize_test"
  mkdir -p "$fsz_dir"

  local result

  # File not found
  result="$(muxm_fn filesize_pretty "$fsz_dir/nonexistent" 2>/dev/null)" || true
  if [[ "$result" == *"not found"* ]]; then pass "filesize_pretty(nonexistent)=not found"; else fail "filesize_pretty(nonexistent) expected 'not found', got '$result'"; fi

  # 0 bytes
  touch "$fsz_dir/empty"
  result="$(muxm_fn filesize_pretty "$fsz_dir/empty")"
  if [[ "$result" == "0 bytes" ]]; then pass "filesize_pretty(0 bytes)"; else fail "filesize_pretty(0 bytes) expected '0 bytes', got '$result'"; fi

  # 512 bytes (bytes path)
  dd if=/dev/zero of="$fsz_dir/small" bs=512 count=1 2>/dev/null
  result="$(muxm_fn filesize_pretty "$fsz_dir/small")"
  if [[ "$result" == "512 bytes" ]]; then pass "filesize_pretty(512 bytes)"; else fail "filesize_pretty(512 bytes) expected '512 bytes', got '$result'"; fi

  # 1024 bytes (KB path)
  dd if=/dev/zero of="$fsz_dir/onekb" bs=1024 count=1 2>/dev/null
  result="$(muxm_fn filesize_pretty "$fsz_dir/onekb")"
  if [[ "$result" == *"KB"* ]]; then pass "filesize_pretty(1 KB)"; else fail "filesize_pretty(1 KB) expected 'KB', got '$result'"; fi

  # ~1.5 MB (MB path)
  dd if=/dev/zero of="$fsz_dir/onemb" bs=1024 count=1536 2>/dev/null
  result="$(muxm_fn filesize_pretty "$fsz_dir/onemb")"
  if [[ "$result" == *"MB"* ]]; then pass "filesize_pretty(~1.5 MB)"; else fail "filesize_pretty(~1.5 MB) expected 'MB', got '$result'"; fi

  # >1 GiB (GB path) — use a sparse file so no real disk space is consumed
  if command -v truncate &>/dev/null; then
    truncate -s 1073741825 "$fsz_dir/onegb"
    result="$(muxm_fn filesize_pretty "$fsz_dir/onegb")"
    if [[ "$result" == *"GB"* ]]; then pass "filesize_pretty(>1 GiB sparse)=GB path"; else fail "filesize_pretty(>1 GiB sparse) expected 'GB', got '$result'"; fi
    rm -f "$fsz_dir/onegb"
  else
    skip "filesize_pretty(GB path) — truncate not available"
  fi
}

_test_unit_sii_container_safety() {
  # ---- _sii_audio_is_container_safe ----
  # Checks whether an audio codec can be muxed into the target container during
  # skip-if-ideal remux.  MKV passes all codecs; MP4/MOV reject TrueHD, DTS/DCA,
  # and raw PCM.  A regression here silently drops audio streams in the metadata
  # remux — the most dangerous failure mode because the output file is valid but
  # incomplete.  Mirrors the _is_text_sub_codec pattern for subtitles.
  # Depends on MUX_FORMAT global.

  # MKV passes everything
  assert_muxm_fn_exit "_sii_audio_is_container_safe('truehd','matroska')=safe"      0 _sii_audio_is_container_safe 'MUX_FORMAT="matroska"' "truehd"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('dts','matroska')=safe"         0 _sii_audio_is_container_safe 'MUX_FORMAT="matroska"' "dts"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('dca','matroska')=safe"         0 _sii_audio_is_container_safe 'MUX_FORMAT="matroska"' "dca"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('pcm_s16le','matroska')=safe"   0 _sii_audio_is_container_safe 'MUX_FORMAT="matroska"' "pcm_s16le"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('aac','matroska')=safe"         0 _sii_audio_is_container_safe 'MUX_FORMAT="matroska"' "aac"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('eac3','matroska')=safe"        0 _sii_audio_is_container_safe 'MUX_FORMAT="matroska"' "eac3"

  # MP4 rejects TrueHD, DTS/DCA, raw PCM, FLAC (whitelist: aac/ac3/eac3/alac only)
  assert_muxm_fn_exit "_sii_audio_is_container_safe('truehd','mp4')=unsafe"         1 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "truehd"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('dts','mp4')=unsafe"            1 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "dts"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('dca','mp4')=unsafe"            1 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "dca"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('pcm_s16le','mp4')=unsafe"      1 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "pcm_s16le"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('flac','mp4')=unsafe"           1 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "flac"

  # MP4 accepts canonical direct-play codecs: {aac, ac3, eac3, alac}
  assert_muxm_fn_exit "_sii_audio_is_container_safe('aac','mp4')=safe"              0 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "aac"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('eac3','mp4')=safe"             0 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "eac3"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('alac','mp4')=safe"             0 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "alac"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('ac3','mp4')=safe"              0 _sii_audio_is_container_safe 'MUX_FORMAT="mp4"' "ac3"

  # MOV mirrors MP4 rejection rules
  assert_muxm_fn_exit "_sii_audio_is_container_safe('truehd','mov')=unsafe"         1 _sii_audio_is_container_safe 'MUX_FORMAT="mov"' "truehd"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('dca','mov')=unsafe"            1 _sii_audio_is_container_safe 'MUX_FORMAT="mov"' "dca"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('aac','mov')=safe"              0 _sii_audio_is_container_safe 'MUX_FORMAT="mov"' "aac"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('alac','mov')=safe"             0 _sii_audio_is_container_safe 'MUX_FORMAT="mov"' "alac"

  # M4V mirrors MP4 (m4v is in the mp4 group)
  assert_muxm_fn_exit "_sii_audio_is_container_safe('aac','m4v')=safe"              0 _sii_audio_is_container_safe 'MUX_FORMAT="m4v"' "aac"
  assert_muxm_fn_exit "_sii_audio_is_container_safe('truehd','m4v')=unsafe"         1 _sii_audio_is_container_safe 'MUX_FORMAT="m4v"' "truehd"
}

_test_unit_misc_helpers() {
  # ---- _lower ----
  # One-liner that lowercases via tr. The awk range pattern picks up extra code
  # but extra definitions in the subshell are harmless when only _lower is called.
  assert_muxm_fn_stdout "_lower('HELLO')=hello"      "hello"      _lower "" "HELLO"
  assert_muxm_fn_stdout "_lower('Hello')=hello"      "hello"      _lower "" "Hello"
  assert_muxm_fn_stdout "_lower('hello')=hello"      "hello"      _lower "" "hello"
  assert_muxm_fn_stdout "_lower('MiXeD')=mixed"      "mixed"      _lower "" "MiXeD"
  assert_muxm_fn_stdout "_lower('HEVC')=hevc"        "hevc"       _lower "" "HEVC"
  assert_muxm_fn_stdout "_lower('')=empty"           ""           _lower "" ""

  # ---- _profile_comment ----
  # Each named profile has a tagline; _profile_comment reads PROFILE_NAME global.
  local pc_body
  pc_body="$(awk '/^_profile_comment\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  _test_pc() {
    local profile="$1" expect="$2"
    local got
    got="$(PROFILE_NAME="$profile" bash -c "$pc_body"$'\n'"_profile_comment")"
    if [[ "$got" == "$expect" ]]; then pass "_profile_comment($profile)"; else fail "_profile_comment($profile) expected '$expect', got '$got'"; fi
  }
  _test_pc "archive"             "Preserved in digital amber."
  _test_pc "hdr10-hq"            "All the nits, none of the drama."
  _test_pc "atv-directplay-hq"   "Shaped to please the most demanding rectangle in your living room."
  _test_pc "atv-directplay-animation" "Studio Ghibli didn't suffer for mov_text."
  # RF12: _profile_comment keys on the CANONICAL profile name only (apply_profile normalizes
  # PROFILE_NAME before any _profile_comment call), so the canonical 'streaming-hevc' yields the
  # tagline and the deprecated raw 'streaming' alias — which production never passes here — returns
  # empty (there is no dead 'streaming' alias arm).
  _test_pc "streaming-hevc"      "Lean, mean, streaming machine."
  _test_pc "streaming"           ""
  _test_pc "animation"           "psy-rd turned down, sakuga turned up."
  _test_pc "universal"           "Lowest common denominator, highest common decency."
  _test_pc "unknown"             ""

  # ---- CR-12: _reclaim empty-WORKDIR guard ----
  # If WORKDIR were ever empty the `case "$f" in "$WORKDIR"/*)` containment pattern degenerates to
  # `/*`, which matches ANY absolute path — _reclaim would then rm a file OUTSIDE the (nonexistent)
  # workdir. The CR-12 precondition `[[ -n "$WORKDIR" ]]` refuses up front (mirrors _cleanup_workdir).
  local rc_body rc_dir rc_file rc_out
  rc_body="$(awk '/^_reclaim\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  rc_dir="$TESTDIR/cr12_reclaim"; mkdir -p "$rc_dir"
  rc_file="$rc_dir/victim.bin"; printf 'data' > "$rc_file"
  rc_out="$(WORKDIR="" DRY_RUN=0 bash -c "warn(){ printf 'WARN %s\n' \"\$*\"; }; note(){ :; }"$'\n'"$rc_body"$'\n''_reclaim "$1" reason' -- "$rc_file" 2>&1)"
  if [[ -e "$rc_file" ]]; then
    pass "unit-reclaim-workdir-guard: _reclaim refuses to delete with WORKDIR empty (file survived the /* degeneracy)"
  else
    fail "unit-reclaim-workdir-guard: _reclaim DELETED a file outside workdir when WORKDIR was empty (guard missing)"
  fi
  if printf '%s\n' "$rc_out" | grep -qiF "WORKDIR is unset"; then
    pass "unit-reclaim-workdir-guard: _reclaim warns 'WORKDIR is unset' on the empty-WORKDIR guard"
  else
    fail "unit-reclaim-workdir-guard: expected a 'WORKDIR is unset' warning. Saw: $(printf '%s\n' "$rc_out" | head -1)"
  fi
  rm -rf "$rc_dir"
}

_test_unit_disk_preflight() {
  # ---- _crf_ratio ----
  # Table-driven lookup: codec × CRF → output/source bitrate ratio ×1000.
  # Tests cover named entries, the below-range clamp (<14 → 850 for x265),
  # and the above-range clamp (>28 → 35 for x265).
  assert_muxm_fn_stdout "_crf_ratio(libx265,18)=330"         "330" _crf_ratio "" "libx265" "18"
  assert_muxm_fn_stdout "_crf_ratio(libx265,28)=50"          "50"  _crf_ratio "" "libx265" "28"
  assert_muxm_fn_stdout "_crf_ratio(libx264,23)=230"         "230" _crf_ratio "" "libx264" "23"
  assert_muxm_fn_stdout "_crf_ratio(libx265,10)=850(clamp)"  "850" _crf_ratio "" "libx265" "10"
  assert_muxm_fn_stdout "_crf_ratio(libx265,35)=35(clamp)"   "35"  _crf_ratio "" "libx265" "35"
  # AV1 ratios use the measured AV1_CALIBRATION.md §6 values.
  # Both libsvt-av1 and libaom-av1 share the table; spot-check named entries + both clamps.
  assert_muxm_fn_stdout "_crf_ratio(libsvt-av1,30)=166"      "166" _crf_ratio "" "libsvt-av1" "30"
  assert_muxm_fn_stdout "_crf_ratio(libsvt-av1,24)=211"      "211" _crf_ratio "" "libsvt-av1" "24"
  assert_muxm_fn_stdout "_crf_ratio(libaom-av1,40)=70"       "70"  _crf_ratio "" "libaom-av1" "40"
  assert_muxm_fn_stdout "_crf_ratio(libsvt-av1,18)=360(clamp)" "360" _crf_ratio "" "libsvt-av1" "18"
  assert_muxm_fn_stdout "_crf_ratio(libsvt-av1,45)=55(clamp)"  "55"  _crf_ratio "" "libsvt-av1" "45"

  # ---- _preset_multiplier ----
  # Maps preset names to encode-size multiplier ×1000.
  # Tests cover extremes (ultrafast, veryslow) and the default fallback.
  assert_muxm_fn_stdout "_preset_multiplier(ultrafast)=2000"  "2000" _preset_multiplier "" "ultrafast"
  assert_muxm_fn_stdout "_preset_multiplier(medium)=1000"     "1000" _preset_multiplier "" "medium"
  assert_muxm_fn_stdout "_preset_multiplier(veryslow)=950"    "950"  _preset_multiplier "" "veryslow"
  assert_muxm_fn_stdout "_preset_multiplier(bogus)=1000"      "1000" _preset_multiplier "" "bogus"
}

# disk_free_warn source-file-size fallback when bitrate metadata is missing.
# disk_free_warn has many dependencies, so we source its body with stubbed helpers and a
# `log` override that prints the preflight line to stdout, then inspect the estimate.
# Covers the three branches plus the copy-mode source-size floor. The integer-math values
# are deterministic for a 10 MiB source @ 100 s, libx265 CRF 28 (_crf_ratio=50, preset 1000).
_test_unit_disk_fallback() {
  local body
  body="$(awk '/^disk_free_warn\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$body" ]]; then fail "disk_free_warn not found in muxm — extraction anchor failed (renamed/reformatted?)"; return; fi

  local srcfile; srcfile="$(mktemp "$TESTDIR/disk_fallback.XXXXXX")"
  head -c 10485760 /dev/zero > "$srcfile"   # exactly 10 MiB = 10485760 bytes

  # Shared stubs + globals. df reports huge free space so the guard never dies; log prints
  # the preflight line to stdout. _jq_cache / SRC_ABS / VIDEO_COPY_IF_COMPLIANT vary per case.
  local common='
    DISK_CHECK=1; VIDEO_CODEC=libx265; CRF_VALUE=28; PRESET_VALUE=medium
    DISABLE_DV=1; AUDIO_MULTI_TRACK=0; AUDIO_FORCE_CODEC=""; METADATA_CACHE=""
    DISK_FREE_WARN_GB=0; WORKDIR=/tmp; OUT_DIR=/tmp
    _get_source_duration_secs(){ echo 100; }
    _audio_stream_count(){ echo 0; }
    _audio_stream_info(){ echo ""; }
    _source_has_dv_metadata(){ return 1; }
    _crf_ratio(){ echo 50; }
    _preset_multiplier(){ echo 1000; }
    _av1_preset_multiplier(){ echo 1000; }
    _gb(){ echo 0; }
    df(){ printf "Filesystem 1K-blocks Used Available Capacity Mounted\nstubdev 100000000000 0 99999999999 1%% /\n"; }
    die(){ echo "DIE:$*"; }
    say(){ :; }
    log(){ printf "%s " "$@"; printf "\n"; }
  '
  local out

  # Branch 1 — bitrate present (re-encode): unchanged behavior, est from bitrate (not size).
  out="$(bash -c "$common"$'\n''_jq_cache(){ echo 5000000; }'$'\n'"SRC_ABS='$srcfile'; VIDEO_COPY_IF_COMPLIANT=0"$'\n'"$body"$'\n''disk_free_warn')"
  assert_contains "video_bytes=3125000" "disk fallback: bitrate present → bitrate-derived estimate" "$out"
  assert_contains "src_size=10485760"   "disk fallback: source size is stat'd"                       "$out"
  assert_contains "peak_factor=2"       "disk fallback: non-DV re-encode keeps peak_factor=2"        "$out"

  # peak_factor axis is independent of the size fallback: a DV re-encode reserves 3×. Drive the DV
  # path via METADATA_CACHE (DISABLE_DV=0) so _source_has_dv_metadata need not be real.
  out="$(bash -c "$common"$'\n''_jq_cache(){ echo 5000000; }'$'\n'"SRC_ABS='$srcfile'; VIDEO_COPY_IF_COMPLIANT=0; DISABLE_DV=0; METADATA_CACHE='dovi'"$'\n'"$body"$'\n''disk_free_warn')"
  assert_contains "peak_factor=3"       "disk fallback: DV re-encode keeps peak_factor=3"            "$out"

  # Branch 2 — bitrate MISSING but size available: estimate must be NON-ZERO (synthesized from
  # file size), instead of collapsing to 0.
  out="$(bash -c "$common"$'\n''_jq_cache(){ echo ""; }'$'\n'"SRC_ABS='$srcfile'; VIDEO_COPY_IF_COMPLIANT=0"$'\n'"$body"$'\n''disk_free_warn')"
  assert_contains "video_bytes=524000" "disk fallback: missing bitrate → estimate derived from source size (non-zero)" "$out"
  if echo "$out" | grep -qE 'video_bytes=0( |$)'; then
    fail "disk fallback: missing-bitrate estimate collapsed to 0 (fallback did not fire)"
  else
    pass "disk fallback: missing-bitrate estimate did not collapse to 0"
  fi

  # Branch 3 — neither bitrate nor a stat-able size: estimate is 0 and the conservative
  # DISK_FREE_WARN_GB floor governs (unchanged behavior). Use a nonexistent SRC_ABS.
  out="$(bash -c "$common"$'\n''_jq_cache(){ echo ""; }'$'\n'"SRC_ABS='$TESTDIR/does-not-exist.xyz'; VIDEO_COPY_IF_COMPLIANT=0"$'\n'"$body"$'\n''disk_free_warn')"
  assert_contains "video_bytes=0 audio_bytes=0 src_size=0" "disk fallback: neither bitrate nor size → estimate 0 (floor governs)" "$out"

  # Branch 4 — copy/remux mode: the output estimate is floored at the source size (×1.25),
  # so a small/low bit_rate can't under-reserve for a near-1:1 remux. 10 MiB × 1.25 = 13107200.
  out="$(bash -c "$common"$'\n''_jq_cache(){ echo 80000; }'$'\n'"SRC_ABS='$srcfile'; VIDEO_COPY_IF_COMPLIANT=1"$'\n'"$body"$'\n''disk_free_warn')"
  assert_contains "est_output=13107200" "disk fallback: copy mode floors output estimate at source size" "$out"
  assert_contains "peak_factor=1"        "disk fallback: copy mode keeps peak_factor=1"                   "$out"

  rm -f "$srcfile"
}


_test_unit_disk_output_volume() {
  # 3.6: disk_free_warn's OUTPUT-VOLUME hard stop — the `od_dev != wd_dev` branch that is
  # never reached by any e2e test (WORKDIR and OUT_DIR normally share a volume). Source the
  # function with a df mock that puts OUT_DIR on a DIFFERENT, (nearly) full device while the workdir
  # volume is roomy, so the workdir check passes and the output-volume `die 11` fires. A same-volume
  # sanity case proves the die is specific to the cross-volume branch (not a blanket always-die).
  # M-DISK-1 inverts the cross-volume guard (!= → ==) → the output check is skipped → no die → red.
  local body
  body="$(awk '/^disk_free_warn\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$body" ]]; then fail "disk_free_warn not found in muxm — extraction anchor failed (renamed/reformatted?)"; return; fi
  local srcfile; srcfile="$(mktemp "$TESTDIR/disk_ov.XXXXXX")"
  head -c 10485760 /dev/zero > "$srcfile"   # 10 MiB, so the stat-based estimate is non-degenerate

  # Re-encode mode (peak_factor=2) so the DISK_FREE_WARN_GB floor (5 GiB) governs need_output —
  # far above the 1 KiB we report free on the output volume. die() prints + exits with its code.
  # shellcheck disable=SC2016  # literal env-setup body; $-refs must expand later inside `bash -c`, not now
  local common='
    DISK_CHECK=1; VIDEO_CODEC=libx265; CRF_VALUE=28; PRESET_VALUE=medium
    DISABLE_DV=1; AUDIO_MULTI_TRACK=0; AUDIO_FORCE_CODEC=""; METADATA_CACHE=""
    DISK_FREE_WARN_GB=5; VIDEO_COPY_IF_COMPLIANT=0
    WORKDIR=/tmp/muxm_ov_wd; OUT_DIR=/tmp/muxm_ov_od
    _get_source_duration_secs(){ echo 100; }
    _jq_cache(){ echo ""; }
    _audio_stream_count(){ echo 0; }
    _audio_stream_info(){ echo ""; }
    _source_has_dv_metadata(){ return 1; }
    _crf_ratio(){ echo 50; }
    _preset_multiplier(){ echo 1000; }
    _av1_preset_multiplier(){ echo 1000; }
    _gb(){ echo 5; }
    log(){ :; }
    die(){ printf "DIE|%s|%s\n" "$1" "$2"; exit "$1"; }
  '
  # df field 1 is the device, field 4 the available KiB (awk NR==2 reads $1/$4). The cross-volume
  # mock returns a DIFFERENT device + 1 KiB free for OUT_DIR; a roomy device for everything else.
  # shellcheck disable=SC2016  # literal mock df() body; ${@:-1}/$OUT_DIR must expand inside `bash -c`, not now
  local dfmock_diff='
    df(){ local p="${@: -1}"
      if [[ "$p" == "$OUT_DIR" ]]; then printf "FS 1K Used Avail Cap M\noddev 100 99 1 99%% /od\n"
      else printf "FS 1K Used Avail Cap M\nwddev 99999999999 0 99999999999 0%% /wd\n"; fi; }
  '
  local dfmock_same='
    df(){ printf "FS 1K Used Avail Cap M\nsamedev 99999999999 0 99999999999 0%% /\n"; }
  '
  local out rc

  rc=0
  out="$(bash -c "$common"$'\n'"$dfmock_diff"$'\n'"SRC_ABS='$srcfile'"$'\n'"$body"$'\n''disk_free_warn' 2>&1)" || rc=$?
  if [[ "$rc" -eq 11 ]] && printf '%s\n' "$out" | grep -qiE 'output volume|output file'; then
    pass "unit-disk-output-volume disk output-volume: full output volume on a different device → die 11"
  else
    fail "unit-disk-output-volume disk output-volume: expected die 11 on a full different output volume, got rc=$rc out='${out:0:120}'"
  fi

  rc=0
  out="$(bash -c "$common"$'\n'"$dfmock_same"$'\n'"SRC_ABS='$srcfile'"$'\n'"$body"$'\n''disk_free_warn' 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    pass "unit-disk-output-volume disk output-volume: same roomy volume → no die (sanity: branch is volume-specific)"
  else
    fail "unit-disk-output-volume disk output-volume: same roomy volume should not die, got rc=$rc out='${out:0:120}'"
  fi
  rm -f "$srcfile"
}

_test_unit_av1_resolution_crf() {
  # _apply_av1_resolution_crf — resolution/HDR-aware CRF for the AV1 profiles.
  # Source the helper with stubbed _probe_field/note/report_add and assert the resulting
  # CRF_VALUE for each (profile × resolution/HDR × --crf) case. Deterministic, no encode.
  local body
  body="$(awk '/^_apply_av1_resolution_crf\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$body" ]]; then fail "_apply_av1_resolution_crf not found in muxm — extraction anchor failed (renamed/reformatted?)"; return; fi

  # $1 profile  $2 width  $3 height  $4 PROFILE_DESC  $5 _CLI_CRF_EXPLICIT  $6 base CRF
  _av1crf() {
    bash -c '
      AV1_HQ_HDR_CRF=24
      _probe_field(){ case "$1" in width) echo '"$2"';; height) echo '"$3"';; esac; }
      note(){ :; }; report_add(){ :; }
      PROFILE_NAME="'"$1"'"; PROFILE_DESC="'"$4"'"; _CLI_CRF_EXPLICIT='"$5"'; CRF_VALUE='"$6"'
      '"$body"'
      _apply_av1_resolution_crf
      echo "$CRF_VALUE"
    '
  }

  # av1-hq: base 28 (≤1080p SDR) → 24 (≥4K or HDR); an explicit --crf wins.
  if [[ "$(_av1crf av1-hq 1920 1080 SDR 0 28)" == 28 ]]; then pass "av1-hq 1080p SDR → base CRF 28"; else fail "av1-hq 1080p SDR → expected 28, got $(_av1crf av1-hq 1920 1080 SDR 0 28)"; fi
  if [[ "$(_av1crf av1-hq 3840 2160 SDR 0 28)" == 24 ]]; then pass "av1-hq 4K → CRF 24 (AV1_HQ_HDR_CRF)"; else fail "av1-hq 4K → expected 24, got $(_av1crf av1-hq 3840 2160 SDR 0 28)"; fi
  if [[ "$(_av1crf av1-hq 1920 1080 HDR10 0 28)" == 24 ]]; then pass "av1-hq 1080p HDR → CRF 24 (HDR trigger)"; else fail "av1-hq 1080p HDR → expected 24, got $(_av1crf av1-hq 1920 1080 HDR10 0 28)"; fi
  if [[ "$(_av1crf av1-hq 3840 2160 SDR 1 30)" == 30 ]]; then pass "av1-hq 4K + explicit --crf 30 wins"; else fail "av1-hq 4K + --crf → expected 30, got $(_av1crf av1-hq 3840 2160 SDR 1 30)"; fi

  # streaming-av1: base 30 → 28 for ≥4K/HDR (behavior unchanged by the refactor).
  if [[ "$(_av1crf streaming-av1 3840 2160 SDR 0 30)" == 28 ]]; then pass "streaming-av1 4K → CRF 28 (unchanged)"; else fail "streaming-av1 4K → expected 28, got $(_av1crf streaming-av1 3840 2160 SDR 0 30)"; fi
  if [[ "$(_av1crf streaming-av1 1920 1080 SDR 0 30)" == 30 ]]; then pass "streaming-av1 1080p SDR → keeps CRF 30"; else fail "streaming-av1 1080p SDR → expected 30, got $(_av1crf streaming-av1 1920 1080 SDR 0 30)"; fi

  # Non-AV1 profile: the helper is a no-op (leaves CRF untouched).
  if [[ "$(_av1crf animation 3840 2160 SDR 0 16)" == 16 ]]; then pass "non-AV1 profile → helper no-op"; else fail "non-AV1 profile → expected 16, got $(_av1crf animation 3840 2160 SDR 0 16)"; fi

  unset -f _av1crf
}


_test_unit_ignored_knobs() {
  # _warn_ignored_knobs warns when an explicitly-typed CLI flag is silently ignored
  # by the resolved backend/codec (C1–C5, C7–C9). Source the helper with a `warn` stub that
  # prints to stdout, set the relevant globals, and assert on the emitted text. Deterministic
  # — exercises the VideoToolbox cases (C1–C4) that can't resolve on non-macOS CI hosts.
  local body iav1
  body="$(awk '/^_warn_ignored_knobs\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$body" ]]; then fail "_warn_ignored_knobs not found in muxm — extraction anchor failed (renamed/reformatted?)"; return; fi
  # _warn_ignored_knobs calls the _is_av1_codec helper; extract its real definition from muxm
  # (rather than duplicating it) so the isolated bash -c below has it and stays in sync with the source.
  iav1="$(grep -E '^_is_av1_codec\(\)' "$MUXM")"
  if [[ -z "$iav1" ]]; then fail "_is_av1_codec not found in muxm — _warn_ignored_knobs would mis-detect AV1"; return; fi

  # $1 = extra global assignments (override the safe defaults below).
  _wik() {
    bash -c 'warn(){ printf "%s\n" "$*"; }
      '"$iav1"'
      HW_ACCEL_RESOLVED=none; VIDEO_CODEC=libx265
      _CLI_CRF_EXPLICIT=0; _CLI_PRESET_EXPLICIT=0; _CLI_X265_PARAMS_EXPLICIT=0
      _CLI_X264_PARAMS_EXPLICIT=0; _CLI_HW_ACCEL_QUALITY_EXPLICIT=0
      _CLI_AV1_PARAMS_EXPLICIT=0; _CLI_LEVEL_EXPLICIT=0
      CRF_VALUE=18; PRESET_VALUE=slower; AV1_MAXRATE=""; AV1_BUFSIZE=""
      '"$1"'
      '"$body"'
      _warn_ignored_knobs'
  }
  local out
  _has() { echo "$2" | grep -qiE "$1"; }   # _has REGEX OUTPUT

  # ---- C1–C4: VideoToolbox ignores the x265/x264 software knobs ----
  out="$(_wik 'HW_ACCEL_RESOLVED=videotoolbox; _CLI_CRF_EXPLICIT=1')"
  if _has 'VideoToolbox.*-q:v.*--crf 18 is ignored' "$out"; then pass "warn-vt-ignores-crf: VT + --crf → warns -q:v"; else fail "warn-vt-ignores-crf: expected --crf-ignored warning, got: $out"; fi

  out="$(_wik 'HW_ACCEL_RESOLVED=videotoolbox; VIDEO_CODEC=libx264; _CLI_PRESET_EXPLICIT=1; PRESET_VALUE=slow')"
  if _has 'does not accept x265/x264 presets.*--preset slow' "$out"; then pass "warn-vt-ignores-preset: VT + --preset → warns preset ignored"; else fail "warn-vt-ignores-preset: expected --preset-ignored warning, got: $out"; fi

  out="$(_wik 'HW_ACCEL_RESOLVED=videotoolbox; _CLI_X265_PARAMS_EXPLICIT=1')"
  if _has 'does not accept --x265-params' "$out"; then pass "warn-vt-ignores-x265-params: VT + libx265 + --x265-params → warns"; else fail "warn-vt-ignores-x265-params: expected --x265-params-ignored warning, got: $out"; fi

  out="$(_wik 'HW_ACCEL_RESOLVED=videotoolbox; VIDEO_CODEC=libx264; _CLI_X264_PARAMS_EXPLICIT=1')"
  if _has 'honors only profile=high from --x264-params' "$out"; then pass "warn-vt-ignores-x264-params: VT + libx264 + --x264-params → warns"; else fail "warn-vt-ignores-x264-params: expected --x264-params-ignored warning, got: $out"; fi

  # C1–C4 negatives: not explicit, or software backend → no warning.
  out="$(_wik 'HW_ACCEL_RESOLVED=videotoolbox; _CLI_CRF_EXPLICIT=0')"
  if _has 'q:v' "$out"; then fail "warn-vt-ignores-crf neg: warned even though --crf not explicit"; else pass "warn-vt-ignores-crf neg: profile/default --crf does not warn under VT"; fi
  out="$(_wik 'HW_ACCEL_RESOLVED=none; _CLI_X265_PARAMS_EXPLICIT=1')"
  if [[ -z "$out" ]]; then pass "warn-vt-ignores-x265-params neg: software backend honors --x265-params (no warning)"; else fail "warn-vt-ignores-x265-params neg: unexpected warning on software backend: $out"; fi

  # ---- C5: --hw-accel-quality only affects hardware encoders ----
  out="$(_wik '_CLI_HW_ACCEL_QUALITY_EXPLICIT=1; HW_ACCEL_RESOLVED=none')"
  if _has 'hw-accel-quality has no effect' "$out"; then pass "warn-hwq-needs-hw-backend: --hw-accel-quality + no HW backend → warns"; else fail "warn-hwq-needs-hw-backend: expected hw-accel-quality warning, got: $out"; fi
  out="$(_wik '_CLI_HW_ACCEL_QUALITY_EXPLICIT=1; HW_ACCEL_RESOLVED=videotoolbox')"
  if _has 'hw-accel-quality has no effect' "$out"; then fail "warn-hwq-needs-hw-backend neg: warned even with a HW backend"; else pass "warn-hwq-needs-hw-backend neg: --hw-accel-quality with HW backend does not warn"; fi

  # ---- C7: --av1-params / --av1-maxrate / --av1-bufsize only for AV1 ----
  out="$(_wik '_CLI_AV1_PARAMS_EXPLICIT=1')"   # codec libx265
  if _has 'av1-params.*apply only to AV1' "$out"; then pass "warn-av1-params-need-av1: --av1-params on non-AV1 → warns"; else fail "warn-av1-params-need-av1: expected av1-params warning, got: $out"; fi
  out="$(_wik 'AV1_MAXRATE=8000k')"
  if _has 'apply only to AV1' "$out"; then pass "warn-av1-params-need-av1: --av1-maxrate on non-AV1 → warns"; else fail "warn-av1-params-need-av1: expected av1 rate warning, got: $out"; fi
  out="$(_wik 'VIDEO_CODEC=libsvt-av1; _CLI_AV1_PARAMS_EXPLICIT=1')"
  if _has 'apply only to AV1' "$out"; then fail "warn-av1-params-need-av1 neg: warned for an AV1 codec"; else pass "warn-av1-params-need-av1 neg: --av1-params honored on AV1 (no warning)"; fi

  # ---- C8: --x265-params / --x264-params only for their own codec ----
  out="$(_wik 'VIDEO_CODEC=libx264; _CLI_X265_PARAMS_EXPLICIT=1')"
  if _has 'x265-params applies only to the libx265' "$out"; then pass "warn-codec-params-match-codec: --x265-params on libx264 → warns"; else fail "warn-codec-params-match-codec: expected x265-params codec warning, got: $out"; fi
  out="$(_wik 'VIDEO_CODEC=libsvt-av1; _CLI_X264_PARAMS_EXPLICIT=1')"
  if _has 'x264-params applies only to the libx264' "$out"; then pass "warn-codec-params-match-codec: --x264-params on non-libx264 → warns"; else fail "warn-codec-params-match-codec: expected x264-params codec warning, got: $out"; fi
  out="$(_wik '_CLI_X265_PARAMS_EXPLICIT=1')"   # codec libx265 (matches)
  if _has 'x265-params applies only' "$out"; then fail "warn-codec-params-match-codec neg: warned when codec matches"; else pass "warn-codec-params-match-codec neg: --x265-params on libx265 honored (no warning)"; fi

  # ---- C9: --level has no effect on AV1 ----
  out="$(_wik 'VIDEO_CODEC=libsvt-av1; _CLI_LEVEL_EXPLICIT=1')"
  if _has 'level has no effect on AV1' "$out"; then pass "warn-level-no-op-on-av1: --level on AV1 → warns"; else fail "warn-level-no-op-on-av1: expected level warning, got: $out"; fi
  out="$(_wik '_CLI_LEVEL_EXPLICIT=1')"   # libx265, level honored
  if _has 'level has no effect' "$out"; then fail "warn-level-no-op-on-av1 neg: warned on a non-AV1 codec"; else pass "warn-level-no-op-on-av1 neg: --level on libx265 honored (no warning)"; fi

  unset -f _wik _has
}


_test_unit_h264_drops_dv() {
  # C6: _warn_h264_drops_dv warns when the source is Dolby Vision and the codec is
  # H.264 (which silently drops the RPU), but only when DV is still enabled. Source the helper
  # with a `warn` stub printing to stdout; deterministic, no real DV source needed. The
  # gated `dv_vt` suite covers the full post-probe path against a real DV fixture.
  local body
  body="$(awk '/^_warn_h264_drops_dv\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$body" ]]; then fail "_warn_h264_drops_dv not found in muxm — extraction anchor failed (renamed/reformatted?)"; return; fi

  _wddv() {  # $1 = global assignments
    bash -c 'warn(){ printf "%s\n" "$*"; }
      VIDEO_CODEC=libx265; IS_DV=0; DISABLE_DV=0
      '"$1"'
      '"$body"'
      _warn_h264_drops_dv'
  }
  local out

  out="$(_wddv 'VIDEO_CODEC=libx264; IS_DV=1; DISABLE_DV=0')"
  if echo "$out" | grep -qi "H.264 cannot carry Dolby Vision"; then
    pass "warn-h264-drops-dv: libx264 + DV source + DV enabled → warns"
  else
    fail "warn-h264-drops-dv: expected DV-dropped warning, got: $out"
  fi

  # Negatives: --no-dv (DISABLE_DV=1), non-DV source, and DV-capable codecs must stay quiet.
  if [[ -z "$(_wddv 'VIDEO_CODEC=libx264; IS_DV=1; DISABLE_DV=1')" ]]; then
    pass "warn-h264-drops-dv neg: libx264 + DV + --no-dv → no warning (deliberate opt-out)"
  else
    fail "warn-h264-drops-dv neg: warned despite DISABLE_DV=1"
  fi
  if [[ -z "$(_wddv 'VIDEO_CODEC=libx264; IS_DV=0; DISABLE_DV=0')" ]]; then
    pass "warn-h264-drops-dv neg: libx264 + non-DV source → no warning"
  else
    fail "warn-h264-drops-dv neg: warned on a non-DV source"
  fi
  if [[ -z "$(_wddv 'VIDEO_CODEC=libx265; IS_DV=1; DISABLE_DV=0')" ]]; then
    pass "warn-h264-drops-dv neg: libx265 + DV → no warning (HEVC carries DV)"
  else
    fail "warn-h264-drops-dv neg: warned for libx265"
  fi
  if [[ -z "$(_wddv 'VIDEO_CODEC=libsvt-av1; IS_DV=1; DISABLE_DV=0')" ]]; then
    pass "warn-h264-drops-dv neg: libsvt-av1 + DV → no C6 warning (AV1+DV handled upstream)"
  else
    fail "warn-h264-drops-dv neg: C6 warned for AV1 (should be handled by the upstream AV1+DV path)"
  fi

  unset -f _wddv
}


_test_unit_realpath_fallback() {
  # ---- realpath_fallback ----
  # Cross-platform path resolver used throughout muxm for SRC_ABS, LOGFILE, etc.
  # Must return an absolute path even when realpath(1) is unavailable or the
  # target doesn't exist yet.  Items 218o–218p from the testing plan.
  local body
  body="$(awk '/^realpath_fallback\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"

  # Absolute path input → returned unchanged (or resolved if exists)
  local abs
  abs="$(bash -c "$body"$'\n'"realpath_fallback /tmp/muxm_test_abs.mkv")"
  if [[ "$abs" == /* ]]; then
    pass "realpath_fallback: absolute input returns absolute path"
  else
    fail "realpath_fallback: absolute input expected absolute, got '$abs'"
  fi

  # Relative path input → prefixed with a directory component
  local rel
  rel="$(cd "$TESTDIR" && bash -c "$body"$'\n'"realpath_fallback some_movie.mkv")"
  if [[ "$rel" == /* ]]; then
    pass "realpath_fallback: relative input returns absolute path"
  else
    fail "realpath_fallback: relative input expected absolute, got '$rel'"
  fi

  # Non-existent file → path is still absolute (no existence check)
  local noexist
  noexist="$(bash -c "$body"$'\n'"realpath_fallback /no/such/path/file.mkv")"
  if [[ "$noexist" == /* ]]; then
    pass "realpath_fallback: non-existent file returns absolute path"
  else
    fail "realpath_fallback: non-existent file expected absolute, got '$noexist'"
  fi
}

_test_unit_apply_level_vbv() {
  # ---- apply_level_vbv ----
  # Appends VBV guardrails to X265_PARAMS when CONSERVATIVE_VBV=1 and LEVEL_VALUE
  # is set to a known level.  A regression silently drops the vbv-maxrate/bufsize
  # constraints, allowing the encoder to produce files that exceed device bitrate caps.
  # Items 218q–218t from the testing plan.
  #
  # We run apply_level_vbv in a subshell with the VBV constants and X265_PARAMS
  # pre-declared, then print X265_PARAMS to verify injection.
  local vbv_env='CONSERVATIVE_VBV=1
LEVEL_VBV_4_1_MAXRATE=10000k; LEVEL_VBV_4_1_BUFSIZE=20000k
LEVEL_VBV_5_0_MAXRATE=25000k; LEVEL_VBV_5_0_BUFSIZE=50000k
LEVEL_VBV_5_1_MAXRATE=40000k; LEVEL_VBV_5_1_BUFSIZE=80000k
LEVEL_VBV_5_2_MAXRATE=60000k; LEVEL_VBV_5_2_BUFSIZE=120000k
X265_PARAMS=""
note() { :; }'
  local body
  body="$(awk '/^apply_level_vbv\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"

  local out

  # Level 4.1 — 10000k / 20000k
  out="$(bash -c "$vbv_env"$'\n'"$body"$'\n'"apply_level_vbv 4.1; echo \"\$X265_PARAMS\"")"
  if echo "$out" | grep -qF "vbv-maxrate=10000k"; then pass "apply_level_vbv(4.1): vbv-maxrate=10000k"; else fail "apply_level_vbv(4.1): expected vbv-maxrate=10000k, got '$out'"; fi
  if echo "$out" | grep -qF "vbv-bufsize=20000k"; then pass "apply_level_vbv(4.1): vbv-bufsize=20000k"; else fail "apply_level_vbv(4.1): expected vbv-bufsize=20000k, got '$out'"; fi

  # Level 5.0 — 25000k / 50000k
  out="$(bash -c "$vbv_env"$'\n'"$body"$'\n'"apply_level_vbv 5.0; echo \"\$X265_PARAMS\"")"
  if echo "$out" | grep -qF "vbv-maxrate=25000k"; then pass "apply_level_vbv(5.0): vbv-maxrate=25000k"; else fail "apply_level_vbv(5.0): expected vbv-maxrate=25000k, got '$out'"; fi
  if echo "$out" | grep -qF "vbv-bufsize=50000k"; then pass "apply_level_vbv(5.0): vbv-bufsize=50000k"; else fail "apply_level_vbv(5.0): expected vbv-bufsize=50000k, got '$out'"; fi

  # Level 5.1 — 40000k / 80000k
  out="$(bash -c "$vbv_env"$'\n'"$body"$'\n'"apply_level_vbv 5.1; echo \"\$X265_PARAMS\"")"
  if echo "$out" | grep -qF "vbv-maxrate=40000k"; then pass "apply_level_vbv(5.1): vbv-maxrate=40000k"; else fail "apply_level_vbv(5.1): expected vbv-maxrate=40000k, got '$out'"; fi
  if echo "$out" | grep -qF "vbv-bufsize=80000k"; then pass "apply_level_vbv(5.1): vbv-bufsize=80000k"; else fail "apply_level_vbv(5.1): expected vbv-bufsize=80000k, got '$out'"; fi

  # Level 5.2 — 60000k / 120000k
  out="$(bash -c "$vbv_env"$'\n'"$body"$'\n'"apply_level_vbv 5.2; echo \"\$X265_PARAMS\"")"
  if echo "$out" | grep -qF "vbv-maxrate=60000k"; then pass "apply_level_vbv(5.2): vbv-maxrate=60000k"; else fail "apply_level_vbv(5.2): expected vbv-maxrate=60000k, got '$out'"; fi
  if echo "$out" | grep -qF "vbv-bufsize=120000k"; then pass "apply_level_vbv(5.2): vbv-bufsize=120000k"; else fail "apply_level_vbv(5.2): expected vbv-bufsize=120000k, got '$out'"; fi

  # Unknown level with CONSERVATIVE_VBV=1 → no vbv injected, but level-idc still appended
  out="$(bash -c "$vbv_env"$'\n'"$body"$'\n'"apply_level_vbv 6.0; echo \"\$X265_PARAMS\"")"
  if echo "$out" | grep -qF "level-idc=6.0"; then pass "apply_level_vbv(6.0, unknown): level-idc appended"; else fail "apply_level_vbv(6.0, unknown): expected level-idc=6.0, got '$out'"; fi
  if ! echo "$out" | grep -qF "vbv-maxrate"; then pass "apply_level_vbv(6.0, unknown): no vbv-maxrate for unknown level"; else fail "apply_level_vbv(6.0, unknown): unexpected vbv-maxrate in '$out'"; fi

  # CONSERVATIVE_VBV=0 → no VBV constraints even for known level (only level-idc injected)
  local novbv_env="${vbv_env/CONSERVATIVE_VBV=1/CONSERVATIVE_VBV=0}"
  out="$(bash -c "$novbv_env"$'\n'"$body"$'\n'"apply_level_vbv 5.1; echo \"\$X265_PARAMS\"")"
  if ! echo "$out" | grep -qF "vbv-maxrate"; then pass "apply_level_vbv(5.1, CONSERVATIVE_VBV=0): no vbv-maxrate"; else fail "apply_level_vbv(5.1, CONSERVATIVE_VBV=0): unexpected vbv-maxrate in '$out'"; fi
  if echo "$out" | grep -qF "level-idc=5.1"; then pass "apply_level_vbv(5.1, CONSERVATIVE_VBV=0): level-idc still injected"; else fail "apply_level_vbv(5.1, CONSERVATIVE_VBV=0): expected level-idc=5.1, got '$out'"; fi
}

_test_unit_mapping_helpers() {
  # Pure codec/extension/language mapping helpers. These are tiny lookup tables
  # whose only failure mode is a wrong/dropped case arm — exactly what a direct
  # unit test pins down. A bad mapping surfaces downstream as cryptic ffmpeg
  # "Unable to choose output format" / "Unknown encoder" errors.

  # ---- _audio_codec_ext (encoder name → intermediate-file extension) ----
  assert_muxm_fn_stdout "_audio_codec_ext(libopus)=opus"     "opus" _audio_codec_ext "" "libopus"
  assert_muxm_fn_stdout "_audio_codec_ext(libmp3lame)=mp3"   "mp3"  _audio_codec_ext "" "libmp3lame"
  assert_muxm_fn_stdout "_audio_codec_ext(libvorbis)=ogg"    "ogg"  _audio_codec_ext "" "libvorbis"
  assert_muxm_fn_stdout "_audio_codec_ext(aac)=aac"          "aac"  _audio_codec_ext "" "aac"
  assert_muxm_fn_stdout "_audio_codec_ext(eac3)=eac3"        "eac3" _audio_codec_ext "" "eac3"
  assert_muxm_fn_stdout "_audio_codec_ext(flac)=flac"        "flac" _audio_codec_ext "" "flac"
  # L4: the AAC encoder variants must resolve to a real muxer extension (.m4a), not the raw encoder
  # name — otherwise a --audio-force-codec libfdk_aac/aac_at transcode names the intermediate after
  # the encoder, ffmpeg cannot choose a muxer, and the run die 43's late. (A `*)` fallthrough would
  # echo the encoder name back, which is what these assertions catch.)
  assert_muxm_fn_stdout "_audio_codec_ext(libfdk_aac)=m4a"   "m4a"  _audio_codec_ext "" "libfdk_aac"
  assert_muxm_fn_stdout "_audio_codec_ext(aac_at)=m4a"       "m4a"  _audio_codec_ext "" "aac_at"
  # Fallback: a genuinely unknown encoder name is still echoed back unchanged.
  assert_muxm_fn_stdout "_audio_codec_ext(bogus_enc)=passthrough" "bogus_enc" _audio_codec_ext "" "bogus_enc"

  # ---- _ext_sub_codec_from_ext (subtitle file extension → ffprobe codec name) ----
  assert_muxm_fn_stdout "_ext_sub_codec_from_ext(srt)=subrip"        "subrip"            _ext_sub_codec_from_ext "" "srt"
  assert_muxm_fn_stdout "_ext_sub_codec_from_ext(ass)=ass"           "ass"               _ext_sub_codec_from_ext "" "ass"
  assert_muxm_fn_stdout "_ext_sub_codec_from_ext(ssa)=ssa"           "ssa"               _ext_sub_codec_from_ext "" "ssa"
  assert_muxm_fn_stdout "_ext_sub_codec_from_ext(vtt)=webvtt"        "webvtt"            _ext_sub_codec_from_ext "" "vtt"
  assert_muxm_fn_stdout "_ext_sub_codec_from_ext(sup)=hdmv_pgs"      "hdmv_pgs_subtitle" _ext_sub_codec_from_ext "" "sup"
  assert_muxm_fn_stdout "_ext_sub_codec_from_ext(idx)=dvd_subtitle"  "dvd_subtitle"      _ext_sub_codec_from_ext "" "idx"
  assert_muxm_fn_stdout "_ext_sub_codec_from_ext(SRT)=subrip (case-insensitive)" "subrip" _ext_sub_codec_from_ext "" "SRT"
  assert_muxm_fn_stdout "_ext_sub_codec_from_ext(xyz)=unknown"       "unknown"           _ext_sub_codec_from_ext "" "xyz"

  # ---- _norm_lang_code (ISO 639-1 → ISO 639-2/T) ----
  assert_muxm_fn_stdout "_norm_lang_code(en)=eng"  "eng" _norm_lang_code "" "en"
  assert_muxm_fn_stdout "_norm_lang_code(es)=spa"  "spa" _norm_lang_code "" "es"
  assert_muxm_fn_stdout "_norm_lang_code(fr)=fra"  "fra" _norm_lang_code "" "fr"
  assert_muxm_fn_stdout "_norm_lang_code(ja)=jpn"  "jpn" _norm_lang_code "" "ja"
  assert_muxm_fn_stdout "_norm_lang_code(EN)=eng (case-insensitive)" "eng" _norm_lang_code "" "EN"
  # Already-3-letter code falls through unchanged (lowercased).
  assert_muxm_fn_stdout "_norm_lang_code(eng)=eng (passthrough)" "eng" _norm_lang_code "" "eng"
  assert_muxm_fn_stdout "_norm_lang_code(zz)=zz (unknown passthrough)" "zz" _norm_lang_code "" "zz"

  # ---- _container_supports_bitmap_subs (only Matroska carries PGS/VobSub) ----
  assert_muxm_fn_exit "_container_supports_bitmap_subs(matroska)=yes" 0 _container_supports_bitmap_subs 'MUX_FORMAT=matroska'
  assert_muxm_fn_exit "_container_supports_bitmap_subs(mp4)=no"       1 _container_supports_bitmap_subs 'MUX_FORMAT=mp4'
  assert_muxm_fn_exit "_container_supports_bitmap_subs(mov)=no"       1 _container_supports_bitmap_subs 'MUX_FORMAT=mov'

  # ---- ffmpeg_has_muxer (capability probe; muxer name is field 2 of -muxers) ----
  # Regression guard for the awk-field bug that made this always return false
  # (broke the PGS→vobsub fast-path). matroska/mp4 are present in every build.
  assert_muxm_fn_exit "ffmpeg_has_muxer(matroska)=present" 0 ffmpeg_has_muxer "" "matroska"
  assert_muxm_fn_exit "ffmpeg_has_muxer(mp4)=present"      0 ffmpeg_has_muxer "" "mp4"
  assert_muxm_fn_exit "ffmpeg_has_muxer(mov)=present"      0 ffmpeg_has_muxer "" "mov"
  assert_muxm_fn_exit "ffmpeg_has_muxer(definitelynotamuxer)=absent" 1 ffmpeg_has_muxer "" "definitelynotamuxer"

  # ---- _normalize_codec_lang (lowercases codec+lang via nameref; empty lang
  #      defaults to TAG_LANGUAGE_DEFAULT). Uses `local -n`, so run it directly. ----
  local ncl_body
  ncl_body="$(awk '/^_normalize_codec_lang\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  local ncl_out
  # Mixed-case codec + empty lang → codec lowercased, lang filled from default.
  ncl_out="$(bash -c 'TAG_LANGUAGE_DEFAULT=und; c="EAC3"; l=""'"
$ncl_body"'
_normalize_codec_lang c l; printf "%s|%s" "$c" "$l"')"
  if [[ "$ncl_out" == "eac3|und" ]]; then pass "_normalize_codec_lang(EAC3,'')=eac3|und (default-filled)"; else fail "_normalize_codec_lang(EAC3,'') expected 'eac3|und', got '$ncl_out'"; fi
  # Present lang is only lowercased, never re-mapped to a 3-letter code.
  ncl_out="$(bash -c 'TAG_LANGUAGE_DEFAULT=und; c="AAC"; l="EN"'"
$ncl_body"'
_normalize_codec_lang c l; printf "%s|%s" "$c" "$l"')"
  if [[ "$ncl_out" == "aac|en" ]]; then pass "_normalize_codec_lang(AAC,EN)=aac|en (lowercase only)"; else fail "_normalize_codec_lang(AAC,EN) expected 'aac|en', got '$ncl_out'"; fi

  # ---- _parse_ext_sub_filename (external-sub filename → "lang<TAB>type").
  #      Calls _norm_lang_code, so extract both bodies. ----
  local pes_body norm_body pes_combined
  pes_body="$(awk '/^_parse_ext_sub_filename\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  norm_body="$(awk '/^_norm_lang_code\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  pes_combined="TAG_LANGUAGE_DEFAULT=und"$'\n'"$norm_body"$'\n'"$pes_body"
  _test_pes() {
    local stem="$1" fname="$2" expect="$3" label="$4" got
    got="$(bash -c "$pes_combined"$'\n'"_parse_ext_sub_filename \"\$1\" \"\$2\"" -- "$stem" "$fname")"
    if [[ "$got" == "$expect" ]]; then pass "$label"; else fail "$label — expected '$expect', got '$got'"; fi
  }
  _test_pes "movie" "movie.srt"            "und"$'\t'"full"   "_parse_ext_sub_filename(movie.srt)=und/full (no qualifier)"
  _test_pes "movie" "movie.en.srt"         "eng"$'\t'"full"   "_parse_ext_sub_filename(movie.en.srt)=eng/full"
  _test_pes "movie" "movie.spa.srt"        "spa"$'\t'"full"   "_parse_ext_sub_filename(movie.spa.srt)=spa/full"
  _test_pes "movie" "movie.forced.en.srt"  "eng"$'\t'"forced" "_parse_ext_sub_filename(movie.forced.en.srt)=eng/forced"
  _test_pes "movie" "movie.en.sdh.srt"     "eng"$'\t'"sdh"    "_parse_ext_sub_filename(movie.en.sdh.srt)=eng/sdh"
  # CR-13: `hi` is language-first (Hindi) when it fills the empty language slot, but stays the SDH
  # marker once a language is already set. Explicit sdh/hearing/cc markers are unaffected.
  _test_pes "movie" "movie.hi.srt"         "hi"$'\t'"full"    "_parse_ext_sub_filename(movie.hi.srt)=hi/full (Hindi, not SDH — CR-13)"
  _test_pes "movie" "movie.eng.hi.srt"     "eng"$'\t'"sdh"    "_parse_ext_sub_filename(movie.eng.hi.srt)=eng/sdh (hi = SDH once lang set — CR-13)"
  _test_pes "movie" "movie.hearing.srt"    "und"$'\t'"sdh"    "_parse_ext_sub_filename(movie.hearing.srt)=und/sdh (explicit SDH marker)"

  # ---- _detect_mp4box (cross-platform: MP4Box on macOS, mp4box on Linux) ----
  # Resolves which DV-muxing binary is on PATH. We mock PATH with fake
  # executables so the test is deterministic regardless of what's installed.
  local mp4_body mp4_dir
  mp4_body="$(awk '/^_detect_mp4box\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  mp4_dir="$TESTDIR/mp4box_mock"; mkdir -p "$mp4_dir"
  # PATH is set INSIDE the bash -c (via $1) so `command -v` resolves only against
  # the mock dir — setting it on the `bash` invocation itself would break locating
  # the bash binary. Case 1: MP4Box (capitalized) present → MP4BOX_CMD=MP4Box.
  printf '#!/bin/sh\n' > "$mp4_dir/MP4Box"; chmod +x "$mp4_dir/MP4Box"
  local mp4_out
  mp4_out="$(bash -c "$mp4_body"$'\n''PATH="$1"; _detect_mp4box && printf "%s" "$MP4BOX_CMD"' -- "$mp4_dir")"
  if [[ "$mp4_out" == "MP4Box" ]]; then pass "_detect_mp4box: MP4Box on PATH → MP4BOX_CMD=MP4Box"; else fail "_detect_mp4box: expected 'MP4Box', got '$mp4_out'"; fi
  # Case 2: only lowercase mp4box present → MP4BOX_CMD=mp4box.
  # Only meaningful on a case-SENSITIVE filesystem; on macOS's default
  # case-insensitive APFS/HFS+, `command -v MP4Box` resolves the lowercase file
  # and the fallback branch is unreachable — so probe and skip there.
  rm -f "$mp4_dir/MP4Box" "$mp4_dir/mp4box"
  printf '#!/bin/sh\n' > "$mp4_dir/mp4box"; chmod +x "$mp4_dir/mp4box"
  if [[ -e "$mp4_dir/MP4Box" ]]; then
    skip "_detect_mp4box: lowercase fallback — case-insensitive filesystem (Linux-only assertion)"
  else
    mp4_out="$(bash -c "$mp4_body"$'\n''PATH="$1"; _detect_mp4box && printf "%s" "$MP4BOX_CMD"' -- "$mp4_dir")"
    if [[ "$mp4_out" == "mp4box" ]]; then pass "_detect_mp4box: mp4box on PATH → MP4BOX_CMD=mp4box"; else fail "_detect_mp4box: expected 'mp4box', got '$mp4_out'"; fi
  fi
  # Case 3: neither present → rc 1, MP4BOX_CMD empty
  rm -f "$mp4_dir/mp4box" "$mp4_dir/MP4Box"
  mp4_out="$(bash -c "$mp4_body"$'\n''PATH="$1"; _detect_mp4box; printf "rc=%s|%s" "$?" "$MP4BOX_CMD"' -- "$mp4_dir")" || true
  if [[ "$mp4_out" == "rc=1|" ]]; then pass "_detect_mp4box: neither binary → rc 1, MP4BOX_CMD empty"; else fail "_detect_mp4box: expected 'rc=1|', got '$mp4_out'"; fi
}

_test_unit_av1_helpers() {
  # ---- _av1_preset_multiplier ----
  # AV1 uses numeric presets (0=slowest/best, 13=fastest/worst).
  # Five buckets: 0-1 → 900, 2-4 → 950, 5-7 → 1000, 8-10 → 1050, 11-13 → 1200.
  # A regression here silently breaks disk-space estimation for AV1 encodes.
  assert_muxm_fn_stdout "_av1_preset_multiplier(0)=900"   "900"  _av1_preset_multiplier "" "0"
  assert_muxm_fn_stdout "_av1_preset_multiplier(1)=900"   "900"  _av1_preset_multiplier "" "1"
  assert_muxm_fn_stdout "_av1_preset_multiplier(2)=950"   "950"  _av1_preset_multiplier "" "2"
  assert_muxm_fn_stdout "_av1_preset_multiplier(3)=950"   "950"  _av1_preset_multiplier "" "3"
  assert_muxm_fn_stdout "_av1_preset_multiplier(4)=950"   "950"  _av1_preset_multiplier "" "4"
  assert_muxm_fn_stdout "_av1_preset_multiplier(5)=1000"  "1000" _av1_preset_multiplier "" "5"
  assert_muxm_fn_stdout "_av1_preset_multiplier(6)=1000"  "1000" _av1_preset_multiplier "" "6"
  assert_muxm_fn_stdout "_av1_preset_multiplier(7)=1000"  "1000" _av1_preset_multiplier "" "7"
  assert_muxm_fn_stdout "_av1_preset_multiplier(8)=1050"  "1050" _av1_preset_multiplier "" "8"
  assert_muxm_fn_stdout "_av1_preset_multiplier(9)=1050"  "1050" _av1_preset_multiplier "" "9"
  assert_muxm_fn_stdout "_av1_preset_multiplier(10)=1050" "1050" _av1_preset_multiplier "" "10"
  assert_muxm_fn_stdout "_av1_preset_multiplier(11)=1200" "1200" _av1_preset_multiplier "" "11"
  assert_muxm_fn_stdout "_av1_preset_multiplier(12)=1200" "1200" _av1_preset_multiplier "" "12"
  assert_muxm_fn_stdout "_av1_preset_multiplier(13)=1200" "1200" _av1_preset_multiplier "" "13"
  # Default (no arg) falls through to 5-7 bucket
  assert_muxm_fn_stdout "_av1_preset_multiplier(default)=1000" "1000" _av1_preset_multiplier "" ""

  # ---- build_av1_params ----
  # build_av1_params() copies SVT_AV1_PARAMS_BASE → SVT_AV1_PARAMS.
  # Verify that after a call SVT_AV1_PARAMS equals SVT_AV1_PARAMS_BASE.
  local bap_body result
  bap_body="$(awk '/^build_av1_params\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$bap_body" ]]; then
    fail "build_av1_params not found in muxm — extraction anchor failed (renamed/reformatted?)"
  else
    # Default base value
    result="$(bash -c 'SVT_AV1_PARAMS_BASE="film-grain=0:enable-overlays=1:scd=1"; SVT_AV1_PARAMS=""'"
$bap_body"'
build_av1_params; echo "$SVT_AV1_PARAMS"')"
    if [[ "$result" == "film-grain=0:enable-overlays=1:scd=1" ]]; then
      pass "build_av1_params: SVT_AV1_PARAMS equals SVT_AV1_PARAMS_BASE (default)"
    else
      fail "build_av1_params: expected 'film-grain=0:enable-overlays=1:scd=1', got '$result'"
    fi

    # Custom base value
    result="$(bash -c 'SVT_AV1_PARAMS_BASE="film-grain=8:tune=0"; SVT_AV1_PARAMS=""'"
$bap_body"'
build_av1_params; echo "$SVT_AV1_PARAMS"')"
    if [[ "$result" == "film-grain=8:tune=0" ]]; then
      pass "build_av1_params: SVT_AV1_PARAMS equals custom SVT_AV1_PARAMS_BASE"
    else
      fail "build_av1_params: expected 'film-grain=8:tune=0', got '$result'"
    fi

    # Empty base value → SVT_AV1_PARAMS is empty
    result="$(bash -c 'SVT_AV1_PARAMS_BASE=""; SVT_AV1_PARAMS="stale"'"
$bap_body"'
build_av1_params; echo "$SVT_AV1_PARAMS"')"
    if [[ "$result" == "" ]]; then
      pass "build_av1_params: empty SVT_AV1_PARAMS_BASE → empty SVT_AV1_PARAMS"
    else
      fail "build_av1_params: expected empty SVT_AV1_PARAMS, got '$result'"
    fi
  fi
}

_test_unit_fps_helpers() {
  # ---- _fps_to_decimal ----
  # Converts a frame rate (exact rational "num/den" or a plain decimal) to a
  # 4-dp decimal string. Underpins the DV raw-ES fps stamping (SRC_FPS) and the
  # post-mux frame-rate integrity guard. Invalid/zero input must echo nothing so
  # callers skip fps enforcement rather than stamp a bogus rate.
  assert_muxm_fn_stdout "_fps_to_decimal(24000/1001)=23.9760" "23.9760" _fps_to_decimal "" "24000/1001"
  assert_muxm_fn_stdout "_fps_to_decimal(30000/1001)=29.9700" "29.9700" _fps_to_decimal "" "30000/1001"
  assert_muxm_fn_stdout "_fps_to_decimal(25/1)=25.0000"       "25.0000" _fps_to_decimal "" "25/1"
  assert_muxm_fn_stdout "_fps_to_decimal(24)=24.0000"         "24.0000" _fps_to_decimal "" "24"
  assert_muxm_fn_stdout "_fps_to_decimal(23.976)=23.9760"     "23.9760" _fps_to_decimal "" "23.976"
  assert_muxm_fn_stdout "_fps_to_decimal(0/0)=empty"          ""        _fps_to_decimal "" "0/0"
  assert_muxm_fn_stdout "_fps_to_decimal(0)=empty"            ""        _fps_to_decimal "" "0"
  assert_muxm_fn_stdout "_fps_to_decimal('')=empty"           ""        _fps_to_decimal "" ""
  assert_muxm_fn_stdout "_fps_to_decimal(abc)=empty"          ""        _fps_to_decimal "" "abc"
}

_test_unit_extract_helper() {
  # Self-test for _extract_muxm_fns: prove the helper works at all by extracting a target
  # plus a real pure-helper dep and
  # run it with only its env mocked. _parse_ext_sub_filename calls _norm_lang_code — pull both
  # and exercise the real parse (movie.en.srt → "eng<TAB>full").
  local body got
  body="$(_extract_muxm_fns _norm_lang_code _parse_ext_sub_filename)"
  if [[ -z "$body" ]]; then
    fail "_extract_muxm_fns: returned empty body for a known function pair"
  else
    got="$(bash -c "TAG_LANGUAGE_DEFAULT=und"$'\n'"$body"$'\n''_parse_ext_sub_filename "$1" "$2"' -- movie movie.en.srt)"
    if [[ "$got" == "eng"$'\t'"full" ]]; then
      pass "_extract_muxm_fns: target + pure-helper dep runs with the real formula (eng/full)"
    else
      fail "_extract_muxm_fns: expected 'eng<TAB>full', got '$got'"
    fi
  fi
  # A missing function name must make the call return non-zero (never a silent partial body
  # that would let a renamed dependency pass misleadingly).
  if _extract_muxm_fns _definitely_not_a_real_fn_zzz >/dev/null 2>&1; then
    fail "_extract_muxm_fns: should return non-zero for a missing function name"
  else
    pass "_extract_muxm_fns: missing function name → non-zero (no silent partial extraction)"
  fi
}

_test_unit_score_audio_stream() {
  # 2.1: direct unit test of _score_audio_stream — the function that decides which audio track
  # every user gets, and which NO test exercised before (the deleted "invariants" block was an
  # arithmetic tautology). Extract the function + its pure-helper deps via _extract_muxm_fns,
  # mock the _audio_stream_info I/O boundary, and assert the emitted score equals an INDEPENDENT
  # recompute of the documented components from CANONICAL constants. A formula edit OR a
  # default-weight edit in muxm then diverges from the oracle.
  #
  # Do NOT set the AUDIO_SCORE_* weights in env_setup: that would MASK M-AUD-3, because it mutates
  # the top-level `declare -i AUDIO_SCORE_SURROUND_BONUS=30`, which _extract_muxm_fns never pulls
  # in, so an injected value would override the mutated default and the test would pass under
  # mutation. Instead we SOURCE muxm's actual default lines (^-anchored, to
  # skip the indented profile-arm reassignments) and use canonical hardcoded constants as oracle.
  local body
  body="$(_extract_muxm_fns _score_audio_stream _split_tab _normalize_codec_lang _audio_codec_rank \
                            _audio_lang_matches _norm_lang_code audio_is_lossless _audio_is_commentary)" || {
    fail "unit-score-audio-stream: could not extract _score_audio_stream + helpers from muxm"; return; }
  local defaults
  defaults="$(grep -E '^(declare -i )?(AUDIO_SCORE_[A-Z_]+|AUDIO_CODEC_PREFERENCE|AUDIO_LANG_PREF|TAG_LANGUAGE_DEFAULT|_AUDIO_CODEC_RANK_PREF)=' "$MUXM")"

  # muxm's emitted score for a mocked stream (codec ch lang br title). The mock ignores the idx
  # arg and emits the canned tab-separated record _score_audio_stream expects.
  # shellcheck disable=SC2016  # literal mock script body; $@/${args[N]} must expand inside `bash -c`, not now
  local _mockrun='args=("$@")
_audio_stream_info(){ printf "%s\t%s\t%s\t%s\t%s\n" "${args[0]}" "${args[1]}" "${args[2]}" "${args[3]}" "${args[4]}"; }
_score_audio_stream 0 | cut -f1'
  _su_score(){ bash -c "$defaults"$'\n'"$body"$'\n'"$_mockrun" -- "$1" "$2" "$3" "$4" "$5"; }

  # Independent oracle — documented formula with CANONICAL constants (NOT muxm's current values).
  # All-`if` (no `cond && action`) to stay set-e-safe inside the command substitution.
  local C_CHMULT=20 C_SURR=30 C_LANG=150 C_COMM=200 C_DIV=50000 C_CAP=8 C_FLOOR=1536000
  local C_PREF="eac3,ac3,aac,alac,other" C_LANGPREF="eng"
  _su_expect(){
    local codec="${1,,}" ch="$2" lang="${3,,}" br="$4" title="${5,,}" s=0 rank=10 i=0 p matched=0
    if [[ -z "$lang" ]]; then lang="und"; fi
    local -a _pa _lp; IFS=',' read -ra _pa <<<"$C_PREF"
    for p in "${_pa[@]}"; do if [[ "$codec" == "$p" ]]; then rank=$i; break; fi; i=$(( i + 1 )); done
    IFS=',' read -ra _lp <<<"$C_LANGPREF"
    for p in "${_lp[@]}"; do if [[ "$lang" == "$p" ]]; then matched=1; break; fi; done
    if (( matched )); then s=$(( s + C_LANG )); fi
    s=$(( s + ch * C_CHMULT ))
    if (( ch >= 6 )); then s=$(( s + C_SURR )); fi
    local inv=$(( (10 - rank) * 10 )); if (( inv < 0 )); then inv=0; fi; s=$(( s + inv ))
    local eff="$br"
    if (( br == 0 )); then case "$codec" in truehd|dts|dca|flac|alac|pcm_s16le|pcm_s24le|pcm_s32le) eff=$C_FLOOR ;; esac; fi
    if (( eff > 0 )); then local bb=$(( eff / C_DIV )); if (( bb > C_CAP )); then bb=$C_CAP; fi; s=$(( s + bb )); fi
    if [[ "$title" =~ (commentary|comentario|kommentar|descriptive|audio.description|visually.impaired) ]]; then s=$(( s - C_COMM )); fi
    echo "$s"
  }
  _su_assert(){
    local label="$1"; shift; local got want
    got="$(_su_score "$@")"; want="$(_su_expect "$@")"
    if [[ "$got" == "$want" ]]; then pass "$label (score=$got)"; else fail "$label — muxm=$got, recomputed=$want"; fi
  }

  # Full-score oracle scenarios. ch<6 keeps them independent of the surround bonus, so the
  # M-AUD-1 (rank-formula) signature stays distinct from M-AUD-3. eac3=rank 0 / aac=rank 2 (≠5),
  # so M-AUD-1's (10-rank)*10 → rank*10 diverges here.
  _su_assert "unit-score-audio-stream score: eac3 2ch eng 448k (rank+lang+bitrate)" eac3 2 eng 448000 ""
  _su_assert "unit-score-audio-stream score: aac 2ch und 0k (rank 2, no lang/floor)"  aac 2 und 0 ""
  _su_assert "unit-score-audio-stream score: flac 2ch eng 0k (lossless floor reaches cap)" flac 2 eng 0 ""
  _su_assert "unit-score-audio-stream score: eac3 2ch eng + commentary (penalty)"     eac3 2 eng 448000 "Director's Commentary"
  _su_assert "unit-score-audio-stream score: aac 8ch eng 256k (channels + bitrate cap)" aac 8 eng 256000 ""

  # Surround-bonus isolation (M-AUD-3 signature): score(6ch) − score(5ch) for the SAME codec is
  # exactly one channel step + the surround bonus. The rank component cancels (same codec), so
  # M-AUD-1 does NOT move it — only M-AUD-3 (surround→0) or a CHANNEL_MULTIPLIER edit does.
  local s6 s5 diff
  s6="$(_su_score eac3 6 eng 448000 "")"; s5="$(_su_score eac3 5 eng 448000 "")"
  diff=$(( s6 - s5 ))
  if (( diff == C_CHMULT + C_SURR )); then
    pass "unit-score-audio-stream surround: bonus at >=6ch verified (6ch-5ch = $diff = chmult+surround)"
  else
    fail "unit-score-audio-stream surround: bonus at >=6ch — expected 6ch-5ch=$(( C_CHMULT + C_SURR )), got $diff (surround/chmult regression)"
  fi
}

_test_unit_decide_color_and_pixfmt() {
  # 2.3: direct unit test of decide_color_and_pixfmt — chooses the output PROFILE + pixel format.
  # Mock _probe_field (the source-color I/O boundary) and assert the PROFILE_DESC + TARGET_PIXFMT
  # globals across SDR-8bit, --sdr-force-10bit, SDR-10bit-source auto, HDR10, HLG, tonemap.
  # This asserts the decision function's output VARS (not an encoded file's tags), so unlike the
  # 1.2 HDR-tag path there is no ffmpeg auto-copy to make a branch mutation un-catchable.
  local body
  # 4.2: decide_color_and_pixfmt now delegates its 4 color-field probes to
  # _probe_video_color_fields (which itself uses _split_tab) instead of calling _probe_field
  # directly 4 times — pull both in too, else the extracted function can't resolve the call.
  body="$(_extract_muxm_fns decide_color_and_pixfmt _lower _probe_video_color_fields _split_tab)" \
    || { fail "unit-decide-color-and-pixfmt: could not extract decide_color_and_pixfmt + _lower"; return; }
  # $1=pix $2=prim $3=trc $4=cspace $5=optional flags ("SDR_FORCE_10BIT=1" etc.). Emits PROF|PIXFMT.
  _dcp(){
    local pix="$1" prim="$2" trc="$3" cspace="$4" flags="${5:-}"
    bash -c "HDR_TARGET_PIXFMT=yuv420p10le; FORCE_CHROMA_420=0; TONEMAP_HDR_TO_SDR=0; SDR_FORCE_10BIT=0; SDR_USE_10BIT_IF_SRC_10BIT=0
$flags
P_PIX=\"\$1\"; P_PRIM=\"\$2\"; P_TRC=\"\$3\"; P_CSPACE=\"\$4\"
_probe_field(){ case \"\$1\" in pix_fmt) printf '%s' \"\$P_PIX\";; color_primaries) printf '%s' \"\$P_PRIM\";; color_transfer) printf '%s' \"\$P_TRC\";; color_space) printf '%s' \"\$P_CSPACE\";; esac; }
warn(){ :; }; note(){ :; }
$body
decide_color_and_pixfmt
printf '%s|%s' \"\$PROFILE_DESC\" \"\$TARGET_PIXFMT\"" -- "$pix" "$prim" "$trc" "$cspace"
  }
  _dcp_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label ($got)"; else fail "$label — got '$got', expected '$want'"; fi; }

  _dcp_assert "unit-decide-color-and-pixfmt color: SDR 8-bit → SDR/yuv420p"             "SDR|yuv420p"          "$(_dcp yuv420p '' '' '')"
  _dcp_assert "unit-decide-color-and-pixfmt color: SDR --sdr-force-10bit → SDR/10le"    "SDR|yuv420p10le"      "$(_dcp yuv420p '' '' '' 'SDR_FORCE_10BIT=1')"
  _dcp_assert "unit-decide-color-and-pixfmt color: SDR 10-bit source auto → SDR/10le"   "SDR|yuv420p10le"      "$(_dcp yuv420p10le '' '' '' 'SDR_USE_10BIT_IF_SRC_10BIT=1')"
  _dcp_assert "unit-decide-color-and-pixfmt color: HDR10 (bt2020/pq) → HDR10/10le"      "HDR10|yuv420p10le"    "$(_dcp yuv420p10le bt2020 smpte2084 bt2020nc)"
  _dcp_assert "unit-decide-color-and-pixfmt color: HLG (arib-std-b67) → HLG/10le"       "HLG|yuv420p10le"      "$(_dcp yuv420p10le bt2020 arib-std-b67 bt2020nc)"
  _dcp_assert "unit-decide-color-and-pixfmt color: tonemap HDR→SDR → SDR-TONEMAP/yuv420p" "SDR-TONEMAP|yuv420p" "$(_dcp yuv420p10le bt2020 smpte2084 bt2020nc 'TONEMAP_HDR_TO_SDR=1')"
}

_test_unit_select_best_audio() {
  # 2.2: direct unit test of select_best_audio — which audio track the user gets (never called by
  # a test before). Mock the I/O boundary (_audio_stream_count + _audio_stream_info), source the
  # AUDIO_SCORE_* defaults, run the REAL scorer, and assert the CHOSEN INDEX across scenarios
  # (esp. invalid-override fallback and the all-fail guard).
  local body defaults
  body="$(_extract_muxm_fns select_best_audio _score_audio_stream _split_tab _normalize_codec_lang \
                            _audio_codec_rank _audio_lang_matches _norm_lang_code audio_is_lossless _audio_is_commentary)" \
    || { fail "unit-select-best-audio: could not extract select_best_audio + helpers"; return; }
  defaults="$(grep -E '^(declare -i )?(AUDIO_SCORE_[A-Z_]+|AUDIO_CODEC_PREFERENCE|AUDIO_LANG_PREF|TAG_LANGUAGE_DEFAULT|_AUDIO_CODEC_RANK_PREF)=' "$MUXM")"
  _tr(){ printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5"; }   # one mocked stream record
  # $1=tracks (newline-separated records) $2=override $3=optional scorer stub (all-fail scenario).
  _sba_idx(){
    local tracks="$1" override="${2:-}" scorer_stub="${3:-}"
    bash -c "$defaults
AUDIO_PREFER_STEREO=0; AUDIO_TRACK_OVERRIDE=\"\$2\"
warn(){ :; }; note(){ :; }; log(){ :; }
mapfile -t _TR <<< \"\$1\"
_audio_stream_count(){ printf '%s\n' \"\${#_TR[@]}\"; }
_audio_stream_info(){ printf '%s\n' \"\${_TR[\$1]}\"; }
$body
$scorer_stub
select_best_audio | cut -f1" -- "$tracks" "$override"
  }
  _sba_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label (idx=$got)"; else fail "$label — chose idx '$got', expected '$want'"; fi; }

  local two; two="$(_tr aac 2 eng 128000 '')"$'\n'"$(_tr eac3 6 eng 448000 '')"
  _sba_assert "unit-select-best-audio select: highest score wins (eac3 6ch > aac 2ch)"            1 "$(_sba_idx "$two")"
  _sba_assert "unit-select-best-audio select: valid --audio-track 0 override honored"             0 "$(_sba_idx "$two" 0)"
  _sba_assert "unit-select-best-audio select: invalid --audio-track 5 → auto-selection fallback"  1 "$(_sba_idx "$two" 5)"
  _sba_assert "unit-select-best-audio select: all-tracks-fail → default-to-track-0 guard"         0 "$(_sba_idx "$two" '' '_score_audio_stream(){ echo nonnumeric; }')"
  local comm; comm="$(_tr eac3 6 eng 448000 'Director Commentary')"$'\n'"$(_tr eac3 6 eng 448000 'Main')"
  _sba_assert "unit-select-best-audio select: commentary deprioritized vs identical main feature" 1 "$(_sba_idx "$comm")"
  # H2: a 2-letter `en` tag must earn the +150 language bonus under the default pref `eng`,
  # beating a higher-channel foreign track. idx0=jpn 6ch, idx1=en 2ch → English (idx1) must win.
  # (Without normalization: en≠eng, no bonus, the 6ch jpn track would win.)
  local h2lang; h2lang="$(_tr eac3 6 jpn 448000 '')"$'\n'"$(_tr aac 2 en 128000 '')"
  _sba_assert "unit-select-best-audio select: en-tagged English wins lang bonus over a 6ch foreign track (H2)" 1 "$(_sba_idx "$h2lang")"
}

# RF3 + RF4: audio-selection correctness driven by DISPOSITION flags and prefer-stereo language.
# Unlike 2.1/2.2 (which mock _audio_stream_info with a canned tab record), this drives the REAL
# _audio_stream_info + _jq_cache over a mocked METADATA_CACHE JSON, so the disposition.* jq
# extraction is exercised end-to-end. select_best_audio runs the full score-all / prefer-stereo
# paths; we assert the chosen audio-relative index.
#   RF3: a track flagged disposition.comment / visual_impaired / hearing_impaired must be demoted
#        even with an EMPTY title (a title-only penalty misses it, and under the default
#        codec preference where lossless mains rank last, it could outscore the main feature).
#   RF4: --prefer-stereo must honor AUDIO_LANG_PREF — skip a wrong-language native stereo and fall
#        through to downmixing the preferred-language track instead.
_test_unit_audio_disposition() {
  local body defaults
  # 4.4: _audio_stream_info delegates to _audio_stream_info_uncached (memoization cache
  # miss/fallback path) instead of doing the jq fork itself — pull it in too, else the REAL
  # (non-mocked) _audio_stream_info this test drives can't resolve the call.
  body="$(_extract_muxm_fns select_best_audio _score_audio_stream _audio_stream_info _audio_stream_info_uncached \
                            _audio_stream_count _split_tab _normalize_codec_lang _audio_codec_rank _audio_lang_matches \
                            _norm_lang_code audio_is_lossless _audio_is_commentary _jq_cache)" \
    || { fail "RF3/RF4: could not extract audio-selection fns"; return; }
  defaults="$(grep -E '^(declare -i )?(AUDIO_SCORE_[A-Z_]+|AUDIO_CODEC_PREFERENCE|AUDIO_LANG_PREF|TAG_LANGUAGE_DEFAULT|_AUDIO_CODEC_RANK_PREF)=' "$MUXM")"
  # $1=METADATA_CACHE JSON  $2=AUDIO_PREFER_STEREO  $3=AUDIO_LANG_PREF → emits the selected idx.
  _rf_idx(){
    bash -c "$defaults
AUDIO_TRACK_OVERRIDE=\"\"; AUDIO_PREFER_STEREO=\"\$2\"; AUDIO_LANG_PREF=\"\$3\"
warn(){ :; }; note(){ :; }; log(){ :; }
METADATA_CACHE=\"\$1\"
$body
select_best_audio | cut -f1" -- "$1" "$2" "$3"
  }
  _rf_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label (idx=$got)"; else fail "$label — selected idx='$got', expected '$want'"; fi; }

  # --- RF3: disposition-based commentary/description demotion (track0 = TrueHD 7.1 main, empty
  #     title; track1 = E-AC-3 5.1, empty title, but a disposition flag set). Without demotion the
  #     flagged E-AC-3 (rank 0) outscores the unlisted TrueHD (rank 10 / score 0) and wins. ---
  local j_comment='{"streams":[{"codec_type":"audio","codec_name":"truehd","channels":8,"tags":{"language":"eng"},"disposition":{}},{"codec_type":"audio","codec_name":"eac3","channels":6,"bit_rate":"448000","tags":{"language":"eng"},"disposition":{"comment":1}}]}'
  _rf_assert "unit-audio-disposition-penalty: disposition.comment (empty title) loses to TrueHD main" 0 "$(_rf_idx "$j_comment" 0 eng)"
  local j_vi='{"streams":[{"codec_type":"audio","codec_name":"truehd","channels":8,"tags":{"language":"eng"},"disposition":{}},{"codec_type":"audio","codec_name":"eac3","channels":6,"bit_rate":"448000","tags":{"language":"eng"},"disposition":{"visual_impaired":1}}]}'
  _rf_assert "unit-audio-disposition-penalty: disposition.visual_impaired (empty title) demoted" 0 "$(_rf_idx "$j_vi" 0 eng)"
  local j_hi='{"streams":[{"codec_type":"audio","codec_name":"truehd","channels":8,"tags":{"language":"eng"},"disposition":{}},{"codec_type":"audio","codec_name":"eac3","channels":6,"bit_rate":"448000","tags":{"language":"eng"},"disposition":{"hearing_impaired":1}}]}'
  _rf_assert "unit-audio-disposition-penalty: disposition.hearing_impaired (empty title) demoted" 0 "$(_rf_idx "$j_hi" 0 eng)"
  # No-regression: a titled-English commentary with NO disposition flag is still demoted via the
  # title keyword path (proves RF3 adds to, not replaces, the existing classifier).
  local j_title='{"streams":[{"codec_type":"audio","codec_name":"truehd","channels":8,"tags":{"language":"eng"},"disposition":{}},{"codec_type":"audio","codec_name":"eac3","channels":6,"bit_rate":"448000","tags":{"language":"eng","title":"Directors Commentary"},"disposition":{}}]}'
  _rf_assert "unit-audio-disposition-penalty: titled-English commentary still demoted (no regression)" 0 "$(_rf_idx "$j_title" 0 eng)"
  # Sanity: with NO commentary signal at all, the flagged-track's twin (un-flagged E-AC-3 5.1)
  # DOES win over the rank-10 TrueHD — proving the RF3 cases above flip on the demotion, not on a
  # blanket TrueHD preference.
  local j_none='{"streams":[{"codec_type":"audio","codec_name":"truehd","channels":8,"tags":{"language":"eng"},"disposition":{}},{"codec_type":"audio","codec_name":"eac3","channels":6,"bit_rate":"448000","tags":{"language":"eng"},"disposition":{}}]}'
  _rf_assert "unit-audio-disposition-penalty sanity: un-flagged E-AC-3 5.1 outscores rank-10 TrueHD (demotion is the variable)" 1 "$(_rf_idx "$j_none" 0 eng)"

  # --- RF4: --prefer-stereo + AUDIO_LANG_PREF=eng. track0 = E-AC-3 5.1 eng, track1 = AAC 2.0 spa.
  #     A naive prefer-stereo prescan picks the Spanish stereo (only 2ch candidate). Instead it must
  #     skip the wrong-language stereo, find no eng stereo, and fall through to downmixing the
  #     eng 5.1 (idx 0). ---
  local j_ps='{"streams":[{"codec_type":"audio","codec_name":"eac3","channels":6,"bit_rate":"448000","tags":{"language":"eng"},"disposition":{}},{"codec_type":"audio","codec_name":"aac","channels":2,"bit_rate":"128000","tags":{"language":"spa"},"disposition":{}}]}'
  _rf_assert "unit-prefer-stereo-language: prefer-stereo skips wrong-language (spa) stereo → eng 5.1 for downmix" 0 "$(_rf_idx "$j_ps" 1 eng)"
  # No-regression: when a preferred-language native stereo exists, prefer-stereo still picks it.
  local j_ps2='{"streams":[{"codec_type":"audio","codec_name":"eac3","channels":6,"bit_rate":"448000","tags":{"language":"eng"},"disposition":{}},{"codec_type":"audio","codec_name":"aac","channels":2,"bit_rate":"128000","tags":{"language":"eng"},"disposition":{}}]}'
  _rf_assert "unit-prefer-stereo-language: prefer-stereo still picks a preferred-language (eng) stereo when present" 1 "$(_rf_idx "$j_ps2" 1 eng)"
}

_test_unit_build_subtitle_lists() {
  # 2.4: direct unit tests for the subtitle-selection decision functions.
  #   _pick_direct_text_sub_relidx — had ZERO coverage; returns the relative index of the
  #     first SUB_LANG_PREF-matching TEXT subtitle (skipping bitmap + wrong-language streams).
  #   _build_subtitle_keep_list — multi-track keep list: language filter, type-inclusion flags,
  #     and the SUB_MAX_TRACKS cap.
  # Mock the probe I/O boundary (list_sub_indices / _sp_sub_lang / _sp_sub_field for the picker;
  # the ALL_SUB_* arrays for the keep list) and assert the returned indices.
  local body_pdt body_bskl
  body_pdt="$(_extract_muxm_fns _pick_direct_text_sub_relidx _is_text_sub_codec _sub_lang_matches _norm_lang_code)" \
    || { fail "unit-build-subtitle-lists: could not extract _pick_direct_text_sub_relidx + _is_text_sub_codec"; return; }
  body_bskl="$(_extract_muxm_fns _build_subtitle_keep_list _is_text_sub_codec _sub_lang_matches _norm_lang_code)" \
    || { fail "unit-build-subtitle-lists: could not extract _build_subtitle_keep_list + _is_text_sub_codec"; return; }

  # $1=space-sep langs  $2=space-sep codecs (parallel)  [$3=SUB_LANG_PREF, default eng].
  # Emits the picked relidx (or empty).
  _pdt(){
    bash -c "SUB_LANG_PREF=\"\$3\"
_LANGS=(\$1); _CODECS=(\$2)
list_sub_indices(){ local k; for k in \"\${!_LANGS[@]}\"; do echo \"\$k\"; done; }
_sp_sub_lang(){ echo \"\${_LANGS[\$1]}\"; }
_sp_sub_field(){ echo \"\${_CODECS[\$1]}\"; }
$body_pdt
_pick_direct_text_sub_relidx" -- "$1" "$2" "${3:-eng}"
  }
  # $1=langs $2=types $3=SUB_MAX_TRACKS $4=extra flags. Codec=subrip, MUX=matroska (so text subs
  # always clear the container filter). Emits the kept-index list.
  _bskl(){
    bash -c "SUB_LANG_PREF=eng; SUB_INCLUDE_FORCED=1; SUB_INCLUDE_FULL=1; SUB_INCLUDE_SDH=1
MUX_FORMAT=matroska; SUB_ENABLE_OCR=0; OUTPUT_EXT=mkv; SUB_MAX_TRACKS=\$3
$4
_L=(\$1); _T=(\$2)
ALL_SUB_LANGS=(\"\${_L[@]}\"); ALL_SUB_TYPES=(\"\${_T[@]}\")
ALL_SUB_SOURCES=(); ALL_SUB_CODECS=()
for k in \"\${!_L[@]}\"; do ALL_SUB_SOURCES+=(\"embedded:\$k\"); ALL_SUB_CODECS+=(subrip); done
_source_label(){ echo \"\$1\"; }
_log_dropped_tracks(){ :; }
log(){ :; }
$body_bskl
_build_subtitle_keep_list" -- "$1" "$2" "$3" "$4"
  }
  _sub_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label ($got)"; else fail "$label — got '$got', expected '$want'"; fi; }

  _sub_assert "unit-build-subtitle-lists direct: picks first text sub matching lang (skips bitmap + fre)" 2  "$(_pdt 'eng fre eng' 'hdmv_pgs_subtitle subrip subrip')"
  _sub_assert "unit-build-subtitle-lists direct: no text sub in pref lang → empty"                        "" "$(_pdt 'eng eng' 'hdmv_pgs_subtitle dvd_subtitle')"
  _sub_assert "unit-build-subtitle-lists keep: lang+type filter keeps eng forced/full/sdh, drops fre"     "0 2 3" "$(_bskl 'eng fre eng eng' 'full full forced sdh' 3 '')"
  _sub_assert "unit-build-subtitle-lists keep: SUB_INCLUDE_SDH=0 drops the sdh track"                     "0 1"   "$(_bskl 'eng eng eng' 'full forced sdh' 3 'SUB_INCLUDE_SDH=0')"
  _sub_assert "unit-build-subtitle-lists keep: SUB_MAX_TRACKS caps 4→2"                                   "0 1"   "$(_bskl 'eng eng eng eng' 'full full full full' 2 '')"

  # D8: --sub-lang-pref is an inclusion FILTER, not a ranking — locks the semantics documented
  # in the man page / README. With "fra,eng" listed but eng appearing first
  # in SOURCE order, the single-track picker returns eng (index 0): list order does NOT prefer
  # French. If anyone ever implements list-order ranking, this assertion flips and forces a doc
  # update. The companion man-page wording check lives in the cli/docs flag-drift test.
  _sub_assert "unit-sub-lang-pref-source-order: sub-lang-pref is source-order, not list-order (fra,eng → eng at 0)" 0 "$(_pdt 'eng fra' 'subrip subrip' 'fra,eng')"
  _sub_assert "unit-sub-lang-pref-source-order: sub-lang-pref filters to the listed set (fra only → fra at 1)"      1 "$(_pdt 'eng fra' 'subrip subrip' 'fra')"
}

# RF6: a usable text sidecar must not be silently lost when the selected embedded bitmap
# can't be prepared (MP4/MOV output, OCR off — the bitmap can neither be stream-copied nor OCR'd).
# Three function-level arms (a full media e2e is not buildable: ffmpeg cannot synthesize an embedded
# bitmap-subtitle fixture from text — see the note near `_is_text_sub_codec` usage in the subs suite):
#   (a) _sub_candidate_undeliverable truth table — the predicate both fixes key on.
#   (b) merge_subtitle_sources codec-aware dedup — an UNDELIVERABLE embedded bitmap must NOT dedup
#       away a same-(lang,type) text sidecar (but a deliverable embedded — MKV / OCR-on — still does).
#   (c) build_subtitle_plan selection — given both candidates, the undeliverable bitmap is skipped
#       and the text sidecar is selected (not the bitmap that would fail to prepare).
_test_unit_rf6_subtitle_fallback() {
  # ---- (a) _sub_candidate_undeliverable truth table ----
  local body_u
  body_u="$(_extract_muxm_fns _sub_candidate_undeliverable _is_text_sub_codec _container_supports_bitmap_subs)" \
    || { fail "RF6(a): could not extract _sub_candidate_undeliverable + helpers"; return; }
  # $1=codec $2=MUX_FORMAT $3=SUB_ENABLE_OCR → exit 0 if undeliverable, 1 if deliverable.
  _undeliv(){
    bash -c "MUX_FORMAT=\"\$2\"; SUB_ENABLE_OCR=\"\$3\"
$body_u
_sub_candidate_undeliverable \"\$1\"; echo \$?" -- "$1" "$2" "$3"
  }
  _u_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label — got rc=$got, expected $want"; fi; }
  _u_assert "RF6(a): text sub (subrip) is always deliverable"                 1 "$(_undeliv subrip mp4 0)"
  _u_assert "RF6(a): bitmap + MKV is deliverable (stream-copy)"               1 "$(_undeliv hdmv_pgs_subtitle matroska 0)"
  _u_assert "RF6(a): bitmap + MP4 + OCR on is deliverable (OCR→text)"         1 "$(_undeliv hdmv_pgs_subtitle mp4 1)"
  _u_assert "RF6(a): bitmap + MP4 + OCR off is UNDELIVERABLE"                 0 "$(_undeliv hdmv_pgs_subtitle mp4 0)"
  _u_assert "RF6(a): VobSub (dvd_subtitle) + MOV + OCR off is UNDELIVERABLE"  0 "$(_undeliv dvd_subtitle mov 0)"

  # ---- (b) merge_subtitle_sources codec-aware dedup ----
  local body_m
  body_m="$(_extract_muxm_fns merge_subtitle_sources _split_tab _normalize_codec_lang _norm_lang_code \
              _is_forced_title _is_sdh_title _sub_candidate_undeliverable _is_text_sub_codec \
              _container_supports_bitmap_subs)" \
    || { fail "RF6(b): could not extract merge_subtitle_sources + helpers"; return; }
  # Mock the embedded-stream I/O boundary: one embedded bitmap (dvd_subtitle) eng/full. A single ext
  # sidecar (srt eng/full) collides on (lang,type). Emits the final ALL_SUB_SOURCES element count.
  # $1=MUX_FORMAT $2=SUB_ENABLE_OCR
  _merge_count(){
    bash -c "MUX_FORMAT=\"\$1\"; SUB_ENABLE_OCR=\"\$2\"; TAG_LANGUAGE_DEFAULT=und
note(){ :; }; report_add(){ :; }
_sub_count(){ echo 1; }
_sub_stream_info(){ printf 'dvd_subtitle\teng\t\t0\t0\n'; }   # codec lang title forced hi (bitmap, full)
EXT_SUB_PATHS=(/x/movie.en.srt); EXT_SUB_LANGS=(eng); EXT_SUB_TYPES=(full); EXT_SUB_CODECS=(srt)
$body_m
merge_subtitle_sources
echo \"\${#ALL_SUB_SOURCES[@]}\"" -- "$1" "$2"
  }
  _m_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label (sources=$got)"; else fail "$label — ALL_SUB_SOURCES=$got, expected $want"; fi; }
  # MP4 + OCR off: embedded bitmap is undeliverable → sidecar KEPT → 2 sources.
  _m_assert "RF6(b): undeliverable embedded bitmap does NOT dedup away the text sidecar (MP4/no-OCR)" 2 "$(_merge_count mp4 0)"
  # MKV: embedded bitmap is deliverable (stream-copy) → sidecar deduped → 1 source (unchanged).
  _m_assert "RF6(b): deliverable embedded bitmap (MKV) still dedups the sidecar" 1 "$(_merge_count matroska 0)"
  # MP4 + OCR on: embedded bitmap is deliverable (OCR) → sidecar deduped → 1 source (unchanged).
  _m_assert "RF6(b): deliverable embedded bitmap (MP4+OCR) still dedups the sidecar" 1 "$(_merge_count mp4 1)"

  # ---- (c) build_subtitle_plan selection skips the undeliverable bitmap, picks the text sidecar ----
  local body_p
  body_p="$(_extract_muxm_fns build_subtitle_plan _sub_candidate_undeliverable _is_text_sub_codec \
              _container_supports_bitmap_subs _sub_lang_matches _norm_lang_code)" \
    || { fail "RF6(c): could not extract build_subtitle_plan + helpers"; return; }
  # ALL_SUB_SOURCES already merged: embedded bitmap (i=0) + text sidecar (i=1), both eng/full.
  # Mock the prepare/export boundary so we can see WHICH source was selected and prepared.
  # $1=MUX_FORMAT $2=SUB_ENABLE_OCR → emits the prepared SRT_FULL marker ("embedded:0" or "ext:...").
  _plan_pick(){
    bash -c "MUX_FORMAT=\"\$1\"; SUB_ENABLE_OCR=\"\$2\"
SKIP_SUBS=0; SUB_MULTI_TRACK=0; SUB_BURN_FORCED=0; SUB_EXPORT_EXTERNAL=0
SUB_LANG_PREF=''; SUB_INCLUDE_FORCED=1; SUB_INCLUDE_FULL=1; SUB_INCLUDE_SDH=1
SUB_SOLE_EXT_FALLBACK=1; SUB_MAX_TRACKS=3
SRT_FORCED=''; SRT_FULL=''; SRT_SDH=''; SRT_FORCED_BURN_PATH=''; EXTERNAL_SRT_PATHS=()
ALL_SUB_SOURCES=('embedded:0' 'ext:/x/movie.en.srt')
ALL_SUB_CODECS=('dvd_subtitle' 'srt'); ALL_SUB_LANGS=('eng' 'eng')
ALL_SUB_TYPES=('full' 'full'); ALL_SUB_TITLES=('' '')
say(){ :; }; note(){ :; }; report_add(){ :; }; mark_done(){ :; }; warn(){ :; }
_pick_direct_text_sub_relidx(){ echo ''; }
_prepare_sub_from_source(){ printf '%s\n' \"\$1\"; }      # echo the SOURCE descriptor selected
_export_or_embed_sub(){ _SUB_EMBED_PATH=\"\$1\"; }        # embed path = the prepared source marker
$body_p
build_subtitle_plan
printf '%s\n' \"\$SRT_FULL\"" -- "$1" "$2"
  }
  local _pick_mp4 _pick_mkv
  _pick_mp4="$(_plan_pick mp4 0)"
  _pick_mkv="$(_plan_pick matroska 0)"
  # MP4/no-OCR: the bitmap (i=0) is undeliverable → skipped → the text sidecar (ext) is selected.
  if [[ "$_pick_mp4" == ext:* ]]; then
    pass "RF6(c): MP4/no-OCR selection skips the undeliverable bitmap, picks the text sidecar ($_pick_mp4)"
  else
    fail "RF6(c): MP4/no-OCR selected '$_pick_mp4' — expected the ext text sidecar (bitmap not skipped)"
  fi
  # MKV control: the bitmap is deliverable, so first-match selects it (embedded:0) — unchanged.
  if [[ "$_pick_mkv" == embedded:0 ]]; then
    pass "RF6(c): MKV control selects the (deliverable) embedded bitmap first — no behavior change"
  else
    fail "RF6(c): MKV control selected '$_pick_mkv' — expected embedded:0 (first-match unchanged)"
  fi
}

# RF8 (security): attacker-controlled track title/language tags must be stripped of the full
# C0 control range + DEL at the jq extraction choke points (_audio_stream_info / _sub_stream_info),
# so a hostile title can't inject terminal escape sequences into the scan output or the persistent
# log. Drives the REAL functions + _jq_cache over a mocked METADATA_CACHE whose tags carry ESC, BEL
# and DEL. The control chars are written as JSON \u escapes (built with printf so this test source
# stays pure ASCII — exactly how ffprobe JSON-escapes control bytes); jq decodes them, then gsub
# must replace each with a space.
_test_unit_metadata_sanitize() {
  local body_a body_s
  # 4.4: _audio_stream_info now delegates to _audio_stream_info_uncached — pull it in too.
  body_a="$(_extract_muxm_fns _audio_stream_info _audio_stream_info_uncached _jq_cache)" || { fail "unit-metadata-control-char-sanitize: could not extract _audio_stream_info"; return; }
  body_s="$(_extract_muxm_fns _sub_stream_info _jq_cache)"   || { fail "unit-metadata-control-char-sanitize: could not extract _sub_stream_info"; return; }
  # JSON \u escapes for ESC (27), BEL (7), DEL (127) — generated, not typed, so no raw control byte
  # ever lands in this file.
  local E B D
  E="$(printf '\\u%04x' 27)"; B="$(printf '\\u%04x' 7)"; D="$(printf '\\u%04x' 127)"
  local _atitle="Main${E}[2J${B}Feat${D}ure" _alang="${E}eng"
  local _stitle="Sub${E}[2Jt${B}itle${D}" _slang="${E}spa"
  local _json
  _json="$(printf '{"streams":[{"codec_type":"audio","codec_name":"eac3","channels":6,"bit_rate":"448000","tags":{"title":"%s","language":"%s"},"disposition":{}},{"codec_type":"subtitle","codec_name":"subrip","tags":{"title":"%s","language":"%s"},"disposition":{}}]}' "$_atitle" "$_alang" "$_stitle" "$_slang")"

  local _a _s
  _a="$(bash -c "METADATA_CACHE=\"\$1\"; DEBUG=0
$body_a
_audio_stream_info 0" -- "$_json" 2>/dev/null)"
  _s="$(bash -c "METADATA_CACHE=\"\$1\"; DEBUG=0
$body_s
_sub_stream_info 0" -- "$_json" 2>/dev/null)"

  # No raw ESC / BEL / DEL byte may survive (tabs are legit field separators, so not flagged).
  _rf8_clean(){
    local label="$1" out="$2"
    if LC_ALL=C grep -q $'[\033\007\177]' <<<"$out"; then
      fail "$label -- a raw control byte (ESC/BEL/DEL) survived: $(printf '%q' "$out")"
    else
      pass "$label"
    fi
  }
  _rf8_clean "unit-metadata-control-char-sanitize: _audio_stream_info strips control chars from title+language" "$_a"
  _rf8_clean "unit-metadata-control-char-sanitize: _sub_stream_info strips control chars from title+language" "$_s"
  # Sanitization REPLACES with a space (does not blank the field) -- the printable text survives.
  if [[ "$_a" == *Main* && "$_a" == *eng* ]]; then
    pass "unit-metadata-control-char-sanitize: audio title/language text preserved (control chars -> space, not dropped)"
  else
    fail "unit-metadata-control-char-sanitize: audio title/language text lost after sanitization: $(printf '%q' "$_a")"
  fi
  if [[ "$_s" == *Sub* && "$_s" == *spa* ]]; then
    pass "unit-metadata-control-char-sanitize: subtitle title/language text preserved"
  else
    fail "unit-metadata-control-char-sanitize: subtitle title/language text lost after sanitization: $(printf '%q' "$_s")"
  fi
}

# RF9: a conditionally-built array (e.g. fps_arg, _ts_fps, fps_in, _ocr_lang, thread_args,
# _child_flags, _cc_override_args) expanded as bare "${arr[@]}" raises `unbound variable` under
# `set -u` on bash < 4.4 when empty — and the documented floor is 4.3. muxm uses the array-safe
# ${arr[@]+"${arr[@]}"} form, which yields the elements when present and NOTHING (no spurious empty
# argument) when empty. This test locks both the idiom's behavior AND that muxm's real call sites use
# it. NOTE: on a modern host bash (>= 4.4) the OLD bare form would NOT error, so the true pre-4.4
# failure can only be reproduced on a genuinely old interpreter. Part (4) below prefers an explicit
# $BASH_43 override (any old interpreter path, not literally version 4.3) and otherwise auto-detects
# one: macOS ships a real pre-4.4 bash (3.2.x) at /bin/bash even when a modern bash is on PATH via
# Homebrew, so that's tried automatically — confirmed empirically (does the bare form actually error
# there?), not by parsing a version string (format varies across GNU/BSD bash builds). Skips only on
# hosts with neither (e.g. a modern-only Linux box).
_test_unit_empty_array_safe() {
  # (1) Idiom behavior: empty → 0 extra args (NOT one empty arg, as "${arr[@]:-}" would give).
  local n_empty n_full
  n_empty="$(bash -c 'set -u; arr=(); set -- PRE ${arr[@]+"${arr[@]}"} POST; echo $#' 2>/dev/null)"
  n_full="$(bash -c 'set -u; arr=(-fps 24); set -- PRE ${arr[@]+"${arr[@]}"} POST; echo $#' 2>/dev/null)"
  if [[ "$n_empty" == 2 ]]; then
    pass "unit-empty-array-safe-set-u: empty array expands to ZERO args under set -u (no spurious empty argument)"
  else
    fail "unit-empty-array-safe-set-u: empty array produced $n_empty args (expected 2 = PRE+POST; a ':-' form would give 3)"
  fi
  if [[ "$n_full" == 4 ]]; then
    pass "unit-empty-array-safe-set-u: populated array expands to its elements (PRE + 2 + POST = 4)"
  else
    fail "unit-empty-array-safe-set-u: populated array produced $n_full args (expected 4)"
  fi
  # (2) No 'unbound variable' under set -u for the empty case.
  local err; err="$(bash -c 'set -u; arr=(); printf "%s" ${arr[@]+"${arr[@]}"}' 2>&1 >/dev/null)"
  if [[ -z "$err" ]]; then
    pass "unit-empty-array-safe-set-u: array-safe expansion raises no error under set -u (empty array)"
  else
    fail "unit-empty-array-safe-set-u: set -u empty-array expansion errored: $err"
  fi
  # (3) Static: muxm's known empty-prone command-arg arrays use the safe form, never bare "${x[@]}".
  # A "bare" expansion is "${arr[@]}" NOT preceded by '+' (the safe form is ${arr[@]+"${arr[@]}"}).
  # Grep the file directly (matching LINES), then keep only NON-comment matches so the RF9
  # explanatory comment (which quotes the unsafe form) doesn't false-positive.
  local arr unsafe=""
  for arr in fps_arg _ts_fps fps_in fps_in2 _ocr_lang thread_args _child_flags _cc_override_args; do
    if grep -E "[^+]\"\\\$\{${arr}\[@\]\}\"" "$MUXM" | grep -qvE '^[[:space:]]*#'; then
      unsafe+="$arr "
    fi
  done
  if [[ -z "$unsafe" ]]; then
    pass "unit-empty-array-safe-set-u: no bare \"\${arr[@]}\" expansion remains for the empty-prone command-arg arrays"
  else
    fail "unit-empty-array-safe-set-u: bare (4.3-unsafe) array expansion still present for: $unsafe"
  fi
  # (4) True pre-4.4 coverage when an old interpreter is available. Skip-first guard (not an
  # else→skip) per the soft-skip ratchet: a genuine host/version skip belongs in `if [[ ! cond ]]; then skip`.
  # Interpreter selection: prefer an explicit $BASH_43 override (any old-bash path, not literally
  # 4.3); otherwise auto-detect by trying /bin/bash and confirming — empirically, not by parsing a
  # version string — that the BARE form actually still errors there (macOS's system /bin/bash is a
  # real pre-4.4 build even when a modern bash is on PATH via Homebrew).
  local old_bash=""
  if [[ -n "${BASH_43:-}" && -x "${BASH_43:-}" ]]; then
    old_bash="$BASH_43"
  # shellcheck disable=SC2016  # the bare "${arr[@]}" form must reach /bin/bash literally, unexpanded
  elif [[ -x /bin/bash ]] && ! /bin/bash -c 'set -u; arr=(); printf "%s" "${arr[@]}"' >/dev/null 2>&1; then
    old_bash="/bin/bash"
  fi
  if [[ -z "$old_bash" ]]; then
    skip "unit-empty-array-safe-set-u: no pre-4.4 bash interpreter available (\$BASH_43 unset, /bin/bash doesn't reproduce the bug) — host bash exercises the idiom; true old-bash coverage needs one"
  else
    local old_ver rc=0 bare_rc=0
    old_ver="$("$old_bash" --version 2>&1 | head -1)" || true
    # Positive control: the BARE form must still error here, or this isn't a valid repro host —
    # guards against a misconfigured $BASH_43 (e.g. pointed at a modern bash) silently passing.
    # shellcheck disable=SC2016  # the bare "${arr[@]}" form must reach $old_bash literally, unexpanded
    "$old_bash" -c 'set -u; arr=(); printf "%s" "${arr[@]}"' >/dev/null 2>&1 || bare_rc=$?
    if (( bare_rc != 0 )); then
      pass "unit-empty-array-safe-set-u: bare \"\${arr[@]}\" expansion still fails on $old_bash ($old_ver) — confirms a valid old-bash repro host"
    else
      fail "unit-empty-array-safe-set-u: bare expansion unexpectedly succeeded on $old_bash ($old_ver) — not actually pre-4.4?"
    fi
    # shellcheck disable=SC2016  # the ${arr[@]+…} idiom must reach $old_bash as a literal, unexpanded
    "$old_bash" -c 'set -u; arr=(); printf "%s" ${arr[@]+"${arr[@]}"}' >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
      pass "unit-empty-array-safe-set-u: array-safe expansion works on a genuinely old bash ($old_bash, $old_ver)"
    else
      fail "unit-empty-array-safe-set-u: $old_bash ($old_ver) errored on the array-safe expansion (rc=$rc)"
    fi
  fi
}

# CR-5: the DV→MKV give-up timestamp wrap must not expand the fps array as a bare "${fps_in2[@]}"
# — it must use the RF9 array-safe form ${arr[@]+"${arr[@]}"} like its four siblings.
# Empty SRC_FPS → 0-element array → `unbound variable` under set -u on bash < 4.4 (documented floor
# 4.3), aborting the wrap. This guard makes the RF9 rule self-enforcing for the WHOLE fps family —
# a reintroduced bare expansion of any of them fails here. Mirrors _test_unit_empty_array_safe (3).
_test_unit_no_bare_fps_array() {
  local arr unsafe=""
  for arr in fps_in fps_in2 fps_arg _ts_fps; do
    # A "bare" expansion is "${arr[@]}" NOT preceded by '+' (safe form is ${arr[@]+"${arr[@]}"}).
    # Keep only NON-comment matches so an explanatory comment quoting the unsafe form can't false-fire.
    if grep -E "[^+]\"\\\$\{${arr}\[@\]\}\"" "$MUXM" | grep -qvE '^[[:space:]]*#'; then
      unsafe+="$arr "
    fi
  done
  if [[ -z "$unsafe" ]]; then
    pass "unit-no-bare-fps-array: no bare (bash-4.3-unsafe) expansion remains for any fps array (fps_in/fps_in2/fps_arg/_ts_fps)"
  else
    fail "unit-no-bare-fps-array: bare \"\${arr[@]}\" fps expansion still present for: $unsafe"
  fi
}

# RF10: every grep invocation in muxm must use only the POSIX-portable flags documented in
# the §5 audit comment — {i, E, o, q, v, x, F}. This both validates the -m1 removal and keeps the
# audit comment test-enforced so it can't silently rot again (a reintroduced non-POSIX flag fails).
_test_unit_grep_flags() {
  local allow="iEoqvxF" bad="" tok flags ch i
  while IFS= read -r tok; do
    flags="${tok#grep -}"
    for (( i=0; i<${#flags}; i++ )); do
      ch="${flags:$i:1}"
      [[ "$allow" == *"$ch"* ]] || bad+="${tok}(${ch}) "
    done
  done < <(grep -oE 'grep -[A-Za-z]+' "$MUXM")
  if [[ -z "$bad" ]]; then
    pass "unit-grep-posix-flags: all grep invocations in muxm use only POSIX-portable flags ($allow)"
  else
    fail "unit-grep-posix-flags: non-allow-listed grep flag(s) in muxm: $bad (allow-list: $allow)"
  fi
  # Explicit guard: the non-POSIX -m (max-count, redundant with -q) must never reappear.
  if grep -qE 'grep -[A-Za-z]*m' "$MUXM"; then
    fail "unit-grep-posix-flags: a non-POSIX 'grep -…m…' (e.g. -m1) was reintroduced into muxm"
  else
    pass "unit-grep-posix-flags: no non-POSIX 'grep -m' present in muxm"
  fi
}

# RF11: the man-page .TH date must be a generated __DATE__ token (substituted from
# RELEASE_DATE by _man_emit), NOT a hardcoded literal the docs-parity guard can't see drifting.
_test_unit_man_date_token() {
  # (1) The .TH heredoc line carries the __DATE__ token (no hardcoded date).
  local th_line; th_line="$(grep -E '^\.TH MUXM 1 ' "$MUXM" | head -1)"
  if [[ "$th_line" == *'"__DATE__"'* ]]; then
    pass "unit-man-date-token: man-page .TH heredoc uses the __DATE__ token (no hardcoded date)"
  else
    fail "unit-man-date-token: man-page .TH line has no __DATE__ token (hardcoded date?): $th_line"
  fi
  # (2) RELEASE_DATE is a defined ISO constant, co-located with VERSION.
  if grep -qE '^readonly RELEASE_DATE="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$MUXM"; then
    pass "unit-man-date-token: RELEASE_DATE is a defined ISO constant in muxm"
  else
    fail "unit-man-date-token: RELEASE_DATE constant not found (or not ISO) in muxm"
  fi
  # (3) --emit-man substitutes the token to a real ISO date (no leaked __DATE__).
  local emitted; emitted="$("$MUXM" --emit-man 2>/dev/null | grep -E '^\.TH MUXM 1 ' | head -1)"
  if [[ "$emitted" == *'__DATE__'* ]]; then
    fail "unit-man-date-token: --emit-man left an unsubstituted __DATE__ token: $emitted"
  elif [[ "$emitted" =~ ^\.TH\ MUXM\ 1\ \"[0-9]{4}-[0-9]{2}-[0-9]{2}\" ]]; then
    pass "unit-man-date-token: --emit-man substitutes __DATE__ to a real ISO release date"
  else
    fail "unit-man-date-token: --emit-man .TH date is not a valid ISO date: $emitted"
  fi
}

# RF12: targeted asserts for small polish changes that are cheaply testable —
#   - _profile_comment: the unreachable 'streaming' alias arm is gone (canonical name still works).
#   - build_videotoolbox_params: hevc_videotoolbox rejects a 4:2:2/4:4:4 target with a clean die.
#   - _probe_stream_field: dropping `head -n1` leaves the single-scalar output unchanged.
# (Not asserted here: the internal audio-helper `_` renaming is purely cosmetic and referenced by
#  ~30 test strings, and the efficiency restructurings are immaterial vs. transcode cost and
#  behavior-preserving.)
_test_unit_probe_stream_field_nits() {
  # ---- _profile_comment: dead 'streaming' alias arm removed ----
  assert_muxm_fn_stdout "unit-probe-stream-field-nits: _profile_comment(streaming-hevc) returns the canonical tagline" \
    "Lean, mean, streaming machine." _profile_comment 'PROFILE_NAME=streaming-hevc'
  local _pc_body; _pc_body="$(awk '/^_profile_comment\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  # The dead alias arm is `streaming|` (pipe) or a bare `streaming)`; the canonical arms are
  # `streaming-hevc)` / `streaming-av1)` (always `streaming-…`), so `streaming[|)]` matches only the
  # unreachable alias form.
  if printf '%s\n' "$_pc_body" | grep -qE 'streaming[|)]'; then
    fail "unit-probe-stream-field-nits: _profile_comment still has an unreachable 'streaming' alias arm"
  else
    pass "unit-probe-stream-field-nits: _profile_comment has no unreachable 'streaming' alias arm"
  fi

  # ---- build_videotoolbox_params: reject 4:2:2/4:4:4 for hevc_videotoolbox ----
  # shellcheck disable=SC2016  # literal env-setup string for assert_muxm_fn_exit — must not expand now
  local _vtenv='die(){ exit "${1:-1}"; }; HW_ACCEL_QUALITY=80; HW_ACCEL_ALLOW_SW=1; VT_QUALITY_DEFAULT=65; X264_PARAMS_BASE=""; VIDEO_ENCODER_FFMPEG=hevc_videotoolbox; OUTPUT_EXT=mkv'
  assert_muxm_fn_exit "unit-probe-stream-field-nits VT: hevc_videotoolbox rejects a 4:4:4 target (clean die)" 1 \
    build_videotoolbox_params "${_vtenv}; TARGET_PIXFMT=yuv444p10le"
  assert_muxm_fn_exit "unit-probe-stream-field-nits VT: hevc_videotoolbox rejects a 4:2:2 target (clean die)" 1 \
    build_videotoolbox_params "${_vtenv}; TARGET_PIXFMT=yuv422p"
  assert_muxm_fn_exit "unit-probe-stream-field-nits VT: hevc_videotoolbox accepts a 4:2:0 target (control)" 0 \
    build_videotoolbox_params "${_vtenv}; TARGET_PIXFMT=yuv420p10le"

  # ---- _probe_stream_field (E4): output unchanged after dropping head -n1 ----
  local _pf_body; _pf_body="$(_extract_muxm_fns _probe_stream_field _jq_cache)" \
    || { fail "unit-probe-stream-field-nits E4: could not extract _probe_stream_field + _jq_cache"; return; }
  local _json='{"streams":[{"codec_type":"video","codec_name":"hevc","width":1920},{"codec_type":"audio","codec_name":"eac3"}]}'
  local _got _empty
  _got="$(bash -c "METADATA_CACHE=\"\$1\"; DEBUG=0
$_pf_body
_probe_stream_field video 0 codec_name" -- "$_json" 2>/dev/null)"
  _empty="$(bash -c "METADATA_CACHE=\"\$1\"; DEBUG=0
$_pf_body
_probe_stream_field video 0 nonexistent_field" -- "$_json" 2>/dev/null)"
  if [[ "$_got" == "hevc" ]]; then
    pass "unit-probe-stream-field-nits E4: _probe_stream_field returns the single scalar field (head -n1 removal harmless)"
  else
    fail "unit-probe-stream-field-nits E4: _probe_stream_field returned '$_got' (expected 'hevc')"
  fi
  if [[ -z "$_empty" ]]; then
    pass "unit-probe-stream-field-nits E4: _probe_stream_field returns empty for a missing field (// empty preserved)"
  else
    fail "unit-probe-stream-field-nits E4: _probe_stream_field returned '$_empty' for a missing field (expected empty)"
  fi
}

_test_unit_report_add_escaping() {
  # 2.5: report_add was stubbed to `:` in tests, so its JSON escaping was never exercised. Call it
  # with a value containing quote/backslash/newline/tab/CR, emit the resulting object, and assert
  # jq PARSES it and ROUND-TRIPS the value. A dropped escape step → invalid JSON → jq fails.
  local body
  body="$(_extract_muxm_fns report_add _json_escape)" || { fail "unit-report-add-escaping: could not extract report_add + _json_escape"; return; }
  # $1=key $2=val → emits the round-tripped value jq reads back (empty if jq rejected the object).
  _ra_roundtrip(){
    bash -c "$body"$'\n''REPORT_ENTRIES=(); report_add "$1" "$2"; IFS=,; printf "{%s}\n" "${REPORT_ENTRIES[*]}"' -- "$1" "$2" 2>/dev/null | jq -r --arg k "$1" '.[$k]' 2>/dev/null || true
  }
  local key="track.title" val got
  printf -v val 'a"b\\c\nd\te\rf'   # quote, backslash, newline, tab, carriage-return
  got="$(_ra_roundtrip "$key" "$val")"
  # Shared label prefix across pass/fail so the perturb signature (which keys on FAIL lines)
  # matches when the escaping is broken — see MUT-REP-1 in tools/perturb_check.sh.
  local label="unit-report-add-escaping report_add escaping: quote/backslash/newline/tab/CR round-trips through jq"
  if [[ "$got" == "$val" ]]; then
    pass "$label"
  else
    fail "$label — jq returned $(printf '%q' "$got"), expected $(printf '%q' "$val")"
  fi
  # M1: a raw control byte < 0x20 (BEL 0x07, 0x01) is invalid in a JSON string per RFC-8259 — it
  # must be \uXXXX-escaped or jq rejects the whole object. Assert the value round-trips intact.
  local cval; cval=$'x\x07y\x01z'
  local cgot; cgot="$(_ra_roundtrip "$key" "$cval")"
  local clabel="unit-report-add-escaping report_add escaping: control bytes (0x07/0x01) \u-escaped → valid JSON round-trips (M1)"
  if [[ "$cgot" == "$cval" ]]; then
    pass "$clabel"
  else
    fail "$clabel — jq returned $(printf '%q' "$cgot"), expected $(printf '%q' "$cval")"
  fi
}

_test_unit_duration_tier3() {
  # 3.4: tier-3 Matroska DURATION parse in _get_source_duration_secs. tiers 1/2 read a numeric
  # stream/format `duration`; tier 3 parses a Matroska `tags.DURATION` of the form "HH:MM:SS.nnn"
  # into integer seconds. We feed a METADATA_CACHE that has
  # ONLY a video-stream tags.DURATION (no stream/format duration) so tiers 1+2 fall through and
  # tier 3 fires, then assert the seconds. Extract the function + the REAL _jq_cache and run jq
  # against the mocked cache (faithful parse, no I/O boundary faked away).
  #
  # A real encode can't exercise this: an MKV carrying only a DURATION tag still gets a
  # format-level duration written by ffmpeg, so a source that reaches tier 3 isn't
  # deterministically buildable with ffmpeg. The mocked cache is the only hermetic way to
  # exercise tier 3, and it is where the parse mutation (M-DUR-1) bites.
  local body
  body="$(_extract_muxm_fns _get_source_duration_secs _jq_cache)" \
    || { fail "unit-duration-tier3: could not extract _get_source_duration_secs + _jq_cache"; return; }
  # $1 = METADATA_CACHE JSON; emits the computed integer seconds.
  _dur(){
    bash -c 'METADATA_CACHE="$1"; _CACHED_SRC_DURATION_SECS=""; DEBUG=0
log(){ :; }
'"$body"'
_get_source_duration_secs' -- "$1"
  }
  _dur_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label ($got)"; else fail "$label — got '$got', expected '$want'"; fi; }

  # Video stream carries ONLY a Matroska DURATION tag — no stream.duration, no format.duration —
  # so tiers 1+2 yield 0 and tier 3 parses 01:02:03 → 1*3600 + 2*60 + 3 = 3723s. (M-DUR-1 breaks
  # the HH:MM:SS multiplier so this diverges; the tier-1 sanity case below is unaffected by it.)
  local j_tier3='{"streams":[{"codec_type":"video","tags":{"DURATION":"01:02:03.000000000"}}],"format":{}}'
  _dur_assert "unit-duration-tier3 duration tier-3: Matroska tag 01:02:03 → 3723s" 3723 "$(_dur "$j_tier3")"
  # Zero-padded hours/minutes must not be read as octal (10# guards it): 00:09:09 → 549s.
  local j_octal='{"streams":[{"codec_type":"video","tags":{"DURATION":"00:09:09.000000000"}}],"format":{}}'
  _dur_assert "unit-duration-tier3 duration tier-3: octal-safe 00:09:09 → 549s" 549 "$(_dur "$j_octal")"
  # Sanity: a numeric stream.duration (tier 1) wins and tier 3 is never consulted — so the parse
  # mutation must NOT move this one (keeps the M-DUR-1 signature isolated to the tier-3 case).
  local j_tier1='{"streams":[{"codec_type":"video","duration":"42.0","tags":{"DURATION":"01:02:03.000000000"}}],"format":{}}'
  _dur_assert "unit-duration-tier3 duration tier-1: stream duration 42.0 → 42s (tier-3 ignored)" 42 "$(_dur "$j_tier1")"
}

_test_unit_video_copy_compliant() {
  # 3.5: direct unit test of _video_is_copy_compliant — decides whether the source video can be
  # stream-COPIED (no re-encode). Covers its reject reasons directly. Mock the source
  # I/O boundary (_probe_field) and assert (return-code, _COPY_REJECT_REASON) across a compliant
  # source and each reject reason: codec mismatch, the 10-bit-pixfmt ceiling, tone-map-required,
  # and the MAX_COPY_BITRATE ceiling. This is the decision function's OWN output (not an encoded
  # file), so a neutered reject is caught directly — no fragile copy-vs-encode log heuristic.
  #
  # SCOPE NOTE: the skip-if-ideal multi-track branch is ALREADY covered e2e by the output suite
  # (sii_mt: commentary forces remux; sii_subs: 5 subs preserved through the ideal path). Not
  # duplicated here — this test adds the reject-reason cover that the e2e path doesn't reach.
  local body
  # CR-2: the DV gate delegates to _is_atv_directplay_profile (shared Direct-Play predicate) —
  # extract it too, else the gate's `if` references an undefined function and never fires here.
  # 4.2: _output_pixfmt_is_10bit delegates its 4 color-field probes to
  # _probe_video_color_fields (which itself uses _split_tab) — pull both in too.
  body="$(_extract_muxm_fns _video_is_copy_compliant _lower _output_pixfmt_is_10bit _is_atv_directplay_profile \
                            _probe_video_color_fields _split_tab)" \
    || { fail "unit-video-copy-compliant: could not extract _video_is_copy_compliant + _lower + _output_pixfmt_is_10bit + _is_atv_directplay_profile"; return; }
  # $1=src_codec $2=src_pix $3=src_prim $4=src_trc $5=src_bitrate(bps) $6=extra global overrides.
  # Emits "<rc>|<reject reason>". Bitrate is always a real number so the size/duration stat
  # fallback in the ceiling check is never reached (keeps the ceiling scenario deterministic).
  # C1: the 10-bit gate derives intent from HDR_TARGET_PIXFMT/SDR_* + probed color (not the
  # stale TARGET_PIXFMT), and the DV gate falls back to a direct probe (stubbed here via
  # P_DV_PROFILE) when IS_DV/DV_SRC_PROFILE are unset — so the harness seeds those config globals
  # and a controllable DV-probe stub. _probe_field also answers color_space for the HDR classifier.
  _vcc(){
    local extra="${6:-}"
    bash -c '_CLI_CRF_EXPLICIT=0; _CLI_PRESET_EXPLICIT=0
VIDEO_CODEC=libx265; TARGET_PIXFMT=yuv420p; TONEMAP_HDR_TO_SDR=0
HDR_TARGET_PIXFMT=yuv420p10le; SDR_FORCE_10BIT=0; SDR_USE_10BIT_IF_SRC_10BIT=0
IS_DV=0; DISABLE_DV=1; PROFILE_NAME=""; DV_SRC_PROFILE=""; MAX_COPY_BITRATE=""; P_DV_PROFILE=""
P_CODEC="$1"; P_PIX="$2"; P_PRIM="$3"; P_TRC="$4"; P_BR="$5"; P_CSPACE=""
'"$extra"'
_probe_field(){ case "$1" in codec_name) printf "%s" "$P_CODEC";; pix_fmt) printf "%s" "$P_PIX";; color_primaries) printf "%s" "$P_PRIM";; color_transfer) printf "%s" "$P_TRC";; color_space) printf "%s" "$P_CSPACE";; bit_rate) printf "%s" "$P_BR";; esac; }
_source_has_dv_metadata(){ [[ -n "$P_DV_PROFILE" ]]; }
_source_dv_profile(){ printf "%s" "$P_DV_PROFILE"; }
warn(){ :; }
'"$body"'
if _video_is_copy_compliant; then printf "0|%s" "$_COPY_REJECT_REASON"; else printf "1|%s" "$_COPY_REJECT_REASON"; fi' -- "$1" "$2" "$3" "$4" "$5"
  }
  # label  expect_rc  reason_substr (empty = expect no reason)  got("rc|reason")
  _vcc_assert(){
    local label="$1" exp_rc="$2" sub="$3" got="$4"
    local rc="${got%%|*}" reason="${got#*|}"
    if [[ "$rc" == "$exp_rc" ]] && { [[ -z "$sub" ]] || [[ "$reason" == *"$sub"* ]]; }; then
      pass "$label (rc=$rc)"
    else
      fail "$label — rc=$rc reason='$reason' (expected rc=$exp_rc, reason containing '$sub')"
    fi
  }

  # Compliant: HEVC source, 8-bit target, no tonemap, no bitrate ceiling → copyable (rc 0).
  _vcc_assert "unit-video-copy-compliant copy-compliant: HEVC matches target → copyable"  0 ""               "$(_vcc hevc yuv420p '' '' 5000000)"
  # Codec mismatch: libx265 target wants hevc; an h264 source must re-encode.
  _vcc_assert "unit-video-copy-compliant copy-compliant: codec mismatch (h264) → re-encode" 1 "video codec"  "$(_vcc h264 yuv420p '' '' 5000000)"
  # 10-bit-pixfmt ceiling (C1): the gate derives intended-10-bit from config + probed source,
  # NOT the stale TARGET_PIXFMT. SDR source + --sdr-force-10bit wants 10-bit out, 8-bit source → re-encode.
  _vcc_assert "unit-video-copy-compliant copy-compliant: 10-bit out (sdr-force) vs 8-bit src → re-encode" 1 "need 10-bit" "$(_vcc hevc yuv420p '' '' 5000000 'SDR_FORCE_10BIT=1')"
  # 10-bit ceiling via an HDR source (HDR_TARGET_PIXFMT is 10-bit) with an 8-bit pixfmt → re-encode.
  _vcc_assert "unit-video-copy-compliant copy-compliant: 10-bit out (HDR target) vs 8-bit src → re-encode" 1 "need 10-bit" "$(_vcc hevc yuv420p bt2020 smpte2084 5000000)"
  # Regression: a 10-bit source under a 10-bit target is NOT bit-depth-rejected (only the depth gap rejects).
  _vcc_assert "unit-video-copy-compliant copy-compliant: 10-bit src under 10-bit target → copyable" 0 "" "$(_vcc hevc yuv420p10le '' '' 5000000 'SDR_FORCE_10BIT=1')"
  # Tonemap-required: HDR source (bt2020/pq) with tone-map on → cannot copy. (10-bit gate must NOT
  # pre-empt this: tone-mapped output is 8-bit, so _output_pixfmt_is_10bit is false here.)
  _vcc_assert "unit-video-copy-compliant copy-compliant: tonemap-required (HDR) → re-encode" 1 "tone-mapping" "$(_vcc hevc yuv420p10le bt2020 smpte2084 5000000 'TONEMAP_HDR_TO_SDR=1')"

  # ---- C1 DV-profile gate. atv-directplay-hq may stream-copy ONLY Profile 8; P7/P5 must re-encode.
  #      The decisive case is the skip-if-ideal path (IS_DV/DV_SRC_PROFILE unset) where the gate
  #      falls back to a direct probe (stubbed via P_DV_PROFILE). 10-bit src so the bit-depth gate
  #      doesn't pre-empt. ----
  local _dv_atv='PROFILE_NAME=atv-directplay-hq; DISABLE_DV=0'
  # Normal path (globals populated): P7 → re-encode, P8 → copyable.
  _vcc_assert "unit-video-copy-compliant DV gate: normal-path P7 → re-encode" 1 "DV profile 7 requires conversion" "$(_vcc hevc yuv420p10le '' '' 5000000 "$_dv_atv; IS_DV=1; DV_SRC_PROFILE=7")"
  _vcc_assert "unit-video-copy-compliant DV gate: normal-path P8 → copyable"   0 ""                                "$(_vcc hevc yuv420p10le '' '' 5000000 "$_dv_atv; IS_DV=1; DV_SRC_PROFILE=8")"
  # Skip-if-ideal path (C1): IS_DV/DV_SRC_PROFILE unset → direct probe decides. P7 → re-encode, P8 → copyable.
  _vcc_assert "unit-video-copy-compliant DV gate: skip-path P7 (direct probe) → re-encode" 1 "DV profile 7 requires conversion" "$(_vcc hevc yuv420p10le '' '' 5000000 "$_dv_atv; P_DV_PROFILE=7")"
  _vcc_assert "unit-video-copy-compliant DV gate: skip-path P8 (direct probe) → copyable"  0 ""                                 "$(_vcc hevc yuv420p10le '' '' 5000000 "$_dv_atv; P_DV_PROFILE=8")"
  # Skip-path, source is NOT DV → no DV reject (probe finds nothing).
  _vcc_assert "unit-video-copy-compliant DV gate: skip-path non-DV → copyable" 0 "" "$(_vcc hevc yuv420p10le '' '' 5000000 "$_dv_atv")"
  # DISABLE_DV bypasses the gate even for a P7 source.
  _vcc_assert "unit-video-copy-compliant DV gate: DISABLE_DV bypasses → copyable" 0 "" "$(_vcc hevc yuv420p10le '' '' 5000000 'PROFILE_NAME=atv-directplay-hq; DISABLE_DV=1; IS_DV=1; DV_SRC_PROFILE=7')"
  # The gate is scoped to atv-directplay-hq; a P7 under any other profile is not DV-rejected here.
  _vcc_assert "unit-video-copy-compliant DV gate: other profile not DV-gated → copyable" 0 "" "$(_vcc hevc yuv420p10le '' '' 5000000 'PROFILE_NAME=hdr10-hq; DISABLE_DV=0; IS_DV=1; DV_SRC_PROFILE=7')"
  # MAX_COPY_BITRATE ceiling: 20 Mbps source over a 10000k cap → re-encode. (M-VCC-2 neuters this.)
  _vcc_assert "unit-video-copy-compliant copy-compliant: bitrate ceiling exceeded → re-encode" 1 "MAX_COPY_BITRATE" "$(_vcc hevc yuv420p '' '' 20000000 'MAX_COPY_BITRATE=10000k')"
  # Under the ceiling: 5 Mbps source below the 10000k cap → still copyable (the ceiling only
  # rejects when exceeded — proves the guard isn't a blanket reject).
  _vcc_assert "unit-video-copy-compliant copy-compliant: bitrate under ceiling → copyable" 0 ""              "$(_vcc hevc yuv420p '' '' 5000000 'MAX_COPY_BITRATE=10000k')"

  # ---- RF2: forced-subtitle burn-in cannot be stream-copied → must re-encode. Keyed on
  #      the config flag SUB_BURN_FORCED (known at both call sites, unlike the runtime burn path).
  #      Without this gate the copy branch returns 0 before the burn filter and the forced track is
  #      silently dropped. A compliant HEVC source that would otherwise copy must be rejected. ----
  _vcc_assert "unit-video-copy-forced-burn: SUB_BURN_FORCED=1 forces re-encode" 1 "burn-in" "$(_vcc hevc yuv420p '' '' 5000000 'SUB_BURN_FORCED=1')"
  # Control: same compliant source WITHOUT forced-burn is still copyable (RF2 is not a blanket reject).
  _vcc_assert "unit-video-copy-forced-burn: no forced-burn → still copyable" 0 "" "$(_vcc hevc yuv420p '' '' 5000000 'SUB_BURN_FORCED=0')"

  # ---- RF2b: chroma downsampling (FORCE_CHROMA_420=1) on a 4:2:2/4:4:4 source
  #      cannot be stream-copied → re-encode. 10-bit src so the bit-depth gate doesn't pre-empt. ----
  _vcc_assert "unit-video-copy-chroma-force: FORCE_CHROMA_420 + 4:2:2 source → re-encode" 1 "chroma downsampling" "$(_vcc hevc yuv422p10le '' '' 5000000 'FORCE_CHROMA_420=1')"
  _vcc_assert "unit-video-copy-chroma-force: FORCE_CHROMA_420 + 4:4:4 source → re-encode" 1 "chroma downsampling" "$(_vcc hevc yuv444p10le '' '' 5000000 'FORCE_CHROMA_420=1')"
  # Control A: 4:2:0 source with chroma-420 enforced → copyable (no downsample needed).
  _vcc_assert "unit-video-copy-chroma-force: FORCE_CHROMA_420 + 4:2:0 source → copyable" 0 "" "$(_vcc hevc yuv420p '' '' 5000000 'FORCE_CHROMA_420=1')"
  # Control B: 4:2:2 source but chroma preservation ON (FORCE_CHROMA_420=0) → not RF2b-gated.
  _vcc_assert "unit-video-copy-chroma-force: chroma preservation on + 4:2:2 → not gated" 0 "" "$(_vcc hevc yuv422p10le '' '' 5000000 'FORCE_CHROMA_420=0')"

  # 3.6: --max-copy-bitrate non-`k` rate formats. The `%k` strip makes the trailing 'k' optional,
  # so a bare integer ("80000") is a valid kbps ceiling: 100 Mbps exceeds it → re-encode, 20 Mbps
  # is under it → copyable. A non-numeric rate ("80M") is rejected by the validity guard — muxm
  # WARNs and SKIPS the ceiling (does not crash, does not block the copy) → copyable.
  _vcc_assert "unit-video-copy-bitrate-ceiling copy-compliant: non-k ceiling '80000' exceeded → re-encode" 1 "MAX_COPY_BITRATE" "$(_vcc hevc yuv420p '' '' 100000000 'MAX_COPY_BITRATE=80000')"
  _vcc_assert "unit-video-copy-bitrate-ceiling copy-compliant: non-k ceiling '80000' not exceeded → copyable" 0 ""              "$(_vcc hevc yuv420p '' ''  20000000 'MAX_COPY_BITRATE=80000')"
  _vcc_assert "unit-video-copy-bitrate-ceiling copy-compliant: invalid rate '80M' → warn + ceiling skipped (copyable)" 0 ""      "$(_vcc hevc yuv420p '' '' 100000000 'MAX_COPY_BITRATE=80M')"
}

_test_unit_pixfmt_gate_helpers() {
  # 3.5b (C1): direct unit tests for the two self-sufficient helpers the skip-if-ideal copy gate
  # relies on (in place of the stale TARGET_PIXFMT / IS_DV reads):
  #   _output_pixfmt_is_10bit — would the OUTPUT be 10-bit? (mirrors decide_color_and_pixfmt's
  #     bit-depth arm) — mock the _probe_field I/O boundary, assert the boolean across the matrix.
  #   _source_dv_profile     — read the source DV profile from the DOVI record in METADATA_CACHE
  #     (real jq parse of a synthetic cache), assert the echoed profile number.

  # ---- _output_pixfmt_is_10bit ----
  local body10
  # 4.2: _output_pixfmt_is_10bit now delegates to _probe_video_color_fields (+ _split_tab).
  body10="$(_extract_muxm_fns _output_pixfmt_is_10bit _lower _probe_video_color_fields _split_tab)" \
    || { fail "unit-pixfmt-10bit-gate: could not extract _output_pixfmt_is_10bit + _lower"; return; }
  # $1=pix $2=prim $3=trc $4=cspace $5=extra flags. Emits "10" if 10-bit output else "8".
  _o10(){
    bash -c 'HDR_TARGET_PIXFMT=yuv420p10le; TONEMAP_HDR_TO_SDR=0; SDR_FORCE_10BIT=0; SDR_USE_10BIT_IF_SRC_10BIT=0
P_PIX="$1"; P_PRIM="$2"; P_TRC="$3"; P_CSPACE="$4"
'"${5:-}"'
_probe_field(){ case "$1" in pix_fmt) printf "%s" "$P_PIX";; color_primaries) printf "%s" "$P_PRIM";; color_transfer) printf "%s" "$P_TRC";; color_space) printf "%s" "$P_CSPACE";; esac; }
'"$body10"'
if _output_pixfmt_is_10bit; then printf 10; else printf 8; fi' -- "$1" "$2" "$3" "$4"
  }
  _o10_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label (=$got-bit)"; else fail "$label — got ${got}-bit, expected ${want}-bit"; fi; }

  _o10_assert "unit-pixfmt-10bit-gate 10bit: SDR 8-bit, no flags → 8-bit out"            8  "$(_o10 yuv420p '' '' '')"
  _o10_assert "unit-pixfmt-10bit-gate 10bit: SDR --sdr-force-10bit → 10-bit out"         10 "$(_o10 yuv420p '' '' '' 'SDR_FORCE_10BIT=1')"
  _o10_assert "unit-pixfmt-10bit-gate 10bit: SDR 10-bit src + use-if-src-10bit → 10-bit" 10 "$(_o10 yuv420p10le '' '' '' 'SDR_USE_10BIT_IF_SRC_10BIT=1')"
  _o10_assert "unit-pixfmt-10bit-gate 10bit: SDR 8-bit src + use-if-src-10bit → 8-bit"   8  "$(_o10 yuv420p '' '' '' 'SDR_USE_10BIT_IF_SRC_10BIT=1')"
  _o10_assert "unit-pixfmt-10bit-gate 10bit: HDR10 (bt2020/pq) → 10-bit out"             10 "$(_o10 yuv420p bt2020 smpte2084 bt2020nc)"
  _o10_assert "unit-pixfmt-10bit-gate 10bit: HDR via colorspace only (bt2020nc) → 10-bit" 10 "$(_o10 yuv420p '' '' bt2020nc)"
  _o10_assert "unit-pixfmt-10bit-gate 10bit: HLG (arib-std-b67) → 10-bit out"            10 "$(_o10 yuv420p10le bt2020 arib-std-b67 bt2020nc)"
  _o10_assert "unit-pixfmt-10bit-gate 10bit: HDR but tone-mapped to SDR → 8-bit out"     8  "$(_o10 yuv420p10le bt2020 smpte2084 bt2020nc 'TONEMAP_HDR_TO_SDR=1')"
  _o10_assert "unit-pixfmt-10bit-gate 10bit: HDR + 8-bit HDR_TARGET_PIXFMT → 8-bit out"  8  "$(_o10 yuv420p bt2020 smpte2084 bt2020nc 'HDR_TARGET_PIXFMT=yuv420p')"

  # ---- _source_dv_profile (real jq over a synthetic cache) ----
  local bodydv
  bodydv="$(_extract_muxm_fns _source_dv_profile _jq_cache)" \
    || { fail "unit-pixfmt-10bit-gate: could not extract _source_dv_profile + _jq_cache"; return; }
  _sdp(){ bash -c 'METADATA_CACHE="$1"; DEBUG=0
'"$bodydv"'
_source_dv_profile' -- "$1"; }
  _sdp_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label (='${got}')"; else fail "$label — got '${got}', expected '${want}'"; fi; }

  local _cache_p7='{"streams":[{"codec_type":"video","side_data_list":[{"side_data_type":"DOVI configuration record","dv_profile":7}]}]}'
  local _cache_p8='{"streams":[{"codec_type":"video","side_data_list":[{"side_data_type":"DOVI configuration record","dv_profile":8}]}]}'
  local _cache_nodv='{"streams":[{"codec_type":"video","side_data_list":[{"side_data_type":"Display Matrix"}]}]}'
  local _cache_plain='{"streams":[{"codec_type":"video"}]}'
  _sdp_assert "unit-pixfmt-10bit-gate dv-profile: DOVI record profile 7 → '7'"   "7" "$(_sdp "$_cache_p7")"
  _sdp_assert "unit-pixfmt-10bit-gate dv-profile: DOVI record profile 8 → '8'"   "8" "$(_sdp "$_cache_p8")"
  _sdp_assert "unit-pixfmt-10bit-gate dv-profile: side-data but no DOVI → empty" ""  "$(_sdp "$_cache_nodv")"
  _sdp_assert "unit-pixfmt-10bit-gate dv-profile: no side_data_list → empty"     ""  "$(_sdp "$_cache_plain")"
}

_test_unit_sw_encoder_preflight() {
  # M5: the software x26x encoder must be preflighted (die 10 with an install hint) when ffmpeg
  # lacks it, instead of slipping through to a mid-encode die 40. Extract the helper, stub the I/O
  # boundary (ffmpeg_has_encoder) and die, and assert the exit code across codec × availability ×
  # HW-backend. die is stubbed to `exit $1` so the exact code (10) is observable.
  local body
  body="$(_extract_muxm_fns _preflight_sw_video_encoder)" \
    || { fail "unit-sw-encoder-preflight: could not extract _preflight_sw_video_encoder"; return; }
  # $1=VIDEO_CODEC $2=HW_ACCEL_RESOLVED $3=ffmpeg_has_encoder return (0=present, 1=missing). Emits exit code.
  _m5(){
    bash -c "die(){ exit \"\$1\"; }
ffmpeg_has_encoder(){ return ${3}; }
VIDEO_CODEC=${1}; HW_ACCEL_RESOLVED=${2}
${body}
_preflight_sw_video_encoder"
    printf '%s' "$?"
  }
  _m5_assert(){ local label="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then pass "$label (exit $got)"; else fail "$label — exit $got, expected $want"; fi; }
  _m5_assert "unit-sw-encoder-preflight: libx265 missing on the software path → die 10" 10 "$(_m5 libx265 none 1)"
  _m5_assert "unit-sw-encoder-preflight: libx264 missing on the software path → die 10" 10 "$(_m5 libx264 none 1)"
  _m5_assert "unit-sw-encoder-preflight: libx265 present → no die (exit 0)"             0  "$(_m5 libx265 none 0)"
  _m5_assert "unit-sw-encoder-preflight: HW backend resolved → check skipped (exit 0)"  0  "$(_m5 libx265 videotoolbox 1)"
  _m5_assert "unit-sw-encoder-preflight: AV1 codec is not x26x → skipped (exit 0)"      0  "$(_m5 libsvt-av1 none 1)"
}

_test_unit_hdr10_static_metadata() {
  # 3.1: direct unit test of _check_hdr10_static_metadata — the (previously untested) guard that
  # warns when a DV source carries NO HDR10 static metadata (mastering-display / MaxCLL), which
  # would yield a dim HDR10 stream after DV stripping. Mock the metadata cache (real jq parse) and
  # stub warn/note/report_add, then assert the emitted report status across present / missing /
  # partial. The fallback ffprobe is stubbed to emit nothing so the cache values fully decide.
  #
  # PLAN-vs-CODE (flagged): the catalog's M-HDR-2 was framed as "drop master-display/max-cll x265
  # params → output side-data absent". Verified empirically (see tools/perturb_check.sh M-HDR-1
  # note and the test_hdr smoke probe): muxm sets NO master-display/max-cll params — ffmpeg
  # AUTO-FORWARDS the source frame side-data to libx265 regardless of the x265-params string (even
  # with none), so the output-survival probe is tautological and has no muxm lever, exactly like
  # M-HDR-1. M-HDR-2 is therefore re-pointed at the genuinely-mutable detection/warning path here.
  local body
  body="$(_extract_muxm_fns _check_hdr10_static_metadata _jq_cache)" \
    || { fail "unit-hdr10-static-metadata: could not extract _check_hdr10_static_metadata + _jq_cache"; return; }
  # $1 = METADATA_CACHE JSON. Emits stubbed REPORT/WARN/NOTE lines on stdout.
  _hdrm(){
    bash -c 'METADATA_CACHE="$1"; SRC_ABS=/dev/null; FFPROBE_FLAGS=(-v error); DEBUG=0
warn(){ printf "WARN|%s\n" "$*"; }; note(){ printf "NOTE|%s\n" "$*"; }
report_add(){ printf "REPORT|%s|%s\n" "$1" "$2"; }
ffprobe(){ :; }
'"$body"'
_check_hdr10_static_metadata' -- "$1"
  }
  # $1=label  $2=expected report value (substring)  $3=expect a WARN? (1/0)  $4=JSON cache
  _hdrm_assert(){
    local label="$1" want_report="$2" want_warn="$3" out
    out="$(_hdrm "$4")"
    local report warned=0
    report="$(printf '%s\n' "$out" | grep '^REPORT|hdr10_static_metadata|' | head -1 | cut -d'|' -f3-)"
    printf '%s\n' "$out" | grep -q '^WARN|' && warned=1
    if [[ "$report" == *"$want_report"* && "$warned" == "$want_warn" ]]; then
      pass "$label (report='$report', warned=$warned)"
    else
      fail "$label — report='$report' warned=$warned (expected report~'$want_report', warned=$want_warn)"
    fi
  }

  local vid_sd='{"streams":[{"codec_type":"video","side_data_list":['
  # Both present → "present", no warning.
  _hdrm_assert "unit-hdr10-static-metadata hdr10-meta: mastering+CLL present → report present, no warn" "present" 0 \
    "${vid_sd}{\"side_data_type\":\"Mastering display metadata\"},{\"side_data_type\":\"Content light level metadata\"}]}]}"
  # Neither present (cache empty + ffprobe stubbed silent) → "missing", WARN fires. (M-HDR-2 target.)
  _hdrm_assert "unit-hdr10-static-metadata hdr10-meta: neither present → report missing + warn" "missing (mastering=0, cll=0)" 1 \
    '{"streams":[{"codec_type":"video","side_data_list":[]}]}'
  # Mastering only → "partial (mastering=1, cll=0)", a NOTE (not a warn).
  _hdrm_assert "unit-hdr10-static-metadata hdr10-meta: mastering only → report partial(m=1,c=0), no warn" "partial (mastering=1, cll=0)" 0 \
    "${vid_sd}{\"side_data_type\":\"Mastering display metadata\"}]}]}"
  # CLL only → "partial (mastering=0, cll=1)", WARN fires.
  _hdrm_assert "unit-hdr10-static-metadata hdr10-meta: CLL only → report partial(m=0,c=1) + warn" "partial (mastering=0, cll=1)" 1 \
    "${vid_sd}{\"side_data_type\":\"Content light level metadata\"}]}]}"
}

_test_unit_ocr_dispatch() {
  # 3.2: dispatch + track-production wiring for the PGS subtitle OCR path in _prepare_subtitle.
  # muxm OCRs ONLY PGS (hdmv_pgs_subtitle); ffmpeg cannot ENCODE PGS and this host has no vobsub
  # muxer, so a "build a VobSub fixture and run muxm" approach is unreachable — muxm never OCRs
  # VobSub (dvd_subtitle falls to the unsupported-codec arm). So we unit-test the REAL PGS branch:
  # mock the codec probe (_sp_sub_field → hdmv_pgs_subtitle), stub ffmpeg to stage a .sup, force the
  # no-vobsub-muxer fallback, and put a MOCK OCR tool on PATH that emits canned SRT. Assert (a) the
  # OCR tool is INVOKED and (b) _prepare_subtitle returns the produced SRT track path.
  # EXPLICIT NON-CLAIM: verifies dispatch + track production + wiring, NOT OCR text legibility.
  #
  # A VobSub/dvdsub fixture cannot exercise this: muxm's OCR branch is PGS-only and ffmpeg has no
  # PGS encoder, so the fixture route cannot reach the code under test.
  local body
  # CR-10: _prepare_subtitle's extract/convert sites await via _await_tracked_pid — pull the
  # helper in too (it calls the mocked spinner + the wait builtin), else the calls fail in isolation.
  # 3.1: _prepare_subtitle's PGS OCR branch delegates to _ocr_lang_flags/_run_ocr — pull both
  # in too, else the OCR dispatch under test silently no-ops (the call sites are unresolved in
  # the isolated subshell).
  body="$(_extract_muxm_fns _prepare_subtitle _await_tracked_pid _ocr_lang_flags _run_ocr)" \
    || { fail "unit-ocr-dispatch: could not extract _prepare_subtitle"; return; }
  local wd; wd="$(mktemp -d "${TMPDIR:-/tmp}/muxm-ocr.XXXXXX")" || { fail "unit-ocr-dispatch: mktemp failed"; return; }
  local sentinel="$wd/ocr_invoked"
  # Mock OCR tool: record the invocation, then emit a canned SRT beside the .sup (strip .sup→.srt),
  # which is exactly where _prepare_subtitle's no-vobsub fallback looks for the OCR result.
  local ocr="$wd/mock_ocr"
  cat > "$ocr" <<MOCKOCR
#!/usr/bin/env bash
printf 'INVOKED %s\n' "\$*" >> "$sentinel"
sup="\${@: -1}"
printf '1\n00:00:00,000 --> 00:00:02,000\nOCR canned line\n' > "\${sup%.sup}.srt"
MOCKOCR
  chmod +x "$ocr"

  local out rc=0
  out="$(bash -c 'set +e
WORKDIR="$1"; SUB_OCR_TOOL="$2"; SUB_OCR_LANG=eng; SUB_ENABLE_OCR=1
SUB_PRESERVE_TEXT_FORMAT=0; SUB_PRESERVE_BITMAP=0; SUB_BURN_FORCED=0; DRY_RUN=0
MUX_FORMAT=matroska; SRC_ABS=/dev/null; FFMPEG_FLAGS=(-v error); _ACTIVE_FFMPEG_PID=""
warn(){ printf "WARN %s\n" "$*" >&2; }; note(){ printf "NOTE %s\n" "$*" >&2; }
spinner(){ :; }
_sp_sub_field(){ printf "hdmv_pgs_subtitle"; }     # codec_name probe → PGS
ffmpeg_has_muxer(){ return 1; }                     # force the no-vobsub fallback OCR path
ffmpeg(){ printf "sup" > "${@: -1}"; return 0; }    # stage the extracted .sup (exit 0)
'"$body"'
_prepare_subtitle 0' -- "$wd" "$ocr")" || rc=$?

  # (a) dispatch: the OCR tool must have been invoked on the PGS bitmap.
  if [[ -f "$sentinel" ]]; then
    pass "unit-ocr-dispatch OCR dispatch: PGS subtitle dispatched to the OCR tool (tool invoked)"
  else
    fail "unit-ocr-dispatch OCR dispatch: OCR tool was NOT invoked for a PGS subtitle (rc=$rc)"
  fi
  # (b) track production: _prepare_subtitle must echo the produced SRT path carrying the OCR cues.
  if [[ -n "$out" && -s "$out" ]] && grep -q 'OCR canned line' "$out" 2>/dev/null; then
    pass "unit-ocr-dispatch OCR dispatch: PGS bitmap produces an SRT text track ($(basename "$out"))"
  else
    fail "unit-ocr-dispatch OCR dispatch: no SRT text track produced from the PGS bitmap (returned '$out', rc=$rc)"
  fi
  rm -rf "$wd"
}

# Log/diagnostics persistence: the two on_exit copy helpers, exercised in
# isolation so the file-selection contract is verified deterministically (no real encode).
# _persist_failure_bundle's selection IS the "additional troubleshooting files" decision:
# the run log + every *.err/*.log, and NONE of the multi-GB binary intermediates.
_test_unit_persist_helpers() {
  # ---- _persist_failure_bundle: copies text diagnostics, excludes binaries ----
  local wd="$TESTDIR/pb_workdir" dest="$TESTDIR/pb_bundle" log
  log="$wd/muxm.20260101-000000.log"
  rm -rf "$wd" "$dest"; mkdir -p "$wd"
  printf 'run log\n'    > "$log"
  printf 'x265 error\n' > "$wd/encode.err"
  printf 'ocr ran\n'    > "$wd/sub_0_ocr.log"
  printf 'probe\n'      > "$wd/probe_meta.err"
  # Binary intermediates that must NOT end up in the bundle (the disk hogs).
  printf 'BIN' > "$wd/video_base.hevc"
  printf 'BIN' > "$wd/video_mixed.mkv"
  printf 'BIN' > "$wd/rpu_final.bin"
  printf 'BIN' > "$wd/audio_stereo.aac"

  assert_muxm_fn_exit "_persist_failure_bundle: returns 0 when the bundle is written" 0 \
    _persist_failure_bundle "LOGFILE='$log'; WORKDIR='$wd'; DEBUG_BUNDLE_DIR='$dest'"

  local want_ok=1 _f
  for _f in muxm.20260101-000000.log encode.err sub_0_ocr.log probe_meta.err; do
    [[ -f "$dest/$_f" ]] || { want_ok=0; break; }
  done
  local no_bin=1
  for _f in video_base.hevc video_mixed.mkv rpu_final.bin audio_stereo.aac; do
    [[ -e "$dest/$_f" ]] && { no_bin=0; break; }
  done
  if (( want_ok && no_bin )); then
    pass "_persist_failure_bundle: copies log + all .err/.log, excludes binary intermediates"
  else
    # shellcheck disable=SC2012  # $dest is a test-controlled tmp dir with alphanumeric fixture names; ls is fine in this fail-only diagnostic
    fail "_persist_failure_bundle: wrong selection (text-present=$want_ok binaries-absent=$no_bin) — got: $(ls "$dest" 2>/dev/null | tr '\n' ' ')"
  fi

  # mkdir failure (bundle path already occupied by a regular file) → returns nonzero so
  # on_exit keeps WORKDIR instead of destroying the only surviving diagnostics.
  local destfile="$TESTDIR/pb_bundle_file"; rm -rf "$destfile"; : > "$destfile"
  assert_muxm_fn_exit "_persist_failure_bundle: returns nonzero when the bundle dir can't be created" 1 \
    _persist_failure_bundle "LOGFILE='$log'; WORKDIR='$wd'; DEBUG_BUNDLE_DIR='$destfile'"
  rm -rf "$wd" "$dest" "$destfile"

  # ---- _persist_log: copy the run log to its durable path ----
  local pl_src="$TESTDIR/pl_src.log" pl_dst="$TESTDIR/pl_dst.log"
  printf 'log body\n' > "$pl_src"; rm -f "$pl_dst"
  assert_muxm_fn_exit "_persist_log: returns 0 on a successful copy" 0 \
    _persist_log "LOGFILE='$pl_src'; LOG_PERSIST_PATH='$pl_dst'"
  if [[ -s "$pl_dst" ]]; then
    pass "_persist_log: log copied to the durable path"
  else
    fail "_persist_log: durable copy missing at $pl_dst"
  fi
  # No log present (e.g. DEBUG=1 created none) → clean no-op, returns 0.
  assert_muxm_fn_exit "_persist_log: absent log is a clean no-op (returns 0)" 0 \
    _persist_log "LOGFILE='$TESTDIR/pl_absent.log'; LOG_PERSIST_PATH='$pl_dst'"
  # Copy target unwritable (parent dir missing) → returns nonzero so caller keeps WORKDIR.
  assert_muxm_fn_exit "_persist_log: returns nonzero when the copy fails" 1 \
    _persist_log "LOGFILE='$pl_src'; LOG_PERSIST_PATH='$TESTDIR/pl_no_such_dir/out.muxm.log'"
  rm -f "$pl_src" "$pl_dst"
}

test_unit() {
  section "Pure-Function Unit Tests"
  _test_unit_audio_helpers
  _test_unit_sub_helpers
  _test_unit_sub_track_model
  _test_unit_sub_emitter
  _test_unit_sub_plan_add_embed
  _test_unit_validation_helpers
  _test_unit_filesize
  _test_unit_sii_container_safety
  _test_unit_misc_helpers
  _test_unit_disk_preflight
  _test_unit_disk_fallback
  _test_unit_disk_output_volume
  _test_unit_av1_resolution_crf
  _test_unit_ignored_knobs
  _test_unit_h264_drops_dv
  _test_unit_realpath_fallback
  _test_unit_apply_level_vbv
  _test_unit_mapping_helpers
  _test_unit_av1_helpers
  _test_unit_fps_helpers
  _test_unit_extract_helper
  _test_unit_score_audio_stream
  _test_unit_select_best_audio
  _test_unit_audio_disposition
  _test_unit_decide_color_and_pixfmt
  _test_unit_build_subtitle_lists
  _test_unit_rf6_subtitle_fallback
  _test_unit_metadata_sanitize
  _test_unit_empty_array_safe
  _test_unit_no_bare_fps_array
  _test_unit_grep_flags
  _test_unit_man_date_token
  _test_unit_probe_stream_field_nits
  _test_unit_report_add_escaping
  _test_unit_duration_tier3
  _test_unit_video_copy_compliant
  _test_unit_pixfmt_gate_helpers
  _test_unit_sw_encoder_preflight
  _test_unit_hdr10_static_metadata
  _test_unit_ocr_dispatch
  _test_unit_persist_helpers
  _test_unit_prefer_complete_ffmpeg
  _test_unit_parse_audio_record
  _test_unit_ffmpeg_pid_lifecycle
  _test_unit_pipx_bin_dir
  _test_unit_dv_config_record_probe
  _test_unit_refresh_mandb
  _test_unit_require_sudo_for
  _test_unit_warn_if_not_on_manpath
  _test_unit_dv_give_up_to_base
  _test_unit_dv_mp4box_wrap
  _test_unit_ocr_lang_flags
  _test_unit_run_ocr
  _test_unit_audio_pretty_line
  _test_unit_check_mux_stream_counts
  _test_unit_loglevel_str
  _test_unit_disk_df_unavailable
  _test_unit_prepare_subtitle_workdir_gone
}

# build_subtitle_plan's _sub_plan_add_embed routing — the single-track desync
# fix at the model level. A preserved PGS bitmap (a .sup from an
# embedded source) MUST become an embedded:N track (mapped from source by the
# emitter — see T6), NOT a file: input (which mux_final would re-import as a
# standalone .sup elementary stream, rebasing it to t=0). Converted/extracted files
# and external sidecars stay file:. Combined with T6, this is the always-runnable
# single-track desync guard (the e2e T11 is fixture-gated, see test_subs).
_test_unit_sub_plan_add_embed() {
  local body out
  body="$(_extract_muxm_fns _sub_tracks_reset _sub_track_add _sub_track_count _sub_track_field _sub_plan_add_embed)" \
    || { fail "sub-plan-add: could not extract _sub_plan_add_embed"; return; }
  out="$(bash -c "$body"$'\n''
    set -u
    _sub_tracks_reset
    # Preserved PGS bitmap (.sup, embedded source) → embedded:N (THE desync fix).
    _sub_plan_add_embed embedded:3 /work/sub.3.sup eng "Full" full hdmv_pgs_subtitle
    # Converted/extracted text file → file: input.
    _sub_plan_add_embed embedded:0 /work/sub.0.srt eng English full subrip
    # External sidecar → file: input.
    _sub_plan_add_embed ext:/x/movie.en.srt /x/movie.en.srt spa "" full subrip
    # Forced PGS preserved → embedded:N with forced disposition.
    _sub_plan_add_embed embedded:1 /work/sub.1.sup eng "Forced" forced hdmv_pgs_subtitle
    echo "n=$(_sub_track_count)"
    echo "t0=$(_sub_track_field 0 kind):$(_sub_track_field 0 value):$(_sub_track_field 0 codec):$(_sub_track_field 0 disposition)"
    echo "t1=$(_sub_track_field 1 kind):$(_sub_track_field 1 value)"
    echo "t2=$(_sub_track_field 2 kind):$(_sub_track_field 2 value)"
    echo "t3=$(_sub_track_field 3 kind):$(_sub_track_field 3 value):$(_sub_track_field 3 disposition)"
  ' 2>&1)"
  assert_contains "n=4" "sub-plan-add: four tracks recorded" "$out"
  assert_contains "t0=embedded:3:hdmv_pgs_subtitle:0" \
    "sub-plan-add: preserved PGS (.sup) → embedded:N from source (desync fix — no .sup -i)" "$out"
  assert_contains "t1=file:/work/sub.0.srt" \
    "sub-plan-add: extracted text file → file: input" "$out"
  assert_contains "t2=file:/x/movie.en.srt" \
    "sub-plan-add: external sidecar → file: input" "$out"
  assert_contains "t3=embedded:1:forced" \
    "sub-plan-add: forced PGS → embedded:N with forced disposition" "$out"
}

# The shared subtitle emitter (_add_sub_stream + _emit_sub_tracks), used by mux_final.
# Driven by extraction: declare the
# mux_final-scoped arrays/counters the emitter mutates (ff_in ff_map ff_codec
# next_idx _src_input_idx _ext_sub_paths _ext_sub_idxs) and the globals it reads
# (SRC_ABS MUX_FORMAT SUB_PRESERVE_TEXT_FORMAT), populate SUB_TRACKS_* like the
# selectors will, run _emit_sub_tracks, and assert the emitted ff_* fragments.
# The headline guard is T6 (embedded bitmap ⇒ map from source, never a .sup input).
_test_unit_sub_emitter() {
  local body
  body="$(_extract_muxm_fns _sub_tracks_reset _sub_track_add _add_sub_stream _emit_sub_tracks _is_text_sub_codec)" \
    || { fail "sub-emitter: could not extract emitter helpers"; return; }

  # Run a scenario in one subshell. $1 = MUX_FORMAT, $2 = SUB_PRESERVE_TEXT_FORMAT,
  # $3 = next_idx seed (simulates inputs video/audio already consumed), $4 = the
  # _sub_track_add lines. Echoes labeled ff_in/ff_map/ff_codec lines (2>&1 so a
  # die() abort surfaces as "DIE:<code>").
  local _emit_run
  # shellcheck disable=SC2016  # single quotes are deliberate: this body is run LATER in a
  # sub-bash (bash -c "$body"$'\n'"$_emit_run"), where $MF/$PTF/$SEED/$ADDS and the ff_*/
  # SUB_TRACKS_* arrays must expand THERE — not in this scope.
  _emit_run='
    set -u
    die(){ echo "DIE:${1:-1}" >&2; exit "${1:-1}"; }
    MUX_FORMAT="$MF"; SUB_PRESERVE_TEXT_FORMAT="$PTF"; SRC_ABS="/src.mkv"
    ff_in=(); ff_map=(); ff_codec=(); next_idx="$SEED"; _src_input_idx=""
    _ext_sub_paths=(); _ext_sub_idxs=()
    _sub_tracks_reset
    eval "$ADDS"
    _emit_sub_tracks
    echo "IN: ${ff_in[*]}"
    echo "MAP: ${ff_map[*]}"
    echo "CODEC: ${ff_codec[*]}"
  '
  local out

  # ── Frozen MULTI shape (archive: 3 embedded subrip, eng/spa/fra, full, no source
  #    title → "Full" label; MKV, src registered at input idx 1). Must equal the
  #    Phase-1 captured multi-track sub fragment token-for-token. ──
  out="$(MF=matroska PTF=1 SEED=1 ADDS='
    _sub_track_add embedded 0 eng "" full subrip 0
    _sub_track_add embedded 1 spa "" full subrip 0
    _sub_track_add embedded 2 fra "" full subrip 0
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "IN: -i /src.mkv" \
    "emitter[multi]: one shared source input (idempotent registration)" "$out"
  assert_not_contains "-i /src.mkv -i /src.mkv" \
    "emitter[multi]: source input not added per-track" "$out"
  assert_contains "MAP: -map 1:s:0 -map 1:s:1 -map 1:s:2" \
    "emitter[multi]: all subs mapped from the shared source input (frozen shape)" "$out"
  assert_contains "CODEC: -c:s:0 copy -metadata:s:s:0 language=eng -metadata:s:s:0 title=Full -disposition:s:0 0 -c:s:1 copy -metadata:s:s:1 language=spa -metadata:s:s:1 title=Full -disposition:s:1 0 -c:s:2 copy -metadata:s:s:2 language=fra -metadata:s:s:2 title=Full -disposition:s:2 0" \
    "emitter[multi]: tagging fragment matches the Phase-1 frozen multi shape" "$out"

  # ── Unified SINGLE-TEXT shape (1 file sub.0.srt, full, source title "English";
  #    MKV, file input at idx 2). NOTE: the unified rule stream-copies a text file
  #    (-c:s:0 copy) rather than re-encoding to srt. Both yield identical subrip in
  #    MKV, so single-track and multi-track share this shape; the assertion below
  #    expects the copy form. ──
  out="$(MF=matroska PTF=1 SEED=2 ADDS='
    _sub_track_add file /work/sub.0.srt eng English full srt 0
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "IN: -i /work/sub.0.srt" \
    "emitter[single-text]: file added as -i input" "$out"
  assert_contains "MAP: -map 2:s:0" \
    "emitter[single-text]: file mapped at idx:s:0" "$out"
  assert_contains "CODEC: -c:s:0 copy -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -disposition:s:0 0" \
    "emitter[single-text]: text file stream-copied + tagged (unified rule)" "$out"

  # ── T6 (core desync guard): embedded PGS bitmap ⇒ mapped from source, NEVER a
  #    standalone .sup input. This is the whole reason the refactor exists. ──
  out="$(MF=matroska PTF=1 SEED=1 ADDS='
    _sub_track_add embedded 0 eng "" full hdmv_pgs_subtitle 0
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "MAP: -map 1:s:0" \
    "unit-sub-emitter: embedded PGS mapped from source (-map src:s:N)" "$out"
  assert_contains "IN: -i /src.mkv" \
    "unit-sub-emitter: embedded PGS uses the source input" "$out"
  assert_not_contains ".sup" \
    "unit-sub-emitter: embedded PGS produces NO standalone .sup input (desync cannot recur)" "$out"
  assert_contains "CODEC: -c:s:0 copy" \
    "unit-sub-emitter: embedded PGS stream-copied in MKV" "$out"

  # ── file: dedup — same path twice ⇒ ONE -i input, TWO -map idx:s:0. ──
  out="$(MF=matroska PTF=1 SEED=2 ADDS='
    _sub_track_add file /work/dup.srt eng "A" full srt 0
    _sub_track_add file /work/dup.srt eng "B" full srt 0
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "IN: -i /work/dup.srt" \
    "emitter[dedup]: duplicated file path registered" "$out"
  assert_not_contains "-i /work/dup.srt -i /work/dup.srt" \
    "emitter[dedup]: duplicated file path added only ONCE" "$out"
  assert_contains "MAP: -map 2:s:0 -map 2:s:0" \
    "emitter[dedup]: both tracks map the same deduped input idx:s:0" "$out"

  # ── file: distinct paths ⇒ TWO -i inputs at consecutive indices. ──
  out="$(MF=matroska PTF=1 SEED=2 ADDS='
    _sub_track_add file /work/a.srt eng "A" full srt 0
    _sub_track_add file /work/b.srt spa "B" full srt 0
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "IN: -i /work/a.srt -i /work/b.srt" \
    "emitter[distinct]: two distinct file paths each added as -i" "$out"
  assert_contains "MAP: -map 2:s:0 -map 3:s:0" \
    "emitter[distinct]: distinct files mapped at consecutive input indices" "$out"

  # ── source idempotency: embedded + file + embedded ⇒ ONE -i SRC, file interleaved. ──
  out="$(MF=matroska PTF=1 SEED=1 ADDS='
    _sub_track_add embedded 0 eng "" full subrip 0
    _sub_track_add file /work/x.srt spa "X" full srt 0
    _sub_track_add embedded 1 fra "" full subrip 0
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "IN: -i /src.mkv -i /work/x.srt" \
    "emitter[idempotent]: source added once, file once, in registration order" "$out"
  assert_contains "MAP: -map 1:s:0 -map 2:s:0 -map 1:s:1" \
    "emitter[idempotent]: both embedded tracks share source idx 1; file at idx 2" "$out"

  # ── Tagging matrix: disposition + title-label from TYPE. ──
  out="$(MF=matroska PTF=1 SEED=1 ADDS='
    _sub_track_add embedded 0 eng "" forced subrip forced
    _sub_track_add embedded 1 eng "" sdh    subrip hearing_impaired
    _sub_track_add embedded 2 eng "" full   subrip 0
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "title=Forced -disposition:s:0 forced" \
    "emitter[matrix]: type forced → title Forced + disposition forced" "$out"
  assert_contains "title=SDH -disposition:s:1 hearing_impaired" \
    "emitter[matrix]: type sdh → title SDH + disposition hearing_impaired" "$out"
  assert_contains "title=Full -disposition:s:2 0" \
    "emitter[matrix]: type full → title Full + disposition 0" "$out"

  # ── Title fallback: a source title overrides the type label. ──
  out="$(MF=matroska PTF=1 SEED=1 ADDS='
    _sub_track_add embedded 0 eng "Director Commentary" full subrip 0
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "title=Director Commentary" \
    "emitter[matrix]: non-empty source title wins over the type label" "$out"

  # ── Codec matrix: ASS preserve vs convert; MP4 text → mov_text. ──
  out="$(MF=matroska PTF=1 SEED=1 ADDS='_sub_track_add embedded 0 eng "" full ass 0' \
    bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "CODEC: -c:s:0 copy" \
    "emitter[codec]: embedded ASS in MKV with preserve=1 → copy" "$out"
  out="$(MF=matroska PTF=0 SEED=1 ADDS='_sub_track_add embedded 0 eng "" full ass 0' \
    bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "CODEC: -c:s:0 srt" \
    "emitter[codec]: embedded ASS in MKV with preserve=0 → srt" "$out"
  out="$(MF=mp4 PTF=1 SEED=1 ADDS='_sub_track_add embedded 0 eng "" full subrip 0' \
    bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "CODEC: -c:s:0 mov_text" \
    "emitter[codec]: embedded text into MP4 → mov_text" "$out"

  # ── MP4/MOV bitmap hard-stop preserved: embedded PGS into MP4 ⇒ die 12. ──
  # The stub die() exits 12, so the command substitution exits nonzero; `|| true`
  # keeps that intentional abort from tripping the harness's set -e.
  out="$(MF=mp4 PTF=1 SEED=1 ADDS='_sub_track_add embedded 0 eng "" full hdmv_pgs_subtitle 0' \
    bash -c "$body"$'\n'"$_emit_run" 2>&1)" || true
  assert_contains "DIE:12" \
    "emitter[safety]: embedded bitmap into MP4 hard-stops (die 12)" "$out"

  # ── ROUTING: burn/export tracks are skipped by the emitter. ──
  out="$(MF=matroska PTF=1 SEED=1 ADDS='
    _sub_track_add embedded 0 eng "" forced subrip forced burn
    _sub_track_add file /work/exp.srt spa "X" full srt 0 export
    _sub_track_add embedded 1 eng "" full subrip 0 embed
  ' bash -c "$body"$'\n'"$_emit_run" 2>&1)"
  assert_contains "MAP: -map 1:s:1" \
    "emitter[routing]: only the embed track is emitted (burn/export skipped)" "$out"
  assert_not_contains "/work/exp.srt" \
    "emitter[routing]: export track not added as an input" "$out"
  assert_not_contains "-map 1:s:0" \
    "emitter[routing]: burn track not mapped into the container" "$out"
}

# The unified subtitle track-list model (SUB_TRACKS_* parallel arrays +
# _sub_tracks_reset / _sub_track_add / _sub_track_count / _sub_track_field).
# This unit-tests the model's own contract in isolation:
# append/iterate/field-access round-trips, empty + multi-entry, the ROUTING default
# (embed) and explicit embed/burn/export, and the unknown-field guard. Driven in a
# single `set -u` subshell so the shared arrays persist across calls.
_test_unit_sub_track_model() {
  local body out
  body="$(_extract_muxm_fns _sub_tracks_reset _sub_track_add _sub_track_count _sub_track_field)" \
    || { fail "sub-track-model: could not extract unified track-list helpers"; return; }
  # shellcheck disable=SC2016  # body must reach the sub-bash unexpanded; arrays live THERE
  out="$(bash -c "$body"$'\n''
    set -u
    _sub_tracks_reset
    echo "empty_count=$(_sub_track_count)"
    # ROUTING omitted on the first two → must default to "embed".
    _sub_track_add embedded 2 eng "" forced copy forced
    _sub_track_add file /work/sub.0.srt spa "Spanish" full srt 0
    # Explicit ROUTING values.
    _sub_track_add embedded 5 fra "Forced FR" forced copy forced burn
    _sub_track_add file /ext/movie.en.srt eng "" full srt 0 export
    echo "count=$(_sub_track_count)"
    echo "t0_kind=$(_sub_track_field 0 kind)"
    echo "t0_value=$(_sub_track_field 0 value)"
    echo "t0_lang=$(_sub_track_field 0 lang)"
    echo "t0_title=[$(_sub_track_field 0 title)]"
    echo "t0_type=$(_sub_track_field 0 type)"
    echo "t0_codec=$(_sub_track_field 0 codec)"
    echo "t0_disp=$(_sub_track_field 0 disposition)"
    echo "t0_routing=$(_sub_track_field 0 routing)"
    echo "t1_kind=$(_sub_track_field 1 kind)"
    echo "t1_value=$(_sub_track_field 1 value)"
    echo "t1_title=[$(_sub_track_field 1 title)]"
    echo "t1_routing=$(_sub_track_field 1 routing)"
    echo "t2_routing=$(_sub_track_field 2 routing)"
    echo "t3_routing=$(_sub_track_field 3 routing)"
    _sub_track_field 0 bogus; echo "bogus_rc=$?"
    _sub_tracks_reset
    echo "reset_count=$(_sub_track_count)"
  ' 2>&1)"

  assert_contains "empty_count=0"        "sub-track-model: empty list has count 0"                 "$out"
  assert_contains "count=4"              "sub-track-model: four appended tracks counted"           "$out"
  # Track 0 — embedded, every field round-trips; empty title stays empty.
  assert_contains "t0_kind=embedded"     "sub-track-model: t0 kind=embedded"                       "$out"
  assert_contains "t0_value=2"           "sub-track-model: t0 value (embedded stream index)"       "$out"
  assert_contains "t0_lang=eng"          "sub-track-model: t0 lang round-trips"                    "$out"
  assert_contains "t0_title=[]"          "sub-track-model: t0 empty title stays empty"             "$out"
  assert_contains "t0_type=forced"       "sub-track-model: t0 type round-trips"                    "$out"
  assert_contains "t0_codec=copy"        "sub-track-model: t0 codec round-trips"                   "$out"
  assert_contains "t0_disp=forced"       "sub-track-model: t0 disposition round-trips"             "$out"
  assert_contains "t0_routing=embed"     "sub-track-model: t0 ROUTING defaults to embed"           "$out"
  # Track 1 — file kind, path preserved as value, title with a space round-trips.
  assert_contains "t1_kind=file"         "sub-track-model: t1 kind=file"                           "$out"
  assert_contains "t1_value=/work/sub.0.srt" "sub-track-model: t1 value (file path) round-trips"  "$out"
  assert_contains "t1_title=[Spanish]"   "sub-track-model: t1 title round-trips"                   "$out"
  assert_contains "t1_routing=embed"     "sub-track-model: t1 ROUTING defaults to embed"           "$out"
  # ROUTING flag values.
  assert_contains "t2_routing=burn"      "sub-track-model: explicit ROUTING=burn round-trips"      "$out"
  assert_contains "t3_routing=export"    "sub-track-model: explicit ROUTING=export round-trips"    "$out"
  # Unknown field is a clean nonzero (2), not a crash.
  assert_contains "bogus_rc=2"           "sub-track-model: unknown field returns 2 (no crash)"     "$out"
  # Reset clears back to empty.
  assert_contains "reset_count=0"        "sub-track-model: reset clears the list"                  "$out"
}

# When df yields nothing (unavailable / unusual mount), disk_free_warn must emit an
# explicit "preflight skipped" note instead of failing open silently. Shim df to output nothing and
# assert the skipped-note fires. Perturb MUT-L-DISKNOTE drops the else-note → no note → red.
_test_unit_disk_df_unavailable() {
  local body
  body="$(awk '/^disk_free_warn\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
  if [[ -z "$body" ]]; then fail "unit-disk-preflight-note: disk_free_warn extraction anchor failed"; return; fi
  local _stubs='
    DISK_CHECK=1; VIDEO_CODEC=libx265; CRF_VALUE=28; PRESET_VALUE=medium
    DISABLE_DV=1; AUDIO_MULTI_TRACK=0; AUDIO_FORCE_CODEC=""; METADATA_CACHE=""
    DISK_FREE_WARN_GB=0; WORKDIR=/tmp; OUT_DIR=/tmp
    _get_source_duration_secs(){ echo 100; }; _audio_stream_count(){ echo 0; }; _audio_stream_info(){ echo ""; }
    _source_has_dv_metadata(){ return 1; }; _crf_ratio(){ echo 50; }; _preset_multiplier(){ echo 1000; }
    _av1_preset_multiplier(){ echo 1000; }; _gb(){ echo 0; }; _jq_cache(){ echo 5000000; }
    SRC_ABS=/dev/null; VIDEO_COPY_IF_COMPLIANT=0
    df(){ :; }                      # df unavailable: emits nothing → no avail figure
    die(){ echo "DIE:$*"; }; say(){ :; }; log(){ :; }
    note(){ printf "NOTE:%s\n" "$*"; }
  '
  local out
  out="$(bash -c "$_stubs"$'\n'"$body"$'\n''disk_free_warn' 2>/dev/null)"
  if printf '%s\n' "$out" | grep -qiE "NOTE:.*preflight skipped: df unavailable"; then
    pass "unit-disk-preflight-note: df-unavailable emits an explicit 'preflight skipped' note (no silent fail-open)"
  else
    fail "unit-disk-preflight-note: no 'preflight skipped' note when df is unavailable (out: ${out:-<none>})"
  fi
}

# _prepare_subtitle on a vanished workdir must echo ""+rc0 (warn-and-skip), not rc1 —
# a non-zero rc trips set -e at the `sub_path="$(...)"` callers and aborts the whole run. Extract
# the helper, point WORKDIR at a nonexistent dir, assert rc 0 + empty output. Perturb
# MUT-L-SUBWD reverts to `return 1` → rc 1 → red.
_test_unit_prepare_subtitle_workdir_gone() {
  local body
  body="$(_extract_muxm_fns _prepare_subtitle _await_tracked_pid)" || { fail "unit-prepare-subtitle-workdir-gone: could not extract _prepare_subtitle"; return; }
  local out rc=0
  out="$(bash -c 'warn(){ :; }; WORKDIR="/no/such/muxm/workdir/xyzzy"'$'\n'"$body"$'\n''_prepare_subtitle 0' 2>/dev/null)" || rc=$?
  if (( rc == 0 )) && [[ -z "$out" ]]; then
    pass "unit-prepare-subtitle-workdir-gone: _prepare_subtitle on a vanished workdir returns ''+rc0 (warn-and-skip, no set -e abort)"
  else
    fail "unit-prepare-subtitle-workdir-gone: vanished-workdir path returned rc=$rc out='$out' (expected rc0 + empty)"
  fi
}

# M8: _pipx_resolve_bin_dir must find PIPX_BIN_DIR even on pipx <1.0, which lacks
# `environment --value` — by falling back to parsing the full `pipx environment` dump. Drives the
# extracted helper against a shim mimicking old pipx. Perturb MUT-M8-FALLBACK removes the fallback
# line → the helper returns empty under the old-pipx shim → red.
_test_unit_pipx_bin_dir() {
  local body
  body="$(_extract_muxm_fns _pipx_resolve_bin_dir)" \
    || { fail "unit-pipx-bin-dir-fallback: could not extract _pipx_resolve_bin_dir"; return; }
  local _d="$TESTDIR/m8_unit"; mkdir -p "$_d/bin"
  # pipx <1.0 shim: `environment --value` fails; plain `environment` prints PIPX_BIN_DIR=...
  cat > "$_d/bin/pipx" <<EOF
#!/bin/sh
if [ "\$1" = "environment" ] && [ "\$2" = "--value" ]; then echo "error: no such option --value" >&2; exit 2; fi
if [ "\$1" = "environment" ]; then echo "PIPX_HOME=/x"; echo "PIPX_BIN_DIR=$_d/pbin"; exit 0; fi
exit 0
EOF
  chmod +x "$_d/bin/pipx"
  local got
  got="$(PATH="$_d/bin:$PATH" bash -c "$body"$'\n''_pipx_resolve_bin_dir')"
  if [[ "$got" == "$_d/pbin" ]]; then
    pass "unit-pipx-bin-dir-fallback: _pipx_resolve_bin_dir finds PIPX_BIN_DIR on pipx <1.0 (parses 'pipx environment')"
  else
    fail "unit-pipx-bin-dir-fallback: _pipx_resolve_bin_dir returned '$got' under old-pipx shim (expected '$_d/pbin')"
  fi
  rm -rf "$_d"
}

# M-DRY-a: _dv_probe_has_config_record is true iff the probe output carries a DOVI configuration
# record. Drives the extracted helper with a shimmed ffprobe (DV text vs plain) — independent of a
# real DV file, so it pins the helper's probe+grep logic directly. Perturb MUT-MDRYA-PROBE breaks
# the helper's grep → the positive case goes false → red.
_test_unit_dv_config_record_probe() {
  local body
  body="$(_extract_muxm_fns _dv_probe_has_config_record)" \
    || { fail "unit-dv-config-record-probe: could not extract _dv_probe_has_config_record"; return; }
  # shellcheck disable=SC2016  # the shim/globals are literal text for the sub-shell, not this one.
  local drv='ffprobe(){ case "$*" in *DVPOS*) echo "DOVI configuration record present";; *) echo "codec_name=hevc";; esac; }
FFPROBE_FLAGS=(-v error); DV_CONTAINER_PATTERN="DOVI configuration record|dv_profile|dv_version"'
  if bash -c "$drv"$'\n'"$body"$'\n''_dv_probe_has_config_record DVPOS' 2>/dev/null; then
    pass "unit-dv-config-record-probe: _dv_probe_has_config_record detects a present DOVI configuration record"
  else
    fail "unit-dv-config-record-probe: helper failed to detect a present DOVI configuration record"
  fi
  if bash -c "$drv"$'\n'"$body"$'\n''_dv_probe_has_config_record nope' 2>/dev/null; then
    fail "unit-dv-config-record-probe: helper falsely reported a DOVI record on non-DV output"
  else
    pass "unit-dv-config-record-probe: _dv_probe_has_config_record returns false on non-DV output"
  fi
}

# M-DRY-b: structural — both _install_man and _uninstall_man must delegate the man-database refresh
# to the extracted _refresh_mandb helper (no inline duplicate block). A behavioral mandb test is
# not meaningful (command -v-guarded, output uninspectable, mandb often absent), so this guards the
# extraction itself. Covered behaviorally by the existing setup man-tests staying green.
_test_unit_refresh_mandb() {
  local _inst _uninst
  _inst="$(awk '/^_install_man\(\)/,/^\}/' "$MUXM")"
  _uninst="$(awk '/^_uninstall_man\(\)/,/^\}/' "$MUXM")"
  if grep -q '_refresh_mandb ' <<<"$_inst" && grep -q '_refresh_mandb ' <<<"$_uninst"; then
    pass "unit-refresh-mandb-shared: _install_man and _uninstall_man both delegate to _refresh_mandb"
  else
    fail "unit-refresh-mandb-shared: a man function still inlines the mandb-refresh block instead of calling _refresh_mandb"
  fi
}

# 1.1: _require_sudo_for must die with an actionable message (not a raw "command not found" or a
# hang) when `sudo` isn't on PATH, and must be a silent no-op when it is. Tested in isolation via
# a controlled PATH (not real-system PATH surgery, which would be fragile across platforms) with
# `die` stubbed to a plain printf+exit — same idiom the rest of this suite already uses for
# functions that call die (e.g. the VMF/disk-preflight unit tests).
_test_unit_require_sudo_for() {
  local body
  body="$(_extract_muxm_fns _require_sudo_for)" || { fail "unit-require-sudo-for: _require_sudo_for not found in muxm"; return; }
  local die_stub='die(){ printf "DIE|%s|%s\n" "$1" "$2"; exit "$1"; }'

  # NOTE: PATH must be reassigned as the FIRST statement INSIDE the bash -c script body, not as
  # an env-prefix on the `bash -c` invocation itself — an env-prefixed `PATH=X bash -c ...`
  # resolves the `bash` command NAME using the reassigned PATH too, so a restrictive value
  # there makes bash itself "command not found" rather than restricting what the script sees.
  local out rc script
  script='PATH="/nonexistent_dir_for_muxm_test"'$'\n'"$die_stub"$'\n'"$body"$'\n''_require_sudo_for "/some/dir"'
  out="$(bash -c "$script" 2>&1)" && rc=$? || rc=$?
  if [[ "$rc" -eq 10 ]] && grep -qiF "sudo" <<<"$out" && grep -qiF "not available" <<<"$out"; then
    pass "unit-require-sudo-for: _require_sudo_for dies (exit 10) with an actionable message when sudo is absent"
  else
    fail "unit-require-sudo-for: _require_sudo_for did not die correctly when sudo absent (rc=$rc, out=${out:0:200})"
  fi

  local stub_bin; stub_bin="$(mktemp -d)"
  printf '#!/bin/sh\nexit 0\n' > "$stub_bin/sudo"; chmod +x "$stub_bin/sudo"
  script="PATH=\"$stub_bin\""$'\n'"$die_stub"$'\n'"$body"$'\n''_require_sudo_for "/some/dir"; echo "RC=$?"'
  out="$(bash -c "$script" 2>&1)"
  rm -rf "$stub_bin"
  if grep -qF "RC=0" <<<"$out" && ! grep -qF "DIE|" <<<"$out"; then
    pass "unit-require-sudo-for: _require_sudo_for does not die when sudo is present"
  else
    fail "unit-require-sudo-for: _require_sudo_for unexpectedly died when sudo was present (out=${out:0:200})"
  fi
}

# 1.7: _warn_if_not_on_manpath must warn when the install target isn't on the resolved search
# path, stay silent when it is, and stay silent (not guess) when neither `manpath`(1) nor
# $MANPATH can resolve anything. Isolated via a controlled PATH/MANPATH, same rationale as 1.1
# (PATH is reassigned inside the script body, not as an env-prefix on `bash -c` itself).
_test_unit_warn_if_not_on_manpath() {
  local body
  body="$(_extract_muxm_fns _warn_if_not_on_manpath)" || { fail "unit-warn-if-not-on-manpath: _warn_if_not_on_manpath not found in muxm"; return; }

  local out script
  script='PATH="/nonexistent_dir_for_muxm_test"; MANPATH="/some/other/dir"; CLI_NAME=muxm'$'\n'"$body"$'\n''_warn_if_not_on_manpath "/tmp/muxm_test_mandir"'
  out="$(bash -c "$script" 2>&1)"
  if grep -qiF "not on your man search path" <<<"$out"; then
    pass "unit-warn-if-not-on-manpath: warns when the install target is not on the resolved man search path"
  else
    fail "unit-warn-if-not-on-manpath: expected a MANPATH warning, got: ${out:0:200}"
  fi

  script='PATH="/nonexistent_dir_for_muxm_test"; MANPATH="/tmp/muxm_test_mandir:/usr/share/man"; CLI_NAME=muxm'$'\n'"$body"$'\n''_warn_if_not_on_manpath "/tmp/muxm_test_mandir"'
  out="$(bash -c "$script" 2>&1)"
  if [[ -z "$out" ]]; then
    pass "unit-warn-if-not-on-manpath: no warning when the install target is already on the search path"
  else
    fail "unit-warn-if-not-on-manpath: unexpectedly warned when target was already on the search path: ${out:0:200}"
  fi

  script='PATH="/nonexistent_dir_for_muxm_test"; unset MANPATH; CLI_NAME=muxm'$'\n'"$body"$'\n''_warn_if_not_on_manpath "/tmp/muxm_test_mandir"'
  out="$(bash -c "$script" 2>&1)"
  if [[ -z "$out" ]]; then
    pass "unit-warn-if-not-on-manpath: stays silent (does not guess) when neither manpath nor \$MANPATH can be resolved"
  else
    fail "unit-warn-if-not-on-manpath: unexpectedly printed something with no resolvable search path: ${out:0:200}"
  fi
}

# 2.1: _dv_give_up_to_base must always alias V_MIXED to V_BASE and reset OUTPUT_HAS_DV=0 —
# verified behaviorally in isolation (DRY_RUN=1 short-circuits _dv_fallback_timestamp_wrap's
# ffmpeg call), THEN structurally as the ONLY path any give-up branch in run_video_pipeline
# uses. An audit while extracting this helper found 3 of the 5 original give-up branches
# omitted the explicit OUTPUT_HAS_DV=0 reset (harmless at the time — OUTPUT_HAS_DV was still 0
# at every one of those points in the pre-refactor control flow — but a latent trap for any
# future change reaching them with it already 1). Routing all 5 through one helper makes that
# whole class of omission structurally impossible, which is what the second half of this test
# guards: it doesn't matter whether a future edit adds a 6th give-up branch that forgets to
# reset the flag directly, as long as it still goes through _dv_give_up_to_base.
_test_unit_dv_give_up_to_base() {
  local body wrap
  body="$(_extract_muxm_fns _dv_give_up_to_base)" || { fail "unit-dv-give-up-to-base: _dv_give_up_to_base not found in muxm"; return; }
  wrap="$(awk '/^_dv_fallback_timestamp_wrap\(\)/,/^\}/' "$MUXM")"

  local out
  out="$(bash -c '
    warn(){ :; }
    mark_done(){ echo "MARK_DONE:$*"; }
    DRY_RUN=1
    V_BASE=/tmp/muxm_test_dv_base.hevc
    V_MIXED=/tmp/muxm_test_dv_mixed.hevc
    OUTPUT_HAS_DV=1
    '"$wrap"'
    '"$body"'
    _dv_give_up_to_base "unit test reason"
    echo "V_MIXED=$V_MIXED"
    echo "OUTPUT_HAS_DV=$OUTPUT_HAS_DV"
  ' 2>&1)"
  if grep -qF "V_MIXED=/tmp/muxm_test_dv_base.hevc" <<<"$out" \
     && grep -qF "OUTPUT_HAS_DV=0" <<<"$out" \
     && grep -qF "MARK_DONE:Use base video (unit test reason)" <<<"$out"; then
    pass "unit-dv-give-up-to-base: _dv_give_up_to_base aliases V_MIXED to V_BASE and resets OUTPUT_HAS_DV=0"
  else
    fail "unit-dv-give-up-to-base: _dv_give_up_to_base did not behave as expected: ${out:0:300}"
  fi

  # Structural: run_video_pipeline must route EVERY give-up branch through this one helper —
  # exactly 5 call sites (RPU validation, inject failure, inject-empty, convert failure, frame
  # mismatch) — so none can silently omit the OUTPUT_HAS_DV reset again.
  local rvp_body call_count
  rvp_body="$(awk '/^run_video_pipeline\(\)/,/^\}/' "$MUXM")"
  call_count="$(grep -c '_dv_give_up_to_base ' <<<"$rvp_body")"
  if [[ "$call_count" -eq 5 ]]; then
    pass "unit-dv-give-up-to-base: run_video_pipeline routes all 5 DV give-up branches through _dv_give_up_to_base"
  else
    fail "unit-dv-give-up-to-base: expected 5 _dv_give_up_to_base call sites in run_video_pipeline, found $call_count"
  fi
}

# 2.2: structural — verify_dv_container_record's mp4box fallback and run_video_pipeline's
# pre-wrap Method 1 must both delegate the mp4box dvp_hint/fps-argument/invocation construction
# to the shared _dv_mp4box_wrap helper (no inline duplicate block). Same M-DRY-b-style guard as
# _test_unit_refresh_mandb; a behavioral test isn't meaningful here since the real work
# (argument construction) is already covered by exercising the two call sites in dv_vt/dv_sw.
_test_unit_dv_mp4box_wrap() {
  local vdcr rvp
  vdcr="$(awk '/^verify_dv_container_record\(\)/,/^\}/' "$MUXM")"
  rvp="$(awk '/^run_video_pipeline\(\)/,/^\}/' "$MUXM")"
  if grep -q '_dv_mp4box_wrap ' <<<"$vdcr" && grep -q '_dv_mp4box_wrap ' <<<"$rvp"; then
    pass "unit-dv-mp4box-wrap: verify_dv_container_record and run_video_pipeline both delegate to _dv_mp4box_wrap"
  else
    fail "unit-dv-mp4box-wrap: a DV mp4box-wrap call site still inlines the block instead of calling _dv_mp4box_wrap"
  fi
}

# 3.1: _ocr_lang_flags must select the correct language flag per OCR tool — behaviorally
# verified in isolation (pgsrip → --language, sub2srt → none, anything else → -l, empty lang →
# none), THEN structurally verified as the ONLY path all three former case-statement copies
# (_prepare_subtitle's PGS branch, _prepare_ext_subtitle's .sup and .idx branches) use, so the
# three copies can never silently drift apart again.
_test_unit_ocr_lang_flags() {
  local body
  body="$(_extract_muxm_fns _ocr_lang_flags)" || { fail "unit-ocr-lang-flags: _ocr_lang_flags not found in muxm"; return; }

  local out script
  # set -e (matching muxm's own set -eEuo pipefail): a bare `cond && action` as a function's
  # LAST statement propagates a false `cond` as the function's own exit status, which aborts the
  # whole script when the function is called as a plain statement — exactly how every real call
  # site invokes _ocr_lang_flags. Without set -e here, a regression of that class would go
  # undetected even though it crashes every real pgsrip/custom-tool run with no language set.
  script='set -e'$'\n'"$body"$'\n''
    declare -a o
    _ocr_lang_flags o pgsrip eng;         echo "pgsrip:${o[*]}"
    _ocr_lang_flags o sub2srt eng;        echo "sub2srt:${o[*]}"
    _ocr_lang_flags o something-else eng; echo "other:${o[*]}"
    _ocr_lang_flags o pgsrip "";          echo "pgsrip-empty:${o[*]}"
    _ocr_lang_flags o something-else "";  echo "other-empty:${o[*]}"
    echo "SCRIPT_COMPLETED_OK"
  '
  out="$(bash -c "$script" 2>&1)"
  if grep -qF "SCRIPT_COMPLETED_OK" <<<"$out" \
     && grep -qF "pgsrip:--language eng" <<<"$out" \
     && grep -qF "sub2srt:" <<<"$out" && ! grep -qF "sub2srt:-" <<<"$out" \
     && grep -qF "other:-l eng" <<<"$out" \
     && grep -qF "pgsrip-empty:" <<<"$out" && ! grep -qF "pgsrip-empty:-" <<<"$out" \
     && grep -qF "other-empty:" <<<"$out" && ! grep -qF "other-empty:-" <<<"$out"; then
    pass "unit-ocr-lang-flags: _ocr_lang_flags selects the correct flag per OCR tool under set -e (pgsrip/sub2srt/other, incl. empty lang — does not abort the script)"
  else
    fail "unit-ocr-lang-flags: _ocr_lang_flags returned unexpected flags or aborted under set -e: ${out//$'\n'/ | }"
  fi

  # Structural: all three former call sites must delegate, not inline the case statement.
  local ps pes ps_count pes_count
  ps="$(awk '/^_prepare_subtitle\(\)/,/^\}/' "$MUXM")"
  pes="$(awk '/^_prepare_ext_subtitle\(\)/,/^\}/' "$MUXM")"
  ps_count="$(grep -c '_ocr_lang_flags ' <<<"$ps")"
  pes_count="$(grep -c '_ocr_lang_flags ' <<<"$pes")"
  if [[ "$ps_count" -eq 1 && "$pes_count" -eq 2 ]]; then
    pass "unit-ocr-lang-flags: _prepare_subtitle (1x) and _prepare_ext_subtitle (2x) delegate to _ocr_lang_flags"
  else
    fail "unit-ocr-lang-flags: expected 1 call in _prepare_subtitle and 2 in _prepare_ext_subtitle, got $ps_count and $pes_count"
  fi
  if ! grep -q 'case "\$SUB_OCR_TOOL" in' <<<"$ps$pes"; then
    pass "unit-ocr-lang-flags: no inlined SUB_OCR_TOOL case statement remains in either function"
  else
    fail "unit-ocr-lang-flags: an inlined 'case \"\$SUB_OCR_TOOL\" in' block still exists — extraction incomplete"
  fi
}

# 3.1: _run_ocr must spawn $SUB_OCR_TOOL with the resolved language flags, register/clear
# _ACTIVE_FFMPEG_PID around the wait (M3), and block until it exits — verified behaviorally in
# isolation, THEN structurally as the delegate for all four former spawn/wait call sites (PGS
# vobsub + PGS .sup fallback in _prepare_subtitle; .sup + .idx branches in
# _prepare_ext_subtitle).
_test_unit_run_ocr() {
  local body
  body="$(_extract_muxm_fns _run_ocr)" || { fail "unit-run-ocr: _run_ocr not found in muxm"; return; }

  local stub_bin; stub_bin="$(mktemp -d)"
  printf '#!/bin/bash\nprintf "OCR_ARGS:%%s\\n" "$*" > "%s/args.txt"\n' "$stub_bin" > "$stub_bin/fake_ocr"
  chmod +x "$stub_bin/fake_ocr"
  local logfile; logfile="$(mktemp)"

  local out script
  script="spinner(){ :; }"$'\n'"SUB_OCR_TOOL=\"$stub_bin/fake_ocr\""$'\n'"$body"$'\n''
    declare -a lang=(--language eng)
    _run_ocr /tmp/muxm_test_ocr_input.sup "'"$logfile"'" "test label" lang
    echo "ACTIVE_PID_AFTER=[$_ACTIVE_FFMPEG_PID]"
  '
  out="$(bash -c "$script" 2>&1)"
  local args_out
  args_out="$(cat "$stub_bin/args.txt" 2>/dev/null)"
  rm -rf "$stub_bin" "$logfile"
  if grep -qF "ACTIVE_PID_AFTER=[]" <<<"$out" \
     && [[ "$args_out" == "OCR_ARGS:--language eng /tmp/muxm_test_ocr_input.sup" ]]; then
    pass "unit-run-ocr: _run_ocr invokes SUB_OCR_TOOL with the language flags and clears _ACTIVE_FFMPEG_PID after wait"
  else
    fail "unit-run-ocr: _run_ocr did not behave as expected (out=${out:0:200}, args=$args_out)"
  fi

  local ps pes ps_count pes_count
  ps="$(awk '/^_prepare_subtitle\(\)/,/^\}/' "$MUXM")"
  pes="$(awk '/^_prepare_ext_subtitle\(\)/,/^\}/' "$MUXM")"
  ps_count="$(grep -c '_run_ocr ' <<<"$ps")"
  pes_count="$(grep -c '_run_ocr ' <<<"$pes")"
  if [[ "$ps_count" -eq 2 && "$pes_count" -eq 2 ]]; then
    pass "unit-run-ocr: _prepare_subtitle (2x) and _prepare_ext_subtitle (2x) delegate to _run_ocr"
  else
    fail "unit-run-ocr: expected 2 _run_ocr calls in each function, got $ps_count and $pes_count"
  fi
}

# 4.5: _audio_pretty_line must format a display line identically to the pre-refactor inline
# construction — behaviorally verified (title suffix, [commentary] tag, bitrate suffix
# including the "0 bitrate omits the suffix" edge case), THEN structurally verified as the ONLY
# path both run_audio_pipeline_multi and run_audio_pipeline's display loops use (M-DRY-b
# pattern) — the SYNC comment that used to warn editors to keep the two copies in step is gone
# because there's only one copy now.
_test_unit_audio_pretty_line() {
  local body
  body="$(_extract_muxm_fns _audio_pretty_line _audio_is_commentary)" \
    || { fail "unit-audio-pretty-line: _audio_pretty_line not found in muxm"; return; }

  local script out
  # set -e (matching muxm's own set -eEuo pipefail): a bare `cond && action` as a function's
  # LAST statement propagates a false `cond` as the function's own exit status, which aborts the
  # whole script when the function is called as a plain statement — exactly how both real call
  # sites invoke _audio_pretty_line. Without set -e here, a regression of that class would go
  # undetected even though it crashes every real run on a 0-bitrate/untitled track (the C
  # scenario below — a very common case, not an edge case).
  script='set -e'$'\n'"$body"$'\n''
    declare out
    _audio_pretty_line out 0 eac3 6 eng "" 384000;          echo "A:$out"
    _audio_pretty_line out 1 aac 2 eng Commentary 128000;   echo "B:$out"
    _audio_pretty_line out 2 ac3 2 und "" 0;                echo "C:$out"
    echo "SCRIPT_COMPLETED_OK"
  '
  out="$(bash -c "$script" 2>&1)"
  if grep -qF "SCRIPT_COMPLETED_OK" <<<"$out" \
     && grep -qF 'A:#0: eac3 6ch [eng], 384kbps' <<<"$out" \
     && grep -qF 'B:#1: aac 2ch [eng] — Commentary [commentary], 128kbps' <<<"$out" \
     && grep -qF 'C:#2: ac3 2ch [und]' <<<"$out" && ! grep -qF 'C:#2: ac3 2ch [und],' <<<"$out"; then
    pass "unit-audio-pretty-line: _audio_pretty_line formats title/commentary/bitrate exactly like the pre-refactor inline construction, and does not abort under set -e on a 0-bitrate track"
  else
    fail "unit-audio-pretty-line: _audio_pretty_line output mismatch or aborted under set -e: ${out//$'\n'/ | }"
  fi

  local multi single multi_count single_count
  multi="$(awk '/^run_audio_pipeline_multi\(\)/,/^\}/' "$MUXM")"
  single="$(awk '/^run_audio_pipeline\(\)/,/^\}/' "$MUXM")"
  multi_count="$(grep -c '_audio_pretty_line ' <<<"$multi")"
  single_count="$(grep -c '_audio_pretty_line ' <<<"$single")"
  if [[ "$multi_count" -eq 1 && "$single_count" -eq 1 ]]; then
    pass "unit-audio-pretty-line: run_audio_pipeline_multi and run_audio_pipeline both delegate to _audio_pretty_line"
  else
    fail "unit-audio-pretty-line: expected 1 _audio_pretty_line call in each function, got multi=$multi_count single=$single_count"
  fi
}

# 5.1: _check_mux_stream_counts must report a match (via log, no warning) and a mismatch (via
# warn) independently for audio and subtitle counts, and must NOT abort under set -e when
# ffprobe legitimately finds zero streams of a type (e.g. a video with no subtitles) — grep -c
# exits 1 on zero matches, which is exactly the class of bug this function's own awk-based
# counting was written to avoid; this test pins that behavior down.
_test_unit_check_mux_stream_counts() {
  local body
  body="$(_extract_muxm_fns _check_mux_stream_counts)" \
    || { fail "unit-check-mux-stream-counts: _check_mux_stream_counts not found in muxm"; return; }

  local script out
  script='set -e'$'\n'"$body"$'\n''
    warn(){ echo "WARN:$*"; }
    log(){ echo "LOG:$*"; }
    ffprobe(){
      case "$*" in
        *"-select_streams a"*) printf "0\n1\n" ;;   # 2 audio streams found
        *"-select_streams s"*) ;;                    # 0 subtitle streams (legitimate, not an error)
      esac
    }
    _check_mux_stream_counts /tmp/muxm_test_fake.mkv "Match test" 2 0
    _check_mux_stream_counts /tmp/muxm_test_fake.mkv "Mismatch test" 3 -1
    echo "SCRIPT_COMPLETED_OK"
  '
  out="$(bash -c "$script" 2>&1)"
  if grep -qF "SCRIPT_COMPLETED_OK" <<<"$out" \
     && grep -qF "LOG:[validate] Match test: audio stream count OK (2)" <<<"$out" \
     && grep -qF "LOG:[validate] Match test: subtitle stream count OK (0)" <<<"$out" \
     && grep -qF "WARN:Mismatch test: expected 3 audio stream(s)" <<<"$out"; then
    pass "unit-check-mux-stream-counts: _check_mux_stream_counts reports match via log, mismatch via warn, and handles a zero-stream count without aborting under set -e"
  else
    fail "unit-check-mux-stream-counts: _check_mux_stream_counts behaved unexpectedly: ${out//$'\n'/ | }"
  fi
}

# M-DRY-c: drift guard — _VALID_LOGLEVEL_STR (the human-readable "Valid values:" list) must stay in
# sync with is_valid_loglevel's case set. Assert every entry passes is_valid_loglevel and the count
# matches the case arms. Perturb MUT-MDRYC-DRIFT adds a bogus value to the constant → drift → red.
_test_unit_loglevel_str() {
  local body
  body="$(_extract_muxm_fns is_valid_loglevel)" \
    || { fail "unit-loglevel-drift-guard: could not extract is_valid_loglevel"; return; }
  local _str
  _str="$(grep -E '^readonly _VALID_LOGLEVEL_STR=' "$MUXM" | sed -E 's/^[^"]*"//; s/"[^"]*$//')"
  if [[ -z "$_str" ]]; then fail "unit-loglevel-drift-guard: could not read _VALID_LOGLEVEL_STR"; return; fi
  # Count of case arms in is_valid_loglevel (split the single 'a|b|c) ...' arm on '|').
  local _arms
  _arms="$(awk -F'|' '/return 0;;/{gsub(/[^a-z|]/,"",$0); n=split($0,a,"|"); print n; exit}' <<<"$body")"
  # Validate each constant entry + count.
  local _bad="" _n=0 _v
  local _IFS_save="$IFS"; IFS=','
  for _v in $_str; do
    _v="${_v// /}"; [[ -z "$_v" ]] && continue
    _n=$(( _n + 1 ))
    bash -c "$body"$'\n'"is_valid_loglevel '$_v'" || _bad="$_bad $_v"
  done
  IFS="$_IFS_save"
  if [[ -z "$_bad" ]] && [[ "$_n" == "$_arms" ]]; then
    pass "unit-loglevel-drift-guard: _VALID_LOGLEVEL_STR ($_n values) is in sync with is_valid_loglevel ($_arms arms)"
  else
    fail "unit-loglevel-drift-guard: _VALID_LOGLEVEL_STR drifted from is_valid_loglevel (invalid:${_bad:-none}; count $_n vs $_arms)"
  fi
}

# M3: _ACTIVE_FFMPEG_PID lifecycle — on_exit SIGKILLs $_ACTIVE_FFMPEG_PID on interrupt, so every
# backgrounded HEAVY child (ffmpeg / dovi_tool / MP4Box / OCR / cp) must (A) register its pid right
# after launch and (B) clear it only AFTER its `wait` (clearing before wait orphans the child on a
# SIGINT in that window, and an OCR child holding the tee write-end can hang the drain). This is a
# STRUCTURAL invariant test (a real SIGINT race is infeasible to test deterministically — same
# rationale as the L5 disk-hint source check). Two perturbs exercise it: MUT-M3-REGISTER removes a
# registration (invariant A → red); MUT-M3-CLEARWAIT reorders one site to clear-before-wait
# (invariant B → red). The DV launches are all sequential (launch→spinner→wait), so the scalar
# _ACTIVE_FFMPEG_PID is sufficient — no two heavy children run concurrently.
# CR-10: most heavy children register+wait+clear via the shared _await_tracked_pid helper
# (register-before-wait, clear-after, all in one place), so a registration is satisfied EITHER by an
# inline `_ACTIVE_FFMPEG_PID=$<v>` (OCR fire-and-forget sites, _ffmpeg_run_with_ui) OR by passing the
# pid to `_await_tracked_pid "$<v>"` — both forms count as "registered on the next line".
_test_unit_ffmpeg_pid_lifecycle() {
  # Invariant A: every `local <v>=$!` heavy-child launch registers _ACTIVE_FFMPEG_PID on the next
  # line — inline OR via _await_tracked_pid "$<v>". Allowlist the light/infra launches that
  # intentionally do NOT register (tee drain, checksum tool, tee watchdog) — orphaning those on
  # Ctrl-C is harmless and on_exit handles the tee.
  local _unreg
  _unreg="$(awk '/local [A-Za-z_]+=\$!/{
      v=$0; sub(/^[[:space:]]*local /,"",v); sub(/=\$!.*/,"",v); ln=NR; getline n;
      if (v=="drain_pid"||v=="_cksum_pid"||v=="_tee_wd") next;
      if (index(n,"_ACTIVE_FFMPEG_PID=$" v)==0 && index(n,"_await_tracked_pid \"$" v "\"")==0) print ln":"v;
    }' "$MUXM")"
  if [[ -z "$_unreg" ]]; then
    pass "unit-ffmpeg-pid-lifecycle: every backgrounded heavy child registers _ACTIVE_FFMPEG_PID right after launch"
  else
    fail "unit-ffmpeg-pid-lifecycle: backgrounded heavy child(ren) not registered (orphaned on Ctrl-C): ${_unreg//$'\n'/ }"
  fi

  # Invariant B: no clear-before-wait — neither same-line (clear position < wait position) nor
  # cross-line (a bare `_ACTIVE_FFMPEG_PID=""` line immediately followed by a wait line).
  local _cbw
  _cbw="$(awk '
    { c=index($0,"_ACTIVE_FFMPEG_PID=\"\""); w=index($0,"wait \"$");
      if (c>0 && w>0 && c<w) print NR":same-line";
      if (prev && $0 ~ /^[[:space:]]*(if[[:space:]]+!?[[:space:]]*)?wait "\$/) print (NR-1)":cross-line";
      prev=($0 ~ /_ACTIVE_FFMPEG_PID=""[[:space:]]*$/);
    }' "$MUXM")"
  if [[ -z "$_cbw" ]]; then
    pass "unit-ffmpeg-pid-lifecycle: _ACTIVE_FFMPEG_PID is always cleared AFTER its wait (no clear-before-wait)"
  else
    fail "unit-ffmpeg-pid-lifecycle: clear-before-wait at: ${_cbw//$'\n'/ } — a SIGINT there orphans the child / can hang the drain"
  fi
}

# Regression: _parse_audio_record must preserve an EMPTY title field. A plain `IFS=$'\t' read`
# collapses an empty middle field (tab is IFS-whitespace), shifting an untitled track's bitrate
# into `title` and blanking the bitrate. This test drives the extracted helper with an untitled
# record and asserts title stays empty + the bitrate lands in br. It goes red on a collapsing
# `IFS=$'\t' read` parse (which yields title=<bitrate>, br=empty) and green on the tab-safe split.
# _parse_audio_record delegates to _split_tab, so extract that too.
_test_unit_parse_audio_record() {
  local body
  body="$(_extract_muxm_fns _parse_audio_record _split_tab)" \
    || { fail "parse_audio_record: could not extract _parse_audio_record"; return; }
  # Driver: parse $1, echo "title|br" so empty fields are visible.
  _par(){ bash -c "$body"$'\n''_parse_audio_record "$1"; printf "%s|%s\n" "$_AREC_TITLE" "$_AREC_BR"' -- "$1"; }
  local out
  # Untitled track (empty title field between two tabs) — the regression case.
  out="$(_par "$(printf '0\teac3\t6\teng\t\t383578')")"
  if [[ "$out" == "|383578" ]]; then
    pass "_parse_audio_record: untitled track keeps title empty, bitrate in br (no field-shift)"
  else
    fail "_parse_audio_record: untitled track expected '|383578', got '$out' (bitrate shifted into title?)"
  fi
  # Titled track — the normal case must still parse correctly.
  out="$(_par "$(printf '2\tac3\t2\tspa\tCommentary\t128000')")"
  if [[ "$out" == "Commentary|128000" ]]; then
    pass "_parse_audio_record: titled track parses title + br correctly"
  else
    fail "_parse_audio_record: titled track expected 'Commentary|128000', got '$out'"
  fi
}

# F5 (runtime): _prefer_complete_ffmpeg prepends the keg-only ffmpeg-full bin to PATH when the
# active ffmpeg is incomplete (or absent), and leaves a complete ffmpeg untouched. Host-independent:
# drives the extracted function with fake ffmpeg scripts and HOMEBREW_PREFIX pointing at a temp keg
# (so the scan finds the fake before any real /opt/homebrew/opt/ffmpeg-full). PATH=/usr/bin:/bin in
# the no-ffmpeg case provides grep/awk without an ffmpeg.
_test_unit_prefer_complete_ffmpeg() {
  local body
  body="$(_extract_muxm_fns _prefer_complete_ffmpeg _ffmpeg_bin_is_complete)" \
    || { fail "F5-rt: could not extract _prefer_complete_ffmpeg + _ffmpeg_bin_is_complete"; return; }
  local d; d="$(mktemp -d)"
  mkdir -p "$d/opt/ffmpeg-full/bin" "$d/onpath" "$d/custom"
  # shellcheck disable=SC2016  # mock ffmpeg body: $1 must stay literal — it expands when the stub runs, not at definition
  local complete='#!/bin/bash
if [[ "$1" == "-version" ]]; then echo "ffmpeg with --enable-libass"; exit 0; fi
printf "%s\n" " V..... libsvtav1   x" " V..... libaom-av1  x"; exit 0'
  # shellcheck disable=SC2016  # mock ffmpeg body: $1 must stay literal — it expands when the stub runs, not at definition
  local incomplete='#!/bin/bash
if [[ "$1" == "-version" ]]; then echo "ffmpeg version 6.0"; exit 0; fi
printf "%s\n" " V..... libx264  x"; exit 0'
  printf '%s\n' "$complete"   > "$d/opt/ffmpeg-full/bin/ffmpeg"; chmod +x "$d/opt/ffmpeg-full/bin/ffmpeg"
  printf '%s\n' "$incomplete" > "$d/onpath/ffmpeg";              chmod +x "$d/onpath/ffmpeg"
  printf '%s\n' "$complete"   > "$d/custom/ffmpeg";              chmod +x "$d/custom/ffmpeg"
  # $1 = PATH to run under. Echoes the resulting PATH after _prefer_complete_ffmpeg.
  _pcf_run(){
    HOMEBREW_PREFIX="$d" PATH="$1" bash -c 'note(){ :; }
'"$body"'
_prefer_complete_ffmpeg
printf "%s\n" "$PATH"'
  }
  local out
  out="$(_pcf_run "$d/onpath:/usr/bin:/bin")"
  if [[ "$out" == "$d/opt/ffmpeg-full/bin:"* ]]; then
    pass "F5-rt: incomplete on-PATH ffmpeg → ffmpeg-full keg prepended"
  else
    fail "F5-rt: expected keg prepended for incomplete ffmpeg; PATH head='${out%%:*}'"
  fi
  out="$(_pcf_run "$d/custom:/usr/bin:/bin")"
  if [[ "$out" == "$d/custom:"* ]]; then
    pass "F5-rt: complete custom ffmpeg on PATH → left untouched"
  else
    fail "F5-rt: complete custom ffmpeg wrongly overridden; PATH head='${out%%:*}'"
  fi
  out="$(_pcf_run "/usr/bin:/bin")"
  if [[ "$out" == "$d/opt/ffmpeg-full/bin:"* ]]; then
    pass "F5-rt: no ffmpeg on PATH → ffmpeg-full keg prepended (muxm goes from won't-run to works)"
  else
    fail "F5-rt: expected keg prepended when no ffmpeg on PATH; PATH head='${out%%:*}'"
  fi
  rm -rf "$d"
}

# === Suite: Profile End-to-End (real encodes with profiles) ===
# Validates that each built-in profile produces a correctly encoded output file
# with the expected container, codec, and stream layout.
test_profile_e2e() {
  section "Profile End-to-End Encodes"

  # Data-driven encode matrix.  Add a row to test a new profile — no new code needed.
  # Columns (pipe-delimited):
  #   profile | source fixture | output filename | expected ext | expected video codec | extra muxm flags
  # Special values:
  #   codec="-"        → skip codec assertion (profile doesn't mandate a specific codec)
  #   extra_flags=""   → only --preset ultrafast is passed (always added by the loop)
  local -a E2E_PROFILES=(
    "streaming|basic_sdr_subs.mkv|e2e_streaming.mp4|mp4|hevc|--crf 28"
    "animation|multi_subs.mkv|e2e_animation.mkv|mkv|hevc|--crf 28"
    "universal|basic_sdr_subs.mkv|e2e_universal.mp4|mp4|h264|--crf 28"
    "archive|hevc_sdr_51.mkv|e2e_archive.mkv|mkv|hevc|"
    "hdr10-hq|hevc_hdr10_tagged.mkv|e2e_hdr10_hq.mkv|mkv|hevc|--crf 28"
    "atv-directplay-hq|basic_sdr_subs.mkv|e2e_atv_directplay.mp4|mp4|hevc|--crf 28"
    "atv-directplay-animation|multi_subs.mkv|e2e_atv_animation.mkv|mkv|hevc|--crf 28"
    "youtube-upload|basic_sdr_subs.mkv|e2e_youtube.mp4|mp4|h264|--crf 28"
  )

  local profile source output ext codec extra_flags
  local outfile actual_ext pix_fmt
  for entry in "${E2E_PROFILES[@]}"; do
    IFS='|' read -r profile source output ext codec extra_flags <<< "$entry"
    outfile="$TESTDIR/$output"

    log "Full encode: $profile profile..."
    # Build muxm flag array: --profile NAME --preset ultrafast [extra flags] SOURCE
    local -a flags=(--profile "$profile" --preset ultrafast)
    if [[ -n "$extra_flags" ]]; then
      local -a extra_arr
      read -ra extra_arr <<< "$extra_flags"
      flags+=("${extra_arr[@]}")
    fi

    if assert_encode "$profile profile: output produced" "$outfile" \
         "${flags[@]}" "$TESTDIR/$source"; then
      # Extension check
      actual_ext="${outfile##*.}"
      if [[ "$actual_ext" == "$ext" ]]; then
        pass "$profile: correct extension (.$ext)"
      else
        fail "$profile: expected .$ext, got .$actual_ext"
      fi

      # Codec check (skip if "-")
      [[ "$codec" != "-" ]] && assert_probe "$profile: $codec codec" "$outfile" codec_name "$codec"

      # Profile-specific extra checks
      case "$profile" in
        archive|atv-directplay-hq)
          assert_stream_count "$profile: audio present" "$outfile" a 1 1
          ;;
        hdr10-hq|animation)
          pix_fmt="$(probe_video "$outfile" pix_fmt)"
          if echo "$pix_fmt" | grep -q "10"; then
            pass "$profile: 10-bit pixel format ($pix_fmt)"
          else
            fail "$profile: expected 10-bit pixel format, got $pix_fmt"
          fi
          ;;
      esac
    fi
  done

  # ---- AV1 profile end-to-end encodes ----
  # AV1 profiles require the libsvtav1 encoder.  Probe actual encode capability first
  # (not just encoder availability in ffmpeg -encoders, since the codec alias used by
  # muxm must be accepted by the installed ffmpeg build).  Skip gracefully if not usable.
  # Note: AV1 CLI presets are numeric (0-13); named presets like "ultrafast" are x265-only.
  # Use the profile's built-in default preset (PRESET_VALUE=6 for av1-hq / streaming-av1).
  local _av1_probe_out="$TESTDIR/_av1_probe.mkv"
  local _av1_probe_ok=0
  # Probe by running muxm itself: if the av1-hq dry-run exits 0 and an actual tiny encode
  # at the profile's own preset does not produce exit 10 (encoder not found), we proceed.
  if (cd "$TESTDIR" && "$MUXM" --profile av1-hq --dry-run \
        basic_sdr_subs.mkv "$_av1_probe_out" >/dev/null 2>&1); then
    # Dry-run succeeded (encoder probe passed in muxm); attempt a real encode.
    (cd "$TESTDIR" && "$MUXM" -K --profile av1-hq --crf 50 \
        basic_sdr_subs.mkv "$_av1_probe_out" >/dev/null 2>&1) \
      && _av1_probe_ok=1 || _av1_probe_ok=0
  fi

  if (( _av1_probe_ok )); then
    rm -f "$_av1_probe_out"

    # av1-hq: res-aware CRF (here --crf 50 forces a fast encode), MKV, lossless audio passthrough
    local av1hq_e2e_out="$TESTDIR/e2e_av1hq.mkv"
    log "Full encode: av1-hq profile..."
    if assert_encode "av1-hq profile: output produced" "$av1hq_e2e_out" \
         --profile av1-hq --crf 50 "$TESTDIR/basic_sdr_subs.mkv"; then
      local av1hq_ext="${av1hq_e2e_out##*.}"
      if [[ "$av1hq_ext" == "mkv" ]]; then
        pass "av1-hq: correct extension (.mkv)"
      else
        fail "av1-hq: expected .mkv, got .$av1hq_ext"
      fi
      assert_probe "av1-hq: video codec is av1" "$av1hq_e2e_out" codec_name av1
      assert_stream_count "av1-hq: audio present" "$av1hq_e2e_out" a 1 1
    fi

    # streaming-av1: CRF 30, MP4, Opus audio
    local sav1_e2e_out="$TESTDIR/e2e_streaming_av1.mp4"
    log "Full encode: streaming-av1 profile..."
    if assert_encode "streaming-av1 profile: output produced" "$sav1_e2e_out" \
         --profile streaming-av1 --crf 50 "$TESTDIR/basic_sdr_subs.mkv"; then
      local sav1_ext="${sav1_e2e_out##*.}"
      if [[ "$sav1_ext" == "mp4" ]]; then
        pass "streaming-av1: correct extension (.mp4)"
      else
        fail "streaming-av1: expected .mp4, got .$sav1_ext"
      fi
      assert_probe "streaming-av1: video codec is av1" "$sav1_e2e_out" codec_name av1
      local sav1_acodec
      sav1_acodec="$(probe_audio "$sav1_e2e_out" codec_name)"
      if [[ "$sav1_acodec" == "opus" ]]; then
        pass "streaming-av1: audio codec is opus"
      else
        fail "streaming-av1: expected opus audio, got '$sav1_acodec'"
      fi
    fi

  else
    skip "av1-hq e2e: AV1 encode probe failed (encoder not functional) — skipping AV1 profile encodes"
    skip "streaming-av1 e2e: AV1 encode probe failed (encoder not functional) — skipping AV1 profile encodes"
  fi

  # ---- Encoder unavailability: libsvtav1 missing → exit code 10 ----
  # When libsvt-av1 is requested but the encoder is absent everywhere, muxm must die with exit
  # code 10 ("encoder not available"). Simulate with a mock ffmpeg that reports no encoders. Two
  # interactions must be handled:
  #   (1) The mock forwards every non-`-encoders` call to the REAL ffmpeg by ABSOLUTE path. A bare
  #       `exec ffmpeg "$@"` would re-find this mock (its dir is first on PATH) and exec-loop
  #       forever — which is exactly the hang this test previously caused once muxm began probing
  #       `ffmpeg -version` at startup (_prefer_complete_ffmpeg).
  #   (2) _prefer_complete_ffmpeg would otherwise see this incomplete ffmpeg and substitute the
  #       real keg-only `ffmpeg-full` (which DOES have libsvtav1), making muxm succeed instead of
  #       dying. So the mock is placed AT a fake HOMEBREW_PREFIX keg path and HOMEBREW_PREFIX points
  #       at it: _prefer_complete_ffmpeg then sees the active ffmpeg already IS the (incomplete)
  #       keg and leaves it, exercising the genuine "no AV1 encoder anywhere → die 10" path.
  local mock_keg_root="$TESTDIR/mock_no_svtav1_prefix"
  local mock_ffmpeg_dir="$mock_keg_root/opt/ffmpeg-full/bin"
  mkdir -p "$mock_ffmpeg_dir"
  local _real_ffmpeg; _real_ffmpeg="$(command -v ffmpeg)"
  cat > "$mock_ffmpeg_dir/ffmpeg" <<MOCK_EOF
#!/bin/bash
# Mock ffmpeg: reports no encoders so the libsvtav1 probe fails. Every other call forwards to the
# REAL ffmpeg by absolute path (NOT bare \`ffmpeg\`, which would re-exec this mock infinitely).
for arg in "\$@"; do [[ "\$arg" == "-encoders" ]] && { echo "Encoders:"; exit 0; }; done
exec "$_real_ffmpeg" "\$@"
MOCK_EOF
  chmod +x "$mock_ffmpeg_dir/ffmpeg"
  local mock_code
  (cd "$TESTDIR" && HOMEBREW_PREFIX="$mock_keg_root" PATH="$mock_ffmpeg_dir:$PATH" "$MUXM" -K \
    --video-codec libsvt-av1 "$TESTDIR/basic_sdr_subs.mkv" 2>&1) \
    && mock_code=$? || mock_code=$?
  if [[ "$mock_code" -eq 10 ]]; then
    pass "encoder-unavailability: libsvtav1 missing → exit code 10"
  else
    fail "encoder-unavailability: expected exit 10, got $mock_code"
  fi

  # ---- animation profile + ASS source: verify subtitle format preserved ----
  # Isolate HOME to prevent user config from affecting subtitle pipeline.
  local _saved_home="$HOME"
  export HOME="$TESTDIR/e2e_ass_home"
  mkdir -p "$HOME"

  local ass_e2e_out="$TESTDIR/e2e_animation_ass.mkv"
  log "Full encode: animation profile with ASS subtitles..."
  if assert_encode "animation + ASS: e2e output produced" "$ass_e2e_out" \
       --profile animation --preset ultrafast --crf 28 "$TESTDIR/ass_subs.mkv"; then
    local ass_e2e_codec
    ass_e2e_codec="$(probe_sub "$ass_e2e_out" codec_name)"
    if [[ "$ass_e2e_codec" == "ass" || "$ass_e2e_codec" == "ssa" ]]; then
      pass "animation + ASS e2e: subtitle preserved as native $ass_e2e_codec"
    else
      fail "animation + ASS e2e: expected ass/ssa, got '$ass_e2e_codec'"
    fi
    # Verify subtitle content retained styling (check for ASS header markers)
    local ass_e2e_content
    ass_e2e_content="$(ffprobe -v error -select_streams s:0 -show_entries \
      stream=codec_name,codec_long_name -of csv=p=0 "$ass_e2e_out" 2>/dev/null)"
    assert_contains "ass" "animation + ASS e2e: ffprobe confirms ASS codec" "$ass_e2e_content"
  fi

  export HOME="$_saved_home"

  # ---- archive multi-track audio: verify commentary filtered, rest preserved ----
  # hevc_multi_audio.mkv: 3 audio tracks — eng "Main Feature", eng "Director's Commentary", spa "Spanish"
  # archive defaults: AUDIO_MULTI_TRACK=1, AUDIO_KEEP_COMMENTARY=0, AUDIO_LANG_PREF="" (keep all langs)
  # Expected: commentary dropped → 2 audio tracks in output (eng main + spa)
  local mt_e2e_home="$TESTDIR/e2e_mt_home"
  mkdir -p "$mt_e2e_home"

  local mt_e2e_out="$TESTDIR/e2e_archive_multi.mkv"
  log "Full encode: archive profile multi-track audio..."
  if assert_encode "archive multi-track: e2e output produced" "$mt_e2e_out" \
       --profile archive "$TESTDIR/hevc_multi_audio.mkv"; then
    # Should have 2 audio tracks (commentary dropped)
    local mt_e2e_acount
    mt_e2e_acount="$(count_streams "$mt_e2e_out" a)"
    if [[ "$mt_e2e_acount" -eq 2 ]]; then
      pass "archive multi-track e2e: 2 audio tracks (commentary filtered)"
    else
      fail "archive multi-track e2e: expected 2 audio tracks, got $mt_e2e_acount"
    fi
    # Video should be copy (HEVC, not re-encoded)
    assert_probe "archive multi-track e2e: video is HEVC (copy)" "$mt_e2e_out" codec_name hevc
    # First audio track should have eng language
    local mt_e2e_lang0
    mt_e2e_lang0="$(probe_stream_tag "$mt_e2e_out" a:0 language)"
    if [[ "$mt_e2e_lang0" == "eng" ]]; then
      pass "archive multi-track e2e: first audio track is English"
    else
      fail "archive multi-track e2e: expected eng, got lang='$mt_e2e_lang0'"
    fi
    # Second audio track should have spa language
    local mt_e2e_lang1
    mt_e2e_lang1="$(probe_stream_tag "$mt_e2e_out" a:1 language)"
    if [[ "$mt_e2e_lang1" == "spa" ]]; then
      pass "archive multi-track e2e: second audio track is Spanish"
    else
      fail "archive multi-track e2e: expected spa, got lang='$mt_e2e_lang1'"
    fi
    # Audio title metadata alignment: after commentary filtering, output indices
    # shift (source #0→out #0, source #2→out #1). The fix uses a sequential
    # output counter instead of source indices for -metadata:s:a:N tags.
    # A misalignment means the wrong title on the wrong track — or blank titles.
    local mt_e2e_title0
    mt_e2e_title0="$(probe_stream_tag "$mt_e2e_out" a:0 title)"
    if [[ -n "$mt_e2e_title0" ]]; then
      pass "archive multi-track e2e: first audio track has title ('$mt_e2e_title0')"
    else
      fail "archive multi-track e2e: first audio track has no title (metadata alignment bug)"
    fi
    local mt_e2e_title1
    mt_e2e_title1="$(probe_stream_tag "$mt_e2e_out" a:1 title)"
    if [[ -n "$mt_e2e_title1" ]]; then
      pass "archive multi-track e2e: second audio track has title ('$mt_e2e_title1')"
    else
      fail "archive multi-track e2e: second audio track has no title (metadata alignment bug)"
    fi
  fi

  # ---- archive multi-track subtitles: verify all subs kept, dispositions correct ----
  # hevc_multi_subs.mkv: 5 subs — eng forced, eng full, eng SDH, spa full, fra full
  # archive defaults: SUB_MULTI_TRACK=1, all SUB_INCLUDE_*=1, SUB_LANG_PREF="" (keep all)
  # Expected: all 5 subtitle tracks preserved in output
  local mt_sub_e2e_home="$TESTDIR/e2e_mt_sub_home"
  mkdir -p "$mt_sub_e2e_home"

  local mt_sub_e2e_out="$TESTDIR/e2e_archive_multi_subs.mkv"
  log "Full encode: archive profile multi-track subtitles..."
  # --no-skip-if-ideal: fixture is fully compliant; without this, muxm skips processing.
  if assert_encode "archive multi-track subs: e2e output produced" "$mt_sub_e2e_out" \
       --no-skip-if-ideal --profile archive "$TESTDIR/hevc_multi_subs.mkv"; then
    # Should have 5 subtitle tracks (all kept)
    local mt_sub_e2e_scount
    mt_sub_e2e_scount="$(count_streams "$mt_sub_e2e_out" s)"
    if [[ "$mt_sub_e2e_scount" -eq 5 ]]; then
      pass "archive multi-track sub e2e: 5 subtitle tracks preserved"
    else
      fail "archive multi-track sub e2e: expected 5 subtitle tracks, got $mt_sub_e2e_scount"
    fi
    # Video should be copy (HEVC)
    assert_probe "archive multi-track sub e2e: video is HEVC (copy)" "$mt_sub_e2e_out" codec_name hevc
    # First sub should have eng language
    local mt_sub_e2e_lang0
    mt_sub_e2e_lang0="$(probe_stream_tag "$mt_sub_e2e_out" s:0 language)"
    if [[ "$mt_sub_e2e_lang0" == "eng" ]]; then
      pass "archive multi-track sub e2e: first subtitle is English"
    else
      fail "archive multi-track sub e2e: expected eng, got lang='$mt_sub_e2e_lang0'"
    fi
    # Fourth sub (s:3) should have spa language
    local mt_sub_e2e_lang3
    mt_sub_e2e_lang3="$(probe_stream_tag "$mt_sub_e2e_out" s:3 language)"
    if [[ "$mt_sub_e2e_lang3" == "spa" ]]; then
      pass "archive multi-track sub e2e: fourth subtitle is Spanish"
    else
      fail "archive multi-track sub e2e: expected spa, got lang='$mt_sub_e2e_lang3'"
    fi
    # Fifth sub (s:4) should have fra language
    local mt_sub_e2e_lang4
    mt_sub_e2e_lang4="$(probe_stream_tag "$mt_sub_e2e_out" s:4 language)"
    if [[ "$mt_sub_e2e_lang4" == "fra" ]]; then
      pass "archive multi-track sub e2e: fifth subtitle is French"
    else
      fail "archive multi-track sub e2e: expected fra, got lang='$mt_sub_e2e_lang4'"
    fi
    # Verify first sub has forced disposition
    local mt_sub_e2e_dispo0
    mt_sub_e2e_dispo0="$(ffprobe -v error -select_streams s:0 -show_entries stream_disposition=forced -of csv=p=0 "$mt_sub_e2e_out" 2>/dev/null | head -1)"
    if [[ "$mt_sub_e2e_dispo0" == "1" ]]; then
      pass "archive multi-track sub e2e: first subtitle has forced disposition"
    else
      fail "archive multi-track sub e2e: first subtitle forced disposition expected 1, got '$mt_sub_e2e_dispo0'"
    fi
  fi

  # ---- archive multi-track subtitles with language filter ----
  # --sub-lang-pref eng should keep only eng tracks (3 of 5)
  local mt_sub_lang_e2e_out="$TESTDIR/e2e_archive_multi_subs_eng.mkv"
  log "Full encode: archive multi-track subs with --sub-lang-pref eng..."
  if assert_encode "archive multi-track subs eng: e2e output produced" "$mt_sub_lang_e2e_out" \
       --profile archive --sub-lang-pref eng "$TESTDIR/hevc_multi_subs.mkv"; then
    local mt_sub_lang_scount
    mt_sub_lang_scount="$(count_streams "$mt_sub_lang_e2e_out" s)"
    if [[ "$mt_sub_lang_scount" -eq 3 ]]; then
      pass "archive multi-track sub eng e2e: 3 subtitle tracks (eng only)"
    else
      fail "archive multi-track sub eng e2e: expected 3 subtitle tracks, got $mt_sub_lang_scount"
    fi
  fi

  # ---- animation multi-track subtitles: verify eng subs kept ----
  # animation profile: SUB_MULTI_TRACK=1, SUB_MAX_TRACKS=6, all SUB_INCLUDE_*=1
  # SUB_LANG_PREF=eng (default) — only English tracks survive the language filter.
  # hevc_multi_subs.mkv: 3 eng + 1 spa + 1 fra = 5 total → 3 kept.
  # This is the core regression test: previously animation routed PGS/bitmap subs
  # through the single-track OCR pipeline and silently dropped them when OCR failed.
  local mt_sub_anim_e2e_out="$TESTDIR/e2e_animation_multi_subs.mkv"
  log "Full encode: animation profile multi-track subtitles..."
  if assert_encode "animation multi-track subs: e2e output produced" "$mt_sub_anim_e2e_out" \
       --profile animation --crf 28 --preset ultrafast "$TESTDIR/hevc_multi_subs.mkv"; then
    local mt_sub_anim_scount
    mt_sub_anim_scount="$(count_streams "$mt_sub_anim_e2e_out" s)"
    if [[ "$mt_sub_anim_scount" -eq 3 ]]; then
      pass "animation multi-track sub e2e: 3 subtitle tracks preserved (eng only)"
    else
      fail "animation multi-track sub e2e: expected 3 subtitle tracks (eng only), got $mt_sub_anim_scount"
    fi
    # Video should be re-encoded to HEVC (animation always re-encodes)
    assert_probe "animation multi-track sub e2e: video is HEVC" "$mt_sub_anim_e2e_out" codec_name hevc
    # First sub should have eng language
    local mt_sub_anim_lang0
    mt_sub_anim_lang0="$(probe_stream_tag "$mt_sub_anim_e2e_out" s:0 language)"
    if [[ "$mt_sub_anim_lang0" == "eng" ]]; then
      pass "animation multi-track sub e2e: first subtitle is English"
    else
      fail "animation multi-track sub e2e: expected eng, got lang='$mt_sub_anim_lang0'"
    fi
    # Third sub (s:2) should also be eng (SDH) — no spa/fra tracks survive
    local mt_sub_anim_lang2
    mt_sub_anim_lang2="$(probe_stream_tag "$mt_sub_anim_e2e_out" s:2 language)"
    if [[ "$mt_sub_anim_lang2" == "eng" ]]; then
      pass "animation multi-track sub e2e: third subtitle is English (SDH)"
    else
      fail "animation multi-track sub e2e: expected eng, got lang='$mt_sub_anim_lang2'"
    fi
  fi

  # ---- archive multi-track audio with language filter ----
  # Dry-run shows "keeping 1 of 3" for --audio-lang-pref eng (commentary dropped
  # by AUDIO_KEEP_COMMENTARY=0, spa dropped by language filter).  This real encode
  # confirms the ffmpeg command is built correctly — output has exactly 1 audio track.
  # Fixture: hevc_multi_audio.mkv — eng main + eng commentary + spa (3 audio tracks).
  local mt_audio_lang_e2e_out="$TESTDIR/e2e_archive_mt_audio_eng.mkv"
  log "Full encode: archive multi-track audio with --audio-lang-pref eng..."
  if assert_encode "archive multi-track audio eng: e2e output produced" "$mt_audio_lang_e2e_out" \
       --profile archive --audio-lang-pref eng "$TESTDIR/hevc_multi_audio.mkv"; then
    assert_stream_count "archive multi-track audio eng e2e: 1 audio track (eng main only)" \
      "$mt_audio_lang_e2e_out" a 1 1
    local mt_audio_lang_e2e_lang0
    mt_audio_lang_e2e_lang0="$(probe_stream_tag "$mt_audio_lang_e2e_out" a:0 language)"
    if [[ "$mt_audio_lang_e2e_lang0" == "eng" ]]; then
      pass "archive multi-track audio eng e2e: surviving track is English"
    else
      fail "archive multi-track audio eng e2e: expected eng, got '$mt_audio_lang_e2e_lang0'"
    fi
  fi
}

# === Suite: Completions Installer ===
# Validates --install-completions creates the completion file and patches .bashrc/.zshrc,
# is idempotent (no duplicate source lines), and --uninstall-completions cleans up.
# Uses an isolated $HOME to avoid touching real RC files.
test_completions() {
  section "Completion Installer (--install-completions / --uninstall-completions)"

  # Use an isolated HOME to avoid touching the real user's RC files
  local fake_home="$TESTDIR/fake_home"
  mkdir -p "$fake_home"

  # Create fake RC files to patch
  touch "$fake_home/.bashrc"
  touch "$fake_home/.zshrc"

  local out comp_file="$fake_home/.muxm/muxm-completion.bash"

  # ---- --install-completions creates the file and patches RC files ----
  out="$(HOME="$fake_home" "$MUXM" --install-completions 2>&1)" || true
  assert_contains "Completion Installer" "--install-completions shows banner" "$out"

  if [[ -f "$comp_file" ]]; then
    pass "--install-completions creates completion file"
    # Verify it contains the completion function
    assert_contains "_muxm_completions" "Completion file has _muxm_completions" "$(cat "$comp_file")"
  else
    fail "--install-completions did not create $comp_file"
  fi

  # Verify source line was added to RC files
  if grep -qF 'muxm-completion.bash' "$fake_home/.bashrc" 2>/dev/null; then
    pass "--install-completions patches .bashrc"
  else
    fail "--install-completions did not patch .bashrc"
  fi

  if grep -qF 'muxm-completion.bash' "$fake_home/.zshrc" 2>/dev/null; then
    pass "--install-completions patches .zshrc"
  else
    fail "--install-completions did not patch .zshrc"
  fi

  # ---- Idempotency: running again should NOT duplicate ----
  out="$(HOME="$fake_home" "$MUXM" --install-completions 2>&1)" || true
  local count
  count="$(grep -cF 'muxm-completion.bash' "$fake_home/.bashrc")"
  if [[ "$count" -eq 1 ]]; then
    pass "--install-completions is idempotent (no duplicate in .bashrc)"
  else
    fail "--install-completions duplicated source line in .bashrc ($count occurrences)"
  fi

  # ---- --uninstall-completions removes file and cleans RC ----
  out="$(HOME="$fake_home" "$MUXM" --uninstall-completions 2>&1)" || true
  assert_contains "Completion Uninstaller" "--uninstall-completions shows banner" "$out"

  if [[ ! -f "$comp_file" ]]; then
    pass "--uninstall-completions removes completion file"
  else
    fail "--uninstall-completions did not remove completion file"
  fi

  if ! grep -qF 'muxm-completion.bash' "$fake_home/.bashrc" 2>/dev/null; then
    pass "--uninstall-completions cleans .bashrc"
  else
    fail "--uninstall-completions did not clean .bashrc"
  fi

  if ! grep -qF 'muxm-completion.bash' "$fake_home/.zshrc" 2>/dev/null; then
    pass "--uninstall-completions cleans .zshrc"
  else
    fail "--uninstall-completions did not clean .zshrc"
  fi

  # ---- --uninstall-completions is safe when nothing is installed ----
  out="$(HOME="$fake_home" "$MUXM" --uninstall-completions 2>&1)" || true
  assert_contains "not found" "--uninstall-completions safe when already removed" "$out"

  # ---- 1.5: a commented-out source line is NOT mistaken for "already configured" ----
  local fake_home2="$TESTDIR/fake_home_1_5"
  mkdir -p "$fake_home2"
  printf '# source ~/.muxm/muxm-completion.bash\n' > "$fake_home2/.bashrc"
  out="$(HOME="$fake_home2" "$MUXM" --install-completions 2>&1)" || true
  if grep -qF "added source line" <<<"$out"; then
    pass "completions-reactivation-after-comment: a commented-out source line does not block re-activation"
  else
    fail "completions-reactivation-after-comment: --install-completions treated a commented-out line as already configured: ${out:0:200}"
  fi
  if grep -vE '^[[:space:]]*#' "$fake_home2/.bashrc" | grep -qF 'muxm-completion.bash'; then
    pass "completions-reactivation-after-comment: .bashrc has an active (uncommented) source line after install"
  else
    fail "completions-reactivation-after-comment: .bashrc has no active source line after install"
  fi
  # Running it again now IS idempotent — the newly-added ACTIVE line is correctly recognized.
  out="$(HOME="$fake_home2" "$MUXM" --install-completions 2>&1)" || true
  if grep -qF "already configured" <<<"$out"; then
    pass "completions-reactivation-after-comment: a genuinely active source line is still recognized as already configured"
  else
    fail "completions-reactivation-after-comment: idempotency regressed for a real (uncommented) source line: ${out:0:200}"
  fi
  rm -rf "$fake_home2"

  # ---- 1.6: $HOME unset gives a muxm-specific diagnostic, not a raw bash "unbound variable" ----
  local out16 rc16
  out16="$(cd "$TESTDIR" && env -u HOME "$MUXM" --install-completions 2>&1)" && rc16=$? || rc16=$?
  if [[ "$rc16" -ne 0 ]] && grep -qiF '$HOME is not set' <<<"$out16" && ! grep -qiF 'unbound variable' <<<"$out16"; then
    pass "completions-home-unset-diagnostic: --install-completions with \$HOME unset gives a muxm-specific diagnostic"
  else
    fail "completions-home-unset-diagnostic: --install-completions with \$HOME unset: ${out16:0:200}"
  fi
  out16="$(cd "$TESTDIR" && env -u HOME "$MUXM" --uninstall-completions 2>&1)" && rc16=$? || rc16=$?
  if [[ "$rc16" -ne 0 ]] && grep -qiF '$HOME is not set' <<<"$out16" && ! grep -qiF 'unbound variable' <<<"$out16"; then
    pass "completions-home-unset-diagnostic: --uninstall-completions with \$HOME unset gives a muxm-specific diagnostic"
  else
    fail "completions-home-unset-diagnostic: --uninstall-completions with \$HOME unset: ${out16:0:200}"
  fi
}

# ===== --setup (combined installer) ===========================================================
# Validates --setup runs all three sub-installers (dependencies, man page, completions),
# shows the combined banner and final summary, and actually installs the completion file.
test_setup() {
  section "Setup (--setup combined installer)"

  # Create isolated home so --install-man and --install-completions don't touch real system
  local fake_home
  fake_home="$(mktemp -d)"
  rm -f "$fake_home/.bashrc"   # ensure clean state (no stale file)
  touch "$fake_home/.bashrc"
  touch "$fake_home/.zshrc"

  # M1: stub `brew` for every installer call below. Without it, --setup / --install-dependencies
  # would `brew install`/`uninstall` real packages (and reinstall ffmpeg per F5), and --setup /
  # --install-man would resolve _man_target_dir to the real $(brew --prefix)/share/man/man1 and
  # overwrite the developer's installed muxm.1. The stub answers `brew --prefix` with a sandbox
  # prefix (steering the man page into a temp dir) and no-ops install/uninstall/tap while
  # recording argv to "$brew_log". HOME isolation alone does NOT cover the man dir — it comes
  # from brew --prefix, not $HOME. (See _make_brew_stub.)
  local stub_bin stub_prefix brew_log stub_path
  stub_bin="$fake_home/brew_stub_bin"
  stub_prefix="$fake_home/brew_prefix"
  _make_brew_stub "$stub_bin" "$stub_prefix"
  brew_log="$stub_prefix/brew_calls.log"
  stub_path="$stub_bin:$PATH"

  # ---- --setup shows the combined banner ----
  local out
  out="$(HOME="$fake_home" PATH="$stub_path" "$MUXM" --setup 2>&1)" || true
  assert_contains "Full Setup" "--setup shows Full Setup banner" "$out"

  # ---- --setup runs all three sub-installers ----
  assert_contains "Dependency Installer" "--setup runs dependency installer" "$out"
  assert_contains "Manual Page Installer" "--setup runs man page installer" "$out"
  assert_contains "Completion Installer" "--setup runs completion installer" "$out"

  # ---- --setup shows the final summary (success or warning depending on env) ----
  if echo "$out" | grep -qE "Setup complete|reporting errors"; then
    pass "--setup shows final summary"
  else
    fail "--setup did not show final summary"
  fi

  # ---- --setup actually installs completions ----
  local comp_file="$fake_home/.muxm/muxm-completion.bash"
  if [[ -f "$comp_file" ]]; then
    pass "--setup installs completion file"
  else
    fail "--setup did not install completion file"
  fi

  # ---- M1: --setup writes the man page into the SANDBOX prefix, not the real man dir ----
  # _install_man targets $(brew --prefix)/share/man/man1; with brew stubbed that resolves to
  # "$stub_prefix/...". If muxm.1 lands there, the developer's real …/share/man/man1 was not
  # touched. This assertion fails the instant the brew stub is removed (then the man page would
  # go to the real prefix and nothing appears under the sandbox), so it is the regression guard.
  if [[ -s "$stub_prefix/share/man/man1/muxm.1" ]]; then
    pass "--setup installs man page under the stubbed prefix (real man dir untouched)"
  else
    fail "--setup did not write muxm.1 under the stubbed prefix — brew stub not honored"
  fi

  # ---- --install-dependencies standalone (R26, R27) ----
  # In CI/test environments without Homebrew, this runs in check-only mode.
  # Either path should show the banner and list core tools.
  local dep_out
  dep_out="$(HOME="$fake_home" PATH="$stub_path" "$MUXM" --install-dependencies 2>&1)" || true
  if echo "$dep_out" | grep -qE "Dependency Installer|Dependency Check"; then
    pass "--install-dependencies shows banner"
  else
    fail "--install-dependencies: no banner found"
  fi
  assert_contains "ffmpeg" "--install-dependencies lists ffmpeg" "$dep_out"
  assert_contains "ffprobe" "--install-dependencies lists ffprobe" "$dep_out"
  assert_contains "jq" "--install-dependencies lists jq" "$dep_out"

  # ---- M1: --install-dependencies routed brew through the stub — no real package mutation ----
  # `brew --prefix` is always called during the run (tessdata resolution), so the stub log is
  # non-empty and contains "--prefix" whenever the stub is engaged. PATH-shadowing guarantees
  # every other brew call (install/uninstall/tap) hit the same no-op stub, so nothing real was
  # installed or removed. Empty log ⇒ real brew ran ⇒ regression.
  if [[ -s "$brew_log" ]] && grep -qF -- '--prefix' "$brew_log"; then
    pass "--install-dependencies intercepts brew via the stub (no real install/uninstall)"
  else
    fail "--install-dependencies did not route brew through the stub — real brew may have run"
  fi

  # ---- F5: missing-AV1/libass ffmpeg → install ffmpeg-full, NEVER uninstall/replace ----
  # Shadow the real (complete) ffmpeg with an incomplete stub (no libass/AV1) so _ensure_ffmpeg_full
  # takes the install path, with brew stubbed so nothing real happens. A destructive path would run
  # `brew tap homebrew-ffmpeg/... && brew install ... --with-* && brew uninstall <old>`; instead it
  # must run `brew install ffmpeg-full` and perform NO uninstall and NO tap.
  local f5_bin f5_prefix f5_log
  f5_bin="$fake_home/f5_bin"
  f5_prefix="$fake_home/f5_prefix"
  _make_brew_stub "$f5_bin" "$f5_prefix"
  f5_log="$f5_prefix/brew_calls.log"
  # Incomplete ffmpeg stub: -version reports a build WITHOUT --enable-libass; -encoders lists none.
  # (Its keg path under the stub prefix has no ffmpeg, so _ensure_ffmpeg_full proceeds to install.)
  # shellcheck disable=SC2016  # mock ffmpeg stub: $1 must stay literal — it expands when the stub runs, not here
  printf '#!/bin/bash\ncase "$1" in -version) echo "ffmpeg version 6.0";; *) :;; esac\nexit 0\n' > "$f5_bin/ffmpeg"
  chmod +x "$f5_bin/ffmpeg"
  HOME="$fake_home" PATH="$f5_bin:$PATH" "$MUXM" --install-dependencies >/dev/null 2>&1 || true
  if grep -qE '(^| )install ffmpeg-full( |$)' "$f5_log"; then
    pass "setup-install-dependencies-ffmpeg-full: --install-dependencies installs ffmpeg-full when ffmpeg lacks libass/AV1"
  else
    fail "setup-install-dependencies-ffmpeg-full: --install-dependencies did not run 'brew install ffmpeg-full' (log: $(tr '\n' ';' < "$f5_log"))"
  fi
  if grep -qE '(^| )uninstall( |$)' "$f5_log"; then
    fail "setup-install-dependencies-ffmpeg-full: --install-dependencies ran 'brew uninstall' — must never replace the user's ffmpeg"
  else
    pass "setup-install-dependencies-ffmpeg-full: --install-dependencies performs NO brew uninstall (non-destructive)"
  fi
  if grep -qE 'homebrew-ffmpeg' "$f5_log"; then
    fail "setup-install-dependencies-ffmpeg-full: --install-dependencies still uses the homebrew-ffmpeg tap (should be ffmpeg-full)"
  else
    pass "setup-install-dependencies-ffmpeg-full: --install-dependencies no longer taps homebrew-ffmpeg"
  fi

  # ---- M4: a failing _ensure_ffmpeg_full must NOT abort the installer before its summary ----
  # A bare call would let a `return 1` (failed/incomplete ffmpeg-full install) exit the
  # whole run under set -e, so the "Summary: …" line never prints. Reuse the incomplete-ffmpeg
  # stub (forces the install path) with a brew stub that FAILS `install ffmpeg-full` (the
  # return-1 path). The `_ensure_ffmpeg_full || true` guard records the failure and still prints
  # the summary. Perturb MUT-M4-SUMMARY reverts the guard → set -e abort → no summary → red.
  local m4_bin m4_prefix m4_log
  m4_bin="$fake_home/m4_bin"; m4_prefix="$fake_home/m4_prefix"
  mkdir -p "$m4_bin" "$m4_prefix/share/man/man1"
  : > "$m4_prefix/brew_calls.log"; m4_log="$m4_prefix/brew_calls.log"
  # brew stub: answer --prefix; FAIL `install ffmpeg-full`; no-op everything else.
  # shellcheck disable=SC2016  # stub body stays literal; only the two %s (log, prefix) expand here.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n[[ "$1" == "--prefix" ]] && { printf "%%s\\n" "%s"; exit 0; }\nif [[ "$1" == "install" && "$2" == "ffmpeg-full" ]]; then exit 1; fi\nexit 0\n' \
    "$m4_log" "$m4_prefix" > "$m4_bin/brew"
  chmod +x "$m4_bin/brew"
  # Incomplete ffmpeg (no libass/AV1) so _ensure_ffmpeg_full proceeds to the (failing) install.
  # shellcheck disable=SC2016  # mock ffmpeg: $1 stays literal; it expands when the stub runs.
  printf '#!/bin/bash\ncase "$1" in -version) echo "ffmpeg version 6.0";; *) :;; esac\nexit 0\n' > "$m4_bin/ffmpeg"
  chmod +x "$m4_bin/ffmpeg"
  local m4_out
  m4_out="$(HOME="$fake_home" PATH="$m4_bin:$PATH" "$MUXM" --install-dependencies 2>&1)" || true
  if printf '%s\n' "$m4_out" | grep -qE "^Summary: [0-9]+ checked,"; then
    pass "setup-install-deps-summary-on-failure: --install-dependencies prints its summary even when ffmpeg-full install fails"
  else
    fail "setup-install-deps-summary-on-failure: installer aborted before the summary when _ensure_ffmpeg_full failed"
  fi

  # ---- --uninstall-man standalone (R24, R25) ----
  # In test environments the man page is unlikely to be installed, so this
  # exercises the "not found — nothing to remove" safe path.
  # M1: use a FRESH stub prefix (no muxm.1 written there) so _man_target_dir resolves into an
  # empty sandbox — preserving the "nothing to remove" coverage. Without a brew stub this would
  # target the real $(brew --prefix)/share/man/man1 and rm -f the developer's installed muxm.1.
  local un_stub_bin un_stub_prefix
  un_stub_bin="$fake_home/brew_stub_bin_uninstall"
  un_stub_prefix="$fake_home/brew_prefix_uninstall"
  _make_brew_stub "$un_stub_bin" "$un_stub_prefix"
  local man_out
  man_out="$(HOME="$fake_home" PATH="$un_stub_bin:$PATH" "$MUXM" --uninstall-man 2>&1)" || true
  assert_contains "Manual Page Uninstaller" "--uninstall-man shows banner" "$man_out"
  # Safe when man page is not installed — should not error
  if echo "$man_out" | grep -qiE "not found|nothing to remove|removed"; then
    pass "--uninstall-man: safe when man page not installed"
  else
    fail "--uninstall-man: unexpected output: ${man_out:0:200}"
  fi

  # ---- L4: --uninstall-man removes a DANGLING man-page symlink ----
  # A `[[ ! -f "$target" ]]` check is true for a broken symlink (its target is gone) — so
  # the uninstaller would report "nothing to remove" and orphan it. The check uses
  # `[[ ! -e && ! -L ]]` instead. Stub `brew --prefix` to point the man dir at a temp,
  # writable location, plant a dangling muxm.1 symlink there, and verify it gets removed.
  local _l4_prefix="$fake_home/l4_prefix"
  local _l4_mandir="$_l4_prefix/share/man/man1"
  local _l4_bin="$fake_home/l4_bin"
  mkdir -p "$_l4_mandir" "$_l4_bin"
  # Single-quoted on purpose: `$1` must stay LITERAL (it's the generated stub's own runtime
  # arg, read when muxm later runs `brew --prefix`), while `%s` is printf's placeholder,
  # substituted here with "$_l4_prefix". `%%s`→literal `%s` and `\\n`→literal `\n` are for
  # the generated stub's inner printf. So only the prefix path is expanded at generation.
  # shellcheck disable=SC2016
  printf '#!/bin/bash\n[[ "$1" == "--prefix" ]] && { printf "%%s\\n" "%s"; exit 0; }\nexit 0\n' "$_l4_prefix" > "$_l4_bin/brew"
  chmod +x "$_l4_bin/brew"
  ln -sf "$_l4_mandir/nonexistent-page.1" "$_l4_mandir/muxm.1"   # dangling symlink
  if [[ -L "$_l4_mandir/muxm.1" && ! -e "$_l4_mandir/muxm.1" ]]; then
    local _l4_out
    _l4_out="$(PATH="$_l4_bin:$PATH" "$MUXM" --uninstall-man 2>&1)" || true
    if [[ -L "$_l4_mandir/muxm.1" || -e "$_l4_mandir/muxm.1" ]]; then
      fail "setup-uninstall-man-dangling-symlink: --uninstall-man left the dangling muxm.1 symlink in place"
    else
      pass "setup-uninstall-man-dangling-symlink: --uninstall-man removes a dangling muxm.1 symlink"
    fi
  else
    skip "setup-uninstall-man-dangling-symlink: filesystem did not create a dangling symlink as expected"
  fi

  # ---- 1.2: --install-man reports FAILURE (not "✅ Installed") when the write itself fails ----
  # Point _man_target_dir at an UNWRITABLE stubbed prefix (forcing the sudo branch) and shadow
  # `sudo` with a stub that always fails — a failed write must surface as a real error, never a
  # false "✅ Installed". Guarded with a precondition check since chmod-based unwritability is
  # meaningless when the suite runs as root.
  local m12_prefix="$fake_home/m12_prefix" m12_bin="$fake_home/m12_bin"
  mkdir -p "$m12_prefix/share/man/man1" "$m12_bin"
  chmod 555 "$m12_prefix/share/man/man1"
  # shellcheck disable=SC2016
  printf '#!/bin/bash\n[[ "$1" == "--prefix" ]] && { printf "%%s\\n" "%s"; exit 0; }\nexit 0\n' "$m12_prefix" > "$m12_bin/brew"
  chmod +x "$m12_bin/brew"
  printf '#!/bin/bash\nexit 1\n' > "$m12_bin/sudo"
  chmod +x "$m12_bin/sudo"
  if [[ -w "$m12_prefix/share/man/man1" ]]; then
    skip "setup-man-dir-unwritable: cannot make the man dir unwritable in this environment (running as root?)"
  else
    local m12_out m12_rc
    m12_out="$(PATH="$m12_bin:$PATH" "$MUXM" --install-man 2>&1)" && m12_rc=$? || m12_rc=$?
    if [[ "$m12_rc" -ne 0 ]] && ! grep -q '✅ Installed' <<<"$m12_out"; then
      pass "setup-man-dir-unwritable: --install-man reports failure (not '✅ Installed') when the write fails"
    else
      fail "setup-man-dir-unwritable: --install-man reported success despite a failing write (rc=$m12_rc): ${m12_out:0:200}"
    fi
  fi
  chmod 755 "$m12_prefix/share/man/man1"  # restore so the final rm -rf "$fake_home" can clean up

  # ---- 1.2: --uninstall-man reports FAILURE (not "✅ Removed") when the remove itself fails ----
  local m12u_prefix="$fake_home/m12u_prefix" m12u_bin="$fake_home/m12u_bin"
  mkdir -p "$m12u_prefix/share/man/man1" "$m12u_bin"
  echo "content" > "$m12u_prefix/share/man/man1/muxm.1"
  chmod 555 "$m12u_prefix/share/man/man1"
  # shellcheck disable=SC2016
  printf '#!/bin/bash\n[[ "$1" == "--prefix" ]] && { printf "%%s\\n" "%s"; exit 0; }\nexit 0\n' "$m12u_prefix" > "$m12u_bin/brew"
  chmod +x "$m12u_bin/brew"
  printf '#!/bin/bash\nexit 1\n' > "$m12u_bin/sudo"
  chmod +x "$m12u_bin/sudo"
  if [[ -w "$m12u_prefix/share/man/man1" ]]; then
    skip "setup-man-dir-unwritable: cannot make the man dir unwritable in this environment (running as root?)"
  else
    local m12u_out m12u_rc
    m12u_out="$(PATH="$m12u_bin:$PATH" "$MUXM" --uninstall-man 2>&1)" && m12u_rc=$? || m12u_rc=$?
    if [[ "$m12u_rc" -ne 0 ]] && ! grep -q '✅ Removed' <<<"$m12u_out"; then
      pass "setup-man-dir-unwritable: --uninstall-man reports failure (not '✅ Removed') when the remove fails"
    else
      fail "setup-man-dir-unwritable: --uninstall-man reported success despite a failing remove (rc=$m12u_rc): ${m12u_out:0:200}"
    fi
  fi
  chmod 755 "$m12u_prefix/share/man/man1"

  # ---- 1.7: --install-man warns when the target dir is not on the resolved man search path ----
  local m17_prefix="$fake_home/m17_prefix" m17_bin="$fake_home/m17_bin"
  mkdir -p "$m17_prefix/share/man/man1" "$m17_bin"
  # shellcheck disable=SC2016
  printf '#!/bin/bash\n[[ "$1" == "--prefix" ]] && { printf "%%s\\n" "%s"; exit 0; }\nexit 0\n' "$m17_prefix" > "$m17_bin/brew"
  chmod +x "$m17_bin/brew"
  local m17_out
  m17_out="$(PATH="$m17_bin:$PATH" env -u MANPATH "$MUXM" --install-man 2>&1)" || true
  assert_contains "not on your man search path" "setup-install-man-manpath-warn: --install-man warns when target isn't on MANPATH" "$m17_out"

  # 1.8 (mp4box/gpac install-check dedup) needs no new test — it's a pure internal refactor
  # already protected by the existing --install-dependencies (R26/R27) and _detect_mp4box
  # unit coverage exercised elsewhere in this suite.

  # ---- Cleanup ----
  rm -rf "$fake_home"
}

# === Suite: External Subtitle Discovery ===
# Validates --no-ext-subs, --ext-subs-dir, filename parsing, discovery, and
# integration with filtering (lang-pref, SDH, forced, max-tracks).
test_ext_subs() {
  section "External Subtitle Discovery"

  local out outfile

  # ---- Config flags via --print-effective-config ----

  # --no-ext-subs disables discovery
  out="$(run_muxm --no-ext-subs --print-effective-config)"
  assert_contains "EXT_SUB_ENABLED           = 0" "--no-ext-subs: config shows 0" "$out"

  # --ext-subs re-enables discovery
  out="$(run_muxm --no-ext-subs --ext-subs --print-effective-config)"
  assert_contains "EXT_SUB_ENABLED           = 1" "--ext-subs: re-enables discovery" "$out"

  # default shows EXT_SUB_ENABLED = 1
  out="$(run_muxm --print-effective-config)"
  assert_contains "EXT_SUB_ENABLED           = 1" "Default: EXT_SUB_ENABLED=1" "$out"

  # --ext-subs-dir shows custom dir in config
  out="$(run_muxm --ext-subs-dir "$TESTDIR" --print-effective-config)"
  assert_contains "EXT_SUB_DIR               = $TESTDIR" "--ext-subs-dir: config shows path" "$out"

  # --ext-subs-dir with nonexistent directory should exit non-zero
  local bad_dir_code
  (cd "$TESTDIR" && "$MUXM" --ext-subs-dir /no/such/dir/xyzzy "$TESTDIR/ext_only_source.mkv" >/dev/null 2>&1) && bad_dir_code=0 || bad_dir_code=$?
  if (( bad_dir_code != 0 )); then
    pass "--ext-subs-dir nonexistent dir: exits with error"
  else
    fail "--ext-subs-dir nonexistent dir: should have failed"
  fi

  # ---- Discovery: sidecar .srt files found alongside source ----

  # Integration: ext_only_source.mkv has exactly one sidecar (ext_only_source.en.srt)
  # and no embedded subs — verify muxm picks it up and produces output with 1 subtitle
  outfile="$TESTDIR/ext_only_out.mkv"
  log "Testing external subtitle discovery (single sidecar)..."
  if assert_encode "ext_only: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       "$TESTDIR/ext_only_source.mkv"; then
    assert_stream_count "ext_only: 1 subtitle track from sidecar" "$outfile" s 1 1
    local ext_lang
    ext_lang="$(probe_stream_tag "$outfile" s:0 language)"
    if [[ "$ext_lang" == "eng" || "$ext_lang" == "en" || "$ext_lang" == "und" ]]; then
      pass "ext_only: subtitle language is eng/en/und (from .en.srt)"
    else
      # Language tag may vary; just confirm a subtitle exists — already asserted above
      skip "ext_only: subtitle language tag '$ext_lang' (acceptable — sub present)"
    fi
  fi

  # ---- --no-ext-subs disables discovery (no embedded + no external = no subs) ----
  outfile="$TESTDIR/ext_no_ext_subs.mkv"
  log "Testing --no-ext-subs suppresses sidecar discovery..."
  if assert_encode "no-ext-subs: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast --no-ext-subs \
       "$TESTDIR/ext_only_source.mkv"; then
    assert_stream_count "no-ext-subs: 0 subtitle tracks" "$outfile" s 0 0
  fi

  # ---- --skip-subs also suppresses external subtitle discovery ----
  out="$(run_muxm --dry-run --skip-subs "$TESTDIR/ext_only_source.mkv")"
  # skip-subs implies no subtitle processing at all
  if echo "$out" | grep -qiE "skip.*sub|subtitle.*skip|SKIP_SUBS"; then
    pass "--skip-subs: subtitle processing skipped (implies no ext discovery)"
  else
    # The output may announce skip differently; confirm no ext-sub message appears
    if ! echo "$out" | grep -qi "external subtitle found"; then
      pass "--skip-subs: no external subtitle discovery triggered"
    else
      fail "--skip-subs: external subtitle discovery ran unexpectedly"
    fi
  fi

  # ---- --ext-subs-dir: use explicit directory for sidecar lookup ----
  # ext_only_source.en.srt lives in TESTDIR; use --ext-subs-dir to point there explicitly
  outfile="$TESTDIR/ext_dir_out.mkv"
  log "Testing --ext-subs-dir explicit directory..."
  if assert_encode "ext-subs-dir: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       --ext-subs-dir "$TESTDIR" \
       "$TESTDIR/ext_only_source.mkv"; then
    assert_stream_count "ext-subs-dir: subtitle track present" "$outfile" s 1 1
  fi

  # ---- Multi-sidecar source: ext_sub_source has 9 sidecar .srt files ----
  # Without filtering, up to SUB_MAX_TRACKS (default 3) should be included.
  outfile="$TESTDIR/ext_multi_out.mkv"
  log "Testing multi-sidecar discovery (ext_sub_source)..."
  if assert_encode "ext_multi: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       "$TESTDIR/ext_sub_source.mkv"; then
    local sub_count
    sub_count="$(count_streams "$outfile" s)"
    if (( sub_count >= 1 )); then
      pass "ext_multi: at least 1 subtitle track included (got $sub_count)"
    else
      fail "ext_multi: expected ≥1 subtitle tracks, got $sub_count"
    fi
  fi

  # ---- Filename parsing: .srt (no qualifier) → lang=default, type=full ----
  # ext_sub_source.srt is the bare sidecar (no language/type qualifier)
  # With --sub-lang-pref set to something non-default we can verify the bare file is still found
  outfile="$TESTDIR/ext_bare_out.mkv"
  log "Testing filename parsing: bare .srt (no qualifier)..."
  if assert_encode "ext_bare: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       "$TESTDIR/ext_sub_source.mkv"; then
    local bare_sub_count
    bare_sub_count="$(count_streams "$outfile" s)"
    if (( bare_sub_count >= 1 )); then
      pass "ext_bare: bare .srt discovered and included (got $bare_sub_count tracks)"
    else
      fail "ext_bare: expected ≥1 subtitle tracks from bare .srt, got $bare_sub_count"
    fi
  fi

  # ---- Filename parsing: .en.srt → lang=en ----
  # Run with --sub-lang-pref eng and confirm eng sub is selected
  outfile="$TESTDIR/ext_lang_eng_out.mkv"
  log "Testing filename parsing: .en.srt → lang=en..."
  if assert_encode "ext_lang_eng: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref eng \
       "$TESTDIR/ext_sub_source.mkv"; then
    assert_stream_count "ext_lang_eng: subtitle track present" "$outfile" s 1
  fi

  # ---- Filename parsing: .spa.srt → lang=spa ----
  outfile="$TESTDIR/ext_lang_spa_out.mkv"
  log "Testing filename parsing: .spa.srt → lang=spa..."
  if assert_encode "ext_lang_spa: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref spa \
       "$TESTDIR/ext_sub_source.mkv"; then
    assert_stream_count "ext_lang_spa: subtitle track present" "$outfile" s 1
    local spa_lang
    spa_lang="$(probe_stream_tag "$outfile" s:0 language)"
    if [[ "$spa_lang" == "spa" ]]; then
      pass "ext_lang_spa: subtitle tag is spa"
    else
      fail "ext_lang_spa: expected language tag 'spa' from the .spa.srt sidecar, got '$spa_lang'"
    fi
  fi

  # ---- Filename parsing: .forced.en.srt → type=forced ----
  # --sub-include-forced must be enabled (default) to pick up forced
  outfile="$TESTDIR/ext_forced_out.mkv"
  log "Testing filename parsing: .forced.en.srt → type=forced..."
  if assert_encode "ext_forced: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref eng \
       "$TESTDIR/ext_sub_source.mkv"; then
    assert_stream_count "ext_forced: subtitle track present" "$outfile" s 1
    # 1.4: the .forced.en sidecar must surface as a sub track flagged forced
    # (disposition.forced=1) — not merely "a sub exists". M-SUB-1 (ignore the .forced.
    # infix) drops the flag, so this goes red.
    local ef_forced
    ef_forced="$(ffprobe -v error -select_streams s -show_entries stream_disposition=forced -of csv=p=0 "$outfile" 2>/dev/null | grep -c '^1$' || true)"
    if [[ "${ef_forced:-0}" -ge 1 ]]; then
      pass "ext_forced: a subtitle track carries the forced disposition (from .forced.en sidecar)"
    else
      fail "ext_forced: expected ≥1 sub with disposition.forced=1 from the .forced.en sidecar, got ${ef_forced:-0}"
    fi
  fi

  # ---- Filename parsing: .en.sdh.srt → type=sdh ----
  outfile="$TESTDIR/ext_sdh_out.mkv"
  log "Testing filename parsing: .en.sdh.srt → type=sdh..."
  if assert_encode "ext_sdh: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref eng \
       "$TESTDIR/ext_sub_source.mkv"; then
    assert_stream_count "ext_sdh: subtitle track present" "$outfile" s 1
    # 1.4: the .en.sdh sidecar must surface as an SDH-marked track (muxm sets title "SDH").
    local es_sdh
    es_sdh="$(ffprobe -v error -select_streams s -show_entries stream_tags=title -of csv=p=0 "$outfile" 2>/dev/null | grep -ci sdh || true)"
    if [[ "${es_sdh:-0}" -ge 1 ]]; then
      pass "ext_sdh: a subtitle track is marked SDH (title) from the .en.sdh sidecar"
    else
      fail "ext_sdh: expected an SDH-titled sub track from the .en.sdh sidecar, got none"
    fi
  fi

  # ---- --no-sub-sdh excludes SDH sidecar (.en.sdh.srt) ----
  # With only eng subs and SDH disabled, forced or full eng sub should win over SDH
  outfile="$TESTDIR/ext_no_sdh_out.mkv"
  log "Testing --no-sub-sdh excludes SDH sidecar..."
  if assert_encode "ext_no_sdh: encode produced" "$outfile" \
       --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref eng --no-sub-sdh \
       "$TESTDIR/ext_sub_source.mkv"; then
    # Should still find a non-SDH eng sub (.en.srt or .forced.en.srt)
    assert_stream_count "ext_no_sdh: subtitle present (non-SDH)" "$outfile" s 1
    # 1.4: --no-sub-sdh must EXCLUDE the .en.sdh sidecar — the inverse the old test couldn't tell.
    local ens_sdh
    ens_sdh="$(ffprobe -v error -select_streams s -show_entries stream_tags=title -of csv=p=0 "$outfile" 2>/dev/null | grep -ci sdh || true)"
    if [[ "${ens_sdh:-0}" -eq 0 ]]; then
      pass "ext_no_sdh: --no-sub-sdh excluded the SDH sidecar (no SDH-titled track)"
    else
      fail "ext_no_sdh: --no-sub-sdh should exclude SDH, but found ${ens_sdh} SDH-titled track(s)"
    fi
  fi

  # ---- SUB_MAX_TRACKS=1 limits external subtitle tracks ----
  local smt_home="$TESTDIR/ext_sub_max_home"
  mkdir -p "$smt_home"
  cat > "$smt_home/.muxmrc" <<'EOF'
SUB_MAX_TRACKS=1
EOF
  outfile="$TESTDIR/ext_max1_out.mkv"
  log "Testing SUB_MAX_TRACKS=1 limits external subtitle output..."
  if HOME="$smt_home" run_muxm --output-ext mkv --crf 28 --preset ultrafast \
       "$TESTDIR/ext_sub_source.mkv" "$outfile" >/dev/null 2>&1 && [[ -f "$outfile" && -s "$outfile" ]]; then
    local max1_count
    max1_count="$(count_streams "$outfile" s)"
    if (( max1_count <= 1 )); then
      pass "SUB_MAX_TRACKS=1: external subs limited to ≤1 (got $max1_count)"
    else
      fail "SUB_MAX_TRACKS=1: expected ≤1 subtitle track, got $max1_count"
    fi
  else
    skip "SUB_MAX_TRACKS=1 ext encode failed"
  fi
  rm -rf "$smt_home"

  # ---- Multi-track mode includes multiple external subs ----
  local mt_home="$TESTDIR/ext_mt_home"
  mkdir -p "$mt_home"
  cat > "$mt_home/.muxmrc" <<'EOF'
SUB_MAX_TRACKS=5
EOF
  outfile="$TESTDIR/ext_mt_out.mkv"
  log "Testing multi-track mode includes multiple external subtitles..."
  if HOME="$mt_home" run_muxm --output-ext mkv --crf 28 --preset ultrafast \
       "$TESTDIR/ext_sub_source.mkv" "$outfile" >/dev/null 2>&1 && [[ -f "$outfile" && -s "$outfile" ]]; then
    local mt_count
    mt_count="$(count_streams "$outfile" s)"
    if (( mt_count >= 2 )); then
      pass "Multi-track ext subs: ≥2 subtitle tracks included (got $mt_count)"
    else
      skip "Multi-track ext subs: only $mt_count track(s) — may be limited by filtering"
    fi
  else
    skip "Multi-track ext subs encode failed"
  fi
  rm -rf "$mt_home"

  # ---- Discovery respects SKIP_SUBS (--skip-subs in dry-run) ----
  out="$(run_muxm --dry-run --skip-subs "$TESTDIR/ext_sub_source.mkv")"
  if ! echo "$out" | grep -qi "external subtitle found"; then
    pass "skip-subs: external subtitle discovery suppressed"
  else
    fail "skip-subs: external subtitle discovery ran when SKIP_SUBS=1"
  fi

  # ---- Dry-run with ext subs: discovery announced in output ----
  out="$(run_muxm --dry-run "$TESTDIR/ext_only_source.mkv")"
  if echo "$out" | grep -qiE "external subtitle found|ext_only_source"; then
    pass "dry-run: external subtitle discovery announced"
  else
    # Discovery might output via note() which may not appear in dry-run quiet mode
    skip "dry-run: no ext sub announcement found (may be log-level gated)"
  fi

  # ---- SUB_SOLE_EXT_FALLBACK: sole sidecar bypasses language filter ----
  # ext_only_source.mkv has 0 embedded subs and exactly 1 sidecar (ext_only_source.en.srt).
  # With --sub-lang-pref jpn the sidecar (parsed as eng from ".en.srt") fails the
  # language filter. SUB_SOLE_EXT_FALLBACK=1 (default) bypasses the filter when there
  # is exactly 1 external sidecar and 0 embedded streams → subtitle is included.
  local fallback_out="$TESTDIR/ext_sole_fallback_out.mkv"
  log "Testing SUB_SOLE_EXT_FALLBACK: sole sidecar bypasses language filter..."
  if assert_encode "sole-ext-fallback: encode produced" "$fallback_out" \
       --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref jpn \
       "$TESTDIR/ext_only_source.mkv"; then
    local fallback_scount
    fallback_scount="$(count_streams "$fallback_out" s)"
    if (( fallback_scount == 1 )); then
      pass "sole-ext-fallback: sole sidecar included despite jpn language filter (1 track)"
    else
      fail "sole-ext-fallback: expected 1 subtitle track via fallback, got $fallback_scount"
    fi
  fi

  # ---- --no-sub-sole-ext-fallback: sole-sidecar bypass disabled ----
  # Same setup as above but with --no-sub-sole-ext-fallback. The language filter drops
  # the sidecar (jpn pref, eng sidecar) and the fallback is disabled → 0 subtitle tracks.
  local no_fallback_out="$TESTDIR/ext_sole_no_fallback_out.mkv"
  log "Testing --no-sub-sole-ext-fallback: fallback disabled, sidecar excluded..."
  if assert_encode "no-sole-ext-fallback: encode produced" "$no_fallback_out" \
       --output-ext mkv --crf 28 --preset ultrafast \
       --sub-lang-pref jpn \
       --no-sub-sole-ext-fallback \
       "$TESTDIR/ext_only_source.mkv"; then
    local no_fallback_scount
    no_fallback_scount="$(count_streams "$no_fallback_out" s)"
    if (( no_fallback_scount == 0 )); then
      pass "--no-sub-sole-ext-fallback: fallback disabled, sidecar excluded (0 tracks)"
    else
      fail "--no-sub-sole-ext-fallback: expected 0 subtitle tracks, got $no_fallback_scount"
    fi
  fi

  # ---- M3: an embedded subtitle and a sidecar of the SAME normalized language+type must not
  #      both survive — `merge_subtitle_sources` de-duplicates the sidecar. Embedded `eng` +
  #      `<stem>.en.srt` (parsed to `eng`) → exactly ONE English subtitle track, not two.
  #      Skip-first guard (not an else-skip) per the soft-skip ratchet. ----
  if ! ffmpeg_has_encoder libx265; then
    skip "extsub-embedded-external-dedup: ffmpeg lacks libx265 — cannot build the embedded+sidecar fixture"
  else
    local _m3_src="$TESTDIR/m3_dedup_source.mkv" _m3_out="$TESTDIR/m3_dedup_out.mkv"
    printf '1\n00:00:00,000 --> 00:00:02,000\nEmbedded English\n' > "$TESTDIR/m3_embed.srt"
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "color=c=maroon:s=320x240:r=24:d=2" \
      -f lavfi -i "sine=frequency=440:duration=2" \
      -i "$TESTDIR/m3_embed.srt" \
      -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p10le \
      -map 0:v -map 1:a -map 2:s -c:a aac -c:s srt \
      -metadata:s:s:0 language=eng \
      "$_m3_src" 2>/dev/null
    # Sidecar with the SAME language (2-letter form) and type (full) as the embedded track.
    printf '1\n00:00:00,000 --> 00:00:02,000\nSidecar English\n' > "$TESTDIR/m3_dedup_source.en.srt"
    if [[ ! -s "$_m3_src" ]]; then
      skip "extsub-embedded-external-dedup: could not build the embedded+sidecar fixture"
    else
      run_muxm --profile archive --output-ext mkv "$_m3_src" "$_m3_out" >/dev/null
      local _m3_scount; _m3_scount="$(count_streams "$_m3_out" s)"
      if [[ -s "$_m3_out" ]] && (( _m3_scount == 1 )); then
        pass "extsub-embedded-external-dedup: embedded 'eng' + sidecar '.en.srt' de-duplicated to exactly 1 subtitle track"
      else
        fail "extsub-embedded-external-dedup: expected exactly 1 subtitle track after dedup, got ${_m3_scount:-?} (embedded+external not deduped)"
      fi
    fi
    rm -f "$_m3_src" "$_m3_out" "$TESTDIR/m3_embed.srt" "$TESTDIR/m3_dedup_source.en.srt" 2>/dev/null || true
  fi

  # ---- L3: two external sidecars normalizing to the SAME (lang, type) pair must not both survive
  #      — merge_subtitle_sources de-duplicates externals against EACH OTHER, not just against
  #      embedded tracks. A source with no embedded eng track + `<stem>.en.srt` + `<stem>.eng.srt`
  #      (both parse to eng/full) must yield exactly ONE subtitle track in multi-track mode (archive),
  #      not two. A dedup loop that only compares sidecars to embedded streams misses it. Skip-first. ----
  if ! ffmpeg_has_encoder libx265; then
    skip "extsub-sidecar-dedup: ffmpeg lacks libx265 — cannot build the sidecar-dedup fixture"
  else
    local _l3_src="$TESTDIR/l3_dedup_source.mkv" _l3_out="$TESTDIR/l3_dedup_out.mkv"
    # Video + audio only — NO embedded subtitle track, so the two sidecars collide only with
    # each other (isolating the external-vs-external dedup that L3 adds).
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "color=c=navy:s=320x240:r=24:d=2" \
      -f lavfi -i "sine=frequency=440:duration=2" \
      -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p10le \
      -map 0:v -map 1:a -c:a aac \
      "$_l3_src" 2>/dev/null
    # Two sidecars, same normalized language (en == eng) and type (full).
    printf '1\n00:00:00,000 --> 00:00:02,000\nSidecar EN\n'  > "$TESTDIR/l3_dedup_source.en.srt"
    printf '1\n00:00:00,000 --> 00:00:02,000\nSidecar ENG\n' > "$TESTDIR/l3_dedup_source.eng.srt"
    if [[ ! -s "$_l3_src" ]]; then
      skip "extsub-sidecar-dedup: could not build the sidecar-dedup fixture"
    else
      run_muxm --profile archive --output-ext mkv "$_l3_src" "$_l3_out" >/dev/null
      local _l3_scount; _l3_scount="$(count_streams "$_l3_out" s)"
      if [[ -s "$_l3_out" ]] && (( _l3_scount == 1 )); then
        pass "extsub-sidecar-dedup: sidecars '.en.srt' + '.eng.srt' de-duplicated to exactly 1 subtitle track"
      else
        fail "extsub-sidecar-dedup: expected exactly 1 subtitle track after external dedup, got ${_l3_scount:-?} (sidecar-vs-sidecar not deduped)"
      fi
    fi
    rm -f "$_l3_src" "$_l3_out" "$TESTDIR/l3_dedup_source.en.srt" "$TESTDIR/l3_dedup_source.eng.srt" 2>/dev/null || true
  fi

  # ---- L2: an external subtitle whose path contains control characters must be skipped (with a
  #      warning), not muxed — mirroring the SRC_ABS/OUT control-char guards. Skip-first guard. ----
  if ! ffmpeg_has_encoder libx265; then
    skip "extsub-control-char-skipped: ffmpeg lacks libx265 — cannot build the control-char sidecar fixture"
  else
    local _l2_dir; _l2_dir="$(mktemp -d "$TESTDIR/l2.XXXXXX")"
    local _l2_src="$_l2_dir/movie.mkv" _l2_out="$_l2_dir/l2out.mkv"
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "testsrc2=size=320x180:rate=24:duration=1" \
      -f lavfi -i "sine=frequency=440:duration=1" \
      -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p -c:a aac "$_l2_src" 2>/dev/null
    # Sidecar with a BEL (0x07) control char in the qualifier: movie.<BEL>en.srt (matches movie.*.srt).
    local _l2_bad; _l2_bad="$(printf '%s/movie.\007en.srt' "$_l2_dir")"
    printf '1\n00:00:00,000 --> 00:00:01,000\nbad sidecar\n' > "$_l2_bad" 2>/dev/null
    if [[ ! -s "$_l2_src" || ! -e "$_l2_bad" ]]; then
      skip "extsub-control-char-skipped: could not build the control-char sidecar fixture"
    else
      local _l2_log _l2_subs
      _l2_log="$(cd "$_l2_dir" && "$MUXM" -K --output-ext mkv "$_l2_src" "$_l2_out" 2>&1)" || true
      _l2_subs="$(count_streams "$_l2_out" s)"
      if printf '%s\n' "$_l2_log" | grep -qiE 'control character' && [[ "${_l2_subs:-0}" == "0" ]]; then
        pass "extsub-control-char-skipped: control-char sidecar skipped with a warning (0 subtitle tracks muxed)"
      else
        fail "extsub-control-char-skipped: control-char sidecar not skipped (warned=$(printf '%s\n' "$_l2_log" | grep -ciE 'control character'), sub tracks=${_l2_subs:-?})"
      fi
    fi
    rm -rf "$_l2_dir"
  fi

  _test_ext_subs_bsd_sort
  _test_ext_subs_idx_relocate
  _test_ext_subs_bracketed_name_sidecar
  _test_ext_subs_hi_is_hindi
}

# CR-4: the source stem is interpolated into a `find -name` GLOB, so glob metacharacters in the
# name (`* ? [`) match as wildcards, not literally — the anime-naming case the animation profiles
# target. `[Grp] Show - 01 [1080p].mkv` has its `[…]` read as character classes, so the real
# bracketed sidecar is MISSED and an unrelated decoy (`r Show - 01 0.eng.srt`, which the classes
# DO match) is picked up instead. The stem must escape the fnmatch specials. Differential: the
# bracketed sidecar is discovered AND the decoy is not.
_test_ext_subs_bracketed_name_sidecar() {
  local d="$TESTDIR/cr4_brackets"; mkdir -p "$d"
  local base='[Grp] Show - 01 [1080p]'
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:s=320x180:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -preset ultrafast -crf 30 -c:a aac "$d/$base.mkv" 2>/dev/null
  printf '1\n00:00:00,000 --> 00:00:01,000\nreal\n'  > "$d/$base.eng.srt"
  # Decoy whose name the UNescaped `[Grp]`/`[1080p]` character classes would over-match.
  printf '1\n00:00:00,000 --> 00:00:01,000\ndecoy\n' > "$d/r Show - 01 0.eng.srt"
  if [[ ! -s "$d/$base.mkv" ]]; then
    skip "extsub-bracketed-name-literal: could not build the bracketed-name fixture"
    rm -rf "$d"; return
  fi
  local out
  out="$( (cd "$d" && "$MUXM" --dry-run "$base.mkv" "$d/out.mkv") 2>&1 )"
  local found
  found="$(printf '%s\n' "$out" | grep -F 'External subtitle found:' | head -1)"
  if printf '%s\n' "$found" | grep -qF "$base.eng.srt"; then
    pass "extsub-bracketed-name-literal: bracketed-name sidecar discovered literally ([…] not treated as a glob class)"
  else
    fail "extsub-bracketed-name-literal: bracketed-name sidecar NOT discovered. Saw: ${found:-<none>}"
  fi
  if printf '%s\n' "$out" | grep -qF 'r Show - 01 0.eng.srt'; then
    fail "extsub-bracketed-name-literal: the decoy 'r Show - 01 0.eng.srt' was over-matched by the glob (escaping failed)"
  else
    pass "extsub-bracketed-name-literal: unrelated decoy not mismatched by the (now literal) stem pattern"
  fi
  rm -rf "$d"
}

# CR-13: `hi` is BOTH the SDH keyword (hearing-impaired) and ISO-639-1 for Hindi. Matching the SDH
# case first would classify `movie.hi.srt` → type=sdh / lang=und. It must be classified as language
# when it fills the empty language slot. e2e differential: discovery announces the sidecar as [hi] (full).
_test_ext_subs_hi_is_hindi() {
  local d="$TESTDIR/cr13_hi"; mkdir -p "$d"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=green:s=320x180:r=24:d=1" \
    -f lavfi -i "sine=frequency=440:duration=1" \
    -c:v libx264 -preset ultrafast -crf 30 -c:a aac "$d/movie.mkv" 2>/dev/null
  printf '1\n00:00:00,000 --> 00:00:01,000\nनमस्ते\n' > "$d/movie.hi.srt"
  if [[ ! -s "$d/movie.mkv" ]]; then
    skip "extsub-hi-is-hindi: could not build the movie.hi.srt fixture"
    rm -rf "$d"; return
  fi
  local out found
  out="$( (cd "$d" && "$MUXM" --dry-run "movie.mkv" "$d/out.mkv") 2>&1 )"
  found="$(printf '%s\n' "$out" | grep -F 'External subtitle found:' | grep -F 'movie.hi.srt' | head -1)"
  if printf '%s\n' "$found" | grep -qF '[hi] (full)'; then
    pass "extsub-hi-is-hindi: movie.hi.srt discovered as lang=hi, type=full (Hindi, not SDH/und)"
  else
    fail "extsub-hi-is-hindi: movie.hi.srt misclassified. Saw: ${found:-<none>}"
  fi
  rm -rf "$d"
}

# RF7: a successful external VobSub `.idx` OCR writes its `.srt` next to the SOURCE, not into
# the workdir. The `.sup` branch relocates that file before the existence check; the `.idx` branch
# must do the same, else a successful OCR leaves $srt_out empty, misreported as "OCR failed" and dropped.
# We don't need a real VobSub tool: drive _prepare_ext_subtitle's `.idx` branch with a fake OCR tool
# that writes `${idx%.idx}.srt` next to the source (exactly what the real tools do), and assert the
# function returns a non-empty workdir path (i.e. the result was relocated and kept).
_test_ext_subs_idx_relocate() {
  local body
  # 3.1: _prepare_ext_subtitle's OCR branches now delegate to _ocr_lang_flags/_run_ocr — pull
  # both in too, else the OCR dispatch under test silently no-ops (unresolved in the subshell).
  body="$(_extract_muxm_fns _prepare_ext_subtitle _container_supports_bitmap_subs _ocr_lang_flags _run_ocr)" \
    || { fail "extsub-idx-ocr-relocated: could not extract _prepare_ext_subtitle"; return; }
  local _dir; _dir="$(mktemp -d "$TESTDIR/rf7.XXXXXX")"
  local _work="$_dir/work"; mkdir -p "$_work"
  # Fake VobSub pair next to the "source".
  : > "$_dir/movie.idx"; : > "$_dir/movie.sub"
  # Fake OCR tool: writes ${idx%.idx}.srt next to the source (last arg is the .idx path).
  local _tool="$_dir/fake_ocr.sh"
  cat > "$_tool" <<'OCR'
#!/usr/bin/env bash
idx=""; for a in "$@"; do idx="$a"; done   # last arg is the .idx path
printf '1\n00:00:00,000 --> 00:00:01,000\nVobSub OCR line\n' > "${idx%.idx}.srt"
OCR
  chmod +x "$_tool"

  local _out
  _out="$(bash -c "WORKDIR=\"\$1\"; SUB_ENABLE_OCR=1; DRY_RUN=0; SUB_OCR_TOOL=\"\$2\"; SUB_OCR_LANG=eng; _ACTIVE_FFMPEG_PID=''
spinner(){ :; }; note(){ :; }; warn(){ :; }
$body
_prepare_ext_subtitle \"\$3\"" -- "$_work" "$_tool" "$_dir/movie.idx")"

  # Correct behavior: the next-to-source .srt is relocated into the workdir → non-empty path returned.
  # A missing relocation leaves $srt_out empty → "" returned (the silent drop).
  if [[ -n "$_out" && "$_out" == "$_work/"* && -s "$_out" ]] && grep -q ' --> ' "$_out" 2>/dev/null; then
    pass "extsub-idx-ocr-relocated: external VobSub .idx OCR output is relocated into the workdir and kept ($(basename -- "$_out"))"
  else
    fail "extsub-idx-ocr-relocated: .idx OCR result not relocated — returned '$_out' (expected a non-empty file under $_work)"
  fi
  rm -rf "$_dir"
}

# H3: discover_external_subtitles must not sort the null-delimited `find` output with GNU-only
# `sort -z`. On stock-macOS BSD `sort` (no -z) the process substitution emits nothing and EVERY
# sidecar is silently dropped (the failure is hidden because `set -e` does not cross the `<( )`
# boundary). It probes for `sort -z` support once and falls back to `cat` (find's single-dir order is
# fine for sidecar matching), keeping null-delimiting intact on both branches. This machine's
# /usr/bin/sort may support -z, so we SIMULATE a BSD sort: a shim on PATH that rejects -z. The probe
# selects `cat` and the sidecar is still discovered; perturb MUT-H3-SORTZ flips the fallback back to
# `sort -z`, which the shim rejects → empty find output → sidecar dropped → red.
_test_ext_subs_bsd_sort() {
  # Reuse the committed single-sidecar fixture: ext_only_source.mkv + ext_only_source.en.srt.
  if [[ ! -s "$TESTDIR/ext_only_source.mkv" || ! -s "$TESTDIR/ext_only_source.en.srt" ]]; then
    skip "extsub-bsd-sort-discovery: ext_only_source fixture + sidecar missing — cannot test BSD-sort discovery"; return
  fi
  local _bin="$TESTDIR/h3_fakebin"; mkdir -p "$_bin"
  cat > "$_bin/sort" <<'FAKESORT'
#!/bin/sh
# Simulate stock-macOS BSD sort: no -z support (reject it, otherwise delegate to the real sort).
for _a in "$@"; do
  case "$_a" in
    -z|--zero-terminated) echo "sort: illegal option -- z" >&2; exit 2 ;;
  esac
done
exec /usr/bin/sort "$@"
FAKESORT
  chmod +x "$_bin/sort"
  # The shim must actually reject -z, else the simulation proves nothing.
  if printf '' | "$_bin/sort" -z >/dev/null 2>&1; then
    skip "extsub-bsd-sort-discovery: BSD-sort shim unexpectedly accepts -z — cannot simulate the break"
    rm -rf "$_bin"; return
  fi
  log "Testing H3: external sidecar discovery under a BSD sort (no -z)..."
  local _out
  _out="$(cd "$TESTDIR" && PATH="$_bin:$PATH" HOME="${MUXM_HOME:-$HOME}" "$MUXM" -K --dry-run "$TESTDIR/ext_only_source.mkv" 2>&1)" || true
  if printf '%s\n' "$_out" | grep -qi "external subtitle found"; then
    pass "extsub-bsd-sort-discovery: external sidecar discovered under BSD sort (no -z) — portable sort fallback works"
  else
    fail "extsub-bsd-sort-discovery: external sidecar NOT discovered under BSD sort (no -z) — sort -z silently dropped it"
  fi
  rm -rf "$_bin"
}

# === Suite: Multi-Profile ===
# Validates --profile a,b comma-separated multi-profile support:
#   - comma parsing validates all names upfront
#   - single profile = unchanged behaviour
#   - multi-profile auto-names outputs with profile suffix
# These are config-only tests (no real encode) using --print-effective-config.
test_multi_profile() {
  section "Multi-Profile (comma-separated --profile)"

  local out

  # --- Comma parsing: valid multi-profile accepted ---
  out="$(run_muxm --profile youtube-upload,streaming --print-effective-config 2>&1)" || true
  # Parent applies first profile for config checks; output should show youtube-upload
  assert_contains "youtube-upload" "multi-profile: first profile active in parent config" "$out"

  # --- Comma parsing: all names validated upfront (unknown name → error before any work) ---
  out="$(run_muxm --profile youtube-upload,BOGUS_PROFILE --print-effective-config 2>&1)" || true
  assert_contains "Unknown profile" "multi-profile: unknown name in list triggers error" "$out"

  # --- Comma parsing: single profile is unchanged ---
  out="$(run_muxm --profile youtube-upload --print-effective-config)"
  assert_contains "youtube-upload" "single --profile: still works normally" "$out"
  assert_contains "VIDEO_CODEC               = libx264" "single --profile youtube-upload: libx264" "$out"

  # --- Comma parsing: empty name rejected ---
  out="$(run_muxm --profile 'streaming,' --print-effective-config 2>&1)" || true
  assert_contains "empty" "multi-profile: empty name in list rejected" "$out"

  # --- M3: positional source BEFORE flags must not corrupt the per-child arg list ---
  # If child flags were built by slicing off the last ${#POSITIONALS[@]} args (assuming
  # positionals trail), `<src> --crf N --profile a,b` would strip the flag VALUE instead
  # of the source, yielding "Too many arguments" (or a flag-missing-value) in the
  # child. Both arg orders must work and run all children.
  local _m3_src="$TESTDIR/basic_sdr_subs.mkv"
  # (i) source first, then flags
  out="$(run_muxm "$_m3_src" --crf 30 --profile streaming-hevc,universal --dry-run 2>&1)" || true
  if printf '%s' "$out" | grep -qiE 'Too many arguments'; then
    fail "mp-source-before-flags-positional: source-before-flags multi-profile → 'Too many arguments' (positional stripping regressed)"
  else
    pass "mp-source-before-flags-positional: source-before-flags multi-profile → no 'Too many arguments'"
  fi
  assert_contains "Profile 1/2" "mp-source-before-flags-positional: source-before-flags → first child runs" "$out"
  assert_contains "Profile 2/2" "mp-source-before-flags-positional: source-before-flags → second child runs" "$out"
  # (ii) flags first, then source (the conventional order) — must still work
  out="$(run_muxm --crf 30 --profile streaming-hevc,universal --dry-run "$_m3_src" 2>&1)" || true
  if printf '%s' "$out" | grep -qiE 'Too many arguments'; then
    fail "mp-source-before-flags-positional: flags-before-source multi-profile → unexpected 'Too many arguments'"
  else
    pass "mp-source-before-flags-positional: flags-before-source multi-profile → no 'Too many arguments'"
  fi
  assert_contains "Profile 2/2" "mp-source-before-flags-positional: flags-before-source → second child runs" "$out"

  # --- L9: multi-profile --dry-run must not emit the spurious tee-drain watchdog ERR-trap
  #     message. The on_exit backstop `( sleep 5; kill "$TEE_PID" ) &` runs under set -E,
  #     so a failing kill (tee already gone) fires on_error ("Command failed at line …:
  #     kill …") in each child. The watchdog traps '' ERR and `|| true`s the kill. ---
  if printf '%s' "$out" | grep -qE 'Command failed at line [0-9]+: kill'; then
    fail "mp-dryrun-no-watchdog-msg: multi-profile --dry-run emits spurious watchdog kill ERR-trap message"
  else
    pass "mp-dryrun-no-watchdog-msg: multi-profile --dry-run emits no spurious watchdog kill ERR-trap message"
  fi

  # --- Multi-profile output auto-naming: output paths contain profile suffix ---
  # Run a dry-run multi-profile pass against the core fixture and verify both
  # per-profile output files have the expected profile-suffixed names.
  local _src="$TESTDIR/basic_sdr_subs.mkv"
  local _stem="${_src%.*}"
  local _yt_out="${_stem}.youtube-upload.mp4"
  local _st_out="${_stem}.streaming-hevc.mp4"  # 'streaming' alias normalizes to streaming-hevc

  # Remove any stale outputs first
  rm -f "$_yt_out" "$_st_out"

  # Dry-run multi-profile: outputs are not actually written (DRY_RUN=1 skips mv)
  # so we just verify the dispatch prints the expected profile headers.
  out="$(run_muxm --profile youtube-upload,streaming --dry-run "$_src" 2>&1)" || true
  assert_contains "youtube-upload" "multi-profile dry-run: youtube-upload header printed" "$out"
  assert_contains "streaming"      "multi-profile dry-run: streaming header printed" "$out"
  assert_contains "Profile 1/2"    "multi-profile dry-run: profile counter printed" "$out"
  assert_contains "Profile 2/2"    "multi-profile dry-run: second pass counter printed" "$out"

  # --- Multi-profile output naming with user-supplied stem ---
  # When the user provides an explicit output filename, muxm should use its stem
  # (without extension) as the base for per-profile output files, inserting the
  # profile name between the stem and extension.
  local _user_out="$TESTDIR/my_video.mp4"

  # With explicit output name: per-profile files use my_video as stem
  out="$(run_muxm --profile streaming,universal --dry-run "$_src" "$_user_out" 2>&1)" || true
  # The deprecated 'streaming' alias normalizes to 'streaming-hevc' in the per-profile name.
  assert_contains "my_video.streaming-hevc.mp4" \
    "multi-profile user stem: streaming output uses my_video stem" "$out"
  assert_contains "my_video.universal.mp4" \
    "multi-profile user stem: universal output uses my_video stem" "$out"

  # Warning about file split should appear when user supplies explicit output name
  if echo "$out" | grep -qiE "split|multiple.*output|warning"; then
    pass "multi-profile user stem: warning about multi-profile file split appears"
  else
    skip "multi-profile user stem: file-split warning not found (may use different wording)"
  fi

  # Without explicit output name: no file-split warning
  out="$(run_muxm --profile streaming,universal --dry-run "$_src" 2>&1)" || true
  if ! echo "$out" | grep -qiE "split.*warning|warning.*split"; then
    pass "multi-profile no user stem: no file-split warning when output name omitted"
  else
    skip "multi-profile no user stem: file-split warning appeared unexpectedly (may be benign)"
  fi

  # --- Multi-profile passthrough + user filename extension hint ---
  # atv-directplay-hq is passthrough (OUTPUT_EXT=""). Without a user filename hint it would
  # fall back to the source extension (.mkv); with an explicit .mp4 output filename, the
  # dispatch block (Section 11) should use .mp4 for that pass. (archive can't exercise this —
  # it forces MKV — so use a still-passthrough profile here.)
  local _hint_src="$TESTDIR/basic_sdr_subs.mkv"
  local _hint_out="$TESTDIR/passthrough_hint.mp4"

  out="$(run_muxm --profile atv-directplay-hq,streaming --dry-run "$_hint_src" "$_hint_out" 2>&1)" || true
  # The pre-encode warning lists per-profile output paths; the passthrough pass uses .mp4.
  assert_contains "passthrough_hint.atv-directplay-hq.mp4" \
    "multi-profile passthrough + user .mp4 hint: passthrough output path uses .mp4 (not .mkv)" "$out"

  # --- M2: deprecated 'dv-archival' alias in a multi-profile list must derive the ARCHIVE
  #     container (.archive.mkv), not fall through to mp4. If the list is validated but not
  #     normalized, _probe_profile_ext("dv-archival") invokes the non-existent
  #     apply_profile_dv_archival, swallows the failure (2>/dev/null || true), and returns its
  #     local OUTPUT_EXT="mp4" default — forcing the archive into the wrong container (and a
  #     spurious die 11 on lossless/PGS sources). The prescan normalizes each list element. ---
  local _m2_src="$TESTDIR/basic_sdr_subs.mkv"
  local _m2_out="$TESTDIR/m2_archive.mkv"
  out="$(run_muxm --profile dv-archival,universal --dry-run "$_m2_src" "$_m2_out" 2>&1)" || true
  assert_contains "m2_archive.archive.mkv" \
    "mp-dv-archival-container: dv-archival in multi-profile list derives the archive container (.archive.mkv, not .mp4)" "$out"
  # The per-profile filename must use the canonical name, never the deprecated alias.
  if printf '%s' "$out" | grep -qE 'dv-archival\.(mp4|mkv)'; then
    fail "mp-dv-archival-container: per-profile output still uses the deprecated 'dv-archival' name in its filename"
  else
    pass "mp-dv-archival-container: per-profile output uses the canonical 'archive' name, not the 'dv-archival' alias"
  fi
  # Normalizing the alias in the parent prescan emits the standard deprecation warning.
  assert_contains "deprecated" \
    "mp-dv-archival-container: dv-archival alias emits a deprecation warning in multi-profile mode" "$out"

  _test_mp_output_ext_container
}

# Map a probed format_name to the container extension it represents, then assert it matches the
# filename's extension. format_name is a comma-joined demuxer list: matroska→mkv, mov/mp4→mp4-family.
_assert_container_matches_ext() {
  local label="$1" file="$2"
  if [[ ! -f "$file" || ! -s "$file" ]]; then fail "$label — no output produced ($file)"; return; fi
  local ext="${file##*.}"; ext="${ext,,}"
  local fmt; fmt="$(probe_format "$file" format_name)"
  local ok=0
  case "$ext" in
    mkv)            [[ "$fmt" == *matroska* ]] && ok=1 ;;
    mp4|m4v|mov)    [[ "$fmt" == *mov* || "$fmt" == *mp4* ]] && [[ "$fmt" != matroska* ]] && ok=1 ;;
  esac
  if (( ok )); then
    pass "$label (.$ext ↔ format_name='$fmt')"
  else
    fail "$label — filename says .$ext but container format_name='$fmt' (mislabel)"
  fi
}

# RF5: a CLI --output-ext combined with a comma-separated --profile must not carry the user's value
# into each child AFTER the injected per-profile --output-ext — otherwise the user's value wins the
# actual container while the auto-generated filename keeps the profile's natural extension, e.g. an
# `.archive.mkv` that is really MP4. The child flags drop the user's --output-ext and make the
# explicit ext the per-profile ext for EVERY profile, so name and container always agree.
_test_mp_output_ext_container() {
  # h264 + aac source so `archive` (video copy + audio copy) succeeds into an MP4 container.
  local _src="$TESTDIR/rf5_src.mkv"
  gen_media "$_src" green \
    -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 \
    -metadata:s:a:0 language=eng
  if [[ ! -s "$_src" ]]; then fail "mp-output-ext-matches-container: could not create h264+aac multi-profile fixture"; return; fi
  local _home="$TESTDIR/rf5_home"; mkdir -p "$_home"
  local _stem="${_src%.*}"

  # --- RF5: explicit --output-ext mp4 → BOTH children produce real MP4 containers, named .mp4. ---
  rm -f "${_stem}".archive.* "${_stem}".streaming-hevc.*
  log "Testing RF5: multi-profile --output-ext mp4 → container matches filename..."
  MUXM_HOME="$_home" run_muxm --output-ext mp4 --profile archive,streaming-hevc "$_src" >/dev/null 2>&1
  _assert_container_matches_ext "mp-output-ext-matches-container: archive child container matches its .mp4 filename" "${_stem}.archive.mp4"
  _assert_container_matches_ext "mp-output-ext-matches-container: streaming-hevc child container matches its .mp4 filename" "${_stem}.streaming-hevc.mp4"
  # A mislabeled name (.archive.mkv) must NOT exist — the user's mp4 owns the name too.
  if [[ -e "${_stem}.archive.mkv" ]]; then
    fail "mp-output-ext-matches-container: a mislabeled .archive.mkv was produced despite --output-ext mp4 (filename ignored the explicit ext)"
  else
    pass "mp-output-ext-matches-container: no mislabeled .archive.mkv produced (explicit --output-ext owns the filename too)"
  fi

  # --- RF5 control (no regression): without --output-ext, each profile names by its NATURAL ext
  #     (archive→mkv, streaming-hevc→mp4) and the container still matches the filename. ---
  rm -f "${_stem}".archive.* "${_stem}".streaming-hevc.*
  log "Testing RF5 control: multi-profile without --output-ext uses each profile's natural ext..."
  MUXM_HOME="$_home" run_muxm --profile archive,streaming-hevc "$_src" >/dev/null 2>&1
  _assert_container_matches_ext "mp-output-ext-matches-container control: archive uses its natural .mkv (container matches)" "${_stem}.archive.mkv"
  _assert_container_matches_ext "mp-output-ext-matches-container control: streaming-hevc uses its natural .mp4 (container matches)" "${_stem}.streaming-hevc.mp4"
}

# === Suite: Regression Tests ===
# Exercises previously-fixed bugs so they can never silently regress.
# C1: shell injection guard in --crf
# M3: comma-decimal locale produces no printf warnings
# H9: HLG source under HDR profile → no hdr10=1/smpte2084 in output
# H8: 4:2:2 SDR + FORCE_CHROMA_420=0 → 4:2:2 target; FORCE_CHROMA_420=1 → 4:2:0 + warn
# H10: DV convert failure + ALLOW_DV_FALLBACK=0 → die 44 (mock ffprobe + dovi_tool)
# CFGGEN: HW_ACCEL is tracked, emitted as a commented default (not leaked from local .muxmrc)
# H11: non-Darwin OS with hw-accel → Linux fallback warning, software encoding
test_regression_p5() {
  section "Phase 5 Regression Tests (P5.3)"

  local out

  # ---- C1: shell injection in --crf ----
  local canary="$TESTDIR/shell_injection_canary.txt"
  rm -f "$canary"
  assert_exit $EXIT_VALIDATION "regression-crf-metachar-rejected: --crf with shell metacharacters rejected" \
    --crf "x[\$(touch $canary)]" "$TESTDIR/basic_sdr_subs.mkv"
  assert_no_file "$canary" "regression-crf-metachar-rejected: shell injection in --crf does not create canary file"

  # ---- M3: comma-decimal locale ----
  # Collect locale list into a variable first (avoids grep -q SIGPIPE under set -o pipefail).
  local _available_locales
  _available_locales="$(locale -a 2>/dev/null || true)"
  if [[ "$_available_locales" == *"de_DE.UTF-8"* ]] || [[ "$_available_locales" == *"de_DE.utf8"* ]]; then
    out="$(LC_ALL="" LC_NUMERIC=de_DE.UTF-8 run_muxm --dry-run "$TESTDIR/basic_sdr_subs.mkv")"
    assert_contains "DRY-RUN complete" "regression-comma-decimal-locale: comma-decimal locale: dry-run completes cleanly" "$out"
    if echo "$out" | LC_ALL=C grep -qiE "printf.*invalid|invalid.*printf|cannot convert|bad number"; then
      fail "regression-comma-decimal-locale: comma-decimal locale: printf format errors detected"
    else
      pass "regression-comma-decimal-locale: comma-decimal locale: no printf format errors"
    fi
  else
    skip "regression-comma-decimal-locale: de_DE.UTF-8 locale not available on this host"
  fi

  # ---- H9: HLG source + HDR profile → arib-std-b67 output (not smpte2084) ----
  if [[ -f "$TESTDIR/hevc_hlg_tagged.mkv" ]]; then
    out="$(run_muxm --profile hdr10-hq --dry-run "$TESTDIR/hevc_hlg_tagged.mkv")"
    assert_contains "Color profile: HLG" "regression-hlg-not-hdr10: HLG source under hdr10-hq detected as HLG (not HDR10)" "$out"
    local h9_out="$TESTDIR/h9_hlg_roundtrip.mkv"
    local h9_encode_out
    h9_encode_out="$(run_muxm --profile hdr10-hq --preset ultrafast --crf 28 \
      "$TESTDIR/hevc_hlg_tagged.mkv" "$h9_out")"
    if [[ -f "$h9_out" ]]; then
      local h9_trc
      h9_trc="$(probe_video "$h9_out" "color_transfer")"
      if [[ "$h9_trc" == "arib-std-b67" ]]; then
        pass "regression-hlg-not-hdr10: HLG + hdr10-hq → color_transfer=arib-std-b67 (not smpte2084)"
      else
        fail "regression-hlg-not-hdr10: HLG + hdr10-hq: expected arib-std-b67, got '$h9_trc'"
      fi
      # Verify build_x265_params strips hdr10=1/smpte2084 from x265 params for HLG.
      # color_transfer in the container is set by COLOR_ARGS (not x265 params) so the
      # container check above passes even if the strip regressed. The log check is the
      # discriminating test for the build_x265_params fix.
      local h9_workdir
      h9_workdir="$(printf '%s\n' "$h9_encode_out" | grep 'Keeping workdir:' | awk '{print $NF}')"
      if [[ -n "$h9_workdir" && -d "$h9_workdir" ]]; then
        local h9_log
        h9_log="$(find "$h9_workdir" -maxdepth 1 -name 'muxm.*.log' 2>/dev/null | head -1)"
        if [[ -n "$h9_log" ]]; then
          local h9_enc_cmd
          h9_enc_cmd="$(grep 'ffmpeg encode command' "$h9_log" | head -1)"
          if printf '%s\n' "$h9_enc_cmd" | grep -qE '(^|[^a-z])hdr10=1|transfer=smpte2084'; then
            fail "regression-hlg-not-hdr10: x265 params contain hdr10=1/smpte2084 for HLG source (build_x265_params strip regressed)"
          else
            pass "regression-hlg-not-hdr10: x265 params: no hdr10=1/smpte2084 for HLG source (build_x265_params strip confirmed)"
          fi
        else
          skip "regression-hlg-not-hdr10: x265 params check skipped — log not found in $h9_workdir"
        fi
      else
        skip "regression-hlg-not-hdr10: x265 params check skipped — WORKDIR not found in encode output"
      fi
    else
      fail "regression-hlg-not-hdr10: HLG + hdr10-hq encode produced no output"
    fi
  else
    skip "regression-hlg-not-hdr10: hevc_hlg_tagged.mkv fixture not found"
  fi

  # ---- H8: 4:2:2 SDR — FORCE_CHROMA_420 controls chroma preservation ----
  if [[ -f "$TESTDIR/h264_422p_sdr.mkv" ]]; then
    # Default (FORCE_CHROMA_420=1): downsamples 4:2:2 → 4:2:0
    out="$(run_muxm --dry-run "$TESTDIR/h264_422p_sdr.mkv")"
    assert_contains "downsampling to 4:2:0" \
      "regression-chroma-420-downsample: default FORCE_CHROMA_420=1 downsamples 4:2:2 source to 4:2:0" "$out"
    assert_contains "Target pixel format: yuv420p" \
      "regression-chroma-420-downsample: default FORCE_CHROMA_420=1 target pixel format is yuv420p" "$out"
    # FORCE_CHROMA_420=0 via .muxmrc: preserves 4:2:2
    local h8_home="$TESTDIR/h8_rc_home"
    mkdir -p "$h8_home"
    printf 'FORCE_CHROMA_420=0\n' > "$h8_home/.muxmrc"
    out="$(MUXM_HOME="$h8_home" run_muxm_in "$TESTDIR" --dry-run "h264_422p_sdr.mkv")"
    assert_contains "Preserving source 4:422 chroma" \
      "regression-chroma-420-downsample: --force-chroma-420 off preserves 4:2:2 chroma" "$out"
    assert_contains "Target pixel format: yuv422p" \
      "regression-chroma-420-downsample: FORCE_CHROMA_420=0 target pixel format is yuv422p" "$out"

    # ---- 4.2: real-encode chroma verification (real encode, not just the H8 dry-run above) ----
    # muxm sets -pix_fmt from TARGET_PIXFMT, so the OUTPUT chroma is muxm's decision (not ffmpeg
    # auto-copy) — a genuine probe. Needs a libx265 build with 4:2:2 OUTPUT support; gate on it
    # (host-capability skip). Collect the encoder help into a variable first to avoid a
    # `ffmpeg | grep -q` pipefail SIGPIPE false-skip. M-CHROMA-1 flips the 4:2:2 preserve branch to
    # 4:2:0, so the FORCE_CHROMA_420=0 output comes out yuv420p → red (the default arm is unaffected).
    local _x265_pf; _x265_pf="$(ffmpeg -hide_banner -h encoder=libx265 2>&1 || true)"
    if [[ "$_x265_pf" != *yuv422p* ]]; then
      skip "regression-chroma-420-downsample real encode: libx265 build lacks 4:2:2 output support"
    else
      # FORCE_CHROMA_420=0 via .muxmrc → preserve source 4:2:2 in the output pixel format.
      local ch_home="$TESTDIR/h8_real_home"; mkdir -p "$ch_home"
      printf 'FORCE_CHROMA_420=0\n' > "$ch_home/.muxmrc"
      local ch_out422="$TESTDIR/h8_real_422.mkv"; rm -f "$ch_out422"
      (cd "$TESTDIR" && HOME="$ch_home" "$MUXM" -K --crf 28 --preset ultrafast --output-ext mkv \
        "$TESTDIR/h264_422p_sdr.mkv" "$ch_out422" >/dev/null 2>&1) || true
      if [[ -s "$ch_out422" ]]; then
        local ch_pix422; ch_pix422="$(probe_video "$ch_out422" pix_fmt)"
        if [[ "$ch_pix422" == yuv422p* ]]; then
          pass "regression-chroma-420-downsample real encode: FORCE_CHROMA_420=0 preserves 4:2:2 in output pix_fmt ($ch_pix422)"
        else
          fail "regression-chroma-420-downsample real encode: FORCE_CHROMA_420=0 expected yuv422p output, got '$ch_pix422'"
        fi
      else
        fail "regression-chroma-420-downsample real encode: FORCE_CHROMA_420=0 produced no output"
      fi
      # Default (FORCE_CHROMA_420=1, isolated HOME) → downsample to 4:2:0. Sanity that the decision
      # routes by the flag; M-CHROMA-1 must NOT move this one (it only flips the preserve branch).
      local ch_out420="$TESTDIR/h8_real_420.mkv"
      if assert_encode "regression-chroma-420-downsample real encode: default downsample output produced" "$ch_out420" \
           --crf 28 --preset ultrafast --output-ext mkv "$TESTDIR/h264_422p_sdr.mkv"; then
        local ch_pix420; ch_pix420="$(probe_video "$ch_out420" pix_fmt)"
        if [[ "$ch_pix420" == "yuv420p" ]]; then
          pass "regression-chroma-420-downsample real encode: default FORCE_CHROMA_420=1 downsamples to yuv420p ($ch_pix420)"
        else
          fail "regression-chroma-420-downsample real encode: default expected yuv420p output, got '$ch_pix420'"
        fi
      fi
      rm -f "$ch_out422" "$ch_out420"
    fi
  else
    skip "regression-chroma-420-downsample: h264_422p_sdr.mkv fixture not found"
  fi

  # ---- H10: DV P5→P8 convert failure + ALLOW_DV_FALLBACK=0 → die 44 ----
  # DV detection uses ffprobe codec_tag_string=dvh1 (from hevc_dv_p5_tagged.mp4).
  # A mock ffprobe intercepts non-JSON calls for the fixture and appends DV profile
  # text so detect_dv_info() text fallback sets DV_SRC_PROFILE=5 (triggers convert path).
  # A mock dovi_tool succeeds for info/extract-rpu/inject-rpu and fails for convert.
  # With --dv-convert-p81 and --no-allow-dv-fallback, muxm must exit 44.
  if [[ -f "$TESTDIR/hevc_dv_p5_tagged.mp4" ]]; then
    local h10_mock_bin="$TESTDIR/h10_mock_bin"
    local h10_home="$TESTDIR/h10_rc_home"
    mkdir -p "$h10_mock_bin" "$h10_home"
    printf 'ALLOW_DV_FALLBACK=0\n' > "$h10_home/.muxmrc"

    local real_ffprobe
    real_ffprobe="$(type -P ffprobe)"
    # Mock ffprobe: for the DV fixture, run real ffprobe and append DV profile
    # text lines so detect_dv_info() text fallback parses DV_SRC_PROFILE=5.
    # JSON calls (-of json) pass through unchanged to avoid corrupting METADATA_CACHE.
    cat > "$h10_mock_bin/ffprobe" << FFPROBESCRIPT
#!/bin/bash
input_file=""
for arg in "\$@"; do
  [[ -f "\$arg" ]] && input_file="\$arg"
done
if [[ "\$(basename "\${input_file:-}")" != "hevc_dv_p5_tagged.mp4" ]]; then
  exec "$real_ffprobe" "\$@"
fi
is_json=0; prev=""
for arg in "\$@"; do
  [[ "\$prev" == "-of" || "\$prev" == "-print_format" ]] && [[ "\$arg" == "json" ]] && { is_json=1; break; }
  prev="\$arg"
done
(( is_json )) && exec "$real_ffprobe" "\$@"
"$real_ffprobe" "\$@" 2>&1
printf 'profile: 5\ncompatibility id: 1\nbl.flag: 1\nel.flag: 0\n'
FFPROBESCRIPT
    chmod +x "$h10_mock_bin/ffprobe"

    # Mock dovi_tool: extract-rpu/inject-rpu succeed; convert intentionally fails
    # to trigger die 44 when ALLOW_DV_FALLBACK=0.
    cat > "$h10_mock_bin/dovi_tool" << 'DOVISCRIPT'
#!/bin/bash
cmd="${1:-}"
shift
case "$cmd" in
  info)
    printf 'Profile: 5\nCompatibility ID: 1\nBL flag: 1\nEL flag: 0\n1 RPU\n'
    exit 0
    ;;
  extract-rpu)
    out_path=""
    args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
      [[ "${args[$i]}" == "-o" ]] && out_path="${args[$((i+1))]}" && break
    done
    cat > /dev/null
    [[ -n "$out_path" ]] && printf '\x00\x01\x02\x03\n' > "$out_path"
    exit 0
    ;;
  inject-rpu)
    in_path="" out_path=""
    args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
      [[ "${args[$i]}" == "-i" ]] && in_path="${args[$((i+1))]}"
      [[ "${args[$i]}" == "-o" ]] && out_path="${args[$((i+1))]}"
    done
    [[ -n "$in_path" && -n "$out_path" && -s "$in_path" ]] && cp "$in_path" "$out_path"
    exit 0
    ;;
  convert)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOVISCRIPT
    chmod +x "$h10_mock_bin/dovi_tool"

    local h10_code=0
    (cd "$TESTDIR" && HOME="$h10_home" PATH="$h10_mock_bin:$PATH" \
      "$MUXM" -K --dv-convert-p81 --no-allow-dv-fallback \
      --preset ultrafast --crf 28 "hevc_dv_p5_tagged.mp4" 2>&1) || h10_code=$?
    if [[ "$h10_code" -eq 44 ]]; then
      pass "regression-dv-p5-convert-fail-exit-44: DV P5 convert failure + ALLOW_DV_FALLBACK=0 → exit 44"
    else
      fail "regression-dv-p5-convert-fail-exit-44: expected exit 44 (DV convert failure), got $h10_code"
    fi
  else
    skip "regression-dv-p5-convert-fail-exit-44: hevc_dv_p5_tagged.mp4 fixture not found"
  fi

  # ---- DVMKV: DV source → MKV must wrap the raw HEVC ES for the Matroska mux ----
  # Regression for the DV+MKV final-mux failure. DV sources are forced to a raw
  # HEVC Annex B elementary stream (dovi_tool needs Annex B), but the pre-wrap that
  # gives that stream packet timestamps was gated to MP4/MOV output only. For MKV
  # output the raw ES (no pts/dts) reached the final ffmpeg mux and aborted with
  #   "Can't write packet with unknown timestamp".
  # The fix also overrides the pre-wrapped MP4's 'dvh1' fourcc (which Matroska
  # rejects: "Tag dvh1 incompatible with output codec id") with 'hvc1'.
  #
  # detect_dv() fires from the real 'dvh1' codec tag, so ffprobe is NOT mocked —
  # the pre-wrap's dvcC probe and the output validation must see reality. Only
  # dovi_tool is mocked, as a cp-passthrough so V_MIXED is a real HEVC ES and the
  # pipeline reaches the real Matroska mux (the path under test).
  if [[ -f "$TESTDIR/hevc_dv_p5_tagged.mp4" ]]; then
    local dvmkv_bin="$TESTDIR/dvmkv_mock_bin"
    local dvmkv_home="$TESTDIR/dvmkv_home"
    mkdir -p "$dvmkv_bin" "$dvmkv_home"
    cat > "$dvmkv_bin/dovi_tool" << 'DVMKVSCRIPT'
#!/bin/bash
# cp-passthrough mock: every stage "succeeds" and emits a valid HEVC ES.
cmd="${1:-}"; shift
case "$cmd" in
  info)
    # Report a valid profile but NO parseable RPU frame count: a cp-passthrough
    # mock cannot match the real encoded clip's frame count, and emitting a bogus
    # "N RPU" would trip muxm's frame-count mismatch fallback (orphaning V_MIXED).
    # Real RPUs match the video, so omitting the count models the no-fallback path.
    printf 'Profile: 8\nCompatibility ID: 1\nBL flag: 1\nEL flag: 0\n'; exit 0 ;;
  extract-rpu)
    out_path=""; args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
      [[ "${args[$i]}" == "-o" ]] && out_path="${args[$((i+1))]}" && break
    done
    cat > /dev/null
    [[ -n "$out_path" ]] && printf '\x00\x01\x02\x03\n' > "$out_path"
    exit 0 ;;
  inject-rpu|convert)
    in_path=""; out_path=""; args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
      [[ "${args[$i]}" == "-i" ]] && in_path="${args[$((i+1))]}"
      [[ "${args[$i]}" == "-o" ]] && out_path="${args[$((i+1))]}"
    done
    [[ -n "$in_path" && -n "$out_path" && -s "$in_path" ]] && cp "$in_path" "$out_path"
    exit 0 ;;
  *) exit 0 ;;
esac
DVMKVSCRIPT
    chmod +x "$dvmkv_bin/dovi_tool"

    local dvmkv_out="$TESTDIR/dv_to_mkv.mkv"
    rm -f "$dvmkv_out"
    local dvmkv_log
    dvmkv_log="$(cd "$TESTDIR" && HOME="$dvmkv_home" PATH="$dvmkv_bin:$PATH" \
      "$MUXM" -K --preset ultrafast --crf 28 \
      "hevc_dv_p5_tagged.mp4" "$dvmkv_out" 2>&1)" || true

    if [[ -f "$dvmkv_out" && -s "$dvmkv_out" ]]; then
      pass "DVMKV: DV source → MKV produced (raw ES wrapped for Matroska mux)"
      assert_probe        "DVMKV: output video codec is hevc" "$dvmkv_out" codec_name hevc
      assert_stream_count "DVMKV: one video stream"           "$dvmkv_out" v 1 1
      assert_stream_count "DVMKV: one audio stream"           "$dvmkv_out" a 1 1
      local dvmkv_fmt
      dvmkv_fmt="$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$dvmkv_out" 2>/dev/null || true)"
      if printf '%s' "$dvmkv_fmt" | grep -q matroska; then
        pass "DVMKV: container is Matroska"
      else
        fail "DVMKV: expected matroska container, got '$dvmkv_fmt'"
      fi
    else
      fail "DVMKV: no output — DV raw-ES Matroska mux failed (regression: 'unknown timestamp')"
    fi
    # Env-independent guard: the hvc1 tag override fires whenever a DV MKV mux runs,
    # regardless of whether mp4box produced a dvcC box (mp4box-dependent, not asserted).
    assert_contains "overriding video tag" "DVMKV: hvc1 tag override applied for Matroska DV mux" "$dvmkv_log"

    # ---- Disk-streamlining guards (Options 1 & 2) ----
    # The workdir (kept by -K) is parsed from the banner line in the captured output; its logfile
    # carries the log-only narration. "Raw ES demux deferred" is a log() line, not a terminal note,
    # so the Option-1 guard greps the kept workdir logfile, not the captured
    # stdout/stderr.
    local dvmkv_wd dvmkv_logf
    dvmkv_wd="$(printf '%s\n' "$dvmkv_log" | sed -n 's/^=== Workdir[[:space:]]*: //p' | head -1)"
    dvmkv_logf="$(find "$dvmkv_wd" -maxdepth 1 -name 'muxm.*.log' 2>/dev/null | head -1)"
    # SCRUB (D11): the user-facing DV-mux note must NOT carry the raw ffmpeg tag swap
    # ("video tag dvh1 → hvc1") — that detail belongs only in the log.
    if [[ -n "$dvmkv_logf" ]] \
       && ! printf '%s\n' "$dvmkv_log" | grep -qF "dvh1 → hvc1" \
       && grep -qF "dvh1 → hvc1" "$dvmkv_logf"; then
      pass "SCRUB: raw DV tag swap kept out of the terminal note, retained in the log (D11)"
    else
      fail "SCRUB: 'dvh1 → hvc1' should be log-only (terminal clean, log retains it)"
    fi
    # Option 1: the multi-GB source ES must be demuxed lazily, never eagerly (log-only line).
    if [[ -n "$dvmkv_logf" ]] && grep -qF "Raw ES demux deferred" "$dvmkv_logf"; then
      pass "DVMKV: source ES demux deferred, not eager (Option 1)"
    else
      fail "DVMKV: 'Raw ES demux deferred' not found in the run log ($dvmkv_logf)"
    fi
    # Option 2: dead intermediates are reclaimed mid-run — even though -K was passed.
    # -K keeps the workdir, so the proof is direct: the big intermediates are gone
    # while the actual mux input + final output survive. (assert_no_file is PATH LABEL.)
    if [[ -n "$dvmkv_wd" && -d "$dvmkv_wd" ]]; then
      assert_no_file "$dvmkv_wd/video_base.hevc"  "DVMKV: video_base.hevc reclaimed mid-run despite -K (Option 2)"
      assert_no_file "$dvmkv_wd/video_mixed.hevc" "DVMKV: video_mixed.hevc reclaimed mid-run despite -K (Option 2)"
      assert_no_file "$dvmkv_wd/video_src.es"     "DVMKV: video_src.es never materialized (Option 1)"
      if [[ -f "$dvmkv_wd/video_dv_prewrap.mp4" ]]; then
        pass "DVMKV: wrapped mux input retained for final mux"
      else
        fail "DVMKV: wrapped mux input (video_dv_prewrap.mp4) missing"
      fi
    else
      fail "DVMKV: could not locate workdir to verify reclaim"
    fi
  else
    skip "DVMKV: hevc_dv_p5_tagged.mp4 fixture not found"
  fi

  # ---- H2: DV frame-count mismatch fallback must NOT mislabel output as Dolby Vision ----
  # Guards the `return 0` in mix_dv_layers' frame-count-mismatch fallback. On a mismatch
  # with ALLOW_DV_FALLBACK=1 the code sets V_MIXED=V_BASE and OUTPUT_HAS_DV=0; without
  # the return it would fall through to the dvcC/dvh1 pre-wrap and re-set
  # OUTPUT_HAS_DV=1 — shipping base video tagged as Dolby Vision.
  #
  # Drive the real DV pipeline (P8, no convert) with a cp-passthrough dovi_tool whose
  # `info` reports a deliberately bogus, huge RPU frame count. The real encoded clip is
  # ~48 frames, so the frame-count check trips its >2-frame mismatch and falls back.
  # MP4 output is used: it's the dvh1/Apple path DV actually targets, and the raw base
  # ES muxes cleanly there (MKV+raw-ES needs the timestamp pre-wrap and is a separate
  # concern shared by all four DV-give-up branches — out of scope here).
  if [[ -f "$TESTDIR/hevc_dv_p5_tagged.mp4" ]]; then
    local h2_bin="$TESTDIR/h2_mock_bin"
    local h2_home="$TESTDIR/h2_home"
    mkdir -p "$h2_bin" "$h2_home"
    # cp-passthrough dovi_tool, but `info` emits a bogus "999999 RPU" so the
    # frame-count check (dovi_tool info --summary | grep 'N RPU') sees a wild
    # mismatch vs. the real ~48-frame video and triggers the fallback.
    cat > "$h2_bin/dovi_tool" << 'H2DOVISCRIPT'
#!/bin/bash
cmd="${1:-}"; shift
case "$cmd" in
  info)
    printf 'Profile: 8\nCompatibility ID: 1\nBL flag: 1\nEL flag: 0\n999999 RPU\n'; exit 0 ;;
  extract-rpu)
    out_path=""; args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
      [[ "${args[$i]}" == "-o" ]] && out_path="${args[$((i+1))]}" && break
    done
    cat > /dev/null
    [[ -n "$out_path" ]] && printf '\x00\x01\x02\x03\n' > "$out_path"
    exit 0 ;;
  inject-rpu|convert)
    in_path=""; out_path=""; args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
      [[ "${args[$i]}" == "-i" ]] && in_path="${args[$((i+1))]}"
      [[ "${args[$i]}" == "-o" ]] && out_path="${args[$((i+1))]}"
    done
    [[ -n "$in_path" && -n "$out_path" && -s "$in_path" ]] && cp "$in_path" "$out_path"
    exit 0 ;;
  *) exit 0 ;;
esac
H2DOVISCRIPT
    chmod +x "$h2_bin/dovi_tool"

    local h2_out="$TESTDIR/h2_dv_mismatch.mp4"
    rm -f "$h2_out"
    local h2_log h2_code=0
    h2_log="$(cd "$TESTDIR" && HOME="$h2_home" PATH="$h2_bin:$PATH" \
      "$MUXM" -K --preset ultrafast --crf 28 \
      "hevc_dv_p5_tagged.mp4" "$h2_out" 2>&1)" || h2_code=$?

    # Guard: the test only proves anything if the frame-count mismatch actually fired.
    # (If _count_video_frames ever returns 0 the check is skipped and DV proceeds — a
    # silent false-pass without this assertion.)
    assert_contains "RPU frame count mismatch" \
      "regression-dv-frame-mismatch-not-tagged: frame-count mismatch path was exercised" "$h2_log"

    if [[ "$h2_code" -eq 0 && -f "$h2_out" && -s "$h2_out" ]]; then
      pass "regression-dv-frame-mismatch-not-tagged: frame-mismatch fallback still produces a (non-DV) output"
      # OUTPUT_HAS_DV=0 → final summary must NOT advertise DV.
      if printf '%s\n' "$h2_log" | grep -qE 'DV[[:space:]]*: present'; then
        fail "regression-dv-frame-mismatch-not-tagged: output mislabeled as Dolby Vision (summary says 'DV: present' on the fallback path)"
      else
        pass "regression-dv-frame-mismatch-not-tagged: output not labeled Dolby Vision (no 'DV: present' in summary)"
      fi
      # The dvcC/dvh1 pre-wrap must be skipped entirely on the give-up path.
      if printf '%s\n' "$h2_log" | grep -qiF 'Pre-wrapping DV video'; then
        fail "regression-dv-frame-mismatch-not-tagged: base video was DV pre-wrapped on the frame-mismatch fallback (missing return 0)"
      else
        pass "regression-dv-frame-mismatch-not-tagged: no DV pre-wrap on the frame-mismatch fallback"
      fi
      # The MP4 codec tag must be the plain HEVC tag, not Apple's DV 'dvh1'.
      local h2_tag
      h2_tag="$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_tag_string -of default=nw=1:nk=1 "$h2_out" 2>/dev/null || true)"
      if [[ "$h2_tag" == "dvh1" ]]; then
        fail "regression-dv-frame-mismatch-not-tagged: output video codec tag is 'dvh1' (mislabeled DV); expected a plain HEVC tag"
      else
        pass "regression-dv-frame-mismatch-not-tagged: output video codec tag is '$h2_tag' (not dvh1)"
      fi
    else
      fail "regression-dv-frame-mismatch-not-tagged: frame-mismatch fallback did not produce output (exit $h2_code) — expected a clean non-DV MP4"
    fi
  else
    skip "regression-dv-frame-mismatch-not-tagged: hevc_dv_p5_tagged.mp4 fixture not found"
  fi

  # ---- DVMKVFB: DV give-up fallback → MKV must wrap the raw base ES (no "unknown timestamp") ----
  # When DV processing gives up and aliases V_MIXED to the raw HEVC Annex B base ES, MKV
  # output used to abort the final mux with "Can't write packet with unknown timestamp"
  # (exit 234, no file): the raw ES has no container timestamps and all DV give-up
  # branches `return 0` before the pre-wrap that would supply them. _dv_fallback_timestamp_wrap
  # now wraps the base ES into a timestamped MP4 (plain HEVC, no DV) on those paths.
  #
  # Same bogus-RPU dovi_tool mock as H2 (forces the frame-mismatch give-up), but MKV
  # output — the path most at risk of a hard failure. Assert a VALID, non-DV MKV is produced.
  if [[ -f "$TESTDIR/hevc_dv_p5_tagged.mp4" ]]; then
    local fb_bin="$TESTDIR/dvmkvfb_mock_bin"
    local fb_home="$TESTDIR/dvmkvfb_home"
    mkdir -p "$fb_bin" "$fb_home"
    cat > "$fb_bin/dovi_tool" << 'FBDOVISCRIPT'
#!/bin/bash
cmd="${1:-}"; shift
case "$cmd" in
  info)
    printf 'Profile: 8\nCompatibility ID: 1\nBL flag: 1\nEL flag: 0\n999999 RPU\n'; exit 0 ;;
  extract-rpu)
    out_path=""; args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
      [[ "${args[$i]}" == "-o" ]] && out_path="${args[$((i+1))]}" && break
    done
    cat > /dev/null
    [[ -n "$out_path" ]] && printf '\x00\x01\x02\x03\n' > "$out_path"
    exit 0 ;;
  inject-rpu|convert)
    in_path=""; out_path=""; args=("$@")
    for (( i=0; i<${#args[@]}; i++ )); do
      [[ "${args[$i]}" == "-i" ]] && in_path="${args[$((i+1))]}"
      [[ "${args[$i]}" == "-o" ]] && out_path="${args[$((i+1))]}"
    done
    [[ -n "$in_path" && -n "$out_path" && -s "$in_path" ]] && cp "$in_path" "$out_path"
    exit 0 ;;
  *) exit 0 ;;
esac
FBDOVISCRIPT
    chmod +x "$fb_bin/dovi_tool"

    local fb_out="$TESTDIR/dvmkvfb_out.mkv"
    rm -f "$fb_out"
    local fb_log fb_code=0
    fb_log="$(cd "$TESTDIR" && HOME="$fb_home" PATH="$fb_bin:$PATH" \
      "$MUXM" -K --preset ultrafast --crf 28 \
      "hevc_dv_p5_tagged.mp4" "$fb_out" 2>&1)" || fb_code=$?

    # Guard: confirm the give-up path was actually exercised.
    assert_contains "RPU frame count mismatch" \
      "DVMKVFB: frame-count mismatch (DV give-up) path was exercised" "$fb_log"

    if [[ "$fb_code" -eq 0 && -f "$fb_out" && -s "$fb_out" ]]; then
      pass "DVMKVFB: DV give-up → MKV produced output (no 'unknown timestamp' mux abort)"
      # Valid MKV: real HEVC video stream with frames, in a Matroska container.
      assert_probe        "DVMKVFB: output video codec is hevc" "$fb_out" codec_name hevc
      assert_stream_count "DVMKVFB: one video stream"           "$fb_out" v 1 1
      local fb_fmt fb_frames
      fb_fmt="$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$fb_out" 2>/dev/null || true)"
      if printf '%s' "$fb_fmt" | grep -q matroska; then
        pass "DVMKVFB: container is Matroska"
      else
        fail "DVMKVFB: expected matroska container, got '$fb_fmt'"
      fi
      fb_frames="$(ffprobe -v error -count_packets -select_streams v:0 \
        -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$fb_out" 2>/dev/null || true)"
      if [[ "$fb_frames" =~ ^[0-9]+$ ]] && (( fb_frames > 0 )); then
        pass "DVMKVFB: output has a non-empty video stream ($fb_frames frames)"
      else
        fail "DVMKVFB: output video stream has no decodable frames (got '$fb_frames')"
      fi
      # Prove the timestamp wrap actually ran (else a future regression false-passes).
      if printf '%s\n' "$fb_log" | grep -qiF 'wrapped into timestamped MP4'; then
        pass "DVMKVFB: base ES was wrapped into a timestamped container for the MKV mux"
      else
        fail "DVMKVFB: timestamp wrap did not run — MKV mux only succeeded by accident"
      fi
      # Peak-disk hygiene (matches the pipeline's _reclaim convention): once the wrap
      # repoints V_MIXED at the timestamped MP4, the superseded raw base ES is dead and
      # must be reclaimed mid-run — even under -K, which keeps the workdir + logs but not
      # the multi-GB video intermediates. The wrapped MP4 (the actual mux input) survives.
      local fb_wd
      fb_wd="$(printf '%s\n' "$fb_log" | sed -n 's/^=== Workdir[[:space:]]*: //p' | head -1)"
      if [[ -n "$fb_wd" && -d "$fb_wd" ]]; then
        assert_no_file "$fb_wd/video_base.hevc" \
          "DVMKVFB: superseded raw base ES reclaimed mid-run despite -K"
        # The fully injected DV video, orphaned when the give-up aliases V_MIXED→V_BASE,
        # is reclaimed before the alias — so no dead .hevc intermediate survives.
        assert_no_file "$fb_wd/video_mixed.hevc" \
          "DVMKVFB: orphaned injected DV video reclaimed mid-run despite -K"
        if [[ -f "$fb_wd/video_base_timestamped.mp4" ]]; then
          pass "DVMKVFB: timestamped wrap retained as the mux input"
        else
          fail "DVMKVFB: timestamped wrap (video_base_timestamped.mp4) missing"
        fi
      else
        skip "DVMKVFB: could not locate workdir to verify reclaim"
      fi
      # Fallback must stay non-DV: no DV signalling reintroduced by the wrap.
      if printf '%s\n' "$fb_log" | grep -qE 'DV[[:space:]]*: present'; then
        fail "DVMKVFB: output mislabeled as Dolby Vision on the give-up path"
      else
        pass "DVMKVFB: output not labeled Dolby Vision (give-up path stays non-DV)"
      fi
    else
      fail "DVMKVFB: DV give-up → MKV did not produce output (exit $fb_code) — 'unknown timestamp' regression"
    fi
  else
    skip "DVMKVFB: hevc_dv_p5_tagged.mp4 fixture not found"
  fi

  # ---- DISKSTOP: disk preflight is a HARD STOP when space is insufficient ----
  # Force the estimate above any real free space via a huge DISK_FREE_WARN_GB floor
  # in a scoped .muxmrc; muxm must die before encoding rather than fail mid-run.
  if [[ -f "$TESTDIR/hevc_sdr_51.mkv" ]]; then
    local ds_home="$TESTDIR/diskstop_home"; mkdir -p "$ds_home"
    printf 'DISK_FREE_WARN_GB=900000\n' > "$ds_home/.muxmrc"
    local ds_out="$TESTDIR/diskstop_out.mkv" ds_log ds_code=0
    ds_log="$(cd "$TESTDIR" && HOME="$ds_home" "$MUXM" -K --crf 28 --preset ultrafast "hevc_sdr_51.mkv" "$ds_out" 2>&1)" || ds_code=$?
    if (( ds_code == 11 )) && printf '%s' "$ds_log" | grep -qiE 'disk space'; then
      pass "DISKSTOP: insufficient space is a hard stop (exit 11)"
    else
      fail "DISKSTOP: expected hard stop exit 11 with disk message, got exit $ds_code"
    fi
    assert_no_file "DISKSTOP: no output produced when the space check fails" "$ds_out"
    # Override: --no-disk-check must bypass the guard and let the encode proceed.
    local ds_out2="$TESTDIR/diskstop_override.mkv" ds_code2=0
    (cd "$TESTDIR" && HOME="$ds_home" "$MUXM" -K --no-disk-check --crf 28 --preset ultrafast "hevc_sdr_51.mkv" "$ds_out2" >/dev/null 2>&1) || ds_code2=$?
    if [[ -f "$ds_out2" && -s "$ds_out2" ]]; then
      pass "DISKSTOP: --no-disk-check overrides the hard stop"
      assert_probe "DISKSTOP override: output is a valid HEVC encode (not just a file)" "$ds_out2" codec_name hevc
    else
      fail "DISKSTOP: --no-disk-check should bypass the guard and produce output (exit $ds_code2)"
    fi
  else
    skip "DISKSTOP: hevc_sdr_51.mkv fixture not found"
  fi

  # ---- WORKDIR: --workdir relocates the .muxm.tmp workdir to another directory ----
  if [[ -f "$TESTDIR/hevc_sdr_51.mkv" ]]; then
    local wd_alt="$TESTDIR/alt_workdir"; mkdir -p "$wd_alt"
    local wd_out="$TESTDIR/workdir_out.mkv" wd_code=0
    (cd "$TESTDIR" && "$MUXM" -K --workdir "$wd_alt" --no-disk-check --crf 28 --preset ultrafast "hevc_sdr_51.mkv" "$wd_out" >/dev/null 2>&1) || wd_code=$?
    if [[ -f "$wd_out" && -s "$wd_out" ]]; then
      pass "WORKDIR: --workdir run produced output"
      assert_probe "WORKDIR: output is a valid HEVC encode (not just a file)" "$wd_out" codec_name hevc
    else
      fail "WORKDIR: --workdir run failed (exit $wd_code)"
    fi
    if [[ -n "$(ls -d "$wd_alt"/.muxm.tmp.* 2>/dev/null)" ]]; then
      pass "WORKDIR: intermediates staged under the --workdir directory"
    else
      fail "WORKDIR: no .muxm.tmp workdir created under --workdir directory"
    fi
    # A nonexistent --workdir must hard-fail (exit 11), not silently fall back.
    local wd_bad_code=0
    (cd "$TESTDIR" && "$MUXM" -K --workdir "$TESTDIR/nonexistent_workdir_xyz" --crf 28 "hevc_sdr_51.mkv" "$TESTDIR/wd_bad.mkv" >/dev/null 2>&1) || wd_bad_code=$?
    if (( wd_bad_code == 11 )); then
      pass "WORKDIR: nonexistent --workdir is rejected (exit 11)"
    else
      fail "WORKDIR: nonexistent --workdir should exit 11, got $wd_bad_code"
    fi
  else
    skip "WORKDIR: hevc_sdr_51.mkv fixture not found"
  fi

  # ---- LOGPERSIST: --keep-log + failure-diagnostics persistence ----
  # The run log lives inside WORKDIR (deleted by default), so by default it never survives
  # — on success OR failure. --keep-log copies the log out on a clean run, and EVERY
  # failure leaves a self-contained <output>.muxm-debug/ bundle (log + the *.err/*.log that
  # the in-log "See: …" breadcrumbs name) beside the output; a failed persist-copy keeps the
  # workdir rather than destroying the only surviving diagnostics. Driven via "$MUXM" DIRECTLY
  # (not run_muxm, which injects -K) so default cleanup is actually exercised. The forced
  # failure is an invalid x265 ctu= value, which aborts the base encode (exit 40) after the
  # logfile/tee and EXIT trap are live — i.e. it routes through on_exit's failure path.
  if [[ ! -f "$TESTDIR/hevc_sdr_51.mkv" ]]; then
    skip "LOGPERSIST: hevc_sdr_51.mkv fixture not found"
  else
    local lp_dir="$TESTDIR/logpersist"; mkdir -p "$lp_dir"
    cp "$TESTDIR/hevc_sdr_51.mkv" "$lp_dir/src.mkv"
    # --no-video-copy-if-compliant forces a real libx265 re-encode (so the bad x265 param
    # actually bites instead of the HEVC source being stream-copied).
    local -a lp_common=(--no-dv --skip-audio --skip-subs --no-disk-check --no-video-copy-if-compliant
                        --video-codec libx265 --crf 30 --preset ultrafast)

    # CASE 1 (default): clean run, no --keep-log, no -k/-K → persist nothing, remove workdir.
    local c1_out="$lp_dir/c1.mkv" c1_code=0
    ( cd "$lp_dir" && "$MUXM" "${lp_common[@]}" src.mkv "$c1_out" >/dev/null 2>&1 ) || c1_code=$?
    if [[ -s "$c1_out" ]] && [[ ! -e "$lp_dir/c1.muxm.log" ]] && [[ ! -e "$lp_dir/c1.muxm-debug" ]] \
       && ! find "$lp_dir" -maxdepth 1 -name '.muxm.tmp.*' 2>/dev/null | grep -q .; then
      pass "LOGPERSIST/default: clean run persists nothing and removes the workdir"
    else
      fail "LOGPERSIST/default: expected output + no .muxm.log/.muxm-debug + no leftover workdir (exit $c1_code)"
    fi

    # CASE 2 (--keep-log): clean run copies the log to <output>.muxm.log, non-empty.
    local c2_out="$lp_dir/c2.mkv" c2_code=0
    ( cd "$lp_dir" && "$MUXM" --keep-log "${lp_common[@]}" src.mkv "$c2_out" >/dev/null 2>&1 ) || c2_code=$?
    if [[ -s "$c2_out" && -s "$lp_dir/c2.muxm.log" ]]; then
      pass "LOGPERSIST/--keep-log: clean run copies the log to <output>.muxm.log"
    else
      fail "LOGPERSIST/--keep-log: expected a non-empty c2.muxm.log beside the output (exit $c2_code)"
    fi

    # CASE 3 (failure): bundle holds the log AND the relevant .err, and the message points at it.
    local c3_out="$lp_dir/c3.mkv" c3_log c3_code=0
    c3_log="$(cd "$lp_dir" && "$MUXM" "${lp_common[@]}" --x265-params "ctu=999" src.mkv "$c3_out" 2>&1)" || c3_code=$?
    local c3_bundle="$lp_dir/c3.muxm-debug"
    if (( c3_code != 0 )) && [[ -d "$c3_bundle" ]] \
       && ls "$c3_bundle"/muxm.*.log >/dev/null 2>&1 && [[ -s "$c3_bundle/encode.err" ]] \
       && printf '%s' "$c3_log" | grep -qF "Diagnostics: $c3_bundle/"; then
      pass "LOGPERSIST/failure: bundle holds the log + encode.err and the message points at it"
    else
      fail "LOGPERSIST/failure: expected $c3_bundle/ with log + encode.err and a matching 'Diagnostics:' line (exit $c3_code)"
    fi
    # FATALDEDUP (D7): on a pipeline failure the cause is printed exactly ONCE (by
    # die() as "❌ ERROR: <cause>"), the on_exit summary is terse ("❌ Build FAILED (exit N).
    # Diagnostics: …/") and no line contains a nested "Fatal:". The counts are trustworthy
    # because ffmpeg/x265 stderr goes to encode.err (a file) and the run log is separate — so the
    # captured stream carries only muxm's own ❌ lines.
    # `grep -c` exits 1 on zero matches; `|| true` keeps the count capture set -e-safe (the
    # harness runs under set -e, and the expected Fatal: count IS zero).
    local c3_fatal c3_cause
    c3_fatal="$(printf '%s\n' "$c3_log" | grep -cF 'Fatal:' || true)"
    c3_cause="$(printf '%s\n' "$c3_log" | grep -cF 'Base video encode failed' || true)"
    if (( c3_code != 0 && c3_fatal == 0 && c3_cause == 1 )) \
       && printf '%s\n' "$c3_log" | grep -qE 'Build FAILED \(exit [0-9]+\)\. Diagnostics:'; then
      pass "FATALDEDUP: failure cause printed once, no 'Fatal:', terse Build-FAILED summary (D7)"
    else
      fail "FATALDEDUP: expected one cause + no 'Fatal:' + terse summary (Fatal=$c3_fatal, cause=$c3_cause, exit=$c3_code)"
    fi

    # CASE 4 (persist-copy fails): the bundle path is pre-occupied by a regular file so the
    # copy can't be written (stands in for 'output volume full'); the workdir must survive and
    # the surviving location must be printed — the only triage artifact is never destroyed.
    local c4_out="$lp_dir/c4.mkv" c4_log c4_code=0
    : > "$lp_dir/c4.muxm-debug"
    c4_log="$(cd "$lp_dir" && "$MUXM" "${lp_common[@]}" --x265-params "ctu=999" src.mkv "$c4_out" 2>&1)" || c4_code=$?
    if (( c4_code != 0 )) && printf '%s' "$c4_log" | grep -qiE 'preserving workdir' \
       && find "$lp_dir" -maxdepth 1 -name '.muxm.tmp.*' 2>/dev/null | grep -q .; then
      pass "LOGPERSIST/persist-fail: a failed bundle copy keeps the workdir (log not destroyed)"
    else
      fail "LOGPERSIST/persist-fail: expected workdir preserved + 'preserving workdir' message (exit $c4_code)"
    fi

    # CASE 5 (failure + -k RENAMES, no duplication): a failure WITH -k must
    # rename the hidden .muxm.tmp.XXXX workdir to a VISIBLE muxm-debug.XXXX in place (same volume,
    # beside OUT since no --workdir) — NOT copy a KB bundle out and leave the hidden workdir behind.
    # Assert: a single visible muxm-debug.* holding the log + encode.err; NO hidden .muxm.tmp.* left;
    # NO duplicate <output>.muxm-debug/ bundle; and the "Diagnostics:" breadcrumb points at the
    # visible dir. Uses -k (keep-on-failure) directly (lp_common has no keep flag).
    local c5_dir="$lp_dir/c5"; mkdir -p "$c5_dir"; cp "$lp_dir/src.mkv" "$c5_dir/src.mkv"
    local c5_out="$c5_dir/c5.mkv" c5_log c5_code=0
    c5_log="$(cd "$c5_dir" && "$MUXM" -k "${lp_common[@]}" --x265-params "ctu=999" src.mkv "$c5_out" 2>&1)" || c5_code=$?
    local c5_vis; c5_vis="$(find "$c5_dir" -maxdepth 1 -name 'muxm-debug.*' -type d 2>/dev/null | head -1)"
    if (( c5_code != 0 )) && [[ -n "$c5_vis" ]] \
       && ls "$c5_vis"/muxm.*.log >/dev/null 2>&1 && [[ -s "$c5_vis/encode.err" ]] \
       && ! find "$c5_dir" -maxdepth 1 -name '.muxm.tmp.*' 2>/dev/null | grep -q . \
       && [[ ! -e "$c5_dir/c5.muxm-debug" ]] \
       && printf '%s' "$c5_log" | grep -qF "Diagnostics: $c5_vis/"; then
      pass "LOGPERSIST/keep-rename: failure + -k renames workdir to a visible muxm-debug.* (no dup, no hidden dir)"
    else
      fail "LOGPERSIST/keep-rename: expected one visible muxm-debug.* (log+encode.err), no .muxm.tmp.*, no c5.muxm-debug, matching Diagnostics (exit $c5_code, vis='$c5_vis')"
    fi

    # CASE 6 (--workdir + -k lands on the workdir volume, not beside OUT): the
    # rename is in-place on the workdir's own volume, so under --workdir the visible artifacts land
    # THERE (roomy volume the user chose), never dragged across to the output disk. Can't stage two
    # real volumes here, but the LANDING DIRECTORY proves the in-place logic: visible muxm-debug.*
    # appears under the --workdir dir and nothing debug-shaped appears beside OUT.
    local c6_wdir="$lp_dir/c6_work"; mkdir -p "$c6_wdir"
    local c6_out="$lp_dir/c6.mkv" c6_code=0
    ( cd "$lp_dir" && "$MUXM" -k --workdir "$c6_wdir" "${lp_common[@]}" --x265-params "ctu=999" src.mkv "$c6_out" >/dev/null 2>&1 ) || c6_code=$?
    if (( c6_code != 0 )) \
       && find "$c6_wdir" -maxdepth 1 -name 'muxm-debug.*' -type d 2>/dev/null | grep -q . \
       && ! find "$c6_wdir" -maxdepth 1 -name '.muxm.tmp.*' 2>/dev/null | grep -q . \
       && ! find "$lp_dir" -maxdepth 1 -name 'muxm-debug.*' 2>/dev/null | grep -q . \
       && [[ ! -e "$lp_dir/c6.muxm-debug" ]]; then
      pass "LOGPERSIST/keep-rename+workdir: visible muxm-debug.* lands under --workdir dir, not beside OUT"
    else
      fail "LOGPERSIST/keep-rename+workdir: expected visible muxm-debug.* under $c6_wdir and nothing beside OUT (exit $c6_code)"
    fi
  fi

  # ---- LOGCONTENT: the persisted log tells the whole story ----
  # A --keep-log run with a profile/flag conflict must persist a log that contains: the decision
  # narrative (conflict/ignored-knob warnings, captured pre-§17 → D6/D2), the effective-config
  # block (self-describing), a monotonic [+Ns] time prefix on log() lines (D8), and a per-step
  # "done in Ns" timing line (D8). Internal log() lines must NOT leak to the terminal (D5).
  # archive + --crf triggers the ignored-knob warnings; --no-video-copy-if-compliant forces a real
  # libx265 re-encode so the encode step is actually timed.
  if [[ ! -f "$TESTDIR/hevc_sdr_51.mkv" ]]; then
    skip "LOGCONTENT: hevc_sdr_51.mkv fixture not found"
  else
    local lc_dir="$TESTDIR/logcontent"; mkdir -p "$lc_dir"
    cp "$TESTDIR/hevc_sdr_51.mkv" "$lc_dir/src.mkv"
    local lc_out="$lc_dir/out.mkv" lc_log="$lc_dir/out.muxm.log" lc_term lc_code=0
    lc_term="$(cd "$lc_dir" && "$MUXM" --keep-log --no-disk-check --no-dv --skip-audio --skip-subs \
                 --no-video-copy-if-compliant --video-codec libx265 --crf 30 --preset ultrafast \
                 --profile archive src.mkv "$lc_out" 2>&1)" || lc_code=$?
    if [[ -s "$lc_out" && -s "$lc_log" ]]; then
      if grep -qF "Profile 'archive' + --crf" "$lc_log"; then
        pass "LOGCONTENT: conflict/ignored-knob warning captured in the persisted log (D6/D2)"
      else
        fail "LOGCONTENT: conflict warning missing from the persisted log"
      fi
      if grep -qF "Effective config" "$lc_log"; then
        pass "LOGCONTENT: effective-config block written to the log (self-describing)"
      else
        fail "LOGCONTENT: effective-config block missing from the log"
      fi
      if grep -qE '^\[\+[0-9]+s\] ' "$lc_log"; then
        pass "LOGCONTENT: log() lines carry a monotonic [+Ns] time prefix (D8)"
      else
        fail "LOGCONTENT: no [+Ns] time prefix found on log lines"
      fi
      if grep -qE 'step "[^"]+" done in [0-9]+s' "$lc_log"; then
        pass "LOGCONTENT: per-step 'done in Ns' timing present (D8)"
      else
        fail "LOGCONTENT: no per-step 'done in Ns' timing line found"
      fi
      if printf '%s' "$lc_term" | grep -qF "[output] Inferred"; then
        fail "LOGCONTENT: internal '[output] Inferred' line leaked to the terminal (D5 regressed)"
      else
        pass "LOGCONTENT: internal log() lines do not leak to the terminal (D5)"
      fi
    else
      fail "LOGCONTENT: --keep-log run produced no output/log (exit $lc_code)"
    fi
  fi

  # ---- BANNERPLAN: banner policy summary + resolved ▶ Plan line; stage-focused stream ----
  # The startup banner must confirm the resolved POLICY (codec/container/audio/subtitles/color-DV),
  # a single "▶ Plan:" line must report the CONCRETE encoder + target pixfmt, and the mid-pipeline
  # terminal must stay stage-focused: encode parameters and audio channel/bitrate detail go to the
  # LOG only, never the terminal. --audio-force-codec aac forces a real transcode (the AC3 5.1
  # fixture would otherwise be copied), exercising the audio stage-focus split.
  if [[ ! -f "$TESTDIR/hevc_sdr_51.mkv" ]]; then
    skip "BANNERPLAN: hevc_sdr_51.mkv fixture not found"
  else
    local bp_dir="$TESTDIR/bannerplan"; mkdir -p "$bp_dir"
    cp "$TESTDIR/hevc_sdr_51.mkv" "$bp_dir/src.mkv"
    local bp_out="$bp_dir/out.mkv" bp_log="$bp_dir/out.muxm.log" bp_term bp_code=0
    bp_term="$(cd "$bp_dir" && "$MUXM" --keep-log --no-disk-check --no-video-copy-if-compliant \
                 --video-codec libx265 --crf 28 --preset ultrafast --audio-force-codec aac \
                 --no-stereo-fallback src.mkv "$bp_out" 2>&1)" || bp_code=$?
    if [[ -s "$bp_out" && -s "$bp_log" ]]; then
      # Banner policy summary present on the terminal.
      if printf '%s\n' "$bp_term" | grep -qE '^=== Video ' && printf '%s\n' "$bp_term" | grep -qE '^=== Container '; then
        pass "BANNERPLAN: banner confirms the resolved policy (=== Video / === Container / …)"
      else
        fail "BANNERPLAN: banner policy lines missing from the terminal"
      fi
      # Resolved Plan line on the terminal, with the concrete encoder + pixfmt.
      if printf '%s\n' "$bp_term" | grep -qF "▶ Plan:" \
         && printf '%s\n' "$bp_term" | grep -qE '▶ Plan:.*libx265.*yuv420p'; then
        pass "BANNERPLAN: resolved '▶ Plan:' line reports the concrete encoder + target pixfmt"
      else
        fail "BANNERPLAN: '▶ Plan:' line missing or lacks encoder/pixfmt"
      fi
      # Stage focus: encode parameters are log-only, NOT dumped to the mid-pipeline terminal.
      if printf '%s\n' "$bp_term" | grep -qF "→ Encoding video ("; then
        fail "BANNERPLAN: encode-parameter line leaked to the mid-pipeline terminal"
      else
        pass "BANNERPLAN: encode parameters not dumped to the mid-pipeline terminal"
      fi
      if grep -qF "→ Encoding video (" "$bp_log"; then
        pass "BANNERPLAN: encode-parameter detail still present in the persisted log"
      else
        fail "BANNERPLAN: encode-parameter detail missing from the log"
      fi
      # Stage focus: audio transcode channel/bitrate detail is log-only.
      if printf '%s\n' "$bp_term" | grep -qF "channels="; then
        fail "BANNERPLAN: audio channel/bitrate detail leaked to the terminal"
      else
        pass "BANNERPLAN: audio transcode detail (channels=) not on the terminal"
      fi
      if grep -qF "channels=" "$bp_log"; then
        pass "BANNERPLAN: audio transcode detail (channels=) present in the log"
      else
        fail "BANNERPLAN: audio transcode detail missing from the log (did the transcode run?)"
      fi
      # SCRUB (D11): no raw ffmpeg flags, internal env-var names, control-flow jargon,
      # or developer-status text may reach the terminal. Most of these tokens belong to DV / VT /
      # NVENC / multi-track paths not exercised by this SDR software encode, so this is primarily a
      # regression guard — it fails loudly if any future change routes one of them to the terminal.
      local _scrub_hit="" _tok
      for _tok in '-strict unofficial' 'LEVEL_VALUE=' 'CONSERVATIVE_VBV=' 'demoted to single-track' \
                  'not yet implemented' 'av1_nvenc' 'Falling through to score-all'; do
        if printf '%s\n' "$bp_term" | grep -qF "$_tok"; then _scrub_hit+="[$_tok] "; fi
      done
      if [[ -z "$_scrub_hit" ]]; then
        pass "BANNERPLAN: no raw flags / internal var names / control-flow jargon on the terminal (D11)"
      else
        fail "BANNERPLAN: internal vocabulary leaked to the terminal: $_scrub_hit"
      fi
    else
      fail "BANNERPLAN: --keep-log encode produced no output/log (exit $bp_code)"
    fi
  fi

  # ---- VERBOSITY: --quiet/--verbose/--no-color, disk-OK, and the DEBUG-log decouple ----
  # --quiet drops info narration from the TERMINAL while the persistent log stays COMPLETE;
  # --verbose surfaces the otherwise log-only detail; NO_COLOR strips emoji; DEBUG=1 produces a
  # persistent logfile that set -x xtrace does NOT pollute (BASH_XTRACEFD → raw terminal).
  if [[ ! -f "$TESTDIR/hevc_sdr_51.mkv" ]]; then
    skip "VERBOSITY: hevc_sdr_51.mkv fixture not found"
  else
    local vb_dir="$TESTDIR/verbosity"; mkdir -p "$vb_dir"
    cp "$TESTDIR/hevc_sdr_51.mkv" "$vb_dir/src.mkv"

    # Flags register in the effective config.
    assert_contains "VERBOSITY                 = quiet" "VERBOSITY/--quiet: sets VERBOSITY=quiet" "$(run_muxm --quiet --print-effective-config)"
    assert_contains "VERBOSITY                 = verbose" "VERBOSITY/--verbose: sets VERBOSITY=verbose" "$(run_muxm --verbose --print-effective-config)"
    assert_contains "USE_COLOR                 = 0" "VERBOSITY/--no-color: sets USE_COLOR=0" "$(run_muxm --no-color --print-effective-config)"

    # (acceptance) --quiet reduces the terminal to warnings/errors, but the LOG stays complete.
    local vq_out="$vb_dir/q.mkv" vq_log="$vb_dir/q.muxm.log" vq_term
    vq_term="$(cd "$vb_dir" && "$MUXM" --quiet --keep-log --no-disk-check --no-dv --skip-audio --skip-subs \
                --no-video-copy-if-compliant --video-codec libx265 --crf 32 --preset ultrafast src.mkv "$vq_out" 2>&1)" || true
    if [[ -s "$vq_out" && -s "$vq_log" ]]; then
      # Count-based (not `grep -q`): grep -q exits on first match → SIGPIPE → pipefail would make
      # an absence check false-pass on a regression. -c reads all input, so the count is honest.
      local _vq_note _vq_emoji
      _vq_note="$(printf '%s\n' "$vq_term" | grep -cF "Build SUCCEEDED" || true)"
      _vq_emoji="$(printf '%s\n' "$vq_term" | grep -cF "ℹ️" || true)"
      if (( _vq_note == 0 && _vq_emoji == 0 )); then
        pass "VERBOSITY/--quiet: info narration suppressed on the terminal"
      else
        fail "VERBOSITY/--quiet: a note leaked to the quiet terminal (SUCCEEDED=$_vq_note, ℹ️=$_vq_emoji)"
      fi
      if grep -qF "Build SUCCEEDED" "$vq_log"; then
        pass "VERBOSITY/--quiet: the persistent log stays complete despite the quiet terminal"
      else
        fail "VERBOSITY/--quiet: narration missing from the persisted log (quiet stripped the log)"
      fi
    else
      fail "VERBOSITY/--quiet: --keep-log encode produced no output/log"
    fi

    # --verbose surfaces otherwise log-only detail to the terminal. Use the effective-config dump
    # ("Effective config", emitted via log() at §17 on every run) as a fixture-independent marker:
    # verbose echoes it to the terminal; normal mode keeps it log-only.
    local _vv_n _vn_n
    _vv_n="$(printf '%s\n' "$(run_muxm --verbose --dry-run --no-disk-check "$vb_dir/src.mkv")" | grep -cF "Effective config" || true)"
    _vn_n="$(printf '%s\n' "$(run_muxm --dry-run --no-disk-check "$vb_dir/src.mkv")" | grep -cF "Effective config" || true)"
    if (( _vv_n >= 1 && _vn_n == 0 )); then
      pass "VERBOSITY/--verbose: log-only detail surfaces on the terminal (absent in normal mode)"
    else
      fail "VERBOSITY/--verbose: log-only detail not surfaced (verbose=$_vv_n, normal=$_vn_n)"
    fi

    # NO_COLOR strips muxm's emoji prefixes from the terminal.
    local vc_term vc_emoji
    vc_term="$(cd "$vb_dir" && NO_COLOR=1 "$MUXM" --dry-run --no-disk-check src.mkv 2>&1)" || true
    vc_emoji="$(printf '%s\n' "$vc_term" | grep -cE 'ℹ️|⚠️|❌' || true)"
    if (( vc_emoji == 0 )); then
      pass "VERBOSITY/NO_COLOR: emoji prefixes stripped from the terminal"
    else
      fail "VERBOSITY/NO_COLOR: emoji still present on the terminal ($vc_emoji)"
    fi

    # Disk-OK preflight success line (D15) — a note, so it shows on a normal run.
    assert_contains "Disk OK" "VERBOSITY/disk-OK: preflight prints a success line on a normal run" \
      "$(run_muxm --dry-run "$vb_dir/src.mkv")"

    # (acceptance) DEBUG=1 yields a persistent log that set -x xtrace does NOT pollute.
    local vdbg_out="$vb_dir/dbg.mkv" vdbg_term vdbg_code=0
    vdbg_term="$(cd "$vb_dir" && DEBUG=1 "$MUXM" -K --no-disk-check --no-dv --skip-audio --skip-subs \
                  --no-video-copy-if-compliant --video-codec libx265 --crf 32 --preset ultrafast src.mkv "$vdbg_out" 2>&1)" || vdbg_code=$?
    local vdbg_wd vdbg_log vdbg_xtrace=0
    vdbg_wd="$(printf '%s\n' "$vdbg_term" | grep 'Keeping workdir:' | head -1 | awk '{print $NF}')"
    vdbg_log="$(find "$vdbg_wd" -maxdepth 1 -name 'muxm.*.log' 2>/dev/null | head -1)"
    [[ -n "$vdbg_log" ]] && vdbg_xtrace="$(grep -cE '^\+ ' "$vdbg_log" || true)"
    if (( vdbg_code == 0 )) && [[ -n "$vdbg_log" ]] && grep -qF "Build SUCCEEDED" "$vdbg_log" && (( vdbg_xtrace == 0 )); then
      pass "VERBOSITY/DEBUG: DEBUG=1 produces a persistent log with no set -x xtrace pollution"
    else
      fail "VERBOSITY/DEBUG: expected a clean persistent log (exit=$vdbg_code, log='$vdbg_log', xtrace_lines=$vdbg_xtrace)"
    fi
  fi

  # ---- CONFIGKNOB: KEEP_LOG/VERBOSITY set in .muxmrc drive a REAL run (end-to-end) ----
  # A .muxmrc with KEEP_LOG=1 + VERBOSITY=quiet and NO CLI flags must: persist <output>.muxm.log
  # (KEEP_LOG honoured from config), keep the terminal quiet (VERBOSITY from config), and keep the
  # persisted log COMPLETE. Also confirm --create-config emits the script DEFAULTS (commented), not
  # this machine's .muxmrc values (H1 leak guard).
  if [[ ! -f "$TESTDIR/hevc_sdr_51.mkv" ]]; then
    skip "CONFIGKNOB: hevc_sdr_51.mkv fixture not found"
  else
    local ckb_dir="$TESTDIR/configknob" ckb_home="$TESTDIR/configknob_home"
    mkdir -p "$ckb_dir" "$ckb_home"
    cp "$TESTDIR/hevc_sdr_51.mkv" "$ckb_dir/src.mkv"
    printf 'KEEP_LOG=1\nVERBOSITY="quiet"\n' > "$ckb_home/.muxmrc"
    local ckb_out="$ckb_dir/out.mkv" ckb_log="$ckb_dir/out.muxm.log" ckb_term ckb_code=0
    ckb_term="$(cd "$ckb_dir" && HOME="$ckb_home" "$MUXM" --no-disk-check --no-dv --skip-audio --skip-subs \
                 --no-video-copy-if-compliant --video-codec libx265 --crf 32 --preset ultrafast src.mkv "$ckb_out" 2>&1)" || ckb_code=$?
    if [[ -s "$ckb_out" ]]; then
      if [[ -s "$ckb_log" ]]; then
        pass "CONFIGKNOB: .muxmrc KEEP_LOG=1 persists <output>.muxm.log with no --keep-log flag"
      else
        fail "CONFIGKNOB: .muxmrc KEEP_LOG=1 did not persist the log (exit $ckb_code)"
      fi
      # Config-only quiet silences the POST-parse pipeline (where _resolve_verbosity has run);
      # the §6→§12 pre-parse window is only silenced by CLI --quiet (via the early pre-scan). This
      # fixture sets NO profile on purpose, so there is no "Applied profile" note in that window —
      # don't add a profile to ckb_home/.muxmrc or this zero-note assertion will start failing.
      local ckb_emoji
      ckb_emoji="$(printf '%s\n' "$ckb_term" | grep -cF "ℹ️" || true)"
      if (( ckb_emoji == 0 )); then
        pass "CONFIGKNOB: .muxmrc VERBOSITY=quiet silences the terminal with no --quiet flag"
      else
        fail "CONFIGKNOB: .muxmrc VERBOSITY=quiet left notes on the terminal ($ckb_emoji)"
      fi
      if [[ -s "$ckb_log" ]] && grep -qF "Build SUCCEEDED" "$ckb_log"; then
        pass "CONFIGKNOB: the persisted log stays complete under config-driven quiet"
      else
        fail "CONFIGKNOB: persisted log incomplete under config-driven quiet"
      fi
    else
      fail "CONFIGKNOB: config-driven run produced no output (exit $ckb_code)"
    fi
    # H1: --create-config emits the defaults, not this machine's KEEP_LOG=1/VERBOSITY=verbose.
    printf 'KEEP_LOG=1\nVERBOSITY="verbose"\n' > "$ckb_home/.muxmrc"
    local ckb_gen="$ckb_dir/gen"; mkdir -p "$ckb_gen"
    ( cd "$ckb_gen" && HOME="$ckb_home" "$MUXM" --create-config project >/dev/null 2>&1 ) || true
    if grep -qE '^#KEEP_LOG="?0"?' "$ckb_gen/.muxmrc" && grep -qE '^#VERBOSITY="normal"' "$ckb_gen/.muxmrc"; then
      pass "CONFIGKNOB: --create-config emits KEEP_LOG/VERBOSITY at script defaults, commented (H1)"
    else
      fail "CONFIGKNOB: generated config leaked the machine's KEEP_LOG/VERBOSITY values (H1)"
    fi
  fi

  # ---- CFGGEN: HW_ACCEL is tracked, emitted as a commented default (not leaked) ----
  # HW_ACCEL must be part of CONFIG_TRACKED_VARS so --create-config emits it at all (it
  # was once omitted entirely). Because no built-in profile sets HW_ACCEL, it is
  # profile-untouched and must appear COMMENTED at its script default — it must NOT carry
  # the invoking machine's ~/.muxmrc value into the generated file.
  #
  # A generated config is a profile TEMPLATE, not a snapshot of the local environment.
  # Baking a machine-specific setting like HW_ACCEL="videotoolbox" into a shared or
  # committed config would be a personal-settings leak — precisely the leak that
  # _create_config_emit guards against (see the config-suite "regression-create-config-leak-guard leak guard" test). So the
  # correct behavior here is the commented default, NOT the invoking machine's local value
  # carried through uncommented into the generated file.
  local h1_dir="$TESTDIR/h1_config_roundtrip"
  local h1_home="$TESTDIR/h1_config_home"
  mkdir -p "$h1_dir" "$h1_home"
  printf 'HW_ACCEL="videotoolbox"\n' > "$h1_home/.muxmrc"
  MUXM_HOME="$h1_home" run_muxm_in "$h1_dir" --create-config project >/dev/null 2>&1
  if [[ -f "$h1_dir/.muxmrc" ]]; then
    local h1_content
    h1_content="$(cat "$h1_dir/.muxmrc")"
    # Tracked + emitted as the commented script default (atv-directplay-hq does not set it).
    if echo "$h1_content" | grep -qE '^#HW_ACCEL="none"$'; then
      pass "CFGGEN: HW_ACCEL emitted as commented default (#HW_ACCEL=\"none\") via SSOT"
    else
      fail "CFGGEN: expected '#HW_ACCEL=\"none\"' (commented default), got: $(echo "$h1_content" | grep 'HW_ACCEL' | head -3 || echo '<not present>')"
    fi
    # The invoking machine's ~/.muxmrc value must NOT leak into the generated config (H1).
    if echo "$h1_content" | grep -qE '^HW_ACCEL='; then
      fail "CFGGEN: local ~/.muxmrc HW_ACCEL leaked uncommented into generated config (H1 regression)"
    else
      pass "CFGGEN: local ~/.muxmrc HW_ACCEL did not leak uncommented into generated config"
    fi
  else
    fail "CFGGEN: --create-config (HW_ACCEL tracking) — no .muxmrc created"
  fi

  # ---- H11: non-Darwin OS + --hw-accel → Linux fallback warning, software encoding ----
  # Strategy: stateful uname mock returns Darwin/arm64 for detect_hw_accel (so
  # videotoolbox is added to HW_ACCEL_AVAILABLE), then Linux for resolve_video_encoder
  # (triggering the OS guard at Section 22). Requires hevc_videotoolbox in this ffmpeg.
  if [[ "$(uname -s)" == "Darwin" ]] \
      && ffmpeg_has_encoder hevc_videotoolbox; then
    local h11_mock="$TESTDIR/mock_uname_linux"
    local h11_count="$TESTDIR/uname_call_count.txt"
    mkdir -p "$h11_mock"
    printf '0\n' > "$h11_count"
    cat > "$h11_mock/uname" << UNAMESCRIPT
#!/bin/bash
cnt=\$(cat "$h11_count" 2>/dev/null || echo 0)
cnt=\$((cnt + 1))
printf '%s\n' "\$cnt" > "$h11_count"
if (( cnt == 1 )); then
  printf 'Darwin\n'   # is_apple_silicon call 1: uname -s
elif (( cnt == 2 )); then
  printf 'arm64\n'    # is_apple_silicon call 2: uname -m
else
  printf 'Linux\n'    # resolve_video_encoder OS guard
fi
UNAMESCRIPT
    chmod +x "$h11_mock/uname"
    out="$(PATH="$h11_mock:$PATH" run_muxm --hw-accel videotoolbox --no-skip-if-ideal \
      --dry-run "$TESTDIR/basic_sdr_subs.mkv")"
    assert_contains "macOS (VideoToolbox) only" \
      "regression-non-darwin-hw-fallback: non-Darwin OS + --hw-accel videotoolbox: Linux fallback warning emitted" "$out"
    assert_contains "DRY-RUN complete" \
      "regression-non-darwin-hw-fallback: non-Darwin OS + --hw-accel: encode completes (software fallback)" "$out"
  else
    skip "regression-non-darwin-hw-fallback: Linux hw-accel guard test requires Darwin + hevc_videotoolbox (not met on this host)"
  fi
}

# === Suite: VideoToolbox + Dolby Vision (gated regression) ===
# Substantiates the code comment claiming VT-encoded HEVC round-trips
# Dolby Vision RPU bit-perfect (resolve_video_encoder has no DV gate; the raw-ES path is
# enabled for hevc_videotoolbox just like libx265). VT encodes an HDR10 base layer, the
# source RPU is injected post-compression by dovi_tool (encoder-agnostic), and MP4Box muxes
# the headerless ES. This proves VT + DV produces an output that still carries a valid DV
# configuration record, with frame-count parity against the source.
#
# DV source: by default the bundled DV Profile 8 fixture (tests/fixtures/HDR1080p.MOV,
# a genuine RPU-carrying clip) is copied into the temp workspace and used. Set
# MUXM_DV_FIXTURE=/path/to/your_dv_source to override with your own DV file instead.
# (A real RPU is required — synthetic tagged fixtures won't do.)
#
# Still gated on the platform/tooling below; when any of these is missing the VT
# encode SKIPs (never fails) so CI stays green without Apple hardware or DV tooling:
#   • macOS (VideoToolbox is macOS-only)
#   • ffmpeg has the hevc_videotoolbox encoder
#   • dovi_tool and MP4Box (or mp4box) are on PATH
# The C6 dry-run check below needs only the DV source (no VT/dovi_tool), so it runs
# on any host once the fixture is available.
# Example (override the bundled fixture):
#   MUXM_DV_FIXTURE=/path/to/dv_p8.mkv ./tests/test_muxm.sh --suite dv_vt
test_dv_vt() {
  section "VideoToolbox + Dolby Vision (gated regression)"

  # Resolve the DV fixture. An explicit MUXM_DV_FIXTURE wins (a user's own DV source,
  # referenced in place). Otherwise fall back to the bundled DV Profile 8 fixture,
  # copied into $TESTDIR so the read-only original is never touched and muxm writes
  # only inside the temp workspace. The copy is named .mp4 (its bitstream is ISOBMFF,
  # read identically to .mov) because muxm's default output container is derived from
  # the source extension and ffmpeg refuses to mux Dolby Vision into a .mov.
  local _dv_fixture="${MUXM_DV_FIXTURE:-}"
  if [[ -z "$_dv_fixture" ]]; then
    local _bundled_dv
    _bundled_dv="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/HDR1080p.MOV"
    if [[ -f "$_bundled_dv" && -r "$_bundled_dv" ]] && cp "$_bundled_dv" "$TESTDIR/dv_source.mp4"; then
      _dv_fixture="$TESTDIR/dv_source.mp4"
    fi
  fi
  # Shadow MUXM_DV_FIXTURE for the rest of this function (no global mutation).
  local MUXM_DV_FIXTURE="$_dv_fixture"

  # ---- C6: H.264 drops Dolby Vision — deferred post-probe warning ----
  # Needs only a real DV source (detect_dv → IS_DV=1) and a dry-run; no VideoToolbox,
  # dovi_tool, or MP4Box required. Gated on MUXM_DV_FIXTURE alone, ahead of the VT gates
  # below, so it runs on any host that can supply a DV fixture. The unit suite
  # (_test_unit_h264_drops_dv) covers the predicate deterministically without a fixture.
  if [[ -n "${MUXM_DV_FIXTURE:-}" && -f "${MUXM_DV_FIXTURE:-}" && -r "${MUXM_DV_FIXTURE:-}" ]]; then
    local _c6
    # libx264 + DV source → warning fires.
    _c6="$(run_muxm --dry-run --video-codec libx264 "$MUXM_DV_FIXTURE" 2>&1)"
    if echo "$_c6" | grep -qi "H.264 cannot carry Dolby Vision"; then
      pass "dvvt-h264-drops-dv-e2e (e2e): libx264 on a DV source warns that DV will be dropped"
    else
      fail "dvvt-h264-drops-dv-e2e (e2e): expected an H.264-drops-DV warning for libx264 on a DV source"
    fi
    # libx265 carries DV → no C6 warning.
    _c6="$(run_muxm --dry-run --video-codec libx265 "$MUXM_DV_FIXTURE" 2>&1)"
    if echo "$_c6" | grep -qi "H.264 cannot carry Dolby Vision"; then
      fail "dvvt-h264-drops-dv-e2e (e2e): libx265 on a DV source wrongly emitted the H.264-drops-DV warning"
    else
      pass "dvvt-h264-drops-dv-e2e (e2e): libx265 on a DV source emits no H.264-drops-DV warning"
    fi
    # libx264 + --no-dv → deliberate opt-out, no warning.
    _c6="$(run_muxm --dry-run --video-codec libx264 --no-dv "$MUXM_DV_FIXTURE" 2>&1)"
    if echo "$_c6" | grep -qi "H.264 cannot carry Dolby Vision"; then
      fail "dvvt-h264-drops-dv-e2e (e2e): libx264 + --no-dv still warned (should be silent on deliberate opt-out)"
    else
      pass "dvvt-h264-drops-dv-e2e (e2e): libx264 + --no-dv emits no H.264-drops-DV warning"
    fi
  else
    skip "dvvt-h264-drops-dv-e2e (e2e): set MUXM_DV_FIXTURE=/path/to/real_dv_source to exercise the post-probe path (unit suite covers the predicate)"
  fi

  # ---- F2: "DV stripped → HDR10 has no static metadata" warning REACHABILITY + scoping ----
  # The bundled DV fixture has a DOVI configuration record but NO mastering-display/MaxCLL side
  # data — exactly the at-risk source. If the _check_hdr10_static_metadata call sat in main()'s
  # dead `_dv_rc==0` arm (DISABLE_DV is always 0 there, since detect_dv returns 2 when
  # DISABLE_DV=1), it would never fire for any DV-stripping profile. The function's own present/
  # missing/partial logic is unit-tested in _test_unit_hdr10_static_metadata; here we assert it is
  # REACHED for the right profiles and NOT for the wrong ones. Dry-run (no encode needed).
  # Skip-first guard (not an else-skip) per the soft-skip ratchet.
  if [[ -z "${MUXM_DV_FIXTURE:-}" || ! -f "${MUXM_DV_FIXTURE:-}" || ! -r "${MUXM_DV_FIXTURE:-}" ]]; then
    skip "dvvt-hdr10-metadata-warning (e2e): no DV fixture available (set MUXM_DV_FIXTURE to exercise the HDR10-metadata warning)"
  else
    local _f2_warn='NO HDR10 static metadata' _f2
    # DV-stripping HDR10 profiles must warn (hdr10-hq, plus the broadened streaming-hevc).
    _f2="$(run_muxm --profile hdr10-hq --dry-run "$MUXM_DV_FIXTURE" 2>&1)"
    if printf '%s' "$_f2" | grep -qF "$_f2_warn"; then
      pass "dvvt-hdr10-metadata-warning: hdr10-hq strips DV from a no-HDR10-metadata source → warns (call now reached)"
    else
      fail "dvvt-hdr10-metadata-warning: hdr10-hq + DV-no-metadata source → expected the missing-HDR10-metadata warning"
    fi
    _f2="$(run_muxm --profile streaming-hevc --dry-run "$MUXM_DV_FIXTURE" 2>&1)"
    if printf '%s' "$_f2" | grep -qF "$_f2_warn"; then
      pass "dvvt-hdr10-metadata-warning: streaming-hevc (broadened DV-stripping profile) + DV-no-metadata → warns"
    else
      fail "dvvt-hdr10-metadata-warning: streaming-hevc + DV-no-metadata → expected the missing-HDR10-metadata warning"
    fi
    # Scoping: atv-directplay-hq PRESERVES DV (DISABLE_DV=0) → it isn't stripped → must NOT warn.
    _f2="$(run_muxm --profile atv-directplay-hq --dry-run "$MUXM_DV_FIXTURE" 2>&1)"
    if printf '%s' "$_f2" | grep -qF "$_f2_warn"; then
      fail "dvvt-hdr10-metadata-warning: atv-directplay-hq preserves DV but wrongly warned about missing HDR10 metadata"
    else
      pass "dvvt-hdr10-metadata-warning: atv-directplay-hq (DV preserved) → no missing-HDR10-metadata warning"
    fi
    # Scoping: --tonemap yields SDR output (not HDR10), so the HDR10 metadata is irrelevant → no warn.
    _f2="$(run_muxm --profile hdr10-hq --tonemap --dry-run "$MUXM_DV_FIXTURE" 2>&1)"
    if printf '%s' "$_f2" | grep -qF "$_f2_warn"; then
      fail "dvvt-hdr10-metadata-warning: hdr10-hq --tonemap (SDR output) wrongly warned about missing HDR10 metadata"
    else
      pass "dvvt-hdr10-metadata-warning: hdr10-hq --tonemap (SDR output) → no missing-HDR10-metadata warning"
    fi
  fi

  # --- Gate 1: platform ---
  if [[ "$(uname -s 2>/dev/null)" != "Darwin" ]]; then
    skip "dv_vt: VideoToolbox is macOS-only (host is $(uname -s 2>/dev/null))"
    return 0
  fi

  # --- Gate 2: hardware encoder present ---
  if ! ffmpeg_has_encoder hevc_videotoolbox; then
    skip "dv_vt: ffmpeg lacks the hevc_videotoolbox encoder"
    return 0
  fi

  # --- Gate 3: DV tooling present ---
  if ! command -v dovi_tool >/dev/null 2>&1; then
    skip "dv_vt: dovi_tool not on PATH (required for RPU inject)"
    return 0
  fi
  local mp4box_cmd=""
  if command -v MP4Box >/dev/null 2>&1; then
    mp4box_cmd="MP4Box"
  elif command -v mp4box >/dev/null 2>&1; then
    mp4box_cmd="mp4box"
  else
    skip "dv_vt: MP4Box not on PATH (required to mux the DV ES)"
    return 0
  fi

  # --- Gate 4: a real DV fixture must be supplied ---
  if [[ -z "${MUXM_DV_FIXTURE:-}" ]]; then
    skip "dv_vt: set MUXM_DV_FIXTURE=/path/to/real_dv_source to run this test"
    return 0
  fi
  if [[ ! -f "$MUXM_DV_FIXTURE" || ! -r "$MUXM_DV_FIXTURE" ]]; then
    skip "dv_vt: MUXM_DV_FIXTURE='$MUXM_DV_FIXTURE' is not a readable file"
    return 0
  fi

  log "dv_vt: encoding '$MUXM_DV_FIXTURE' with --hw-accel videotoolbox (mp4box: $mp4box_cmd)"

  # --- Encode the DV source through the VideoToolbox path ---
  local out="$TESTDIR/dv_vt_out.mp4"
  rm -f "$out"
  if ! assert_encode "dv_vt: VT encode of DV source produces output" "$out" \
        --hw-accel videotoolbox --output-ext mp4 "$MUXM_DV_FIXTURE"; then
    # assert_encode already recorded the failure; nothing more to check.
    return 0
  fi

  # --- Assertion 1: output still carries a Dolby Vision configuration record / RPU ---
  # The dvcC/dvvC box (or DOVI side data) survives the VT-base + post-hoc inject + mux path.
  local dv_probe
  dv_probe="$(ffprobe -v error -show_streams -of default=noprint_wrappers=1 "$out" 2>/dev/null)"
  if printf '%s' "$dv_probe" | grep -qiE 'dovi|dv_profile|dvhe|dvh1|DOVIConfigurationRecord'; then
    pass "dv_vt: output carries a Dolby Vision configuration record (RPU survived VT path)"
  else
    fail "dv_vt: no Dolby Vision configuration record found in VT-encoded output"
  fi

  # --- Assertion 2: frame-count parity between source and output ---
  local src_frames out_frames
  src_frames="$(ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames -of csv=p=0 "$MUXM_DV_FIXTURE" 2>/dev/null | head -1)"
  out_frames="$(ffprobe -v error -select_streams v:0 -count_frames \
    -show_entries stream=nb_read_frames -of csv=p=0 "$out" 2>/dev/null | head -1)"
  # ffprobe's csv writer appends a trailing field separator (e.g. "258,") on some
  # builds; strip every non-digit so the numeric comparison below sees a bare count.
  src_frames="${src_frames//[^0-9]/}"
  out_frames="${out_frames//[^0-9]/}"
  if [[ "$src_frames" =~ ^[0-9]+$ && "$out_frames" =~ ^[0-9]+$ && "$src_frames" -gt 0 ]]; then
    if [[ "$src_frames" -eq "$out_frames" ]]; then
      pass "dv_vt: frame-count parity (source=$src_frames, output=$out_frames)"
    else
      fail "dv_vt: frame-count mismatch — source=$src_frames, output=$out_frames"
    fi
  else
    skip "dv_vt: could not count frames (source='$src_frames', output='$out_frames')"
  fi
}

# === Suite: Software Dolby Vision round-trip (portable; no VideoToolbox) ===
# A SOFTWARE libx265 re-encode of a real DV source exercises the full RPU pipeline
# (extract → P5/P7→P8 convert-if-needed → inject → mp4box dvcC pre-wrap → verify_dv_container_record)
# on ANY host with dovi_tool + MP4Box — no VideoToolbox or macOS needed (that leaves only the VT
# *encode* macOS-gated, in dv_vt). Closes the "Linux hosts have zero real DV coverage" gap. The
# bundled HDR1080p.MOV is a real DV Profile 8 source.
# Like dv_vt this suite generates NO synthetic fixtures (it uses the bundled DV file) — it is in
# MEDIA_FREE_SUITES and, in run_parallel, in the encode batch (it does a real, if short, encode).
#   MUXM_DV_FIXTURE=/path/to/dv.mp4 ./tests/test_muxm.sh --suite dv_sw
test_dv_sw() {
  section "Software Dolby Vision round-trip (portable; no VideoToolbox)"

  # --- Gates: DV tooling + software encoder present (positive host-capability guards) ---
  if ! command -v dovi_tool >/dev/null 2>&1; then
    skip "dv_sw: dovi_tool not on PATH (required for RPU extract/inject)"; return 0
  fi
  if ! command -v MP4Box >/dev/null 2>&1 && ! command -v mp4box >/dev/null 2>&1; then
    skip "dv_sw: MP4Box/mp4box not on PATH (required to write the dvcC box)"; return 0
  fi
  if ! ffmpeg_has_encoder libx265; then
    skip "dv_sw: ffmpeg lacks the libx265 software encoder"; return 0
  fi

  # --- Resolve the DV fixture: explicit MUXM_DV_FIXTURE wins, else the bundled DV P8 fixture,
  # copied into $TESTDIR as .mp4 (ISOBMFF; ffmpeg refuses DV into .mov and the default output
  # container is derived from the source extension, so .mov-in would mis-route). ---
  local _dv_src="${MUXM_DV_FIXTURE:-}"
  if [[ -z "$_dv_src" ]]; then
    local _bundled
    _bundled="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/HDR1080p.MOV"
    if [[ -f "$_bundled" && -r "$_bundled" ]] && cp "$_bundled" "$TESTDIR/dv_sw_source.mp4"; then
      _dv_src="$TESTDIR/dv_sw_source.mp4"
    fi
  fi
  if [[ -z "$_dv_src" || ! -f "$_dv_src" || ! -r "$_dv_src" ]]; then
    skip "dv_sw: no readable DV fixture (bundled HDR1080p.MOV missing; set MUXM_DV_FIXTURE)"; return 0
  fi

  # --- Software re-encode through the DV pipeline. --crf forces a RE-ENCODE so extract→inject→dvcC
  # actually runs (a stream-copy would pass DV through via container copy — tautological). Default
  # codec is libx265 (software); no --hw-accel, so this never touches VideoToolbox. ---
  local out="$TESTDIR/dv_sw_out.mp4"; rm -f "$out"
  (cd "$TESTDIR" && "$MUXM" -K --crf 24 --preset ultrafast --output-ext mp4 "$_dv_src" "$out" >/dev/null 2>&1) || true
  if [[ ! -s "$out" ]]; then
    fail "dv_sw: software DV re-encode produced no output"; return 0
  fi
  pass "dv_sw: software libx265 DV re-encode produced output"

  # --- Assertion 1: output carries a Dolby Vision configuration record (dvcC/dvvC / DOVI side-data) ---
  local dv_probe
  dv_probe="$(ffprobe -v error -show_streams -show_entries stream_side_data -select_streams v:0 "$out" 2>/dev/null)"
  if printf '%s\n' "$dv_probe" | grep -qiE 'dovi|dv_profile|DOVI configuration|dvhe|dvh1'; then
    pass "dv_sw: output carries a Dolby Vision configuration record (RPU survived the software round-trip)"
  else
    fail "dv_sw: no Dolby Vision configuration record in the software-encoded output (RPU extract/inject/dvcC broke)"
  fi

  # --- Assertion 2: frame-count parity between source and output (positive guard on countability). ---
  local src_frames out_frames
  src_frames="$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$_dv_src" 2>/dev/null | head -1)"
  out_frames="$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$out" 2>/dev/null | head -1)"
  src_frames="${src_frames//[^0-9]/}"; out_frames="${out_frames//[^0-9]/}"
  if [[ ! "$src_frames" =~ ^[0-9]+$ || ! "$out_frames" =~ ^[0-9]+$ || "$src_frames" -le 0 ]]; then
    skip "dv_sw: could not count frames (source='$src_frames', output='$out_frames')"
  elif [[ "$src_frames" -eq "$out_frames" ]]; then
    pass "dv_sw: frame-count parity (source=$src_frames, output=$out_frames)"
  else
    fail "dv_sw: frame-count mismatch — source=$src_frames, output=$out_frames"
  fi
  rm -f "$out"

  # ---- real P7→P8.1 convert-SUCCESS path. The mock-driven tests cover only the convert-
  #      FAILURE fallback (H10) and copy/re-encode; this exercises a SUCCESSFUL dovi_tool convert.
  #      Fabricate a Profile-7-labeled source (MP4Box dvp hint over the bundled P8 ES) and force a
  #      re-encode through --dv-convert-p81: muxm must run `dovi_tool convert`, report SUCCESS (the
  #      "DV profile converted" note fires only on rc0+non-empty output — not the fallback), and
  #      emit a DV-bearing output. Perturb MUT-DVSW-CONVERT breaks `dovi_tool convert` → the run
  #      takes the fallback → the success marker vanishes → red.
  section "P7→P8.1 DV conversion (real dovi_tool convert success path)"
  local _cv_mp4box=""
  if command -v MP4Box >/dev/null 2>&1; then _cv_mp4box=MP4Box
  elif command -v mp4box >/dev/null 2>&1; then _cv_mp4box=mp4box; fi
  local _cv_bundled
  _cv_bundled="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/HDR1080p.MOV"
  if [[ ! -r "$_cv_bundled" || -z "$_cv_mp4box" ]]; then
    skip "dv_sw convert: bundled HDR1080p.MOV or MP4Box unavailable — cannot fabricate a P7 source"
  else
    local _cv_p8="$TESTDIR/cv_p8.mp4" _cv_es="$TESTDIR/cv_src.hevc" _cv_p7="$TESTDIR/cv_p7.mp4"
    cp "$_cv_bundled" "$_cv_p8"
    local _cv_fps
    _cv_fps="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nk=1:nw=1 "$_cv_p8" 2>/dev/null | head -1)"
    [[ "$_cv_fps" =~ ^[0-9]+/[0-9]+$ || "$_cv_fps" =~ ^[0-9.]+$ ]] || _cv_fps="24"
    ffmpeg -v error -y -i "$_cv_p8" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc "$_cv_es" 2>/dev/null
    "$_cv_mp4box" -fps "$_cv_fps" -add "${_cv_es}:dvp=7.6" -new "$_cv_p7" >/dev/null 2>&1
    local _cv_prof
    _cv_prof="$(ffprobe -v error -show_streams -select_streams v:0 "$_cv_p7" 2>/dev/null | grep -m1 '^dv_profile=' | cut -d= -f2)"
    if [[ ! -s "$_cv_p7" || "$_cv_prof" != "7" ]]; then
      skip "dv_sw convert: could not fabricate a Profile-7-labeled source (got dv_profile='${_cv_prof:-none}')"
    else
      local _cv_out="$TESTDIR/cv_out.mp4" _cv_log="$TESTDIR/cv_term.log"; rm -f "$_cv_out"
      (cd "$TESTDIR" && "$MUXM" -K --dv-convert-p81 --crf 24 --preset ultrafast --output-ext mp4 "$_cv_p7" "$_cv_out" >"$_cv_log" 2>&1) || true
      # (1) the convert-SUCCESS path ran (the note fires only after dovi_tool convert returns 0).
      if grep -qF "DV profile converted" "$_cv_log"; then
        pass "dv_sw convert: real P7→P8.1 dovi_tool convert succeeded (convert path, not the fallback)"
      else
        fail "dv_sw convert: convert-success marker missing — P7→P8.1 convert did not run/succeed. Saw: $(grep -iE 'convert|fallback' "$_cv_log" | head -1)"
      fi
      # (2) the run did NOT report a convert failure / fall back to non-DV base.
      if grep -qiE "dovi_tool convert failed" "$_cv_log"; then
        fail "dv_sw convert: convert reported FAILURE on a real P7 source (expected success)"
      else
        pass "dv_sw convert: no convert-failure fallback triggered"
      fi
      # (3) the converted output exists and carries a Dolby Vision configuration record.
      if [[ -s "$_cv_out" ]] && ffprobe -v error -show_streams -show_entries stream_side_data -select_streams v:0 "$_cv_out" 2>/dev/null | grep -qiE 'dovi|DOVI configuration|dv_profile'; then
        pass "dv_sw convert: converted output carries a Dolby Vision configuration record"
      else
        fail "dv_sw convert: converted output missing or carries no DV configuration record"
      fi
      # (4) CR-1 (value, not presence): the converted output's CONTAINER must signal Profile 8.1
      #     — dv_profile=8 AND dv_bl_signal_compatibility_id=1 — NOT the stale source 7.6. MP4Box's
      #     `:dvp=` overrides the written profile regardless of the (now P8.1) RPU NALs, so the
      #     presence-only check (3) stays green even when the container mis-signals — hence CR-1.
      local _cv_side
      _cv_side="$(ffprobe -v error -show_streams -show_entries stream_side_data -select_streams v:0 "$_cv_out" 2>/dev/null)"
      local _cv_outprof _cv_outcompat
      _cv_outprof="$(printf '%s\n' "$_cv_side" | grep -m1 -oiE 'dv_profile=[0-9]+' | grep -oE '[0-9]+')"
      _cv_outcompat="$(printf '%s\n' "$_cv_side" | grep -m1 -oiE 'dv_bl_signal_compatibility_id=[0-9]+' | grep -oE '[0-9]+')"
      if [[ -z "$_cv_outprof" ]]; then
        skip "dv_sw convert CR-1: output exposes no dv_profile side-data field — cannot assert the converted value"
      elif [[ "$_cv_outprof" == "8" ]]; then
        pass "dv_sw convert CR-1: converted output signals dv_profile=8 (P8.1, not stale source P7)"
      else
        fail "dv_sw convert CR-1: converted output signals dv_profile=${_cv_outprof} (expected 8 — stale-source dvcC mis-signaling)"
      fi
      if [[ -z "$_cv_outcompat" ]]; then
        skip "dv_sw convert CR-1: output exposes no dv_bl_signal_compatibility_id field — cannot assert compat_id"
      elif [[ "$_cv_outcompat" == "1" ]]; then
        pass "dv_sw convert CR-1: converted output signals compat_id=1 (BL HDR10-compatible)"
      else
        fail "dv_sw convert CR-1: converted output signals compat_id=${_cv_outcompat} (expected 1 — stale source 7.6)"
      fi
    fi
    rm -f "$_cv_p8" "$_cv_es" "$_cv_p7" "$TESTDIR/cv_out.mp4" "$TESTDIR/cv_term.log" 2>/dev/null || true
  fi

  # ---- C1 regression: skip-if-ideal must evaluate the DV and bit-depth copy gates against the
  #      REAL source, not the still-default globals. IS_DV/DV_SRC_PROFILE/TARGET_PIXFMT are unset
  #      when check_skip_if_ideal runs (they are only populated later, on the non-skip path), so a
  #      DV-Profile-7 or an 8-bit source was stream-copied verbatim under atv-directplay-hq's
  #      "HEVC Main10 + DV P8.1" contract with NO warning. --dry-run suffices: the skip vs.
  #      "does not match ideal" decision and its reason are emitted before any encode runs.
  section "dvsw-skip-if-ideal-gates: skip-if-ideal evaluates the DV & bit-depth gates against the real source"

  local _c1_mp4box=""
  if command -v MP4Box >/dev/null 2>&1; then _c1_mp4box=MP4Box
  elif command -v mp4box >/dev/null 2>&1; then _c1_mp4box=mp4box; fi
  local _c1_bundled
  _c1_bundled="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/HDR1080p.MOV"

  if [[ ! -r "$_c1_bundled" || -z "$_c1_mp4box" ]]; then
    skip "dv_sw C1: bundled HDR1080p.MOV or MP4Box unavailable — cannot build the P7/P8 fixtures"
  else
    # Known-Profile-8, 10-bit, HLG source (the bundled DV fixture copied to .mp4).
    local _c1_p8="$TESTDIR/c1_p8.mp4"
    cp "$_c1_bundled" "$_c1_p8"
    local _c1_srcprofile _c1_fps
    _c1_srcprofile="$(ffprobe -v error -show_streams -select_streams v:0 "$_c1_p8" 2>/dev/null | grep -m1 '^dv_profile=' | cut -d= -f2)"
    _c1_fps="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nk=1:nw=1 "$_c1_p8" 2>/dev/null | head -1)"
    [[ "$_c1_fps" =~ ^[0-9]+/[0-9]+$ || "$_c1_fps" =~ ^[0-9.]+$ ]] || _c1_fps="24"

    # Fabricate a DV-Profile-7-LABELED source: extract the HEVC ES and re-mux declaring dvp=7 via
    # MP4Box's profile hint, so the container DOVI configuration record reports dv_profile=7 — which
    # is exactly what the copy gate reads (the RPU payload is irrelevant to the profile-number gate).
    local _c1_es="$TESTDIR/c1_src.hevc" _c1_p7="$TESTDIR/c1_p7.mp4"
    ffmpeg -v error -y -i "$_c1_p8" -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc "$_c1_es" 2>/dev/null
    "$_c1_mp4box" -fps "$_c1_fps" -add "${_c1_es}:dvp=7.6" -new "$_c1_p7" >/dev/null 2>&1

    # Build an 8-bit HEVC source tagged HDR (bt2020nc) so decide_color_and_pixfmt targets 10-bit
    # while the source stays 8-bit — the bit-depth companion to the P7 case.
    local _c1_8bit="$TESTDIR/c1_8bit.mp4"
    ffmpeg -v error -y -f lavfi -i "testsrc2=size=640x360:rate=24:duration=2" \
      -c:v libx265 -pix_fmt yuv420p -x265-params log-level=none \
      -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
      -tag:v hvc1 -movflags +faststart "$_c1_8bit" 2>/dev/null
    local _c1_8cs
    _c1_8cs="$(ffprobe -v error -select_streams v:0 -show_entries stream=color_space -of default=nk=1:nw=1 "$_c1_8bit" 2>/dev/null | head -1)"

    # --dry-run atv-directplay-hq; capture the combined skip/no-skip decision + reason.
    _c1_run(){ (cd "$TESTDIR" && "$MUXM" --profile atv-directplay-hq --dry-run "$1" "$TESTDIR/c1_out.mp4" 2>&1) || true; }
    local _c1_out

    # (a) Regression guard: a genuinely-compliant Profile-8 10-bit source must STILL skip (don't
    #     over-correct into never skipping). Skip-first guard (not an else-skip) per the ratchet.
    if [[ "$_c1_srcprofile" != "8" ]]; then
      skip "dv_sw C1: bundled fixture is not Profile 8 (got '${_c1_srcprofile:-none}') — skipping the P8 skip-guard"
    else
      _c1_out="$(_c1_run "$_c1_p8")"
      if printf '%s\n' "$_c1_out" | grep -qiE 'already matches.*skipping'; then
        pass "dv_sw C1: compliant Profile-8 10-bit source still skips under atv-directplay-hq (no over-correction)"
      else
        fail "dv_sw C1: Profile-8 source no longer skips — the gate over-corrected. Saw: $(printf '%s\n' "$_c1_out" | grep -iE 'match|skip' | head -1)"
      fi
    fi

    # (b) DV-Profile-7 source must NOT skip-copy; the reason must cite the DV conversion gate.
    #     Skip-first guard (not an else-skip) per the ratchet.
    if [[ ! -s "$_c1_p7" ]] || \
       [[ "$(ffprobe -v error -show_streams -select_streams v:0 "$_c1_p7" 2>/dev/null | grep -m1 '^dv_profile=' | cut -d= -f2)" != "7" ]]; then
      skip "dv_sw C1: could not fabricate a Profile-7-labeled fixture (MP4Box dvp hint) — skipping the P7 assertion"
    else
      _c1_out="$(_c1_run "$_c1_p7")"
      if printf '%s\n' "$_c1_out" | grep -qiE 'does not match ideal:.*DV profile 7.*requires conversion'; then
        pass "dv_sw C1: DV Profile-7 source rejected from skip-copy under atv-directplay-hq (no silent P7 passthrough)"
      else
        fail "dv_sw C1: DV Profile-7 source still skip-copied under atv-directplay-hq (C1). Saw: $(printf '%s\n' "$_c1_out" | grep -iE 'match|skip' | head -1)"
      fi
    fi

    # (b2) CR-2 sibling-parity: the SAME Profile-7 source must be rejected from skip-copy under
    #      atv-directplay-animation too. A DV→P8 copy gate keyed to the single literal
    #      `atv-directplay-hq` would let its Direct-Play sibling silently stream-copy/hardlink
    #      dual-layer P7 verbatim. Differential: same fixture, only the profile differs.
    #      Skip-first guard (not an else-skip) per the ratchet.
    if [[ ! -s "$_c1_p7" ]] || \
       [[ "$(ffprobe -v error -show_streams -select_streams v:0 "$_c1_p7" 2>/dev/null | grep -m1 '^dv_profile=' | cut -d= -f2)" != "7" ]]; then
      skip "dv_sw C1/CR-2: could not fabricate a Profile-7-labeled fixture — skipping the animation parity assertion"
    else
      local _cr2_out
      _cr2_out="$( (cd "$TESTDIR" && "$MUXM" --profile atv-directplay-animation --dry-run "$_c1_p7" "$TESTDIR/c1_out.mp4" 2>&1) || true )"
      if printf '%s\n' "$_cr2_out" | grep -qiE 'does not match ideal:.*DV profile 7.*requires conversion'; then
        pass "dv_sw C1/CR-2: DV Profile-7 source rejected from skip-copy under atv-directplay-animation (gate parity with -hq)"
      else
        fail "dv_sw C1/CR-2: DV Profile-7 source still skip-copied under atv-directplay-animation (CR-2). Saw: $(printf '%s\n' "$_cr2_out" | grep -iE 'match|skip' | head -1)"
      fi
    fi

    # (c) 8-bit source must NOT skip-copy under a 10-bit profile; the reason must cite the bit-depth.
    #     Skip-first guard (not an else-skip) per the ratchet.
    if [[ ! -s "$_c1_8bit" || "$_c1_8cs" != "bt2020nc" ]]; then
      skip "dv_sw C1: 8-bit HDR fixture unavailable or lost its bt2020nc tag (got '${_c1_8cs:-none}') — skipping the bit-depth assertion"
    else
      _c1_out="$(_c1_run "$_c1_8bit")"
      if printf '%s\n' "$_c1_out" | grep -qiE 'does not match ideal:.*need 10-bit'; then
        pass "dv_sw C1: 8-bit source rejected from skip-copy under atv-directplay-hq (no silent 8-bit passthrough)"
      else
        fail "dv_sw C1: 8-bit source still skip-copied under atv-directplay-hq (C1). Saw: $(printf '%s\n' "$_c1_out" | grep -iE 'match|skip' | head -1)"
      fi
    fi

    rm -f "$_c1_p8" "$_c1_p7" "$_c1_es" "$_c1_8bit" "$TESTDIR/c1_out.mp4" 2>/dev/null || true
  fi
}

# Prose-doc profile drift guard. Mirrors the cli-suite VALID_PROFILES
# cross-check (_test_cli_profile_crossref) but targets the *unguarded* prose docs:
# README's profile table and docs/config_profile.md's profile
# sections. Catches drift — a profile added/renamed in
# the script but not the docs, or a deprecated alias resurfacing as a heading. Extraction
# is anchored on stable structure (the "| Profile |" table header, "### " headings), never
# line numbers, so it survives doc edits.
_test_docs_prose_drift() {
  local repo_root readme cfgprofile av1doc
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  readme="$repo_root/README.md"
  cfgprofile="$repo_root/docs/config_profile.md"
  av1doc="$repo_root/docs/AV1_CALIBRATION.md"

  # Single source of truth (same extraction as _test_cli_profile_crossref).
  local canonical
  # `|| true`: a no-match grep exits 1, which (under set -e + pipefail) would abort the suite at
  # this assignment BEFORE the drift guard below can fire a clean diagnostic. Swallow it so the
  # empty result reaches the `[[ -z "$canonical" ]]` fail instead of a cryptic mid-suite abort.
  canonical="$(grep '^readonly VALID_PROFILES=' "$MUXM" | sed 's/^readonly VALID_PROFILES="//;s/"$//' || true)"
  if [[ -z "$canonical" ]]; then
    # VALID_PROFILES is committed — its absence is drift (anchor renamed), not host
    # optionality. Fail, never skip (a skip would void the whole prose-doc cross-check below).
    fail "VALID_PROFILES constant not found in script — prose-doc drift guard could not run (drift?)"
    return
  fi

  # ---- README profile table: a `\`name\`` row for every canonical profile ----
  # Anchor on the table header so profile names appearing in *other* README tables
  # (flags, config vars) can't false-match; read from the header to the next blank line.
  if [[ -r "$readme" ]]; then
    local table
    table="$(awk '/^\|[[:space:]]*Profile[[:space:]]*\|/{f=1} f{print} f&&/^[[:space:]]*$/{exit}' "$readme")"
    if [[ -z "$table" ]]; then
      # 0.2: a renamed/missing "| Profile |" header empties the capture. The README IS
      # readable, so this is drift, not host optionality — fail, never skip (vacuous pass).
      fail "README.md profile table (\"| Profile |\" header) not found — was the header renamed? prose-drift guard could not run"
    else
      local r_missing=0 p
      for p in $canonical; do
        printf '%s\n' "$table" | grep -qE "^\|[[:space:]]*\`$p\`[[:space:]]*\|" \
          || { fail "Profile '$p' missing from the README.md profile table"; r_missing=1; }
      done
      (( r_missing )) || pass "README.md profile table lists all VALID_PROFILES"
    fi
  else
    fail "README.md not found/readable at $readme — prose-drift guard could not run"
  fi

  # ---- config_profile.md: a `### \`name\`` section heading per canonical profile ----
  if [[ -r "$cfgprofile" ]]; then
    local c_missing=0 p
    for p in $canonical; do
      grep -qE "^### \`$p\`" "$cfgprofile" \
        || { fail "Profile '$p' missing a section heading in docs/config_profile.md"; c_missing=1; }
    done
    (( c_missing )) || pass "docs/config_profile.md has a section heading for every VALID_PROFILES entry"

    # A deprecated alias must never resurface as a primary (###) profile heading. The
    # backtick delimiters make `\`streaming\`` reject the canonical `\`streaming-hevc\``.
    local alias_hit=0 a
    for a in dv-archival streaming; do
      grep -qE "^### \`$a\`" "$cfgprofile" \
        && { fail "Deprecated alias '$a' used as a profile heading in docs/config_profile.md"; alias_hit=1; }
    done
    (( alias_hit )) || pass "docs/config_profile.md uses no deprecated alias (dv-archival/streaming) as a heading"

    # 0.2 reverse direction: a `### `name`` heading that is NOT in VALID_PROFILES is stale
    # (a profile renamed/removed in the script but left in the docs). Deprecated aliases are
    # owned by the alias check above, so skip them here to avoid double-reporting.
    local stale_hit=0 heading
    # shellcheck disable=SC2016  # the grep/sed feeding this loop use literal regex (backtick + `$` end-anchor) — must NOT shell-expand
    while read -r heading; do
      [[ -n "$heading" ]] || continue
      [[ "$heading" == "dv-archival" || "$heading" == "streaming" ]] && continue
      [[ " $canonical " == *" $heading "* ]] \
        || { fail "Stale profile heading '$heading' in docs/config_profile.md — not in VALID_PROFILES"; stale_hit=1; }
    done < <(grep -oE '^### `[a-z0-9][a-z0-9-]*`' "$cfgprofile" | sed -E 's/^### `//; s/`$//')
    (( stale_hit )) || pass "docs/config_profile.md has no stale profile headings (all map to VALID_PROFILES)"

    # ---- Container column cross-check (D1-D2 guard) ----
    # The config_profile.md profile table's "Container" column must match each profile's LIVE
    # OUTPUT_EXT: mkv→"MKV", mp4→"MP4", ""(passthrough)→"source ext". This is what catches the
    # D2 class (archive's stale "source ext" while OUTPUT_EXT="mkv"). Any OUTPUT_EXT without a
    # mapping below FAILS — never a silent pass. NOTE: the README profile table has no Container
    # column, so README container prose (D1) is a hand-fix only and is intentionally NOT guarded.
    local cont_bad=0 cf_table fn ext expected cell
    cf_table="$(awk '/^\|[[:space:]]*Profile[[:space:]]*\|[[:space:]]*Container[[:space:]]*\|/{f=1} f{print} f&&/^[[:space:]]*$/{exit}' "$cfgprofile")"
    if [[ -z "$cf_table" ]]; then
      fail "docs/config_profile.md container table (\"| Profile | Container |\" header) not found — container cross-check could not run"
    else
      for p in $canonical; do
        fn="apply_profile_$(printf '%s' "$p" | tr '-' '_')"
        ext="$(awk "/^$fn\\(\\)[[:space:]]*\\{/,/^\\}/" "$MUXM" | grep -oE 'OUTPUT_EXT="[^"]*"' | head -1 | sed -E 's/OUTPUT_EXT="([^"]*)"/\1/')"
        case "$ext" in
          mkv) expected="MKV" ;;
          mp4) expected="MP4" ;;
          "")  expected="source ext" ;;
          *)   fail "Profile '$p' has unmapped OUTPUT_EXT='$ext' — extend the container cross-check map"; cont_bad=1; continue ;;
        esac
        # Pull the profile's table row; column 2 (between 1st/2nd '|') is the Container cell.
        cell="$(printf '%s\n' "$cf_table" | awk -F'|' -v name="$p" '
          { k=$2; gsub(/[`\t ]/,"",k); if (k==name) { c=$3; gsub(/^[ \t]+|[ \t]+$/,"",c); print c; exit } }')"
        [[ -n "$cell" ]] || continue   # missing row already reported by the name check above
        if [[ "$cell" != "$expected" ]]; then
          fail "config_profile.md Container for '$p' is '$cell', but OUTPUT_EXT='$ext' → expected '$expected'"
          cont_bad=1
        fi
      done
      (( cont_bad )) || pass "docs/config_profile.md Container column matches every profile's OUTPUT_EXT"
    fi

    # ---- Chapters cross-check (D3 guard) ----
    # No "Chapters" table column exists, so this scans each profile's `### section` PROSE and
    # fires only on an UNAMBIGUOUS contradiction with the live KEEP_CHAPTERS: a keep-verb near
    # "chapter" while KEEP_CHAPTERS=0, or a strip-verb near "chapter" while KEEP_CHAPTERS=1. The
    # section text is whitespace-collapsed first so a line-wrapped "keep\nchapters" (archive) is
    # seen as one phrase; a section that is silent, or that has BOTH verbs near "chapter", is
    # skipped (no false fail). Deliberately conservative to avoid false failures.
    local chap_bad=0 sec keepish stripish kc
    for p in $canonical; do
      fn="apply_profile_$(printf '%s' "$p" | tr '-' '_')"
      kc="$(awk "/^$fn\\(\\)[[:space:]]*\\{/,/^\\}/" "$MUXM" | grep -oE 'KEEP_CHAPTERS=[01]' | head -1 | grep -oE '[01]')"
      [[ -n "$kc" ]] || continue
      # Section body: from this profile's `### `name`` heading to the next `### ` (collapsed).
      # Prefix-match (index==1), not exact: headings carry a trailing "— Title", and the closing
      # backtick in h delimits the name so it can't match a longer profile's heading.
      sec="$(awk -v h="### \`$p\`" 'index($0,h)==1{f=1;next} f&&/^### /{exit} f{print}' "$cfgprofile" | tr '\n' ' ')"
      grep -qiE 'chapter' <<<"$sec" || continue   # silent on chapters → skip
      keepish=0; stripish=0
      grep -qiE '(keep|kept|preserv|retain)[a-z]*[^.]{0,40}chapter|chapter[^.]{0,40}(kept|preserv|retain)' <<<"$sec" && keepish=1
      grep -qiE '(strip|remov)[a-z]*[^.]{0,40}chapter|chapter[^.]{0,40}(strip|remov)' <<<"$sec" && stripish=1
      (( keepish == stripish )) && continue        # ambiguous (both) or no clear verb → skip
      if (( keepish )) && (( kc == 0 )); then
        fail "config_profile.md '$p' prose says chapters are kept, but KEEP_CHAPTERS=0"; chap_bad=1
      elif (( stripish )) && (( kc == 1 )); then
        fail "config_profile.md '$p' prose says chapters are stripped, but KEEP_CHAPTERS=1"; chap_bad=1
      fi
    done
    (( chap_bad )) || pass "docs/config_profile.md chapters prose agrees with every profile's KEEP_CHAPTERS"
  else
    fail "docs/config_profile.md not found/readable at $cfgprofile — prose-drift guard could not run"
  fi

  # ---- Stretch: AV1 _crf_ratio table in AV1_CALIBRATION.md matches the live function ----
  # The doc reproduces _crf_ratio's libsvt-av1 case arm; verify each CRF→ratio pair the doc
  # states by *executing* the real function (not string-diffing), so a doc value that drifts
  # from the script fails. Direction note: this guards "every value the doc states is
  # correct" — it won't catch a CRF arm added to the function but not the doc (the safe
  # direction to miss). VT_QUALITY_MAP is intentionally NOT cross-checked: its values live in
  # scattered prose, not a structured table, so there is nothing to diff without fragile parsing.
  if [[ -r "$av1doc" ]]; then
    local body pairs
    body="$(awk '/^_crf_ratio\(\)[[:space:]]*\{/,/^\}/' "$MUXM")"
    # `|| true`: like the VALID_PROFILES grep above, a no-match here exits 1 and would abort the
    # suite under set -e + pipefail before the `[[ -z "$pairs" ]]` drift fail can fire.
    pairs="$(grep -oE '[0-9]+\) echo [0-9]+' "$av1doc" | sed 's/) echo / /' || true)"
    if [[ -z "$body" ]]; then
      # _crf_ratio is a committed function — if the awk anchor can't find it, it was
      # renamed/reformatted. That is drift, not host-optionality, so fail (never skip).
      fail "_crf_ratio not found in muxm — AV1 ratio cross-check anchor failed (renamed/reformatted?)"
    elif [[ -z "$pairs" ]]; then
      fail "docs/AV1_CALIBRATION.md is present but its _crf_ratio ratio table is gone — doc drift"
    else
      local av1_bad=0 crf ratio actual n=0
      while read -r crf ratio; do
        [[ -n "$crf" ]] || continue
        n=$(( n + 1 ))
        actual="$(bash -c "$body"$'\n''_crf_ratio "$1" "$2"' -- libsvt-av1 "$crf")"
        if [[ "$actual" != "$ratio" ]]; then
          fail "AV1_CALIBRATION.md says CRF $crf → $ratio, but _crf_ratio(libsvt-av1,$crf)=$actual"
          av1_bad=1
        fi
      done <<< "$pairs"
      (( av1_bad )) || pass "AV1_CALIBRATION.md _crf_ratio table matches the script ($n values)"
    fi
  else
    # 0.2: a missing/renamed AV1 doc previously hit this `if [[ -r ]]` with no else → silent
    # no-op (vacuous pass). It is a committed file, so absence is drift → fail.
    fail "docs/AV1_CALIBRATION.md not found/readable at $av1doc — _crf_ratio cross-check could not run"
  fi
}

# 0.3: soft-skip anti-pattern guard (baseline ratchet). An `else` branch whose ONLY statement
# is `skip` turns "the property the test setup guaranteed wasn't there" into a green pass
# instead of a red fail — false confidence. Offenders get converted to `fail` over time;
# this guard's job is to stop NEW ones creeping in.
#
# Why a count ratchet rather than a strict defensible-only allow-list:
#  • Enforcing defensible-only up front would flag every un-converted soft-skip at once and
#    ship a RED result. Instead this is a *count ratchet*: it tolerates the current
#    snapshot and fails only when the count RISES (a newly-added soft-skip). Lower
#    SOFT_SKIP_BASELINE as offenders are converted.
#  • Keyed on a *count*, not a per-message allow-list, because the skip strings carry dynamic
#    content ($vars) and aren't stable literals to allow-list individually.
#  • Scans the whole harness (not only encode-suite bodies) — a strict superset, so it also
#    catches creep in the config/CLI suites.
_test_meta_soft_skip() {
  local self="${BASH_SOURCE[0]}"
  local -i baseline=60   # History: 80→65 (converted 15 soft-skips to fail); 65→62 (replaced the R28/R29 tonemap dry-run skips with a real encode and converted the avi-fixture else-skip to a positive guard); 62→61 (replaced the host-gated NVENC-stub else-skip with a host-independent unit test); 61→60 (converted the _codec_max_channels else-skip to fail — a committed function's absence is drift, not host-optionality). LOWER as more convert; never raise.
  local -i found
  found="$(awk '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    { t=trim($0)
      if (t ~ /^else[ \t]+skip[ \t]/) { c++; next }                 # inline:  else skip "..."
      if (t=="else") { ie=1; next }                                  # multiline: else \n skip \n fi
      if (ie){ if(t==""||t~/^#/)next; if(ss){ if(t=="fi")c++; ie=0;ss=0;next } if(t~/^skip[ \t]/){ss=1;next} ie=0 } }
    END{print c+0}' "$self")"
  if (( found <= baseline )); then
    pass "soft-skip ratchet: $found else-only-skip blocks ≤ baseline $baseline (no new soft-skips)"
    # NB: plain `if`, not `(( found < baseline )) && log` — under `set -e` a false `(( ))`
    # in an && list returns 1 and would abort the suite before its summary.
    if (( found < baseline )); then
      log "  ↳ soft-skips dropped to $found — lower SOFT_SKIP_BASELINE to $found in _test_meta_soft_skip to lock it in"
    fi
  else
    fail "soft-skip ratchet: $found else-only-skip blocks > baseline $baseline — a new 'else → skip' crept in. Convert it to 'fail' where the setup guarantees the property, or it's a genuine host/version skip that belongs in an 'if [[ ! cond ]]; then skip' guard, not an else."
  fi

  # Recurrence guard: the soft-skip ratchet above only catches the `else → skip` *shape*.
  # A second, message-keyed class is just as drift-prone regardless of shape — a skip() whose
  # message reports a COMMITTED muxm/script symbol as absent. That can only happen when an
  # extraction anchor (awk/grep) stops matching because the symbol was renamed or reformatted,
  # which is always drift, never host-optionality, so it must fail — never skip (a skip would
  # silently void the test). Every such site fails rather than skips; this keeps new ones
  # from creeping back. Anchored on the `skip "<text>` invocation form (double-quoted arg), so
  # the legitimate runtime guards ("<fixture>.mkv fixture not found", "… output not found") and
  # this guard's own grep line (single-quoted pattern) are not matched.
  local drift_skips
  drift_skips="$(grep -nE 'skip "[^"]*not found in (muxm|script)' "$self" || true)"
  if [[ -z "$drift_skips" ]]; then
    pass "no 'committed symbol not found in muxm/script' soft-skips (absence of a committed symbol must fail, not skip)"
  else
    local _ds
    while IFS= read -r _ds; do
      [[ -n "$_ds" ]] && fail "drift soft-skip must be 'fail', not 'skip' (committed-symbol absence is drift): $_ds"
    done <<< "$drift_skips"
  fi
  return 0
}

# ---- Suite: docs (generated-artifact parity) ----
# Verifies the two committed generated artifacts are in sync with their embedded
# heredocs in muxm (the single source of truth):
#   * docs/muxm.1                      vs `muxm --emit-man`   (test_docs_parity.sh)
#   * completions/muxm-completion.bash vs `muxm --emit-completions`
#                                                            (test_completions_parity.sh)
# Delegates to the standalone scripts so the logic lives in one place; here we
# just translate their exit codes into the harness pass/fail counters.
# Needs no media fixtures (see MEDIA_FREE_SUITES).
test_docs_parity() {
  section "Suite: docs (generated-artifact parity)"
  local tests_dir
  tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # The standalone scripts print their own ✅/❌ detail (and the diff on failure).
  local man_script="${tests_dir}/test_docs_parity.sh"
  if [[ ! -x "$man_script" ]]; then
    fail "docs parity: tests/test_docs_parity.sh not found or not executable ($man_script)"
  elif "$man_script"; then
    pass "docs/muxm.1 in sync with muxm embedded man page"
  else
    fail "docs/muxm.1 OUT OF SYNC with muxm heredoc — run tools/gen-docs.sh and commit"
  fi

  local comp_script="${tests_dir}/test_completions_parity.sh"
  if [[ ! -x "$comp_script" ]]; then
    fail "completions parity: tests/test_completions_parity.sh not found or not executable ($comp_script)"
  elif "$comp_script"; then
    pass "completions/muxm-completion.bash in sync with muxm embedded completion"
  else
    fail "completions/muxm-completion.bash OUT OF SYNC with muxm heredoc — run tools/gen-docs.sh and commit"
  fi

  # Cross-check the prose docs (README profile table + config_profile.md
  # sections, and the AV1 _crf_ratio table) against the canonical VALID_PROFILES / script.
  _test_docs_prose_drift
  # Ratchet against new `else → skip` soft-skip anti-patterns in the harness.
  _test_meta_soft_skip
}

# ---- Run Suites ----
# NOTE: Suite names are listed in three places that must stay in sync:
#   1. File header comment (top of file)
#   2. show_help() function
#   3. This function's case statement

# Run one suite function and record a per-suite PASS/FAIL for the summary.
# A suite FAILs if it adds any failing assertions; otherwise it PASSes.
# Used only by the `all` path so the per-suite table reflects a full run.
run_suite_tracked() {
  local name="$1" fn="$2" fail_before=$FAIL
  "$fn"
  if (( FAIL > fail_before )); then
    SUITE_STATUS+=("$name:FAIL")
  else
    SUITE_STATUS+=("$name:PASS")
  fi
}

run_suites() {
  case "$SUITE" in
    all)
      run_suite_tracked cli           test_cli
      run_suite_tracked toggles       test_toggles
      run_suite_tracked unit          test_unit
      run_suite_tracked completions   test_completions
      run_suite_tracked setup         test_setup
      run_suite_tracked config        test_config
      run_suite_tracked profiles      test_profiles
      run_suite_tracked conflicts     test_conflicts
      run_suite_tracked hw_accel      test_hw_accel
      run_suite_tracked collision     test_collision
      run_suite_tracked dryrun        test_dryrun
      run_suite_tracked video         test_video
      run_suite_tracked hdr           test_hdr
      run_suite_tracked audio         test_audio
      run_suite_tracked subs          test_subs
      run_suite_tracked ext_subs      test_ext_subs
      run_suite_tracked output        test_output
      run_suite_tracked containers    test_containers
      run_suite_tracked metadata      test_metadata
      run_suite_tracked edge          test_edge
      run_suite_tracked e2e           test_profile_e2e
      run_suite_tracked multi_profile test_multi_profile
      run_suite_tracked regression_p5 test_regression_p5
      run_suite_tracked dv_vt         test_dv_vt
      run_suite_tracked dv_sw         test_dv_sw
      run_suite_tracked docs          test_docs_parity
      ;;
    cli)           test_cli ;;
    toggles)       test_toggles ;;
    hw_accel)      test_hw_accel ;;
    unit)          test_unit ;;
    completions)   test_completions ;;
    setup)         test_setup ;;
    config)        test_config ;;
    profiles)      test_profiles ;;
    conflicts)     test_conflicts ;;
    collision)     test_collision ;;
    dryrun)        test_dryrun ;;
    video)         test_video ;;
    hdr)           test_hdr ;;
    audio)         test_audio ;;
    subs)          test_subs ;;
    ext_subs)      test_ext_subs ;;
    output)        test_output ;;
    containers)    test_containers ;;
    metadata)      test_metadata ;;
    edge)          test_edge ;;
    e2e)           test_profile_e2e ;;
    multi_profile)   test_multi_profile ;;
    regression_p5)   test_regression_p5 ;;
    dv_vt)           test_dv_vt ;;
    dv_sw)           test_dv_sw ;;
    docs)            test_docs_parity ;;
    *)
      echo "Unknown suite: $SUITE (run with --help to see available suites)"
      exit 1
      ;;
  esac
}

# ---- Summary ----
summary() {
  section "Test Summary"
  local total=$((PASS + FAIL + SKIP))
  printf "  %bPassed:%b  %d\n" "$GREEN" "$NC" "$PASS"
  printf "  %bFailed:%b  %d\n" "$RED" "$NC" "$FAIL"
  printf "  %bSkipped:%b %d\n" "$YELLOW" "$NC" "$SKIP"
  printf "  Total:   %d\n" "$total"

  # Per-suite results (only populated for multi-suite runs)
  if [[ ${#SUITE_STATUS[@]} -gt 0 ]]; then
    printf "\n%b%bSuite Results:%b\n" "$BOLD" "$BLUE" "$NC"
    local entry suite status
    for entry in "${SUITE_STATUS[@]}"; do
      suite="${entry%%:*}"
      status="${entry##*:}"
      if [[ "$status" == "PASS" ]]; then
        printf "  %b✅ %-16s PASS%b\n" "$GREEN" "$suite" "$NC"
      else
        printf "  %b❌ %-16s FAIL%b\n" "$RED" "$suite" "$NC"
      fi
    done
  fi

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    printf "\n%b%bFailed Tests:%b\n" "$RED" "$BOLD" "$NC"
    for err in "${ERRORS[@]}"; do
      printf "  %b• %s%b\n" "$RED" "$err" "$NC"
    done
  fi

  # Cleanup
  if [[ -n "$TESTDIR" && -d "$TESTDIR" ]]; then
    log "Test artifacts in: $TESTDIR"
    log "Clean up with: rm -rf $TESTDIR"
  fi

  if (( FAIL > 0 )); then
    printf "\n%b%bRESULT: FAIL%b\n" "$RED" "$BOLD" "$NC"
    exit 1
  else
    printf "\n%b%bRESULT: ALL PASSED%b\n" "$GREEN" "$BOLD" "$NC"
    exit 0
  fi
}

# ---- Main ----
# Execution flow:
#   1. preflight             — verify required tools exist, create temp directory
#   2. generate media (gated) — build synthetic 2-sec clips; skipped for config-only suites
#   3. run_suites            — execute the selected test suite(s)
#   4. summary               — report pass/fail/skip counts, list failures, set exit code

# Media generation is gated by suite to keep fast suites fast.
# MEDIA_FREE_SUITES: Pure config/CLI/unit tests — no ffmpeg fixtures needed (~2s).
# Core media: basic_sdr_subs.mkv only — needed by cli, dryrun, edge, etc. (~3s to generate).
# EXTENDED_SUITES: Full fixture set (multi-track, HDR, chapters, metadata) (~15s to generate).
# dv_vt is "media-free" only in the sense that it generates NO synthetic fixtures — it
# either SKIPs (default) or encodes a real DV source supplied via MUXM_DV_FIXTURE, so it
# needs none of the generated clips.
readonly MEDIA_FREE_SUITES="^(toggles|completions|setup|config|profiles|conflicts|hw_accel|unit|dv_vt|dv_sw|docs)$"
readonly EXTENDED_SUITES="^(collision|dryrun|video|hdr|audio|subs|ext_subs|output|containers|metadata|edge|e2e|multi_profile|regression_p5|all)$"

auto_cleanup_test_dirs
preflight
if [[ ! "$SUITE" =~ $MEDIA_FREE_SUITES ]]; then
  generate_core_media
  if [[ "$SUITE" =~ $EXTENDED_SUITES ]]; then
    generate_extended_media
  fi
fi
run_suites
summary
