# AST/mocked host tests only. Never load the real Editor DLL or connect to it.
$ErrorActionPreference='Stop'
$stage=Split-Path $PSScriptRoot
$source=Join-Path $stage 'tools\aivoice-daemon.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'PowerShell source parse failed'}
foreach($definition in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($definition.Extent.Text))}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
namespace AI.Talk.Editor.Api { public enum TextEditMode { Text, List } }
public sealed class EmotionMockRow { public string Preset; public string Text; }
public sealed class EmotionMockHost {
 public List<string> Calls = new List<string>();
 public Dictionary<string,int> Counts = new Dictionary<string,int>();
 public Dictionary<string,string> Presets = new Dictionary<string,string>();
 public List<EmotionMockRow> Rows = new List<EmotionMockRow>();
 public string FailPoint=""; public int FailOccurrence=1;
 public bool FailAfterRow; public bool InjectForeignRow; public bool WaitFails;
 public int SaveAttempts; public int Adds; public int Clears; public int Selected; public int SelectedCount;
 public string LastSavedMaster; public AI.Talk.Editor.Api.TextEditMode LastSavedMode;
 string master="{\"Volume\":0.95,\"Speed\":1.02,\"Pitch\":1,\"PitchRange\":1,\"MiddlePause\":150,\"LongPause\":370,\"SentencePause\":800}";
 string text="original editor text"; string preset="足立 レイ";
 AI.Talk.Editor.Api.TextEditMode mode=AI.Talk.Editor.Api.TextEditMode.Text;
 public EmotionMockHost() { Presets["足立 レイ"]="{\"PresetName\":\"足立 レイ\",\"VoiceName\":\"rei_emo_48\",\"Volume\":1,\"Speed\":1,\"Pitch\":1,\"PitchRange\":1,\"MiddlePause\":150,\"LongPause\":370,\"Styles\":[{\"Name\":\"J\",\"Value\":0}]}"; }
 public void Call(string op) { Calls.Add(op); int count; Counts.TryGetValue(op,out count); Counts[op]=++count; if(FailPoint==op && count==FailOccurrence) throw new InvalidOperationException("mock failure (never disclose)"); }
 public string Status {get{return "Idle";}}
 public string MasterControl {get{Call("get_master");return master;}set{Call("set_master");master=value;}}
 public string Text {get{Call("get_text");return text;}set{Call("set_text");text=value;}}
 public string CurrentVoicePresetName {get{Call("get_current");return preset;}set{Call("set_current");preset=value;}}
 public AI.Talk.Editor.Api.TextEditMode TextEditMode {get{Call("get_mode");return mode;}set{Call("set_mode");mode=value;}}
 public string[] VoicePresetNames {get{Call("get_names");string[] result=new string[Presets.Count];Presets.Keys.CopyTo(result,0);return result;}}
 public string GetVoicePreset(string name) { Call("get_preset");return Presets[name]; }
 public void AddVoicePreset(string json) { Call("add_preset");string name=Regex.Match(json,"\"PresetName\"\\s*:\\s*\"([^\"]+)\"").Groups[1].Value;Presets.Add(name,json);Adds++;preset=name; }
 public int GetListCount() { Call("get_count");return Rows.Count; }
 public void AddListItem(string name,string value) { if(mode!=AI.Talk.Editor.Api.TextEditMode.List) throw new InvalidOperationException("not list");if(FailAfterRow) Rows.Add(new EmotionMockRow{Preset=name,Text=value});Call("add_row");if(!FailAfterRow)Rows.Add(new EmotionMockRow{Preset=name,Text=value}); }
 public void SetListSelectionIndex(int index) {Call("select_row");Selected=index;SelectedCount=1;}
 public int[] GetListSelectionIndices() {Call("get_selection_indices");return SelectedCount==0?new int[0]:new int[]{Selected};}
 public void SetListSelectionIndices(int[] values) {Call("restore_selection");SelectedCount=values.Length;Selected=values.Length==0?0:values[0];}
 public void SetListSelectionRange(int start,int length) {Call("select_range");Calls.Add("range:"+start+":"+length);Selected=start;SelectedCount=length;}
 public int GetListSelectionCount() {Call("get_selection_count");return SelectedCount;}
 public string GetListVoicePreset() {Call("get_row_preset");return Rows[Selected].Preset;}
 public string GetListSentence() {Call("get_row_text");return Rows[Selected].Text;}
 public void ClearListItems() {Call("clear");Rows.Clear();Clears++;}
 public void SaveAudioToFile(string path) {SaveAttempts++;LastSavedMaster=master;LastSavedMode=mode;File.WriteAllBytes(path,new byte[48]);Call("save");if(InjectForeignRow)Rows.Add(new EmotionMockRow{Preset="user-voice",Text="user's work"});}
}
'@
$fixture=Join-Path $PSScriptRoot ('list-mock-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$script:passed=0
function Assert($value,$message){if(-not $value){throw $message}}
function Case($name,[scriptblock]$body){Reset-Mock;& $body;$script:passed++;Write-Output ('PASS '+$name)}
function Wait-Editor {$tts.Call('wait');if($tts.WaitFails){throw 'mock wait failed'}}
function Test-Wav($path){$tts.Call('wav');return 48}
function Backup-VoicePresets {if(-not $script:VoicePresetBackup){$script:backupCalls++;$script:VoicePresetBackup=[ordered]@{snapshot=$fixture;created_presets=@()}}}
function Save-PresetManifest {$script:manifestWrites++}
function Get-VoiceBackupRoot {return $fixture}
function Reset-Mock {
 $script:tts=New-Object EmotionMockHost
 $script:VoicePresetBackup=$null;$script:backupCalls=0;$script:manifestWrites=0
 $script:originalMaster=$tts.MasterControl;$script:originalText=$tts.Text;$script:originalPreset=$tts.CurrentVoicePresetName
 $tts.Calls.Clear();$tts.Counts.Clear()
 $lease=Get-VoiceListLeasePath;if([IO.File]::Exists($lease)){[IO.File]::Delete($lease)}
}
function Profile($emotion='normal',$text='これはテスト。') {
 return [pscustomobject]@{emotion=$emotion;text=$text;style=0.55;speed=1.1;pitch=1.03;volume=0.98;pitch_range=1.1;middle_pause=150;long_pause=370;sentence_pause=800}
}
function Request($segments=$null) {
 $value=Profile 'normal' 'これはテスト。'
 Add-Member -InputObject $value -MemberType NoteProperty -Name id -Value ([Guid]::NewGuid().ToString('N'))
 Add-Member -InputObject $value -MemberType NoteProperty -Name out -Value (Join-Path $fixture ([Guid]::NewGuid().ToString('N')+'.wav'))
 if($null -ne $segments){$value.text=($segments|ForEach-Object{$_.text})-join '';Add-Member -InputObject $value -MemberType NoteProperty -Name segments -Value @($segments)}
 return $value
}
function Assert-Restored {
 Assert ($tts.MasterControl -ceq $script:originalMaster) 'MasterControl was not restored'
 Assert ($tts.Text -ceq $script:originalText) 'Editor text was not restored'
 Assert ($tts.CurrentVoicePresetName -ceq $script:originalPreset) 'Current voice preset was not restored'
 Assert ($tts.TextEditMode -eq [AI.Talk.Editor.Api.TextEditMode]::Text) 'Editor mode was not restored'
}
function Error-Code([scriptblock]$body){try{& $body|Out-Null;return ''}catch{return [string]$_.Exception.Data['VoiceCode']}}
try {
 Case 'Legacy single-text request keeps its original protocol and restores editor state' {
  $req=Request;$req.PSObject.Properties.Remove('style')
  $result=Invoke-VoiceRequest $req
  Assert ($result.mode -eq 'single' -and $tts.SaveAttempts -eq 1 -and $tts.Adds -eq 0) 'Legacy path changed'
  Assert-Restored
 }
 Case 'List request selects all rows and performs one export with neutral Master effects' {
  $result=Invoke-VoiceRequest (Request @((Profile 'happy' 'やった！'),(Profile 'sad' 'そうなんだ。'),(Profile 'teasing' '聞いてる？')))
  Assert ($result.mode -eq 'list' -and $tts.SaveAttempts -eq 1 -and $tts.Rows.Count -eq 0) 'List export/cleanup failed'
  Assert ($tts.Calls.Contains('range:0:3')) 'Range argument was not row count'
  Assert ($tts.Calls.IndexOf('set_mode') -lt $tts.Calls.IndexOf('add_row')) 'List mode was not set first'
  Assert ($tts.Calls.IndexOf('select_range') -lt $tts.Calls.IndexOf('save') -and $tts.Calls.IndexOf('save') -lt $tts.Calls.IndexOf('clear')) 'Export sequence changed'
  $master=$tts.LastSavedMaster|ConvertFrom-Json
  Assert ($master.Speed -eq 1 -and $master.Pitch -eq 1 -and $master.PitchRange -eq 1 -and $master.Volume -eq 1) 'Master effects were applied twice'
  Assert ($tts.Adds -eq 3 -and $script:backupCalls -eq 1) 'Preset creation/backup count wrong'
  Assert-Restored
 }
 Case 'Repeated prewarm profiles and segment requests never add duplicate presets' {
  $req=Request @((Profile 'happy' 'やった！'))
  Add-Member -InputObject $req -MemberType NoteProperty -Name profiles -Value @((Profile 'happy'),(Profile 'sad'),(Profile 'normal'))
  [void](Invoke-VoiceRequest $req);$added=$tts.Adds
  $req.out=Join-Path $fixture ([Guid]::NewGuid().ToString('N')+'.wav')
  [void](Invoke-VoiceRequest $req)
  Assert ($added -eq 3 -and $tts.Adds -eq 3 -and $script:backupCalls -eq 1) 'Repeated profile creation occurred'
 }
 Case 'Existing reserved-name collision is not overwritten' {
  $row=Profile 'happy' ('あ'*210);$normalized=Convert-VoiceProfile $row $true;$spec=Get-VoicePresetSpec $normalized
  $wrong=$spec.json|ConvertFrom-Json;$wrong.Speed=9;$old=$wrong|ConvertTo-Json -Depth 5 -Compress;$tts.Presets.Add($spec.name,$old)
  $code=Error-Code {Invoke-VoiceRequest (Request @($row,(Profile 'sad' ('い'*210))))}
  Assert ($code -eq 'list_fallback_required' -and $tts.Presets[$spec.name] -ceq $old -and $tts.SaveAttempts -eq 0) 'Preset collision was overwritten or exported'
  Assert-Restored
 }
 Case 'Nonempty user list is preserved while short text uses safe Text fallback' {
  $tts.Rows.Add((New-Object EmotionMockRow -Property @{Preset='user-voice';Text='user work'}));$tts.TextEditMode=[AI.Talk.Editor.Api.TextEditMode]::List
  $result=Invoke-VoiceRequest (Request @((Profile 'happy' 'やった！')))
  Assert ($result.mode -eq 'single_fallback' -and $tts.Clears -eq 0 -and $tts.Rows.Count -eq 1 -and $tts.Rows[0].Text -eq 'user work') 'User list was modified'
  Assert ($tts.TextEditMode -eq [AI.Talk.Editor.Api.TextEditMode]::List -and $tts.Text -eq $originalText) 'Original List mode/text was not restored'
 }
 Case 'Nonempty user list and long text require caller chunk fallback without an export' {
  $tts.Rows.Add((New-Object EmotionMockRow -Property @{Preset='user-voice';Text='user work'}))
  $code=Error-Code {Invoke-VoiceRequest (Request @((Profile 'happy' ('あ'*210)),(Profile 'sad' ('い'*210))))}
  Assert ($code -eq 'list_fallback_required' -and $tts.Clears -eq 0 -and $tts.SaveAttempts -eq 0 -and $tts.Rows.Count -eq 1) 'Long fallback touched the user list'
  Assert-Restored
 }
 Case 'Add failure after a partial row is cleaned before Text fallback' {
  $tts.FailPoint='add_row';$tts.FailAfterRow=$true
  $result=Invoke-VoiceRequest (Request @((Profile 'happy' 'やった！'),(Profile 'sad' 'そうなんだ。')))
  Assert ($result.mode -eq 'single_fallback' -and $tts.Rows.Count -eq 0 -and $tts.Clears -eq 1) 'Partially created row was not safely cleaned'
  Assert-Restored
 }
 Case 'A failed list export cleans its partial output before one Text fallback' {
  $tts.FailPoint='save'
  $result=Invoke-VoiceRequest (Request @((Profile 'happy' 'やった！'),(Profile 'sad' 'そうなんだ。')))
  Assert ($result.mode -eq 'single_fallback' -and $tts.SaveAttempts -eq 2 -and $tts.Rows.Count -eq 0) 'Text fallback did not recover failed export'
  Assert-Restored
 }
 Case 'List cleanup failure reports unsafe cleanup and never starts another export' {
  $tts.FailPoint='clear'
  $code=Error-Code {Invoke-VoiceRequest (Request @((Profile 'happy' 'やった！')))}
  Assert ($code -eq 'unsafe_cleanup' -and $tts.SaveAttempts -eq 1 -and $tts.Rows.Count -eq 1) 'Unsafe cleanup retried or erased data'
  Assert-Restored
 }
 Case 'Foreign rows introduced during export are preserved and block retry' {
  $tts.InjectForeignRow=$true
  $code=Error-Code {Invoke-VoiceRequest (Request @((Profile 'happy' 'やった！')))}
  Assert ($code -eq 'unsafe_cleanup' -and $tts.Clears -eq 0 -and $tts.SaveAttempts -eq 1 -and $tts.Rows.Count -eq 2) 'Foreign data was cleared'
  Assert-Restored
 }
 Case 'A killed bridge lease recovers exactly matching partial rows on the next List request' {
  $oldRows=New-Object Collections.Generic.List[object]
  foreach($p in @((Profile 'happy' 'やった！'),(Profile 'sad' 'そうなんだ。'))){$name=Ensure-VoicePreset (Convert-VoiceProfile $p $true);$oldRows.Add([pscustomobject]@{preset=$name;text=$p.text})}
  $oldLease=Write-VoiceListLease $oldRows.ToArray()
  $tts.TextEditMode=[AI.Talk.Editor.Api.TextEditMode]::List
  $tts.AddListItem($oldRows[0].preset,$oldRows[0].text)
  # Simulate a new bridge process attached to the same host after a hard kill:
  # no finally ran, and only the first of two expected rows was appended.
  $script:VoicePresetBackup=$null
  $result=Invoke-VoiceRequest (Request @((Profile 'calm' '落ち着いて。')))
  Assert ($result.mode -eq 'list' -and $tts.Clears -eq 2 -and $tts.Rows.Count -eq 0 -and -not [IO.File]::Exists((Get-VoiceListLeasePath))) 'Owned crash leftovers did not recover'
  Assert ($tts.MasterControl -ceq $originalMaster -and $tts.Text -ceq $originalText) 'Recovery applied old global settings'
 }
 Case 'A valid lease never clears an external row with a different text hash' {
  $p=Profile 'happy' 'やった！';$name=Ensure-VoicePreset (Convert-VoiceProfile $p $true)
  [void](Write-VoiceListLease @([pscustomobject]@{preset=$name;text=$p.text},[pscustomobject]@{preset=$name;text='二番。'}))
  $tts.Rows.Add((New-Object EmotionMockRow -Property @{Preset=$name;Text='user changed this row'}))
  $tts.Rows.Add((New-Object EmotionMockRow -Property @{Preset=$name;Text='二番。'}))
  $tts.SetListSelectionIndex(1)
  $result=Invoke-VoiceRequest (Request @((Profile 'normal' '短い文。')))
  Assert ($result.mode -eq 'single_fallback' -and $tts.Clears -eq 0 -and $tts.Rows.Count -eq 2 -and $tts.Rows[0].Text -eq 'user changed this row') 'External text was cleared'
  Assert ($tts.Selected -eq 1 -and $tts.SelectedCount -eq 1 -and [IO.File]::Exists((Get-VoiceListLeasePath))) 'Nonmatching list selection or lease was changed'
 }
 Case 'An expired matching lease is preserved and cannot authorize clearing rows' {
  $p=Profile 'happy' 'やった！';$name=Ensure-VoicePreset (Convert-VoiceProfile $p $true)
  [void](Write-VoiceListLease @([pscustomobject]@{preset=$name;text=$p.text}))
  $path=Get-VoiceListLeasePath;$lease=[IO.File]::ReadAllText($path)|ConvertFrom-Json
  $lease.utc=[DateTimeOffset]::UtcNow.AddMinutes(-31).ToString('o',[Globalization.CultureInfo]::InvariantCulture)
  [IO.File]::WriteAllText($path,($lease|ConvertTo-Json -Depth 5 -Compress))
  $tts.Rows.Add((New-Object EmotionMockRow -Property @{Preset=$name;Text=$p.text}))
  $result=Invoke-VoiceRequest (Request @((Profile 'normal' '短い文。')))
  Assert ($result.mode -eq 'single_fallback' -and $tts.Clears -eq 0 -and $tts.Rows.Count -eq 1 -and [IO.File]::Exists($path)) 'Expired lease authorized a destructive cleanup'
 }
 Case 'An empty host list safely removes an invalid old lease before starting a new request' {
  $path=Get-VoiceListLeasePath;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllText($path,'invalid old lease')
  $result=Invoke-VoiceRequest (Request @((Profile 'normal' '短い文。')))
  Assert ($result.mode -eq 'list' -and -not [IO.File]::Exists($path)) 'Empty-list lease cleanup did not recover'
 }
 Case 'Lease writes are atomic replacements containing hashes without spoken text' {
  $p=Profile 'happy' '秘密のテスト。';$name=Ensure-VoicePreset (Convert-VoiceProfile $p $true);$expected=@([pscustomobject]@{preset=$name;text=$p.text})
  $first=Write-VoiceListLease $expected;$second=Write-VoiceListLease $expected
  $path=Get-VoiceListLeasePath;$raw=[IO.File]::ReadAllText($path);$lease=$raw|ConvertFrom-Json
  Assert ($first -cne $second -and $lease.lease_id -ceq $second -and $lease.expected[0].text_sha256 -ceq (Get-VoiceTextHash $p.text)) 'Atomic lease replacement or hash failed'
  Assert ($raw -notmatch [regex]::Escape($p.text) -and @([IO.Directory]::GetFiles([IO.Path]::GetDirectoryName($path),'*.tmp')).Count -eq 0) 'Lease leaked text or left a temporary file'
  Remove-VoiceListLease $second
  Assert (-not [IO.File]::Exists($path)) 'Matching lease was not removed'
 }
 Case 'A mismatching lease id is never removed by normal request cleanup' {
  $p=Profile 'normal';$name=Ensure-VoicePreset (Convert-VoiceProfile $p $true)
  $id=Write-VoiceListLease @([pscustomobject]@{preset=$name;text=$p.text})
  Assert ((Error-Code {Remove-VoiceListLease ('0'*32)}) -eq 'unsafe_cleanup' -and [IO.File]::Exists((Get-VoiceListLeasePath))) 'Another request lease was deleted'
  Remove-VoiceListLease $id
 }
 foreach($point in @('get_count','add_preset','add_row','select_range','get_selection_count','save','wav','get_row_preset','get_row_text')) {
  Case ('Fault at '+$point+' always attempts all editor restoration fields') {
   $tts.FailPoint=$point
   try{Invoke-VoiceRequest (Request @((Profile 'happy' 'やった！'),(Profile 'sad' 'そうなんだ。')))|Out-Null}catch{}
   Assert ($tts.Calls.Contains('set_master') -and $tts.Calls.Contains('set_current') -and $tts.Calls.Contains('set_text')) 'Finally did not attempt all state restoration'
   Assert-Restored
  }
 }
 foreach($definition in @(@('set_master',3),@('set_current',1),@('set_mode',3),@('set_text',1))) {
  Case ('Restoration failure at '+$definition[0]+' blocks success while other fields are attempted') {
   $tts.FailPoint=$definition[0];$tts.FailOccurrence=$definition[1]
   $code=Error-Code {Invoke-VoiceRequest (Request @((Profile 'happy' 'やった！')))}
   Assert ($code -eq 'unsafe_cleanup') 'A failed restoration returned success'
   Assert ($tts.Calls.Contains('set_master') -and $tts.Calls.Contains('set_current') -and $tts.Calls.Contains('set_text')) 'One restoration failure prevented other restorations'
  }
 }
 Case 'New profile numbers clamp and sentence pause follows long pause' {
  $p=Profile;$p.style=2;$p.speed=100;$p.pitch=-1;$p.volume=9;$p.pitch_range=0;$p.middle_pause=80;$p.long_pause=800;$p.sentence_pause=400
  $n=Convert-VoiceProfile $p $true
  Assert ($n.style -eq 1 -and $n.speed -eq 1.3 -and $n.pitch -eq 0.9 -and $n.volume -eq 2 -and $n.pitch_range -eq 0.8 -and $n.middle_pause -eq 80 -and $n.sentence_pause -eq 800) 'Profile clamps or pause relation failed'
 }
 Case 'Invalid segments and missing/nonfinite fields are rejected before editor calls' {
  $bad=Profile;$bad.PSObject.Properties.Remove('speed');$req=Request @($bad)
  Assert ((Error-Code {Invoke-VoiceRequest $req}) -eq 'missing_profile_parameter') 'Missing profile field accepted'
  $bad=Profile;$bad.style=[double]::NaN;$req=Request @($bad)
  Assert ((Error-Code {Invoke-VoiceRequest $req}) -eq 'invalid_profile_parameter') 'NaN accepted'
  $req=Request @((Profile));$req.text='different'
  Assert ((Error-Code {Invoke-VoiceRequest $req}) -eq 'segment_text_mismatch') 'Mismatched root text accepted'
  $req=Request @((Profile),(Profile),(Profile),(Profile),(Profile),(Profile),(Profile))
  Assert ((Error-Code {Invoke-VoiceRequest $req}) -eq 'invalid_segment_count') 'Seven segments accepted'
  Assert ($tts.Calls.Count -eq 0) 'Invalid request touched the editor'
 }
 Case 'Interior sentence-ending punctuation is rejected before any Editor access' {
  foreach($text in @('最初。次。','最初｡次。','最初！次。','最初？次。','first!next.','first?next.','本当！？','引用「そう。」')) {
   $req=Request @((Profile 'calm' $text))
   Assert ((Error-Code {Invoke-VoiceRequest $req}) -eq 'invalid_segment_sentence') 'A List row could trigger a modal sentence warning'
  }
  Assert ($tts.Calls.Count -eq 0 -and $tts.SaveAttempts -eq 0 -and $tts.Adds -eq 0) 'Rejected sentence reached the editor'
 }
 Case 'A single terminal sentence mark is allowed while legacy text may contain many sentences' {
  foreach($text in @('いいね。','いいね｡','すごい！','本当？','great!','really?','終端記号なし')) {
   $request=Convert-VoiceRequest (Request @((Profile 'normal' $text)))
   Assert ($request.segments.Count -eq 1) 'Single sentence was rejected'
  }
  $legacy=Request;$legacy.text='最初。次！最後？'
  $result=Invoke-VoiceRequest $legacy
  Assert ($result.mode -eq 'single' -and $tts.SaveAttempts -eq 1) 'Legacy multi-sentence Text mode changed'
 }
 Case 'Preset hash is culture independent and does not include unsupported SentencePause' {
  $p=Convert-VoiceProfile (Profile) $true;$a=Get-VoicePresetSpec $p
  $culture=[Threading.Thread]::CurrentThread.CurrentCulture
  try{[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('fr-FR');$p.sentence_pause=1200;$b=Get-VoicePresetSpec $p}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$culture}
  Assert ($a.name -ceq $b.name -and $a.json -notmatch 'SentencePause') 'Unsupported preset field or culture-sensitive hash'
 }
 Case 'Optional stage trace contains only a fixed stage and UTC and is inert when disabled' {
  $previous=[Environment]::GetEnvironmentVariable('DAFEIYU_VOICE_STAGE_PATH','Process')
  $path=Join-Path $fixture 'safe-stage.json'
  try {
   [Environment]::SetEnvironmentVariable('DAFEIYU_VOICE_STAGE_PATH',$path,'Process')
   Set-VoiceStage 'verify'
   $record=[IO.File]::ReadAllText($path)|ConvertFrom-Json
   Assert ($record.stage -ceq 'verify' -and $record.utc -match 'Z$' -and @($record.PSObject.Properties).Count -eq 2) 'Trace leaked fields or omitted UTC'
   $before=Get-VoiceFileHash $path
   [Environment]::SetEnvironmentVariable('DAFEIYU_VOICE_STAGE_PATH',$null,'Process')
   Set-VoiceStage 'list_save'
   Assert ((Get-VoiceFileHash $path) -ceq $before) 'Disabled trace wrote a file'
   [Environment]::SetEnvironmentVariable('DAFEIYU_VOICE_STAGE_PATH',$fixture,'Process')
   Set-VoiceStage 'append'
   Assert ($script:VoiceStage -ceq 'append') 'Diagnostic I/O failure affected the request stage'
  } finally {[Environment]::SetEnvironmentVariable('DAFEIYU_VOICE_STAGE_PATH',$previous,'Process')}
 }
 Case 'First actual file backup preserves original bytes and manifest, once only' {
  foreach($name in @('Backup-VoicePresets','Save-PresetManifest')){$d=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($d.Extent.Text))}
  function Get-VoiceBackupRoot{return $fixture}
  function Get-PresetStorePath{return (Join-Path $fixture 'source-user.vpc')}
  $vpc=Get-PresetStorePath;[IO.File]::WriteAllText($vpc,'mock original preset bytes')
  Backup-VoicePresets;$folder=$script:VoicePresetBackup.snapshot;Backup-VoicePresets
  Assert ($folder -ceq $script:VoicePresetBackup.snapshot) 'Backup was duplicated'
  Assert ((Get-FileHash -LiteralPath (Join-Path $folder 'user.vpc')).Hash -eq (Get-FileHash -LiteralPath $vpc).Hash) 'Preset backup did not preserve bytes'
  $manifest=Get-Content -LiteralPath (Join-Path $folder 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
  Assert ($manifest.original_present -and $manifest.restore_requires_editor_closed -and $manifest.original_sha256) 'Rollback metadata missing'
 }
 Case 'Preset backup still works when Get-FileHash is unavailable in the bridge environment' {
  foreach($name in @('Backup-VoicePresets','Save-PresetManifest')){$d=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($d.Extent.Text))}
  function Get-VoiceBackupRoot{return $fixture}
  function Get-PresetStorePath{return (Join-Path $fixture 'source-without-cmdlet.vpc')}
  function Get-FileHash {throw 'Get-FileHash intentionally unavailable'}
  $vpc=Get-PresetStorePath;[IO.File]::WriteAllText($vpc,'mock native environment regression')
  $expected=Get-VoiceFileHash $vpc
  Backup-VoicePresets
  $folder=$script:VoicePresetBackup.snapshot
  Assert ((Get-VoiceFileHash (Join-Path $folder 'user.vpc')) -ceq $expected) 'Streaming SHA256 failed without module cmdlet'
  Assert ([IO.File]::Exists((Join-Path $folder 'manifest.json'))) 'Missing cmdlet still blocked manifest creation'
 }
} finally {
 $resolved=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath($PSScriptRoot)+'\'
 if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output ('OK '+$script:passed+' List bridge tests; PowerShell '+$PSVersionTable.PSVersion.ToString())
