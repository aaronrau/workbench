#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
MODULE_PATH = SCRIPTS / "kokoro_turn_suite.py"
SPEC = importlib.util.spec_from_file_location("kokoro_turn_suite", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def line(second: float, message: str) -> str:
    whole = int(second)
    millis = round((second - whole) * 1000)
    return f"07-25 12:00:{whole:02d}.{millis:03d} D/flutter: {message}"


class TurnSuiteTest(unittest.TestCase):
    def test_default_cases_cover_requested_sequence(self) -> None:
        cases = {case.name: case for case in MODULE.CASES}
        self.assertEqual(cases["long_continuous"].expected_turns, 1)
        self.assertEqual(cases["short_continuation"].silence_seconds, 0.4)
        self.assertEqual(cases["short_continuation"].expected_turns, 1)
        self.assertEqual(cases["separated_questions"].silence_seconds, 2.2)
        self.assertEqual(cases["separated_questions"].expected_turns, 3)

    def test_suite_uses_the_validated_playback_fixture_defaults(self) -> None:
        args = MODULE.parser().parse_args(["--output-dir", "/tmp/test-suite"])
        self.assertEqual(MODULE.loop.PLAYBACK_PATH, "computer_speaker")
        self.assertEqual(args.computer_volume, 0.90)
        self.assertEqual(args.leading_silence_seconds, 1.0)
        self.assertEqual(args.trailing_silence_seconds, 0.5)
        self.assertEqual(args.connection_timeout, 60.0)

    def test_suite_rejects_phone_speaker_playback(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                MODULE.parser().parse_args(
                    [
                        "--output-dir",
                        "/tmp/test-suite",
                        "--phone-speaker",
                    ]
                )

    def test_suite_enables_and_restores_required_android_log_tags(self) -> None:
        adb_prefix = ["adb", "-s", "device"]
        previous_values = ["", "W", "I"]
        with mock.patch.object(
            MODULE.loop,
            "get_android_property",
            side_effect=previous_values,
        ), mock.patch.object(
            MODULE.loop,
            "set_android_property",
        ) as set_property:
            previous = MODULE._enable_android_log_tags(adb_prefix)
            MODULE._restore_android_log_tags(adb_prefix, previous)

        expected_enable_calls = [
            mock.call(adb_prefix, tag, "V")
            for tag in MODULE.REQUIRED_ANDROID_LOG_TAGS
        ]
        expected_restore_calls = [
            mock.call(adb_prefix, tag, value)
            for tag, value in zip(
                MODULE.REQUIRED_ANDROID_LOG_TAGS,
                previous_values,
            )
        ]
        self.assertEqual(
            set_property.call_args_list,
            expected_enable_calls + expected_restore_calls,
        )

    def test_duration_and_boundary_profiles_cover_extremes(self) -> None:
        durations = {case.name: case for case in MODULE.DURATION_CASES}
        boundaries = {case.name: case for case in MODULE.BOUNDARY_CASES}
        self.assertEqual(durations["duration_clip_100ms"].expected_turns, 0)
        self.assertIsNone(
            durations["duration_clip_300ms_characterize"].expected_turns
        )
        self.assertIsNone(
            durations["duration_clip_800ms_characterize"].expected_turns
        )
        self.assertIsNone(
            durations["duration_clip_650ms_characterize"].expected_turns
        )
        self.assertEqual(
            len(durations["duration_sixty_seconds"].utterances),
            13,
        )
        self.assertEqual(durations["duration_thirty_seconds"].minimum_chunks, 2)
        self.assertEqual(durations["duration_sixty_seconds"].minimum_chunks, 3)
        self.assertEqual(boundaries["gap_1200ms_merge"].expected_turns, 1)
        self.assertIsNone(
            boundaries["gap_1900ms_characterize"].expected_turns
        )
        self.assertIsNone(
            boundaries["gap_2000ms_characterize"].expected_turns
        )
        self.assertIsNone(
            boundaries["gap_2050ms_characterize"].expected_turns
        )
        self.assertEqual(boundaries["gap_2100ms_split"].expected_turns, 2)

    def test_center_clip_has_exact_requested_length(self) -> None:
        pcm = bytes(range(100))
        clipped = MODULE._center_clip_pcm(pcm, sample_rate=10, seconds=2)
        self.assertEqual(len(clipped), 40)
        self.assertEqual(clipped, pcm[30:70])

    def test_center_clip_rejects_an_invalid_longer_request(self) -> None:
        with self.assertRaises(RuntimeError):
            MODULE._center_clip_pcm(
                bytes(range(100)),
                sample_rate=10,
                seconds=6,
            )

    def test_case_requires_endpoint_buffer_queue_and_order(self) -> None:
        case = MODULE.TurnCase(
            name="unit",
            utterances=("Where is my red book?",),
            silence_seconds=0.0,
            expected_turns=1,
        )
        segment = "turn-1"
        start = MODULE.loop.playback_marker("playback_start", case.name)
        end = MODULE.loop.playback_marker("playback_end", case.name)
        log = "\n".join(
            [
                line(
                    0.0,
                    "[Even G2/R1][Audio] 32.0 kbit/s • "
                    "100 frames/s • level 5/255",
                ),
                line(0.5, start),
                line(
                    1.0,
                    "[Even G2/R1][Audio] 32.0 kbit/s • "
                    "100 frames/s • level 90/255",
                ),
                line(
                    2.0,
                    f"[WorkBench][VAD] state=speech_started segment={segment}",
                ),
                line(
                    2.0,
                    "[WorkBench][TranscriptUI] state=cleared "
                    f"reason=speech_started segment={segment}",
                ),
                line(2.5, end),
                line(
                    3.0,
                    "[WorkBench][VAD] state=speech_ending "
                    f"segment={segment} delay_ms=1500",
                ),
                line(
                    4.5,
                    "[WorkBench][VAD] state=buffer_cleared "
                    f"segment={segment} bytes=64000 next=ready",
                ),
                line(
                    4.5,
                    "[WorkBench][VAD] state=speech_ended "
                    f"segment={segment} audio_ms=1500",
                ),
                line(
                    4.5,
                    "[WorkBench][Transcription] state=queued "
                    f"segment={segment} pending=1",
                ),
                line(
                    4.6,
                    "[WorkBench][Transcription] state=processing "
                    f"segment={segment}",
                ),
                line(
                    4.7,
                    "[WorkBench][Transcript][FINAL] "
                    f"segment={segment} text=Where is my red book",
                ),
                line(
                    4.71,
                    "[WorkBench][Transcription] state=completed "
                    f"segment={segment} model=test provider=cpu "
                    "audio_ms=5000 decode_ms=200 windows=1 total_ms=210",
                ),
            ]
        )
        result = MODULE.analyze_case(
            case,
            log,
            baseline_count=1,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
            playback_start_marker=start,
            playback_end_marker=end,
        )
        self.assertTrue(result.passed)
        self.assertTrue(result.checks["playback_boundary"])
        self.assertAlmostEqual(result.turns[0].endpoint_seconds, 1.5)
        self.assertEqual(result.turns[0].endpoint_audio_ms, 1500)
        self.assertAlmostEqual(
            result.turns[0].queue_to_final_seconds,
            0.2,
        )

    def test_forced_chunks_remain_one_turn_without_llm_correction(self) -> None:
        case = MODULE.TurnCase(
            name="forced",
            utterances=("The first boundary chunk and the second chunk",),
            silence_seconds=0.0,
            expected_turns=1,
            minimum_chunks=2,
        )
        root = "turn-1"
        continuation = f"{root}-part-2"
        start = MODULE.loop.playback_marker("playback_start", case.name)
        end = MODULE.loop.playback_marker("playback_end", case.name)
        log = "\n".join(
            [
                line(
                    0.0,
                    "[Even G2/R1][Audio] 32.0 kbit/s • "
                    "100 frames/s • level 5/255",
                ),
                line(0.5, start),
                line(
                    1.0,
                    "[Even G2/R1][Audio] 32.0 kbit/s • "
                    "100 frames/s • level 90/255",
                ),
                line(
                    2.0,
                    f"[WorkBench][VAD] state=speech_started segment={root}",
                ),
                line(
                    2.0,
                    "[WorkBench][TranscriptUI] state=cleared "
                    f"reason=speech_started segment={root}",
                ),
                line(
                    17.0,
                    "[WorkBench][VAD] state=speech_chunked "
                    f"segment={root} reason=durationHardLimit continuation=true",
                ),
                line(
                    17.0,
                    "[WorkBench][VAD] state=speech_continued "
                    f"segment={continuation} "
                    "reason=durationHardLimit overlap_ms=1000",
                ),
                line(
                    17.0,
                    "[WorkBench][Transcription] state=queued "
                    f"segment={root} pending=1",
                ),
                line(
                    17.1,
                    "[WorkBench][Transcription] state=processing "
                    f"segment={root}",
                ),
                line(
                    17.3,
                    "[WorkBench][Transcript][FINAL] "
                    f"segment={root} text=The first boundary chunk",
                ),
                line(
                    17.31,
                    "[WorkBench][Transcription] state=completed "
                    f"segment={root} model=test provider=cpu "
                    "audio_ms=17000 decode_ms=200 windows=1 total_ms=210",
                ),
                line(
                    17.32,
                    "[WorkBench][VoiceRoute] state=collecting "
                    f"segment={root} reason=conversation_continues "
                    "action=deferred",
                ),
                line(31.0, end),
                line(
                    31.1,
                    "[WorkBench][VAD] state=speech_ending "
                    f"segment={continuation} delay_ms=1500",
                ),
                line(
                    32.6,
                    "[WorkBench][VAD] state=buffer_cleared "
                    f"segment={continuation} bytes=64000 next=ready",
                ),
                line(
                    32.6,
                    "[WorkBench][VAD] state=speech_ended "
                    f"segment={continuation} audio_ms=1500",
                ),
                line(
                    32.6,
                    "[WorkBench][Transcription] state=queued "
                    f"segment={continuation} pending=1",
                ),
                line(
                    32.7,
                    "[WorkBench][Transcription] state=processing "
                    f"segment={continuation}",
                ),
                line(
                    32.9,
                    "[WorkBench][Transcript][FINAL] "
                    f"segment={continuation} "
                    "text=boundary chunk and the second chunk",
                ),
                line(
                    32.91,
                    "[WorkBench][Transcription] state=completed "
                    f"segment={continuation} model=test provider=cpu "
                    "audio_ms=15000 decode_ms=200 windows=1 total_ms=210",
                ),
            ]
        )

        result = MODULE.analyze_case(
            case,
            log,
            baseline_count=1,
            max_wer=0.25,
            min_activity_rise=30,
            min_frames_per_second=90,
            playback_start_marker=start,
            playback_end_marker=end,
        )

        self.assertTrue(result.passed)
        self.assertEqual(result.observed_turns, 1)
        self.assertEqual(result.turns[0].chunk_count, 2)
        self.assertEqual(result.turns[0].duration_rollovers, 1)
        self.assertEqual(result.turns[0].maximum_audio_ms, 17000)
        self.assertTrue(result.turns[0].checks["single_real_endpoint"])
        self.assertTrue(result.turns[0].checks["no_correction_without_hey"])
        self.assertTrue(result.turns[0].checks["rollover_overlap_contract"])
        self.assertTrue(
            result.turns[0].checks["intermediate_actions_deferred"]
        )
        self.assertEqual(
            result.turns[0].transcript,
            "The first boundary chunk and the second chunk",
        )

    def test_prior_turn_words_are_detected_in_later_transcript(self) -> None:
        leaked = MODULE._leaked_prior_words(
            "When does the train leave?",
            "When does the red book train leave?",
            ("Where is my red book?",),
        )
        self.assertEqual(leaked, {"book"})


if __name__ == "__main__":
    unittest.main()
