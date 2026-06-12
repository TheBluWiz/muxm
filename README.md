# ![muxm](assets/muxm_header_small.png) MuxMaster

[![Version](https://img.shields.io/badge/version-1.4.0-blue)](https://github.com/TheBluWiz/MuxMaster/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](#compatibility)
[![License](https://img.shields.io/badge/license-freeware-green)](#license)

**MuxMaster** (`muxm`) — a single-command video repacking and encoding utility that handles Dolby Vision, HDR10, audio track selection, subtitle processing, and container muxing so you don't have to. Built for home media enthusiasts managing Plex, Jellyfin, or Emby libraries from disc rips and downloads. Pick a profile, point it at a file, and get a properly encoded output without memorizing ffmpeg flags.

```bash
# Install via Homebrew (macOS)
brew install TheBluWiz/taps/muxm

# Encode for Apple TV Direct Play — that's it
muxm --profile atv-directplay-hq movie.mkv
```

<a id="why-muxmaster"></a>

## 💡 Why MuxMaster?

Getting a Blu-ray rip to direct-play correctly on an Apple TV, a Roku, or through Plex — without the server transcoding on the fly — is a surprisingly deep problem. The video might be Dolby Vision Profile 7 that needs conversion to Profile 8.1. The audio might be TrueHD, which your player can't direct-play, so you need E-AC-3 — or AAC stereo if the target is a phone or an old Roku. PGS subtitle bitmaps are OCR'd to soft text (SRT or mov_text) when the container requires it — only the `universal` profile burns forced subs, and any profile can opt in via `--sub-burn-forced`. And the color space metadata needs to survive the whole process.

You can solve all of this with raw ffmpeg, but the command will be 15+ flags long, different for every source file, and you'll need to inspect the source with ffprobe first to figure out what half those flags should even be. Every new file is a new puzzle.

**HandBrake** is the go-to GUI for video encoding, and it's excellent for what it does. But its preset system doesn't adapt to what's actually in the file. It can't detect that your source is already Apple TV-compliant and skip the encode. It doesn't extract Dolby Vision RPUs, convert between DV profiles, or inject them back into re-encoded video. It won't selectively OCR your PGS subtitles to SRT when the output container can't carry bitmaps. And it won't generate a JSON report of everything it did for your records. HandBrake gives you a good encode; MuxMaster gives you an opinionated pipeline that understands the relationship between your source, your target device, and every stream in the file.

**Tdarr** solves the batch-processing and automation problem well, especially at library scale. But it requires a server, a database, a web UI, and Node.js — it's infrastructure. If you want to process a single file, or a handful of files, with precise control over DV handling, audio track selection, and subtitle policy, Tdarr's plugin system means writing JavaScript to configure what `muxm` handles with a single `--profile` flag. Tdarr is a media library manager; MuxMaster is a per-file encoding tool that aims to make every decision correctly so you don't have to inspect the output.

MuxMaster sits in the gap between "I know ffmpeg well enough to do this manually" and "I need a server-based automation platform." It's a single Bash script with only three required packages (ffmpeg, jq, and bc) and optional tooling for Dolby Vision and subtitle OCR. It understands Dolby Vision at the RPU level, and its profile system encodes the tribal knowledge of what actually works on real hardware into repeatable, overridable presets.

Configuration is where the design philosophy comes together. Most CLI tools expect you to read the source code to learn which variables exist, then hand-build a dotfile from scratch. `muxm --create-config` generates a complete, commented config file pre-seeded with a real profile's values — you start from a working baseline and customize, not from a blank page. Configs cascade through three tiers (system, user, project) so an encoding team can lock organization defaults in `/etc/.muxmrc` while individuals override their preferred CRF or audio settings in `~/.muxmrc` and specific project directories can pin a streaming profile. And `--print-effective-config` shows you the fully resolved result of all those layers *before* you commit to an encode, so you always know exactly what's about to happen.

---

## Table of Contents

- [Format Profiles](#format-profiles)
- [How It Works](#how-it-works)
- [Installation](#installation)
  - [Upgrading](#upgrading)
- [Usage](#usage)
- [Why MuxMaster?](#why-muxmaster)
- [Configuration](#configuration)
- [Additional Features](#additional-features)
- [FAQ](#faq)
- [License](#license)
- [Bug Reports](#bug-reports)
- [Contact](#contact)
- [Author](#author)
- [Changelog](#changelog)

---

<a id="format-profiles"></a>

## 🎯 Format Profiles

Profiles are named presets that configure `muxm` for a specific use case in a single flag. Every setting a profile changes can be individually overridden with CLI flags.

```bash
muxm --profile <name> input.mkv
```

| Profile | Goal | Video | Audio | Subtitles | DV |
| --- | --- | --- | --- | --- | --- |
| `archive` | Lossless preservation | Copy (no re-encode) | All tracks, lossless passthrough | Multi-track stream-copy (all types, up to 99) | Preserve |
| `hdr10-hq` | Max HDR10 quality | HEVC CRF 17 | Lossless passthrough | Single-track per type, soft subs | Strip |
| `atv-directplay-hq` | Apple TV Direct Play | HEVC Main10 (copy if compliant) | E-AC-3 | Soft forced (mov_text); others as mov_text; PGS→OCR | Convert to P8.1 (auto, if possible) |
| `av1-hq` | High-quality AV1 archive | AV1 CRF 20, preset 6 | Lossless passthrough | Single-track per type, soft subs | Disabled (AV1 pipeline) |
| `streaming-hevc` | Modern HEVC streaming | HEVC CRF 20 | E-AC-3 448k | Soft forced + full (no SDH); PGS→OCR | Strip |
| `streaming-av1` | AV1 streaming | AV1 CRF 30, preset 6 | Opus 256k | Soft forced + full (no SDH); PGS→OCR | Strip |
| `animation` | Anime/cartoon optimized | HEVC CRF 16, 10-bit | Lossless passthrough | Multi-track stream-copy (up to 6); preserve ASS/SSA | Strip |
| `atv-directplay-animation` | Anime for Apple TV Direct Play | HEVC CRF 16, slower, animation psy params | E-AC-3 (lossless transcoded for ATV) | Multi-track; native ASS/SSA; soft forced | Strip |
| `universal` | Play anywhere | H.264 SDR (tone-map HDR) | AAC stereo (native preferred, else downmix) | Burn forced; export others as external SRT | Strip |
| `youtube-upload` | YouTube upload prep | H.264 High CRF 16, slow | Best-scored track (surround allowed) | Soft forced; export full subs as SRT | Disabled (HDR10 preserved) |

### `archive` — Lossless Archival

For collectors who want bit-perfect preservation. Copies video without re-encoding, keeps all matching audio and subtitle tracks via lossless stream-copy, and generates a JSON report with a checksum (SHA-256 by default; use `--checksum-algo blake2b` for BLAKE2b via `b2sum`). Always outputs MKV. Commentary and descriptive audio tracks are dropped by default. Language filtering is controlled by `AUDIO_LANG_PREF` and `SUB_LANG_PREF` — when empty (the default), all languages pass. Skips processing entirely if the source already matches.

> Formerly `dv-archival`, which is still accepted as a deprecated alias.

```bash
muxm --profile archive movie.mkv
```

### `hdr10-hq` — High Quality HDR10

Strips Dolby Vision layers and re-encodes to clean HDR10 HEVC at CRF 17. Preserves lossless audio (TrueHD, DTS-HD MA, FLAC) via passthrough. MKV output.

```bash
muxm --profile hdr10-hq movie.mkv
```

### `atv-directplay-hq` — Apple TV Direct Play

Targets true Direct Play on Apple TV 4K via Plex: MP4 container, HEVC Main10 with DV Profile 8.1 when possible, E-AC-3 surround (with Atmos JOC when present), and soft forced subtitles (mov_text). Copies compliant video without re-encoding. Skips processing if source is already ATV-compliant.

```bash
muxm --profile atv-directplay-hq movie.mkv
```

### `av1-hq` — High-Quality AV1

High-fidelity AV1 encode via SVT-AV1. CRF 20, preset 6, lossless audio passthrough, MKV container, and SHA-256 checksum enabled by default. Dolby Vision is automatically disabled — the AV1 encode pipeline does not support DV muxing. Intended as a modern space-efficient alternative to `hdr10-hq` for clients with AV1 decode support.

> **Requires AV1 encoder support in ffmpeg.** Unlike Dolby Vision tools, a missing AV1 encoder is a fatal error — ffmpeg will exit immediately. A standard `brew install ffmpeg` does not include AV1 encoders. Use `brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-svt-av1` for SVT-AV1 (`libsvtav1`) or `--with-libaom` for libaom (`libaom-av1`), or run `muxm --install-dependencies` to check what's available.

```bash
muxm --profile av1-hq movie.mkv
```

### `streaming-hevc` — Modern HEVC Streaming

Optimized for Plex, Jellyfin, and Emby on modern clients: Shield, Fire TV, Roku Ultra, smart TVs, and web browsers. HEVC CRF 20 with E-AC-3 surround at streaming-friendly bitrates and soft subtitles. Always outputs MP4. Strips DV and keeps HDR10. Balances quality with file size.

> Formerly `streaming`, which is still accepted as a deprecated alias.

```bash
muxm --profile streaming-hevc movie.mkv
```

### `streaming-av1` — AV1 Streaming

AV1 streaming encode for modern clients with AV1 decode support (Fire TV Stick 4K Max, Chromecast with Google TV, web browsers). AV1 CRF 30, preset 6, Opus audio at 256k (`AUDIO_FORCE_BITRATE="256k"`), soft subtitles. Always outputs MP4. Strips DV; HDR10 preserved. Delivers smaller files than `streaming-hevc` at equivalent perceptual quality on supported hardware.

> **Requires AV1 encoder support in ffmpeg** — see the note under [`av1-hq`](#av1-hq--high-quality-av1) above.

```bash
muxm --profile streaming-av1 movie.mkv
```

### `animation` — Anime & Cartoon Optimized

Tuned for animation content: lower psy-rd/psy-rdoq to avoid ringing on hard cel edges, 10-bit even for SDR to eliminate banding in gradients, and lossless audio passthrough. MKV container preserves styled ASS/SSA subtitles. All matching subtitle tracks — including PGS bitmap streams — are stream-copied from source (up to 6). Chapter markers are preserved.

```bash
muxm --profile animation movie.mkv
```

### `atv-directplay-animation` — Anime for Apple TV Direct Play

Combines the animation-tuned encoder settings of the `animation` profile with the Apple TV Direct Play constraints of `atv-directplay-hq`. Encodes at CRF 16 with the `slower` preset and animation-optimized psychovisual parameters (`psy-rd=1.0`, `psy-rdoq=0.5`, `aq-mode=3`) to suppress ringing on hard cel edges and eliminate banding in gradients. Audio is transcoded to E-AC-3 surround for ATV compatibility — lossless codecs (TrueHD, DTS-HD MA, FLAC) that cannot direct-play on Apple TV are re-encoded rather than passed through. All matching subtitle tracks are stream-copied in multi-track mode, with native ASS/SSA preserved when the output is MKV. Forced subtitles are embedded as soft subs in any container — no burn-in. Container follows the source: MKV in, MKV out; MP4 in, MP4 out.

```bash
muxm --profile atv-directplay-animation show.mkv
```

### `universal` — Universal Compatibility

Plays on everything: old Rokus, mobile devices, web browsers, and non-HDR TVs. Tone-maps HDR to SDR, encodes to H.264, produces a single AAC stereo track (selects the best native stereo track if present; otherwise downmixes the best-scored surround track to stereo), burns forced subtitles, exports others as external SRT, and strips chapters and non-essential metadata. Always outputs MP4.

```bash
muxm --profile universal movie.mkv
```

### `youtube-upload` — YouTube Upload Prep

Optimized for uploading to YouTube. Encodes to H.264 High profile at CRF 16 with the `slow` preset in an MP4 container. Audio is kept as the best-scored track — surround is allowed and passed through, giving YouTube's encoder the cleanest source. Forced subtitles are embedded as soft subs (mov_text); all other dialogue subtitles (excluding SDH) are exported as an external `.srt` file for upload to YouTube Studio. Dolby Vision is disabled; HDR10 metadata is preserved so YouTube can use it during its own re-encode. Strips non-essential metadata; chapter markers are preserved.

Because YouTube re-encodes every upload regardless, the goal is to give YouTube's encoder the cleanest, highest-quality source possible — not to minimize file size. CRF 16 with `slow` delivers near-transparent quality that survives YouTube's compression with noticeably less artifacting than a smaller source would.

```bash
muxm --profile youtube-upload movie.mkv
```

### Overriding Profile Defaults

Use CLI flags to customize any profile on the fly:

```bash
# Use archive but keep only English and Japanese audio (drops all other languages)
muxm --profile archive --audio-lang-pref eng,jpn movie.mkv

# Use hdr10-hq but with a different CRF and an added AAC stereo fallback track
muxm --profile hdr10-hq --crf 20 --stereo-fallback movie.mkv

# Use universal but keep chapters
muxm --profile universal --keep-chapters movie.mkv
```

---

<a id="how-it-works"></a>

## 🔧 How It Works

<details>
<summary>Expand to see the full encoding pipeline</summary>

When you run `muxm`, the script executes a multi-stage pipeline that inspects the source file, makes codec and container decisions based on the active profile, processes each stream type independently, and assembles the final output. Here's what happens under the hood:

**1. Source Inspection.** `muxm` calls ffprobe once and caches the full JSON metadata for the source file. Every subsequent decision — codec detection, color space identification, audio channel layout, subtitle format — reads from this cache rather than re-probing.

**2. Profile Resolution.** Settings are resolved through a layered precedence chain: hardcoded defaults → system config (`/etc/.muxmrc`) → user config (`~/.muxmrc`) → project config (`./.muxmrc`) → profile → CLI flags. Contradictory combinations (like `--profile archive --no-dv`) trigger warnings but never errors — CLI flags always win.

**3. Video Pipeline.** The video stage handles the most complexity. It detects Dolby Vision by probing both stream metadata and frame-level side data, then identifies the DV profile (5, 7, or 8) and compatibility ID. For profiles that preserve DV, it extracts the RPU (Reference Processing Unit) via `dovi_tool`, converts between DV profiles when necessary (e.g., Profile 7 dual-layer → Profile 8.1 single-layer), encodes the base layer with x265, and injects the RPU back into the encoded stream. For non-DV profiles, it detects the source color space (BT.2020 PQ, BT.2020 HLG, or BT.709 SDR), sets the matching x265 or x264 color parameters and pixel format, and applies tone-mapping when the profile targets SDR output.

**4. Audio Pipeline.** Audio track selection operates in one of two modes. In single-track mode (the default for most profiles), `muxm` scores each track based on language match, channel count, surround layout, codec preference, and bitrate — with configurable weights in `.muxmrc` (see `man muxm` for details). The pipeline picks the best available track (honoring `--audio-lang-pref`) and decides whether to copy it through or transcode it based on the profile's codec requirements. The `universal` profile additionally prefers a native stereo track when one exists (`AUDIO_PREFER_STEREO`), falling back to a downmix of the best-scored surround track otherwise. A second AAC stereo fallback track can be added alongside a surround primary with `--stereo-fallback` (off by default in every profile). In multi-track mode (`AUDIO_MULTI_TRACK=1`, enabled by `archive`), all tracks that pass the language and commentary filters are stream-copied directly from the source — no scoring, no transcoding, no intermediate files. Commentary and descriptive audio tracks can be excluded via `AUDIO_KEEP_COMMENTARY`. Lossless codecs (TrueHD, DTS-HD MA, FLAC) are passed through untouched when the profile and container support it.

**5. Subtitle Pipeline.** Subtitles are categorized into forced, full, and SDH tracks. In single-track mode (the default for most profiles), `muxm` selects one track per type based on language preference and can exclude SDH tracks. PGS bitmap subtitles are OCR'd to SRT (via `pgsrip` or `sub2srt`) when the output container can't carry them natively. In multi-track mode (`SUB_MULTI_TRACK=1`, enabled by `archive` and `animation`), all tracks that pass the language and type filters are stream-copied from the source — no OCR, no format conversion. Bitmap subtitles (PGS, VobSub) that cannot be muxed into the target container are silently skipped; MKV handles all formats. `SUB_MAX_TRACKS` caps the total number of subtitle streams kept. Text-based subtitles (ASS/SSA) can be preserved in their native format — retaining positioning, fonts, and typesetting — when the output container is MKV (`--sub-preserve-format`), or converted to plain-text SRT for broader compatibility; this applies in both single-track and multi-track modes. Forced subtitles can be burned into the video stream; other tracks can be embedded or exported as external `.srt` files.

**6. Final Mux.** All processed streams are assembled into the target container (MP4, MKV, M4V, or MOV) with correct codec tagging, chapter markers, subtitle disposition flags, and metadata. For Dolby Vision in MP4, `muxm` verifies that the `dvcC`/`dvvC` container signaling record is present via `MP4Box`.

**7. Verification.** The output file is validated with ffprobe to confirm it's non-empty and parseable. Optionally, a checksum is written (SHA-256 via `.sha256`, or BLAKE2b via `.b2` when `--checksum-algo blake2b` is used) and a JSON report is generated documenting every decision, warning, and stream mapping from the run.

If any stage fails, `muxm` logs the failure, cleans up incomplete temp files, and exits with a descriptive error code. The `--dry-run` flag executes the entire decision pipeline without writing real output, so you can preview exactly what `muxm` would do before committing to an encode.

</details>

---

<a id="installation"></a>

## 📦 Installation

<a id="compatibility"></a>

### Compatibility

`muxm` requires Bash 4.3+ and runs on macOS (10.15 Catalina or later) and modern Linux distributions (Ubuntu 20.04+, Fedora 33+, Debian 11+, Arch). It is tested primarily on macOS with Homebrew-installed ffmpeg builds.

**Hardware acceleration** is supported on **macOS (Apple VideoToolbox) only**. On Linux, `--hw-accel` is accepted but encoding always runs in software. See [`docs/HW_ACCEL.md`](docs/HW_ACCEL.md) for the full architecture and backend matrix.

### Homebrew (recommended — macOS)

```bash
brew install TheBluWiz/taps/muxm
muxm --install-completions      # bash/zsh tab completion
```

This installs `muxm` with its required dependencies (bash 4.3+, ffmpeg, jq, bc) and the man page automatically.

**Optional dependencies** — for Dolby Vision, subtitle OCR, and subtitle burn-in:

```bash
muxm --install-dependencies       # installs everything missing in one pass
```

After installing ffmpeg, `--install-dependencies` checks whether the installed build includes AV1 encoder support (`libsvtav1` or `libaom-av1`). If AV1 encoders are missing, it prints an advisory with the exact `brew` commands needed — nothing is automatically replaced, since swapping a working ffmpeg install is a significant step.

Or install individually as needed:

```bash
brew install dovi_tool            # Dolby Vision RPU handling
brew install gpac                 # DV container signaling (MP4Box)
brew install tesseract            # PGS subtitle OCR engine
brew install ffmpeg-full          # ffmpeg with libass (for --sub-burn-forced) + tesseract
```

### Manual Install (macOS/Linux)

```bash
git clone https://github.com/TheBluWiz/MuxMaster.git
cd MuxMaster
chmod +x muxm
sudo cp muxm /usr/local/bin/muxm
muxm --setup                     # installs dependencies, man page, and tab completion
```

### Dependencies

**Required:**

- **ffmpeg** and **ffprobe** – core encoding and media inspection
- **jq** – JSON parsing for stream metadata and reporting
- **bc** – arithmetic evaluation for frame-rate and bitrate calculations

**Optional (auto-disabled if missing):**

- **ffmpeg with libass** (`ffmpeg-full` on Homebrew) – required for subtitle burn-in (`--sub-burn-forced`); the standard `ffmpeg` package works for all other features
- **ffmpeg with AV1 encoder** (`libsvtav1` or `libaom-av1`) – required for `av1-hq` and `streaming-av1` profiles; a missing AV1 encoder is a fatal error (unlike missing DV tools, it cannot be silently disabled). Not included in the standard Homebrew `ffmpeg` formula.
- **dovi_tool** – Dolby Vision RPU extraction/injection; DV handling is automatically disabled if missing
- **MP4Box** (gpac) – DV container-level signaling verification
- **tesseract** – OCR engine required by `pgsrip` for PGS bitmap subtitle conversion
- **sub2srt** or **pgsrip** – PGS bitmap subtitle OCR to SRT (configurable via `--ocr-tool`)

### Setup Helpers

```bash
# First-time setup (manual installs only): dependencies, man page, and tab completion
muxm --setup

# Or run individually:
muxm --install-dependencies
muxm --install-man
muxm --install-completions

# Generate a config file pre-filled with a profile's defaults
muxm --create-config user atv-directplay-hq   # ~/.muxmrc
muxm --create-config project streaming         # ./.muxmrc

# Remove installed components
muxm --uninstall-man
muxm --uninstall-completions
```

<a id="upgrading"></a>

### Upgrading

**Homebrew:**

```bash
brew upgrade muxm
```

The man page and tab completions are refreshed automatically on every upgrade — no extra steps needed.

**Manual installs:**

Pull the latest version and re-run setup to update the man page, completions, and dependencies:

```bash
cd MuxMaster && git pull
sudo cp muxm /usr/local/bin/muxm
muxm --setup
```

---

<a id="usage"></a>

## 🚀 Usage

```bash
muxm [options] <source> [target.mp4]
```

### Arguments

- `<source>` – Input media file (e.g., `movie.mkv`)
- `[target]` – Output file (optional; defaults to `<source>.<output-ext>`). If the derived output path would overwrite the source file, `muxm` auto-appends a version number: `movie(1).mp4`, `movie(2).mp4`, etc.

### Key Flags

| Flag | Description |
| --- | --- |
| `--profile NAME` | Apply a format profile (`archive`, `hdr10-hq`, `atv-directplay-hq`, `atv-directplay-animation`, `av1-hq`, `streaming-hevc`, `streaming-av1`, `animation`, `universal`, `youtube-upload`) |
| `--dry-run` | Simulate without writing output |
| `--crf N` | Set video CRF value |
| `-p, --preset NAME` | x265 encoder preset (e.g., `slow`, `medium`) |
| `--video-codec libx265\|libx264` | Video encoder |
| `--tonemap` | Tone-map HDR to SDR |
| `--dv` / `--no-dv` | Enable or disable Dolby Vision handling (overrides profile) |
| `--dv-convert-p81` / `--no-dv-convert-p81` | Convert DV to Profile 8.1 when native injection fails (default: on) |
| `--audio-lang-pref LANGS` | Audio language preference (comma-separated, e.g., `eng,jpn`) |
| `--audio-force-codec CODEC` | Force all audio to a specific codec |
| `--audio-force-bitrate RATE` | Override bitrate for all non-lossless audio output (e.g., `256k`); overrides codec-specific bitrate variables |
| `--audio-lossless-passthrough` | Allow lossless codecs to pass through |
| `--sub-lang-pref LANGS` | Subtitle language preference (comma-separated) |
| `--sub-burn-forced` | Burn forced subtitles into video |
| `--sub-preserve-format` | Keep ASS/SSA subtitles in native format (MKV only; use `--no-sub-preserve-format` to force SRT conversion) |
| `--sub-preserve-bitmap` / `--no-sub-preserve-bitmap` | Stream-copy PGS bitmap subtitles to MKV without OCR (default: on; no effect for MP4/MOV) |
| `--output-ext mp4\|mkv\|m4v\|mov` | Output container |
| `--report-json` | Generate a JSON report alongside the output file |
| `--checksum` | Write a checksum sidecar for the output (SHA-256 by default) |
| `--checksum-algo sha256\|blake2b\|auto` | Checksum algorithm (`auto` prefers `b2sum`, falls back to sha256) |
| `--strip-metadata` | Strip non-essential metadata |
| `--skip-if-ideal` | Skip processing if source matches target |
| `--replace-source` | Replace the original source file (interactive confirmation) |
| `--force-replace-source` | Replace the original source file (no prompt; scripting-friendly) |
| `--print-effective-config` | Show resolved config after config file imports |

**Multi-profile encoding:** Pass comma-separated profiles to encode the same source once per profile. Output filenames are auto-suffixed with the profile name, and each profile runs sequentially:

```bash
muxm --profile youtube-upload,streaming source.mkv
# → source.youtube-upload.mp4  source.streaming.mp4
```

**Output container inference:** When you provide an explicit output filename, `muxm` infers the container from its extension — `output.mkv` forces MKV regardless of the profile default.

Run `muxm --help` for the full flag reference.

---

<a id="configuration"></a>

## ⚙️ Configuration

`muxm` has a layered configuration system designed so you set your preferences once and override only when you need to.

Settings are resolved through multiple levels, applied in this order (lowest → highest precedence):

```
Hardcoded defaults
  → /etc/.muxmrc           (system-wide)
    → ~/.muxmrc            (user defaults)
      → ./.muxmrc          (project-specific)
        → --profile        (format profile)
          → CLI flags      (highest — always wins)
```

### Setting a Default Profile

Add to any `.muxmrc` file:

```
# ~/.muxmrc — always use Apple TV Direct Play unless overridden
PROFILE_NAME="atv-directplay-hq"
```

CLI `--profile` always overrides a config-file `PROFILE_NAME`.

### Creating a Config File

Use `--create-config` to generate a `.muxmrc` file pre-configured for a profile:

```bash
muxm --create-config <scope> [profile]
```

| Scope | Path |
|---|---|
| `system` | `/etc/.muxmrc` |
| `user` | `~/.muxmrc` |
| `project` | `./.muxmrc` (current directory) |

Pass CLI flags to pre-set specific values:

```bash
muxm --create-config user atv-directplay-hq --crf 20 --preset medium
```

See `man muxm` for the full list of 40+ supported override flags. Use `--force-create-config` to overwrite an existing file.

### Verifying Effective Configuration

When configs cascade through multiple layers, it's easy to lose track of what's actually active. `--print-effective-config` resolves every layer and shows you the final result before anything is encoded:

```bash
# See what the resolved config looks like after all sources merge
muxm --profile hdr10-hq --crf 20 --print-effective-config
```

Every variable is displayed grouped by section, with the active profile name and the source of each override (CLI, config file, or profile default). No more guessing what a run will do.

---

<a id="additional-features"></a>

## 📋 Additional Features

Beyond profiles and the core encoding pipeline, `muxm` ships with a set of operational features that make it safer and easier to use in practice:

- **Skip-if-Ideal** – Before encoding, `muxm` inspects the source to determine if it already matches the target profile. If it does, the file is linked or copied without re-encoding, saving time and avoiding generation loss. When multi-track audio or subtitle modes are active, the ideal check verifies that every source track would survive the filter — if any would be dropped, the source is not ideal and remuxing proceeds with explicit per-stream maps. Enabled per-profile or via `--skip-if-ideal`.
- **Collision Handling** – When the derived output filename matches the source (e.g., encoding `movie.mp4` with the default `.mp4` extension), `muxm` auto-versions the output to `movie(1).mp4`, `movie(2).mp4`, etc. instead of failing. Use `--replace-source` for interactive in-place replacement or `--force-replace-source` for scripted workflows.
- **Conflict Warnings** – Running `--profile archive --no-dv` doesn't error out — it warns you that the combination is contradictory and proceeds with your explicit flags taking precedence. Flags that are incompatible with multi-track modes (e.g., `--audio-track`, `--audio-force-codec`, `--sub-burn-forced`) trigger a graceful demotion: multi-track mode drops to single-track mode with an informational note, and the explicit CLI flag wins. The tool trusts you but lets you know when something looks wrong.
- **Dry-Run Mode** – `--dry-run` executes the entire decision pipeline (profile resolution, codec detection, DV identification, audio selection) and prints what it would do, without writing any output files.
- **JSON Reporting** – `--report-json` generates a machine-readable JSON report alongside the output file, documenting every decision, warning, codec mapping, and stream disposition from the run.
- **Checksum Verification** – Writes a checksum sidecar for the output to verify integrity after transfer or archival. Defaults to SHA-256 (`.sha256`); use `--checksum-algo blake2b` for BLAKE2b (`.b2`, requires `b2sum`), or `--checksum-algo auto` to prefer BLAKE2b when available. Enabled by default for `archive`; available for other profiles via `--checksum`.
- **External Subtitle Discovery** – At startup, `muxm` automatically scans for sidecar subtitle files alongside the source: `.srt`, `.ass`, `.ssa`, `.vtt`, `.sup`, and `.idx`. Common filename conventions are recognized — `movie.en.srt`, `movie.forced.en.srt`, and similar patterns — and discovered tracks are fed into the subtitle pipeline alongside embedded streams, subject to the same language and type filters already in effect. Enabled by default; use `--no-ext-subs` to opt out, or `--ext-subs-dir` to point at a different search directory. See `man muxm` for the full filename convention reference.
- **Man Page** – A full `muxm(1)` manual page with complete flag reference, profile documentation, and examples, accessible via `man muxm`. See [Installation → Setup Helpers](#installation) for setup commands.
- **Tab Completion** – bash/zsh tab completion for all flags, profiles, presets, and config scopes. Completes media file extensions when providing input files. See [Installation → Setup Helpers](#installation) for setup commands.
- **Live Progress Bar** – During encoding, `muxm` displays a live progress bar showing percentage complete and elapsed time via Unicode block characters (▏▎▍▌▋▊▉█), updated in real-time through a named FIFO. A clean single-line indicator replaces the raw ffmpeg output and clears automatically when the encode finishes.
- **Smart Disk Space Preflight** – Before starting an encode, `muxm` estimates the required output size from the source video bitrate, CRF value, codec, preset, and audio configuration using conservative CRF-to-ratio lookup tables with a 25% safety margin. Both the output volume and the temp volume (when on a separate device) are checked. If available space appears insufficient, the run is aborted early rather than failing mid-encode and leaving a partial file. Use `--no-disk-check` to disable, or set `DISK_CHECK=0` in `.muxmrc`.
- **Signal Handling** – `muxm` catches `SIGINT` (Ctrl-C), `SIGTERM`, and `SIGHUP` and performs a clean shutdown: partial output files and temp files are removed, the named FIFO is cleaned up, and a brief summary is printed before exit. No stray temp files left behind.
- **DEBUG=1 Trace Mode** – Set `DEBUG=1` in your environment (`DEBUG=1 muxm --profile streaming movie.mkv`) to enable verbose trace output. Every major decision point — profile resolution, codec detection, DV identification, stream selection — is logged to stderr, making it straightforward to diagnose unexpected behavior without modifying the script. Debug mode also traces jq metadata cache queries (filter expression, exit code, and result preview), which is useful for diagnosing probe failures or unexpected stream detection results.

---

<a id="faq"></a>

## ❓ FAQ

**`muxm` says it requires Bash 4.3+ but I'm on macOS.**
macOS ships Bash 3.2 (2007) due to licensing. If you installed via Homebrew (`brew install TheBluWiz/taps/muxm`), this is handled automatically — the formula rewrites the shebang to use Homebrew's bash. For manual installs, run `brew install bash` and make sure `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash` (Intel) appears before `/bin/bash` in your `$PATH`.

**Dolby Vision handling seems to be disabled / I don't see DV in my output.**
DV processing requires `dovi_tool` and, for MP4 container signaling, `MP4Box` (gpac). If either is missing, `muxm` silently disables DV features rather than failing. Run `muxm --install-dependencies` to install them, or check with `muxm --dry-run` — the output will show whether DV was detected and what the pipeline plans to do with it.

**My file was copied instead of re-encoded. Is that a bug?**
Probably not. If the source already matches the target profile (correct codec, container, color space, and audio layout), `muxm` skips the encode and copies/links the file. This is the Skip-if-Ideal feature — it saves time and avoids generation loss. You'll see a message indicating the skip. To force a re-encode, pass `--no-skip-if-ideal` or override a setting (e.g., `--crf 18`) so the source no longer matches.

**Which profile should I use?**
If you're playing through Plex on an Apple TV 4K: `atv-directplay-hq`. If you want broad device compatibility across Plex/Jellyfin/Emby clients: `streaming-hevc`. If your clients support AV1 decode (Fire TV Stick 4K Max, Chromecast with Google TV, modern browsers) and you want smaller files: `streaming-av1`. For a high-quality AV1 archive on AV1-capable hardware: `av1-hq`. If you're archiving a disc rip and want all audio and subtitle tracks preserved losslessly: `archive`. If you need it to play on everything including old hardware and phones: `universal`. For anime or cartoons: `animation`. For anime or cartoons that need to direct-play on an Apple TV: `atv-directplay-animation`. For clean HDR10 without DV complexity: `hdr10-hq`. If you're uploading to YouTube and want to give YouTube's encoder the cleanest possible source to re-encode from: `youtube-upload`. When in doubt, start with `--dry-run` to preview what a profile will do to your file.

**Can I process a batch of files?**
`muxm` is a per-file tool by design. For a batch, a simple shell loop works:

```bash
for f in *.mkv; do muxm --profile streaming-hevc "$f"; done
```

For library-scale automation, consider pairing `muxm` with `find`, `xargs`, or a job runner like GNU Parallel.

**How do I know what settings are actually active?**
Run `muxm --print-effective-config` (with any profile and flags you plan to use). It resolves every config layer — defaults, system/user/project `.muxmrc` files, profile, and CLI flags — and prints the final result. Nothing is encoded; it just shows you exactly what would happen.

**The output file is larger than I expected.**
CRF-based encoding targets quality, not file size. A visually complex source (grain, fast motion, high detail) will produce a larger file at the same CRF than a clean digital source. You can lower quality slightly with a higher `--crf` value (e.g., `--crf 22` instead of the default), or use a slower `--preset` (`slow` or `slower`) which achieves better compression at the same quality — at the cost of longer encode time.

---

<a id="license"></a>

## 📄 License

MuxMaster is freeware for personal, non-commercial use.
Any business, government, or organizational use requires a paid license.

Full license text available in [LICENSE.md](LICENSE.md).

---

<a id="bug-reports"></a>

## 🐛 Bug Reports

Found a bug? Please [open an issue on GitHub](https://github.com/TheBluWiz/MuxMaster/issues). Include the output of `muxm --version`, the profile and flags you used, and any relevant log output. A `--dry-run` dump or `--report-json` output is especially helpful.

This is a solo project — not taking outside code contributions right now, but bug reports and feedback are always welcome.

---

<a id="contact"></a>

## 📬 Contact

If you're using MuxMaster, I'd love to hear about it — what's working, what's not, what workflows you're using it for. This is a solo project and real-world feedback shapes what gets built next.

- **Bug reports** → [GitHub Issues](https://github.com/TheBluWiz/MuxMaster/issues)
- **Everything else** (feedback, licensing, questions) → [thebluwiz@thoughtspace.place](mailto:thebluwiz@thoughtspace.place)

---

<a id="author"></a>

## 👤 Author

Jamey Wicklund ([@TheBluWiz](https://github.com/TheBluWiz))

---

<a id="changelog"></a>

## 📝 Changelog

See [CHANGELOG.md](CHANGELOG.md) for the full release history.
