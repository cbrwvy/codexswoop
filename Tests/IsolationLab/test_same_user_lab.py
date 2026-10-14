"""Guarded resources and our own bounded child processes; never launch Codex."""
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock
import uuid

from test_isolation_lab import lab, SOURCE


class SameUserChecks(unittest.TestCase):
    def setUp(self):
        self.permission = lab.same_user_permission(True)
        self.permission.__enter__()
        self.root = lab.prepare_guarded()
        self.metadata = lab.load(self.root)[1]
        self.run_id = self.metadata["run_id"]

    def tearDown(self):
        try:
            if self.root.exists():
                lab.cleanup(self.root, self.run_id)
        finally:
            self.permission.__exit__(None, None, None)

    def cli(self, verb, *extra):
        return subprocess.run([sys.executable, "-I", "-B", str(SOURCE), verb,
                               "--root", str(self.root), *extra],
                              env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"},
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)

    def test_mode_is_off_by_default_for_creation_and_every_operation(self):
        with lab.same_user_permission(False):
            for operation in (lab.prepare_guarded, lambda: lab.load(self.root),
                              lambda: lab.environment(self.root, self.metadata, "A"),
                              lambda: lab.cleanup(self.root, self.run_id),
                              lambda: lab.probe(self.root)):
                with self.assertRaises(lab.LabError):
                    operation()
        self.assertTrue(self.root.exists())

    def test_cli_permission_is_not_persisted_by_a_previous_invocation(self):
        self.assertEqual(self.cli("plan", "--guarded-same-user").returncode, 0)
        self.assertNotEqual(self.cli("plan").returncode, 0)

    def test_strict_mode_still_refuses_protected_uid_even_with_guard(self):
        with self.assertRaises(lab.LabError):
            lab.validate_test_session(os.getuid())
        fixture = lab.prepare()
        try:
            self.assertEqual(lab.load(fixture)[1]["mode"], "fixture")
        finally:
            lab.cleanup(fixture, fixture.name[len(lab.PREFIX):])

    def test_all_paths_are_disjoint_uuid_owned_and_private(self):
        paths = [p for label in ("A", "B") for p in lab.layout(self.root, self.metadata, label)]
        self.assertEqual(len(set(paths)), 4)
        self.assertEqual(self.root.parent, Path("/private/tmp"))
        for path in paths:
            self.assertTrue(path.is_relative_to(self.root))
            lab.owned(path, directory=True)
        self.assertEqual(self.metadata["owner_uid"], os.getuid())
        self.assertEqual(self.metadata["protected_uid"], os.getuid())

    def test_aba_and_reload_restore_both_synthetic_profiles(self):
        self.assertEqual(lab.rehearse(self.root)["sequence"], ["A", "B", "A"])
        self.assertEqual(self.cli("plan", "--guarded-same-user").returncode, 0)
        root, metadata = lab.load(self.root)
        desktop = lab.MockDesktop(root, metadata)
        for label in ("A", "B", "A"):
            desktop.launch(label)
            self.assertEqual(desktop.running, label)
            desktop.exit()
        self.assertFalse(lab.plan(root)["authentication_verified"])

    def test_own_children_receive_paired_environment_and_exclude_host_values(self):
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "synthetic-" + "blocked-key",
                                          "HOME": "/synthetic-host", "CODEX_HOME": "/synthetic-wrong"}):
            result = lab.probe(self.root)
        self.assertTrue(result["environment_verified"])
        self.assertEqual(result["real_isolation"], "unverified")
        for label in ("A", "B"):
            data = lab.read_json(self.root / ("probe-" + label + ".json"))
            self.assertEqual(data["environment"], lab.environment(self.root, self.metadata, label))
            self.assertNotIn("synthetic-canary", str(data))
            self.assertEqual(data["evidence"], "own-process-only")
        self.assertFalse((self.root / "probe-pending.json").exists())

    def test_probe_restarts_in_a_fresh_cli_process(self):
        for _ in range(2):
            self.assertEqual(self.cli("probe", "--guarded-same-user").returncode, 0)

    def test_probe_refuses_fixture_instead_of_relaxing_its_mode(self):
        root = lab.prepare()
        try:
            with self.assertRaises(lab.LabError):
                lab.probe(root)
        finally:
            lab.cleanup(root, root.name[len(lab.PREFIX):])

    def test_child_missing_environment_refuses_before_report_write(self):
        result = self.cli("internal-probe", "--label", "A", "--guarded-same-user")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "probe-A.json").exists())

    def test_launch_failure_preserves_lease_and_blocks_cleanup_or_retry(self):
        with mock.patch.object(lab.subprocess, "Popen", side_effect=OSError("synthetic-private-error")):
            with self.assertRaises(OSError):
                lab.probe(self.root)
        try:
            with self.assertRaises(lab.LabError):
                lab.cleanup(self.root, self.run_id)
            with self.assertRaises(lab.LabError):
                lab.probe(self.root)
        finally:
            # This failure never created a child; remove only our test's known lease.
            (self.root / "probe-pending.json").unlink()

    def test_timeout_never_signals_child_and_blocks_cleanup(self):
        child = mock.Mock()
        child.wait.side_effect = subprocess.TimeoutExpired("own-probe", 10)
        with mock.patch.object(lab.subprocess, "Popen", return_value=child):
            with self.assertRaises(lab.LabError):
                lab.probe(self.root)
        try:
            child.kill.assert_not_called()
            child.terminate.assert_not_called()
            with self.assertRaises(lab.LabError):
                lab.cleanup(self.root, self.run_id)
        finally:
            (self.root / "probe-pending.json").unlink()

    def test_real_interprocess_lock_rejects_switch_and_cleanup_without_writes(self):
        code = """import fcntl, os, select, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOFOLLOW)
fcntl.flock(fd, fcntl.LOCK_EX)
print('ready', flush=True)
select.select([sys.stdin], [], [], 5)
os.close(fd)
"""
        child = subprocess.Popen([sys.executable, "-I", "-B", "-c", code, str(self.root / "lab.lock")],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 env={"PATH": "/usr/bin:/bin"})
        try:
            self.assertEqual(child.stdout.readline(), b"ready\n")
            for verb, args in (("rehearse", []), ("probe", []), ("cleanup", ["--confirm-id", self.run_id])):
                self.assertNotEqual(self.cli(verb, "--guarded-same-user", *args).returncode, 0)
            self.assertFalse((self.root / "rehearsal.json").exists())
            self.assertFalse((self.root / "probe-A.json").exists())
        finally:
            child.communicate(input=b"release", timeout=7)
        self.assertEqual(child.returncode, 0)
        self.assertEqual(lab.rehearse(self.root)["sequence"], ["A", "B", "A"])

    def test_two_simultaneous_cli_requests_commit_only_one_rehearsal(self):
        args = [sys.executable, "-I", "-B", str(SOURCE), "rehearse", "--root", str(self.root), "--guarded-same-user"]
        children = [subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, env={"PATH": "/usr/bin:/bin"}) for _ in range(2)]
        self.assertEqual(sorted(child.wait(timeout=10) for child in children), [0, 1])
        self.assertEqual(lab.read_json(self.root / "rehearsal.json")["sequence"], ["A", "B", "A"])

    def test_dry_run_has_no_resolved_official_executable_or_actuator(self):
        with mock.patch.object(lab.subprocess, "Popen", side_effect=AssertionError("must not launch")):
            result = lab.plan(self.root)
        self.assertEqual(result["production_switching"], "disabled")
        self.assertEqual(result["activity"], "Unknown")
        self.assertIn("unverified", result["single_instance_routing"])
        self.assertTrue(all(spec["executable"].startswith("UNRESOLVED")
                            for spec in result["launch_spec_to_review_only"].values()))

    def test_guard_does_not_allow_arbitrary_or_traversing_roots(self):
        for root in (Path("/private/tmp"), self.root / "..", Path("/Users/fixture/.codex"),
                     self.root / "Profiles", Path("/tmp") / self.root.name):
            with self.assertRaises(lab.LabError):
                lab.load(root)

    def test_symlinks_inside_and_outside_are_rejected(self):
        home, _ = lab.layout(self.root, self.metadata, "A")
        for target in (self.root, Path("/private/tmp")):
            link = home / "escape"
            link.symlink_to(target, target_is_directory=True)
            try:
                with self.assertRaises(lab.LabError):
                    lab.cleanup(self.root, self.run_id)
                with self.assertRaises(lab.LabError):
                    lab.probe(self.root)
            finally:
                link.unlink()

    def test_unknown_file_is_not_read_or_deleted(self):
        path = lab.layout(self.root, self.metadata, "B")[0] / "unexpected.dat"
        path.write_bytes(b"synthetic-do-not-read")
        path.chmod(0o600)
        try:
            with mock.patch.object(lab, "read_json", side_effect=AssertionError("unexpected read")):
                with self.assertRaises(lab.LabError):
                    lab.verify_tree(self.root, self.metadata)
            with self.assertRaises(lab.LabError):
                lab.cleanup(self.root, self.run_id)
            self.assertTrue(path.exists())
        finally:
            path.unlink()

    def test_invalid_duplicate_or_unicode_uuid_metadata_is_preserved(self):
        marker = self.root / lab.MARKER
        original = marker.read_bytes()
        try:
            for profiles in ({"A": "../escape", "B": self.metadata["profiles"]["B"]},
                             {"A": "Рабочий", "B": str(uuid.uuid4())},
                             {"A": self.metadata["profiles"]["A"], "B": self.metadata["profiles"]["A"]}):
                lab.write_json(marker, dict(self.metadata, profiles=profiles))
                before = marker.read_bytes()
                with self.assertRaises(lab.LabError):
                    lab.cleanup(self.root, self.run_id)
                self.assertEqual(marker.read_bytes(), before)
        finally:
            marker.write_bytes(original)

    def test_unicode_fixture_data_never_changes_paths(self):
        lab.rehearse(self.root)
        home, _ = lab.layout(self.root, self.metadata, "A")
        path = home / "fixture-history.json"
        lab.write_json(path, ["Основной", "Рабочий", "O‘zbekcha", "🦉"])
        self.assertEqual(lab.read_json(path), ["Основной", "Рабочий", "O‘zbekcha", "🦉"])
        self.assertEqual(lab.load(self.root)[1], self.metadata)

    def test_atomic_write_error_preserves_prior_metadata(self):
        marker = self.root / lab.MARKER
        before = marker.read_bytes()
        with mock.patch.object(lab.os, "replace", side_effect=OSError("synthetic-private-error")):
            with self.assertRaises(OSError):
                lab.write_json(marker, self.metadata)
        self.assertEqual(marker.read_bytes(), before)
        lab.load(self.root)

    def test_corrupt_metadata_stops_all_operations_without_repair(self):
        marker = self.root / lab.MARKER
        original = marker.read_bytes()
        marker.write_bytes(b"broken-json")
        try:
            for operation in (lab.probe, lab.rehearse, lab.plan):
                with self.assertRaises(lab.LabError):
                    operation(self.root)
            self.assertEqual(marker.read_bytes(), b"broken-json")
        finally:
            marker.write_bytes(original)

    def test_foreign_lab_and_wrong_confirmation_are_preserved(self):
        other = lab.prepare_guarded()
        try:
            before = (other / lab.MARKER).read_bytes()
            with self.assertRaises(lab.LabError):
                lab.cleanup(other, self.run_id)
            self.assertEqual((other / lab.MARKER).read_bytes(), before)
        finally:
            lab.cleanup(other, other.name[len(lab.PREFIX):])

    def test_supplied_metadata_cannot_redirect_environment(self):
        changed = dict(self.metadata, profiles={"A": str(uuid.uuid4()), "B": str(uuid.uuid4())})
        with self.assertRaises(lab.LabError):
            lab.environment(self.root, changed, "A")

    def test_repeated_creation_never_reuses_existing_root(self):
        before = (self.root / lab.MARKER).read_bytes()
        with self.assertRaises(FileExistsError):
            lab.create(self.root, self.metadata)
        self.assertEqual((self.root / lab.MARKER).read_bytes(), before)

    def test_error_logs_do_not_echo_inputs(self):
        result = self.cli("plan", "--synthetic-private-canary")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"synthetic-private-canary", result.stderr + result.stdout)

    def test_hardlink_or_unsafe_permissions_refuse_before_cleanup(self):
        marker = self.root / lab.MARKER
        twin = self.root / "linked-marker"
        os.link(marker, twin)
        try:
            with self.assertRaises(lab.LabError):
                lab.cleanup(self.root, self.run_id)
        finally:
            twin.unlink()
        marker.chmod(0o644)
        try:
            with self.assertRaises(lab.LabError):
                lab.probe(self.root)
        finally:
            marker.chmod(0o600)

    def test_guarded_creation_refuses_foreign_owner_or_unmanaged_name(self):
        for root, metadata in ((Path("/private/tmp/unmanaged-lab"), self.metadata),
                               (self.root, dict(self.metadata, owner_uid=os.getuid() + 1,
                                                protected_uid=os.getuid() + 1))):
            with self.assertRaises(lab.LabError):
                lab.create(root, metadata)

    def test_mock_object_cannot_retain_permission_after_invocation(self):
        lab.rehearse(self.root)
        desktop = lab.MockDesktop(self.root, self.metadata)
        desktop.launch("A")
        with lab.same_user_permission(False):
            for operation in (desktop.exit, desktop.logout, lambda: desktop.reauthenticate("B")):
                with self.assertRaises(lab.LabError):
                    operation()
        self.assertEqual(desktop.running, "A")

    def test_pending_probe_blocks_rehearsal(self):
        pending = self.root / "probe-pending.json"
        lab.write_json(pending, {"run_id": self.run_id, "state": "own-probe-pending"})
        try:
            with self.assertRaises(lab.LabError):
                lab.rehearse(self.root)
        finally:
            pending.unlink()

    def test_external_root_refuses_before_any_metadata_read(self):
        path = Path("/Users/synthetic") / self.root.name
        with mock.patch.object(lab, "read_json", side_effect=AssertionError("must not read")):
            with self.assertRaises(lab.LabError):
                lab.load(path)

    def test_nonzero_probe_exit_never_reports_success(self):
        child = mock.Mock()
        child.wait.return_value = 1
        with mock.patch.object(lab.subprocess, "Popen", return_value=child):
            with self.assertRaises(lab.LabError):
                lab.probe(self.root)
        try:
            self.assertFalse((self.root / "probe-A.json").exists())
            child.kill.assert_not_called()
        finally:
            (self.root / "probe-pending.json").unlink()

    def test_no_process_signal_shell_network_or_keychain_actuator(self):
        import ast
        tree = ast.parse(SOURCE.read_text())
        forbidden = {"kill", "killpg", "terminate", "system", "execv", "execve", "fork", "socket", "urlopen"}
        self.assertFalse(any(isinstance(node, ast.Attribute) and node.attr in forbidden for node in ast.walk(tree)))
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Attribute) and node.func.attr == "Popen"]
        self.assertEqual(len(calls), 1)
        self.assertNotIn("shell", {keyword.arg for keyword in calls[0].keywords})


if __name__ == "__main__":
    unittest.main()
