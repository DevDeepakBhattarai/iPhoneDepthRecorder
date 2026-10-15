param(
    [string]$Root = (Join-Path $(if($env:DEPTHRECORDER_DATA_ROOT){$env:DEPTHRECORDER_DATA_ROOT}else{Join-Path $env:USERPROFILE 'Videos\DepthRecorder'}) 'device-captures'),
    [switch]$Rerender
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Root)) { throw "Capture root not found: $Root" }
$takeScript = Join-Path $PSScriptRoot 'postprocess-take.ps1'
$packages = Get-ChildItem -LiteralPath $Root -Directory -Recurse | Where-Object {
    (Test-Path -LiteralPath (Join-Path $_.FullName 'master.mov')) -and
    (Test-Path -LiteralPath (Join-Path $_.FullName 'frames.jsonl'))
} | Sort-Object FullName -Unique
if (-not $packages) { Write-Host "No recording packages found under $Root"; exit 0 }
Write-Host ("Found {0} package(s)." -f $packages.Count)
foreach ($package in $packages) {
    Write-Host "`n=== $($package.FullName) ==="
    if ($Rerender) { & $takeScript -Package $package.FullName -Rerender }
    else { & $takeScript -Package $package.FullName }
}
