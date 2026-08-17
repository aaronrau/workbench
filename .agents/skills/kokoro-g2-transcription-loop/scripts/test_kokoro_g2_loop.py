#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import struct
import sys
import tempfile
import unittest
import wave
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("kokoro_g2_loop.py")
SPEC = importlib.util.spec_from_file_location("kokoro_g2_loop", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ScoringTest(unittest.TestCase):
    @staticmethod
    def _audio(level: int) -> str:
        return (
            "[Even G2/R1][Audio] 32.0 kbit/s • "
            f"100 frames/s • level {level}/255"
        )

    def test_default_speaker_is_american_english(self) -> None:
        args = MODULE.parser().parse_args(
            ["generate", "--output", "/tmp/test.wav"]
        )
        self.assertEqual(args.speaker_id, 0)
        self.assertEqual(MODULE.ENGLISH_SPEAKERS[args.speaker_id], "af_maple")

    def test_physical_run_controls_computer_volume(self) -> None:
        args = MODULE.parser().parse_args(
            ["run", "--output-dir", "/tmp/test-run"]
        )
        self.assertEqual(args.computer_volume, 0.90)
        self.assertEqual(MODULE.PLAYBACK_PATH, "computer_speaker")
        self.assertFalse(hasattr(args, "phone_speaker"))
        self.assertFalse(hasattr(args, "phone_volume"))
        self.assertEqual(args.leading_silence_seconds, 1.0)
        self.assertEqual(args.trailing_silence_seconds, 0.5)
        self.assertEqual(args.connection_timeout, 60.0)

    def test_preflight_command_requires_app_button_reconnect(self) -> None:
        args = MODULE.parser().parse_args(
            ["preflight", "--output-dir", "/tmp/test-preflight"]
        )

        self.assertEqual(args.command, "preflight")
        self.assertEqual(args.connection_timeout, 60.0)

    def test_physical_run_rejects_phone_speaker_playback(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                MODULE.parser().parse_args(
                    [
                        "run",
                        "--output-dir",
                        "/tmp/test-run",
                        "--phone-speaker",
                    ]
                )

    def test_connection_button_tap_point_uses_phone_geometry(self) -> None:
        self.assertEqual(
            MODULE.connection_button_tap_point(
                "Physical size: 1080x2400\n",
                "Physical density: 480\n",
            ),
            (216, 156),
        )
        with self.assertRaises(RuntimeError):
            MODULE.connection_button_tap_point(
                "Physical size: 2400x1080\n",
                "Physical density: 480\n",
            )

    def test_connection_test_markers_are_bounded(self) -> None:
        self.assertEqual(
            MODULE.test_marker("connection_reconnect_ready", "preflight"),
            "[WorkBench][Test] "
            "state=connection_reconnect_ready case=preflight",
        )
        self.assertIn(
            "state=connection_disconnect_ready",
            MODULE.test_marker("connection_disconnect_ready", "preflight"),
        )
        self.assertIn(
            "state=connection_initial_retry",
            MODULE.test_marker("connection_initial_retry", "preflight"),
        )
        with self.assertRaises(ValueError):
            MODULE.test_marker("unbounded", "preflight")

    def test_disconnect_preflight_requires_vad_flush_readiness(self) -> None:
        self.assertIsNotNone(
            MODULE.VAD_FLUSHED_RE.search(
                "[WorkBench][VAD] state=flushed next=ready "
                "provider=cpu detector=recreated"
            )
        )
        self.assertIsNone(
            MODULE.VAD_FLUSHED_RE.search(
                "[WorkBench][VAD] state=flushed next=ready provider=cpu"
            )
        )

    def test_late_audio_wins_while_waiting_for_pipeline_ready(self) -> None:
        marker = MODULE.test_marker("connection_audio_wait", "initial_connect")
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "connection.log"
            log.write_text(
                "\n".join([marker, self._audio(1), self._audio(2)]),
                encoding="utf-8",
            )

            samples, pipeline_ready = MODULE._wait_for_audio_or_log_pattern(
                log,
                marker,
                MODULE.PIPELINE_READY_RE,
                timeout_seconds=0.1,
            )

        self.assertEqual(samples, 2)
        self.assertFalse(pipeline_ready)

    def test_android_log_tag_can_be_restored_to_empty(self) -> None:
        self.assertEqual(
            MODULE.android_setprop_command("log.tag.WorkBench", ""),
            "setprop log.tag.WorkBench ''",
        )

    def test_padding_preserves_pcm_and_adds_exact_silence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            stimulus = output_dir / "stimulus.wav"
            samples = tuple(range(1, 11))
            with wave.open(str(stimulus), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(10)
                wav.writeframes(struct.pack("<10h", *samples))

            padded = MODULE.padded_wav_copy(
                stimulus,
                output_dir,
                leading_silence_seconds=1.0,
                trailing_silence_seconds=0.5,
            )

            with wave.open(str(padded), "rb") as wav:
                actual = struct.unpack(
                    "<25h",
                    wav.readframes(wav.getnframes()),
                )
                self.assertEqual(wav.getnframes(), 25)
            self.assertEqual(actual[:10], (0,) * 10)
            self.assertEqual(actual[10:20], samples)
            self.assertEqual(actual[20:], (0,) * 5)

    def test_playback_peak_normalization_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            stimulus = output_dir / "stimulus.wav"
            samples = (-1000, 0, 500, 1000)
            with wave.open(str(stimulus), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(10)
                wav.writeframes(struct.pack("<4h", *samples))

            normalized, details = MODULE.peak_normalized_wav_copy(
                stimulus,
                output_dir,
                target_fraction=0.5,
            )

            with wave.open(str(normalized), "rb") as wav:
                actual = struct.unpack("<4h", wav.readframes(4))
            self.assertEqual(actual, (-16384, 0, 8192, 16384))
            self.assertEqual(details["target_fraction"], 0.5)
            self.assertEqual(details["input_peak"], 1000)
            self.assertEqual(details["output_peak"], 16384)
            self.assertAlmostEqual(
                details["gain_db"],
                20 * MODULE.math.log10(16.384),
            )

    def test_artifact_directory_refuses_to_overwrite_prior_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            (output_dir / "report.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                MODULE.prepare_artifact_directory(output_dir)

    def test_wav_manifest_records_reproducible_audio_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            stimulus = Path(temporary) / "stimulus.wav"
            with wave.open(str(stimulus), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(10)
                wav.writeframes(struct.pack("<10h", *range(10)))

            manifest = MODULE.wav_manifest(stimulus)

            self.assertEqual(manifest["sample_rate_hz"], 10)
            self.assertEqual(manifest["frame_count"], 10)
            self.assertEqual(manifest["duration_seconds"], 1.0)
            self.assertEqual(len(manifest["sha256"]), 64)

    def test_sentence_chunks_preserve_all_validation_text(self) -> None:
        self.assertEqual(
            MODULE._sentence_chunks("First sentence. Second sentence!"),
            ["First sentence.", "Second sentence!"],
        )

    def test_normalized_word_error_rate(self) -> None:
        self.assertEqual(
            MODULE.word_error_rate(
                "Work Bench checks audio.",
                "work bench checks audio",
            ),
            0.0,
        )

    def test_common_compound_and_number_formats_are_equivalent(self) -> None:
        self.assertEqual(
            MODULE.normalize_words("WorkBench check number seven"),
            ["work", "bench", "check", "number", "7"],
        )
        self.assertEqual(
            MODULE.word_error_rate(
                "Work Bench check number seven",
                "workbench check number 7",
            ),
            0.0,
        )

    def test_report_requires_transport_transcript_and_safety(self) -> None:
        log = "\n".join(
            [
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 5/255",
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 7/255",
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 90/255",
                "[WorkBench][Transcript][FINAL] segment=1 text=hello glasses",
            ]
        )
        report = MODULE.build_report(
            expected="hello glasses",
            log_text=log,
            baseline_count=2,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
        )
        self.assertTrue(report.passed)

    def test_report_rejects_a_failed_connection_preflight(self) -> None:
        log = "\n".join(
            [
                self._audio(5),
                self._audio(90),
                "[WorkBench][Transcript][FINAL] segment=1 text=hello",
            ]
        )
        failed = MODULE.build_report(
            expected="hello",
            log_text=log,
            baseline_count=1,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
            connection_preflight_passed=False,
        )
        passed = MODULE.build_report(
            expected="hello",
            log_text=log,
            baseline_count=1,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
            connection_preflight_passed=True,
        )

        self.assertFalse(failed.checks["connection_preflight"])
        self.assertFalse(failed.passed)
        self.assertTrue(passed.checks["connection_preflight"])
        self.assertTrue(passed.passed)

    def test_report_combines_vad_split_transcripts_in_order(self) -> None:
        log = "\n".join(
            [
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 5/255",
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 90/255",
                "[WorkBench][Transcript][FINAL] segment=1 text=hello",
                "[WorkBench][Transcript][FINAL] segment=2 text=glasses",
            ]
        )
        report = MODULE.build_report(
            expected="hello glasses",
            log_text=log,
            baseline_count=1,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
        )
        self.assertEqual(report.transcript, "hello glasses")
        self.assertTrue(report.passed)

    def test_report_deduplicates_hard_rollover_boundary_words(self) -> None:
        log = "\n".join(
            [
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 5/255",
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 90/255",
                "[WorkBench][Transcript][FINAL] segment=1 text=keep the boundary words",
                "[WorkBench][Transcript][FINAL] segment=2 text=boundary words intact now",
            ]
        )
        report = MODULE.build_report(
            expected="keep the boundary words intact now",
            log_text=log,
            baseline_count=1,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
        )

        self.assertEqual(report.transcript, "keep the boundary words intact now")
        self.assertTrue(report.passed)

    def test_restart_must_recover(self) -> None:
        log = "\n".join(
            [
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 5/255",
                "[Even G2/R1][Audio] 32.0 kbit/s • 100 frames/s • level 80/255",
                "[WorkBench][Transcription] state=restarting attempt=1",
                "[WorkBench][Transcript][FINAL] segment=1 text=hello",
            ]
        )
        report = MODULE.build_report(
            expected="hello",
            log_text=log,
            baseline_count=1,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
        )
        self.assertFalse(report.passed)
        self.assertFalse(report.checks["transcription_recovered"])

    def test_playback_cannot_contaminate_quiet_baseline(self) -> None:
        start = MODULE.playback_marker("playback_start", "baseline")
        end = MODULE.playback_marker("playback_end", "baseline")
        log = "\n".join(
            [
                self._audio(8),
                self._audio(10),
                self._audio(12),
                start,
                self._audio(210),
                end,
                "[WorkBench][Transcript][FINAL] "
                "segment=1 text=the blue lamp is ready",
            ]
        )
        report = MODULE.build_report(
            expected="the blue lamp is ready",
            log_text=log,
            baseline_count=4,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
            playback_start_marker=start,
            playback_end_marker=end,
        )

        self.assertEqual(report.baseline_level, 10)
        self.assertEqual(report.peak_level, 210)
        self.assertEqual(report.activity_rise, 200)
        self.assertTrue(report.checks["playback_boundary"])
        self.assertTrue(report.passed)

    def test_stale_transcript_before_playback_is_not_scored(self) -> None:
        start = MODULE.playback_marker("playback_start", "stale")
        end = MODULE.playback_marker("playback_end", "stale")
        log = "\n".join(
            [
                self._audio(10),
                "[WorkBench][Transcript][FINAL] "
                "segment=old text=wrong old words",
                start,
                self._audio(180),
                end,
                "[WorkBench][Transcript][FINAL] "
                "segment=new text=the blue lamp is ready",
            ]
        )
        report = MODULE.build_report(
            expected="the blue lamp is ready",
            log_text=log,
            baseline_count=4,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
            playback_start_marker=start,
            playback_end_marker=end,
        )

        self.assertEqual(report.transcript, "the blue lamp is ready")
        self.assertEqual(report.word_error_rate, 0)

    def test_missing_playback_end_fails_boundary_check(self) -> None:
        start = MODULE.playback_marker("playback_start", "missing_end")
        end = MODULE.playback_marker("playback_end", "missing_end")
        report = MODULE.build_report(
            expected="hello",
            log_text="\n".join(
                [
                    self._audio(10),
                    start,
                    self._audio(180),
                    "[WorkBench][Transcript][FINAL] segment=1 text=hello",
                ]
            ),
            baseline_count=4,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
            playback_start_marker=start,
            playback_end_marker=end,
        )

        self.assertTrue(report.playback_start_observed)
        self.assertFalse(report.playback_end_observed)
        self.assertFalse(report.checks["playback_boundary"])
        self.assertFalse(report.passed)


if __name__ == "__main__":
    unittest.main()
