#!/usr/bin/env bash
# =============================================================================
#  perturb_check.sh — perturbation catalog / acceptance gate for the hardened test suite
#
#  The "spine" of the test-remediation plan: it proves each hardened test can actually
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
#  remediation item.
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

# M-HDR-1 (Phase 1.2) is DEFERRED to Phase 3.1 — no working mutation exists within 1.2's
# "assertion-only, no new fixtures" scope. Empirically (verified during Phase 1.2) muxm's output
# color tags track the SOURCE via ffmpeg's auto-copy; the COLOR_ARGS the plan targets do NOT
# observably override them — dropping, overriding-to-bt709, and force-HDR-detect ALL leave the
# probed output tags unchanged. A non-tautological HDR-metadata test needs Phase 3.1's
# master-display/MaxCLL fixture + frame_side_data probe, which is where M-HDR-2 already lives.

# M-SUB-1 (Phase 1.4): make _parse_ext_sub_filename treat the `.forced.` infix as a full sub, so
# the forced sidecar no longer gets disposition.forced=1. The rebuilt ext_forced test probes the
# actual forced disposition (not just "a sub exists"), so it goes red.
enforce MUT-SUB-1 ext_subs \
  's/forced|signs|foreign) stype="forced"/forced|signs|foreign) stype="full"/' \
  'ext_forced: expected ≥1 sub with disposition.forced=1' \
  'M-SUB-1: external forced-sidecar disposition probe'

# M-SII-1 (Phase 1.6): force check_skip_if_ideal's final `if (( ideal ))` decision always-true
# (anchored on the unique "Build validated stream keep-lists" comment so only that arm changes,
# not the identical line earlier in the function). The non-compliant source is then wrongly
# skipped/copied (stays H.264) instead of re-encoded → the non-compliant re-encode probe fails.
enforce MUT-SII-1 output \
  '/if (( ideal )); then/{N;/Build validated stream keep-lists/s/if (( ideal )); then/if (( 1 )); then/;}' \
  'skip-if-ideal non-compliant: re-encoded H.264 → HEVC' \
  'M-SII-1: check_skip_if_ideal always-ideal → non-compliant must-re-encode probe'

# M-AUD-1 (Phase 2.1 — was pending): the same '(10 - rank)' inversion, now caught by the new
# direct _score_audio_stream unit test. The ch<6 scenario keeps this signature distinct from
# M-AUD-3 (surround only applies at ≥6ch).
enforce MUT-AUD-INV-unit unit \
  's/(10 - rank)/rank/' \
  '2.1 score: eac3 2ch eng 448k' \
  'M-AUD-1: codec-rank inversion caught by the _score_audio_stream oracle'

# M-AUD-3 (Phase 2.1 — was pending): zero the surround-bonus default. The unit test SOURCES the
# muxm default (not an injected value — see its plan-vs-code note), so the surround-isolation
# assertion (6ch−5ch) diverges. The rank cancels in that difference, so M-AUD-1 does NOT flip it.
enforce MUT-AUD-SURROUND unit \
  's/AUDIO_SCORE_SURROUND_BONUS=30/AUDIO_SCORE_SURROUND_BONUS=0/' \
  '2.1 surround: bonus at >=6ch' \
  'M-AUD-3: surround-bonus default caught by the surround-isolation assertion'

# 2.2 (Phase 2.2): make the --audio-track override unconditional by widening the range check, so
# an out-of-range override is wrongly honored instead of falling back to auto-selection. The new
# select_best_audio unit test asserts the invalid-override case auto-selects (idx 1), so it goes red.
enforce MUT-AUD-OVERRIDE unit \
  's/AUDIO_TRACK_OVERRIDE < n/AUDIO_TRACK_OVERRIDE < 9999/' \
  '2.2 select: invalid --audio-track 5 → auto-selection fallback' \
  '2.2: override range-guard widened → invalid override no longer falls back'

# M-TM-1 (Phase 2.3): collapse the tonemap arm's PROFILE from "SDR-TONEMAP" to "SDR". The new
# decide_color_and_pixfmt unit test asserts PROFILE_DESC=SDR-TONEMAP for the tonemap scenario,
# so that one scenario diverges (the others, which never set SDR-TONEMAP, stay green).
enforce MUT-TM-1 unit \
  's/profile="SDR-TONEMAP"/profile="SDR"/' \
  '2.3 color: tonemap HDR→SDR' \
  'M-TM-1: tonemap PROFILE label caught by decide_color_and_pixfmt unit test'

# M-TM-2 (Phase 4.1) — the catalog's single "M-TM-1" row covers BOTH the Phase 2.3 unit label and
# the Phase 4.1 real-encode color probe, which need DIFFERENT mutations. MUT-TM-1 above flips only
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

# M-CHROMA-1 (Phase 4.2): flip the SDR-path 4:2:2-preserve branch of decide_color_and_pixfmt to
# 4:2:0 (tgt_pix yuv422 → yuv420p), so a FORCE_CHROMA_420=0 encode wrongly downsamples. The
# real-encode chroma test asserts the FORCE_CHROMA_420=0 output is yuv422p (and the default arm is
# yuv420p, unaffected by this branch) → only the preserve assertion goes red.
# shellcheck disable=SC2016  # ${_cbit} is literal sed text — it must NOT expand in this shell.
enforce MUT-CHROMA-1 regression_p5 \
  's/422) tgt_pix="yuv422${_cbit}"/422) tgt_pix="yuv420p"/' \
  'H8 real encode: FORCE_CHROMA_420=0' \
  'M-CHROMA-1: 4:2:2 chroma preserve decision caught by the real-encode pix_fmt probe'

# M-AVIFB-1 (Phase 4.3): break the container-passthrough fallback default for unsupported source
# extensions (the `*) OUTPUT_EXT="mkv"` arm → "mp4"). Anchored on the unique adjacent "not supported
# for output" notice (the N pulls it into the pattern space) so only the fallback arm changes, not
# the many profile `OUTPUT_EXT="mkv"` assignments. The real .avi passthrough encode then derives a
# .mp4 instead of .mkv → the matroska-container probe finds no .mkv → red. (The notice still fires,
# now naming .mp4, so the signature keys on the missing-.mkv-output assertion, not the notice.)
enforce MUT-AVIFB-1 containers \
  '/OUTPUT_EXT="mkv"/{N;/not supported for output/s/OUTPUT_EXT="mkv"/OUTPUT_EXT="mp4"/;}' \
  'passthrough fallback:' \
  'M-AVIFB-1: .avi→mkv container fallback caught by the real-encode format_name probe'

# M-VTPARAMS-1 (Phase 5.3): change the hevc_videotoolbox container tag from hvc1 to hev1 in
# build_videotoolbox_params. The VT-params unit test asserts the 10-bit mp4 arg string carries
# `-tag:v hvc1`; under the mutation it carries hev1 → that assertion goes red (the 8-bit-mkv arm,
# which adds no tag, is unaffected). Pure param-builder check — no VT host needed.
enforce MUT-VTPARAMS-1 hw_accel \
  's/VIDEOTOOLBOX_ARGS+=( -tag:v hvc1 )/VIDEOTOOLBOX_ARGS+=( -tag:v hev1 )/' \
  '5.3 VT params: hevc_videotoolbox mp4 10-bit' \
  'M-VTPARAMS-1: hevc_videotoolbox hvc1 tag caught by the build_videotoolbox_params unit test'

# M-NVENC-1 (Phase 5.2): strip "NVENC" from resolve_video_encoder's software-fallback reason
# string. The NVENC-fallback unit test asserts the recorded reason names NVENC (so the user is
# told WHY hardware accel was disabled); under the mutation it no longer does → that assertion goes
# red (the companion "stays software libx265" assertion is unaffected). QSV/VAAPI rejection rides
# the existing is_valid_hw_accel validation (same path as --hw-accel bogus) — no dedicated mutation.
enforce MUT-NVENC-1 hw_accel \
  's/NVENC encoder dispatch not yet implemented/HW-accel dispatch not yet implemented/' \
  '5.2 NVENC: software-fallback reason' \
  'M-NVENC-1: NVENC software-fallback contract caught by the resolve_video_encoder unit test'

# M-DVSW-1 (Phase 5.1): corrupt the dovi_tool inject-rpu subcommand so RPU injection fails. With
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

# 2.4a (Phase 2.4): off-by-one the relidx returned by _pick_direct_text_sub_relidx (echo i+1 on
# the text-codec match). Anchored on the positive `if _is_text_sub_codec` (the keep-list uses the
# negated `! _is_text_sub_codec`), the `n` advances to the unique echo line. The picker test
# asserts idx 2; the empty-case scenario never reaches the inner echo, so only the picker flips.
# shellcheck disable=SC2016  # $codec/$i are literal sed text — they must NOT expand in this shell.
enforce MUT-SUB-RELIDX unit \
  '/if _is_text_sub_codec "$codec"; then/{n;s/echo "$i"/echo "$(( i + 1 ))"/;}' \
  '2.4 direct: picks first text sub matching lang' \
  '2.4a: direct-text-sub relidx off-by-one caught by _pick_direct_text_sub_relidx test'

# 2.4b (Phase 2.4): neuter the SUB_MAX_TRACKS cap by widening its threshold, so the keep list is
# never truncated. The new _build_subtitle_keep_list test caps 4→2; under the mutation it returns
# all four, so the cap scenario goes red (the under-cap scenarios are unaffected).
enforce MUT-SUB-MAXTRACKS unit \
  's/> SUB_MAX_TRACKS/> 9999/' \
  '2.4 keep: SUB_MAX_TRACKS caps 4→2' \
  '2.4b: SUB_MAX_TRACKS cap caught by _build_subtitle_keep_list test'

# M-REP-1 (Phase 2.5): use the raw $2 instead of the escaped $val in report_add's JSON push, so a
# value containing a quote/backslash/newline produces invalid JSON. The new report_add escaping
# test feeds exactly such a value and asserts jq parses + round-trips, so it goes red.
# shellcheck disable=SC2016  # ${val}/${2} are literal sed text — they must NOT expand in this shell.
enforce MUT-REP-1 unit \
  's/${val}/${2}/' \
  '2.5 report_add escaping' \
  'M-REP-1: report_add JSON-escaping caught by the jq round-trip test'

# M-DUR-1 (Phase 3.4): break the tier-3 Matroska-DURATION parse in _get_source_duration_secs by
# collapsing the hours multiplier (10#$h * 3600 → * 60). The duration-tier-3 unit test asserts
# 01:02:03 → 3723s, which then diverges to 183s. The octal-safe (00:09:09, hours=0) and tier-1
# scenarios are unaffected — 0*anything is unchanged — so the signature stays isolated to the
# 3723s case (and the test proves tier 3 actually runs, not just tiers 1/2).
# shellcheck disable=SC2016  # $h is literal sed text — it must NOT expand in this shell.
enforce MUT-DUR-1 unit \
  's/10#$h \* 3600/10#$h \* 60/' \
  '3.4 duration tier-3: Matroska tag 01:02:03' \
  'M-DUR-1: tier-3 HH:MM:SS parse caught by the _get_source_duration_secs unit test'

# M-VCC-1 (Phase 3.5): neuter the 10-bit-pixfmt copy-reject in _video_is_copy_compliant by
# inverting its source-pixfmt test (`!= *p10*` → `== *p10*`), so an 8-bit source is wrongly judged
# copyable for a 10-bit target. The copy-compliant unit test asserts that exact case returns
# re-encode (rc 1, "pixel format" reason); under the mutation it returns copyable (rc 0) → red.
# The compliant / codec / tonemap / bitrate scenarios use an 8-bit (or matching) target, so the
# first half of the `&&` is false there — only the 10-bit-ceiling scenario flips.
enforce MUT-VCC-1 unit \
  's/!= \*"p10"\*/== *"p10"*/' \
  '3.5 copy-compliant: 10-bit pixfmt ceiling' \
  'M-VCC-1: 10-bit-pixfmt copy-reject caught by the _video_is_copy_compliant unit test'

# M-HDR-2 (Phase 3.1) — RE-POINTED off the catalog's original "drop master-display/max-cll x265
# params" framing. Verified during Phase 3.1: muxm sets NO master-display/max-cll params; ffmpeg
# auto-forwards the source frame side-data to libx265 irrespective of the x265-params string (even
# with none, even with color stripped), so an output-survival probe is tautological with no muxm
# lever — exactly the reason M-HDR-1 was deferred. The genuinely-mutable, previously-untested
# surface is the warning path: neuter the "missing HDR10 static metadata" gate in
# _check_hdr10_static_metadata (anchored on the unique "Source has DV but NO HDR10" warn line so
# only the warning arm — not the identical fallback gate — changes). The hdr10-static-metadata
# unit test's missing-source scenario then reports "partial", not "missing" → it goes red.
enforce MUT-HDR-2 unit \
  '/if (( ! has_mastering && ! has_cll )); then/{N;/Source has DV but NO HDR10/s/if (( ! has_mastering && ! has_cll )); then/if (( 0 )); then/;}' \
  '3.1 hdr10-meta: neither present' \
  'M-HDR-2: HDR10 missing-static-metadata warning caught by the _check_hdr10_static_metadata unit test'

# M-OCR-1 (Phase 3.2): make _prepare_subtitle's PGS branch skip OCR by forcing its
# `if (( ! SUB_ENABLE_OCR ))` gate always-true. Anchored on the unique "PGS subtitle #" warn line
# (the N pulls the following warn into the pattern space) so only the embedded-PGS gate flips, not
# the two identical external-PGS/VobSub gates later in the file. The OCR-dispatch unit test then
# sees neither a tool invocation nor a produced SRT track → both its assertions go red.
enforce MUT-OCR-1 unit \
  '/if (( ! SUB_ENABLE_OCR )); then/{N;/PGS subtitle #/s/if (( ! SUB_ENABLE_OCR )); then/if (( 1 )); then/;}' \
  '3.2 OCR dispatch:' \
  'M-OCR-1: PGS OCR dispatch caught by the _prepare_subtitle unit test'

# M-BURN-1 (Phase 3.3): turn the forced-subtitle burn filter into a no-op passthrough
# (subtitles=filename=burn.srt → null). The encode still succeeds and still produces output — it
# just stops burning text into the video — so the burn-in pixel test's two encodes become
# bit-identical in the subtitle band (y-PSNR jumps from ~21 dB to inf) and it goes red. `null` (not
# a broken filtergraph) is chosen so the failure mode is "no pixels changed", not "no output".
enforce MUT-BURN-1 subs \
  's/subtitles=filename=burn.srt/null/' \
  '3.3 burn-in:' \
  'M-BURN-1: forced-subtitle burn-in pixels caught by the band-PSNR test'

# ---- Phase 3.6: previously-unreached die/guard branches -------------------------------------
# (Already covered elsewhere, deliberately NOT re-added: --replace-source non-interactive die and
# the collision auto-version loop live in the collision suite; the catalog's "DISK_FREE_WARN_GB
# warning path" is stale — that code now die 11s, exercised by M-DISK-1 below.)

# M-DISK-1 (Phase 3.6): invert disk_free_warn's cross-volume guard (`od_dev != wd_dev` → `==`) so
# the output-volume hard stop is skipped when WORKDIR and OUT_DIR are on different volumes — the
# branch the review found no e2e test ever reaches. The disk-output-volume unit test mocks a full
# output volume on a separate device and asserts die 11; under the mutation no die fires → red.
# shellcheck disable=SC2016  # $od_dev/$wd_dev are literal sed text — they must NOT expand here.
enforce MUT-DISK-1 unit \
  's/"$od_dev" != "$wd_dev"/"$od_dev" == "$wd_dev"/' \
  '3.6 disk output-volume:' \
  'M-DISK-1: disk_free_warn output-volume die branch caught by the disk-output-volume unit test'

# M-CTRL-1 (Phase 3.6): neuter the OUTPUT-filename control-char guard (its [[:cntrl:]] regex → a
# never-matching literal) so a tabbed output path is no longer rejected. Anchored on $OUT_ABS so
# the identical $SRC_ABS source-filename check (already tested) is untouched. The edge test then
# sees neither exit 11 nor the output-specific message → red.
# shellcheck disable=SC2016  # $OUT_ABS is literal sed text — it must NOT expand here.
enforce MUT-CTRL-1 edge \
  's/\$OUT_ABS" =~ \[\[:cntrl:\]\]/$OUT_ABS" =~ ZZZNEVER/' \
  '3.6 output control-char:' \
  'M-CTRL-1: output-filename control-char die caught by the edge-suite output-path test'

# M-VCC-2 (Phase 3.6): neuter the MAX_COPY_BITRATE ceiling reject in _video_is_copy_compliant
# (`if (( src_br_bps > max_br_bps ))` → always-false) so an over-ceiling source is wrongly judged
# copyable. The copy-compliant unit test's bitrate-ceiling-exceeded scenarios then return copyable
# (rc 0) instead of re-encode → red. Distinct from M-VCC-1 (which targets the 10-bit-pixfmt reject).
enforce MUT-VCC-2 unit \
  's/if (( src_br_bps > max_br_bps )); then/if (( 0 )); then/' \
  '3.5 copy-compliant: bitrate ceiling exceeded' \
  'M-VCC-2: MAX_COPY_BITRATE ceiling reject caught by the _video_is_copy_compliant unit test'

printf '\n%sEnforced: %d passed, %d failed.%s\n' "$BOLD" "$PASS" "$FAIL" "$NC"
if (( FAIL == 0 )); then
  printf '%s%sRESULT: PERTURBATION GATE GREEN%s\n' "$BOLD" "$GREEN" "$NC"; exit 0
else
  printf '%s%sRESULT: %d GATE(S) FAILED%s\n' "$BOLD" "$RED" "$FAIL" "$NC"; exit 1
fi
