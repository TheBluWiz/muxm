# muxm Presets

Below are the four main presets for `muxm`, listed **from highest fidelity to widest compatibility**.  
Each preset includes **who/where it’s for**, **its goal**, and **default behaviors**.

---

## 1) `dv-archival` — High Quality Dolby Vision Archival
**Who/Where:**  
For collectors or Plex users with a **Dolby Vision-capable ecosystem** (e.g., Apple TV 4K + DV TV, Shield, LG WebOS w/ Plex) who want to **preserve original quality**.  
Great for long-term storage where fidelity > compatibility.

**Goal:**  
Preserve DV + HDR10 metadata and lossless audio whenever possible. Only perform **lossless remuxes** or metadata fixes. Skip processing if the file is already ideal.

**Defaults:**
- **DV policy:** `preserve` (no re-encode unless `--dv-policy reencode` specified)
- **Container:** `auto` (leave as-is; remux only if needed for structural or compatibility reasons)
- **Video:** `-c:v copy` unless DV re-encode explicitly requested
- **Audio:** keep lossless; `--stereo-fallback=off` (toggleable)
- **Subs:** keep all; detect/mark forced; fix language tags; no burn
- **Chapters/metadata:** keep and normalize
- **Skip heuristic:** `--skip-if-ideal` (enabled) — no changes if file already matches target profile
- **Reporting:** generate JSON + human-readable report of checks/fixes

---

## 2) `hdr10-hq` — High Quality HDR10 (No Dolby Vision)
**Who/Where:**  
For HDR10 TVs and mixed-device environments where DV causes quirks (e.g., older streaming devices, non-DV TVs, varied Plex clients).

**Goal:**  
Maximize HDR10 quality while avoiding DV playback issues. Keep HDR10 metadata intact, remove DV layers, preserve lossless audio, and add stereo fallback.

**Defaults:**
- **DV policy:** `strip`
- **Container:** `mkv`
- **Video:** HEVC re-encode if needed:  
  `-c:v libx265 -preset slow -crf 17 -x265-params "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display='G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)':max-cll=1000,400"`
- **Audio:** keep lossless **and** add stereo fallback (AAC 256k, `-ac 2`)
- **Subs:** keep all; default by language; no burn
- **Chapters/metadata:** preserve

---

## 3) `atv-directplay-hq` — Apple TV Direct Play (Plex) Optimized
**Who/Where:**  
Plex → **Apple TV 4K** setups, aiming for *true Direct Play* without remux/transcode.

**Goal:**  
Conform to tvOS/Plex playback constraints while keeping high quality: MP4 container, HEVC Main10 (HDR10 and optional DV P8.1), E-AC-3 audio (with Atmos JOC when present), and text-based subtitles.

**Defaults:**
- **DV policy:** `auto`  
  - Preserve DV **Profile 8.1** if present & compliant; otherwise fall back to clean **HDR10**. (Don’t output P7.)
- **Container:** `mp4` (maximize Apple TV Direct Play)
- **Video:**  
  - Prefer copy if already compliant; else:
    ```
    -c:v libx265 -preset slow -crf 17 -pix_fmt yuv420p10le \
    -x265-params "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display='G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)'"
    ```
  - If DV kept: add `:dv-profile=8.1:dv-bl-compatible-id=1`.
- **Audio:**  
  - If source is TrueHD/Atmos or DTS-HD: **transcode to E-AC-3 5.1 @ 768k** (or 640k) with Atmos JOC when possible  
  - Also include **AAC 2.0 @ 256k** as fallback  
  - (Apple TV can’t Direct Play TrueHD; E-AC-3 is the safe bet.)
- **Subs:**  
  - **Forced:** burn into video *or* convert to **mov_text**  
  - **Others:** embed **mov_text** or export **external .srt**; avoid PGS in MP4
- **Chapters/metadata:** keep chapters; normalize language tags & default flags
- **Skip heuristic:** on — if fully ATV-compliant already, do nothing and report

---

## 4) `universal` — Universal Compatibility
**Who/Where:**  
For playback **anywhere**: old Rokus, mobile devices, web browsers, non-HDR TVs. Ideal for sharing with friends/family without worrying about playback capability.

**Goal:**  
Prioritize compatibility over fidelity. Tone-map HDR to SDR H.264, ensure AAC stereo audio, burn forced subs, and strip anything that could block playback.

**Defaults:**
- **DV policy:** `strip`
- **Container:** `mp4`
- **Video:** SDR H.264, tone-mapped from HDR if present:  
  `-vf "zscale=tin=bt2020:pin=bt2020:min=bt709:t=bt709,tonemap=hable,zscale=t=bt709:m=bt709" -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p`
- **Audio:** AAC stereo (`-c:a aac -b:a 256k -ac 2`), optional AC3 5.1 (`-c:a:1 ac3 -b:a:1 640k`)
- **Subs:** burn forced; export all others as external `.srt` or embed as `mov_text` for MP4
- **Chapters/metadata:** strip chapters; minimal metadata

---

## Configuration Flexibility

These presets are **opinionated starting points** — every option is adjustable.

`muxm` reads configuration from multiple levels, applied in the following order  
(**lowest precedence** → **highest precedence**):

1. **Global config** — system-wide `/etc/muxm.conf` (shared defaults for all users/projects)
2. **User config** — `~/.muxmrc` (personal defaults across all projects)
3. **Project config** — `.muxmrc` in the current working directory (project-specific overrides)
4. **CLI arguments** — command-line flags (override everything above for a single run)

**Example:**
- Global sets `--container mkv`
- User config changes default to `--container mp4`
- Project config sets `--stereo-fallback=off`
- CLI run: `muxm --preset hdr10-hq --container mkv`

→ Result: `hdr10-hq` profile, container forced to `mkv` (from CLI), stereo fallback off (from project config).

This hierarchy ensures:
- You can **set and forget** your preferred tweaks in `~/.muxmrc`
- Projects can **enforce consistent output** regardless of your global/user defaults
- You can **override anything instantly** at the CLI without editing configs

---