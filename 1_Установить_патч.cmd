@echo off
chcp 65001 >nul
echo ============================================================
echo   Patch for Yandex Music: X button now minimizes to tray
echo   (close the console window if it stays open)
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0YandexMusicTrayPatch.ps1"
echo.
pause
