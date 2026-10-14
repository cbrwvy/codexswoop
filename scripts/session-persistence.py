#!/usr/bin/env python3
"""Research-only metadata gates. No launch, quit, auth, cleanup or network actuator."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("desktop_observer", Path(__file__).with_name("desktop-observer.py"))
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)
Refusal = observer.lab.LabError


def descendants(processes, pid):
    owned = {pid}
    while True:
        updated = owned | {p["pid"] for p in processes if p["ppid"] in owned}
        if updated == owned:
            return owned
        owned = updated


def inventory(snapshot, stable):
    if not stable or snapshot.get("descriptor_observation") != "partial-sample":
        raise Refusal("Unavailable or unstable metadata")
    rows = snapshot["processes"]
    by_pid = {p["pid"]: p for p in rows}
    counts = {p["pid"]: p["open_name_counts"] for p in snapshot["descriptors"]}
    if len(by_pid) != len(rows) or set(by_pid) != set(counts):
        raise Refusal("Incomplete metadata attribution")
    if any(c["B_backend"] or c["B_electron"] for c in counts.values()):
        raise Refusal("Unexpected B use")
    return by_pid, counts


def running_gate(snapshot, primary, target, stable):
    by_pid, counts = inventory(snapshot, stable)
    if primary["pid"] == target["pid"] or primary["uid"] != target["uid"]:
        raise Refusal("Unsafe target")
    for expected in (primary, target):
        if expected["role"] != "desktop" or by_pid.get(expected["pid"]) != expected:
            raise Refusal("Desktop identity changed")
    desktops = {p["pid"] for p in by_pid.values() if p["role"] == "desktop"}
    if desktops != {primary["pid"], target["pid"]}:
        raise Refusal("Ambiguous Desktop inventory")
    owned = descendants(snapshot["processes"], target["pid"])
    for pid, c in counts.items():
        if pid in owned:
            if c["default_backend"] or c["default_electron"]:
                raise Refusal("Target uses default roots")
        elif c["A_backend"] or c["A_electron"]:
            raise Refusal("A use outside target lineage")
    main_counts = counts[target["pid"]]
    if not main_counts["A_backend"] or not main_counts["A_electron"]:
        raise Refusal("Missing positive A root evidence")
    backends = [p for p in by_pid.values() if p["role"] == "backend"
                and p["ppid"] == target["pid"] and p["uid"] == target["uid"]
                and counts[p["pid"]]["A_backend"] > 0]
    if len(backends) != 1:
        raise Refusal("Ambiguous A backend")
    return {"primary": primary, "target": target, "backend": backends[0],
            "observed_lineage": [by_pid[pid] for pid in sorted(owned)],
            "activity": "Unknown", "authentication": "operator-reported only",
            "coverage": "partial in-bundle metadata; external/reparented work unverified"}


def exited_gate(snapshot, primary, observed_lineage, stable, native_exit_confirmed):
    by_pid, counts = inventory(snapshot, stable)
    if not native_exit_confirmed or by_pid.get(primary["pid"]) != primary:
        raise Refusal("Exit or primary continuity unconfirmed")
    if any(p["pid"] in by_pid for p in observed_lineage):
        raise Refusal("Target or observed helper remains; no overlapping restart")
    if any(c["A_backend"] or c["A_electron"] for c in counts.values()):
        raise Refusal("Candidate resources remain in use")
    if any(p["role"] == "desktop" and p["pid"] != primary["pid"] for p in by_pid.values()):
        raise Refusal("Another Desktop appeared")
    return {"observed_target_lineage_absent": True, "primary_identity_retained": True,
            "unobserved_background_work": "Unknown"}


def directory_identity(root, metadata):
    paths = [root, root / "Profiles"]
    for label in ("A", "B"):
        home, electron = observer.lab.layout(root, metadata, label)
        paths.extend((home.parent, home, electron))
    result = {}
    for path in paths:
        observer.lab.owned(path, directory=True)
        value = path.lstat()
        result[str(path)] = [value.st_dev, value.st_ino, value.st_uid, value.st_mode & 0o777]
    return result


def restart_argv(root, metadata, expected_directories):
    # No repair, creation, tree walk or credential read. Identity is directory metadata only.
    checked, current = observer.observation_root(root, True)
    if current != metadata or directory_identity(checked, current) != expected_directories:
        raise Refusal("Directory identity changed; preserve resources")
    home, electron = observer.lab.layout(checked, current, "A")
    return ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "LANG=en_US.UTF-8",
            "/usr/bin/open", "-n", "-g", "--env", "CODEX_HOME=" + str(home),
            "--env", "CODEX_ELECTRON_USER_DATA_PATH=" + str(electron),
            "--env", "PATH=/usr/bin:/bin", "--env", "LANG=en_US.UTF-8",
            str(observer.APP), "--args", "--user-data-dir=" + str(electron)]
