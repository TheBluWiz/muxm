# Changelog

All notable changes to MuxMaster will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com), and this project adheres to [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- **`atv-directplay-animation` and `youtube-upload` e2e test coverage** — Both profiles are now included in the `test_profile_e2e` matrix. Previously had zero end-to-end encode coverage; each entry validates container extension, video codec, and profile-specific properties (10-bit pixel format for `atv-directplay-animation`, H.264 + AAC for `youtube-upload`).
- **`--hw-accel-allow-sw` / `--no-hw-accel-allow-sw` toggle tests** — Added to `TOGGLE_CASES` in `test_toggles`; the flags were parsed by the CLI but absent from the toggle coverage suite.
- **`--sub-preserve-bitmap` / `--no-sub-preserve-bitmap` toggle tests** — Added to `TOGGLE_CASES` in `test_toggles` alongside the existing `--sub-preserve-format` pair.
- **`--x264-params` value-flag test** — Verifies that `X264_PARAMS_BASE` is set correctly in the effective config; the flag had toggle coverage in the config suite but no direct value assertion.
- **Hardware acceleration foundation (Phase 1)** — Plumbing for the upcoming VideoToolbox (v1.5.0) and NVENC (v1.6.0) backends. Introduces the `--hw-accel` CLI flag (and matching `HW_ACCEL` variable in `.muxmrc`) accepting `none`, `auto`, `videotoolbox`, or `nvenc`. Detection probes populate `HW_ACCEL_AVAILABLE` from `ffmpeg -encoders`; `auto` resolves to the best available backend. Compatibility gates identify incompatible combinations (Dolby Vision, `libaom-av1`, AV1 on VideoToolbox, pre-Ada NVENC for AV1) and fall back to software with a recorded reason. Explicit backends that aren't available fail fast with a precise error. No encode behavior changes yet: the existing software encoders remain in use.
- **`docs/HW_ACCEL.md`** — Architecture document describing the resolver flow, gates, and forward plan for Phase 2 (VideoToolbox calibration) and Phase 3 (NVENC calibration).
- **`hw_accel` test suite** (`tests/test_muxm.sh --suite hw_accel`) — Config-only regression coverage: CLI parsing, `.muxmrc` loading, CLI-over-rc precedence, rejection of invalid values, explicit-backend strict check, profile-level compatibility warnings, and `auto` resolution on platforms without hardware encoders.
- **Non-AAC native stereo regression tests** (`tests/test_muxm.sh --suite audio`) — Two new cases in `_test_audio_native_stereo` guard the dropped-stereo fix below: EAC3 5.1 + FLAC 2.0 → MKV, and EAC3 5.1 + AC3 2.0 → MP4. Unlike the existing native-stereo test (which used an AAC track and only asserted the `"Native stereo track found"` log line, emitted before the copy), these probe the actual output streams — asserting the stereo track survives (2 audio streams) with the expected channel count and stream-copied codec (`flac`/`ac3`). Verified to fail against the pre-fix binary (`got 1` stream) and pass after the fix. Documented as cases 136–137 in `docs/TESTING_PLAN.md`, which also backfills the previously-undocumented native-stereo cases 133–135.

### Changed

- **Forced subtitle burn-in narrowed to `universal` only** — `atv-directplay-hq`, `atv-directplay-animation`, and `youtube-upload` no longer burn forced subtitles by default. Forced foreign-dialogue subs are now soft (mov_text in MP4, native format in MKV). `universal` remains the only profile that burns by default. Any profile can opt in via `--sub-burn-forced`.
- **Stereo downmix fallback removed from all profiles except `universal`** — `hdr10-hq`, `atv-directplay-hq`, `atv-directplay-animation`, `streaming-hevc`, `av1-hq`, `streaming-av1`, and `animation` no longer add a second AAC stereo track when the primary is multichannel (`ADD_STEREO_IF_MULTICH=0`). Each profile now keeps the single best-scored audio track. `archive` is unchanged (multi-track copy). `universal` produces one stereo track — the best native 2ch track when present (new `AUDIO_PREFER_STEREO=1`), otherwise a downmix of the best-scored track via `MAX_AUDIO_CHANNELS=2`. Toggle with `--prefer-stereo` / `--no-prefer-stereo`. `youtube-upload` no longer force-downmixes or forces AAC — the best-scored track (surround allowed) is kept as the cleanest source for YouTube's server-side re-encode.
- **`--x265-params` test strengthened** — Previously only asserted encode success. Now captures the workdir log path from muxm output and greps for the custom param value (`aq-mode=4`) in the logged ffmpeg command, confirming the flag is forwarded to the encoder and not silently dropped.
- **`--video-copy-if-compliant` test now verifies the copy path** — The existing test passed `--preset ultrafast`, which sets `_CLI_PRESET_EXPLICIT=1` and always forces a re-encode, making the copy path unreachable. A second pass now runs with isolated `HOME` and no explicit CRF or preset, then asserts the "will copy directly from source" message appears in muxm output.
- **`--skip-video` assertion tightened** — Replaced a broad keyword grep (`skip|video|warn|error|cannot|invalid|disabled`) with `assert_exit 42` plus a check for the specific error message `"incompatible with producing a valid output file"`, matching muxm's documented exit code for this incompatible flag.

### Fixed

- **Native stereo fallback silently dropped for non-AAC source tracks** — When `ADD_STEREO_IF_MULTICH=1`, the primary track was surround, and a qualifying native stereo track was stream-copied (any codec into MKV; AAC/AC3/EAC3 into MP4/M4V/MOV), the copy targeted the hardcoded `audio_stereo.aac` intermediate. ffmpeg selects the muxer from the file extension, and the `.aac` (ADTS) muxer accepts only AAC — copying a FLAC, AC3, or EAC3 stereo track failed with `adts muxer supports only codec aac`, leaving a 0-byte file. muxm then warned and continued without the track, so the expected stereo track was missing from the output. The stream-copy path now derives the intermediate's extension from the native codec via `_audio_copy_ext` (matching how the primary track is named), so the copy succeeds and the stereo track is muxed in. The synthetic-downmix and native-transcode paths were unaffected (they always produce real AAC).

## [1.4.0] - 2026-04-11

### Added

- **Table of contents comment block** — 30-section TOC with line numbers added to the top of the script for navigability.
- **Clarifying comments** — Added at `.muxmrc` sourcing, cross-platform detection, error handling strategy, FD 3 lifecycle, and other key locations throughout the script.
- **`_check_disk_full()` helper** — Detects `ENOSPC` (disk-full) conditions in encode/mux failure output and surfaces a targeted error message.
- **`_repeat_char()` pure-bash helper** — Replaces the external `seq` dependency for character repetition.
- **`_normalize_codec_lang()`, `_log_dropped_tracks()`, `_source_label()`, `_check_filter_ideality()` DRY helpers** — Extracted repeated logic into named helpers to reduce duplication across pipeline paths.
- **Debug `jq` logging (`DEBUG=1`)** — When `DEBUG=1`, logs the jq filter, exit code, and first 300 characters of output for every jq invocation.
- **Post-install AV1 encoder advisory** — `--install-dependencies` now prints brew commands for AV1 encoders after ffmpeg installation.
- **Runtime validation for `libaom-av1` encoder selection** — Exits early with a clear error when `libaom-av1` is selected but not available in the installed ffmpeg build.
- **Two-step output verification in `_validate_media_file`** — Checks file existence first, then runs an ffprobe stream check, so each failure mode produces a distinct error.
- **`MAX_COPY_BITRATE` arithmetic guard** — Guards against non-numeric values before using `MAX_COPY_BITRATE` in arithmetic expressions.
- **`AUDIO_FORCE_BITRATE` variable and `--audio-force-bitrate` flag** — Sets a fixed bitrate for all non-lossless audio output (e.g., `AUDIO_FORCE_BITRATE="256k"`). Overrides codec-specific bitrate variables (`EAC3_BITRATE_5_1`, `EAC3_BITRATE_7_1`, `STEREO_BITRATE`) when set. Used by `streaming-av1` to pin Opus surround at 256k.
- **AV1 (SVT-AV1) codec support** — `--video-codec libsvt-av1` enables full AV1 pipeline integration: CRF, preset, encoder params, conflict detection, disk space estimation, and config generation. Companion CLI flags: `--av1-params STR`, `--av1-maxrate KBPS`, `--av1-bufsize KBPS`.
- **`--checksum-algo` flag** — Selects the checksum algorithm: `sha256`, `blake2b`, or `auto`. Specifying an algorithm implies `--checksum`; `auto` prefers `b2sum` and falls back to `sha256`.
- **BLAKE2b checksum support** — `write_checksum()` now dispatches to `b2sum` when selected, writing `.b2` sidecar files alongside the output. `auto` mode uses BLAKE2b when available.
- **`SUB_PRESERVE_BITMAP` flag** (default `1`) — Stream-copies PGS bitmap subtitles in MKV output instead of OCR'ing to text. Controlled via `--sub-preserve-bitmap` / `--no-sub-preserve-bitmap`. Backed by a new `_container_supports_bitmap_subs()` helper for container-aware subtitle handling.
- **`tools/av1_compare.sh`** — HEVC vs AV1 quality/size benchmarking script with optional VMAF scoring.
- **`docs/AV1_CALIBRATION.md`** — Documents the encode comparison methodology and CRF equivalence findings.
- **`av1-hq` profile** — High-quality AV1 encode via SVT-AV1: CRF 20, preset 6, MKV container, lossless audio passthrough, SHA-256 checksum enabled by default. Dolby Vision is auto-disabled (AV1 pipeline does not support DV muxing). `SVT_AV1_PARAMS_BASE` is emitted uncommented by `--create-config`.
- **`streaming-av1` profile** — AV1 streaming encode via SVT-AV1: CRF 30, preset 6, MP4 container, Opus audio at 192k with AAC stereo fallback. Targets modern clients with AV1 decode support (Fire TV Stick 4K Max, Chromecast with Google TV, web browsers). Strips DV; HDR10 preserved.

### Changed

- **Standardize blank-line output** — 132 `echo` calls used solely to print a blank line replaced with `printf '\n'`.
- **Rename `$p` variables** — Cryptic `$p` variables renamed to `$file_path` / `$sub_path` in `write_checksum` and `build_subtitle_plan` for clarity.
- **Guard-clause refactor** — `disk_free_warn`, `_video_is_copy_compliant`, `run_video_pipeline`, `run_audio_pipeline`, `build_subtitle_plan`, and `_ensure_ffmpeg_full` refactored to early-return guard-clause style.
- **Void-context arithmetic** — 70+ `$((...))` expressions used for their side-effects (no value captured) converted to `((...))` form.
- **Batch `jq` calls in `detect_dv_info`** — 4 sequential `jq` invocations merged into a single call, reducing subprocess overhead.
- **Associative-array cache for `_audio_codec_rank`** — Codec rank lookups are now O(1) via a pre-built associative array instead of a linear scan.
- **Cache `dovi_tool` availability at startup** — `command -v dovi_tool` is now checked once at startup and cached; repeated inline checks removed.
- **`streaming` renamed to `streaming-hevc`** — The existing HEVC streaming profile is now canonically named `streaming-hevc`. The old name `streaming` is retained as a deprecated backwards-compatible alias — existing scripts and `.muxmrc` files will continue to work but will log a deprecation notice.
- **Single-track subtitle mode preserves PGS bitmap subs** — When the output container supports bitmap subtitles (MKV), PGS tracks are stream-copied rather than OCR'd. OCR is used only when the container requires text subtitles (MP4) or the user explicitly disables preservation via `--no-sub-preserve-bitmap`.
- **`write_checksum()` rewritten with algorithm dispatch** — Supports BLAKE2b, SHA-256, and auto-detection in a unified function replacing the previous single-algorithm implementation.

### Fixed

- **`spinner()` false ERR trap killing encodes** — `(( i = (i+1) % 4 ))` evaluates to 0 (falsy) every fourth iteration when the index wraps to zero, returning exit code 1 and triggering the ERR trap under `set -eEuo pipefail`. Any encode step where the spinner ran in the main shell context (most visibly the final mux) would be killed with a spurious `Command failed` error. Fixed by using the assignment form `i=$(( (i+1) % 4 ))`, which always exits 0.
- **SHA-256 sidecar test skipping when `CHECKSUM_ALGO` is overridden via `.muxmrc`** — The `--checksum` encode test did not pass `--checksum-algo sha256` explicitly, so a `.muxmrc` that sets `CHECKSUM_ALGO=blake2b` caused the test to produce a `.b2` sidecar while looking for `.sha256`, silently skipping rather than failing. The algorithm flag is now passed explicitly.
- **Positive toggle tests passing trivially when `.muxmrc` pre-sets the value** — `--checksum`, `--skip-if-ideal`, `--sub-burn-forced`, and `--video-copy-if-compliant` were in the single-flag `TOGGLE_CASES` loop, where they passed even when the flag was broken because `~/.muxmrc` or the default profile already set those variables to `1`. Moved to explicit two-flag tests (`--no-X` followed by `--X`) that establish a known-zero baseline before asserting the positive flag takes effect.

- **`--help` and `--version` silently exiting** — `_prescan_args` used post-increment (`counter++`) from zero, which evaluates to `0` under `set -e` and triggered the ERR trap before the help/version output could print. Replaced with `counter=$(( counter + 1 ))`.
- **Post-increment bug in config-override parser** — The same `(( flag++ ))` from-zero pattern in the boolean config-override parser caused silent exits when a boolean flag appeared at argument position 0. Fixed with `$(( flag + 1 ))` assignment form.
- **`report_add` producing invalid JSON** — Values containing newlines, tabs, or carriage returns were written literally into the JSON string, producing unparseable output. Values are now escaped before insertion.
- **Deprecated aliases not normalized in comma-separated multi-profile lists** — Deprecated profile aliases (e.g., `dv-archival`) were not resolved when passed as part of a comma-separated `--profile` list (e.g., `dv-archival,streaming`), causing an unknown-profile error. Alias normalization now runs before per-profile validation.
- **False "DOVI record missing" warning when ffprobe failed** — When `ffprobe` itself failed (e.g., unsupported file), the empty output was being checked for a DOVI record, producing a spurious warning. The check is now skipped when ffprobe exits non-zero.
- **RPU copy failure silently swallowed** — Errors from the `dovi_tool` RPU copy step were not surfaced; a failed RPU copy would silently produce a corrupt or incomplete output. The failure is now detected and propagated as a fatal error.
- **SII remux/copy exit code silently discarded** — The exit code from the secondary-image-interleave remux and copy paths was not checked. Both paths now validate exit code and ffprobe the output before continuing.
- **`--install-dependencies` not verifying AV1 encoder after ffmpeg install** — After installing ffmpeg, `--install-dependencies` did not confirm that the installed build included an AV1 encoder, so a missing encoder would only surface at encode time. The post-install check now verifies AV1 encoder availability and prints an advisory if absent.
- **`libaom-av1` receiving wrong ffmpeg flags** — The encoder flag dispatch was passing `-svtav1-params` and `-preset` to `libaom-av1` encodes. `libaom-av1` uses `-aom-params` and `-cpu-used` instead; the dispatch now routes each flag set to the correct encoder.
- **Opus multichannel bitrate using EAC3 values in `streaming-av1`** — The surround audio pass for `streaming-av1` was pulling `EAC3_BITRATE_5_1` / `EAC3_BITRATE_7_1` instead of an Opus-appropriate bitrate. `streaming-av1` now sets `AUDIO_FORCE_BITRATE="256k"`, which the audio pipeline prefers over codec-specific variables when set.
- **Working file extension derived from encoder name instead of format** — Intermediate audio copy files were using the codec/encoder name (e.g., `libopus`) as the file extension instead of the container-appropriate format extension (e.g., `ogg`). The new `_audio_codec_ext()` helper maps encoder names to correct extensions, preventing "Unable to choose output format" errors for Opus and similar non-obvious codec/extension pairs.
- **`--create-config` profile variable detection** — Snapshot baseline now captures script defaults before config file loading, preventing values set in `.muxmrc` from masking profile-owned variables in the generated config.
- **`--checksum-algo` test assertions** — Moved from the boolean toggle array to explicit value-flag tests.

### Security

- **`_BURN_SRT_FILTER` temp file moved to `WORKDIR`** — The subtitle filter file was previously written to a PID-predictable `/tmp` path, making it vulnerable to symlink attacks. It is now created inside the mktemp-based `WORKDIR`, which is only accessible to the running process.

### Docs

- **`docs/config_profile.md` cross-references synced** — All 10 profile entries now include accurate script section cross-references matching the current TOC.
- **`completions/muxm-completion.bash`** — Added missing `--x264-params` to the tab-completion flag list.

## [1.3.0] - 2026-03-29

### Added

- **New profile `youtube-upload`** — H.264 high-profile master-quality encode for YouTube ingestion. CRF 16, preset `slow`, x264 params `profile=high:rc-lookahead=60:aq-mode=2:aq-strength=1.0`. Forces AAC stereo at 256 k, burns forced subtitles, exports full subtitles as external SRT sidecars, strips non-essential metadata, keeps chapters. No tone-mapping (YouTube processes HDR natively); HDR10 metadata is preserved as-is. Container: MP4. DV layer disabled. Registered in `--help`, embedded and installed man pages, tab completions, `--create-config`, and conflict warnings (warns on `--audio-lossless-passthrough` and `--output-ext mkv`).
- **`X264_PARAMS_BASE`** — New configuration variable (default empty) for advanced x264 parameter tuning, analogous to `X265_PARAMS_BASE`. The `youtube-upload` profile sets it to `profile=high:rc-lookahead=60:aq-mode=2:aq-strength=1.0`. Passed to ffmpeg via `-x264-params` when non-empty. Registered in `--print-effective-config`, `--create-config` template, and the new `--x264-params` CLI flag.
- **`--x264-params STR`** — CLI flag to override `X264_PARAMS_BASE` at the command line, matching the existing `--x265-params` flag. Registered in the man page.
- **Multi-profile via comma-separated `--profile`** — `--profile youtube-upload,streaming` runs both profiles sequentially from the same source, each as a full independent pipeline pass. All profile names are validated upfront before any work begins; an unknown name exits immediately with a helpful error. Output files are automatically suffixed with the profile name: `source.mkv` → `source.youtube-upload.mp4` and `source.streaming.mp4`. Single-profile invocations are unaffected. Per-profile success/failure is reported at the end; a failure in one profile logs a warning and continues with remaining profiles. Each pass prints a `━━━ Profile N/M: name ━━━` header. CLI flags are forwarded to each sub-invocation, so `--crf 14` applies to every profile in the list.
- **`--create-config` CLI overrides** — `--create-config` now accepts CLI flags after the scope and profile to pre-populate config values. For example, `muxm --create-config user atv-directplay-hq --crf 20 --preset medium` generates a `.muxmrc` with `CRF_VALUE=20` and `PRESET_VALUE="medium"` uncommented. Supported overrides include `--crf`, `--preset`, `--output-ext`, `--level`, `--video-codec`, `--stereo-bitrate`, `--sub-lang-pref`, `--audio-lang-pref`, and common boolean toggles. Unrecognized flags produce an error.
- **Output filename extension inference** — When the user provides an explicit output filename with a recognized extension (`.mp4`, `.m4v`, `.mov`, `.mkv`), muxm now infers `OUTPUT_EXT` from that extension, as if `--output-ext` had been passed. This prevents mismatched container formats (e.g., writing MKV data to a `.mp4` filename). Only applies in single-profile mode; `--output-ext` still wins if explicitly passed.
- **Container compatibility warnings** — Early warnings when ASS/SSA subtitle preservation is requested but output is MP4 (formatting will be lost), and when lossless audio passthrough is enabled but output is MP4 (limited playback support).
- **`_CLI_CRF_EXPLICIT` and `_CLI_PRESET_EXPLICIT` tracking variables** — Set when `--crf` or `--preset` are passed on the CLI, used by skip-if-ideal and video copy compliance checks.

### Changed

- **Native stereo track preference in stereo fallback** — When `ADD_STEREO_IF_MULTICH=1` and the primary track is surround (>2ch), muxm now scans all audio streams for a native stereo track before creating a synthetic downmix. A qualifying native stereo track must have exactly 2 channels, the same language as the primary track (`und` matches anything), no commentary/descriptive-audio title keywords, and no `visual_impaired` or `hearing_impaired` disposition flags. When a qualifying track is found it is copied directly (for container-compatible codecs: AAC, AC3, EAC3 into MP4/M4V/MOV; any codec into MKV) or transcoded to AAC at `STEREO_BITRATE` otherwise. If no qualifying native track exists, the existing downmix path is used unchanged. Primary track selection and all other behavior are unaffected.
- **Multi-profile output naming honors user's filename** — When using comma-separated `--profile` with an explicit output filename, the user's stem and directory are used as the base for auto-suffixed names (e.g., `muxm --profile youtube-upload,streaming source.mkv /nas/my_video.mp4` → `my_video.youtube-upload.mp4`, `my_video.streaming.mp4` in `/nas/`). A warning listing all output paths is printed before encoding starts. When no output filename is provided, the source stem is used as before.
- **`--create-config` single-profile variable output** — For single-profile configs, variables owned by the selected profile are now emitted uncommented (active) rather than commented out. CLI overrides that differ from the profile's own default value have `# Manually adjusted` appended to mark them as user customizations.

### Fixed

- **`check_skip_if_ideal` now checks for external subtitle files** — Skip-if-ideal logic now inspects `EXT_SUB_PATHS[]` before declaring a source "ideal." Previously, when sidecar subtitle files had been discovered, `SKIP_IF_IDEAL=1` would copy the source as-is without muxing them in, silently dropping the discovered subtitles.
- **`check_skip_if_ideal` now respects `VIDEO_COPY_IF_COMPLIANT=0`** — Profiles that require re-encoding (e.g., `animation`) are no longer silently skipped when `SKIP_IF_IDEAL=1`. The check now gates on `VIDEO_COPY_IF_COMPLIANT` so a source that is otherwise stream-copy eligible is still re-encoded when the profile demands it.
- **`check_skip_if_ideal` now checks `ADD_STEREO_IF_MULTICH`** — A surround-audio source is no longer declared "ideal" when a stereo downmix track is required. Previously `SKIP_IF_IDEAL=1` with a multi-channel source would skip encoding and omit the requested stereo track.
- **`_video_is_copy_compliant` tonemap detection** — Replaced a stale `PROFILE_DESC` string-match with a direct probe of source color metadata (`color_primaries`, `color_transfer`). Previously, `--tonemap` combined with an HDR source and `SKIP_IF_IDEAL=1` would silently skip tone-mapping because the profile description check no longer matched the internal variable layout.
- **En-dash in `assert_stream_count` fail message** — The en-dash character (U+2013) used as a separator in the assertion failure message caused an unbound variable crash under `set -u`. Replaced with an ASCII hyphen.
- **Collision test isolation** — Added explicit `--output-ext mp4` to the collision test to prevent a user's `.muxmrc` passthrough config from changing the output container and invalidating the test scenario.
- **`--create-config` override values not applied** — CLI override values passed after the profile name were being ignored; the generated config did not reflect them. Fixed.
- **DV + unsupported output container** — muxm now errors early (exit 11) when Dolby Vision is detected but the output container (e.g., MOV) is not supported for DV muxing by ffmpeg. Previously the encode would complete and fail at the mux step. The error message directs the user to `--output-ext mkv`, `--output-ext mp4`, or `--no-dv`.
- **`check_skip_if_ideal` ignores explicit `--crf` and `--preset`** — when CRF or preset are explicitly set on the CLI, skip-if-ideal and video-copy-if-compliant now correctly force a re-encode instead of stream-copying or skipping.
- **`--create-config` with multi-profile** — comma-separated profile names now generate a minimal config containing only `PROFILE_NAME` and explicit overrides, instead of a full template seeded from one profile's defaults.

### Tests

- **`--cleanup` flag for standalone cleanup** — `--cleanup` now runs as a standalone mode: prints each stale temp directory with its size on disk, removes them, and prints a total freed summary. No longer tied to ending a test run.
- **Auto-cleanup of stale `muxm-test.*` directories at run start** — The test runner now purges leftover `muxm-test.*` temp directories at the beginning of every run (not the end), so failures from a prior aborted run do not pollute the next one.
- **Reverted parallel test runner** — `--parallel`, `--no-parallel`, and `-j N` flags have been removed due to process management issues that caused intermittent hangs. Suites run sequentially again.
- **New `multi_profile` test suite** — Tests for comma-separated profile parsing, invalid profile name rejection (exits before any work begins), single-profile invocation remaining unchanged, and output filename auto-suffixing.
- **`youtube-upload` profile variable assertions** — New tests verify that the profile sets the expected values for `VIDEO_CRF`, `VIDEO_PRESET`, `X264_PARAMS_BASE`, `AUDIO_CODEC`, `AUDIO_BITRATE`, `ADD_STEREO_IF_MULTICH`, `SUB_BURN_FORCED`, `DISABLE_DV`, and `TONEMAP`.
- **`youtube-upload` conflict warning tests** — Assertions that `--output-ext mkv` and `--audio-lossless-passthrough` each trigger the expected conflict warning when used with the `youtube-upload` profile.

## [1.2.0] - 2026-03-26

Smart disk space preflight: `disk_free_warn` now estimates expected output size from source video bitrate, CRF, codec, preset, audio tracks, and duration instead of using a static free-space floor. Adds `--no-disk-check` / `--disk-check` to suppress or re-enable the check at the CLI.

External subtitle discovery: muxm now automatically finds and muxes sidecar subtitle files (.srt, .ass, .ssa, .vtt, .sup, .idx/.sub) alongside the source. Language codes in filenames are normalized to ISO 639-2/T and routed through all existing subtitle filters. Internal refactors (no user-facing behavior changes) also included.

Container passthrough: `archive` and `atv-directplay-hq` now derive the output container from the source file extension (`mkv→mkv`, `mp4→mp4`) instead of hardcoding it, with a fallback to `.mkv` for unsupported source containers. When `atv-directplay-hq` produces MKV output, it automatically enables native ASS/SSA subtitle preservation and disables forced-subtitle burn-in (both overrideable via CLI flags).

Profile rename: `dv-archival` has been renamed to `archive`. The old name is retained as a deprecated backwards-compatible alias — existing scripts and `.muxmrc` files using `PROFILE_NAME="dv-archival"` will continue to work but will log a deprecation notice.

New profile `atv-directplay-animation`: combines `atv-directplay-hq` ATV Direct Play constraints with `animation`'s quality-first encoding settings. Ideal for anime/cartoon sources destined for Apple TV. Lossless audio is transcoded to E-AC-3 (ATV cannot Direct Play TrueHD/DTS-HD MA). Multi-track ASS/SSA + PGS subtitle preservation. Passthrough container with MKV-output subtitle adjustment (same as `atv-directplay-hq`).

### Added

- **Smart disk-space preflight** — `disk_free_warn()` now estimates encoded output size before encoding begins rather than just checking a fixed free-space floor. Estimation uses per-codec CRF-to-bitrate-ratio tables (`_crf_ratio`, with a baked-in 1.3× light grain pessimism factor) and preset-size multipliers (`_preset_multiplier`). When `VIDEO_COPY_IF_COMPLIANT=1`, the source video bitrate is used directly (no CRF reduction). Audio estimation uses source bitrate for passthrough codecs (eac3, ac3, aac, dts, truehd, mlp, flac) and 64 kbps × channel-count for transcode targets. A 5 MB subtitle overhead and a 1.25× safety margin are applied. `DISK_FREE_WARN_GB` acts as a minimum floor. Both the output volume and the temp/workdir volume (when on a separate device from output) are checked. Warning messages now include `Use --no-disk-check to suppress this warning.`
- **`--disk-check` / `--no-disk-check`** — Enable or disable the smart disk preflight at the CLI. `DISK_CHECK=0` in `.muxmrc` has the same effect. Registered in `--print-effective-config`, `--create-config` template, tab completions, and man page.
- **`DISK_CHECK`** config variable (default `1`) — controls the smart disk preflight. Added to `--print-effective-config` output under `[Pipeline Control]` and to the `--create-config` generated template.
- **External subtitle discovery** (`EXT_SUB_ENABLED`) — muxm now automatically discovers sidecar subtitle files (.srt, .ass, .ssa, .vtt, .sup, .idx/.sub) in the same directory as the source file and muxes them as additional subtitle tracks. Filename parsing extracts language codes and type qualifiers (e.g., `movie.en.srt`, `movie.forced.en.srt`, `movie.sdh.srt`). 2-letter ISO 639-1 codes are normalized to 3-letter ISO 639-2/T codes. External subtitles pass through all existing subtitle filters (`SUB_LANG_PREF`, `SUB_INCLUDE_FORCED`/`FULL`/`SDH`, `SUB_MAX_TRACKS`) and work in both single-track and multi-track subtitle modes.
- **`--ext-subs` / `--no-ext-subs`** — Enable or disable external subtitle discovery at the CLI. `--ext-subs-dir <dir>` overrides the search directory (defaults to the source file's directory).
- **`EXT_SUB_ENABLED` / `EXT_SUB_DIR`** — New config variables for external subtitle discovery. `--create-config` now includes these variables (commented out) in the generated template for all profiles.
- **58 new external subtitle discovery tests** in a new `ext_subs` test suite.
- **~430 additional tests** covering previously untested features (total test count now 702).
- **Container passthrough for `archive` and `atv-directplay-hq`** — Both profiles now set `OUTPUT_EXT=""`, signalling container passthrough. After source validation, the passthrough resolution block (Section 15) derives `OUTPUT_EXT` from the source file extension: `mkv→mkv`, `mp4→mp4`, `m4v→m4v`, `mov→mov`. Sources with unsupported output containers (`.avi`, `.ts`, etc.) fall back to `.mkv` with an informational note. `--output-ext` on the CLI always wins (`_OUTPUT_EXT_EXPLICIT=1` skips the resolution block). `USAGE_SHORT` shows `[target.{src-ext}]` when `OUTPUT_EXT` is empty at parse time.
- **`atv-directplay-hq` MKV-output subtitle adjustment** — When `atv-directplay-hq` resolves to MKV output, `SUB_BURN_FORCED` is set to `0` (soft subtitles preferred over burn-in) and `SUB_PRESERVE_TEXT_FORMAT` is set to `1` (native ASS/SSA preservation). `--sub-burn-forced` on the CLI prevents the burn-in override; ASS preservation is always enabled for MKV output.
- **`_OUTPUT_EXT_EXPLICIT` tracking variable** — Set to `1` when `--output-ext` is passed on the CLI, distinguishing "user forced a container" from "container is being resolved from source."
- **`_CLI_SUB_BURN_FORCED` tracking variable** — Set to `1` when `--sub-burn-forced` is passed on the CLI, preventing the `atv-directplay-hq` MKV subtitle adjustment from overriding an explicit user request.
- **`SUB_SOLE_EXT_FALLBACK`** — When the language filter drops all subtitle candidates but there is exactly one external sidecar and zero embedded streams, that sidecar is included regardless of its language tag. Enabled by default; disable with `--no-sub-sole-ext-fallback` or `SUB_SOLE_EXT_FALLBACK=0`.
- **`--sub-sole-ext-fallback` / `--no-sub-sole-ext-fallback`** — CLI flag pair registered in `--print-effective-config`, tab completions, and man page.
- **New profile `atv-directplay-animation`** — Animation-quality encode shaped for Apple TV / Plex Direct Play. Takes `animation`'s quality-first settings (CRF 16, animation-tuned x265 params, HEVC 10-bit, multi-track ASS/SSA + PGS subtitle preservation) and layers on `atv-directplay-hq`'s ATV compatibility constraints (E-AC-3 audio, Level 5.1 VBV guardrails, passthrough container, copy-if-compliant with 50 Mbit/s ceiling). Lossless audio (TrueHD, DTS-HD MA, FLAC) is transcoded to E-AC-3 since ATV cannot Direct Play lossless codecs. Forced subtitles are burned for MP4 output (Direct Play requirement); for MKV output the MKV subtitle adjustment block (Section 15) switches to soft forced subs and confirms native ASS/SSA preservation. Registered in `--help`, man page, tab completions, `--create-config`, and conflict warnings.
- **Profile rename: `dv-archival` → `archive`** — The `dv-archival` profile has been renamed to `archive`. The old name is preserved as a silent backwards-compatible alias: `--profile dv-archival` and `PROFILE_NAME="dv-archival"` in `.muxmrc` continue to work and now emit a deprecation notice. All user-facing surfaces (help text, man page, tab completions, `--create-config`, conflict warnings) use the new name.

### Fixed

- **`(( counter++ ))` from zero exits under bash error handling** — The `SUB_SOLE_EXT_FALLBACK` loop used post-increment from `0`, which evaluates to `0` (false) and triggers `set -e` / ERR trap. Replaced with `counter=$(( counter + 1 ))`.
- **`atv-directplay-hq` conflict warning false positive for passthrough-to-MKV** — Warning now requires `(( _OUTPUT_EXT_EXPLICIT ))` so it only fires for explicit `--output-ext mkv`. Updated message acknowledges Plex/Infuse MKV Direct Play support.
- **ShellCheck SC2017 precision-loss warnings** — Integer-only `$(( ))` arithmetic was used in places where intermediate float values were expected, triggering SC2017. The affected expressions in the disk-preflight estimation helpers (`_crf_ratio`, `_preset_multiplier`) have been rewritten to use `awk` for floating-point math, eliminating all SC2017 warnings from a full `shellcheck` pass.

### Changed

- **`disk_free_warn` call moved** — The function is now called inside `main()` after `cache_stream_metadata()`, so it uses the already-populated `METADATA_CACHE` (via `_jq_cache`, `_get_source_duration_secs`, and `_audio_stream_info`) without re-probing the source file.
- **GB display format** — Available and estimated disk space in preflight warnings is now shown with one decimal place (e.g. `3.4GB`) instead of truncated integer GB.
- **README** — Editorial polish pass: added `bc` to the Homebrew dependencies list, highlighted the live progress bar, documented disk space preflight, signal handling, and `DEBUG=1`, added a CHANGELOG link, fixed the table of contents, moved the "Why MuxMaster?" section after the usage section, corrected grammar throughout, and normalized all code fences to consistent backtick-triple style.
- **Man page** (`docs/muxm.1` and embedded `--install-man` copy) — Updated with external subtitle discovery documentation covering new flags, config variables, filename parsing behavior, and filter interaction. This release additionally adds `--sub-sole-ext-fallback` / `--no-sub-sole-ext-fallback` flag documentation and `SUB_SOLE_EXT_FALLBACK` to the configuration variable reference.
- **Tab completions** (`completions/muxm-completion.bash`) — `--sub-sole-ext-fallback` and `--no-sub-sole-ext-fallback` added to the subtitle flag group. `archive` and `atv-directplay-animation` added to profile completion lists; `dv-archival` removed (deprecated alias no longer advertised).
- **Man page** (`docs/muxm.1` and embedded copy) — `archive` and `atv-directplay-animation` profiles added; `dv-archival` entry removed. `--output-ext` entry updated to describe passthrough behavior for passthrough profiles. `--sub-sole-ext-fallback` section in embedded copy synced to match `docs/muxm.1`. Multi-Track Audio and Multi-Track Subtitles sections updated to reflect the three multi-track profiles (`archive`, `animation`, `atv-directplay-animation`). Version header updated to v1.2.0 / 2026-03-24. Passthrough container language updated in `atv-directplay-hq` description.
- **Extract `_create_config_prescan()`** — The `--create-config` pre-scan block was extracted into its own function. Its 6 temporary variables are now local to the function, eliminating the corresponding `unset` calls in the main flow.
- **Extract `_cleanup_workdir()` from `on_exit`** — Deduplicated the WORKDIR removal safety guard into a single helper. `exec 3>&-` is now unconditionally issued before the success/failure branch so FD 3 is always closed in the same place regardless of exit path.
- **Add `# SYNC:` cross-reference comments to duplicated audio stream display loops** — The parallel loops in `run_audio_pipeline` and `run_audio_pipeline_multi` now carry `# SYNC:` annotations pointing at each other, making the duplication intentional and visible to future editors.
- **Extract `_ffmpeg_run_with_ui()`** — Consolidated the repeated pipe / progress-bar / spinner boilerplate that appeared across the video encode, audio transcode, and stereo fallback paths into a single shared helper. Call sites pass their ffmpeg arguments and a label; the helper owns the subprocess, UI wiring, and exit-code propagation.
- **Consolidate `printf | sed` calls in `build_x265_params`** — Six separate `printf | sed` subprocess invocations have been merged into a single `sed` call with multiple `-e` expressions, reducing subprocess overhead and centralizing the parameter-sanitization logic.
- **Eliminate double-scan in `select_best_audio`** — The previous two-pass implementation (one pass to build the score summary, a second to find the best stream) has been merged into a single loop that tracks the running best while accumulating the summary, halving the number of iterations over the stream list.
- **Replace `wc -w` word counting with pure Bash array expansion** — Three-subprocess chains (`echo | wc | tr`) used to count whitespace-delimited tokens have been replaced with `read -r -a arr` followed by `${#arr[@]}`, eliminating subshells and external process forks for this operation.

### Tests

- **Unit tests for `_crf_ratio` and `_preset_multiplier`** — New `test_disk_preflight` suite includes dedicated unit-test assertions for both helper functions, verifying correct ratio and multiplier values across all supported codecs, CRF values, and preset names, as well as boundary behaviour (unknown codec/preset fallback defaults).
- **3 new assertions in `test_dryrun`**: `--no-disk-check` suppresses the warning, `DISK_CHECK=0` in config suppresses the warning, and `--video-copy-if-compliant` (copy mode) completes the disk preflight without error.
- **24 new test assertions** across 5 suites: `profiles` (CLI override wins over passthrough), `conflicts` (passthrough doesn't fire MKV warning), `dryrun` (passthrough resolution logs, subtitle adjustment for MKV/MP4, CLI override), `containers` (real-encode passthrough MKV→MKV, MP4→MP4, M4V→M4V, AVI→MKV fallback, CLI override), `ext_subs` (sole-external fallback includes/excludes correctly).
- **2 updated assertions**: `dv-archival` and `atv-directplay-hq` profile tests updated from hardcoded `OUTPUT_EXT` to empty (passthrough).
- **Parallel test runner** — `test_muxm.sh` now supports `--parallel` / `--no-parallel` and `-j N` to control the number of concurrent test workers. Suites run sequentially by default; `--parallel` distributes suites across worker subshells (default concurrency: number of CPU cores as reported by `nproc`/`sysctl -n hw.logicalcpu`). Suite output is buffered and printed atomically when each suite finishes so interleaving is never visible.
- **Test cleanup** — `--cleanup` removes all fixture output files and temporary directories generated during a test run. Auto-cleanup now runs at the end of every test run by default (previously the caller was responsible for cleanup). Pass `--no-cleanup` to suppress it for post-failure inspection.

## [1.1.0] - 2026-03-22

Multi-track audio and subtitles for `dv-archival` and `animation`: both profiles now keep all matching audio/subtitle tracks from the source instead of scoring and selecting one. Commentary/descriptive audio tracks are dropped by default in `dv-archival`. All surviving tracks are stream-copied (never transcoded). Configurable via `.muxmrc`.

### Added

- **Multi-track audio pipeline** (`AUDIO_MULTI_TRACK=1`) — New audio mode that keeps all matching audio tracks instead of selecting a single best track. Audio streams are mapped directly from source with `-c:a copy` (no intermediate extraction, no transcoding, no temp files). Controlled by two new config variables:
  - `AUDIO_MULTI_TRACK` — `1` = keep all tracks that pass filters, `0` = single-track scoring (default, unchanged for all other profiles).
  - `AUDIO_KEEP_COMMENTARY` — `1` = keep commentary/descriptive tracks, `0` = drop them. Uses the existing `_audio_is_commentary()` heuristic.
- **Multi-track subtitle pipeline** (`SUB_MULTI_TRACK=1`) — New subtitle mode that keeps all matching subtitle tracks instead of selecting one per type (forced/full/SDH). Subtitle streams are mapped directly from source with `-c:s copy` (no OCR, no format conversion, no intermediate files). Controlled by one new config variable:
  - `SUB_MULTI_TRACK` — `1` = keep all tracks that pass filters, `0` = single-track per-type selection (default, unchanged for all other profiles).
  - Uses existing `SUB_INCLUDE_FORCED`, `SUB_INCLUDE_FULL`, `SUB_INCLUDE_SDH` as type filters and `SUB_LANG_PREF` as language filter. `SUB_MAX_TRACKS` is respected as a cap.
  - Bitmap subtitles (PGS, VobSub) that cannot be muxed into the target container are silently skipped. MKV handles all formats.
- **`dv-archival` profile updated** — Now sets `AUDIO_MULTI_TRACK=1`, `AUDIO_KEEP_COMMENTARY=0`, and `SUB_MULTI_TRACK=1`. Language filtering uses the existing `AUDIO_LANG_PREF` and `SUB_LANG_PREF` variables: when empty (the dv-archival default), all languages pass; when set (e.g., `eng,jpn`), only matching tracks are kept.
- **`animation` profile updated** — Now sets `SUB_MULTI_TRACK=1` so all matching subtitle tracks (including PGS bitmap streams) are stream-copied from source without OCR or format conversion. Previously, PGS subtitles were routed through the single-track OCR pipeline and silently dropped when OCR tooling was unavailable, despite the output container (MKV) supporting PGS natively. `SUB_MAX_TRACKS` defaults to 6.
- **Graceful demotion** — If `--audio-track` or `--audio-force-codec` is set alongside `AUDIO_MULTI_TRACK=1`, multi-track audio mode is automatically demoted to single-track with an informational note. If `--sub-burn-forced` is set alongside `SUB_MULTI_TRACK=1`, multi-track subtitle mode is demoted to single-track. The explicit CLI flag always wins.
- **Conflict warnings** (Section 13) for `dv-archival` + `--audio-track`, `--audio-force-codec`, `--stereo-fallback`, `--sub-burn-forced`, and `--sub-export-external` when multi-track modes are active.
- **`skip-if-ideal` updated** — When `AUDIO_MULTI_TRACK=1` or `SUB_MULTI_TRACK=1`, the ideal check verifies that every source audio/subtitle track would survive the respective filter. If any would be dropped, the source is not ideal and remuxing proceeds.
- **Per-stream gating in skip-if-ideal remux** — `check_skip_if_ideal` now produces validated stream keep-lists (`SII_AUDIO_INDICES`, `SII_SUB_INDICES`) that the metadata remux uses to build explicit `-map 0:v:0 -map 0:a:N -map 0:s:N` flags instead of `-map 0`. Multi-track profiles delegate to `_build_audio_keep_list` / `_build_subtitle_keep_list`. Single-track profiles filter every stream against container compatibility, preventing incompatible codecs (e.g., TrueHD or PGS in MP4) from reaching the mux — even if a future profile change removes the implicit container gate.
- **`_sii_audio_is_container_safe()` helper** — Checks whether an audio codec can be muxed into the target container. MKV passes all codecs; MP4/MOV rejects TrueHD, DTS/DCA, and raw PCM. Mirrors the existing `_is_text_sub_codec` pattern for subtitles.
- **`dv-archival` profile now enables `CHECKSUM=1` by default** — SHA-256 integrity verification is a natural part of the archival workflow and was a missing default. Can be suppressed with `--no-checksum`.
- **Shared source input in `mux_final`** — `VIDEO_COPY_FROM_SOURCE`, `AUDIO_COPY_FROM_SOURCE`, `SUB_COPY_FROM_SOURCE`, and direct subtitle mapping now share a single `-i "$SRC_ABS"` ffmpeg input via `_src_input_idx`, eliminating duplicate source file inputs.
- New man page subsections "Multi-Track Audio (Archival)" and "Multi-Track Subtitles" under AUDIO OPTIONS and SUBTITLE OPTIONS, documenting filter behavior, config variables, demotion rules, and per-profile defaults for both `dv-archival` and `animation`.
- `AUDIO_MULTI_TRACK`, `AUDIO_KEEP_COMMENTARY`, and `SUB_MULTI_TRACK` added to `--print-effective-config`, `--create-config` template, and man page CONFIGURATION variable groups.
- 21 new test assertions in `test_muxm.sh` across `test_profiles`, `test_conflicts`, `test_dryrun`, `test_subs`, and `test_profile_e2e` suites validating animation profile multi-track subtitle behavior: profile variable assignment, conflict warnings (burn-forced demotion, export-external), dry-run announcements, language filtering, and a full e2e encode verifying all 5 subtitle tracks are preserved in output.

### Fixed

- **`--no-sub-preserve-format` silently ignored in multi-track subtitle mode.** The multi-track pipeline used blanket `-c:s copy` for all streams, bypassing the `SUB_PRESERVE_TEXT_FORMAT` check entirely. ASS/SSA subtitles were always stream-copied regardless of the flag. The multi-track codec assignment in `mux_final` now makes per-stream decisions: ASS/SSA tracks are converted to SRT (MKV) or mov_text (MP4/MOV) when `SUB_PRESERVE_TEXT_FORMAT=0`, while all other codecs (PGS, SRT, VobSub) remain stream-copied. `run_subtitle_pipeline_multi` logs an informational note when ASS/SSA conversion will occur.
- **Skip-if-ideal metadata remux silently dropped streams.** The ffmpeg copy-remux used to stamp audio titles had no `-map` flag, causing ffmpeg's default stream selection to keep only one stream per type. On a 39-stream source (video + TrueHD + AC-3 + PGS + 35 SRT tracks), `dv-archival` output retained only 3 streams — the AC-3 compatibility track, PGS SDH subtitle, and all non-first-selected SRT tracks were silently lost. The remux now uses explicit per-stream maps built from the validated keep-lists populated by `check_skip_if_ideal`.
- **Audio title metadata misaligned when streams are filtered.** The skip-if-ideal remux referenced source audio indices for `-metadata:s:a:N` tags, but when streams are filtered out, output indices shift. Tags now use a sequential output counter, matching the proven pattern in `mux_final`.
- **No visual feedback during skip-if-ideal remux.** The ffmpeg copy-remux, `cp` fallback, and SHA-256 checksum all ran in the foreground with no spinner, causing the CLI to appear hung for 10–30+ seconds on multi-GB files. All three now run in the background with `spinner` progress indicators.
- **FD 3 closed before checksum in `on_exit`.** The raw-terminal file descriptor used by `spinner` was closed at the top of `on_exit`, before `write_checksum` could use it. The checksum spinner would write to a closed FD. FD 3 close is now deferred to after the checksum in both the success and failure paths.

### Changed

- `dv-archival` profile description updated in man page, usage text, and `--help` output to reflect multi-track audio and subtitle behavior.
- `animation` profile description updated in man page to reflect multi-track subtitle mode (ASS/SSA + PGS bitmap). MP4/MOV compatibility warnings now mention PGS bitmap subtitles alongside ASS/SSA.
- Man page "Multi-Track Subtitles" section updated: ASS/SSA tracks are converted to SRT when `SUB_PRESERVE_TEXT_FORMAT=0`, even in multi-track mode. Previously stated "no format conversion" unconditionally.

## [1.0.2] - 2026-03-20

Enforce HEVC Level 5.1 VBV guardrails in `atv-directplay-hq` re-encodes to prevent bitrate spikes that cause stutter on Apple TV 4K. Fix crash when subtitle or audio stream titles contain literal pipe characters. Add ASS/SSA subtitle format preservation for MKV containers. Eliminate redundant multi-GB file copies in the video pipeline. Fix fatal ffmpeg muxer failure when stream-copying TrueHD or ALAC audio via lossless passthrough. Fix misleading "No Dolby Vision detected" log message when DV detection is skipped by a profile.

### Added

- **`--sub-preserve-format` / `--no-sub-preserve-format`** — New CLI flag pair controlling whether text-based subtitles (ASS/SSA) are kept in their native format or converted to plain-text SRT. When enabled and the output container is MKV, ASS/SSA subtitles are stream-copied with full positioning, fonts, and typesetting intact. Ignored for MP4/MOV containers (which cannot carry ASS). Controllable via the `SUB_PRESERVE_TEXT_FORMAT` config variable in `.muxmrc`.
- **`animation` profile now preserves ASS/SSA subtitles by default.** The profile sets `SUB_PRESERVE_TEXT_FORMAT=1`, fulfilling its documented promise of preserving styled ASS/SSA subtitles in MKV output. Previously, ASS subtitles were unconditionally converted to SRT regardless of profile or container, losing all positioning, styling, and typesetting data.
- New conflict warning when `animation` profile is combined with `--no-sub-preserve-format`, alerting that ASS/SSA styling will be lost.
- `SUB_PRESERVE_TEXT_FORMAT` added to `--print-effective-config`, `--create-config` template, man page, and tab completions.
- New `ass_subs.mkv` test fixture and 10 new test assertions across `test_profiles`, `test_conflicts`, `test_dryrun`, `test_subs`, and `test_profile_e2e` suites validating ASS preservation, SRT conversion fallback, CLI override, and MP4 container limitation.
- `probe_sub` helper added to `test_muxm.sh` for subtitle stream field inspection.
- **`_audio_copy_ext()` helper** — Maps ffprobe codec names to file extensions that ffmpeg can actually mux when stream-copying intermediate audio. Covers `truehd→.thd`, `alac→.m4a`, `pcm_s*→.wav`, `dca→.dts`; all other codecs pass through unchanged.
- `SYNC` cross-reference comments on `audio_is_direct_play_copyable()`, `audio_is_lossless()`, and `_audio_copy_ext()` documenting that these three codec lists must stay in sync — any codec added to either copy-eligible gate must have a valid mapping in `_audio_copy_ext()`.
- 11 new unit test assertions for `_audio_copy_ext` covering all 5 mapped codecs and 6 passthrough codecs.
- **`--dv` CLI flag** — Re-enables Dolby Vision handling after a profile disables it. Follows the existing `--flag` / `--no-flag` convention alongside `--no-dv`. Allows users to combine animation-tuned x265 parameters with DV preservation on live-action sources (e.g., `muxm --profile animation --dv Movie.mkv`). Added to man page, tab completions, and usage text.
- **`_source_has_dv_metadata()` helper** — Lightweight check for DOVI configuration records in the already-populated metadata cache. Used to emit actionable warnings when DV detection is skipped on a source that actually contains Dolby Vision.

### Fixed

- **`atv-directplay-hq` re-encodes now capped by Level 5.1 VBV.** Previously, the copy path was guarded by `MAX_COPY_BITRATE=50000k` but the re-encode path had no bitrate ceiling — a CRF 17 encode of complex scenes could spike beyond what the Apple TV 4K hardware decoder sustains without buffering. The profile now sets `LEVEL_VALUE="5.1"`, which activates the existing conservative VBV machinery (`vbv-maxrate=40000k`, `vbv-bufsize=80000k`). Can be overridden with `--level` or `--no-conservative-vbv`.
- **Pipe characters in stream titles no longer break field parsing.** Subtitle titles such as `"Original | English"` or `"Original | English | (SDH)"` contain literal `|` which corrupted the pipe-delimited output of `_sub_stream_info` and the verify-block audio jq call. The `forced` variable would receive fragments like `" English|0"` instead of `0`, causing an arithmetic evaluation crash under `nounset`. Switched all internal field delimiters from `|` to `\t` (tab) across 4 jq producer functions, 10 consumer `read`/`cut`/parameter-expansion sites, and their fallback defaults. Tab is safe because it effectively never appears in media metadata. The audio pipeline (`_audio_stream_info`, `_score_audio_stream`, and their consumers) was not actively broken — the free-text `title` field happened to be last, absorbing extra pipes — but was migrated for consistency to prevent silent breakage if fields are ever reordered.
- **ASS/SSA subtitles no longer silently converted to SRT.** The subtitle pipeline unconditionally funneled all text-based subtitles through SRT conversion via `_prepare_sub_to_srt`, destroying ASS positioning, fonts, and typesetting — even when the output container (MKV) natively supports ASS. The `--no-ocr` flag only gated PGS bitmap OCR, not text-format conversion. The function has been renamed to `_prepare_subtitle` and now checks `SUB_PRESERVE_TEXT_FORMAT` and the output container format before deciding whether to convert or stream-copy. The final mux stage (`mux_final`) has been updated from a blanket `-c:s srt` to per-stream codec assignment, so ASS and SRT tracks can coexist in the same output.
- **Lossless audio passthrough no longer fails for TrueHD and ALAC codecs.** The audio pipeline's copy path wrote the intermediate file as `audio_primary.${codec}` using the raw ffprobe codec name as the extension. ffmpeg has no muxer registered for `.truehd` or `.alac`, causing a fatal "Unable to choose an output format" error before any data was written. This broke `--profile animation` (which enables `AUDIO_LOSSLESS_PASSTHROUGH=1`) for any source with a TrueHD Atmos track, and `--audio-lossless-passthrough` or `--profile dv-archival` for sources with ALAC audio. The same class of bug also affected `pcm_s16le`/`pcm_s24le`/`pcm_s32le` (no `.pcm_*` muxer) and `dca` (ffprobe name vs ffmpeg's `.dts` muxer). A new `_audio_copy_ext()` helper now maps each codec to a valid ffmpeg muxer extension. The transcode path was not affected (it already reassigns the extension from the target codec).
- **Misleading "No Dolby Vision detected" message when DV is disabled by a profile.** Profiles that set `DISABLE_DV=1` (e.g., `animation`, `streaming`, `universal`) caused `detect_dv()` to bail out before probing, then the caller logged "No Dolby Vision detected" — identical to the message shown when a source genuinely lacks DV. For sources that do contain Dolby Vision (e.g., a Netflix 4K HDR rip with DV Profile 7), this was confusing and gave no indication that DV was being intentionally skipped. `detect_dv()` now returns a distinct exit code (2) when detection is skipped due to `DISABLE_DV`. The caller uses the new `_source_has_dv_metadata()` helper to check whether the source actually has DV, and emits one of two messages: a warning with `--dv` override guidance when DV is present but disabled, or a neutral note when the source has no DV and detection was simply unnecessary.

### Changed

- `--create-config ... atv-directplay-hq` now emits `LEVEL_VALUE` and `CONSERVATIVE_VBV` as uncommented (active) variables, matching the profile's new defaults.
- **Video pipeline no longer copies multi-GB intermediates on non-DV and DV-fallback paths.** Six `cp -f` operations that duplicated the encoded video from `V_BASE` to `V_MIXED` (or `V_INJECTED` to `V_MIXED`) have been replaced with variable reassignment. Downstream consumers (`mux_final`, DV container verification, DV pre-wrap) only read `V_MIXED` and never write to it, so an alias is functionally identical to a file copy. For a typical 2-hour 4K HEVC encode at CRF 17–18, this eliminates 8–25 GB of redundant disk I/O, saves 10–30 seconds of wall-clock time, and halves peak intermediate disk usage. The only user-visible change is that `--keep-temp-always` workdirs will no longer contain a separate `video_mixed` file on non-DV runs.

## [1.0.1] - 2026-03-09

Output file collisions now handled gracefully. Adds new flags `--replace-source` and `--force-replace-source`.

### Fixed

- **Source/output collision no longer fatal.** When the derived output path matches the source file (e.g., `muxm movie.mp4` where the default output extension is also `.mp4`), muxm now auto-appends a version number instead of aborting: `movie(1).mp4`, `movie(2).mp4`, etc. The version number increments until a free filename is found.

### Added

- **`--replace-source`** — Replace the original source file with the encoded output after an interactive confirmation prompt. Requires a TTY; rejected in non-interactive shells with a clear error directing the user to `--force-replace-source`.
- **`--force-replace-source`** — Same as `--replace-source` but skips the confirmation prompt. Designed for scripting and automation.
- Both flags registered in `--help`, `--print-effective-config`, tab completions, man page, and `.muxmrc` config generator.
- New `collision` test suite in `test_muxm.sh` with 17 assertions covering auto-versioning, sequential incrementing, TTY rejection, in-place replacement, and no-collision passthrough.

### Changed

- Existing tests in `test_edge` and `_test_cli_error_codes` updated to expect auto-versioning behavior instead of the previous fatal error.

## [1.0.0] - 2026-03-07

Initial public release.

### Core

- Multi-stage encoding pipeline: source inspection → profile resolution → video → audio → subtitles → final mux → verification
- Single-pass ffprobe metadata cache for all stream analysis
- Layered configuration precedence: hardcoded defaults → `/etc/.muxmrc` → `~/.muxmrc` → `./.muxmrc` → `--profile` → CLI flags
- 60+ CLI flags with `--help`, `man muxm`, and bash/zsh tab completion

### Format Profiles

- **`dv-archival`** — Lossless Dolby Vision preservation. Copy video if compliant, lossless audio passthrough, skip-if-ideal, JSON reporting
- **`hdr10-hq`** — High-quality HDR10 encoding. HEVC CRF 17, strip DV, lossless audio + stereo fallback, MKV
- **`atv-directplay-hq`** — Apple TV 4K Direct Play via Plex. MP4, HEVC Main10, DV Profile 8.1 auto-conversion, E-AC-3 + AAC stereo, forced subtitle burn-in
- **`streaming`** — Modern HEVC streaming for Plex/Jellyfin/Emby. CRF 20, E-AC-3 448k, AAC stereo, MP4
- **`animation`** — Optimized for anime and cartoons. CRF 16, keeps 10-bit for SDR sources (anti-banding), low psy-rd/psy-rdoq, lossless audio, ASS/SSA subtitle preservation, MKV
- **`universal`** — Maximum compatibility. H.264 SDR with HDR tone-mapping, AAC stereo, burned forced subs, external SRT export, MP4

### Video

- Dolby Vision detection via stream metadata and frame-level side data
- RPU extraction, profile conversion (P7 dual-layer → P8.1 single-layer), and injection via `dovi_tool`
- DV container signaling verification via `MP4Box`
- Color space detection (BT.2020 PQ, BT.2020 HLG, BT.709 SDR) with distinct HDR10, HLG, and SDR encoding paths and automatic x265 parameter selection
- HDR-to-SDR tone-mapping via zscale + hable
- Chroma subsampling normalization (4:2:2/4:4:4 → 4:2:0) for Direct Play compatibility
- Video copy-if-compliant to skip re-encoding when source already matches target, with configurable bitrate ceiling to prevent blindly copying oversized streams
- Conservative VBV guardrails per x265 level

### Audio

- Weighted scoring system for automatic track selection (language, channels, surround bonus, codec preference, commentary penalty)
- Configurable scoring weights via `.muxmrc`
- Lossless passthrough for TrueHD, DTS-HD MA, and FLAC
- Automatic AAC stereo fallback generation from surround sources
- E-AC-3 transcoding at profile-specific bitrates (5.1 and 7.1)
- Descriptive audio stream titling (e.g., "5.1 Surround (E-AC-3)")

### Subtitles

- Track categorization: forced, full, and SDH
- PGS bitmap subtitle OCR to SRT via `pgsrip` or `sub2srt`
- Forced subtitle burn-in
- External `.srt` export
- Language preference filtering
- SDH track exclusion

### Output & Reporting

- MP4, MKV, M4V, and MOV container support
- Chapter marker preservation and stripping
- Metadata stripping
- skip-if-ideal detection (avoids re-processing compliant files)
- JSON reporting with full decision/warning/stream-mapping documentation
- SHA-256 checksum generation
- Dry-run mode (`--dry-run`) for previewing the full pipeline without encoding
- Effective config display (`--print-effective-config`) showing resolved settings from all layers

### Setup & Tooling

- `--setup` for one-command first-time installation (dependencies + man page + tab completion)
- `--install-dependencies` with Homebrew and pipx detection
- `--install-man` / `--uninstall-man` for system man page management
- `--install-completions` / `--uninstall-completions` for bash/zsh tab completion
- `--create-config` / `--force-create-config` for generating pre-seeded `.muxmrc` files
- Conflict warnings for contradictory profile + flag combinations
- Spinner and progress bar for long-running operations
- Quick-test mode (`--skip-video`, `--skip-audio`, `--skip-subs`) for validating pipeline decisions without waiting for a full encode
- Disk space preflight warning before encoding begins
- Graceful signal handling (Ctrl-C / SIGTERM) with automatic temp file cleanup
- Structured exit codes for scripting and automation (10 = missing tool, 11 = bad arguments, 12 = corrupt source, 40–43 = pipeline failures)
- Comprehensive test harness (`test_muxm.sh`) with 18 test suites and ~165 assertions

[1.2.0]: https://github.com/TheBluWiz/MuxMaster/releases/tag/v1.2.0
[1.1.0]: https://github.com/TheBluWiz/MuxMaster/releases/tag/v1.1.0
[1.0.2]: https://github.com/TheBluWiz/MuxMaster/releases/tag/v1.0.2
[1.0.1]: https://github.com/TheBluWiz/MuxMaster/releases/tag/v1.0.1
[1.0.0]: https://github.com/TheBluWiz/MuxMaster/releases/tag/v1.0.0