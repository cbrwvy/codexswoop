#!/usr/bin/env python3
import importlib.util
import plistlib
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_artifact", ROOT / "scripts/release_artifact.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def macho(cpu_type=release.ARM64, minos=(14, 0, 0), platform=1):
    version = (minos[0] << 16) | (minos[1] << 8) | minos[2]
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cpu_type, 0, 2, 1, 24, 0, 0)
    command = struct.pack("<IIIIII", release.LC_BUILD_VERSION, 24, platform, version, version, 0)
    return header + command


def png():
    signature = b"\x89PNG\r\n\x1a\n"
    header = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    raw_pixel = zlib.compress(b"\x00\x00\x00\x00\x00")
    return signature + release._png_chunk(b"IHDR", header) + release._png_chunk(b"IDAT", raw_pixel) + release._png_chunk(b"IEND", b"")


def universal(*slices):
    header_size = 8 + 20 * len(slices)
    entries = []
    payload = bytearray()
    offset = header_size
    for binary in slices:
        cpu_type = struct.unpack_from("<i", binary, 4)[0]
        subtype = struct.unpack_from("<i", binary, 8)[0]
        entries.append(struct.pack(">IIIII", cpu_type, subtype, offset, len(binary), 0))
        payload.extend(binary)
        offset += len(binary)
    return struct.pack(">II", 0xCAFEBABE, len(slices)) + b"".join(entries) + bytes(payload)


def create_app(parent, *, binary=None, bundle_id=release.EXPECTED_BUNDLE_ID, version="0.1.0", build="3", include_resources=True):
    app = parent / "CodexSwoop.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    executable = contents / "MacOS/CodexSwoop"
    executable.write_bytes(binary or macho())
    executable.chmod(0o755)
    info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "CodexSwoop",
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "LSMinimumSystemVersion": "14.0",
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    if include_resources:
        icns_chunk = b"icp4" + struct.pack(">I", 12) + b"test"
        (resources / "AppIcon.icns").write_bytes(b"icns" + struct.pack(">I", 8 + len(icns_chunk)) + icns_chunk)
        (resources / "MenuBarIcon.png").write_bytes(png())
        (resources / "MenuBarIcon@2x.png").write_bytes(png())
    signature = contents / "_CodeSignature"
    signature.mkdir()
    (signature / "CodeResources").write_text("synthetic signature seal", encoding="utf-8")
    return app


def success(command, **kwargs):
    return subprocess.CompletedProcess(command, 0, stdout="", stderr="")


class ReleaseToolingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codexswoop-release-tests-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_valid_synthetic_arm64_app(self):
        app = create_app(self.root)
        version, build = release.validate_app(app, release.LOCAL_MODE, runner=success)
        self.assertEqual((version, build), ("0.1.0", "3"))

    def test_recovery_helper_is_an_exact_allowlisted_macho(self):
        app = create_app(self.root)
        helper = app / "Contents/MacOS/codexswoop-recovery"
        helper.write_bytes(macho())
        helper.chmod(0o755)
        release.inspect_app(app)
        helper.write_bytes(b"not executable code")
        with self.assertRaisesRegex(release.ReleaseError, "executable Mach-O"):
            release.inspect_app(app)

    def test_recovery_helper_wrong_arch_is_rejected(self):
        app = create_app(self.root)
        helper = app / "Contents/MacOS/codexswoop-recovery"
        helper.write_bytes(macho(release.X86_64))
        helper.chmod(0o755)
        with self.assertRaisesRegex(release.ReleaseError, "arm64-only"):
            release.inspect_app(app)

    def test_x86_64_app_is_rejected(self):
        app = create_app(self.root, binary=macho(release.X86_64))
        with self.assertRaisesRegex(release.ReleaseError, "arm64-only"):
            release.inspect_app(app)

    def test_universal_app_is_rejected_in_arm64_only_mode(self):
        app = create_app(self.root, binary=universal(macho(), macho(release.X86_64)))
        with self.assertRaisesRegex(release.ReleaseError, "arm64-only"):
            release.inspect_app(app)

    def test_wrong_bundle_id_is_rejected(self):
        app = create_app(self.root, bundle_id="example.invalid")
        with self.assertRaisesRegex(release.ReleaseError, "Bundle ID"):
            release.inspect_app(app)

    def test_missing_mandatory_resource_is_rejected(self):
        app = create_app(self.root, include_resources=False)
        with self.assertRaisesRegex(release.ReleaseError, "AppIcon.icns|Assets.car"):
            release.inspect_app(app)

    def test_wrong_version_is_rejected_without_rewriting_metadata(self):
        app = create_app(self.root)
        with self.assertRaisesRegex(release.ReleaseError, "version 1.0.0"):
            release.inspect_app(app, expected_version="1.0.0")
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")

    def test_public_release_does_not_accept_the_current_development_version(self):
        app = create_app(self.root)
        with self.assertRaisesRegex(release.ReleaseError, "Expected application version 1.0.0"):
            release.validate_app(app, release.PUBLIC_MODE, runner=success)

    def test_invalid_png_resource_is_rejected(self):
        app = create_app(self.root)
        (app / "Contents/Resources/MenuBarIcon@2x.png").write_bytes(b"\x89PNG\r\n\x1a\nnot a PNG")
        with self.assertRaisesRegex(release.ReleaseError, "valid PNG"):
            release.inspect_app(app)

    def test_unexpected_info_plist_data_is_rejected(self):
        app = create_app(self.root)
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CodexSwoopCustomerEmail"] = "synthetic@example.invalid"
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(release.ReleaseError, "non-release data"):
            release.inspect_app(app)

    def test_unexpected_file_in_packaging_staging_is_rejected(self):
        root = self.root / "mounted"
        root.mkdir()
        (root / "CodexSwoop.app").mkdir()
        (root / "Applications").symlink_to("/Applications")
        (root / ".background").mkdir()
        (root / ".background/DMGBackground.png").write_bytes(png())
        (root / "debug.log").write_text("not allowed", encoding="utf-8")
        with self.assertRaisesRegex(release.ReleaseError, "Unexpected file"):
            release.validate_mounted_root(root, release.LOCAL_MODE, expected_version=None, runner=success)

    def test_incorrect_applications_symlink_is_rejected(self):
        root = self.root / "mounted"
        root.mkdir()
        (root / "CodexSwoop.app").mkdir()
        (root / "Applications").symlink_to("/tmp")
        (root / ".background").mkdir()
        (root / ".background/DMGBackground.png").write_bytes(png())
        with self.assertRaisesRegex(release.ReleaseError, "absolute symlink to /Applications"):
            release.validate_mounted_root(root, release.LOCAL_MODE, expected_version=None, runner=success)

    def test_public_mode_rejects_an_ad_hoc_signature(self):
        app = create_app(self.root)

        def ad_hoc(command, **kwargs):
            if command[0].endswith("codesign") and "-dv" in command:
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="Signature=adhoc\nflags=0x0\n")
            return success(command)

        with self.assertRaisesRegex(release.ReleaseError, "real Developer ID Application"):
            release._signature_details(app, public=True, runner=ad_hoc)

    def test_public_mode_rejects_a_missing_signature(self):
        app = create_app(self.root)

        def missing_signature(command, **kwargs):
            if command[0].endswith("codesign"):
                raise release.ReleaseError("codesign: code object is not signed at all")
            return success(command)

        with self.assertRaisesRegex(release.ReleaseError, "not signed at all"):
            release._signature_details(app, public=True, runner=missing_signature)

    def test_app_with_non_sonoma_deployment_target_is_rejected(self):
        app = create_app(self.root, binary=macho(minos=(13, 0, 0)))
        with self.assertRaisesRegex(release.ReleaseError, "minimum OS must be 14.0"):
            release.inspect_app(app)

    def test_non_macos_macho_platform_is_rejected(self):
        app = create_app(self.root, binary=macho(platform=2))
        with self.assertRaisesRegex(release.ReleaseError, "not built for the macOS platform"):
            release.inspect_app(app)

    def test_damaged_dmg_is_rejected(self):
        dmg = self.root / "damaged.dmg"
        dmg.write_bytes(b"damaged image")

        def bad_image(command, **kwargs):
            if command[1:2] == ["verify"]:
                raise release.ReleaseError("hdiutil verify failed")
            return success(command)

        with self.assertRaisesRegex(release.ReleaseError, "hdiutil verify failed"):
            release.validate_dmg(dmg, release.LOCAL_MODE, runner=bad_image)

    def test_checksum_mismatch_is_rejected(self):
        dmg = self.root / "preview.dmg"
        dmg.write_bytes(b"synthetic dmg bytes")
        release.checksum_path(dmg).write_text("0" * 64 + "  preview.dmg\n", encoding="ascii")
        with self.assertRaisesRegex(release.ReleaseError, "SHA-256 mismatch"):
            release._check_checksum(dmg, required=True)

    def test_arm64_only_parser_records_minimum_os(self):
        slices = release.macho_slices(macho())
        self.assertEqual(slices, [("arm64", (14, 0, 0), 1)])


if __name__ == "__main__":
    unittest.main()
