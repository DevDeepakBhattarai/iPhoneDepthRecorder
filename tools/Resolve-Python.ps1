param([switch]$RequirePymobiledevice3)
$project = Split-Path -Parent $PSScriptRoot
$candidates = @(
    (Join-Path $project '.venv\Scripts\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'pymobiledevice3-pure\venv\Scripts\python.exe')
)
foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { Write-Output $candidate; exit 0 }
}
$cmd = Get-Command python -ErrorAction SilentlyContinue
if ($cmd) { Write-Output $cmd.Source; exit 0 }
throw 'Python not found. Create .venv and install requirements.txt.'
