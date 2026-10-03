#!/usr/bin/env python3
"""Kill and relaunch a debug Work Bench app to validate its private SIGKILL journal."""

import argparse
import json
import subprocess
import time


PACKAGE = "dev.opensourceglasses.even_g2_r1_poc"
JOURNAL = "files/workbench/runtime/kill-events.json"
EVENT_FIELDS = {
    "timestamp_ms", "process", "pid", "reason", "reason_code", "status",
    "signal_number", "signal", "importance", "last_sample_pss_kb",
    "last_sample_rss_kb",
}


def read_journal(adb):
    result = subprocess.run(
        [*adb, "shell", "run-as", PACKAGE, "cat", JOURNAL],
        capture_output=True, timeout=10,
    )
    if result.returncode:
        return None
    if len(result.stdout) > 128 * 1024:
        raise RuntimeError("The kill journal exceeds its size bound.")
    try:
        document = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        return None
    if set(document) != {"schema_version", "low_memory_kill_reporting_supported", "events"}:
        raise RuntimeError("The journal contains unexpected metadata fields.")
    if document["schema_version"] != 1 or not isinstance(document["events"], list):
        raise RuntimeError("The journal schema is invalid.")
    events = document["events"]
    if len(events) > 64:
        raise RuntimeError("The kill journal exceeds its retention bound.")
    identities = set()
    for event in events:
        if set(event) != EVENT_FIELDS or event["process"] not in {"app", "gemma"}:
            raise RuntimeError("The journal contains unexpected event fields.")
        if event["reason_code"] not in {2, 3}:
            raise RuntimeError("The journal contains an ordinary process exit.")
        identity = (event["timestamp_ms"], event["process"], event["pid"])
        if identity in identities:
            raise RuntimeError("The journal contains duplicate exits.")
        identities.add(identity)
    return document


def wait_for_journal(adb, predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        document = read_journal(adb)
        if document is not None and predicate(document):
            return document
        time.sleep(0.5)
    raise RuntimeError("The expected private kill record was not persisted.")


def start_app(adb):
    # am start can return success while ActivityManager still holds the dead
    # activity. Retry until there is a live main process, not just a launch reply.
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        result = subprocess.run(
            [*adb, "shell", "am", "start", "-W", "-n", PACKAGE + "/.MainActivity"],
            capture_output=True, timeout=20,
        )
        running = subprocess.run([*adb, "shell", "pidof", PACKAGE],
                                 capture_output=True, timeout=10)
        if result.returncode == 0 and running.returncode == 0 and running.stdout.strip():
            return
        time.sleep(0.5)
    raise RuntimeError("Work Bench could not be relaunched after process cleanup.")


def validate(adb):
    start_app(adb)
    before = wait_for_journal(adb, lambda _: True)
    pid_reply = subprocess.run(
        [*adb, "shell", "pidof", PACKAGE], capture_output=True, timeout=10,
    )
    pids = pid_reply.stdout.split()
    if pid_reply.returncode or len(pids) != 1 or not pids[0].isdigit():
        raise RuntimeError("Expected exactly one Work Bench main process.")
    pid = int(pids[0])
    # A real signal through the app UID is required: am force-stop records USER REQUESTED.
    kill = subprocess.run(
        [*adb, "shell", "run-as", PACKAGE, "kill", "-9", str(pid)],
        capture_output=True, timeout=10,
    )
    if kill.returncode:
        raise RuntimeError("The controlled main-process SIGKILL could not be delivered.")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        running = subprocess.run([*adb, "shell", "pidof", PACKAGE],
                                 capture_output=True, timeout=10)
        if str(pid).encode() not in running.stdout.split():
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("The killed process did not exit.")
    start_app(adb)
    def captured(document):
        return any(
            event["process"] == "app" and event["pid"] == pid
            and event["reason_code"] == 2 and event["status"] == 9
            and event["signal_number"] == 9 and event["signal"] == "SIGKILL"
            for event in document["events"]
        )
    after = wait_for_journal(adb, captured)
    old = {(e["timestamp_ms"], e["process"], e["pid"]) for e in before["events"]}
    new = {(e["timestamp_ms"], e["process"], e["pid"]) for e in after["events"]}
    if len(before["events"]) < 64 and not old.issubset(new):
        raise RuntimeError("Earlier kill evidence was lost during recovery.")
    # Exercise a second foreground transition without killing another process.
    subprocess.run([*adb, "shell", "input", "keyevent", "3"],
                   check=True, capture_output=True, timeout=10)
    start_app(adb)
    time.sleep(1)
    again = wait_for_journal(adb, captured)
    if len(again["events"]) != len(after["events"]):
        raise RuntimeError("Foregrounding duplicated a kill event.")
    return {"passed": True, "controlled_test": True, "test_pid": pid,
            "signal": "SIGKILL", "signal_number": 9,
            "durable_after_relaunch": True, "earlier_records_preserved": True,
            "duplicate_events": False, "general_logs_collected": False,
            "retained_events": len(again["events"])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Explicit Android device serial")
    args = parser.parse_args()
    print(json.dumps(validate(["adb", "-s", args.device]), sort_keys=True))
