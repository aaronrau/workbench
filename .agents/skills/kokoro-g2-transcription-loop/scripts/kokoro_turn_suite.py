#!/usr/bin/env python3
"""Exercise Work Bench VAD and transcription turn boundaries with Kokoro."""

from __future__ import annotations

import argparse
import json
import re
import struct
import subprocess
import time
import wave
from dataclasses import asdict, dataclass, replace
from datetime import datetime
from pathlib import Path

import kokoro_g2_loop as loop

ENDPOINT_TAIL_MS = 1500
ENDPOINT_AUDIO_MIN_MS = 1450
ENDPOINT_AUDIO_MAX_MS = 1600
MAXIMUM_CHUNK_AUDIO_MS = 19500
REQUIRED_ANDROID_LOG_TAGS = (
    "log.tag.WorkBenchTest",
    "log.tag.flutter",
    "log.tag.WorkBench",
)


def _enable_android_log_tags(adb_prefix: list[str]) -> dict[str, str]:
    previous: dict[str, str] = {}
    for tag in REQUIRED_ANDROID_LOG_TAGS:
        previous[tag] = loop.get_android_property(adb_prefix, tag)
        loop.set_android_property(adb_prefix, tag, "V")
    return previous


def _restore_android_log_tags(
    adb_prefix: list[str],
    previous: dict[str, str],
) -> None:
    for tag, value in previous.items():
        try:
            loop.set_android_property(adb_prefix, tag, value)
        except subprocess.CalledProcessError:
            pass


@dataclass(frozen=True)
class TurnCase:
    name: str
    utterances: tuple[str, ...]
    silence_seconds: float
    expected_turns: int | None
    clip_seconds: float | None = None
    repeat_count: int = 1
    score_transcript: bool = True
    minimum_chunks: int = 1
    selector_at_seconds: float | None = None
    selector_fixture: int = 0

    @property
    def expected_transcripts(self) -> tuple[str, ...]:
        expanded = self.utterances * self.repeat_count
        if self.expected_turns == 1:
            return (" ".join(expanded),)
        return expanded


CASES = (
    TurnCase(
        name="long_continuous",
        utterances=(
            "Today I am testing the glasses with one long sentence and I will "
            "keep speaking until every word is complete",
        ),
        silence_seconds=0.0,
        expected_turns=1,
    ),
    TurnCase(
        name="short_continuation",
        utterances=(
            "Today is Monday",
            "The sky is blue",
            "The room is quiet",
        ),
        silence_seconds=0.4,
        expected_turns=1,
    ),
    TurnCase(
        name="separated_questions",
        utterances=(
            "Where is my red book?",
            "When does the train leave?",
            "Did you open the front door?",
        ),
        silence_seconds=2.2,
        expected_turns=3,
    ),
    TurnCase(
        name="queue_overlap",
        utterances=(
            "Please save the green note.",
            "Please close the blue window.",
            "Please call the next meeting.",
        ),
        silence_seconds=2.2,
        expected_turns=3,
    ),
)

LONG_UTTERANCES = (
    "Today I am testing the glasses while the audio stream remains clear "
    "and every spoken word moves through the pipeline",
    "The green lamp stands beside the quiet window while a red notebook "
    "rests safely on the wooden table",
    "A small clock shows the correct time and the blue folder contains all "
    "of the notes for our meeting",
    "The morning train will leave the central station after every passenger "
    "has found the proper seat",
    "Please record this sentence carefully and keep the sound connected "
    "while the local model completes its work",
    "Our simple test uses clear English words so each result can be compared "
    "with the original phrase",
    "The garden path turns past the old stone wall and continues toward the "
    "bright open field",
    "A careful worker checks every saved file before the next request enters "
    "the transcription queue",
    "The silver cup remains near the yellow plate while clean water fills "
    "the glass beside it",
    "We will finish this extended audio test after the final sentence reaches "
    "the local speech model",
    "The brown package waits near the front door until the delivery record "
    "has been checked and saved",
    "A steady connection carries each audio frame while the screen and ring "
    "remain responsive to new events",
    "This final passage confirms that a longer recording can close safely and "
    "enter the transcription worker queue",
)

DURATION_CASES = (
    TurnCase(
        name="duration_clip_100ms",
        utterances=("Yes",),
        silence_seconds=0.0,
        expected_turns=0,
        clip_seconds=0.1,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_clip_200ms",
        utterances=("Yes",),
        silence_seconds=0.0,
        expected_turns=0,
        clip_seconds=0.2,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_clip_300ms_characterize",
        utterances=("Yes",),
        silence_seconds=0.0,
        expected_turns=None,
        clip_seconds=0.3,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_clip_500ms",
        utterances=("Yes",),
        silence_seconds=0.0,
        expected_turns=None,
        clip_seconds=0.5,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_clip_600ms_characterize",
        utterances=("Today is a clear Monday",),
        silence_seconds=0.0,
        expected_turns=None,
        clip_seconds=0.6,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_clip_650ms_characterize",
        utterances=("Today is a clear Monday",),
        silence_seconds=0.0,
        expected_turns=None,
        clip_seconds=0.65,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_clip_700ms_characterize",
        utterances=("Today is a clear Monday",),
        silence_seconds=0.0,
        expected_turns=None,
        clip_seconds=0.7,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_clip_800ms_characterize",
        utterances=("Today is a clear Monday",),
        silence_seconds=0.0,
        expected_turns=None,
        clip_seconds=0.8,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_clip_900ms_characterize",
        utterances=("Today is a clear Monday",),
        silence_seconds=0.0,
        expected_turns=None,
        clip_seconds=0.9,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_short_word_characterize",
        utterances=("Yes",),
        silence_seconds=0.0,
        expected_turns=None,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_one_second",
        utterances=("Today is a clear Monday",),
        silence_seconds=0.0,
        expected_turns=1,
        clip_seconds=1.0,
        score_transcript=False,
    ),
    TurnCase(
        name="duration_short_phrase",
        utterances=("The blue lamp is ready",),
        silence_seconds=0.0,
        expected_turns=1,
    ),
    TurnCase(
        name="duration_five_seconds",
        utterances=(
            "Today I am testing the glasses with one long sentence and I will "
            "keep speaking until every word is complete",
        ),
        silence_seconds=0.0,
        expected_turns=1,
    ),
    TurnCase(
        name="duration_fifteen_seconds",
        utterances=LONG_UTTERANCES[:3],
        silence_seconds=0.1,
        expected_turns=1,
    ),
    TurnCase(
        name="duration_thirty_seconds",
        utterances=LONG_UTTERANCES[:6],
        silence_seconds=0.1,
        expected_turns=1,
        minimum_chunks=2,
    ),
    TurnCase(
        name="duration_sixty_seconds",
        utterances=LONG_UTTERANCES,
        silence_seconds=0.1,
        expected_turns=1,
        minimum_chunks=3,
    ),
)

STRESS_CASES = (
    TurnCase(
        name="continuous_agent_menu_stress",
        utterances=LONG_UTTERANCES,
        silence_seconds=0.1,
        expected_turns=1,
        repeat_count=5,
        minimum_chunks=15,
        selector_at_seconds=15.0,
    ),
)

BOUNDARY_PHRASES = (
    "The red book is on the table",
    "The blue lamp is by the window",
)


def _boundary_case(
    milliseconds: int,
    expected_turns: int | None,
) -> TurnCase:
    suffix = "characterize" if expected_turns is None else (
        "merge" if expected_turns == 1 else "split"
    )
    return TurnCase(
        name=f"gap_{milliseconds:04d}ms_{suffix}",
        utterances=BOUNDARY_PHRASES,
        silence_seconds=milliseconds / 1000,
        expected_turns=expected_turns,
        score_transcript=expected_turns is not None,
    )


BOUNDARY_CASES = (
    _boundary_case(100, 1),
    _boundary_case(400, 1),
    _boundary_case(800, 1),
    _boundary_case(1200, 1),
    _boundary_case(1600, 1),
    _boundary_case(1800, None),
    _boundary_case(1900, None),
    _boundary_case(1950, None),
    _boundary_case(2000, None),
    _boundary_case(2050, None),
    _boundary_case(2100, 2),
    _boundary_case(2200, 2),
    _boundary_case(2500, 2),
    _boundary_case(5000, 2),
)

ALL_CASES = CASES + DURATION_CASES + BOUNDARY_CASES + STRESS_CASES

TIMESTAMP_RE = re.compile(
    r"^(?P<timestamp>\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})"
)
START_RE = re.compile(
    r"\[WorkBench\]\[VAD\] state=speech_started segment=(?P<id>\S+)"
)
ENDING_RE = re.compile(
    r"\[WorkBench\]\[VAD\] state=speech_ending segment=(?P<id>\S+) "
    r"delay_ms=(?P<delay>\d+)"
)
BUFFER_RE = re.compile(
    r"\[WorkBench\]\[VAD\] state=buffer_cleared segment=(?P<id>\S+) "
    r"bytes=(?P<bytes>\d+) next=ready"
)
ENDED_RE = re.compile(
    r"\[WorkBench\]\[VAD\] state=speech_ended segment=(?P<id>\S+) "
    r"audio_ms=(?P<audioMs>\d+)"
)
CHUNKED_RE = re.compile(
    r"\[WorkBench\]\[VAD\] state=speech_chunked segment=(?P<id>\S+) "
    r"reason=(?P<reason>\S+) continuation=true"
)
CONTINUED_RE = re.compile(
    r"\[WorkBench\]\[VAD\] state=speech_continued segment=(?P<id>\S+) "
    r"reason=\S+ overlap_ms=(?P<overlapMs>\d+)"
)
QUEUED_RE = re.compile(
    r"\[WorkBench\]\[Transcription\] state=queued segment=(?P<id>\S+) "
    r"pending=(?P<pending>\d+)"
)
PROCESSING_RE = re.compile(
    r"\[WorkBench\]\[Transcription\] state=processing segment=(?P<id>\S+)"
)
COMPLETED_RE = re.compile(
    r"\[WorkBench\]\[Transcription\] state=completed segment=(?P<id>\S+) "
    r".* audio_ms=(?P<audioMs>\d+)"
)
CORRECTION_QUEUED_RE = re.compile(
    r"\[WorkBench\]\[Correction\] state=queued segment=(?P<id>\S+)"
)
ACTION_DEFERRED_RE = re.compile(
    r"\[WorkBench\]\[VoiceRoute\] state=collecting segment=(?P<id>\S+) "
    r"reason=conversation_continues action=deferred"
)
FINAL_RE = re.compile(
    r"\[WorkBench\]\[Transcript\]\[FINAL\] "
    r"segment=(?P<id>\S+) text=(?P<text>.*)$"
)
UI_CLEAR_RE = re.compile(
    r"\[WorkBench\]\[TranscriptUI\] state=cleared "
    r"reason=speech_started segment=(?P<id>\S+)"
)
SELECTOR_OPEN_RE = re.compile(
    r"\[WorkBench\]\[DebugSelector\] state=opened fixture=(?P<fixture>\d+)"
)
HISTORY_DISPLAY_RE = re.compile(
    r"\[WorkBench\]\[G2Display\] state=generation_changed\b"
    r".*\bowner=history\b"
)
CAPTURE_STREAMING_RE = re.compile(
    r"\[WorkBench\]\[Capture\] state=streaming\b"
)
ANDROID_CRASH_RE = re.compile(
    r"FATAL EXCEPTION|Fatal signal\s+\d+|ANR in "
    + re.escape(loop.APP_PACKAGE)
)


@dataclass(frozen=True)
class Marker:
    line: int
    seconds: float
    segment_id: str
    value: str | int | None = None


@dataclass(frozen=True)
class TurnResult:
    segment_id: str
    segment_ids: tuple[str, ...]
    chunk_count: int
    duration_rollovers: int
    maximum_audio_ms: int | None
    expected: str
    transcript: str | None
    word_error_rate: float | None
    endpoint_seconds: float | None
    endpoint_audio_ms: int | None
    queue_to_final_seconds: float | None
    configured_delay_ms: int | None
    buffer_bytes: int | None
    pending_at_queue: int | None
    checks: dict[str, bool]
    passed: bool


@dataclass(frozen=True)
class CaseResult:
    name: str
    silence_seconds: float
    stimulus_seconds: float | None
    expected_turns: int | None
    observed_turns: int
    test_fixture: dict[str, object]
    audio_report: dict[str, object]
    turns: tuple[TurnResult, ...]
    checks: dict[str, bool]
    passed: bool


def _timestamp_seconds(line: str) -> float:
    match = TIMESTAMP_RE.search(line)
    if match is None:
        raise ValueError(f"Log marker has no timestamp: {line}")
    parsed = datetime.strptime(
        f"2000-{match.group('timestamp')}",
        "%Y-%m-%d %H:%M:%S.%f",
    )
    return (
        parsed.timetuple().tm_yday * 86400
        + parsed.hour * 3600
        + parsed.minute * 60
        + parsed.second
        + parsed.microsecond / 1_000_000
    )


def _markers(
    lines: list[str],
    pattern: re.Pattern[str],
    value_group: str | None = None,
) -> list[Marker]:
    result: list[Marker] = []
    for line_number, line in enumerate(lines):
        match = pattern.search(line)
        if match is None:
            continue
        value: str | int | None = None
        if value_group is not None:
            value = match.group(value_group)
            if value_group in {
                "delay",
                "bytes",
                "pending",
                "audioMs",
                "overlapMs",
            }:
                value = int(value)
        result.append(
            Marker(
                line=line_number,
                seconds=_timestamp_seconds(line),
                segment_id=match.group("id"),
                value=value,
            )
        )
    return result


def _by_segment(markers: list[Marker]) -> dict[str, Marker]:
    return {marker.segment_id: marker for marker in markers}


def _belongs_to_turn(root_segment_id: str, segment_id: str) -> bool:
    return (
        segment_id == root_segment_id
        or segment_id.startswith(f"{root_segment_id}-part-")
    )


def _turn_markers(
    root_segment_id: str,
    markers: dict[str, Marker],
) -> list[Marker]:
    return sorted(
        (
            marker
            for marker in markers.values()
            if _belongs_to_turn(root_segment_id, marker.segment_id)
        ),
        key=lambda marker: marker.line,
    )


def _leaked_prior_words(
    expected: str,
    transcript: str,
    prior_expected: tuple[str, ...],
) -> set[str]:
    current = set(loop.normalize_words(expected))
    actual = set(loop.normalize_words(transcript))
    prior = {
        word
        for phrase in prior_expected
        for word in loop.normalize_words(phrase)
        if len(word) >= 4
    }
    return (prior - current) & actual


def analyze_case(
    case: TurnCase,
    log_text: str,
    *,
    baseline_count: int,
    max_wer: float,
    min_activity_rise: float,
    min_frames_per_second: float,
    stimulus_seconds: float | None = None,
    playback_start_marker: str | None = None,
    playback_end_marker: str | None = None,
    playback_volume: float | None = None,
    leading_silence_seconds: float | None = None,
    trailing_silence_seconds: float | None = None,
    test_fixture: dict[str, object] | None = None,
) -> CaseResult:
    _, scored_log, playback_start_observed = loop.split_at_marker(
        log_text,
        playback_start_marker,
    )
    lines = (
        scored_log.splitlines()
        if playback_start_observed is not False
        else []
    )
    starts = _markers(lines, START_RE)
    endings = _by_segment(_markers(lines, ENDING_RE, "delay"))
    buffers = _by_segment(_markers(lines, BUFFER_RE, "bytes"))
    ended = _by_segment(_markers(lines, ENDED_RE, "audioMs"))
    chunked = _by_segment(_markers(lines, CHUNKED_RE, "reason"))
    continued = _by_segment(_markers(lines, CONTINUED_RE, "overlapMs"))
    queued = _by_segment(_markers(lines, QUEUED_RE, "pending"))
    processing = _by_segment(_markers(lines, PROCESSING_RE))
    completed = _by_segment(_markers(lines, COMPLETED_RE, "audioMs"))
    correction_queued = _by_segment(_markers(lines, CORRECTION_QUEUED_RE))
    action_deferred = _by_segment(_markers(lines, ACTION_DEFERRED_RE))
    finals = _by_segment(_markers(lines, FINAL_RE, "text"))
    ui_clears = _by_segment(_markers(lines, UI_CLEAR_RE))

    audio = loop.build_report(
        expected=" ".join(case.utterances),
        log_text=log_text,
        baseline_count=baseline_count,
        max_wer=max_wer,
        min_activity_rise=min_activity_rise,
        min_frames_per_second=min_frames_per_second,
        playback_start_marker=playback_start_marker,
        playback_end_marker=playback_end_marker,
        playback_volume=playback_volume,
        leading_silence_seconds=leading_silence_seconds,
        trailing_silence_seconds=trailing_silence_seconds,
    )
    transport_check_names = (
        "playback_boundary",
        "audio_observed",
        "audio_activity_rise",
        "frame_rate",
        "no_unexpected_disconnect",
        "capture_safe",
        "transcription_recovered",
    )
    audio_checks = {
        name: audio.checks[name]
        for name in transport_check_names
    }
    if (
        case.expected_turns in {0, None}
        and case.clip_seconds is not None
        and case.clip_seconds < 1.0
    ):
        # A once-per-second level summary can miss a sub-second stimulus.
        # Transport continuity and all safety checks remain hard assertions.
        audio_checks["audio_activity_rise"] = True

    expected_transcripts = case.expected_transcripts
    turn_results: list[TurnResult] = []
    for index, start in enumerate(starts):
        segment_id = start.segment_id
        expected = (
            expected_transcripts[index]
            if index < len(expected_transcripts)
            else ""
        )
        turn_endings = _turn_markers(segment_id, endings)
        turn_buffers = _turn_markers(segment_id, buffers)
        turn_ended = _turn_markers(segment_id, ended)
        turn_chunked = _turn_markers(segment_id, chunked)
        turn_continued = _turn_markers(segment_id, continued)
        turn_queued = _turn_markers(segment_id, queued)
        turn_processing = _turn_markers(segment_id, processing)
        turn_completed = _turn_markers(segment_id, completed)
        turn_correction_queued = _turn_markers(segment_id, correction_queued)
        turn_action_deferred = _turn_markers(segment_id, action_deferred)
        turn_finals = _turn_markers(segment_id, finals)
        ending = turn_endings[-1] if turn_endings else None
        buffer = turn_buffers[-1] if turn_buffers else None
        end = turn_ended[-1] if turn_ended else None
        queue = turn_queued[0] if turn_queued else None
        final = turn_finals[-1] if turn_finals else None
        transcript = (
            loop.merge_overlapping_transcripts(
                str(item.value) for item in turn_finals
            )
            if turn_finals
            else None
        )
        segment_ids = tuple(item.segment_id for item in turn_finals)
        completed_audio_ms = [
            int(item.value)
            for item in turn_completed
            if isinstance(item.value, int)
        ]
        endpoint_seconds = (
            end.seconds - ending.seconds
            if ending is not None and end is not None
            else None
        )
        queue_to_final_seconds = (
            final.seconds - queue.seconds
            if queue is not None and final is not None
            else None
        )
        wer = (
            loop.word_error_rate(expected, transcript)
            if expected and transcript is not None
            else None
        )
        prior_expected = expected_transcripts[:index]
        leaked = (
            _leaked_prior_words(expected, transcript, prior_expected)
            if expected and transcript is not None
            else set()
        )
        ui_clear = ui_clears.get(segment_id)
        initial_order = (
            ui_clear is not None and start.line <= ui_clear.line
        )
        endpoint_order = (
            ending is not None
            and buffer is not None
            and end is not None
            and ending.line <= buffer.line <= end.line
        )
        transcription_order = (
            len(turn_queued)
            == len(turn_processing)
            == len(turn_finals)
            == len(turn_completed)
            and all(
                queue_marker.line
                <= process_marker.line
                <= final_marker.line
                <= completed_marker.line
                for queue_marker, process_marker, final_marker, completed_marker
                in zip(
                    turn_queued,
                    turn_processing,
                    turn_finals,
                    turn_completed,
                )
            )
        )
        expected_has_wake_word = bool(
            re.search(
                r"(^|[^A-Za-z0-9_])hey(?=$|[^A-Za-z0-9_])",
                expected,
                flags=re.IGNORECASE,
            )
        )
        rollover_overlap_contract = (
            len(turn_continued) == len(turn_chunked)
            and [item.segment_id for item in turn_continued]
            == list(segment_ids[1:])
            and all(
                (
                    chunk.value == "durationHardLimit"
                    and continuation.value == 1000
                )
                or (
                    chunk.value
                    in {"durationPause", "durationWordBoundary"}
                    and continuation.value == 0
                )
                for chunk, continuation in zip(turn_chunked, turn_continued)
            )
        )
        checks = {
            "expected_turn": (
                case.expected_turns is None
                or index < len(expected_transcripts)
            ),
            "ui_cleared_at_start": ui_clear is not None,
            "endpoint_configured_1500_ms": (
                ending is not None and ending.value == ENDPOINT_TAIL_MS
            ),
            "endpoint_audio_duration": (
                end is not None
                and isinstance(end.value, int)
                and ENDPOINT_AUDIO_MIN_MS
                <= end.value
                <= ENDPOINT_AUDIO_MAX_MS
            ),
            "buffer_cleared": (
                buffer is not None
                and isinstance(buffer.value, int)
                and buffer.value > 0
            ),
            "queued": bool(turn_queued),
            "processed": bool(turn_processing),
            "final_transcript": bool(turn_finals),
            "minimum_chunk_count": len(turn_finals) >= case.minimum_chunks,
            "bounded_chunk_audio": (
                len(completed_audio_ms) == len(turn_finals)
                and all(
                    value <= MAXIMUM_CHUNK_AUDIO_MS
                    for value in completed_audio_ms
                )
            ),
            "single_real_endpoint": len(turn_ended) == 1,
            "duration_rollovers_are_not_endpoints": (
                len(turn_chunked) == max(0, len(turn_finals) - 1)
            ),
            "rollover_overlap_contract": rollover_overlap_contract,
            "intermediate_actions_deferred": (
                {item.segment_id for item in turn_action_deferred}
                == set(segment_ids[:-1])
            ),
            "no_correction_without_hey": (
                expected_has_wake_word or not turn_correction_queued
            ),
            "marker_order": (
                initial_order and endpoint_order and transcription_order
            ),
            "transcript_accuracy": (
                not case.score_transcript
                or (wer is not None and wer <= max_wer)
            ),
            "no_prior_turn_leak": not leaked,
        }
        turn_results.append(
            TurnResult(
                segment_id=segment_id,
                segment_ids=segment_ids,
                chunk_count=len(turn_finals),
                duration_rollovers=len(turn_chunked),
                maximum_audio_ms=(
                    max(completed_audio_ms) if completed_audio_ms else None
                ),
                expected=expected,
                transcript=transcript,
                word_error_rate=wer,
                endpoint_seconds=endpoint_seconds,
                endpoint_audio_ms=(
                    int(end.value) if end is not None else None
                ),
                queue_to_final_seconds=queue_to_final_seconds,
                configured_delay_ms=(
                    int(ending.value) if ending is not None else None
                ),
                buffer_bytes=(
                    int(buffer.value) if buffer is not None else None
                ),
                pending_at_queue=(
                    int(queue.value) if queue is not None else None
                ),
                checks=checks,
                passed=all(checks.values()),
            )
        )

    characterization = case.expected_turns is None
    logical_final_count = sum(item.chunk_count > 0 for item in turn_results)
    assigned_final_count = sum(item.chunk_count for item in turn_results)
    case_checks = {
        "expected_turn_count": (
            characterization or len(starts) == case.expected_turns
        ),
        "expected_final_count": (
            logical_final_count == len(starts)
            if characterization
            else logical_final_count == case.expected_turns
        ),
        "all_final_chunks_assigned": assigned_final_count == len(finals),
        "segment_ids_unique": len({item.segment_id for item in starts}) == len(starts),
        "all_turns_passed": (
            (characterization or len(turn_results) == case.expected_turns)
            and all(item.passed for item in turn_results)
        ),
        **audio_checks,
    }
    if case.selector_at_seconds is not None:
        selector_line = next(
            (
                index
                for index, line in enumerate(lines)
                if (
                    (match := SELECTOR_OPEN_RE.search(line)) is not None
                    and int(match.group("fixture")) == case.selector_fixture
                )
            ),
            None,
        )
        case_checks.update(
            {
                "agent_menu_opened": selector_line is not None,
                "history_owns_display_generation": any(
                    HISTORY_DISPLAY_RE.search(line) for line in lines
                ),
                "audio_continued_in_agent_menu": (
                    selector_line is not None
                    and any(
                        loop.AUDIO_RE.search(line)
                        for line in lines[selector_line + 1 :]
                    )
                ),
                "capture_continued_in_agent_menu": (
                    selector_line is not None
                    and any(
                        CAPTURE_STREAMING_RE.search(line)
                        for line in lines[selector_line + 1 :]
                    )
                ),
                "no_android_crash_marker": not ANDROID_CRASH_RE.search(
                    scored_log
                ),
            }
        )
    return CaseResult(
        name=case.name,
        silence_seconds=case.silence_seconds,
        stimulus_seconds=stimulus_seconds,
        expected_turns=case.expected_turns,
        observed_turns=len(starts),
        test_fixture=test_fixture or {},
        audio_report={
            "audio_samples": audio.audio_samples,
            "baseline_level": audio.baseline_level,
            "peak_level": audio.peak_level,
            "activity_rise": audio.activity_rise,
            "median_frames_per_second": audio.median_frames_per_second,
            "unexpected_disconnect": audio.unexpected_disconnect,
            "capture_failure": audio.capture_failure,
            "transcription_restarts": audio.transcription_restarts,
            "transcription_recovered": audio.transcription_recovered,
            "playback_start_observed": audio.playback_start_observed,
            "playback_end_observed": audio.playback_end_observed,
            "playback_volume": audio.playback_volume,
            "leading_silence_seconds": audio.leading_silence_seconds,
            "trailing_silence_seconds": audio.trailing_silence_seconds,
        },
        turns=tuple(turn_results),
        checks=case_checks,
        passed=all(case_checks.values()),
    )


def _read_pcm(path: Path) -> tuple[int, bytes]:
    with wave.open(str(path), "rb") as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2:
            raise RuntimeError(f"Expected mono 16-bit PCM: {path}")
        return wav.getframerate(), wav.readframes(wav.getnframes())


def _trim_pcm(pcm: bytes, sample_rate: int) -> bytes:
    samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
    audible = [
        index for index, value in enumerate(samples) if abs(value) >= 256
    ]
    if not audible:
        raise RuntimeError("Kokoro output has no audible samples")
    padding = round(sample_rate * 0.05)
    first = max(0, audible[0] - padding)
    last = min(len(samples), audible[-1] + padding + 1)
    return struct.pack(f"<{last - first}h", *samples[first:last])


def _center_clip_pcm(pcm: bytes, sample_rate: int, seconds: float) -> bytes:
    target_samples = round(sample_rate * seconds)
    available_samples = len(pcm) // 2
    if target_samples <= 0:
        raise ValueError("Clip duration must be positive")
    if target_samples > available_samples:
        raise RuntimeError(
            f"Requested {seconds:.3f}s clip from only "
            f"{available_samples / sample_rate:.3f}s of speech"
        )
    if target_samples == available_samples:
        return pcm
    first = (available_samples - target_samples) // 2
    start = first * 2
    return pcm[start : start + target_samples * 2]


def build_stimulus(
    case: TurnCase,
    output_dir: Path,
    *,
    speaker_id: int,
    speed: float,
) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    sample_rate: int | None = None
    chunks: list[bytes] = []
    generated: dict[str, tuple[int, bytes]] = {}
    for index, utterance in enumerate(
        case.utterances * case.repeat_count,
        start=1,
    ):
        cached = generated.get(utterance)
        if cached is None:
            part = output_dir / f"utterance-{index}.wav"
            loop.synthesize(utterance, part, speaker_id, speed)
            current_rate, pcm = _read_pcm(part)
            pcm = _trim_pcm(pcm, current_rate)
            generated[utterance] = (current_rate, pcm)
        else:
            current_rate, pcm = cached
        if sample_rate is None:
            sample_rate = current_rate
        elif current_rate != sample_rate:
            raise RuntimeError("Kokoro sample rate changed within a test case")
        if chunks:
            chunks.append(
                b"\x00\x00"
                * round(sample_rate * case.silence_seconds)
            )
        chunks.append(pcm)
    if sample_rate is None:
        raise RuntimeError("Test case contains no Kokoro utterance")

    combined = b"".join(chunks)
    if case.clip_seconds is not None:
        combined = _center_clip_pcm(
            combined,
            sample_rate,
            case.clip_seconds,
        )

    stimulus = output_dir / "stimulus.wav"
    with wave.open(str(stimulus), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(combined)
    return stimulus


def get_computer_volume(wpctl: str) -> float:
    result = subprocess.run(
        [wpctl, "get-volume", "@DEFAULT_AUDIO_SINK@"],
        check=True,
        capture_output=True,
        text=True,
    )
    match = re.search(r"\bVolume:\s*(\d+(?:\.\d+)?)", result.stdout)
    if match is None:
        raise RuntimeError("Could not read the computer speaker volume")
    return float(match.group(1))


def set_computer_volume(wpctl: str, volume: float) -> None:
    if not 0.0 <= volume <= 1.0:
        raise ValueError("Computer speaker volume must be between 0.0 and 1.0")
    subprocess.run(
        [wpctl, "set-volume", "@DEFAULT_AUDIO_SINK@", f"{volume:.4f}"],
        check=True,
    )


def agent_selector_command(
    adb_prefix: list[str],
    fixture: int,
) -> list[str]:
    if fixture not in range(4):
        raise ValueError("Agent selector fixture must be between 0 and 3")
    return [
        *adb_prefix,
        "shell",
        "am",
        "start",
        "-n",
        f"{loop.APP_PACKAGE}/.MainActivity",
        "-a",
        f"{loop.APP_PACKAGE}.SHOW_AGENT_SELECTOR_FIXTURE",
        "--ei",
        "selector_fixture",
        str(fixture),
    ]


def run_case(
    case: TurnCase,
    output_dir: Path,
    args: argparse.Namespace,
    adb_prefix: list[str],
) -> CaseResult:
    case_dir = output_dir / case.name
    stimulus = build_stimulus(
        case,
        case_dir,
        speaker_id=args.speaker_id,
        speed=args.speed,
    )
    playback = loop.playback_copy(
        stimulus,
        case_dir,
        leading_silence_seconds=args.leading_silence_seconds,
        trailing_silence_seconds=args.trailing_silence_seconds,
    )
    device_log = case_dir / "device.log"
    playback_start = loop.playback_marker("playback_start", case.name)
    playback_end = loop.playback_marker("playback_end", case.name)

    subprocess.run([*adb_prefix, "logcat", "-c"], check=True)
    log_handle = device_log.open("w", encoding="utf-8")
    log_process = subprocess.Popen(
        [*adb_prefix, "logcat", "-v", "time"],
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        time.sleep(args.baseline_seconds)
        loop.emit_android_test_marker(
            adb_prefix,
            "playback_start",
            case.name,
        )
        try:
            player = subprocess.Popen([args.player, str(playback)])
            try:
                if case.selector_at_seconds is not None:
                    selector_deadline = (
                        time.monotonic() + case.selector_at_seconds
                    )
                    while (
                        player.poll() is None
                        and time.monotonic() < selector_deadline
                    ):
                        time.sleep(
                            max(
                                0.0,
                                min(
                                    0.1,
                                    selector_deadline - time.monotonic(),
                                ),
                            )
                        )
                    if player.poll() is not None:
                        raise RuntimeError(
                            "Computer-speaker playback ended before the "
                            "agent menu stress action"
                        )
                    subprocess.run(
                        agent_selector_command(
                            adb_prefix,
                            case.selector_fixture,
                        ),
                        check=True,
                        stdout=subprocess.DEVNULL,
                    )
                return_code = player.wait()
                if return_code != 0:
                    raise subprocess.CalledProcessError(
                        return_code,
                        [args.player, str(playback)],
                    )
            finally:
                if player.poll() is None:
                    player.terminate()
                    try:
                        player.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        player.kill()
                        player.wait(timeout=5)
        finally:
            loop.emit_android_test_marker(
                adb_prefix,
                "playback_end",
                case.name,
            )
        _wait_for_case_result(case, device_log, args)
    finally:
        log_process.terminate()
        try:
            log_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            log_process.kill()
            log_process.wait(timeout=5)
        log_handle.close()

    with wave.open(str(stimulus), "rb") as wav:
        stimulus_seconds = wav.getnframes() / wav.getframerate()
    result = analyze_case(
        case,
        device_log.read_text(encoding="utf-8", errors="replace"),
        baseline_count=max(1, round(args.baseline_seconds)),
        max_wer=args.max_wer,
        min_activity_rise=args.min_activity_rise,
        min_frames_per_second=args.min_frames_per_second,
        stimulus_seconds=stimulus_seconds,
        playback_start_marker=playback_start,
        playback_end_marker=playback_end,
        playback_volume=args.computer_volume,
        leading_silence_seconds=args.leading_silence_seconds,
        trailing_silence_seconds=args.trailing_silence_seconds,
        test_fixture={
            "case": case.name,
            "expected_text": " ".join(
                case.utterances * case.repeat_count
            ),
            "speaker_id": args.speaker_id,
            "speaker_name": loop.ENGLISH_SPEAKERS[args.speaker_id],
            "speed": args.speed,
            "playback_path": loop.PLAYBACK_PATH,
            "computer_volume": args.computer_volume,
            "inter_utterance_silence_seconds": case.silence_seconds,
            "agent_menu_at_seconds": case.selector_at_seconds,
            "agent_menu_fixture": (
                case.selector_fixture
                if case.selector_at_seconds is not None
                else None
            ),
            "stimulus": loop.wav_manifest(stimulus),
            "playback": loop.wav_manifest(playback),
        },
    )
    (case_dir / "report.json").write_text(
        json.dumps(asdict(result), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return result


def _wait_for_case_result(
    case: TurnCase,
    device_log: Path,
    args: argparse.Namespace,
) -> None:
    minimum_deadline = time.monotonic() + args.wait_after
    final_deadline = time.monotonic() + args.result_timeout
    while time.monotonic() < final_deadline:
        time.sleep(0.25)
        log_text = device_log.read_text(
            encoding="utf-8",
            errors="replace",
        )
        lines = log_text.splitlines()
        starts = _markers(lines, START_RE)
        ended_ids = {
            marker.segment_id for marker in _markers(lines, ENDED_RE, "audioMs")
        }
        final_ids = {
            marker.segment_id for marker in _markers(lines, FINAL_RE, "text")
        }
        completed_ids = {
            marker.segment_id
            for marker in _markers(lines, COMPLETED_RE, "audioMs")
        }
        if time.monotonic() < minimum_deadline:
            continue
        if case.expected_turns == 0 or not starts:
            return
        finished_turns = len(ended_ids & final_ids & completed_ids)
        if case.expected_turns is None and finished_turns >= len(starts):
            return
        if (
            case.expected_turns is not None
            and finished_turns >= case.expected_turns
        ):
            return


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--output-dir", required=True)
    root.add_argument(
        "--profile",
        action="append",
        choices=("core", "duration", "boundary", "stress", "all"),
        help="Case group to run; defaults to core and may be repeated",
    )
    root.add_argument(
        "--case",
        action="append",
        choices=tuple(case.name for case in ALL_CASES),
        help="Run only this case; repeat to select multiple cases",
    )
    root.add_argument(
        "--repeat",
        type=int,
        default=1,
        help="Repeat every selected case into independent numbered artifacts",
    )
    root.add_argument(
        "--speaker-id",
        type=int,
        choices=tuple(loop.ENGLISH_SPEAKERS),
        default=0,
        help="English Kokoro voice: 0=af_maple, 1=af_sol, 2=bf_vale",
    )
    root.add_argument("--speed", type=float, default=1.0)
    root.add_argument("--computer-volume", type=float, default=0.90)
    root.add_argument("--leading-silence-seconds", type=float, default=1.0)
    root.add_argument("--trailing-silence-seconds", type=float, default=0.5)
    root.add_argument("--adb")
    root.add_argument("--serial")
    root.add_argument("--player")
    root.add_argument("--baseline-seconds", type=float, default=4.0)
    root.add_argument("--wait-after", type=float, default=8.0)
    root.add_argument("--connection-timeout", type=float, default=60.0)
    root.add_argument(
        "--result-timeout",
        type=float,
        default=30.0,
        help="Maximum post-playback wait when a started turn has no final result",
    )
    root.add_argument("--max-wer", type=float, default=0.25)
    root.add_argument("--min-activity-rise", type=float, default=30.0)
    root.add_argument("--min-frames-per-second", type=float, default=90.0)
    return root


def main() -> int:
    args = parser().parse_args()
    if args.repeat < 1:
        raise ValueError("--repeat must be at least 1")
    output_dir = Path(args.output_dir).resolve()
    loop.prepare_artifact_directory(output_dir)
    args.player = args.player or loop.require_tool("pw-play")
    wpctl = loop.require_tool("wpctl")
    adb = loop.select_adb(args.adb)
    serial = loop.ensure_single_device(adb, args.serial)
    adb_prefix = [adb, "-s", serial]

    package_result = subprocess.run(
        [*adb_prefix, "shell", "pm", "path", loop.APP_PACKAGE],
        capture_output=True,
        text=True,
    )
    if package_result.returncode != 0 or "package:" not in package_result.stdout:
        raise RuntimeError(f"Work Bench is not installed ({loop.APP_PACKAGE})")

    connection_preflight = loop.run_connection_preflight(
        adb_prefix,
        output_dir / "connection-preflight.log",
        timeout_seconds=args.connection_timeout,
    )

    selected_names = set(args.case or ())
    if selected_names:
        selected = [
            case for case in ALL_CASES if case.name in selected_names
        ]
    else:
        profiles = set(args.profile or ("core",))
        if "all" in profiles:
            selected = list(ALL_CASES)
        else:
            profile_cases = {
                "core": CASES,
                "duration": DURATION_CASES,
                "boundary": BOUNDARY_CASES,
                "stress": STRESS_CASES,
            }
            selected = [
                case
                for profile in ("core", "duration", "boundary", "stress")
                if profile in profiles
                for case in profile_cases[profile]
            ]
    if args.repeat > 1:
        selected = [
            replace(case, name=f"{case.name}_r{repetition}")
            for case in selected
            for repetition in range(1, args.repeat + 1)
        ]
    original_volume = get_computer_volume(wpctl)
    previous_log_tags = _enable_android_log_tags(adb_prefix)
    results: list[CaseResult] = []
    try:
        set_computer_volume(wpctl, args.computer_volume)
        for case in selected:
            print(
                f"running {case.name}: expected_turns={case.expected_turns} "
                f"silence={case.silence_seconds:.2f}s",
                flush=True,
            )
            result = run_case(case, output_dir, args, adb_prefix)
            results.append(result)
            print(
                f"{case.name}: {'PASS' if result.passed else 'FAIL'} "
                f"observed_turns={result.observed_turns}",
                flush=True,
            )
    finally:
        set_computer_volume(wpctl, original_volume)
        _restore_android_log_tags(adb_prefix, previous_log_tags)

    report = {
        "speaker_id": args.speaker_id,
        "speaker_name": loop.ENGLISH_SPEAKERS[args.speaker_id],
        "playback_path": loop.PLAYBACK_PATH,
        "computer_volume_during_test": args.computer_volume,
        "computer_volume_restored_to": original_volume,
        "connection_preflight": connection_preflight,
        "leading_silence_seconds": args.leading_silence_seconds,
        "trailing_silence_seconds": args.trailing_silence_seconds,
        "cases": [asdict(result) for result in results],
        "passed": connection_preflight["ready"] is True
        and bool(results)
        and all(result.passed for result in results),
    }
    report_path = output_dir / "suite-report.json"
    report_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(report_path.read_text(encoding="utf-8"))
    return 0 if report["passed"] else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}")
        raise SystemExit(1)
