#!/usr/bin/env bash
# VT calibration sweep runner — all 14 profile/clip combinations
# Runs sequentially; each sweep writes result.json + run.log to its output dir.
set -euo pipefail

SCRIPT="/Users/thebluwiz/claude_workspace/muxm/tools/hw_compare.sh"
CLIP_A="/Users/thebluwiz/claude_workspace/muxm/calibration/clips/clip_a_city_of_god_1080p_sdr_120s.mkv"
CLIP_B="/Users/thebluwiz/claude_workspace/muxm/calibration/clips/clip_b_avatar_4k_hdr10_120s.mkv"
RESULTS="/Users/thebluwiz/claude_workspace/muxm/calibration/results"

PASS=0
FAIL=0

run_sweep() {
  local enc="$1" prof="$2" clip_label="$3" range="$4"
  local clip; [[ "$clip_label" == "clip_a" ]] && clip="$CLIP_A" || clip="$CLIP_B"
  local outdir="${RESULTS}/${prof}/${clip_label}"
  mkdir -p "$outdir"

  local start; start=$(date +%s)
  echo "[$(date '+%H:%M:%S')] START  ${prof} / ${clip_label}  (${enc}  q:v ${range})" | tee -a "${RESULTS}/progress.log"

  if bash "$SCRIPT" \
    --encoder "$enc" \
    --profile "$prof" \
    --clip "$clip" \
    --quality-range "$range" \
    --output-dir "$outdir" \
    --json \
    > "${outdir}/result.json" \
    2> "${outdir}/run.log"; then
    local elapsed=$(( $(date +%s) - start ))
    echo "[$(date '+%H:%M:%S')] DONE   ${prof} / ${clip_label}  (${elapsed}s)" | tee -a "${RESULTS}/progress.log"
    (( PASS++ )) || true
  else
    local elapsed=$(( $(date +%s) - start ))
    echo "[$(date '+%H:%M:%S')] FAILED ${prof} / ${clip_label}  (${elapsed}s)" | tee -a "${RESULTS}/progress.log"
    (( FAIL++ )) || true
  fi
}

echo "=== VT calibration sweeps starting $(date) ===" | tee "${RESULTS}/progress.log"
echo "Script: $SCRIPT" | tee -a "${RESULTS}/progress.log"
echo "" | tee -a "${RESULTS}/progress.log"

# ── Clip A (1080p SDR) ─────────────────────────────────────────────────────
# Primary SDR profiles
run_sweep h264_videotoolbox universal                clip_a 55:80:5
run_sweep h264_videotoolbox youtube-upload           clip_a 65:85:5
run_sweep hevc_videotoolbox streaming-hevc           clip_a 55:75:5
# HDR profiles against SDR clip (cross-check)
run_sweep hevc_videotoolbox hdr10-hq                 clip_a 65:85:5
run_sweep hevc_videotoolbox animation                clip_a 65:85:5
run_sweep hevc_videotoolbox atv-directplay-hq        clip_a 65:85:5
run_sweep hevc_videotoolbox atv-directplay-animation clip_a 65:85:5

# ── Clip B (4K HDR10) ──────────────────────────────────────────────────────
# Primary HDR profiles
run_sweep hevc_videotoolbox hdr10-hq                 clip_b 65:85:5
run_sweep hevc_videotoolbox animation                clip_b 65:85:5
run_sweep hevc_videotoolbox atv-directplay-hq        clip_b 65:85:5
run_sweep hevc_videotoolbox atv-directplay-animation clip_b 65:85:5
# SDR profiles against HDR clip (cross-check)
run_sweep h264_videotoolbox universal                clip_b 55:80:5
run_sweep h264_videotoolbox youtube-upload           clip_b 65:85:5
run_sweep hevc_videotoolbox streaming-hevc           clip_b 55:75:5

echo "" | tee -a "${RESULTS}/progress.log"
echo "=== ALL SWEEPS COMPLETE  pass=${PASS}  fail=${FAIL}  $(date) ===" | tee -a "${RESULTS}/progress.log"
