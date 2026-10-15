$ErrorActionPreference = 'Stop'
$python = & (Join-Path $PSScriptRoot 'tools\Resolve-Python.ps1') -RequirePymobiledevice3
$script = Join-Path $PSScriptRoot 'tools\pull_latest_recording.py'
& $python $script @args
exit $LASTEXITCODE
