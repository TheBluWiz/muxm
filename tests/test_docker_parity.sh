#!/usr/bin/env bash
# =============================================================================
#  test_docker_parity.sh — Docker distribution drift check
#  Part of the MuxMaster™ test suite
#  Copyright © 2025–2026 Jamey Wicklund (theBluWiz)
# =============================================================================
#
#  The docker/ helpers embed knowledge that lives canonically in `muxm`:
#  profile names in the encode menus and doc examples. This guard exists
#  because that knowledge HAS drifted before — encode.bat shipped with menu
#  entries for `streaming` and `dv-archival`, profiles that had long since
#  been renamed, so two of its six options simply failed at runtime.
#
#  Checks:
#    1. Every profile name referenced in docker/ (menu entries in encode.bat /
#       encode.sh, `--profile X` examples in the guides and compose file) is a
#       member of muxm's VALID_PROFILES.
#    2. The encode.bat and encode.sh menus cover EVERY profile in
#       VALID_PROFILES (adding a profile without extending the menus fails).
#    3. Line endings: .bat files are CRLF (cmd.exe requirement), .sh files
#       and muxm are LF; .sh helpers are executable.
#    4. The files the Windows bundle/guide promise are actually present.
#
#  Exit: 0 = in sync, 1 = drift / error.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUXM="$REPO_ROOT/muxm"
DOCKER_DIR="$REPO_ROOT/docker"

fail_count=0
err() { printf '❌ docker parity: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }
ok()  { printf '✅ docker parity: %s\n' "$*"; }

[[ -f "$MUXM" ]] || { err "muxm not found ($MUXM)"; exit 1; }
[[ -d "$DOCKER_DIR" ]] || { err "docker/ directory not found"; exit 1; }

# ---- Canonical profile list (single source of truth in muxm) ----
valid_profiles="$(sed -n 's/^readonly VALID_PROFILES="\(.*\)"$/\1/p' "$MUXM")"
if [[ -z "$valid_profiles" ]]; then
  err "could not extract VALID_PROFILES from muxm"
  exit 1
fi

_is_valid_profile() {
  local p
  for p in $valid_profiles; do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}

# ---- 1. Every referenced profile must be valid ----
# Menu assignments:   set "profile=NAME"   (bat)  /  profile="NAME"  (sh)
# Doc/example usage:  --profile NAME
# Lowercase-only capture skips placeholders like `--profile NAME`.
referenced="$(
  {
    tr -d '\r' < "$DOCKER_DIR/encode.bat" \
      | sed -n 's/.*set "profile=\([a-z0-9-]\{1,\}\)".*/\1/p'
    sed -n 's/.*profile="\([a-z0-9-]\{1,\}\)" ;;.*/\1/p' "$DOCKER_DIR/encode.sh"
    grep -rhoE -- '--profile [a-z0-9-]+' \
      "$DOCKER_DIR/DOCKER_WINDOWS_GUIDE.md" "$DOCKER_DIR/README.md" \
      "$DOCKER_DIR/docker-compose.yml" "$DOCKER_DIR/encode.sh" 2>/dev/null \
      | awk '{print $2}'
  } | sort -u
)"

unknown=0
for p in $referenced; do
  if ! _is_valid_profile "$p"; then
    err "docker/ references unknown profile '$p' (not in VALID_PROFILES: $valid_profiles)"
    unknown=1
  fi
done
[[ $unknown -eq 0 ]] && ok "all profile names referenced under docker/ are valid"

# ---- 2. Menus must cover every canonical profile ----
for menu_desc in "encode.bat:set \"profile=" "encode.sh:profile=\""; do
  menu_file="${menu_desc%%:*}"
  missing=""
  for p in $valid_profiles; do
    case "$menu_file" in
      encode.bat)
        tr -d '\r' < "$DOCKER_DIR/encode.bat" | grep -q "set \"profile=$p\"" || missing="$missing $p" ;;
      encode.sh)
        grep -q "profile=\"$p\" ;;" "$DOCKER_DIR/encode.sh" || missing="$missing $p" ;;
    esac
  done
  if [[ -n "$missing" ]]; then
    err "docker/$menu_file menu is missing profile(s):$missing"
  else
    ok "docker/$menu_file menu covers all $(echo "$valid_profiles" | wc -w | tr -d ' ') profiles"
  fi
done

# ---- 3. Line endings and exec bits ----
for f in setup.bat encode.bat; do
  if grep -q $'\r' "$DOCKER_DIR/$f"; then
    ok "docker/$f has CRLF line endings"
  else
    err "docker/$f is not CRLF — double-clicking on Windows can misparse it"
  fi
done
for f in setup.sh encode.sh; do
  if grep -q $'\r' "$DOCKER_DIR/$f"; then
    err "docker/$f contains CR characters — bash will choke on CRLF"
  elif [[ ! -x "$DOCKER_DIR/$f" ]]; then
    err "docker/$f is not executable"
  else
    ok "docker/$f is LF and executable"
  fi
done
if grep -q $'\r' "$MUXM"; then
  err "muxm contains CR characters"
fi

# ---- 4. Promised files exist ----
for f in Dockerfile docker-compose.yml .dockerignore setup.bat encode.bat \
         setup.sh encode.sh DOCKER_WINDOWS_GUIDE.md README.md; do
  [[ -f "$DOCKER_DIR/$f" ]] || err "docker/$f is missing (referenced by the setup scripts/guides)"
done
[[ $fail_count -eq 0 ]] && ok "all bundle files present"

if [[ $fail_count -gt 0 ]]; then
  printf '❌ docker parity: %d check(s) failed.\n' "$fail_count" >&2
  exit 1
fi
printf '✅ docker parity: docker/ distribution in sync with muxm\n'
exit 0
