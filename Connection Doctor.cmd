@echo off
rem Opens Connection Doctor. It only measures your connection - no admin rights, no changes.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ConnectionDoctor.ps1"
