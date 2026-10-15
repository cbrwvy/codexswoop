#!/usr/bin/env python3
"""Build and validate CodexSwoop Apple Silicon release disk images."""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path
from typing import Callable, Iterable


EXPECTED_BUNDLE_ID = "io.github.cbrwvy.codexswoop"
PUBLIC_VERSION = "1.0.0"
MINIMUM_MACOS = (14, 0, 0)
PUBLIC_DMG_NAME = "CodexSwoop-1.0.0-macos-arm64.dmg"
LOCAL_MODE = "local-preview"
PUBLIC_MODE = "public-release"
INFO_PLIST_KEYS = {
    "CFBundleDevelopmentRegion",
    "CFBundleDisplayName",
    "CFBundleExecutable",
    "CFBundleIconFile",
    "CFBundleIdentifier",
    "CFBundleLocalizations",
    "CFBundleName",
    "CFBundlePackageType",
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "LSMinimumSystemVersion",
    "LSUIElement",
    "NSHighResolutionCapable",
    "NSHumanReadableCopyright",
    "NSPrincipalClass",
}
ARM64 = 0x0100000C
X86_64 = 0x01000007
ARM64E_SUBTYPE = 2
LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32


class ReleaseError(Exception):
    """A release input failed a required check."""


def run_command(command: list[str], *, capture: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except FileNotFoundError as exc:
        raise ReleaseError(f"Required tool is missing: {command[0]}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise ReleaseError(f"Command failed ({result.returncode}): {' '.join(command)}" + (f"\n{detail}" if detail else ""))
    return result


def parse_version(value: object, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", value):
        raise ReleaseError(f"{label} must be a numeric dotted version")
    parts = tuple(int(part) for part in value.split("."))
    if len(parts) == 2:
        parts += (0,)
    return parts


def _version_from_macho(value: int) -> tuple[int, int, int]:
    return ((value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF)


def _arch_name(cpu_type: int, cpu_subtype: int) -> str:
    if cpu_type == ARM64:
        return "arm64e" if (cpu_subtype & 0x00FFFFFF) == ARM64E_SUBTYPE else "arm64"
    if cpu_type == X86_64:
        return "x86_64"
    if cpu_type == 12:
        return "arm"
    if cpu_type == 7:
        return "i386"
    return f"cpu-{cpu_type:#x}"


def _thin_macho(data: bytes, offset: int, length: int) -> tuple[str, tuple[int, int, int] | None, int | None]:
    chunk = data[offset : offset + length]
    if len(chunk) < 28:
        raise ReleaseError("Mach-O slice is truncated")
    magics = {
        b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xfe\xed\xfa\xce": (">", 28),
        b"\xcf\xfa\xed\xfe": ("<", 32),
        b"\xfe\xed\xfa\xcf": (">", 32),
    }
    if chunk[:4] not in magics:
        raise ReleaseError("Universal binary contains an invalid Mach-O slice")
    endian, header_size = magics[chunk[:4]]
    if len(chunk) < header_size:
        raise ReleaseError("Mach-O header is truncated")
    cpu_type, cpu_subtype = struct.unpack_from(endian + "II", chunk, 4)
    ncmds, sizeofcmds = struct.unpack_from(endian + "II", chunk, 16)
    if ncmds > 65535 or header_size + sizeofcmds > len(chunk):
        raise ReleaseError("Mach-O load command table is invalid")
    minos: tuple[int, int, int] | None = None
    platform: int | None = None
    cursor = header_size
    for _ in range(ncmds):
        if cursor + 8 > header_size + sizeofcmds:
            raise ReleaseError("Mach-O load command is truncated")
        command, command_size = struct.unpack_from(endian + "II", chunk, cursor)
        if command_size < 8 or cursor + command_size > header_size + sizeofcmds:
            raise ReleaseError("Mach-O load command has an invalid size")
        if command == LC_BUILD_VERSION:
            if command_size < 24:
                raise ReleaseError("LC_BUILD_VERSION command is truncated")
            platform = struct.unpack_from(endian + "I", chunk, cursor + 8)[0]
            minos = _version_from_macho(struct.unpack_from(endian + "I", chunk, cursor + 12)[0])
        elif command == LC_VERSION_MIN_MACOSX:
            if command_size < 16:
                raise ReleaseError("LC_VERSION_MIN_MACOSX command is truncated")
            platform = 1
            minos = _version_from_macho(struct.unpack_from(endian + "I", chunk, cursor + 8)[0])
        cursor += command_size
    return _arch_name(cpu_type, cpu_subtype), minos, platform


def macho_slices(data: bytes) -> list[tuple[str, tuple[int, int, int] | None, int | None]] | None:
    """Return Mach-O slices and minimum OS versions, or None for a non-Mach-O file."""
    if len(data) < 4:
        return None
    fat_magics = {
        b"\xca\xfe\xba\xbe": (">", False),
        b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True),
        b"\xbf\xba\xfe\xca": ("<", True),
    }
    if data[:4] in fat_magics:
        endian, fat64 = fat_magics[data[:4]]
        if len(data) < 8:
            raise ReleaseError("Universal Mach-O header is truncated")
        count = struct.unpack_from(endian + "I", data, 4)[0]
        entry_size = 32 if fat64 else 20
        if count == 0 or count > 64 or 8 + count * entry_size > len(data):
            raise ReleaseError("Universal Mach-O architecture table is invalid")
        result: list[tuple[str, tuple[int, int, int] | None, int | None]] = []
        for index in range(count):
            entry = 8 + index * entry_size
            cpu_type, cpu_subtype = struct.unpack_from(endian + "II", data, entry)
            if fat64:
                slice_offset, slice_size = struct.unpack_from(endian + "QQ", data, entry + 8)
            else:
                slice_offset, slice_size = struct.unpack_from(endian + "II", data, entry + 8)
            if slice_size == 0 or slice_offset + slice_size > len(data):
                raise ReleaseError("Universal Mach-O slice points outside the file")
            slice_name, minos, platform = _thin_macho(data, slice_offset, slice_size)
            if _arch_name(cpu_type, cpu_subtype) != slice_name:
                raise ReleaseError("Universal Mach-O architecture table does not match its slice")
            result.append((slice_name, minos, platform))
        if len({name for name, _, _ in result}) != len(result):
            raise ReleaseError("Universal Mach-O contains duplicate architecture slices")
        return result
    try:
        return [_thin_macho(data, 0, len(data))]
    except ReleaseError as exc:
        if data[:4] in (b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
            raise
        return None


def _allowed_bundle_file(relative: str) -> bool:
    allowed = {
        "Contents/Info.plist",
        "Contents/MacOS/CodexSwoop",
        "Contents/MacOS/codexswoop-recovery",
        "Contents/Resources/AppIcon.icns",
        "Contents/Resources/Assets.car",
        "Contents/Resources/MenuBarIcon.png",
        "Contents/Resources/MenuBarIcon@2x.png",
        "Contents/PkgInfo",
        "Contents/_CodeSignature/CodeResources",
    }
    return relative in allowed


def _is_png(data: bytes) -> bool:
    signature = b"\x89PNG\r\n\x1a\n"
    if not data.startswith(signature):
        return False
    cursor = len(signature)
    saw_header = False
    saw_data = False
    saw_end = False
    while cursor + 12 <= len(data):
        length = struct.unpack_from(">I", data, cursor)[0]
        kind_start = cursor + 4
        data_start = cursor + 8
        crc_offset = data_start + length
        if crc_offset + 4 > len(data):
            return False
        kind = data[kind_start:data_start]
        payload = data[data_start:crc_offset]
        checksum = struct.unpack_from(">I", data, crc_offset)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != checksum:
            return False
        if not saw_header:
            if kind != b"IHDR" or length != 13:
                return False
            width, height = struct.unpack_from(">II", payload)
            if width == 0 or height == 0:
                return False
            saw_header = True
        elif kind == b"IHDR":
            return False
        if kind == b"IDAT":
            saw_data = True
        if kind == b"IEND":
            if length != 0 or crc_offset + 4 != len(data):
                return False
            saw_end = True
            break
        cursor = crc_offset + 4
    return saw_header and saw_data and saw_end


def _valid_icns(data: bytes) -> bool:
    if len(data) < 16 or data[:4] != b"icns" or struct.unpack_from(">I", data, 4)[0] != len(data):
        return False
    cursor = 8
    chunks = 0
    while cursor + 8 <= len(data):
        size = struct.unpack_from(">I", data, cursor + 4)[0]
        if size < 8 or cursor + size > len(data):
            return False
        cursor += size
        chunks += 1
    return cursor == len(data) and chunks > 0


def _inspect_bundle_files(app: Path) -> tuple[list[Path], dict[str, object]]:
    if app.is_symlink() or not app.exists() or not app.is_dir() or app.name != "CodexSwoop.app":
        raise ReleaseError(f"Expected an existing .app bundle: {app}")
    info_path = app / "Contents/Info.plist"
    executable = app / "Contents/MacOS/CodexSwoop"
    if not info_path.is_file() or not executable.is_file():
        raise ReleaseError("Bundle is missing Contents/Info.plist or Contents/MacOS/CodexSwoop")
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise ReleaseError(f"Info.plist cannot be read: {exc}") from exc
    if not isinstance(info, dict):
        raise ReleaseError("Info.plist root must be a dictionary")

    allowed_directories = {
        "Contents",
        "Contents/MacOS",
        "Contents/Resources",
        "Contents/_CodeSignature",
    }
    files: list[Path] = []
    for root, directories, names in os.walk(app, followlinks=False):
        root_path = Path(root)
        for name in list(directories):
            path = root_path / name
            relative = path.relative_to(app).as_posix()
            if path.is_symlink():
                raise ReleaseError(f"Unexpected symlink in app bundle: {relative}")
            if relative not in allowed_directories:
                raise ReleaseError(f"Unexpected directory in app bundle: {relative}")
        for name in names:
            path = root_path / name
            relative = path.relative_to(app).as_posix()
            if path.is_symlink() or not path.is_file():
                raise ReleaseError(f"Unexpected non-regular bundle entry: {relative}")
            if not _allowed_bundle_file(relative):
                raise ReleaseError(f"Unexpected file in app bundle: {relative}")
            if path.stat().st_size == 0:
                raise ReleaseError(f"Empty required bundle file: {relative}")
            files.append(path)

    if "Contents/Resources/AppIcon.icns" not in {path.relative_to(app).as_posix() for path in files} and "Contents/Resources/Assets.car" not in {path.relative_to(app).as_posix() for path in files}:
        raise ReleaseError("Bundle must include AppIcon.icns or a compiled Assets.car")
    required_menu_icons = {"Contents/Resources/MenuBarIcon.png", "Contents/Resources/MenuBarIcon@2x.png"}
    actual_files = {path.relative_to(app).as_posix() for path in files}
    if not required_menu_icons.issubset(actual_files):
        raise ReleaseError("Bundle is missing MenuBarIcon.png or MenuBarIcon@2x.png")
    for icon in (app / "Contents/Resources/MenuBarIcon.png", app / "Contents/Resources/MenuBarIcon@2x.png"):
        if not _is_png(icon.read_bytes()):
            raise ReleaseError(f"Menu bar resource is not a valid PNG image: {icon.name}")
    icns = app / "Contents/Resources/AppIcon.icns"
    if icns.exists() and not _valid_icns(icns.read_bytes()):
        raise ReleaseError("AppIcon.icns is not a valid ICNS container")
    return files, info


def _check_metadata(info: dict[str, object], expected_version: str | None) -> tuple[str, str]:
    unexpected_keys = set(info) - INFO_PLIST_KEYS
    if unexpected_keys:
        raise ReleaseError(f"Unexpected Info.plist keys may carry non-release data: {', '.join(sorted(map(str, unexpected_keys)))}")
    if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
        raise ReleaseError(f"Unexpected Bundle ID: {info.get('CFBundleIdentifier')!r}")
    if info.get("CFBundleExecutable") != "CodexSwoop" or info.get("CFBundlePackageType") != "APPL" or info.get("CFBundleIconFile") != "AppIcon":
        raise ReleaseError("Info.plist does not describe the expected CodexSwoop application")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    parse_version(version, "CFBundleShortVersionString")
    if not isinstance(build, (str, int)) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", str(build)):
        raise ReleaseError("CFBundleVersion must be a numeric build number")
    if expected_version is not None and version != expected_version:
        raise ReleaseError(f"Expected application version {expected_version}, found {version}; version metadata is never rewritten by packaging")
    minimum = info.get("LSMinimumSystemVersion")
    if parse_version(minimum, "LSMinimumSystemVersion") != MINIMUM_MACOS:
        raise ReleaseError("LSMinimumSystemVersion must be exactly 14.0 for the public Sonoma-and-newer target")
    forbidden_keys = {key for key in info if isinstance(key, str) and re.search(r"(fixture|testmode|uitest|qaonly|debugbuild)", key, re.IGNORECASE)}
    if forbidden_keys:
        raise ReleaseError(f"Test-only Info.plist keys are not allowed: {', '.join(sorted(forbidden_keys))}")
    return str(version), str(build)


def inspect_app(app: Path, *, expected_version: str | None = None) -> tuple[str, str]:
    files, info = _inspect_bundle_files(app)
    version, build = _check_metadata(info, expected_version)
    executable = app / "Contents/MacOS/CodexSwoop"
    if not os.access(executable, os.X_OK):
        raise ReleaseError("CodexSwoop executable bit is not set")
    helper = app / "Contents/MacOS/codexswoop-recovery"
    if helper.exists() and (not os.access(helper, os.X_OK) or macho_slices(helper.read_bytes()) is None):
        raise ReleaseError("Recovery helper must be an executable Mach-O")
    macho_count = 0
    for path in files:
        try:
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic not in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
                continue
            data = path.read_bytes()
        except OSError as exc:
            raise ReleaseError(f"Unable to inspect bundle file {path}: {exc}") from exc
        slices = macho_slices(data)
        if not slices:
            continue
        macho_count += 1
        architectures = {architecture for architecture, _, _ in slices}
        if architectures != {"arm64"}:
            raise ReleaseError(f"{path.relative_to(app)} must be arm64-only; found {', '.join(sorted(architectures))}")
        minimums = [minimum for _, minimum, _ in slices]
        if any(minimum is None for minimum in minimums):
            raise ReleaseError(f"{path.relative_to(app)} is missing a macOS deployment target load command")
        platforms = [platform for _, _, platform in slices]
        if any(platform != 1 for platform in platforms):
            raise ReleaseError(f"{path.relative_to(app)} contains a Mach-O slice not built for the macOS platform")
        if any(minimum != MINIMUM_MACOS for minimum in minimums):
            rendered = ", ".join(".".join(map(str, minimum or ())) for minimum in minimums)
            raise ReleaseError(f"{path.relative_to(app)} minimum OS must be 14.0 in every slice; found {rendered}")
    if macho_count == 0 or macho_slices((app / "Contents/MacOS/CodexSwoop").read_bytes()) is None:
        raise ReleaseError("App bundle does not contain a Mach-O executable")
    return version, build


def _signature_details(app: Path, *, public: bool, runner: Callable[..., subprocess.CompletedProcess[str]], require_notarization: bool = True) -> None:
    runner(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    if not public:
        return
    details = runner(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)])
    text = (details.stdout or "") + "\n" + (details.stderr or "")
    if "Authority=Developer ID Application:" not in text:
        raise ReleaseError("Public release requires a real Developer ID Application signature")
    if not re.search(r"flags=.*\bruntime\b", text, re.IGNORECASE):
        raise ReleaseError("Public release requires the Hardened Runtime signature flag")
    if not re.search(r"^Timestamp=\S+", text, re.MULTILINE):
        raise ReleaseError("Public release requires a secure signing timestamp")
    if re.search(r"^TeamIdentifier=(?:not set)?\s*$", text, re.MULTILINE):
        raise ReleaseError("Public release signature is missing its Team Identifier")
    if require_notarization:
        runner(["/usr/bin/xcrun", "stapler", "validate", str(app)])
        runner(["/usr/sbin/spctl", "-a", "-t", "exec", "-vv", str(app)])


def validate_app(app: Path, mode: str, *, expected_version: str | None = None, runner: Callable[..., subprocess.CompletedProcess[str]] = run_command) -> tuple[str, str]:
    if mode == PUBLIC_MODE:
        if expected_version is not None and expected_version != PUBLIC_VERSION:
            raise ReleaseError(f"Public validation is fixed to version {PUBLIC_VERSION}")
        expected_version = PUBLIC_VERSION
    version, build = inspect_app(app, expected_version=expected_version)
    _signature_details(app, public=(mode == PUBLIC_MODE), runner=runner)
    return version, build


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def checksum_path(dmg: Path) -> Path:
    return Path(str(dmg) + ".sha256")


def _check_checksum(dmg: Path, *, required: bool) -> str:
    expected = checksum_path(dmg)
    actual_hash = _sha256(dmg)
    if not expected.exists():
        if required:
            raise ReleaseError(f"Public artifact is missing its SHA-256 sidecar: {expected}")
        return actual_hash
    try:
        line = expected.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as exc:
        raise ReleaseError(f"Checksum sidecar cannot be read: {exc}") from exc
    match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)", line)
    if not match or match.group(2) != dmg.name:
        raise ReleaseError("Checksum sidecar must contain one lowercase SHA-256 line for this DMG")
    if match.group(1) != actual_hash:
        raise ReleaseError(f"SHA-256 mismatch for {dmg.name}")
    return actual_hash


def _verify_image(dmg: Path, runner: Callable[..., subprocess.CompletedProcess[str]]) -> None:
    if not dmg.is_file() or dmg.stat().st_size == 0 or dmg.suffix.lower() != ".dmg":
        raise ReleaseError(f"Expected a non-empty DMG file: {dmg}")
    runner(["/usr/bin/hdiutil", "verify", str(dmg)])


def validate_mounted_root(mountpoint: Path, mode: str, *, expected_version: str | None, runner: Callable[..., subprocess.CompletedProcess[str]]) -> tuple[str, str]:
    if not mountpoint.is_dir():
        raise ReleaseError("DMG mountpoint is unavailable")
    allowed = {"CodexSwoop.app", "Applications", ".background", ".DS_Store"}
    entries = {entry.name for entry in mountpoint.iterdir()}
    unexpected = entries - allowed
    missing = {"CodexSwoop.app", "Applications", ".background"} - entries
    if unexpected:
        raise ReleaseError(f"Unexpected file(s) in DMG root: {', '.join(sorted(unexpected))}")
    if missing:
        raise ReleaseError(f"DMG is missing required root item(s): {', '.join(sorted(missing))}")
    alias = mountpoint / "Applications"
    if not alias.is_symlink() or os.readlink(alias) != "/Applications":
        raise ReleaseError("Applications must be an absolute symlink to /Applications")
    for name in (".background",):
        hidden = mountpoint / name
        if not hidden.is_dir() or hidden.is_symlink():
            raise ReleaseError(f"DMG {name} must be a real directory")
        children = {child.name for child in hidden.iterdir()}
        if children != {"DMGBackground.png"}:
            raise ReleaseError(f"DMG {name} must contain only DMGBackground.png")
        background = hidden / "DMGBackground.png"
        if background.is_symlink() or not background.is_file() or not _is_png(background.read_bytes()):
            raise ReleaseError("DMG background must be a regular PNG image")
    ds_store = mountpoint / ".DS_Store"
    if ds_store.exists() and (ds_store.is_symlink() or not ds_store.is_file() or ds_store.stat().st_size == 0):
        raise ReleaseError("Finder layout metadata must be a non-empty regular .DS_Store file")
    return validate_app(mountpoint / "CodexSwoop.app", mode, expected_version=expected_version, runner=runner)


def validate_dmg(dmg: Path, mode: str, *, expected_version: str | None = None, runner: Callable[..., subprocess.CompletedProcess[str]] = run_command, require_public_filename: bool = True, require_checksum: bool | None = None) -> str:
    if mode == PUBLIC_MODE:
        if expected_version is not None and expected_version != PUBLIC_VERSION:
            raise ReleaseError(f"Public validation is fixed to version {PUBLIC_VERSION}")
        expected_version = PUBLIC_VERSION
    _verify_image(dmg, runner)
    if mode == PUBLIC_MODE and require_public_filename and dmg.name != PUBLIC_DMG_NAME:
        raise ReleaseError(f"Public artifact filename must be {PUBLIC_DMG_NAME}")
    with tempfile.TemporaryDirectory(prefix="codexswoop-dmg-verify-") as temp:
        mountpoint = Path(temp) / "mount"
        mountpoint.mkdir()
        mounted = False
        try:
            runner(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mountpoint), str(dmg)])
            mounted = True
            validate_mounted_root(mountpoint, mode, expected_version=expected_version, runner=runner)
        finally:
            if mounted:
                runner(["/usr/bin/hdiutil", "detach", str(mountpoint)])
    if mode == PUBLIC_MODE:
        runner(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(dmg)])
        details = runner(["/usr/bin/codesign", "-dv", "--verbose=4", str(dmg)])
        text = (details.stdout or "") + "\n" + (details.stderr or "")
        if "Authority=Developer ID Application:" not in text:
            raise ReleaseError("Public DMG requires a real Developer ID Application signature")
        if not re.search(r"^Timestamp=\S+", text, re.MULTILINE):
            raise ReleaseError("Public DMG requires a secure signing timestamp")
        runner(["/usr/bin/xcrun", "stapler", "validate", str(dmg)])
        runner(["/usr/sbin/spctl", "-a", "-t", "open", "--context", "context:primary-signature", "-vv", str(dmg)])
    if require_checksum is None:
        require_checksum = mode == PUBLIC_MODE
    return _check_checksum(dmg, required=require_checksum)


def _set_pixel(pixels: bytearray, width: int, height: int, x: int, y: int, color: tuple[int, int, int]) -> None:
    if 0 <= x < width and 0 <= y < height:
        offset = (y * width + x) * 3
        pixels[offset : offset + 3] = bytes(color)


def _draw_line(pixels: bytearray, width: int, height: int, x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int], thickness: int = 1) -> None:
    dx, sx = abs(x1 - x0), 1 if x0 < x1 else -1
    dy, sy = -abs(y1 - y0), 1 if y0 < y1 else -1
    error = dx + dy
    while True:
        radius = max(0, thickness // 2)
        for oy in range(-radius, radius + 1):
            for ox in range(-radius, radius + 1):
                _set_pixel(pixels, width, height, x0 + ox, y0 + oy, color)
        if x0 == x1 and y0 == y1:
            break
        twice = 2 * error
        if twice >= dy:
            error += dy
            x0 += sx
        if twice <= dx:
            error += dx
            y0 += sy


_FONT = {
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "C": ("01111", "10000", "10000", "10000", "10000", "10000", "01111"),
    "D": ("11110", "10001", "10001", "10001", "10001", "10001", "11110"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "F": ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
    "G": ("01111", "10000", "10000", "10111", "10001", "10001", "01111"),
    "H": ("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
    "I": ("11111", "00100", "00100", "00100", "00100", "00100", "11111"),
    "J": ("00111", "00010", "00010", "00010", "10010", "10010", "01100"),
    "K": ("10001", "10010", "10100", "11000", "10100", "10010", "10001"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "M": ("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
    "N": ("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "Q": ("01110", "10001", "10001", "10001", "10101", "10010", "01101"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "T": ("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "V": ("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
    "W": ("10001", "10001", "10001", "10101", "10101", "10101", "01010"),
    "X": ("10001", "10001", "01010", "00100", "01010", "10001", "10001"),
    "Y": ("10001", "10001", "01010", "00100", "00100", "00100", "00100"),
    "Z": ("11111", "00001", "00010", "00100", "01000", "10000", "11111"),
    "a": ("00000", "01110", "00001", "01111", "10001", "10011", "01101"),
    "c": ("00000", "01111", "10000", "10000", "10000", "10000", "01111"),
    "d": ("00001", "00001", "01111", "10001", "10001", "10011", "01101"),
    "e": ("00000", "01110", "10001", "11111", "10000", "10001", "01110"),
    "g": ("00000", "01111", "10001", "10001", "01111", "00001", "01110"),
    "i": ("00100", "00000", "01100", "00100", "00100", "00100", "01110"),
    "l": ("01100", "00100", "00100", "00100", "00100", "00100", "01110"),
    "n": ("00000", "10110", "11001", "10001", "10001", "10001", "10001"),
    "o": ("00000", "01110", "10001", "10001", "10001", "10001", "01110"),
    "p": ("00000", "11110", "10001", "10001", "11110", "10000", "10000"),
    "r": ("00000", "10110", "11001", "10000", "10000", "10000", "10000"),
    "s": ("00000", "01111", "10000", "01110", "00001", "00001", "11110"),
    "t": ("01000", "01000", "11110", "01000", "01000", "01001", "00110"),
    "v": ("00000", "10001", "10001", "10001", "10001", "01010", "00100"),
    "w": ("00000", "10001", "10001", "10101", "10101", "10101", "01010"),
    "z": ("00000", "11111", "00010", "00100", "01000", "10000", "11111"),
    "-": ("00000", "00000", "00000", "11111", "00000", "00000", "00000"),
}


def _draw_label(pixels: bytearray, width: int, height: int, text: str, *, top: int, scale: int, color: tuple[int, int, int]) -> None:
    advance = 7 * scale
    total_width = max(0, len(text) * advance - 2 * scale)
    start_x = (width - total_width) // 2
    for character_index, character in enumerate(text):
        if character == " ":
            continue
        glyph = _FONT.get(character)
        if glyph is None:
            continue
        for row_index, row in enumerate(glyph):
            for column_index, bit in enumerate(row):
                if bit == "1":
                    for dy in range(scale):
                        for dx in range(scale):
                            _set_pixel(pixels, width, height, start_x + character_index * advance + column_index * scale + dx, top + row_index * scale + dy, color)


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    payload = kind + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)


def write_dmg_background(path: Path, *, local_preview: bool = False) -> None:
    width, height = 1100, 600
    background = (23, 25, 29)
    pixels = bytearray(background * (width * height))
    coral = (255, 90, 54)
    muted = (64, 67, 73)
    _draw_line(pixels, width, height, 88, 60, width - 88, 60, muted, 1)
    _draw_line(pixels, width, height, 88, height - 60, width - 88, height - 60, muted, 1)
    _draw_label(pixels, width, height, "Drag to Applications", top=125, scale=4, color=coral)
    _draw_line(pixels, width, height, 420, 340, 680, 340, coral, 2)
    _draw_line(pixels, width, height, 680, 340, 658, 326, coral, 2)
    _draw_line(pixels, width, height, 680, 340, 658, 354, coral, 2)
    if local_preview:
        _draw_label(pixels, width, height, "local-preview - not notarized", top=455, scale=2, color=(145, 149, 157))
    rows = b"".join(b"\x00" + pixels[y * width * 3 : (y + 1) * width * 3] for y in range(height))
    png = b"\x89PNG\r\n\x1a\n"
    png += _png_chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 2, 0, 0, 0))
    png += _png_chunk(b"IDAT", zlib.compress(rows, level=9))
    png += _png_chunk(b"IEND", b"")
    path.write_bytes(png)


def _ensure_preview_output_dir(output_dir: Path, repository: Path) -> Path:
    build_root = (repository / "build").resolve()
    resolved = output_dir.resolve()
    try:
        resolved.relative_to(build_root)
    except ValueError as exc:
        raise ReleaseError("Local preview and release artifacts may be written only below the ignored repository build/ directory") from exc
    resolved.mkdir(parents=True, exist_ok=True)
    return resolved


def _copy_bundle(source: Path, destination: Path, runner: Callable[..., subprocess.CompletedProcess[str]]) -> None:
    runner(["/usr/bin/ditto", str(source), str(destination)])


def _create_dmg(staging: Path, output: Path, runner: Callable[..., subprocess.CompletedProcess[str]]) -> None:
    runner(["/usr/bin/hdiutil", "create", "-srcfolder", str(staging), "-volname", "CodexSwoop", "-format", "UDZO", "-ov", "-o", str(output)])


def package_release(args: argparse.Namespace, *, repository: Path, runner: Callable[..., subprocess.CompletedProcess[str]] = run_command) -> Path:
    app = Path(args.app).expanduser().resolve()
    expected_version = args.expected_version
    if args.mode == PUBLIC_MODE:
        if not args.identity or not args.notary_profile:
            raise ReleaseError("Public packaging requires --identity and --notary-profile; configure these secure external credentials before use")
        if expected_version is None:
            expected_version = PUBLIC_VERSION
        if expected_version != PUBLIC_VERSION:
            raise ReleaseError(f"Public packaging is fixed to version {PUBLIC_VERSION}; application version is never rewritten")
        inspect_app(app, expected_version=PUBLIC_VERSION)
    elif expected_version is not None:
        parse_version(expected_version, "--expected-version")
        inspect_app(app, expected_version=expected_version)
    else:
        inspect_app(app)

    output_dir = _ensure_preview_output_dir(Path(args.output_dir), repository)
    version = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
    if args.mode == PUBLIC_MODE:
        final_name = PUBLIC_DMG_NAME
    else:
        final_name = f"CodexSwoop-{version}-macos-arm64-local-preview.dmg"
    final_path = output_dir / final_name
    partial_path = output_dir / f".{final_name}.partial.dmg"
    if partial_path.exists():
        partial_path.unlink()
    with tempfile.TemporaryDirectory(prefix="codexswoop-release-stage-") as temp:
        temp_root = Path(temp)
        payload = temp_root / "payload"
        payload.mkdir()
        staged_app = payload / "CodexSwoop.app"
        _copy_bundle(app, staged_app, runner)

        if args.mode == PUBLIC_MODE:
            helper = staged_app / "Contents/MacOS/codexswoop-recovery"
            if helper.exists():
                runner(["/usr/bin/codesign", "--force", "--sign", args.identity, "--options", "runtime", "--timestamp", str(helper)])
            runner(["/usr/bin/codesign", "--force", "--sign", args.identity, "--options", "runtime", "--timestamp", str(staged_app)])
            _signature_details(staged_app, public=True, runner=runner, require_notarization=False)
            app_zip = output_dir / f".{final_name}.app.zip"
            try:
                runner(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(staged_app), str(app_zip)])
                runner(["/usr/bin/xcrun", "notarytool", "submit", str(app_zip), "--keychain-profile", args.notary_profile, "--wait"])
                runner(["/usr/bin/xcrun", "stapler", "staple", str(staged_app)])
            finally:
                app_zip.unlink(missing_ok=True)
            validate_app(staged_app, PUBLIC_MODE, expected_version=PUBLIC_VERSION, runner=runner)
        elif args.mode != LOCAL_MODE:
            raise ReleaseError(f"Unknown packaging mode: {args.mode}")
        else:
            validate_app(staged_app, LOCAL_MODE, expected_version=expected_version, runner=runner)

        applications = payload / "Applications"
        applications.symlink_to("/Applications")
        background_dir = payload / ".background"
        background_dir.mkdir()
        write_dmg_background(background_dir / "DMGBackground.png", local_preview=(args.mode == LOCAL_MODE))
        _create_dmg(payload, partial_path, runner)
        if args.mode == PUBLIC_MODE:
            runner(["/usr/bin/codesign", "--force", "--sign", args.identity, "--timestamp", str(partial_path)])
            runner(["/usr/bin/xcrun", "notarytool", "submit", str(partial_path), "--keychain-profile", args.notary_profile, "--wait"])
            runner(["/usr/bin/xcrun", "stapler", "staple", str(partial_path)])
        validate_dmg(partial_path, args.mode, expected_version=expected_version, runner=runner, require_public_filename=False, require_checksum=False)

    os.replace(partial_path, final_path)
    digest = _sha256(final_path)
    checksum_path(final_path).write_text(f"{digest}  {final_path.name}\n", encoding="ascii")
    validate_dmg(final_path, args.mode, expected_version=expected_version, runner=runner)
    return final_path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    package = commands.add_parser("package", help="package a pre-built .app into a local preview or public release DMG")
    package.add_argument("--mode", choices=(LOCAL_MODE, PUBLIC_MODE), required=True)
    package.add_argument("--app", required=True, help="path to an already-built CodexSwoop.app")
    package.add_argument("--output-dir", default="build/release-dmg")
    package.add_argument("--expected-version")
    package.add_argument("--identity", help="Developer ID Application identity name (public mode only)")
    package.add_argument("--notary-profile", help="notarytool keychain profile name (public mode only)")

    validate = commands.add_parser("validate", help="validate a built .app or a completed DMG")
    target = validate.add_mutually_exclusive_group(required=True)
    target.add_argument("--app")
    target.add_argument("--dmg")
    validate.add_argument("--mode", choices=(LOCAL_MODE, PUBLIC_MODE), required=True)
    validate.add_argument("--expected-version")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    repository = Path(__file__).resolve().parent.parent
    try:
        if args.command == "package":
            result = package_release(args, repository=repository)
            print(f"PASS {args.mode}: {result}")
            print(f"SHA-256: {_sha256(result)}")
            if args.mode == LOCAL_MODE:
                print("Local preview only. Not notarized and not for public distribution.")
            else:
                print("PUBLIC RELEASE VALIDATION PASSED: Developer ID, Hardened Runtime, notarization and stapling checks succeeded.")
            return 0
        if args.app:
            app = Path(args.app).expanduser().resolve()
            version, build = validate_app(app, args.mode, expected_version=args.expected_version)
            print(f"PASS {args.mode} app: {app} (version {version}, build {build}, arm64, minimum macOS 14.0)")
        else:
            dmg = Path(args.dmg).expanduser().resolve()
            digest = validate_dmg(dmg, args.mode, expected_version=args.expected_version)
            print(f"PASS {args.mode} DMG: {dmg}")
            print(f"SHA-256: {digest}")
            if args.mode == LOCAL_MODE:
                print("Local preview only. Not notarized and not for public distribution.")
            else:
                print("PUBLIC RELEASE VALIDATION PASSED: Developer ID, notarization, stapling, Gatekeeper and checksum checks succeeded.")
        return 0
    except (ReleaseError, OSError, KeyError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
