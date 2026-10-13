@echo off
chcp 65001 >nul
echo ============================================================
echo   Undo patch (restore original Yandex Music files)
echo ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0YandexMusicTrayPatch.ps1" -Undo
echo.
pause
