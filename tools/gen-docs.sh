#!/usr/bin/env bash
# =============================================================================
#  gen-docs.sh — Regenerate the committed generated artifacts from muxm
#  Part of the MuxMaster™ toolchain
#  Copyright © 2025–2026 Jamey Wicklund (theBluWiz)
# =============================================================================
#
#  The embedded heredocs in `muxm` are the SINGLE SOURCE OF TRUTH for two
#  committed artifacts:
#    * docs/muxm.1                    (MANPAGE_EOF, emitted by `muxm --emit-man`)
#    * completions/muxm-completion.bash (COMPLETIONS_EOF, `muxm --emit-completions`)
#  Never hand-edit either committed file — edit the heredoc in `muxm` and
#  re-run this script. The man page gets a prepended roff "generated" banner;
#  the completion carries its own banner inside the heredoc, so its committed
#  copy is byte-identical to `muxm --emit-completions`.
#
#  Usage:
#    tools/gen-docs.sh           # regenerate BOTH committed artifacts in place
#    tools/gen-docs.sh OUTFILE   # write ONLY the man page to OUTFILE instead
#                                # (used by the man parity test so it never
#                                # clobbers the checked-in page)
#
#  Requires: bash 4.3+ (same as muxm)
# =============================================================================

set -eEuo pipefail
if shopt -q inherit_errexit 2>/dev/null; then shopt -s inherit_errexit; fi

# Resolve repo root from this script's location (tools/ is a direct child).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUXM="$REPO_ROOT/muxm"
OUT="${1:-$REPO_ROOT/docs/muxm.1}"

if [[ ! -x "$MUXM" ]]; then
  printf '❌ gen-docs.sh: cannot find executable muxm at %s\n' "$MUXM" >&2
  exit 1
fi

# Roff comment banner (lines beginning with `.\"` are comments — they do not
# render in `man`, so this is safe to carry into the generated page).
read -r -d '' HEADER <<'BANNER' || true
.\" ============================================================================
.\" GENERATED FILE — do not edit.
.\" This page is generated from the embedded man-page heredoc in `muxm`
.\" (emitted by `muxm --emit-man`). To change it, edit that heredoc and
.\" regenerate with tools/gen-docs.sh. Hand edits here will be overwritten.
.\" ============================================================================
BANNER

# Write atomically: build into a temp file, then move into place.
tmp="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
{
  printf '%s\n' "$HEADER"
  "$MUXM" --emit-man
} > "$tmp"
mv "$tmp" "$OUT"
trap - EXIT

printf '✅ Regenerated %s from the embedded man page in muxm\n' "$OUT" >&2

# Completions are only regenerated on a full in-place run (no explicit OUTFILE),
# so the man parity test's `gen-docs.sh OUTFILE` invocation stays man-only.
# The completion carries its banner inside the heredoc, so no banner is prepended
# here — the committed file equals `muxm --emit-completions` byte-for-byte.
if [[ -z "${1:-}" ]]; then
  COMP_OUT="$REPO_ROOT/completions/muxm-completion.bash"
  comp_tmp="$(mktemp "${COMP_OUT}.XXXXXX")"
  trap 'rm -f "$comp_tmp"' EXIT
  "$MUXM" --emit-completions > "$comp_tmp"
  mv "$comp_tmp" "$COMP_OUT"
  trap - EXIT
  printf '✅ Regenerated %s from the embedded completion in muxm\n' "$COMP_OUT" >&2
fi
