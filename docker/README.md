# Running MuxMaster in Docker (macOS / Linux / Windows)

Docker packages muxm together with **all** of its dependencies (ffmpeg, jq, bc,
dovi_tool, MP4Box, tesseract with full language data, pgsrip) into one image —
no manual installs, identical behavior on every OS. It is the supported way to
run MuxMaster on **Windows**, and an option anywhere you'd rather not install
the toolchain natively.

**Prefer native when you can:**

- **macOS** — `brew install TheBluWiz/taps/muxm` runs natively, is faster, and
  can use VideoToolbox hardware acceleration (`--hw-accel videotoolbox`).
  Inside Docker, encoding is CPU-only.
- **Linux** — muxm runs natively (`muxm --setup` installs dependencies).
  Docker is handy when you can't install packages system-wide.
- **Windows** — Docker is the way. Follow the
  **[step-by-step Windows guide](DOCKER_WINDOWS_GUIDE.md)** — it assumes no
  command-line experience and covers installing Docker Desktop, setup, and
  troubleshooting.

## Quick start (macOS / Linux)

From a repo checkout:

```bash
cd docker
./setup.sh          # one-time: builds the image, creates input/ and output/
# drop a video into docker/input/, then:
./encode.sh         # guided: pick a file, pick a profile, done
```

`setup.sh` copies the repo's `muxm` into this folder for the image build
(that copy is gitignored) and re-copies it whenever the repo version is newer,
so rerunning `setup.sh` after an update always rebuilds from the current script.

## Quick start (Windows)

Follow the [Windows guide](DOCKER_WINDOWS_GUIDE.md). Short version: install
Docker Desktop, put the files listed in the guide into one folder
(`setup.bat`, `encode.bat`, `Dockerfile`, `docker-compose.yml`,
`.dockerignore`, and the `muxm` script), double-click `setup.bat` once, then
double-click `encode.bat` whenever you want to encode.

## Direct control (any OS)

The helpers are conveniences — every muxm flag works directly:

```bash
docker compose run --rm muxm --profile atv-directplay-hq /media/input/movie.mkv /media/output/movie.mp4
docker compose run --rm muxm --profile streaming-hevc --dry-run /media/input/movie.mkv
docker compose run --rm muxm --help
```

Inside the container your folders are **`/media/input`** and
**`/media/output`** — always use those paths in commands, never host paths.
If you pass no output path, muxm writes next to the source, i.e. into your
`input` folder — passing an explicit `/media/output/...` path keeps things
tidy.

## Good to know

- **Output ownership (Linux hosts).** A plain `docker compose run` executes as
  root, so output files land root-owned. `encode.sh` already handles this by
  running the container as your uid/gid; for direct commands, add
  `--user "$(id -u):$(id -g)"` after `run --rm` if you want the same.
  macOS and Windows (Docker Desktop) map ownership transparently — nothing to do.
- **Root-owned `input`/`output` (Linux hosts).** If a `docker compose run` is the
  first thing that touches this folder — before `./setup.sh` has created them —
  the Docker engine auto-creates the missing bind-mount sources as `root:root`.
  Every later `--user` encode then dies with "Output directory not writable", and
  rerunning `setup.sh` **cannot** repair it (`mkdir -p` happily succeeds on a
  directory it can't write). `setup.sh` and `encode.sh` now detect this and print
  the one command that fixes it:

  ```bash
  sudo chown -R "$(id -u):$(id -g)" input output
  ```

  Running `./setup.sh` first avoids the situation entirely.
- **Custom config.** Uncomment the `.muxmrc` line in `docker-compose.yml` to
  mount a config file (it lands in muxm's project-level config tier inside the
  container, so it applies on every run).
- **Temp space.** muxm stages intermediates next to the output by default, so
  large temp files live on your mounted `output` folder — not inside Docker's
  VM disk. No sizing knobs needed.
- **No hardware acceleration.** Encodes inside Docker are CPU-only (x264 /
  x265 / SVT-AV1). Expect a 2-hour movie to take from ~30 minutes to several
  hours depending on CPU and profile.
- **Rebuilding.** After updating muxm, rerun `./setup.sh` / `setup.bat`.
  The build is verified end-to-end: it fails loudly (rather than producing a
  quietly degraded image) if any dependency, ffmpeg encoder, or muxm itself
  doesn't work.

## For maintainers

- `Dockerfile` pins `dovi_tool` via `ARG DOVI_TOOL_VERSION`; bump it
  deliberately. Full tesseract language data is installed by default
  (`ARG TESSERACT_LANG_PACKAGES` to slim down custom builds).
- `tests/test_docker_parity.sh` (part of the `docs` suite) cross-checks
  everything under `docker/` that duplicates knowledge owned by `muxm`: profile
  names in both encode menus (assignments *and* echo'd labels) and in the guide
  examples, each profile's output container and the container-passthrough set,
  the input-extension globs, the Dockerfile's required-tool roster, the staged
  `docker/muxm` copy, the bundle manifest, and line-ending policy on the `.bat`
  files. It reads muxm's `VALID_PROFILES`, per-profile `OUTPUT_EXT`,
  `_check_tool … required` roster, and completion source list — so a rename or a
  container change fails the suite until these files are updated. Note this guard
  is **not** fixed by `tools/gen-docs.sh`; these are hand-maintained files.
- `tools/gen-docker-bundle.sh` zips the Windows-layperson bundle for attaching to
  a GitHub release. Its `BUNDLE_FILES` array is the single source of truth for the
  contents: the six files listed above plus `DOCKER_WINDOWS_GUIDE.md` and
  `LICENSE.md` (redistribution requires the license — see LICENSE.md §3), so the
  zip holds **eight**. The parity guard reads that same array, so the bundler and
  the check can't drift apart.
