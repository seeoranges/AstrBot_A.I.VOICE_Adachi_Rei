# AST-only tests: no DLL loading, host connection, synthesis, or QQ interaction.
$ErrorActionPreference = 'Stop'
$daemonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\aivoice-daemon.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($daemonPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($definition in $functions) { . ([scriptblock]::Create($definition.Extent.Text)) }
$assignment = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$tts.MasterControl'
}, $true)
if ($null -eq $assignment) { throw 'Production MasterControl assignment missing' }
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
function Evaluate-Control($request) {
    $script:req = $request
    $script:speed = Get-Number $request.speed 0.85 1.3
    $script:pitch = Get-Number $request.pitch 0.9 1.15
    $script:volume = Get-Number $request.volume 0 2
    $script:tts = [pscustomobject]@{ MasterControl = '' }
    . ([scriptblock]::Create($assignment.Extent.Text))
    return $tts.MasterControl | ConvertFrom-Json
}

Test-Case 'Missing fields preserve all legacy values' {
    $control = Evaluate-Control ([pscustomobject]@{})
    Assert-True ($control.Speed -eq 1 -and $control.Pitch -eq 1 -and $control.Volume -eq 1) 'Legacy parameters changed'
    Assert-True ($control.PitchRange -eq 1 -and $control.MiddlePause -eq 150 -and $control.LongPause -eq 370 -and $control.SentencePause -eq 800) 'Optional defaults changed'
}
Test-Case 'Explicit null optional fields preserve legacy values' {
    $control = Evaluate-Control ('{"pitch_range":null,"middle_pause":null,"long_pause":null,"sentence_pause":null}' | ConvertFrom-Json)
    Assert-True ($control.PitchRange -eq 1 -and $control.MiddlePause -eq 150 -and $control.LongPause -eq 370 -and $control.SentencePause -eq 800) 'Null fields did not default'
}
Test-Case 'Supplied emotional settings reach the actual MasterControl JSON' {
    $control = Evaluate-Control ('{"speed":1.2,"pitch":1.1,"pitch_range":1.2,"middle_pause":110,"long_pause":230,"sentence_pause":430}' | ConvertFrom-Json)
    Assert-True ($control.Speed -eq 1.2 -and $control.Pitch -eq 1.1 -and $control.PitchRange -eq 1.2) 'Prosody was not applied'
    Assert-True ($control.MiddlePause -eq 110 -and $control.LongPause -eq 230 -and $control.SentencePause -eq 430) 'Pauses were not applied'
}
Test-Case 'Every upper limit is clamped' {
    $control = Evaluate-Control ('{"pitch_range":99,"middle_pause":99999,"long_pause":99999,"sentence_pause":99999}' | ConvertFrom-Json)
    Assert-True ($control.PitchRange -eq 1.3 -and $control.MiddlePause -eq 400 -and $control.LongPause -eq 800 -and $control.SentencePause -eq 1500) 'Upper clamp failed'
}
Test-Case 'Every lower limit is clamped' {
    $control = Evaluate-Control ('{"pitch_range":-9,"middle_pause":-9,"long_pause":-9,"sentence_pause":-9}' | ConvertFrom-Json)
    Assert-True ($control.PitchRange -eq 0.8 -and $control.MiddlePause -eq 100 -and $control.LongPause -eq 200 -and $control.SentencePause -eq 400) 'Lower clamp failed'
}
Test-Case 'Fractional pauses become deterministic integer milliseconds' {
    $control = Evaluate-Control ('{"middle_pause":123.99,"long_pause":345.9,"sentence_pause":678.5}' | ConvertFrom-Json)
    Assert-True ($control.MiddlePause -eq 123 -and $control.LongPause -eq 345 -and $control.SentencePause -eq 678) 'Pause rounding was not truncation'
}
Test-Case 'Sentence pause is never shorter than the long pause for direct bridge callers' {
    $control = Evaluate-Control ('{"long_pause":800,"sentence_pause":400}' | ConvertFrom-Json)
    Assert-True ($control.LongPause -eq 800 -and $control.SentencePause -eq 800) 'Invalid related pause values reached the editor'
}
Test-Case 'Boolean emotional values are rejected' {
    foreach ($field in @('pitch_range', 'middle_pause', 'long_pause', 'sentence_pause')) {
        $request = [pscustomobject]@{}
        Add-Member -InputObject $request -MemberType NoteProperty -Name $field -Value $true
        Assert-Throws { Evaluate-Control $request } ('Boolean accepted for ' + $field)
    }
}
Test-Case 'Malformed and nonfinite optional values are rejected' {
    foreach ($field in @('pitch_range', 'middle_pause', 'long_pause', 'sentence_pause')) {
        foreach ($value in @('invalid', [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity)) {
            $request = [pscustomobject]@{}
            Add-Member -InputObject $request -MemberType NoteProperty -Name $field -Value $value
            Assert-Throws { Evaluate-Control $request } ('Invalid value accepted for ' + $field)
        }
    }
}
Test-Case 'Invariant decimals survive a non-English Windows culture' {
    $previous = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
        $control = Evaluate-Control ('{"speed":"1.2","pitch_range":"1.25","middle_pause":"123.9"}' | ConvertFrom-Json)
        Assert-True ($control.Speed -eq 1.2 -and $control.PitchRange -eq 1.25 -and $control.MiddlePause -eq 123) 'Decimal parsing became culture-dependent'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previous }
}
Test-Case 'Partial payload does not erase other defaults' {
    $control = Evaluate-Control ('{"pitch_range":1.1}' | ConvertFrom-Json)
    Assert-True ($control.PitchRange -eq 1.1 -and $control.MiddlePause -eq 150 -and $control.LongPause -eq 370 -and $control.SentencePause -eq 800) 'Partial request changed unspecified parameters'
}
Test-Case 'Source remains UTF-8 with BOM for Windows PowerShell 5.1' {
    $bytes = [IO.File]::ReadAllBytes($daemonPath)
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Daemon lost UTF-8 BOM'
}

Write-Output ('OK ' + $script:passed + ' emotion tests; PowerShell ' + $PSVersionTable.PSVersion.ToString())
