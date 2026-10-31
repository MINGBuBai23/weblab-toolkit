@echo off
chcp 65001 >nul
title 2 - 一键刷分
cd /d "%~dp0"
echo.
echo  ============================================
echo   把最近一次实验提交改成满分数据并重放
echo   前提：已经运行过「1-开始抓包.bat」，且刚结束了一个实验
echo  ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Invoke-LabPerfect.ps1" -Apply
echo.
pause
