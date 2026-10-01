@echo off
setlocal
title Firefox omni.ja patch

fltmc >nul 2>&1
if not errorlevel 1 goto admin_ok

echo Requesting administrator permission...
powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:admin_ok
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0firefox_omnia_patch.ps1"
echo.
echo Press a key to close this window.
pause >nul
endlocal
