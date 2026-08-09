import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'gemma_correction_client.dart';
import 'gemma_model.dart';
import 'transcript_correction_config.dart';

typedef CorrectionStatusSink = void Function(String message, {bool isError});
typedef CorrectedTranscriptSink =
    void Function(CorrectedTranscriptResult result);
typedef UncorrectedTranscriptSink =
    void Function(
      TranscriptCorrectionJob job,
      String transcript,
      String reason,
    );

bool transcriptBeginsWithWakeWord(String transcript) => RegExp(
  r'^\s*hey(?=$|[^A-Za-z0-9_])',
  caseSensitive: false,
).hasMatch(transcript);

bool isLiveTranscriptCorrectionEligible(
  String transcript, {
  required bool explicitlyTargeted,
}) => explicitlyTargeted || transcriptBeginsWithWakeWord(transcript);

final class TranscriptCorrectionJob {
  const TranscriptCorrectionJob({
    required this.segmentId,
    required this.rawPath,
    required this.sttModel,
    required this.sttProvider,
    required this.audioMs,
    required this.sttDecodeMs,
    required this.sttTotalMs,
    required this.queuedAt,
    this.correctionTerms = const <String>[],
    this.routeWhenCorrected = false,
    this.liveTranscript,
    this.attempts = 0,
    this.nextAttemptAt,
  });

  final String segmentId;
  final String rawPath;
  final String sttModel;
  final String sttProvider;
  final int audioMs;
  final int sttDecodeMs;
  final int sttTotalMs;
  final DateTime queuedAt;
  final List<String> correctionTerms;
  final bool routeWhenCorrected;

  /// Optional live-process input after rollover overlap removal. It is never
  /// written to the pending ledger; restored jobs remain read-only and do not
  /// route to the agent bridge.
  final String? liveTranscript;
  final int attempts;
  final DateTime? nextAttemptAt;

  TranscriptCorrectionJob retryAfter(
    Duration delay, {
    bool incrementAttempt = true,
  }) => TranscriptCorrectionJob(
    segmentId: segmentId,
    rawPath: rawPath,
    sttModel: sttModel,
    sttProvider: sttProvider,
    audioMs: audioMs,
    sttDecodeMs: sttDecodeMs,
    sttTotalMs: sttTotalMs,
    queuedAt: queuedAt,
    correctionTerms: correctionTerms,
    routeWhenCorrected: routeWhenCorrected,
    liveTranscript: liveTranscript,
    attempts: attempts + (incrementAttempt ? 1 : 0),
    nextAttemptAt: DateTime.now().toUtc().add(delay),
  );

  Map<String, Object> toJson() => <String, Object>{
    'rawPath': rawPath,
    'sttModel': sttModel,
    'sttProvider': sttProvider,
    'audioMs': audioMs,
    'sttDecodeMs': sttDecodeMs,
    'sttTotalMs': sttTotalMs,
    'queuedAt': queuedAt.toUtc().toIso8601String(),
    'attempts': attempts,
    if (nextAttemptAt != null)
      'nextAttemptAt': nextAttemptAt!.toUtc().toIso8601String(),
  };

  static TranscriptCorrectionJob? fromJson(String id, Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final rawPath = value['rawPath'];
    final queuedAt = DateTime.tryParse('${value['queuedAt']}');
    if (rawPath is! String || rawPath.isEmpty || queuedAt == null) {
      return null;
    }
    return TranscriptCorrectionJob(
      segmentId: id,
      rawPath: rawPath,
      sttModel: '${value['sttModel'] ?? 'unknown'}',
      sttProvider: '${value['sttProvider'] ?? 'unknown'}',
      audioMs: (value['audioMs'] as num?)?.toInt() ?? 0,
      sttDecodeMs: (value['sttDecodeMs'] as num?)?.toInt() ?? 0,
      sttTotalMs: (value['sttTotalMs'] as num?)?.toInt() ?? 0,
      queuedAt: queuedAt.toUtc(),
      correctionTerms: const <String>[],
      routeWhenCorrected: false,
      attempts: (value['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAt: DateTime.tryParse(
        '${value['nextAttemptAt'] ?? ''}',
      )?.toUtc(),
    );
  }
}

final class CorrectedTranscriptResult {
  const CorrectedTranscriptResult({
    required this.segmentId,
    required this.originalText,
    required this.correctedText,
    required this.correctedPath,
    required this.provider,
    required this.queueMs,
    required this.engineLoadMs,
    required this.inferenceMs,
    required this.correctionTotalMs,
    required this.pipelineTotalMs,
    required this.routeWhenCorrected,
  });

  final String segmentId;
  final String originalText;
  final String correctedText;
  final String correctedPath;
  final String provider;
  final int queueMs;
  final int engineLoadMs;
  final int inferenceMs;
  final int correctionTotalMs;
  final int pipelineTotalMs;
  final bool routeWhenCorrected;
}

final class TranscriptCorrectionSupervisor {
  static const int maximumTranscriptCharacters = 6000;
  static const int maximumCorrectionAttempts = 3;

  TranscriptCorrectionSupervisor({
    required this.speechPath,
    required this.configStore,
    required this.modelStore,
    required this.onCorrected,
    required this.onUncorrected,
    required this.onStatus,
    GemmaCorrectionClient? client,
    this.transientRetryDelayOverride,
  }) : _client = client ?? PlatformGemmaCorrectionClient();

  final String speechPath;
  final TranscriptCorrectionConfigStore configStore;
  final GemmaModelStore modelStore;
  final CorrectedTranscriptSink onCorrected;
  final UncorrectedTranscriptSink onUncorrected;
  final CorrectionStatusSink onStatus;
  final GemmaCorrectionClient _client;
  final Duration? transientRetryDelayOverride;
  final LinkedHashMap<String, TranscriptCorrectionJob> _pending =
      LinkedHashMap<String, TranscriptCorrectionJob>();
  final Map<String, int> _transientFailureCounts = <String, int>{};

  Timer? _pumpTimer;
  Future<void> _ledgerWriteTail = Future<void>.value();
  bool _pumping = false;
  bool _pumpRequested = false;
  bool _disposed = false;
  String? activeProvider;
  String state = 'idle';

  int get pendingCount => _pending.length;

  Future<void> start() async {
    await _restorePending();
    final modelPath = await modelStore.installedModelPath();
    final installed = modelPath != null;
    final shouldPrepare = installed && configStore.config.enabled;
    state = shouldPrepare ? 'warming' : (installed ? 'ready' : 'model missing');
    onStatus(
      '[WorkBench][Correction] '
      'state=${shouldPrepare ? 'warming' : (installed ? 'ready' : 'model_missing')} '
      'model=${gemma4E4bModel.id} provider=gpu '
      'pending=${_pending.length}',
      isError: !installed,
    );
    if (shouldPrepare) {
      unawaited(_prepareEngine(modelPath));
    }
    _requestPump();
  }

  Future<void> _prepareEngine(String modelPath) async {
    try {
      await _client.prepareEngine(
        modelPath: modelPath,
        modelId: gemma4E4bModel.id,
      );
      if (_disposed) {
        return;
      }
      state = 'ready';
      onStatus(
        '[WorkBench][Correction] state=warm_idle '
        'model=${gemma4E4bModel.id} provider=gpu',
      );
    } on Object catch (error) {
      if (_disposed) {
        return;
      }
      state = 'ready';
      onStatus(
        '[WorkBench][Correction] state=warmup_failed '
        'model=${gemma4E4bModel.id} provider=gpu '
        'raw_transcription=available error=${_oneLine(error)}',
        isError: true,
      );
    }
  }

  Future<void> queue(
    TranscriptCorrectionJob job, {
    bool prioritize = false,
  }) async {
    if (_disposed) {
      return;
    }
    _pending.remove(job.segmentId);
    if (prioritize) {
      final reordered = <String, TranscriptCorrectionJob>{
        job.segmentId: job,
        ..._pending,
      };
      _pending
        ..clear()
        ..addAll(reordered);
    } else {
      _pending[job.segmentId] = job;
    }
    await _persistPending();
    onStatus(
      '[WorkBench][Correction] state=queued segment=${job.segmentId} '
      'priority=${prioritize ? 'selected_agent' : 'normal'} '
      'pending=${_pending.length} stt_decode_ms=${job.sttDecodeMs} '
      'stt_total_ms=${job.sttTotalMs}',
    );
    _requestPump();
  }

  /// Moves a live queued job ahead of other ready correction work.
  ///
  /// An already-processing job cannot be interrupted, but it remains the
  /// active head and reports success. This only changes in-process ordering;
  /// the durable ledger remains crash-safe and recovered jobs never route.
  Future<bool> prioritize(String segmentId) async {
    if (_disposed) {
      return false;
    }
    final job = _pending.remove(segmentId);
    if (job == null) {
      return false;
    }
    final reordered = <String, TranscriptCorrectionJob>{
      segmentId: job,
      ..._pending,
    };
    _pending
      ..clear()
      ..addAll(reordered);
    await _persistPending();
    onStatus(
      '[WorkBench][Correction] state=prioritized segment=$segmentId '
      'pending=${_pending.length}',
    );
    _requestPump();
    return true;
  }

  Future<void> skipIneligible(
    TranscriptCorrectionJob job,
    String rawText, {
    required String reason,
  }) async {
    if (_disposed) {
      return;
    }
    await persistSkipped(job, reason: reason);
    _pending.remove(job.segmentId);
    _transientFailureCounts.remove(job.segmentId);
    await _persistPending();
    onStatus(
      '[WorkBench][Correction] state=skipped_ineligible '
      'segment=${job.segmentId} reason=$reason raw=preserved '
      'pending=${_pending.length}',
    );
    onUncorrected(job, rawText, reason);
  }

  static Future<void> persistSkipped(
    TranscriptCorrectionJob job, {
    required String reason,
  }) => _atomicWriteJson(_skippedPathForRaw(job.rawPath), <String, Object>{
    'version': 1,
    'segment': job.segmentId,
    'reason': reason,
    'attempts': job.attempts,
    'skippedAt': DateTime.now().toUtc().toIso8601String(),
  });

  void _schedulePump(Duration delay) {
    if (_disposed) {
      return;
    }
    if (delay <= Duration.zero) {
      _requestPump();
      return;
    }
    _pumpTimer?.cancel();
    _pumpTimer = Timer(delay, () {
      _pumpTimer = null;
      _requestPump();
    });
  }

  void _requestPump() {
    if (_disposed || _pending.isEmpty) {
      return;
    }
    _pumpTimer?.cancel();
    _pumpTimer = null;
    if (_pumping) {
      _pumpRequested = true;
      return;
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_disposed || _pumping || _pending.isEmpty) {
      return;
    }
    _pumping = true;
    try {
      while (!_disposed && _pending.isNotEmpty) {
        final now = DateTime.now().toUtc();
        final ready = _pending.values
            .where(
              (job) =>
                  job.nextAttemptAt == null || !job.nextAttemptAt!.isAfter(now),
            )
            .firstOrNull;
        if (ready == null) {
          final earliest = _pending.values
              .map((job) => job.nextAttemptAt)
              .whereType<DateTime>()
              .reduce((left, right) => left.isBefore(right) ? left : right);
          _schedulePump(earliest.difference(now));
          break;
        }
        await _process(ready);
      }
    } finally {
      _pumping = false;
      if (_pumpRequested && !_disposed) {
        _pumpRequested = false;
        _requestPump();
      }
    }
  }

  Future<void> _process(TranscriptCorrectionJob job) async {
    final rawFile = File(job.rawPath);
    if (!await rawFile.exists()) {
      _pending.remove(job.segmentId);
      _transientFailureCounts.remove(job.segmentId);
      await _persistPending();
      onStatus(
        '[WorkBench][Correction] state=dropped_missing_raw '
        'segment=${job.segmentId}',
        isError: true,
      );
      onUncorrected(job, job.liveTranscript?.trim() ?? '', 'raw_missing');
      return;
    }
    final rawText = (job.liveTranscript ?? await rawFile.readAsString()).trim();
    if (rawText.isEmpty) {
      await _finishWithoutCorrection(
        job,
        rawText: rawText,
        stateName: 'skipped_empty',
        reason: 'empty_transcript',
      );
      return;
    }
    if (rawText.length > maximumTranscriptCharacters) {
      await _finishWithoutCorrection(
        job,
        rawText: rawText,
        stateName: 'skipped_oversize',
        reason: 'input_too_long',
        detail: 'chars=${rawText.length}',
        isError: true,
      );
      return;
    }
    if (job.attempts >= maximumCorrectionAttempts) {
      await _finishWithoutCorrection(
        job,
        rawText: rawText,
        stateName: 'abandoned',
        reason: 'retry_exhausted',
        detail: 'attempts=${job.attempts}',
        attempts: job.attempts,
        isError: true,
      );
      state = 'degraded';
      return;
    }

    onStatus(
      '[WorkBench][Correction] state=preparing segment=${job.segmentId} '
      'stage=config_reload pending=${_pending.length}',
    );
    final config = await configStore.reloadForNextTranscript();
    onStatus(
      '[WorkBench][Correction] state=preparing segment=${job.segmentId} '
      'stage=model_check config_fallback='
      '${configStore.validationError != null}',
    );
    if (!config.enabled) {
      await _finishWithoutCorrection(
        job,
        rawText: rawText,
        stateName: 'disabled',
        reason: 'correction_disabled',
      );
      return;
    }
    final modelPath = await modelStore.installedModelPath();
    if (modelPath == null) {
      await _finishWithoutCorrection(
        job,
        rawText: rawText,
        stateName: 'skipped_model_missing',
        reason: 'model_missing',
        isError: true,
      );
      return;
    }

    final queueMs = DateTime.now()
        .toUtc()
        .difference(job.queuedAt)
        .inMilliseconds;
    state = 'processing';
    onStatus(
      '[WorkBench][Correction] state=processing segment=${job.segmentId} '
      'model=${config.modelId} provider=gpu queue_ms=$queueMs '
      'attempt=${job.attempts + 1}',
    );
    try {
      final result = await _client.correct(
        GemmaCorrectionRequest(
          modelPath: modelPath,
          modelId: config.modelId,
          instructions: buildCorrectionInstructions(
            config.instructions,
            job.correctionTerms,
          ),
          transcript: rawText,
          timeoutMs: config.timeoutMs,
        ),
      );
      if (_disposed) {
        return;
      }
      final corrected = validateCorrectedTranscript(
        original: rawText,
        candidate: result.correctedText,
      );
      final correctedPath = _correctedPathForRaw(job.rawPath);
      await _atomicWriteText(correctedPath, corrected);
      final pipelineTotalMs = DateTime.now()
          .toUtc()
          .difference(job.queuedAt)
          .inMilliseconds;
      final metadataPath = _metadataPathForRaw(job.rawPath);
      await _atomicWriteJson(metadataPath, <String, Object>{
        'version': 1,
        'segment': job.segmentId,
        'stt': <String, Object>{
          'model': job.sttModel,
          'provider': job.sttProvider,
          'audioMs': job.audioMs,
          'decodeMs': job.sttDecodeMs,
          'totalMs': job.sttTotalMs,
        },
        'correction': <String, Object>{
          'model': config.modelId,
          'runtime': 'litertlm-0.14.0',
          'provider': result.provider,
          'queueMs': queueMs,
          'engineLoadMs': result.engineLoadMs,
          'inferenceMs': result.inferenceMs,
          'totalMs': result.totalMs,
          'timeToFirstTokenMs': result.timeToFirstTokenMs,
          'prefillTokensPerSecond': result.prefillTokensPerSecond,
          'decodeTokensPerSecond': result.decodeTokensPerSecond,
        },
        'pipelineTotalMs': pipelineTotalMs,
        'completedAt': DateTime.now().toUtc().toIso8601String(),
      });
      _pending.remove(job.segmentId);
      _transientFailureCounts.remove(job.segmentId);
      await _persistPending();
      activeProvider = result.provider;
      state = 'ready';
      onStatus(
        '[WorkBench][Correction] state=completed segment=${job.segmentId} '
        'model=${config.modelId} provider=${result.provider} '
        'queue_ms=$queueMs engine_load_ms=${result.engineLoadMs} '
        'inference_ms=${result.inferenceMs} correction_ms=${result.totalMs} '
        'stt_decode_ms=${job.sttDecodeMs} stt_total_ms=${job.sttTotalMs} '
        'pipeline_total_ms=$pipelineTotalMs '
        'ttft_ms=${result.timeToFirstTokenMs} '
        'prefill_tps=${result.prefillTokensPerSecond.toStringAsFixed(1)} '
        'decode_tps=${result.decodeTokensPerSecond.toStringAsFixed(1)} '
        'pending=${_pending.length}',
      );
      onCorrected(
        CorrectedTranscriptResult(
          segmentId: job.segmentId,
          originalText: rawText,
          correctedText: corrected,
          correctedPath: correctedPath,
          provider: result.provider,
          queueMs: queueMs,
          engineLoadMs: result.engineLoadMs,
          inferenceMs: result.inferenceMs,
          correctionTotalMs: result.totalMs,
          pipelineTotalMs: pipelineTotalMs,
          routeWhenCorrected: job.routeWhenCorrected,
        ),
      );
    } on Object catch (error) {
      await _retry(job, rawText, error);
    }
  }

  Future<void> _retry(
    TranscriptCorrectionJob job,
    String rawText,
    Object error,
  ) async {
    if (_disposed) {
      return;
    }
    final errorCode = _errorCode(error);
    if (_isTransientServiceFailure(errorCode)) {
      final failures = (_transientFailureCounts[job.segmentId] ?? 0) + 1;
      _transientFailureCounts[job.segmentId] = failures;
      final backoff =
          transientRetryDelayOverride ??
          switch (failures) {
            1 => const Duration(seconds: 1),
            2 => const Duration(seconds: 5),
            3 => const Duration(seconds: 15),
            _ => const Duration(seconds: 30),
          };
      final retried = job.retryAfter(backoff, incrementAttempt: false);
      _pending[job.segmentId] = retried;
      await _persistPending();
      state = 'degraded';
      onStatus(
        '[WorkBench][Correction] state=deferred segment=${job.segmentId} '
        'service_failures=$failures retry_ms=${backoff.inMilliseconds} '
        'error_code=$errorCode raw=preserved pending=${_pending.length}',
        isError: true,
      );
      return;
    }
    final attempt = job.attempts + 1;
    if (attempt >= maximumCorrectionAttempts) {
      await _finishWithoutCorrection(
        job,
        rawText: rawText,
        stateName: 'abandoned',
        reason: 'retry_exhausted',
        detail: 'attempts=$attempt error_code=$errorCode',
        attempts: attempt,
        isError: true,
      );
      state = 'degraded';
      return;
    }
    final backoff = switch (attempt) {
      1 => const Duration(seconds: 1),
      2 => const Duration(seconds: 5),
      3 => const Duration(seconds: 30),
      _ => const Duration(minutes: 5),
    };
    final retried = job.retryAfter(backoff);
    _pending[job.segmentId] = retried;
    await _persistPending();
    state = 'degraded';
    onStatus(
      '[WorkBench][Correction] state=failed segment=${job.segmentId} '
      'attempt=$attempt retry_ms=${backoff.inMilliseconds} '
      'error_code=$errorCode raw=preserved',
      isError: true,
    );
  }

  Future<void> _finishWithoutCorrection(
    TranscriptCorrectionJob job, {
    required String rawText,
    required String stateName,
    required String reason,
    String? detail,
    int? attempts,
    bool isError = false,
  }) async {
    final retained = attempts == null
        ? job
        : TranscriptCorrectionJob(
            segmentId: job.segmentId,
            rawPath: job.rawPath,
            sttModel: job.sttModel,
            sttProvider: job.sttProvider,
            audioMs: job.audioMs,
            sttDecodeMs: job.sttDecodeMs,
            sttTotalMs: job.sttTotalMs,
            queuedAt: job.queuedAt,
            correctionTerms: job.correctionTerms,
            routeWhenCorrected: job.routeWhenCorrected,
            liveTranscript: job.liveTranscript,
            attempts: attempts,
            nextAttemptAt: job.nextAttemptAt,
          );
    await persistSkipped(retained, reason: reason);
    _pending.remove(job.segmentId);
    _transientFailureCounts.remove(job.segmentId);
    await _persistPending();
    onStatus(
      '[WorkBench][Correction] state=$stateName segment=${job.segmentId} '
      '${detail == null ? '' : '$detail '}raw=preserved '
      'pending=${_pending.length}',
      isError: isError,
    );
    onUncorrected(retained, rawText, reason);
  }

  Future<void> _restorePending() async {
    final directory = Directory(speechPath);
    await directory.create(recursive: true);
    final ledger = File('$speechPath/pending-corrections.json');
    if (await ledger.exists()) {
      try {
        final decoded = jsonDecode(await ledger.readAsString());
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            final job = TranscriptCorrectionJob.fromJson(
              entry.key,
              entry.value,
            );
            if (job != null) {
              _pending[entry.key] = job;
            }
          }
        }
      } on Object catch (error) {
        onStatus(
          '[WorkBench][Correction] state=ledger_rebuild '
          'error_code=${_errorCode(error)}',
          isError: true,
        );
      }
    }
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.raw.txt')) {
        continue;
      }
      if (await File(_skippedPathForRaw(entity.path)).exists()) {
        continue;
      }
      final id = entity.path
          .split(Platform.pathSeparator)
          .last
          .replaceFirst(RegExp(r'\.raw\.txt$'), '');
      if (await File(_correctedPathForRaw(entity.path)).exists()) {
        _pending.remove(id);
      } else {
        final queuedAt = (await entity.lastModified()).toUtc();
        _pending.putIfAbsent(
          id,
          () => TranscriptCorrectionJob(
            segmentId: id,
            rawPath: entity.path,
            sttModel: 'recovered',
            sttProvider: 'unknown',
            audioMs: 0,
            sttDecodeMs: 0,
            sttTotalMs: 0,
            queuedAt: queuedAt,
          ),
        );
      }
    }
    _pending.removeWhere(
      (_, job) =>
          !File(job.rawPath).existsSync() ||
          File(_skippedPathForRaw(job.rawPath)).existsSync() ||
          File(_correctedPathForRaw(job.rawPath)).existsSync(),
    );
    var wakeGated = 0;
    for (final job in _pending.values.toList(growable: false)) {
      try {
        final rawText = await File(job.rawPath).readAsString();
        if (transcriptBeginsWithWakeWord(rawText)) {
          continue;
        }
        await persistSkipped(job, reason: 'no_wake_word');
        _pending.remove(job.segmentId);
        wakeGated++;
      } on Object {
        // Leave unreadable jobs in the existing recovery path. Processing will
        // preserve the ledger entry or record the storage failure explicitly.
      }
    }
    await _persistPending();
    if (wakeGated > 0) {
      onStatus(
        '[WorkBench][Correction] state=recovery_wake_gated '
        'skipped=$wakeGated pending=${_pending.length}',
      );
    }
    if (_pending.isNotEmpty) {
      onStatus(
        '[WorkBench][Correction] state=jobs_recovered '
        'pending=${_pending.length}',
      );
    }
  }

  Future<void> _persistPending() {
    final value = <String, Object>{
      for (final entry in _pending.entries) entry.key: entry.value.toJson(),
    };
    final encoded = jsonEncode(value);
    final operation = _ledgerWriteTail.then((_) async {
      final ledger = File('$speechPath/pending-corrections.json');
      final partial = File('${ledger.path}.part');
      await partial.writeAsString(encoded, flush: true);
      await partial.rename(ledger.path);
    });
    _ledgerWriteTail = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  static String validateCorrectedTranscript({
    required String original,
    required String candidate,
  }) {
    final corrected = candidate.trim();
    if (corrected.isEmpty) {
      throw const FormatException('The corrected transcript is empty.');
    }
    final maximumLength = original.length * 2 + 256;
    if (corrected.length > maximumLength) {
      throw const FormatException(
        'The corrected transcript expanded beyond the safety limit.',
      );
    }
    final protectedPattern = RegExp(
      r'(?:--?[A-Za-z0-9][A-Za-z0-9_-]*|'
      r'(?:/|[A-Za-z]:\\)[^\s]+|'
      r'\b\d+(?:[.:/-]\d+)*\b)',
    );
    final correctedLower = corrected.toLowerCase();
    for (final match in protectedPattern.allMatches(original)) {
      final token = match.group(0);
      if (token != null && !correctedLower.contains(token.toLowerCase())) {
        throw FormatException(
          'The correction removed protected token "$token".',
        );
      }
    }
    return corrected;
  }

  static String buildCorrectionInstructions(
    String base,
    Iterable<String> correctionTerms,
  ) {
    final terms = <String>[];
    final seen = <String>{};
    for (final value in correctionTerms) {
      final term = value.trim();
      final key = term.toLowerCase();
      if (term.isEmpty || term.length > 64 || !seen.add(key)) {
        continue;
      }
      terms.add(term);
      if (terms.length == 32) {
        break;
      }
    }
    if (terms.isEmpty) {
      return base;
    }
    final acousticAliases = <String, List<String>>{};
    const knownAliases = <String, List<String>>{
      'flux': <String>['plus', 'plux', 'flex', 'flax', 'fox'],
      'brock': <String>['broke', 'block', 'broc'],
      'pike': <String>['bike', 'pipe', 'pyke'],
      'wolf': <String>['woolf', 'woof', 'wolfe'],
      'hey memo': <String>['hey me mo', 'hey mimo'],
    };
    for (final term in terms) {
      final aliases = knownAliases[term.toLowerCase()];
      if (aliases != null) {
        acousticAliases[term] = aliases;
      }
    }
    final hasMemoInvocation = terms.any(
      (term) => term.toLowerCase() == 'hey memo',
    );
    final memoGuidance = hasMemoInvocation
        ? ' The exact leading local memo invocation is "Hey Memo". Correct a '
              'plausible leading acoustic variant such as "hey me mo" or '
              '"hey mimo" to exactly "Hey Memo" when the remaining words are '
              'dictated memo content or a clear request to take a memo. Never '
              'expand a standalone "Hey" into "Hey Memo"; the source must '
              'contain both "Hey" and a memo-like second word. Never '
              'rewrite an ordinary use of the word memo, such as "I wrote a '
              'memo yesterday", into an invocation.'
        : '';
    final hasAgentAliases = acousticAliases.keys.any(
      (term) => term.toLowerCase() != 'hey memo',
    );
    final agentGuidance = hasAgentAliases
        ? ' For configured agents other than Hey Memo, normalize a known '
              'acoustic alias only when the source begins with "Hey" followed '
              'by that alias. Never promote a bare alias such as "Plus" into '
              'an agent invocation.'
        : '';
    return '$base\nKnown local command names: ${jsonEncode(terms)}.$memoGuidance '
        '$agentGuidance Known acoustic aliases: ${jsonEncode(acousticAliases)}. '
        'An exact configured command name may be normalized in place. Never '
        'insert a command name when the audio does not plausibly contain it.';
  }

  static Future<void> _atomicWriteText(String path, String value) async {
    final partial = File('$path.part');
    await partial.writeAsString('$value\n', flush: true);
    await partial.rename(path);
  }

  static Future<void> _atomicWriteJson(
    String path,
    Map<String, Object> value,
  ) async {
    final partial = File('$path.part');
    await partial.writeAsString(jsonEncode(value), flush: true);
    await partial.rename(path);
  }

  Future<void> dispose() async {
    _disposed = true;
    _pumpRequested = false;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    await _ledgerWriteTail;
    await _client.releaseEngine();
  }

  Future<void> releaseIdleEngine() async {
    if (!_disposed && state != 'processing') {
      await _client.releaseEngine();
      state = 'idle';
      onStatus(
        '[WorkBench][Correction] state=engine_released reason=memory_pressure',
      );
    }
  }

  static String _correctedPathForRaw(String rawPath) =>
      rawPath.replaceFirst(RegExp(r'\.raw\.txt$'), '.corrected.txt');

  static String _skippedPathForRaw(String rawPath) =>
      rawPath.replaceFirst(RegExp(r'\.raw\.txt$'), '.correction-skipped.json');

  static String _metadataPathForRaw(String rawPath) =>
      rawPath.replaceFirst(RegExp(r'\.raw\.txt$'), '.transcript.json');

  static String _errorCode(Object error) => switch (error) {
    GemmaCorrectionClientException _ => error.code,
    FormatException _ => 'invalid_output',
    TimeoutException _ => 'timeout',
    FileSystemException _ => 'storage',
    StateError _ => 'invalid_state',
    UnsupportedError _ => 'unsupported',
    _ => 'runtime_failure',
  };

  static bool _isTransientServiceFailure(String code) => switch (code) {
    'service_disconnected' ||
    'service_send_failed' ||
    'service_unavailable' ||
    'memory_pressure' => true,
    _ => false,
  };

  static String _oneLine(Object? value) =>
      value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}
