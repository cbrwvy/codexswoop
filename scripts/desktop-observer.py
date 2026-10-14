#!/usr/bin/env python3
"""Read-only, redacted process/file-descriptor metadata for a guarded lab.

Never launches/quits Desktop, reads user-data contents, queries auth, or sends signals.
This is partial observation, never proof of account or exclusive state isolation.
"""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys

spec = importlib.util.spec_from_file_location("isolation_lab", Path(__file__).with_name("isolation-lab.py"))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
APP = Path("/Applications/ChatGPT.app")


def observation_root(value, enabled):
    if not enabled:
        raise lab.LabError("Explicit guarded consent required")
    root = Path(value)
    if (not root.is_absolute() or ".." in root.parts or root.resolve() != root
            or root.parent != Path("/private/tmp") or not root.name.startswith(lab.PREFIX)):
        raise lab.LabError("Unmanaged observation root")
    lab.identifier(root.name[len(lab.PREFIX):])
    lab.owned(root, directory=True)
    metadata = lab.read_json(root / lab.MARKER)
    lab.metadata_check(metadata)
    if (metadata["mode"] != "guarded" or metadata["owner_uid"] != os.getuid()
            or root.name != lab.PREFIX + metadata["run_id"]):
        raise lab.LabError("Observation ownership mismatch")
    lab.owned(root / "Profiles", directory=True)
    for label in ("A", "B"):
        home, electron = lab.layout(root, metadata, label)
        for path in (home.parent, home, electron):
            lab.owned(path, directory=True)
    # Unlike mutation/cleanup, observation permits Desktop-created files.
    # It never walks/opens them, changes their permissions or grants cleanup access.
    return root, metadata


def process_rows(text, uid):
    rows = []
    prefix = str(APP) + "/"
    for line in text.splitlines():
        # PID PPID UID + five lstart fields + executable path. Never argv/environment.
        fields = line.strip().split(None, 8)
        if len(fields) != 9:
            continue
        try:
            pid, ppid, owner = map(int, fields[:3])
        except ValueError:
            continue
        executable = fields[8]
        if owner != uid or pid <= 0 or not executable.startswith(prefix):
            continue
        relative = executable[len(prefix):]
        role = ("desktop" if relative == "Contents/MacOS/ChatGPT" else
                "backend" if relative == "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" else
                "bundle-helper")
        rows.append({"pid": pid, "ppid": ppid, "uid": owner,
                     "started": " ".join(fields[3:8]), "role": role})
    return sorted(rows, key=lambda row: row["pid"])


def path_category(value, roots):
    # String classification only. Never stat/resolve/open a path obtained from lsof.
    for name, path in roots.items():
        prefix = str(path)
        if value == prefix or value.startswith(prefix + "/"):
            return name
    return "other"


def descriptor_summary(text, processes, roots):
    accepted = {p["pid"] for p in processes}
    counts = {pid: {name: 0 for name in (*roots, "other")} for pid in accepted}
    current = None
    for line in text.splitlines():
        if line.startswith("p"):
            try:
                current = int(line[1:])
            except ValueError:
                current = None
        elif line.startswith("n") and current in accepted:
            counts[current][path_category(line[1:], roots)] += 1
    # No filenames, socket addresses, paths outside the lab, file contents or secrets.
    return [{"pid": pid, "open_name_counts": counts[pid]} for pid in sorted(counts)]


def fixed_read_command(arguments):
    result = subprocess.run(arguments, env={"PATH": "/usr/bin:/bin:/usr/sbin", "LANG": "C", "LC_ALL": "C"},
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, errors="replace")
    return result.returncode, result.stdout


def observe(root, metadata, files=False):
    code, output = fixed_read_command(["/bin/ps", "-axo", "pid=,ppid=,uid=,lstart=,comm="])
    if code != 0:
        raise lab.LabError("Process inventory unavailable")
    processes = process_rows(output, os.getuid())
    result = {"schema": 1, "run_id": metadata["run_id"], "processes": processes,
              "observation": "partial-metadata-only", "activity": "Unknown",
              "authentication": "not inspected", "exclusive_isolation": "unverified",
              "descriptor_observation": "not requested"}
    if files and processes:
        code, output = fixed_read_command(["/usr/sbin/lsof", "-n", "-P", "-a", "-p",
                                           ",".join(str(row["pid"]) for row in processes), "-Fpn"])
        # Even success is a point-in-time partial sample. Errors never become empty/Idle.
        if code != 0:
            result["descriptor_observation"] = "unavailable"
        else:
            roots = {}
            for label in ("A", "B"):
                home, electron = lab.layout(root, metadata, label)
                roots[label + "_backend"] = home
                roots[label + "_electron"] = electron
            home = Path(pwd.getpwuid(os.getuid()).pw_dir)
            roots.update({"default_backend": home / ".codex",
                          "default_electron": home / "Library/Application Support/Codex"})
            result["descriptor_observation"] = "partial-sample"
            result["descriptors"] = descriptor_summary(output, processes, roots)
    return result


def main():
    parser = lab.SafeArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--guarded-same-user", action="store_true")
    parser.add_argument("--files", action="store_true")
    args = parser.parse_args()
    try:
        root, metadata = observation_root(args.root, args.guarded_same_user)
        print(json.dumps(observe(root, metadata, args.files), indent=2, sort_keys=True))
    except (lab.LabError, OSError, ValueError, KeyError, TypeError):
        print("ERROR: metadata observation unavailable; stop and preserve resources.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
