# A5/A6 — OSM refresh (maps, speed cameras, hazards, fuel stations, pause spots) + GraphHopper re-import.
# Scheduled every 4 weeks by the Windows task « MotoTrip - mise a jour cartes et radars » (see README).
# Coverage: the Geofabrik extracts listed in companion\maps.txt (one per line); add a country there, then run this.
# The new graph is built NEXT TO the running one (/graphs/new in the Docker volume mototrip-graphs) and swapped at
# the end: routing stays available. A run stopped midway can simply be started again (fresh downloads are reused).
param(
    [string[]]$Extracts = @(),
    [string]$Heap = "16g"
)
$ErrorActionPreference = "Stop"
# Any failure is written to the log (update_osm.log) before stopping; the map in service is never touched.
trap { Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ÉCHEC : $_"; exit 1 }
$companion = Split-Path -Parent $PSScriptRoot
$data = Join-Path $companion "data"
$osmDir = Join-Path $data "osm"
New-Item -ItemType Directory -Force -Path $osmDir | Out-Null
if ($Extracts.Count -eq 0) {
    $Extracts = Get-Content (Join-Path $companion "maps.txt") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") }
}
if ($Extracts.Count -eq 0) { throw "Aucune carte dans companion\maps.txt" }

# Docker Desktop may be installed per user and not be on PATH.
$dockerBin = Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\bin"
if (Test-Path $dockerBin) { $env:Path = "$dockerBin;$env:Path" }

function Step($text) { Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $text" }

# Runs a native program (curl, docker). Windows PowerShell 5.1 turns every line a native program writes on stderr
# into a terminating error when the output is redirected (the scheduled task logs with *>) — docker and curl print
# progress there, which silently killed the job. Only the exit code decides; the output goes to the log.
function Run([string]$failure, [scriptblock]$command) {
    $ErrorActionPreference = "Continue"
    & $command 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$failure (code $LASTEXITCODE)" }
}

# 1. Download every extract (fresh copy, resumable; a copy younger than 20 h is reused).
$files = @()
foreach ($extract in $Extracts) {
    $name = ($extract -split "/")[-1]
    $tmp = Join-Path $osmDir "$name.osm.pbf.download"
    $dst = Join-Path $osmDir "$name.osm.pbf"
    $files += "$name.osm.pbf"
    if ((Test-Path $dst) -and (Get-Item $dst).LastWriteTime -gt (Get-Date).AddHours(-20)) {
        Step "Carte récente déjà téléchargée : $extract"
        continue
    }
    Step "Téléchargement $extract"
    Run "Échec du téléchargement de $extract (nom exact sur download.geofabrik.de ?)" {
        curl.exe -L --fail --retry 5 -C - -sS -o $tmp "https://download.geofabrik.de/$extract-latest.osm.pbf"
    }
    Move-Item -Force $tmp $dst
}

# 2. Merge (overlapping extracts are fine) + extract speed cameras, hazards, fuel stations, pause spots, seasonal
#    road closures and mountain passes.
Step "Fusion et extraction des points (radars, dangers, stations, pauses)"
$sh = @"
set -e
apt-get update -qq >/dev/null && apt-get install -y -qq osmium-tool >/dev/null 2>&1
cd /osm
osmium merge $($files -join ' ') -o region.new.osm.pbf --overwrite
osmium tags-filter region.new.osm.pbf n/highway=speed_camera n/hazard nwr/amenity=fuel nwr/amenity=cafe nwr/tourism=viewpoint n/amenity=drinking_water -o /tmp/poi.pbf --overwrite
osmium tags-filter /tmp/poi.pbf n/highway=speed_camera -o /tmp/c.pbf --overwrite && osmium export /tmp/c.pbf -f geojsonseq -o speed_cameras.new --overwrite
osmium tags-filter /tmp/poi.pbf n/hazard -o /tmp/h.pbf --overwrite && osmium export /tmp/h.pbf -f geojsonseq -o hazards.new --overwrite
osmium tags-filter /tmp/poi.pbf nwr/amenity=fuel -o /tmp/f.pbf --overwrite && osmium export /tmp/f.pbf -f geojsonseq -o fuel_stations.new --overwrite
osmium tags-filter /tmp/poi.pbf nwr/amenity=cafe nwr/tourism=viewpoint n/amenity=drinking_water -o /tmp/p.pbf --overwrite && osmium export /tmp/p.pbf -f geojsonseq -o pauses.new --overwrite
osmium tags-filter region.new.osm.pbf w/access:conditional w/motor_vehicle:conditional w/vehicle:conditional w/motorcar:conditional w/motorcycle:conditional n/mountain_pass=yes -o /tmp/s.pbf --overwrite
osmium tags-filter /tmp/s.pbf w/highway -o /tmp/closed.pbf --overwrite && osmium export /tmp/closed.pbf -f geojsonseq -o closures.new --overwrite
osmium tags-filter /tmp/s.pbf n/mountain_pass=yes -o /tmp/passes.pbf --overwrite && osmium export /tmp/passes.pbf -f geojsonseq -o passes.new --overwrite
"@
$sh = $sh -replace "`r", ""     # a checkout with Windows line endings must not reach sh (« set: Illegal option »)
Run "Échec de la fusion / extraction osmium" { docker run --rm -v "${osmDir}:/osm" debian:bookworm-slim sh -c $sh }
Move-Item -Force (Join-Path $osmDir "region.new.osm.pbf") (Join-Path $osmDir "region.osm.pbf")
# The downloads are merged into region.osm.pbf and fetched fresh next time: free the disk.
foreach ($f in $files) { Remove-Item -Force (Join-Path $osmDir $f) -ErrorAction SilentlyContinue }

Push-Location $companion
try {
    # 3. Build the new graph next to the running one.
    Step "Import GraphHopper dans le volume (/graphs/new)"
    Run "Échec de l'import GraphHopper (la carte actuelle reste en service)" {
        docker compose run --rm --no-deps -e "JAVA_OPTS=-Xmx$Heap -Xms1g" graphhopper sh -c "rm -rf /graphs/new && java `$JAVA_OPTS -Ddw.graphhopper.datareader.file=/data/osm/region.osm.pbf -Ddw.graphhopper.graph.location=/graphs/new -jar /opt/graphhopper-web.jar import /opt/config.yml"
    }

    # 4. Swap graph and point files, restart the router, clean up.
    Step "Bascule vers la nouvelle carte"
    Run "Arrêt du routeur impossible" { docker compose stop graphhopper }
    Run "Échec de la bascule (volume mototrip-graphs)" {
        docker compose run --rm --no-deps graphhopper sh -c "rm -rf /graphs/old; if [ -d /graphs/current ]; then mv /graphs/current /graphs/old; fi; mv /graphs/new /graphs/current"
    }
    foreach ($kind in "speed_cameras", "hazards", "fuel_stations", "pauses", "closures", "passes") {
        Move-Item -Force (Join-Path $osmDir "$kind.new") (Join-Path $osmDir "$kind.geojsonseq")
    }
    Run "Redémarrage du routeur impossible" { docker compose up -d graphhopper }
    Run "Nettoyage de l'ancienne carte impossible" { docker compose run --rm --no-deps graphhopper sh -c "rm -rf /graphs/old" }
} finally {
    Pop-Location
}

# 5. Free the disk: the merged map (≈ 16 GB) only served this import (the next update downloads fresh copies), and
# data\graph-cache is the graph of the first versions, before it moved to the Docker volume.
Step "Nettoyage du disque"
Remove-Item -Force (Join-Path $osmDir "region.osm.pbf") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $data "graph-cache") -ErrorAction SilentlyContinue
Step "OK — nouvelle carte en service (GraphHopper redémarre en 1 à 2 minutes). Cartes : $($Extracts -join ', ')"
