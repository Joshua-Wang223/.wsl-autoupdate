#Requires -Version 5.1
<#
================================================================
 把 WSL 自动更新的脚本同步到备份目录

 只同步脚本本体，**不含**：
   - downloads\ —— 内含约 247 MB 的引擎 MSI
   - 运行日志（wsl-autoupdate.log）—— 含主机名与本机路径，属运行时产物

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

$ExcludeDirs  = @('downloads', '.git')
$ExcludeGlobs = @('*.log', '*.log.*', '*.msi', '_*.ps1')

if (-not (Test-Path $Source)) { throw "源目录不存在: $Source" }
if (-not (Test-Path $Dest)) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    "已创建备份目录: $Dest"
}

# 挑选待同步文件：排除 $ExcludeDirs 下的内容与匹配 $ExcludeGlobs 的文件
$items = Get-ChildItem -Path $Source -Recurse -File | Where-Object {
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
    foreach ($f in @(Get-ChildItem -Path $Dest -Recurse -File)) {
        $rel = $f.FullName.Substring($Dest.Length).TrimStart('\')
        $inSource = Test-Path (Join-Path $Source $rel)
        if (-not $inSource) {
            Remove-Item -LiteralPath $f.FullName -Force
            $removed += $rel
        }
    }
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
'备份目录内容:'
Get-ChildItem -Path $Dest -Recurse -File |
    Select-Object @{n='相对路径';e={$_.FullName.Substring($Dest.Length).TrimStart('\')}}, Length, LastWriteTime |
    Format-Table -AutoSize
