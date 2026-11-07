@echo off
chcp 65001 >nul
title 大肥鱼-一键启动
cd /d "%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start-all.ps1" -Dir "%~dp0." %*
set "DFY_STACK_EXIT=%ERRORLEVEL%"
echo.
timeout /t 15 >nul
exit /b %DFY_STACK_EXIT%
