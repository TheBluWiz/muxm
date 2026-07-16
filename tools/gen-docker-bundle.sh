#!/usr/bin/env bash
# =============================================================================
#  gen-docker-bundle.sh — Assemble the Windows Docker bundle zip
#  Part of the MuxMaster™ toolchain
#  Copyright © 2025–2026 Jamey Wicklund (theBluWiz)
# =============================================================================
#
#  Produces dist/muxm-docker-windows-v<VERSION>.zip: the flat folder a Windows
#  user unpacks and drives with setup.bat / encode.bat, exactly as
#  docker/DOCKER_WINDOWS_GUIDE.md describes ("Place all six of these files
#  inside that folder"). Attach it to the GitHub release so nobody has to
#  collect the files by hand.
#
#  Contents: Dockerfile, docker-compose.yml, .dockerignore, setup.bat,
#  encode.bat, muxm (repo root), plus DOCKER_WINDOWS_GUIDE.md and LICENSE.md
#  (redistribution requires the license file — see LICENSE.md §3).
#
#  Usage:
#    tools/gen-docker-bundle.sh            # writes dist/muxm-docker-windows-v<VERSION>.zip
#
#  Requires: zip
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v zip >/dev/null 2>&1 || { echo "❌ zip not found" >&2; exit 1; }

VERSION="$(sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' muxm | head -1)"
[[ -n "$VERSION" ]] || { echo "❌ could not read VERSION from muxm" >&2; exit 1; }

# Refuse to bundle a drifted distribution.
tests/test_docker_parity.sh >/dev/null || {
  echo "❌ tests/test_docker_parity.sh failed — fix drift before bundling" >&2
  exit 1
}

# ---- Single source of truth for the bundle contents ----
# Repo-relative source paths; the zip stores each by basename (the flat folder a
# Windows user unpacks). This array drives BOTH the cp and the zip below, so they
# can't drift from each other. tests/test_docker_parity.sh parses this same
# `BUNDLE_FILES=( ... )` block (keep the one-path-per-line format) to check every
# promised file exists — so the manifest lives in exactly one place.
BUNDLE_FILES=(
  docker/Dockerfile
  docker/docker-compose.yml
  docker/.dockerignore
  docker/setup.bat
  docker/encode.bat
  docker/DOCKER_WINDOWS_GUIDE.md
  muxm
  LICENSE.md
)

OUT_DIR="$REPO_ROOT/dist"
OUT_ZIP="$OUT_DIR/muxm-docker-windows-v${VERSION}.zip"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/muxm-bundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT_DIR"
cp "${BUNDLE_FILES[@]}" "$STAGE/"

# Zip stores basenames (flat layout). Build the basename list from the array.
bundle_names=()
for f in "${BUNDLE_FILES[@]}"; do bundle_names+=("${f##*/}"); done
rm -f "$OUT_ZIP"
(cd "$STAGE" && zip -q "$OUT_ZIP" "${bundle_names[@]}")

echo "✅ wrote $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1 | tr -d ' '))"
