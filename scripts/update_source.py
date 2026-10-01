#!/usr/bin/env python3
"""Adds a new version to the SideStore/AltStore source (distribution/source.json). Called by CI."""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

BUNDLE_ID = "fr.plandefab.mototrip"
KEEP_VERSIONS = 5


def base_source(repo: str) -> dict:
    return {
        "name": "Moto Road (FAB)",
        "identifier": f"{BUNDLE_ID}.source",
        "sourceURL": f"https://raw.githubusercontent.com/{repo}/main/distribution/source.json",
        "apps": [{
            "name": "Moto Road",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "FAB",
            "subtitle": "Road trips moto, guidage vocal, radars et dangers",
            "localizedDescription": "Road trips moto préparés avec Claude, guidage vocal façon GPS, radars, dangers et trafic en direct, carnet d'entretien. Navigation 100 % locale.",
            "iconURL": f"https://raw.githubusercontent.com/{repo}/main/distribution/moto-road-icon.png",
            "tintColor": "FF5E1A",
            "versions": [],
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSLocationWhenInUseUsageDescription": "Guidage sur le trip.",
                    "NSLocationAlwaysAndWhenInUseUsageDescription": "Guidage écran verrouillé.",
                },
            },
        }],
        "news": [],
    }


def update(source: dict, version: str, build: str, url: str, size: int, now: datetime) -> dict:
    app = next(a for a in source["apps"] if a["bundleIdentifier"] == BUNDLE_ID)
    entry = {
        "version": version,
        "buildVersion": build,
        "date": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": f"Build {build}",
        "downloadURL": url,
        "size": size,
        "minOSVersion": "17.0",
    }
    app["versions"] = [entry] + [v for v in app["versions"] if v.get("version") != version]
    app["versions"] = app["versions"][:KEEP_VERSIONS]
    return source


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, type=Path)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--size", required=True, type=int)
    a = ap.parse_args()

    src = json.loads(a.source.read_text(encoding="utf-8")) if a.source.exists() else base_source(a.repo)
    if not src.get("apps"):
        src = base_source(a.repo)
    src["sourceURL"] = f"https://raw.githubusercontent.com/{a.repo}/main/distribution/source.json"
    # Name, texts and icon follow the app (renamed MotoTrip → Moto Road); versions are kept.
    base = base_source(a.repo)
    src["name"] = base["name"]
    for app in src["apps"]:
        if app.get("bundleIdentifier") == BUNDLE_ID:
            for key in ("name", "subtitle", "localizedDescription", "iconURL", "tintColor"):
                app[key] = base["apps"][0][key]
    update(src, a.version, a.build, a.url, a.size, datetime.now(timezone.utc))
    a.source.parent.mkdir(parents=True, exist_ok=True)
    a.source.write_text(json.dumps(src, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
