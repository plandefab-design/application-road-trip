# SwiftLint on this PC (Docker Desktop required): same check as the « Swift lint » CI job.
# Run it with:  powershell -ExecutionPolicy Bypass -File scriptslint-swift.ps1  (Bypass applies to this command only)
$docker = "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin\docker.exe"
if (-not (Test-Path $docker)) { $docker = "docker" }
$repo = (Resolve-Path "$PSScriptRoot\..").Path
& $docker run --rm -v "${repo}:/src:ro" -w /src ghcr.io/realm/swiftlint@sha256:b8f3cf76353336c048f133aa5b02f5c35c6984b9e6451e906fb8f8c9f92bb30b lint --strict --no-cache --quiet
