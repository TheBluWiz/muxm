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

# Compose v2 plugin. Debian/Ubuntu's `apt install docker.io` ships the engine
# with no compose plugin, so the check above passes and `docker compose` then
# dies mid-run with a cryptic "'compose' is not a docker command".
if ! docker compose version >/dev/null 2>&1; then
  echo " [ERROR] The Docker Compose v2 plugin is missing." >&2
  echo "         Linux:  sudo apt install docker-compose-plugin" >&2
  echo "                 (or see https://docs.docker.com/compose/install/)" >&2
  echo "         macOS:  install or repair Docker Desktop, which bundles it." >&2
  exit 1
fi

if [[ ! -f docker-compose.yml || ! -d input || ! -d output ]]; then
  echo " [ERROR] Setup incomplete — run ./setup.sh first." >&2
  exit 1
fi

# ---- The media folders must be usable by the current user ----
# On Linux the Docker engine auto-creates a missing bind-mount source as
# root:root. If anyone ran `docker compose run` before ./setup.sh, input/ and
# output/ are root-owned and every --user encode below dies with "Output
# directory not writable" — with no hint as to why, and rerunning setup.sh
# cannot repair it (mkdir -p happily "succeeds" on a dir it cannot write).
badperm=""
[[ -r input && -x input ]] || badperm="$badperm input"
[[ -w output ]] || badperm="$badperm output"
if [[ -n "$badperm" ]]; then
  echo " [ERROR] These folders are not usable by your user:$badperm" >&2
  if [[ "$(uname -s)" == "Linux" ]]; then
    echo "         On Linux, Docker auto-creates a missing bind-mount folder as" >&2
    echo "         root:root — which is what happens if 'docker compose run' ran" >&2
    echo "         before ./setup.sh did." >&2
  fi
  echo "         Fix the ownership with:" >&2
  echo "           sudo chown -R $(id -u):$(id -g)$badperm" >&2
  exit 1
fi

# ---- Warn if muxm changed since the image was built ----
# `docker compose run` reuses an existing muxm:latest tag and never rebuilds, so
# an edited muxm keeps encoding with the old script until ./setup.sh runs again.
# Strictly best-effort: every probe below is guarded, and any failure (no image,
# no muxm beside us, an unparseable timestamp, a stat/date dialect we don't know)
# silently skips the warning. This must never block an encode.
_file_mtime() {  # epoch mtime; GNU stat first, then BSD/macOS
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}
_iso_to_epoch() {  # RFC3339 -> epoch; GNU date first, then BSD/macOS
  local iso="$1" trimmed="${1%%.*}"
  trimmed="${trimmed%Z}"
  date -u -d "$iso" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%S' "$trimmed" +%s 2>/dev/null \
    || true
}
img_iso="$(docker image inspect -f '{{.Created}}' muxm:latest 2>/dev/null || true)"
if [[ -n "$img_iso" ]]; then
  img_epoch="$(_iso_to_epoch "$img_iso")"
  newest_muxm=0
  for m in ./muxm ../muxm; do
    [[ -f "$m" ]] || continue
    mt="$(_file_mtime "$m")"
    [[ "$mt" =~ ^[0-9]+$ ]] || continue
    if (( mt > newest_muxm )); then newest_muxm="$mt"; fi
  done
  if [[ "$img_epoch" =~ ^[0-9]+$ ]] && (( newest_muxm > img_epoch )); then
    echo " [WARNING] The muxm script is newer than the muxm:latest image." >&2
    echo "           Your changes are NOT in the image — rerun ./setup.sh to rebuild." >&2
    echo >&2
  fi
fi

# ---- Pick a file ----
# nocaseglob so .MOV / .MP4 / .MKV (what phones and cameras produce) are visible
# too — without it the user just sees "No video files found".
shopt -s nullglob nocaseglob
files=()
for f in input/*.mkv input/*.mp4 input/*.m4v input/*.mov input/*.avi input/*.ts \
         input/*.m2ts input/*.wmv input/*.flv input/*.webm; do
  files+=("${f#input/}")
done
shopt -u nullglob nocaseglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo " No video files found in the \"input\" folder."
  echo " Put files (.mkv .mp4 .m4v .mov .avi .ts .m2ts .wmv .flv .webm — any"
  echo " capitalization) there and run this again."
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
  # `|| { ... }`: under `set -e` a closed/exhausted stdin (automation, or a single
  # piped answer with 2+ files) would otherwise abort right here with no message.
  read -r filechoice || { echo; echo " [ERROR] No input received (stdin closed)." >&2; exit 1; }
  if [[ "$filechoice" == "A" || "$filechoice" == "a" ]]; then
    choices=("${files[@]}")
  # 10# forces base 10: bare "08"/"09" are invalid octal and would abort the
  # script with "value too great for base" before the bounds test could run.
  elif [[ "$filechoice" =~ ^[0-9]+$ ]] \
       && (( 10#$filechoice >= 1 && 10#$filechoice <= ${#files[@]} )); then
    choices=("${files[$((10#$filechoice - 1))]}")
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
read -r profilechoice || { echo; echo " [ERROR] No input received (stdin closed)." >&2; exit 1; }

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
    # Loud default: if a profile is added to the menu but not mapped here, fail
    # instead of emitting "/media/output/name." (empty ext). test_docker_parity.sh
    # guards this table against muxm, so this should only ever fire mid-edit.
    *) echo " [ERROR] internal: no output container mapped for profile '$profile'." >&2
       exit 1 ;;
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

# Exit non-zero when anything failed, so `./encode.sh && ...` chains and any
# automation driving this script actually see the failure.
(( failures == 0 )) || exit 1
