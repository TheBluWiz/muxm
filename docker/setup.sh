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

mkdir -p input output
echo " [OK] Created \"input\" and \"output\" folders."

echo
echo " Building MuxMaster image (this may take a few minutes the first time)..."
echo
docker compose build

echo
echo " Verifying installation..."
if docker compose run --rm muxm --version >/dev/null 2>&1; then
  echo " [OK] muxm is working."
else
  echo " [WARNING] muxm may not be working correctly inside the container." >&2
  echo "           Try running: docker compose run --rm muxm --help" >&2
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
