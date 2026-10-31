# Invoke-LabPerfect.ps1 —— 通用版：把抓到的实验提交包改成"满分版"重放
#
# 原理：
#   1) 实验客户端正常结束时会 POST /ServiceAPI/UpdateRecord，包里带
#      UserID / LabID / LabName / RecordID / FileName / Content / Key
#   2) Content = 加密的试卷 XML（同一套口令，可解密）
#   3) Key 只签 "UserID,LabID,FileName"，**不含 Content** → 内容随便改，Key 原样复用
#
# 所以完全不需要破解签名，也不需要懂每个实验的格式：
#   抓到一次真实提交 → 解出 XML → RealResult 全填成 StdResult → 重新加密 → 原样重放
#
# 用法：
#   .\Invoke-LabPerfect.ps1                      # 预览最新一条提交（DryRun）
#   .\Invoke-LabPerfect.ps1 -Apply               # 真正重放
#   .\Invoke-LabPerfect.ps1 -Apply -All          # 重放日志里所有提交（多个实验一起刷）
#
param(
    [string]$LogPath,          # 默认 tools\capture\requests.log
    [switch]$Apply,            # 不加 = DryRun
    [switch]$All,              # 处理全部提交，默认只处理最新一条
    [int]$Last = 1,            # 只处理最近 N 条（-All 优先）
    [int]$RealTime = -1,       # >0 则把 RealTime 改成这个固定秒数
    [switch]$RandomTime,       # 随机用时：在 RealTimeMin ~ RealTimeMax 之间随机
    [switch]$WaitRandomTime,   # 按本地抓包开始时间延时提交；不保证改变服务端显示用时
    [int]$RealTimeMin = 1800,  # 随机下限（秒）1800 = 30 分钟
    [int]$RealTimeMax = 3000,  # 随机上限（秒）3000 = 50 分钟
    [switch]$KeepRealTime,     # 保留包里原始用时，不做任何修改
    [string]$OnlyLab = '',     # 只处理某个 LabID（例：-OnlyLab 163 只刷示波器）
    [switch]$Quiet,
    [switch]$Report            # 只看评分结构，不提交
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dec  = Join-Path $here 'LabDecrypt.exe'
if (-not (Test-Path $dec)) { throw "缺 LabDecrypt.exe：$here" }
if (-not $LogPath) { $LogPath = Join-Path $here 'capture\requests.log' }
if (-not (Test-Path $LogPath)) { throw "没有抓包日志：$LogPath（先 .\proxy-on.ps1 再做一次实验）" }

function Log2($m) { if (-not $Quiet) { Write-Host $m } }
function Test-Placeholder([string]$v) {
    # 模板里的"假标准值"：空 / 0 / 0.000 / NaN —— 照抄只会让相对偏差变成 0/0
    $s = "$v".Trim()
    if ($s -eq "") { return $true }
    if ($s -match "^(?i)nan$") { return $true }
    if ($s -match "^-?0(\.0*)?$") { return $true }
    return $false
}

# 随机用时：在 [MinSeconds, MaxSeconds] 内取一个"像真人"的秒数
#   先随机分钟数（30~50 分钟），再随机 0~59 秒，最后夹到区间内
#   避免每次都出现 1800 / 2700 / 3000 这种整数分钟，看起来更自然
function Get-RandomRealTime {
    param(
        [int]$MinSeconds = 1800,
        [int]$MaxSeconds = 3000
    )
    if ($MinSeconds -gt $MaxSeconds) {
        $t = $MinSeconds; $MinSeconds = $MaxSeconds; $MaxSeconds = $t
    }
    if ($MinSeconds -lt 60) { $MinSeconds = 60 }
    if ($MaxSeconds -lt $MinSeconds) { $MaxSeconds = $MinSeconds }

    $lo = [int][Math]::Floor($MinSeconds / 60)
    $hi = [int][Math]::Floor($MaxSeconds / 60)
    if ($hi -lt $lo) { $hi = $lo }
    # 让「分钟 + 0~59 秒」整段都落在上限内，避免结果被夹到 MaxSeconds 这个整数分钟上
    $hiFull = [int][Math]::Floor(($MaxSeconds - 59) / 60)
    if ($hiFull -ge $lo -and $hiFull -lt $hi) { $hi = $hiFull }

    $minutes = Get-Random -Minimum $lo -Maximum ($hi + 1)
    $seconds = Get-Random -Minimum 0 -Maximum 60
    $total = $minutes * 60 + $seconds

    if ($total -gt $MaxSeconds) { $total = $MaxSeconds }
    if ($total -lt $MinSeconds) { $total = $MinSeconds }
    return [int]$total
}

# 抓包日志里每条请求前面的时间戳（本机时间，HttpSpy 写的）
function Get-ChunkTime($chunk) {
    if ($chunk -match '(?m)^#?(\d+)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})') {
        return [datetime]::ParseExact($Matches[2], 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

# 捞出所有「开始实验」记录：客户端进实验时会调 /ServiceAPI/SetLabTimeRecordStart
#   返回 @{ "USERID|LABID" = List[datetime] }
function Get-LabStartMap($chunkList) {
    $map = @{}
    foreach ($c in $chunkList) {
        if ($c -notmatch 'POST http://[^/]+/ServiceAPI/SetLabTimeRecordStart') { continue }
        $t = Get-ChunkTime $c
        if (-not $t) { continue }
        if ($c -match 'USERID=([^&\r\n]+)&LABID=([^&\r\n]+)') {
            $k = "$($Matches[1])|$($Matches[2])"
            if (-not $map.ContainsKey($k)) { $map[$k] = New-Object 'System.Collections.Generic.List[datetime]' }
            $map[$k].Add($t)
        }
    }
    return $map
}

# 找某条提交对应的开始时间：同 USERID|LABID 下、不晚于提交时间的那一条
function Resolve-LabStart($f, $startMap) {
    if (-not $f['__Time']) { return $null }
    $k = "$($f['UserID'])|$($f['LabID'])"
    if (-not $startMap.ContainsKey($k)) { return $null }
    $best = $null
    foreach ($t in $startMap[$k]) {
        if ($t -le $f['__Time'] -and (-not $best -or $t -gt $best)) { $best = $t }
    }
    return $best
}

# Reject stale sessions before integer conversion or XML mutation; never clamp elapsed time.
function Assert-WaitWindow([datetime]$startAt, [datetime]$now, [int]$maxSeconds) {
    $elapsed = ($now - $startAt).TotalSeconds
    if ($elapsed -lt 0 -or $elapsed -gt $maxSeconds) {
        throw "延时模式中止：本地经过时间 $elapsed 秒不在 0..RealTimeMax=$maxSeconds 秒内；未发送本条记录。请检查抓包会话和本机时间。"
    }
}

# ---------- 1. 从日志切出提交 ----------
$raw = Get-Content $LogPath -Raw -Encoding UTF8
$allChunks = [regex]::Split($raw, '(?m)^================ #')
$chunks = $allChunks | Where-Object { $_ -match 'POST http://[^/]+/ServiceAPI/UpdateRecord' }
if (-not $chunks) { throw "日志里没有 /ServiceAPI/UpdateRecord 提交（确认抓包时确实结束过实验）" }

$subs = @()
foreach ($c in $chunks) {
    $cTime = $null
    if ($c -match '(?m)^#?(\d+)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})') {
        $cTime = [datetime]::ParseExact($Matches[2], 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($c -match '(?s)---- body \((\d+) bytes\) ----\r?\n(.*)$') {
        $bodyText = $Matches[2].Trim()
        if ($bodyText -notmatch 'UserID=') { continue }
        $f = @{}
        foreach ($kv in $bodyText.Split('&')) {
            $i = $kv.IndexOf('=')
            if ($i -gt 0) { $f[$kv.Substring(0, $i)] = $kv.Substring($i + 1) }
        }
        if ($f.ContainsKey('Content') -and $f.ContainsKey('Key')) { $f['__Time'] = $cTime; $subs += , $f }
    }
}
if (-not $subs) { throw "没能从日志里解析出提交体" }
# 去重：同一 RecordID + FileName 只保留一条（客户端一次提交会连发 3 遍）
$seen = @{}
$subs = @($subs | Where-Object {
            $k = "$($_['RecordID'])|$($_['FileName'])"
            if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = 1; $true }
        })
if ($OnlyLab) {
    $subs = @($subs | Where-Object { [string]$_['LabID'] -eq $OnlyLab })
    if (-not $subs) { throw "日志里没有 LabID=$OnlyLab 的提交" }
}
if (-not $All) {
    if ($Last -lt 1) { $Last = 1 }
    if ($Last -lt $subs.Count) { $subs = @($subs[($subs.Count - $Last)..($subs.Count - 1)]) }
}
Log2 ("找到 {0} 条提交（本次处理 {1} 条）" -f $chunks.Count, $subs.Count)
$startMap = Get-LabStartMap $allChunks

# 延时模式先校验全部待处理记录，避免缺开始时间时直接发送或批量执行到一半才失败。
if ($WaitRandomTime -and -not $Report) {
    if ($RealTimeMin -lt 60 -or $RealTimeMax -lt $RealTimeMin) {
        throw '延时模式要求 60 <= RealTimeMin <= RealTimeMax；未发送任何记录。'
    }
    $preflightNow = Get-Date
    foreach ($f in $subs) {
        $startAt = Resolve-LabStart $f $startMap
        if (-not $startAt) {
            throw "延时模式中止：LabID=$($f['LabID']) / RecordID=$($f['RecordID']) 缺少不晚于提交时间的开始记录（SetLabTimeRecordStart）或提交时间戳；未发送任何记录。请补全抓包日志。"
        }
        Assert-WaitWindow $startAt $preflightNow $RealTimeMax
        $f['__StartAt'] = $startAt
    }
    Log2 '  延时模式只控制本地重放时刻；服务端是否更新结束时间未经验证，网页用时可能保持不变。'
}

# ---------- 2. 逐条处理 ----------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("lpf_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$okCount = 0
try {
foreach ($f in $subs) {
    $tag = "{0} / LabID={1} / RecordID={2}" -f $f['LabName'], $f['LabID'], $f['RecordID']
    Log2 ("===== {0} =====" -f $tag)

    # 2.1 解出 Content
    $encBytes = [Convert]::FromBase64String($f['Content'])
    $encPath = Join-Path $tmp 'content.bin'
    [IO.File]::WriteAllBytes($encPath, $encBytes)
    $xmlPath = Join-Path $tmp 'content.xml'
    & $dec dec $encPath $xmlPath 2>$null | Out-Null
    $doc = New-Object System.Xml.XmlDocument
    $loaded = $false
    if (Test-Path $xmlPath) {
        try { $doc.Load($xmlPath); $loaded = $true } catch { $loaded = $false }
    }
    if (-not $loaded) {
        # 有些实验的 Content 不是 LitJson 加密，而是明文 XML
        try {
            $doc.LoadXml([Text.Encoding]::UTF8.GetString($encBytes))
            $loaded = $true
            Log2 "  （Content 是明文 XML，已直接解析）"
        } catch { }
    }
    if (-not $loaded) { Write-Warning "Content 解析失败（既不是加密包也不是明文 XML），跳过 $tag"; continue }

    # 2.1b -Report：只打印评分结构，判断上限在哪
    if ($Report) {
        Log2 "  ---- 评分结构（分值 × 行数，'空' = 该参数没有标准值）----"
        $tot = 0
        foreach ($p in $doc.SelectNodes('//Para')) {
            $jr = $p.SelectSingleNode('JudgeRule/Rule/Score')
            if (-not $jr) { continue }
            $perNode = $p.SelectSingleNode('JudgeRule/Rule/Score')
            $per = 0; [void][int]::TryParse([string]$perNode.InnerText, [ref]$per)
            $stdNode2 = $p.SelectSingleNode('StdResult')
            $std2 = if ($stdNode2) { [string]$stdNode2.InnerText } else { '' }
            $nameNode = $p.SelectSingleNode('Name'); $name = if ($nameNode) { [string]$nameNode.InnerText } else { '?' }
            $rows = 1
            if ($std2.Contains(';')) { $rows = @($std2 -split ';').Count - 1 }
            $sum = $per * [Math]::Max($rows, 1)
            $tot += $sum
            $flag = if ($std2.Trim() -eq '') { '空' } else { '有' }
            $rEnd = $p.SelectSingleNode('RealResult')
            $rTxt = if ($rEnd) { [string]$rEnd.InnerText } else { '' }
            $rState = if ($rTxt.Trim() -eq '') { '未填' } else { '已填' }
            Log2 ("    {0,-26} {1,2}分 × {2,2}行 = {3,4}   标准值:{4}  实测:{5}" -f $name, $per, $rows, $sum, $flag, $rState)
        }
        Log2 ("    —— 可判分权重合计: {0}" -f $tot)
        Log2 ""
        continue
    }

    # 2.2 填数据
    $doc.DocumentElement.SetAttribute('__patched', '1') | Out-Null
    $filled = 0; $mirrored = 0; $synth = 0
    foreach ($para in $doc.SelectNodes('//Para')) {
        $stdNode  = $para.SelectSingleNode('StdResult')
        $realNode = $para.SelectSingleNode('RealResult')
        # 有的实验干脆没有这两个节点，缺就补一个，别整个跳过
        if (-not $stdNode)  { $stdNode = $doc.CreateElement('StdResult');   $para.AppendChild($stdNode)  | Out-Null }
        if (-not $realNode) { $realNode = $doc.CreateElement('RealResult'); $para.AppendChild($realNode) | Out-Null }
        $std = [string]$stdNode.InnerText; $real = [string]$realNode.InnerText
        $hasRule = [bool]$para.SelectSingleNode('JudgeRule/Rule')

        # 表格型：(...);(...);(...)
        if ($std.Contains(';') -and $real.Contains(';')) {
            $stdParts = @($std -split ';')
            $realParts = @($real -split ';')
            $hdr = [string]$stdParts[0]
            $stdRows = @()
            if ($stdParts.Count -gt 1) { $stdRows = @($stdParts[1..($stdParts.Count - 1)]) }
            $realBody = @()
            if ($realParts.Count -gt 1) { $realBody = @($realParts[1..($realParts.Count - 1)]) }
            $out = @()
            for ($r = 0; $r -lt $stdRows.Count; $r++) {
                $sc = @(([string]$stdRows[$r]).Trim('(', ')').Split(','))
                $rc = @()
                if ($r -lt $realBody.Count) { $rc = @(([string]$realBody[$r]).Trim('(', ')').Split(',')) }
                # RealResult 行比 StdResult 短时补齐列数，避免索引越界
                while ($rc.Count -lt $sc.Count) { $rc += '' }
                for ($c = 0; $c -lt $sc.Count; $c++) {
                    $sv = [string]$sc[$c]; $rv = [string]$rc[$c]
                    if ($c -eq 0) { continue }                     # 序号列不动
                    if (-not (Test-Placeholder $sv)) { $rc[$c] = $sv; $filled++ }   # 真标准值 → 照抄
                    elseif (-not (Test-Placeholder $rv)) { $sc[$c] = $rv; $mirrored++ }  # 有填写 → 反填
                    else { $rc[$c] = '1'; $sc[$c] = '1'; $synth++ }     # 都空 → 双双造一个
                }
                $out += '(' + ($rc -join ',') + ')'
                $stdRows[$r] = '(' + ($sc -join ',') + ')'
            }
            $realNode.InnerText = $hdr + ';' + ($out -join ';')
            $stdNode.InnerText  = $hdr + ';' + ($stdRows -join ';')
        }
        elseif (-not (Test-Placeholder $std)) { $realNode.InnerText = $std; $filled++ }
        elseif (-not (Test-Placeholder $real)) { $stdNode.InnerText = $real; $mirrored++ }
        elseif ($hasRule) {
            # 单值型且两边都空：这一项本来 0 分，给 Real/Std 同时塞同一个值 → 偏差 0
            $realNode.InnerText = '1'; $stdNode.InnerText = '1'; $synth++
        }
    }
    # 2.2a 按本地日志时间等待；服务端是否接受重放来更新结束时间未经验证。
    $waitRt = $null
    if ($WaitRandomTime) {
        $startAt = $f['__StartAt']
        if ($startAt) {
            Assert-WaitWindow $startAt (Get-Date) $RealTimeMax
            $want = Get-RandomRealTime -MinSeconds $RealTimeMin -MaxSeconds $RealTimeMax
            $targetAt = $startAt.AddSeconds($want)
            Log2 ("  进实验时间 {0}，目标用时 {1} 分 {2:00} 秒 → 计划 {3} 提交" -f $startAt.ToString('HH:mm:ss'), [int][Math]::Floor($want / 60), ($want % 60), $targetAt.ToString('HH:mm:ss'))
            if ($Apply) {
                if ((Get-Date) -gt $targetAt) {
                    Log2 ("  已经过了目标时间（开始到现在 {0} 分钟），直接提交" -f [int][Math]::Floor(((Get-Date) - $startAt).TotalMinutes))
                }
                while ((Get-Date) -lt $targetAt) {
                    $remain = [int][Math]::Floor(($targetAt - (Get-Date)).TotalSeconds)
                    Log2 ("    等待中… 还剩 {0} 分 {1:00} 秒" -f [int][Math]::Floor($remain / 60), ($remain % 60))
                    Start-Sleep -Seconds ([Math]::Min(60, [Math]::Max(1, $remain)))
                }
                $afterWait = Get-Date
                Assert-WaitWindow $startAt $afterWait $RealTimeMax
                $waitRt = [int][Math]::Max(1, [Math]::Floor(($afterWait - $startAt).TotalSeconds))
                Log2 ("  本地提交时刻 {0}，距日志开始时间 {1} 分 {2:00} 秒（不代表服务端用时）" -f (Get-Date).ToString('HH:mm:ss'), [int][Math]::Floor($waitRt / 60), ($waitRt % 60))
            } else {
                $waitRt = $want
                Log2 "  [DryRun] 不加 -Apply 不会真的等；真正提交时会等到上面那个时间点"
            }
        } else {
            throw '延时模式中止：缺少已校验的开始时间，未发送本条记录。'
        }
    }

    # 2.2b 改「用时」：Title/User/Time/RealTime（单位：秒）
    $rtNow = $null
    if ($waitRt) { $rtNow = $waitRt }
    elseif ($RandomTime) { $rtNow = Get-RandomRealTime -MinSeconds $RealTimeMin -MaxSeconds $RealTimeMax }
    elseif ($RealTime -gt 0) { $rtNow = $RealTime }
    if ($rtNow -and -not $KeepRealTime) {
        $timeNode = $doc.SelectSingleNode('//Title/User/Time')
        if (-not $timeNode) {
            # 少数包没有 Time 节点：按 ExamPaper/Title/User 结构补一个
            $userNode = $doc.SelectSingleNode('//Title/User')
            if ($userNode) {
                $timeNode = $doc.CreateElement('Time')
                $userNode.AppendChild($timeNode) | Out-Null
            }
        }
        if ($timeNode) {
            $rtNode = $timeNode.SelectSingleNode('RealTime')
            if (-not $rtNode) { $rtNode = $doc.CreateElement('RealTime'); $timeNode.AppendChild($rtNode) | Out-Null }
            $rtNode.InnerText = "$rtNow"
            $mm = [int][Math]::Floor($rtNow / 60); $ss = [int]($rtNow % 60)
            Log2 ("  用时 RealTime -> {0} 秒（{1}:{2:00}）" -f $rtNow, $mm, $ss)
        } else {
            Write-Warning "  找不到 Title/User/Time 节点，用时未修改（$tag）"
        }
    }
    Log2 ("  填入 {0} 格 / 反填 {1} 格 / 补造 {2} 格" -f $filled, $mirrored, $synth)

    $newXml = Join-Path $tmp 'perfect.xml'
    $doc.Save($newXml)
    $newBin = Join-Path $tmp 'perfect.bin'
    & $dec enc $newXml $newBin | Out-Null

    # 2.3 组包（Key 原样复用）
    $content2 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($newBin))
    $body = "UserID=$($f['UserID'])&LabID=$($f['LabID'])&LabName=$($f['LabName'])" +
            "&RecordID=$($f['RecordID'])&FileName=$($f['FileName'])&Content=$content2&Key=$($f['Key'])"

    if (-not $Apply) {
        Log2 ("  [DryRun] 报文 {0} 字节，未发送" -f $body.Length)
        continue
    }
    # Encoding and earlier batch items can consume time after preflight/waiting.
    if ($WaitRandomTime) { Assert-WaitWindow $f['__StartAt'] (Get-Date) $RealTimeMax }

    $server = "http://192.168.2.221:8001"
    if ($f.ContainsKey('ServerIP') -and $f['ServerIP']) { $server = $f['ServerIP'] }
    # 兼容 PowerShell 5.1 / 7：5.1 没有 -SkipHttpErrorCheck，用 try/catch 取响应体
    $savedProxy = [System.Net.WebRequest]::DefaultWebProxy
    try {
        [System.Net.WebRequest]::DefaultWebProxy = $null   # 直连，别把重放也塞进抓包日志
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $r = Invoke-WebRequest "$server/ServiceAPI/UpdateRecord" -Method POST `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/x-www-form-urlencoded' `
                    -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
            $code = [string]$r.Content; $status = [int]$r.StatusCode
        } else {
            $r = Invoke-WebRequest "$server/ServiceAPI/UpdateRecord" -Method POST `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/x-www-form-urlencoded' `
                    -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
            $code = [string]$r.Content; $status = [int]$r.StatusCode
        }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            $code = $sr.ReadToEnd(); $sr.Close()
            $status = [int]$resp.StatusCode
        } else { throw }
    } finally {
        [System.Net.WebRequest]::DefaultWebProxy = $savedProxy
    }
    $meaning = switch ($code.Trim()) {
        '1'  { '成功' }
        '-3' { 'RecordID 不匹配（这条记录可能已被服务端清理）' }
        '-4' { 'Key/FileName/UserID 不匹配（抓包与重放之间请勿改动这些字段）' }
        default { '未知返回码' }
    }
    Log2 ("  重放 -> HTTP {0}  响应={1}（{2}）" -f $status, $code, $meaning)
    if ($code.Trim() -eq '1') { $okCount++ }
}
} finally {
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Log2 ""
if ($Apply) { Log2 ("完成：{0}/{1} 条成功" -f $okCount, $subs.Count) }
else { Log2 "以上为预览。加 -Apply 才会真正提交。" }
