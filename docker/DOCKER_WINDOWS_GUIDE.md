# MuxMaster on Windows -- Docker Setup Guide

This guide walks you through running MuxMaster (`muxm`) on Windows using Docker. No coding experience required.

---

## What You're Setting Up

MuxMaster is a macOS/Linux command-line tool, so it can't run directly on Windows. Docker solves this by running a small Linux environment inside Windows, with all of muxm's dependencies pre-installed. You interact with it through simple batch files or typed commands.

Once set up, you'll have two workflows:

- **Double-click `encode.bat`** -- an interactive menu that walks you through encoding a file step by step
- **Type a command** -- for full control over every muxm flag and option

---

## Before You Start

**System requirements:**

- **Windows 10 (version 2004 or later) or Windows 11.** Older versions of Windows 10 won't work.
- **At least 8 GB of RAM.** 16 GB or more is strongly recommended. Video encoding is memory-intensive, and both Windows and Docker need their share. With only 8 GB, long encodes may be killed silently.
- **Disk space.** The Docker image is roughly 2.5 GB (it bundles the full encoding toolchain plus OCR language data for ~160 subtitle languages). You'll also need room for your source files plus the encoded output. Budget at least 2x the size of your largest source file as free space.
- **An internet connection** for the initial setup (to download Docker and build the image). Not needed after that.

**A note about encoding speed:**

MuxMaster uses CPU-based encoding (x265/x264/SVT-AV1) inside Docker. There is no GPU acceleration. If you've used HandBrake with NVENC or QuickSync before, expect MuxMaster encodes to be significantly slower -- a 2-hour movie might take anywhere from 30 minutes to several hours depending on your CPU and the chosen profile.

This is a deliberate tradeoff: CPU encoding produces noticeably better quality at the same file size compared to GPU encoding. The `universal` profile (H.264) is the fastest; `hdr10-hq` with a slow preset is the slowest.

---

## Part 1: Install Docker Desktop

1. Go to [https://www.docker.com/products/docker-desktop/](https://www.docker.com/products/docker-desktop/) and click **Download for Windows**.
2. Run the installer. Accept the defaults.
3. When it asks about **WSL 2** vs **Hyper-V**, choose **WSL 2** (this is the default and recommended option).
4. Restart your computer when prompted.
5. After restarting, open **Docker Desktop** from your Start menu. Wait for the status indicator in the bottom-left to show **"Engine running"** (green). This may take a minute on first launch.

> **Note:** Docker Desktop is free for personal use. You don't need to create an account -- click "Continue without signing in" if prompted.

**If the installer fails or mentions "virtualization":** Some PCs -- especially older machines or company-managed computers -- have hardware virtualization disabled in the BIOS. Docker requires it. You'll see an error mentioning "WSL 2", "Hyper-V", or "virtualization". To fix this, you need to enter your PC's BIOS/UEFI settings (usually by pressing F2, F12, or Delete during startup) and enable "Intel VT-x" or "AMD-V" (the exact name and location varies by manufacturer). If you're not comfortable doing this, search for your PC model + "enable virtualization" for a walkthrough.

---

## Part 2: Set Up MuxMaster

1. Download the ready-made bundle -- the `muxm-docker-windows-v*.zip` file attached to the latest release at [github.com/TheBluWiz/MuxMaster/releases](https://github.com/TheBluWiz/MuxMaster/releases) -- and unzip it into a folder anywhere you like, for example `C:\MuxMaster`. It contains everything listed below, so you can skip step 2. (It also includes a copy of this guide and `LICENSE.md` -- eight files in total. Those two aren't needed to run anything; leave them be.)

2. (Only if you're collecting the files by hand instead of using the bundle.) Place **all six** of these files inside that folder:

```
C:\MuxMaster\
   Dockerfile
   docker-compose.yml
   .dockerignore
   setup.bat
   encode.bat
   muxm                 <-- the muxm script itself
```

> **Tip:** The `.dockerignore` file starts with a dot, so Windows Explorer hides it by default. To confirm it's there, click **View** in the toolbar and check **Hidden items** (Windows 10) or **Show > Hidden items** (Windows 11). You don't need to open or edit this file -- just make sure it's present.

3. Double-click **`setup.bat`**. It will:
   - Verify that Docker is running and all files are present
   - Create `input` and `output` folders for your video files
   - Build the Docker image with all of muxm's dependencies (ffmpeg, jq, dovi_tool, MP4Box, tesseract, pgsrip)
   - Run a quick sanity check to confirm muxm works

The first build takes a few minutes while it downloads and installs packages. You'll see a lot of terminal output scroll by -- this is normal. When you see **"Setup complete!"**, you're done.

You only need to run setup once. Run it again only if you update the muxm script to a new version.

---

## Part 3: Encode a Video

### Important: Filenames

Before encoding, check your filenames. Spaces, parentheses, hyphens, and most characters are fine:

- `The Dark Knight (2008).mkv` -- works
- `movie-rip_final.mkv` -- works
- `Spirited Away [1080p].mkv` -- works

But filenames containing `!` or `%` will cause errors. Rename them first:

- `What a Movie!.mkv` -- rename to `What a Movie.mkv`
- `100% True.mkv` -- rename to `100 Percent True.mkv`

### Option A: Double-Click (Easy)

1. Copy a video file into the **`input`** folder.
2. Double-click **`encode.bat`**.
3. It lists your files and asks you to pick one.
4. Choose a profile (Apple TV, streaming HEVC, universal, etc.). To encode **every** file in the folder with the same profile, answer **A** when asked which file.
5. The encoded file appears in the **`output`** folder when it's done.

The window will stay open while encoding. You can minimize it, but don't close it -- that kills the encode. When it finishes, you'll see either "Done!" or an error message.

### Option B: Command Line (Full Control)

Open a terminal in your MuxMaster folder:
- **Windows 11:** Right-click in an empty area of the folder and choose **"Open in Terminal"**
- **Windows 10:** Hold **Shift**, right-click in an empty area of the folder, and choose **"Open PowerShell window here"**

Then run:

```
docker compose run --rm muxm --profile atv-directplay-hq /media/input/movie.mkv /media/output/movie.mp4
```

This gives you access to every muxm flag. Some examples:

```
REM Apple TV Direct Play
docker compose run --rm muxm --profile atv-directplay-hq /media/input/movie.mkv /media/output/movie.mp4

REM Streaming for Plex/Jellyfin
docker compose run --rm muxm --profile streaming-hevc /media/input/movie.mkv /media/output/movie.mp4

REM Universal compatibility (plays everywhere)
docker compose run --rm muxm --profile universal /media/input/movie.mkv /media/output/movie.mp4

REM Anime with custom CRF
docker compose run --rm muxm --profile animation --crf 14 /media/input/show.mkv /media/output/show.mkv

REM Dry run (preview what muxm would do, no encoding)
docker compose run --rm muxm --profile streaming-hevc --dry-run /media/input/movie.mkv

REM Show all available flags
docker compose run --rm muxm --help
```

> **Important:** Inside the container, your files live at `/media/input/` and `/media/output/` -- always use those paths in commands, not your Windows paths like `C:\MuxMaster\input\`.

> **Filenames with spaces** in command-line mode need to be wrapped in quotes: `"/media/input/The Dark Knight (2008).mkv"`

---

## Encoding Multiple Files

To encode every MKV in your input folder with the same profile, open a terminal and run:

**Command Prompt (cmd):**
```
for %f in (input\*.mkv) do docker compose run --rm muxm --profile streaming-hevc "/media/input/%~nxf" "/media/output/%~nf.mp4"
```

**PowerShell:**
```powershell
Get-ChildItem input\*.mkv | ForEach-Object { docker compose run --rm muxm --profile streaming-hevc "/media/input/$($_.Name)" "/media/output/$($_.BaseName).mp4" }
```

Each file is processed one at a time. This can take a while for large batches -- consider running it overnight.

> **Match the extension to the profile's container.** Both loops above hardcode
> `.mp4`, which is right for `streaming-hevc` (and for `streaming-av1`,
> `universal`, `youtube-upload`). But muxm takes the container from the output
> filename you give it, **overriding the profile's own choice**. So pasting one of
> these loops with an MKV-container profile (`animation`, `hdr10-hq`, `av1-hq`,
> `archive`) would quietly hand you an MP4 -- and MP4 can't carry everything MKV
> can (ASS subtitles and some lossless audio, for instance), which is exactly why
> those profiles choose MKV. Swap the profile and the extension together -- e.g.
> for `animation`:
>
> ```
> for %f in (input\*.mkv) do docker compose run --rm muxm --profile animation "/media/input/%~nxf" "/media/output/%~nf.mkv"
> ```
>
> Run `docker compose run --rm muxm --help` to see each profile's container. (The
> two `atv-directplay-*` profiles keep the source file's container, so match
> whatever your inputs are.) The double-click `encode.bat` / `encode.sh` helpers
> work all of this out for you -- this only matters for hand-written loops.

---

## Using a Custom Config File

If you want to customize muxm's default settings:

1. Create a file called `.muxmrc` in your MuxMaster folder. (See "Creating files that start with a dot" in the Troubleshooting section below if Windows won't let you.)

   > **⚠ Important — save `.muxmrc` with Unix (LF) line endings, not Windows (CRLF).**
   > muxm reads `.muxmrc` as a shell script inside the Linux container. Windows'
   > default line endings (CRLF) leave an invisible carriage return on every line,
   > which breaks muxm on **every** run — you'll see errors like
   > `Invalid CRF_VALUE ... (got: 18)` (the value looks correct because the stray
   > character is invisible) or `$'\r': command not found`.
   >
   > Plain Notepad creates new files as CRLF with no way to change that, so **don't
   > create `.muxmrc` in Notepad.** Use an editor that lets you pick the line ending:
   > - **VS Code** — click **CRLF** in the bottom-right status bar, choose **LF**, then save.
   > - **Notepad++** — **Edit > EOL Conversion > Unix (LF)**, then save.
   >
   > (Editing the *existing* `docker-compose.yml` in step 2 with Notepad is fine —
   > Notepad preserves a file's current line endings; only *creating* a brand-new
   > `.muxmrc` is a problem.)

2. Open `docker-compose.yml` in Notepad and remove the `#` from this line:
   ```
   # - ./.muxmrc:/media/.muxmrc:ro
   ```
   so it reads:
   ```
   - ./.muxmrc:/media/.muxmrc:ro
   ```
3. Now muxm will read your config on every run.

---

## Quick Reference

| What you want to do | How |
|---|---|
| Encode a file (interactive) | Double-click `encode.bat` |
| Encode with full control | `docker compose run --rm muxm --profile NAME /media/input/FILE /media/output/FILE` |
| Preview without encoding | Add `--dry-run` to any command |
| See all options | `docker compose run --rm muxm --help` |
| Rebuild after updating muxm | Double-click `setup.bat` (or run `docker compose build --no-cache`) |

---

## Troubleshooting

### Setup Problems

**Docker installer fails with a "virtualization" error**
Your PC's hardware virtualization is disabled. See the note at the end of Part 1 above.

**Docker Desktop is stuck on "Starting..."**
Give it a couple of minutes. If it doesn't resolve, open **Task Manager** (Ctrl+Shift+Esc), look for "Docker Desktop" or "com.docker", end those processes, and try opening Docker Desktop again. If it keeps happening, restart your computer.

**Docker Desktop keeps asking me to update / accept terms**
Docker Desktop periodically prompts for updates and re-acceptance of its terms. This is normal. Accept and update when prompted. If an update happens mid-encode, the encode will be killed -- try to update before starting long encodes.

**setup.bat says "muxm script not found"**
Make sure the `muxm` file (no file extension) is in the same folder as `setup.bat` and `Dockerfile`. If you downloaded it from GitHub, your browser may have added a `.txt` extension. To check: in Windows Explorer, click **View > Show > File name extensions** (Windows 11) or **View > check "File name extensions"** (Windows 10). If you see `muxm.txt`, rename it to just `muxm`.

**Build fails with a network error**
Docker needs internet access to download packages during the initial build. Check your connection. If you're on a VPN or corporate network, try disconnecting the VPN first -- some VPNs block Docker's network traffic. Firewalls and antivirus software can also interfere.

### Encoding Problems

**Encode seems stuck or is very slow**
This is almost certainly normal. Video encoding is CPU-intensive work. There is no GPU acceleration in this setup. A 2-hour Blu-ray rip can take 1-4 hours or more to encode, depending on your CPU and profile. The `universal` profile is fastest (H.264); HEVC profiles like `hdr10-hq` are slowest. If you want to verify it's still working, check that CPU usage is high in Task Manager.

**Encoding is much slower than expected or system feels sluggish**
If your antivirus software (Windows Defender, Norton, McAfee, etc.) is scanning the `input` and `output` folders in real time, it intercepts every file read and write, which can dramatically slow things down. Try adding your MuxMaster folder to your antivirus exclusion list. In Windows Security: Settings > Virus & threat protection > Manage settings > Exclusions > Add exclusion > Folder.

**Encode was killed with no error message**
Docker may have run out of memory. By default, Docker Desktop limits itself to about half your system RAM. If you have 8 GB total, that may not be enough for demanding encodes. Open Docker Desktop > Settings > Resources and increase the memory limit. 12 GB or more is recommended if your system has it.

**A killed encode left huge hidden files behind (`.muxm.tmp.*`)**
While encoding, muxm stages its intermediate files in a hidden `.muxm.tmp.*` folder **next to the output** -- that is, inside the `output` folder on your PC, not inside Docker. A run that finishes (or fails) normally cleans this up. A run that was *hard-killed* -- Docker Desktop updated or crashed mid-encode, `wsl --shutdown`, the container was killed, or the PC lost power -- never gets the chance, so a multi-gigabyte hidden folder can be left behind. `docker system prune` will **not** reclaim it: it isn't Docker's to clean.

To check, open the `output` folder and turn on hidden items (**View > Show > Hidden items** on Windows 11, or **View > Hidden items** on Windows 10). After a killed encode it's safe to delete:

- `output\.muxm.tmp.*` -- leftover work folders. These are the big ones.
- `output\.<name>.lock` -- a leftover lock for that output name.

Only delete these when no encode is running.

**muxm says another run is already writing to this output**
If a previous encode was hard-killed, its lock file can be left behind and muxm refuses to start:

```
Another muxm run (PID 1) is already writing to this output: /media/output/movie.mp4
 — wait for it to finish, choose a different output path, or remove the stale lock
 with: rm -rf '/media/output/.movie.mp4.lock'
```

That path is the **container's** view. `/media/output` is simply your `output` folder, so the file to delete is `output\.movie.mp4.lock` on your PC (it's hidden -- turn on hidden items as above). Make sure no encode is actually running first, then delete it and re-run.

**"Permission denied" or file not found**
Make sure your video files are directly in the `input` folder (not in a subfolder), and that filenames don't contain `!` or `%` characters (see the Filenames section above).

**Output file is 0 bytes or missing**
Check the terminal output for error messages from muxm. Run with `--dry-run` first to preview what muxm would do: `docker compose run --rm muxm --profile streaming-hevc --dry-run /media/input/movie.mkv`

**Output file appeared and then vanished**
Some antivirus tools quarantine files that are created by "unknown" processes (which is how they see Docker). Check your antivirus quarantine. Adding the MuxMaster folder to your antivirus exclusions should prevent this.

### Other

**Creating files that start with a dot (`.muxmrc`)**
Windows Explorer won't let you name a new file `.muxmrc` directly, and it must be saved with Unix (LF) line endings (see "Using a Custom Config File" above for why). The reliable way to satisfy both is a code editor:
- **VS Code** -- File > New File, type your settings, click **CRLF** in the status bar and switch it to **LF**, then Save As `.muxmrc` (set "Save as type" to *All Files*).
- **Notepad++** -- type your settings, choose **Edit > EOL Conversion > Unix (LF)**, then Save As `.muxmrc` (set "Save as type" to *All types*, or wrap the name in quotes: `".muxmrc"`).

Avoid `echo. > .muxmrc` and plain Notepad -- both write Windows (CRLF) line endings that break muxm on every run. (Don't recreate `.dockerignore` this way -- it ships with real contents; if it's missing, re-download the release bundle.)

**Updating muxm to a new version**
Replace the `muxm` file in your MuxMaster folder with the new version, then double-click `setup.bat` again. If the update doesn't seem to take effect, run `docker compose build --no-cache` from a terminal to force a full rebuild.

**Freeing disk space**
Docker stores its images and build cache on your system drive. Over time this can grow. To clean up, open Docker Desktop > Settings > Resources > Disk image and note the size, or run `docker system prune` in a terminal to remove unused data.

If space is still missing after that, check your `output` folder for hidden `.muxm.tmp.*` leftovers from a killed encode -- `docker system prune` cannot reclaim those, because they live on your PC rather than inside Docker. See "A killed encode left huge hidden files behind" above.
