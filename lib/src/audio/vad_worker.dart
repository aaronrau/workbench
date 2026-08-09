import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'nnapi_attestation.dart';

typedef VadStatusSink = void Function(String message, {bool isError});
typedef SpeechSegmentSink = void Function(VadSpeechSegment segment);
typedef VadSpeechEventSink = void Function(VadSpeechEvent event);

enum VadSpeechEventType { started, ended }

/// The two product flows intentionally use different VAD-inactive endpoints.
enum VadEndpointMode { defaultFlow, selectedAgent }

final class VadSpeechEvent {
  const VadSpeechEvent({
    required this.type,
    required this.segmentId,
    this.endpointAudioMs = 0,
  });

  final VadSpeechEventType type;
  final String segmentId;
  final int endpointAudioMs;
}

const Duration vadPreRollDuration = Duration(seconds: 2);
const Duration vadDetectorSilenceDuration = Duration(milliseconds: 500);
const Duration defaultVadEndpointDelay = Duration(milliseconds: 1500);
const Duration selectedAgentVadEndpointDelay = Duration(seconds: 1);
const Duration defaultVadTotalSilenceDuration = Duration(seconds: 2);
const Duration selectedAgentVadTotalSilenceDuration = Duration(
  milliseconds: 1500,
);
const Duration preferredVadSegmentDuration = Duration(seconds: 15);
const Duration maximumVadSegmentDuration = Duration(seconds: 17);
const Duration vadRolloverOverlapDuration = Duration(seconds: 1);
const Duration vadWordBoundaryQuietDuration = Duration(milliseconds: 75);

Duration vadEndpointDelayForMode(VadEndpointMode mode) => switch (mode) {
  VadEndpointMode.defaultFlow => defaultVadEndpointDelay,
  VadEndpointMode.selectedAgent => selectedAgentVadEndpointDelay,
};

enum VadSegmentEndReason {
  silence,
  durationLimit,
  durationPause,
  durationWordBoundary,
  durationHardLimit,
  flush,
  close,
  recovery,
}

final class VadSpeechSegment {
  const VadSpeechSegment({
    required this.id,
    required this.wavPath,
    required this.conversationId,
    required this.isConversationFinal,
    required this.endReason,
    this.leadingOverlapMs = 0,
  });

  final String id;
  final String wavPath;
  final String conversationId;
  final bool isConversationFinal;
  final VadSegmentEndReason endReason;
  final int leadingOverlapMs;
}

final class VadSegmentDurationTracker {
  VadSegmentDurationTracker({
    required int sampleRate,
    this.preferredDuration = preferredVadSegmentDuration,
    this.maximumDuration = maximumVadSegmentDuration,
  }) : assert(sampleRate > 0),
       assert(preferredDuration > Duration.zero),
       assert(maximumDuration > Duration.zero),
       assert(maximumDuration >= preferredDuration),
       _preferredSamples =
           sampleRate *
           preferredDuration.inMilliseconds ~/
           Duration.millisecondsPerSecond,
       _maximumSamples =
           sampleRate *
           maximumDuration.inMilliseconds ~/
           Duration.millisecondsPerSecond;

  final Duration preferredDuration;
  final Duration maximumDuration;
  final int _preferredSamples;
  final int _maximumSamples;
  int _samples = 0;

  int get samples => _samples;
  bool get shouldPreferVadPause => _samples >= _preferredSamples;
  bool get reachedHardLimit => _samples >= _maximumSamples;

  bool willPreferVadPause(int incomingSamples) =>
      _samples + incomingSamples >= _preferredSamples;

  bool shouldSplitAtVadResume({
    required bool detected,
    required bool endpointActive,
    int incomingSamples = 0,
  }) => detected && endpointActive && willPreferVadPause(incomingSamples);

  bool add(int samples) {
    assert(samples >= 0);
    _samples += samples;
    return reachedHardLimit;
  }

  void reset() {
    _samples = 0;
  }
}

/// Finds a short low-energy gap followed by resumed audio. Silero deliberately
/// waits for a longer pause before lowering its VAD state, so this detector is
/// used only after the soft duration target to select an inter-word boundary.
final class VadWordBoundaryDetector {
  VadWordBoundaryDetector({
    required int sampleRate,
    this.quietDuration = vadWordBoundaryQuietDuration,
    this.absoluteQuietRms = 650,
    this.quietToSpeechRatio = 0.35,
  }) : assert(sampleRate > 0),
       assert(quietDuration > Duration.zero),
       assert(absoluteQuietRms > 0),
       assert(quietToSpeechRatio > 0 && quietToSpeechRatio < 1),
       _quietSamplesRequired =
           sampleRate *
           quietDuration.inMilliseconds ~/
           Duration.millisecondsPerSecond;

  final Duration quietDuration;
  final double absoluteQuietRms;
  final double quietToSpeechRatio;
  final int _quietSamplesRequired;
  double _speechRms = 0;
  int _quietSamples = 0;

  bool observe(Uint8List pcm16, {required bool seekBoundary}) {
    final sampleCount = pcm16.length ~/ 2;
    if (sampleCount == 0) {
      return false;
    }
    final rms = _pcm16Rms(pcm16);
    final quietThreshold = max(
      absoluteQuietRms,
      _speechRms * quietToSpeechRatio,
    );
    final isQuiet = _speechRms > 0 && rms <= quietThreshold;
    if (!seekBoundary) {
      _quietSamples = 0;
      if (!isQuiet) {
        _updateSpeechRms(rms);
      }
      return false;
    }
    if (isQuiet) {
      _quietSamples += sampleCount;
      return false;
    }
    final foundBoundary = _quietSamples >= _quietSamplesRequired;
    _quietSamples = 0;
    _updateSpeechRms(rms);
    return foundBoundary;
  }

  void reset() {
    _speechRms = 0;
    _quietSamples = 0;
  }

  void _updateSpeechRms(double rms) {
    _speechRms = _speechRms == 0 ? rms : (_speechRms * 0.9) + (rms * 0.1);
  }
}

final class VadEndpointBuffer {
  VadEndpointBuffer({required int sampleRate, required Duration duration})
    : assert(sampleRate > 0),
      assert(duration > Duration.zero),
      _sampleRate = sampleRate,
      _targetSamples =
          sampleRate *
          duration.inMilliseconds ~/
          Duration.millisecondsPerSecond;

  final int _sampleRate;
  final int _targetSamples;
  int _remainingSamples = -1;
  int _capturedSamples = 0;

  bool get isActive => _remainingSamples >= 0;
  int get capturedMilliseconds =>
      _capturedSamples * Duration.millisecondsPerSecond ~/ _sampleRate;

  bool begin(int chunkSamples) {
    assert(chunkSamples >= 0);
    _capturedSamples = chunkSamples;
    _remainingSamples = _targetSamples - chunkSamples;
    return _remainingSamples <= 0;
  }

  bool add(int chunkSamples) {
    assert(chunkSamples >= 0);
    if (!isActive) {
      return false;
    }
    _capturedSamples += chunkSamples;
    _remainingSamples -= chunkSamples;
    return _remainingSamples <= 0;
  }

  void reset() {
    _remainingSamples = -1;
    _capturedSamples = 0;
  }
}

final class VadPreRollBuffer {
  VadPreRollBuffer({required this.maximumBytes}) : assert(maximumBytes > 0);

  final int maximumBytes;
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _sizeBytes = 0;

  Iterable<Uint8List> get chunks => _chunks;
  int get sizeBytes => _sizeBytes;

  void add(Uint8List pcm) {
    final stable = Uint8List.fromList(pcm);
    _chunks.addLast(stable);
    _sizeBytes += stable.length;
    while (_sizeBytes > maximumBytes && _chunks.isNotEmpty) {
      _sizeBytes -= _chunks.removeFirst().length;
    }
  }

  int clear() {
    final clearedBytes = _sizeBytes;
    _chunks.clear();
    _sizeBytes = 0;
    return clearedBytes;
  }
}

final class VadSupervisor {
  VadSupervisor({
    required this.modelPath,
    required this.outputPath,
    required this.providers,
    required this.onSegment,
    required this.onStatus,
    this.onSpeechEvent,
    VadEndpointMode endpointMode = VadEndpointMode.defaultFlow,
  }) : _endpointMode = endpointMode;

  final String modelPath;
  final String outputPath;
  final List<String> providers;
  final SpeechSegmentSink onSegment;
  final VadStatusSink onStatus;
  final VadSpeechEventSink? onSpeechEvent;
  VadEndpointMode _endpointMode;

  ReceivePort? _events;
  ReceivePort? _errors;
  ReceivePort? _exit;
  StreamSubscription<Object?>? _eventSubscription;
  StreamSubscription<Object?>? _errorSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  SendPort? _commands;
  Isolate? _isolate;
  Completer<String>? _ready;
  Completer<void>? _closed;
  Timer? _restartTimer;
  final Map<int, Completer<void>> _flushRequests = <int, Completer<void>>{};
  int _nextFlushRequestId = 0;
  bool _disposed = false;
  bool _restarting = false;
  String? activeProvider;

  bool get isReady => _commands != null && (_ready?.isCompleted ?? false);

  Future<String> start() async {
    await Directory(outputPath).create(recursive: true);
    await _spawn();
    return _ready!.future.timeout(const Duration(seconds: 20));
  }

  void acceptPcm(Uint8List pcm16) {
    if (_disposed || pcm16.isEmpty) {
      return;
    }
    _commands?.send(<String, Object>{
      'type': 'pcm',
      'bytes': TransferableTypedData.fromList(<Uint8List>[pcm16]),
    });
  }

  void flush() {
    _commands?.send(<String, Object>{'type': 'flush'});
  }

  /// Flushes the current VAD segment and resolves after its segment event has
  /// been delivered. STT may still be processing the resulting durable WAV.
  Future<void> flushAndWait() {
    final commands = _commands;
    if (_disposed || commands == null) {
      return Future<void>.value();
    }
    final requestId = ++_nextFlushRequestId;
    final completion = Completer<void>();
    _flushRequests[requestId] = completion;
    commands.send(<String, Object>{'type': 'flush', 'requestId': requestId});
    return completion.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _flushRequests.remove(requestId);
        throw TimeoutException('VAD flush acknowledgement timed out.');
      },
    );
  }

  /// Selects the product flow and its quiet interval after VAD falls inactive.
  /// An active endpoint keeps the duration it started with; the new mode
  /// applies at the next quiet transition so a UI change cannot shorten a turn
  /// mid-tail.
  void setEndpointMode(VadEndpointMode mode) {
    if (_disposed || mode == _endpointMode) {
      return;
    }
    _endpointMode = mode;
    final duration = vadEndpointDelayForMode(mode);
    _commands?.send(<String, Object>{
      'type': 'set_endpoint_mode',
      'mode': mode.name,
      'delayMs': duration.inMilliseconds,
    });
  }

  Future<void> restartForTest() async {
    if (_disposed || _isolate == null) {
      return;
    }
    onStatus('[WorkBench][VAD] state=restarting reason=diagnostic');
    _isolate!.kill(priority: Isolate.immediate);
  }

  Future<void> _spawn() async {
    _commands = null;
    activeProvider = null;
    _ready = Completer<String>();
    _closed = Completer<void>();
    _events = ReceivePort();
    _errors = ReceivePort();
    _exit = ReceivePort();
    _eventSubscription = _events!.listen(_handleEvent);
    _errorSubscription = _errors!.listen((Object? error) {
      onStatus(
        '[WorkBench][VAD] state=failed error=${_oneLine(error)}',
        isError: true,
      );
    });
    _exitSubscription = _exit!.listen((_) {
      _commands = null;
      _isolate = null;
      final closed = _closed;
      if (closed != null && !closed.isCompleted) {
        closed.complete();
      }
      if (!_disposed) {
        _scheduleRestart();
      }
    });
    _isolate = await Isolate.spawn<Map<String, Object>>(
      _vadWorker,
      <String, Object>{
        'events': _events!.sendPort,
        'modelPath': modelPath,
        'outputPath': outputPath,
        'providers': providers,
        'endpointDelayMs': vadEndpointDelayForMode(
          _endpointMode,
        ).inMilliseconds,
      },
      debugName: 'workbench-vad',
      errorsAreFatal: true,
      onError: _errors!.sendPort,
      onExit: _exit!.sendPort,
    );
  }

  void _handleEvent(Object? event) {
    if (event is! Map<Object?, Object?>) {
      return;
    }
    switch (event['type']) {
      case 'commands':
        _commands = event['port']! as SendPort;
        return;
      case 'provider_attempt':
        onStatus(
          '[WorkBench][VAD] state=loading provider=${event['provider']}',
        );
        return;
      case 'provider_failed':
        onStatus(
          '[WorkBench][VAD] state=provider_failed '
          'provider=${event['provider']} '
          'error=${_oneLine(event['error'])}',
        );
        return;
      case 'provider_attested':
        onStatus(
          '[WorkBench][Inference] state=attested workload=vad '
          'provider=nnapi nnapi_nodes=${event['nnapiNodes']} '
          'cpu_nodes=${event['cpuNodes']} '
          'other_nodes=${event['otherNodes']} '
          'nnapi_us=${event['nnapiMicros']} '
          'cpu_us=${event['cpuMicros']}',
        );
        return;
      case 'ready':
        activeProvider = event['provider']! as String;
        final recovered = _restarting;
        _restarting = false;
        onStatus(
          '[WorkBench][VAD] state=ready provider=$activeProvider '
          'recovered=$recovered',
        );
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.complete(activeProvider);
        }
        return;
      case 'speech_started':
        final id = event['id']! as String;
        onStatus(
          '[WorkBench][VAD] state=speech_started segment=$id '
          'pre_roll_ms=${event['preRollMs']} '
          'pre_roll_bytes=${event['preRollBytes']}',
        );
        onSpeechEvent?.call(
          VadSpeechEvent(type: VadSpeechEventType.started, segmentId: id),
        );
        return;
      case 'speech_continued':
        final id = event['id']! as String;
        onStatus(
          '[WorkBench][VAD] state=speech_continued segment=$id '
          'reason=${event['reason']} overlap_ms=${event['overlapMs']}',
        );
        onSpeechEvent?.call(
          VadSpeechEvent(type: VadSpeechEventType.started, segmentId: id),
        );
        return;
      case 'speech_ending':
        onStatus(
          '[WorkBench][VAD] state=speech_ending segment=${event['id']} '
          'delay_ms=${event['delayMs']}',
        );
        return;
      case 'buffer_cleared':
        onStatus(
          '[WorkBench][VAD] state=buffer_cleared segment=${event['id']} '
          'bytes=${event['bytes']} next=ready',
        );
        return;
      case 'segment':
        final id = event['id']! as String;
        final endpointAudioMs = event['endpointAudioMs']! as int;
        final isConversationFinal = event['isConversationFinal']! as bool;
        final endReason = VadSegmentEndReason.values.byName(
          event['endReason']! as String,
        );
        if (isConversationFinal) {
          onStatus(
            '[WorkBench][VAD] state=speech_ended segment=$id '
            'audio_ms=$endpointAudioMs reason=${endReason.name}',
          );
          onSpeechEvent?.call(
            VadSpeechEvent(
              type: VadSpeechEventType.ended,
              segmentId: id,
              endpointAudioMs: endpointAudioMs,
            ),
          );
        } else {
          onStatus(
            '[WorkBench][VAD] state=speech_chunked segment=$id '
            'reason=${endReason.name} continuation=true',
          );
        }
        onSegment(
          VadSpeechSegment(
            id: id,
            wavPath: event['path']! as String,
            conversationId: event['conversationId']! as String,
            isConversationFinal: isConversationFinal,
            endReason: endReason,
            leadingOverlapMs: (event['leadingOverlapMs'] as int?) ?? 0,
          ),
        );
        return;
      case 'flush_completed':
        final requestId = event['requestId'];
        if (requestId is int) {
          _flushRequests.remove(requestId)?.complete();
        }
        return;
      case 'error':
        final error = StateError('${event['message']}');
        onStatus(
          '[WorkBench][VAD] state=failed '
          'error=${_oneLine(error)}',
          isError: true,
        );
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.completeError(error);
        }
        return;
      case 'closed':
        final closed = _closed;
        if (closed != null && !closed.isCompleted) {
          closed.complete();
        }
        return;
    }
  }

  void _scheduleRestart() {
    if (_disposed || _restartTimer != null) {
      return;
    }
    _restarting = true;
    onStatus('[WorkBench][VAD] state=restarting');
    _restartTimer = Timer(const Duration(seconds: 1), () {
      _restartTimer = null;
      unawaited(
        _closePorts().then((_) => _spawn()).catchError((Object error) {
          onStatus(
            '[WorkBench][VAD] state=failed '
            'restart_error=${_oneLine(error)}',
            isError: true,
          );
          _scheduleRestart();
        }),
      );
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

  Future<void> dispose() async {
    _disposed = true;
    for (final completion in _flushRequests.values) {
      if (!completion.isCompleted) {
        completion.complete();
      }
    }
    _flushRequests.clear();
    _restartTimer?.cancel();
    final commands = _commands;
    final closed = _closed;
    commands?.send(<String, Object>{'type': 'close'});
    if (commands != null && closed != null && !closed.isCompleted) {
      try {
        await closed.future.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        onStatus(
          '[WorkBench][VAD] state=close_timeout native_cleanup=forced',
          isError: true,
        );
      }
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    await _closePorts();
  }

  String _oneLine(Object? value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}

void _vadWorker(Map<String, Object> bootstrap) {
  const sampleRate = 16000;
  final preRollBytes =
      sampleRate *
      2 *
      vadPreRollDuration.inMilliseconds ~/
      Duration.millisecondsPerSecond;
  final rolloverOverlapBytes =
      sampleRate *
      2 *
      vadRolloverOverlapDuration.inMilliseconds ~/
      Duration.millisecondsPerSecond;
  final events = bootstrap['events']! as SendPort;
  final modelPath = bootstrap['modelPath']! as String;
  final outputPath = bootstrap['outputPath']! as String;
  final providers = (bootstrap['providers']! as List<Object?>).cast<String>();
  var endpointDelay = Duration(
    milliseconds: bootstrap['endpointDelayMs']! as int,
  );
  final commands = ReceivePort();
  final preRoll = VadPreRollBuffer(maximumBytes: preRollBytes);
  final rolloverOverlap = VadPreRollBuffer(maximumBytes: rolloverOverlapBytes);
  var endpoint = VadEndpointBuffer(
    sampleRate: sampleRate,
    duration: endpointDelay,
  );
  final segmentDuration = VadSegmentDurationTracker(sampleRate: sampleRate);
  final wordBoundary = VadWordBoundaryDetector(sampleRate: sampleRate);
  RandomAccessFile? segmentFile;
  String? segmentId;
  String? conversationId;
  String? partialPath;
  var segmentSamples = 0;
  var segmentLeadingOverlapMs = 0;
  var conversationPart = 0;
  var wasDetected = false;

  void writeHeader(RandomAccessFile file, int samples) {
    final dataBytes = samples * 2;
    final header = ByteData(44);
    void ascii(int offset, String value) {
      header.buffer.asUint8List().setAll(offset, value.codeUnits);
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, dataBytes, Endian.little);
    file.setPositionSync(0);
    file.writeFromSync(header.buffer.asUint8List());
  }

  void beginSegment({
    bool continuation = false,
    List<Uint8List> leadingOverlapChunks = const <Uint8List>[],
    VadSegmentEndReason? continuationReason,
  }) {
    if (!continuation) {
      final now = DateTime.now().toUtc();
      conversationId =
          '${now.microsecondsSinceEpoch}-${now.toIso8601String().substring(11, 19).replaceAll(':', '')}';
      conversationPart = 0;
    }
    final activeConversationId = conversationId;
    if (activeConversationId == null) {
      throw StateError('A VAD continuation has no active conversation.');
    }
    conversationPart++;
    final preRollBytesAtStart = preRoll.sizeBytes;
    segmentId = conversationPart == 1
        ? activeConversationId
        : '$activeConversationId-part-$conversationPart';
    partialPath = '$outputPath/$segmentId.part.wav';
    segmentFile = File(partialPath!).openSync(mode: FileMode.write);
    writeHeader(segmentFile!, 0);
    segmentSamples = 0;
    segmentLeadingOverlapMs = 0;
    segmentDuration.reset();
    wordBoundary.reset();
    rolloverOverlap.clear();
    if (!continuation) {
      for (final chunk in preRoll.chunks) {
        segmentFile!.writeFromSync(chunk);
        segmentSamples += chunk.length ~/ 2;
      }
    } else {
      var leadingOverlapBytes = 0;
      for (final chunk in leadingOverlapChunks) {
        segmentFile!.writeFromSync(chunk);
        segmentSamples += chunk.length ~/ 2;
        leadingOverlapBytes += chunk.length;
        rolloverOverlap.add(chunk);
      }
      segmentLeadingOverlapMs =
          leadingOverlapBytes *
          Duration.millisecondsPerSecond ~/
          (sampleRate * 2);
    }
    endpoint.reset();
    if (!continuation) {
      events.send(<String, Object>{
        'type': 'speech_started',
        'id': segmentId!,
        'preRollMs':
            preRollBytesAtStart *
            Duration.millisecondsPerSecond ~/
            (sampleRate * 2),
        'preRollBytes': preRollBytesAtStart,
      });
    } else {
      events.send(<String, Object>{
        'type': 'speech_continued',
        'id': segmentId!,
        'reason':
            (continuationReason ?? VadSegmentEndReason.durationPause).name,
        'overlapMs': segmentLeadingOverlapMs,
      });
    }
  }

  void finishSegment({
    bool preserveEndpointPreRoll = false,
    required bool isConversationFinal,
    required VadSegmentEndReason endReason,
  }) {
    final file = segmentFile;
    final id = segmentId;
    final activeConversationId = conversationId;
    final part = partialPath;
    if (file == null ||
        id == null ||
        activeConversationId == null ||
        part == null) {
      return;
    }
    final endpointAudioMs = endpoint.capturedMilliseconds;
    final leadingOverlapMs = segmentLeadingOverlapMs;
    writeHeader(file, segmentSamples);
    file.flushSync();
    file.closeSync();
    final finalPath = part.replaceFirst('.part.wav', '.wav');
    File(part).renameSync(finalPath);
    segmentFile = null;
    segmentId = null;
    partialPath = null;
    segmentSamples = 0;
    segmentLeadingOverlapMs = 0;
    segmentDuration.reset();
    endpoint.reset();
    if (!preserveEndpointPreRoll) {
      final clearedBytes = preRoll.clear();
      events.send(<String, Object>{
        'type': 'buffer_cleared',
        'id': id,
        'bytes': clearedBytes,
      });
    }
    events.send(<String, Object>{
      'type': 'segment',
      'id': id,
      'path': finalPath,
      'conversationId': activeConversationId,
      'isConversationFinal': isConversationFinal,
      'endReason': endReason.name,
      'endpointAudioMs': endpointAudioMs,
      'leadingOverlapMs': leadingOverlapMs,
    });
    if (isConversationFinal) {
      conversationId = null;
      conversationPart = 0;
    }
  }

  void recoverInterruptedSegments() {
    final directory = Directory(outputPath);
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.part.wav')) {
        continue;
      }
      if (entity.lengthSync() <= 44) {
        entity.deleteSync();
        continue;
      }
      final file = entity.openSync(mode: FileMode.append);
      final samples = (entity.lengthSync() - 44) ~/ 2;
      writeHeader(file, samples);
      file.flushSync();
      file.closeSync();
      final id = entity.uri.pathSegments.last.replaceFirst('.part.wav', '');
      final recoveredPath = entity.path.replaceFirst(
        '.part.wav',
        '.recovered.wav',
      );
      entity.renameSync(recoveredPath);
      events.send(<String, Object>{
        'type': 'segment',
        'id': '$id-recovered',
        'path': recoveredPath,
        'conversationId': '$id-recovered',
        'isConversationFinal': true,
        'endReason': VadSegmentEndReason.recovery.name,
        'endpointAudioMs': 0,
      });
    }
  }

  try {
    sherpa.initBindings();
    sherpa.VoiceActivityDetector createVad(String provider) {
      return sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: modelPath,
            threshold: 0.5,
            minSilenceDuration:
                vadDetectorSilenceDuration.inMilliseconds /
                Duration.millisecondsPerSecond,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: 900,
          ),
          sampleRate: sampleRate,
          numThreads: 1,
          provider: provider,
          debug: false,
        ),
        bufferSizeInSeconds: 30,
      );
    }

    sherpa.VoiceActivityDetector? vad;
    String? activeProvider;
    for (final provider in providers) {
      events.send(<String, Object>{
        'type': 'provider_attempt',
        'provider': provider,
      });
      sherpa.VoiceActivityDetector? candidate;
      NnapiProfileProbe? probe;
      try {
        if (provider == 'nnapi') {
          probe = NnapiProfileProbe.create(workload: 'vad');
        }
        candidate = createVad(probe?.provider ?? provider);
        candidate.acceptWaveform(Float32List(512));
        candidate.isDetected();
        candidate.reset();
        if (probe != null) {
          candidate.free();
          candidate = null;
          final attestation = probe.finish();
          probe = null;
          if (!attestation.usedNnapiHardware) {
            throw StateError(attestation.rejectionReason);
          }
          events.send(<String, Object>{
            'type': 'provider_attested',
            'nnapiNodes': attestation.nnapiNodeExecutions,
            'cpuNodes': attestation.cpuNodeExecutions,
            'otherNodes': attestation.otherNodeExecutions,
            'nnapiMicros': attestation.nnapiDurationMicros,
            'cpuMicros': attestation.cpuDurationMicros,
          });
          candidate = createVad(provider);
          candidate.acceptWaveform(Float32List(512));
          candidate.isDetected();
          candidate.reset();
        }
        vad = candidate;
        activeProvider = provider;
        break;
      } catch (error) {
        candidate?.free();
        probe?.discard();
        events.send(<String, Object>{
          'type': 'provider_failed',
          'provider': provider,
          'error': '$error',
        });
      }
    }

    final detector = vad;
    final selectedProvider = activeProvider;
    if (detector == null || selectedProvider == null) {
      throw StateError('No compatible ONNX execution provider could load VAD.');
    }

    commands.listen((Object? message) {
      if (message is! Map<Object?, Object?>) {
        return;
      }
      switch (message['type']) {
        case 'set_endpoint_mode':
          final delayMs = message['delayMs'];
          if (delayMs is int && delayMs > 0) {
            endpointDelay = Duration(milliseconds: delayMs);
            if (!endpoint.isActive) {
              endpoint = VadEndpointBuffer(
                sampleRate: sampleRate,
                duration: endpointDelay,
              );
            }
          }
          return;
        case 'pcm':
          final pcm = (message['bytes']! as TransferableTypedData)
              .materialize()
              .asUint8List();
          final samples = _pcm16ToFloat(pcm);
          detector.acceptWaveform(samples);
          final detected = detector.isDetected();
          final chunkSamples = pcm.length ~/ 2;
          final splitAtVadResume =
              segmentFile != null &&
              segmentDuration.shouldSplitAtVadResume(
                detected: detected,
                endpointActive: endpoint.isActive,
                incomingSamples: chunkSamples,
              );
          final splitAtWordBoundary =
              segmentFile != null &&
              wordBoundary.observe(
                pcm,
                seekBoundary: segmentDuration.willPreferVadPause(chunkSamples),
              );
          if (splitAtVadResume || splitAtWordBoundary) {
            final reason = splitAtVadResume
                ? VadSegmentEndReason.durationPause
                : VadSegmentEndReason.durationWordBoundary;
            finishSegment(
              preserveEndpointPreRoll: true,
              isConversationFinal: false,
              endReason: reason,
            );
            beginSegment(continuation: true, continuationReason: reason);
          }
          if (detected && segmentFile == null) {
            beginSegment();
          }
          if (segmentFile != null) {
            segmentFile!.writeFromSync(pcm);
            segmentSamples += chunkSamples;
            segmentDuration.add(chunkSamples);
            rolloverOverlap.add(pcm);
            if (detected) {
              endpoint.reset();
            } else if (wasDetected) {
              endpoint = VadEndpointBuffer(
                sampleRate: sampleRate,
                duration: endpointDelay,
              );
              final endpointComplete = endpoint.begin(chunkSamples);
              final clearedBytes = preRoll.clear();
              events.send(<String, Object>{
                'type': 'speech_ending',
                'id': segmentId!,
                'delayMs': endpointDelay.inMilliseconds,
              });
              events.send(<String, Object>{
                'type': 'buffer_cleared',
                'id': segmentId!,
                'bytes': clearedBytes,
              });
              if (endpointComplete) {
                finishSegment(
                  preserveEndpointPreRoll: true,
                  isConversationFinal: true,
                  endReason: VadSegmentEndReason.silence,
                );
              }
            } else if (endpoint.isActive) {
              if (endpoint.add(chunkSamples)) {
                finishSegment(
                  preserveEndpointPreRoll: true,
                  isConversationFinal: true,
                  endReason: VadSegmentEndReason.silence,
                );
              }
            }
            if (segmentFile != null &&
                detected &&
                segmentDuration.reachedHardLimit) {
              final leadingOverlapChunks = rolloverOverlap.chunks
                  .map(Uint8List.fromList)
                  .toList(growable: false);
              finishSegment(
                preserveEndpointPreRoll: true,
                isConversationFinal: false,
                endReason: VadSegmentEndReason.durationHardLimit,
              );
              beginSegment(
                continuation: true,
                leadingOverlapChunks: leadingOverlapChunks,
                continuationReason: VadSegmentEndReason.durationHardLimit,
              );
            }
          }
          preRoll.add(pcm);
          wasDetected = detected;
          return;
        case 'flush':
          detector.flush();
          finishSegment(
            isConversationFinal: true,
            endReason: VadSegmentEndReason.flush,
          );
          wasDetected = false;
          final requestId = message['requestId'];
          if (requestId is int) {
            events.send(<String, Object>{
              'type': 'flush_completed',
              'requestId': requestId,
            });
          }
          return;
        case 'close':
          detector.flush();
          finishSegment(
            isConversationFinal: true,
            endReason: VadSegmentEndReason.close,
          );
          detector.free();
          events.send(<String, Object>{'type': 'closed'});
          commands.close();
          return;
      }
    });
    events.send(<String, Object>{
      'type': 'commands',
      'port': commands.sendPort,
    });
    recoverInterruptedSegments();
    events.send(<String, Object>{
      'type': 'ready',
      'provider': selectedProvider,
    });
  } catch (error) {
    events.send(<String, Object>{'type': 'error', 'message': '$error'});
    rethrow;
  }
}

Float32List _pcm16ToFloat(Uint8List pcm) {
  final input = ByteData.sublistView(pcm);
  final samples = Float32List(pcm.length ~/ 2);
  for (var index = 0; index < samples.length; index++) {
    samples[index] = input.getInt16(index * 2, Endian.little) / 32768.0;
  }
  return samples;
}

double _pcm16Rms(Uint8List pcm) {
  final input = ByteData.sublistView(pcm);
  var squareSum = 0.0;
  var samples = 0;
  for (var offset = 0; offset + 1 < pcm.length; offset += 2) {
    final sample = input.getInt16(offset, Endian.little);
    squareSum += sample * sample;
    samples++;
  }
  return samples == 0 ? 0 : sqrt(squareSum / samples);
}
