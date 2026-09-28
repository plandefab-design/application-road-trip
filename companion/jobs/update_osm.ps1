# A5/A6 — OSM refresh (maps, speed cameras, hazards, fuel stations, pause spots) + GraphHopper re-import.
# Scheduled every 4 weeks by the Windows task « MotoTrip - mise a jour cartes et radars » (see README).
# Coverage: about 4 000 km around Salon-de-Provence (Europe, Russia, North Africa, Near East) ≈ 43 GB download.
# The new graph is built NEXT TO the running one (graph-cache-new) and swapped at the end: routing stays available.
param(
    [string[]]$Extracts = @(
        "europe", "russia",
        "africa/morocco", "africa/algeria", "africa/tunisia", "africa/libya", "africa/egypt",
        "asia/israel-and-palestine", "asia/jordan", "asia/lebanon", "asia/syria"
    ),
    [string]$Heap = "20g"
)
$ErrorActionPreference = "Stop"
$companion = Split-Path -Parent $PSScriptRoot
$data = Join-Path $companion "data"
$osmDir = Join-Path $data "osm"
New-Item -ItemType Directory -Force -Path $osmDir | Out-Null

# Docker Desktop may be installed per user and not be on PATH.
$dockerBin = Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\bin"
if (Test-Path $dockerBin) { $env:Path = "$dockerBin;$env:Path" }

function Step($text) { Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $text" }

# 1. Download every extract (fresh copy, resumable).
$files = @()
foreach ($extract in $Extracts) {
    $name = ($extract -split "/")[-1]
    $tmp = Join-Path $osmDir "$name.osm.pbf.download"
    $dst = Join-Path $osmDir "$name.osm.pbf"
    Step "Téléchargement $extract"
    curl.exe -L --fail --retry 5 -C - -sS -o $tmp "https://download.geofabrik.de/$extract-latest.osm.pbf"
    if ($LASTEXITCODE -ne 0) { throw "Échec du téléchargement de $extract" }
    Move-Item -Force $tmp $dst
    $files += "$name.osm.pbf"
}

# 2. Merge + extract speed cameras, hazards, fuel stations and pause spots (osmium in a throwaway container).
Step "Fusion et extraction des points (radars, dangers, stations, pauses)"
$sh = @"
set -e
apt-get update -qq >/dev/null && apt-get install -y -qq osmium-tool >/dev/null
cd /osm
osmium merge $($files -join ' ') -o region-4000.osm.pbf.new --overwrite
osmium tags-filter region-4000.osm.pbf.new n/highway=speed_camera n/hazard nwr/amenity=fuel nwr/amenity=cafe nwr/tourism=viewpoint n/amenity=drinking_water -o /tmp/poi.pbf --overwrite
osmium tags-filter /tmp/poi.pbf n/highway=speed_camera -o /tmp/c.pbf --overwrite && osmium export /tmp/c.pbf -f geojsonseq -o speed_cameras.new --overwrite
osmium tags-filter /tmp/poi.pbf n/hazard -o /tmp/h.pbf --overwrite && osmium export /tmp/h.pbf -f geojsonseq -o hazards.new --overwrite
osmium tags-filter /tmp/poi.pbf nwr/amenity=fuel -o /tmp/f.pbf --overwrite && osmium export /tmp/f.pbf -f geojsonseq -o fuel_stations.new --overwrite
osmium tags-filter /tmp/poi.pbf nwr/amenity=cafe nwr/tourism=viewpoint n/amenity=drinking_water -o /tmp/p.pbf --overwrite && osmium export /tmp/p.pbf -f geojsonseq -o pauses.new --overwrite
"@
docker run --rm -v "${osmDir}:/osm" debian:bookworm-slim sh -c $sh
if ($LASTEXITCODE -ne 0) { throw "Échec de la fusion / extraction osmium" }
Move-Item -Force (Join-Path $osmDir "region-4000.osm.pbf.new") (Join-Path $osmDir "region-4000.osm.pbf")

# 3. Build the new graph next to the running one.
Step "Import GraphHopper dans graph-cache-new (plusieurs heures pour l'Europe)"
$new = Join-Path $data "graph-cache-new"
if (Test-Path $new) { Remove-Item -Recurse -Force $new }
Push-Location $companion
docker compose run --rm --no-deps -e "JAVA_OPTS=-Xmx$Heap -Xms2g" graphhopper sh -c "java `$JAVA_OPTS -Ddw.graphhopper.datareader.file=/data/osm/region-4000.osm.pbf -Ddw.graphhopper.graph.location=/data/graph-cache-new -jar /opt/graphhopper-web.jar import /opt/config.yml"
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "Échec de l'import GraphHopper (la carte actuelle reste en service)" }

# 4. Swap graph and point files, restart the router, clean up.
Step "Bascule vers la nouvelle carte"
docker compose stop graphhopper
$current = Join-Path $data "graph-cache"
$old = Join-Path $data "graph-cache-old"
if (Test-Path $old) { Remove-Item -Recurse -Force $old }
if (Test-Path $current) { Move-Item $current $old }
Move-Item $new $current
foreach ($kind in "speed_cameras", "hazards", "fuel_stations", "pauses") {
    Move-Item -Force (Join-Path $osmDir "$kind.new") (Join-Path $osmDir "$kind.geojsonseq")
}
docker compose up -d graphhopper
Pop-Location
if (Test-Path $old) { Remove-Item -Recurse -Force $old }
Step "OK — nouvelle carte en service (GraphHopper redémarre en 1 à 2 minutes)."
