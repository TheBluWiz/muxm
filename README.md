# MuxMaster

**MuxMaster** – a versatile, cross-platform video repacking and encoding utility that preserves HDR, Dolby Vision, and high-quality audio while optimizing for Plex and Apple TV Direct Play. Supports smart codec handling, color space matching, error recovery, and optional stereo fallback.

## Table of Contents
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Examples](#examples)
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