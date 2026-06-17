# Hardware Acceleration — Architecture

> **Platform support:** Hardware acceleration is supported on **macOS (Apple VideoToolbox) only**.
> On Linux, encoding always runs in software regardless of `--hw-accel` setting.
> NVENC dispatch is not yet implemented; passing `--hw-accel nvenc` falls back to software with a warning.

**Status:** VideoToolbox dispatch and calibration **shipped in v1.5.0** (Phase 2 — live-action + animation content, calibrated 2026-06-10/11). Phase 3 (NVENC) is the next milestone.

---

## 1. User-facing surface

**CLI flag:**

```
--hw-accel {none|auto|videotoolbox|nvenc}
```

**`.muxmrc` variable:**

```bash
HW_ACCEL="auto"
```

Precedence (last wins): script defaults → `/etc/.muxmrc` → `~/.muxmrc` → `./.muxmrc` → CLI. Invalid values in any config file abort with exit 11 before any encode starts.

**Default:** `none` (pure software — existing v1.4.x behavior).

---

## 2. Backend support matrix

| Backend         | HEVC | H.264 | AV1                  | Dolby Vision |
|-----------------|------|-------|----------------------|--------------|
| `none`          | ✅   | ✅    | ✅ (libsvt/libaom)   | ✅ (libx265) |
| `videotoolbox`  | ✅ (hevc_videotoolbox) | ✅ (h264_videotoolbox) | ❌ (no HW encoder on Apple Silicon) | ✅ (RPU injected post-compression via dovi_tool — encoder-agnostic) |
| `nvenc`         | ⚠️ not implemented (software fallback) | ⚠️ not implemented (software fallback) | ⚠️ not implemented (software fallback) | ❌ (DV RPU requires libx265) |

Backends that cannot satisfy a request fall back to software and record the reason in `HW_ACCEL_FALLBACK_REASON`.

---

## 3. Resolution flow

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐    ┌───────────────────────┐
│ HW_ACCEL set    │───▶│ detect_hw_accel  │───▶│ per-encode           │───▶│ resolve_video_encoder │
│ (.muxmrc / CLI) │    │ (populate        │    │ compatibility gates  │    │ (choose -c:v arg)     │
│                 │    │  AVAILABLE[],    │    │ (AV1 on VT? libaom?) │    │                       │
│                 │    │  RESOLVED)       │    │                      │    │                       │
└─────────────────┘    └──────────────────┘    └─────────────────────┘    └───────────────────────┘
```

- **`detect_hw_accel`** runs once, post-CLI parsing. Non-fatal: an explicit but missing backend leaves `HW_ACCEL_RESOLVED="none"` so `--print-effective-config` still succeeds.
- **Strict check** in Section 14 (tool validation) dies with exit 10 when an explicit `--hw-accel videotoolbox`/`--hw-accel nvenc` does not resolve. This mirrors the existing AV1 encoder strict-check pattern.
- **`resolve_video_encoder`** runs per-encode after Dolby Vision detection. It walks the gates in this order:

  1. `HW_ACCEL_RESOLVED == "none"` → software (no gate).
  2. `VIDEO_CODEC == libaom-av1` → software (no hardware libaom counterpart).
  3. `videotoolbox + libsvt-av1` → software (Apple Silicon has no AV1 hardware encode).
  4. `nvenc + libsvt-av1 + !av1_nvenc` → software (requires Ada Lovelace / RTX 40+).

  Dolby Vision is **not** a gate: VideoToolbox encodes an HDR10 base layer and the DV RPU is injected post-compression by `dovi_tool` (encoder-agnostic), then muxed with MP4Box. The VideoToolbox arm is fully implemented. NVENC dispatch is not yet implemented; the nvenc arm emits a warning and falls back to software.

---

## 4. Parameter builders

Software encoders continue to use `build_x265_params` and `build_av1_params`. `build_video_encoder_params` is the single dispatch entry point — it routes to `build_videotoolbox_params()` for VideoToolbox encoders. A future `build_nvenc_params()` will be added when NVENC dispatch is implemented.

| Encoder             | Params global        | CLI surface                                   |
|---------------------|----------------------|-----------------------------------------------|
| `libx265`           | `X265_PARAMS`        | `--x265-params`                               |
| `libx264`           | `X264_PARAMS_BASE`   | `--x264-params`                               |
| `libsvtav1`         | `SVT_AV1_PARAMS`     | `--av1-params`                                |
| `hevc_videotoolbox` | `VIDEOTOOLBOX_ARGS`  | Implemented — `build_videotoolbox_params()`   |
| `h264_videotoolbox` | `VIDEOTOOLBOX_ARGS`  | Implemented — `build_videotoolbox_params()`   |
| `hevc_nvenc`        | _(not yet implemented)_ | _(not yet implemented)_                    |

Hardware encoders do **not** accept `-x265-params`; `build_videotoolbox_params()` translates CRF/preset into `-q:v` (VideoToolbox's native quality knob). A future `build_nvenc_params()` will use `-cq`/`-preset p7` for NVENC when implemented.

Because the VideoToolbox backend silently drops the software encode knobs, muxm warns at config time (before `--print-effective-config` exits) when a user **explicitly** types a flag that the resolved backend or codec ignores — never blocking, just surfacing. These warnings are gated on the `_CLI_*_EXPLICIT` trackers, so a value supplied by a profile or config file never warns. Covered cases: `--crf`/`--preset`/`--x265-params`/`--x264-params` under the VideoToolbox backend; `--hw-accel-quality` without any hardware backend; `--av1-params`/`--av1-maxrate`/`--av1-bufsize` on a non-AV1 codec; `--x265-params`/`--x264-params` on the wrong codec; and `--level` on an AV1 encode.

---

## 5. Quality parity protocol

Phase 2 and Phase 3 each commit a calibration document (`docs/VIDEOTOOLBOX_CALIBRATION.md`, `docs/NVENC_CALIBRATION.md`) modeled on [`AV1_CALIBRATION.md`](AV1_CALIBRATION.md):

- **Reference clips:** 120s *City of God* (1080p SDR) + 120s *Avatar: The Way of Water* (4K HDR10), extracted from `-ss 0 -t 120`.
- **Software baseline:** per-profile CRF values used in Phase 2 calibration:

  | Profile | Encoder | CRF | Preset |
  |---|---|---|---|
  | `hdr10-hq` | libx265 | 17 | slower |
  | `atv-directplay-hq` | libx265 | 17 | slower |
  | `atv-directplay-animation` | libx265 | 16 | slower |
  | `animation` | libx265 | 16 | slower |
  | `streaming-hevc` | libx265 | 20 | medium |
  | `universal` | libx264 | 22 | slow |
  | `youtube-upload` | libx264 | 16 | slow |
- **Sweep:** per-profile, sweep the hardware backend's quality knob across a reasonable range.
- **Metric:** mean VMAF (`vmaf_v0.6.1`). Pass threshold: Δ ≤ 0.5 VMAF vs software baseline. Document any profile that cannot meet parity with the size/speed trade-off made.
- **Harness:** `tools/hw_compare.sh` (Phase 2) generalizes `tools/av1_compare.sh` with an `--encoder` argument.

---

## 6. Observability

`--print-effective-config` reports three new fields:

```
  [Video — Hardware Acceleration]
  HW_ACCEL                  = auto
  HW_ACCEL_RESOLVED         = videotoolbox
  HW_ACCEL_AVAILABLE        = videotoolbox nvenc
```

During encode, `HW_ACCEL_FALLBACK_REASON` is logged via `note` whenever a gate forces software fallback.

---

## 7. Version roadmap

| Version | Scope |
|---------|-------|
| v1.5.0 (released) | VideoToolbox dispatch complete; calibration committed |
| v1.6.0 (next) | Phase 3 NVENC dispatch + calibration + `--hw-accel auto` CI coverage |
