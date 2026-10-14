"""Privacy and scope checks for the read-only observer, without live Desktop calls."""
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "scripts/desktop-observer.py"
spec = importlib.util.spec_from_file_location("desktop_observer", SOURCE)
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)
lab = observer.lab


class ObserverChecks(unittest.TestCase):
    def setUp(self):
        self.permission = lab.same_user_permission(True)
        self.permission.__enter__()
        self.root = lab.prepare_guarded()
        self.metadata = lab.load(self.root)[1]

    def tearDown(self):
        try:
            lab.cleanup(self.root, self.metadata["run_id"])
        finally:
            self.permission.__exit__(None, None, None)

    def test_scope_and_consent_are_required_before_metadata_read(self):
        for path, enabled in ((self.root, False), (Path("/private/tmp"), True),
                              (Path("/Users/synthetic") / self.root.name, True)):
            with mock.patch.object(lab, "read_json", side_effect=AssertionError("must not read")):
                with self.assertRaises(lab.LabError):
                    observer.observation_root(path, enabled)

    def test_unknown_desktop_file_is_not_opened_and_does_not_grant_cleanup(self):
        path = lab.layout(self.root, self.metadata, "A")[0] / "unexpected.dat"
        path.write_bytes(b"synthetic-private-canary")
        path.chmod(0o600)
        try:
            self.assertEqual(observer.observation_root(self.root, True)[1], self.metadata)
            with self.assertRaises(lab.LabError):
                lab.cleanup(self.root, self.metadata["run_id"])
        finally:
            path.unlink()

    def test_process_parser_keeps_metadata_only_for_this_users_exact_bundle(self):
        uid = os.getuid()
        text = (f"10 1 {uid} Sun Oct 11 10:00:00 2026 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n"
                f"11 10 {uid} Sun Oct 11 10:00:00 2026 /Applications/ChatGPT.app.fake/private-canary\n"
                f"12 1 {uid+1} Sun Oct 11 10:00:00 2026 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n")
        rows = observer.process_rows(text, uid)
        self.assertEqual([r["pid"] for r in rows], [10])
        self.assertEqual(set(rows[0]), {"pid", "ppid", "uid", "started", "role"})
        self.assertNotIn("private-canary", json.dumps(rows))

    def test_descriptor_names_are_reduced_to_counts_and_foreign_pids_discarded(self):
        roots = {"A_backend": self.root / "Profiles/A/codex-home"}
        text = f"p10\nn{roots['A_backend']}/auth.json\nn/Users/synthetic/private-canary\np999\nn/secret\n"
        result = observer.descriptor_summary(text, [{"pid": 10}], roots)
        self.assertEqual(result, [{"pid": 10, "open_name_counts": {"A_backend": 1, "other": 1}}])
        self.assertNotIn("auth.json", json.dumps(result))
        self.assertNotIn("private-canary", json.dumps(result))

    def test_similarly_prefixed_paths_do_not_count_as_owned(self):
        roots = {"owned": Path("/private/tmp/owned")}
        self.assertEqual(observer.path_category("/private/tmp/owned-copy/file", roots), "other")
        self.assertEqual(observer.path_category("/private/tmp/owned/file", roots), "owned")

    def test_process_failure_is_not_reported_as_empty_or_idle(self):
        with mock.patch.object(observer, "fixed_read_command", return_value=(1, "")):
            with self.assertRaises(lab.LabError):
                observer.observe(self.root, self.metadata)

    def test_descriptor_failure_remains_unavailable_and_activity_unknown(self):
        text = f"10 1 {os.getuid()} Sun Oct 11 10:00:00 2026 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n"
        with mock.patch.object(observer, "fixed_read_command", side_effect=[(0, text), (1, "")]):
            result = observer.observe(self.root, self.metadata, files=True)
        self.assertEqual(result["descriptor_observation"], "unavailable")
        self.assertEqual(result["activity"], "Unknown")
        self.assertEqual(result["exclusive_isolation"], "unverified")

    def test_no_signal_auth_network_or_application_launch_methods(self):
        import ast
        tree = ast.parse(SOURCE.read_text())
        forbidden = {"kill", "killpg", "terminate", "system", "fork", "socket", "urlopen", "Popen"}
        self.assertFalse(any(isinstance(node, ast.Attribute) and node.attr in forbidden for node in ast.walk(tree)))
        strings = {node.value for node in ast.walk(tree) if isinstance(node, ast.Constant) and isinstance(node.value, str)}
        self.assertNotIn("/usr/bin/open", strings)
        self.assertNotIn("account/read", strings)


if __name__ == "__main__":
    unittest.main()
