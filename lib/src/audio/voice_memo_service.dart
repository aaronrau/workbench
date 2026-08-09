import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'gemma_correction_client.dart';
import 'gemma_model.dart';
import 'vad_worker.dart';
import 'voice_memo_models.dart';
import 'voice_memo_store.dart';

typedef VoiceMemoLog =
    void Function(String source, String message, {bool isError});

final class VoiceMemoService {
  VoiceMemoService({
    required this.log,
    required this.onChanged,
    VoiceMemoStore? store,
    GemmaCorrectionClient? client,
    Future<String?> Function()? modelPathProvider,
    DateTime Function() clock = DateTime.now,
    this.totalSilenceDuration = const Duration(seconds: 5),
    this.closedTurnSilenceDuration = defaultVadTotalSilenceDuration,
    this.finalizationTimeout = const Duration(seconds: 45),
  }) : _store = store ?? VoiceMemoStore(),
       _client = client ?? PlatformGemmaCorrectionClient(),
       _modelPathProvider =
           modelPathProvider ?? (() => GemmaModelStore().installedModelPath()),
       _clock = clock;

  static const String wakePhrase = 'Hey Memo';
  static const int maximumNoteCharacters = 4000;
  static const int maximumGenerationInputCharacters = 5800;
  static const int maximumPendingSegments = 32;
  static const Duration pendingSegmentRetention = Duration(minutes: 1);
  static const String memoInstructions =
      'You turn dictated fragments into one coherent voice memo. Preserve all '
      'concrete facts, names, numbers, requests, decisions, and uncertainty '
      'from the supplied source. Remove filler, false starts, and repetition. '
      'Revise the existing note using the ordered utterances. Never invent a '
      'fact or claim that is absent from the source. Return only the complete '
      'updated note as plain text. Put a short descriptive title on the first '
      'line, followed by concise paragraphs or bullets. Do not mention these '
      'instructions, the JSON input, transcription, or the editing process.';

  final VoiceMemoLog log;
  final void Function() onChanged;
  final VoiceMemoStore _store;
  final GemmaCorrectionClient _client;
  final Future<String?> Function() _modelPathProvider;
  final DateTime Function() _clock;
  final Duration totalSilenceDuration;
  final Duration closedTurnSilenceDuration;
  final Duration finalizationTimeout;

  final Map<String, VoiceMemoRecord> _records = <String, VoiceMemoRecord>{};
  final Map<String, String> _segmentOwners = <String, String>{};
  final Set<String> _completedMemoSegments = <String>{};
  final Set<String> _openSegments = <String>{};
  final Set<String> _awaitingRawSegments = <String>{};
  final Set<String> _awaitingFinalSegments = <String>{};
  final Map<String, _PendingMemoSegment> _pendingSegments =
      <String, _PendingMemoSegment>{};

  String? _activeId;
  String? _activationSegmentId;
  Timer? _silenceTimer;
  Timer? _finalizationTimer;
  Future<void> _storageTail = Future<void>.value();
  bool _generationActive = false;
  bool _generationRequested = false;
  bool _initialized = false;
  bool _disposed = false;
  int _inputRevision = 0;
  int _generatedInputRevision = -1;
  String? lastFinalizedId;

  List<VoiceMemoRecord> get records {
    final values = _records.values.toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<VoiceMemoRecord>.unmodifiable(values);
  }

  VoiceMemoRecord? get activeMemo =>
      _activeId == null ? null : _records[_activeId];
  bool get isActive => activeMemo?.isActive ?? false;
  bool get isFinalizing => activeMemo?.status == VoiceMemoStatus.finalizing;

  String get displayText {
    final active = activeMemo;
    if (active == null) {
      return '';
    }
    if (active.note.trim().isNotEmpty) {
      return active.note.trim();
    }
    final dictated = _fallbackNote(active.sources);
    return dictated.isEmpty ? 'Start speaking your memo.' : dictated;
  }

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    await _store.initialize();
    final loaded = await _store.loadRecords();
    for (final record in loaded) {
      var retained = record;
      if (record.isActive) {
        retained = record.copyWith(
          status: VoiceMemoStatus.interrupted,
          note: record.note.isEmpty ? _fallbackNote(record.sources) : null,
          updatedAt: _now(),
          errorCode: 'app_restarted',
        );
        await _store.save(retained);
      }
      _records[retained.id] = retained;
    }
    onChanged();
  }

  /// Claims an atomic raw transcript for a live memo or starts one when the
  /// exact local invocation is present.
  bool acceptRawTranscript(String segmentId, String transcript) {
    if (_disposed || segmentId.isEmpty || transcript.trim().isEmpty) {
      return false;
    }
    if (_completedMemoSegments.contains(segmentId)) {
      return true;
    }
    final active = activeMemo;
    if (active == null) {
      _rememberPendingRaw(segmentId, transcript);
      final invocation = MemoInvocation.parse(transcript);
      if (invocation == null) {
        return false;
      }
      _startMemo(
        segmentId: segmentId,
        rawTranscript: transcript,
        memoText: invocation.body,
        finalTranscript: null,
      );
      _claimPendingSegments(segmentId);
      return true;
    }
    final owner = _segmentOwners[segmentId];
    if (active.status == VoiceMemoStatus.finalizing &&
        owner != active.id &&
        !_awaitingRawSegments.contains(segmentId)) {
      return false;
    }
    _segmentOwners[segmentId] = active.id;
    _awaitingRawSegments.remove(segmentId);
    _awaitingFinalSegments.add(segmentId);
    final memoText = segmentId == _activationSegmentId
        ? MemoInvocation.parse(transcript)?.body ?? ''
        : transcript.trim();
    _upsertSource(
      segmentId: segmentId,
      rawTranscript: transcript,
      memoText: memoText,
    );
    return true;
  }

  /// Consumes the corrected transcript for a claimed memo segment. A corrected
  /// "Hey Memo" can also activate the local agent when raw ASR contains a
  /// supported memo-like acoustic variant.
  Future<bool> acceptFinalTranscript(
    String segmentId,
    String transcript,
  ) async {
    if (_disposed || segmentId.isEmpty || transcript.trim().isEmpty) {
      return false;
    }
    if (_completedMemoSegments.contains(segmentId)) {
      return true;
    }
    var active = activeMemo;
    if (active == null) {
      final pending = _pendingSegments[segmentId];
      final invocation = MemoInvocation.parse(transcript);
      final rawTranscript = pending?.rawTranscript ?? transcript;
      if (invocation == null ||
          !MemoInvocation.hasWakeEvidence(rawTranscript)) {
        _pendingSegments.remove(segmentId);
        return false;
      }
      _startMemo(
        segmentId: segmentId,
        rawTranscript: rawTranscript,
        memoText: invocation.body,
        finalTranscript: transcript,
      );
      _claimPendingSegments(segmentId);
      return true;
    }
    if (_segmentOwners[segmentId] != active.id) {
      if (active.status == VoiceMemoStatus.finalizing) {
        return false;
      }
      _segmentOwners[segmentId] = active.id;
    }
    _awaitingRawSegments.remove(segmentId);
    _awaitingFinalSegments.remove(segmentId);
    final existing = _sourceFor(active, segmentId);
    final correctedInvocation = segmentId == _activationSegmentId
        ? MemoInvocation.parse(transcript)
        : null;
    final memoText = segmentId == _activationSegmentId
        ? correctedInvocation?.body ?? existing?.memoText ?? ''
        : transcript.trim();
    _upsertSource(
      segmentId: segmentId,
      rawTranscript: existing?.rawTranscript ?? transcript,
      memoText: memoText,
      finalTranscript: transcript,
    );
    _finishIfSettled();
    return true;
  }

  void speechStarted(String segmentId) {
    final active = activeMemo;
    if (_disposed || segmentId.isEmpty) {
      return;
    }
    if (active == null) {
      _rememberPendingSpeechStart(segmentId);
      return;
    }
    if (active.status == VoiceMemoStatus.finalizing) {
      return;
    }
    _cancelSilenceTimer();
    _segmentOwners[segmentId] = active.id;
    _openSegments.add(segmentId);
    _awaitingRawSegments.add(segmentId);
    _setActive(
      active.copyWith(status: VoiceMemoStatus.listening, updatedAt: _now()),
    );
    log(
      'Memo',
      '[WorkBench][Memo] state=speech_started '
          'pending_segments=${_awaitingRawSegments.length}',
    );
  }

  void speechEnded(String segmentId) {
    final active = activeMemo;
    if (_disposed || segmentId.isEmpty) {
      return;
    }
    if (active == null) {
      _rememberPendingSpeechEnd(segmentId);
      return;
    }
    if (_segmentOwners[segmentId] != active.id) {
      return;
    }
    _openSegments.remove(segmentId);
    if (active.status == VoiceMemoStatus.finalizing) {
      _finishIfSettled();
      return;
    }
    final remaining = totalSilenceDuration - closedTurnSilenceDuration;
    _armSilenceTimer(remaining.isNegative ? Duration.zero : remaining);
    log(
      'Memo',
      '[WorkBench][Memo] state=silence_waiting '
          'remaining_ms=${max(0, remaining.inMilliseconds)}',
    );
  }

  void requestFinalize({required String reason}) {
    final active = activeMemo;
    if (_disposed || active == null) {
      return;
    }
    _cancelSilenceTimer();
    _setActive(
      active.copyWith(status: VoiceMemoStatus.finalizing, updatedAt: _now()),
    );
    _finalizationTimer?.cancel();
    _finalizationTimer = Timer(finalizationTimeout, () {
      _finalizationTimer = null;
      _finalize(force: true, reason: 'finalization_timeout');
    });
    log(
      'Memo',
      '[WorkBench][Memo] state=finalizing reason=$reason '
          'pending_raw=${_awaitingRawSegments.length} '
          'pending_final=${_awaitingFinalSegments.length}',
    );
    if (_inputRevision > _generatedInputRevision) {
      _requestGeneration();
    }
    _finishIfSettled();
  }

  void handleWearableDisconnect() {
    if (isActive) {
      requestFinalize(reason: 'wearable_disconnected');
    }
  }

  void _startMemo({
    required String segmentId,
    required String rawTranscript,
    required String memoText,
    required String? finalTranscript,
  }) {
    final now = _now();
    final id = 'memo-${now.microsecondsSinceEpoch}';
    final source = VoiceMemoSource(
      segmentId: segmentId,
      rawTranscript: rawTranscript.trim(),
      memoText: memoText.trim(),
      finalTranscript: finalTranscript?.trim(),
    );
    final record = VoiceMemoRecord(
      id: id,
      status: VoiceMemoStatus.listening,
      note: '',
      sources: <VoiceMemoSource>[source],
      revision: 0,
      createdAt: now,
      updatedAt: now,
    );
    _records[id] = record;
    _activeId = id;
    _activationSegmentId = segmentId;
    _segmentOwners[segmentId] = id;
    if (finalTranscript == null) {
      _awaitingFinalSegments.add(segmentId);
    }
    _inputRevision++;
    _generatedInputRevision = -1;
    _persist(record);
    _armSilenceTimer(totalSilenceDuration);
    onChanged();
    log(
      'Memo',
      '[WorkBench][Memo] state=started source=live '
          'has_initial_text=${memoText.trim().isNotEmpty}',
    );
    if (finalTranscript != null && memoText.trim().isNotEmpty) {
      _requestGeneration();
    }
  }

  void _upsertSource({
    required String segmentId,
    required String rawTranscript,
    required String memoText,
    String? finalTranscript,
  }) {
    final active = activeMemo;
    if (active == null) {
      return;
    }
    final sources = active.sources.toList(growable: true);
    final index = sources.indexWhere((source) => source.segmentId == segmentId);
    final next = VoiceMemoSource(
      segmentId: segmentId,
      rawTranscript: rawTranscript.trim(),
      memoText: memoText.trim(),
      finalTranscript: finalTranscript?.trim(),
    );
    final previous = index < 0 ? null : sources[index];
    if (index < 0) {
      sources.add(next);
    } else {
      sources[index] = next;
    }
    final changed =
        previous == null ||
        previous.memoText != next.memoText ||
        previous.finalTranscript != next.finalTranscript;
    _setActive(active.copyWith(sources: sources, updatedAt: _now()));
    if (changed) {
      _inputRevision++;
    }
    if (changed && next.memoText.isNotEmpty && finalTranscript != null) {
      _requestGeneration();
    }
  }

  void _rememberPendingSpeechStart(String segmentId) {
    final now = _now();
    final pending = _pendingSegments.putIfAbsent(
      segmentId,
      () => _PendingMemoSegment(observedAt: now),
    );
    pending
      ..startedAt ??= now
      ..observedAt = now;
    _prunePendingSegments(now);
  }

  void _rememberPendingSpeechEnd(String segmentId) {
    final now = _now();
    final pending = _pendingSegments.putIfAbsent(
      segmentId,
      () => _PendingMemoSegment(observedAt: now),
    );
    pending
      ..endedAt = now
      ..observedAt = now;
    _prunePendingSegments(now);
  }

  void _rememberPendingRaw(String segmentId, String transcript) {
    final now = _now();
    final pending = _pendingSegments.putIfAbsent(
      segmentId,
      () => _PendingMemoSegment(observedAt: now),
    );
    pending
      ..rawTranscript = transcript.trim()
      ..observedAt = now;
    _prunePendingSegments(now);
  }

  void _prunePendingSegments(DateTime now) {
    _pendingSegments.removeWhere(
      (_, pending) =>
          now.difference(pending.observedAt) > pendingSegmentRetention,
    );
    while (_pendingSegments.length > maximumPendingSegments) {
      _pendingSegments.remove(_pendingSegments.keys.first);
    }
  }

  void _claimPendingSegments(String activationSegmentId) {
    final active = activeMemo;
    if (active == null) {
      return;
    }
    final entries = _pendingSegments.entries.toList(growable: false);
    final activationIndex = entries.indexWhere(
      (entry) => entry.key == activationSegmentId,
    );
    if (activationIndex < 0) {
      return;
    }

    DateTime? latestEndedAt = entries[activationIndex].value.endedAt;
    var hasOpenSegment = false;
    for (var index = activationIndex + 1; index < entries.length; index++) {
      final entry = entries[index];
      final segmentId = entry.key;
      final pending = entry.value;
      _segmentOwners[segmentId] = active.id;
      if (pending.startedAt != null && pending.endedAt == null) {
        _openSegments.add(segmentId);
        hasOpenSegment = true;
      }
      final rawTranscript = pending.rawTranscript;
      if (rawTranscript == null || rawTranscript.isEmpty) {
        _awaitingRawSegments.add(segmentId);
      } else {
        _awaitingFinalSegments.add(segmentId);
        _upsertSource(
          segmentId: segmentId,
          rawTranscript: rawTranscript,
          memoText: rawTranscript,
        );
      }
      final endedAt = pending.endedAt;
      if (endedAt != null &&
          (latestEndedAt == null || endedAt.isAfter(latestEndedAt))) {
        latestEndedAt = endedAt;
      }
    }

    for (final entry in entries) {
      _pendingSegments.remove(entry.key);
    }

    if (hasOpenSegment) {
      _cancelSilenceTimer();
    } else if (latestEndedAt != null) {
      final elapsed = _now().difference(latestEndedAt);
      final remaining =
          totalSilenceDuration - closedTurnSilenceDuration - elapsed;
      _armSilenceTimer(remaining.isNegative ? Duration.zero : remaining);
    }
    log(
      'Memo',
      '[WorkBench][Memo] state=pending_claimed '
          'segments=${max(0, entries.length - activationIndex - 1)} '
          'pending_raw=${_awaitingRawSegments.length}',
    );
  }

  void _requestGeneration() {
    if (_disposed || activeMemo == null) {
      return;
    }
    if (_generationActive) {
      _generationRequested = true;
      return;
    }
    unawaited(_generate());
  }

  Future<void> _generate() async {
    final active = activeMemo;
    if (_disposed || active == null || _generationActive) {
      return;
    }
    final utterances = active.sources
        .map((source) => source.memoText.trim())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);
    if (utterances.isEmpty) {
      _finishIfSettled();
      return;
    }
    _generationActive = true;
    _generationRequested = false;
    final inputRevision = _inputRevision;
    if (active.status != VoiceMemoStatus.finalizing) {
      _setActive(
        active.copyWith(status: VoiceMemoStatus.revising, updatedAt: _now()),
      );
    }
    try {
      final modelPath = await _modelPathProvider();
      if (modelPath == null) {
        throw StateError('memo_model_missing');
      }
      final current = activeMemo;
      if (current == null) {
        return;
      }
      final requestInput = _generationInput(current.note, utterances);
      final result = await _client.correct(
        GemmaCorrectionRequest(
          modelPath: modelPath,
          modelId: gemma4E4bModel.id,
          instructions: memoInstructions,
          transcript: requestInput,
          timeoutMs: 30000,
          task: GemmaTextTask.memoRevision,
        ),
      );
      if (_disposed || activeMemo?.id != current.id) {
        return;
      }
      final note = _validateNote(result.correctedText);
      final latest = activeMemo!;
      _setActive(
        latest.copyWith(
          status: latest.status == VoiceMemoStatus.finalizing
              ? VoiceMemoStatus.finalizing
              : VoiceMemoStatus.listening,
          note: note,
          revision: latest.revision + 1,
          updatedAt: _now(),
          clearError: true,
        ),
      );
      log(
        'Memo',
        '[WorkBench][Memo] state=revision_completed '
            'revision=${latest.revision + 1} provider=${result.provider} '
            'input_revision=$inputRevision characters=${note.length}',
      );
    } on Object catch (error) {
      final latest = activeMemo;
      if (latest != null) {
        _setActive(
          latest.copyWith(
            status: latest.status == VoiceMemoStatus.finalizing
                ? VoiceMemoStatus.finalizing
                : VoiceMemoStatus.listening,
            note: latest.note.isEmpty ? _fallbackNote(latest.sources) : null,
            updatedAt: _now(),
            errorCode: _errorCode(error),
          ),
        );
      }
      log(
        'Memo',
        '[WorkBench][Memo] state=revision_failed '
            'error_code=${_errorCode(error)} raw=preserved',
        isError: true,
      );
    } finally {
      _generatedInputRevision = max(_generatedInputRevision, inputRevision);
      _generationActive = false;
      final rerun = _generationRequested || inputRevision != _inputRevision;
      _generationRequested = false;
      if (rerun && activeMemo != null) {
        _requestGeneration();
      } else {
        _finishIfSettled();
      }
    }
  }

  String _generationInput(String currentNote, List<String> utterances) {
    var retained = utterances.toList(growable: true);
    var encoded = jsonEncode(<String, Object>{
      'currentNote': currentNote,
      'utterances': retained,
    });
    while (encoded.length > maximumGenerationInputCharacters &&
        retained.length > 1) {
      retained.removeAt(0);
      encoded = jsonEncode(<String, Object>{
        'currentNote': currentNote,
        'utterances': retained,
      });
    }
    if (encoded.length <= maximumGenerationInputCharacters) {
      return encoded;
    }
    final available = max(
      1,
      maximumGenerationInputCharacters - currentNote.length - 64,
    );
    final newest = retained.last;
    final clipped = newest.length <= available
        ? newest
        : newest.substring(newest.length - available);
    return jsonEncode(<String, Object>{
      'currentNote': currentNote,
      'utterances': <String>[clipped],
    });
  }

  void _armSilenceTimer(Duration duration) {
    _cancelSilenceTimer();
    _silenceTimer = Timer(duration, () {
      _silenceTimer = null;
      requestFinalize(reason: 'five_second_silence');
    });
  }

  void _cancelSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  void _finishIfSettled() {
    final active = activeMemo;
    if (active == null || active.status != VoiceMemoStatus.finalizing) {
      return;
    }
    final owned = active.id;
    final hasOpen = _openSegments.any(
      (segmentId) => _segmentOwners[segmentId] == owned,
    );
    final awaitsRaw = _awaitingRawSegments.any(
      (segmentId) => _segmentOwners[segmentId] == owned,
    );
    if (hasOpen || awaitsRaw || _generationActive || _generationRequested) {
      return;
    }
    _finalize(force: false, reason: 'settled');
  }

  void _finalize({required bool force, required String reason}) {
    final active = activeMemo;
    if (active == null) {
      return;
    }
    _cancelSilenceTimer();
    _finalizationTimer?.cancel();
    _finalizationTimer = null;
    final now = _now();
    final note = active.note.isEmpty
        ? _fallbackNote(active.sources)
        : active.note;
    final finalized = active.copyWith(
      status: VoiceMemoStatus.finalized,
      note: note,
      updatedAt: now,
      finalizedAt: now,
      errorCode: force && active.errorCode == null
          ? 'finalization_timeout'
          : null,
    );
    _records[active.id] = finalized;
    lastFinalizedId = active.id;
    _activeId = null;
    _activationSegmentId = null;
    final completedSegments = _segmentOwners.entries
        .where((entry) => entry.value == active.id)
        .map((entry) => entry.key)
        .toList(growable: false);
    _completedMemoSegments.addAll(completedSegments);
    while (_completedMemoSegments.length > 256) {
      _completedMemoSegments.remove(_completedMemoSegments.first);
    }
    _segmentOwners.removeWhere((_, memoId) => memoId == active.id);
    _openSegments.clear();
    _awaitingRawSegments.clear();
    _awaitingFinalSegments.clear();
    _persist(finalized);
    onChanged();
    log(
      'Memo',
      '[WorkBench][Memo] state=finalized reason=$reason '
          'revision=${finalized.revision} sources=${finalized.sources.length} '
          'characters=${finalized.note.length}',
    );
  }

  void _setActive(VoiceMemoRecord record) {
    if (_activeId != record.id) {
      return;
    }
    _records[record.id] = record;
    _persist(record);
    onChanged();
  }

  void _persist(VoiceMemoRecord record) {
    final operation = _storageTail.then((_) => _store.save(record));
    _storageTail = operation.then<void>(
      (_) {},
      onError: (Object error) {
        log(
          'Memo',
          '[WorkBench][Memo] state=storage_failed '
              'error_code=${_errorCode(error)}',
          isError: true,
        );
      },
    );
  }

  static VoiceMemoSource? _sourceFor(
    VoiceMemoRecord record,
    String segmentId,
  ) => record.sources
      .where((source) => source.segmentId == segmentId)
      .firstOrNull;

  static String _fallbackNote(Iterable<VoiceMemoSource> sources) => sources
      .map((source) => source.memoText.trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n')
      .trim();

  static String _validateNote(String candidate) {
    final note = candidate
        .replaceAll(
          RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'),
          '',
        )
        .trim();
    if (note.isEmpty) {
      throw const FormatException('The memo revision is empty.');
    }
    if (note.length > maximumNoteCharacters) {
      throw const FormatException('The memo revision is too long.');
    }
    return note;
  }

  static String _errorCode(Object error) {
    final value = '$error';
    if (value.contains('memo_model_missing')) {
      return 'model_missing';
    }
    return switch (error) {
      FormatException _ => 'invalid_output',
      TimeoutException _ => 'timeout',
      StateError _ => 'invalid_state',
      _ => 'runtime_failure',
    };
  }

  DateTime _now() => _clock().toUtc();

  Future<void> handleMemoryPressure() async {
    if (!_disposed && !_generationActive) {
      await _client.releaseEngine();
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cancelSilenceTimer();
    _finalizationTimer?.cancel();
    _finalizationTimer = null;
    await _storageTail;
    final active = activeMemo;
    if (active != null) {
      final interrupted = active.copyWith(
        status: VoiceMemoStatus.interrupted,
        note: active.note.isEmpty ? _fallbackNote(active.sources) : null,
        updatedAt: _now(),
        errorCode: 'app_closed',
      );
      _records[active.id] = interrupted;
      await _store.save(interrupted);
    }
    await _client.releaseEngine();
  }
}

final class _PendingMemoSegment {
  _PendingMemoSegment({required this.observedAt});

  DateTime observedAt;
  DateTime? startedAt;
  DateTime? endedAt;
  String? rawTranscript;
}
