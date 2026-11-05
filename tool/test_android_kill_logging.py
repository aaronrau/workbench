import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import android_kill_logging as diagnostics


class KillLoggingTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="workbench-kill-logging-test.")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.state = self.directory / "state.json"
        self.device = "<android-serial>"
        self.adb = ["adb", "-s", self.device]
        self.levels = {tag: "" for tag in diagnostics.LEVELS}
        self.levels["AndroidRuntime"] = "S"

    def output(self, adb, *args):
        self.assertEqual(adb, self.adb)
        if args[:2] == ("shell", "getprop"):
            return self.levels[args[2].removeprefix("log.tag.")]
        if args[:2] == ("shell", "setprop"):
            self.levels[args[2].removeprefix("log.tag.")] = args[3].replace("'", "")
            return ""
        self.fail("Unexpected adb command")

    def test_enable_overrides_silent_tags_and_restore_recovers_empty_values(self):
        previous = dict(self.levels)
        with patch.object(diagnostics, "adb_output", side_effect=self.output):
            diagnostics.enable(self.adb, self.device, self.state)
            self.assertEqual(self.levels, diagnostics.LEVELS)
            diagnostics.restore(self.adb, self.device, self.state)
        self.assertEqual(self.levels, previous)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(self.device, self.state.read_text())

    def test_duplicate_enable_does_not_overwrite_original_settings(self):
        with patch.object(diagnostics, "adb_output", side_effect=self.output):
            diagnostics.enable(self.adb, self.device, self.state)
            saved = self.state.read_bytes()
            with self.assertRaises(FileExistsError):
                diagnostics.enable(self.adb, self.device, self.state)
        self.assertEqual(self.state.read_bytes(), saved)

    def test_failed_enable_rolls_back_already_changed_tags(self):
        previous = dict(self.levels)
        original_set = diagnostics.set_level

        def fail_once(adb, tag, level):
            if tag == "DEBUG" and level == "I":
                raise RuntimeError("Property change refused")
            original_set(adb, tag, level)

        with patch.object(diagnostics, "adb_output", side_effect=self.output), \
                patch.object(diagnostics, "set_level", side_effect=fail_once):
            with self.assertRaisesRegex(RuntimeError, "Property change refused"):
                diagnostics.enable(self.adb, self.device, self.state)
        self.assertEqual(self.levels, previous)
        self.assertTrue(self.state.exists())

    def test_wrong_device_and_unexpected_state_never_mutate_properties(self):
        state = {"schema_version": 1, "device_key": diagnostics.device_key(self.device),
                 "previous": self.levels}
        self.state.write_text(json.dumps(state))
        with patch.object(diagnostics, "adb_output") as adb:
            with self.assertRaises(ValueError):
                diagnostics.restore(self.adb, "<other-android-serial>", self.state)
            state["previous"]["untrusted-tag"] = "I"
            self.state.write_text(json.dumps(state))
            with self.assertRaises(ValueError):
                diagnostics.restore(self.adb, self.device, self.state)
        adb.assert_not_called()

    def test_evidence_paths_cannot_enter_repository_through_symlinks(self):
        link = self.directory / "repo-link"
        link.symlink_to(diagnostics.REPOSITORY, target_is_directory=True)
        for path in [diagnostics.REPOSITORY / "ignored-evidence", link / "evidence"]:
            with self.assertRaises(ValueError):
                diagnostics.outside_repository(path)

    def test_property_failure_does_not_expose_private_command_output(self):
        result = diagnostics.subprocess.CompletedProcess([], 1, b"private-value", b"private-value")
        with patch.object(diagnostics.subprocess, "run", return_value=result):
            with self.assertRaises(RuntimeError) as error:
                diagnostics.adb_output(self.adb, "shell", "getprop")
        self.assertNotIn("private-value", str(error.exception))

    def test_collection_keeps_private_files_outside_repository_and_never_clears_logs(self):
        output = self.directory / "evidence"

        def run(command, **kwargs):
            self.assertEqual(command[:3], self.adb)
            self.assertNotIn("-c", command)
            kwargs["stdout"].write(b"synthetic diagnostic evidence")
            return diagnostics.subprocess.CompletedProcess(command, 0)

        with patch.object(diagnostics.subprocess, "run", side_effect=run):
            diagnostics.collect(self.adb, output)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(len(list(output.iterdir())), 6)
        for path in output.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            diagnostics.collect(self.adb, output)


if __name__ == "__main__":
    unittest.main()
