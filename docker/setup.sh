#!/usr/bin/env bash
# =============================================================================
#  MuxMaster — First-Time Docker Setup for macOS and Linux
#
#  What this does:
#    1. Copies the muxm script into this folder (when run from a repo checkout)
#    2. Creates "input" and "output" folders for your video files
#    3. Builds the MuxMaster Docker image with all dependencies
#    4. Runs a quick sanity check to confirm muxm works
#
#  You only need to run this ONCE (or again after updating muxm).
#
#  Note for macOS users: if you have Homebrew, `brew install TheBluWiz/taps/muxm`
#  runs muxm natively (faster, VideoToolbox-capable) — Docker is optional there.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

echo
echo " ============================================="
echo "  MuxMaster - First-Time Docker Setup"
echo " ============================================="
echo

# In a repo checkout muxm lives one level up; the image build needs it next to
# the Dockerfile. Refresh the local copy whenever the repo copy is newer, so a
# rebuild after `git pull` can't silently use a stale script.
if [[ -f ../muxm && ( ! -f ./muxm || ../muxm -nt ./muxm ) ]]; then
  cp ../muxm ./muxm
  echo " [OK] Copied muxm script from the repo checkout."
fi

if [[ ! -f ./muxm ]]; then
  echo " [ERROR] The \"muxm\" script was not found in this folder." >&2
  echo "         Download it from https://github.com/TheBluWiz/MuxMaster and" >&2
  echo "         place it next to this script, then run setup.sh again." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo " [ERROR] Docker is not installed." >&2
  echo "         macOS:  install Docker Desktop from https://www.docker.com/products/docker-desktop/" >&2
  echo "         Linux:  https://docs.docker.com/engine/install/ (then add yourself to the docker group)" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo " [ERROR] Docker is installed but not running (or you lack permission)." >&2
  echo "         macOS:  open Docker Desktop and wait for the engine to start." >&2
  echo "         Linux:  sudo systemctl start docker   (and ensure your user is in the docker group)" >&2
  exit 1
fi
echo " [OK] Docker is running."

# Compose v2 plugin. Debian/Ubuntu's `apt install docker.io` ships the engine
# with no compose plugin, so both checks above pass and `docker compose build`
# below then dies with a cryptic "'compose' is not a docker command".
if ! docker compose version >/dev/null 2>&1; then
  echo " [ERROR] The Docker Compose v2 plugin is missing." >&2
  echo "         Linux:  sudo apt install docker-compose-plugin" >&2
  echo "                 (or see https://docs.docker.com/compose/install/)" >&2
  echo "         macOS:  install or repair Docker Desktop, which bundles it." >&2
  exit 1
fi
echo " [OK] Docker Compose v2 is available."

# Report what actually happened — a pre-existing folder is not one we "created",
# and on Linux the difference matters (see the ownership check below).
for d in input output; do
  if [[ -d "$d" ]]; then
    echo " [OK] \"$d\" folder already exists."
  else
    mkdir -p "$d"
    echo " [OK] Created \"$d\" folder."
  fi
done

# The folders must be usable by the invoking user. On Linux the Docker engine
# auto-creates a missing bind-mount source as root:root, so if anyone ran
# `docker compose run` before this script, input/ and output/ are root-owned:
# mkdir -p above "succeeds" on them, and every --user encode later dies with
# "Output directory not writable". Rerunning setup.sh cannot chown them, so
# fail here with the one command that actually fixes it — before the long build.
badperm=""
[[ -r input && -x input ]] || badperm="$badperm input"
[[ -w output ]] || badperm="$badperm output"
if [[ -n "$badperm" ]]; then
  echo " [ERROR] These folders are not usable by your user:$badperm" >&2
  if [[ "$(uname -s)" == "Linux" ]]; then
    echo "         On Linux, Docker auto-creates a missing bind-mount folder as" >&2
    echo "         root:root — which is what happens if 'docker compose run' ran" >&2
    echo "         before this script did." >&2
  fi
  echo "         Fix the ownership with:" >&2
  echo "           sudo chown -R $(id -u):$(id -g)$badperm" >&2
  echo "         Then run ./setup.sh again." >&2
  exit 1
fi

echo
echo " Building MuxMaster image (this may take a few minutes the first time)..."
echo
docker compose build

echo
echo " Verifying installation..."
# Capture the real error instead of discarding it. The old version sent both
# streams to /dev/null, printed a WARNING, then fell through to the success
# banner and exited 0 — so `./setup.sh && ./encode.sh` chained straight into a
# broken image, and the user never saw why.
if verify_out="$(docker compose run --rm muxm --version 2>&1)"; then
  echo " [OK] muxm is working."
else
  echo " [ERROR] muxm could not run inside the container. Setup did NOT complete." >&2
  echo "         The container said:" >&2
  printf '%s\n' "$verify_out" | sed 's/^/           /' >&2
  echo >&2
  echo "         Try 'docker compose run --rm muxm --help' to reproduce it, or" >&2
  echo "         rebuild from scratch with 'docker compose build --no-cache'." >&2
  exit 1
fi

echo
echo " ============================================="
echo "  Setup complete!"
echo " ============================================="
echo
echo " Next steps:"
echo "   1. Put video files in the \"input\" folder"
echo "   2. Run ./encode.sh to encode them"
echo
