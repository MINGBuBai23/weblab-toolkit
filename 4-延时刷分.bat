@echo off
chcp 65001 >nul
title 4 - 延时刷分（用时随机 30~50 分钟）
cd /d "%~dp0"
echo.
echo  ============================================
echo   网页上的「用时」= 服务端算的（提交时刻 - 进实验时刻）
echo   所以本脚本会一直等到「进实验时间 + 随机 30~50 分钟」
echo   再自动提交，让页面上的用时落在 30~50 分钟
echo   窗口别关，到点会自己提交；等待期间可以干别的
echo  ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Invoke-LabPerfect.ps1" -Apply -WaitRandomTime
echo.
pause
