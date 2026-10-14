"""Metadata and owned-directory gates only; no real Desktop lifecycle actions."""
import ast
import copy
import importlib.util
import os
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "scripts/session-persistence.py"
spec = importlib.util.spec_from_file_location("persistence", SOURCE)
persistence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(persistence)
lab = persistence.observer.lab


def process(pid, parent, role="desktop"):
    return {"pid": pid, "ppid": parent, "uid": os.getuid(), "role": role, "started": "synthetic-generation-1"}


def sample(rows):
    names = ("A_backend", "A_electron", "B_backend", "B_electron", "default_backend", "default_electron", "other")
    return {"processes": rows, "descriptor_observation": "partial-sample",
            "descriptors": [{"pid": p["pid"], "open_name_counts": dict.fromkeys(names, 0)} for p in rows]}


class PersistenceGates(unittest.TestCase):
    def setUp(self):
        self.primary = process(10, 1)
        self.target = process(20, 1)
        self.backend = process(21, 20, "backend")
        self.snapshot = sample([self.primary, self.target, self.backend])
        self.counts = {r["pid"]: r["open_name_counts"] for r in self.snapshot["descriptors"]}
        self.counts[20].update(A_backend=1, A_electron=1)
        self.counts[21]["A_backend"] = 1

    def gate(self, stable=True):
        return persistence.running_gate(self.snapshot, self.primary, self.target, stable)

    def test_positive_roots_and_parentage_bind_target_without_claiming_idle_or_auth(self):
        result = self.gate()
        self.assertEqual(result["backend"], self.backend)
        self.assertEqual(result["activity"], "Unknown")
        self.assertEqual(result["authentication"], "operator-reported only")

    def test_reused_target_pid_is_rejected(self):
        self.snapshot["processes"][1] = dict(self.target, started="generation-2")
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_changed_primary_is_rejected(self):
        self.snapshot["processes"][0] = dict(self.primary, started="generation-2")
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_wrong_parentage_is_rejected(self):
        self.snapshot["processes"][2] = dict(self.backend, ppid=1)
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_window_or_pid_without_both_root_evidence_is_insufficient(self):
        self.counts[20]["A_electron"] = 0
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_target_default_root_use_is_rejected(self):
        self.counts[21]["default_backend"] = 1
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_primary_or_unrelated_process_using_A_is_rejected(self):
        self.counts[10]["A_backend"] = 1
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_B_use_is_rejected(self):
        self.counts[21]["B_backend"] = 1
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_unavailable_unstable_or_incomplete_metadata_is_rejected(self):
        with self.assertRaises(lab.LabError):
            self.gate(stable=False)
        self.snapshot["descriptor_observation"] = "unavailable"
        with self.assertRaises(lab.LabError):
            self.gate()
        self.snapshot["descriptor_observation"] = "partial-sample"
        self.snapshot["descriptors"].pop()
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_extra_desktop_or_duplicate_inventory_is_rejected(self):
        self.snapshot["processes"].append(process(30, 1))
        self.snapshot["descriptors"].append(sample([process(30, 1)])["descriptors"][0])
        with self.assertRaises(lab.LabError):
            self.gate()
        self.snapshot["processes"][-1] = copy.deepcopy(self.target)
        with self.assertRaises(lab.LabError):
            self.gate()

    def test_exit_requires_native_confirmation_and_no_observed_helpers(self):
        lineage = self.gate()["observed_lineage"]
        remaining = sample([self.primary, self.backend])
        with self.assertRaises(lab.LabError):
            persistence.exited_gate(remaining, self.primary, lineage, True, True)
        clean = sample([self.primary])
        with self.assertRaises(lab.LabError):
            persistence.exited_gate(clean, self.primary, lineage, True, False)
        self.assertTrue(persistence.exited_gate(clean, self.primary, lineage, True, True)["observed_target_lineage_absent"])

    def test_exit_blocks_primary_loss_resource_use_or_another_desktop(self):
        lineage = self.gate()["observed_lineage"]
        for rows in ([], [dict(self.primary, started="changed")], [self.primary, process(30, 1)]):
            with self.assertRaises(lab.LabError):
                persistence.exited_gate(sample(rows), self.primary, lineage, True, True)
        clean = sample([self.primary])
        clean["descriptors"][0]["open_name_counts"]["A_backend"] = 1
        with self.assertRaises(lab.LabError):
            persistence.exited_gate(clean, self.primary, lineage, True, True)

    def test_policy_has_no_execution_auth_or_cleanup_actuators(self):
        tree = ast.parse(SOURCE.read_text())
        forbidden = {"run", "Popen", "kill", "killpg", "terminate", "system", "socket", "urlopen", "unlink", "rmdir"}
        self.assertFalse(any(isinstance(n, ast.Attribute) and n.attr in forbidden for n in ast.walk(tree)))


class PersistenceDirectories(unittest.TestCase):
    def setUp(self):
        self.permission = lab.same_user_permission(True)
        self.permission.__enter__()
        self.root = lab.prepare_guarded()
        self.metadata = lab.load(self.root)[1]
        self.identity = persistence.directory_identity(self.root, self.metadata)

    def tearDown(self):
        try:
            lab.cleanup(self.root, self.metadata["run_id"])
        finally:
            self.permission.__exit__(None, None, None)

    def test_restart_spec_preserves_exact_A_uuid_and_both_paths(self):
        argv = persistence.restart_argv(self.root, self.metadata, self.identity)
        home, electron = lab.layout(self.root, self.metadata, "A")
        self.assertIn("CODEX_HOME=" + str(home), argv)
        self.assertIn("CODEX_ELECTRON_USER_DATA_PATH=" + str(electron), argv)
        self.assertEqual(argv[-1], "--user-data-dir=" + str(electron))
        self.assertNotIn(self.metadata["profiles"]["B"], " ".join(argv))

    def test_missing_path_refuses_without_recreating(self):
        home = lab.layout(self.root, self.metadata, "A")[0]
        home.rmdir()
        try:
            with self.assertRaises((lab.LabError, OSError)):
                persistence.restart_argv(self.root, self.metadata, self.identity)
            self.assertFalse(home.exists())
        finally:
            home.mkdir(mode=0o700)

    def test_replaced_directory_or_symlink_refuses(self):
        home = lab.layout(self.root, self.metadata, "A")[0]
        retained = home.with_name("fixture-retained")
        home.rename(retained)
        try:
            home.mkdir(mode=0o700)
            with self.assertRaises(lab.LabError):
                persistence.restart_argv(self.root, self.metadata, self.identity)
            home.rmdir()
            home.symlink_to(retained, target_is_directory=True)
            with self.assertRaises(lab.LabError):
                persistence.restart_argv(self.root, self.metadata, self.identity)
            home.unlink()
        finally:
            retained.rename(home)


if __name__ == "__main__":
    unittest.main()
