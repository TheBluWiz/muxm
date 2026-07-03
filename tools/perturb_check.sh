#!/usr/bin/env bash
# =============================================================================
#  perturb_check.sh — perturbation catalog / acceptance gate for the hardened test suite
#
#  The acceptance gate for the hardened test suite: it proves each hardened test can actually
#  FAIL when the feature it covers is broken. For every ENFORCED mutation it
#    1. copies muxm to a throwaway file,
#    2. applies ONE content-anchored mutation, asserting exactly one line changed (so a
#       drifted anchor is caught instead of silently mutating nothing / too much),
#    3. runs the named suite against the copy and asserts the NAMED test's FAIL line appears
#       (red-under-mutation) — the *specific* test, not just a nonzero suite exit, so a
#       mutation that happens to break some other assertion can't false-pass the gate,
#    4. runs the clean (unmutated) muxm and asserts that same test does NOT fail (green-
#       when-reverted), proving the test is specific to the break.
#  Originals are never touched: every mutation lives in a temp dir removed on exit.
#
#  Anchors are content-based (not muxm:NNNN line numbers), so they survive edits; if an anchor
#  ever drifts, the "exactly one line changed" guard turns it into a loud failure here.
#
#  Usage: tools/perturb_check.sh [--muxm PATH] [--test PATH] [-h|--help]
#  Exit:  0 = every enforced mutation behaved; 1 = a gate failed; 2 = usage/setup error.
#
#  Run it locally after the suite passes — it's the acceptance gate that signs off each
#  test in the hardened suite.
# =============================================================================
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; BOLD=$'\033[1m'; NC=$'\033[0m'
HERE="$(cd "$(dirname -- "$0")" && pwd)"
MUXM="$HERE/../muxm"
TEST="$HERE/../tests/test_muxm.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --muxm) [[ $# -ge 2 ]] || { echo "Error: --muxm needs a PATH" >&2; exit 2; }; MUXM="$2"; shift 2 ;;
    --test) [[ $# -ge 2 ]] || { echo "Error: --test needs a PATH" >&2; exit 2; }; TEST="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
[[ -r "$MUXM" ]] || { echo "ERROR: muxm not readable: $MUXM" >&2; exit 2; }
[[ -x "$TEST" ]] || { echo "ERROR: test harness not found/executable: $TEST" >&2; exit 2; }
# Absolutize muxm — the harness cds into a tmp dir before invoking it.
MUXM="$(cd "$(dirname -- "$MUXM")" && pwd)/$(basename -- "$MUXM")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/muxm-perturb.XXXXXXXX")" || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

declare -i PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  %s✅ %s%s\n' "$GREEN"  "$1" "$NC"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s❌ %s%s\n' "$RED"    "$1" "$NC"; }

# _named_test_failed OUTPUT SIGNATURE — true iff SIGNATURE appears in a FAIL line of OUTPUT.
# "FAIL:" marks ❌ lines (pass lines say "PASS:", the summary says "Failed:"), so this keys on
# the specific failing test, not a bare nonzero suite exit.
# `-- "$2"` so a signature that starts with "--" (e.g. "--sdr-force-10bit…") isn't parsed as a flag.
_named_test_failed() { printf '%s\n' "$1" | grep 'FAIL:' | grep -qF -- "$2"; }

# enforce ID SUITE 'SEDPROG' 'FAIL_SIGNATURE' 'note'
enforce() {
  local id="$1" suite="$2" sedprog="$3" sig="$4" note="$5"
  local copy="$WORK/muxm.$id" out nchanged
  cp "$MUXM" "$copy"
  # `sed >tmp; mv` drops the execute bit (the redirect makes a fresh non-exec file), and the
  # harness invokes muxm directly — so re-assert +x or every mutated run dies "permission denied".
  sed "$sedprog" "$copy" > "$copy.m" && mv "$copy.m" "$copy" && chmod +x "$copy"
  nchanged="$(diff "$MUXM" "$copy" | grep -c '^>')"
  if [[ "$nchanged" != "1" ]]; then
    bad "$id [$suite]: mutation changed $nchanged line(s), expected exactly 1 — anchor drifted. sed: $sedprog"
    return
  fi
  # (1) red under mutation
  out="$(bash "$TEST" --muxm "$copy" --suite "$suite" 2>&1)"
  if ! _named_test_failed "$out" "$sig"; then
    bad "$id [$suite]: mutation applied but the named test did NOT go red (sig: '$sig') — that test cannot detect this break"
    return
  fi
  # (2) green when reverted (run the clean muxm). AFFIRMATIVELY confirm the clean run completed
  # before concluding "green": a crashed / OOM-killed / empty clean-harness run emits no FAIL line
  # either, so inferring success from a missing FAIL alone would report a false GREEN — the one
  # outcome an acceptance gate must never produce. test_muxm.sh always prints a "Test Summary"
  # block when it runs to completion; its absence means the harness did not finish.
  out="$(bash "$TEST" --muxm "$MUXM" --suite "$suite" 2>&1)"
  if ! grep -q 'Test Summary' <<<"$out"; then
    bad "$id [$suite]: CLEAN muxm run did not complete (no 'Test Summary') — cannot confirm green; harness/setup error?"
    return
  fi
  if _named_test_failed "$out" "$sig"; then
    bad "$id [$suite]: named test also fails on CLEAN muxm (sig: '$sig') — guard is not specific to the mutation"
    return
  fi
  ok "$id [$suite]: red-under-mutation, green-when-reverted — '$sig' ($note)"
}

# pending ID SUITE 'note'

printf '%s%sperturb_check — acceptance gate%s  (muxm: %s)\n\n' "$BOLD" "$GREEN" "$NC" "$MUXM"
printf '%sEnforced mutations (must go red today):%s\n' "$BOLD" "$NC"

# ---- ENFORCED: a named test goes red today and must stay that way --------------------------
# M-VID-1 (P3): force 8-bit even with --sdr-force-10bit. Anchor on the SDR_FORCE_10BIT arm so
# only that tgt_pix line changes (the next, SDR_USE_10BIT_IF_SRC_10BIT arm, is identical text).
enforce MUT-VID-10BIT video \
  '/if (( SDR_FORCE_10BIT )); then/{n;s/tgt_pix="yuv420p10le"/tgt_pix="yuv420p"/;}' \
  '--sdr-force-10bit: 8-bit SDR source encoded as 10-bit' \
  'M-VID-1: force-10bit-arm pixfmt probe'

# M-AUD-2 (P1b): invert codec-preference rank so worse codecs score higher. '(10 - rank)' is
# unique in muxm, so a bare substitution hits exactly the inv= line in _score_audio_stream.
enforce MUT-AUD-INV-audio audio \
  's/(10 - rank)/rank/' \
  'Lossless-vs-lossy: expected track #0' \
  'M-AUD-2: codec-rank inversion caught by FLAC-vs-AC3 selection'

# M-HDR-1 is deferred: no working assertion-only mutation exists (no new fixtures). muxm's output
# color tags track the SOURCE via ffmpeg's auto-copy; the COLOR_ARGS do NOT observably override
# them — dropping, overriding-to-bt709, and force-HDR-detect ALL leave the probed output tags
# unchanged. A non-tautological HDR-metadata test needs a master-display/MaxCLL fixture +
# frame_side_data probe, which is where M-HDR-2 already lives.
#

# M-SUB-1: make _parse_ext_sub_filename treat the `.forced.` infix as a full sub, so
# the forced sidecar no longer gets disposition.forced=1. The rebuilt ext_forced test probes the
# actual forced disposition (not just "a sub exists"), so it goes red.
enforce MUT-SUB-1 ext_subs \
  's/forced|signs|foreign) stype="forced"/forced|signs|foreign) stype="full"/' \
  'ext_forced: expected ≥1 sub with disposition.forced=1' \
  'M-SUB-1: external forced-sidecar disposition probe'

# M-SII-1: force check_skip_if_ideal's final `if (( ideal ))` decision always-true
# (anchored on the unique "Build validated stream keep-lists" comment so only that arm changes,
# not the identical line earlier in the function). The non-compliant source is then wrongly
# skipped/copied (stays H.264) instead of re-encoded → the non-compliant re-encode probe fails.
enforce MUT-SII-1 output \
  '/if (( ideal )); then/{N;/Build validated stream keep-lists/s/if (( ideal )); then/if (( 1 )); then/;}' \
  'skip-if-ideal non-compliant: re-encoded H.264 → HEVC' \
  'M-SII-1: check_skip_if_ideal always-ideal → non-compliant must-re-encode probe'

# MUT-SII-MOV (C1): invert the mov) arm's source-container guard (!= → ==) in
# check_skip_if_ideal, so a copy-compliant non-.mov source requested as .mov is again judged
# ideal and false-skipped (the C1 defect). Anchored on the unique `!= "mov"` (the mp4/m4v/mkv
# arms test their own extensions), so exactly the mov) guard changes. The new skip-if-ideal+.mov
# probe asserts the source is NOT skipped and the output is a real MOV → under the mutation it is
# skipped (and raw-hardlinked to Matroska-in-.mov) → red.
# shellcheck disable=SC2016  # $src_ext is literal sed text — it must NOT expand in this shell.
enforce MUT-SII-MOV output \
  's/!= "mov"/== "mov"/' \
  'skip-if-ideal mov: compliant .mkv was wrongly skipped' \
  'M-SII-MOV: check_skip_if_ideal mov) container arm → false-skip mislabel probe'

# MUT-C2-MTLANG (C2): revert the multi-track audio populate site in
# run_audio_pipeline_multi from the non-collapsing _split_tab back to the collapsing
# `IFS=$'\t' read`. For an untagged-language track the empty middle field then collapses and the
# bitrate shifts into `lang`, so AUDIO_MT_LANGS carries the bitrate and mux_final stamps a bogus
# `language=<digits>` on the output. Anchored on that site's UNIQUE inline comment ("…untagged
# lang/title into MT output metadata"), so exactly the output-corrupting site reverts (the scorer
# and keep-list `_split_tab "$info" …` lines, identical but for their comment, are untouched). The
# untagged-track probe asserts a:1 is NOT a numeric language → under the mutation it is → red.
# shellcheck disable=SC2016  # $info / $'\t' are literal sed text — they must NOT expand in this shell.
enforce MUT-C2-MTLANG audio \
  's|_split_tab "$info" codec ch lang br title  # Non-collapsing split — untagged lang/title into MT output metadata|IFS=$'"'"'\t'"'"' read -r codec ch lang br title <<< "$info"|' \
  'audio-untagged-lang multi-track: untagged track a:1 has garbage numeric language' \
  'M-C2-MTLANG: run_audio_pipeline_multi non-collapsing split → untagged-language output-metadata probe'

# MUT-C2-CSAFETY (C2 follow-up): revert the audio-record split in _check_multitrack_container_safety
# to the collapsing `IFS=$'\t' read`. An untagged-language commentary track then loses its title,
# so _audio_is_commentary misses it and the track is wrongly counted as a kept lossless stream →
# muxm die-11s the MP4 encode it should have accepted. Anchored on that site's unique inline
# comment. The container-safety probe (untagged TrueHD commentary → MP4 must succeed) goes red.
# shellcheck disable=SC2016  # $_info / $'\t' are literal sed text — they must NOT expand here.
enforce MUT-C2-CSAFETY audio \
  's|_split_tab "$_info" _codec _ch _lang _br _title  # Non-collapsing split — keep-filter mirrors _build_audio_keep_list|IFS=$'"'"'\t'"'"' read -r _codec _ch _lang _br _title <<< "$_info"|' \
  'audio-container-safety container-safety: MP4 encode wrongly blocked' \
  'M-C2-CSAFETY: _check_multitrack_container_safety non-collapsing split → untagged-commentary keep-filter probe'

# MUT-C2-VERIFY (C2 follow-up): revert the per-record split in mux_final's post-encode "Audio :"
# verify summary to a collapsing read. A track with an empty bit_rate field (e.g. FLAC) then shifts
# its channel_layout into the title slot, so the verify line shows the layout instead of the title.
# Anchored on the unique `_split_tab "$_a_rec" …` line. The verify-display probe goes red.
# shellcheck disable=SC2016  # $_a_rec / $'\t' are literal sed text — they must NOT expand here.
enforce MUT-C2-VERIFY audio \
  's|_split_tab "$_a_rec" a_codec a_ch a_lang a_br a_title a_layout|IFS=$'"'"'\t'"'"' read -r a_codec a_ch a_lang a_br a_title a_layout <<< "$_a_rec"|' \
  'audio-verify-display verify-display: verify Audio line lost the title' \
  'M-C2-VERIFY: mux_final verify-summary non-collapsing split → empty-bitrate title-shift probe'

# MUT-C2-SUBCLASS (C2 follow-up): revert the subtitle-record split in merge_subtitle_sources to the
# collapsing `IFS=$'\t' read`. An UNTAGGED-language subtitle's empty middle (lang) field then
# collapses, shifting title→lang and forced→title, so `(( forced ))` reads the wrong field and an
# untagged forced subtitle is mis-stored (language="<title>") and mis-classified "full". Anchored on
# that site's full inline-commented line (merge_subtitle_sources is now the sole consumer of this
# parse — the prefix-identical describe_sub_stream helper was dead code and has been removed). The
# untagged-forced scan probe goes red.
# shellcheck disable=SC2016  # $info / $'\t' are literal sed text — they must NOT expand here.
enforce MUT-C2-SUBCLASS subs \
  's|_split_tab "$info" codec lang title forced hi  # Non-collapsing split — empty lang/title must not shift forced/hi (sub classification)|IFS=$'"'"'\t'"'"' read -r codec lang title forced hi <<< "$info"|' \
  'subs-untagged-forced-classification sub-classify: untagged forced subtitle misclassified' \
  'M-C2-SUBCLASS: merge_subtitle_sources non-collapsing split → untagged-forced classification probe'

# MUT-H2-REEMBED (H2): revert build_subtitle_plan's direct-map fallback guard to its old
# "nothing EMBEDDED" form by neutering the two added "nothing PREPARED" clauses (collapse them to
# `true`). On the universal profile (burn + export) the embed vars are empty even though subs were
# prepared, so the reverted guard fires the fallback and re-embeds a contradictory soft mov_text
# track. Both clauses are reverted as a unit (in universal each alone still suppresses the fallback,
# so neutering only one would not reintroduce the re-embed). The H2 negative probe goes red.
# shellcheck disable=SC2016  # $SRT_FORCED_BURN_PATH / ${#EXTERNAL_SRT_PATHS[@]} are literal sed text.
enforce MUT-H2-REEMBED subs \
  's|\[\[ -z "$SRT_FORCED_BURN_PATH" \]\] && (( ${#EXTERNAL_SRT_PATHS\[@\]} == 0 ))|true|' \
  'subs-universal-no-reembed: universal re-embedded a soft subtitle' \
  'M-H2-REEMBED: build_subtitle_plan fallback gates on "nothing prepared" → universal no-reembed probe'

# MUT-H3-SORTZ (H3): flip discover_external_subtitles' portable-sort FALLBACK from `cat`
# back to GNU-only `sort -z`. On a sort without -z (the test shims a BSD sort on PATH) the probe
# fails, the else-branch is taken, and `find … | sort -z` then errors → empty → every sidecar is
# silently dropped. The BSD-sort discovery probe goes red.
# shellcheck disable=SC2016  # literal sed text.
enforce MUT-H3-SORTZ ext_subs \
  's|_sub_sort=( cat )|_sub_sort=( sort -z )|' \
  'extsub-bsd-sort-discovery: external sidecar NOT discovered under BSD sort' \
  'M-H3-SORTZ: discover_external_subtitles portable-sort fallback → BSD-sort sidecar-discovery probe'

# MUT-M1-DASHDASH (M1): revert the `--` end-of-options handler to the old drop-positionals
# form. `muxm -- <src>` then loses its source and falls through to usage/help instead of a plan.
# shellcheck disable=SC2016  # $@ is literal sed text.
enforce MUT-M1-DASHDASH cli \
  's/    --) shift; POSITIONALS+=("$@"); break ;;.*/    --) shift; break ;;/' \
  "cli-dashdash-source-resolution: '--' dropped the source positional" \
  'M-M1-DASHDASH: `--` folds remaining args into POSITIONALS → end-of-options source-resolution probe'

# MUT-M2-CLEANUP (M2): revert the guarded checksum call to a bare `&& write_checksum`.
# A failed checksum (last cmd of the && list) then trips `set -e` and aborts on_exit mid-way,
# skipping the workdir cleanup → the workdir leaks. (The ERR-disarm alone does NOT prevent this —
# set -e exits regardless; the guard is the real fix.) The leak probe goes red.
# shellcheck disable=SC2016  # $OUT is literal sed text.
enforce MUT-M2-CLEANUP output \
  's#{ write_checksum "$OUT" || warn "Could not write the checksum file for $OUT."; }#write_checksum "$OUT"#' \
  'output-cleanup-on-checksum-fail: failed checksum leaked the workdir' \
  'M-M2-CLEANUP: guarded final checksum keeps set -e from aborting on_exit → no-workdir-leak probe'

# MUT-M3-REGISTER (M3): drop one DV child registration (inject_pid) so it is launched but
# never recorded in _ACTIVE_FFMPEG_PID — on Ctrl-C on_exit cannot SIGKILL it (orphan). The
# structural registration invariant goes red.
# shellcheck disable=SC2016  # $inject_pid is literal sed text.
enforce MUT-M3-REGISTER unit \
  's/_ACTIVE_FFMPEG_PID=\$inject_pid.*/: # mutated/' \
  'unit-ffmpeg-pid-lifecycle: backgrounded heavy child(ren) not registered' \
  'M-M3-REGISTER: every backgrounded heavy child registers _ACTIVE_FFMPEG_PID → orphan-on-Ctrl-C probe'

# MUT-M3-CLEARWAIT (M3): reorder one OCR site to clear _ACTIVE_FFMPEG_PID BEFORE its wait.
# A SIGINT in that window orphans the OCR child (which may hold the tee write-end and hang the
# drain). The structural clear-after-wait invariant goes red.
# shellcheck disable=SC2016  # $ocr_sup_pid is literal sed text.
enforce MUT-M3-CLEARWAIT unit \
  's@wait "$ocr_sup_pid" 2>/dev/null || true; _ACTIVE_FFMPEG_PID=""@_ACTIVE_FFMPEG_PID=""; wait "$ocr_sup_pid" 2>/dev/null || true@' \
  'unit-ffmpeg-pid-lifecycle: clear-before-wait at:' \
  'M-M3-CLEARWAIT: _ACTIVE_FFMPEG_PID cleared only AFTER wait → orphan-during-wait-window probe'

# MUT-M4-SUMMARY (M4): revert the guarded _ensure_ffmpeg_full call to bare. Its return-1
# (failed ffmpeg-full install) then aborts the installer under set -e before the summary prints.
enforce MUT-M4-SUMMARY setup \
  's/_ensure_ffmpeg_full || true/_ensure_ffmpeg_full/' \
  'setup-install-deps-summary-on-failure: installer aborted before the summary' \
  'M-M4-SUMMARY: guarded _ensure_ffmpeg_full call → installer-summary-still-prints probe'

# MUT-M5-UNBOUND (M5): revert the --crf config-override arm to the raw unchecked index
# read. A trailing `--crf` (no value) then crashes under set -u (unbound variable) instead of a
# clean die 11. Anchored on the --crf arm so only it reverts.
# shellcheck disable=SC2016  # ${_cc_override_argv[...]} is literal sed text.
enforce MUT-M5-UNBOUND cli \
  's#--crf)\(  *\)_cc_need_val;#--crf)\1_cc_val="${_cc_override_argv[$((_cc_oi+1))]}";#' \
  'cli-config-missing-value: --create-config with a trailing --crf (missing value)' \
  'M-M5-UNBOUND: _cc_need_val bounds-checks config-override values → clean-die-11 probe'

# MUT-M6-EOF (M6): drop the `|| _confirm=""` EOF guard on the replace-source prompt. A
# non-interactive stdin (EOF) then makes `read` fail and crash under set -e instead of a clean
# die 11 decline.
# shellcheck disable=SC2016  # _confirm is literal sed text.
enforce MUT-M6-EOF cli \
  's/  read -r _confirm || _confirm="".*/  read -r _confirm/' \
  'cli-replace-source-eof: REPLACE_SOURCE + EOF stdin → expected die 11' \
  'M-M6-EOF: read EOF treated as decline → clean-die-11-not-crash probe'

# MUT-M7-BRIDGE (M7): make the deprecation bridge's guard always-true (compare the new var
# to itself), reverting to the unconditional overwrite. With BOTH set in config the legacy value
# then wins over the explicitly-set new value → the M7 both-set probe goes red.
# shellcheck disable=SC2016  # the variable refs are literal sed text.
enforce MUT-M7-BRIDGE config \
  's#== "${_MUXM_PRE_CONFIG\[AUDIO_SCORE_LANG_BONUS\]}"#== "$AUDIO_SCORE_LANG_BONUS"#' \
  'config-deprecation-bridge: both set → expected AUDIO_SCORE_LANG_BONUS=200' \
  'M-M7-BRIDGE: deprecation bridge applies legacy only when new is unset → new-wins probe'

# MUT-M8-FALLBACK (M8): drop the pipx <1.0 fallback line in _pipx_resolve_bin_dir. Under
# the old-pipx shim (no `environment --value`) the helper then returns empty → the M8 unit probe red.
# shellcheck disable=SC2016  # $_d / pipx text is literal sed text.
enforce MUT-M8-FALLBACK unit \
  's@  \[\[ -z "$_d" \]\] && _d="$(pipx environment.*@  :@' \
  'unit-pipx-bin-dir-fallback: _pipx_resolve_bin_dir returned' \
  'M-M8-FALLBACK: pipx <1.0 environment-dump fallback → bin-dir-resolution probe'

# MUT-MDRYA-PROBE (M-DRY-a): break _dv_probe_has_config_record's grep (always false).
# Anchored on the helper's "$_probe" so only the helper changes (verify_dv_container_record's
# "$out_probe" grep is untouched). The DV-probe unit positive case goes red.
# shellcheck disable=SC2016  # $_probe / $DV_CONTAINER_PATTERN are literal sed text.
enforce MUT-MDRYA-PROBE unit \
  's/printf .*"$_probe" | grep -qiE "$DV_CONTAINER_PATTERN"/false/' \
  'unit-dv-config-record-probe: helper failed to detect a present DOVI configuration record' \
  'M-MDRYA-PROBE: _dv_probe_has_config_record probe+grep → DV-record-detection probe'

# MUT-MDRYC-DRIFT (M-DRY-c): inject a bogus value into _VALID_LOGLEVEL_STR so it diverges
# from is_valid_loglevel's case set (invalid entry + count mismatch). The loglevel drift guard red.
enforce MUT-MDRYC-DRIFT unit \
  's/, trace"/, bogus, trace"/' \
  'unit-loglevel-drift-guard: _VALID_LOGLEVEL_STR drifted from is_valid_loglevel' \
  'M-MDRYC-DRIFT: _VALID_LOGLEVEL_STR ↔ is_valid_loglevel sync → loglevel drift-guard probe'

# MUT-L-FORCEAAC: revert the force-AAC bitrate to a hardcoded 256k, ignoring
# STEREO_BITRATE. The forced-AAC probe (STEREO_BITRATE=96k) then logs bitrate=256k → red.
# shellcheck disable=SC2016  # $STEREO_BITRATE is literal sed text.
enforce MUT-L-FORCEAAC audio \
  's/tgt_br="$STEREO_BITRATE"/tgt_br="256k"/' \
  'audio-forceaac-stereo-bitrate: forced-AAC bitrate ignored STEREO_BITRATE' \
  'M-L-FORCEAAC: force-AAC honors STEREO_BITRATE → no-hardcoded-256k probe'

# MUT-L-DISKNOTE: drop the disk-preflight "df unavailable" else-note so the preflight
# fails open silently again when df yields nothing. The df-unavailable note probe goes red.
enforce MUT-L-DISKNOTE unit \
  's/note "Disk preflight skipped.*/: # mutated/' \
  "unit-disk-preflight-note: no 'preflight skipped' note" \
  'M-L-DISKNOTE: df-unavailable emits an explicit skipped-note → no-silent-fail-open probe'

# MUT-L-SUBWD: revert _prepare_subtitle's vanished-workdir path to `return 1`, which trips
# set -e at the `sub_path="$(...)"` callers. The unit probe expects rc0+empty → rc1 → red. Anchored
# two lines below the unique "Workdir disappeared" warn.
enforce MUT-L-SUBWD unit \
  '/Workdir disappeared/{n;n;s/    return 0/    return 1/;}' \
  'unit-prepare-subtitle-workdir-gone: vanished-workdir path returned' \
  'M-L-SUBWD: _prepare_subtitle workdir-gone returns ""+rc0 → no-set-e-abort probe'

# MUT-L-CCESCAPE: neuter the _V quoted-value escaping so an embedded " in a --create-config
# override corrupts the generated .muxmrc on round-trip. The cc-escape round-trip probe goes red.
# shellcheck disable=SC2016  # ${qval//…} is literal sed text.
enforce MUT-L-CCESCAPE config \
  's#qval="${qval//.*#:#' \
  'config-create-config-escaping: override value corrupted on round-trip' \
  'M-L-CCESCAPE: --create-config %q-escapes emitted values → faithful-round-trip probe'

# M-AUD-1: the same '(10 - rank)' inversion, now caught by the new
# direct _score_audio_stream unit test. The ch<6 scenario keeps this signature distinct from
# M-AUD-3 (surround only applies at ≥6ch).
enforce MUT-AUD-INV-unit unit \
  's/(10 - rank)/rank/' \
  'unit-score-audio-stream score: eac3 2ch eng 448k' \
  'M-AUD-1: codec-rank inversion caught by the _score_audio_stream oracle'

# M-AUD-3: zero the surround-bonus default. The unit test SOURCES the
# muxm default (not an injected value), so the surround-isolation
# assertion (6ch−5ch) diverges. The rank cancels in that difference, so M-AUD-1 does NOT flip it.
enforce MUT-AUD-SURROUND unit \
  's/AUDIO_SCORE_SURROUND_BONUS=30/AUDIO_SCORE_SURROUND_BONUS=0/' \
  'unit-score-audio-stream surround: bonus at >=6ch' \
  'M-AUD-3: surround-bonus default caught by the surround-isolation assertion'

# 2.2: make the --audio-track override unconditional by widening the range check, so
# an out-of-range override is wrongly honored instead of falling back to auto-selection. The new
# select_best_audio unit test asserts the invalid-override case auto-selects (idx 1), so it goes red.
enforce MUT-AUD-OVERRIDE unit \
  's/AUDIO_TRACK_OVERRIDE < n/AUDIO_TRACK_OVERRIDE < 9999/' \
  'unit-select-best-audio select: invalid --audio-track 5 → auto-selection fallback' \
  '2.2: override range-guard widened → invalid override no longer falls back'

# M-TM-1: collapse the tonemap arm's PROFILE from "SDR-TONEMAP" to "SDR". The new
# decide_color_and_pixfmt unit test asserts PROFILE_DESC=SDR-TONEMAP for the tonemap scenario,
# so that one scenario diverges (the others, which never set SDR-TONEMAP, stay green).
enforce MUT-TM-1 unit \
  's/profile="SDR-TONEMAP"/profile="SDR"/' \
  'unit-decide-color-and-pixfmt color: tonemap HDR→SDR' \
  'M-TM-1: tonemap PROFILE label caught by decide_color_and_pixfmt unit test'

# M-TM-2 — the tonemap arm needs two DIFFERENT mutations: one for the unit label and one for the
# real-encode color probe. MUT-TM-1 above flips only
# the PROFILE_DESC *label* (`SDR-TONEMAP`→`SDR`); the bt709 COLOR_ARGS on the next line still run,
# so a real encode's output is still bt709-TAGGED (the tag probe can't catch the label mutation —
# the unit test does). MUT-TM-2 instead disables the SDR-tonemap arm's entry condition so it falls
# through to the HDR10 arm (bt2020/smpte2084 COLOR_ARGS, no tonemap filter), leaving the output
# HDR-tagged → the real-encode color probe goes red. Together the pair covers both surfaces.
# shellcheck disable=SC2016  # $prim is literal sed text — it must NOT expand in this shell.
enforce MUT-TM-2 hdr \
  's/if (( TONEMAP_HDR_TO_SDR )) && \[\[ "$prim" == "bt2020"/if (( 0 )) \&\& [[ "$prim" == "bt2020"/' \
  'tonemap real encode:' \
  'M-TM-2: SDR-tonemap arm output color tags caught by the real --tonemap encode probe'

# M-CHROMA-1: flip the SDR-path 4:2:2-preserve branch of decide_color_and_pixfmt to
# 4:2:0 (tgt_pix yuv422 → yuv420p), so a FORCE_CHROMA_420=0 encode wrongly downsamples. The
# real-encode chroma test asserts the FORCE_CHROMA_420=0 output is yuv422p (and the default arm is
# yuv420p, unaffected by this branch) → only the preserve assertion goes red.
# shellcheck disable=SC2016  # ${_cbit} is literal sed text — it must NOT expand in this shell.
enforce MUT-CHROMA-1 regression_p5 \
  's/422) tgt_pix="yuv422${_cbit}"/422) tgt_pix="yuv420p"/' \
  'regression-chroma-420-downsample real encode: FORCE_CHROMA_420=0' \
  'M-CHROMA-1: 4:2:2 chroma preserve decision caught by the real-encode pix_fmt probe'

# M-AVIFB-1: break the container-passthrough fallback default for unsupported source
# extensions (the `*) OUTPUT_EXT="mkv"` arm → "mp4"). Anchored on the unique adjacent "not supported
# for output" notice (the N pulls it into the pattern space) so only the fallback arm changes, not
# the many profile `OUTPUT_EXT="mkv"` assignments. The real .avi passthrough encode then derives a
# .mp4 instead of .mkv → the matroska-container probe finds no .mkv → red. (The notice still fires,
# now naming .mp4, so the signature keys on the missing-.mkv-output assertion, not the notice.)
enforce MUT-AVIFB-1 containers \
  '/OUTPUT_EXT="mkv"/{N;/not supported for output/s/OUTPUT_EXT="mkv"/OUTPUT_EXT="mp4"/;}' \
  'passthrough fallback:' \
  'M-AVIFB-1: .avi→mkv container fallback caught by the real-encode format_name probe'

# M-VTPARAMS-1: change the hevc_videotoolbox container tag from hvc1 to hev1 in
# build_videotoolbox_params. The VT-params unit test asserts the 10-bit mp4 arg string carries
# `-tag:v hvc1`; under the mutation it carries hev1 → that assertion goes red (the 8-bit-mkv arm,
# which adds no tag, is unaffected). Pure param-builder check — no VT host needed.
enforce MUT-VTPARAMS-1 hw_accel \
  's/VIDEOTOOLBOX_ARGS+=( -tag:v hvc1 )/VIDEOTOOLBOX_ARGS+=( -tag:v hev1 )/' \
  'hw-vt-params VT params: hevc_videotoolbox mp4 10-bit' \
  'M-VTPARAMS-1: hevc_videotoolbox hvc1 tag caught by the build_videotoolbox_params unit test'

# M-NVENC-1: strip "NVENC" from resolve_video_encoder's software-fallback reason
# string. The NVENC-fallback unit test asserts the recorded reason names NVENC (so the user is
# told WHY hardware accel was disabled); under the mutation it no longer does → that assertion goes
# red (the companion "stays software libx265" assertion is unaffected). QSV/VAAPI rejection rides
# the existing is_valid_hw_accel validation (same path as --hw-accel bogus) — no dedicated mutation.
# Anchored on the unique nvenc-case reason string ("NVENC is not supported in this build; …").
enforce MUT-NVENC-1 hw_accel \
  's/NVENC is not supported in this build/Hardware acceleration is not supported in this build/' \
  'hw-accel-backend NVENC: software-fallback reason' \
  'M-NVENC-1: NVENC software-fallback contract caught by the resolve_video_encoder unit test'

# M-DVSW-1: corrupt the dovi_tool inject-rpu subcommand so RPU injection fails. With
# ALLOW_DV_FALLBACK=1 (default) muxm falls back to a non-DV encode (exit 0, output produced — NOT a
# die), so the failure mode is clean: the software DV round-trip's output carries no DOVI record →
# the dv_sw DV-record assertion goes red. The --crf re-encode forces the extract→inject path (a
# stream-copy would pass DV through via container copy), so the mutation genuinely bites. Anchored
# on `inject-rpu -i "$V_BASE"` (the comment at the inject site also contains "inject-rpu").
# shellcheck disable=SC2016  # $V_BASE is literal sed text — it must NOT expand in this shell.
enforce MUT-DVSW-1 dv_sw \
  's/dovi_tool inject-rpu -i "$V_BASE"/dovi_tool inject-rpu-BROKEN -i "$V_BASE"/' \
  'dv_sw: no Dolby Vision configuration record' \
  'M-DVSW-1: software DV RPU round-trip caught by the dv_sw DOVI-record probe'

# MUT-DVSW-CONVERT: break the `dovi_tool convert` subcommand so the P7→P8.1 conversion
# fails. With ALLOW_DV_FALLBACK=1 (default) the run falls back to non-DV base (exit 0, no die), so
# the convert-SUCCESS marker ("DV profile converted") never fires → the new P7→P8.1 convert-success
# probe goes red. Anchored on the unique `dovi_tool convert -i "$V_INJECTED"` invocation.
# shellcheck disable=SC2016  # $V_INJECTED is literal sed text — it must NOT expand in this shell.
enforce MUT-DVSW-CONVERT dv_sw \
  's/dovi_tool convert -i "$V_INJECTED"/dovi_tool convert-BROKEN -i "$V_INJECTED"/' \
  'dv_sw convert: convert-success marker missing' \
  'M-DVSW-CONVERT: real P7→P8.1 dovi_tool convert success path caught by the dv_sw convert probe'

# 2.4a: off-by-one the relidx returned by _pick_direct_text_sub_relidx (echo i+1 on
# the text-codec match). Anchored on the positive `if _is_text_sub_codec` (the keep-list uses the
# negated `! _is_text_sub_codec`), the `n` advances to the unique echo line. The picker test
# asserts idx 2; the empty-case scenario never reaches the inner echo, so only the picker flips.
# shellcheck disable=SC2016  # $codec/$i are literal sed text — they must NOT expand in this shell.
enforce MUT-SUB-RELIDX unit \
  '/if _is_text_sub_codec "$codec"; then/{n;s/echo "$i"/echo "$(( i + 1 ))"/;}' \
  'unit-build-subtitle-lists direct: picks first text sub matching lang' \
  '2.4a: direct-text-sub relidx off-by-one caught by _pick_direct_text_sub_relidx test'

# 2.4b: neuter the SUB_MAX_TRACKS cap by widening its threshold, so the keep list is
# never truncated. The new _build_subtitle_keep_list test caps 4→2; under the mutation it returns
# all four, so the cap scenario goes red (the under-cap scenarios are unaffected).
enforce MUT-SUB-MAXTRACKS unit \
  's/> SUB_MAX_TRACKS/> 9999/' \
  'unit-build-subtitle-lists keep: SUB_MAX_TRACKS caps 4→2' \
  '2.4b: SUB_MAX_TRACKS cap caught by _build_subtitle_keep_list test'

# M-REP-1: drop the _json_escape wrapper around the report_add VALUE ($2) so the raw
# argument is pushed into the JSON entry — a value containing a quote/backslash/newline then
# produces invalid JSON. The report_add escaping test feeds exactly such a value and asserts jq
# parses + round-trips, so it goes red. Anchored on the unique `_json_escape "$2"` (the key uses
# "$1"), so exactly the value-escape call changes.
# shellcheck disable=SC2016  # $(_json_escape "$2")/$2 are literal sed text — they must NOT expand here.
enforce MUT-REP-1 unit \
  's/$(_json_escape "$2")/$2/' \
  'unit-report-add-escaping report_add escaping' \
  'M-REP-1: report_add JSON-escaping caught by the jq round-trip test'

# M-DUR-1: break the tier-3 Matroska-DURATION parse in _get_source_duration_secs by
# collapsing the hours multiplier (10#$h * 3600 → * 60). The duration-tier-3 unit test asserts
# 01:02:03 → 3723s, which then diverges to 183s. The octal-safe (00:09:09, hours=0) and tier-1
# scenarios are unaffected — 0*anything is unchanged — so the signature stays isolated to the
# 3723s case (and the test proves tier 3 actually runs, not just tiers 1/2).
# shellcheck disable=SC2016  # $h is literal sed text — it must NOT expand in this shell.
enforce MUT-DUR-1 unit \
  's/10#$h \* 3600/10#$h \* 60/' \
  'unit-duration-tier3 duration tier-3: Matroska tag 01:02:03' \
  'M-DUR-1: tier-3 HH:MM:SS parse caught by the _get_source_duration_secs unit test'

# M-VCC-1: neuter the 10-bit-pixfmt copy-reject in _video_is_copy_compliant by
# inverting its source-pixfmt test — drop the negation in `[[ ! "$src_pix" =~ (p010le|p10|p12) ]]`
# so an 8-bit source is wrongly judged copyable for a 10-bit target. The copy-compliant unit test
# asserts that exact case (sdr-force 10-bit out vs 8-bit src) returns re-encode (rc 1, "need 10-bit"
# reason); under the mutation it returns copyable (rc 0) → red. The compliant / codec / tonemap /
# bitrate scenarios use an 8-bit (or matching) target, so `_output_pixfmt_is_10bit` is false there —
# only the 10-bit-ceiling scenarios flip. Anchored on the unique `! "$src_pix" =~`.
# shellcheck disable=SC2016  # $src_pix is literal sed text — it must NOT expand in this shell.
enforce MUT-VCC-1 unit \
  's/\[\[ ! "$src_pix" =~/[[ "$src_pix" =~/' \
  'unit-video-copy-compliant copy-compliant: 10-bit out (sdr-force) vs 8-bit src' \
  'M-VCC-1: 10-bit-pixfmt copy-reject caught by the _video_is_copy_compliant unit test'

# M-HDR-2 targets the warning path, not the output color params. muxm sets NO
# master-display/max-cll params; ffmpeg auto-forwards the source frame side-data to libx265
# irrespective of the x265-params string (even with none, even with color stripped), so an
# output-survival probe is tautological with no muxm lever — the same reason M-HDR-1 was deferred.
# The genuinely-mutable, previously-untested surface is the warning path: neuter the
# "missing HDR10 static metadata" gate in
# _check_hdr10_static_metadata (anchored on the unique "Source has DV but NO HDR10" warn line so
# only the warning arm — not the identical fallback gate — changes). The hdr10-static-metadata
# unit test's missing-source scenario then reports "partial", not "missing" → it goes red.
enforce MUT-HDR-2 unit \
  '/if (( ! has_mastering && ! has_cll )); then/{N;/Source has DV but NO HDR10/s/if (( ! has_mastering && ! has_cll )); then/if (( 0 )); then/;}' \
  'unit-hdr10-static-metadata hdr10-meta: neither present' \
  'M-HDR-2: HDR10 missing-static-metadata warning caught by the _check_hdr10_static_metadata unit test'

# M-OCR-1: make _prepare_subtitle's PGS branch skip OCR by forcing its
# `if (( ! SUB_ENABLE_OCR ))` gate always-true. Anchored on the unique "PGS subtitle #" warn line
# (the N pulls the following warn into the pattern space) so only the embedded-PGS gate flips, not
# the two identical external-PGS/VobSub gates later in the file. The OCR-dispatch unit test then
# sees neither a tool invocation nor a produced SRT track → both its assertions go red.
enforce MUT-OCR-1 unit \
  '/if (( ! SUB_ENABLE_OCR )); then/{N;/PGS subtitle #/s/if (( ! SUB_ENABLE_OCR )); then/if (( 1 )); then/;}' \
  'unit-ocr-dispatch OCR dispatch:' \
  'M-OCR-1: PGS OCR dispatch caught by the _prepare_subtitle unit test'

# M-BURN-1: turn the forced-subtitle burn filter into a no-op passthrough
# (subtitles=filename=burn.srt → null). The encode still succeeds and still produces output — it
# just stops burning text into the video — so the burn-in pixel test's two encodes become
# bit-identical in the subtitle band (y-PSNR jumps from ~21 dB to inf) and it goes red. `null` (not
# a broken filtergraph) is chosen so the failure mode is "no pixels changed", not "no output".
enforce MUT-BURN-1 subs \
  's/subtitles=filename=burn.srt/null/' \
  'subs-forced-burn-in burn-in:' \
  'M-BURN-1: forced-subtitle burn-in pixels caught by the band-PSNR test'

# ---- previously-unreached die/guard branches ------------------------------------------------
# (Already covered elsewhere, deliberately NOT re-added: --replace-source non-interactive die and
# the collision auto-version loop live in the collision suite; the catalog's "DISK_FREE_WARN_GB
# warning path" is stale — that code now die 11s, exercised by M-DISK-1 below.)

# M-DISK-1: invert disk_free_warn's cross-volume guard (`od_dev != wd_dev` → `==`) so
# the output-volume hard stop is skipped when WORKDIR and OUT_DIR are on different volumes — a
# branch no e2e test reaches. The disk-output-volume unit test mocks a full
# output volume on a separate device and asserts die 11; under the mutation no die fires → red.
# shellcheck disable=SC2016  # $od_dev/$wd_dev are literal sed text — they must NOT expand here.
enforce MUT-DISK-1 unit \
  's/"$od_dev" != "$wd_dev"/"$od_dev" == "$wd_dev"/' \
  'unit-disk-output-volume disk output-volume:' \
  'M-DISK-1: disk_free_warn output-volume die branch caught by the disk-output-volume unit test'

# M-CTRL-1: neuter the OUTPUT-filename control-char guard (its [[:cntrl:]] regex → a
# never-matching literal) so a tabbed output path is no longer rejected. Anchored on $OUT_ABS so
# the identical $SRC_ABS source-filename check (already tested) is untouched. The edge test then
# sees neither exit 11 nor the output-specific message → red.
# shellcheck disable=SC2016  # $OUT_ABS is literal sed text — it must NOT expand here.
enforce MUT-CTRL-1 edge \
  's/\$OUT_ABS" =~ \[\[:cntrl:\]\]/$OUT_ABS" =~ ZZZNEVER/' \
  'edge-output-control-char output control-char:' \
  'M-CTRL-1: output-filename control-char die caught by the edge-suite output-path test'

# M-VCC-2: neuter the MAX_COPY_BITRATE ceiling reject in _video_is_copy_compliant
# (`if (( src_br_bps > max_br_bps ))` → always-false) so an over-ceiling source is wrongly judged
# copyable. The copy-compliant unit test's bitrate-ceiling-exceeded scenarios then return copyable
# (rc 0) instead of re-encode → red. Distinct from M-VCC-1 (which targets the 10-bit-pixfmt reject).
enforce MUT-VCC-2 unit \
  's/if (( src_br_bps > max_br_bps )); then/if (( 0 )); then/' \
  'unit-video-copy-compliant copy-compliant: bitrate ceiling exceeded' \
  'M-VCC-2: MAX_COPY_BITRATE ceiling reject caught by the _video_is_copy_compliant unit test'

printf '\n%sEnforced: %d passed, %d failed.%s\n' "$BOLD" "$PASS" "$FAIL" "$NC"
if (( FAIL == 0 )); then
  printf '%s%sRESULT: PERTURBATION GATE GREEN%s\n' "$BOLD" "$GREEN" "$NC"; exit 0
else
  printf '%s%sRESULT: %d GATE(S) FAILED%s\n' "$BOLD" "$RED" "$FAIL" "$NC"; exit 1
fi
