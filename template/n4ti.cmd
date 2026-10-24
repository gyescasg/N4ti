@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0gy.ps1" %*
exit /b %errorlevel%
