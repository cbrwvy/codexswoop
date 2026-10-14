"""Heuristic Git audit tests use only generated non-secret data and disposable files."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import tempfile
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("baseline_audit", Path(__file__).resolve().parents[2] / "scripts/audit-baseline.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class BaselineAuditTests(unittest.TestCase):
    def inspect(self, root, candidates):
        def git(*args):
            return b"" if args == ("ls-files", "-z") else b"\0".join(name.encode() for name in candidates) + b"\0"
        with patch.object(audit, "ROOT", root), patch.object(audit, "git", git), patch.object(
                audit.subprocess, "run", return_value=SimpleNamespace(stdout="\n".join(audit.EXCLUDED))):
            return audit.audit()

    def test_reviewed_screenshot_assets_are_accepted_from_worktree_and_index(self):
        self.assertEqual(set(audit.SCREENSHOT_ASSETS), {
            "docs/assets/screenshots/codexswoop-overview.png",
            "docs/assets/screenshots/recovery.png",
            "docs/assets/screenshots/settings.png",
        })
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text((audit.ROOT / ".gitignore").read_text())
            for name in audit.SCREENSHOT_ASSETS:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((audit.ROOT / name).read_bytes())
            subprocess.run(["git", "-C", str(root), "add", "--", *audit.SCREENSHOT_ASSETS], check=True)
            with patch.object(audit, "ROOT", root):
                working = audit.audit()
                staged = audit.audit(staged=True)
            self.assertEqual(working["findings"], [])
            self.assertEqual(staged["findings"], [])
            self.assertTrue(set(audit.SCREENSHOT_ASSETS).issubset(working["candidates"]))
            self.assertEqual(set(audit.SCREENSHOT_ASSETS), set(staged["candidates"]))

    def test_png_outside_reviewed_catalog_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            name = "docs/assets/screenshots/unexpected.png"
            path = root / name
            path.parent.mkdir(parents=True)
            path.write_bytes(b"not a reviewed screenshot")
            result = self.inspect(root, [name])
            self.assertEqual(result["findings"], [{"path": name, "rule": "unexpected-file-extension"}])

    def test_png_extension_with_invalid_content_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            name = "docs/assets/screenshots/recovery.png"
            path = root / name
            path.parent.mkdir(parents=True)
            path.write_bytes(b"not a PNG file")
            result = self.inspect(root, [name])
            self.assertEqual(result["findings"], [{"path": name, "rule": "invalid-screenshot-asset"}])

    def test_unknown_binary_extension_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            name = "docs/assets/screenshots/extra.bin"
            path = root / name
            path.parent.mkdir(parents=True)
            path.write_bytes(b"\x00\x01unrecognized binary")
            result = self.inspect(root, [name])
            self.assertEqual(result["findings"], [{"path": name, "rule": "unexpected-file-extension"}])

    def test_ignored_idea_does_not_hide_other_untracked_secret(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text((audit.ROOT / ".gitignore").read_text())
            private_ide_file = root / ".idea" / "codexswoop.iml"
            private_ide_file.parent.mkdir()
            private_ide_file.write_text("local IDE configuration")
            secret = "sk-" + "x" * 32
            leak = root / "docs" / "leak.md"
            leak.parent.mkdir()
            leak.write_text(secret)
            with patch.object(audit, "ROOT", root):
                result = audit.audit()
            self.assertNotIn(".idea/codexswoop.iml", result["candidates"])
            self.assertEqual(result["findings"], [{"path": "docs/leak.md", "rule": "api-key"}])
            self.assertNotIn(secret, str(result))

    def test_staged_unsupported_extension_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text((audit.ROOT / ".gitignore").read_text())
            path = root / "docs" / "unsupported.bin"
            path.parent.mkdir()
            path.write_bytes(b"unknown staged data")
            subprocess.run(["git", "-C", str(root), "add", "docs/unsupported.bin"], check=True)
            with patch.object(audit, "ROOT", root):
                result = audit.audit(staged=True)
            self.assertEqual(result["findings"], [{"path": "docs/unsupported.bin", "rule": "unexpected-file-extension"}])

    def test_detects_generated_key_without_disclosing_value(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            value = "sk-" + "x" * 32
            (root / "README.md").write_text(value)
            result = self.inspect(root, ["README.md"])
            self.assertEqual(result["findings"], [{"path": "README.md", "rule": "api-key"}])
            self.assertNotIn(value, str(result))

    def test_ignored_runtime_file_is_never_read(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            (root / "README.md").write_text("safe public documentation")
            (root / "auth.json").write_text("sk-" + "x" * 32)
            result = self.inspect(root, ["README.md"])
            self.assertEqual(result["findings"], [])
            self.assertEqual(result["candidates"], ["README.md"])

    def test_symlink_candidate_is_rejected_before_following(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            (root / "private").write_text("sk-" + "x" * 32)
            (root / "README.md").symlink_to(root / "private")
            result = self.inspect(root, ["README.md"])
            self.assertEqual(result["findings"], [{"path": "README.md", "rule": "unexpected-file-type"}])

    def test_force_added_runtime_candidate_is_never_opened(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            with patch.object(Path, "read_bytes", side_effect=AssertionError("must not read credentials")):
                result = self.inspect(root, ["Resources/auth.json"])
            self.assertEqual(result["findings"], [{"path": "Resources/auth.json", "rule": "private-or-runtime-file"}])

    def test_document_identifiers_and_nonfictional_paths_are_flagged(self):
        data = ("Environment " + "12345678-1234-1234-1234-123456789012" + " PID 123456 UID 999").encode()
        self.assertEqual({f["rule"] for f in audit.inspect_data("docs/example.md", data)},
                         {"concrete-document-uuid", "concrete-document-process-id"})
        path = b"/Users/" + b"private-person/example"
        self.assertEqual(audit.inspect_data("Sources/example.swift", path)[0]["rule"], "local-user-path")
        self.assertEqual(audit.inspect_data("Tests/negative.py", b"/Users/" + b"synthetic/example"), [])

    def test_json_credential_is_detected_without_disclosure(self):
        value = b"generated-" + b"x" * 32
        data = b'{"refresh_token": "' + value + b'"}'
        findings = audit.inspect_data("README.md", data)
        self.assertEqual(findings, [{"path": "README.md", "rule": "assigned-credential"}])
        self.assertNotIn(value.decode(), str(findings))

    def test_index_scan_reads_staged_blob_even_after_worktree_is_cleaned(self):
        with tempfile.TemporaryDirectory(prefix="codexswoop-audit-") as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text("\n".join(audit.EXCLUDED) + "\n")
            value = "sk-" + "x" * 32
            (root / "README.md").write_text(value)
            subprocess.run(["git", "-C", str(root), "add", "README.md", ".gitignore"], check=True)
            (root / "README.md").write_text("safe replacement not staged")
            with patch.object(audit, "ROOT", root):
                self.assertEqual(audit.audit()["findings"], [])
                findings = audit.audit(staged=True)["findings"]
            self.assertEqual(findings, [{"path": "README.md", "rule": "api-key"}])
            self.assertNotIn(value, str(findings))


if __name__ == "__main__":
    unittest.main()
