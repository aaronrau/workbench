import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'conversation_models.dart';
import 'speech_model.dart';
import 'transcription_chunking.dart';

typedef ConversationAnalysisStatusSink =
    void Function(String message, {bool isError});
typedef ConversationAnalysisResultSink =
    void Function(ConversationAnalysisResult result);
typedef ConversationAnalysisFailureSink =
    void Function(String segmentId, Object error);

final class ConversationAnalysisResult {
  const ConversationAnalysisResult({
    required this.record,
    required this.profiles,
    required this.enrollment,
    required this.audioMs,
    required this.analysisMs,
  });

  final ConversationRecord record;
  final List<SpeakerProfile> profiles;
  final bool enrollment;
  final int audioMs;
  final int analysisMs;
}

abstract interface class ConversationAnalysisWorker {
  bool get isReady;
  Future<void> start();
  void analyze({
    required String segmentId,
    required String wavPath,
    required Iterable<SpeakerProfile> profiles,
    required bool enrollment,
    double? signatureMatchThreshold,
  });
  Future<void> restartForTest();
  Future<void> dispose();
}

final class ConversationAnalysisSupervisor
    implements ConversationAnalysisWorker {
  ConversationAnalysisSupervisor({
    required this.models,
    required this.transcription,
    required this.onResult,
    required this.onFailure,
    required this.onStatus,
    // TitaNet cosine distances are tightly grouped for short VAD segments.
    // A low cut keeps alternating synthetic and live voices in separate local
    // clusters; persistent profile matching reunites repeated turns.
    this.clusteringThreshold = 0.01,
    this.signatureMatchThreshold = defaultSpeakerSignatureMatchThreshold,
  });

  final ConversationModelPaths models;
  final TranscriptionModelPaths transcription;
  final ConversationAnalysisResultSink onResult;
  final ConversationAnalysisFailureSink onFailure;
  final ConversationAnalysisStatusSink onStatus;
  final double clusteringThreshold;
  final double signatureMatchThreshold;
  final Map<String, Map<String, Object>> _pending =
      <String, Map<String, Object>>{};

  ReceivePort? _events;
  ReceivePort? _errors;
  ReceivePort? _exit;
  StreamSubscription<Object?>? _eventSubscription;
  StreamSubscription<Object?>? _errorSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  SendPort? _commands;
  Isolate? _isolate;
  Completer<void>? _ready;
  Completer<void>? _closed;
  Timer? _restartTimer;
  bool _disposed = false;
  bool _closing = false;
  int _restartAttempt = 0;

  @override
  bool get isReady => _commands != null && _isolate != null;
  int get pendingCount => _pending.length;

  @override
  Future<void> start() async {
    if (_disposed) {
      throw StateError('Conversation analysis is closed.');
    }
    if (isReady) {
      return;
    }
    await _spawnAndWaitUntilReady();
  }

  @override
  void analyze({
    required String segmentId,
    required String wavPath,
    required Iterable<SpeakerProfile> profiles,
    required bool enrollment,
    double? signatureMatchThreshold,
  }) {
    if (_disposed || !isReady) {
      return;
    }
    final job = <String, Object>{
      'type': 'analyze',
      'id': segmentId,
      'path': wavPath,
      'profiles': profiles
          .map((profile) => profile.toJson())
          .toList(growable: false),
      'enrollment': enrollment,
      'signatureMatchThreshold':
          signatureMatchThreshold ?? this.signatureMatchThreshold,
    };
    _pending[segmentId] = job;
    _commands!.send(job);
    onStatus(
      '[WorkBench][Conversation] state=queued '
      'segment=$segmentId pending=${_pending.length}',
    );
  }

  @override
  Future<void> restartForTest() async {
    if (_disposed || _isolate == null) {
      return;
    }
    onStatus('[WorkBench][Conversation] state=restarting reason=manual_test');
    _isolate!.kill(priority: Isolate.immediate);
  }

  Future<void> _spawn() async {
    _closing = false;
    _ready = Completer<void>();
    _closed = Completer<void>();
    _events = ReceivePort();
    _errors = ReceivePort();
    _exit = ReceivePort();
    _eventSubscription = _events!.listen(_handleEvent);
    _errorSubscription = _errors!.listen((Object? error) {
      if (!_disposed) {
        onStatus(
          '[WorkBench][Conversation] state=worker_error '
          'error=${_oneLine(error)}',
          isError: true,
        );
      }
    });
    _exitSubscription = _exit!.listen((Object? _) {
      _isolate = null;
      _commands = null;
      final closed = _closed;
      if (closed != null && !closed.isCompleted) {
        closed.complete();
      }
      final ready = _ready;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(
          StateError('Conversation analysis worker exited before ready.'),
        );
      }
      if (!_disposed && !_closing) {
        _scheduleRestart();
      }
    });
    final isolate = await Isolate.spawn<Map<String, Object>>(
      _conversationWorker,
      <String, Object>{
        'events': _events!.sendPort,
        'models': models.toMessage(),
        'transcription': transcription.toMessage(),
        'clusteringThreshold': clusteringThreshold,
        'signatureMatchThreshold': signatureMatchThreshold,
      },
      onError: _errors!.sendPort,
      onExit: _exit!.sendPort,
      errorsAreFatal: true,
      debugName: 'workbench-conversation-analysis',
    );
    if (_disposed || _closing) {
      isolate.kill(priority: Isolate.immediate);
      return;
    }
    _isolate = isolate;
  }

  Future<void> _spawnAndWaitUntilReady() async {
    // Listen for cancellation immediately, including while Isolate.spawn is
    // still completing, so disposal cannot leave an unhandled ready error.
    await Future.wait<void>(<Future<void>>[
      _spawn(),
      _ready!.future.timeout(const Duration(seconds: 45)),
    ]);
  }

  void _handleEvent(Object? value) {
    if (value is! Map<Object?, Object?> ||
        (_disposed && value['type'] != 'closed')) {
      return;
    }
    switch (value['type']) {
      case 'ready':
        _commands = value['port']! as SendPort;
        _restartAttempt = 0;
        final ready = _ready;
        if (ready != null && !ready.isCompleted) {
          ready.complete();
        }
        onStatus(
          '[WorkBench][Conversation] state=ready provider=cpu '
          'transcription_model=${transcription.definition.id} '
          'signature_match_threshold='
          '${signatureMatchThreshold.toStringAsFixed(2)} isolated=true',
        );
        for (final job in _pending.values) {
          _commands!.send(job);
        }
      case 'processing':
        onStatus(
          '[WorkBench][Conversation] state=processing '
          'segment=${value['id']}',
        );
      case 'completed':
        final id = value['id']! as String;
        _pending.remove(id);
        final record = ConversationRecord.fromJson(
          (value['record']! as Map<Object?, Object?>).map(
            (key, value) => MapEntry('$key', value),
          ),
        );
        final profiles = (value['profiles']! as List<Object?>)
            .whereType<Map<Object?, Object?>>()
            .map(
              (profile) => SpeakerProfile.fromJson(
                profile.map((key, value) => MapEntry('$key', value)),
              ),
            )
            .toList(growable: false);
        onStatus(
          '[WorkBench][Conversation] state=completed segment=$id '
          'speakers=${profiles.length} '
          'turns=${record.utterances.length} '
          'audio_ms=${value['audioMs']} '
          'analysis_ms=${value['analysisMs']} '
          'pending=${_pending.length}',
        );
        onResult(
          ConversationAnalysisResult(
            record: record,
            profiles: profiles,
            enrollment: value['enrollment'] == true,
            audioMs: value['audioMs']! as int,
            analysisMs: value['analysisMs']! as int,
          ),
        );
      case 'failed':
        final id = value['id']! as String;
        _pending.remove(id);
        final error = StateError('${value['error']}');
        onStatus(
          '[WorkBench][Conversation] state=failed segment=$id '
          'raw_transcription=available error=${_oneLine(error)}',
          isError: true,
        );
        onFailure(id, error);
      case 'fatal':
        final ready = _ready;
        final error = StateError('${value['error']}');
        if (ready != null && !ready.isCompleted) {
          ready.completeError(error);
        }
        onStatus(
          '[WorkBench][Conversation] state=unavailable '
          'raw_transcription=available error=${_oneLine(error)}',
          isError: true,
        );
      case 'closed':
        final closed = _closed;
        if (closed != null && !closed.isCompleted) {
          closed.complete();
        }
    }
  }

  void _scheduleRestart() {
    if (_restartTimer != null || _disposed) {
      return;
    }
    _restartAttempt++;
    final seconds = min(30, 1 << min(_restartAttempt - 1, 4));
    onStatus(
      '[WorkBench][Conversation] state=restarting '
      'attempt=$_restartAttempt delay_seconds=$seconds '
      'capture=unaffected transcription=unaffected',
      isError: true,
    );
    _restartTimer = Timer(Duration(seconds: seconds), () {
      _restartTimer = null;
      _closePorts().then((_) => _spawnAndWaitUntilReady()).catchError((
        Object error,
      ) {
        if (!_disposed) {
          onStatus(
            '[WorkBench][Conversation] state=restart_failed '
            'error=${_oneLine(error)}',
            isError: true,
          );
          _scheduleRestart();
        }
      });
    });
  }

  Future<void> _closePorts() async {
    await _eventSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _exitSubscription?.cancel();
    _eventSubscription = null;
    _errorSubscription = null;
    _exitSubscription = null;
    _events?.close();
    _errors?.close();
    _exit?.close();
    _events = null;
    _errors = null;
    _exit = null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _closing = true;
    _restartTimer?.cancel();
    _restartTimer = null;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('Conversation analysis was cancelled.'));
    }
    final commands = _commands;
    final closed = _closed;
    commands?.send(<String, Object>{'type': 'close'});
    if (commands != null && closed != null && !closed.isCompleted) {
      try {
        await closed.future.timeout(const Duration(seconds: 45));
      } on TimeoutException {
        onStatus(
          '[WorkBench][Conversation] state=close_timeout '
          'native_cleanup=forced',
          isError: true,
        );
      }
    }
    _commands = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _pending.clear();
    await _closePorts();
  }
}

void _conversationWorker(Map<String, Object> bootstrap) {
  final events = bootstrap['events']! as SendPort;
  final models = (bootstrap['models']! as Map<Object?, Object?>)
      .cast<String, Object>();
  final transcription = (bootstrap['transcription']! as Map<Object?, Object?>)
      .cast<String, Object>();
  final clusteringThreshold = bootstrap['clusteringThreshold']! as double;
  final signatureMatchThreshold =
      bootstrap['signatureMatchThreshold']! as double;
  final commands = ReceivePort();
  sherpa.OfflineSpeakerDiarization? diarizer;
  sherpa.SpeakerEmbeddingExtractor? embeddingExtractor;
  sherpa.OfflineRecognizer? recognizer;

  try {
    if (!isAdjustableSpeakerSignatureThreshold(signatureMatchThreshold)) {
      throw StateError('The speaker signature threshold is invalid.');
    }
    sherpa.initBindings();
    diarizer = sherpa.OfflineSpeakerDiarization(
      sherpa.OfflineSpeakerDiarizationConfig(
        segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
          pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
            model: models['segmentation']! as String,
          ),
          numThreads: 1,
          debug: false,
          provider: 'cpu',
        ),
        embedding: sherpa.SpeakerEmbeddingExtractorConfig(
          model: models['embedding']! as String,
          numThreads: 1,
          debug: false,
          provider: 'cpu',
        ),
        clustering: sherpa.FastClusteringConfig(
          numClusters: -1,
          threshold: clusteringThreshold,
        ),
        minDurationOn: 0.25,
        minDurationOff: 0.35,
      ),
    );
    if (diarizer.ptr == nullptr || diarizer.sampleRate != 16000) {
      throw StateError('The speaker diarization model did not initialize.');
    }
    embeddingExtractor = sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(
        model: models['embedding']! as String,
        numThreads: 1,
        debug: false,
        provider: 'cpu',
      ),
    );
    if (embeddingExtractor.ptr == nullptr || embeddingExtractor.dim <= 0) {
      throw StateError('The speaker embedding model did not initialize.');
    }
    recognizer = _createConversationRecognizer(transcription);
    _warmConversationRecognizer(recognizer);
  } catch (error) {
    recognizer?.free();
    embeddingExtractor?.free();
    diarizer?.free();
    events.send(<String, Object>{'type': 'fatal', 'error': '$error'});
    commands.close();
    return;
  }

  events.send(<String, Object>{'type': 'ready', 'port': commands.sendPort});
  commands.listen((Object? message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }
    switch (message['type']) {
      case 'analyze':
        final id = message['id']! as String;
        final path = message['path']! as String;
        final enrollment = message['enrollment'] == true;
        final jobSignatureMatchThreshold =
            (message['signatureMatchThreshold']! as num).toDouble();
        events.send(<String, Object>{'type': 'processing', 'id': id});
        try {
          if (!isAdjustableSpeakerSignatureThreshold(
            jobSignatureMatchThreshold,
          )) {
            throw StateError('The speaker signature threshold is invalid.');
          }
          final timer = Stopwatch()..start();
          final profiles = (message['profiles']! as List<Object?>)
              .whereType<Map<Object?, Object?>>()
              .map(
                (value) => SpeakerProfile.fromJson(
                  value.map((key, value) => MapEntry('$key', value)),
                ),
              )
              .toList();
          final result = _analyzeConversation(
            id: id,
            path: path,
            enrollment: enrollment,
            diarizer: diarizer!,
            embeddingExtractor: embeddingExtractor!,
            recognizer: recognizer!,
            profiles: profiles,
            signatureMatchThreshold: jobSignatureMatchThreshold,
          );
          timer.stop();
          events.send(<String, Object>{
            'type': 'completed',
            'id': id,
            'record': result.record.toJson(),
            'profiles': result.profiles
                .map((profile) => profile.toJson())
                .toList(growable: false),
            'enrollment': enrollment,
            'audioMs': result.audioMs,
            'analysisMs': timer.elapsedMilliseconds,
          });
        } catch (error) {
          events.send(<String, Object>{
            'type': 'failed',
            'id': id,
            'error': '$error',
          });
        }
      case 'close':
        recognizer?.free();
        recognizer = null;
        embeddingExtractor?.free();
        embeddingExtractor = null;
        diarizer?.free();
        diarizer = null;
        events.send(<String, Object>{'type': 'closed'});
        commands.close();
    }
  });
}

final class _WorkerAnalysisResult {
  const _WorkerAnalysisResult({
    required this.record,
    required this.profiles,
    required this.audioMs,
  });

  final ConversationRecord record;
  final List<SpeakerProfile> profiles;
  final int audioMs;
}

final class _SpeakerAssignment {
  const _SpeakerAssignment({
    required this.profile,
    required this.confidence,
    required this.signature,
  });

  final SpeakerProfile profile;
  final double confidence;
  final List<double> signature;
}

_WorkerAnalysisResult _analyzeConversation({
  required String id,
  required String path,
  required bool enrollment,
  required sherpa.OfflineSpeakerDiarization diarizer,
  required sherpa.SpeakerEmbeddingExtractor embeddingExtractor,
  required sherpa.OfflineRecognizer recognizer,
  required List<SpeakerProfile> profiles,
  required double signatureMatchThreshold,
}) {
  const maximumWindowSamples = 30 * 16000;
  profiles = retainBoundedSpeakerProfiles(profiles).toList(growable: true);
  final wave = sherpa.readWave(path);
  if (wave.sampleRate != 16000 || wave.samples.isEmpty) {
    throw StateError('Conversation analysis requires a non-empty 16 kHz WAV.');
  }
  final now = DateTime.now().toUtc();
  final utterances = <ConversationUtterance>[];
  var windowStart = 0;
  var createdSpeakers = 0;
  while (windowStart < wave.samples.length) {
    final windowEnd = min(
      wave.samples.length,
      windowStart + maximumWindowSamples,
    );
    final window = Float32List.sublistView(
      wave.samples,
      windowStart,
      windowEnd,
    );
    var segments = diarizer.process(samples: window);
    if (segments.isEmpty) {
      segments = <sherpa.OfflineSpeakerDiarizationSegment>[
        sherpa.OfflineSpeakerDiarizationSegment(
          start: 0,
          end: window.length / wave.sampleRate,
          speaker: 0,
        ),
      ];
    }
    final byLocalSpeaker =
        <int, List<sherpa.OfflineSpeakerDiarizationSegment>>{};
    for (final segment in segments) {
      if (segment.end <= segment.start) {
        continue;
      }
      byLocalSpeaker
          .putIfAbsent(
            segment.speaker,
            () => <sherpa.OfflineSpeakerDiarizationSegment>[],
          )
          .add(segment);
    }
    if (enrollment && byLocalSpeaker.length != 1) {
      throw StateError(
        'Enrollment detected more than one speaker. Try again in a quiet room.',
      );
    }
    final assignments = <int, _SpeakerAssignment>{};
    for (final entry in byLocalSpeaker.entries) {
      final signatureSamples = _signatureAudio(
        window,
        entry.value,
        sampleRate: wave.sampleRate,
      );
      final embedding = _speakerEmbedding(
        embeddingExtractor,
        signatureSamples,
        wave.sampleRate,
      );
      if (embedding.isEmpty) {
        continue;
      }
      if (enrollment) {
        final primaryIndex = profiles.indexWhere(
          (profile) => profile.isPrimary,
        );
        final primary = acceptPrimarySpeakerEnrollmentSample(
          primary: primaryIndex < 0 ? null : profiles[primaryIndex],
          candidate: embedding,
          now: now,
          signatureMatchThreshold: signatureMatchThreshold,
        );
        if (primaryIndex < 0) {
          profiles.add(primary);
        } else {
          profiles[primaryIndex] = primary;
        }
        assignments[entry.key] = _SpeakerAssignment(
          profile: primary,
          confidence: 1,
          signature: embedding,
        );
        continue;
      }
      SpeakerProfile? best;
      var bestScore = -1.0;
      var nearestKnownScore = -1.0;
      for (final profile in profiles) {
        if (!profile.calibrationComplete || profile.enrollmentInProgress) {
          continue;
        }
        final score = speakerProfileSimilarity(profile, embedding);
        nearestKnownScore = max(nearestKnownScore, score);
        final threshold = profile.isPrimary
            ? profile.signatureMatchThreshold
            : signatureMatchThreshold;
        if (speakerSignatureMatches(score, threshold: threshold) &&
            score > bestScore) {
          bestScore = score;
          best = profile;
        }
      }
      if (best == null) {
        createdSpeakers++;
        best = SpeakerProfile(
          id: 'speaker-${now.microsecondsSinceEpoch}-$createdSpeakers',
          label: nextNonPrimarySpeakerLabel(profiles),
          embedding: embedding,
          sampleCount: 1,
          createdAt: now,
          updatedAt: now,
        );
        profiles.add(best);
        profiles = retainBoundedSpeakerProfiles(
          profiles,
        ).toList(growable: true);
        bestScore = nearestKnownScore < 0 ? 0 : nearestKnownScore;
      } else if (bestScore >= speakerSignatureLearningThreshold) {
        final index = profiles.indexWhere((profile) => profile.id == best!.id);
        best = best.merge(embedding, now);
        profiles[index] = best;
      }
      assignments[entry.key] = _SpeakerAssignment(
        profile: best,
        confidence: bestScore.clamp(0, 1),
        signature: embedding,
      );
    }

    if (enrollment) {
      break;
    }
    final ordered = segments.toList()
      ..sort((left, right) => left.start.compareTo(right.start));
    for (var index = 0; index < ordered.length; index++) {
      final segment = ordered[index];
      final assignment = assignments[segment.speaker];
      if (assignment == null) {
        continue;
      }
      final startSample = (segment.start * wave.sampleRate).round().clamp(
        0,
        window.length,
      );
      final endSample = (segment.end * wave.sampleRate).round().clamp(
        startSample,
        window.length,
      );
      if (endSample - startSample < wave.sampleRate ~/ 5) {
        continue;
      }
      final text = _transcribeConversationAudio(
        recognizer,
        Float32List.sublistView(window, startSample, endSample),
        wave.sampleRate,
      );
      if (text.isEmpty) {
        continue;
      }
      final globalStartMs =
          (windowStart * 1000 ~/ wave.sampleRate) +
          (segment.start * 1000).round();
      final globalEndMs =
          (windowStart * 1000 ~/ wave.sampleRate) +
          (segment.end * 1000).round();
      final overlapsPrevious =
          utterances.isNotEmpty && globalStartMs < utterances.last.endMs;
      utterances.add(
        ConversationUtterance(
          id: '$id-${utterances.length + 1}',
          conversationId: id,
          speakerId: assignment.profile.id,
          speakerLabel: overlapsPrevious
              ? 'Overlapping speakers'
              : assignment.profile.label,
          text: text,
          startMs: globalStartMs,
          endMs: max(globalStartMs + 1, globalEndMs),
          confidence: assignment.confidence,
          updatedAt: now,
          isPrimary: !overlapsPrevious && assignment.profile.isPrimary,
          isOverlap: overlapsPrevious,
          speakerSignature: assignment.signature,
        ),
      );
    }
    windowStart = windowEnd;
  }
  if (enrollment && !profiles.any((profile) => profile.isPrimary)) {
    throw StateError(
      'Enrollment did not contain enough clear speech. Try again.',
    );
  }
  if (!enrollment && utterances.isEmpty) {
    throw StateError('No speaker-attributed conversation could be produced.');
  }
  final textPath = path.replaceFirst(
    RegExp(r'\.(?:recovered\.)?wav$'),
    '.conversation.txt',
  );
  final metadataPath = path.replaceFirst(
    RegExp(r'\.(?:recovered\.)?wav$'),
    '.conversation.json',
  );
  final record = ConversationRecord(
    id: id,
    audioPath: path,
    textPath: textPath,
    metadataPath: metadataPath,
    utterances: enrollment ? const <ConversationUtterance>[] : utterances,
    updatedAt: now,
  );
  if (!enrollment) {
    _atomicWriteText(textPath, encodeConversationText(utterances));
    _atomicWriteText(metadataPath, '${record.encode()}\n');
  }
  return _WorkerAnalysisResult(
    record: record,
    profiles: retainBoundedSpeakerProfiles(profiles),
    audioMs: wave.samples.length * 1000 ~/ wave.sampleRate,
  );
}

Float32List _signatureAudio(
  Float32List window,
  List<sherpa.OfflineSpeakerDiarizationSegment> segments, {
  required int sampleRate,
}) {
  const maximumSamples = 12 * 16000;
  const gapSamples = 1600;
  final output = BytesBuilder(copy: false);
  var samplesWritten = 0;
  final sorted = segments.toList()
    ..sort(
      (left, right) =>
          (right.end - right.start).compareTo(left.end - left.start),
    );
  for (final segment in sorted) {
    final start = (segment.start * sampleRate).round().clamp(0, window.length);
    final end = (segment.end * sampleRate).round().clamp(start, window.length);
    final available = min(end - start, maximumSamples - samplesWritten);
    if (available <= 0) {
      break;
    }
    final samples = Float32List.sublistView(window, start, start + available);
    output.add(Uint8List.sublistView(samples));
    samplesWritten += available;
    if (samplesWritten < maximumSamples) {
      final gap = Float32List(min(gapSamples, maximumSamples - samplesWritten));
      output.add(Uint8List.sublistView(gap));
      samplesWritten += gap.length;
    }
  }
  final bytes = output.takeBytes();
  return Float32List.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes ~/ Float32List.bytesPerElement,
  );
}

List<double> _speakerEmbedding(
  sherpa.SpeakerEmbeddingExtractor extractor,
  Float32List samples,
  int sampleRate,
) {
  if (samples.length < sampleRate) {
    return const <double>[];
  }
  final stream = extractor.createStream();
  try {
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    stream.inputFinished();
    return normalizeSpeakerEmbedding(
      extractor.compute(stream).map((value) => value.toDouble()).toList(),
    );
  } finally {
    stream.free();
  }
}

sherpa.OfflineRecognizer _createConversationRecognizer(
  Map<String, Object> model,
) {
  final architecture = model['architecture']! as String;
  final config = switch (architecture) {
    'nemoCtc' => sherpa.OfflineModelConfig(
      nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(
        model: model['model']! as String,
      ),
      tokens: model['tokens']! as String,
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    ),
    'transducer' => sherpa.OfflineModelConfig(
      transducer: sherpa.OfflineTransducerModelConfig(
        encoder: model['encoder']! as String,
        decoder: model['decoder']! as String,
        joiner: model['joiner']! as String,
      ),
      tokens: model['tokens']! as String,
      numThreads: 2,
      debug: false,
      provider: 'cpu',
      modelType: 'nemo_transducer',
    ),
    'whisper' => sherpa.OfflineModelConfig(
      whisper: sherpa.OfflineWhisperModelConfig(
        encoder: model['encoder']! as String,
        decoder: model['decoder']! as String,
        language: 'en',
        task: 'transcribe',
      ),
      tokens: model['tokens']! as String,
      numThreads: 2,
      debug: false,
      provider: 'cpu',
      modelType: 'whisper',
    ),
    _ => throw UnsupportedError(
      'Unsupported conversation speech model "$architecture".',
    ),
  };
  return sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(model: config),
  );
}

void _warmConversationRecognizer(sherpa.OfflineRecognizer recognizer) {
  final stream = recognizer.createStream();
  try {
    stream.acceptWaveform(samples: Float32List(16000), sampleRate: 16000);
    recognizer.decode(stream);
    recognizer.getResult(stream);
  } finally {
    stream.free();
  }
}

String _transcribeConversationAudio(
  sherpa.OfflineRecognizer recognizer,
  Float32List samples,
  int sampleRate,
) {
  final transcripts = <String>[];
  final windows = planTranscriptionWindows(
    totalSamples: samples.length,
    sampleRate: sampleRate,
  );
  for (final window in windows) {
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(
        samples: Float32List.sublistView(samples, window.start, window.end),
        sampleRate: sampleRate,
      );
      recognizer.decode(stream);
      transcripts.add(recognizer.getResult(stream).text.trim());
    } finally {
      stream.free();
    }
  }
  return mergeTranscriptionWindows(transcripts);
}

void _atomicWriteText(String path, String value) {
  final partial = File('$path.part');
  if (partial.existsSync()) {
    partial.deleteSync();
  }
  partial.writeAsStringSync(value, flush: true);
  final target = File(path);
  if (target.existsSync()) {
    target.deleteSync();
  }
  partial.renameSync(path);
}

String _oneLine(Object? value) =>
    '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
