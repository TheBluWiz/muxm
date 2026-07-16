@echo off
setlocal enabledelayedexpansion
REM Run from this script's own folder. A right-click "Run as administrator"
REM starts cmd in C:\Windows\System32, where docker-compose.yml / input / output
REM are not -- without this, the checks below fire with misleading messages.
cd /d "%~dp0"
REM ============================================================================
REM  MuxMaster -- Encode Videos on Windows
REM
REM  How to use:
REM    1. Put video files in the "input" folder
REM    2. Double-click this file
REM    3. Choose a profile when prompted
REM    4. Encoded files appear in the "output" folder
REM ============================================================================

echo.
echo  =============================================
echo   MuxMaster - Video Encoder
echo  =============================================
echo.

REM Check if Docker is running
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo  [ERROR] Docker is not running.
    echo  Please open Docker Desktop and wait for it to finish starting.
    echo.
    pause
    exit /b 1
)

REM Check the Docker Compose v2 plugin. It normally ships with Docker Desktop,
REM but a broken/partial install leaves "docker compose" failing with a cryptic
REM "'compose' is not a docker command" mid-run.
docker compose version >nul 2>&1
if %errorlevel% neq 0 (
    echo  [ERROR] The Docker Compose v2 plugin is missing or not working.
    echo  Open Docker Desktop and let it finish starting. If it keeps failing,
    echo  use Docker Desktop's Troubleshoot ^> Repair option, then try again.
    echo.
    pause
    exit /b 1
)

REM One "did you run setup?" gate. The Dockerfile is irrelevant at encode time
REM (the image is already built), so we only confirm what setup.bat leaves
REM behind. Mirrors encode.sh's single Setup-incomplete check.
set "setup_ok=1"
if not exist "docker-compose.yml" set "setup_ok="
if not exist "input"  set "setup_ok="
if not exist "output" set "setup_ok="
if not defined setup_ok (
    echo  [ERROR] Setup incomplete - run "setup.bat" first.
    echo.
    pause
    exit /b 1
)

REM List files in input folder
echo  Files in your "input" folder:
echo  -------------------------------------------
set filecount=0
for %%f in (input\*.mkv input\*.mp4 input\*.m4v input\*.mov input\*.avi input\*.ts input\*.m2ts input\*.wmv input\*.flv input\*.webm) do (
    set /a filecount+=1
    echo   !filecount!. %%~nxf
    set "file!filecount!=%%~nxf"
)

if !filecount!==0 (
    echo   [empty - no video files found]
    echo.
    echo  Put video files (.mkv .mp4 .m4v .mov .avi .ts .m2ts .wmv .flv .webm^)
    echo  in the "input" folder and run this again.
    echo.
    pause
    exit /b 0
)

echo  -------------------------------------------
echo.

REM Ask which file to encode (a number, or A for all of them)
set "firstfile=1"
set "lastfile=!filecount!"
if !filecount!==1 (
    set filechoice=1
    echo  Using: !file1!
) else (
    set /p filechoice="  Which file? Enter a number (1-!filecount!), or A for all: "
)

if /i "!filechoice!"=="A" (
    echo  Encoding all !filecount! files.
) else (
    REM Turn the raw entry into a bare integer WITHOUT ever expanding it onto a
    REM command line. The previous version indexed the file list using the raw
    REM set /p text via percent-expansion, so an entry containing a quote or an
    REM ampersand could abort the window or inject a command. set /a reads the
    REM value BY NAME and only does arithmetic on it, writing only a number to
    REM sel (never the raw string); we pre-clear sel so a non-numeric, empty, or
    REM EOF entry leaves it undefined and is rejected below.
    set "sel="
    set /a sel=filechoice 2>nul
    if not defined sel (
        echo  [ERROR] Invalid selection.
        pause
        exit /b 1
    )
    if !sel! lss 1 (
        echo  [ERROR] Invalid selection.
        pause
        exit /b 1
    )
    if !sel! gtr !filecount! (
        echo  [ERROR] Invalid selection.
        pause
        exit /b 1
    )
    set "firstfile=!sel!"
    set "lastfile=!sel!"
)

echo.
echo  =============================================
echo   Choose an Encoding Profile
echo  =============================================
echo.
echo    1. atv-directplay-hq         Apple TV Direct Play [recommended]
echo    2. streaming-hevc            HEVC for Plex / Jellyfin / Emby
echo    3. streaming-av1             AV1 for AV1-capable platforms, smaller files
echo    4. universal                 Plays on everything (H.264 SDR^)
echo    5. hdr10-hq                  Max-quality HDR10 (strips Dolby Vision^)
echo    6. archive                   Lossless preservation (no re-encode^)
echo    7. av1-hq                    High-quality AV1 archive
echo    8. animation                 Anime / cartoon optimized
echo    9. atv-directplay-animation  Anime for Apple TV Direct Play
echo   10. youtube-upload            YouTube upload prep
echo.
set /p profilechoice="  Enter a number (1-10): "

REM Profile menu -- one entry per profile in muxm's VALID_PROFILES
REM (tests/test_docker_parity.sh guards this list against renames).
REM Clear first: an inherited "profile" environment variable would defeat
REM the "if not defined" invalid-selection check below.
set "profile="
if "!profilechoice!"=="1"  set "profile=atv-directplay-hq"
if "!profilechoice!"=="2"  set "profile=streaming-hevc"
if "!profilechoice!"=="3"  set "profile=streaming-av1"
if "!profilechoice!"=="4"  set "profile=universal"
if "!profilechoice!"=="5"  set "profile=hdr10-hq"
if "!profilechoice!"=="6"  set "profile=archive"
if "!profilechoice!"=="7"  set "profile=av1-hq"
if "!profilechoice!"=="8"  set "profile=animation"
if "!profilechoice!"=="9"  set "profile=atv-directplay-animation"
if "!profilechoice!"=="10" set "profile=youtube-upload"

if not defined profile (
    echo  [ERROR] Invalid selection. Please enter 1-10.
    pause
    exit /b 1
)

REM Output container per profile -- mirrors each profile's documented container
REM (see `muxm --help`). Every profile is listed EXPLICITLY (no silent default):
REM test_docker_parity.sh cross-checks this table against muxm, and the fail-arm
REM below turns a newly-added-but-unmapped profile into a loud error rather than
REM a mis-containered .mp4. The two ATV profiles are container-passthrough (SRC):
REM keep the source extension when it is a supported output container, else .mkv.
set "outext="
if "!profile!"=="streaming-hevc"  set "outext=mp4"
if "!profile!"=="streaming-av1"   set "outext=mp4"
if "!profile!"=="universal"       set "outext=mp4"
if "!profile!"=="youtube-upload"  set "outext=mp4"
if "!profile!"=="archive"   set "outext=mkv"
if "!profile!"=="hdr10-hq"  set "outext=mkv"
if "!profile!"=="av1-hq"    set "outext=mkv"
if "!profile!"=="animation" set "outext=mkv"
if "!profile!"=="atv-directplay-hq"        set "outext=SRC"
if "!profile!"=="atv-directplay-animation" set "outext=SRC"
if not defined outext (
    echo  [ERROR] internal: no output container mapped for profile "!profile!".
    pause
    exit /b 1
)

REM ---- Refuse if two selected inputs would write the same output ----
REM muxm defaults to overwriting its output and only auto-versions when the
REM source and output paths are identical, so two inputs whose stems collide
REM (movie.mkv + movie.ts -^> movie.mp4, or two passthrough sources both
REM falling back to .mkv) would silently clobber each other. Detect it here
REM and stop before any encode runs. Mirrors encode.sh.
for /l %%n in (!firstfile!,1,!lastfile!) do (
    set "cchosen=!file%%n!"
    for %%i in ("!cchosen!") do set "cbase=%%~ni"
    for %%i in ("!cchosen!") do set "cext=%%~xi"
    set "cext=!cext:~1!"
    set "cuse=!outext!"
    if "!cuse!"=="SRC" (
        set "cuse=mkv"
        if /i "!cext!"=="mp4" set "cuse=!cext!"
        if /i "!cext!"=="m4v" set "cuse=!cext!"
        if /i "!cext!"=="mov" set "cuse=!cext!"
        if /i "!cext!"=="mkv" set "cuse=!cext!"
    )
    set "plan%%n=!cbase!.!cuse!"
)

set "collision="
for /l %%a in (!firstfile!,1,!lastfile!) do (
    for /l %%b in (!firstfile!,1,!lastfile!) do (
        if %%a lss %%b if /i "!plan%%a!"=="!plan%%b!" (
            echo  [ERROR] Two input files would both be written to "output\!plan%%a!":
            echo            - !file%%a!
            echo            - !file%%b!
            set "collision=1"
        )
    )
)
if defined collision (
    echo.
    echo  Rename one of the colliding files, or encode them one at a time, and try again.
    pause
    exit /b 1
)

set failures=0
for /l %%n in (!firstfile!,1,!lastfile!) do (
    set "chosen=!file%%n!"

    REM Filename without extension, and the source extension (without dot)
    for %%i in ("!chosen!") do set "basename=%%~ni"
    for %%i in ("!chosen!") do set "srcext=%%~xi"
    set "srcext=!srcext:~1!"

    set "useext=!outext!"
    if "!useext!"=="SRC" (
        set "useext=mkv"
        if /i "!srcext!"=="mp4" set "useext=!srcext!"
        if /i "!srcext!"=="m4v" set "useext=!srcext!"
        if /i "!srcext!"=="mov" set "useext=!srcext!"
        if /i "!srcext!"=="mkv" set "useext=!srcext!"
    )

    echo.
    echo  =============================================
    echo   Starting encode
    echo  =============================================
    echo.
    echo   File:    !chosen!
    echo   Profile: !profile!
    echo.

    docker compose run --rm muxm --profile !profile! "/media/input/!chosen!" "/media/output/!basename!.!useext!"

    if !errorlevel!==0 (
        echo.
        echo   Done: output\!basename!.!useext!
    ) else (
        echo.
        echo   [ERROR] Encode failed for: !chosen! ^(code: !errorlevel!^)
        set /a failures+=1
    )
)

echo.
if !failures!==0 (
    echo  =============================================
    echo   Done. Check the "output" folder.
    echo  =============================================
) else (
    echo  =============================================
    echo   Finished with !failures! failed encode^(s^).
    echo   Check the messages above for details.
    echo  =============================================
)
echo.
pause
