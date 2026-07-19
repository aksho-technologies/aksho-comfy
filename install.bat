@echo off
setlocal
title Aksho ComfyUI Installer

rem Aksho ComfyUI one-click installer bootstrap.
rem Downloads the real installer (PowerShell) from Aksho's CDN and runs it.
rem The installer is idempotent: run it again anytime to update or repair.

set "AKSHO_DL=https://dl.akshoai.com"
set "PS1_URL=%AKSHO_DL%/installer/install.ps1"
set "PS1_LOCAL=%TEMP%\aksho-comfy-install.ps1"

echo.
echo  ============================================
echo   AKSHO COMFY - local ComfyUI for Atelier
echo  ============================================
echo.
echo [AKSHO COMFY] Fetching installer...

where curl.exe >nul 2>nul
if errorlevel 1 (
    echo [AKSHO COMFY] curl.exe not found. Please update Windows 10/11 and try again.
    pause
    exit /b 1
)

curl.exe -fsSL -m 30 "%PS1_URL%" -o "%PS1_LOCAL%"
if errorlevel 1 (
    echo [AKSHO COMFY] Could not download the installer. Check your internet connection and try again.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_LOCAL%" %*
if errorlevel 1 (
    echo.
    echo [AKSHO COMFY] The installer reported a problem. See the messages above.
    pause
    exit /b 1
)

exit /b 0
