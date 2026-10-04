# Runs the app's group logic tests (Supabase client, group session) on this PC in ~15 s (Docker Desktop required),
# instead of waiting for the iOS build. SwiftUI / LiveKit / MapLibre code is not covered: only the CI compiles it.
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\test-app-logic.ps1            (Bypass: this command only)
#         powershell -ExecutionPolicy Bypass -File scripts\test-app-logic.ps1 -Filter GroupSessionTests
param([string]$Filter = "")

$docker = "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin\docker.exe"
if (-not (Test-Path $docker)) { $docker = "docker" }
$repo = (Resolve-Path "$PSScriptRoot\..").Path

& $docker run --rm -e "FILTER=$Filter" -v "${repo}:/repo:ro" -v mototrip-swiftbuild:/build swift:6.1-noble sh /repo/scripts/app-logic/harness.sh
