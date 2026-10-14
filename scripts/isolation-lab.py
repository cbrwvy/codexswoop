#!/usr/bin/env python3
"""Isolation preparation: files, synthetic rehearsal and an explicit same-user probe.

Only the guarded probe executes this script itself; no official apps or signals.
No function in this module verifies real Codex authentication or activity.
"""
import argparse
from contextlib import contextmanager
from contextvars import ContextVar
import fcntl
import json
import os
from pathlib import Path
import pwd
import shlex
import stat
import subprocess
import sys
import uuid

PREFIX = "codexswoop-lab-"
MARKER = "lab.json"
STEPS = ("baseline", "a-login", "a-restart", "b-login", "b-restart", "a-return",
         "b-logout", "a-after-b-logout", "b-reauth", "cancel", "launch-failure",
         "exit-timeout", "missing-path", "callback-cancel", "refresh")
OUTCOMES = ("pass", "fail", "unknown")
ROOT_FILES = {MARKER, "lab.lock", "handoff.json", "rehearsal.json", "observations.json"}
PROFILE_FILES = {"codex-home/fixture-session.json", "codex-home/fixture-history.json",
                 "electron-user-data/fixture-settings.json"}
SAME_USER = ContextVar("same_user_permission", default=False)
PROBE_FILES = {"probe-A.json", "probe-B.json", "probe-pending.json"}


@contextmanager
def same_user_permission(enabled):
    """One invocation only; metadata never grants consent for a later operation."""
    token = SAME_USER.set(enabled is True)
    try:
        yield
    finally:
        SAME_USER.reset(token)


def require_guard(m):
    if m["mode"] == "guarded" and not SAME_USER.get():
        raise LabError("Explicit same-user permission required for this invocation")


class LabError(Exception):
    """Controlled messages only: never forward raw OS errors or file contents."""


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "ERROR: invalid lab arguments; use --help.\n")


def identifier(value):
    try:
        result = str(uuid.UUID(value))
        if result != value:
            raise ValueError()
        return result
    except (ValueError, TypeError, AttributeError):
        raise LabError("Invalid UUID") from None


def exact_keys(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise LabError("Invalid metadata schema")


def metadata_check(m):
    exact_keys(m, {"schema", "mode", "run_id", "owner_uid", "protected_uid", "profiles"})
    if type(m["schema"]) is not int or m["schema"] != 1 or m["mode"] not in ("fixture", "manual", "guarded"):
        raise LabError("Unsupported lab mode or version")
    identifier(m["run_id"])
    if any(type(m[k]) is not int or m[k] <= 0 for k in ("owner_uid", "protected_uid")):
        raise LabError("Root or invalid user is forbidden")
    exact_keys(m["profiles"], {"A", "B"})
    for value in m["profiles"].values():
        identifier(value)
    if m["profiles"]["A"] == m["profiles"]["B"]:
        raise LabError("Profile collision")
    if m["mode"] == "manual" and m["owner_uid"] == m["protected_uid"]:
        raise LabError("Manual preparation is forbidden for the protected user")
    if m["mode"] in ("fixture", "guarded") and m["owner_uid"] != m["protected_uid"]:
        raise LabError("Fixture protection must match its owner")


def owned(path, directory=False, private=True):
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid != os.getuid():
        raise LabError("Foreign, linked or special resource")
    if not directory and info.st_nlink != 1:
        raise LabError("Hard-linked files are forbidden")
    if private and stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        raise LabError("Unsafe resource permissions")
    if path.resolve() != path:
        raise LabError("Aliased resource path")


def read_json(path):
    owned(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        data = stream.read(131073)
    if len(data) > 131072:
        raise LabError("Oversized lab metadata")
    try:
        return json.loads(data)
    except (ValueError, UnicodeError):
        raise LabError("Invalid lab JSON") from None


def write_json(path, data):
    owned(path.parent, directory=True)
    if path.exists() or path.is_symlink():
        owned(path)
    temporary = path.parent / (".lab-write-" + str(uuid.uuid4()))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def layout(root, m, label):
    if label not in ("A", "B"):
        raise LabError("Unknown profile label")
    base = root / "Profiles" / m["profiles"][label]
    return base / "codex-home", base / "electron-user-data"


def allowed_tree(m):
    directories = {"Profiles"}
    files = set(ROOT_FILES)
    if m["mode"] == "guarded":
        files.update(PROBE_FILES)
    for profile in m["profiles"].values():
        prefix = "Profiles/" + profile
        directories.update({prefix, prefix + "/codex-home", prefix + "/electron-user-data"})
        if m["mode"] in ("fixture", "guarded"):
            files.update(prefix + "/" + name for name in PROFILE_FILES)
    return directories, files


def walk_error(error):
    raise LabError("Cannot inspect the whole lab; preserve all resources")


def verify_tree(root, m):
    directories, files = allowed_tree(m)
    present = set()
    for parent, names, entries in os.walk(root, followlinks=False, onerror=walk_error):
        for name in names + entries:
            path = Path(parent) / name
            relative = path.relative_to(root).as_posix()
            if relative in directories:
                owned(path, directory=True)
            elif relative in files:
                owned(path)
            else:
                # Never open unexpected files, including any real credentials/cookies/history.
                raise LabError("Unexpected resource; preserve the lab for manual review")
            present.add(relative)
    if not directories.issubset(present) or not {MARKER, "lab.lock"}.issubset(present):
        raise LabError("Incomplete lab environment; no fallback is allowed")


def load(root):
    root = Path(root)
    if not root.is_absolute() or ".." in root.parts or root.resolve() != root:
        raise LabError("Use a canonical absolute lab path")
    if not root.name.startswith(PREFIX):
        raise LabError("Only generated lab roots are accepted")
    identifier(root.name[len(PREFIX):])
    if SAME_USER.get() and root.parent != Path("/private/tmp"):
        raise LabError("Same-user paths must be below /private/tmp")
    owned(root, directory=True)
    m = read_json(root / MARKER)
    metadata_check(m)
    require_guard(m)
    if root.name != PREFIX + m["run_id"] or m["owner_uid"] != os.getuid():
        raise LabError("Lab ownership mismatch")
    if m["mode"] in ("fixture", "guarded"):
        if root.parent != Path("/private/tmp"):
            raise LabError("Fixture root must be below /private/tmp")
    else:
        validate_test_session(m["protected_uid"])
        if root.parent != manual_parent():
            raise LabError("Manual root must belong to the separate test user")
    verify_tree(root, m)
    return root, m


@contextmanager
def locked(root):
    owned(root / "lab.lock")
    fd = os.open(root / "lab.lock", os.O_RDWR | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise LabError("Lab is busy") from None
        yield
    finally:
        os.close(fd)


def create(root, m):
    metadata_check(m)
    require_guard(m)
    if m["owner_uid"] != os.getuid():
        raise LabError("Environment owner mismatch")
    if m["mode"] in ("fixture", "guarded") and root != Path("/private/tmp") / (PREFIX + m["run_id"]):
        raise LabError("Synthetic labs must stay below /private/tmp")
    root.mkdir(mode=0o700)  # Exclusive; never reuse or repair an existing environment.
    created = [root]
    try:
        directories, _ = allowed_tree(m)
        for relative in sorted(directories, key=lambda p: (p.count("/"), p)):
            path = root / relative
            path.mkdir(mode=0o700)
            created.append(path)
        write_json(root / MARKER, m)
        created.append(root / MARKER)
        fd = os.open(root / "lab.lock", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        created.append(root / "lab.lock")
        verify_tree(root, m)
    except (LabError, OSError):
        # Reverse only resources created by this call; preserve anything unexpected.
        for path in reversed(created):
            try:
                owned(path, directory=path == root or path.is_dir())
                if path.is_dir():
                    path.rmdir()
                else:
                    path.unlink()
            except (LabError, OSError):
                pass
        raise
    return root


def prepare():
    uid = os.getuid()
    m = {"schema": 1, "mode": "fixture", "run_id": str(uuid.uuid4()), "owner_uid": uid,
         "protected_uid": uid, "profiles": {label: str(uuid.uuid4()) for label in ("A", "B")}}
    return create(Path("/private/tmp") / (PREFIX + m["run_id"]), m)


def prepare_guarded():
    if not SAME_USER.get():
        raise LabError("Explicit same-user permission required")
    uid = os.getuid()
    m = {"schema": 1, "mode": "guarded", "run_id": str(uuid.uuid4()), "owner_uid": uid,
         "protected_uid": uid, "profiles": {label: str(uuid.uuid4()) for label in ("A", "B")}}
    return create(Path("/private/tmp") / (PREFIX + m["run_id"]), m)


def environment(root, m, label):
    # Do not accept caller-supplied path/metadata as an ownership capability.
    root, current = load(root)
    if m != current:
        raise LabError("Environment metadata changed")
    home, electron = layout(root, m, label)
    return {"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "CODEX_HOME": str(home),
            "CODEX_ELECTRON_USER_DATA_PATH": str(electron)}


def handoff(root):
    root, m = load(root)
    with locked(root):
        root, m = load(root)
        value = {"schema": 1, "purpose": "manual-preparation-only", "protected_uid": m["protected_uid"],
                 "run_id": m["run_id"], "profiles": m["profiles"]}
        write_json(root / "handoff.json", value)
    return value


def validate_test_session(protected_uid, current_uid=None, confirmed=True):
    uid = os.getuid() if current_uid is None else current_uid
    if (not confirmed or type(protected_uid) is not int or protected_uid <= 0
            or type(uid) is not int or uid <= 0 or uid == protected_uid):
        raise LabError("Separate test-user session required; no automatic user switching")


def manual_parent():
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    owned(home, directory=True, private=False)
    return home / "Library" / "Application Support" / "CodexSwoopIsolationLab"


def prepare_manual(handoff_file, confirmed):
    path = Path(handoff_file)
    forbidden = {".codex", "codex", "codex-home", "electron-user-data", "profiles", "cookies"}
    if not path.is_absolute() or path.name != "handoff.json" or any(p.lower() in forbidden for p in path.parts):
        raise LabError("Use only the generated handoff outside Codex data directories")
    value = read_json(path)
    exact_keys(value, {"schema", "purpose", "protected_uid", "run_id", "profiles"})
    if type(value["schema"]) is not int or value["schema"] != 1 or value["purpose"] != "manual-preparation-only":
        raise LabError("Invalid handoff purpose")
    # Refuse primary UID before computing/creating anything below a user home.
    validate_test_session(value["protected_uid"], confirmed=confirmed)
    m = {"schema": 1, "mode": "manual", "run_id": value["run_id"], "owner_uid": os.getuid(),
         "protected_uid": value["protected_uid"], "profiles": value["profiles"]}
    metadata_check(m)
    parent = manual_parent()
    # Check existing ancestors before writes; create only missing test-user directories, never chmod them.
    missing = []
    ancestor = parent
    while not ancestor.exists() and not ancestor.is_symlink():
        missing.append(ancestor)
        ancestor = ancestor.parent
    owned(ancestor, directory=True, private=False)
    if ancestor.stat().st_mode & 0o022:
        raise LabError("Writable shared ancestor is forbidden")
    for path in reversed(missing):
        path.mkdir(mode=0o700)
    owned(parent, directory=True)
    return create(parent / (PREFIX + m["run_id"]), m)


def plan(root):
    root, m = load(root)
    result = {"mode": m["mode"], "run_id": m["run_id"], "steps": list(STEPS),
              "live_operations": "not implemented; separate human authorization required",
              "authentication_verified": False, "activity": "Unknown", "production_switching": "disabled"}
    if m["mode"] == "guarded":
        result["launch_spec_to_review_only"] = {
            label: {"environment": environment(root, m, label),
                    "arguments": ["--user-data-dir=" + str(layout(root, m, label)[1])],
                    "executable": "UNRESOLVED: revalidate signed official bundle before any live launch"}
            for label in ("A", "B")}
        result["single_instance_routing"] = "unverified; stop before official launch"
    if m["mode"] == "manual":
        result["commands_to_review_only"] = {}
        for label in ("A", "B"):
            env = environment(root, m, label)
            args = ["/usr/bin/env", "-i", "PATH=" + env["PATH"], "LANG=" + env["LANG"],
                    "/usr/bin/open", "-n", "--env", "CODEX_HOME=" + env["CODEX_HOME"],
                    "--env", "CODEX_ELECTRON_USER_DATA_PATH=" + env["CODEX_ELECTRON_USER_DATA_PATH"],
                    "/Applications/ChatGPT.app", "--args", "--user-data-dir=" + env["CODEX_ELECTRON_USER_DATA_PATH"]]
            result["commands_to_review_only"][label] = shlex.join(args)
    return result


class MockDesktop:
    """Synthetic state only; no process objects, credentials or Codex interfaces."""
    def __init__(self, root, metadata):
        require_guard(metadata)
        if metadata["mode"] not in ("fixture", "guarded"):
            raise LabError("Mocks are forbidden in manual environments")
        self.root, self.metadata, self.running = root, metadata, None
        self.recovery_required = False

    def launch(self, label, fail=False, identity_known=True):
        if self.running is not None:
            raise LabError("Mock must exit before another launch")
        environment(self.root, self.metadata, label)
        if fail:
            raise LabError("Injected mock launch failure")
        home, _ = layout(self.root, self.metadata, label)
        session = read_json(home / "fixture-session.json")
        if not identity_known or session != {"label": label, "valid": True}:
            raise LabError("Synthetic identity unavailable")
        self.running = label

    def exit(self, timeout=False):
        require_guard(self.metadata)
        if timeout:
            raise LabError("Injected mock exit timeout")
        self.running = None

    def logout(self):
        if self.running is None:
            raise LabError("No selected mock account")
        environment(self.root, self.metadata, self.running)
        home, _ = layout(self.root, self.metadata, self.running)
        write_json(home / "fixture-session.json", {"label": self.running, "valid": False})

    def reauthenticate(self, label):
        environment(self.root, self.metadata, label)
        home, _ = layout(self.root, self.metadata, label)
        write_json(home / "fixture-session.json", {"label": label, "valid": True})

    def switch(self, label, confirmed=False, fail_launch=False, identity_known=True,
               exit_timeout=False, rollback_fails=False):
        environment(self.root, self.metadata, label)
        if not confirmed:
            return "cancelled"
        previous = self.running
        self.exit(timeout=exit_timeout)
        try:
            self.launch(label, fail=fail_launch, identity_known=identity_known)
        except LabError:
            if rollback_fails:
                self.recovery_required = True
            elif previous is not None:
                self.launch(previous)
            raise
        return "switched"


def rehearse(root):
    root, m = load(root)
    if m["mode"] not in ("fixture", "guarded"):
        raise LabError("Rehearsal is forbidden in manual environments")
    with locked(root):
        root, m = load(root)
        if (root / "probe-pending.json").exists():
            raise LabError("Unresolved own probe; rehearsal refused")
        if (root / "rehearsal.json").exists():
            raise LabError("Rehearsal already exists; create a fresh fixture")
        for label in ("A", "B"):
            home, electron = layout(root, m, label)
            write_json(home / "fixture-session.json", {"label": label, "valid": True})
            write_json(home / "fixture-history.json", ["synthetic-" + label])
            write_json(electron / "fixture-settings.json", {"marker": label})
        desktop = MockDesktop(root, m)
        sequence = []
        for label in ("A", "B", "A"):
            desktop.switch(label, confirmed=True)
            sequence.append(desktop.running)
        desktop.switch("B", confirmed=True)
        desktop.logout()
        desktop.exit()
        try:
            desktop.launch("B")
        except LabError:
            pass
        else:
            raise LabError("Logged-out synthetic session was accepted")
        desktop.launch("A")
        results = {"sequence": sequence, "b_logout_preserves_a": True, "b_requires_reauth": True}
        desktop.reauthenticate("B")
        desktop.switch("B", confirmed=True)
        desktop.switch("A", confirmed=True)
        results["b_reauth_preserves_a"] = desktop.running == "A"
        for label in ("A", "B"):
            home, electron = layout(root, m, label)
            if read_json(home / "fixture-history.json") != ["synthetic-" + label] or read_json(electron / "fixture-settings.json") != {"marker": label}:
                raise LabError("Synthetic data changed")
        if desktop.switch("B", confirmed=False) != "cancelled" or desktop.running != "A":
            raise LabError("Synthetic cancellation lost previous account")
        results["cancel"] = "previous synthetic account retained"
        for scenario, options in (("launch_failure", {"fail_launch": True}), ("unknown_identity", {"identity_known": False})):
            try:
                desktop.switch("B", confirmed=True, **options)
            except LabError:
                if desktop.running != "A":
                    raise LabError("Synthetic recovery lost previous account")
                results[scenario] = "rejected; both fixture profiles retained"
            else:
                raise LabError("Injected error was accepted")
        try:
            desktop.switch("B", confirmed=True, exit_timeout=True)
        except LabError:
            if desktop.running != "A":
                raise LabError("Timeout lost previous mock state")
        desktop.exit()
        results["exit_timeout"] = "previous synthetic account retained"
        desktop.launch("A")
        try:
            desktop.switch("B", confirmed=True, fail_launch=True, rollback_fails=True)
        except LabError:
            if not desktop.recovery_required or desktop.running is not None:
                raise LabError("Synthetic recovery failure was hidden")
        results["rollback_failure"] = "recovery required; fixture profiles retained"
        results.update({"evidence": "synthetic-only", "real_isolation": "unverified", "activity": "Unknown"})
        write_json(root / "rehearsal.json", results)
        return results


def internal_probe(root, label):
    """Owned, short-lived child. Read only the four allowed environment keys."""
    root, m = load(root)
    if m["mode"] != "guarded":
        raise LabError("Probe requires guarded mode")
    expected = environment(root, m, label)
    if read_json(root / "probe-pending.json") != {"run_id": m["run_id"], "state": "own-probe-pending"}:
        raise LabError("Missing own probe lease")
    # Python/macOS can inject these locale keys after exec; never log their values.
    if not set(os.environ).issubset(set(expected) | {"LC_CTYPE", "__CF_USER_TEXT_ENCODING"}):
        raise LabError("Unexpected inherited environment")
    received = {key: os.environ.get(key) for key in expected}
    if received != expected:
        raise LabError("Probe environment mismatch; no fallback")
    value = {"schema": 1, "label": label, "environment": received,
             "evidence": "own-process-only", "authentication_verified": False}
    write_json(root / ("probe-" + label + ".json"), value)
    return value


def probe(root):
    root, m = load(root)
    if m["mode"] != "guarded":
        raise LabError("Probe requires guarded mode")
    with locked(root):
        root, m = load(root)
        pending = root / "probe-pending.json"
        if pending.exists():
            raise LabError("Unresolved own probe; preserve resources")
        write_json(pending, {"run_id": m["run_id"], "state": "own-probe-pending"})
        for label in ("A", "B", "A"):
            # Fixed executable + fixed script + fixed verb. No arbitrary executable,
            # shell, official bundle, host environment or captured child output.
            child = subprocess.Popen(
                [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "internal-probe",
                 "--root", str(root), "--label", label, "--guarded-same-user"],
                env=environment(root, m, label), cwd=root,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                status = child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Preserve resources; never send a signal or launch the next child.
                raise LabError("Own probe did not exit; manual review required") from None
            if status != 0:
                raise LabError("Own probe failed")
            result = read_json(root / ("probe-" + label + ".json"))
            expected = {"schema": 1, "label": label, "environment": environment(root, m, label),
                        "evidence": "own-process-only", "authentication_verified": False}
            if result != expected:
                raise LabError("Own probe result unverified")
        pending.unlink()
    return {"sequence": ["A", "B", "A"], "environment_verified": True,
            "evidence": "own-process-only", "real_isolation": "unverified", "activity": "Unknown"}


def record(root, step, outcome):
    root, m = load(root)
    if m["mode"] != "manual" or step not in STEPS or outcome not in OUTCOMES:
        raise LabError("Only controlled manual observations are accepted")
    with locked(root):
        root, m = load(root)
        path = root / "observations.json"
        entries = read_json(path) if path.exists() else []
        if not isinstance(entries, list) or len(entries) >= 100:
            raise LabError("Invalid or full observation journal")
        for entry in entries:
            exact_keys(entry, {"step", "outcome", "evidence"})
            if entry["step"] not in STEPS or entry["outcome"] not in OUTCOMES or entry["evidence"] != "operator-reported":
                raise LabError("Invalid observation")
        latest = {entry["step"]: entry["outcome"] for entry in entries}
        # Baseline and the nine enrollment/restart checkpoints are sequential.
        # Optional fault/refresh checks may independently remain Unknown.
        prerequisites = STEPS[:min(STEPS.index(step), 9)]
        if any(latest.get(prior) != "pass" for prior in prerequisites):
            raise LabError("Earlier manual checkpoint is incomplete")
        entries.append({"step": step, "outcome": outcome, "evidence": "operator-reported"})
        write_json(path, entries)
    return {"recorded": step, "evidence": "operator-reported", "real_isolation": "unverified"}


def cleanup(root, confirmation):
    root, m = load(root)
    if confirmation != m["run_id"]:
        raise LabError("Cleanup requires the exact run UUID")
    with locked(root):
        # Whole-tree allowlist first; any unexpected data blocks ALL deletion.
        root, m = load(root)
        verify_tree(root, m)
        if (root / "probe-pending.json").exists():
            raise LabError("Unresolved own probe; cleanup refused")
        for parent, directories, files in os.walk(root, topdown=False, followlinks=False, onerror=walk_error):
            for name in files:
                path = Path(parent) / name
                owned(path)
                path.unlink()
            for name in directories:
                path = Path(parent) / name
                owned(path, directory=True)
                path.rmdir()
        root.rmdir()
    return {"removed": m["run_id"], "scope": "owned allowlisted lab files only"}


def main():
    parser = SafeArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    item = sub.add_parser("prepare")
    item.add_argument("--guarded-same-user", action="store_true")
    for name in ("rehearse", "handoff", "plan", "cleanup", "record", "probe", "internal-probe"):
        item = sub.add_parser(name)
        item.add_argument("--root", required=True)
        item.add_argument("--guarded-same-user", action="store_true")
        if name == "internal-probe":
            item.add_argument("--label", choices=("A", "B"), required=True)
        if name == "cleanup":
            item.add_argument("--confirm-id", required=True)
        if name == "record":
            item.add_argument("--step", choices=STEPS, required=True)
            item.add_argument("--outcome", choices=OUTCOMES, required=True)
    item = sub.add_parser("prepare-manual")
    item.add_argument("--handoff", required=True)
    item.add_argument("--test-session-confirmed", action="store_true")
    args = parser.parse_args()
    try:
        with same_user_permission(getattr(args, "guarded_same_user", False)):
            if args.command == "prepare":
                root = prepare_guarded() if SAME_USER.get() else prepare()
                result = {"root": str(root), "mode": load(root)[1]["mode"], "run_id": root.name[len(PREFIX):]}
            elif args.command == "prepare-manual":
                root = prepare_manual(args.handoff, args.test_session_confirmed)
                result = {"root": str(root), "mode": "manual", "live_operations": "not executed"}
            elif args.command == "cleanup":
                result = cleanup(args.root, args.confirm_id)
            elif args.command == "record":
                result = record(args.root, args.step, args.outcome)
            elif args.command == "internal-probe":
                result = internal_probe(args.root, args.label)
            else:
                result = {"rehearse": rehearse, "handoff": handoff, "plan": plan, "probe": probe}[args.command](args.root)
        print(json.dumps(result, indent=2, sort_keys=True))
    except (LabError, OSError, ValueError, KeyError, TypeError):
        # Never print exception values: paths/contents from malformed inputs could contain secrets.
        print("ERROR: lab operation refused; preserve resources and review the isolation runbooks.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
