@echo off
setlocal
if "%~1"=="" (
  echo Usage: Install-GY.cmd "C:\path\to\project"
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-GY.ps1" -ProjectPath "%~1"
exit /b %errorlevel%
