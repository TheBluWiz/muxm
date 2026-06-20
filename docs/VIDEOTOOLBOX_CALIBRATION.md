# VideoToolbox Calibration — Test Results

**Last updated:** 2026-06-11  
**Scope:** Apple VideoToolbox (`hevc_videotoolbox`, `h264_videotoolbox`) quality calibration — establishing `q:v` values that achieve VMAF parity (|Δ| ≤ 0.5) with each profile's software baseline

---

## 1. Test Methodology

### Platform

- **Hardware:** Apple Silicon (Apple M-series, VideoToolbox HW encoder)
- **OS:** macOS 15 (Darwin 25.x)
- **ffmpeg:** 8.1.1

### Source Material

| Clip | Film | Year | Resolution | Dynamic Range | Pixel Format | Characteristics |
|---|---|---|---|---|---|---|
| A | *City of God* | 2002 | 1080p | SDR | yuv420p | High-motion urban drama, fast cuts, complex textures |
| B | *Avatar: Fire and Ash* | 2025 | 4K | HDR10 + DV Profile 7 | yuv420p10le (base layer) | CGI-heavy, wide dynamic range, dense motion |
| C | *Arcane* S01E01 | 2021 | 1080p | SDR | yuv420p | CG animation; sharp line-art, flat gradient backgrounds, banding-prone surfaces, mixed action and static scenes |

Clips A and B: 120 s extracted from start of feature (`-ss 0 -t 120`), MKV container, video-only.  
Clip C: 120 s extracted at 5:00 (`-ss 300 -t 120`), stream-copy, MKV container.  
All clips: video-only (`-an`).

Clip B carries Dolby Vision Profile 7 RPU side data. The DV layer is inert during the HEVC baseline and HW encodes — the HDR10 base layer (`smpte2084`, `bt2020`) is what both SW and VT encode. DV presence is confirmed safe for calibration (see planning doc §3.2).

### Sweep Parameters

Each sweep encodes the clip at multiple `q:v` values, computes VMAF against the profile's SW baseline, and reports pass/fail per step.

**Pass criterion:** |Δ VMAF| ≤ 0.5 (bidirectional — HW that overshoots the SW baseline by more than 0.5 also fails)

**Calibrated q:v:** The `q:v` of the smallest-file PASS step across the sweep.

**VMAF:** Model `vmaf_v0.6.1`, `n_subsample=5`, mean score over the 120 s clip. See §6 (Limitations) for the 4K HDR model-calibration note.

**Pixel formats:**
- `hevc_videotoolbox` 10-bit: `p010le` (VT native); compared at `yuv420p10le` for VMAF
- `hevc_videotoolbox` 8-bit: `yuv420p`
- `h264_videotoolbox`: `yuv420p` (8-bit only; H.264 High profile)

### Software Baselines per Profile

| Profile | SW codec | CRF | Preset | Pixel format |
|---|---|---|---|---|
| `hdr10-hq` | libx265 | 17 | slower | yuv420p10le |
| `atv-directplay-hq` | libx265 | 17 | slower | yuv420p10le |
| `atv-directplay-animation` | libx265 | 16 | slower | yuv420p10le |
| `animation` | libx265 | 16 | slower | yuv420p10le |
| `streaming-hevc` | libx265 | 20 | medium | yuv420p10le |
| `universal` | libx264 | 22 | slow | yuv420p |
| `youtube-upload` | libx264 | 16 | slow | yuv420p |

### Representative Clips per Profile

Each profile is primarily calibrated from the clip that represents its real-world use:

- **HDR profiles** (`hdr10-hq`, `atv-directplay-hq`): Clip B (4K HDR10) is representative. Clip A (1080p SDR) is a cross-check.
- **Animation profiles** (`animation`, `atv-directplay-animation`): Clip C (1080p SDR animation) is representative. Clips A and B from Phase 2 live-action content were the initial calibration; Clip C supersedes them for the final `VT_QUALITY_MAP` value.
- **SDR/upload profiles** (`streaming-hevc`, `universal`, `youtube-upload`): Clip A (1080p SDR) is primary. Clip B (4K HDR10) is a cross-check.

When clips disagree on calibrated q:v, the representative clip wins. Cross-check results are informational and noted where relevant.

---

## 2. Results

### `hdr10-hq` — `hevc_videotoolbox`

SW baseline: libx265 CRF 17 slower

**Clip A (1080p SDR, cross-check)** — SW VMAF 97.95

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 98.23   | −0.28 | PASS |
| 70  | 98.51   | −0.56 | FAIL |
| 75  | 98.60   | −0.65 | FAIL |
| 80  | 98.72   | −0.77 | FAIL |
| 85  | 98.78   | −0.83 | FAIL |

Cross-check cal_q: 65. Only q:v 65 passes — VT overshoots the x265 CRF 17 baseline with `range=limited` on SDR content at q:v 70+. This is a profile/content mismatch (`hdr10-hq` applies `colormatrix=bt2020nc:range=limited` to an SDR source) and is not representative of normal use.

**Clip B (4K HDR10, representative)** — SW VMAF 99.15

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 98.43   | +0.72 | FAIL |
| 70  | 99.00   | +0.15 | PASS |
| 75  | 99.15   |  0.00 | PASS |
| 80  | 99.34   | −0.19 | PASS |
| 85  | 99.41   | −0.26 | PASS |

Representative cal_q: **70**

---

### `atv-directplay-hq` — `hevc_videotoolbox`

SW baseline: libx265 CRF 17 slower

**Clip A (1080p SDR, cross-check)** — SW VMAF 98.70

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 98.23   | +0.47 | PASS |
| 70  | 98.51   | +0.19 | PASS |
| 75  | 98.60   | +0.10 | PASS |
| 80  | 98.72   | −0.02 | PASS |
| 85  | 98.78   | −0.08 | PASS |

Cross-check cal_q: 65 (full sweep passes)

**Clip B (4K HDR10, representative)** — SW VMAF 99.15

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 98.43   | +0.72 | FAIL |
| 70  | 99.00   | +0.15 | PASS |
| 75  | 99.15   |  0.00 | PASS |
| 80  | 99.34   | −0.19 | PASS |
| 85  | 99.41   | −0.26 | PASS |

Representative cal_q: **70**

---

### `atv-directplay-animation` — `hevc_videotoolbox`

SW baseline: libx265 CRF 16 slower

**Clip A (1080p SDR, live-action cross-check)** — SW VMAF 98.65

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 98.23   | +0.42 | PASS |
| 70  | 98.51   | +0.14 | PASS |
| 75  | 98.60   | +0.05 | PASS |
| 80  | 98.72   | −0.07 | PASS |
| 85  | 98.78   | −0.13 | PASS |

Cross-check cal_q: 65 (full sweep passes)

**Clip B (4K HDR10, live-action cross-check)** — SW VMAF 99.04

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 98.43   | +0.61 | FAIL |
| 70  | 99.00   | +0.04 | PASS |
| 75  | 99.15   | −0.11 | PASS |
| 80  | 99.34   | −0.30 | PASS |
| 85  | 99.41   | −0.37 | PASS |

Live-action cal_q: 70 (superseded by Clip C below)

**Clip C (1080p SDR animation, representative)** — SW VMAF 84.44  
*x265 note: `hdr10-opt` disabled by x265 on SDR source — non-fatal warning, encode completed normally at CRF 16 slower.*

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 60  | 83.33   | +1.11 | FAIL |
| 65  | 84.05   | +0.39 | PASS |
| 70  | 84.51   | −0.07 | PASS |
| 75  | 84.65   | −0.21 | PASS |
| 80  | 84.84   | −0.40 | PASS |
| 85  | 84.93   | −0.49 | PASS |

Representative cal_q: **65** (updated from live-action value of 70)

---

### `animation` — `hevc_videotoolbox`

SW baseline: libx265 CRF 16 slower

**Clip A (1080p SDR, live-action cross-check)** — SW VMAF 98.65

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 98.23   | +0.42 | PASS |
| 70  | 98.51   | +0.14 | PASS |
| 75  | 98.60   | +0.05 | PASS |
| 80  | 98.72   | −0.07 | PASS |
| 85  | 98.78   | −0.13 | PASS |

Cross-check cal_q: 65 (full sweep passes)

**Clip B (4K HDR10, live-action cross-check)** — SW VMAF 99.15

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 98.43   | +0.72 | FAIL |
| 70  | 99.00   | +0.15 | PASS |
| 75  | 99.15   |  0.00 | PASS |
| 80  | 99.34   | −0.19 | PASS |
| 85  | 99.41   | −0.26 | PASS |

Live-action cal_q: 70 (superseded by Clip C below)

**Clip C (1080p SDR animation, representative)** — SW VMAF 84.44

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 60  | 83.33   | +1.11 | FAIL |
| 65  | 84.05   | +0.39 | PASS |
| 70  | 84.51   | −0.07 | PASS |
| 75  | 84.65   | −0.21 | PASS |
| 80  | 84.84   | −0.40 | PASS |
| 85  | 84.93   | −0.49 | PASS |

Representative cal_q: **65** (updated from live-action value of 70)

---

### `streaming-hevc` — `hevc_videotoolbox`

SW baseline: libx265 CRF 20 medium

**Clip A (1080p SDR, representative)** — SW VMAF 98.37

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 55  | 97.27   | +1.10 | FAIL |
| 60  | 97.74   | +0.63 | FAIL |
| 65  | 98.23   | +0.14 | PASS |
| 70  | 98.51   | −0.14 | PASS |
| 75  | 98.60   | −0.23 | PASS |

Representative cal_q: **65**

**Clip B (4K HDR10, cross-check)** — SW VMAF 98.09

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 55  | 96.00   | +2.09 | FAIL |
| 60  | 97.22   | +0.87 | FAIL |
| 65  | 98.43   | −0.34 | PASS |
| 70  | 99.00   | −0.91 | FAIL |
| 75  | 99.15   | −1.06 | FAIL |

Cross-check cal_q: 65. q:v 65 is the only passing step — at q:v 70, VT already exceeds the CRF 20 medium baseline by 0.91 VMAF on 4K HDR content. Both clips agree: calibrated q:v is **65**.

---

### `universal` — `h264_videotoolbox`

SW baseline: libx264 CRF 22 slow

**Clip A (1080p SDR, representative)** — SW VMAF 97.78

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 55  | 94.88   | +2.90 | FAIL |
| 60  | 96.22   | +1.56 | FAIL |
| 65  | 97.09   | +0.69 | FAIL |
| 70  | 97.89   | −0.11 | PASS |
| 75  | 98.19   | −0.41 | PASS |
| 80  | 98.46   | −0.68 | FAIL |

Representative cal_q: **70**

**Clip B (4K HDR10, cross-check)** — SW VMAF 96.58

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 55  | 89.23   | +7.35 | FAIL |
| 60  | 92.12   | +4.46 | FAIL |
| 65  | 94.48   | +2.10 | FAIL |
| 70  | 96.98   | −0.40 | PASS |
| 75  | 98.06   | −1.48 | FAIL |
| 80  | 98.71   | −2.13 | FAIL |

Cross-check cal_q: 70. Only q:v 70 passes on the 4K cross-check — q:v 75+ overshoots x264 CRF 22 on 4K by ≥1.48 VMAF. Both clips agree: calibrated q:v is **70**.

---

### `youtube-upload` — `h264_videotoolbox`

SW baseline: libx264 CRF 16 slow

**Clip A (1080p SDR, representative)** — SW VMAF 98.62

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 97.09   | +1.53 | FAIL |
| 70  | 97.89   | +0.73 | FAIL |
| 75  | 98.19   | +0.43 | PASS |
| 80  | 98.46   | +0.16 | PASS |
| 85  | 98.63   | −0.01 | PASS |

Representative cal_q: **75** (primary calibration)

**Clip B (4K HDR10, cross-check — OQ#3 path)** — SW VMAF 98.91

| q:v | HW VMAF | Δ     | Pass |
|-----|---------|-------|------|
| 65  | 94.48   | +4.43 | FAIL |
| 70  | 96.98   | +1.93 | FAIL |
| 75  | 98.06   | +0.85 | FAIL |
| 80  | 98.71   | +0.20 | PASS |
| 85  | 99.08   | −0.17 | PASS |

Cross-check cal_q: 80. This run encodes a 4K HDR10 source via `h264_videotoolbox` with `TONEMAP_HDR_TO_SDR=0` — both SW and VT produce 8-bit H.264 with PQ/BT.2020 metadata, which is the known-broken OQ#3 path. The cross-check confirms VT parity with the SW baseline on this path at q:v 80, but **q:v 80 is not used for calibration** — see §5 (Open Question #3).

---

## 3. Key Findings

### VT ignores x265 profile parameters

All four HEVC HDR profiles (`hdr10-hq`, `atv-directplay-hq`, `atv-directplay-animation`, `animation`) produce **bit-for-bit identical HW VMAF values** at each q:v on both clips. `hevc_videotoolbox` receives a raw pixel stream and a q:v target — it has no awareness of x265 parameters (CRF, x265-params, HDR options). Calibration differences between these profiles come entirely from their SW baseline quality level (CRF 16 vs. CRF 17) and from profile-specific x265 params that affect the SW baseline VMAF.

### Bidirectional failures dominate at high q:v

At high q:v settings, VT regularly overshoots the SW baseline by more than 0.5 VMAF, causing FAIL. This is the dominant failure mode at 4K HDR content across multiple profiles:

- `streaming-hevc/clip_b`: q:v 70+ all FAIL because VT HEVC at high quality exceeds x265 CRF 20 medium by ≥0.91 VMAF on 4K
- `universal/clip_b`: only q:v 70 passes; q:v 75 overshoots x264 CRF 22 by 1.48 VMAF
- `hdr10-hq/clip_a`: only q:v 65 passes (cross-check artifact; see §2)

The VT quality curve at 4K is non-linear relative to the SW references — small q:v increments produce larger-than-expected VMAF jumps, narrowing the passing window.

### Animation content shifts the operating point

The live-action Phase 2 calibration set `animation` and `atv-directplay-animation` to q:v 70 based on Clips A and B (*City of God*, *Avatar*). After re-calibrating on Clip C (*Arcane* S01E01 — CG animation), both profiles calibrate to **q:v 65**.

The shift happens because VT's quality curve relative to libx265 CRF 16 is content-dependent:

- **Live-action (Clips A/B):** VT at q:v 65 is 0.61–0.72 VMAF *below* the SW baseline on the representative HDR clip — a bidirectional FAIL. q:v 70 is needed to reach parity.
- **Animation (Clip C):** VT at q:v 65 is 0.39 VMAF *below* the SW baseline — a PASS. q:v 60 fails (Δ 1.11). The SW baseline VMAF is 84.44 vs. 99+ for live-action, reflecting that Arcane's sharp line-art and flat gradients are harder to compress at CRF 16, raising the relative bar for VT to match.

The HW VMAF values at each q:v are identical between `animation` and `atv-directplay-animation` (confirming the §3.1 finding), even though `atv-directplay-animation` includes `hdr10-opt` in its x265 params — x265 disabled those params on the SDR source with a non-fatal warning.

### All Phase 2 stub values were underestimated

Every profile's Phase 2 Commit 1 stub was too low. The planning doc stubs were conservative midpoints; the live-action calibration required higher q:v across the board:

| Profile | Stub | Live-action cal_q | Animation cal_q | **Final** |
|---|---|---|---|---|
| `hdr10-hq` | 65 | 70 | — | **70** |
| `atv-directplay-hq` | 65 | 70 | — | **70** |
| `atv-directplay-animation` | 65 | 70 | 65 | **65** |
| `animation` | 65 | 70 | 65 | **65** |
| `streaming-hevc` | 60 | 65 | — | **65** |
| `universal` | 60 | 70 | — | **70** |
| `youtube-upload` | 70 | 75 | — | **75** |

The `universal` stub was the furthest off — a 10-point underestimate. The animation profiles returned to their stub value after animation-content calibration, but via a different path: the stub was a guess, whereas q:v 65 is now a measured result on representative content.

### `streaming-hevc` has a narrow passing window on 4K HDR

On Clip B, only q:v 65 passes. The window between "VT is 0.34 VMAF better than baseline" (q:v 65) and "VT is 0.91 VMAF better than baseline" (q:v 70) spans a single 5-point q:v step. Content with different characteristics could shift this window; the calibrated value of 65 is the measured sweet spot for 120 s of Avatar 4K HDR.

---

## 4. Calibrated Values

| Profile | HW encoder | Calibrated q:v | Calibrating clip | SW baseline |
|---|---|---|---|---|
| `hdr10-hq` | hevc_videotoolbox | **70** | Clip B (4K HDR10) | libx265 CRF 17 slower |
| `atv-directplay-hq` | hevc_videotoolbox | **70** | Clip B (4K HDR10) | libx265 CRF 17 slower |
| `atv-directplay-animation` | hevc_videotoolbox | **65** | Clip C (1080p SDR animation) | libx265 CRF 16 slower |
| `animation` | hevc_videotoolbox | **65** | Clip C (1080p SDR animation) | libx265 CRF 16 slower |
| `streaming-hevc` | hevc_videotoolbox | **65** | Both (agree) | libx265 CRF 20 medium |
| `universal` | h264_videotoolbox | **70** | Both (agree) | libx264 CRF 22 slow |
| `youtube-upload` | h264_videotoolbox | **75** | Clip A (1080p SDR) | libx264 CRF 16 slow |

These values are written to the `VT_QUALITY_MAP` array in `muxm` (Section 4, *Opinionated defaults*).

---

## 5. Open Question #3 — `youtube-upload` + HDR sources

### The problem

The `youtube-upload` profile sets `TONEMAP_HDR_TO_SDR=0` and `HDR_TARGET_PIXFMT="yuv420p10le"` by design — the intent is to pass the HDR source through to YouTube's ingestion pipeline without tone-mapping.

However, both `h264_videotoolbox` and `libx264` produce **8-bit H.264 only** (`-pix_fmt yuv420p` is hardcoded in the encoder dispatch for all H.264 paths). When an HDR source is detected, `decide_color_and_pixfmt()` sets `COLOR_ARGS` to include `smpte2084 + bt2020` metadata, which is then written to the output container. The result is 8-bit H.264 tagged as HDR10 — valid H.264 syntax, but incoherent: PQ requires 10-bit precision to preserve the luminance range. The output will appear washed out on any display that interprets the smpte2084 metadata literally.

### Decision (2026-06-11): Option C — warn, don't block

The existing behaviour is preserved for both `libx264` and `h264_videotoolbox`. A runtime warning fires whenever the combination (H.264 encoder, HDR source, `TONEMAP_HDR_TO_SDR=0`) is detected — via the deferred H.264 + HDR + no-tone-map check in muxm's *Main* section (post-probe). The warning is unconditional (`warn()` → stderr, always visible). Users who need clean SDR output can pass `--tonemap`; users who want to pass through to YouTube's HDR pipeline accept the 8-bit degradation.

The Clip B cross-check (q:v 80) is documented here for completeness — it confirms VT parity with `libx264` on the 8-bit HDR passthrough path. It is **not** used as the calibrated value for `VT_QUALITY_MAP`; the SDR-calibrated value (q:v 75) is correct for the intended `youtube-upload` use case.

If YouTube's ingestion pipeline ever demonstrates reliable HDR-from-8-bit-H.264 handling, the Clip B result (q:v 80) would be the appropriate value to adopt for HDR sources — but resolving that path requires a separate decision on whether to expose per-source-type VT quality overrides.

---

## 6. Limitations

- **Three source clips, all 120 s.** *City of God* (1080p SDR drama), *Avatar: Fire and Ash* (4K HDR10), and *Arcane* S01E01 (1080p SDR CG animation). Live-action 4K SDR, HLG, DV Profile 8.1, and traditional hand-drawn animation are not characterised. Additional content types could shift calibrated values by ±5 q:v.
- **Fixed HEVC preset (`slower`, `medium`).** The SW baselines use the presets specified in each profile. VT calibration is specific to these SW references; if SW preset changes, recalibration is needed.
- **VMAF model `vmaf_v0.6.1` with `n_subsample=5`.** This model is calibrated for 1080p viewing distance. 4K HDR scores run conservative (absolute values lower than perceived quality on UHD displays). Scores within each test are internally consistent and valid for relative comparison, but should not be treated as absolute quality thresholds. Use `vmaf_4k` for production UHD quality gates.
- **`atv-directplay-hq` and `atv-directplay-animation` copy path.** Both profiles have `COPY_IF_COMPLIANT=1` — VT calibration only applies when a re-encode is actually triggered.
- **DV quality (q:v calibration) not characterised, but VT + DV is supported and tested.** The calibration *clips* include DV Profile 7 RPU side data, but the DV layer's perceptual quality is not part of this q:v sweep — VT encodes an HDR10-only base, and the DV RPU is injected post-hoc via `dovi_tool` (encoder-agnostic) and muxed with MP4Box. VT + DV compatibility itself is verified by the gated `dv_vt` regression test (`tests/test_muxm.sh`, manual tier M-series in `TESTING_PLAN.md`), which encodes a real DV source with `--hw-accel videotoolbox` and asserts the output carries a valid DV configuration record with frame-count parity. Only the *quality* of DV-over-VT remains uncharacterised here.
- **No speed data.** Encode times are available in `calibration/results/progress.log` but are not included here. VT HEVC at 4K takes approximately 13–16 min per 5-step sweep; H.264 at 4K takes approximately 20–22 min per 6-step sweep.
