#!/usr/bin/env bash
# =============================================================================
#  test_completions_parity.sh — Tab-completion parity check
#  Part of the MuxMaster™ test suite
#  Copyright © 2025–2026 Jamey Wicklund (theBluWiz)
# =============================================================================
#
#  Verifies that the committed completions/muxm-completion.bash is byte-identical
#  to what `muxm --emit-completions` produces from the embedded COMPLETIONS_EOF
#  heredoc in `muxm`. That heredoc is the single source of truth; this guards
#  against the committed completion being hand-edited or going stale (the
#  --workdir/--threads drift this test was introduced to prevent).
#
#  The completion carries its "generated" banner inside the heredoc, so the
#  committed file equals the raw emit (no prepended banner, unlike the man page).
#
#  On failure, prints the unified diff and exits non-zero. To fix:
#    tools/gen-docs.sh   # regenerates completions/muxm-completion.bash, then commit it
#
#  Exit: 0 = in sync, 1 = out of sync / error.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUXM="$REPO_ROOT/muxm"
COMP="$REPO_ROOT/completions/muxm-completion.bash"

if [[ ! -x "$MUXM" ]]; then
  printf '❌ completions parity: muxm not found or not executable (%s)\n' "$MUXM" >&2
  exit 1
fi
if [[ ! -f "$COMP" ]]; then
  printf '❌ completions parity: completions/muxm-completion.bash not found (%s)\n' "$COMP" >&2
  exit 1
fi

expected="$(mktemp "${TMPDIR:-/tmp}/muxm-comp-parity.XXXXXX")"
trap 'rm -f "$expected"' EXIT

if ! "$MUXM" --emit-completions > "$expected" 2>/dev/null; then
  printf '❌ completions parity: muxm --emit-completions failed\n' >&2
  exit 1
fi

if diff -u "$COMP" "$expected" >/dev/null; then
  printf '✅ completions parity: completions/muxm-completion.bash matches muxm --emit-completions (in sync)\n'
  exit 0
else
  printf '❌ completions parity: completions/muxm-completion.bash is OUT OF SYNC with the muxm embedded completion.\n' >&2
  printf '   Fix by regenerating and committing: tools/gen-docs.sh\n' >&2
  printf '   Unified diff (committed <  >  generated):\n' >&2
  diff -u "$COMP" "$expected" >&2 || true
  exit 1
fi
