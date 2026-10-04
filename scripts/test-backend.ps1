# Tests the group server's schema and access rules on this PC in ~15 s (Docker Desktop required): a throw-away
# PostgreSQL, the Supabase stand-ins, schema.sql applied twice (it must be re-runnable), then the isolation scenarios.
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\test-backend.ps1   (Bypass: this command only)
$docker = "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin\docker.exe"
if (-not (Test-Path $docker)) { $docker = "docker" }
$backend = (Resolve-Path "$PSScriptRoot\..\backend\supabase").Path
$name = "mototrip-pgtest"

& $docker rm -f $name 2>$null | Out-Null
& $docker run -d --name $name -e POSTGRES_PASSWORD=test postgres:16 | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    & $docker exec $name pg_isready -U postgres 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 1
}
Start-Sleep -Seconds 2
& $docker cp "$backend\tests" "${name}:/tests"
& $docker cp "$backend\schema.sql" "${name}:/schema.sql"

$ok = $true
foreach ($file in @("/tests/stub.sql", "/schema.sql", "/schema.sql", "/tests/isolation.sql")) {
    & $docker exec $name psql -U postgres -v ON_ERROR_STOP=1 -q -f $file 2>&1 |
        Where-Object { $_ -match "FAIL|ERROR" -or $_ -match "ok   " } | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $ok = $false; Write-Host "FAILED: $file"; break }
}
& $docker rm -f $name | Out-Null
if ($ok) { Write-Host "Backend tests: all green" } else { exit 1 }
