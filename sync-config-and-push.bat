@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\sync-config-and-push.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo Sync failed with exit code %EXIT_CODE%.
) else (
  echo Sync completed.
)

pause
exit /b %EXIT_CODE%
