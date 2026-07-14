# =============================================================================
#  MuxMaster (muxm) Docker image
#  Built on Ubuntu 24.04 with all required and optional dependencies.
#
#  Build (flat bundle folder — muxm next to this Dockerfile, the layout
#  setup.bat / setup.sh prepare):
#      docker compose build            # or: docker build -t muxm .
#
#  Build (from a repo checkout): run docker/setup.sh, which copies the
#  repo-root muxm into this folder first (docker/muxm is gitignored).
# =============================================================================

FROM ubuntu:24.04

LABEL maintainer="TheBluWiz <thebluwiz@thoughtspace.place>"
LABEL description="MuxMaster (muxm) video encoding utility with all dependencies"
LABEL org.opencontainers.image.title="MuxMaster (muxm)"
LABEL org.opencontainers.image.source="https://github.com/TheBluWiz/MuxMaster"
LABEL org.opencontainers.image.licenses="LicenseRef-MuxMaster-Freeware"

ENV DEBIAN_FRONTEND=noninteractive
ENV TERM=xterm-256color

# Tesseract language data. muxm feeds pgsrip the source track's language and
# pgsrip picks its OCR model from it, so English-only data silently degrades
# OCR of every non-English PGS track. Default matches the brew path
# (`tesseract-lang` = all languages, ~+350 MB). Slim builds can override:
#   docker build --build-arg TESSERACT_LANG_PACKAGES="tesseract-ocr-eng tesseract-ocr-fra" .
ARG TESSERACT_LANG_PACKAGES="tesseract-ocr-all"

# ---- 1. System packages ----
#   Required:  bash, ffmpeg, ffprobe, jq, bc
#   Optional:  tesseract (subtitle OCR), gpac/MP4Box (DV container signaling)
#   Build:     curl, ca-certificates (for downloading dovi_tool)
#   Utility:   dos2unix (fix Windows line endings on muxm script)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ffmpeg \
    jq \
    bc \
    tesseract-ocr \
    ${TESSERACT_LANG_PACKAGES} \
    gpac \
    python3 \
    python3-pip \
    python3-venv \
    pipx \
    curl \
    ca-certificates \
    dos2unix \
    && rm -rf /var/lib/apt/lists/*

# ---- 2. dovi_tool (Dolby Vision RPU handling) ----
# Pinned direct download (no GitHub API — unauthenticated API calls are
# rate-limited per IP and made this step fail intermittently in CI).
# Extracts to /tmp first, then finds and moves the binary (handles both flat
# archives and archives with subdirectories). Any failure fails the BUILD:
# a warn-and-continue here would ship an image whose DV features silently
# do nothing.
#
# Pinned dovi_tool release. Bump deliberately; the URL is verified at build
# time (curl -f fails the build), so a bad bump cannot produce a silently
# DV-less image the way the old "query the GitHub API for latest" approach
# could when rate-limited. Declared HERE (after the apt layer) rather than up
# top so a version bump busts only this small layer, not the ~1 GB apt/tesseract
# layer above it.
ARG DOVI_TOOL_VERSION=2.3.2
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) DOVI_ARCH="x86_64-unknown-linux-musl" ;; \
      arm64) DOVI_ARCH="aarch64-unknown-linux-musl" ;; \
      *)     echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac && \
    mkdir -p /tmp/dovi && \
    curl -fSL "https://github.com/quietvoid/dovi_tool/releases/download/${DOVI_TOOL_VERSION}/dovi_tool-${DOVI_TOOL_VERSION}-${DOVI_ARCH}.tar.gz" \
        -o /tmp/dovi_tool.tar.gz && \
    tar -xzf /tmp/dovi_tool.tar.gz -C /tmp/dovi && \
    find /tmp/dovi -name "dovi_tool" -type f -exec mv {} /usr/local/bin/dovi_tool \; && \
    chmod +x /usr/local/bin/dovi_tool && \
    dovi_tool --version && \
    rm -rf /tmp/dovi /tmp/dovi_tool.tar.gz

# ---- 3. PGS subtitle OCR (pgsrip) ----
# Installed system-wide (not under /root/.local) so the tool is still on PATH
# when the container runs as a non-root user — e.g. Linux hosts using
# `--user $(id -u):$(id -g)` to keep output files owned by the invoking user.
# Hard failure on purpose, same rationale as dovi_tool above.
ENV PIPX_HOME=/opt/pipx
ENV PIPX_BIN_DIR=/usr/local/bin
RUN pipx install pgsrip && pgsrip --version

# ---- 4. Install muxm ----
# dos2unix converts Windows line endings (\r\n) to Unix (\n).
# Without this, bash fails with: /usr/local/bin/muxm: line 2: $'\r': command not found
# chmod 755 (not just +x): COPY preserves the host file's mode, and a
# world-UNREADABLE mode (e.g. rwx--x--x) breaks non-root runs — bash must
# READ a script to interpret it, and only root bypasses the missing r bit.
COPY muxm /usr/local/bin/muxm
RUN dos2unix /usr/local/bin/muxm && chmod 755 /usr/local/bin/muxm

# ---- 5. Verify the toolchain at build time ----
# Every check is fatal. The ffmpeg encoder/filter probes pin the capabilities
# the profiles depend on (x264/x265/SVT-AV1/Opus/E-AC-3/AAC encodes, and the
# zscale+tonemap chain `universal` uses for HDR→SDR), so an Ubuntu packaging
# change that drops one breaks the build instead of a user's encode.
# `muxm --version` is the canary for "the script cannot even start on Linux"
# (bash/coreutils dialect regressions — a class of bug that has shipped before).
#
# dovi_tool and pgsrip are intentionally absent here: each already runs its own
# `--version` as the last step of its install layer (steps 2 and 3), which fails
# the build if the binary is broken. Re-checking them here can never fail — don't
# re-add them.
RUN echo "--- Dependency check ---" && \
    bash --version | head -1 && \
    ffmpeg -version | head -1 && \
    jq --version && \
    MP4Box -version 2>&1 | head -1 && \
    tesseract --version 2>&1 | head -1 && \
    for enc in libx264 libx265 libsvtav1 libopus eac3 aac; do \
        ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw "$enc" \
            || { echo "MISSING ffmpeg encoder: $enc" >&2; exit 1; }; \
    done && \
    for flt in zscale tonemap; do \
        ffmpeg -hide_banner -filters 2>/dev/null | grep -qw "$flt" \
            || { echo "MISSING ffmpeg filter: $flt" >&2; exit 1; }; \
    done && \
    muxm --version && \
    echo "--- All checks passed ---"

# ---- 6. Working directories ----
RUN mkdir -p /media/input /media/output && chmod 777 /media/input /media/output

WORKDIR /media

# ---- 7. Default entrypoint ----
ENTRYPOINT ["muxm"]
CMD ["--help"]
