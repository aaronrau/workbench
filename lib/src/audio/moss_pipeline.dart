import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'moss_audio.dart';
import 'transcription_worker.dart';
import 'vad_worker.dart';

/// Durable WAVs are the queue. Each worker restart can finish files, but a job
/// discovered on disk can never send an agent command.
final class MossPipeline {
  MossPipeline({
    required this.speechPath,
    required this.modelPath,
    required this.onTranscript,
    required this.onStatus,
    required this.onUnsafe,
    this.onDiarizationReady,
    this.recoveryIdleDelay = const Duration(seconds: 30),
    MossClient? client,
  }) : client = client ?? const MossClient();
  final String speechPath;
  final String modelPath;
  final TranscriptSink onTranscript;
  final TranscriptionStatusSink onStatus;
  final void Function() onUnsafe;
  final FutureOr<void> Function(String metadataPath)? onDiarizationReady;
  final MossClient client;
  final Duration recoveryIdleDelay;
  Timer? _recoveryTimer;
  bool _inputActive = false;
  bool _recoveryAllowed = false;
  bool _decodingRecoveredJob = false;
  Future<void>? _workerRelease;
  final _pending = <String, String>{};
  final _live = <String>{};
  final _queuedAt = <String, DateTime>{};
  final _failed = <String>{};
  bool _disposed = false;
  bool _busy = false;
  bool _ready = false;
  int get pendingCount => _pending.length;
  int get failedCount => _failed.length;
  int? lastDecodeMs;
  int? lastAudioMs;
  String get provider => client.provider.name;
  String get modelId => client.quantization.modelId;

  Future<void> start() async {
    final root = Directory(speechPath);
    await root.create(recursive: true);
    await for (final file in root.list()) {
      if (file is File &&
          file.path.endsWith('.wav') &&
          !file.path.endsWith('.part.wav')) {
        final id = file.uri.pathSegments.last.replaceFirst('.wav', '');
        if (!await File('$speechPath/$id.raw.txt').exists()) {
          _pending[id] = file.path;
        }
      }
    }
    await client.prepare(modelPath);
    _ready = true;
    onStatus(
      '[WorkBench][MOSS] state=ready model=$modelId provider=$provider threads=4 pending=${_pending.length}',
    );
    _scheduleRecovery();
  }

  void setInputActive(bool active) {
    if (_inputActive == active || _disposed) return;
    _inputActive = active;
    _recoveryAllowed = false;
    _recoveryTimer?.cancel();
    if (active && _decodingRecoveredJob) {
      // Cancel only restored inference. Its durable WAV stays queued, while
      // capture/VAD and live jobs remain independent of this worker process.
      _ready = false;
      _workerRelease = client.close().catchError((Object _) {});
    }
    if (!active) _scheduleRecovery();
  }

  void _scheduleRecovery() {
    _recoveryTimer?.cancel();
    if (_disposed || _inputActive) return;
    _recoveryTimer = Timer(recoveryIdleDelay, () {
      _recoveryAllowed = true;
      unawaited(_pump());
    });
  }

  void transcribeSegment(VadSpeechSegment segment) {
    if (_disposed) return;
    _pending[segment.id] = segment.wavPath;
    if (segment.endReason != VadSegmentEndReason.recovery) {
      _live.add(segment.id);
    }
    _queuedAt[segment.id] = DateTime.now().toUtc();
    onStatus(
      '[WorkBench][MOSS] state=queued segment=${segment.id} provider=$provider pending=${_pending.length}',
    );
    if (_pending.length >= 128) onUnsafe();
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_disposed || _busy) return;
    _busy = true;
    try {
      while (!_disposed) {
        final jobs = _pending.entries.where(
          (entry) => !_failed.contains(entry.key),
        );
        if (jobs.isEmpty) break;
        // A recovered backlog may finish locally without delaying newly
        // captured speech behind every older file. The active decode is serial.
        final job = jobs.firstWhere(
          (entry) => _live.contains(entry.key),
          orElse: () => jobs.first,
        );
        if (!_live.contains(job.key) && !_recoveryAllowed) break;
        final queued = _queuedAt[job.key] ?? DateTime.now().toUtc();
        var success = false;
        var recoveryInterrupted = false;
        for (var attempt = 0; attempt < 3 && !_disposed; attempt++) {
          try {
            await _workerRelease;
            if (!_ready) {
              await client.prepare(modelPath);
              _ready = true;
            }
            if (!_live.contains(job.key) && !_recoveryAllowed) {
              recoveryInterrupted = true;
              break;
            }
            late Map<String, dynamic> reply;
            _decodingRecoveredJob = !_live.contains(job.key);
            try {
              reply = await client.transcribe(job.value);
            } finally {
              _decodingRecoveredJob = false;
            }
            if (_disposed) break;
            final reportedModel = reply['model'] as String?;
            if (reportedModel != null && reportedModel != modelId) {
              throw StateError('MOSS model mismatch');
            }
            final annotated = reply['text'] as String;
            final actual = reply['provider'] as String? ?? provider;
            if (actual != provider) throw StateError('MOSS provider mismatch');
            final profile = (reply['profile'] as List<Object?>?)?.cast<num>();
            if (provider == 'opencl' &&
                (profile == null ||
                    profile.length != 5 ||
                    profile[1] <= 0 ||
                    profile[2] != 0 ||
                    profile[3] <= 0 ||
                    profile[4] <= 0)) {
              throw StateError('MOSS GPU execution was not verified');
            }
            final audioMs =
                ((await File(job.value).length()) - 44) * 1000 ~/ 32000;
            await _atomicText('$speechPath/${job.key}.moss.txt', annotated);
            final utterances = parseMossTranscript(
              annotated,
              audioSeconds: audioMs / 1000,
            );
            final plain = utterances.map((entry) => entry.text).join(' ');
            final decodeMs = (reply['decodeMs'] as num).toInt();
            await _atomicText(
              '$speechPath/${job.key}.moss.json',
              jsonEncode({
                'model': modelId,
                'model_sha256': client.quantization.sha256,
                'runtime_revision': mossRuntimeRevision,
                'ggml_revision': mossGgmlRevision,
                'android_api': reply['osApi'],
                'android_release': reply['osRelease'],
                'app_build': reply['appBuild'],
                'provider': provider,
                'native_adapter': 'strict-provider-1',
                if (profile != null)
                  'execution_profile': {
                    'graphs': profile[0],
                    'gpu_nodes': profile[1],
                    'cpu_nodes': profile[2],
                    'gpu_ns': profile[3],
                    'gpu_queries': profile[4],
                  },
                'threads': 4,
                'audio_ms': audioMs,
                'decode_ms': decodeMs,
                'speaker_scope': job.key,
                'utterances': utterances
                    .map((entry) => entry.toJson())
                    .toList(),
              }),
            );
            final rawPath = '$speechPath/${job.key}.raw.txt';
            await _atomicText(
              rawPath,
              annotated,
            ); // Completion marker written last.
            _pending.remove(job.key);
            _queuedAt.remove(job.key);
            final live = _live.remove(job.key);
            lastDecodeMs = decodeMs;
            lastAudioMs = audioMs;
            onStatus(
              '[WorkBench][MOSS] state=completed segment=${job.key} model=$modelId provider=$provider threads=4 audio_ms=$audioMs decode_ms=$decodeMs speakers=${utterances.map((entry) => entry.speaker).toSet().length}',
            );
            if (isMossKokoroFixture(plain)) {
              onStatus(
                '[WorkBench][Transcript][FINAL] segment=${job.key} text=$plain',
              );
            }
            onTranscript(
              TranscriptionResult(
                segmentId: job.key,
                text: plain,
                transcriptPath: rawPath,
                model: modelId,
                provider: provider,
                audioMs: audioMs,
                decodeMs: decodeMs,
                totalMs: DateTime.now()
                    .toUtc()
                    .difference(queued)
                    .inMilliseconds,
                queuedAt: queued,
                routeEligible: live,
              ),
            );
            success = true;
            final handoff = onDiarizationReady;
            if (handoff != null) {
              // Primary delivery is dispatched first. Optional history work
              // cannot occupy the inference queue or make this job retry.
              unawaited(
                Future<void>(() async {
                  await handoff('$speechPath/${job.key}.moss.json');
                }).catchError((Object _) {
                  if (!_disposed) {
                    onStatus(
                      '[WorkBench][Conversation] state=handoff_deferred source=moss',
                      isError: true,
                    );
                  }
                }),
              );
            }
            break;
          } on Object catch (error) {
            if (_disposed) break;
            if (!_live.contains(job.key) && !_recoveryAllowed) {
              _ready = false;
              recoveryInterrupted = true;
              break;
            }
            if (error is FormatException) {
              // Greedy generation is deterministic; rerunning malformed output
              // only occupies the live worker and cannot repair the WAV.
              onStatus(
                '[WorkBench][MOSS] state=invalid_output segment=${job.key} audio=preserved',
                isError: true,
              );
              break;
            }
            _ready = false;
            onStatus(
              '[WorkBench][MOSS] state=retry segment=${job.key} attempt=${attempt + 1} audio=preserved',
              isError: true,
            );
            if (!_disposed) {
              await Future<void>.delayed(Duration(seconds: attempt + 1));
            }
          }
        }
        if (!success && !recoveryInterrupted) {
          _failed.add(job.key);
          _live.remove(job.key);
          if (!_disposed) {
            onStatus(
              '[WorkBench][MOSS] state=job_preserved segment=${job.key} action=reload_moss audio=preserved',
              isError: true,
            );
          }
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _recoveryTimer?.cancel();
    await client.close();
  }

  static Future<void> _atomicText(String path, String text) =>
      _atomicBytes(path, Uint8List.fromList(utf8.encode(text)));
  static Future<void> _atomicBytes(String path, Uint8List bytes) async {
    final partial = File('$path.part');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(path);
  }
}
