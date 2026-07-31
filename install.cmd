@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0ChatGPTUsageWidget.ps1" -Install
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%LOCALAPPDATA%\ChatGPTUsageWidget\LaunchWidget.ps1"
