@echo off
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

REM Quick sanity check: run muxm --version inside the container
echo.
echo  Verifying installation...
docker compose run --rm muxm --version >nul 2>&1
if %errorlevel% neq 0 (
    echo  [WARNING] muxm may not be working correctly inside the container.
    echo  Try running: docker compose run --rm muxm --help
    echo.
) else (
    echo  [OK] muxm is working.
)

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
