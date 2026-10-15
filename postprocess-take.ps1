param(
    [Parameter(Mandatory=$true)][string]$Package,
    [int]$Limit = 0,
    [switch]$Rerender
)
$ErrorActionPreference = 'Stop'
$packagePath = (Resolve-Path -LiteralPath $Package).Path
$python = & (Join-Path $PSScriptRoot 'tools\Resolve-Python.ps1')
$inspect = Join-Path $PSScriptRoot 'tools\inspect_recording.py'
$renderer = Join-Path $PSScriptRoot 'tools\render_natural_dof.py'
$sync = Join-Path $PSScriptRoot 'tools\sync_report.py'
foreach ($required in @('master.mov','frames.jsonl')) {
    if (-not (Test-Path -LiteralPath (Join-Path $packagePath $required))) { throw "Not a valid recording package; missing $required" }
}

Write-Host "Validating $packagePath"
& $python $inspect $packagePath --sample-depth
if ($LASTEXITCODE -ne 0) { throw 'Recording validation failed. Source package was preserved unchanged.' }

$manifestPath = Join-Path $packagePath 'manifest.json'
$hasDepth = Test-Path -LiteralPath (Join-Path $packagePath 'depth.bin')
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($null -ne $manifest.depth_available) { $hasDepth = [bool]$manifest.depth_available }
}

$output = Join-Path $packagePath $(if($Limit -gt 0){"cinematic_natural_test_$Limit.mov"}else{'cinematic_natural.mov'})
if ($hasDepth) {
    if ((Test-Path -LiteralPath $output) -and $Rerender) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmssZ')
        $output = Join-Path $packagePath "cinematic_natural_$stamp.mov"
    }
    if (Test-Path -LiteralPath $output) { Write-Host "Render already exists; preserving it: $output" }
    else {
        $args = @($renderer,$packagePath,$output)
        if ($Limit -gt 0) { $args += @('--limit',"$Limit") }
        & $python @args
        if ($LASTEXITCODE -ne 0) { throw 'Natural DOF render failed. Source package was preserved unchanged.' }
    }
} else {
    Write-Host 'RGB-only lens take: LiDAR cinematic rendering is intentionally skipped.'
}

if (Test-Path -LiteralPath (Join-Path $packagePath 'obs_sync.json')) {
    & $python $sync $packagePath
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Alignment report failed.' }
}
Write-Host "Done: $packagePath"
