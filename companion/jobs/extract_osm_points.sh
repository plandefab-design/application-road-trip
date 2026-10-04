#!/usr/bin/env bash
# OpenStreetMap objects of the iPhone's data pack (workflow data-pack.yml, weekly): speed cameras, hazards, roads
# with a seasonal closure and mountain passes, for the countries of companion/maps.txt.
# One country at a time (a GitHub runner has little disk): download from Geofabrik, keep only these objects,
# delete the download; then merge and export as GeoJSON sequences (same files as the PC's update_osm.ps1).
# Usage: extract_osm_points.sh <osm_dir> [maps file]     (needs curl and osmium-tool)
set -euo pipefail
out="$1"
maps="${2:-$(dirname "$0")/../maps.txt}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
conditional=(w/access:conditional w/motor_vehicle:conditional w/vehicle:conditional w/motorcar:conditional
             w/motorcycle:conditional)

small=()
while IFS= read -r line || [ -n "$line" ]; do
    extract="$(printf '%s' "${line%%#*}" | tr -d '\r' | xargs)"
    [ -z "$extract" ] && continue
    name="${extract##*/}"
    echo "$(date -u +%H:%M:%S)  $extract"
    curl -L --fail --retry 5 -sS -o "$work/$name.osm.pbf" "https://download.geofabrik.de/$extract-latest.osm.pbf"
    osmium tags-filter "$work/$name.osm.pbf" n/highway=speed_camera n/hazard n/mountain_pass=yes "${conditional[@]}" \
        -o "$work/$name.small.osm.pbf" --overwrite --no-progress
    rm "$work/$name.osm.pbf"
    small+=("$work/$name.small.osm.pbf")
done < "$maps"
[ ${#small[@]} -gt 0 ] || { echo "Aucune carte dans maps.txt"; exit 1; }
osmium merge "${small[@]}" -o "$work/points.osm.pbf" --overwrite --no-progress

export_geojson() {   # <name> <filter>... : objects of points.osm.pbf matching a filter → <name>.geojsonseq
    local name="$1"; shift
    osmium tags-filter "$work/points.osm.pbf" "$@" -o "$work/$name.osm.pbf" --overwrite --no-progress
    osmium export "$work/$name.osm.pbf" -f geojsonseq -o "$work/$name.geojsonseq" --overwrite --no-progress
}
export_geojson speed_cameras n/highway=speed_camera
export_geojson hazards n/hazard
export_geojson passes n/mountain_pass=yes
osmium tags-filter "$work/points.osm.pbf" "${conditional[@]}" -o "$work/conditional.osm.pbf" --overwrite --no-progress
osmium tags-filter "$work/conditional.osm.pbf" w/highway -o "$work/closures.osm.pbf" --overwrite --no-progress
osmium export "$work/closures.osm.pbf" -f geojsonseq -o "$work/closures.geojsonseq" --overwrite --no-progress

mkdir -p "$out"
for kind in speed_cameras hazards passes closures; do mv -f "$work/$kind.geojsonseq" "$out/$kind.geojsonseq"; done
wc -l "$out"/*.geojsonseq
