@echo off
title Gmail Archive
echo.
echo Gmail Archive - By John Halfords
echo (Move to Trash script)
echo.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Gmail_Archive_Delete_v1.03.ps1"
echo.
echo Press any key (or another one...)
pause>nul