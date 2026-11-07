# Offline AST/mocked tests. Never execute a real stop/task command.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\stop-all.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($definition in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

$script:fixtureRoot = Join-Path ([IO.Path]::GetPathRoot($PSScriptRoot)) 'adachi-test-install'
$script:passed = 0
function Assert-True($condition, [string]$message) { if (-not $condition) { throw $message } }
function Test-Case([string]$name, [scriptblock]$body) {
    Reset-Test
    & $body
    $script:passed++
    Write-Output ('PASS ' + $name)
}
function New-Component([int]$ProcessId = 0) {
    $owned = if ($ProcessId) { @([pscustomobject]@{pid=$ProcessId;created=10.5}) } else { @() }
    return [pscustomobject]@{owned=$owned;unknown=$false;external=$false;shared=$false;running=[bool]$ProcessId}
}
function New-TaskFixture([string]$Name, [string]$Root = $script:fixtureRoot, [string]$State = 'Running') {
    $entry = switch ($Name) {
        'Dafeiyu-AstrBot' { "$Root\start-astrbot.cmd" }
        'Dafeiyu-QQWatch' { "$Root\tools\qq-watch.cmd" }
        default { "$Root\tools\relogin-qq.ps1" }
    }
    $arguments = '-NoProfile -File "' + $entry + '"'
    if ($Name -in @('Dafeiyu-NapCat','Dafeiyu-SnowLuma','Dafeiyu-Relogin')) { $arguments += ' -Dir "' + $Root + '" -Autostart' }
    return [pscustomobject]@{TaskName=$Name;State=$State;Actions=@([pscustomobject]@{
        Execute="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe";Arguments=$arguments
    })}
}
function Reset-Test {
    $script:tasks = @{}
    $script:events = New-Object Collections.ArrayList
    $script:logs = New-Object Collections.ArrayList
    $script:denied = $false
    $script:queryDenied = $false
    $script:helperFails = $false
    $script:falseSuccess = $false
    $script:state = [pscustomobject]@{protocol='snowluma';relogin=(New-Component);watch=(New-Component);snowluma=(New-Component);voice_bridge=(New-Component);backend=(New-Component);ollama=(New-Component);qq=(New-Component 999)}
}
function Write-StackLog([string]$Root,[string]$Action,[string]$Message,[bool]$DryRun) {
    [void]$script:logs.Add([pscustomobject]@{message=$Message;dry=$DryRun})
}
function Get-StackState([string]$Root) { return $script:state }
function Invoke-StackStop([string]$Root,[string]$Kind,[int]$ProcessId,[double]$Created) {
    [void]$script:events.Add(('process:' + $Kind + ':' + $ProcessId + ':' + $Created))
    if ($script:helperFails) { return [pscustomobject]@{ok=$false;reason='permission_denied'} }
    if (-not $script:falseSuccess) { $script:state.$Kind.owned=@();$script:state.$Kind.running=$false }
    return [pscustomobject]@{ok=$true;reason='exited'}
}
function Get-ScheduledTask {
    [CmdletBinding()]param([string]$TaskName)
    if ($script:queryDenied) { throw 'test query denied' }
    return $script:tasks[$TaskName]
}
function Stop-ScheduledTask {
    [CmdletBinding()]param([string]$TaskName)
    [void]$script:events.Add(('task:' + $TaskName))
    if ($script:denied) { throw 'test access denied' }
    $script:tasks[$TaskName].State='Ready'
}
function Start-Sleep { param([int]$Milliseconds) }

Test-Case 'Windows PowerShell parses BOM source and stop path has no broad kill command' {
    $bytes=[IO.File]::ReadAllBytes($path)
    Assert-True ($bytes.Length -gt 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Source lacks UTF8 BOM'
    $source=[IO.File]::ReadAllText($path)
    Assert-True ($source -notmatch '(?i)\bStop-Process\b|\btaskkill\b|Get-Process\s+-Name') 'A broad termination fallback was introduced'
    Assert-True ($source -match 'if \(-not \$DryRun\).*Enter-StackLock') 'DryRun should not acquire the runtime lock'
}
Test-Case 'Exact task entry is accepted and sibling installation rejected' {
    Assert-True (Test-StackTaskEntry (New-TaskFixture 'Dafeiyu-AstrBot') $script:fixtureRoot 'snowluma') 'Own task rejected'
    Assert-True (-not (Test-StackTaskEntry (New-TaskFixture 'Dafeiyu-AstrBot' ($script:fixtureRoot+'2')) $script:fixtureRoot 'snowluma')) 'Sibling task accepted'
}
Test-Case 'Relogin task requires SnowLuma automatic entry and same Dir' {
    $task=New-TaskFixture 'Dafeiyu-Relogin'
    Assert-True (Test-StackTaskEntry $task $script:fixtureRoot 'snowluma') 'Safe automatic task rejected'
    Assert-True (-not (Test-StackTaskEntry $task $script:fixtureRoot 'napcat')) 'Potential QQ task tree accepted'
    $task.Actions[0].Arguments=$task.Actions[0].Arguments -replace '-Autostart',''
    Assert-True (-not (Test-StackTaskEntry $task $script:fixtureRoot 'snowluma')) 'Manual QQ launcher task accepted'
    $task=New-TaskFixture 'Dafeiyu-Relogin'
    $task.Actions[0].Arguments=$task.Actions[0].Arguments.Replace(('-Dir "'+$script:fixtureRoot+'"'),('-Dir "'+$script:fixtureRoot+'2"'))
    Assert-True (-not (Test-StackTaskEntry $task $script:fixtureRoot 'snowluma')) 'Other target Dir accepted'
}
Test-Case 'Unknown shell and multiple task actions are rejected' {
    $task=New-TaskFixture 'Dafeiyu-QQWatch'
    $task.Actions[0].Execute='C:\other\powershell.exe'
    Assert-True (-not (Test-StackTaskEntry $task $script:fixtureRoot 'snowluma')) 'Unknown executable accepted'
    $task=New-TaskFixture 'Dafeiyu-QQWatch';$task.Actions+=@($task.Actions[0])
    Assert-True (-not (Test-StackTaskEntry $task $script:fixtureRoot 'snowluma')) 'Multiple actions accepted'
}
Test-Case 'DryRun describes owned processes and tasks without stopping either' {
    $script:state.backend=New-Component 101
    $script:tasks['Dafeiyu-AstrBot']=New-TaskFixture 'Dafeiyu-AstrBot'
    $code=Invoke-StackShutdown $script:fixtureRoot $false $true
    Assert-True ($code -eq 0 -and $script:events.Count -eq 0) 'DryRun changed a process or task'
    Assert-True (@($script:logs | Where-Object {-not $_.dry}).Count -eq 0) 'DryRun attempted persistent logging'
}
Test-Case 'Recovery tasks stop before component processes and QQ is never targeted' {
    $script:tasks['Dafeiyu-QQWatch']=New-TaskFixture 'Dafeiyu-QQWatch'
    $script:tasks['Dafeiyu-Relogin']=New-TaskFixture 'Dafeiyu-Relogin'
    $script:state.relogin=New-Component 100;$script:state.watch=New-Component 101
    $script:state.snowluma=New-Component 102;$script:state.voice_bridge=New-Component 103;$script:state.backend=New-Component 104
    $code=Invoke-StackShutdown $script:fixtureRoot $true $false
    Assert-True ($code -eq 0) 'Expected confirmed shutdown'
    Assert-True ($script:events[0] -eq 'task:Dafeiyu-QQWatch' -and $script:events[1] -eq 'task:Dafeiyu-Relogin') 'Processes stopped before recovery tasks'
    Assert-True ($script:events[2] -eq 'process:relogin:100:10.5') 'Manual recovery was not stopped first'
    Assert-True (@($script:events | Where-Object {$_ -match ':qq:|:999:'}).Count -eq 0) 'Desktop QQ was targeted'
}
Test-Case 'Task permission failure aborts dependency shutdown and reports nonzero' {
    $script:tasks['Dafeiyu-Relogin']=New-TaskFixture 'Dafeiyu-Relogin';$script:denied=$true
    $script:state.backend=New-Component 101
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $false $false) -eq 1) 'Task failure was hidden'
    Assert-True (@($script:events | Where-Object {$_ -like 'process:*'}).Count -eq 0) 'Dependencies were killed despite running recovery'
}
Test-Case 'Unverifiable own NapCat task is preserved rather than terminating QQ tree' {
    $task=New-TaskFixture 'Dafeiyu-NapCat';$task.Actions[0].Arguments=('--headless cmd.exe /c "'+$script:fixtureRoot+'\start-napcat.cmd"')
    $script:tasks['Dafeiyu-NapCat']=$task
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $false $false) -eq 1) 'Unsafe task did not block shutdown'
    Assert-True ($script:events.Count -eq 0) 'Unsafe task or process was terminated'
}
Test-Case 'Other installation task is preserved without blocking this installation' {
    $script:tasks['Dafeiyu-AstrBot']=New-TaskFixture 'Dafeiyu-AstrBot' ($script:fixtureRoot+'2')
    $script:state.backend=New-Component 101
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 0) 'Other task blocked own safe processes'
    Assert-True (@($script:events | Where-Object {$_ -like 'task:*'}).Count -eq 0) 'Other task was stopped'
}
Test-Case 'Helper permission failure cannot print final all-stopped success' {
    $script:state.backend=New-Component 101;$script:helperFails=$true
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 1) 'Helper failure was hidden'
    Assert-True (@($script:logs | Where-Object {$_.message -like '已确认本安装*'}).Count -eq 0) 'False final success logged'
}
Test-Case 'Final snapshot detects respawn even when stop helper returned success' {
    $script:state.backend=New-Component 101;$script:falseSuccess=$true
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 1) 'Remaining process not detected'
}
Test-Case 'Unknown watcher identity is reported instead of killing every pythonw' {
    $script:state.watch.unknown=$true;$script:state.watch.running=$true
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 1) 'Unconfirmed watcher was called stopped'
    Assert-True ($script:events.Count -eq 0) 'Unknown watcher was terminated'
}
Test-Case 'Unknown manual recovery prevents stopping dependencies' {
    $script:state.relogin.unknown=$true;$script:state.backend=New-Component 101
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 1) 'Unknown recovery was hidden'
    Assert-True ($script:events.Count -eq 0) 'Dependencies were stopped while recovery remained unknown'
}
Test-Case 'Watcher permission failure prevents dependency shutdown' {
    $script:state.watch=New-Component 100;$script:state.backend=New-Component 101;$script:helperFails=$true
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 1) 'Unstopped watcher was hidden'
    Assert-True (@($script:events | Where-Object {$_ -like 'process:backend:*'}).Count -eq 0) 'Brain stopped before guard was quiet'
}
Test-Case 'KeepOllama preserves own server while stopping the brain' {
    $script:state.backend=New-Component 101;$script:state.ollama=New-Component 102
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 0) 'KeepOllama failed'
    Assert-True (@($script:events | Where-Object {$_ -like 'process:ollama:*'}).Count -eq 0) 'Ollama was terminated'
}
Test-Case 'External and shared Ollama are preserved by default' {
    foreach ($field in @('external','shared','unknown')) {
        Reset-Test;$script:state.ollama=New-Component 102;$script:state.ollama.$field=$true
        Assert-True ((Invoke-StackShutdown $script:fixtureRoot $false $false) -eq 0) ('Preservation failed: ' + $field)
        Assert-True ($script:events.Count -eq 0) ('Unsafe Ollama stopped: ' + $field)
    }
}
Test-Case 'Task query denial does not fall back to port or process-name killing' {
    $script:queryDenied=$true;$script:state.backend=New-Component 101
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $false $false) -eq 1) 'Unreadable tasks accepted'
    Assert-True ($script:events.Count -eq 0) 'Blind process termination occurred'
}
Test-Case 'Queued recovery task is cancelled before it can launch dependencies' {
    $script:tasks['Dafeiyu-Relogin']=New-TaskFixture 'Dafeiyu-Relogin' $script:fixtureRoot 'Queued'
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 0) 'Queued recovery was not stopped'
    Assert-True ($script:events[0] -eq 'task:Dafeiyu-Relogin') 'Queued recovery was ignored'
}
Test-Case 'Renamed SnowLuma autostart task is cancelled before process shutdown' {
    $script:tasks['Dafeiyu-SnowLuma']=New-TaskFixture 'Dafeiyu-SnowLuma' $script:fixtureRoot 'Queued'
    $script:state.backend=New-Component 104
    Assert-True ((Invoke-StackShutdown $script:fixtureRoot $true $false) -eq 0) 'SnowLuma autostart not stopped'
    Assert-True ($script:events[0] -eq 'task:Dafeiyu-SnowLuma') 'New task name was missed'
}
Write-Output ('RESULT ' + $script:passed + ' offline shutdown tests passed; no real processes or tasks changed')
