#!/usr/bin/env bash
# =============================================================================
#  av1_compare.sh — AV1 vs HEVC quality/size comparison tool
#  Part of the MuxMaster™ toolchain
#  Copyright © 2025–2026 Jamey Wicklund (theBluWiz)
# =============================================================================
#
#  Encodes a clip from a source video at multiple AV1 and HEVC settings,
#  then produces a side-by-side comparison table with file size, bitrate,
#  encode time, and (optionally) VMAF scores.
#
#  Requires: ffmpeg (with libsvtav1 + libx265), ffprobe, jq
#  Optional: ffmpeg with libvmaf (for VMAF scoring)
#
# =============================================================================

# ===== Section 1: Strict mode & bash version guard ========================================
set -eEuo pipefail
if shopt -q inherit_errexit 2>/dev/null; then shopt -s inherit_errexit; fi
[[ "${DEBUG:-0}" == "1" ]] && set -x

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  printf "❌ av1_compare requires bash 4.3+. Found: %s\n" "$BASH_VERSION" >&2
  printf "   macOS: brew install bash  (ensure /opt/homebrew/bin/bash is in PATH)\n" >&2
  exit 1
fi

# ===== Section 2: Constants ===============================================================
readonly TOOL_NAME="av1_compare"
readonly TOOL_VERSION="1.0.0"

# ANSI colour codes — disable when not on a terminal or when NO_COLOR is set
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_CYAN='\033[36m'
  C_GREEN='\033[32m'
  C_YELLOW='\033[33m'
  C_RED='\033[31m'
  C_MAGENTA='\033[35m'
  C_BLUE='\033[34m'
  C_WHITE='\033[97m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_GREEN=''
  C_YELLOW='' C_RED='' C_MAGENTA='' C_BLUE='' C_WHITE=''
fi

# ===== Section 3: Globals =================================================================
WORKDIR=""
CLIP_FILE=""
FAILED=0
FAIL_MSG=""
declare -a RESULT_LABELS=()
declare -a RESULT_SIZES=()
declare -a RESULT_BITRATES=()
declare -a RESULT_TIMES=()
declare -a RESULT_VMAF=()
declare -a RESULT_FILES=()
declare -i HAS_VMAF=0

# ===== Section 4: Defaults ================================================================
# ---- Clip extraction
declare -i CLIP_START=0          # seconds from the beginning
declare -i CLIP_DURATION=120     # seconds

# ---- HEVC encode
HEVC_CRF=18
HEVC_PRESET="slower"

# ---- SVT-AV1 encodes (label:crf:preset triplets, colon-separated)
# Each entry is "label:crf:preset"
declare -a AV1_ENCODES=(
  "AV1-CRF28-p6:28:6"
  "AV1-CRF30-p6:30:6"
  "AV1-CRF32-p6:32:6"
  "AV1-CRF30-p4:30:4"
  "AV1-CRF30-p8:30:8"
)

# ---- Convenience CRF/preset overrides (used to rebuild AV1_ENCODES if provided)
AV1_CRF_LIST=""     # e.g. "28,30,32" — if set, overrides the CRF dimension
AV1_PRESET_LIST=""  # e.g. "4,6,8"   — if set, overrides the preset dimension

# ---- VMAF
declare -i VMAF_ENABLED=1        # 1 = try VMAF; 0 = skip (override with --no-vmaf)
VMAF_MODEL=""                    # blank = use ffmpeg default (vmaf_v0.6.1)

# ---- Output
OUTPUT_DIR=""                    # default: same directory as source
declare -i KEEP_CLIP=0           # keep the extracted clip after encoding

# ===== Section 5: Helpers =================================================================
# ---- Logging (all output to stderr; stdout is reserved for the summary table) ----
say()  { printf "%s\n"    "$@" >&2; }
note() { printf "ℹ️   %s\n" "$@" >&2; }
warn() { printf "⚠️   %s\n" "$@" >&2; }
ok()   { printf "✅  %s\n" "$@" >&2; }

die() {
  local code=1
  if [[ $# -gt 1 && "$1" =~ ^[0-9]+$ ]]; then code="$1"; shift; fi
  printf "❌  ERROR: %s\n" "$*" >&2
  exit "$code"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die 10 "Missing required tool: $1"
}

# ---- Spinner ----
spinner() {
  local pid=$1 msg=$2 i=0
  local -a sym=( '|' '/' '—' $'\\' )
  # `|| true` on every `wait`: under `set -e` a failed background encode would otherwise make
  # `wait` (the function's last command) return non-zero, aborting the whole run BEFORE the
  # caller's graceful "Encode FAILED — skipping" handler. Detect failure via the output-file
  # check instead, mirroring hw_compare.sh's spinner.
  [[ -t 2 ]] || { wait "$pid" 2>/dev/null || true; return; }
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s  [%s]' "$msg" "${sym[i]}" >&2
    i=$(( (i+1) % 4 ))
    sleep 0.15
  done
  printf '\r  %s  [done]\n' "$msg" >&2
  wait "$pid" 2>/dev/null || true
}

# ---- Formatting helpers ----
# bytes_to_human <bytes>  — e.g. "234.5 MB"
bytes_to_human() {
  local bytes=$1
  if   (( bytes >= 1073741824 )); then
    LC_ALL=C awk "BEGIN{printf \"%.2f GB\", $bytes/1073741824}"
  elif (( bytes >= 1048576 )); then
    LC_ALL=C awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
  else
    LC_ALL=C awk "BEGIN{printf \"%.0f KB\", $bytes/1024}"
  fi
}

# secs_to_hms <seconds>  — e.g. "1m 23s" or "4m 02s"
secs_to_hms() {
  local -i s=$1
  local -i m=$(( s / 60 )) r=$(( s % 60 ))
  if (( m > 0 )); then
    printf "%dm %02ds" "$m" "$r"
  else
    printf "%ds" "$r"
  fi
}

# ---- Cleanup ----
on_exit() {
  local rc=$?
  # Remove the extracted clip unless the user asked to keep it
  if [[ -n "$CLIP_FILE" && -f "$CLIP_FILE" && "$KEEP_CLIP" -eq 0 ]]; then
    rm -f "$CLIP_FILE"
  fi
  # Remove empty WORKDIR (non-empty means encodes are there — keep them)
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rmdir "$WORKDIR" 2>/dev/null || true
  fi
  if (( rc != 0 && FAILED == 0 )); then
    printf "❌  Exited with code %d\n" "$rc" >&2
  fi
}
trap on_exit EXIT

on_error() {
  FAILED=1
  printf "❌  Unexpected error on line %d (exit %d): %s\n" \
    "${BASH_LINENO[0]}" "$?" "${BASH_COMMAND}" >&2
}
trap on_error ERR

# ===== Section 6: Help text ===============================================================
show_help() {
  cat >&2 <<EOF
${C_BOLD}${C_CYAN}av1_compare ${TOOL_VERSION}${C_RESET} — AV1 vs HEVC quality/size comparison tool

${C_BOLD}USAGE${C_RESET}
  av1_compare.sh [OPTIONS] <source-video>

${C_BOLD}OPTIONS${C_RESET}
  ${C_GREEN}-s, --start <secs>${C_RESET}        Clip start time in seconds (default: 0)
  ${C_GREEN}-d, --duration <secs>${C_RESET}     Clip duration in seconds (default: 120)
  ${C_GREEN}-o, --output-dir <dir>${C_RESET}    Directory for encode output (default: source directory)
  ${C_GREEN}    --hevc-crf <n>${C_RESET}        x265 CRF value (default: 18)
  ${C_GREEN}    --hevc-preset <p>${C_RESET}     x265 preset (default: slower)
  ${C_GREEN}    --av1-crf <list>${C_RESET}      Comma-separated CRF values to test (e.g. "28,30,32")
                            Each CRF is tested at each --av1-preset (default: 6)
  ${C_GREEN}    --av1-preset <list>${C_RESET}   Comma-separated SVT-AV1 presets (e.g. "4,6,8")
                            Each preset is tested at each --av1-crf (default: 30)
  ${C_GREEN}    --av1-encodes <spec>${C_RESET}  Advanced: comma-separated label:crf:preset triplets
                            (overrides --av1-crf/--av1-preset when used together)
  ${C_GREEN}    --vmaf-model <path>${C_RESET}   Path to VMAF model file (default: ffmpeg built-in)
  ${C_GREEN}    --no-vmaf${C_RESET}             Skip VMAF scoring even if libvmaf is available
  ${C_GREEN}    --keep-clip${C_RESET}           Keep the extracted clip after encoding
  ${C_GREEN}-h, --help${C_RESET}               Show this help and exit
  ${C_GREEN}-V, --version${C_RESET}            Print version and exit

${C_BOLD}EXAMPLES${C_RESET}
  # Compare using 2-minute clip from start
  av1_compare.sh movie.mkv

  # Use a 90-second clip starting at 5 minutes
  av1_compare.sh -s 300 -d 90 movie.mkv

  # Custom CRF ladder (preset 6 for each)
  av1_compare.sh --av1-crf "24,28,32" movie.mkv

  # Test a single CRF across multiple presets (speed/quality trade-off)
  av1_compare.sh --av1-crf "30" --av1-preset "4,6,8" movie.mkv

  # Full Cartesian product: 3 CRFs × 2 presets = 6 AV1 encodes
  av1_compare.sh --av1-crf "26,30,34" --av1-preset "4,6" movie.mkv

  # Advanced: explicit label:crf:preset triplets; output to /tmp
  av1_compare.sh --av1-encodes "fast:35:9,balanced:30:6,slow:25:4" \\
                 -o /tmp movie.mkv

  # Skip VMAF (faster)
  av1_compare.sh --no-vmaf movie.mkv

${C_BOLD}OUTPUT${C_RESET}
  Encodes are saved alongside the source (or in --output-dir).
  A JSON results file is saved as <source-stem>_av1_compare.json.

${C_BOLD}NOTES${C_RESET}
  • Requires ffmpeg built with libsvtav1 and libx265.
  • VMAF scoring requires ffmpeg built with libvmaf.
  • HDR sources are handled automatically (pixel format and colour
    space are preserved across all encodes).
  • Set NO_COLOR=1 to disable coloured output.
EOF
}

# ===== Section 7: CLI parsing =============================================================
POSITIONALS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        show_help; exit 0 ;;
    -V|--version)     printf "%s %s\n" "$TOOL_NAME" "$TOOL_VERSION"; exit 0 ;;
    -s|--start)       CLIP_START="${2:-}"; shift 2 ;;
    -d|--duration)    CLIP_DURATION="${2:-}"; shift 2 ;;
    -o|--output-dir)  OUTPUT_DIR="${2:-}"; shift 2 ;;
    --hevc-crf)       HEVC_CRF="${2:-}"; shift 2 ;;
    --hevc-preset)    HEVC_PRESET="${2:-}"; shift 2 ;;
    --av1-encodes)
      IFS=',' read -r -a AV1_ENCODES <<< "${2:-}"
      shift 2 ;;
    --av1-crf)      AV1_CRF_LIST="${2:-}";    shift 2 ;;
    --av1-preset)   AV1_PRESET_LIST="${2:-}"; shift 2 ;;
    --vmaf-model)     VMAF_MODEL="${2:-}"; shift 2 ;;
    --no-vmaf)        VMAF_ENABLED=0; shift ;;
    --keep-clip)      KEEP_CLIP=1; shift ;;
    --)               shift; break ;;
    -*) die 11 "Unknown option: $1  (try --help)" ;;
    *)  POSITIONALS+=("$1"); shift ;;
  esac
done
set -- "${POSITIONALS[@]+"${POSITIONALS[@]}"}"

# ===== Section 8: Validation ==============================================================
[[ $# -ge 1 ]] || die 11 "No source file specified.  Usage: av1_compare.sh [OPTIONS] <source>"

SOURCE_FILE="$1"
[[ -f "$SOURCE_FILE" ]] || die 12 "Source file not found: $SOURCE_FILE"

# Validate numeric arguments
[[ "$CLIP_START"    =~ ^[0-9]+$ ]] || die 11 "--start must be a non-negative integer"
[[ "$CLIP_DURATION" =~ ^[0-9]+$ && "$CLIP_DURATION" -gt 0 ]] \
  || die 11 "--duration must be a positive integer"
[[ "$HEVC_CRF" =~ ^[0-9]+$ ]] || die 11 "--hevc-crf must be a positive integer"

# Validate AV1 encode specs
for spec in "${AV1_ENCODES[@]}"; do
  IFS=':' read -r _lbl _crf _pst <<< "$spec"
  [[ -n "$_lbl" && "$_crf" =~ ^[0-9]+$ && "$_pst" =~ ^[0-9]+$ ]] \
    || die 11 "Invalid --av1-encodes spec: '$spec'  (expected label:crf:preset)"
done

# Set output directory. `realpath` is GNU/coreutils — absent on stock macOS — so guard it
# with a portable `cd … && pwd` fallback (resolves the source file's directory either way).
if [[ -z "$OUTPUT_DIR" ]]; then
  if command -v realpath >/dev/null 2>&1; then
    OUTPUT_DIR="$(dirname "$(realpath "$SOURCE_FILE")")"
  else
    OUTPUT_DIR="$(cd "$(dirname -- "$SOURCE_FILE")" 2>/dev/null && pwd)"
  fi
fi
[[ -d "$OUTPUT_DIR" ]] || die 12 "Output directory does not exist: $OUTPUT_DIR"

# Validate --av1-crf / --av1-preset if provided (comma-separated non-negative integers)
_validate_int_list() {
  local name="$1" val="$2"
  local IFS=',' item
  for item in $val; do
    [[ "$item" =~ ^[0-9]+$ ]] || die 11 "${name} '${val}' contains non-integer value '${item}'"
  done
}
[[ -n "$AV1_CRF_LIST"    ]] && _validate_int_list "--av1-crf"    "$AV1_CRF_LIST"
[[ -n "$AV1_PRESET_LIST" ]] && _validate_int_list "--av1-preset" "$AV1_PRESET_LIST"

# If --av1-crf or --av1-preset were given, rebuild AV1_ENCODES from them.
# Logic:
#   --av1-crf only:    each CRF × default preset 6
#   --av1-preset only: each preset × default CRF 30
#   both:              Cartesian product of all CRF × preset combinations
if [[ -n "$AV1_CRF_LIST" || -n "$AV1_PRESET_LIST" ]]; then
  _crf_vals="${AV1_CRF_LIST:-30}"
  _preset_vals="${AV1_PRESET_LIST:-6}"
  AV1_ENCODES=()
  IFS=',' read -r -a _crfs    <<< "$_crf_vals"
  IFS=',' read -r -a _presets <<< "$_preset_vals"
  for _c in "${_crfs[@]}"; do
    for _p in "${_presets[@]}"; do
      AV1_ENCODES+=( "AV1-CRF${_c}-p${_p}:${_c}:${_p}" )
    done
  done
fi

# Dependency check (all float math uses awk; bc is intentionally not required)
need ffmpeg
need ffprobe
need jq

# ===== Section 9: Pre-flight ffmpeg capability checks =====================================
say ""
say "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════╗${C_RESET}"
say "${C_BOLD}${C_CYAN}║   av1_compare ${TOOL_VERSION}  — AV1 vs HEVC comparison     ║${C_RESET}"
say "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════╝${C_RESET}"
say ""

# Check libsvtav1
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libsvtav1'; then
  die 10 "ffmpeg is missing libsvtav1 support. Rebuild ffmpeg with --enable-libsvtav1."
fi
note "ffmpeg libsvtav1 ✓"

# Check libx265
if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libx265'; then
  die 10 "ffmpeg is missing libx265 support. Rebuild ffmpeg with --enable-libx265."
fi
note "ffmpeg libx265 ✓"

# Check libvmaf (optional)
if (( VMAF_ENABLED )); then
  if ffmpeg -hide_banner -filters 2>/dev/null | grep -q 'libvmaf\|vmaf'; then
    HAS_VMAF=1
    note "ffmpeg libvmaf ✓ — VMAF scoring enabled"
  else
    HAS_VMAF=0
    warn "ffmpeg lacks libvmaf — VMAF scoring will be skipped"
    warn "  Rebuild with --enable-libvmaf to enable, or pass --no-vmaf to silence this warning"
  fi
else
  note "VMAF scoring disabled via --no-vmaf"
fi

# ===== Section 10: Source probe ===========================================================
note "Probing source: $(basename "$SOURCE_FILE")"

PROBE_JSON=$(ffprobe -v quiet -print_format json -show_streams -show_format \
  "$SOURCE_FILE" 2>/dev/null) || die 12 "ffprobe failed — is this a valid video file?"

SRC_DURATION=$(printf '%s' "$PROBE_JSON" | jq -r '.format.duration // "0"')
SRC_DURATION_INT=$(LC_ALL=C printf '%.0f' "$SRC_DURATION")

SRC_VIDEO_STREAM=$(printf '%s' "$PROBE_JSON" \
  | jq -r '[.streams[] | select(.codec_type=="video")][0]')

SRC_WIDTH=$(printf '%s'  "$SRC_VIDEO_STREAM" | jq -r '.width  // "unknown"')
SRC_HEIGHT=$(printf '%s' "$SRC_VIDEO_STREAM" | jq -r '.height // "unknown"')
SRC_CODEC=$(printf '%s'  "$SRC_VIDEO_STREAM" | jq -r '.codec_name // "unknown"')
SRC_PIXFMT=$(printf '%s' "$SRC_VIDEO_STREAM" | jq -r '.pix_fmt // "yuv420p"')
SRC_COLOR_PRIMARIES=$(printf '%s' "$SRC_VIDEO_STREAM" \
  | jq -r '.color_primaries // ""')
SRC_COLOR_TRC=$(printf '%s' "$SRC_VIDEO_STREAM" \
  | jq -r '.color_transfer // ""')
SRC_COLOR_SPACE=$(printf '%s' "$SRC_VIDEO_STREAM" \
  | jq -r '.color_space // ""')

# Detect HDR (bt2020 primaries or PQ/HLG transfer characteristics)
declare -i IS_HDR=0
if [[ "$SRC_COLOR_PRIMARIES" == "bt2020" ]] \
  || [[ "$SRC_COLOR_TRC" =~ ^(smpte2084|arib-std-b67)$ ]]; then
  IS_HDR=1
fi

# Choose pixel format: preserve 10-bit for HDR; use source pix_fmt otherwise
if (( IS_HDR )); then
  ENCODE_PIXFMT="yuv420p10le"
else
  case "$SRC_PIXFMT" in
    yuv420p10le|yuv420p10) ENCODE_PIXFMT="yuv420p10le" ;;
    *)                      ENCODE_PIXFMT="yuv420p"    ;;
  esac
fi

# Warn & clamp clip bounds
if (( CLIP_START >= SRC_DURATION_INT )); then
  warn "Clip start (${CLIP_START}s) >= source duration (${SRC_DURATION_INT}s). Resetting to 0."
  CLIP_START=0
fi
AVAILABLE=$(( SRC_DURATION_INT - CLIP_START ))
if (( CLIP_DURATION > AVAILABLE )); then
  warn "Requested ${CLIP_DURATION}s clip, but only ${AVAILABLE}s available from offset ${CLIP_START}s."
  CLIP_DURATION=$AVAILABLE
fi

note "Source : ${SRC_WIDTH}×${SRC_HEIGHT}  ${SRC_CODEC}  ${SRC_PIXFMT}"
note "HDR    : $(( IS_HDR ? 1 : 0 )) (primaries=${SRC_COLOR_PRIMARIES:-n/a}, trc=${SRC_COLOR_TRC:-n/a})"
note "Encode pixfmt: ${ENCODE_PIXFMT}"
note "Clip   : ${CLIP_START}s → $((CLIP_START + CLIP_DURATION))s  (${CLIP_DURATION}s)"
say ""

# ===== Section 11: Colour metadata passthrough flags =====================================
# Build ffmpeg flags to preserve HDR colour metadata across all encodes.
HDR_FLAGS=()
if (( IS_HDR )); then
  [[ -n "$SRC_COLOR_PRIMARIES" ]] && HDR_FLAGS+=( -color_primaries "$SRC_COLOR_PRIMARIES" )
  [[ -n "$SRC_COLOR_TRC"       ]] && HDR_FLAGS+=( -color_trc       "$SRC_COLOR_TRC"       )
  [[ -n "$SRC_COLOR_SPACE"     ]] && HDR_FLAGS+=( -colorspace      "$SRC_COLOR_SPACE"     )

  # x265 master-display / MaxCLL from stream side-data (best-effort)
  MASTER_DISPLAY=$(printf '%s' "$SRC_VIDEO_STREAM" \
    | jq -r '.side_data_list[]? | select(.side_data_type=="Mastering display metadata") |
      "G(\(.green_x | split("/") | .[0]|tonumber)_\(.green_x | split("/") | .[1]|tonumber),\(.green_y | split("/") | .[0]|tonumber)_\(.green_y | split("/") | .[1]|tonumber))B(\(.blue_x | split("/") | .[0]|tonumber)_\(.blue_x | split("/") | .[1]|tonumber),\(.blue_y | split("/") | .[0]|tonumber)_\(.blue_y | split("/") | .[1]|tonumber))R(\(.red_x | split("/") | .[0]|tonumber)_\(.red_x | split("/") | .[1]|tonumber),\(.red_y | split("/") | .[0]|tonumber)_\(.red_y | split("/") | .[1]|tonumber))WP(\(.white_point_x | split("/") | .[0]|tonumber)_\(.white_point_x | split("/") | .[1]|tonumber),\(.white_point_y | split("/") | .[0]|tonumber)_\(.white_point_y | split("/") | .[1]|tonumber))L(\(.min_luminance | split("/") | .[0]|tonumber)_\(.min_luminance | split("/") | .[1]|tonumber),\(.max_luminance | split("/") | .[0]|tonumber)_\(.max_luminance | split("/") | .[1]|tonumber))"' \
    2>/dev/null || true)

  MAX_CLL=$(printf '%s' "$SRC_VIDEO_STREAM" \
    | jq -r '.side_data_list[]? | select(.side_data_type=="Content light level metadata") |
      "\(.max_content),\(.max_average)"' 2>/dev/null || true)
fi

# ===== Section 12: Extract clip ===========================================================
SOURCE_STEM=$(basename "${SOURCE_FILE%.*}")
CLIP_FILE="${OUTPUT_DIR}/${SOURCE_STEM}_clip_${CLIP_START}s_${CLIP_DURATION}s.mkv"

say "⏳  Extracting ${CLIP_DURATION}s clip (start=${CLIP_START}s) …"

ffmpeg -hide_banner -loglevel error -y \
  -ss "$CLIP_START" -i "$SOURCE_FILE" \
  -t "$CLIP_DURATION" \
  -c copy \
  "$CLIP_FILE" 2>&1 \
  || die 40 "Failed to extract clip from source."

ok "Clip extracted: $(basename "$CLIP_FILE")  ($(bytes_to_human "$(stat -f%z "$CLIP_FILE" 2>/dev/null || stat -c%s "$CLIP_FILE")"))"
say ""

# ===== Section 13: Encode loop ============================================================
# Build encode plan: HEVC baseline + all AV1 variants
declare -a ENCODE_PLAN_LABELS=()
declare -a ENCODE_PLAN_CODEC=()
declare -a ENCODE_PLAN_CRF=()
declare -a ENCODE_PLAN_PRESET=()
declare -a ENCODE_PLAN_EXT=()

# HEVC baseline first
ENCODE_PLAN_LABELS+=( "HEVC-CRF${HEVC_CRF}-${HEVC_PRESET}" )
ENCODE_PLAN_CODEC+=( "hevc" )
ENCODE_PLAN_CRF+=( "$HEVC_CRF" )
ENCODE_PLAN_PRESET+=( "$HEVC_PRESET" )
ENCODE_PLAN_EXT+=( "mkv" )

# AV1 encodes
for spec in "${AV1_ENCODES[@]}"; do
  IFS=':' read -r _lbl _crf _pst <<< "$spec"
  ENCODE_PLAN_LABELS+=( "$_lbl" )
  ENCODE_PLAN_CODEC+=( "av1" )
  ENCODE_PLAN_CRF+=( "$_crf" )
  ENCODE_PLAN_PRESET+=( "$_pst" )
  ENCODE_PLAN_EXT+=( "mkv" )
done

TOTAL_ENCODES=${#ENCODE_PLAN_LABELS[@]}
say "${C_BOLD}Running ${TOTAL_ENCODES} encodes …${C_RESET}"
say ""

for (( idx=0; idx < TOTAL_ENCODES; idx++ )); do
  label="${ENCODE_PLAN_LABELS[$idx]}"
  codec="${ENCODE_PLAN_CODEC[$idx]}"
  crf="${ENCODE_PLAN_CRF[$idx]}"
  preset="${ENCODE_PLAN_PRESET[$idx]}"
  ext="${ENCODE_PLAN_EXT[$idx]}"

  OUT_FILE="${OUTPUT_DIR}/${SOURCE_STEM}_${label}.${ext}"

  say "${C_BOLD}${C_BLUE}[$((idx+1))/${TOTAL_ENCODES}] ${label}${C_RESET}"

  # Build ffmpeg video encode arguments
  FF_VIDEO_ARGS=()
  if [[ "$codec" == "hevc" ]]; then
    # x265 CRF encode
    X265_PARAMS="crf=${crf}:preset=${preset}"
    # Append HDR-specific x265 params
    if (( IS_HDR )); then
      X265_PARAMS="${X265_PARAMS}:hdr-opt=1:repeat-headers=1"
      [[ -n "${MASTER_DISPLAY:-}" ]] \
        && X265_PARAMS="${X265_PARAMS}:master-display=${MASTER_DISPLAY}"
      [[ -n "${MAX_CLL:-}" ]] \
        && X265_PARAMS="${X265_PARAMS}:max-cll=${MAX_CLL}"
    fi
    FF_VIDEO_ARGS+=(
      -c:v libx265
      -crf "$crf"
      -preset "$preset"
      -pix_fmt "$ENCODE_PIXFMT"
      "${HDR_FLAGS[@]+"${HDR_FLAGS[@]}"}"
      -x265-params "$X265_PARAMS"
    )
  else
    # SVT-AV1 CRF encode
    SVTAV1_PARAMS="preset=${preset}"
    FF_VIDEO_ARGS+=(
      -c:v libsvtav1
      -crf "$crf"
      -preset "$preset"
      -pix_fmt "$ENCODE_PIXFMT"
      "${HDR_FLAGS[@]+"${HDR_FLAGS[@]}"}"
      -svtav1-params "$SVTAV1_PARAMS"
    )
  fi

  # Record start time
  T_START=$(date +%s)

  # Run encode (audio copy, no subtitles for a clean video-only comparison)
  ffmpeg -hide_banner -loglevel error -y \
    -i "$CLIP_FILE" \
    "${FF_VIDEO_ARGS[@]}" \
    -c:a copy \
    -sn \
    "$OUT_FILE" 2>&1 &
  enc_pid=$!
  spinner "$enc_pid" "  Encoding ${label}"

  T_END=$(date +%s)
  ENCODE_SECS=$(( T_END - T_START ))

  # -s (not just -f): a failed ffmpeg with -y can leave a 0-byte file behind. Treating an empty
  # output as success would later feed a 0 denominator into the "vs HEVC" size ratio (awk div-by-0).
  if [[ ! -s "$OUT_FILE" ]]; then
    warn "Encode FAILED for ${label} — skipping."
    RESULT_LABELS+=( "$label" )
    RESULT_SIZES+=( "FAILED" )
    RESULT_BITRATES+=( "—" )
    RESULT_TIMES+=( "—" )
    RESULT_VMAF+=( "—" )
    RESULT_FILES+=( "" )
    continue
  fi

  # File size
  FILE_SIZE=$(stat -f%z "$OUT_FILE" 2>/dev/null || stat -c%s "$OUT_FILE")

  # Bitrate (kbps) from ffprobe
  BITRATE_RAW=$(ffprobe -v quiet -print_format json -show_format "$OUT_FILE" 2>/dev/null \
    | jq -r '.format.bit_rate // "0"')
  BITRATE_KBPS=$(LC_ALL=C awk "BEGIN{printf \"%.0f\", ${BITRATE_RAW}/1000}")

  RESULT_LABELS+=( "$label" )
  RESULT_SIZES+=( "$FILE_SIZE" )
  RESULT_BITRATES+=( "${BITRATE_KBPS} kbps" )
  RESULT_TIMES+=( "$ENCODE_SECS" )
  RESULT_VMAF+=( "—" )
  RESULT_FILES+=( "$OUT_FILE" )

  ok "  Done: $(bytes_to_human "$FILE_SIZE")  ${BITRATE_KBPS} kbps  $(secs_to_hms "$ENCODE_SECS")"
done
say ""

# ===== Section 14: VMAF scoring ===========================================================
if (( HAS_VMAF && VMAF_ENABLED )); then
  say "${C_BOLD}Running VMAF scores …${C_RESET}"
  say ""

  for (( idx=0; idx < TOTAL_ENCODES; idx++ )); do
    label="${RESULT_LABELS[$idx]}"
    enc_file="${RESULT_FILES[$idx]}"

    [[ -z "$enc_file" || ! -f "$enc_file" ]] && continue
    [[ "${RESULT_SIZES[$idx]}" == "FAILED" ]]  && continue

    say "  ${C_DIM}VMAF: ${label}${C_RESET}"

    # Build VMAF filter
    # distorted = encoded; reference = clip (same resolution; no scaling needed
    # unless encode changed resolution, which we don't do here)
    if [[ -n "$VMAF_MODEL" ]]; then
      VMAF_FILTER="libvmaf=model_path=${VMAF_MODEL}:log_fmt=json:log_path=/dev/null"
    else
      VMAF_FILTER="libvmaf=log_fmt=json:log_path=/dev/null"
    fi

    # Write VMAF JSON to a temp file, honoring $TMPDIR (macOS uses a per-user dir).
    VMAF_TMP=$(mktemp "${TMPDIR:-/tmp}/av1_compare_vmaf.XXXXXX.json")

    # libvmaf requires: [distorted][reference]libvmaf
    # We use -filter_complex with two inputs: reference (clip) and distorted (encode)
    VMAF_SCORE=""
    if ffmpeg -hide_banner -loglevel error -y \
      -i "$enc_file" \
      -i "$CLIP_FILE" \
      -filter_complex "[0:v][1:v]libvmaf=log_fmt=json:log_path=${VMAF_TMP}" \
      -f null - 2>/dev/null; then
      VMAF_SCORE=$(jq -r '.pooled_metrics.vmaf.mean // ""' "$VMAF_TMP" 2>/dev/null || true)
      # Older libvmaf JSON schema
      if [[ -z "$VMAF_SCORE" || "$VMAF_SCORE" == "null" ]]; then
        VMAF_SCORE=$(jq -r '.VMAF score // ""' "$VMAF_TMP" 2>/dev/null || true)
      fi
    fi
    rm -f "$VMAF_TMP"

    if [[ -n "$VMAF_SCORE" && "$VMAF_SCORE" != "null" ]]; then
      VMAF_SCORE=$(LC_ALL=C printf "%.2f" "$VMAF_SCORE")
      RESULT_VMAF[$idx]="$VMAF_SCORE"
      ok "  ${label}: VMAF ${VMAF_SCORE}"
    else
      warn "  ${label}: VMAF scoring failed or returned no score"
      RESULT_VMAF[$idx]="err"
    fi
  done
  say ""
fi

# ===== Section 15: Summary table ==========================================================
# Summary table goes to STDOUT so it can be captured/piped independently of log messages.
# All other log output (say/note/warn/ok) goes to stderr.

# Find HEVC baseline size for relative comparison
HEVC_SIZE_BYTES="${RESULT_SIZES[0]}"

# Column widths
readonly COL_LABEL=24 COL_SIZE=12 COL_BITRATE=12 COL_TIME=10 COL_VMAF=8 COL_REL=8
_sep_width=$(( COL_LABEL + COL_SIZE + COL_BITRATE + COL_TIME + COL_VMAF + COL_REL + 14 ))
_sep_line=$(printf '%.0s─' $(seq 1 "$_sep_width"))

printf "${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
printf "${C_BOLD}  RESULTS — %s  (%ss clip, start=%ss)${C_RESET}\n" \
  "$SOURCE_STEM" "$CLIP_DURATION" "$CLIP_START"
printf "${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"

# Header row
printf "${C_BOLD}  %-${COL_LABEL}s  %${COL_SIZE}s  %${COL_BITRATE}s  %${COL_TIME}s  %${COL_VMAF}s  %${COL_REL}s${C_RESET}\n" \
  "Encode" "File Size" "Bitrate" "Time" "VMAF" "vs HEVC"
printf "  %s\n" "$_sep_line"

for (( idx=0; idx < TOTAL_ENCODES; idx++ )); do
  label="${RESULT_LABELS[$idx]}"
  raw_size="${RESULT_SIZES[$idx]}"
  bitrate="${RESULT_BITRATES[$idx]}"
  enc_time="${RESULT_TIMES[$idx]}"
  vmaf_score="${RESULT_VMAF[$idx]}"

  if [[ "$raw_size" == "FAILED" ]]; then
    printf "  ${C_RED}%-${COL_LABEL}s  %${COL_SIZE}s  %${COL_BITRATE}s  %${COL_TIME}s  %${COL_VMAF}s  %${COL_REL}s${C_RESET}\n" \
      "$label" "FAILED" "—" "—" "—" "—"
    continue
  fi

  size_human=$(bytes_to_human "$raw_size")
  time_human=$(secs_to_hms "$enc_time")

  # Relative size vs HEVC baseline
  rel_str="baseline"
  COLOR="$C_RESET"
  if (( idx > 0 )) && [[ "$HEVC_SIZE_BYTES" =~ ^[0-9]+$ && "$raw_size" =~ ^[0-9]+$ ]]; then
    rel_pct=$(LC_ALL=C awk "BEGIN{printf \"%.1f\", (${raw_size}/${HEVC_SIZE_BYTES}-1)*100}")
    rel_sign=$(LC_ALL=C awk "BEGIN{printf \"%s\", ($rel_pct < 0 ? \"\" : \"+\")}")
    rel_str="${rel_sign}${rel_pct}%"
    # Green = smaller than HEVC; yellow = larger
    if LC_ALL=C awk "BEGIN{exit !($rel_pct < 0)}"; then
      COLOR="$C_GREEN"
    else
      COLOR="$C_YELLOW"
    fi
  elif (( idx == 0 )); then
    COLOR="$C_CYAN"
  fi

  printf "  ${COLOR}%-${COL_LABEL}s${C_RESET}  %${COL_SIZE}s  %${COL_BITRATE}s  %${COL_TIME}s  %${COL_VMAF}s  ${COLOR}%${COL_REL}s${C_RESET}\n" \
    "$label" "$size_human" "$bitrate" "$time_human" "$vmaf_score" "$rel_str"
done

printf "  %s\n\n" "$_sep_line"

if (( HAS_VMAF == 0 && VMAF_ENABLED == 1 )); then
  note "VMAF scores were skipped (ffmpeg lacks libvmaf)."
  say ""
fi

# ===== Section 16: JSON output ============================================================
JSON_FILE="${OUTPUT_DIR}/${SOURCE_STEM}_av1_compare.json"

# Build JSON array of results
JSON_RESULTS="["
first=1
for (( idx=0; idx < TOTAL_ENCODES; idx++ )); do
  label="${RESULT_LABELS[$idx]}"
  raw_size="${RESULT_SIZES[$idx]}"
  bitrate_str="${RESULT_BITRATES[$idx]}"
  enc_time="${RESULT_TIMES[$idx]}"
  vmaf_score="${RESULT_VMAF[$idx]}"
  out_file="${RESULT_FILES[$idx]}"

  bitrate_num="${bitrate_str/ kbps/}"

  # Relative size
  rel_pct="null"
  if (( idx > 0 )) && [[ "$HEVC_SIZE_BYTES" =~ ^[0-9]+$ && "$raw_size" =~ ^[0-9]+$ ]]; then
    rel_pct=$(LC_ALL=C awk "BEGIN{printf \"%.2f\", (${raw_size}/${HEVC_SIZE_BYTES}-1)*100}")
  fi

  vmaf_json="null"
  if [[ "$vmaf_score" =~ ^[0-9] ]]; then
    vmaf_json="$vmaf_score"
  fi

  size_json="null"
  time_json="null"
  bitrate_json="null"
  [[ "$raw_size" =~ ^[0-9]+$ ]]    && size_json="$raw_size"
  [[ "$enc_time" =~ ^[0-9]+$ ]]    && time_json="$enc_time"
  [[ "$bitrate_num" =~ ^[0-9]+$ ]] && bitrate_json="$bitrate_num"

  (( first )) || JSON_RESULTS+=","
  first=0
  JSON_RESULTS+=$(printf '{
    "label": %s,
    "codec": %s,
    "crf": %s,
    "preset": %s,
    "file": %s,
    "size_bytes": %s,
    "bitrate_kbps": %s,
    "encode_seconds": %s,
    "vmaf": %s,
    "relative_size_pct": %s
  }' \
    "$(printf '%s' "$label"                         | jq -Rs '.')" \
    "$(printf '%s' "${ENCODE_PLAN_CODEC[$idx]}"      | jq -Rs '.')" \
    "$(printf '%s' "${ENCODE_PLAN_CRF[$idx]}"        | jq -Rs '.')" \
    "$(printf '%s' "${ENCODE_PLAN_PRESET[$idx]}"     | jq -Rs '.')" \
    "$(printf '%s' "$out_file"                       | jq -Rs '.')" \
    "$size_json" "$bitrate_json" "$time_json" "$vmaf_json" "$rel_pct"
  )
done
JSON_RESULTS+="]"

# Wrap in top-level object
jq -n \
  --argjson results "$JSON_RESULTS" \
  --arg source    "$SOURCE_FILE" \
  --arg stem      "$SOURCE_STEM" \
  --argjson start  "$CLIP_START" \
  --argjson dur    "$CLIP_DURATION" \
  --arg pix_fmt  "$ENCODE_PIXFMT" \
  --argjson is_hdr "$(( IS_HDR ))" \
  --arg tool_ver "$TOOL_VERSION" \
  --arg run_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    tool: "av1_compare",
    version: $tool_ver,
    run_date: $run_date,
    source: $source,
    source_stem: $stem,
    clip_start_secs: $start,
    clip_duration_secs: $dur,
    encode_pix_fmt: $pix_fmt,
    is_hdr: ($is_hdr == 1),
    encodes: $results
  }' > "$JSON_FILE" \
  && ok "JSON saved: $(basename "$JSON_FILE")" \
  || warn "Failed to write JSON results file."

say ""

# ===== Section 17: Wrap-up ================================================================
note "Encodes saved to: ${OUTPUT_DIR}/"
[[ "$KEEP_CLIP" -eq 1 ]] && note "Clip kept: $(basename "$CLIP_FILE")"
say ""
ok "Done."
say ""
