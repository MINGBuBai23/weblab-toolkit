@echo off
chcp 65001 >nul
title 1 - 开始抓包
cd /d "%~dp0"
echo.
echo  ============================================
echo   开始抓包：会临时改系统代理到 127.0.0.1:8888
echo   做完实验后请务必运行「3-停止抓包.bat」
echo  ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\proxy-on.ps1"
echo.
pause
