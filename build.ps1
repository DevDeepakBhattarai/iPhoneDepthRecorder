param(
    [switch]$Release,
    [string]$TheosRoot = (Join-Path $env:USERPROFILE '.theos\theos'),
    [string]$MsysBash = 'C:\msys64\usr\bin\bash.exe'
)
$ErrorActionPreference = 'Stop'
$Project = Split-Path -Parent $MyInvocation.MyCommand.Path

function Convert-ToMsysPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "Unsupported Windows path: $full" }
    return '/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '\\','/')
}

if (!(Test-Path -LiteralPath $MsysBash)) { throw "MSYS2 bash not found: $MsysBash" }
if (!(Test-Path -LiteralPath (Join-Path $TheosRoot 'makefiles\common.mk'))) { throw "Theos not found: $TheosRoot" }

$unixProject = Convert-ToMsysPath $Project
$unixTheos = Convert-ToMsysPath $TheosRoot
$mode = if ($Release) { 'FINALPACKAGE=1' } else { '' }
$cmd = "export THEOS='$unixTheos'; export PATH=`"`$THEOS/toolchain/windows/iphone/bin:`$PATH`"; cd '$unixProject'; /usr/bin/make clean all $mode"
& $MsysBash -lc $cmd
if ($LASTEXITCODE -ne 0) { throw "Theos build failed with exit code $LASTEXITCODE" }

$app = Join-Path $Project '.theos\obj\debug\DepthRecorder.app'
if ($Release) { $app = Join-Path $Project '.theos\obj\DepthRecorder.app' }
if (!(Test-Path -LiteralPath $app)) {
    $app = Get-ChildItem (Join-Path $Project '.theos\obj') -Recurse -Directory -Filter 'DepthRecorder.app' |
        Select-Object -First 1 -ExpandProperty FullName
}
if (!$app -or !(Test-Path -LiteralPath $app)) { throw 'Built .app not found' }

$python = Join-Path $Project '.venv\Scripts\python.exe'
if (!(Test-Path -LiteralPath $python)) {
    $cmdPython = Get-Command python -ErrorAction SilentlyContinue
    if (!$cmdPython) { throw 'Python not found. Create .venv or install Python 3.' }
    $python = $cmdPython.Source
}
$ipa = Join-Path $Project 'DepthRecorder-unsigned.ipa'
& $python (Join-Path $Project 'tools\package_ipa.py') $app $ipa
if ($LASTEXITCODE -ne 0) { throw 'IPA packaging failed' }
Write-Host "Built unsigned IPA: $ipa"
