# MuxMaster

**MuxMaster** – a versatile, cross-platform video repacking and encoding utility that preserves HDR, Dolby Vision, and high-quality audio while optimizing for Plex and Apple TV Direct Play. Supports smart codec handling, color space matching, error recovery, and optional stereo fallback.

## Table of Contents
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Examples](#examples)
- [Going Forward](#goingforward)
- [License](#license)
- [Contributing](#contributing)
- [Author](#author)


## ✨ Features <a id="features"></a>

- **Preserves HDR & Dolby Vision** – Keeps original color depth and HDR metadata where possible
- **Audio Preservation** – Retains E-AC-3, AC-3, or AAC without re-encoding; converts others to best Direct Play-compatible format
- **Stereo Fallback** – Optionally creates a high-quality stereo track for compatibility
- **Error Recovery** – Detects, logs, and gracefully handles mid-process failures
- **Color Space Matching** – Matches output color space & depth to the source if not Dolby Vision
- **Cross-Platform** – Works on macOS and most modern Linux distributions
- **Dry-Run Mode** – Test workflows without writing files
- **Checksum Verification** – Ensures output integrity
- **Clean-up on Failure** – Removes incomplete temp files when an error occurs

---

## 📦 Installation <a id="installation"></a>

```bash
# Clone the repository
git clone https://github.com/theBluWiz/muxmaster.git
cd muxmaster

# Make the script executable
chmod +x muxm

# Optionally move to a location in your PATH
sudo mv muxm /usr/local/bin/muxm
```

## 🚀 Usage <a id="usage"></a>

```bash
muxm <source file> <target file>
```
### Arguments:
- `<source file>` – Input media file (e.g., `movie.mkv`)
- `<target file>` – Output file (e.g., `movie.mp4`)
### Flags:
- `--dry-run` – Simulate without writing output
- `--parallelize` / `-p` – Encode audio in parallel

## 🔍 Examples <a id="examples"></a>

```bash
# Standard encode, defaults to CRF 18 and 192k stereo fallback
muxm input.mkv output.mp4

# Dry run for testing
muxm --dry-run input.mkv output.mp4
```

## Going Forward <a id="goingforward"></a>
-	Environment Configuration – Support local (.env.local) and global (.env) files to adjust constants, variables, and flags without editing the script.
-	Batch Directory Processing – Add logic to process all compatible files in a directory (including subdirectories) with filtering by extension or codec.
-	Parallel Processing Option – Allow multi-threaded encoding when hardware resources are available, with automatic core detection.
-	Codec Expansion – Broaden compatibility to include VP9, AV1, and ProRes workflows while preserving current Dolby Vision/HDR handling.
-	Format Presets – Introduce named presets for different targets (Apple TV, Plex, archival storage, YouTube).
-	Logging Enhancements – Support JSON log output for easier integration with monitoring systems or CI pipelines.
-	Interactive Mode – Add a guided CLI wizard for non-technical users to configure a job without needing full command-line knowledge.
-	Self-Update Mechanism – Include an update command to pull the latest release from GitHub automatically.
-	Custom Naming Templates – Allow users to define output filename patterns with variables (e.g., {title}_{codec}_{crf}).
-	Checksum Verification – Integrate optional hash verification of inputs and outputs for data integrity.

## 📄 License <a id="license"></a>

MuxMaster is freeware for personal, non-commercial use.
Any business, government, or organizational use requires a paid license.

Full license text available in [LICENSE.md](./LICENSE.md)

## 🤝 Contributing <a id="contributing"></a>

Contributions are welcome for bug reports, feature requests, and documentation improvements.
Please note that all code changes must be approved by the maintainer and comply with the license.

## 👤 Author <a id="author"></a>

Maintainer: Jamey Wicklund (theBluWiz)  
Email: [thebluwiz@thoughtspace.place](mailto:thebluwiz@thoughtspace.place)

> **Tip:** If you are a hiring manager or recruiter, this project demonstrates advanced Bash scripting, media processing workflows, error handling, and cross-platform compatibility design.