#!/usr/bin/env bash
# =============================================================================
#  hw_compare.sh — Hardware encoder quality calibration tool
#  Part of the MuxMaster™ toolchain
#  Copyright © 2025–2026 Jamey Wicklund (theBluWiz)
# =============================================================================
#
#  Encodes a reference clip at a sweep of hardware quality settings,
#  scores each against the software baseline (VMAF), and produces a
#  per-profile calibration table identifying the quality setting that
#  achieves VMAF parity with the software encoder (Δ ≤ 0.5).
#
#  Requires: ffmpeg (with target hardware encoder), ffprobe, jq
#  Optional: ffmpeg with libvmaf (for VMAF scoring)
#
# =============================================================================

# ===== Section 1: Strict mode & bash version guard ========================================
set -eEuo pipefail
if shopt -q inherit_errexit 2>/dev/null; then shopt -s inherit_errexit; fi
[[ "${DEBUG:-0}" == "1" ]] && set -x

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  printf "❌ hw_compare requires bash 4.3+. Found: %s\n" "$BASH_VERSION" >&2
  printf "   macOS: brew install bash  (ensure /opt/homebrew/bin/bash is in PATH)\n" >&2
  exit 1
fi

# ===== Section 2: Constants ===============================================================
readonly TOOL_NAME="hw_compare"
readonly TOOL_VERSION="1.0.0"
readonly VMAF_THRESHOLD="0.5"
readonly VMAF_MIN_DURATION=10

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET='\033[0m' C_BOLD='\033[1m' C_DIM='\033[2m'
  C_CYAN='\033[36m' C_GREEN='\033[32m' C_YELLOW='\033[33m'
  C_RED='\033[31m'  C_BLUE='\033[34m'  C_WHITE='\033[97m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_CYAN='' C_GREEN=''
  C_YELLOW='' C_RED='' C_BLUE='' C_WHITE=''
fi

# ===== Section 3: Globals =================================================================
ENCODER=""
PROFILE=""
CLIP=""
QUALITY_START=""
QUALITY_END=""
QUALITY_STEP=""
OUTPUT_DIR=""
SW_BASELINE_OVERRIDE=""
DRY_RUN=0
JSON_OUT=0
VMAF_ENABLED=1
FAILED=0

SRC_WIDTH="" SRC_HEIGHT="" SRC_CODEC="" SRC_PIXFMT=""
SRC_COLOR_PRIMARIES="" SRC_COLOR_TRC="" SRC_COLOR_SPACE=""
declare -i IS_HDR=0
declare -i CLIP_DURATION_SECS=0
HDR_FLAGS=()

SW_BASELINE_FILE=""
SW_VMAF=""
SW_BITRATE_KBPS=""
SW_SIZE_BYTES=""
SW_BASELINE_DESC=""

declare -a SWEEP_Q=()
declare -a SWEEP_VMAF=()
declare -a SWEEP_DELTA=()
declare -a SWEEP_PASS=()
declare -a SWEEP_SIZE_BYTES=()
declare -a SWEEP_BITRATE_KBPS=()
declare -a SWEEP_TIME_SECS=()
declare -a SWEEP_FILE=()

declare -i HAS_VMAF=0
VMAF_PIXFMT=""

# ===== Section 4: Profile → SW baseline lookup tables =====================================
declare -A PROFILE_SW_CODEC=(
  [hdr10-hq]=libx265
  [atv-directplay-hq]=libx265
  [atv-directplay-animation]=libx265
  [animation]=libx265
  [streaming-hevc]=libx265
  [universal]=libx264
  [youtube-upload]=libx264
)

declare -A PROFILE_SW_CRF=(
  [hdr10-hq]=17
  [atv-directplay-hq]=17
  [atv-directplay-animation]=16
  [animation]=16
  [streaming-hevc]=20
  [universal]=22
  [youtube-upload]=16
)

declare -A PROFILE_SW_PRESET=(
  [hdr10-hq]=slower
  [atv-directplay-hq]=slower
  [atv-directplay-animation]=slower
  [animation]=slower
  [streaming-hevc]=medium
  [universal]=slow
  [youtube-upload]=slow
)

# Forces 8-bit for H.264 even on HDR source (h264_videotoolbox is 8-bit only)
declare -A PROFILE_SW_PIXFMT=(
  [hdr10-hq]=yuv420p10le
  [atv-directplay-hq]=yuv420p10le
  [atv-directplay-animation]=yuv420p10le
  [animation]=yuv420p10le
  [streaming-hevc]=yuv420p10le
  [universal]=yuv420p
  [youtube-upload]=yuv420p
)

declare -A PROFILE_X265PARAMS=(
  [hdr10-hq]="profile=main10:repeat-headers=1:hdr-opt=1:hdr10=1:hdr10-opt=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:aq-mode=3:aq-strength=1.3:psy-rd=2.0:psy-rdoq=1.0:rc-lookahead=60"
  [atv-directplay-hq]="profile=main10:repeat-headers=1:hdr-opt=1:hdr10=1:hdr10-opt=1:aq-mode=3:aq-strength=1.3:psy-rd=2.0:psy-rdoq=1.0:rc-lookahead=60"
  [atv-directplay-animation]="profile=main10:repeat-headers=1:hdr-opt=1:hdr10=1:hdr10-opt=1:aq-mode=3:aq-strength=0.8:psy-rd=1.0:psy-rdoq=0.5:rc-lookahead=60:deblock=-1,-1:bframes=8"
  [animation]="profile=main10:repeat-headers=1:aq-mode=3:aq-strength=0.8:psy-rd=1.0:psy-rdoq=0.5:rc-lookahead=60:deblock=-1,-1:bframes=8"
  [streaming-hevc]="profile=main10:repeat-headers=1:hdr-opt=1:hdr10=1:hdr10-opt=1:aq-mode=3:aq-strength=1.3:psy-rd=2.0:psy-rdoq=1.0:rc-lookahead=60"
)

declare -A PROFILE_X264PARAMS=(
  [youtube-upload]="profile=high:rc-lookahead=60:aq-mode=2:aq-strength=1.0"
)

# VT HEVC pixel format: p010le for 10-bit profiles; h264_videotoolbox is always 8-bit
declare -A PROFILE_HW_VT_PIXFMT=(
  [hdr10-hq]=p010le
  [atv-directplay-hq]=p010le
  [atv-directplay-animation]=p010le
  [animation]=p010le
  [streaming-hevc]=p010le
  [universal]=yuv420p
  [youtube-upload]=yuv420p
)

# ===== Section 5: Helpers =================================================================
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

need() { command -v "$1" >/dev/null 2>&1 || die 10 "Missing required tool: $1"; }

spinner() {
  local pid=$1 msg="${2:-...}" i=0
  local -a sym=( '|' '/' '—' $'\\' )
  [[ -t 2 ]] || { wait "$pid" 2>/dev/null || true; return; }
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s  [%s]' "$msg" "${sym[i]}" >&2
    i=$(( (i+1) % 4 ))
    sleep 0.15
  done
  printf '\r  %s  [done]\n' "$msg" >&2
  wait "$pid" 2>/dev/null || true
}

bytes_to_human() {
  local bytes=$1
  if   (( bytes >= 1073741824 )); then LC_ALL=C awk "BEGIN{printf \"%.2f GB\", $bytes/1073741824}"
  elif (( bytes >= 1048576    )); then LC_ALL=C awk "BEGIN{printf \"%.1f MB\", $bytes/1048576}"
  else                                 LC_ALL=C awk "BEGIN{printf \"%.0f KB\", $bytes/1024}"
  fi
}

secs_to_hms() {
  local -i s=$1 m=$(( $1 / 60 )) r=$(( $1 % 60 ))
  (( m > 0 )) && printf "%dm %02ds" "$m" "$r" || printf "%ds" "$r"
}

on_exit() {
  local rc=$?
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

# ===== Section 6: Encoder utilities =======================================================
is_nvenc() { [[ "$ENCODER" == *_nvenc ]]; }
is_vt()    { [[ "$ENCODER" == *_videotoolbox ]]; }
hw_quality_knob()  { is_nvenc && echo "-cq"  || echo "-q:v"; }
hw_quality_label() { is_nvenc && echo "cq"   || echo "q:v"; }

hw_pix_fmt() {
  case "$ENCODER" in
    h264_videotoolbox|h264_nvenc) echo "yuv420p" ;;
    av1_nvenc)                    echo "yuv420p10le" ;;
    hevc_videotoolbox)            echo "${PROFILE_HW_VT_PIXFMT[$PROFILE]:-yuv420p}" ;;
    hevc_nvenc)
      [[ "${PROFILE_SW_PIXFMT[$PROFILE]:-yuv420p}" == "yuv420p10le" ]] \
        && echo "p010le" || echo "yuv420p" ;;
    *) echo "yuv420p" ;;
  esac
}

vmaf_cmp_fmt() {
  [[ "${PROFILE_SW_PIXFMT[$PROFILE]:-yuv420p}" == "yuv420p10le" ]] \
    && echo "yuv420p10le" || echo "yuv420p"
}

# score_vmaf DISTORTED REFERENCE PIXFMT [JSON_DEST]
# Sets VMAF_SCORE_RESULT to formatted score or "" on failure.
VMAF_SCORE_RESULT=""
score_vmaf() {
  local distorted="$1" reference="$2" pixfmt="$3" json_dest="${4:-}"
  VMAF_SCORE_RESULT=""

  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/hw_compare_vmaf.XXXXXX.json")  # honor $TMPDIR (macOS per-user dir)

  local filter ok=0
  filter="[0:v]format=${pixfmt}[d];[1:v]format=${pixfmt}[r];[d][r]libvmaf=model=version=vmaf_v0.6.1:n_subsample=5:log_fmt=json:log_path=${tmp}"
  if ffmpeg -hide_banner -loglevel error -y \
    -i "$distorted" -i "$reference" \
    -filter_complex "$filter" -f null - 2>/dev/null; then
    ok=1
  else
    filter="[0:v]format=${pixfmt}[d];[1:v]format=${pixfmt}[r];[d][r]libvmaf=n_subsample=5:log_fmt=json:log_path=${tmp}"
    ffmpeg -hide_banner -loglevel error -y \
      -i "$distorted" -i "$reference" \
      -filter_complex "$filter" -f null - 2>/dev/null && ok=1 || true
  fi

  if (( ok )); then
    local score
    score=$(jq -r '.pooled_metrics.vmaf.mean // ""' "$tmp" 2>/dev/null || true)
    [[ -z "$score" || "$score" == "null" ]] \
      && score=$(jq -r '.["VMAF score"] // ""' "$tmp" 2>/dev/null || true)
    if [[ -n "$score" && "$score" != "null" && "$score" =~ ^[0-9] ]]; then
      VMAF_SCORE_RESULT=$(LC_ALL=C printf "%.2f" "$score")
      [[ -n "$json_dest" ]] && cp "$tmp" "$json_dest" 2>/dev/null || true
    fi
  fi
  rm -f "$tmp"
}

# ===== Section 7: Help text ===============================================================
show_help() {
  cat >&2 <<EOF
${C_BOLD}${C_CYAN}hw_compare ${TOOL_VERSION}${C_RESET} — Hardware encoder quality calibration tool

${C_BOLD}USAGE${C_RESET}
  hw_compare.sh --encoder ENC --profile PROFILE --clip CLIP \\
                --quality-range START:END:STEP --output-dir DIR [OPTIONS]

${C_BOLD}REQUIRED FLAGS${C_RESET}
  ${C_GREEN}--encoder ENC${C_RESET}             Hardware encoder:
                              hevc_videotoolbox | h264_videotoolbox |
                              hevc_nvenc | h264_nvenc | av1_nvenc
  ${C_GREEN}--profile PROFILE${C_RESET}         muxm profile (derives SW baseline codec + params):
                              hdr10-hq | atv-directplay-hq | atv-directplay-animation |
                              animation | streaming-hevc | universal | youtube-upload
  ${C_GREEN}--clip CLIP${C_RESET}               Path to pre-extracted reference clip
  ${C_GREEN}--quality-range S:E:T${C_RESET}     Quality sweep  e.g. 65:85:5
                              VT:   -q:v range (0–100, higher=better quality)
                              NVENC: -cq range (0–51, lower=better quality)
  ${C_GREEN}--output-dir DIR${C_RESET}          Directory for encoded files and VMAF JSON

${C_BOLD}OPTIONAL FLAGS${C_RESET}
  ${C_GREEN}--sw-baseline ARGS${C_RESET}        Override auto-derived SW baseline. Provide the ffmpeg
                              video encode arguments as a quoted string, e.g.:
                              "-c:v libx265 -crf 17 -preset slower -pix_fmt yuv420p10le"
                              The clip input and output filename are added automatically.
  ${C_GREEN}--json${C_RESET}                    Emit machine-readable JSON summary to stdout
  ${C_GREEN}--dry-run${C_RESET}                 Print ffmpeg commands without running them
  ${C_GREEN}--no-vmaf${C_RESET}                 Skip VMAF scoring
  ${C_GREEN}-h, --help${C_RESET}               Show this help and exit
  ${C_GREEN}-V, --version${C_RESET}            Print version and exit

${C_BOLD}OUTPUT FILES${C_RESET}
  sw_baseline_{profile}.mkv          Software baseline encode
  hw_{encoder}_{profile}_q{N}.mkv   HW encode at quality step N
  vmaf_{profile}_sw_baseline.json    VMAF result for SW baseline vs clip
  vmaf_{profile}_q{N}.json           VMAF result for HW encode vs clip

${C_BOLD}EXAMPLES${C_RESET}
  # VideoToolbox HEVC sweep, HDR10 profile (Apple Silicon)
  hw_compare.sh \\
    --encoder hevc_videotoolbox --profile hdr10-hq \\
    --clip clip_b.mkv --quality-range 65:85:5 \\
    --output-dir /tmp/vt_calibration

  # h264_videotoolbox for universal profile, with JSON output
  hw_compare.sh \\
    --encoder h264_videotoolbox --profile universal \\
    --clip clip_a.mkv --quality-range 55:80:5 \\
    --output-dir ./results --json > results.json

  # Dry run — print commands only
  hw_compare.sh --encoder hevc_videotoolbox --profile streaming-hevc \\
    --clip clip_a.mkv --quality-range 55:75:5 --output-dir /tmp --dry-run

${C_BOLD}NOTES${C_RESET}
  • SW baseline is auto-derived from --profile matching muxm's codec/CRF/params.
    Use --sw-baseline to override for non-standard comparisons.
  • VMAF comparison normalises both inputs to the same pixel format before scoring.
    p010le (VT/NVENC HW output) and yuv420p10le (SW output) are both converted to
    yuv420p10le inside the VMAF filtergraph.
  • VMAF is skipped for clips shorter than ${VMAF_MIN_DURATION}s (scores are noisy on short clips).
  • Calibrated value = smallest file among all PASS results (minimum quality meeting threshold).
  • youtube-upload + h264_videotoolbox: h264_videotoolbox is 8-bit only; both SW and HW
    encodes use yuv420p regardless of source HDR content (open question §3 in planning doc).
  • Set NO_COLOR=1 to disable coloured output.
EOF
}

# ===== Section 8: CLI parsing =============================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        show_help; exit 0 ;;
    -V|--version)     printf "%s %s\n" "$TOOL_NAME" "$TOOL_VERSION"; exit 0 ;;
    --encoder)        ENCODER="${2:-}";      shift 2 ;;
    --profile)        PROFILE="${2:-}";      shift 2 ;;
    --clip)           CLIP="${2:-}";         shift 2 ;;
    --quality-range)
      IFS=':' read -r QUALITY_START QUALITY_END QUALITY_STEP <<< "${2:-}"
      shift 2 ;;
    --output-dir)     OUTPUT_DIR="${2:-}";   shift 2 ;;
    --sw-baseline)    SW_BASELINE_OVERRIDE="${2:-}"; shift 2 ;;
    --json)           JSON_OUT=1; shift ;;
    --dry-run)        DRY_RUN=1;  shift ;;
    --no-vmaf)        VMAF_ENABLED=0; shift ;;
    --) shift; break ;;
    -*) die 11 "Unknown option: $1  (try --help)" ;;
    *)  die 11 "Unexpected positional argument: $1  (this tool takes no positional arguments)" ;;
  esac
done

# ===== Section 9: Validation ==============================================================
[[ -n "$ENCODER"       ]] || die 11 "--encoder is required"
[[ -n "$PROFILE"       ]] || die 11 "--profile is required"
[[ -n "$CLIP"          ]] || die 11 "--clip is required"
[[ -n "$OUTPUT_DIR"    ]] || die 11 "--output-dir is required"
[[ -n "$QUALITY_START" && -n "$QUALITY_END" && -n "$QUALITY_STEP" ]] \
  || die 11 "--quality-range is required  (format: START:END:STEP, e.g. 65:85:5)"

readonly VALID_ENCODERS="hevc_videotoolbox h264_videotoolbox hevc_nvenc h264_nvenc av1_nvenc"
readonly VALID_PROFILES="hdr10-hq atv-directplay-hq atv-directplay-animation animation streaming-hevc universal youtube-upload"

printf '%s\n' $VALID_ENCODERS | grep -qxF "$ENCODER" \
  || die 11 "Invalid --encoder '${ENCODER}'.  Valid: ${VALID_ENCODERS// /, }"

printf '%s\n' $VALID_PROFILES | grep -qxF "$PROFILE" \
  || die 11 "Invalid --profile '${PROFILE}'.  Valid: ${VALID_PROFILES// /, }"

# ---- A-1: guard the hand-maintained profile subset against muxm's canonical list ----
# VALID_PROFILES above is a deliberate SUBSET of muxm's ten, not an oversight: it is exactly
# the set muxm carries a calibrated hardware quality for (VT_QUALITY_MAP), which is also what
# calibration/run_sweeps.sh sweeps. `archive`, `av1-hq` and `streaming-av1` are excluded on
# purpose — none has a VideoToolbox arm. What a hand-maintained subset cannot survive on its
# own is a RENAME or removal upstream: the list would silently go stale, the same drift class
# tests/test_docker_parity.sh closes for docker/. So cross-check it against a real muxm.
#   Resolution order: $MUXM, the sibling checkout (tools/ lives beside muxm), then $PATH.
# Graded severity, because this is a calibration tool and not the encoder:
#   * no muxm readable        → note and skip (an installed-elsewhere copy is legitimate)
#   * stale entry in the list → warn (maintainer signal; this run still proceeds)
#   * the SELECTED profile is stale → die (the sweep would calibrate something muxm cannot use)
_canonical_muxm_profiles() {
  local candidate list
  for candidate in "${MUXM:-}" "$(dirname "${BASH_SOURCE[0]}")/../muxm" "$(command -v muxm 2>/dev/null || true)"; do
    [[ -n "$candidate" && -r "$candidate" ]] || continue
    # Byte-identical extraction to tests/test_docker_parity.sh and test_muxm.sh (review L-20):
    # an EOL-anchored sed returns EMPTY on a trailing space/comment, which would make two
    # guards disagree about the canonical list. Keep all three in sync.
    list="$(grep '^readonly VALID_PROFILES=' "$candidate" \
            | sed 's/^readonly VALID_PROFILES="//;s/"$//' | head -1 || true)"
    [[ -n "$list" ]] || continue
    printf '%s\n' "$list"
    return 0
  done
  return 1
}

_MUXM_PROFILES="$(_canonical_muxm_profiles || true)"
if [[ -z "$_MUXM_PROFILES" ]]; then
  note "muxm's canonical VALID_PROFILES could not be read — profile-list drift check skipped."
  note "  Set MUXM=/path/to/muxm to enable it."
else
  _STALE_PROFILES=""
  for _hp in $VALID_PROFILES; do
    printf '%s\n' $_MUXM_PROFILES | grep -qxF "$_hp" || _STALE_PROFILES="${_STALE_PROFILES} ${_hp}"
  done
  if [[ -n "$_STALE_PROFILES" ]]; then
    warn "hw_compare's profile list has drifted from muxm — unknown to muxm:${_STALE_PROFILES}"
    warn "  Update VALID_PROFILES in this script.  muxm has: ${_MUXM_PROFILES// /, }"
    if printf '%s\n' $_STALE_PROFILES | grep -qxF "$PROFILE"; then
      die 11 "--profile '${PROFILE}' no longer exists in muxm — calibrating it would produce a table muxm can never apply."
    fi
  fi
  unset _STALE_PROFILES _hp
fi
unset _MUXM_PROFILES

[[ "$QUALITY_START" =~ ^[0-9]+$ ]] || die 11 "--quality-range START must be a non-negative integer"
[[ "$QUALITY_END"   =~ ^[0-9]+$ ]] || die 11 "--quality-range END must be a non-negative integer"
[[ "$QUALITY_STEP"  =~ ^[0-9]+$ && "$QUALITY_STEP" -gt 0 ]] \
  || die 11 "--quality-range STEP must be a positive integer"
(( QUALITY_START <= QUALITY_END )) \
  || die 11 "--quality-range: START (${QUALITY_START}) must be ≤ END (${QUALITY_END})"

[[ -f "$CLIP" || "$DRY_RUN" -eq 1 ]] || die 12 "Clip not found: $CLIP"
[[ -d "$OUTPUT_DIR" ]] || mkdir -p "$OUTPUT_DIR" \
  || die 12 "Cannot create output directory: $OUTPUT_DIR"

# ===== Section 10: Dependency + encoder availability checks ===============================
need ffmpeg
need ffprobe
need jq
# (all float math uses awk; bc is intentionally not required)

say ""
say "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════╗${C_RESET}"
say "${C_BOLD}${C_CYAN}║   hw_compare ${TOOL_VERSION}  — HW encoder calibration       ║${C_RESET}"
say "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════╝${C_RESET}"
say ""

if (( DRY_RUN )); then
  note "Dry run — encoder availability checks skipped"
else
  if ! ffmpeg -hide_banner -encoders 2>/dev/null | awk '{print $2}' | grep -qxF "$ENCODER"; then
    die 10 "Encoder '${ENCODER}' not available in ffmpeg. Check 'ffmpeg -encoders'."
  fi
  note "Encoder ${ENCODER} ✓"

  if [[ -z "$SW_BASELINE_OVERRIDE" ]]; then
    local_sw_codec="${PROFILE_SW_CODEC[$PROFILE]:-}"
    if [[ -n "$local_sw_codec" ]]; then
      if ! ffmpeg -hide_banner -encoders 2>/dev/null | awk '{print $2}' | grep -qxF "$local_sw_codec"; then
        die 10 "${local_sw_codec} not available in ffmpeg (required for SW baseline of profile '${PROFILE}')"
      fi
      note "ffmpeg ${local_sw_codec} ✓"
    fi
  fi
fi

if (( VMAF_ENABLED )); then
  if ffmpeg -hide_banner -filters 2>/dev/null | grep -q 'libvmaf\|vmaf'; then
    HAS_VMAF=1
    note "ffmpeg libvmaf ✓ — VMAF scoring enabled"
  else
    warn "ffmpeg lacks libvmaf — VMAF scoring will be skipped"
    warn "  Rebuild with --enable-libvmaf to enable, or pass --no-vmaf to silence this warning"
  fi
else
  note "VMAF scoring disabled via --no-vmaf"
fi

# Warn about the youtube-upload + h264_videotoolbox pixel format compatibility gap
if [[ "$PROFILE" == "youtube-upload" && "$ENCODER" == "h264_videotoolbox" ]]; then
  warn "youtube-upload + h264_videotoolbox: h264_videotoolbox is 8-bit only."
  warn "  Both SW baseline and HW encodes will use yuv420p (HDR data not preserved)."
  warn "  See Hardware_Acceleration_Planning.md open question §3."
fi

# ===== Section 11: Clip probe =============================================================
if [[ -f "$CLIP" ]]; then
  note "Probing clip: $(basename "$CLIP")"

  PROBE_JSON=$(ffprobe -v quiet -print_format json -show_streams -show_format \
    "$CLIP" 2>/dev/null) || die 12 "ffprobe failed — is '$(basename "$CLIP")' a valid video file?"

  CLIP_DURATION_SECS=$(printf '%s' "$PROBE_JSON" \
    | jq -r '.format.duration // "0"' | LC_ALL=C xargs printf "%.0f")

  SRC_VIDEO_STREAM=$(printf '%s' "$PROBE_JSON" \
    | jq -r '[.streams[] | select(.codec_type=="video")][0]')

  SRC_WIDTH=$(printf '%s'  "$SRC_VIDEO_STREAM" | jq -r '.width        // "unknown"')
  SRC_HEIGHT=$(printf '%s' "$SRC_VIDEO_STREAM" | jq -r '.height       // "unknown"')
  SRC_CODEC=$(printf '%s'  "$SRC_VIDEO_STREAM" | jq -r '.codec_name   // "unknown"')
  SRC_PIXFMT=$(printf '%s' "$SRC_VIDEO_STREAM" | jq -r '.pix_fmt      // "yuv420p"')
  SRC_COLOR_PRIMARIES=$(printf '%s' "$SRC_VIDEO_STREAM" | jq -r '.color_primaries // ""')
  SRC_COLOR_TRC=$(printf '%s'       "$SRC_VIDEO_STREAM" | jq -r '.color_transfer  // ""')
  SRC_COLOR_SPACE=$(printf '%s'     "$SRC_VIDEO_STREAM" | jq -r '.color_space     // ""')

  if [[ "$SRC_COLOR_PRIMARIES" == "bt2020" ]] \
    || [[ "$SRC_COLOR_TRC" =~ ^(smpte2084|arib-std-b67)$ ]]; then
    IS_HDR=1
  fi

  note "Clip  : ${SRC_WIDTH}×${SRC_HEIGHT}  ${SRC_CODEC}  ${SRC_PIXFMT}  ${CLIP_DURATION_SECS}s"
  note "HDR   : ${IS_HDR}  (primaries=${SRC_COLOR_PRIMARIES:-n/a}, trc=${SRC_COLOR_TRC:-n/a})"
  say ""

  if (( CLIP_DURATION_SECS < VMAF_MIN_DURATION )); then
    warn "Clip is ${CLIP_DURATION_SECS}s — shorter than ${VMAF_MIN_DURATION}s minimum for reliable VMAF."
    warn "  VMAF scoring will be skipped."
    HAS_VMAF=0
  fi
else
  note "Clip not found — skipping probe (dry-run mode)"
  say ""
fi

# ===== Section 12: HDR colour metadata passthrough flags ==================================
if (( IS_HDR )); then
  [[ -n "$SRC_COLOR_PRIMARIES" ]] && HDR_FLAGS+=( -color_primaries "$SRC_COLOR_PRIMARIES" )
  [[ -n "$SRC_COLOR_TRC"       ]] && HDR_FLAGS+=( -color_trc       "$SRC_COLOR_TRC"       )
  [[ -n "$SRC_COLOR_SPACE"     ]] && HDR_FLAGS+=( -colorspace      "$SRC_COLOR_SPACE"     )
fi

VMAF_PIXFMT=$(vmaf_cmp_fmt)
HW_PIXFMT=$(hw_pix_fmt)
KNOB_LABEL=$(hw_quality_label)

# ===== Section 13: SW baseline encode =====================================================
SW_BASELINE_FILE="${OUTPUT_DIR}/sw_baseline_${PROFILE}.mkv"

declare -a SW_FF_ARGS=()
if [[ -n "$SW_BASELINE_OVERRIDE" ]]; then
  read -r -a SW_FF_ARGS <<< "$SW_BASELINE_OVERRIDE"
  SW_BASELINE_DESC="custom (--sw-baseline override)"
else
  sw_codec="${PROFILE_SW_CODEC[$PROFILE]}"
  sw_crf="${PROFILE_SW_CRF[$PROFILE]}"
  sw_preset="${PROFILE_SW_PRESET[$PROFILE]}"
  sw_pixfmt="${PROFILE_SW_PIXFMT[$PROFILE]}"
  SW_BASELINE_DESC="${sw_codec} CRF ${sw_crf} ${sw_preset}"

  SW_FF_ARGS=( -c:v "$sw_codec" -crf "$sw_crf" -preset "$sw_preset" -pix_fmt "$sw_pixfmt" )
  SW_FF_ARGS+=( "${HDR_FLAGS[@]+"${HDR_FLAGS[@]}"}" )

  if [[ "$sw_codec" == "libx265" ]]; then
    _x265p="${PROFILE_X265PARAMS[$PROFILE]:-}"
    [[ -n "$_x265p" ]] && SW_FF_ARGS+=( -x265-params "$_x265p" )
  elif [[ "$sw_codec" == "libx264" ]]; then
    _x264p="${PROFILE_X264PARAMS[$PROFILE]:-}"
    [[ -n "$_x264p" ]] && SW_FF_ARGS+=( -x264-params "$_x264p" )
  fi
fi

if (( DRY_RUN )); then
  say "${C_BOLD}[DRY RUN] SW baseline (${SW_BASELINE_DESC}):${C_RESET}"
  say "  ffmpeg -hide_banner -loglevel error -y -i '${CLIP}' \\"
  say "    ${SW_FF_ARGS[*]} -an -sn '${SW_BASELINE_FILE}'"
  say ""
else
  say "⏳  Encoding SW baseline (${SW_BASELINE_DESC}) …"
  T_START=$(date +%s)
  ffmpeg -hide_banner -loglevel error -y \
    -i "$CLIP" "${SW_FF_ARGS[@]}" -an -sn "$SW_BASELINE_FILE" &
  enc_pid=$!
  spinner "$enc_pid" "  SW baseline"
  T_END=$(date +%s)

  [[ -f "$SW_BASELINE_FILE" && -s "$SW_BASELINE_FILE" ]] \
    || die 40 "SW baseline encode failed — output file missing or empty."

  SW_SIZE_BYTES=$(stat -f%z "$SW_BASELINE_FILE" 2>/dev/null || stat -c%s "$SW_BASELINE_FILE")
  _br_raw=$(ffprobe -v quiet -print_format json -show_format "$SW_BASELINE_FILE" 2>/dev/null \
    | jq -r '.format.bit_rate // "0"')
  SW_BITRATE_KBPS=$(LC_ALL=C awk "BEGIN{printf \"%.0f\", ${_br_raw}/1000}")
  ok "  SW baseline: $(bytes_to_human "$SW_SIZE_BYTES")  ${SW_BITRATE_KBPS} kbps  $(secs_to_hms $(( T_END - T_START )))"
fi

# ===== Section 14: SW baseline VMAF =======================================================
if (( DRY_RUN == 0 && HAS_VMAF && VMAF_ENABLED )); then
  say "  VMAF: SW baseline vs clip …"
  _vmaf_sw_json="${OUTPUT_DIR}/vmaf_${PROFILE}_sw_baseline.json"
  score_vmaf "$SW_BASELINE_FILE" "$CLIP" "$VMAF_PIXFMT" "$_vmaf_sw_json"
  SW_VMAF="$VMAF_SCORE_RESULT"

  if [[ -n "$SW_VMAF" ]]; then
    ok "  SW baseline VMAF: ${SW_VMAF}"
  else
    warn "  SW baseline VMAF scoring failed — per-step delta comparison unavailable"
  fi
  say ""
fi

# ===== Section 15: Build HW base args (constant across quality steps) =====================
declare -a HW_BASE_ARGS=()
HW_BASE_ARGS+=( -c:v "$ENCODER" -pix_fmt "$HW_PIXFMT" )
HW_BASE_ARGS+=( "${HDR_FLAGS[@]+"${HDR_FLAGS[@]}"}" )

if is_nvenc; then
  HW_BASE_ARGS+=( -preset p7 -rc-lookahead 32 -spatial-aq 1 -b:v 0 )
  case "$ENCODER" in
    hevc_nvenc)
      [[ "$HW_PIXFMT" == "p010le" ]] \
        && HW_BASE_ARGS+=( -profile:v main10 ) || HW_BASE_ARGS+=( -profile:v main )
      HW_BASE_ARGS+=( -tier high -level 5.1 -temporal-aq 1 )
      ;;
    h264_nvenc)
      HW_BASE_ARGS+=( -profile:v high -level 4.2 -temporal-aq 1 )
      ;;
    av1_nvenc)
      HW_BASE_ARGS+=( -profile:v main )
      ;;
  esac
else
  HW_BASE_ARGS+=( -allow_sw 0 -realtime 0 )
  case "$ENCODER" in
    hevc_videotoolbox)
      [[ "$HW_PIXFMT" == "p010le" ]] \
        && HW_BASE_ARGS+=( -profile:v main10 ) || HW_BASE_ARGS+=( -profile:v main )
      ;;
    h264_videotoolbox)
      [[ "${PROFILE_X264PARAMS[$PROFILE]:-}" == *"profile=high"* ]] \
        && HW_BASE_ARGS+=( -profile:v high )
      ;;
  esac
fi

# ===== Section 16: HW quality sweep =======================================================
total_steps=0
for _q in $(seq "$QUALITY_START" "$QUALITY_STEP" "$QUALITY_END"); do total_steps=$(( total_steps + 1 )); done

say "${C_BOLD}Running ${total_steps} HW encode(s): ${ENCODER} / ${PROFILE} / ${KNOB_LABEL} ${QUALITY_START}–${QUALITY_END} step ${QUALITY_STEP} …${C_RESET}"
say ""

step_idx=0
for q in $(seq "$QUALITY_START" "$QUALITY_STEP" "$QUALITY_END"); do
  step_idx=$(( step_idx + 1 ))

  out_file="${OUTPUT_DIR}/hw_${ENCODER}_${PROFILE}_q${q}.mkv"
  vmaf_json_path="${OUTPUT_DIR}/vmaf_${PROFILE}_q${q}.json"

  HW_ARGS=( "${HW_BASE_ARGS[@]}" )
  is_nvenc && HW_ARGS+=( -cq "$q" ) || HW_ARGS+=( -q:v "$q" )

  say "${C_BOLD}${C_BLUE}[${step_idx}/${total_steps}] ${KNOB_LABEL} ${q}${C_RESET}"

  if (( DRY_RUN )); then
    say "  ffmpeg -hide_banner -loglevel error -y -i '${CLIP}' \\"
    say "    ${HW_ARGS[*]} -an -sn '${out_file}'"
    SWEEP_Q+=( "$q" )
    SWEEP_FILE+=( "" )
    SWEEP_SIZE_BYTES+=( 0 )
    SWEEP_BITRATE_KBPS+=( 0 )
    SWEEP_TIME_SECS+=( 0 )
    SWEEP_VMAF+=( "" )
    SWEEP_DELTA+=( "" )
    SWEEP_PASS+=( "" )
    say ""
    continue
  fi

  T_START=$(date +%s)
  ffmpeg -hide_banner -loglevel error -y \
    -i "$CLIP" "${HW_ARGS[@]}" -an -sn "$out_file" &
  enc_pid=$!
  spinner "$enc_pid" "  ${KNOB_LABEL} ${q}"
  T_END=$(date +%s)
  ENCODE_SECS=$(( T_END - T_START ))

  if [[ ! -f "$out_file" || ! -s "$out_file" ]]; then
    warn "  Encode FAILED for ${KNOB_LABEL} ${q} — skipping this step"
    SWEEP_Q+=( "$q" )
    SWEEP_FILE+=( "" )
    SWEEP_SIZE_BYTES+=( 0 )
    SWEEP_BITRATE_KBPS+=( 0 )
    SWEEP_TIME_SECS+=( "$ENCODE_SECS" )
    SWEEP_VMAF+=( "" )
    SWEEP_DELTA+=( "" )
    SWEEP_PASS+=( "ERR" )
    say ""
    continue
  fi

  FILE_SIZE=$(stat -f%z "$out_file" 2>/dev/null || stat -c%s "$out_file")
  _br_raw=$(ffprobe -v quiet -print_format json -show_format "$out_file" 2>/dev/null \
    | jq -r '.format.bit_rate // "0"')
  BITRATE_KBPS=$(LC_ALL=C awk "BEGIN{printf \"%.0f\", ${_br_raw}/1000}")

  ok "  Done: $(bytes_to_human "$FILE_SIZE")  ${BITRATE_KBPS} kbps  $(secs_to_hms "$ENCODE_SECS")"

  step_vmaf="" step_delta="" step_pass=""

  if (( HAS_VMAF && VMAF_ENABLED )); then
    say "  VMAF: ${KNOB_LABEL} ${q} vs clip …"
    score_vmaf "$out_file" "$CLIP" "$VMAF_PIXFMT" "$vmaf_json_path"
    step_vmaf="$VMAF_SCORE_RESULT"

    if [[ -n "$step_vmaf" ]]; then
      if [[ -n "$SW_VMAF" ]]; then
        # delta = SW_VMAF − HW_VMAF; display |delta|; PASS when |delta| ≤ threshold
        step_delta=$(LC_ALL=C awk "BEGIN{printf \"%.2f\", ${SW_VMAF} - ${step_vmaf}}")
        abs_delta="${step_delta#-}"
        if LC_ALL=C awk "BEGIN{exit !(${abs_delta} <= ${VMAF_THRESHOLD})}"; then
          step_pass="PASS"
          ok "  VMAF ${step_vmaf}  Δ${abs_delta}  PASS ✓"
        else
          step_pass="FAIL"
          say "  ${C_YELLOW}✗  VMAF ${step_vmaf}  Δ${abs_delta}  FAIL${C_RESET}"
        fi
      else
        ok "  VMAF ${step_vmaf}  (no SW baseline — delta unavailable)"
        step_pass="N/A"
      fi
    else
      warn "  VMAF scoring failed for ${KNOB_LABEL} ${q}"
      step_pass="ERR"
    fi
  fi

  SWEEP_Q+=( "$q" )
  SWEEP_FILE+=( "$out_file" )
  SWEEP_SIZE_BYTES+=( "$FILE_SIZE" )
  SWEEP_BITRATE_KBPS+=( "$BITRATE_KBPS" )
  SWEEP_TIME_SECS+=( "$ENCODE_SECS" )
  SWEEP_VMAF+=( "$step_vmaf" )
  SWEEP_DELTA+=( "$step_delta" )
  SWEEP_PASS+=( "$step_pass" )
  say ""
done

# ===== Section 17: Summary table ==========================================================
# Summary goes to STDOUT normally; when --json is active, route it to stderr so stdout
# is reserved for clean JSON output.
(( JSON_OUT )) && exec 3>&1 1>&2  # save stdout → fd3, redirect stdout to stderr

printf "${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
printf "${C_BOLD}  Profile: %-24s Encoder: %-22s Clip: %s${C_RESET}\n" \
  "$PROFILE" "$ENCODER" "$(basename "$CLIP")"

if (( DRY_RUN == 0 )); then
  sw_br_str=""
  [[ -n "$SW_BITRATE_KBPS" ]] && sw_br_str="  $(LC_ALL=C awk "BEGIN{printf \"%.1f Mbps\", ${SW_BITRATE_KBPS}/1000}")"
  if [[ -n "$SW_VMAF" ]]; then
    printf "  SW baseline: %-38s VMAF %s%s\n" "$SW_BASELINE_DESC" "$SW_VMAF" "$sw_br_str"
  else
    printf "  SW baseline: %s%s\n" "$SW_BASELINE_DESC" "$sw_br_str"
  fi
fi

printf "${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"

if (( DRY_RUN )); then
  printf "  (dry run — no encode results)\n"
else
  for (( i=0; i < ${#SWEEP_Q[@]}; i++ )); do
    _q="${SWEEP_Q[$i]}"
    _vmaf="${SWEEP_VMAF[$i]:-—}"
    _delta="${SWEEP_DELTA[$i]:-}"
    _pass="${SWEEP_PASS[$i]:-}"
    _size="${SWEEP_SIZE_BYTES[$i]:-0}"
    _kbps="${SWEEP_BITRATE_KBPS[$i]:-0}"
    _secs="${SWEEP_TIME_SECS[$i]:-0}"

    _vmaf_str="VMAF ${_vmaf}"
    [[ "$_vmaf" == "—" ]] && _vmaf_str="VMAF —"

    _delta_str=""
    [[ -n "$_delta" ]] && _delta_str="  Δ${_delta#-}"

    _pass_str=""
    case "$_pass" in
      PASS)  _pass_str="  ${C_GREEN}PASS ✓${C_RESET}" ;;
      FAIL)  _pass_str="  ${C_YELLOW}FAIL${C_RESET}"   ;;
      ERR)   _pass_str="  ${C_RED}ERR${C_RESET}"      ;;
      N/A)   _pass_str="  N/A"                         ;;
    esac

    _size_str=""
    _br_str=""
    _time_str=""
    (( _size > 0 )) && _size_str="  size: $(bytes_to_human "$_size")"
    (( _kbps > 0 )) && _br_str="  bitrate: $(LC_ALL=C awk "BEGIN{printf \"%.1f Mbps\", ${_kbps}/1000}")"
    (( _secs > 0 )) && _time_str="  time: $(secs_to_hms "$_secs")"

    printf "  ${KNOB_LABEL} %-4s → %s%s%s%s%s%s\n" \
      "$_q" "$_vmaf_str" "$_delta_str" "$_pass_str" "$_br_str" "$_size_str" "$_time_str"
  done

  # Calibrated value: smallest file among all PASS results
  best_q="" best_size=0
  for (( i=0; i < ${#SWEEP_Q[@]}; i++ )); do
    [[ "${SWEEP_PASS[$i]:-}" == "PASS" ]] || continue
    _sz="${SWEEP_SIZE_BYTES[$i]:-0}"
    if [[ -z "$best_q" ]] || (( _sz < best_size )); then
      best_q="${SWEEP_Q[$i]}"
      best_size="$_sz"
    fi
  done

  printf "${C_BOLD}${C_WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
  if (( HAS_VMAF == 0 || VMAF_ENABLED == 0 )); then
    printf "  VMAF scoring was skipped — rerun without --no-vmaf for calibration result.\n"
  elif [[ -z "$SW_VMAF" ]]; then
    printf "  SW baseline VMAF unavailable — per-step delta comparison not possible.\n"
  elif [[ -n "$best_q" ]]; then
    printf "${C_BOLD}${C_GREEN}  Calibrated value: ${KNOB_LABEL} %s  (smallest PASS file, Δ ≤ %s)${C_RESET}\n" \
      "$best_q" "$VMAF_THRESHOLD"
  else
    # No passing steps — report nearest (smallest absolute delta)
    closest_q="" closest_delta=""
    for (( i=0; i < ${#SWEEP_Q[@]}; i++ )); do
      [[ "${SWEEP_PASS[$i]:-}" == "ERR" || -z "${SWEEP_DELTA[$i]:-}" ]] && continue
      _abs="${SWEEP_DELTA[$i]#-}"
      if [[ -z "$closest_q" ]] || LC_ALL=C awk "BEGIN{exit !(${_abs} < ${closest_delta:-999})}"; then
        closest_q="${SWEEP_Q[$i]}"
        closest_delta="$_abs"
      fi
    done
    printf "${C_BOLD}${C_YELLOW}  No quality setting in range meets VMAF parity threshold (Δ ≤ %s).${C_RESET}\n" \
      "$VMAF_THRESHOLD"
    [[ -n "$closest_q" ]] && \
      printf "  Nearest: ${KNOB_LABEL} %s (Δ%s) — consider expanding sweep toward better quality.\n" \
        "$closest_q" "$closest_delta"
  fi
fi
printf "\n"

# ===== Section 18: JSON output ============================================================
(( JSON_OUT )) && exec 1>&3 3>&-  # restore stdout from fd3 for JSON output

if (( JSON_OUT && DRY_RUN == 0 )); then
  _results_json="["
  _first=1
  for (( i=0; i < ${#SWEEP_Q[@]}; i++ )); do
    _q="${SWEEP_Q[$i]}"
    _sz="${SWEEP_SIZE_BYTES[$i]:-0}"
    _kbps="${SWEEP_BITRATE_KBPS[$i]:-0}"
    _secs="${SWEEP_TIME_SECS[$i]:-0}"
    _vmaf="${SWEEP_VMAF[$i]:-}"
    _delta="${SWEEP_DELTA[$i]:-}"
    _pass="${SWEEP_PASS[$i]:-}"
    _file="${SWEEP_FILE[$i]:-}"

    _vmaf_j="null";  [[ "$_vmaf" =~ ^[0-9]  ]] && _vmaf_j="$_vmaf"
    _delta_j="null"; [[ "$_delta" =~ ^-?[0-9] ]] && _delta_j="$_delta"
    _sz_j="null";    (( _sz > 0 ))   && _sz_j="$_sz"
    _kbps_j="null";  (( _kbps > 0 )) && _kbps_j="$_kbps"
    _secs_j="null";  (( _secs > 0 )) && _secs_j="$_secs"

    (( _first )) || _results_json+=","
    _first=0
    _results_json+=$(printf '{
      "quality": %d,
      "file": %s,
      "size_bytes": %s,
      "bitrate_kbps": %s,
      "encode_seconds": %s,
      "vmaf": %s,
      "vmaf_delta": %s,
      "pass": %s
    }' \
      "$_q" \
      "$(printf '%s' "$_file" | jq -Rs '.')" \
      "$_sz_j" "$_kbps_j" "$_secs_j" "$_vmaf_j" "$_delta_j" \
      "$(printf '%s' "$_pass" | jq -Rs '.')"
    )
  done
  _results_json+="]"

  _sw_vmaf_j="null"; [[ "$SW_VMAF" =~ ^[0-9] ]] && _sw_vmaf_j="$SW_VMAF"
  _sw_sz_j="null";   (( ${SW_SIZE_BYTES:-0} > 0 )) && _sw_sz_j="$SW_SIZE_BYTES"
  _sw_kbps_j="null"; (( ${SW_BITRATE_KBPS:-0} > 0 )) && _sw_kbps_j="$SW_BITRATE_KBPS"

  jq -n \
    --arg  tool_ver     "$TOOL_VERSION" \
    --arg  run_date     "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg  encoder      "$ENCODER" \
    --arg  profile      "$PROFILE" \
    --arg  clip         "$CLIP" \
    --arg  quality_range "${QUALITY_START}:${QUALITY_END}:${QUALITY_STEP}" \
    --arg  quality_knob "$KNOB_LABEL" \
    --arg  hw_pixfmt    "$HW_PIXFMT" \
    --arg  vmaf_pixfmt  "$VMAF_PIXFMT" \
    --argjson is_hdr    "$IS_HDR" \
    --arg  sw_desc      "$SW_BASELINE_DESC" \
    --arg  sw_file      "${SW_BASELINE_FILE:-}" \
    --argjson sw_vmaf   "$_sw_vmaf_j" \
    --argjson sw_size   "$_sw_sz_j" \
    --argjson sw_kbps   "$_sw_kbps_j" \
    --arg  vmaf_threshold "$VMAF_THRESHOLD" \
    --argjson steps     "$_results_json" \
    '{
      tool: "hw_compare",
      version: $tool_ver,
      run_date: $run_date,
      encoder: $encoder,
      profile: $profile,
      clip: $clip,
      quality_range: $quality_range,
      quality_knob: $quality_knob,
      hw_pix_fmt: $hw_pixfmt,
      vmaf_cmp_fmt: $vmaf_pixfmt,
      is_hdr: ($is_hdr == 1),
      vmaf_threshold: ($vmaf_threshold | tonumber),
      sw_baseline: {
        description: $sw_desc,
        file: $sw_file,
        vmaf: $sw_vmaf,
        size_bytes: $sw_size,
        bitrate_kbps: $sw_kbps
      },
      steps: $steps
    }'
fi

# ===== Section 19: Wrap-up ================================================================
note "Encodes saved to: ${OUTPUT_DIR}/"
say ""
ok "Done."
say ""
