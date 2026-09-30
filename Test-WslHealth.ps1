#Requires -Version 5.1
<#
================================================================
 WSL 健康检查（只读）

 用途：按需体检本机 WSL 子系统，判断「还能不能正常用」。典型场景：
   - 重启后发现 WSL 起不来
   - 排查完某个问题后，确认已恢复
   - 定期巡检

 ⚠️ 本脚本是**只读**的：只查询状态，绝不调用 `wsl --shutdown` 或
    `wsl --terminate`，不会中断 WSL 里正在跑的任何任务。
    唯一的副作用是「启动测试」会在 distro 本来处于 Stopped 时把它唤醒 ——
    这与关机性质不同，不会打断任何东西；想完全避免可加 -SkipBootTest。

 检查项：
   [1] Windows 超虚拟机是否已加载（HypervisorPresent）
   [2] BCD hypervisorlaunchtype（需管理员权限，读不到则跳过）
   [3] 虚拟化相关服务 WslService / vmcompute / HvHost / hns
   [4] WSL 引擎与内核版本
   [5] 发行版清单与状态
   [6] 启动测试：真的在目标 distro 里跑一条命令并校验哨兵字符串

 退出码：
   0 = 通过（可能有 WARN，但不影响使用）
   1 = 存在 FAIL，需要处理
   2 = 脚本自身无法运行

 用法：
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-WslHealth.ps1
   ... -Distro Ubuntu            指定要检查的发行版（默认取 wsl 的默认发行版）
   ... -SkipBootTest             跳过启动测试（完全不碰 distro）
   ... -LogPath .\wsl-health.log 同时写入文件

 注意：本脚本刻意**自包含**，不要 dot-source `Invoke-WslAutoUpdate.ps1` 来复用函数
 —— 那个脚本没有「只定义不执行」的守卫，dot-source 会真的触发一次升级流程
 （含 apt 更新，甚至在有新版时关闭 WSL）。这正是两者必须分开的原因。
================================================================
#>
[CmdletBinding()]
param(
    [string]$Distro,
    [switch]$SkipBootTest,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# 让 wsl.exe 直接输出 UTF-8。不要改成 [Console]::OutputEncoding = Unicode ——
# 那种做法对 wsl.exe 自身输出有效，但对经 wsl 透传的 bash 输出会乱码，
# 曾因此把一次成功的检查误报成 FAIL（见 README 的「设计要点与已知坑」）。
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'

$script:Checks = New-Object System.Collections.Generic.List[object]
$script:Lines  = New-Object System.Collections.Generic.List[string]

function Add-Line {
    param([string]$Text)
    $script:Lines.Add($Text)
    Write-Output $Text
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = ''
    )
    $script:Checks.Add([PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $tag = switch ($Status) {
        'OK'   { '[ OK ]' }
        'WARN' { '[WARN]' }
        'FAIL' { '[FAIL]' }
        'SKIP' { '[SKIP]' }
    }
    $msg = "  $tag $Name"
    if ($Detail) { $msg += "`n         $Detail" }
    Add-Line $msg
}

# 调用 wsl.exe 并把输出归一化为普通字符串：
#   - 去掉 UTF-16 残留的 NUL
#   - stderr 会被 PowerShell 包成 ErrorRecord，直接字符串化只会得到
#     "System.Management.Automation.RemoteException"，真实文本在 TargetObject 里
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

# ============================== 开始 ==============================
Add-Line '=== WSL 健康检查（只读）==='
Add-Line ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ("主机: " + $env:COMPUTERNAME + "   用户: " + $env:USERDOMAIN + '\' + $env:USERNAME)
Add-Line ''

if (-not (Test-Path -LiteralPath $WslExe)) {
    Add-Line "找不到 wsl.exe: $WslExe"
    Add-Line '结论: 无法检查（WSL 可能未安装）'
    if ($LogPath) { try { $script:Lines | Out-File -FilePath $LogPath -Encoding UTF8 } catch { } }
    exit 2
}

# --- [1] 超虚拟机 ---
Add-Line '[1] Windows 超虚拟机'
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.HypervisorPresent) {
        Add-Check -Name 'HypervisorPresent' -Status 'OK' -Detail '超虚拟机已加载'
    } else {
        Add-Check -Name 'HypervisorPresent' -Status 'FAIL' -Detail (
            '超虚拟机未加载，WSL2 起不来。先确认固件里虚拟化（VT-x/AMD-V）已开启，' +
            '再查下面 [2] 的 BCD 设置')
    }
} catch {
    Add-Check -Name 'HypervisorPresent' -Status 'WARN' -Detail "查询失败: $($_.Exception.Message)"
}

# --- [2] BCD ---
Add-Line ''
Add-Line '[2] BCD hypervisorlaunchtype（2026-09-17 那次故障的根因就在这一项）'
$launchType = $null
try {
    $bcdOut = (& bcdedit /enum '{current}' 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        $m = [regex]::Match($bcdOut, 'hypervisorlaunchtype\s+(\S+)')
        if ($m.Success) { $launchType = $m.Groups[1].Value }
    }
} catch { }
if ($launchType) {
    if ($launchType -match '^Auto') {
        Add-Check -Name 'hypervisorlaunchtype' -Status 'OK' -Detail $launchType
    } else {
        Add-Check -Name 'hypervisorlaunchtype' -Status 'FAIL' -Detail (
            "当前为 $launchType，应为 Auto。修复：以管理员运行 " +
            "bcdedit /set hypervisorlaunchtype auto 然后重启")
    }
} else {
    Add-Check -Name 'hypervisorlaunchtype' -Status 'SKIP' -Detail (
        '读不到（bcdedit 需要管理员权限）。可忽略 —— [1] 的 HypervisorPresent 是更直接的判据')
}

# --- [3] 服务 ---
Add-Line ''
Add-Line '[3] 虚拟化相关服务'
foreach ($s in (Get-Service -Name WslService, vmcompute, HvHost, hns -ErrorAction SilentlyContinue)) {
    $detail = "$($s.Status) / $($s.StartType)"
    if ($s.Name -eq 'WslService') {
        if ($s.Status -eq 'Running') {
            Add-Check -Name $s.Name -Status 'OK' -Detail $detail
        } else {
            Add-Check -Name $s.Name -Status 'FAIL' -Detail "$detail —— WSL 核心服务，应为 Running"
        }
    } else {
        # 这几个是按需启动的：WSL 没在跑时 Stopped 属正常，故只给 WARN
        if ($s.Status -eq 'Running') {
            Add-Check -Name $s.Name -Status 'OK' -Detail $detail
        } else {
            Add-Check -Name $s.Name -Status 'WARN' -Detail "$detail —— 按需启动，WSL 未运行时 Stopped 正常"
        }
    }
}

# --- [4] 引擎版本 ---
Add-Line ''
Add-Line '[4] WSL 引擎'
$ver = Invoke-Wsl @('--version')
if ($ver.Code -eq 0 -and $ver.Text -match 'WSL version:') {
    $wv = [regex]::Match($ver.Text, 'WSL version:\s*(\S+)')
    $kv = [regex]::Match($ver.Text, 'Kernel version:\s*(\S+)')
    Add-Check -Name 'wsl --version' -Status 'OK' -Detail "引擎 $($wv.Groups[1].Value)   内核 $($kv.Groups[1].Value)"
} else {
    Add-Check -Name 'wsl --version' -Status 'FAIL' -Detail "无法解析输出 (exit=$($ver.Code)): $($ver.Text)"
}

# --- [5] 发行版清单 ---
Add-Line ''
Add-Line '[5] 发行版'
$list     = Invoke-Wsl @('--list', '--verbose')
$found    = @()
$defaultD = $null
if ($list.Code -ne 0) {
    Add-Check -Name '发行版清单' -Status 'FAIL' -Detail "wsl -l -v 失败 (exit=$($list.Code)): $($list.Text)"
} else {
    foreach ($ln in ($list.Text -split "`n")) {
        if ($ln -match '^\s*(\*)?\s*(\S+)\s+(Running|Stopped|Installing|Uninstalling)\s+(\d+)\s*$') {
            $isDefault = [bool]$Matches[1]
            $name      = $Matches[2]
            $state     = $Matches[3]
            $verNo     = $Matches[4]
            $found    += $name
            if ($isDefault) { $defaultD = $name }
            Add-Check -Name "distro $name" -Status 'OK' -Detail "状态 $state   WSL $verNo$(if ($isDefault) { '   （默认）' })"
        }
    }
    if ($found.Count -eq 0) {
        Add-Check -Name '发行版清单' -Status 'FAIL' -Detail '一个发行版都没有'
    }
}

# 确定要检查的目标发行版
if (-not $Distro) { $Distro = $defaultD }
if ($Distro -and ($found -notcontains $Distro)) {
    Add-Check -Name "目标发行版 $Distro" -Status 'FAIL' -Detail "清单里没有这个发行版（可用: $($found -join ', ')）"
    $Distro = $null
}

# --- [6] 启动测试 ---
Add-Line ''
Add-Line '[6] 启动测试'
if ($SkipBootTest) {
    Add-Check -Name '启动测试' -Status 'SKIP' -Detail '按 -SkipBootTest 跳过（本项是唯一会碰 distro 的检查）'
} elseif (-not $Distro) {
    Add-Check -Name '启动测试' -Status 'SKIP' -Detail '未确定目标发行版，跳过'
} else {
    # 哨兵字符串：只有它原样出现在输出里才算真的跑通。
    # 这一步顺带也是编码检查 —— 若 wsl 输出被错误解码，哨兵会变乱码而匹配不上，
    # 那正是 2026-09-17 的 wsl-verify 把成功误报成 FAIL 的原因。
    $sentinel = 'WSL_HEALTH_BOOT_OK'
    $boot = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--', 'bash', '-lc', "uname -r; echo $sentinel")
    if ($boot.Text -match $sentinel) {
        $kern = (($boot.Text -split "`n") | Where-Object { $_.Trim() })[0].Trim()
        Add-Check -Name '启动测试' -Status 'OK' -Detail "$Distro 启动成功，内核 $kern"
    } else {
        Add-Check -Name '启动测试' -Status 'FAIL' -Detail (
            "未取到哨兵 $sentinel —— distro 可能起不来。原始输出: $($boot.Text)")
    }
}

# --- 汇总 ---
Add-Line ''
Add-Line '=== 汇总 ==='
$okCount   = @($script:Checks | Where-Object { $_.Status -eq 'OK' }).Count
$warnCount = @($script:Checks | Where-Object { $_.Status -eq 'WARN' }).Count
$failCount = @($script:Checks | Where-Object { $_.Status -eq 'FAIL' }).Count
$skipCount = @($script:Checks | Where-Object { $_.Status -eq 'SKIP' }).Count
Add-Line "  OK $okCount    WARN $warnCount    FAIL $failCount    SKIP $skipCount"
Add-Line ''
if ($failCount -gt 0) {
    Add-Line '结论: FAIL —— 以下项需要处理：'
    foreach ($c in $script:Checks) {
        if ($c.Status -eq 'FAIL') { Add-Line "  - $($c.Name): $($c.Detail)" }
    }
} else {
    Add-Line '结论: PASS —— WSL 可正常使用'
}

if ($LogPath) {
    try {
        $script:Lines | Out-File -FilePath $LogPath -Encoding UTF8
        Add-Line ''
        Add-Line "已写入日志: $LogPath"
    } catch {
        Add-Line ''
        Add-Line "写入日志失败: $($_.Exception.Message)"
    }
}

if ($failCount -gt 0) { exit 1 }
exit 0
