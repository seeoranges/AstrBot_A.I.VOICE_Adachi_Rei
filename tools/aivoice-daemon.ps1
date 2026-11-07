# One UTF-8 JSON request per line, one JSON response with the same id.
# SaveAudioToFile is synchronous. Never write diagnostics to stdout.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8

function Write-Response($response) {
    [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress -Depth 4))
    [Console]::Out.Flush()
}

try {
    $dll = 'C:\Program Files\AI\AIVoice\AIVoiceEditor\AI.Talk.Editor.Api.dll'
    [void][Reflection.Assembly]::LoadFrom($dll)
    $tts = New-Object AI.Talk.Editor.Api.TtsControl
    $tts.Initialize('A.I.VOICE Editor')
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

function New-EditorTimer { return [Diagnostics.Stopwatch]::StartNew() }

function Wait-Editor {
    $timer = New-EditorTimer
    $started = $false
    $busySince = $null
    $stopSent = $false
    $lastStatus = ''
    $connectionError = ''
    while ($timer.Elapsed.TotalSeconds -lt 50) {
        $lastStatus = [string]$tts.Status
        # Only continuous Busy time counts towards the recovery threshold.
        # A host restart/reconnection may expose several distinct Busy periods.
        if ($lastStatus -ne 'Busy') { $busySince = $null }
        switch ($lastStatus) {
            'Idle' { return }
            'NotRunning' {
                if (-not $started) {
                    try { $tts.StartHost(); $started = $true } catch { $connectionError = $_.Exception.Message }
                }
            }
            'NotConnected' { try { $tts.Connect() } catch { $connectionError = $_.Exception.Message } }
            'Busy' {
                # A previous request that was cut off can leave the host exporting
                # busy. The API does not distinguish this from long playback.
                # Preserve the configured 20 s recovery policy, then Stop() once.
                # Never overwrite text meanwhile.
                if ($null -eq $busySince) {
                    $busySince = $timer.Elapsed
                } elseif (-not $stopSent -and ($timer.Elapsed - $busySince).TotalSeconds -ge 20) {
                    $stopSent = $true
                    try { $tts.Stop() } catch {
                        throw ('A.I.VOICE Stop failed after 20 seconds of continuous Busy: ' + $_.Exception.Message)
                    }
                }
            }
            default { throw 'Unknown A.I.VOICE host status' }
        }
        Start-Sleep -Milliseconds 250
    }
    $detail = 'last status=' + $lastStatus + '; Stop attempted=' + $stopSent
    if ($connectionError) { $detail += '; connection error=' + $connectionError }
    throw ('A.I.VOICE did not become Idle within 50 seconds (' + $detail + ')')
}

function Close-Editor {
    # This is graceful cleanup only. TerminateProcess/proc.kill cannot run finally;
    # a later request's Wait-Editor must recover any remaining Busy state.
    try { $tts.Stop() } catch { [Console]::Error.WriteLine('A.I.VOICE cleanup Stop failed: ' + $_.Exception.Message) }
    try { $tts.Disconnect() } catch { [Console]::Error.WriteLine('A.I.VOICE cleanup Disconnect failed: ' + $_.Exception.Message) }
}

function Get-Number($value, [double]$low, [double]$high, [double]$fallback = 1.0) {
    if ($null -eq $value) { return $fallback }
    if ($value -is [bool]) { throw 'Audio parameter must be a finite number' }
    $number = [Convert]::ToDouble($value, [Globalization.CultureInfo]::InvariantCulture)
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw 'Audio parameter must be a finite number'
    }
    return [Math]::Max($low, [Math]::Min($number, $high))
}

function Test-Wav([string]$path) {
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        if ($stream.Length -le 44) { throw 'Empty WAV file' }
        $header = New-Object byte[] 12
        if ($stream.Read($header, 0, 12) -ne 12 -or
            [Text.Encoding]::ASCII.GetString($header, 0, 4) -ne 'RIFF' -or
            [Text.Encoding]::ASCII.GetString($header, 8, 4) -ne 'WAVE' -or
            ([long][BitConverter]::ToUInt32($header, 4) + 8) -ne $stream.Length) {
            throw 'Incomplete or unsupported WAV file'
        }
        return $stream.Length
    } finally { $stream.Dispose() }
}

function Set-LegacyControl($req) {
    $speed = Get-Number $req.speed 0.85 1.3
    $pitch = Get-Number $req.pitch 0.9 1.15
    $volume = Get-Number $req.volume 0.0 2.0
    $tts.MasterControl = (@{
        Volume = $volume; Speed = $speed; Pitch = $pitch
        PitchRange = Get-Number $req.pitch_range 0.8 1.3 1.0
        MiddlePause = [int][Math]::Truncate((Get-Number $req.middle_pause 100 400 150))
        LongPause = [int][Math]::Truncate((Get-Number $req.long_pause 200 800 370))
        SentencePause = [Math]::Max([int][Math]::Truncate((Get-Number $req.sentence_pause 400 1500 800)), [int][Math]::Truncate((Get-Number $req.long_pause 200 800 370)))
    } | ConvertTo-Json -Compress)
}

function Fail-Voice([string]$Code) {
    $failure = New-Object InvalidOperationException($Code)
    $failure.Data['VoiceCode'] = $Code
    throw $failure
}

function Set-VoiceStage([string]$Stage) {
    if ($Stage -notmatch '^[a-z_]{1,32}$') { return }
    $script:VoiceStage = $Stage
    $path = [Environment]::GetEnvironmentVariable('DAFEIYU_VOICE_STAGE_PATH','Process')
    if (-not $path) { return }
    # Optional local diagnostics only: no request text, account, preset or path is
    # written into the file. A diagnostic I/O failure must not affect synthesis.
    try {
        if (-not [IO.Path]::IsPathRooted($path)) { return }
        $path = [IO.Path]::GetFullPath($path)
        if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))) { return }
        $utc = [DateTime]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        $json = '{"stage":"' + $Stage + '","utc":"' + $utc + '"}'
        [IO.File]::WriteAllText($path,$json,(New-Object Text.UTF8Encoding($false)))
    } catch {}
}

function Set-VoiceDiagnostic($Record, [string]$Stage) {
    # Store diagnostics where the native exception was caught, before rethrowing
    # an ErrorRecord changes its displayed invocation position.
    if (-not $Record.Exception.Data.Contains('VoiceLine')) {
        $Record.Exception.Data['VoiceLine'] = [int]$Record.InvocationInfo.ScriptLineNumber
        $Record.Exception.Data['VoiceType'] = [string]$Record.Exception.GetType().Name
        if ($Record.Exception.InnerException) { $Record.Exception.Data['VoiceInnerType'] = [string]$Record.Exception.InnerException.GetType().Name }
        $Record.Exception.Data['VoiceStage'] = $Stage
    }
}

function Get-VoiceValue($Object, [string]$Name) {
    if ($Object -is [Collections.IDictionary]) { return ,($Object[$Name]) }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,($property.Value) }
    return $null
}

function Convert-VoiceProfile($InputProfile, [bool]$RequireAll = $true) {
    $result = [ordered]@{}
    $emotion = [string](Get-VoiceValue $InputProfile 'emotion')
    if (-not $emotion) { $emotion = 'normal' }
    $emotion = $emotion.ToLowerInvariant()
    if ($emotion -notmatch '^[a-z][a-z0-9_]{0,20}$') { Fail-Voice 'invalid_emotion' }
    $result.emotion = $emotion
    foreach ($definition in @(
        @('style',0.0,1.0,0.55), @('speed',0.85,1.3,1.0),
        @('pitch',0.9,1.15,1.0), @('volume',0.0,2.0,1.0),
        @('pitch_range',0.8,1.3,1.0), @('middle_pause',80,500,150),
        @('long_pause',200,800,370), @('sentence_pause',400,1500,800)
    )) {
        $name = [string]$definition[0]
        $value = Get-VoiceValue $InputProfile $name
        if ($RequireAll -and $null -eq $value) { Fail-Voice 'missing_profile_parameter' }
        try { $number = Get-Number $value $definition[1] $definition[2] $definition[3] }
        catch { Fail-Voice 'invalid_profile_parameter' }
        $result[$name] = if($name.EndsWith('_pause')){[int][Math]::Truncate($number)}else{$number}
    }
    $result.sentence_pause = [Math]::Max($result.sentence_pause,$result.long_pause)
    return [pscustomobject]$result
}

function Convert-VoiceRequest($Request) {
    $id = [string](Get-VoiceValue $Request 'id')
    if ([string]::IsNullOrWhiteSpace($id)) { Fail-Voice 'missing_request_id' }
    $text = Get-VoiceValue $Request 'text'
    $segments = Get-VoiceValue $Request 'segments'
    $profiles = Get-VoiceValue $Request 'profiles'
    $isList = $null -ne $segments
    $limit = if($isList){4000}else{400}
    if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text) -or $text.Length -gt $limit) { Fail-Voice 'invalid_text_length' }
    $out = [string](Get-VoiceValue $Request 'out')
    if (-not [IO.Path]::IsPathRooted($out) -or [IO.Path]::GetExtension($out) -ne '.wav') { Fail-Voice 'invalid_output_path' }
    $out = [IO.Path]::GetFullPath($out)
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($out)) -or [IO.File]::Exists($out)) { Fail-Voice 'output_not_available' }
    # Validate every profile before contacting the editor or adding any preset.
    $root = Convert-VoiceProfile $Request $false
    $normalizedSegments = New-Object Collections.Generic.List[object]
    if ($isList) {
        if ($segments -isnot [array] -or $segments.Count -lt 1 -or $segments.Count -gt 6) { Fail-Voice 'invalid_segment_count' }
        foreach ($segment in $segments) {
            $segmentText = Get-VoiceValue $segment 'text'
            if ($segmentText -isnot [string] -or [string]::IsNullOrWhiteSpace($segmentText) -or $segmentText.Length -gt 400) { Fail-Voice 'invalid_segment_text' }
            # A List row is one phrase. An interior sentence-ending symbol opens
            # an Editor confirmation dialog and blocks the synchronous API.
            # Validate before Wait-Editor or any other editor access.
            if ($segmentText.Length -gt 1 -and $segmentText.Substring(0,$segmentText.Length-1) -match '[。｡！？!?]') { Fail-Voice 'invalid_segment_sentence' }
            $profile = Convert-VoiceProfile $segment $true
            Add-Member -InputObject $profile -MemberType NoteProperty -Name text -Value $segmentText
            $normalizedSegments.Add($profile)
        }
        if ((($normalizedSegments | ForEach-Object {$_.text}) -join '') -cne $text) { Fail-Voice 'segment_text_mismatch' }
    }
    $normalizedProfiles = New-Object Collections.Generic.List[object]
    if ($null -ne $profiles) {
        if ($profiles -isnot [array] -or $profiles.Count -gt 9) { Fail-Voice 'invalid_profile_count' }
        foreach ($profile in $profiles) { $normalizedProfiles.Add((Convert-VoiceProfile $profile $true)) }
    }
    return [pscustomobject]@{id=$id;text=$text;out=$out;root=$root;raw=$Request;has_style=($null -ne (Get-VoiceValue $Request 'style'));is_list=$isList;segments=$normalizedSegments.ToArray();profiles=$normalizedProfiles.ToArray()}
}

function Get-PresetStorePath {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if (-not $documents) { $documents = Join-Path $env:USERPROFILE 'Documents' }
    return Join-Path $documents 'A.I.VOICE Editor\VoicePresets\user.vpc'
}

function Save-PresetManifest {
    if (-not $script:VoicePresetBackup) { return }
    $json = $script:VoicePresetBackup | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $script:VoicePresetBackup.snapshot 'manifest.json'),$json,(New-Object Text.UTF8Encoding($true)))
}

function Get-VoiceBackupRoot { return (Split-Path -Parent $PSScriptRoot) }

function Get-VoiceFileHash([string]$Path) {
    # Get-FileHash is a module-provided function and is not discoverable in some
    # Python-launched Windows PowerShell environments. Keep backup verification
    # independent of PSModulePath and read through a bounded-memory stream.
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-','')
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function Backup-VoicePresets {
    if ($script:VoicePresetBackup) { return }
    $source = Get-PresetStorePath
    $root = Get-VoiceBackupRoot
    $folder = Join-Path $root ('private\snapshots\voice-emotion-presets-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    [void][IO.Directory]::CreateDirectory($folder)
    $exists = [IO.File]::Exists($source)
    $hash = $null
    if ($exists) {
        $saved = Join-Path $folder 'user.vpc'
        [IO.File]::Copy($source,$saved,$false)
        $hash = Get-VoiceFileHash $saved
        if ($hash -ne (Get-VoiceFileHash $source)) { Fail-Voice 'preset_backup_changed' }
    }
    $script:VoicePresetBackup = [ordered]@{source=$source;snapshot=$folder;original_present=$exists;original_sha256=$hash;created_presets=@();restore_requires_editor_closed=$true}
    Save-PresetManifest
}

function Get-VoicePresetSpec($Profile) {
    # SentencePause has no VoicePreset field. It belongs to the request's MasterControl.
    Set-VoiceStage 'get_base'
    $base = $tts.GetVoicePreset('足立 レイ') | ConvertFrom-Json
    if (-not $base.VoiceName) { Fail-Voice 'base_voice_unavailable' }
    $values = [ordered]@{
        VoiceName=[string]$base.VoiceName;Volume=[double]$Profile.volume;Speed=[double]$Profile.speed
        Pitch=[double]$Profile.pitch;PitchRange=[double]$Profile.pitch_range
        MiddlePause=[int]$Profile.middle_pause;LongPause=[int]$Profile.long_pause
        Styles=@([ordered]@{Name='J';Value=[double]$Profile.style})
    }
    $canonical = $values | ConvertTo-Json -Depth 5 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $tag = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-','').Substring(0,16).ToLowerInvariant() }
    finally { $sha.Dispose() }
    $name = 'dafeiyu-emo-v1-' + $Profile.emotion + '-' + $tag
    $preset = [ordered]@{PresetName=$name}
    foreach($key in $values.Keys){$preset[$key]=$values[$key]}
    return [pscustomobject]@{name=$name;values=$preset;json=($preset|ConvertTo-Json -Depth 5 -Compress)}
}

function Test-VoicePreset($Actual, $Expected) {
    if ([string]$Actual.PresetName -cne [string]$Expected.PresetName -or [string]$Actual.VoiceName -cne [string]$Expected.VoiceName) { return $false }
    foreach($name in @('Volume','Speed','Pitch','PitchRange','MiddlePause','LongPause')) {
        try { $actualValue = [Convert]::ToDouble($Actual.$name,[Globalization.CultureInfo]::InvariantCulture) } catch { return $false }
        if ($null -eq $Actual.$name -or [double]::IsNaN($actualValue) -or [double]::IsInfinity($actualValue)) { return $false }
        if ([Math]::Abs($actualValue - [double]$Expected[$name]) -gt 0.00001) { return $false }
    }
    $styles = @($Actual.Styles)
    if ($styles.Count -ne 1 -or [string]$styles[0].Name -cne 'J') { return $false }
    try { $style = [double]$styles[0].Value } catch { return $false }
    return (-not [double]::IsNaN($style) -and -not [double]::IsInfinity($style) -and [Math]::Abs($style - [double]$Expected.Styles[0].Value) -lt 0.00001)
}

function Ensure-VoicePreset($Profile) {
    $spec = Get-VoicePresetSpec $Profile
    Set-VoiceStage 'get_names'
    if (@($tts.VoicePresetNames) -ccontains $spec.name) {
        Set-VoiceStage 'get_preset'
        $existing = $tts.GetVoicePreset($spec.name) | ConvertFrom-Json
        if (-not (Test-VoicePreset $existing $spec.values)) { Fail-Voice 'preset_name_collision' }
        return $spec.name
    }
    Set-VoiceStage 'backup'
    Backup-VoicePresets
    # Journal the intended name first, so even an Add that fails after persisting is recoverable.
    $script:VoicePresetBackup.created_presets += $spec.name
    Save-PresetManifest
    Set-VoiceStage 'add_preset'
    $tts.AddVoicePreset($spec.json)
    Set-VoiceStage 'verify'
    $added = $tts.GetVoicePreset($spec.name) | ConvertFrom-Json
    if (-not (Test-VoicePreset $added $spec.values)) { Fail-Voice 'preset_verification_failed' }
    return $spec.name
}

function Set-NeutralControl($Request) {
    Set-LegacyControl $Request
    $control = $tts.MasterControl | ConvertFrom-Json
    $control.Speed = 1.0; $control.Pitch = 1.0; $control.PitchRange = 1.0; $control.Volume = 1.0
    $tts.MasterControl = $control | ConvertTo-Json -Compress
}

function Get-EditorSnapshot {
    Set-VoiceStage 'snapshot_mode'; $mode = $tts.TextEditMode
    Set-VoiceStage 'snapshot_master'; $master = $tts.MasterControl
    Set-VoiceStage 'snapshot_preset'; $preset = $tts.CurrentVoicePresetName
    Set-VoiceStage 'snapshot_text'; $text = $tts.Text
    return [pscustomobject]@{mode=$mode;master=$master;preset=$preset;text=$text}
}

function Restore-EditorSnapshot($Snapshot) {
    $safe = $true
    try { Set-VoiceStage 'restore_wait'; Wait-Editor } catch { return $false }
    # Each restoration is attempted even when a different property setter fails.
    try { Set-VoiceStage 'restore_master'; $tts.MasterControl = $Snapshot.master } catch { $safe=$false }
    try { Set-VoiceStage 'restore_preset'; $tts.CurrentVoicePresetName = $Snapshot.preset } catch { $safe=$false }
    try { Set-VoiceStage 'restore_text_mode'; $tts.TextEditMode = [AI.Talk.Editor.Api.TextEditMode]::Text } catch { $safe=$false }
    try { Set-VoiceStage 'restore_text'; $tts.Text = $Snapshot.text } catch { $safe=$false }
    try { Set-VoiceStage 'restore_mode'; $tts.TextEditMode = $Snapshot.mode } catch { $safe=$false }
    return $safe
}

function Test-OwnedList($Expected) {
    $count = $tts.GetListCount()
    if ($count -gt @($Expected).Count) { return $false }
    for($index=0;$index -lt $count;$index++) {
        $tts.SetListSelectionIndex($index)
        if ([string]$tts.GetListVoicePreset() -cne [string]$Expected[$index].preset -or [string]$tts.GetListSentence() -cne [string]$Expected[$index].text) { return $false }
    }
    return $true
}

function Get-VoiceTextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $encoding = New-Object Text.UTF8Encoding($false,$true)
        return ([BitConverter]::ToString($sha.ComputeHash($encoding.GetBytes($Text))) -replace '-','')
    } finally { $sha.Dispose() }
}

function Get-VoiceListLeasePath {
    return [IO.Path]::Combine((Get-VoiceBackupRoot),'private','aivoice-list-lease.json')
}

function Read-VoiceListLease {
    try {
        $lease = [IO.File]::ReadAllText((Get-VoiceListLeasePath),[Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($lease.version -ne 1 -or [string]$lease.lease_id -notmatch '^[0-9a-f]{32}$' -or $lease.expected -isnot [array] -or $lease.expected.Count -lt 1 -or $lease.expected.Count -gt 6) { return $null }
        $at = [DateTimeOffset]::ParseExact([string]$lease.utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None)
        $age = ([DateTimeOffset]::UtcNow - $at).TotalSeconds
        if ($age -lt 0 -or $age -gt 1800) { return $null }
        foreach($row in $lease.expected) {
            if ([string]$row.preset -notmatch '^dafeiyu-emo-v1-[a-z][a-z0-9_]{0,20}-[0-9a-f]{16}$' -or [string]$row.text_sha256 -notmatch '^[0-9A-F]{64}$') { return $null }
        }
        return $lease
    } catch { return $null }
}

function Remove-VoiceListLease([string]$LeaseId = '') {
    $path = Get-VoiceListLeasePath
    if (-not [IO.File]::Exists($path)) { return }
    if ($LeaseId) {
        try { $current = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json }
        catch { Fail-Voice 'unsafe_cleanup' }
        if ([string]$current.lease_id -cne $LeaseId) { Fail-Voice 'unsafe_cleanup' }
    }
    [IO.File]::Delete($path)
}

function Write-VoiceListLease($Expected) {
    Set-VoiceStage 'lease_write'
    $rows = @($Expected | ForEach-Object { [ordered]@{preset=[string]$_.preset;text_sha256=(Get-VoiceTextHash ([string]$_.text))} })
    $id = [Guid]::NewGuid().ToString('N')
    $lease = [ordered]@{version=1;utc=[DateTimeOffset]::UtcNow.ToString('o',[Globalization.CultureInfo]::InvariantCulture);lease_id=$id;expected=$rows}
    $path = Get-VoiceListLeasePath
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $temporary = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($lease|ConvertTo-Json -Compress -Depth 5),(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$path) }
    } finally { if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)} }
    return $id
}

function Recover-VoiceList([int]$Count) {
    Set-VoiceStage 'lease_check'
    if ($Count -eq 0) {
        # With no rows there is nothing left to recover; malformed/expired
        # journals from an interrupted request can safely be removed as well.
        Remove-VoiceListLease
        return $true
    }
    $lease = Read-VoiceListLease
    if ($null -eq $lease -or $Count -gt $lease.expected.Count) { return $false }
    $selection = [int[]]$tts.GetListSelectionIndices()
    $cleared = $false
    try {
        for($index=0;$index -lt $Count;$index++) {
            Set-VoiceStage 'lease_row_check'
            $tts.SetListSelectionIndex($index)
            if ([string]$tts.GetListVoicePreset() -cne [string]$lease.expected[$index].preset -or (Get-VoiceTextHash ([string]$tts.GetListSentence())) -cne [string]$lease.expected[$index].text_sha256) { return $false }
        }
        if ($tts.GetListCount() -ne $Count) { return $false }
        try {
            Set-VoiceStage 'lease_recover_clear'
            $tts.ClearListItems()
            if ($tts.GetListCount() -ne 0) { Fail-Voice 'unsafe_cleanup' }
            $cleared = $true
            Remove-VoiceListLease ([string]$lease.lease_id)
        } catch { Fail-Voice 'unsafe_cleanup' }
        return $true
    } finally {
        # Inspecting a nonmatching user's list must preserve its selection too.
        # Never apply a stale lease's MasterControl, preset or mode snapshot.
        if (-not $cleared) {
            try { $tts.SetListSelectionIndices($selection) } catch { Fail-Voice 'unsafe_cleanup' }
        }
    }
}

function Save-TextAudio($Request) {
    $tts.TextEditMode = [AI.Talk.Editor.Api.TextEditMode]::Text
    if ($Request.has_style) {
        $tts.CurrentVoicePresetName = Ensure-VoicePreset $Request.root
        Set-NeutralControl $Request.raw
    } else { Set-LegacyControl $Request.raw }
    $tts.Text = $Request.text
    $tts.SaveAudioToFile($Request.out)
    return (Test-Wav $Request.out)
}

function Invoke-VoiceRequest($InputRequest) {
    Set-VoiceStage 'validate'
    $request = Convert-VoiceRequest $InputRequest
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Set-VoiceStage 'wait'
    Wait-Editor
    Set-VoiceStage 'snapshot'
    $snapshot = Get-EditorSnapshot
    $result = $null
    $restoreSafe = $true
    $requestFailure = $null
    try {
        Set-VoiceStage 'profile'
        foreach($profile in $request.profiles) { [void](Ensure-VoicePreset $profile) }
        if (-not $request.is_list) {
            if (-not $request.has_style) { $tts.CurrentVoicePresetName = $snapshot.preset }
            Set-VoiceStage 'single_save'
            $bytes = Save-TextAudio $request
            $result = @{id=$request.id;ok=$true;out=$request.out;bytes=$bytes;mode='single'}
        } else {
            $owned = $false
            $cleanupSafe = $true
            $listFailed = $false
            $leaseId = ''
            $expected = New-Object Collections.Generic.List[object]
            try {
                Set-VoiceStage 'list_prepare'
                $tts.TextEditMode = [AI.Talk.Editor.Api.TextEditMode]::List
                if (-not (Recover-VoiceList ($tts.GetListCount()))) { Fail-Voice 'list_in_use' }
                foreach($segment in $request.segments) {
                    Set-VoiceStage 'profile'
                    $name = Ensure-VoicePreset $segment
                    $expected.Add([pscustomobject]@{preset=$name;text=$segment.text})
                }
                if ($tts.GetListCount() -ne 0) { Fail-Voice 'list_in_use' }
                $leaseId = Write-VoiceListLease $expected.ToArray()
                $owned = $true
                Set-VoiceStage 'list_control'
                Set-NeutralControl $request.raw
                Set-VoiceStage 'append'
                foreach($row in $expected) { $tts.AddListItem($row.preset,$row.text) }
                Set-VoiceStage 'selection'
                if ($tts.GetListCount() -ne $expected.Count) { Fail-Voice 'list_count_mismatch' }
                $tts.SetListSelectionRange(0,$expected.Count)
                if ($tts.GetListSelectionCount() -ne $expected.Count) { Fail-Voice 'list_selection_mismatch' }
                Set-VoiceStage 'list_save'
                $tts.SaveAudioToFile($request.out)
                Set-VoiceStage 'wav_check'
                $bytes = Test-Wav $request.out
                $result = @{id=$request.id;ok=$true;out=$request.out;bytes=$bytes;mode='list'}
            } catch {
                Set-VoiceDiagnostic $_ $script:VoiceStage
                if ([string]$_.Exception.Data['VoiceCode'] -eq 'unsafe_cleanup') { $cleanupSafe = $false }
                $listFailed = $true
            }
            finally {
                if ($owned) {
                    try {
                        Set-VoiceStage 'list_cleanup'
                        Wait-Editor
                        $tts.TextEditMode = [AI.Talk.Editor.Api.TextEditMode]::List
                        if (-not (Test-OwnedList $expected.ToArray())) { Fail-Voice 'list_ownership_changed' }
                        $tts.ClearListItems()
                        if ($tts.GetListCount() -ne 0) { Fail-Voice 'list_cleanup_failed' }
                        Remove-VoiceListLease $leaseId
                    } catch { $cleanupSafe = $false }
                }
            }
            if (-not $cleanupSafe) { Fail-Voice 'unsafe_cleanup' }
            if ($listFailed) {
                Set-VoiceStage 'restore'
                if (-not (Restore-EditorSnapshot $snapshot)) { Fail-Voice 'unsafe_cleanup' }
                Set-VoiceStage 'fallback_wait'
                Wait-Editor
                if ($request.text.Length -gt 400) { Fail-Voice 'list_fallback_required' }
                # A failed export may have created a partial file at this request's unique path.
                if ([IO.File]::Exists($request.out)) { [IO.File]::Delete($request.out) }
                Set-VoiceStage 'fallback_save'
                $bytes = Save-TextAudio $request
                $result = @{id=$request.id;ok=$true;out=$request.out;bytes=$bytes;mode='single_fallback'}
            }
        }
    } catch { Set-VoiceDiagnostic $_ $script:VoiceStage; $requestFailure = $_ }
    finally { Set-VoiceStage 'restore'; $restoreSafe = Restore-EditorSnapshot $snapshot }
    if (-not $restoreSafe) { Fail-Voice 'unsafe_cleanup' }
    if ($null -ne $requestFailure) { throw $requestFailure }
    $result.timings = @{bridge_ms=[int]$timer.Elapsed.TotalMilliseconds}
    return $result
}

$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
try {
    while ($null -ne ($line = $stdin.ReadLine())) {
        if (-not $line.Trim()) { continue }
        $requestId = $null
        try {
            Set-VoiceStage 'parse'
            $req = $line | ConvertFrom-Json
            $requestId = [string]$req.id
            Write-Response (Invoke-VoiceRequest $req)
        } catch {
            Set-VoiceDiagnostic $_ $script:VoiceStage
            $code = [string]$_.Exception.Data['VoiceCode']
            if (-not $code) { $code = 'editor_request_failed' }
            Write-Response @{ id = $requestId; ok = $false; error = $code; error_code = $code; code = $code; error_type = [string]$_.Exception.Data['VoiceType']; error_inner_type = [string]$_.Exception.Data['VoiceInnerType']; error_line = [int]$_.Exception.Data['VoiceLine']; stage = [string]$_.Exception.Data['VoiceStage'] }
        }
    }
} finally {
    $stdin.Dispose()
    Close-Editor
}
