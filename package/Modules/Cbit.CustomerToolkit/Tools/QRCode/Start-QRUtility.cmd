@echo off
setlocal
title CBIT - QR Code Utility
rem Let Windows PowerShell rebuild its module path instead of inheriting PowerShell 7 paths.
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -File "%~dp0Decode-QRCode.ps1" -Menu
if errorlevel 1 (
    echo.
    echo The QR utility could not start. The error is shown above.
    pause
)
endlocal
