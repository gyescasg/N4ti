@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-GY.ps1" %*
exit /b %errorlevel%
