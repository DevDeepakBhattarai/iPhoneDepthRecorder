param([string]$Destination = (Join-Path (Split-Path -Parent $PSScriptRoot) 'models\u2net_human_seg.onnx'))
$ErrorActionPreference = 'Stop'
$url = 'https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net_human_seg.onnx'
$sha256 = '01EB6A29A5C4D8EDB30B56ADAD9BB3A2A0535338E480724A213E0ACFD2D1C73C'
$dir = Split-Path -Parent $Destination
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$tmp = "$Destination.download"
Invoke-WebRequest -Uri $url -OutFile $tmp
$actual = (Get-FileHash -Algorithm SHA256 $tmp).Hash.ToUpperInvariant()
if ($actual -ne $sha256) {
    throw "U2Net model checksum mismatch. Expected $sha256, got $actual"
}
Move-Item -Force $tmp $Destination
Write-Host "Model ready: $Destination"
