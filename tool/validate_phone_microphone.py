#!/usr/bin/env python3
"""Replay the fixed host Kokoro fixture through Work Bench's phone microphone.

Uses the G2 skill's synthesis, speaker volume, padding, markers, and scoring
helpers with a separate visible phone-microphone preflight. Evidence stays in
an explicitly supplied fresh directory outside the repository.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import statistics
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / '.agents/skills/kokoro-g2-transcription-loop/scripts/kokoro_g2_loop.py'
spec = importlib.util.spec_from_file_location('workbench_kokoro_loop', SKILL)
loop = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = loop
spec.loader.exec_module(loop)


def ui_nodes(adb: list[str]) -> list[ET.Element]:
    remote = '/data/local/tmp/workbench-microphone-ui.xml'
    for attempt in range(3):
        try:
            subprocess.run([*adb, 'shell', 'uiautomator', 'dump', '--compressed', remote],
                           capture_output=True, text=True, check=True, timeout=20)
            xml = subprocess.check_output([*adb, 'exec-out', 'cat', remote],
                                          text=True, timeout=5)
        finally:
            subprocess.run([*adb, 'shell', 'rm', '-f', remote],
                           capture_output=True, timeout=5)
        start = xml.find('<hierarchy')
        end = xml.rfind('</hierarchy>')
        if start >= 0 and end >= 0:
            return list(ET.fromstring(xml[start:end + len('</hierarchy>')]).iter('node'))
        if attempt < 2:
            time.sleep(0.5)
    raise RuntimeError('Android UI hierarchy unavailable')



def find_control(nodes, label):
    return next((node for node in nodes
                 if label in (node.get('text'), node.get('content-desc'))), None)


def tap(adb, node):
    if node is None or node.get('enabled') != 'true':
        raise RuntimeError('Required visible control is unavailable')
    bounds = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
    if len(bounds) != 4:
        raise RuntimeError('Control bounds unavailable')
    subprocess.run([*adb, 'shell', 'input', 'tap',
                    str((bounds[0] + bounds[2]) // 2),
                    str((bounds[1] + bounds[3]) // 2)], check=True)


def foreground(adb):
    subprocess.run([*adb, 'shell', 'am', 'start', '-n',
                    f'{loop.APP_PACKAGE}/.MainActivity'],
                   capture_output=True, check=True)


def microphone_preflight(adb, timeout=90):
    foreground(adb)
    deadline = time.monotonic() + timeout
    requested = False
    while time.monotonic() < deadline:
        nodes = ui_nodes(adb)
        stop = find_control(nodes, 'Stop microphone')
        if stop is not None and stop.get('enabled') == 'true':
            if requested:
                return {'ready': True, 'source': 'phone_microphone',
                        'visible_control': 'Stop microphone'}
            tap(adb, stop)
        else:
            disconnect = find_control(nodes, 'Disconnect')
            start = find_control(nodes, 'Start microphone')
            if disconnect is not None and disconnect.get('enabled') == 'true':
                tap(adb, disconnect)
            elif start is not None and start.get('enabled') == 'true':
                tap(adb, start)
                requested = True
            else:
                permission = next((n for n in nodes if n.get('resource-id', '').endswith(
                    ':id/permission_allow_foreground_only_button')), None)
                if permission is not None:
                    tap(adb, permission)
        time.sleep(0.5)
    raise RuntimeError('Phone microphone preflight failed; no speaker playback started')


def run(args):
    output = Path(args.output_dir).resolve()
    if output == ROOT or ROOT in output.parents:
        raise ValueError('Audio evidence must stay outside the repository')
    loop.prepare_artifact_directory(output)
    adb = [loop.select_adb(None), '-s', args.serial]
    stimulus = output / 'stimulus.wav'
    report = {'passed': False, 'expected': loop.DEFAULT_TEXT,
              'source': 'phone_microphone', 'checks': {}}
    previous_tags = {}
    log_process = None
    log_handle = None
    previous_volume = None
    wpctl = None
    try:
        loop.synthesize(loop.DEFAULT_TEXT, stimulus, 0, 1.0)
        normalized, normalization = loop.peak_normalized_wav_copy(stimulus, output)
        playback = loop.playback_copy(normalized, output,
            leading_silence_seconds=1.0, trailing_silence_seconds=0.5)
        report['test_fixture'] = {
            'speaker_name': 'af_maple', 'computer_volume': 0.9,
            'playback_path': 'computer_speaker', 'normalization': normalization,
            'stimulus': loop.wav_manifest(stimulus), 'playback': loop.wav_manifest(playback),
        }
        for tag in ('log.tag.WorkBenchTest', 'log.tag.flutter', 'log.tag.WorkBench'):
            previous_tags[tag] = loop.get_android_property(adb, tag)
            loop.set_android_property(adb, tag, 'V')
        subprocess.run([*adb, 'logcat', '-c'], check=True)
        log_handle = (output / 'device.log').open('w')
        log_process = subprocess.Popen([*adb, 'logcat', '-v', 'time'],
                                       stdout=log_handle, stderr=subprocess.STDOUT)
        report['preflight'] = microphone_preflight(adb)
        deadline = time.monotonic() + 15
        while True:
            log = (output / 'device.log').read_text(errors='replace')
            fresh = log.rsplit('[WorkBench][Capture] state=ready journal=writable', 1)[-1]
            if fresh.count('[WorkBench][PCM] rms=') >= 2:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('No fresh phone PCM; speaker playback refused')
            time.sleep(0.5)
        if args.background:
            subprocess.run([*adb, 'shell', 'input', 'keyevent', 'KEYCODE_HOME'], check=True)
        wpctl = loop.require_tool('wpctl')
        previous_volume = loop.get_computer_volume(wpctl)
        loop.set_computer_volume(wpctl, 0.9)
        time.sleep(4)
        loop.emit_android_test_marker(adb, 'playback_start', 'phone_microphone')
        try:
            subprocess.run([loop.require_tool('pw-play'), str(playback)], check=True)
        finally:
            loop.emit_android_test_marker(adb, 'playback_end', 'phone_microphone')
        # Wait for primary completion; no model or queue is restarted by this runner.
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            log = (output / 'device.log').read_text(errors='replace')
            after = log.split(loop.playback_marker('playback_start', 'phone_microphone'))[-1]
            # The shared expression uses $; match individual log lines.
            if any(loop.TRANSCRIPT_RE.search(line) for line in after.splitlines()):
                break
            time.sleep(1)
        foreground(adb)
        tap(adb, find_control(ui_nodes(adb), 'Stop microphone'))
        time.sleep(3)
        nodes = ui_nodes(adb)
        start = find_control(nodes, 'Start microphone')
        connect = find_control(nodes, 'Connect devices')
        log = (output / 'device.log').read_text(errors='replace')
        start_marker = loop.playback_marker('playback_start', 'phone_microphone')
        end_marker = loop.playback_marker('playback_end', 'phone_microphone')
        before, _, after = log.partition(start_marker)
        matches = [loop.TRANSCRIPT_RE.search(line) for line in after.splitlines()]
        transcript = ' '.join(m.group('text') for m in matches if m)
        pcm_re = re.compile(r'\[WorkBench\]\[PCM\] rms=([\d.]+) peak=\d+ samples=(\d+)')
        baseline = [float(m[0]) for m in pcm_re.findall(before)]
        levels = [float(m[0]) for m in pcm_re.findall(after)]
        sample_counts = [int(m[1]) for m in pcm_re.findall(after)]
        segments = re.findall(r'\[WorkBench\]\[Transcription\] state=completed segment=(\S+)', after)
        manifests = []
        for segment in dict.fromkeys(segments):
            if not re.fullmatch(r'[A-Za-z0-9._-]+', segment):
                raise RuntimeError('Invalid segment ID')
            target = output / f'{segment}.wav'
            with target.open('wb') as sink:
                subprocess.run([*adb, 'exec-out', 'run-as', loop.APP_PACKAGE, 'cat',
                    f'files/workbench/audio/speech/{segment}.wav'], stdout=sink, check=True)
            manifests.append(loop.wav_manifest(target))
        report.update(transcript=transcript, word_error_rate=loop.word_error_rate(loop.DEFAULT_TEXT, transcript),
                      baseline_rms=statistics.median(baseline) if baseline else None,
                      peak_rms=max(levels) if levels else None, captured_wavs=manifests)
        report['checks'] = {
            'playback_boundaries': start_marker in log and end_marker in log,
            'activity_rise': bool(baseline and levels and max(levels) > max(50, statistics.median(baseline) * 2)),
            'pcm_rate': bool(sample_counts and 15000 <= statistics.median(sample_counts) <= 20000),
            'transcript': bool(transcript) and report['word_error_rate'] <= 0.25,
            'durable_wav_format': bool(manifests) and all(m['sample_rate_hz'] == 16000 and
                m['channels'] == 1 and m['sample_width_bytes'] == 2 for m in manifests),
            'capture_safety': not loop.CAPTURE_FAILURE_RE.search(after) and '[Microphone] state=failed' not in after,
            'worker_recovery': not loop.TRANSCRIPTION_RESTART_RE.search(after) or
                bool(loop.TRANSCRIPTION_RECOVERED_RE.search(after)),
            'no_crash': not re.search(r'FATAL EXCEPTION|Fatal signal|ANR in ' + re.escape(loop.APP_PACKAGE), after),
            'vad_stt_order': bool(re.search(r'state=speech_started.*state=queued.*state=completed', after, re.S)),
            'stop_releases_input': start is not None and start.get('enabled') == 'true' and
                connect is not None and connect.get('enabled') == 'true',
        }
        report['passed'] = all(report['checks'].values())
    except Exception as error:
        report['error'] = str(error)
    finally:
        def cleanup(operation):
            try:
                operation()
            except Exception as error:
                report.setdefault('cleanup_errors', []).append(type(error).__name__)
                report['passed'] = False

        if wpctl is not None and previous_volume is not None:
            cleanup(lambda: loop.set_computer_volume(wpctl, previous_volume))
        # Always use the visible toggle to stop recording after a failed trial.
        def stop_visible_microphone():
            foreground(adb)
            stop = find_control(ui_nodes(adb), 'Stop microphone')
            if stop is not None and stop.get('enabled') == 'true':
                tap(adb, stop)
        cleanup(stop_visible_microphone)
        if log_process is not None:
            log_process.terminate()
            cleanup(lambda: log_process.wait(timeout=5))
        if log_handle is not None:
            log_handle.close()
        for tag, value in previous_tags.items():
            cleanup(lambda: loop.set_android_property(adb, tag, value))
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: report.get(k) for k in ('passed', 'checks', 'word_error_rate', 'error')}, indent=2))
    return 0 if report['passed'] else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--background', action='store_true')
    sys.exit(run(parser.parse_args()))
