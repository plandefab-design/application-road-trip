# A5 — Weekly OSM refresh + GraphHopper re-import (Windows PowerShell).
# Schedule once (admin PowerShell):
#   schtasks /Create /SC WEEKLY /D SUN /ST 03:00 /TN "MotoTrip OSM" /TR "powershell -ExecutionPolicy Bypass -File C:\chemin\application-road-trip\companion\jobs\update_osm.ps1"
param(
    # Geofabrik extracts, merged into one map: the Alps (FR/IT/CH/AT), Provence-Alpes-Côte d'Azur (the Rhône
    # bridges, which join the Alps to the west) and Languedoc-Roussillon (Cévennes). Neighbouring extracts must
    # overlap, otherwise GraphHopper sees separate road networks. Add regions here if a trip goes elsewhere.
    [string[]]$Extracts = @("europe/alps", "europe/france/provence-alpes-cote-d-azur", "europe/france/languedoc-roussillon")
)
$ErrorActionPreference = "Stop"
$companion = Split-Path -Parent $PSScriptRoot
$osmDir = Join-Path $companion "data\osm"
New-Item -ItemType Directory -Force -Path $osmDir | Out-Null

# Docker Desktop may be installed per user and not be on PATH.
$dockerBin = Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\bin"
if (Test-Path $dockerBin) { $env:Path = "$dockerBin;$env:Path" }

$files = @()
foreach ($extract in $Extracts) {
    $name = ($extract -split "/")[-1]
    $url = "https://download.geofabrik.de/$extract-latest.osm.pbf"
    $tmp = Join-Path $osmDir "$name.osm.pbf.download"
    $dst = Join-Path $osmDir "$name.osm.pbf"
    Write-Host "Téléchargement $url"
    curl.exe -L --fail --retry 3 -sS -o $tmp $url
    if ($LASTEXITCODE -ne 0) { throw "Échec du téléchargement de $url" }
    Move-Item -Force $tmp $dst
    $files += "/osm/$name.osm.pbf"
}

# Merge the extracts into region.osm.pbf (the file GraphHopper imports), with osmium in a throwaway container.
Write-Host "Fusion : $($files -join ', ')"
docker run --rm -v "${osmDir}:/osm" debian:bookworm-slim sh -c "apt-get update -qq >/dev/null && apt-get install -y -qq osmium-tool >/dev/null && osmium merge $($files -join ' ') -o /osm/region.osm.pbf --overwrite"
if ($LASTEXITCODE -ne 0) { throw "Échec de la fusion osmium" }

# A6 — Speed cameras, mapped hazards and fuel stations, embedded in each trip by the planner (offline).
Write-Host "Extraction radars, dangers et stations"
docker run --rm -v "${osmDir}:/osm" debian:bookworm-slim sh -c "apt-get update -qq >/dev/null && apt-get install -y -qq osmium-tool >/dev/null && osmium tags-filter /osm/region.osm.pbf n/highway=speed_camera -o /tmp/cams.osm.pbf --overwrite && osmium export /tmp/cams.osm.pbf -f geojsonseq -o /osm/speed_cameras.geojsonseq --overwrite && osmium tags-filter /osm/region.osm.pbf n/hazard -o /tmp/hazards.osm.pbf --overwrite && osmium export /tmp/hazards.osm.pbf -f geojsonseq -o /osm/hazards.geojsonseq --overwrite && osmium tags-filter /osm/region.osm.pbf nwr/amenity=fuel -o /tmp/fuel.osm.pbf --overwrite && osmium export /tmp/fuel.osm.pbf -f geojsonseq -o /osm/fuel_stations.geojsonseq --overwrite"
if ($LASTEXITCODE -ne 0) { throw "Échec de l'extraction radars/dangers" }

# Force a fresh graph import on next start.
Push-Location $companion
docker compose stop graphhopper
$cache = Join-Path $companion "data\graph-cache"
if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }
docker compose up -d graphhopper
Pop-Location
Write-Host "OK — GraphHopper réimporte les données (5 à 15 minutes)."
