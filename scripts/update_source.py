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
        "name": "MotoTrip (FAB)",
        "identifier": f"{BUNDLE_ID}.source",
        "sourceURL": f"https://raw.githubusercontent.com/{repo}/main/distribution/source.json",
        "apps": [{
            "name": "MotoTrip",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "FAB",
            "subtitle": "Road trips moto sur routes sinueuses",
            "localizedDescription": "Création de road trips assistée par Claude et navigation 100 % locale.",
            "iconURL": f"https://raw.githubusercontent.com/{repo}/main/distribution/icon.png",
            "tintColor": "FF6B00",
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
    for app in src["apps"]:
        app["iconURL"] = f"https://raw.githubusercontent.com/{a.repo}/main/distribution/icon.png"
    update(src, a.version, a.build, a.url, a.size, datetime.now(timezone.utc))
    a.source.parent.mkdir(parents=True, exist_ok=True)
    a.source.write_text(json.dumps(src, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
