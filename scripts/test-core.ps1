# Runs the TripCore tests on this PC in ~10 s (Docker Desktop required), instead of waiting for the CI.
# The repository is mounted read-only; build output stays in the Docker volume « mototrip-swiftbuild ».
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\test-core.ps1            all tests (Bypass: this command only)
#         powershell -ExecutionPolicy Bypass -File scripts\test-core.ps1 -Filter Fuel   only the tests whose name contains « Fuel »
param([string]$Filter = "")

$docker = "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin\docker.exe"
if (-not (Test-Path $docker)) { $docker = "docker" }
$core = (Resolve-Path "$PSScriptRoot\..\core").Path
$swiftTest = if ($Filter) { "swift test --filter $Filter" } else { "swift test" }

& $docker run --rm -v "${core}:/src:ro" -v mototrip-swiftbuild:/build -w /build swift:6.1-noble sh -c `
    "rm -rf Sources Tests Package.swift && cp -r /src/Sources /src/Tests /src/Package.swift . && $swiftTest 2>&1 | grep -E 'error|failed|Executed' | tail -8"
