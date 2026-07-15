@echo off
REM Run from this script's own folder. A right-click "Run as administrator"
REM starts cmd in C:\Windows\System32, where the muxm files are not -- without
REM this, the "files not found" checks below fire on correctly-placed files.
cd /d "%~dp0"
REM ============================================================================
REM  MuxMaster -- First-Time Setup for Windows
REM
REM  What this does:
REM    1. Creates "input" and "output" folders for your video files
REM    2. Builds the MuxMaster Docker image with all dependencies
REM
REM  You only need to run this ONCE (or again after updating muxm).
REM ============================================================================

echo.
echo  =============================================
echo   MuxMaster - First-Time Setup
echo  =============================================
echo.

REM Check that muxm script exists in this folder
if not exist "muxm" (
    echo  [ERROR] The "muxm" script was not found in this folder.
    echo.
    echo  Make sure the following files are all in the same folder:
    echo    - muxm
    echo    - Dockerfile
    echo    - docker-compose.yml
    echo    - setup.bat
    echo    - encode.bat
    echo    - .dockerignore
    echo.
    pause
    exit /b 1
)

REM Check that Dockerfile exists
if not exist "Dockerfile" (
    echo  [ERROR] "Dockerfile" was not found in this folder.
    echo  Make sure all MuxMaster files are in the same folder.
    echo.
    pause
    exit /b 1
)

REM Check if Docker is running
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo  [ERROR] Docker is not running.
    echo.
    echo  Please open Docker Desktop and wait for it to finish starting,
    echo  then run this script again.
    echo.
    pause
    exit /b 1
)

echo  [OK] Docker is running.

REM Check the Docker Compose v2 plugin. Debian-style engines and partial Docker
REM Desktop installs can lack it, and "docker compose build" below would then
REM fail with a cryptic "'compose' is not a docker command".
docker compose version >nul 2>&1
if %errorlevel% neq 0 (
    echo  [ERROR] The Docker Compose v2 plugin is missing or not working.
    echo  Open Docker Desktop and let it finish starting. If it keeps failing,
    echo  use Docker Desktop's Troubleshoot ^> Repair option, then run this again.
    echo.
    pause
    exit /b 1
)
echo  [OK] Docker Compose v2 is available.
echo.

REM Create folders
if not exist "input"  mkdir input
if not exist "output" mkdir output
echo  [OK] Created "input" and "output" folders.

REM Build the image
echo.
echo  Building MuxMaster image (this may take a few minutes the first time)...
echo.
docker compose build
if %errorlevel% neq 0 (
    echo.
    echo  [ERROR] Build failed. Check the messages above for details.
    pause
    exit /b 1
)

REM Quick sanity check: run muxm --version inside the container. Its output is
REM shown, not silenced: on failure the real container error prints just above the
REM message below, and we exit non-zero instead of falling through to the
REM "Setup complete!" banner (which had let ./setup.bat "succeed" on a dead image).
echo.
echo  Verifying installation...
docker compose run --rm muxm --version
if %errorlevel% neq 0 (
    echo.
    echo  [ERROR] muxm could not run inside the container. Setup did NOT complete.
    echo  The container's error is shown above. Try:
    echo    docker compose run --rm muxm --help
    echo  or rebuild from scratch with:
    echo    docker compose build --no-cache
    echo.
    pause
    exit /b 1
)
echo  [OK] muxm is working.

echo.
echo  =============================================
echo   Setup complete!
echo  =============================================
echo.
echo  Next steps:
echo    1. Put video files in the "input" folder
echo    2. Double-click "encode.bat" to encode them
echo.
pause
