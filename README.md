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
        │                        └─ 5 分钟无响应 → 自动同意，升级
        │                  ↓
        │             curl 断点续传 → 校验微软签名 → wsl --shutdown → msiexec 静默安装
        │
        └─ 收尾     downloads\ 内引擎 MSI 与安装日志各保留最新 2 个
```

**关键设计：只在会打断用户时才弹窗。** 日常 03:30 时 distro 通常已自动休眠（`Stopped`），因此绝大多数运行都是静默完成的，不会半夜弹窗。

---

## 文件说明

| 文件 | 作用 | 纳入版本控制 |
|---|---|:---:|
| `Invoke-WslAutoUpdate.ps1` | 主编排脚本。计划任务真正调用的就是它，阶段 0/A/B/收尾都在这里 | ✅ |
| `wsl-autoupdate-apt.sh` | 在 Ubuntu 内执行 apt 的脚本。每次运行由主线用 `cp` 覆盖同步到 distro 的 `/usr/local/sbin/`，因此**改 Windows 侧这份就会自动生效** | ✅ |
| `Register-WslAutoUpdateTask.ps1` | 注册 / 卸载 / 改时间。整套配置可复现，重装系统后一条命令恢复 | ✅ |
| `Sync-WslAutoUpdateBackup.ps1` | 把脚本同步到备份目录 | ✅ |
| `.gitignore` | 挡掉 `downloads/`、`*.msi`、运行日志、`_*.ps1` | ✅ |
| `wsl-autoupdate.log` | 运行日志，超 2 MB 轮转为 `.log.1` | ❌ |
| `downloads\` | 引擎 MSI（约 247 MB/个）与 msiexec 安装日志 | ❌ |

distro 内另有部署副本：`/usr/local/sbin/wsl-autoupdate-apt.sh`

---

## 快速开始

### 前提

- Windows 11（在 26200 上验证过），已启用 WSL 与 VirtualMachinePlatform
- 已安装至少一个 WSL 发行版
- 以**管理员**身份执行注册

### 部署

```powershell
# 1. 放到固定目录
git clone https://github.com/Joshua-Wang223/.wsl-autoupdate.git "$env:USERPROFILE\.wsl-autoupdate"

# 2. 按实际情况修改配置区（见下方「适配到其他机器」）

# 3. 注册计划任务（需管理员）
cd "$env:USERPROFILE\.wsl-autoupdate"
.\Register-WslAutoUpdateTask.ps1
```

---

## 日常使用

### 手动触发完整升级

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File "C:\Users\Administrator\.wsl-autoupdate\Invoke-WslAutoUpdate.ps1"
```

脚本把过程写进日志而非屏幕，跑完请看日志。

> `-STA` 不能省略 —— 同意弹窗基于 WinForms，需要 STA 线程。
> 若此时你开着 WSL 终端，会看到同意弹窗。

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
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Users\Administrator\.wsl-autoupdate\Sync-WslAutoUpdateBackup.ps1"
```

| 参数 | 说明 |
|---|---|
| 无 | 非破坏性，只覆盖 / 新增 |
| `-Mirror` | 额外删除备份目录里多出来的文件 |
| `-Source` / `-Dest` | 覆盖默认路径 |

用 SHA256 比对决定是否覆盖，输出会明确区分「已同步」与「未变化」，因此重复执行是安全的。

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

## 配置项

都在 `Invoke-WslAutoUpdate.ps1` 顶部配置区（第 28–41 行），改完无需改动其他代码：

| 变量 | 默认 | 含义 |
|---|---|---|
| `$BaseDir` | `C:\Users\Administrator\.wsl-autoupdate` | 部署目录 |
| `$AptScriptHostWsl` | `/mnt/c/Users/Administrator/.wsl-autoupdate/wsl-autoupdate-apt.sh` | apt 脚本在 distro 视角下的源路径 |
| `$Distro` | `Ubuntu` | 目标发行版名 |
| `$ConsentSeconds` | `300` | 弹窗无响应多少秒后自动同意 |
| `$MaxDownloadAttempts` | `80` | 断点续传最多重试次数 |
| `$KeepEngineMsi` | `2` | `downloads\` 内保留的 MSI 个数 |
| `$KeepInstallLog` | `2` | `downloads\` 内保留的安装日志个数 |

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

脚本中存在硬编码的绝对路径，克隆后需要修改：

| 文件 | 需修改 |
|---|---|
| `Invoke-WslAutoUpdate.ps1` | 第 28 行 `$BaseDir`、第 32 行 `$AptScriptHostWsl` |
| `Sync-WslAutoUpdateBackup.ps1` | 第 23/24 行 `-Source` / `-Dest` 默认值（也可用参数覆盖） |
| `Register-WslAutoUpdateTask.ps1` | 无 —— 用 `$PSScriptRoot` 与动态取当前用户，可直接使用 |
| `wsl-autoupdate-apt.sh` | 无 |

另外备份目录默认为 `D:\Workspace_Python\.wsl-autoupdate`，请按自己的布局调整。

---

## 日常维护清单

改动脚本之后：

```powershell
# 1. 同步到备份目录
.\Sync-WslAutoUpdateBackup.ps1

# 2. 提交并推送
cd C:\Users\Administrator\.wsl-autoupdate
git add -A
git commit -m "说明本次改动"
git push
```

若改的是 `wsl-autoupdate-apt.sh`，下次运行会自动同步进 distro；想立刻生效就手动触发一次完整升级。
