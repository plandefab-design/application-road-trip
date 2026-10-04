"""Data the iPhone downloads from GitHub, without the PC (workflow .github/workflows/data-pack.yml, every day):

- alerts pack: every speed camera (official France and Spain lists, OpenStreetMap, MapAtlas) and hazard (OSM),
  for riding without an itinerary;
- seasons pack: roads with a dated seasonal closure and named mountain passes (OSM), to choose a trip's dates.

Each pack is written as raw DEFLATE (read on the iPhone by NSData.decompressed(using: .zlib)) and listed in
manifest.json with a version derived from its content: the iPhone downloads a pack only when it changed.

    python -m app.data_pack <data_dir> <out_dir>

`data_dir/osm` holds the OSM extracts (jobs/extract_osm_points.sh) and the official lists (refreshed here).
"""
from __future__ import annotations

import asyncio
import datetime as dt
import hashlib
import json
import sys
import zlib
from pathlib import Path
from typing import Any

from .alerts import camera_alert, hazard_alert, load_features
from .finalize import douglas_peucker
from .radar_sources import (mapatlas, merged_cameras, official_es, official_fr, refresh_es, refresh_fr,
                            refresh_mapatlas)
from .seasonal import load_closures, load_passes

CLOSURE_TOLERANCE_M = 5.0      # closed roads simplified: the iPhone only needs to know which roads the trip uses
KIND_CODE = {"speedCamera": 0, "redLightCamera": 1, "sectionCamera": 2}
ATTRIBUTION = ("Radars : Sécurité routière (Licence Ouverte), DGT (CC BY), MapAtlas (CC BY 4.0). "
               "Dangers, radars, fermetures saisonnières et cols : © contributeurs OpenStreetMap (ODbL).")


def all_cameras(data_dir: Path) -> list[dict[str, Any]]:
    """Official lists (France, Spain) + OpenStreetMap + MapAtlas, merged by priority (see radar_sources)."""
    return merged_cameras(load_features(data_dir / "osm" / "speed_cameras.geojsonseq"),
                          official_fr(data_dir) + official_es(data_dir), camera_alert, extra=mapatlas(data_dir))


def alerts_pack(data_dir: Path) -> dict[str, Any]:
    """Cameras `[lat, lon, maxspeed|null, 0 speed / 1 red light / 2 section, label]`, hazards `[lat, lon, label]`."""
    cameras = [[round(f["lat"], 5), round(f["lon"], 5), f["alert"].get("maxspeed"), KIND_CODE.get(f["alert"]["kind"], 0),
                f["alert"]["label"]] for f in all_cameras(data_dir)]
    hazards = [[round(f["lat"], 5), round(f["lon"], 5), hazard_alert(f["props"])["label"]]
               for f in load_features(data_dir / "osm" / "hazards.geojsonseq")]
    return {"cameras": cameras, "hazards": hazards}


def seasons_pack(data_dir: Path) -> dict[str, Any]:
    """Closures `[road, [[m1, d1, m2, d2]…], [lat, lon, lat, lon…]]` (simplified to 5 m), passes `[lat, lon, ele|null, name]`."""
    osm = data_dir / "osm"
    closures = []
    for c in load_closures(osm / "closures.geojsonseq"):
        coords = [[lon, lat] for lat, lon in c["points"]]
        keep = douglas_peucker(coords, [0, len(coords) - 1], CLOSURE_TOLERANCE_M) if len(coords) > 2 else range(len(coords))
        flat = [round(v, 5) for i in keep for v in (coords[i][1], coords[i][0])]
        closures.append([c["road"], [list(p) for p in c["periods"]], flat])
    passes = [[round(p["lat"], 5), round(p["lon"], 5), p["ele"], p["name"]] for p in load_passes(osm / "passes.geojsonseq")]
    return {"closures": closures, "passes": passes}


def write_packs(out_dir: Path, packs: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Each pack as `<name>-pack.json.deflate` with its version (content hash), then manifest.json."""
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, Any] = {"generatedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                "attribution": ATTRIBUTION}
    for name, content in packs.items():
        body = json.dumps(content, separators=(",", ":"), ensure_ascii=False)
        version = hashlib.sha256(body.encode()).hexdigest()[:16]
        raw = json.dumps({"version": version, **content}, separators=(",", ":"), ensure_ascii=False).encode()
        deflate = zlib.compressobj(9, zlib.DEFLATED, -15)
        file = f"{name}-pack.json.deflate"
        (out_dir / file).write_bytes(deflate.compress(raw) + deflate.flush())
        manifest[name] = {"file": file, "version": version, "bytes": len(raw)}
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
    return manifest


async def refresh_sources(data_dir: Path) -> None:
    """Official camera lists: France and Spain every run (daily), MapAtlas once a month. A failing source keeps the
    previous file (restored from the workflow cache)."""
    await refresh_fr(data_dir, force=True)
    await refresh_es(data_dir, force=True)
    await refresh_mapatlas(data_dir)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    data_dir, out_dir = Path(argv[0]), Path(argv[1])
    asyncio.run(refresh_sources(data_dir))
    alerts, seasons = alerts_pack(data_dir), seasons_pack(data_dir)
    # Never publish a broken pack over a good one: the official lists alone hold thousands of cameras.
    if len(alerts["cameras"]) < 10_000 or not seasons["closures"] or not seasons["passes"]:
        print(f"Données incomplètes : {len(alerts['cameras'])} radars, {len(seasons['closures'])} fermetures, "
              f"{len(seasons['passes'])} cols")
        return 1
    manifest = write_packs(out_dir, {"alerts": alerts, "seasons": seasons})
    print(f"{len(alerts['cameras'])} radars, {len(alerts['hazards'])} dangers, {len(seasons['closures'])} fermetures, "
          f"{len(seasons['passes'])} cols → {json.dumps({k: v for k, v in manifest.items() if isinstance(v, dict)})}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
