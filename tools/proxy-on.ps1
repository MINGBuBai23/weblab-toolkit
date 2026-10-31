# proxy-on.ps1 —— 打开本地抓包代理（只影响走系统代理的程序）
#   1) 记录当前代理设置到 proxy-state.json（关闭时原样还原，别把 Clash 的代理搞丢）
#   2) 后台启动 HttpSpy（127.0.0.1:8888，抓包存 tools\capture\）
#   3) 把当前用户的 IE/WinINET 代理指向它
# 关闭：.\proxy-off.ps1
param([int]$Port = 8888)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$spy  = Join-Path $here 'HttpSpy.exe'
if (-not (Test-Path $spy)) { throw "缺 HttpSpy.exe，先 csc 编译 HttpSpy.cs" }

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$cur = Get-ItemProperty -Path $key
$stateFile = Join-Path $here 'proxy-state.json'
# 只在第一次开启时备份；重复执行不要把备份覆盖成我们自己的 8888
if ((Test-Path $stateFile) -and ([string]$cur.ProxyServer -eq "127.0.0.1:$Port")) {
    Write-Host "检测到已在抓包模式（备份已存在），跳过备份覆盖。" -ForegroundColor Yellow
} else {
    @{
        ProxyEnable   = [int]$cur.ProxyEnable
        ProxyServer   = [string]$cur.ProxyServer
        ProxyOverride = [string]$cur.ProxyOverride
    } | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
    Write-Host "已备份原代理: ProxyEnable=$($cur.ProxyEnable)  ProxyServer=$($cur.ProxyServer)"
}

$cap = Join-Path $here 'capture'
New-Item -ItemType Directory -Force -Path $cap | Out-Null
Get-Process HttpSpy -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath $spy -ArgumentList "$Port", $cap -WindowStyle Hidden
Start-Sleep -Milliseconds 800

Set-ItemProperty -Path $key -Name ProxyServer   -Value "127.0.0.1:$Port"
Set-ItemProperty -Path $key -Name ProxyOverride -Value '<local>'
Set-ItemProperty -Path $key -Name ProxyEnable   -Value 1

Write-Host "抓包代理已开启: 127.0.0.1:$Port" -ForegroundColor Green
Write-Host "日志: $cap\requests.log  响应: responses.log"
Write-Host "注意: 对已经跑起来的进程不一定立刻生效 —— 先关掉实验窗口，重新进入实验室，再正常结束提交，包才会被抓到。" -ForegroundColor Yellow
Write-Host "用完务必执行: .\proxy-off.ps1（会还原成原来的 $($cur.ProxyServer)）" -ForegroundColor Yellow
