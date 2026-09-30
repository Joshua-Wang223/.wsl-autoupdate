# .wsl-autoupdate

用 Windows 计划任务驱动 WSL 引擎与 Ubuntu 软件包的自动更新，绕过这台机器上两条**都不可用**的原生更新通道。

---

## 背景：为什么需要它

WSL 有两条互不相干的更新链，各自都有坑。本项目是在实测确认两者都失效后才写的。

| 更新对象 | 原生方式 | 实际情况 |
|---|---|---|
| **WSL 引擎**（含内核） | `wsl --update` / 微软商店 | **完全不可用** —— 实测挂起 17 分钟，CPU 仅 2.8 秒，零输出，无下载文件产生，版本不变 |
| **Ubuntu 内的包** | distro 内 `unattended-upgrades` | **形同失效** —— systemd 定时器只在 distro 存活时触发，而 WSL 的 distro 只在被访问时运行。实测 4 个月未触发，积压 173 个待升级包 |

此外，即使改走 `wsl --update --web-download`，GitHub 直连也存在两个问题：速度仅 68–90 kB/s，且 MSI 下载到约 52 MB 时会 socket 死锁，而 WSL 自带下载器**没有超时机制**，会永久挂起而不是报错重试。

本项目的做法：用 Windows 计划任务定时唤醒 distro 补上 apt，并改用 `curl -C -` 断点续传从 GitHub 取引擎 MSI。

---

## 工作原理

```
Windows 计划任务 "WSL Auto Update"（每日 03:30，仅用户登录时运行）
        │
        ├─ 阶段 0  记录 distro 初始状态（决定后续是否会打断用户）
        │
        ├─ 阶段 A  wsl.exe ──► Ubuntu ──► apt-get update + upgrade
        │             └─ apt 脚本每次由 Windows 侧 cp 覆盖同步到 distro
        │
        ├─ 阶段 B  GitHub API 查最新引擎版本
        │             └─ 有新版本
        │                  ├─ distro 原本 Stopped → 直接升级（不打断任何人）
        │                  └─ distro 原本 Running → 弹窗征求同意
        │                        ├─ 点击「立即升级」→ 升级
        │                        ├─ 点击「跳过本次」→ 跳过
        │                        └─ 5 分钟无响应   → 复查此刻 distro 是否仍在运行
        │                              ├─ 仍在 Running → 跳过（不关闭 WSL）
        │                              └─ 已 Stopped   → 自动继续升级
        │                  ↓
        │             curl 断点续传 → 校验微软签名 → wsl --shutdown → msiexec 静默安装
        │
        └─ 收尾     downloads\ 内引擎 MSI 与安装日志各保留最新 2 个
```

**关键设计一：只在会打断用户时才弹窗。** 日常 03:30 时 distro 通常已自动休眠（`Stopped`），因此绝大多数运行都是静默完成的，不会半夜弹窗。

**关键设计二：超时不凭 5 分钟前的状态拍板，而是看「此刻」还有没有实例在跑。**

| 弹窗结果 | 行为 |
|---|---|
| 点击「立即升级」 | 升级 |
| 点击「跳过本次」/ 关窗 | 跳过 |
| 5 分钟无响应 | **复查此刻 distro 状态**：仍在 `Running` → 跳过；已 `Stopped` → 自动继续 |
| 弹窗不可用 / 抛异常 | 跳过（无法确认有人在场） |

> ⚠️ 这条规则来自一次真实事故。早先的版本是"超时 5 分钟自动同意"，其隐含假设是「distro 处于 `Running` 就说明人在电脑前」。但**长时批处理任务同样会让 distro 保持 `Running`**，该假设不成立：2026-09-30 03:36，弹窗在无人值守下超时，于是自动执行了 `wsl --shutdown`，把 WSL 里正在跑的长任务中断，distro 直到 07:49 才重启。
>
> 现在改为超时后复查：如果这 5 分钟里用户已结束所有会话、distro 自动歇下（WSL 在无会话时会自行终止），那么关闭它影响不到任何人，升级可以继续；**只要还有实例在跑就跳过**。两侧代价不对称 —— 误关闭一次就是真实的工作损失，而错过一次升级最多晚一天。

> **关机前还有最后一道闸（`Test-DistroIdle`）**：上面那些判定都发生在*下载之前*，而下载可能耗时数分钟，等真正执行 `wsl --shutdown` 时结论已经过期。所以关机前会再复查一次「此刻有没有实例在跑」。
>
> 这里有个坑：看到 `Running` 未必是用户在跑 —— 本任务自己的 apt 步骤刚唤醒过 distro，而 WSL 在最后一个客户端断开后要过一会儿才终止 VM。所以复查发现 `Running` 时会**静候 `$SettleSeconds`（默认 90 秒）再复查一次**：转为 `Stopped` 说明刚才是我方残留、可以关机；仍然 `Running` 则判定为用户在用、放弃安装（MSI 会保留，下次运行发现它已完整便跳过下载）。方向偏保守：宁可多等，也不误关。
>
> 真人明确点击「立即升级」的那条路径**免于这道闸** —— 他已在知情前提下同意关闭 WSL，且从点击到关机只隔着几行代码，没有可供漂移的窗口。（也因此：若点击后在下载期间又往 WSL 里起任务，仍会被关掉。这是点击者自己制造的矛盾，弹窗文案已明示会中断其中任务。）
>
> 一个可预期的副作用：**只要你的 WSL 长期保持忙碌，引擎就会一直停在旧版本**（每次都判定为「有人在用」而跳过）。需要更新时手动跑一次即可。

---

## 文件说明

| 文件 | 作用 | 纳入版本控制 |
|---|---|:---:|
| `Invoke-WslAutoUpdate.ps1` | 主编排脚本。计划任务真正调用的就是它，阶段 0/A/B/收尾都在这里 | ✅ |
| `wsl-autoupdate-apt.sh` | 在 Ubuntu 内执行 apt 的脚本。每次运行由主线用 `cp` 覆盖同步到 distro 的 `/usr/local/sbin/`，因此**改 Windows 侧这份就会自动生效** | ✅ |
| `Register-WslAutoUpdateTask.ps1` | 注册 / 卸载 / 改时间。整套配置可复现，重装系统后一条命令恢复 | ✅ |
| `Sync-WslAutoUpdateBackup.ps1` | 把项目同步到备份目录，**含 `.git` 完整历史**，使备份成为可用于恢复的完整副本 | ✅ |
| `settings.example.psd1` | 部署设置模板。复制为 `settings.psd1` 后填写自己的值 | ✅ |
| `settings.psd1` | 本机部署设置（备份目录）。已 gitignore，不进仓库 | ❌ |
| `.gitignore` | 挡掉 `downloads/`、`*.msi`、运行日志、`settings.psd1`、`_*.ps1` | ✅ |
| `wsl-autoupdate.log` | 运行日志，超 2 MB 轮转为 `.log.1` | ❌ |
| `downloads\` | 引擎 MSI（约 247 MB/个）与 msiexec 安装日志 | ❌ |

distro 内另有部署副本：`/usr/local/sbin/wsl-autoupdate-apt.sh`

**关于路径**：所有路径都由脚本自身位置推导（见下方「路径推导」），因此**整个目录可以原样复制到任何位置或盘符，无需改代码**。唯一无法推导的是备份目录，它放在 `settings.psd1` 里。

---

## 快速开始

### 前提

- Windows 11（在 26200 上验证过），已启用 WSL 与 VirtualMachinePlatform
- 已安装至少一个 WSL 发行版
- 以**管理员**身份执行注册

### 部署

```powershell
# 1. 克隆到任意目录 —— 路径会自动推导，放哪都行
git clone https://github.com/Joshua-Wang223/.wsl-autoupdate.git "$env:USERPROFILE\.wsl-autoupdate"

# 2. 指定备份目录（可选。不建此文件则回退到 $env:USERPROFILE\.wsl-autoupdate-backup）
cd "$env:USERPROFILE\.wsl-autoupdate"
Copy-Item settings.example.psd1 settings.psd1
notepad settings.psd1

# 3. 注册计划任务（需管理员）
.\Register-WslAutoUpdateTask.ps1
```

---

## 日常使用

### 手动触发完整升级

```powershell
cd "$env:USERPROFILE\.wsl-autoupdate"   # 换成你实际克隆到的目录
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Invoke-WslAutoUpdate.ps1
```

脚本把过程写进日志而非屏幕，跑完请看日志。

> `-STA` 不能省略 —— 同意弹窗基于 WinForms，需要 STA 线程。
> 若此时你开着 WSL 终端，会看到同意弹窗。
> 路径都从脚本位置推导，所以只要 `-File` 指向的那份脚本对了，其余全对。

### 通过计划任务触发

更接近真实场景，且能顺带验证任务接线是否正常：

```powershell
Start-ScheduledTask -TaskName 'WSL Auto Update'

Get-ScheduledTaskInfo -TaskName 'WSL Auto Update' |
  Select-Object LastRunTime, LastTaskResult, NextRunTime
```

### 只升级 Ubuntu 包（最轻量，不碰引擎）

```bash
wsl -d Ubuntu -u root -- /usr/local/sbin/wsl-autoupdate-apt.sh
```

### 只升级 WSL 引擎

主线脚本没有「跳过 apt」的开关，但引擎升级本身是幂等的 —— 已是最新就什么都不做，所以直接跑「手动触发完整升级」即可，代价是顺带做一次 apt。

手工等价步骤：

```bash
# 1. 查最新版本与 x64 资产地址
curl -s https://api.github.com/repos/microsoft/WSL/releases/latest \
  | grep -E '"tag_name"|browser_download_url' | grep x64

# 2. 断点续传下载（GitHub 直连慢且会死锁，务必带续传与超时参数）
curl -L -C - --speed-limit 2048 --speed-time 25 -o wsl.msi <上一步拿到的 URL>
```

```powershell
# 3. 校验签名 —— 必做，不要跳过
(Get-AuthenticodeSignature .\wsl.msi).Status          # 应为 Valid
(Get-AuthenticodeSignature .\wsl.msi).SignerCertificate.Subject   # 应为 CN=Microsoft Corporation
```

### 手动备份

```powershell
cd "$env:USERPROFILE\.wsl-autoupdate"   # 换成你实际克隆到的目录
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-WslAutoUpdateBackup.ps1
```

| 参数 | 说明 |
|---|---|
| 无 | 非破坏性，只覆盖 / 新增；备份目录取 `settings.psd1` 的 `BackupDir` |
| `-Mirror` | 额外删除备份目录里多出来的文件 |
| `-Source` | 覆盖源目录（默认即脚本所在目录） |
| `-Dest` | 覆盖备份目录（优先级最高） |

用 SHA256 比对决定是否覆盖，输出会明确区分「已同步」与「未变化」，因此重复执行是安全的。

**备份是「带完整历史的仓库」**，不是单纯的脚本副本：

| 内容 | 是否进备份 |
|---|:---:|
| 项目工作树（脚本、README、`.gitignore`） | ✅ |
| **`.git`（完整提交历史）** | ✅ |
| `settings.psd1`（本机部署设置，不在版本控制内） | ✅ |
| `downloads\`（引擎 MSI，单个 250–370 MB） | ❌ |
| 运行日志（含主机名与本机路径） | ❌ |

所以备份目录里可以直接 `git log` 看改动、`git checkout` 回退版本，是**可用于恢复的完整副本**。同步结束时脚本会核对两边的 HEAD 是否一致，并打印备份侧能读到的最新提交 —— 这一步会当场暴露「`.git` 没同步过去」之类的问题（实测就抓到过一次）。

> ⚠️ 备份是**镜像**，不是工作副本。别在备份目录里改代码再指望同步回源；要改请改源目录，然后跑本脚本。
>
> 另：同步期间不要在源仓库里跑 git 写操作。拷贝 `.git` 时会话到一半的索引 / 引用可能不完整；同步结束的 HEAD 校验能发现，但最好避免。


### 注册 / 卸载 / 改时间

```powershell
.\Register-WslAutoUpdateTask.ps1                  # 注册或重新注册
.\Register-WslAutoUpdateTask.ps1 -Remove          # 卸载
.\Register-WslAutoUpdateTask.ps1 -RunAt '05:00'   # 改为每天 05:00
```

### 回滚引擎

```powershell
winget install Microsoft.WSL --version 2.7.14.0
# 或用 downloads\ 中保留的上一个版本 MSI 重新安装
```

---

## 路径推导

脚本里**不含任何硬编码绝对路径**。`Invoke-WslAutoUpdate.ps1` 以自身所在目录（`$PSScriptRoot`）为项目根目录，推导出全部路径：

| 路径 | 推导方式 |
|---|---|
| 项目根目录 | `$PSScriptRoot` |
| apt 脚本（本机视角） | `<根目录>\wsl-autoupdate-apt.sh` |
| apt 脚本（distro 视角） | 由上一项转换：`<盘符>:\...` → `/mnt/<小写盘符>/...` |
| 运行日志 | `<根目录>\wsl-autoupdate.log` |
| `downloads\` | `<根目录>\downloads` |

因此把整个目录复制到别的路径甚至别的盘符后，**不需要改任何代码**即可运行。已实测：整体复制到 `D:\Temp\...` 后正常运行，apt 脚本通过 `/mnt/d/...` 成功 `cp` 进 distro，全程退出码 0。

转换函数 `ConvertTo-WslPath` 遇到非 `<盘符>:\...` 形式的路径会**直接抛错**，而不是静默返回一个错误路径 —— 这类静默错误最难排查。每次运行也会把解析结果写进日志头两行，出问题时一眼可查：

```
[INFO ] 项目目录: D:\Temp\wsl-au-portability-test
[INFO ] apt 脚本: D:\Temp\...\wsl-autoupdate-apt.sh  ==> distro: /mnt/d/Temp/.../wsl-autoupdate-apt.sh
```

**唯一无法推导的是备份目录**，它属于部署决策，放在 `settings.psd1`：

| 优先级 | 取值来源 |
|:--:|---|
| 1 | 命令行 `-Dest` 参数 |
| 2 | `settings.psd1` 的 `BackupDir` |
| 3 | 回退到 `$env:USERPROFILE\.wsl-autoupdate-backup` |

`settings.psd1` 由 `Import-PowerShellDataFile` 读取（只解析数据、不执行代码）。同步脚本会打印实际取值来源，便于确认。

---

## 配置项

都在 `Invoke-WslAutoUpdate.ps1` 顶部配置区，改完无需改动其他代码：

| 变量 | 默认 | 含义 |
|---|---|---|
| `$Distro` | `Ubuntu` | 目标发行版名 |
| `$ConsentSeconds` | `300` | 弹窗无响应多少秒后复查状态并决定（仍在运行则跳过） |
| `$SettleSeconds` | `90` | 关机前复查发现 distro 仍在运行时的静候秒数，用于区分「我方活动残留」与「用户在用」 |
| `$MaxDownloadAttempts` | `80` | 断点续传最多重试次数 |
| `$KeepEngineMsi` | `2` | `downloads\` 内保留的 MSI 个数 |
| `$KeepInstallLog` | `2` | `downloads\` 内保留的安装日志个数 |

路径相关的项不在上表中 —— 它们全部由脚本位置推导，无需也不应手工配置。

---

## 退出码

最后一个阶段决定退出码，便于定位失败环节：

| 码 | 含义 |
|:--:|---|
| `0` | 成功 |
| `2` | 无法识别 `$Distro` |
| `3` | apt 脚本部署失败，或未通过 `bash -n` 语法门禁 |
| `4` | apt 阶段非零退出 |
| `5` | 引擎 MSI 下载未完成 |
| `6` | **签名校验失败**（已自动删除可疑文件并拒绝安装） |
| `7` | msiexec 安装失败 |
| `8` | 引擎检查阶段异常（如 GitHub 不可达） |

`5`/`6`/`7`/`8` 都会在日志中写明原因。

---

## 日志与排查

```bash
tail -40 "$USERPROFILE/.wsl-autoupdate/wsl-autoupdate.log"
```

每次运行由 `====` 分隔线以及「任务开始」/「任务结束」包起来，按时间定位即可。

> PowerShell 控制台直接 `Get-Content` 时中文可能因代码页显示乱码。请用支持 UTF-8 的方式查看：编辑器、Git Bash 的 `tail`，或 `Get-Content -Encoding UTF8`。

排查时优先看这三行：

```
[INFO ] distro 'Ubuntu' 初始状态: Stopped      ← 决定本次是否会弹窗
[INFO ] ### apt-get upgrade 退出码: 0          ← apt 是否成功
[INFO ] 引擎 MSI 现存 N 个（上限 2）: ...       ← 收尾清理情况
```

---

## 保留策略

`downloads\` 内的历史产物按类型限量保留，每次运行结束时清理：

| 类型 | 匹配 | 保留开关 | 默认 |
|---|---|---|---|
| 引擎 MSI | `^wsl\..*\.x64\.msi$` | `$KeepEngineMsi` | 2 |
| 安装日志 | `^install-.*\.log$` | `$KeepInstallLog` | 2 |

即「最新一次 + 上一次」，MSI 的上一次即回滚副本。

实现上有几个刻意的选择：

- **按数字版本号排序**，不能按字符串 —— 否则 `2.7.10` 会被误判为小于 `2.7.9`，保留错文件。
- **版本号正则只捕获开头数字、不锚定行尾**。日志名由 release tag 生成、MSI 名由 asset 名生成，两者格式都不受本地控制；一旦 tag 带后缀（如 `2.11.0-rc1`），严格正则匹配失败会被当作 `0.0.0.0` 参与排序，**反而把最新的一份优先删除**，与保留意图完全相反。
- **用显式正则而非 `Get-ChildItem -Filter`**。后者走文件系统通配符语义，文件名含多个点号时可能因 8.3 短名匹配出意外结果。
- 只删匹配上述模式的文件，绝不误删其他内容；重复执行幂等。
- 清理放在流程最后，避免升级过程中删掉正在使用的回滚副本。

---

## 设计要点与已知坑

写这个项目时踩到的坑，都已固化在代码里，这里记录以便理解设计决策。

### 1. 微软商店更新通道不可用

`wsl --update` 会永久挂起。因此本项目完全不使用它，改为直接取官方 MSI。

注意 winget 报告的可用版本也可能滞后于 GitHub（曾报 2.7.13，实际 GitHub 已发布 2.7.14）—— **以 GitHub 为准**。

### 2. WSL 自带下载器没有超时机制

`wsl --update --web-download` 在 GitHub 中途死锁后会永久挂起，而不是报错重试。因此改用 `curl -L -C -` 配合重试循环，并加 `--speed-limit 2048 --speed-time 25`，让低速连接尽早断开重连。

### 3. 签名校验不可省略

下载完成后必须用 `Get-AuthenticodeSignature` 校验，要求 `Status = Valid` 且签署者为 `CN=Microsoft Corporation`、证书链到 Microsoft Root CA。校验失败会自动删除文件并拒绝安装（退出码 `6`）。

### 4. PowerShell 5.1 读无 BOM 的 UTF-8 `.ps1` 会按 GBK 解析

含中文的脚本会直接语法报错或中文乱码。**本项目的 `.ps1` 必须保留 UTF-8 BOM**（前 3 字节 `EF BB BF`）。

反过来，**`wsl-autoupdate-apt.sh` 必须 LF 行尾且不能有 BOM**，否则 `#!/bin/bash` shebang 失效。

`.gitignore` 与提交前检查都应保证这一点；`core.autocrlf=false` 时 git 不会自作主张转换行尾。

### 5. 不要用 `bash -lc "..."` 从 PowerShell 传带引号的命令

PowerShell 5.1 向原生程序传参时会把内层 `"` 转义为 `\"`，bash 于是看到未加引号的 `\r`，反斜杠被 shell 吃掉。曾因此把 `export`/`upgrade`/`grep`/`true` 破坏成 `expot`/`upgade`/`gep`/`tue`（**所有字母 `r` 被删除**），脚本能跑、退出码是 0，但实际什么都没干。

正确做法是**直接传参、不套 shell**：

```powershell
wsl -d Ubuntu -u root -- cp -f <src> <dst>
wsl -d Ubuntu -u root -- chmod 755 <path>
wsl -d Ubuntu -u root -- bash -n <path>      # 语法门禁
```

同步部署 apt 脚本时还加了 `bash -n` 语法门禁 —— 语法不通过就拒绝执行，避免被损坏的脚本静默跑挂。

### 6. Windows 侧脚本必须处理 stderr 被包装的问题

`& cmd 2>&1` 在 PowerShell 5.1 中会把 stderr 包装成 `ErrorRecord`，直接字符串化只会得到 `System.Management.Automation.RemoteException`，真实文本在 `.TargetObject` 里。

本项目双管齐下：apt 脚本开头 `exec 2>&1` 把 stderr 并入 stdout，捕获侧（`Invoke-Wsl`）也按 `ErrorRecord` 取 `.TargetObject`。

### 7. WSL 必须按用户运行

WSL 的发行版注册在 `HKCU` 下（每用户一份），且需要在关闭 WSL 前弹窗，因此计划任务**不能**设成 SYSTEM 或「不管用户是否登录运行」—— 否则既找不到 distro，弹窗也无法显示在交互桌面上。

---

## 适配到其他机器

**不需要改代码。** 整个目录可以原样复制到任何位置或盘符。

| 要做的 | 说明 |
|---|---|
| 复制 / 克隆目录 | 放哪都行，所有路径自动推导 |
| 建 `settings.psd1` | 指定备份目录；不建则回退到 `$env:USERPROFILE\.wsl-autoupdate-backup` |
| 注册计划任务 | `.\Register-WslAutoUpdateTask.ps1`（内部用 `$PSScriptRoot` 与动态取当前用户） |
| 非 Ubuntu 发行版 | 改 `Invoke-WslAutoUpdate.ps1` 里的 `$Distro` |

各文件的硬编码路径现状：

| 文件 | 硬编码绝对路径 |
|---|---|
| `Invoke-WslAutoUpdate.ps1` | **无** —— 全部由 `$PSScriptRoot` 推导 |
| `Sync-WslAutoUpdateBackup.ps1` | **无** —— `-Source` 默认脚本所在目录，`-Dest` 走 `settings.psd1` |
| `Register-WslAutoUpdateTask.ps1` | **无** |
| `wsl-autoupdate-apt.sh` | **无** |

> ⚠️ **移动了项目目录后，必须重新注册一次计划任务。**
> 计划任务里存的是注册当时的脚本绝对路径 —— 那是运行期数据而非源码硬编码，但目录一移就成了失效的旧路径。重新注册即可刷新：
>
> ```powershell
> cd <新目录>
> .\Register-WslAutoUpdateTask.ps1
> ```
>
> 验证是否指向正确位置：
>
> ```powershell
> (Get-ScheduledTask -TaskName 'WSL Auto Update').Actions[0].Arguments
> ```

---

## 日常维护清单

改动脚本之后：

```powershell
# 1. 同步到备份目录
.\Sync-WslAutoUpdateBackup.ps1

# 2. 提交并推送
git add -A
git commit -m "说明本次改动"
git push
```

若改的是 `wsl-autoupdate-apt.sh`，下次运行会自动同步进 distro；想立刻生效就手动触发一次完整升级。

补充三点：

- 新增的脚本文件会被同步脚本**自动纳入**（排除规则是黑名单，不是白名单），无需改同步脚本。
- `settings.psd1` 会被**同步进备份**（它是部署状态的一部分，恢复时用得上），但它**不会进仓库**。
- `.git` 也会被同步进备份，所以备份带完整历史。注意 `Get-ChildItem -Recurse` 默认会跳过隐藏目录（`git init` 给 `.git` 加了隐藏属性），同步脚本里必须带 `-Force` —— 这点踩过坑，已在脚本注释里说明。
