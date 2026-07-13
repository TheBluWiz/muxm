#!/usr/bin/env bash
# =============================================================================
#  MuxMaster — Encode Videos via Docker (macOS / Linux)
#
#  How to use:
#    1. Put video files in the "input" folder
#    2. Run ./encode.sh
#    3. Choose a file and a profile when prompted
#    4. Encoded files appear in the "output" folder
#
#  Power users: drive muxm directly for access to every flag —
#    docker compose run --rm muxm --profile streaming-hevc /media/input/movie.mkv /media/output/movie.mp4
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

echo
echo " ============================================="
echo "  MuxMaster - Video Encoder"
echo " ============================================="
echo

if ! docker info >/dev/null 2>&1; then
  echo " [ERROR] Docker is not running. Start Docker and try again." >&2
  exit 1
fi
if [[ ! -f docker-compose.yml || ! -d input ]]; then
  echo " [ERROR] Setup incomplete — run ./setup.sh first." >&2
  exit 1
fi

# ---- Pick a file ----
shopt -s nullglob
files=()
for f in input/*.mkv input/*.mp4 input/*.m4v input/*.mov input/*.avi input/*.ts input/*.m2ts; do
  files+=("${f#input/}")
done
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo " No video files found in the \"input\" folder."
  echo " Put files (.mkv, .mp4, .m4v, .mov, .avi, .ts, .m2ts) there and run this again."
  exit 0
fi

echo " Files in your \"input\" folder:"
echo " -------------------------------------------"
i=1
for f in "${files[@]}"; do
  printf "  %2d. %s\n" "$i" "$f"
  i=$((i + 1))
done
echo " -------------------------------------------"
echo

if [[ ${#files[@]} -eq 1 ]]; then
  choices=("${files[0]}")
  echo " Using: ${files[0]}"
else
  printf "  Which file? Enter a number (1-%d), or A for all: " "${#files[@]}"
  read -r filechoice
  if [[ "$filechoice" == "A" || "$filechoice" == "a" ]]; then
    choices=("${files[@]}")
  elif [[ "$filechoice" =~ ^[0-9]+$ ]] && (( filechoice >= 1 && filechoice <= ${#files[@]} )); then
    choices=("${files[$((filechoice - 1))]}")
  else
    echo " [ERROR] Invalid selection." >&2
    exit 1
  fi
fi

# ---- Pick a profile ----
# One menu entry per profile in muxm's VALID_PROFILES (tests/test_docker_parity.sh
# guards this list against renames). Descriptions follow `muxm --help`.
echo
echo " ============================================="
echo "  Choose an Encoding Profile"
echo " ============================================="
echo
echo "   1. atv-directplay-hq         Apple TV Direct Play [recommended]"
echo "   2. streaming-hevc            HEVC for Plex / Jellyfin / Emby"
echo "   3. streaming-av1             AV1 for AV1-capable platforms, smaller files"
echo "   4. universal                 Plays on everything (H.264 SDR)"
echo "   5. hdr10-hq                  Max-quality HDR10 (strips Dolby Vision)"
echo "   6. archive                   Lossless preservation (no re-encode)"
echo "   7. av1-hq                    High-quality AV1 archive"
echo "   8. animation                 Anime / cartoon optimized"
echo "   9. atv-directplay-animation  Anime for Apple TV Direct Play"
echo "  10. youtube-upload            YouTube upload prep"
echo
printf "  Enter a number (1-10): "
read -r profilechoice

profile=""
case "$profilechoice" in
  1)  profile="atv-directplay-hq" ;;
  2)  profile="streaming-hevc" ;;
  3)  profile="streaming-av1" ;;
  4)  profile="universal" ;;
  5)  profile="hdr10-hq" ;;
  6)  profile="archive" ;;
  7)  profile="av1-hq" ;;
  8)  profile="animation" ;;
  9)  profile="atv-directplay-animation" ;;
  10) profile="youtube-upload" ;;
  *)  echo " [ERROR] Invalid selection. Please enter 1-10." >&2; exit 1 ;;
esac

# ---- Output container per profile ----
# Mirrors each profile's documented container (see `muxm --help`). The two
# ATV profiles are container-passthrough: keep the source extension when it
# is a supported output container, otherwise fall back to .mkv exactly as
# muxm's own passthrough resolution does.
_out_ext() {
  local src_ext="$1"
  case "$profile" in
    streaming-hevc|streaming-av1|universal|youtube-upload) echo "mp4" ;;
    archive|hdr10-hq|av1-hq|animation)                     echo "mkv" ;;
    atv-directplay-hq|atv-directplay-animation)
      case "$src_ext" in
        mp4|m4v|mov|mkv) echo "$src_ext" ;;
        *)               echo "mkv" ;;
      esac ;;
  esac
}

# On Linux, run as the invoking user so output files are owned by you, not
# root. Docker Desktop (macOS/Windows) already maps ownership transparently.
userflag=()
if [[ "$(uname -s)" == "Linux" ]]; then
  userflag=(--user "$(id -u):$(id -g)")
fi

# ---- Refuse if two selected inputs would write the same output ----
# muxm defaults to overwriting its output and only auto-versions when the source
# and output paths are identical, so two inputs whose stems collide would
# silently clobber each other. This bites "A for all" batches: movie.mkv + movie.ts
# both target output/movie.mp4, and the ATV passthrough widens it (movie.ts and
# movie.avi both fall back to .mkv). Detect it here and stop before any encode runs.
# Uses indexed arrays and an O(n^2) pair compare (not an associative array) to
# stay compatible with macOS's stock bash 3.2. Mirrors encode.bat.
planned=()
collision=0
i=0
for chosen in "${choices[@]}"; do
  base="${chosen%.*}"
  src_ext="$(printf '%s' "${chosen##*.}" | tr '[:upper:]' '[:lower:]')"
  out="$base.$(_out_ext "$src_ext")"
  j=0
  while (( j < i )); do
    if [[ "${planned[$j]}" == "$out" ]]; then
      echo " [ERROR] Two input files would both be written to \"output/$out\":" >&2
      echo "           - ${choices[$j]}" >&2
      echo "           - $chosen" >&2
      collision=1
    fi
    j=$((j + 1))
  done
  planned[$i]="$out"
  i=$((i + 1))
done
if (( collision )); then
  echo >&2
  echo " Rename one of the colliding files, or encode them one at a time, and try again." >&2
  exit 1
fi

failures=0
for chosen in "${choices[@]}"; do
  base="${chosen%.*}"
  src_ext="$(printf '%s' "${chosen##*.}" | tr '[:upper:]' '[:lower:]')"
  out_ext="$(_out_ext "$src_ext")"

  echo
  echo " ============================================="
  echo "  Starting encode"
  echo " ============================================="
  echo
  echo "  File:    $chosen"
  echo "  Profile: $profile"
  echo

  if docker compose run --rm "${userflag[@]+"${userflag[@]}"}" muxm \
       --profile "$profile" \
       "/media/input/$chosen" "/media/output/$base.$out_ext"; then
    echo
    echo " Done: output/$base.$out_ext"
  else
    echo
    echo " [ERROR] Encode failed for: $chosen (see messages above)" >&2
    failures=$((failures + 1))
  fi
done

echo
if (( failures == 0 )); then
  echo " ============================================="
  echo "  Done! Check the \"output\" folder."
  echo " ============================================="
else
  echo " ============================================="
  echo "  Finished with $failures failed encode(s)."
  echo " ============================================="
fi
echo
