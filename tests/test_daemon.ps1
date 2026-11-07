# Offline regression tests. Import AST function definitions, never daemon startup.
$ErrorActionPreference = 'Stop'
$daemonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\aivoice-daemon.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($daemonPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($definition in $functions) { . ([scriptblock]::Create($definition.Extent.Text)) }

$script:passed = 0
function Assert-True($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Test-Case([string]$name, [scriptblock]$body) {
    & $body
    $script:passed++
    Write-Output ('PASS ' + $name)
}
function Assert-Throws([scriptblock]$body, [string]$message) {
    $thrown = $false
    try { & $body | Out-Null } catch { $thrown = $true }
    Assert-True $thrown $message
}

Add-Type -TypeDefinition @'
using System;
public sealed class OfflineVoiceTimer {
    public double Seconds;
    public TimeSpan Elapsed { get { return TimeSpan.FromSeconds(Seconds); } }
}
public sealed class OfflineVoiceHost {
    public string State = "NotRunning";
    public int Starts;
    public int Connections;
    public int BusyReads;
    public int Stops;
    public int Disconnects;
    public bool RemainBusy;
    public bool StopThrows;
    public bool StopKeepsBusy;
    public bool ConnectThrows;
    public string Calls = "";
    public double StopAt = -1;
    public OfflineVoiceTimer Clock;
    public double[] StateTimes;
    public string[] StateValues;
    public string Text = "keep text";
    public string MasterControl = "keep settings";
    public string Status {
        get {
            if (StateTimes != null) {
                int index = 0;
                for (int i = 1; i < StateTimes.Length && Clock.Seconds >= StateTimes[i]; i++) index = i;
                return StateValues[index];
            }
            if (State == "Busy" && !RemainBusy && ++BusyReads >= 3) State = "Idle";
            return State;
        }
    }
    public void StartHost() { Starts++; State = "NotConnected"; }
    public void Connect() {
        Connections++;
        if (ConnectThrows) throw new InvalidOperationException("offline connect failure");
        State = "Idle";
    }
    public void Stop() {
        Stops++; Calls += "Stop;"; StopAt = Clock == null ? -1 : Clock.Seconds;
        if (StopThrows) throw new InvalidOperationException("offline stop failure");
        if (!StopKeepsBusy) State = "Idle";
    }
    public void Disconnect() { Disconnects++; Calls += "Disconnect;"; }
}
'@

# Avoid real waits; production Wait-Editor code and its status handling stay intact.
$script:sleeps = 0
function New-EditorTimer {
    $script:editorTimer = New-Object OfflineVoiceTimer
    $script:tts.Clock = $script:editorTimer
    return $script:editorTimer
}
function Start-Sleep {
    param([int]$Milliseconds)
    $script:sleeps++
    $script:editorTimer.Seconds += $Milliseconds / 1000.0
}

Test-Case 'Cold host starts, connects, and becomes Idle' {
    $script:tts = New-Object OfflineVoiceHost
    Wait-Editor
    Assert-True ($tts.Starts -eq 1) 'Expected one StartHost'
    Assert-True ($tts.Connections -eq 1) 'Expected one Connect'
    Assert-True ($tts.State -eq 'Idle') 'Expected Idle'
}
Test-Case 'Idle host never reconnects or restarts' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.State = 'Idle'
    Wait-Editor
    Assert-True ($tts.Starts -eq 0 -and $tts.Connections -eq 0) 'Idle host changed connection'
}
Test-Case 'Busy host waits without overwriting text or settings' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.State = 'Busy'
    $before = $script:sleeps
    Wait-Editor
    Assert-True ($script:sleeps - $before -eq 2) 'Busy status did not wait'
    Assert-True ($tts.Starts -eq 0 -and $tts.Connections -eq 0) 'Busy host was reconnected'
    Assert-True ($tts.Text -eq 'keep text' -and $tts.MasterControl -eq 'keep settings') 'Busy host content was overwritten'
}
Test-Case 'Unknown host state fails closed' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.State = 'Unexpected'
    Assert-Throws { Wait-Editor } 'Unknown status must fail'
}
Test-Case 'Continuous Busy is stopped exactly once after twenty seconds' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.State = 'Busy'; $tts.RemainBusy = $true
    Wait-Editor
    Assert-True ($tts.Stops -eq 1 -and $tts.StopAt -eq 20) 'Recovery did not happen once at twenty seconds'
    Assert-True ($tts.Text -eq 'keep text' -and $tts.MasterControl -eq 'keep settings') 'Recovery overwrote text/settings'
}
Test-Case 'A disconnection resets continuous Busy time' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.StateTimes = [double[]](0, 10, 11, 35)
    $tts.StateValues = [string[]]('Busy', 'NotConnected', 'Busy', 'Idle')
    Wait-Editor
    Assert-True ($tts.Stops -eq 1 -and $tts.StopAt -eq 31) 'Disconnected time counted towards Busy recovery'
}
Test-Case 'A stopped Busy host still has the original fifty second limit' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.State = 'Busy'; $tts.RemainBusy = $true; $tts.StopKeepsBusy = $true
    $message = ''
    try { Wait-Editor } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'within 50 seconds' -and $message -match 'last status=Busy') 'Timeout omitted useful state'
    Assert-True ($tts.Stops -eq 1 -and $editorTimer.Seconds -eq 50) 'Recovery repeated Stop or changed total timeout'
}
Test-Case 'Failed Stop reports its cause without silently waiting out the timeout' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.State = 'Busy'; $tts.RemainBusy = $true; $tts.StopThrows = $true
    $message = ''
    try { Wait-Editor } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'Stop failed' -and $message -match 'offline stop failure') 'Stop failure was swallowed'
    Assert-True ($tts.Stops -eq 1 -and $editorTimer.Seconds -eq 20) 'Failed Stop was retried or hidden by long wait'
}
Test-Case 'Connection timeout reports the underlying connection error' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.State = 'NotConnected'; $tts.ConnectThrows = $true
    $message = ''
    try { Wait-Editor } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'within 50 seconds' -and $message -match 'offline connect failure') 'Connection error lost'
    Assert-True ($tts.Stops -eq 0) 'NotConnected host was stopped'
}
Test-Case 'Graceful cleanup stops before disconnecting' {
    $script:tts = New-Object OfflineVoiceHost
    Close-Editor
    Assert-True ($tts.Calls -eq 'Stop;Disconnect;') 'Graceful cleanup order changed'
}
Test-Case 'Cleanup Stop failure still disconnects and writes only stderr' {
    $script:tts = New-Object OfflineVoiceHost
    $tts.StopThrows = $true
    $capture = New-Object IO.StringWriter
    $previous = [Console]::Error
    try {
        [Console]::SetError($capture)
        $out = @(Close-Editor)
    } finally { [Console]::SetError($previous) }
    Assert-True ($out.Count -eq 0) 'Cleanup diagnostic contaminated stdout protocol'
    Assert-True ($tts.Disconnects -eq 1 -and $capture.ToString() -match 'offline stop failure') 'Failed Stop blocked disconnect or lost error'
    $capture.Dispose()
}
Test-Case 'Response is one JSON line and special characters round-trip' {
    $special = 'C:\voice\"quoted"' + "`r`n`t" + [char]0x3042 + [char]0x96F6
    $capture = New-Object IO.StringWriter
    $previous = [Console]::Out
    try {
        [Console]::SetOut($capture)
        Write-Response @{ id = 'test'; ok = $false; error = $special; out = $special }
    } finally { [Console]::SetOut($previous) }
    $lines = @($capture.ToString() -split '\r?\n' | Where-Object { $_.Length })
    Assert-True ($lines.Count -eq 1) 'Response contains transport-breaking newline'
    $decoded = $lines[0] | ConvertFrom-Json
    Assert-True ($decoded.error -ceq $special -and $decoded.out -ceq $special) 'Special characters did not round-trip'
    $capture.Dispose()
}
Test-Case 'Numbers reject nonfinite and boolean values and clamp range' {
    Assert-True ((Get-Number $null 0.85 1.3) -eq 1) 'Null should default to 1'
    Assert-True ((Get-Number 9 0.85 1.3) -eq 1.3) 'Upper clamp failed'
    Assert-True ((Get-Number -9 0.85 1.3) -eq 0.85) 'Lower clamp failed'
    Assert-Throws { Get-Number $true 0.85 1.3 } 'Boolean accepted'
    Assert-Throws { Get-Number ([double]::NaN) 0.85 1.3 } 'NaN accepted'
    Assert-Throws { Get-Number ([double]::PositiveInfinity) 0.85 1.3 } 'Infinity accepted'
    Assert-Throws { Get-Number 'invalid' 0.85 1.3 } 'Invalid number accepted'
}
Test-Case 'Invariant decimal parsing and actual MasterControl JSON under fr-FR' {
    $previous = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
        $script:speed = Get-Number '1.25' 0.85 1.3
        $script:pitch = Get-Number '1.05' 0.9 1.15
        $script:volume = Get-Number '0.75' 0 2
        $script:tts = New-Object OfflineVoiceHost
        $assignment = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$tts.MasterControl'
        }, $true)
        Assert-True ($null -ne $assignment) 'MasterControl assignment missing'
        . ([scriptblock]::Create($assignment.Extent.Text))
        $decoded = $tts.MasterControl | ConvertFrom-Json
        Assert-True ($decoded.Speed -eq 1.25 -and $decoded.Pitch -eq 1.05 -and $decoded.Volume -eq 0.75) 'Locale changed decimal values'
        Assert-True ($decoded.MiddlePause -eq 150 -and $decoded.PitchRange -eq 1) 'MasterControl settings missing'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previous }
}

$tempFolder = Join-Path $PSScriptRoot ('daemon-offline-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempFolder)
try {
    $wavPath = Join-Path $tempFolder 'valid.wav'
    $stream = [IO.File]::Create($wavPath)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32]40)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([uint32]16)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([uint32]24000)
        $writer.Write([uint32]48000)
        $writer.Write([uint16]2)
        $writer.Write([uint16]16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([uint32]4)
        $writer.Write([byte[]](0, 0, 0, 0))
    } finally { $writer.Dispose() }
    Test-Case 'Complete PCM WAV is accepted' {
        Assert-True ((Test-Wav $wavPath) -eq 48) 'Valid WAV rejected'
    }
    Test-Case 'Truncated WAV is rejected' {
        $path = Join-Path $tempFolder 'truncated.wav'
        [byte[]]$bytes = [IO.File]::ReadAllBytes($wavPath)
        [IO.File]::WriteAllBytes($path, [byte[]]$bytes[0..45])
        Assert-Throws { Test-Wav $path } 'Truncated WAV accepted'
    }
    Test-Case 'Empty and wrong-signature WAV files are rejected' {
        $empty = Join-Path $tempFolder 'empty.wav'
        [IO.File]::WriteAllBytes($empty, (New-Object byte[] 44))
        Assert-Throws { Test-Wav $empty } 'Empty WAV accepted'
        $invalid = Join-Path $tempFolder 'invalid.wav'
        [byte[]]$bytes = [IO.File]::ReadAllBytes($wavPath)
        $bytes[0] = 0
        [IO.File]::WriteAllBytes($invalid, $bytes)
        Assert-Throws { Test-Wav $invalid } 'Wrong RIFF signature accepted'
    }
    Test-Case 'Locked WAV is rejected until writer releases it' {
        $lock = [IO.File]::Open($wavPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { Assert-Throws { Test-Wav $wavPath } 'Locked WAV accepted' } finally { $lock.Dispose() }
        Assert-True ((Test-Wav $wavPath) -eq 48) 'Released WAV remained inaccessible'
    }
} finally {
    # Only remove exact files from this newly created test folder.
    foreach ($file in [IO.Directory]::GetFiles($tempFolder)) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($tempFolder)
}

Write-Output ('OK ' + $script:passed + ' tests; PowerShell ' + $PSVersionTable.PSVersion.ToString())
