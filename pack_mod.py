#!/usr/bin/env python3
"""
DroneFlames-Mods Packaging Tool
Universal packaging and validation tool for DroneFlames mods (.dfmod).

Usage:
    python3 pack_mod.py              # Pack all mods in mods/ directory
    python3 pack_mod.py <mod_id>     # Pack a specific mod by its directory name
    python3 pack_mod.py --validate   # Validate mod.json and structure without packing
"""

import os
import sys
import json
import shutil
import zipfile
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
MODS_DIR = BASE_DIR / "mods"
CATALOG_PATH = BASE_DIR / "catalog.json"

ALLOWED_EXTENSIONS = {
    ".gd", ".json", ".png", ".py", ".ps1", ".txt", ".ogg", ".wav", ".svg"
}

IGNORED_NAMES = {
    ".DS_Store", "Thumbs.db", ".git", ".gitignore"
}


def validate_mod(mod_dir: Path) -> dict:
    mod_id = mod_dir.name
    mod_json = mod_dir / "mod.json"
    mod_gd = mod_dir / "mod.gd"
    icon_png = mod_dir / "icon.png"

    if not mod_json.exists():
        raise FileNotFoundError(f"Missing mod.json in {mod_dir}")
    if not mod_gd.exists():
        raise FileNotFoundError(f"Missing mod.gd in {mod_dir}")

    # Validate JSON syntax
    try:
        data = json.loads(mod_json.read_text(encoding="utf-8"))
    except Exception as e:
        raise ValueError(f"Invalid JSON in {mod_json}: {e}")

    # Fallback icon check (for mods using custom icons e.g. image.png)
    custom_icon = data.get("icon", "icon.png")
    if not (mod_dir / custom_icon).exists() and not icon_png.exists():
        raise FileNotFoundError(f"Missing icon ({custom_icon}) in {mod_dir}")

    return data


def pack_mod(mod_dir: Path) -> Path:
    mod_id = mod_dir.name
    data = validate_mod(mod_dir)
    version = data.get("version", "1.0.0")

    # Filter files to pack into .dfmod
    files_to_pack = []
    for f in sorted(mod_dir.iterdir()):
        if f.is_file():
            if f.suffix == ".dfmod":
                continue
            if f.name.endswith(".import") or f.name.endswith(".uid"):
                continue
            if f.name in IGNORED_NAMES:
                continue
            if f.suffix in ALLOWED_EXTENSIONS:
                files_to_pack.append(f)

    # Output paths
    dfmod_in_folder = mod_dir / f"{mod_id}.dfmod"
    dfmod_in_mods_root = MODS_DIR / f"{mod_id}.dfmod"

    with zipfile.ZipFile(dfmod_in_folder, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files_to_pack:
            zf.write(f, arcname=f.name)

    # Also copy to mods root for direct link compatibility
    shutil.copy2(dfmod_in_folder, dfmod_in_mods_root)

    print(f"  [OK] Packed {mod_id} v{version} ({len(files_to_pack)} files) -> {dfmod_in_folder.name}")
    return dfmod_in_folder


def main():
    args = sys.argv[1:]

    if not MODS_DIR.exists():
        print(f"Error: Mods directory not found at {MODS_DIR}")
        sys.exit(1)

    target_mods = []
    validate_only = "--validate" in args

    if validate_only:
        args.remove("--validate")

    if args:
        for name in args:
            p = MODS_DIR / name
            if p.is_dir():
                target_mods.append(p)
            else:
                print(f"Warning: Mod directory not found: {p}")
    else:
        target_mods = [p for p in sorted(MODS_DIR.iterdir()) if p.is_dir()]

    if not target_mods:
        print("No mod directories found to process.")
        sys.exit(0)

    print(f"Processing {len(target_mods)} mods in {MODS_DIR}...")
    errors = 0

    for m in target_mods:
        try:
            if validate_only:
                data = validate_mod(m)
                print(f"  [VALID] {m.name} v{data.get('version')}")
            else:
                pack_mod(m)
        except Exception as e:
            print(f"  [FAIL] {m.name}: {e}")
            errors += 1

    if errors > 0:
        print(f"\nCompleted with {errors} errors.")
        sys.exit(1)
    else:
        print(f"\nAll {len(target_mods)} mods processed successfully!")


if __name__ == "__main__":
    main()
