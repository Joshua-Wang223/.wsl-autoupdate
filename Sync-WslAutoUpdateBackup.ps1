#Requires -Version 5.1
<#
================================================================
 把 WSL 自动更新的脚本同步到备份目录

 同步内容 = 项目工作树 + .git（完整版本历史）
 备份目录因此是一个「带历史、可直接使用的仓库」：既能直接取用脚本，
 也能 git log 查改动、git checkout 回退到任意版本。
 **不含**：
   - downloads\ —— 内含引擎 MSI（单个 250–370 MB），体积过大
   - 运行日志（wsl-autoupdate.log）—— 含主机名与本机路径，属运行时产物

 注意：备份是**镜像**，不是工作副本。别在备份目录里改代码再指望同步回源；
   要改请改源目录，然后跑本脚本。

 排除规则集中在 $ExcludeDirs / $ExcludeGlobs，所以将来新增的脚本
 会被自动纳入同步，不需要改这个文件。

 默认是非破坏性的：只覆盖和新增，不删除备份目录里多出来的文件
 （对备份而言，多留一份通常比误删安全）。需要严格镜像时加 -Mirror。

 路径解析（无需改代码）：
   源目录   默认 = 本脚本所在目录，可用 -Source 覆盖
   备份目录 优先级 = -Dest 参数 > settings.psd1 的 BackupDir
                     > $env:USERPROFILE\.wsl-autoupdate-backup

 用法：
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-WslAutoUpdateBackup.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-WslAutoUpdateBackup.ps1 -Mirror
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Sync-WslAutoUpdateBackup.ps1 -Dest 'E:\bak\wsl'
================================================================
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Dest,
    [switch]$Mirror
)

$ErrorActionPreference = 'Stop'

# --- 源目录：默认就是本脚本所在目录（即项目根目录），无需硬编码 ---
if ([string]::IsNullOrEmpty($Source)) {
    if ([string]::IsNullOrEmpty($PSScriptRoot)) {
        throw '无法确定脚本所在目录（$PSScriptRoot 为空）。请用 -File 方式运行本脚本。'
    }
    $Source = $PSScriptRoot
}

# --- 备份目录：属于部署决策，无法从代码推导，按以下优先级取值 ---
#   1) 命令行 -Dest
#   2) 同目录下 settings.psd1 的 BackupDir
#   3) 回退到 $env:USERPROFILE\.wsl-autoupdate-backup（可移植，不写死盘符）
# 用 Import-PowerShellDataFile 读取 .psd1：它只解析数据、不执行代码。
$destSource = '-Dest 参数'
if ([string]::IsNullOrEmpty($Dest)) {
    $Dest       = Join-Path $env:USERPROFILE '.wsl-autoupdate-backup'
    $destSource = '内置回退值'
    $settingsFile = Join-Path $Source 'settings.psd1'
    if (Test-Path $settingsFile) {
        $settings = Import-PowerShellDataFile -Path $settingsFile
        if ($settings.ContainsKey('BackupDir') -and -not [string]::IsNullOrEmpty($settings.BackupDir)) {
            $Dest       = $settings.BackupDir
            $destSource = 'settings.psd1'
        } else {
            Write-Warning "settings.psd1 存在但未提供有效的 BackupDir，改用内置回退值：$Dest"
        }
    } else {
        Write-Warning "未找到 settings.psd1，改用内置回退值：$Dest（可复制 settings.example.psd1 为 settings.psd1 来指定）"
    }
}

# .git 一并同步，让备份也成为带完整历史的仓库。
# 它只有几百 KB（46 个文件），且内部没有会被 $ExcludeGlobs 误伤的文件名。
# 前提：同步期间不要有 git 命令在源仓库里写（本脚本自身不调用 git 写操作）。
$ExcludeDirs  = @('downloads')
$ExcludeGlobs = @('*.log', '*.log.*', '*.msi', '_*.ps1')

if (-not (Test-Path $Source)) { throw "源目录不存在: $Source" }
if (-not (Test-Path $Dest)) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    "已创建备份目录: $Dest"
}

# 挑选待同步文件：排除 $ExcludeDirs 下的内容与匹配 $ExcludeGlobs 的文件
# 必须加 -Force：git init 在 Windows 上会给 .git 目录加上隐藏属性，而
# Get-ChildItem -Recurse 默认既不返回隐藏项、也不递归进隐藏目录，
# 不加的话 .git 会被整个跳过、备份就拿不到版本历史（曾实测踩到）。
$items = Get-ChildItem -Path $Source -Recurse -File -Force | Where-Object {
    $rel   = $_.FullName.Substring($Source.Length).TrimStart('\')
    $first = ($rel -split '\\')[0]
    if ($ExcludeDirs -contains $first) { return $false }
    foreach ($g in $ExcludeGlobs) { if ($_.Name -like $g) { return $false } }
    return $true
}

$copied  = @()
$skipped = @()
foreach ($f in $items) {
    $rel    = $f.FullName.Substring($Source.Length).TrimStart('\')
    $target = Join-Path $Dest $rel
    $tdir   = Split-Path $target -Parent
    if (-not (Test-Path $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }

    # 只在内容确实不同时才覆盖，便于从输出一眼看出本次是否真有变化
    $same = $false
    if (Test-Path $target) {
        $same = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -eq
                (Get-FileHash -LiteralPath $target   -Algorithm SHA256).Hash
    }
    if ($same) {
        $skipped += $rel
    } else {
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
        $copied += $rel
    }
}

$removed = @()
if ($Mirror) {
    # 同样要 -Force，否则 .git 隐藏目录不会被纳入镜像比较，旧的 git 对象
    # 永远清不掉，-Mirror 就名不副实
    foreach ($f in @(Get-ChildItem -Path $Dest -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($Dest.Length).TrimStart('\')
        $inSource = Test-Path (Join-Path $Source $rel)
        if (-not $inSource) {
            Remove-Item -LiteralPath $f.FullName -Force
            $removed += $rel
        }
    }
}

# --- 校验备份里的 git 仓库：除了「文件拷过来了」，还要能读、且与源同一提交 ---
# 备份现在含 .git，所以光看文件是否复制成功不够 —— 还须确认历史可用且没有
# 落后于源（例如拷贝期间源仓库正在变动，或排除规则把 .git 漏掉了）。
$repoCheck = @()
if (Test-Path (Join-Path $Source '.git')) {
    if (-not (Test-Path (Join-Path $Dest '.git'))) {
        $repoCheck += '备份目录缺少 .git —— 历史未同步，请检查排除规则'
    } else {
        $srcHead  = (& git -C $Source rev-parse HEAD 2>$null | Select-Object -First 1)
        $destHead = (& git -C $Dest   rev-parse HEAD 2>$null | Select-Object -First 1)
        $destLog  = (& git -C $Dest   log --oneline -1 2>$null | Select-Object -First 1)
        $repoCheck += "源   HEAD   : $srcHead"
        $repoCheck += "备份 HEAD   : $destHead"
        if ($srcHead -and ($srcHead -eq $destHead)) {
            $repoCheck += '历史校验    : 一致 ✓'
        } else {
            $repoCheck += '历史校验    : 不一致 ✗ 备份历史与源不同步'
        }
        $repoCheck += "备份最新提交: $destLog"
    }
} else {
    $repoCheck += '源目录不是 git 仓库，跳过历史校验'
}

''
"源目录   : $Source   （来源: 脚本所在目录或 -Source）"
"备份目录 : $Dest   （来源: $destSource）"
''
"已同步 ({0}):" -f $copied.Count
foreach ($c in $copied) { "  + $c" }
"未变化 ({0}):" -f $skipped.Count
foreach ($s in $skipped) { "  = $s" }
if ($Mirror) {
    "已删除备份中多余文件 ({0}):" -f $removed.Count
    foreach ($r in $removed) { "  - $r" }
}
''
'版本历史校验:'
foreach ($l in $repoCheck) { "  $l" }
''
'备份目录内容（不含 .git 内部）:'
Get-ChildItem -Path $Dest -Recurse -File |
    Where-Object { $_.FullName.Substring($Dest.Length).TrimStart('\') -notlike '.git\*' } |
    Select-Object @{n='相对路径';e={$_.FullName.Substring($Dest.Length).TrimStart('\')}}, Length, LastWriteTime |
    Format-Table -AutoSize
