<#
================================================================
 部署设置示例文件

 复制本文件为 settings.psd1，改成自己的值即可：

     Copy-Item settings.example.psd1 settings.psd1

 settings.psd1 已被 .gitignore 忽略，不会被提交，因此可以放心
 填本机专属路径。

 若不存在 settings.psd1，Sync-WslAutoUpdateBackup.ps1 会回退到
 $env:USERPROFILE\.wsl-autoupdate-backup。

 注意：本文件由 Import-PowerShellDataFile 读取，只解析数据、
 不执行代码，因此不要在里面写函数或命令。
================================================================
#>
@{
    # 备份目录 —— 脚本会被同步到这里。改成你自己的路径。
    # 例如：'D:\Backups\.wsl-autoupdate'  或  'E:\bak\wsl-autoupdate'
    BackupDir = 'C:\Users\YourName\.wsl-autoupdate-backup'
}
