$ErrorActionPreference = 'Stop'

function Get-StackRoot([string]$Dir) {
    $root = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
    if ($root -match '["\r\n]' -or -not (Test-Path -LiteralPath $root -PathType Container)) { throw '安装目录无效。' }
    return $root
}

function Enter-StackLock([string]$Dir, [int]$WaitMs = 0, [ValidateSet('DafeiyuLifecycle','DafeiyuQQ')][string]$Purpose = 'DafeiyuLifecycle') {
    $root = Get-StackRoot $Dir
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $tag = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))) -replace '-', '').Substring(0,24) } finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, "Local\$Purpose-$tag")
    try { $held = $mutex.WaitOne($WaitMs) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { $mutex.Dispose(); throw '本目录的启动或关闭正在进行，请等它结束。' }
    return $mutex
}

function Exit-StackLock($Mutex) {
    if ($null -ne $Mutex) { try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
}

function Find-StackPython([string]$Dir) {
    $path = Join-Path $Dir 'uv\tools\astrbot\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '缺少本安装的 Python，未操作进程。' }
    return $path
}

function Get-StackState([string]$Dir) {
    $py = Find-StackPython $Dir
    $helper = Join-Path $PSScriptRoot 'stack_state.py'
    $raw = & $py -X utf8 -B $helper --dir $Dir 2>$null
    if ($LASTEXITCODE -ne 0) { throw '进程归属探针失败，未根据端口猜测状态。' }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw '进程归属探针返回格式错误。' }
}

function Invoke-StackStop([string]$Dir, [string]$Kind, [int]$ProcessId, [double]$Created) {
    $py = Find-StackPython $Dir
    $helper = Join-Path $PSScriptRoot 'stack_state.py'
    $birth = $Created.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    $raw = & $py -X utf8 -B $helper --dir $Dir --stop $Kind --pid $ProcessId --created $birth 2>$null
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return [pscustomobject]@{ok=$false;reason='invalid_stop_response'} }
}

function Write-StackLog([string]$Dir, [string]$Action, [string]$Message, [bool]$DryRun = $false) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message
    Write-Host $line
    if ($DryRun) { return }
    if ($Action -notin @('start','stop')) { throw 'Unknown log action' }
    $folder = Join-Path $Dir 'logs'
    $path = Join-Path $folder ($Action + '-all.log')
    try {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1048576) {
            $old = $path + '.1'
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
            Move-Item -LiteralPath $path -Destination $old
        }
        $writer = New-Object IO.StreamWriter($path, $true, (New-Object Text.UTF8Encoding($true)))
        try { $writer.WriteLine($line) } finally { $writer.Dispose() }
    } catch { Write-Warning '状态已显示，但本次日志无法写入。' }
}

function Test-StackTaskOwner($Task, [string]$Dir, [string]$Name = '') {
    if ($null -eq $Task) { return $false }
    if ($Name) {
        if (@($Task.Actions).Count -ne 1) { return $false }
        $entry = switch($Name) {
            'Dafeiyu-AstrBot' { Join-Path $Dir 'start-astrbot.cmd' }
            'Dafeiyu-QQWatch' { Join-Path $Dir 'tools\qq-watch.cmd' }
            'Dafeiyu-Relogin' { Join-Path $Dir 'tools\relogin-qq.ps1' }
            default { return $false }
        }
        $action = $Task.Actions[0]
        if (([string]$action.Execute).Equals($entry,[StringComparison]::OrdinalIgnoreCase)) { return $true }
        $shells = @("$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", "$env:SystemRoot\System32\conhost.exe", "$env:SystemRoot\System32\cmd.exe")
        if ($shells -notcontains [string]$action.Execute) { return $false }
        $pattern = '(?:"|\x27)' + [regex]::Escape($entry) + '(?:"|\x27)'
        if (-not [regex]::IsMatch([string]$action.Arguments,$pattern,'IgnoreCase')) { return $false }
        if ($Name -eq 'Dafeiyu-Relogin') {
            $match = [regex]::Match([string]$action.Arguments, '(?i)(?:^|\s)-Dir\s+(?:"([^"\r\n]+)"|\x27([^\x27\r\n]+)\x27|([^\s]+))')
            if ($match.Success) {
                $target = @($match.Groups[1].Value,$match.Groups[2].Value,$match.Groups[3].Value) | Where-Object {$_} | Select-Object -First 1
                try { if (-not (Get-StackRoot $target).Equals((Get-StackRoot $Dir),[StringComparison]::OrdinalIgnoreCase)) { return $false } } catch { return $false }
            }
        }
        return $true
    }
    $prefix = (Get-StackRoot $Dir) + '\'
    foreach ($action in $Task.Actions) {
        if (([string]$action.Arguments).IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            ([string]$action.Execute).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Start-StackTask([string]$Name, [string]$Dir) {
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $false }
    if (-not (Test-StackTaskOwner $task $Dir $Name)) { throw '同名计划任务的启动入口无法核验，未启动。' }
    if ($task.State -eq 'Disabled') { throw '本安装的启动任务被禁用，请先修复任务。' }
    if ($task.State -notin @('Running','Queued')) {
        try { Start-ScheduledTask -TaskName $Name -ErrorAction Stop } catch { throw '当前权限无法启动本安装的计划任务。' }
    }
    return $true
}

function Start-StackCommand([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw '缺少组件启动脚本。' }
    $command = "& '" + $File.Replace("'", "''") + "'; exit `$LASTEXITCODE"
    Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "' + $command + '"') -WindowStyle Hidden -ErrorAction Stop | Out-Null
}

function Wait-StackState([string]$Dir, [scriptblock]$Predicate, [int]$Seconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $state = Get-StackState $Dir
        if (& $Predicate $state) { return $state }
        if ($timer.Elapsed.TotalSeconds -ge $Seconds) { return $state }
        Start-Sleep -Milliseconds 800
    } while ($true)
}

function Start-StackOllama([string]$Dir) {
    $exe = Join-Path $Dir 'Ollama\ollama.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw '本安装没有找到 Ollama 服务程序。' }
    $names = @('OLLAMA_MODELS','OLLAMA_KEEP_ALIVE')
    $previous = @{}
    try {
        foreach ($name in $names) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
            $value = [Environment]::GetEnvironmentVariable($name,'User')
            if ($value) { [Environment]::SetEnvironmentVariable($name,$value,'Process') }
        }
        if (-not $env:OLLAMA_MODELS -and (Test-Path -LiteralPath (Join-Path $Dir 'ollama-models'))) { $env:OLLAMA_MODELS = Join-Path $Dir 'ollama-models' }
        Start-Process -FilePath $exe -ArgumentList 'serve' -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') } }
}

function Get-StackSnowPassword([string]$Dir) {
    $path = Join-Path $Dir 'private\snowluma-webui.txt'
    try { $password = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF).TrimEnd([char[]]"`r`n") } catch { throw 'SnowLuma 密码文件缺失或不可读。' }
    if ([string]::IsNullOrWhiteSpace($password) -or $password -match '[\r\n]') { throw 'SnowLuma 密码文件应为一行有效内容。' }
    return $password
}

function Start-StackSnowLuma([string]$Dir) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'SnowLuma 应与桌面 QQ 同为普通权限，请普通双击一键启动。' }
    $password = Get-StackSnowPassword $Dir
    $folder = Join-Path $Dir 'SnowLuma'
    $node = Join-Path $folder 'node.exe'
    $entry = Join-Path $folder 'index.mjs'
    if (-not (Test-Path -LiteralPath $node) -or -not (Test-Path -LiteralPath $entry)) { throw 'SnowLuma 程序不完整。' }
    $launcher = Join-Path $Dir 'start-snowluma.cmd'
    $configured = [IO.File]::ReadAllText($launcher)
    $names = @('SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD','SNOWLUMA_HOOK_AUTOLOAD','SNOWLUMA_ACCEPT_EULA','SNOWLUMA_ACCEPT_PRIVACY')
    $previous = @{}
    try {
        foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
        $env:SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD = $password
        foreach ($name in $names | Where-Object { $_ -ne 'SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD' }) {
            $match = [regex]::Match($configured, '(?im)^\s*set\s+"?' + [regex]::Escape($name) + '=([01])"?\s*$')
            [Environment]::SetEnvironmentVariable($name, $(if($match.Success){$match.Groups[1].Value}else{$null}), 'Process')
        }
        $log = Join-Path $folder 'snowluma-run.log'
        $command = '"' + $node + '" "' + $entry + '" >> "' + $log + '" 2>&1'
        Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /s /c "' + $command + '"') -WorkingDirectory $folder -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
        $password = $null
    }
}

function Start-StackSnowLumaGuarded([string]$Dir) {
    $gate = $null
    try {
        try { $gate = Enter-StackLock $Dir 0 'DafeiyuQQ' } catch { return $false }
        $state = Get-StackState $Dir
        if ($state.snowluma.running) { return $true }
        if ($state.snowluma.unknown -or $state.snowluma.port_conflict) { throw 'SnowLuma 归属不明，未启动。' }
        Start-StackSnowLuma $Dir
        $state = Wait-StackState $Dir { param($s) $s.snowluma.running } 10
        return [bool]$state.snowluma.running
    } finally { if($gate){Exit-StackLock $gate} }
}
