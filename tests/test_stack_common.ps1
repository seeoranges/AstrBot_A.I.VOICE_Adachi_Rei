$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$tokens=$null;$errors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'tools\stack_common.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Invalid source'}
foreach($definition in $tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($definition.Extent.Text))}
$script:passed=0
function Assert($condition,$message){if(-not $condition){throw $message}}
function Case($name,[scriptblock]$body){& $body;$script:passed++;Write-Output ('PASS '+$name)}
function Get-ScheduledTask { [CmdletBinding()]param($TaskName) return $script:task }
function Start-ScheduledTask { [CmdletBinding()]param($TaskName) $script:starts++ }
$fixture=Join-Path $root ('test-fixtures\common-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
function Task([string]$State,[string]$Entry) {
 return [pscustomobject]@{State=$State;Actions=@([pscustomobject]@{Execute="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe";Arguments=('-NoProfile -File "'+$Entry+'"')})}
}
try {
 Case 'Queued startup task is not launched again' {
  $script:starts=0;$script:task=Task 'Queued' (Join-Path $fixture 'start-astrbot.cmd')
  Assert (Start-StackTask 'Dafeiyu-AstrBot' $fixture) 'Own queued task rejected'
  Assert ($script:starts -eq 0) 'Queued task restarted'
 }
 Case 'Ready owned task is launched once' {
  $script:starts=0;$script:task=Task 'Ready' (Join-Path $fixture 'start-astrbot.cmd')
  Assert (Start-StackTask 'Dafeiyu-AstrBot' $fixture) 'Own ready task rejected'
  Assert ($script:starts -eq 1) 'Expected one launch'
 }
 Case 'Mentioning root with wrong task entry is rejected' {
  $script:starts=0;$script:task=Task 'Ready' (Join-Path $fixture 'tools\other.cmd')
  $failed=$false;try{[void](Start-StackTask 'Dafeiyu-AstrBot' $fixture)}catch{$failed=$true}
  Assert ($failed -and $script:starts -eq 0) 'Wrong task entry started'
 }
 Case 'Relogin cannot target sibling Dir with same script entry' {
  $script:starts=0;$script:task=Task 'Ready' (Join-Path $fixture 'tools\relogin-qq.ps1')
  $script:task.Actions[0].Arguments += ' -Dir "'+$fixture+'-other" -Autostart'
  $failed=$false;try{[void](Start-StackTask 'Dafeiyu-Relogin' $fixture)}catch{$failed=$true}
  Assert ($failed -and $script:starts -eq 0) 'Sibling relogin task started'
 }
 Case 'Unknown shell cannot be used as an owned task' {
  $script:starts=0;$script:task=Task 'Ready' (Join-Path $fixture 'start-astrbot.cmd')
  $script:task.Actions[0].Execute='C:\other\powershell.exe'
  $failed=$false;try{[void](Start-StackTask 'Dafeiyu-AstrBot' $fixture)}catch{$failed=$true}
  Assert ($failed -and $script:starts -eq 0) 'Unknown executable launched'
 }
 function Enter-StackLock($Dir,$WaitMs,$Purpose){$script:purpose=$Purpose;if($script:busy){throw 'busy'};return [pscustomobject]@{held=$true}}
 function Exit-StackLock($mutex){$script:released++}
 function Get-StackState($Dir){return $script:state}
 function Wait-StackState($Dir,$Predicate,$Seconds){return $script:state}
 function Start-StackSnowLuma($Dir){$script:snowStarts++;$script:state.snowluma.running=$true}
 Case 'SnowLuma uses existing QQ mutex and waits for process ownership before release' {
  $script:busy=$false;$script:released=0;$script:snowStarts=0
  $script:state=[pscustomobject]@{snowluma=[pscustomobject]@{running=$false;unknown=$false;port_conflict=$false}}
  Assert (Start-StackSnowLumaGuarded $fixture) 'Expected startup ownership'
  Assert ($script:purpose -eq 'DafeiyuQQ' -and $script:snowStarts -eq 1 -and $script:released -eq 1) 'Gate was not shared or released'
 }
 Case 'Busy relogin gate prevents a parallel SnowLuma launch' {
  $script:busy=$true;$script:snowStarts=0;$script:released=0
  Assert (-not (Start-StackSnowLumaGuarded $fixture)) 'Busy gate accepted'
  Assert ($script:snowStarts -eq 0 -and $script:released -eq 0) 'Busy gate modified bridge'
 }
 Case 'Process discovered after acquiring gate is reused' {
  $script:busy=$false;$script:snowStarts=0;$script:released=0;$script:state.snowluma.running=$true
  Assert (Start-StackSnowLumaGuarded $fixture) 'Existing process not reused'
  Assert ($script:snowStarts -eq 0 -and $script:released -eq 1) 'Duplicate bridge launched'
 }
} finally {
 $resolved=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath((Join-Path $root 'test-fixtures'))+'\'
 if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup path'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output ('RESULT '+$script:passed+' shared lifecycle tests passed; no tasks or programs started')
