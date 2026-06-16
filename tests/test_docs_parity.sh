#!/usr/bin/env bash
# =============================================================================
#  test_docs_parity.sh — Man-page parity check
#  Part of the MuxMaster™ test suite
#  Copyright © 2025–2026 Jamey Wicklund (theBluWiz)
# =============================================================================
#
#  Verifies that the checked-in docs/muxm.1 is identical to what
#  tools/gen-docs.sh produces from the embedded man page in `muxm`
#  (emitted by `muxm --emit-man`). The heredoc is the single source of
#  truth; this guards against docs/muxm.1 being hand-edited or going stale.
#
#  On failure, prints the unified diff and exits non-zero. To fix:
#    tools/gen-docs.sh   # regenerate docs/muxm.1, then commit it
#
#  Exit: 0 = in sync, 1 = out of sync / error.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$REPO_ROOT/tools/gen-docs.sh"
DOC="$REPO_ROOT/docs/muxm.1"

if [[ ! -x "$GEN" ]]; then
  printf '❌ docs parity: tools/gen-docs.sh not found or not executable (%s)\n' "$GEN" >&2
  exit 1
fi
if [[ ! -f "$DOC" ]]; then
  printf '❌ docs parity: docs/muxm.1 not found (%s)\n' "$DOC" >&2
  exit 1
fi

expected="$(mktemp "${TMPDIR:-/tmp}/muxm-docs-parity.XXXXXX")"
trap 'rm -f "$expected"' EXIT

# Regenerate into the temp file (gen-docs.sh writes to $1 instead of clobbering
# the checked-in page when given an argument).
if ! "$GEN" "$expected" >/dev/null 2>&1; then
  printf '❌ docs parity: gen-docs.sh failed to regenerate the man page\n' >&2
  exit 1
fi

if diff -u "$DOC" "$expected" >/dev/null; then
  printf '✅ docs parity: docs/muxm.1 matches generated output (in sync with muxm embedded man page)\n'
  exit 0
else
  printf '❌ docs parity: docs/muxm.1 is OUT OF SYNC with the muxm embedded man page.\n' >&2
  printf '   Fix by regenerating and committing: tools/gen-docs.sh\n' >&2
  printf '   Unified diff (checked-in <  >  generated):\n' >&2
  diff -u "$DOC" "$expected" >&2 || true
  exit 1
fi
