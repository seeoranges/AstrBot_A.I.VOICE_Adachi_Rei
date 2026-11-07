@echo off
chcp 65001 >nul
title 大肥鱼-全部关闭
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\stop-all.ps1" -Dir "%~dp0." %*
set "DFY_STACK_EXIT=%ERRORLEVEL%"
echo.
timeout /t 10 >nul
exit /b %DFY_STACK_EXIT%
