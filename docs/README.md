# muxm Documentation Index

Where each document sits on the **user-facing ↔ maintainer** spectrum, so contributors
know which docs are reference material for end users and which are internal engineering
records (terser, deeper, and free to assume familiarity with the `muxm` script).

| Document | Audience | What it covers |
|---|---|---|
| [`config_profile.md`](config_profile.md) | **User-facing** | The ten format profiles — what each one sets, configuration precedence, and conflict warnings. |
| [`muxm.1`](muxm.1) | **User-facing** (generated) | The man page. Generated from `muxm`'s `MANPAGE_EOF` heredoc — never hand-edit (see [`../CLAUDE.md`](../CLAUDE.md)). |
| [`AV1_CALIBRATION.md`](AV1_CALIBRATION.md) | **User-facing reference / engineering record** | AV1 CRF calibration and the `_crf_ratio` disk-estimate ratios; linked from the README and guarded by the `docs` suite. |
| [`HW_ACCEL.md`](HW_ACCEL.md) | **Maintainer / engineering record** | Hardware-acceleration architecture and roadmap (VideoToolbox now; NVENC later). |
| [`VIDEOTOOLBOX_CALIBRATION.md`](VIDEOTOOLBOX_CALIBRATION.md) | **User-facing reference / engineering record** | Per-profile VideoToolbox `q:v` calibration data behind the `VT_QUALITY_MAP` array; linked from the README HW-accel section. |
| [`TESTING_PLAN.md`](TESTING_PLAN.md) | **Maintainer / engineering record** | Automated-suite map, manual test matrix, and coverage-gap analysis. |
| [`../docker/README.md`](../docker/README.md) | **User-facing** | Running muxm in Docker on macOS/Linux/Windows — quickstarts, helpers, and maintainer notes. |
| [`../docker/DOCKER_WINDOWS_GUIDE.md`](../docker/DOCKER_WINDOWS_GUIDE.md) | **User-facing** | Step-by-step Windows walkthrough (Docker Desktop install → setup.bat → encode.bat), assumes no CLI experience. |