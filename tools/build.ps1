# build.ps1 —— 用系统自带的 .NET Framework 编译器重新构建两个工具
# 需要：Windows 10/11 自带的 csc.exe（无需安装 SDK）
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$csc = $null
foreach ($v in 'v4.0.30319', 'v3.5', 'v2.0.50727') {
    $p = Join-Path $env:WINDIR "Microsoft.NET\Framework64\$v\csc.exe"
    if (Test-Path $p) { $csc = $p; break }
}
if (-not $csc) { throw "找不到 csc.exe（需要 .NET Framework）" }

Write-Host "使用编译器: $csc"

Write-Host "[1/2] HttpSpy.exe"
& $csc /nologo /optimize+ /target:exe /out:"$here\HttpSpy.exe" "$here\HttpSpy.cs"
if ($LASTEXITCODE -ne 0) { throw "HttpSpy 编译失败" }

Write-Host "[2/2] LabDecrypt.exe"
$dll = Join-Path $here 'USTCORi.SimExp.Instruments.Component.dll'
if (Test-Path $dll) {
    & $csc /nologo /optimize+ /target:exe /out:"$here\LabDecrypt.exe" /r:"$dll" "$here\LabDecrypt.cs"
} else {
    # 没带 dll 也能编译（运行时再找）
    & $csc /nologo /optimize+ /target:exe /out:"$here\LabDecrypt.exe" "$here\LabDecrypt.cs"
}
if ($LASTEXITCODE -ne 0) { throw "LabDecrypt 编译失败" }

Write-Host "完成。" -ForegroundColor Green
