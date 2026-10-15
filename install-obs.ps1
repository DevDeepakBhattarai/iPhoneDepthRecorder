param([string]$ObsScriptRoot = (Join-Path $env:APPDATA 'obs-studio\scripts\DepthRecorder'))
$ErrorActionPreference = 'Stop'
$Project = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceLua = Join-Path $Project 'obs\depth-recorder-sync.lua'
if (!(Test-Path -LiteralPath $SourceLua)) { throw "Missing $SourceLua" }
New-Item -ItemType Directory -Force -Path $ObsScriptRoot | Out-Null
Copy-Item -Force $SourceLua (Join-Path $ObsScriptRoot 'depth-recorder-sync.lua')
$escaped = $Project.Replace('%','%%')
$proxy = @"
@echo off
setlocal
set "DEPTHRECORDER_PROJECT=$escaped"
call "$escaped\obs\obs-depthrecorder-event.cmd" %*
endlocal
"@
[IO.File]::WriteAllText((Join-Path $ObsScriptRoot 'obs-depthrecorder-event.cmd'), $proxy, [Text.UTF8Encoding]::new($false))
Write-Host "OBS integration installed to: $ObsScriptRoot"
Write-Host "In OBS: Tools -> Scripts -> + -> $ObsScriptRoot\depth-recorder-sync.lua"
