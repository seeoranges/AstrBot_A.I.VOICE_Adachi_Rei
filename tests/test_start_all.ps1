$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
foreach($file in @('tools\stack_common.ps1','tools\start-all.ps1')) {
    $tokens=$null;$errors=$null
    $tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Source failed PowerShell parsing'}
    foreach($definition in $tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$script:passed=0
function Assert($condition,$message){if(-not $condition){throw $message}}
function Case($name,[scriptblock]$body){& $body;$script:passed++;Write-Output ('PASS '+$name)}
function FreshState {
    return [pscustomobject]@{
        protocol='snowluma'
        backend=[pscustomobject]@{state='up';owned=@(@{pid=10;created=10});ws_ready=$true;online=$true;ambiguous=$false;port_conflict=$false}
        ollama=[pscustomobject]@{api_ready=$true;model_available=$true;running=$true;unknown=$false;port_conflict=$false}
        snowluma=[pscustomobject]@{running=$true;ready=$true;unknown=$false;port_conflict=$false}
        qq=[pscustomobject]@{running=$true;unknown=$false;owner_login=$null}
        watch=[pscustomobject]@{running=$true;unknown=$false}
    }
}
$script:events=New-Object Collections.Generic.List[string]
function Write-StackLog($Dir,$Action,$Message,$DryRun=$false){$script:events.Add([string]$Message)}
function Get-StackState($Dir){return $script:state}
function Wait-StackState($Dir,$Predicate,$Seconds){return $script:state}
function Get-StackPluginHealth($Dir){return $script:health}
function Start-StackTask($Name,$Dir){$script:events.Add('task:'+ $Name);return $true}
function Start-StackCommand($File){$script:events.Add('command')}
function Start-StackOllama($Dir){$script:events.Add('ollama-serve')}
function Start-StackSnowLumaGuarded($Dir){$script:events.Add('snowluma');return $true}
function Start-Process {param($FilePath,$ArgumentList,$ErrorAction) $script:events.Add('qq-open')}
function Reset-Test {$script:events.Clear();$script:state=FreshState;$script:health=[pscustomobject]@{ok=$true;features=@{voice=$true;memory=$true;memes=$true}}}

Case 'Already ready components are not launched again' {
    Reset-Test
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 0) 'Expected ready'
    Assert (-not @($events|Where-Object{$_ -match '^task:|^command$|^ollama-serve$|^snowluma$|^qq-open$'}).Count) 'Duplicate launch occurred'
}
Case 'Starting brain with missing WS is waited for without another launch' {
    Reset-Test;$state.backend.state='starting';$state.backend.ws_ready=$false
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 1) 'Partial brain should fail readiness'
    Assert (-not @($events|Where-Object{$_ -eq 'task:Dafeiyu-AstrBot' -or $_ -eq 'command'}).Count) 'Duplicate brain launched'
}
Case 'Unrelated backend listener never authorizes a new launch or success' {
    Reset-Test;$state.backend.port_conflict=$true
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 1) 'Conflict should fail'
    Assert (-not @($events|Where-Object{$_ -eq 'task:Dafeiyu-AstrBot'}).Count) 'Conflict launched brain'
}
Case 'Failed brain never starts a new transport bridge' {
    Reset-Test;$state.backend.state='starting';$state.backend.ws_ready=$false;$state.snowluma.running=$false;$state.snowluma.ready=$false
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 1) 'Incomplete backend should fail'
    Assert (-not $events.Contains('snowluma')) 'Bridge started before backend readiness'
    $state.protocol='napcat';$state.backend.online=$false
    [void](Invoke-StackStartup 'E:\dafeiyu' 1 1 1)
    Assert (-not $events.Contains('task:Dafeiyu-Relogin')) 'Relogin started before backend readiness'
}
Case 'Existing Ollama without the model is not started twice' {
    Reset-Test;$state.ollama.model_available=$false
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 1) 'Missing model should be visible'
    Assert (-not $events.Contains('ollama-serve')) 'Existing service restarted'
}
Case 'An occupied unrelated Ollama port does not launch a second server' {
    Reset-Test;$state.ollama.api_ready=$false;$state.ollama.port_conflict=$true
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 1) 'Conflict should fail'
    Assert (-not $events.Contains('ollama-serve')) 'Port conflict ignored'
}
Case 'Failed plugin registry prevents all-ready report despite open ports' {
    Reset-Test;$health.ok=$false
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 1) 'Plugins failure should be visible'
}
Case 'Missing QQ transport prevents all-ready report despite live components' {
    Reset-Test;$state.backend.online=$false
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 1) 'Disconnected QQ falsely ready'
}
Case 'Unknown QQ process does not open another desktop QQ' {
    Reset-Test;$state.qq.running=$false;$state.qq.unknown=$true
    Assert ((Invoke-StackStartup 'E:\dafeiyu' 1 1 1) -eq 1) 'Unknown QQ should fail'
    Assert (-not $events.Contains('qq-open')) 'Unknown QQ duplicated'
}
Case 'Other protocol uses guarded task and does not start SnowLuma' {
    Reset-Test;$state.protocol='napcat';$state.backend.online=$false
    [void](Invoke-StackStartup 'E:\dafeiyu' 1 1 1)
    Assert ($events.Contains('task:Dafeiyu-Relogin')) 'Expected guarded relogin'
    Assert (-not $events.Contains('snowluma') -and -not $events.Contains('qq-open')) 'Wrong protocol started desktop stack'
}

# Test the production password/log implementations separately using workspace-only files.
$common=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'tools\stack_common.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Get-StackSnowPassword','Write-StackLog')) {
    $definition=$common.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$fixture=Join-Path $root ('test-fixtures\start-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'private') -Force | Out-Null
try {
    Case 'Password BOM and trailing newline are normalized without printing' {
        [IO.File]::WriteAllText((Join-Path $fixture 'private\snowluma-webui.txt'),"dummy-value`r`n",(New-Object Text.UTF8Encoding($true)))
        Assert ((Get-StackSnowPassword $fixture) -eq 'dummy-value') 'BOM not normalized'
    }
    Case 'Password spaces are preserved as part of the secret' {
        [IO.File]::WriteAllText((Join-Path $fixture 'private\snowluma-webui.txt')," dummy-value `r`n",(New-Object Text.UTF8Encoding($true)))
        Assert ((Get-StackSnowPassword $fixture) -eq ' dummy-value ') 'Password spaces changed'
    }
    Case 'Multiline password is rejected' {
        [IO.File]::WriteAllText((Join-Path $fixture 'private\snowluma-webui.txt'),"first`nsecond")
        $failed=$false;try{[void](Get-StackSnowPassword $fixture)}catch{$failed=$true}
        Assert $failed 'Multiline secret accepted'
    }
    Case 'DryRun logging creates no files' {
        Write-StackLog $fixture 'start' 'dry' $true
        Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'logs'))) 'DryRun wrote log directory'
    }
    Case 'Repeated UTF8 log append has a single BOM' {
        Write-StackLog $fixture 'start' 'first' $false;Write-StackLog $fixture 'start' 'second' $false
        $bytes=[IO.File]::ReadAllBytes((Join-Path $fixture 'logs\start-all.log'))
        $boms=0;for($i=0;$i -lt $bytes.Length-2;$i++){if($bytes[$i]-eq239 -and $bytes[$i+1]-eq187 -and $bytes[$i+2]-eq191){$boms++}}
        Assert ($boms -eq 1) 'Expected one BOM'
    }
    Case 'Large log rotates only its named previous file' {
        $path=Join-Path $fixture 'logs\start-all.log';[IO.File]::WriteAllBytes($path,(New-Object byte[] 1048577))
        Write-StackLog $fixture 'start' 'after rotation' $false
        Assert ((Get-Item -LiteralPath ($path+'.1')).Length -eq 1048577) 'Old log not retained'
        Assert ((Get-Item -LiteralPath $path).Length -lt 1024) 'Current log not bounded'
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath((Join-Path $root 'test-fixtures'))+'\'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output ('RESULT '+$script:passed+' startup/common tests passed; no real programs started')
