#!/usr/bin/env python3
"""Enable narrow Android kill diagnostics, restore settings, or collect evidence."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


PACKAGE = "dev.opensourceglasses.even_g2_r1_poc"
REPOSITORY = Path(__file__).resolve().parents[1]
LEVELS = {
    "WorkBench": "I",
    "ActivityManager": "I",
    "ActivityTaskManager": "I",
    "AndroidRuntime": "E",
    "DEBUG": "I",
    "libc": "W",
    "lowmemorykiller": "I",
    "lmkd": "I",
    "Zygote": "I",
}


def outside_repository(path):
    resolved = Path(path).resolve()
    if resolved == REPOSITORY or REPOSITORY in resolved.parents:
        raise ValueError("Diagnostic evidence and settings must stay outside the repository.")
    return resolved


def adb_output(adb, *args):
    # Never echo adb output in an exception: it may contain private device data.
    result = subprocess.run([*adb, *args], capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError("Android diagnostic command failed; settings may require restoration.")
    return result.stdout.decode("utf-8", errors="replace").strip()


def set_level(adb, tag, level):
    if level not in {"", "V", "D", "I", "W", "E", "A", "F", "S"}:
        raise ValueError("Unexpected Android log level; refusing to change settings.")
    # adb shell reparses arguments. All interpolated values are fixed labels or
    # validated levels, and an empty value needs an explicit shell quotation.
    adb_output(adb, "shell", "setprop", "log.tag." + tag, level or "''")
    if adb_output(adb, "shell", "getprop", "log.tag." + tag) != level:
        raise RuntimeError("Android did not accept a diagnostic log level.")


def device_key(device):
    return hashlib.sha256(device.encode("utf-8")).hexdigest()


def enable(adb, device, state_path):
    state_path = outside_repository(state_path)
    previous = {tag: adb_output(adb, "shell", "getprop", "log.tag." + tag)
                for tag in LEVELS}
    if any(value not in {"", "V", "D", "I", "W", "E", "A", "F", "S"}
           for value in previous.values()):
        raise ValueError("Unexpected Android log level; settings were not changed.")
    # Save before the first mutation. Exclusive creation prevents accidentally
    # overwriting the original settings when enable is run twice.
    with state_path.open("x", encoding="utf-8") as output:
        state_path.chmod(0o600)
        json.dump({"schema_version": 1, "device_key": device_key(device),
                   "previous": previous}, output)
    changed = []
    try:
        for tag, level in LEVELS.items():
            changed.append(tag)
            set_level(adb, tag, level)
    except Exception:
        for tag in reversed(changed):
            try:
                set_level(adb, tag, previous[tag])
            except Exception:
                pass  # Keep the state document available for a later restore.
        raise


def restore(adb, device, state_path):
    state = json.loads(outside_repository(state_path).read_text(encoding="utf-8"))
    previous = state.get("previous", {})
    if (state.get("schema_version") != 1 or state.get("device_key") != device_key(device)
            or set(previous) != set(LEVELS)
            or any(value not in {"", "V", "D", "I", "W", "E", "A", "F", "S"}
                   for value in previous.values())):
        raise ValueError("The restoration document is invalid or belongs to another device.")
    for tag, level in previous.items():
        set_level(adb, tag, level)


def collect(adb, output):
    output = outside_repository(output)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    commands = {
        "logcat.txt": ["logcat", "-b", "main", "-b", "system", "-b", "crash",
                       "-d", "-v", "threadtime", *[tag + ":V" for tag in LEVELS], "*:S"],
        "exit-info.txt": ["shell", "dumpsys", "activity", "exit-info", PACKAGE],
        "meminfo-app.txt": ["shell", "dumpsys", "meminfo", PACKAGE],
        "meminfo-gemma.txt": ["shell", "dumpsys", "meminfo", PACKAGE + ":gemma"],
        "processes.txt": ["shell", "dumpsys", "activity", "processes"],
        "meminfo-system.txt": ["shell", "cat", "/proc/meminfo"],
    }
    for name, command in commands.items():
        target = output / name
        with target.open("xb") as stream:
            target.chmod(0o600)
            result = subprocess.run([*adb, *command], stdout=stream,
                                    stderr=subprocess.DEVNULL, timeout=30)
        if result.returncode:
            raise RuntimeError("Evidence collection failed; partial evidence was retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["enable", "restore", "collect"])
    parser.add_argument("--device", required=True, help="Explicit Android device serial")
    parser.add_argument("--state", type=Path, help="Settings document outside the repository")
    parser.add_argument("--output", type=Path, help="New evidence directory outside the repository")
    args = parser.parse_args()
    adb = ["adb", "-s", args.device]
    if args.action == "collect":
        if args.output is None:
            parser.error("collect requires --output")
        collect(adb, args.output)
        print("Evidence saved outside the repository.")
    else:
        if args.state is None:
            if args.action == "restore":
                parser.error("restore requires --state")
            directory = Path(tempfile.mkdtemp(prefix="workbench-kill-logging."))
            args.state = directory / "logging-state.json"
        if args.action == "enable":
            enable(adb, args.device, args.state)
            print("Diagnostic tags enabled until restored or the phone reboots.")
            print("Restoration document:", args.state.resolve())
        else:
            restore(adb, args.device, args.state)
            print("Previous diagnostic log levels restored.")


if __name__ == "__main__":
    main()
