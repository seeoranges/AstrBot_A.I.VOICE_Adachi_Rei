param(
    [string]$Dir = 'E:\dafeiyu',
    [switch]$KeepOllama,
    [switch]$DryRun
)
# 只停止本安装中可核验的组件；不以通用进程名或端口授权停止。
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\stack_common.ps1"
$Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\')

function Test-StackTaskEntry($Task, [string]$Root, [string]$Protocol) {
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    $action = $actions[0]
    $execute = [string]$action.Execute
    $arguments = [string]$action.Arguments
    $system = $env:SystemRoot.TrimEnd('\')
    $shells = @(
        "$system\System32\WindowsPowerShell\v1.0\powershell.exe",
        "$system\System32\conhost.exe", "$system\System32\cmd.exe"
    )
    $entry = switch ([string]$Task.TaskName) {
        'Dafeiyu-AstrBot' { Join-Path $Root 'start-astrbot.cmd' }
        'Dafeiyu-QQWatch' { Join-Path $Root 'tools\qq-watch.cmd' }
        'Dafeiyu-NapCat' { Join-Path $Root 'tools\relogin-qq.ps1' }
        'Dafeiyu-SnowLuma' { Join-Path $Root 'tools\relogin-qq.ps1' }
        'Dafeiyu-Relogin' { Join-Path $Root 'tools\relogin-qq.ps1' }
        default { return $false }
    }
    $direct = $execute.Equals($entry, [StringComparison]::OrdinalIgnoreCase)
    if (-not $direct -and -not ($shells -contains $execute)) { return $false }
    # Exact quoted entry token; merely mentioning a sibling directory is not ownership.
    $quotedEntry = '(?:"|\x27)' + [regex]::Escape($entry) + '(?:"|\x27)'
    if (-not $direct -and -not [regex]::IsMatch($arguments, $quotedEntry, 'IgnoreCase')) { return $false }
    if ([string]$Task.TaskName -in @('Dafeiyu-NapCat', 'Dafeiyu-SnowLuma', 'Dafeiyu-Relogin')) {
        # NapCat/relogin can otherwise have QQ descendants. Never terminate those
        # task trees while promising to preserve the user's desktop QQ.
        if ($Protocol -ne 'snowluma' -or $arguments -notmatch '(?i)(?:^|\s)-Autostart(?:\s|$)') { return $false }
        $dirMatch = [regex]::Match($arguments, '(?i)(?:^|\s)-Dir\s+(?:"([^"\r\n]+)"|\x27([^\x27\r\n]+)\x27|([^\s]+))')
        if ($dirMatch.Success) {
            $value = @($dirMatch.Groups[1].Value, $dirMatch.Groups[2].Value, $dirMatch.Groups[3].Value) | Where-Object { $_ } | Select-Object -First 1
            try { if (-not ([IO.Path]::GetFullPath($value).TrimEnd('\')).Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { return $false } }
            catch { return $false }
        }
    }
    return $true
}

function Stop-StackTasks([string]$Root, [string]$Protocol, [bool]$PlanOnly) {
    $ok = $true
    foreach ($name in @('Dafeiyu-QQWatch', 'Dafeiyu-Relogin', 'Dafeiyu-SnowLuma', 'Dafeiyu-NapCat', 'Dafeiyu-AstrBot')) {
        try { $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop }
        catch {
            if ($_.FullyQualifiedErrorId -match 'NotFound|ObjectNotFound') { continue }
            Write-StackLog $Root 'stop' ('无法读取任务 {0}；未猜测其进程归属。' -f $name) $PlanOnly
            $ok = $false
            continue
        }
        if (-not $task -or [string]$task.State -notin @('Running','Queued')) { continue }
        if (-not (Test-StackTaskEntry $task $Root $Protocol)) {
            $belongsHere = @($task.Actions | Where-Object {
                ([string]$_.Execute).StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase) -or
                ([string]$_.Arguments).IndexOf($Root + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0
            }).Count -gt 0
            if ($belongsHere) {
                Write-StackLog $Root 'stop' ('任务 {0} 的动作无法安全核验，保留并中止其余停止。' -f $name) $PlanOnly
                $ok = $false
            } else { Write-StackLog $Root 'stop' ('保留其他安装的任务 {0}。' -f $name) $PlanOnly }
            continue
        }
        if ($PlanOnly) { Write-StackLog $Root 'stop' ('演练：将停止本安装正在运行的任务 {0}。' -f $name) $true; continue }
        try {
            Stop-ScheduledTask -TaskName $name -ErrorAction Stop | Out-Null
            $timer = [Diagnostics.Stopwatch]::StartNew()
            do {
                $current = Get-ScheduledTask -TaskName $name -ErrorAction Stop
                if ([string]$current.State -notin @('Running','Queued')) { break }
                Start-Sleep -Milliseconds 200
            } while ($timer.Elapsed.TotalSeconds -lt 5)
            if ([string]$current.State -in @('Running','Queued')) { throw 'Task is still running or queued' }
            Write-StackLog $Root 'stop' ('已停止本安装任务 {0}。' -f $name) $false
        } catch {
            Write-StackLog $Root 'stop' ('任务 {0} 未确认停止，可能需要该任务的运行权限。' -f $name) $false
            $ok = $false
        }
    }
    return $ok
}

function Invoke-StackShutdown([string]$Root, [bool]$PreserveOllama, [bool]$PlanOnly) {
    Write-StackLog $Root 'stop' '================ 关闭本安装组件 ================' $PlanOnly
    $before = Get-StackState $Root
    if (-not $before) { throw '没有获得可靠的组件归属快照。' }
    # Stop automatic recovery before taking down its dependencies, so it cannot
    # bring the stack back during the shutdown. No long-term task is disabled.
    if (-not (Stop-StackTasks $Root ([string]$before.protocol) $PlanOnly)) {
        Write-StackLog $Root 'stop' '无法确认恢复/启动任务已停止；为避免反复拉起，未继续停止组件。' $PlanOnly
        return 1
    }
    $failed = $false
    $kinds = @('relogin', 'watch', 'snowluma', 'voice_bridge', 'backend')
    if (-not $PreserveOllama) { $kinds += 'ollama' }
    foreach ($kind in $kinds) {
        $state = Get-StackState $Root
        $component = $state.$kind
        if ($null -eq $component) { continue }
        if ($kind -eq 'ollama' -and ($component.external -or $component.shared -or $component.unknown)) {
            Write-StackLog $Root 'stop' 'Ollama：外部、共享或归属不明，已保留。' $PlanOnly
            continue
        }
        $owned = @($component.owned | Where-Object { $null -ne $_ })
        if ($PlanOnly) {
            Write-StackLog $Root 'stop' ('演练：{0} 已核验 {1} 个进程；只对这些身份重新核验后停止。' -f $kind, $owned.Count) $true
            if ($component.unknown) { $failed = $true }
            continue
        }
        foreach ($identity in $owned) {
            $result = Invoke-StackStop $Root $kind ([int]$identity.pid) ([double]$identity.created)
            if ($result.ok -eq $true) {
                Write-StackLog $Root 'stop' ('{0}：已确认进程 {1} 退出。' -f $kind, $identity.pid) $false
            } else {
                Write-StackLog $Root 'stop' ('{0}：进程 {1} 未确认停止（{2}），未采用宽泛强杀。' -f $kind, $identity.pid, $result.reason) $false
                $failed = $true
            }
        }
        if ($component.unknown) {
            Write-StackLog $Root 'stop' ('{0}：存在无法核验的候选，保留并报告未完全停止。' -f $kind) $false
            $failed = $true
        }
        if ($kind -in @('relogin', 'watch')) {
            $guardState = (Get-StackState $Root).$kind
            if ($guardState.unknown -or @($guardState.owned | Where-Object { $null -ne $_ }).Count -gt 0) {
                Write-StackLog $Root 'stop' ('{0} 尚未确认退出，为避免恢复动作反弹，未继续停止依赖组件。' -f $kind) $false
                return 1
            }
        }
    }
    if ($PreserveOllama) { Write-StackLog $Root 'stop' 'Ollama：按 -KeepOllama 保留。' $PlanOnly }
    if ($PlanOnly) {
        Write-StackLog $Root 'stop' '演练完成；没有停止进程、任务或写入状态/日志文件。' $true
        return [int]$failed
    }
    $after = Get-StackState $Root
    foreach ($kind in $kinds) {
        $component = $after.$kind
        if ($null -eq $component) { continue }
        if ($kind -eq 'ollama' -and ($component.external -or $component.shared -or $component.unknown)) { continue }
        if (@($component.owned | Where-Object { $null -ne $_ }).Count -gt 0 -or $component.unknown) {
            Write-StackLog $Root 'stop' ('{0}：最终回读仍有本安装进程或归属无法确认；请检查权限或外部自启。' -f $kind) $false
            $failed = $true
        }
    }
    if ($failed) { Write-StackLog $Root 'stop' '未完全停止。QQ 未列入停止目标。' $false; return 1 }
    Write-StackLog $Root 'stop' '已确认本安装的可停止组件退出；QQ 未列入停止目标。' $false
    return 0
}

$guard = $null
$exitCode = 1
try {
    if (-not $DryRun) { $guard = Enter-StackLock $Dir 0 }
    $exitCode = Invoke-StackShutdown $Dir ([bool]$KeepOllama) ([bool]$DryRun)
} catch {
    Write-StackLog $Dir 'stop' ('关闭未完成：{0}' -f $_.Exception.Message) ([bool]$DryRun)
    $exitCode = 1
} finally {
    if ($null -ne $guard) { Exit-StackLock $guard }
}
exit $exitCode
