# Installs the freshly-built host over the installed copy in Program Files.
# Run from an ELEVATED PowerShell:  pwsh -File install-local-build.ps1
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'target\release\remote-desktop-host.exe'
$dst = 'C:\Program Files\Remote Desktop Host\remote-desktop-host.exe'

if (-not (Test-Path $src)) { throw "Build not found at $src. Run: cargo build --release" }

Write-Host "Stopping any running host..."
Get-Process remote-desktop-host -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

Write-Host "Copying $src -> $dst"
Copy-Item -Path $src -Destination $dst -Force

Write-Host "Launching updated host..."
Start-Process $dst
Write-Host "Done. Watch %LOCALAPPDATA%\RemoteDesktopHost\host.log for 'ICE selected pair' and 'peer connection state -> Connected'."
