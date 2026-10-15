#!/usr/bin/env python3
"""Inspect Git candidates or index blobs; never open credential files or print matched values."""
import hashlib
import json
import re
import struct
import subprocess
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_FILES = {".gitignore", "LICENSE", "Package.swift", "README.md"}
ALLOWED_ROOTS = {".github", "CodexSwoop.xcodeproj", "Resources", "Sources", "Tests", "docs", "scripts"}
TEXT_SUFFIXES = {".md", ".swift", ".py", ".sh", ".json", ".svg", ".plist", ".pbxproj", ".xcscheme", ".yml"}
RUNTIME_NAMES = {"auth.json", "profiles.json", "profiles.backup.json", "environments.json",
                 "environments.backup.json", "managed-environments.json", "managed-environments.backup.json",
                 "retained-environments.json", "retained-environments.backup.json", "setup-journal.json", "opening-journal.json", "opening-journal-watermark.json", "opening-operation.lock", "metadata.lock"}
PRIVATE_PARTS = {"Profiles", "SetupBackups", "UnresolvedOpeningEpoch", "private-reports", "build", ".build", "DerivedData", "xcuserdata"}
SCREENSHOT_ASSETS = {
    "docs/assets/screenshots/codexswoop-overview.png": {
        "size": 55795, "width": 640, "height": 662,
        "sha256": "1cf5b86947a05eaede838823131ba814dbb109d567349fd39f3d996ad36976a9",
    },
    "docs/assets/screenshots/recovery.png": {
        "size": 64971, "width": 640, "height": 700,
        "sha256": "fefae348da78eca78cd32388b0bd37c31bbfc842a7c8f42eef07fca8c1f6d007",
    },
    "docs/assets/screenshots/settings.png": {
        "size": 141477, "width": 1080, "height": 1280,
        "sha256": "ed93138111bee77fbdd9916c1aef8a1357d81695b0f68d0c16b6374fdc3660cc",
    },
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_CHUNKS = {b"IHDR", b"iCCP", b"eXIf", b"pHYs", b"IDAT", b"IEND"}
PATTERNS = {
    "private-key": re.compile(rb"-----BEGIN (?:[A-Z ]+)?PRIVATE KEY-----"),
    "api-key": re.compile(rb"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}"),
    "service-token": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b"),
    "jwt": re.compile(rb"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{12,}"),
    "assigned-credential": re.compile(rb'''(?i)["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)["']?\s*[=:]\s*["'][A-Za-z0-9_./+\-=]{16,}["']'''),
    "authorization-header": re.compile(rb"(?i)\bBearer\s+[A-Za-z0-9_.-]{20,}"),
    "url-credentials": re.compile(rb"[a-z]+://[^\s/:]+:[^\s/@]+@"),
}
USER_PATH = re.compile(rb"/(?:Users|home)/[^\s/\"'`]+")
DOCUMENT_IDENTIFIERS = {
    "concrete-document-uuid": re.compile(rb"\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b"),
    "concrete-document-process-id": re.compile(rb"(?i)\b(?:PID|PPID|UID)\s*[=:]?\s*\d{3,}\b"),
}
EXCLUDED = ["build/research/private-report.json", ".build/object", "Profiles/fixture/data", "auth.json",
            "profiles.json", "environments.json", "managed-environments.json", "managed-environments.backup.json",
            "managed-environments-damaged-fixture.json", "private-reports/report.md", ".env", "key.p12",
            "retained-environments.json", "setup-journal.json", "opening-journal.json", "opening-journal-watermark.json", "opening-operation.lock", "SetupBackups/snapshot.json", "UnresolvedOpeningEpoch/manifest.json", "UnresolvedLaunchOpening-fixture/manifest.json", "Cookies",
            ".idea/codexswoop.iml", "refresh-tokens.json", "credentials.json", "export.keychain-db", "export.pfx", "trace.har",
            "diagnostic.ips", "data.sqlite", "old.bak", "local.app/Contents/Info.plist", "trial.dmg", "backup.zip"]


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def private_name(name):
    path = Path(name)
    lower = path.name.lower()
    return ((bool(set(path.parts) & PRIVATE_PARTS) or any(part.startswith("UnresolvedLaunchOpening-") for part in path.parts)) or path.name in RUNTIME_NAMES
            or lower.startswith(("auth.", "cookies", "credentials", ".env"))
            or lower.endswith((".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".log", ".har", ".bak"))
            or (lower.endswith(".json") and any(word in lower for word in ("token", "-damaged-"))))


def inspect_data(name, data):
    findings = [{"path": name, "rule": rule} for rule, pattern in PATTERNS.items() if pattern.search(data)]
    # Only these explicit negative-test usernames are fictional; no general home-path exemption.
    paths = USER_PATH.findall(data)
    fictional_paths = {b"/Users/" + user for user in (b"fixture", b"synthetic")}
    if any(not (name.startswith("Tests/") and path in fictional_paths) for path in paths):
        findings.append({"path": name, "rule": "local-user-path"})
    if name == "README.md" or name.startswith("docs/"):
        findings.extend({"path": name, "rule": rule} for rule, pattern in DOCUMENT_IDENTIFIERS.items() if pattern.search(data))
    if Path(name).suffix not in {".png", ".icns"}:
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            findings.append({"path": name, "rule": "unexpected-binary"})
    return findings


def inspect_screenshot(name, data):
    """Accept only the three reviewed screenshot byte streams and their PNG structure."""
    expected = SCREENSHOT_ASSETS.get(name)
    if expected is None:
        return [{"path": name, "rule": "unapproved-screenshot"}]
    expected_size = expected["size"]
    expected_width = expected["width"]
    expected_height = expected["height"]
    expected_hash = expected["sha256"]
    # Pin all bytes so image pixels and ancillary metadata cannot change silently.
    if (len(data) != expected_size or len(data) > 192 * 1024
            or hashlib.sha256(data).hexdigest() != expected_hash
            or not data.startswith(PNG_SIGNATURE)):
        return [{"path": name, "rule": "invalid-screenshot-asset"}]

    offset = len(PNG_SIGNATURE)
    chunks = []
    image_data = bytearray()
    ihdr = None
    ended = False
    while offset < len(data):
        if offset + 12 > len(data):
            return [{"path": name, "rule": "invalid-screenshot-asset"}]
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data) or kind not in PNG_CHUNKS or ended:
            return [{"path": name, "rule": "invalid-screenshot-asset"}]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack(">I", data[offset + 8 + length:end])[0]
        if crc != (zlib.crc32(kind + payload) & 0xffffffff):
            return [{"path": name, "rule": "invalid-screenshot-asset"}]
        chunks.append(kind)
        if kind == b"IHDR":
            if ihdr is not None or chunks != [b"IHDR"] or length != 13:
                return [{"path": name, "rule": "invalid-screenshot-asset"}]
            ihdr = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            image_data.extend(payload)
        elif kind == b"IEND":
            if length != 0:
                return [{"path": name, "rule": "invalid-screenshot-asset"}]
            ended = True
        offset = end

    expected_chunks = [b"IHDR", b"iCCP", b"eXIf", b"pHYs"]
    idat_count = chunks.count(b"IDAT")
    if (offset != len(data) or not ended or ihdr is None or idat_count < 1
            or chunks != expected_chunks + [b"IDAT"] * idat_count + [b"IEND"]
            or ihdr != (expected_width, expected_height, 8, 6, 0, 0, 0)):
        return [{"path": name, "rule": "invalid-screenshot-asset"}]
    try:
        pixels = zlib.decompress(image_data)
    except zlib.error:
        return [{"path": name, "rule": "invalid-screenshot-asset"}]
    if len(pixels) != expected_height * (1 + expected_width * 4):
        return [{"path": name, "rule": "invalid-screenshot-asset"}]
    return []


def audit(staged=False):
    modes = {}
    if staged:
        paths = set()
        for entry in git("ls-files", "--stage", "-z").split(b"\0"):
            if not entry:
                continue
            metadata, raw = entry.split(b"\t", 1)
            mode, _, stage = metadata.split()
            paths.add(raw)
            modes[raw] = mode if stage == b"0" else b"unmerged"
    else:
        paths = set(git("ls-files", "-z").split(b"\0")) | set(git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"))
    findings = []
    candidates = []
    for raw in sorted(paths - {b""}):
        name = raw.decode("utf-8")
        path = ROOT / name
        if name not in ALLOWED_FILES and Path(name).parts[0] not in ALLOWED_ROOTS:
            findings.append({"path": name, "rule": "outside-baseline-allowlist"})
            continue
        # Reject by filename before opening, even when a credential was force-added to Git.
        if private_name(name):
            findings.append({"path": name, "rule": "private-or-runtime-file"})
            continue
        suffix = path.suffix
        binary_asset = (name == "Resources/AppIcon.icns"
                        or (name.startswith("Resources/Assets.xcassets/") and suffix == ".png")
                        or name in SCREENSHOT_ASSETS)
        if name not in ALLOWED_FILES and suffix not in TEXT_SUFFIXES and not binary_asset:
            findings.append({"path": name, "rule": "unexpected-file-extension"})
            continue
        if (staged and modes[raw] not in {b"100644", b"100755"}) or (not staged and (
                not path.is_file() or path.is_symlink()
                or any(parent.is_symlink() for parent in path.parents if ROOT in parent.parents))):
            findings.append({"path": name, "rule": "unexpected-file-type"})
            continue
        candidates.append(name)
        data = git("show", ":" + name) if staged else path.read_bytes()
        findings.extend(inspect_data(name, data))
        if name in SCREENSHOT_ASSETS:
            findings.extend(inspect_screenshot(name, data))
    ignored = subprocess.run(
        ["git", "-C", str(ROOT), "check-ignore", "--stdin"], input="\n".join(EXCLUDED) + "\n",
        text=True, capture_output=True, check=False).stdout.splitlines()
    for name in EXCLUDED:
        if name not in ignored:
            findings.append({"path": name, "rule": "missing-ignore-rule"})
    return {"candidate_count": len(candidates), "candidates": candidates, "findings": findings,
            "ignore_checks": len(EXCLUDED), "scope": "Index blobs" if staged else "Working-tree Git candidates",
            "limitation": "Heuristic scan plus manual review; ignored runtime data is never inspected"}


if __name__ == "__main__":
    result = audit(staged="--staged" in sys.argv)
    if "--json" in sys.argv:
        print(json.dumps(result, indent=2))
    else:
        print(f"Baseline candidates: {result['candidate_count']}; ignore checks: {result['ignore_checks']}; findings: {len(result['findings'])}")
        for finding in result["findings"]:
            print(f"REVIEW {finding['path']}: {finding['rule']}")
    sys.exit(bool(result["findings"]))
