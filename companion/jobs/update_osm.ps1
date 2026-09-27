# A5 — Weekly OSM refresh + GraphHopper re-import (Windows PowerShell).
# Schedule once (admin PowerShell):
#   schtasks /Create /SC WEEKLY /D SUN /ST 03:00 /TN "MotoTrip OSM" /TR "powershell -ExecutionPolicy Bypass -File C:\chemin\application-road-trip\companion\jobs\update_osm.ps1"
param(
    # Geofabrik extract. "europe/alps" covers the Alps (FR/IT/CH/AT). For Provence only:
    # "europe/france/provence-alpes-cote-d-azur". Merging several extracts: milestone M2.
    [string]$Extract = "europe/alps"
)
$ErrorActionPreference = "Stop"
$companion = Split-Path -Parent $PSScriptRoot
$osmDir = Join-Path $companion "data\osm"
New-Item -ItemType Directory -Force -Path $osmDir | Out-Null

$url = "https://download.geofabrik.de/$Extract-latest.osm.pbf"
$tmp = Join-Path $osmDir "region.osm.pbf.download"
$dst = Join-Path $osmDir "region.osm.pbf"

Write-Host "Téléchargement $url"
Invoke-WebRequest -Uri $url -OutFile $tmp
Move-Item -Force $tmp $dst

# Force a fresh graph import on next start.
$cache = Join-Path $companion "data\graph-cache"
if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }

Push-Location $companion
docker compose restart graphhopper
Pop-Location
Write-Host "OK — GraphHopper réimporte les données (plusieurs minutes)."
