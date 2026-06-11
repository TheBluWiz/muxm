# Hardware Acceleration — Architecture

**Status:** Phase 2 — VideoToolbox dispatch implemented; calibration in progress.
**Next:** Phase 3 adds NVIDIA NVENC dispatch in v1.6.0.

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
| `videotoolbox`  | ✅ (hevc_videotoolbox) | ✅ (h264_videotoolbox) | ❌ (no HW encoder on Apple Silicon) | ❌ (DV RPU requires libx265) |
| `nvenc`         | Phase 3 | Phase 3 | Phase 3 (RTX 40+ only) | ❌ (DV RPU requires libx265) |

Backends that cannot satisfy a request fall back to software and record the reason in `HW_ACCEL_FALLBACK_REASON`.

---

## 3. Resolution flow

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐    ┌───────────────────────┐
│ HW_ACCEL set    │───▶│ detect_hw_accel  │───▶│ per-encode           │───▶│ resolve_video_encoder │
│ (.muxmrc / CLI) │    │ (populate        │    │ compatibility gates  │    │ (choose -c:v arg)     │
│                 │    │  AVAILABLE[],    │    │ (DV? AV1 on VT? …)   │    │                       │
│                 │    │  RESOLVED)       │    │                      │    │                       │
└─────────────────┘    └──────────────────┘    └─────────────────────┘    └───────────────────────┘
```

- **`detect_hw_accel`** runs once, post-CLI parsing. Non-fatal: an explicit but missing backend leaves `HW_ACCEL_RESOLVED="none"` so `--print-effective-config` still succeeds.
- **Strict check** in Section 14 (tool validation) dies with exit 10 when an explicit `--hw-accel videotoolbox`/`--hw-accel nvenc` does not resolve. This mirrors the existing AV1 encoder strict-check pattern.
- **`resolve_video_encoder`** runs per-encode after Dolby Vision detection. It walks the gates in this order:

  1. `HW_ACCEL_RESOLVED == "none"` → software (no gate).
  2. Source is Dolby Vision → software (DV RPU injection requires libx265).
  3. `VIDEO_CODEC == libaom-av1` → software (no hardware libaom counterpart).
  4. `videotoolbox + libsvt-av1` → software (Apple Silicon has no AV1 hardware encode).
  5. `nvenc + libsvt-av1 + !av1_nvenc` → software (requires Ada Lovelace / RTX 40+).

  In Phase 2, the VideoToolbox arm is fully implemented. Phase 3 will add the NVENC arm.

---

## 4. Parameter builders

Software encoders continue to use `build_x265_params` and `build_av1_params`. `build_video_encoder_params` is the single dispatch entry point — it routes to `build_videotoolbox_params()` for VideoToolbox encoders; Phase 3 will add `build_nvenc_params()` alongside.

| Encoder             | Params global        | CLI surface                                   |
|---------------------|----------------------|-----------------------------------------------|
| `libx265`           | `X265_PARAMS`        | `--x265-params`                               |
| `libx264`           | `X264_PARAMS_BASE`   | `--x264-params`                               |
| `libsvtav1`         | `SVT_AV1_PARAMS`     | `--av1-params`                                |
| `hevc_videotoolbox` | `VIDEOTOOLBOX_ARGS`  | Implemented — `build_videotoolbox_params()`   |
| `h264_videotoolbox` | `VIDEOTOOLBOX_ARGS`  | Implemented — `build_videotoolbox_params()`   |
| `hevc_nvenc`        | _(Phase 3)_          | _(Phase 3)_                                   |

Hardware encoders do **not** accept `-x265-params`; `build_videotoolbox_params()` translates CRF/preset into `-q:v` (VideoToolbox's native quality knob). Phase 3 will add an analogous `build_nvenc_params()` using `-cq`/`-preset p7` for NVENC.

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
| v1.5.0 (in progress) | VideoToolbox dispatch complete; calibration committed |
| v1.6.0 | Phase 3 NVENC dispatch + calibration + `--hw-accel auto` CI coverage |
