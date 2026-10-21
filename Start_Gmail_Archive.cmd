@echo off
title Gmail Archive
echo.
echo Gmail Archive - By John Halfords
echo (Archive script)
echo.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Gmail_Archive_v1.00.ps1"
echo.
echo Press any key (or another one...)
pause>nul