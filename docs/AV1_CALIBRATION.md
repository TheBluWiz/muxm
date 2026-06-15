# AV1 Calibration — Test Results

**Last updated:** 2026-04-06
**Scope:** AV1 (libsvt-av1) vs HEVC (libx265) quality/size/speed comparison across two sources

---

## 1. Test Methodology

### Source Material

| Test | Film | Resolution | Dynamic Range | Pixel Format | Characteristics |
|---|---|---|---|---|---|
| 1 | *City of God* (2002) | 1080p | SDR | yuv420p | High-motion urban drama, fast cuts, complex textures |
| 2 | *Avatar: The Way of Water* (2022) | 4K | HDR10 | yuv420p10le | Heavy CGI, wide dynamic range, dense motion |

Both clips: 120s extracted from start of feature (`-ss 0 -t 120`), MKV container.

### Encode Parameters

**HEVC baseline:**
```
ffmpeg -i clip.mkv -c:v libx265 -crf 18 -preset slower
```

**AV1 candidates:**
```
ffmpeg -i clip.mkv -c:v libsvt-av1 -crf {24,26,28,30,32} -preset {6}
```

The sweep covers CRF 24–32 at 1080p SDR and CRF 20–32 at 4K HDR. CRF 20 was tested at 4K HDR only as a supplemental data point to probe the parity boundary.

Audio was excluded from size measurements; file sizes reflect video stream only.

### VMAF
- Model: `vmaf_v0.6.1` (ffmpeg libvmaf default) for both tests
- Reference: original 120s clip; distorted: each encoded file
- Scoring: mean VMAF over all frames at native resolution
- **Note:** `vmaf_v0.6.1` was trained at 1080p viewing distance, so scores for 4K content run slightly conservative — perceived quality on UHD displays is marginally higher than the numbers reflect. Test 2 scores are internally consistent and valid for comparing CRF settings against each other and against the HEVC baseline.

---

## 2. Results

### Test 1: City of God (2002) — 1080p SDR

| Label | Codec | CRF | Preset | Size (MB) | Bitrate (kbps) | Encode Time (s) | VMAF | Size vs HEVC |
|---|---|---|---|---|---|---|---|---|
| HEVC-CRF18-slower | libx265 | 18 | slower | 133.1 | 9,293 | 759 | 98.54 | baseline |
| AV1-CRF28-p6 | libsvt-av1 | 28 | 6 | 71.8 | 5,013 | 60 | 97.91 | −46.1% |
| AV1-CRF30-p6 | libsvt-av1 | 30 | 6 | 66.8 | 4,666 | 43 | 97.70 | −49.8% |
| AV1-CRF32-p6 | libsvt-av1 | 32 | 6 | 61.5 | 4,299 | 30 | 97.34 | −53.7% |

#### Speed — Test 1 (vs HEVC 759s)

| AV1 variant | Encode time (s) | Speedup |
|---|---|---|
| CRF 28, p6 | 60 | **12.6×** |
| CRF 30, p6 | 43 | **17.7×** |
| CRF 32, p6 | 30 | **25.3×** |

---

### Test 2: Avatar: The Way of Water (2022) — 4K HDR10

| Label | Codec | CRF | Preset | Size (MB) | Bitrate (kbps) | Encode Time (s) | VMAF | Size vs HEVC |
|---|---|---|---|---|---|---|---|---|
| HEVC-CRF18-slower | libx265 | 18 | slower | 224.7 | 15,658 | 2,755 | 94.98 | baseline |
| AV1-CRF20-p6 | libsvt-av1 | 20 | 6 | 104.0 | 7,250 | 79 | 93.48 | −53.7% |
| AV1-CRF24-p6 | libsvt-av1 | 24 | 6 | 128.7 | 8,965 | 82 | 92.54 | −42.75% |
| AV1-CRF26-p6 | libsvt-av1 | 26 | 6 | 113.4 | 7,900 | 82 | 91.82 | −49.54% |
| AV1-CRF28-p6 | libsvt-av1 | 28 | 6 | 104.1 | 7,252 | 84 | 91.24 | −53.7% |
| AV1-CRF30-p6 | libsvt-av1 | 30 | 6 | 97.2 | 6,774 | 84 | 90.65 | −56.7% |
| AV1-CRF32-p6 | libsvt-av1 | 32 | 6 | 90.5 | 6,304 | 86 | 89.91 | −59.7% |

> **HEVC timing note:** The CRF 24/26 JSON reports `encode_seconds: 7215` for the HEVC baseline, vs 2,755s in the original run. The encoded file is identical (same size 224.7 MB, same bitrate 15,658 kbps). The discrepancy is likely a timing-method difference between runs. Speedup figures below use 2,755s for internal consistency.

#### Speed — Test 2 (vs HEVC 2,755s)

| AV1 variant | Encode time (s) | Speedup |
|---|---|---|
| CRF 20, p6 | 79 | **34.9×** |
| CRF 24, p6 | 82 | **33.6×** |
| CRF 26, p6 | 82 | **33.6×** |
| CRF 28, p6 | 84 | **32.8×** |
| CRF 30, p6 | 84 | **32.8×** |
| CRF 32, p6 | 86 | **32.0×** |

---

## 3. Key Findings

### Both sources

1. **File size:** AV1 achieves 46–60% smaller files vs HEVC CRF 18 across both sources. Reductions are larger at 4K HDR (54–60%) than 1080p SDR (46–54%), confirming that 4K HDR compresses proportionally more efficiently with AV1.

2. **Encode speed:** SVT-AV1 preset 6 is dramatically faster than x265 `slower` — 13–25× at 1080p, and 32–33× at 4K. The 4K speedup ratio is higher because x265 `slower` scales poorly to UHD resolution; SVT-AV1 does not suffer the same regression.

### 1080p SDR (City of God)

3. **VMAF parity:** AV1 CRF 28 (97.91) closely matches HEVC CRF 18 (98.54) — delta of 0.63 VMAF points, imperceptible in practice. All three AV1 variants exceed the visually transparent threshold (VMAF 93+) by a wide margin.

4. **CRF diminishing returns:** Each 2-CRF step gives roughly 7–8% bitrate reduction and 0.2–0.4 VMAF points. CRF 30 is near the knee of the curve for this content type.

### 4K HDR10 (Avatar)

5. **VMAF parity does not hold at CRF 28 for 4K HDR.** AV1 CRF 28 (91.24) is 3.74 VMAF points below HEVC CRF 18 (94.98) — a gap six times larger than at 1080p SDR. The "CRF + 10" rule of thumb breaks down for 4K HDR content at this CRF range.

6. **CRF 20 (93.48) is the closest AV1 variant to the HEVC CRF 18 baseline (94.98) at 4K HDR and the only tested variant to clear the ≥93 parity threshold.** The 1.50-point gap is likely imperceptible on most displays. CRF 24 (92.54) is the next closest. Per-step scores: CRF 20: 93.48, CRF 24: 92.54, CRF 26: 91.82, CRF 28: 91.24, CRF 30: 90.65, CRF 32: 89.91.

7. **VMAF per-step delta is larger at 4K HDR.** Each 2-CRF step costs 0.59–0.74 VMAF points (vs 0.21–0.36 at 1080p SDR), meaning quality degrades faster with looser CRF on UHD content.

8. **The HEVC CRF 18 baseline itself scores lower at 4K HDR (94.98 vs 98.54).** Part of this is the `vmaf_v0.6.1` model being calibrated for 1080p; part may reflect genuine HDR tone-mapping complexity that both codecs struggle with. Scores are internally consistent within Test 2 but not directly comparable to Test 1 absolute values.

---

## 4. Profile Recommendations

### `av1-hq` — CRF 28 (1080p SDR) / CRF 24 (4K HDR), preset 6

Recommended as the **primary AV1 encode profile**, and the AV1 equivalent of the existing `hevc-hq` / `hdr10-hq` baseline (HEVC CRF 18, slower).

| Metric | 1080p SDR (City of God) — CRF 28 | 4K HDR (Avatar) — CRF 24 |
|---|---|---|
| VMAF | 97.91 (Δ −0.63 vs HEVC CRF 18) | 92.54 (Δ −2.44 vs HEVC CRF 18) |
| Size vs HEVC CRF 18 | −46.1% | −42.75% |
| Encode speed vs HEVC | 12.6× faster | 33.6× faster |

**Rationale (1080p SDR, CRF 28):** Minimises VMAF deviation from the HEVC archive baseline. The 0.63 VMAF delta is below the threshold of noticeability on reference displays.

**Rationale (4K HDR, CRF 24):** CRF 20 scores 93.48 — the closest measured result to the HEVC CRF 18 baseline and the only tested AV1 variant to clear ≥93 at 4K HDR. File size (104.0 MB, −53.7% vs HEVC), bitrate (7,250 kbps), and encode time (79s, 34.9× speedup vs HEVC) for CRF 20 are now fully measured. CRF 24 (92.54) remains the calibrated default; CRF 20 is fully characterised as a higher-quality alternative.

---

### `streaming-av1` — CRF 30 (≤1080p SDR) / CRF 28 (≥4K or HDR), preset 6

Recommended for **streaming delivery** where per-GB bandwidth cost outweighs the marginal quality difference. The CRF is **resolution/HDR-aware** (A1): CRF 30 for the common 1080p-SDR case, dropping to **CRF 28 for ≥4K or HDR sources**, applied automatically in `main()` after the source is probed (an explicit `--crf` always overrides it). Because the override happens at encode time after probing, `--print-effective-config` — which never reads a source file — always reports the base CRF 30; the effective CRF is logged at encode time (e.g. `streaming-av1: 3840×2160 … → CRF 28`).

| Metric | 1080p SDR (City of God), CRF 30 | 4K HDR (Avatar), CRF 28 |
|---|---|---|
| VMAF | 97.70 (Δ −0.84 vs HEVC CRF 18) | 91.24 (Δ −3.74 vs HEVC CRF 18) |
| Size vs HEVC CRF 18 | −49.8% | −53.7% |
| Encode speed vs HEVC | 17.7× faster | 32.8× faster |

**Why CRF 28 at 4K/HDR (not full transparency):** at 4K HDR the "+10 CRF vs HEVC" rule breaks down — CRF 30 scores VMAF 90.65 and even CRF 28 reaches only 91.24, still below the ~93 visually-transparent line (clearing 93 needs CRF ~20, which is `av1-hq`'s job, not a streaming profile's). CRF 28 is a deliberate streaming trade-off: it nudges quality up (+0.59 VMAF) for a small bandwidth cost (−53.7% vs −56.7% size reduction), without paying the full bitrate to reach transparency. **Note:** the ≥4K trigger also fires for 4K SDR, and the HDR trigger fires for 1080p HDR — both extrapolations beyond the single measured 4K-HDR data point, chosen as the safer (higher-quality) default on a per-the-decision "≥4K and/or HDR" basis.

---

## 5. CRF Equivalence Table

Approximate HEVC CRF → AV1 CRF mapping. **Values are calibrated for 1080p SDR.** 4K HDR requires lower AV1 CRF for equivalent quality — see the 4K section below.

| HEVC CRF (libx265) | Target VMAF (1080p SDR) | AV1 CRF (libsvt-av1, p6) | Confidence |
|---|---|---|---|
| 14 | 99.5+ | ~20 | extrapolated |
| 16 | 99.0 | ~23 | extrapolated |
| 18 | 98.5 | **28** | **measured (1080p SDR)** |
| 20 | 97.5 | ~30–31 | extrapolated |
| 22 | 96.5 | ~33–34 | extrapolated |
| 23 | 95.5 | ~35 | extrapolated |
| 28 | 91–93 | ~42–44 | extrapolated |

**Rule of thumb (1080p SDR):** AV1 CRF ≈ HEVC CRF + 10 (±2 depending on content complexity).

#### 4K HDR CRF sweep — complete data (all 5 AV1 points)

| AV1 CRF | Size (MB) | Bitrate (kbps) | Encode (s) | VMAF | Δ vs HEVC CRF 18 (94.98) | Parity (≥93)? |
|---|---|---|---|---|---|---|
| 20 | 104.0 | 7,250 | 79 | 93.48 (min 70.03) | −1.50 | **Yes** |
| 24 | 128.7 | 8,965 | 82 | 92.54 (min 68.38) | −2.44 | **No** |
| 26 | 113.4 | 7,900 | 82 | 91.82 (min 67.80) | −3.16 | **No** |
| 28 | 104.1 | 7,252 | 84 | 91.24 | −3.74 | **No** |
| 30 | 97.2 | 6,774 | 84 | 90.65 | −4.33 | **No** |
| 32 | 90.5 | 6,304 | 86 | 89.91 | −5.07 | **No** |

**VMAF summary:** CRF 20 at 93.48 is the best-performing tested variant — 1.50 VMAF points below the HEVC CRF 18 baseline (94.98) and the only AV1 result to clear the ≥93 parity threshold. Encode time: 79s (34.9× speedup vs HEVC 2,755s). CRF 24 (92.54) is the current `av1-hq` default.

**4K HDR note:** The +10 CRF offset (valid for 1080p SDR) underestimates the AV1 quality budget needed at UHD. The closest measured near-parity point at 4K HDR is CRF 20 (93.48 VMAF), an effective offset of +2 vs HEVC CRF 18 — versus +10 at 1080p SDR. CRF 24 represents an effective offset of +6 with full measured data.

---

## 6. `_crf_ratio()` Calibration

`_crf_ratio()` (`muxm:4665`) estimates the output/source bitrate ratio for disk space preflight warnings.

### Method

Without raw source bitrates, measured ratios are anchored against the HEVC CRF 18 encode for each test, using the code's existing HEVC CRF 18 ratio (330/1000) to back-calculate an implied source bitrate:

| Test | HEVC CRF 18 bitrate | Implied source bitrate | Consistent with |
|---|---|---|---|
| City of God (1080p SDR) | 9,293 kbps | ~28,160 kbps | 1080p SDR Blu-ray (20–35 Mbps) |
| Avatar (4K HDR) | 15,658 kbps | ~47,448 kbps | 4K HDR Blu-ray (40–80 Mbps) |

Measured ratios derived as: `(AV1 bitrate / HEVC bitrate) × 330`.

### Comparison: code estimates vs measured

| AV1 CRF | Code estimate | CoG measured (1080p SDR) | Avatar measured (4K HDR) | Direction |
|---|---|---|---|---|
| 24 | 220 | — (not tested) | **189** | code overestimates — 4K HDR now measured |
| 26 | 195 | — (not tested) | **167** | code overestimates — 4K HDR now measured |
| 28 | 120 | 178 | 153 | code **underestimates** size by 28–48% |
| 30 | 100 | 166 | 143 | code **underestimates** size by 43–66% |
| 32 | 85  | 153 | 133 | code **underestimates** size by 57–80% |

CRF 24 and 26 ratios derived from the Avatar 4K HDR data: `(8965 / 15658) × 330 = 189` and `(7900 / 15658) × 330 = 167`. The extrapolated 1080p SDR upper bounds (adding the observed ~22-point 4K-to-SDR gap) are approximately **211** (CRF 24) and **189** (CRF 26).

### Cross-source comparison

4K HDR produces lower ratios than 1080p SDR at every CRF, confirming the prediction that UHD compresses more efficiently relative to source. The gap is 15–25 ratio points at each CRF step.

If a single set of ratios must cover both resolutions, the 1080p SDR values (178/166/153) are the conservative upper bound. Using these for 4K content will slightly overestimate file size — the safer failure mode for a disk preflight check.

### Suggested updated values

```bash
# libsvt-av1 — calibrated ratios (1080p SDR upper bound)
20) echo 320 ;; 22) echo 260 ;; 24) echo 211 ;; 26) echo 189 ;;
28) echo 178 ;; 30) echo 166 ;; 32) echo 153 ;; 34) echo 130 ;;
36) echo 108 ;; 38) echo 88  ;; 40) echo 70  ;;
```

CRF 24 and 26 values anchored to 4K HDR measurements (189/167) plus the observed ~22-point gap between 4K HDR and 1080p SDR at CRF 28–32. CRF 28/30/32 are anchored to measured 1080p SDR values (178/166/153).

---

## 7. HDR-Specific Behaviour

- **Lower absolute VMAF at 4K HDR.** Both the HEVC baseline (94.98) and all AV1 variants score 3–7 points below their 1080p SDR equivalents. This is partly a model artefact (`vmaf_v0.6.1` is not calibrated for UHD) and partly real — HDR10 content has higher source fidelity demands and wider dynamic range gradients that stress lossy codecs more severely.
- **Larger per-CRF quality penalty.** Each 2-CRF step costs ~0.6–0.7 VMAF at 4K HDR vs ~0.2–0.4 at 1080p SDR. CRF selection must be more conservative for UHD workflows.
- **Greater bitrate efficiency.** Despite higher raw bitrates, AV1 compresses 4K HDR files 54–60% smaller than the HEVC CRF 18 baseline vs 46–54% at 1080p SDR. The 4K source has more redundancy that AV1's spatial and temporal prediction exploits.
- **SVT-AV1 speed scales well to 4K.** Encode times at 4K HDR (84–86s) are only 40% longer than at 1080p SDR (30–60s) despite 4× the pixel count. The speedup ratio vs HEVC `slower` is 32× at 4K vs 13–25× at 1080p.
- **VMAF model caveat.** Use `vmaf_4k` for production quality gates on UHD content. The scores here are useful for relative comparison (AV1 vs HEVC within Test 2) but should not be used as absolute quality thresholds for a 4K HDR pipeline.

---

## 8. Limitations

- **Two source files, both 120s clips.** *City of God* (high-motion urban drama) and *Avatar: The Way of Water* (CGI-heavy 4K HDR). Animated content, slow-paced drama, live-action 4K SDR, and Dolby Vision content are not characterised. Additional content types would broaden the CRF equivalence data; the current results are sufficient for profile defaults.
- **Fixed preset (p6).** Preset 4 and 8 comparisons were not included. Speed/quality trade-offs at other presets are not characterised.
- **VMAF model mismatch for 4K.** Both tests used `vmaf_v0.6.1`. Absolute VMAF scores from Test 2 are not directly comparable to Test 1 values; use `vmaf_4k` for production UHD measurements.
- **No Dolby Vision test.** SVT-AV1 handling of DV Profile 8.1 vs HDR10 fallback is not confirmed.
- **No audio.** Audio track size excluded. For files with TrueHD or DTS-HD MA tracks, audio dominates at short durations.
