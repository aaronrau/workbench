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
    this.onDiarizationReady,
    this.recoveryIdleDelay = const Duration(seconds: 30),
    this.workerRetryDelay = const Duration(seconds: 5),
    MossClient? client,
  }) : client = client ?? const MossClient();
  final String speechPath;
  final String modelPath;
  final TranscriptSink onTranscript;
  final TranscriptionStatusSink onStatus;
  final FutureOr<void> Function(String metadataPath)? onDiarizationReady;
  final MossClient client;
  final Duration recoveryIdleDelay;
  final Duration workerRetryDelay;
  DateTime? _workerRetryAt;
  Timer? _recoveryTimer;
  bool _inputActive = false;
  bool _recoveryAllowed = false;
  Timer? _retryTimer;
  final _attempts = <String, int>{};
  final _retryAt = <String, DateTime>{};
  final _pending = <String, String>{};
  final _live = <String>{};
  final _queuedAt = <String, DateTime>{};
  final _failed = <String>{};
  final _failureReasons = <String, String>{};
  String? _activeJobId;
  bool _disposed = false;
  bool _busy = false;
  bool _backlogReported = false;
  bool _ready = false;
  int get pendingCount => _pending.length;
  int get failedCount => _failed.length;
  int? lastDecodeMs;
  int? lastAudioMs;
  String get provider => client.provider.name;
  String get modelId => client.quantization.modelId;

  Future<void> retryHeld() async {
    if (_disposed) return;
    for (final id in _failed.toList()) {
      final marker = File('$speechPath/$id.moss-failure.json');
      if (await marker.exists()) await marker.delete();
      _failed.remove(id);
      _failureReasons.remove(id);
      _attempts.remove(id);
      _retryAt.remove(id);
      // An explicit retry is local recovery, never a delayed agent command.
      _live.remove(id);
    }
    _recoveryAllowed = true;
    unawaited(_pump());
  }

  Future<void> start() async {
    final root = Directory(speechPath);
    await root.create(recursive: true);
    final files = await root.list().toList();
    // Current and legacy capture IDs contain a timestamp. Recover recent results
    // first, rather than burying them behind a potentially long old backlog.
    // Live jobs still take priority in _pump; no durable WAV is dropped.
    int captureTime(FileSystemEntity file) =>
        int.tryParse(
          RegExp(
                r'^(?:moss_)?(\d+)',
              ).firstMatch(file.uri.pathSegments.last)?.group(1) ??
              '',
        ) ??
        0;
    files.sort((a, b) {
      final byTime = captureTime(b).compareTo(captureTime(a));
      return byTime != 0 ? byTime : b.path.compareTo(a.path);
    });
    for (final file in files) {
      if (file is File &&
          file.path.endsWith('.wav') &&
          !file.path.endsWith('.part.wav')) {
        final id = file.uri.pathSegments.last.replaceFirst('.wav', '');
        if (!await File('$speechPath/$id.raw.txt').exists()) {
          _pending[id] = file.path;
          if (await _hasHeldFailure(id)) _failed.add(id);
        }
      }
    }
    await client.prepare(modelPath);
    _ready = true;
    onStatus(
      '[WorkBench][MOSS] state=ready model=$modelId provider=$provider language=$mossTranscriptionLanguage threads=4 pending=${_pending.length}',
    );
    _reportQueue();
    if (_failed.isNotEmpty) {
      final id = _failed.first;
      onStatus(
        '[WorkBench][MOSS] state=job_preserved segment=$id '
        'reason=${_failureReasons[id] ?? 'previous_failure'} audio=preserved',
        isError: true,
      );
    }
    _scheduleRecovery();
  }

  void _reportQueue() {
    if (_disposed) return;
    final queued =
        _pending.length - _failed.length - (_activeJobId == null ? 0 : 1);
    onStatus(
      '[WorkBench][MOSS] state=queue_status queued=${queued < 0 ? 0 : queued} '
      'held=${_failed.length}',
    );
  }

  void setInputActive(bool active) {
    if (_inputActive == active || _disposed) return;
    _inputActive = active;
    _recoveryAllowed = false;
    _recoveryTimer?.cancel();
    // Keep the one in-flight decode. Killing it on reconnect wasted its work
    // and looked like a crash; the next dispatch gives live speech priority.
    _scheduleRecovery();
  }

  void _scheduleRecovery() {
    _recoveryTimer?.cancel();
    if (_disposed) return;
    _recoveryTimer = Timer(recoveryIdleDelay, () {
      _recoveryAllowed = true;
      unawaited(_pump());
    });
  }

  void transcribeSegment(VadSpeechSegment segment) {
    if (_disposed) return;
    if (_pending.containsKey(segment.id) ||
        File('$speechPath/${segment.id}.raw.txt').existsSync()) {
      return;
    }
    _pending[segment.id] = segment.wavPath;
    if (segment.endReason != VadSegmentEndReason.recovery) {
      _live.add(segment.id);
      _recoveryAllowed = false;
      _scheduleRecovery();
    }
    _queuedAt[segment.id] = DateTime.now().toUtc();
    onStatus(
      '[WorkBench][MOSS] state=queued segment=${segment.id} provider=$provider pending=${_pending.length}',
    );
    _reportQueue();
    // Every job already has a durable WAV. A slow optional recognizer must
    // never invoke the capture-failure handler or disconnect Bluetooth.
    if (_pending.length >= 128 && !_backlogReported) {
      _backlogReported = true;
      onStatus(
        '[WorkBench][MOSS] state=backlog pending=${_pending.length} audio=preserved capture=unaffected',
        isError: true,
      );
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_disposed || _busy) return;
    _busy = true;
    try {
      while (!_disposed) {
        if (_workerRetryAt?.isAfter(DateTime.now().toUtc()) ?? false) break;
        final jobs = _pending.entries.where(
          (entry) =>
              !_failed.contains(entry.key) &&
              !(_retryAt[entry.key]?.isAfter(DateTime.now().toUtc()) ?? false),
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
        var deferred = false;
        var failureReason = 'worker_error';
        do {
          try {
            if (!_ready) {
              try {
                await client.prepare(modelPath);
                _ready = true;
                _workerRetryAt = null;
              } on Object {
                // Worker availability is not evidence that this WAV is bad.
                _workerRetryAt = DateTime.now().toUtc().add(workerRetryDelay);
                deferred = true;
                onStatus(
                  '[WorkBench][MOSS] state=worker_wait audio=preserved',
                  isError: true,
                );
                break;
              }
            }
            if (!_live.contains(job.key) && !_recoveryAllowed) {
              deferred = true;
              break;
            }
            _activeJobId = job.key;
            onStatus(
              '[WorkBench][MOSS] state=processing segment=${job.key} '
              'model=$modelId provider=$provider',
            );
            _reportQueue();
            final reply = await client.transcribe(job.value);
            if (_disposed) break;
            failureReason = 'worker_contract_mismatch';
            final reportedModel = reply['model'] as String?;
            if (reportedModel != null && reportedModel != modelId) {
              throw StateError('MOSS model mismatch');
            }
            if (reply['language'] != mossTranscriptionLanguage ||
                reply['languagePolicy'] != mossLanguagePolicy) {
              throw const FormatException(
                'MOSS English policy was not verified.',
              );
            }
            if (reply['nativeAdapter'] != mossNativeAdapter) {
              throw const FormatException(
                'MOSS native adapter was not verified.',
              );
            }
            final annotated = reply['text'];
            if (annotated is! String || annotated.length > 65536) {
              throw const FormatException('Invalid MOSS output size or type.');
            }
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
            failureReason = 'unsupported_or_empty_output';
            validateMossEnglishOutput(annotated);
            failureReason = 'incomplete_speaker_timestamps';
            final utterances = parseMossTranscript(
              annotated,
              audioSeconds: audioMs / 1000,
            );
            final plain = stripMossAnnotations(
              utterances.map((entry) => entry.text).join(' '),
            );
            final decodeMs = (reply['decodeMs'] as num).toInt();
            failureReason = 'saving_failed';
            onStatus('[WorkBench][MOSS] state=saving segment=${job.key}');
            await _atomicText(
              '$speechPath/${job.key}.moss.json',
              jsonEncode({
                'model': modelId,
                'language': mossTranscriptionLanguage,
                'language_policy': mossLanguagePolicy,
                'model_sha256': client.quantization.sha256,
                'runtime_revision': mossRuntimeRevision,
                'ggml_revision': mossGgmlRevision,
                'android_api': reply['osApi'],
                'android_release': reply['osRelease'],
                'app_build': reply['appBuild'],
                'provider': provider,
                'native_adapter': mossNativeAdapter,
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
              plain,
            ); // Completion marker written last.
            _pending.remove(job.key);
            if (_pending.length < 128) _backlogReported = false;
            _queuedAt.remove(job.key);
            _attempts.remove(job.key);
            _retryAt.remove(job.key);
            final live = _live.remove(job.key);
            lastDecodeMs = decodeMs;
            lastAudioMs = audioMs;
            onStatus(
              '[WorkBench][MOSS] state=completed segment=${job.key} model=$modelId provider=$provider language=$mossTranscriptionLanguage threads=4 audio_ms=$audioMs decode_ms=$decodeMs speakers=${utterances.map((entry) => entry.speaker).toSet().length}',
            );
            if (isMossKokoroFixture(plain)) {
              onStatus(
                '[WorkBench][Transcript][FINAL] segment=${job.key} text=$plain',
              );
            }
            success = true;
            try {
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
                  routeEligible: live && plain.isNotEmpty,
                ),
              );
            } on Object {
              onStatus(
                '[WorkBench][MOSS] state=delivery_failed audio=preserved',
                isError: true,
              );
            }
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
            if (error is FormatException) {
              // Greedy generation is deterministic; rerunning malformed output
              // only occupies the live worker and cannot repair the WAV.
              onStatus(
                '[WorkBench][MOSS] state=invalid_output segment=${job.key} reason=$failureReason audio=preserved',
                isError: true,
              );
              break;
            }
            _ready = false;
            final attempt = (_attempts[job.key] ?? 0) + 1;
            _attempts[job.key] = attempt;
            if (attempt < 3) {
              deferred = true;
              _retryAt[job.key] = DateTime.now().toUtc().add(
                Duration(seconds: attempt),
              );
              onStatus(
                '[WorkBench][MOSS] state=retry_deferred segment=${job.key} attempt=$attempt audio=preserved',
                isError: true,
              );
            }
          }
        } while (false);
        if (!_disposed && !success && !deferred) {
          _failed.add(job.key);
          _failureReasons[job.key] = failureReason;
          await _holdFailure(job.key);
          _retryAt.remove(job.key);
          _live.remove(job.key);
          if (!_disposed) {
            onStatus(
              '[WorkBench][MOSS] state=job_preserved segment=${job.key} reason=$failureReason action=review_saved_audio audio=preserved',
              isError: true,
            );
          }
        }
        _activeJobId = null;
        _reportQueue();
      }
    } finally {
      _activeJobId = null;
      _busy = false;
      _retryTimer?.cancel();
      final retryTimes = _retryAt.entries
          .where((entry) => _live.contains(entry.key) || _recoveryAllowed)
          .map((entry) => entry.value)
          .toList();
      // A reconnect can pause recovery during worker backoff. Do not keep
      // waking on an expired worker deadline when no job is eligible to run.
      if (_workerRetryAt != null &&
          _pending.keys.any(
            (id) =>
                !_failed.contains(id) &&
                (_live.contains(id) || _recoveryAllowed),
          )) {
        retryTimes.add(_workerRetryAt!);
      }
      if (!_disposed && retryTimes.isNotEmpty) {
        var next = retryTimes.reduce((a, b) => a.isBefore(b) ? a : b);
        if (_workerRetryAt != null && _workerRetryAt!.isAfter(next)) {
          next = _workerRetryAt!;
        }
        final delay = next.difference(DateTime.now().toUtc());
        _retryTimer = Timer(
          delay.isNegative ? Duration.zero : delay,
          () => unawaited(_pump()),
        );
      }
    }
  }

  // Retry local WAVs held by the bridge that omitted nativeAdapter.
  // Restored jobs remain ineligible for agent routing.
  String get _failurePolicy =>
      '$modelId:$provider:$mossRuntimeRevision:$mossLanguagePolicy:$mossNativeAdapter:queue-v3';

  Future<bool> _hasHeldFailure(String id) async {
    try {
      final file = File('$speechPath/$id.moss-failure.json');
      if (!await file.exists() || await file.length() > 4096) return false;
      final data = jsonDecode(await file.readAsString());
      final wav = await File('$speechPath/$id.wav').stat();
      final held =
          data is Map &&
          data['policy'] == _failurePolicy &&
          data['bytes'] == wav.size &&
          data['modified'] == wav.modified.microsecondsSinceEpoch;
      if (held &&
          data['reason'] is String &&
          RegExp(r'^[a-z_]{1,64}$').hasMatch(data['reason'])) {
        _failureReasons[id] = data['reason'];
      }
      return held;
    } on Object {
      return false;
    }
  }

  Future<void> _holdFailure(String id) async {
    try {
      final wav = await File('$speechPath/$id.wav').stat();
      await _atomicText(
        '$speechPath/$id.moss-failure.json',
        jsonEncode({
          'policy': _failurePolicy,
          'reason': _failureReasons[id] ?? 'worker_error',
          'bytes': wav.size,
          'modified': wav.modified.microsecondsSinceEpoch,
        }),
      );
    } on Object {
      onStatus(
        '[WorkBench][MOSS] state=failure_marker_unavailable audio=preserved',
        isError: true,
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _recoveryTimer?.cancel();
    _retryTimer?.cancel();
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
