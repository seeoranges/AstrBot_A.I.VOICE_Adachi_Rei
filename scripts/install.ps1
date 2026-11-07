param(
    [Parameter(Mandatory=$true)][string]$Dir,
    [ValidateSet('voice','proactive','support','ops')][string]$Component = 'voice'
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$target = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $target 'astrbot\data') -PathType Container)) {
    throw 'Target must be an existing installation with astrbot\data.'
}
if ($target -eq $repo -or $target.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The runtime must be outside this source repository.'
}
$files = @{}
function Add-File([string]$From,[string]$To) { $script:files[$To] = (Join-Path $repo $From) }
function Get-SourceHash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Get-TextHash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $text = [IO.File]::ReadAllText($Path).Replace("`r`n","`n")
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')
    } finally { $sha.Dispose() }
}
switch ($Component) {
    'voice' {
        foreach ($name in @('main.py','metadata.yaml','_conf_schema.json')) {
            $rel = 'plugins\astrbot_plugin_adachi_aivoice\'+$name
            Add-File $rel ('astrbot\data\'+$rel)
        }
        Add-File 'tools\aivoice-daemon.ps1' 'tools\aivoice-daemon.ps1'
    }
    'proactive' {
        $rel = 'astrbot\data\plugins\astrbot_plugin_proactive_chat\core\services\sender_service.py'
        $source = 'integrations\astrbot_plugin_proactive_chat\core\services\sender_service.py'
        if (-not (Test-Path -LiteralPath (Join-Path $target $rel) -PathType Leaf)) { throw 'Install upstream Proactive Chat first.' }
        $hash = Get-TextHash (Join-Path $target $rel)
        $baseline = (Get-Content -Raw -LiteralPath (Join-Path $repo 'integrations\astrbot_plugin_proactive_chat\baseline.json') | ConvertFrom-Json).sha256
        $current = Get-TextHash (Join-Path $repo $source)
        if ($hash -ne $baseline -and $hash -ne $current) { throw 'Upstream file differs from the known baseline. Review the patch manually.' }
        Add-File $source $rel
    }
    'support' {
        foreach ($folder in Get-ChildItem -LiteralPath (Join-Path $repo 'plugins') -Directory -Filter 'astrbot_plugin_dafeiyu_*') {
            foreach ($file in Get-ChildItem -LiteralPath $folder.FullName -File -Recurse) {
                $relative = $file.FullName.Substring($repo.Length+1)
                Add-File $relative ('astrbot\data\'+$relative)
            }
        }
    }
    'ops' {
        if (-not (Test-Path -LiteralPath (Join-Path $target 'start-astrbot.cmd') -PathType Leaf)) { throw 'The ops component requires the original installation launchers.' }
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo 'tools') -File) { Add-File ('tools\'+$file.Name) ('tools\'+$file.Name) }
        foreach ($name in @('启动大肥鱼.cmd','关闭大肥鱼.cmd')) { Add-File $name $name }
    }
}
# Reject junctions/symlinks in destination ancestors before any write.
foreach ($relative in $files.Keys) {
    if (-not (Test-Path -LiteralPath $files[$relative] -PathType Leaf)) { throw 'Missing source file.' }
    if (Test-Path -LiteralPath (Join-Path $target $relative) -PathType Container) { throw 'A destination file is a directory.' }
}
$pathsToCheck = @($files.Keys | ForEach-Object { Join-Path $target $_ }) + @(Join-Path $target 'private\snapshots')
foreach ($pathToCheck in $pathsToCheck) {
    $check = $pathToCheck
    while ($check) {
        if (Test-Path -LiteralPath $check) {
            if (((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse point in destination path.' }
        }
        $parent = Split-Path -Parent $check
        if ($parent -eq $check) { break }
        $check = $parent
    }
}
$snapshot = Join-Path $target ('private\snapshots\github-install-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$entries = @()
New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
foreach ($relative in ($files.Keys | Sort-Object)) {
    $dest = Join-Path $target $relative
    $existed = Test-Path -LiteralPath $dest -PathType Leaf
    if ($existed) {
        $backup = Join-Path $snapshot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        Copy-Item -LiteralPath $dest -Destination $backup
    }
    $entries += [pscustomobject]@{path=$relative;existed=$existed}
}
$entries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $snapshot 'manifest.json') -Encoding UTF8
$written = @()
try {
    foreach ($entry in $entries) {
        $dest = Join-Path $target $entry.path
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        $written += $entry
        Copy-Item -LiteralPath $files[$entry.path] -Destination $dest -Force
        if ((Get-SourceHash $dest) -ne (Get-SourceHash $files[$entry.path])) { throw 'File copy verification failed.' }
    }
} catch {
    $restoreFailed = $false
    foreach ($entry in $written) {
        try {
            $dest = Join-Path $target $entry.path
            if ($entry.existed) { Copy-Item -LiteralPath (Join-Path $snapshot $entry.path) -Destination $dest -Force }
            elseif (Test-Path -LiteralPath $dest -PathType Leaf) { Remove-Item -LiteralPath $dest -Force }
        } catch { $restoreFailed = $true }
    }
    if ($restoreFailed) { Write-Warning ('Some files require manual recovery from '+$snapshot) }
    throw 'Installation failed; previous files were restored where possible.'
}
Write-Host ('Installed component: '+$Component)
Write-Host ('Backup: '+$snapshot)
Write-Host 'Reload the affected plugins yourself. No processes or scheduled tasks were changed.'
