param([int]$Limit = 0)
$ErrorActionPreference = 'Stop'
$python = & (Join-Path $PSScriptRoot 'tools\Resolve-Python.ps1') -RequirePymobiledevice3
$pullScript = Join-Path $PSScriptRoot 'tools\pull_latest_recording.py'
$postScript = Join-Path $PSScriptRoot 'postprocess-take.ps1'
Write-Host 'Pulling newest Depth Recorder take (read-only from iPhone)...'
$pullOutput = & $python $pullScript --quiet 2>&1
$code = $LASTEXITCODE
$pullOutput | ForEach-Object { Write-Host $_ }
if ($code -ne 0) { throw "Phone transfer failed with exit code $code" }
$line = $pullOutput | Where-Object { "$_" -like 'Pulled: *' } | Select-Object -Last 1
if (-not $line) { throw 'Could not determine local recording path.' }
$package = ("$line").Substring('Pulled: '.Length).Trim()
if ($Limit -gt 0) { & $postScript -Package $package -Limit $Limit } else { & $postScript -Package $package }
