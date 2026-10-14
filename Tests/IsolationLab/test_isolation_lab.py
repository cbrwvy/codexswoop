"""Real temporary-filesystem checks; no child processes, signals, network or authentication."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import stat
import unittest
from unittest import mock
import uuid

SOURCE = Path(__file__).resolve().parents[2] / "scripts" / "isolation-lab.py"
spec = importlib.util.spec_from_file_location("isolation_lab", SOURCE)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class IsolationLabChecks(unittest.TestCase):
    def setUp(self):
        self.root = lab.prepare()
        _, self.metadata = lab.load(self.root)
        self.run_id = self.metadata["run_id"]
        self.addCleanup(self.remove_lab)

    def remove_lab(self):
        if self.root.exists():
            lab.cleanup(self.root, self.run_id)

    def test_profiles_use_distinct_immutable_uuid_paths(self):
        a = lab.layout(self.root, self.metadata, "A")
        b = lab.layout(self.root, self.metadata, "B")
        self.assertEqual(len(set(a + b)), 4)
        for label in ("A", "B"):
            self.assertEqual(str(uuid.UUID(self.metadata["profiles"][label])), self.metadata["profiles"][label])
        before = self.metadata.copy()
        lab.handoff(self.root)
        self.assertEqual(lab.load(self.root)[1], before)

    def test_private_permissions_for_all_created_resources(self):
        for parent, directories, files in os.walk(self.root):
            for name in directories + files:
                path = Path(parent) / name
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700 if path.is_dir() else 0o600)

    def test_environment_contains_both_overrides_without_host_credentials(self):
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "synthetic-" + "blocked-key", "CODEX_HOME": "/synthetic/wrong"}):
            env = lab.environment(self.root, self.metadata, "A")
        self.assertEqual(set(env), {"PATH", "LANG", "CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"})
        self.assertNotEqual(env["CODEX_HOME"], "/synthetic/wrong")
        self.assertNotIn("HOME", env)

    def test_automated_aba_restart_logout_and_errors_are_synthetic(self):
        result = lab.rehearse(self.root)
        self.assertEqual(result["sequence"], ["A", "B", "A"])
        self.assertTrue(result["b_logout_preserves_a"])
        self.assertTrue(result["b_requires_reauth"])
        self.assertTrue(result["b_reauth_preserves_a"])
        self.assertEqual(result["real_isolation"], "unverified")
        self.assertEqual(result["evidence"], "synthetic-only")
        self.assertIn("launch_failure", result)
        self.assertIn("unknown_identity", result)
        self.assertIn("exit_timeout", result)
        for label in ("A", "B"):
            home, electron = lab.layout(self.root, self.metadata, label)
            self.assertEqual(lab.read_json(home / "fixture-history.json"), ["synthetic-" + label])
            self.assertEqual(lab.read_json(electron / "fixture-settings.json"), {"marker": label})
        a, _ = lab.layout(self.root, self.metadata, "A")
        b, _ = lab.layout(self.root, self.metadata, "B")
        self.assertTrue(lab.read_json(a / "fixture-session.json")["valid"])
        self.assertTrue(lab.read_json(b / "fixture-session.json")["valid"])

    def test_b_cannot_reopen_after_mock_logout_but_a_can(self):
        lab.rehearse(self.root)
        desktop = lab.MockDesktop(self.root, self.metadata)
        desktop.launch("B")
        desktop.logout()
        desktop.exit()
        with self.assertRaises(lab.LabError):
            desktop.launch("B")
        desktop.launch("A")
        self.assertEqual(desktop.running, "A")
        desktop.exit()

    def test_mock_cannot_overlap_launches_and_timeout_does_not_exit(self):
        lab.rehearse(self.root)
        desktop = lab.MockDesktop(self.root, self.metadata)
        desktop.launch("A")
        with self.assertRaises(lab.LabError):
            desktop.launch("B")
        with self.assertRaises(lab.LabError):
            desktop.exit(timeout=True)
        self.assertEqual(desktop.running, "A")
        desktop.exit()

    def test_cancel_before_launch_leaves_all_files_identical(self):
        lab.rehearse(self.root)
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        desktop = lab.MockDesktop(self.root, self.metadata)
        desktop.launch("A")
        self.assertEqual(desktop.switch("B", confirmed=False), "cancelled")
        self.assertEqual(desktop.running, "A")
        self.assertFalse(lab.plan(self.root)["authentication_verified"])
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_launch_and_identity_failure_restore_previous_synthetic_account(self):
        lab.rehearse(self.root)
        desktop = lab.MockDesktop(self.root, self.metadata)
        desktop.launch("A")
        for options in ({"fail_launch": True}, {"identity_known": False}):
            with self.assertRaises(lab.LabError):
                desktop.switch("B", confirmed=True, **options)
            self.assertEqual(desktop.running, "A")
            self.assertFalse(desktop.recovery_required)

    def test_failed_rollback_preserves_data_and_exposes_recovery_required(self):
        lab.rehearse(self.root)
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        desktop = lab.MockDesktop(self.root, self.metadata)
        desktop.launch("A")
        with self.assertRaises(lab.LabError):
            desktop.switch("B", confirmed=True, fail_launch=True, rollback_fails=True)
        self.assertTrue(desktop.recovery_required)
        self.assertIsNone(desktop.running)
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_mock_is_denied_for_manual_metadata(self):
        with self.assertRaises(lab.LabError):
            lab.MockDesktop(self.root, dict(self.metadata, mode="manual"))

    def test_rehearsal_cannot_overwrite_completed_fixture(self):
        lab.rehearse(self.root)
        before = (self.root / "rehearsal.json").read_bytes()
        with self.assertRaises(lab.LabError):
            lab.rehearse(self.root)
        self.assertEqual((self.root / "rehearsal.json").read_bytes(), before)

    def test_primary_root_and_unconfirmed_sessions_are_denied(self):
        uid = os.getuid()
        for current, confirmed in ((uid, True), (0, True), (uid + 100, False)):
            with self.assertRaises(lab.LabError):
                lab.validate_test_session(uid, current_uid=current, confirmed=confirmed)
        lab.validate_test_session(uid, current_uid=uid + 100, confirmed=True)
        with self.assertRaises(lab.LabError):
            lab.validate_test_session(0, current_uid=uid + 100)

    def test_actual_primary_uid_blocks_manual_preparation_before_home_access(self):
        lab.handoff(self.root)
        with mock.patch.object(lab, "manual_parent", side_effect=AssertionError("Home must not be accessed")):
            with self.assertRaises(lab.LabError):
                lab.prepare_manual(self.root / "handoff.json", confirmed=True)

    def test_credential_paths_and_ordinary_roots_are_rejected_before_file_reads(self):
        with mock.patch.object(lab, "read_json", side_effect=AssertionError("No data read")):
            for path in ("/synthetic/.codex/auth.json", "/synthetic/codex-home/handoff.json"):
                with self.assertRaises(lab.LabError):
                    lab.prepare_manual(path, confirmed=True)
            with self.assertRaises(lab.LabError):
                lab.load("/synthetic/ordinary-user-directory")

    def test_handoff_contains_only_nonsecret_portable_identifiers(self):
        result = lab.handoff(self.root)
        self.assertEqual(set(result), {"schema", "purpose", "protected_uid", "run_id", "profiles"})
        self.assertEqual(result["purpose"], "manual-preparation-only")
        self.assertEqual(result["protected_uid"], os.getuid())

    def test_fixture_plan_cannot_offer_live_commands_or_claim_real_success(self):
        result = lab.plan(self.root)
        self.assertNotIn("commands_to_review_only", result)
        self.assertEqual(result["activity"], "Unknown")
        self.assertEqual(result["production_switching"], "disabled")
        self.assertFalse(result["authentication_verified"])

    def test_manual_command_rendering_has_paired_paths_and_no_execution(self):
        # Only render a plan against empty owned fixtures; no test user/application is created.
        metadata = dict(self.metadata, mode="manual")
        with mock.patch.object(lab, "load", return_value=(self.root, metadata)):
            result = lab.plan(self.root)
        for label, command in result["commands_to_review_only"].items():
            words = shlex.split(command)
            home, electron = lab.layout(self.root, self.metadata, label)
            self.assertEqual(words[:2], ["/usr/bin/env", "-i"])
            self.assertIn("CODEX_HOME=" + str(home), words)
            self.assertIn("CODEX_ELECTRON_USER_DATA_PATH=" + str(electron), words)
            self.assertIn("--user-data-dir=" + str(electron), words)
        self.assertFalse(result["authentication_verified"])

    def test_failed_atomic_write_preserves_original_and_removes_own_temporary_file(self):
        path = self.root / "handoff.json"
        lab.handoff(self.root)
        before = path.read_bytes()
        with mock.patch.object(lab.os, "replace", side_effect=OSError("synthetic write failure")):
            with self.assertRaises(OSError):
                lab.write_json(path, {"new": "synthetic"})
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse(list(self.root.glob(".lab-write-*")))

    def test_fixture_does_not_accept_manual_observations(self):
        with self.assertRaises(lab.LabError):
            lab.record(self.root, "baseline", "pass")
        self.assertFalse((self.root / "observations.json").exists())

    def test_missing_directory_denies_fallback_and_keeps_other_profile(self):
        home, _ = lab.layout(self.root, self.metadata, "B")
        held = self.root / "held-directory"
        home.rename(held)
        try:
            with self.assertRaises(lab.LabError):
                lab.environment(self.root, self.metadata, "B")
            self.assertTrue(lab.layout(self.root, self.metadata, "A")[0].is_dir())
        finally:
            held.rename(home)

    def test_profile_alias_is_refused_without_touching_target(self):
        a, _ = lab.layout(self.root, self.metadata, "A")
        b, _ = lab.layout(self.root, self.metadata, "B")
        b.rmdir()
        b.symlink_to(a, target_is_directory=True)
        try:
            with self.assertRaises(lab.LabError):
                lab.load(self.root)
            self.assertEqual(list(a.iterdir()), [])
        finally:
            b.unlink()
            b.mkdir(mode=0o700)

    def test_unexpected_auth_file_blocks_all_cleanup_without_reading_it(self):
        unexpected = self.root / "auth.json"
        unexpected.write_text("synthetic-never-open-this", encoding="utf-8")
        try:
            with mock.patch.object(lab, "read_json", wraps=lab.read_json) as reader:
                with self.assertRaises(lab.LabError):
                    lab.cleanup(self.root, self.run_id)
                self.assertNotIn(mock.call(unexpected), reader.call_args_list)
            self.assertTrue((self.root / lab.MARKER).is_file())
            self.assertTrue(unexpected.exists())
        finally:
            unexpected.unlink()

    def test_root_alias_and_traversal_are_refused(self):
        alias = self.root.parent / ("codexswoop-lab-alias-" + str(uuid.uuid4()))
        alias.symlink_to(self.root, target_is_directory=True)
        try:
            with self.assertRaises(lab.LabError):
                lab.load(alias)
            with self.assertRaises(lab.LabError):
                lab.load(str(self.root) + "/../" + self.root.name)
        finally:
            alias.unlink()

    def test_hardlinked_metadata_is_refused(self):
        marker = self.root / lab.MARKER
        twin = self.root.parent / ("codexswoop-lab-hardlink-" + str(uuid.uuid4()))
        os.link(marker, twin)
        try:
            with self.assertRaises(lab.LabError):
                lab.load(self.root)
        finally:
            twin.unlink()

    def test_foreign_owner_and_unsafe_permissions_are_refused(self):
        marker = self.root / lab.MARKER
        marker.chmod(0o644)
        try:
            with self.assertRaises(lab.LabError):
                lab.load(self.root)
        finally:
            marker.chmod(0o600)
        original = marker.read_bytes()
        changed = dict(self.metadata, owner_uid=os.getuid() + 100)
        lab.write_json(marker, changed)
        try:
            with self.assertRaises(lab.LabError):
                lab.load(self.root)
        finally:
            marker.write_bytes(original)

    def test_conflicting_operation_is_rejected_before_writes(self):
        with lab.locked(self.root):
            with self.assertRaises(lab.LabError):
                lab.rehearse(self.root)
        self.assertFalse((self.root / "rehearsal.json").exists())

    def test_cleanup_requires_exact_run_and_preserves_an_unrelated_lab(self):
        other = lab.prepare()
        _, other_m = lab.load(other)
        try:
            marker = (other / lab.MARKER).read_bytes()
            with self.assertRaises(lab.LabError):
                lab.cleanup(self.root, str(uuid.uuid4()))
            lab.cleanup(self.root, self.run_id)
            self.assertFalse(self.root.exists())
            self.assertEqual((other / lab.MARKER).read_bytes(), marker)
        finally:
            lab.cleanup(other, other_m["run_id"])

    def test_partial_creation_rolls_back_only_its_own_empty_resources(self):
        root = self.root.parent / (lab.PREFIX + str(uuid.uuid4()))
        metadata = dict(self.metadata, run_id=root.name[len(lab.PREFIX):])
        with mock.patch.object(lab, "write_json", side_effect=OSError("synthetic-private-error")):
            with self.assertRaises(OSError):
                lab.create(root, metadata)
        self.assertFalse(root.exists())
        self.assertTrue(self.root.exists())

    def test_corrupt_or_unknown_metadata_is_preserved(self):
        path = self.root / lab.MARKER
        before = path.read_bytes()
        try:
            for content in (b"not-json", json.dumps(dict(self.metadata, schema=99)).encode(),
                            json.dumps(dict(self.metadata, schema=True)).encode()):
                path.write_bytes(content)
                with self.assertRaises(lab.LabError):
                    lab.cleanup(self.root, self.run_id)
                self.assertEqual(path.read_bytes(), content)
        finally:
            path.write_bytes(before)

    def test_cli_errors_do_not_echo_arbitrary_input_or_os_error(self):
        canary = "synthetic-private-input-canary"
        for arguments in (["tool", "record", "--root", str(self.root), "--step", "baseline", "--outcome", canary],
                          ["tool", "plan", "--root", "/" + canary]):
            output = io.StringIO()
            with mock.patch.object(lab.sys, "argv", arguments), contextlib.redirect_stderr(output), contextlib.redirect_stdout(output):
                try:
                    code = lab.main()
                except SystemExit as error:
                    code = error.code
            self.assertNotEqual(code, 0)
            self.assertNotIn(canary, output.getvalue())
            self.assertIn("ERROR:", output.getvalue())

    def test_manual_journal_is_ordered_and_only_operator_reported(self):
        # Simulated manual metadata, still writing exclusively inside this test's own fixture root.
        metadata = dict(self.metadata, mode="manual")
        with mock.patch.object(lab, "load", return_value=(self.root, metadata)):
            with self.assertRaises(lab.LabError):
                lab.record(self.root, "a-login", "pass")
            lab.record(self.root, "baseline", "unknown")
            with self.assertRaises(lab.LabError):
                lab.record(self.root, "a-login", "pass")
            lab.record(self.root, "baseline", "pass")
            result = lab.record(self.root, "a-login", "pass")
        self.assertEqual(result["real_isolation"], "unverified")
        entries = lab.read_json(self.root / "observations.json")
        self.assertTrue(all(e["evidence"] == "operator-reported" for e in entries))
        self.assertTrue(all(set(e) == {"step", "outcome", "evidence"} for e in entries))

    def test_optional_unknown_checks_do_not_hide_or_block_other_open_checks(self):
        metadata = dict(self.metadata, mode="manual")
        with mock.patch.object(lab, "load", return_value=(self.root, metadata)):
            for step in lab.STEPS[:9]:
                lab.record(self.root, step, "pass")
            lab.record(self.root, "exit-timeout", "unknown")
            result = lab.record(self.root, "refresh", "unknown")
        self.assertEqual(result["real_isolation"], "unverified")
        latest = {entry["step"]: entry["outcome"] for entry in lab.read_json(self.root / "observations.json")}
        self.assertEqual(latest["exit-timeout"], "unknown")
        self.assertEqual(latest["refresh"], "unknown")


if __name__ == "__main__":
    unittest.main()
