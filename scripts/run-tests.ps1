$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter 'test_*.ps1' -File | Sort-Object Name)
foreach ($file in $files) {
    Write-Host ('Testing ' + $file.Name)
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $file.FullName
    if ($LASTEXITCODE -ne 0) { throw ('Failed: ' + $file.Name) }
}
Write-Host ('Passed ' + $files.Count + ' PowerShell test files.')
