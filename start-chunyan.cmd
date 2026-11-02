@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-chunyan.ps1"
if errorlevel 1 (
  echo.
  echo Startup failed. Check the PowerShell windows and try again.
  pause
)
