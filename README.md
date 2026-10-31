# WebLab 仿真实验提交包分析工具

本项目原创代码和文档采用 [MIT License](LICENSE)。附带的第三方组件
`tools/USTCORi.SimExp.Instruments.Component.dll` 不在本项目 MIT 授权范围内，
其权利归原权利人所有。

针对 **科大奥锐 WebLab / USTCORi.SimExp** 虚拟仿真实验平台的提交协议分析工具集。
通过本地抓包还原客户端的提交包，把实验数据表填成标准答案后原样重放。

> 用于协议分析、安全研究与教学演示。使用者需自行确认使用场景是否合规，风险自负。

---

## 一、使用场景

### ✅ 适用

| 场景 | 说明 |
|---|---|
| **平台** | 科大奥锐 WebLab / USTCORi.SimExp 系列（高校大学物理虚拟仿真实验常见的那套） |
| **客户端形态** | WPF 版实验室（`USTCORi.SimExp.*.exe` + `SimExpConfig\ExamConfig.bin`）实测通过 |
| **提交方式** | 客户端通过 `POST {ServerIP}/ServiceAPI/UpdateRecord` 上报加密 XML 的部署 |
| **网络** | 明文 HTTP（`http://ip:port`），同网段可达 |
| **典型用途** | ① 批量核对各实验的判分项与权重；② 复现"提交包可篡改"这一设计缺陷；③ 实验课快速完成数值类判分项 |

### ❌ 不适用

| 场景 | 原因 |
|---|---|
| 非 USTCORi 系平台 | 协议完全不同 |
| HTTPS 且证书固定（HSTS） | 需要给代理装证书，工具本身不做 TLS 解密 |
| 提交包经过二次签名/服务端二次校验的版本 | `Key` 若覆盖了 `Content` 摘要就改不动 |
| 需要教师端人工审核定分的实验 | 工具只影响自动判分那部分 |

---

## 二、能力边界（务必先看）

平台把判分项分成两类，**本工具只对第一类有效**：

| 判分项类型 | 例子 | 能否用本工具拿分 | 原因 |
|---|---|---|---|
| **数值类** | 周期 5ms、倔强系数 0.944、单缝宽度 0.1219、砝码读数表 | ✅ 可以 | 数据在 XML 里，可解可改 |
| **状态/操作类** | "连接成功"、"已经退磁"、光强 1–2mW 区间、CH1=50mV 档、"点击确认" | ❌ 不行 | XML 里存的是**状态码**（double），含义由客户端私有映射决定，改文件填不出正确码 |
| **无 JudgeRule 的实验** | 透镜成像（TotalScore 全 0） | ⚠️ 部分 | 判分规则不在 XML 里，只能按"表格是否填满 + 平均值是否匹配"试 |

实测结论：

- 示波器、电桥、声速、驻波、刚体转动惯量、杨氏模量、长度密度、霍尔效应、单摆、液体表面张力 → 可做到 90~100；
- 单缝衍射、动态磁滞回线 → 卡在状态/操作类判分项（有 45 分左右拿不到），必须真的在软件里把连线、退磁、档位、光强调对；
- 实验报告类成绩（占总成绩 60%）→ 完全不在本工具范围内。

---

## 三、硬性前提

1. **必须先抓一次真实提交**。
   签名 `Key` 覆盖 `UserID + "," + LabID + FileName`，而 `FileName` 含**秒级时间戳**（`UserID+yyyyMMddHHmmss.xml`），无法离线构造。
   → 每个实验都必须"进一次 → 点结束实验"让它提交，才有可复用的 `Key`。

2. **不能杀进程**。必须点界面上的「结束实验」正常退出，否则客户端不上报。

3. **系统代理会被临时修改**。`proxy-on` 会把当前用户的 WinINET 代理指向 `127.0.0.1:8888`，`proxy-off` 还原（自动备份到 `proxy-state.json`）。异常退出后请手动执行一次 `proxy-off`，否则断网。

4. **仅 Windows**：需要 PowerShell 5.1+ 与 .NET Framework 4.x（Win10/11 自带）。

---

## 四、快速开始

```powershell
# 1. 开始抓包（只需一次）
.\1-开始抓包.bat

# 2. 进实验 → 点「结束实验」→ 等提示提交成功
#    每个实验都重复这一步

# 3. 刷分
.\2-一键刷分.bat
#    或命令行：.\tools\Invoke-LabPerfect.ps1 -Apply

# 4. 全部做完后还原代理
.\3-停止抓包.bat
```

批量：

```powershell
cd tools
.\Invoke-LabPerfect.ps1 -Apply -All         # 处理日志里所有实验（自动去重）
.\Invoke-LabPerfect.ps1 -Report -Last 5     # 只看评分结构，判断上限
.\Invoke-LabPerfect.ps1 -Apply -WaitRandomTime    # 按本地日志开始时间延时重放，不保证改变网页用时
.\Invoke-LabPerfect.ps1 -Apply -RandomTime      # 只改 XML 里的 RealTime，不保证影响网页用时
.\Invoke-LabPerfect.ps1 -Apply -RandomTime -RealTimeMin 1500 -RealTimeMax 2400   # 自定义 25~40 分钟
.\Invoke-LabPerfect.ps1 -Apply -RealTime 1800   # 固定 30 分钟
.\Invoke-LabPerfect.ps1 -Apply -KeepRealTime    # 保留包里的原始用时（默认行为）
.\Invoke-LabPerfect.ps1 -Apply -WaitRandomTime -KeepRealTime   # 延时重放，但保留 XML 原用时
```

`-WaitRandomTime` 仅控制本地重放时刻，默认目标为日志开始时间后 30~50 分钟；
目标已过但本地经过时间仍未超过 `RealTimeMax` 时直接重放；超过上限或开始时间晚于本机时间时中止。
**未验证服务端是否会因重放更新结束时间，不保证网页显示 30~50 分钟。**
如果服务端只保留首次提交时间，延时重放不会改变网页用时。延时模式会先检查所有选中记录，
缺少提交时间戳或对应开始记录时整批报错中止，不发送任何记录；`-Report` 仅查看评分结构，不做延时检查。
`-KeepRealTime` 优先于所有 XML 用时修改选项，包括延时模式，但不取消等待。
一键入口 `2-一键刷分.bat` 只传 `-Apply`，默认保留 XML 原用时；随机用时需显式选择 `-RandomTime`。
延时模式要求 `60 <= RealTimeMin <= RealTimeMax`。过期检查会在批量处理前、每条等待前后及发送前执行，
适用于 Apply、DryRun 和 KeepRealTime 组合；`-Report` 除外。初始有过期记录时整批不发送；
若等待、系统休眠或前一条请求耗时导致后续记录过期，则中止剩余处理，已发送记录无法撤回。
超时会报错，不会将实际用时截断为上限后发送。

---

## 五、工作原理

```
实验客户端 ──结束实验──▶ POST /ServiceAPI/UpdateRecord
                        UserID / LabID / LabName / RecordID / FileName / Content / Key
                                                                    │
                                                    Content = 加密 XML（固定口令）
                                                                    │
                        ┌───────────────────────────────────────────┘
                        ▼
        解密 → 把 RealResult 填成 StdResult → 重新加密 → 原样重放
                        │
                        ▼
        服务端校验（实测返回码）：
            1  = 成功
           -3  = RecordID 不存在
           -4  = Key / FileName / UserID 任一不匹配
```

关键点：**`Key` 只签 `UserID,LabID,FileName`，不包含 `Content`** —— 所以内容可以随便改，签名原样复用。这是整套方案成立的前提，也是这个平台的设计缺陷。

---

## 六、限制清单（GitHub 读者请看这里）

| # | 限制 | 影响 |
|---|---|---|
| 1 | 每个实验必须真实提交一次才能拿到 `Key` | 无法"完全离线生成" |
| 2 | 只能改数值类判分项 | 状态/操作类必须真做 |
| 3 | 依赖固定加密口令与 `Component.dll` | 平台一旦换口令或换组件即失效 |
| 4 | 只验证过明文 HTTP 部署 | HTTPS + 证书固定需额外处理 |
| 5 | `Real=Std` 依赖服务端使用记录内的 `StdResult` 判分 | 若某实验使用独立标准值则不生效 |
| 6 | 占位标准值（`NaN`/`0.000`）的判分项可能永远 0 分 | 这是平台自身的数据问题，非工具可解 |
| 7 | 需杀毒软件对 `HttpSpy.exe` 加信任 | 本地代理易被误报 |
| 8 | 只管实验成绩，不管实验报告 | 总成绩仍受报告分影响 |
| 9 | 脚本会临时改系统代理 | 异常退出记得手动还原 |
| 10 | 不同学校/版本部署的接口可能不同 | 本工具按实测的一套实现，未做兼容层 |

---

## 七、目录结构

```
lab-toolkit/
├─ 1-开始抓包.bat              启动代理 + 抓包
├─ 2-一键刷分.bat              处理最近一次提交
├─ 3-停止抓包.bat              停止抓包 + 还原代理
├─ 使用说明.md                 详细中文手册
├─ README.md                   本文件
├─ docs\
│  └─ 协议分析.md              提交协议/加密/签名/判分模型的技术笔记
└─ tools/
   ├─ proxy-on.ps1             备份代理 / 启动 HttpSpy / 切换代理
   ├─ proxy-off.ps1            停 HttpSpy / 还原代理
   ├─ Invoke-LabPerfect.ps1    核心：解包 → 填答案 → 重放（-Report / -All / -Last / -RealTime）
   ├─ HttpSpy.exe / .cs        本地抓包代理（HTTP 全量记录，HTTPS CONNECT 隧道）
   ├─ LabDecrypt.exe / .cs     实验数据包加解密（找不到 dll 时自动去 %TEMP%\lab\ 找）
   ├─ build.ps1                用系统 csc.exe 重新编译（无需 SDK）
   └─ USTCORi.SimExp.Instruments.Component.dll
```

---

## 八、返回码 / 常见问题

| 现象 | 含义 | 处理 |
|---|---|---|
| 响应 `1` | 成功 | 刷新网页看成绩 |
| 响应 `-3` | `RecordID` 不存在或已被清理 | 重进一次该实验再刷 |
| 响应 `-4` | `Key`/`FileName`/`UserID` 不匹配 | 说明这次抓包对不上，重抓 |
| `找不到参数 SkipHttpErrorCheck` | 用了旧版脚本 | 更新到本仓库版本（已兼容 PS 5.1） |
| `禁止运行脚本` | 执行策略限制 | 用 `.bat` 入口，已带 `-ExecutionPolicy Bypass` |
| 抓不到包 | 实验进程在改代理前已联网 | 先开抓包，再启动实验 |

---

## 九、致谢与声明

- 加解密组件 `USTCORi.SimExp.Instruments.Component.dll` 取自实验客户端，仅用于解析其自身格式。
- 本项目仅做协议分析与可复现性研究，不对任何使用后果负责。

---

## 十、自行构建

只依赖 Windows 自带的 .NET Framework 编译器，无需 SDK：

`````````````````
cd tools
powershell -ExecutionPolicy Bypass -File .\build.ps1
`````````````````

Component.dll 是可选依赖：仓库里带了就从同目录加载，没带则自动去
%TEMP%\lab\<编号>\ 找（启动过一次实验后就有）。如果你不想在仓库里放第三方二进制，
直接删掉这个 dll 即可，工具会提示你从客户端复制。

## 十一、离线回归测试

在仓库根目录运行 `powershell -NoProfile -File tests/Test-DelayedSubmission.ps1`，
也可使用 `pwsh`。测试使用合成日志、模拟时钟、模拟 HTTP 请求和临时编译的编解码桩，
不连接实验平台；覆盖开始时间匹配、缺失记录时整批中止、保留 XML 用时和 DryRun 行为。
这些测试不验证服务端是否更新结束时间或网页显示。
