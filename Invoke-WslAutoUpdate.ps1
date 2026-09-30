#Requires -Version 5.1
<#
================================================================
 WSL 自动更新任务  ——  Windows 侧编排脚本
 由计划任务 "WSL Auto Update" 调用（每日 03:30，仅在用户登录时运行）

 阶段 A：唤醒 Ubuntu，执行发行版内 apt update + upgrade
 阶段 B：检查 GitHub 上是否有新 WSL 引擎版本；若有，
         在强制关闭 WSL 前弹窗征求同意 —— 真人点击则升级；超时无人响应则
         复查届时 distro 是否仍在运行（仍在跑就跳过）；弹窗异常一律跳过。
         历史事故见 Request-Consent 的注释。
         然后 curl 断点续传下载 MSI → 校验微软签名 → 静默安装
 收尾  ：downloads 内的历史产物按类型限量保留
         引擎 MSI 与 msiexec 安装日志各保留最新 2 个
         （最新一次 + 上一次，MSI 用于回滚）

 设计约束（本机实测）：
   * 商店更新通道不可用，wsl --update 会永久挂起，故不使用
   * GitHub 直连约 68-90 kB/s 且会中途死锁，WSL 自带下载器无超时
     机制，故改用 curl -C - 配合重试循环
================================================================
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# --------------------- 路径推导（无硬编码） ---------------------
# 本脚本所在目录即项目根目录，所有路径由它推导。这样整个目录可以
# 原样复制到任何位置（含换盘符）而无需改代码。
# 用 -File 方式调用时 $PSScriptRoot 一定有值；若为空（例如把脚本内容
# 直接粘进命令行执行），推导会失效，此处明确报错而不是继续跑错路径。
$BaseDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($BaseDir)) {
    throw '无法确定脚本所在目录（$PSScriptRoot 为空）。请用 -File 方式运行本脚本。'
}

# 把本机 Windows 路径转成 distro 内可见的 /mnt/<小写盘符>/... 路径，
# 供 wsl.exe 直接读取（例如把 apt 脚本 cp 进 distro）。
function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2]
    }
    throw "无法转换为 WSL 路径（需为 <盘符>:\... 形式）: $WindowsPath"
}

# ---------------------------- 配置 ----------------------------
$DownloadDir         = Join-Path $BaseDir 'downloads'
$LogFile             = Join-Path $BaseDir 'wsl-autoupdate.log'
$AptScriptHost       = Join-Path $BaseDir 'wsl-autoupdate-apt.sh'
$AptScriptHostWsl    = ConvertTo-WslPath $AptScriptHost
$Distro              = 'Ubuntu'
$WslExe              = Join-Path $env:SystemRoot 'System32\wsl.exe'
$CurlExe             = Join-Path $env:SystemRoot 'System32\curl.exe'
$AptScriptInDistro   = '/usr/local/sbin/wsl-autoupdate-apt.sh'
$GitHubApi           = 'https://api.github.com/repos/microsoft/WSL/releases/latest'
$ConsentSeconds      = 300     # 弹窗无响应多久后跳过引擎升级（注意：超时不会关闭 WSL）
$SettleSeconds       = 90      # 关机前复查发现 distro 仍在运行时的静候秒数（用于区分「我方活动残留」与「用户在用」）
$MaxDownloadAttempts = 80      # 断点续传最多重试次数
$KeepEngineMsi       = 2       # downloads 内最多保留的引擎 MSI 个数（最新下载的 + 升级前那一版，供回滚）
$KeepInstallLog      = 2       # downloads 内最多保留的 msiexec 安装日志个数（最新一次 + 上一次）
# --------------------------------------------------------------

foreach ($d in @($BaseDir, $DownloadDir)) {
    if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 2MB) {
    Move-Item -Path $LogFile -Destination "$LogFile.1" -Force
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value ('{0} [{1,-5}] {2}' -f $stamp, $Level, $Message) -Encoding UTF8
}

# 调用 wsl.exe 并把输出归一化为普通字符串：
#   - 去掉 UTF-16 残留的 NUL
#   - stderr 会被 PowerShell 包装成 ErrorRecord，直接字符串化只会得到
#     "System.Management.Automation.RemoteException"，必须取 TargetObject
function Invoke-Wsl {
    param([string[]]$WslArgs)
    $out  = & $WslExe @WslArgs 2>&1
    $code = $LASTEXITCODE
    $lines = foreach ($o in $out) {
        if ($o -is [System.Management.Automation.ErrorRecord]) {
            $t = $o.TargetObject
            if ([string]::IsNullOrEmpty($t)) { $t = $o.Exception.Message }
            if ([string]::IsNullOrEmpty($t)) { $t = $o.ToString() }
            "$t"
        } else {
            "$o"
        }
    }
    $text = (($lines | ForEach-Object { $_ -replace "`0", '' }) -join "`n")
    return [PSCustomObject]@{ Text = $text; Code = $code }
}

# 读取指定 distro 当前状态，返回 Running / Stopped / Installing / Unknown。
# 阶段 0 与「超时后复查」都用它，避免两处解析逻辑不一致。
function Get-DistroState {
    param([Parameter(Mandatory)][string]$Name)
    $res = Invoke-Wsl @('--list', '--verbose')
    foreach ($line in ($res.Text -split "`n")) {
        if ($line -match ('^\s*\*?\s*' + [regex]::Escape($Name) + '\s')) {
            if     ($line -match 'Running')    { return 'Running' }
            elseif ($line -match 'Stopped')    { return 'Stopped' }
            elseif ($line -match 'Installing') { return 'Installing' }
        }
    }
    return 'Unknown'
}

# 判断 distro 此刻是否确实空闲（可供安全关闭）。
# 难点：看到 Running 未必是用户在跑 —— 本任务自己的 apt 步骤刚唤醒过它，
# 而 WSL 在最后一个客户端断开后要过一段时间才终止 VM，所以那一刻的
# Running 可能只是我方活动的残留。
# 因此看到 Running 时先静候 $SettleSeconds 再复查：
#   转为 Stopped -> 说明刚才是我方残留，可以关闭
#   仍 Running   -> 判定为用户在用，放弃关闭
# 方向偏保守：宁可多等，也不误关。
function Test-DistroIdle {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$SettleSeconds = 90
    )
    $s1 = Get-DistroState -Name $Name
    if ($s1 -eq 'Stopped') { return $true }

    Write-Log "关机前检查: distro 状态为 $s1，可能是本任务自身活动残留；静候 ${SettleSeconds}s 后复查"
    Start-Sleep -Seconds $SettleSeconds
    $s2 = Get-DistroState -Name $Name
    Write-Log "静候后复查: $s2"
    return ($s2 -eq 'Stopped')
}

function ConvertTo-NormVersion {
    param([string]$V)
    $p = @($V.Split('.') | Where-Object { $_ -ne '' })
    while ($p.Count -lt 4) { $p += '0' }
    try { return [version](($p[0..3]) -join '.') } catch { return $null }
}

# 清理 downloads 内的历史产物：按版本号从新到旧排序，只保留最新 $Keep 个，更旧的删除。
# 调用方通过 FilePattern / VersionPattern 指定清理哪一类文件，两类产物（引擎 MSI 与
# msiexec 安装日志）共用同一套逻辑，避免重复实现。
#   FilePattern    识别归属（哪些文件算这一类，认得出就参与限量）
#   VersionPattern 提取版本号，第 1 个捕获组即为版本
#                  只捕获开头的数字部分、不锚定行尾，以便容忍后缀（如 -rc1）。
#                  若锚定成 ^install-([0-9.]+)\.log$ 这种严格形式，带后缀的
#                  名字会匹配失败、被当作 0.0.0.0 而优先删除 —— 会把最新的一份
#                  反而删掉，与“保住最新”的意图相反。日志名由 GitHub tag 生成，
#                  MSI 名由 asset 名生成，两者格式并不受我们控制。
# 只处理匹配 FilePattern 的文件，绝不误删其他文件；可重复执行（幂等）。
function Remove-OldArtifact {
    param(
        [string]$Dir,
        [string]$FilePattern,
        [string]$VersionPattern,
        [int]$Keep = 2
    )

    # 用显式正则而不用 -Filter：-Filter 走文件系统通配符语义，文件名含多个
    # 点号时可能因 8.3 短名匹配出意外结果；正则行为可预测。
    $files = @(Get-ChildItem -Path $Dir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match $FilePattern })
    if ($files.Count -le $Keep) { return @() }

    # 先逐文件算出排序键再排，不用 Sort-Object 的 Expression 脚本块 ——
    # 那样需要靠闭包捕获 $VersionPattern，作用域行为不够直观也不好排查。
    $sorted = $files |
        ForEach-Object {
            $ver = [version]'0.0.0.0'
            $m   = [regex]::Match($_.Name, $VersionPattern)
            if ($m.Success) {
                $v = ConvertTo-NormVersion $m.Groups[1].Value
                if ($null -ne $v) { $ver = $v }
            }
            # 认得出归属但解析不出版本号的（如手工改名留下的）按最低版本处理，
            # 优先被清掉，避免长期占位
            [PSCustomObject]@{ File = $_; Version = $ver }
        } |
        Sort-Object -Property Version -Descending

    $removed = @()
    foreach ($item in ($sorted | Select-Object -Skip $Keep)) {
        Remove-Item -LiteralPath $item.File.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $item.File.FullName)) { $removed += $item.File.Name }
    }
    return $removed
}

# ================= 同意弹窗 =================
# 返回值约定：
#     user-approved  Proceed=$true   真人点击「立即升级」—— 唯一无条件放行的情况
#     user-declined  Proceed=$false  真人点「跳过本次」或直接关窗
#     prompt-failed  Proceed=$false  弹窗不可用 / 抛异常 —— 无法确认有人在场，跳过
#     timeout        Proceed=$false  超时无响应 —— **交由调用方按届时状态决定**
#
# timeout 的 Proceed 取 $false 只是保守默认值：调用方必须显式处理这个 Reason，
# 否则等价于跳过。这样即便调用方将来漏改，也不会意外关掉 WSL。
#
# 为什么超时不在这里拍板：distro 处于 Running 并不等于「人在电脑前」——
# 长时批处理任务同样会让它保持运行。2026-09-30 03:36 就因此出过事故：
# 弹窗超时后自动同意，执行了 wsl --shutdown，中断了正在跑的长任务
# （distro 直到 07:49 才重启）。因此超时后要先看「此刻」还有没有实例在跑。
function Request-Consent {
    param([string]$Message, [int]$TimeoutSeconds = 300)

    $result = [PSCustomObject]@{ Proceed = $false; Reason = 'prompt-failed' }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    } catch {
        Write-Log "无法加载 WinForms，弹窗不可用，本次跳过引擎升级（不关闭 WSL）: $($_.Exception.Message)" 'WARN'
        return $result
    }

    try {
        $form                 = New-Object System.Windows.Forms.Form
        $form.Text            = 'WSL 自动更新'
        $form.ClientSize      = New-Object System.Drawing.Size(560, 250)
        $form.StartPosition   = 'CenterScreen'
        $form.TopMost         = $true
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox     = $false
        $form.MinimizeBox     = $false
        try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) } catch { }

        $lbl           = New-Object System.Windows.Forms.Label
        $lbl.Text      = $Message
        $lbl.Location  = New-Object System.Drawing.Point(18, 18)
        $lbl.Size      = New-Object System.Drawing.Size(524, 140)
        $form.Controls.Add($lbl)

        $countdown         = New-Object System.Windows.Forms.Label
        $countdown.Location = New-Object System.Drawing.Point(18, 162)
        $countdown.Size     = New-Object System.Drawing.Size(524, 24)
        $countdown.ForeColor = [System.Drawing.Color]::DimGray
        $form.Controls.Add($countdown)

        $btnGo          = New-Object System.Windows.Forms.Button
        $btnGo.Text     = '立即升级'
        $btnGo.Location = New-Object System.Drawing.Point(300, 196)
        $btnGo.Size     = New-Object System.Drawing.Size(116, 34)
        $btnGo.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Controls.Add($btnGo)

        $btnSkip          = New-Object System.Windows.Forms.Button
        $btnSkip.Text     = '跳过本次'
        $btnSkip.Location = New-Object System.Drawing.Point(426, 196)
        $btnSkip.Size     = New-Object System.Drawing.Size(116, 34)
        $btnSkip.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnSkip)

        $form.AcceptButton = $btnGo
        $form.CancelButton = $btnSkip

        $form.Show()
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $timedOut = $false

        while ($form.Visible) {
            # 显式检查 DialogResult，不依赖“设置 DialogResult 会自动隐藏窗体”这一
            # 行为：否则用户点了“跳过本次”而窗体未自动关闭时，会被误判为超时，
            # 进而做出与用户意愿相反的决定（自动升级）。
            if ($form.DialogResult -ne [System.Windows.Forms.DialogResult]::None) { break }
            if ((Get-Date) -ge $deadline) { $timedOut = $true; break }
            $rem = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)
            $countdown.Text = "若 $rem 秒内无操作，届时将检查 WSL 是否仍在运行：在跑则跳过，已歇下则继续。"
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
        }

        $dialog = $form.DialogResult
        if ($form.Visible) { $form.Close() }
        $form.Dispose()

        # 只有明确点击「立即升级」才返回 Proceed=$true；timeout 的最终决定权在调用方
        if ($timedOut)   { $result = [PSCustomObject]@{ Proceed = $false; Reason = 'timeout' } }
        elseif ($dialog -eq [System.Windows.Forms.DialogResult]::OK) { $result = [PSCustomObject]@{ Proceed = $true;  Reason = 'user-approved' } }
        else             { $result = [PSCustomObject]@{ Proceed = $false; Reason = 'user-declined' } }
    } catch {
        Write-Log "弹窗异常，本次跳过引擎升级（不关闭 WSL）: $($_.Exception.Message)" 'WARN'
    }
    return $result
}

# ================================ 主流程 ================================
$exitCode = 0
Write-Log ('=' * 68)
Write-Log 'WSL 自动更新任务开始'

# 记录本次解析出的路径：路径全部由脚本位置推导，出问题时这行能立刻
# 看出脚本是从哪个目录跑的、以及转换成 distro 视角后是什么
Write-Log "项目目录: $BaseDir"
Write-Log "apt 脚本: $AptScriptHost  ==> distro: $AptScriptHostWsl"

# ---------- 阶段 0：记录 distro 初始状态 ----------
# 用于判断“关闭 WSL 是否会打断用户”。若任务开始前 distro 本来就是 Running，
# 说明有别的东西正在用它，此时才需要弹窗征求同意。
$initialState = Get-DistroState -Name $Distro
Write-Log "distro '$Distro' 初始状态: $initialState"

if ($initialState -eq 'Unknown') {
    Write-Log "无法识别 distro '$Distro'，任务中止" 'ERROR'
    Write-Log 'WSL 自动更新任务结束 (exit=2)'
    exit 2
}

# ---------- 阶段 A：发行版内软件包升级 ----------
Write-Log '--- 阶段 A：升级发行版内软件包 ---'

# distro 内的脚本以 Windows 侧同名文件为准，每次覆盖同步，避免两边漂移。
# 这里用 cp/chmod 直接传参，不套 bash -lc：PowerShell 5.1 向原生程序传参时会
# 把内层 " 转义为 \"，使 shell 收到未加引号的 \r 并吃掉反斜杠，导致 tr 收不到
# CR 而把文本里所有字母 r 删掉（曾把 export/upgrade/grep 损坏成 expot/upgade/gep）。
$deployFailed = $false

$cpRes = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--', 'cp', '-f', $AptScriptHostWsl, $AptScriptInDistro)
if ($cpRes.Code -ne 0) {
    Write-Log "拷贝 apt 脚本进 distro 失败 (exit=$($cpRes.Code)): $($cpRes.Text)" 'ERROR'
    $deployFailed = $true
}

if (-not $deployFailed) {
    $chmodRes = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--', 'chmod', '755', $AptScriptInDistro)
    if ($chmodRes.Code -ne 0) {
        Write-Log "chmod 755 失败 (exit=$($chmodRes.Code)): $($chmodRes.Text)" 'ERROR'
        $deployFailed = $true
    }
}

# 语法门禁：必须先能被 bash 解析才允许执行，防止损坏的脚本静默跑挂
if (-not $deployFailed) {
    $synRes = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--', 'bash', '-n', $AptScriptInDistro)
    if ($synRes.Code -ne 0) {
        Write-Log "apt 脚本语法检查失败 (exit=$($synRes.Code)): $($synRes.Text)" 'ERROR'
        $deployFailed = $true
    }
}

if ($deployFailed) {
    $exitCode = 3
} else {
    Write-Log 'apt 脚本已同步并通过 bash -n 语法检查'
    $aptRes = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--', $AptScriptInDistro)
    foreach ($l in ($aptRes.Text -split "`n")) { Write-Log $l }
    Write-Log "apt 阶段退出码: $($aptRes.Code)"
    if ($aptRes.Code -ne 0) { $exitCode = 4 }
}

# ---------- 阶段 B：WSL 引擎升级 ----------
Write-Log '--- 阶段 B：检查 WSL 引擎更新 ---'
try {
    $verRes = Invoke-Wsl @('--version')
    $m = [regex]::Match($verRes.Text, 'WSL version:\s*([0-9]+(?:\.[0-9]+)+)')
    $installedRaw = $null
    if ($m.Success) { $installedRaw = $m.Groups[1].Value }
    if (-not $installedRaw) { throw "无法解析已安装的 WSL 版本：$($verRes.Text)" }

    $kernelRaw = '-'
    $km = [regex]::Match($verRes.Text, 'Kernel version:\s*(\S+)')
    if ($km.Success) { $kernelRaw = $km.Groups[1].Value }
    Write-Log "已安装: WSL $installedRaw (内核 $kernelRaw)"

    $rel = Invoke-RestMethod -Uri $GitHubApi -Headers @{ 'User-Agent' = 'wsl-autoupdate/1.0' } -TimeoutSec 90
    $latestTag = ("$($rel.tag_name)").TrimStart('v')
    Write-Log "GitHub 最新: $latestTag"

    $vInstalled = ConvertTo-NormVersion $installedRaw
    $vLatest    = ConvertTo-NormVersion $latestTag

    if ($null -eq $vInstalled -or $null -eq $vLatest) {
        throw "版本号解析失败 (已安装=$installedRaw, 最新=$latestTag)"
    }

    if ($vLatest -le $vInstalled) {
        Write-Log '引擎已是最新，无需升级'
    } else {
        Write-Log "发现新版本: $installedRaw -> $latestTag"

        $asset = $rel.assets | Where-Object { $_.name -match '^wsl\..*\.x64\.msi$' } | Select-Object -First 1
        if (-not $asset) { throw "release $latestTag 中未找到 x64 MSI 资产" }
        Write-Log "资产: $($asset.name)  ($($asset.size) 字节)"
        Write-Log "地址: $($asset.browser_download_url)"

        # --- 征求同意：仅当任务开始前 distro 已在运行，才可能打断用户 ---
        # 注意：distro 处于 Running 并不等于「人在电脑前」—— 长时批处理任务
        # 同样会让它保持运行，所以不能凭「5 分钟前是 Running」就认定有人守着。
        # $approvalMode 记录「这次关闭是谁批的」：
        #   user = 真人明确点击过，关机前不再重复检查（他已知情并同意）
        #   auto = 超时判定或本来就空闲，关机前还要再过一道闸（见下方 Test-DistroIdle）
        $proceed = $true
        $approvalMode = 'auto'
        if ($initialState -eq 'Running') {
            $msg = "检测到 WSL 引擎有新版本：$installedRaw -> $latestTag" + [Environment]::NewLine + [Environment]::NewLine +
                   "安装新引擎需要关闭 WSL，这会中断其中正在运行的任务与终端会话。" + [Environment]::NewLine + [Environment]::NewLine +
                   '是否现在升级？'
            Write-Log "distro 初始为 Running，弹窗征求同意（超时 ${ConsentSeconds}s 后按届时状态决定）"
            $consent = Request-Consent -Message $msg -TimeoutSeconds $ConsentSeconds
            Write-Log "弹窗结果: $($consent.Reason) (Proceed=$($consent.Proceed))"
            $proceed = $consent.Proceed
            if ($consent.Reason -eq 'user-approved') { $approvalMode = 'user' }

            if ($consent.Reason -eq 'timeout') {
                # 超时无响应：以「此刻」distro 是否仍在运行作为判据，而不是拿
                # 5 分钟前的状态推断。若这期间用户已结束所有会话、distro 自动
                # 歇下，关闭它就影响不到任何人，此时才允许继续；只要还有实例
                # 在跑（无论是终端还是批处理任务）就一律跳过。
                $stateNow = Get-DistroState -Name $Distro
                Write-Log "超时后复查 distro 状态: $stateNow"
                # 只认明确的 Stopped 为「确认没在跑」。Running/Installing/
                # Unknown 一律按「可能有实例在用」处理 —— Unknown 只是没拿到
                # 证据，不等于确认空闲，这种时候不能朝放行的方向猜。
                if ($stateNow -eq 'Stopped') {
                    $proceed = $true
                    Write-Log '已无运行中的 WSL 实例（状态 Stopped），自动继续升级'
                } else {
                    $proceed = $false
                    Write-Log "distro 状态为 $stateNow，无法确认已空闲，跳过本次引擎升级（不关闭 WSL）"
                }
            }
        } else {
            Write-Log "distro 初始为 Stopped，未打断任何会话，直接升级"
        }

        if (-not $proceed) {
            Write-Log '本次跳过引擎升级，WSL 未被关闭；下次运行会再询问'
        } else {
            # --- 断点续传下载 ---
            $msiPath = Join-Path $DownloadDir $asset.name
            $target  = [int64]$asset.size
            $done    = $false
            for ($i = 1; $i -le $MaxDownloadAttempts; $i++) {
                $have = 0
                if (Test-Path $msiPath) { $have = (Get-Item $msiPath).Length }
                if ($have -ge $target) { $done = $true; break }
                Write-Log ("下载尝试 {0}/{1}，续传起点 {2:N1} MB / {3:N1} MB" -f $i, $MaxDownloadAttempts, ($have / 1MB), ($target / 1MB))
                & $CurlExe -L -C - -s --connect-timeout 20 --speed-limit 2048 --speed-time 25 -o $msiPath $asset.browser_download_url 2>$null | Out-Null
            }
            if (Test-Path $msiPath) {
                $finalLen = (Get-Item $msiPath).Length
                if ($finalLen -ge $target) { $done = $true }
            }

            if (-not $done) {
                Write-Log "下载未完成（重试 $MaxDownloadAttempts 次后仍不完整），本次跳过引擎升级" 'ERROR'
                if ($exitCode -eq 0) { $exitCode = 5 }
            } else {
                Write-Log "下载完成: $msiPath ($finalLen 字节)"

                # --- 校验微软签名 ---
                $sig = Get-AuthenticodeSignature $msiPath
                $okSigner = $false
                if ($sig.SignerCertificate) { $okSigner = ($sig.SignerCertificate.Subject -match 'Microsoft Corporation') }
                if ($sig.Status -ne 'Valid' -or -not $okSigner) {
                    Write-Log "签名校验失败，拒绝安装。Status=$($sig.Status) Signer=$($sig.SignerCertificate.Subject)" 'ERROR'
                    Write-Log "已删除可疑文件: $msiPath"
                    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
                    if ($exitCode -eq 0) { $exitCode = 6 }
                } else {
                    Write-Log "签名校验通过: $($sig.SignerCertificate.Subject)"

                    # --- 关机前最后一道闸：锁住「授权 → 下载 → 关机」之间的状态漂移 ---
                    # 授权发生在下载之前，而下载可能耗时数分钟；若期间有人启动了
                    # WSL，直接关机就会砍掉他刚起的任务 —— 前面那次复查的结论
                    # 到这时已经过期了。所以真正关机前必须重判一次。
                    # 只有真人明确点击过的免检：他是在知情前提下同意的，且从点击
                    # 到关机之间只隔着这几行代码，没有可供漂移的窗口。
                    $gateOpen = $true
                    if ($approvalMode -eq 'user') {
                        Write-Log '关机前复查: 本次为真人明确批准，不再重复检查'
                    } else {
                        $gateOpen = Test-DistroIdle -Name $Distro -SettleSeconds $SettleSeconds
                        if ($gateOpen) {
                            Write-Log '关机前复查通过: distro 已空闲，可以安全关闭'
                        } else {
                            Write-Log '关机前复查未通过: distro 仍在运行（或状态不明），放弃本次安装、不关闭 WSL' 'WARN'
                            Write-Log "MSI 已保留在 $msiPath；下次运行会发现它已完整并跳过下载，无需重新下载"
                        }
                    }

                    if ($gateOpen) {
                        # --- 关闭 WSL 并静默安装 ---
                        $shut = Invoke-Wsl @('--shutdown')
                        Write-Log "已执行 wsl --shutdown (exit=$($shut.Code))"
                        Start-Sleep -Seconds 5

                        $installLog = Join-Path $DownloadDir ("install-{0}.log" -f $latestTag)
                        $p = Start-Process -FilePath 'msiexec.exe' `
                                           -ArgumentList @('/i', $msiPath, '/qn', '/norestart', '/l*v', $installLog) `
                                           -Wait -PassThru
                        Write-Log "msiexec 退出码: $($p.ExitCode)"

                        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
                            Start-Sleep -Seconds 3
                            $afterRes = Invoke-Wsl @('--version')
                            $am = [regex]::Match($afterRes.Text, 'WSL version:\s*([0-9]+(?:\.[0-9]+)+)')
                            $akm = [regex]::Match($afterRes.Text, 'Kernel version:\s*(\S+)')
                            if ($am.Success) { Write-Log "升级后: WSL $($am.Groups[1].Value), 内核 $($akm.Groups[1].Value)" }
                            Write-Log '引擎升级成功'
                        } else {
                            Write-Log "引擎安装失败，退出码 $($p.ExitCode)，详见 $installLog" 'ERROR'
                            if ($exitCode -eq 0) { $exitCode = 7 }
                        }
                    }
                }
            }
        }
    }
} catch {
    Write-Log "引擎检查/升级阶段异常: $($_.Exception.Message)" 'ERROR'
    if ($exitCode -eq 0) { $exitCode = 8 }
}

# ---------- 收尾：downloads 内历史产物按类型限量保留 ----------
# 放在整个流程最后，避免升级过程中误删正在使用的回滚副本
$retention = @(
    [PSCustomObject]@{
        Label = '引擎 MSI'
        File  = '^wsl\..*\.x64\.msi$'
        Ver   = '^wsl\.([0-9]+(?:\.[0-9]+)*)'
        Keep  = $KeepEngineMsi
    },
    [PSCustomObject]@{
        Label = '安装日志'
        File  = '^install-.*\.log$'
        Ver   = '^install-([0-9]+(?:\.[0-9]+)*)'
        Keep  = $KeepInstallLog
    }
)
foreach ($r in $retention) {
    try {
        $removed = Remove-OldArtifact -Dir $DownloadDir -FilePattern $r.File -VersionPattern $r.Ver -Keep $r.Keep
        if ($removed.Count -gt 0) {
            Write-Log ("已清理旧 $($r.Label)（保留最新 $($r.Keep) 个）: " + ($removed -join ', '))
        }
        $kept = @(Get-ChildItem -Path $DownloadDir -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match $r.File })
        $keptNames = '(无)'
        if ($kept.Count -gt 0) { $keptNames = ($kept.Name -join ', ') }
        Write-Log "$($r.Label) 现存 $($kept.Count) 个（上限 $($r.Keep)）: $keptNames"
    } catch {
        Write-Log "清理 $($r.Label) 失败: $($_.Exception.Message)" 'WARN'
    }
}

Write-Log "WSL 自动更新任务结束 (exit=$exitCode)"
exit $exitCode
