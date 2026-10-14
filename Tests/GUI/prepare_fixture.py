#!/usr/bin/env python3
"""Prepare a non-authenticated GUI fixture; never launch/quit Codex or touch user storage."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
import sys

import argparse
parser = argparse.ArgumentParser()
parser.add_argument('--readiness', action='store_true')
parser.add_argument('--count', type=int, default=2, choices=range(0,21))
parser.add_argument('--appearance', choices=['light','dark'])
parser.add_argument('--preview-error', action='store_true')
parser.add_argument('--codex-state', choices=['verified', 'missing', 'unverified'], default='verified')
parser.add_argument('--corrupt-metadata', action='store_true')
args = parser.parse_args()
readiness = args.readiness

repository = Path(__file__).resolve().parents[2]
source = repository / "build/debug/CodexSwoop.app"
assert source.is_dir(), "Build the Debug app first."
info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "io.github.cbrwvy.codexswoop"

identifier = uuid.uuid4().hex
root = Path(tempfile.mkdtemp(prefix="codexswoop-ui-overhaul-", dir="/private/tmp"))
os.chmod(root, 0o700)
for relative in [".codex", "Library/Application Support/Codex"]:
    (root / "fixture-user" / relative).mkdir(mode=0o700, parents=True, exist_ok=True)
profiles = []
folders = []
now = time.time() - 978307200  # Foundation reference date, no account data.
names = ["Fixture Primary", "Fixture Work"] + [f"Long fictional account {i} · Очень длинное имя · Juda uzun nom" for i in range(3,args.count+1)]
for name in names[:args.count]:
    profile_id = str(uuid.uuid4())
    profiles.append({"id": profile_id, "name": name, "createdAt": now, "updatedAt": now})
    folder = root / "Profiles" / profile_id
    paths = [root / "Profiles", folder]
    if not readiness or name == "Fixture Primary":
        paths += [folder / "codex-home", folder / "electron-user-data"]
    for path in paths:
        path.mkdir(mode=0o700, exist_ok=True)
    folders.append(str(folder))
metadata = root / "profiles.json"
metadata.write_text("invalid fixture metadata" if args.corrupt_metadata else json.dumps({"schemaVersion": 1, "revision": 2, "profiles": profiles}))
os.chmod(metadata, 0o600)
(root / "metadata.lock").touch(mode=0o600)
if readiness and profiles:
    def identity(path):
        info = path.stat()
        return {"device": info.st_dev, "inode": info.st_ino, "owner": info.st_uid, "permissions": info.st_mode & 0o777}
    base = Path(folders[0])
    association = {"profileID": profiles[0]["id"], "environmentID": profiles[0]["id"], "kind": "managed",
                   "codexHome": str(base / "codex-home"), "electronData": str(base / "electron-user-data"),
                   "homeIdentity": identity(base / "codex-home"), "electronIdentity": identity(base / "electron-user-data"),
                   "origin": "userSelected", "lastCheck": "directoryMetadataVerified", "checkedAt": now}
    sidecar = root / "environments.json"
    sidecar.write_text(json.dumps({"schemaVersion": 1, "revision": 1, "associations": [association]}))
    sidecar.chmod(0o600)

bundle = repository / "build" / ("qa-ui-overhaul-" + identifier) / "CodexSwoopQA.app"
(bundle / "Contents/MacOS").mkdir(parents=True, mode=0o700)
(bundle / "Contents/Resources").mkdir(mode=0o700)
shutil.copy2(source / "Contents/MacOS/CodexSwoop", bundle / "Contents/MacOS/CodexSwoop")
for name in ["AppIcon.icns", "MenuBarIcon.png", "MenuBarIcon@2x.png"]:
    shutil.copy2(source / "Contents/Resources" / name, bundle / "Contents/Resources" / name)
info["CFBundleIdentifier"] = "io.github.cbrwvy.codexswoop.qa" + identifier
info["CFBundleName"] = info["CFBundleDisplayName"] = "CodexSwoop QA"
info["CodexSwoopTestStorageRoot"] = str(root)
info["CodexSwoopTestInstallationState"] = args.codex_state
info["CodexSwoopTestShowMenu"] = True
if args.appearance: info["CodexSwoopTestAppearance"] = args.appearance
info["CodexSwoopTestPreviewError"] = args.preview_error
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)], check=True)
result = {"bundle": str(bundle), "root": str(root), "folders": folders, "bundle_id": info["CFBundleIdentifier"]}
manifest = bundle.parent / "fixture.json"
manifest.write_text(json.dumps(result, indent=2))
os.chmod(manifest, 0o600)
print(json.dumps(result, indent=2))
