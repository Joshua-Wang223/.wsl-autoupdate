#Requires -Version 5.1
<#
================================================================
 注册 / 重新注册 / 卸载 WSL 自动更新计划任务

 以管理员身份运行：
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-WslAutoUpdateTask.ps1
 卸载：
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-WslAutoUpdateTask.ps1 -Remove
================================================================
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$TaskName = 'WSL Auto Update',
    [string]$RunAt    = '03:30'
)

$ErrorActionPreference = 'Stop'

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        "已卸载计划任务: $TaskName"
    } else {
        "计划任务不存在: $TaskName"
    }
    return
}

$scriptPath = Join-Path $PSScriptRoot 'Invoke-WslAutoUpdate.ps1'
if (-not (Test-Path $scriptPath)) { throw "找不到主脚本: $scriptPath" }

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptPath)

$trigger = New-ScheduledTaskTrigger -Daily -At $RunAt

# StartWhenAvailable: 错过计划时间（如机器关机/休眠）后开机尽快补跑
# ExecutionTimeLimit 3 小时: 本机 GitHub 下载实测仅 68-90 kB/s，需留足时间
# 未启用 WakeToRun: 不主动唤醒机器，避免半夜无谓启动工作机
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

# WSL 的发行版注册在 HKCU 下（每个用户一份），因此任务必须以登录用户身份运行；
# 又因为需要在关闭 WSL 前弹窗征求同意，也不能用 SYSTEM 或“不管用户是否登录运行”，
# 否则弹窗无法显示在交互桌面上。
$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Highest

$description = '每日唤醒 Ubuntu 执行 apt 升级，并检查 WSL 引擎是否有新版本；' +
               '需要关闭 WSL 时先弹窗征求同意，5 分钟无响应则自动继续。'

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -Principal   $principal `
    -Description $description `
    -Force | Out-Null

"已注册计划任务: $TaskName"
""
"=== 任务配置 ==="
$t = Get-ScheduledTask -TaskName $TaskName
"执行身份     : $($t.Principal.UserId)  (LogonType=$($t.Principal.LogonType), RunLevel=$($t.Principal.RunLevel))"
"触发器       : 每日 $RunAt"
"命令         : $($t.Actions[0].Execute)"
"参数         : $($t.Actions[0].Arguments)"
"多实例       : $($t.Settings.MultipleInstances)"
"超时限制     : $($t.Settings.ExecutionTimeLimit)"
"错过补跑     : $($t.Settings.StartWhenAvailable)"
"唤醒机器     : $($t.Settings.WakeToRun)"
""
"=== 运行计划 ==="
Get-ScheduledTaskInfo -TaskName $TaskName | Select-Object NextRunTime, LastRunTime, LastTaskResult | Format-List
