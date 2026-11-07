# 建立本安装的最高权限交互会话任务；-OnlyRelogin 只修按需重登任务。
param([string]$Dir = 'E:\dafeiyu', [switch]$OnlyRelogin, [switch]$OnlyNapCat)
$ErrorActionPreference = 'Stop'
$Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
$log = Join-Path $Dir 'logs\make-tasks.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
function Say([string]$s) { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('HH:mm:ss') + ' ' + $s) -Encoding UTF8 }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '修复计划任务需要管理员权限。' }
$user = $identity.Name
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Test-TaskOwnership($Task, [string]$Root) {
    if ($null -eq $Task) { return $true }
    $prefix = $Root.TrimEnd('\') + '\'
    foreach ($action in $Task.Actions) {
        if (([string]$action.Arguments).IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$action.Execute).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function New-Task([string]$Name, [string]$File, [switch]$AtLogon, [switch]$Relogin) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "任务启动文件不存在：$File" }
    $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not (Test-TaskOwnership $existing $Dir)) { throw "已有同名任务属于其他目录，未覆盖：$Name" }
    $arguments = if ($Relogin) {
        '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $File + '" -Dir "' + $Dir + '" -Autostart'
    } else {
        $command = "& '" + $File.Replace("'", "''") + "'; exit `$LASTEXITCODE"
        '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "' + $command + '"'
    }
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $Dir
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $definition = @{ TaskName = $Name; Action = $action; Principal = $principal; Settings = $settings; Force = $true; ErrorAction = 'Stop' }
    if ($AtLogon) { $definition.Trigger = New-ScheduledTaskTrigger -AtLogOn -User $user }
    # 没有 Trigger 的 Relogin 仍是 enabled，可被 schtasks /Run 按需启动。
    Register-ScheduledTask @definition | Out-Null
    Enable-ScheduledTask -TaskName $Name -ErrorAction Stop | Out-Null
    Say "OK $Name"
}

try {
    if ($OnlyRelogin -and $OnlyNapCat) { throw 'OnlyRelogin and OnlyNapCat cannot be combined' }
    if ($OnlyNapCat) {
        New-Task 'Dafeiyu-SnowLuma' "$Dir\tools\relogin-qq.ps1" -AtLogon -Relogin
        Say 'done onlySnowLuma'
        return
    }
    Say ('start onlyRelogin=' + [bool]$OnlyRelogin)
    New-Task 'Dafeiyu-Relogin' "$Dir\tools\relogin-qq.ps1" -Relogin
    if (-not $OnlyRelogin) {
        New-Task 'Dafeiyu-AstrBot' "$Dir\start-astrbot.cmd" -AtLogon
        # SnowLuma 开机也走有互斥体、等待大脑/网络的重登入口。
        New-Task 'Dafeiyu-SnowLuma' "$Dir\tools\relogin-qq.ps1" -AtLogon -Relogin
        New-Task 'Dafeiyu-QQWatch' "$Dir\tools\qq-watch.cmd" -AtLogon
        # 全部注册成功才清理已迁移的三个快捷方式；其他实例或其他名字均保留。
        $startup = [Environment]::GetFolderPath('Startup')
        $backup = Join-Path $Dir ('logs\startup-links-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $shell = New-Object -ComObject WScript.Shell
        foreach ($name in @('大肥鱼-AstrBot.lnk', '大肥鱼-NapCat.lnk', '大肥鱼-QQWatch.lnk')) {
            $path = Join-Path $startup $name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $shortcut = $shell.CreateShortcut($path)
            $target = [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = $shortcut.TargetPath; Arguments = $shortcut.Arguments }) }
            if (-not (Test-TaskOwnership $target $Dir)) { continue }
            New-Item -ItemType Directory -Force $backup | Out-Null
            Copy-Item -LiteralPath $path -Destination (Join-Path $backup $name) -ErrorAction Stop
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Say "MIGRATED $name"
        }
    }
    Say 'done'
} catch {
    Say ('FAIL ' + $_.Exception.Message)
    throw
}
