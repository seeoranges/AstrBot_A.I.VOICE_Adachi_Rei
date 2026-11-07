$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$path = Join-Path $root 'tools\relogin-qq.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
$defs=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($def in $defs){. ([scriptblock]::Create($def.Extent.Text))}
$script:passed=0
function Assert($value,[string]$text){if(-not $value){throw $text}}
function Case([string]$name,[scriptblock]$body){& $body;$script:passed++;Write-Output ('PASS '+$name)}
function Get-QQState{return $script:probe}
function Boot-State([string]$State,[string]$Text){$script:states+=,$State}
function Start-Quiet([string]$File){$script:launches++}
function Start-Sleep{param([int]$Seconds)}
function Get-CimInstance{return @()}
function Get-UserStartupIdentity{return @('test\user')}
function QrTime{$script:copies++;return [datetime]::MinValue}
function Write-ScanPage{$script:pages++}
$Dir=Join-Path $root ('.relogin-test-'+[guid]::NewGuid().ToString('N'))
$resolved=[IO.Path]::GetFullPath($Dir)
Assert ($resolved.StartsWith([IO.Path]::GetFullPath($root)+'\',[StringComparison]::OrdinalIgnoreCase)) 'Test path escaped workspace'
New-Item -ItemType Directory -Path $Dir | Out-Null
$shell=[pscustomobject]@{FullName=(Join-Path $Dir 'shell')}
New-Item -ItemType Directory -Path $shell.FullName | Out-Null
[IO.File]::WriteAllText((Join-Path $Dir 'start-napcat.cmd'),'mock')
[IO.File]::WriteAllText((Join-Path $shell.FullName 'NapCatWinBootMain.exe'),'mock')
function Reset-Test {
    $script:launches=0;$script:copies=0;$script:pages=0;$script:states=@();$script:automaticRestartUsed=$false
    $script:probe=[pscustomobject]@{state='offline';needs_scan=$false;automatic_retry_wait=0;login_info=$null;log_found=$true}
}
try {
Case 'PowerShell 5.1 source parses and has UTF8 BOM' {
    $b=[IO.File]::ReadAllBytes($path)
    Assert ($b[0]-eq239 -and $b[1]-eq187 -and $b[2]-eq191) 'PS5.1 source requires UTF8 BOM'
}
Case 'DryRun returns before elevation mutex and state writes' {
    $source=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $dry=$source.IndexOf('if ($DryRun)')
    Assert ($dry -gt 0 -and $dry -lt $source.IndexOf('$proto =')) 'DryRun must return before elevation decisions'
    Assert ($dry -lt $source.IndexOf('$mutex =')) 'DryRun must return before acquiring mutex'
}
Case 'Online rehearsal reports no restart' {
    Reset-Test;$Autostart=$true;$script:probe.state='online'
    $plan=Get-ReloginPlan
    Assert ($plan.state-eq'online' -and -not$plan.would_restart) 'Healthy probe should exit'
    Assert ($script:states.Count-eq0 -and $script:launches-eq0) 'Plan has side effects'
}
Case 'Expired-login automatic rehearsal waits for person' {
    Reset-Test;$Autostart=$true;$script:probe.needs_scan=$true
    $plan=Get-ReloginPlan
    Assert (-not$plan.would_restart -and $plan.needs_scan) 'Expired login must wait for person'
}
Case 'Cooldown automatic rehearsal does not restart' {
    Reset-Test;$Autostart=$true;$script:probe.automatic_retry_wait=600
    Assert (-not(Get-ReloginPlan).would_restart) 'Cooldown must block automatic login'
}
Case 'Unknown rehearsal stops safely' {
    Reset-Test;$Autostart=$true;$script:probe.state='unknown'
    Assert (-not(Get-ReloginPlan).would_restart) 'Unknown probe cannot restart'
}
Case 'Manual rehearsal permits one explicit login' {
    Reset-Test;$Autostart=$false;$script:probe.needs_scan=$true;$script:probe.automatic_retry_wait=600
    Assert ((Get-ReloginPlan).would_restart) 'Explicit manual login should remain available'
}
Case 'Expired automatic login preserves process and updates stable scan page' {
    Reset-Test;$Autostart=$true;$script:probe.needs_scan=$true
    Assert (-not(Restart-NapCat)) 'Expired auto login should not restart'
    Assert ($script:launches-eq0 -and $script:copies-eq1 -and $script:pages-eq1) 'Expected stable page refresh without launch'
    Assert ($script:states -contains 'scan-required') 'Expected waiting state'
}
Case 'Cooldown blocks actual automatic launch' {
    Reset-Test;$Autostart=$true;$script:probe.automatic_retry_wait=600
    Assert (-not(Restart-NapCat)) 'Cooldown should skip restart'
    Assert ($script:launches-eq0) 'Cooldown launched a process'
}
Case 'Automatic restart records one actual attempt and cannot repeat in same task' {
    Reset-Test;$Autostart=$true
    Assert (Restart-NapCat) 'Expected one allowed automatic restart'
    Assert ($script:launches-eq1) 'Expected one launch'
    $attempt=Join-Path $Dir 'logs\qq-relogin-attempt.json'
    Assert (Test-Path -LiteralPath $attempt) 'Actual restart must persist cooldown'
    $entry=Get-Content -LiteralPath $attempt -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($entry.at-gt0 -and $entry.automatic) 'Invalid cooldown metadata'
    Assert (-not(Restart-NapCat)) 'Second automatic restart in one task forbidden'
    Assert ($script:launches-eq1) 'Second launch happened'
}
Case 'Manual login is not blocked by automatic cooldown' {
    Reset-Test;$Autostart=$false;$script:probe.needs_scan=$true;$script:probe.automatic_retry_wait=600
    Assert (Restart-NapCat) 'Manual retry should be explicit and available'
    Assert ($script:launches-eq1) 'Expected one manual launch'
}
Case 'No retry loop and no forced scan refresh restart remain' {
    $source=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    Assert (-not$source.Contains('while (-not $readyForScan)')) 'Infinite login loop remains'
    Assert (-not$source.Contains('Start-Sleep 300')) 'Five minute restart loop remains'
    $scan=$source.Substring($source.LastIndexOf('$deadline = (Get-Date).AddMinutes(10)'))
    Assert (-not$scan.Contains('Restart-NapCat')) 'Scanning phase still forces a restart'
}
} finally {
    if([IO.Path]::GetFullPath($Dir).StartsWith([IO.Path]::GetFullPath($root)+'\',[StringComparison]::OrdinalIgnoreCase)){
        Remove-Item -LiteralPath $Dir -Recurse -Force
    }
}
Write-Output ('RESULT '+$script:passed+' PowerShell rehearsal/retry tests passed; no real QQ, task or notification actions')
