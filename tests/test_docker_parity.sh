#!/usr/bin/env bash
# =============================================================================
#  test_docker_parity.sh — Docker distribution drift check
#  Part of the MuxMaster™ test suite
#  Copyright © 2025–2026 Jamey Wicklund (theBluWiz)
# =============================================================================
#
#  The docker/ helpers embed knowledge that lives canonically in `muxm`:
#  profile names, per-profile output containers, the accepted input extensions,
#  and the required-tool roster. This guard exists because that knowledge HAS
#  drifted before — encode.bat once shipped menu entries for `streaming` and
#  `dv-archival`, stale deprecated aliases muxm only tolerated with a warning.
#
#  Checks:
#    1. Every profile name referenced in docker/ (menu assignments AND echo'd
#       menu labels in encode.bat / encode.sh, `--profile X` examples in the
#       guides and compose file) is a member of muxm's VALID_PROFILES.
#    2. The encode.bat and encode.sh menus cover EVERY profile in VALID_PROFILES.
#    3. Line endings: .bat files are CRLF, .sh files and muxm are LF; .sh
#       helpers are executable.
#    4. The files gen-docker-bundle.sh promises (its BUNDLE_FILES array) exist.
#    5. Each profile's output container in both helpers matches muxm's per-profile
#       OUTPUT_EXT (and the container-passthrough set matches).
#    6. The input-extension menus agree with each other and cover muxm's own
#       completion source-extension list.
#    7. Every REQUIRED tool muxm checks (`_check_tool X required`) is provided by
#       the Dockerfile.
#    8. A staged docker/muxm (gitignored build copy) is byte-identical to ../muxm.
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

# Sorted, space-delimited normalisation of a "a|b|c" or whitespace list, so
# set comparisons are order-insensitive.
_norm_set() { printf '%s\n' "$1" | tr '| ' '\n\n' | sed '/^$/d' | sort -u | tr '\n' ' '; }

# ---- Canonical data from muxm (single source of truth) ----
# L-20: byte-identical extraction to test_muxm.sh's thrice-used pipeline (the old
# EOL-anchored sed returned EMPTY on a trailing space/comment — two guards
# disagreeing about the canonical list).
valid_profiles="$(grep '^readonly VALID_PROFILES=' "$MUXM" | sed 's/^readonly VALID_PROFILES="//;s/"$//' || true)"
if [[ -z "$valid_profiles" ]]; then
  err "could not extract VALID_PROFILES from muxm"
  exit 1
fi
profile_count="$(set -- $valid_profiles; echo $#)"

_is_valid_profile() {
  local p
  for p in $valid_profiles; do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}

# Read each helper once (L-16: avoid a tr|grep subshell per profile). Tolerant
# reads (M-6): a missing helper leaves the text empty and surfaces as ❌ findings
# in the checks below + check 4, instead of a silent set -e/pipefail abort here.
bat_text="$(tr -d '\r' < "$DOCKER_DIR/encode.bat" 2>/dev/null || true)"
sh_text="$(cat "$DOCKER_DIR/encode.sh" 2>/dev/null || true)"

# ---- 1. Every referenced profile must be valid ----
# Menu assignments:   set "profile=NAME" (bat) / profile="NAME" (sh)
# Menu labels (L-17): the token right after "N. " in each echo'd menu line —
#   catches a stale label whose case-arm assignment was renamed but the visible
#   name was not. (Only the first token is taken, so descriptions like
#   "(no re-encode)" never leak in.)
# Doc/example usage:  --profile NAME
# Lowercase-only capture skips placeholders like `--profile NAME`.
referenced="$(
  {
    printf '%s\n' "$bat_text" | sed -n 's/.*set "profile=\([a-z0-9-]\{1,\}\)".*/\1/p'
    printf '%s\n' "$sh_text"  | sed -n 's/.*profile="\([a-z0-9-]\{1,\}\)" ;;.*/\1/p'
    printf '%s\n' "$bat_text" | sed -n 's/^[[:space:]]*echo[[:space:]]*[0-9]\{1,\}\. \([a-z0-9-]\{1,\}\).*/\1/p'
    printf '%s\n' "$sh_text"  | sed -n 's/^[[:space:]]*echo "[[:space:]]*[0-9]\{1,\}\. \([a-z0-9-]\{1,\}\).*/\1/p'
    { grep -rhoE -- '--profile [a-z0-9-]+' \
        "$DOCKER_DIR/DOCKER_WINDOWS_GUIDE.md" "$DOCKER_DIR/README.md" \
        "$DOCKER_DIR/docker-compose.yml" "$DOCKER_DIR/encode.sh" 2>/dev/null \
      | awk '{print $2}'; } || true
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
# L-6: no unused pattern payload — two plain membership tests. L-16: match against
# the once-stripped text with bash [[ ]] instead of a tr|grep subshell per profile.
for menu in bat sh; do
  missing=""
  for p in $valid_profiles; do
    case "$menu" in
      bat) [[ "$bat_text" == *"set \"profile=$p\""* ]] || missing="$missing $p" ;;
      sh)  [[ "$sh_text"  == *"profile=\"$p\" ;;"* ]]  || missing="$missing $p" ;;
    esac
  done
  if [[ -n "$missing" ]]; then
    err "docker/encode.$menu menu is missing profile(s):$missing"
  else
    ok "docker/encode.$menu menu covers all $profile_count profiles"
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

# ---- 4. Promised bundle files exist ----
# L-4: single source of truth — read the BUNDLE_FILES array from
# gen-docker-bundle.sh (the same list that drives the cp + zip) so this check and
# the bundler can't drift. L-7: section-local counter, not the global fail_count,
# so an unrelated earlier failure doesn't suppress the success line.
bundle_list="$(awk '/^BUNDLE_FILES=\(/{f=1;next} /^\)/{f=0} f{gsub(/^[[:space:]]+|[[:space:]]+$/,"");print}' \
                 "$REPO_ROOT/tools/gen-docker-bundle.sh" 2>/dev/null || true)"
if [[ -z "$bundle_list" ]]; then
  err "could not read BUNDLE_FILES from tools/gen-docker-bundle.sh (bundle manifest guard could not run)"
else
  missing_files=0
  for f in $bundle_list; do
    [[ -f "$REPO_ROOT/$f" ]] || { err "bundle file '$f' is missing (promised by gen-docker-bundle.sh / the guide)"; missing_files=$((missing_files + 1)); }
  done
  (( missing_files == 0 )) && ok "all $(set -- $bundle_list; echo $#) bundle files present"
fi

# ---- 5. Output containers match muxm's per-profile OUTPUT_EXT (M-9) ----
# muxm sets OUTPUT_EXT in each apply_profile_<name> function (hyphens → underscores
# in the name); the two passthrough profiles set OUTPUT_EXT="" and resolve the
# container from the source extension. Extract that map FUNCTION-SCOPED so the
# global OUTPUT_EXT default and the `local OUTPUT_EXT` decoy are ignored.
muxm_ext_map="$(awk '
  /^apply_profile_[a-z0-9_]+\(\)[[:space:]]*\{/ { fn=$1; sub(/\(\).*/,"",fn); sub(/^apply_profile_/,"",fn); gsub(/_/,"-",fn); have=1; next }
  have && /^  OUTPUT_EXT=/ { ext=$0; sub(/^  OUTPUT_EXT="?/,"",ext); sub(/".*/,"",ext); if (ext=="") ext="passthrough"; print fn" "ext; have=0 }
' "$MUXM")"

# encode.sh _out_ext case arms (generic — the ext token is not hard-coded).
sh_mp4_arm="$(printf '%s\n' "$sh_text" | sed -n 's/^[[:space:]]*\([a-z0-9|-]*\))[[:space:]]*echo "mp4".*/\1/p')"
sh_mkv_arm="$(printf '%s\n' "$sh_text" | sed -n 's/^[[:space:]]*\([a-z0-9|-]*\))[[:space:]]*echo "mkv".*/\1/p')"
sh_pass_arm="$(printf '%s\n' "$sh_text" | sed -n 's/^[[:space:]]*\([a-z0-9|-]*\))$/\1/p')"

_muxm_ext_for() { printf '%s\n' "$muxm_ext_map" | awk -v p="$1" '$1==p{print $2; exit}'; }
_sh_ext_for() {
  case "|$sh_mp4_arm|"  in *"|$1|"*) echo mp4; return;; esac
  case "|$sh_mkv_arm|"  in *"|$1|"*) echo mkv; return;; esac
  case "|$sh_pass_arm|" in *"|$1|"*) echo passthrough; return;; esac
  echo UNMAPPED
}
_bat_ext_for() {
  local v
  v="$(printf '%s\n' "$bat_text" | sed -n "s/.*==\"$1\"[[:space:]]*set \"outext=\([a-zA-Z0-9]*\)\".*/\1/p" | head -1)"
  case "$v" in
    SRC) echo passthrough ;;
    "")  echo UNMAPPED ;;
    *)   echo "$v" ;;
  esac
}

ext_drift=0
map_count="$(printf '%s\n' "$muxm_ext_map" | grep -c . || true)"
if [[ "$map_count" -ne "$profile_count" ]]; then
  err "extracted OUTPUT_EXT for $map_count profile(s) but VALID_PROFILES has $profile_count (apply_profile_* extraction drift)"
  ext_drift=1
fi
for p in $valid_profiles; do
  e="$(_muxm_ext_for "$p")"
  if [[ -z "$e" ]]; then
    err "muxm has no apply_profile_* OUTPUT_EXT for profile '$p'"
    ext_drift=1
    continue
  fi
  s="$(_sh_ext_for "$p")"
  b="$(_bat_ext_for "$p")"
  [[ "$s" == "$e" ]] || { err "encode.sh maps '$p' → container '$s' but muxm OUTPUT_EXT is '$e'"; ext_drift=1; }
  [[ "$b" == "$e" ]] || { err "encode.bat maps '$p' → container '$b' but muxm OUTPUT_EXT is '$e'"; ext_drift=1; }
done

# Container-passthrough set: muxm's `_resolve_output_and_sub_policy` copies the
# source container only for this set (else falls back to mkv). Both helpers mirror
# it; all three must agree.
muxm_pass="$(_norm_set "$(grep -B1 'OUTPUT_EXT="\$_src_passthrough_ext"' "$MUXM" | sed -n 's/^[[:space:]]*\([a-z0-9|]*\))[[:space:]]*$/\1/p' | head -1)")"
sh_pass="$(_norm_set "$(printf '%s\n' "$sh_text" | sed -n 's/^[[:space:]]*\([a-z0-9|]*\)) echo "\$src_ext".*/\1/p' | head -1)")"
bat_pass="$(_norm_set "$(printf '%s\n' "$bat_text" | sed -n 's/.*"!srcext!"=="\([a-z0-9]*\)".*/\1/p')")"
if [[ "$muxm_pass" != "$sh_pass" || "$muxm_pass" != "$bat_pass" ]]; then
  err "container-passthrough set drift: muxm={$muxm_pass} encode.sh={$sh_pass} encode.bat={$bat_pass}"
  ext_drift=1
fi
(( ext_drift == 0 )) && ok "encode.sh / encode.bat output containers match muxm for all $profile_count profiles"

# ---- 6. Input-extension menus agree (M-16) ----
sh_globs="$(printf '%s\n' "$sh_text" | grep -oE 'input/\*\.[a-z0-9]+' | sed 's#input/\*\.##' | sort -u)"
bat_globs="$(printf '%s\n' "$bat_text" | grep -oE 'input\\\*\.[a-z0-9]+' | sed 's/.*\.//' | sort -u)"
if [[ "$sh_globs" != "$bat_globs" ]]; then
  err "input-file globs differ — encode.sh={$(echo $sh_globs)} encode.bat={$(echo $bat_globs)}"
else
  ok "encode.sh and encode.bat offer the same input extensions"
fi
# muxm's completion source list must be a SUBSET of the helper globs: every ext
# muxm recognises should be offered. Helpers may carry extras (e.g. m2ts, which
# muxm/ffmpeg process but muxm does not tab-complete) — so this is one-directional.
comp_exts="$(grep -oE '[a-z0-9]+(\|[a-z0-9]+)+\) COMPREPLY' "$MUXM" | head -1 | sed 's/) COMPREPLY//' | tr '|' ' ')"
if [[ -z "$comp_exts" ]]; then
  err "could not extract the completion source-extension list from muxm"
else
  helper_globs=" $(echo $sh_globs) "
  missing_exts=""
  for e in $comp_exts; do
    case "$helper_globs" in *" $e "*) ;; *) missing_exts="$missing_exts $e";; esac
  done
  if [[ -n "$missing_exts" ]]; then
    err "helper input globs omit muxm-supported extension(s):$missing_exts (in muxm's completion list)"
  else
    ok "helper input globs cover muxm's completion source list"
  fi
fi

# ---- 7. Dockerfile provides every REQUIRED tool (M-14) ----
required_tools="$(grep -E '_check_tool[[:space:]]+[a-z0-9_]+[[:space:]]+required' "$MUXM" \
  | sed -E 's/.*_check_tool[[:space:]]+([a-z0-9_]+)[[:space:]]+required.*/\1/' | sort -u)"
if [[ -z "$required_tools" ]]; then
  err "could not extract the required _check_tool roster from muxm"
else
  # Match against non-comment lines only. A tool named merely in the "# Required:"
  # doc comment must NOT satisfy the check — the failure this guards against is a
  # new required tool added to the comment but forgotten in the apt/verify layers.
  dockerfile_code="$(grep -v '^[[:space:]]*#' "$DOCKER_DIR/Dockerfile")"
  tool_gap=0
  for t in $required_tools; do
    if printf '%s\n' "$dockerfile_code" | grep -qw "$t"; then
      :
    elif [[ "$t" == "ffprobe" ]] && printf '%s\n' "$dockerfile_code" | grep -qw ffmpeg; then
      : # ffprobe ships inside the apt `ffmpeg` package — no separate install
    else
      err "muxm requires '$t' (_check_tool … required) but the Dockerfile never installs/verifies it"
      tool_gap=1
    fi
  done
  (( tool_gap == 0 )) && ok "Dockerfile provides all required tools ($(echo $required_tools))"
fi

# ---- 8. Staged docker/muxm must not be stale (M-15) ----
# docker/muxm is a gitignored build-staging copy of ../muxm (docker/setup.sh and
# the CI workflow refresh it before building). A dev who edits repo-root muxm and
# runs `docker compose build` directly would otherwise bake a week-old copy. This
# is a LOCAL-DEV guard: the file is absent in a clean checkout and freshly copied
# in CI, so both pass — its job is catching a stale local copy.
if [[ -f "$DOCKER_DIR/muxm" ]]; then
  if cmp -s "$DOCKER_DIR/muxm" "$MUXM"; then
    ok "staged docker/muxm is byte-identical to ../muxm"
  else
    err "docker/muxm differs from ../muxm — stale build-staging copy; rerun docker/setup.sh (or rm docker/muxm)"
  fi
fi

if [[ $fail_count -gt 0 ]]; then
  printf '❌ docker parity: %d check(s) failed.\n' "$fail_count" >&2
  exit 1
fi
printf '✅ docker parity: docker/ distribution in sync with muxm\n'
exit 0
