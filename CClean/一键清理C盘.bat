@echo off
chcp 65001 >nul
title C Drive Cleaner

:: ============================================================
::  C Drive Cleaner Launcher
::  Auto-elevates to admin, then runs PowerShell script
::  Usage: double-click this file, no installation needed
:: ============================================================

set "PS_SCRIPT=%~dp0CClean.ps1"

if not exist "%PS_SCRIPT%" (
    echo [ERROR] Script not found: %PS_SCRIPT%
    echo Please keep CClean.ps1 in the same folder as this BAT file.
    echo.
    pause
    exit /b 1
)

:: Check for admin rights
net session >nul 2>nul
if "%errorLevel%"=="0" (
    goto :run
) else (
    echo Requesting admin rights, click YES in the popup...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:run
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%PS_SCRIPT%"
set "RC=%errorLevel%"

if "%RC%" neq "0" (
    echo.
    echo [INFO] Program exited with code: %RC%
    echo If the window did not appear, try these steps:
    echo   1. Check %TEMP% for CClean_*.log for error details
    echo   2. Make sure this folder is not blocked by antivirus
    echo   3. Right-click and select "Run as administrator"
    echo.
    pause
)
exit /b