#requires -version 5.1
$ErrorActionPreference = 'Stop'

$ProjectRoot = $PSScriptRoot
$Python = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$Config = Join-Path $ProjectRoot 'accessibility_overlay.json'

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw 'Missing .venv\Scripts\python.exe. Run the existing Voice Writer bootstrap first.'
}
if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    throw 'Missing accessibility_overlay.json. Copy accessibility_overlay.example.json first.'
}

$env:PYTHONPATH = Join-Path $ProjectRoot 'src'
& $Python -m wpt --accessibility-ui --accessibility-config $Config --tts-device Soundcore --auto-paste
exit $LASTEXITCODE
