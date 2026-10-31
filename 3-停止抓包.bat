@echo off
chcp 65001 >nul
title 3 - 停止抓包
cd /d "%~dp0"
echo.
echo  ============================================
echo   停止 HttpSpy 并把系统代理还原成原来的设置
echo  ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\proxy-off.ps1"
echo.
pause
