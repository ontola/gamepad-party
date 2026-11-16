param(
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][string]$TargetDir,
    [ValidateSet("dev", "ci", "release")][string]$BuildProfile = "dev",
    # The Warp Game Room lobby: game-room.exe built from ontola/warp-game-engine
    # (cargo build --release -p game-room). It is the only lobby.
    [Parameter(Mandatory=$true)][string]$GameRoom
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$env:CARGO_TARGET_DIR = $TargetDir
& cargo build --locked --profile $BuildProfile --manifest-path (Join-Path $repo 'Cargo.toml') -p gamenight-daemon
if ($LASTEXITCODE -ne 0) { throw 'Daemon build failed' }
if (Test-Path -LiteralPath $OutputDir) { throw 'Choose a new output directory; packages are never overwritten.' }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
$packageDir = Join-Path $OutputDir 'package'
if (!(Test-Path -LiteralPath $GameRoom -PathType Leaf)) { throw "Warp Game Room not found: $GameRoom" }
$roomOut = Join-Path $OutputDir 'warp-game-room'
New-Item -ItemType Directory -Path $roomOut | Out-Null
Copy-Item -LiteralPath $GameRoom -Destination (Join-Path $roomOut 'game-room.exe')
$packageArgs = @('--target', $TargetDir, '--output', $packageDir, '--profile', $BuildProfile, '--game-room', $roomOut)
& python (Join-Path $PSScriptRoot 'package-windows.py') @packageArgs
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
Copy-Item -LiteralPath (Join-Path $packageDir 'gamenight-windows-preview.zip'),(Join-Path $packageDir 'SHA256SUMS.txt') -Destination $OutputDir
