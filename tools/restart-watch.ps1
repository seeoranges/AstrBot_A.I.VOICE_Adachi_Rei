# 只重启本安装、当前 Windows 会话的掉线提醒，不碰其他实例。
param([string]$Dir = '')
$ErrorActionPreference = 'Stop'
if (-not $Dir) { $Dir = Split-Path $PSScriptRoot }
$Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
$watch = Join-Path $Dir 'tools\qq_watch.py'
$py = Join-Path $Dir 'uv\tools\astrbot\Scripts\python.exe'
$pyw = @((Join-Path $Dir 'tools\python\pythonw.exe'), (Join-Path $Dir 'uv\tools\astrbot\Scripts\pythonw.exe'), $py) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $pyw -or -not (Test-Path -LiteralPath $py) -or -not (Test-Path -LiteralPath $watch)) { throw '缺少守护程序或 Python，未关闭现有提醒进程。' }

function Test-WatchProcess($Process, [string]$WatchPath, [string]$Root, [int]$Session) {
    if ($Process.Name -notmatch '^pythonw?\.exe$' -or $Process.SessionId -ne $Session) { return $false }
    $tokens = @([regex]::Matches([string]$Process.CommandLine, '"[^"]*"|[^\s"]+') | ForEach-Object { $_.Value.Trim('"') })
    if ($tokens -notcontains $WatchPath) { return $false }
    for ($i = 0; $i -lt $tokens.Count - 1; $i++) {
        if ($tokens[$i] -eq '--dir') {
            try { return [IO.Path]::GetFullPath($tokens[$i + 1]).TrimEnd('\').Equals($Root, [StringComparison]::OrdinalIgnoreCase) } catch { return $false }
        }
    }
    return $false
}

$session = (Get-Process -Id $PID).SessionId
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Get-CimInstance Win32_Process | Where-Object { Test-WatchProcess $_ $watch $Dir $session } | Where-Object {
    (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Domain)\$($_.User)" }) -eq $identity
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop }
Start-Sleep 1
Start-Process $pyw -ArgumentList ('-X utf8 "' + $watch + '" --dir "' + $Dir + '"') -WindowStyle Hidden -ErrorAction Stop
Start-Sleep 1
& $py -X utf8 $watch --dir $Dir --once
if ($LASTEXITCODE -ne 0) { throw '提醒程序已启动，但单次状态检查失败。' }
