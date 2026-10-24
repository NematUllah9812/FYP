#!/usr/bin/env python3
"""
TerraSteps — Google Drive Heavy Asset Sync Utility
Downloads heavy GPX benchmark datasets, offline H3 GeoJSON packs, high-res brand
masters, or APK builds declared in `drive_assets_manifest.json` into a local
git-ignored `.drive_cache/` directory.

Usage:
  python3 scripts/fetch_drive_assets.py --list
  python3 scripts/fetch_drive_assets.py --category gpx_benchmark_datasets
  python3 scripts/fetch_drive_assets.py --key h3_pack_abbottabad_res9
  python3 scripts/fetch_drive_assets.py --all
"""

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "drive_assets_manifest.json"
DEFAULT_CACHE_DIR = ROOT / ".drive_cache"


def load_manifest() -> dict:
    with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def format_size(num_bytes: int) -> str:
    if num_bytes >= 1024 * 1024:
        return f"{num_bytes / (1024 * 1024):.2f} MB"
    if num_bytes >= 1024:
        return f"{num_bytes / 1024:.1f} KB"
    return f"{num_bytes} B"


def download_asset(asset: dict, out_dir: Path) -> Path:
    cat_dir = out_dir / asset["category"]
    cat_dir.mkdir(parents=True, exist_ok=True)
    dest = cat_dir / asset["name"]
    url = asset["download_url"]
    print(f"Downloading {asset['key']} ({format_size(asset['size_bytes'])}) -> {dest} ...")
    req = urllib.request.Request(url, headers={"User-Agent": "TerraSteps-AssetSync/0.3"})
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as out:
        while True:
            chunk = resp.read(256 * 1024)
            if not chunk:
                break
            out.write(chunk)
    print(f"  Saved {dest} ({format_size(dest.stat().st_size)})")
    return dest


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync TerraSteps heavy files from Google Drive.")
    parser.add_argument("--list", action="store_true", help="List all Drive assets in manifest.")
    parser.add_argument("--key", type=str, help="Download a single asset by key.")
    parser.add_argument("--category", type=str, help="Download all assets in a category.")
    parser.add_argument("--all", action="store_true", help="Download all heavy assets (excluding APK unless requested).")
    parser.add_argument("--include-apk", action="store_true", help="Include the 47.5 MB APK when using --all.")
    parser.add_argument("--out", type=Path, default=DEFAULT_CACHE_DIR, help="Target cache directory.")
    args = parser.parse_args()

    manifest = load_manifest()
    assets = manifest.get("assets", [])

    if args.list or not (args.key or args.category or args.all):
        print(f"Drive Root: {manifest['drive_root_folder']['name']} -> {manifest['drive_root_folder']['url']}\n")
        for a in assets:
            print(f"  [{a['category']}] {a['key']:<28} {format_size(a['size_bytes']):>9}  {a['name']}")
        return 0

    selected = []
    if args.key:
        selected = [a for a in assets if a["key"] == args.key]
        if not selected:
            print(f"Error: unknown asset key '{args.key}'", file=sys.stderr)
            return 1
    elif args.category:
        selected = [a for a in assets if a["category"] == args.category]
        if not selected:
            print(f"Error: unknown category '{args.category}'", file=sys.stderr)
            return 1
    elif args.all:
        selected = [
            a for a in assets
            if args.include_apk or a["key"] != "prototype_debug_apk"
        ]

    for asset in selected:
        download_asset(asset, args.out)

    print(f"\nCompleted {len(selected)} asset download(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
