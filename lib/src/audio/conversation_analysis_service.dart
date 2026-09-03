import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'conversation_analysis_preferences.dart';
import 'conversation_analysis_worker.dart';
import 'conversation_model_store.dart';
import 'conversation_models.dart';
import 'conversation_record_store.dart';
import 'model_asset_store.dart';
import 'shared_audio_export_store.dart';
import 'speech_model.dart';

typedef ConversationServiceLog =
    void Function(String source, String message, {bool isError});

/// Optional, supervised analysis downstream of the already durable speech WAV.
///
/// No live LC3 or PCM buffer is copied. The primary capture/VAD/STT path closes
/// the WAV first, then offers only its path to this service. This service owns a
/// separate durable queue, isolate, diarizer, and Parakeet recognizer. It is a
/// strictly parallel consumer: none of its startup, inference, persistence,
/// cleanup, memory-pressure, or recovery futures may be awaited by capture,
/// primary transcription, Gemma correction, glasses output, or agent routing.
/// Running both Parakeet instances concurrently is intentional. Never add a
/// correction-driven pause or teardown dependency between these paths.
final class ConversationAnalysisService {
  ConversationAnalysisService({
    required this.log,
    required this.onChanged,
    required SharedAudioExportStore sharedAudioExportStore,
    ConversationAnalysisPreferences preferences =
        const ConversationAnalysisPreferences(),
    ConversationRecordStore? recordStore,
    ConversationModelStore? modelStore,
    ModelAssetStore? speechModelStore,
    DateTime Function() clock = DateTime.now,
  }) : _sharedAudioExportStore = sharedAudioExportStore,
       _preferences = preferences,
       _recordStore = recordStore ?? ConversationRecordStore(),
       _modelStore = modelStore ?? ConversationModelStore(),
       _speechModelStore = speechModelStore ?? ModelAssetStore(),
       _clock = clock;

  static const int _maximumPendingJobs = 32;
  static const Duration _idleWorkerReleaseDelay = Duration(seconds: 30);

  final ConversationServiceLog log;
  final VoidCallback onChanged;
  final SharedAudioExportStore _sharedAudioExportStore;
  final ConversationAnalysisPreferences _preferences;
  final ConversationRecordStore _recordStore;
  final ConversationModelStore _modelStore;
  final ModelAssetStore _speechModelStore;
  final DateTime Function() _clock;
  final Queue<ConversationPendingJob> _jobs = Queue<ConversationPendingJob>();

  ConversationAnalysisSupervisor? _supervisor;
  List<SpeakerProfile> _profiles = const <SpeakerProfile>[];
  bool _initialized = false;
  bool _disposed = false;
  bool _starting = false;
  Completer<void>? _startSettled;
  bool _jobActive = false;
  bool _activeJobEnrollment = false;
  bool _enrollmentRequested = false;
  int? _minimumEnrollmentSegmentMicros;
  Future<void>? _memoryPressureRelease;
  Timer? _idleWorkerReleaseTimer;
  double _speakerMatchThreshold = defaultSpeakerSignatureMatchThreshold;

  bool enabled = false;
  String state = 'disabled';
  String? error;
  int completedConversations = 0;

  bool get isStarting => _starting;
  bool get isReady => _supervisor?.isReady ?? false;
  SpeakerProfile? get _primaryProfile {
    for (final profile in _profiles) {
      if (profile.isPrimary) {
        return profile;
      }
    }
    return null;
  }

  bool get needsEnrollment =>
      enabled &&
      (_primaryProfile == null || _primaryProfile!.enrollmentInProgress);
  bool get isEnrollmentPending =>
      _enrollmentRequested ||
      _activeJobEnrollment ||
      _jobs.any((job) => job.enrollment);
  int get acceptedEnrollmentSamples =>
      _primaryProfile?.acceptedEnrollmentSamples ?? 0;
  int get requiredEnrollmentSamples => minimumPrimarySpeakerEnrollmentSamples;
  double get speakerMatchThreshold => _speakerMatchThreshold;
  int get knownSpeakerCount =>
      _profiles.where((profile) => profile.calibrationComplete).length;
  int get pendingCount => _jobs.length + (_jobActive && _jobs.isEmpty ? 1 : 0);

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    try {
      await _recordStore.initialize();
      _speakerMatchThreshold = await _preferences.loadSpeakerMatchThreshold();
      var storedProfiles = await _recordStore.loadProfiles();
      bool? recoveredEnabled;
      if (storedProfiles.isEmpty) {
        final recovery = await _readSharedRecovery();
        if (recovery != null && recovery.profiles.isNotEmpty) {
          storedProfiles = recovery.profiles;
          _speakerMatchThreshold = recovery.speakerMatchThreshold;
          recoveredEnabled = recovery.enabled;
          await _preferences.saveSpeakerMatchThreshold(_speakerMatchThreshold);
          await _preferences.saveEnabled(recovery.enabled);
          await _recordStore.saveProfiles(storedProfiles);
          log(
            'Conversation',
            '[WorkBench][Conversation] state=signatures_restored '
                'profiles=${storedProfiles.length}',
          );
        }
      }
      _profiles = retainBoundedSpeakerProfiles(storedProfiles);
      if (storedProfiles.length != _profiles.length) {
        await _recordStore.saveProfiles(_profiles);
        log(
          'Conversation',
          '[WorkBench][Conversation] state=profiles_compacted '
              'before=${storedProfiles.length} after=${_profiles.length} '
              'maximum_other=$maximumNonPrimarySpeakerProfiles',
        );
      }
      await _applySpeakerMatchThresholdToPrimary();
      await _reconcilePrimarySpeakerHistoryIfNeeded();
      _jobs.addAll(await _recordStore.loadPendingJobs());
      enabled = recoveredEnabled ?? await _preferences.loadEnabled();
      await _backupSharedRecovery();
      if (!enabled) {
        state = 'disabled';
        onChanged();
        return;
      }
      if (needsEnrollment) {
        _enrollmentRequested = true;
        _minimumEnrollmentSegmentMicros = _nowMicros();
      }
      if (_jobs.isNotEmpty) {
        await _start();
      } else {
        state = _idleState;
        log(
          'Conversation',
          '[WorkBench][Conversation] state=$state worker=on_demand '
              'capture=unaffected transcription=unaffected',
        );
        onChanged();
      }
    } catch (caught) {
      _fail(caught, stateName: 'unavailable');
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_disposed) {
      return;
    }
    enabled = value;
    error = null;
    await _preferences.saveEnabled(value);
    await _backupSharedRecovery();
    if (!value) {
      _idleWorkerReleaseTimer?.cancel();
      _idleWorkerReleaseTimer = null;
      state = 'disabled';
      _enrollmentRequested = false;
      _minimumEnrollmentSegmentMicros = null;
      _jobActive = false;
      _activeJobEnrollment = false;
      _jobs.clear();
      await _persistJobs();
      final supervisor = _supervisor;
      _supervisor = null;
      await supervisor?.dispose();
      log(
        'Conversation',
        '[WorkBench][Conversation] state=disabled '
            'capture=unaffected transcription=unaffected',
      );
      onChanged();
      return;
    }
    if (needsEnrollment) {
      _enrollmentRequested = true;
      _minimumEnrollmentSegmentMicros = _nowMicros();
    }
    if (_jobs.isNotEmpty) {
      await _start();
    } else {
      state = _idleState;
      onChanged();
    }
  }

  Future<void> setSpeakerMatchThreshold(double value) async {
    if (_disposed) {
      return;
    }
    if (_jobActive || _jobs.isNotEmpty) {
      throw StateError(
        'Wait for pending conversation analysis before changing the speaker match threshold.',
      );
    }
    if (!isAdjustableSpeakerSignatureThreshold(value)) {
      throw ArgumentError.value(
        value,
        'value',
        'The speaker match threshold is outside the adjustable range.',
      );
    }
    final normalized = normalizeAdjustableSpeakerSignatureThreshold(value);
    await _preferences.saveSpeakerMatchThreshold(normalized);
    _speakerMatchThreshold = normalized;
    await _applySpeakerMatchThresholdToPrimary();
    await _backupSharedRecovery();
    log(
      'Conversation',
      '[WorkBench][Conversation] state=threshold_saved '
          'signature_match_threshold=${normalized.toStringAsFixed(2)}',
    );
    onChanged();
  }

  Future<void> resetSpeakerIdentification() async {
    if (_disposed) {
      return;
    }
    if (_jobActive || _jobs.isNotEmpty) {
      throw StateError(
        'Wait for pending conversation analysis before resetting speaker identification.',
      );
    }
    await _preferences.saveSpeakerMatchThreshold(
      defaultSpeakerSignatureMatchThreshold,
    );
    _speakerMatchThreshold = defaultSpeakerSignatureMatchThreshold;
    _profiles = retainBoundedSpeakerProfiles(
      retainNonPrimarySpeakerProfiles(_profiles),
    );
    _enrollmentRequested = enabled;
    _minimumEnrollmentSegmentMicros = enabled ? _nowMicros() : null;
    state = enabled ? 'waiting_for_enrollment_speech' : 'disabled';
    error = null;
    onChanged();
    try {
      await _saveProfilesAndBackup();
      log(
        'Conversation',
        '[WorkBench][Conversation] state=speaker_identification_reset '
            'other_speakers_retained=${_profiles.length} '
            'signature_match_threshold='
            '${_speakerMatchThreshold.toStringAsFixed(2)} '
            'conversations_retained=true',
      );
    } catch (caught) {
      _fail(caught, stateName: 'profile_storage_failed');
      rethrow;
    } finally {
      onChanged();
    }
  }

  /// Synchronizes the sensitive speaker profile recovery after the user
  /// selects a shared folder. Existing app-private profiles always win.
  Future<void> syncSharedRecovery() async {
    if (!_initialized || _disposed) {
      return;
    }
    if (_profiles.isNotEmpty) {
      await _backupSharedRecovery();
      return;
    }
    final recovery = await _readSharedRecovery();
    if (recovery == null || recovery.profiles.isEmpty) {
      return;
    }
    _profiles = retainBoundedSpeakerProfiles(recovery.profiles);
    _speakerMatchThreshold = recovery.speakerMatchThreshold;
    enabled = recovery.enabled;
    await _preferences.saveSpeakerMatchThreshold(_speakerMatchThreshold);
    await _preferences.saveEnabled(enabled);
    await _recordStore.saveProfiles(_profiles);
    _enrollmentRequested = enabled && needsEnrollment;
    _minimumEnrollmentSegmentMicros = _enrollmentRequested
        ? _nowMicros()
        : null;
    state = enabled ? _idleState : 'disabled';
    error = null;
    log(
      'Conversation',
      '[WorkBench][Conversation] state=signatures_restored '
          'profiles=${_profiles.length}',
    );
    onChanged();
  }

  /// Called after VAD has atomically finalized the speech WAV.
  ///
  /// This method deliberately returns void so the primary audio pipeline
  /// cannot await conversation analysis.
  void acceptFinalizedSegment(String segmentId, String wavPath) {
    if (!enabled || _disposed || segmentId.isEmpty || wavPath.isEmpty) {
      return;
    }
    _idleWorkerReleaseTimer?.cancel();
    _idleWorkerReleaseTimer = null;
    final enrollment = _enrollmentRequested || needsEnrollment;
    final minimumEnrollmentMicros = _minimumEnrollmentSegmentMicros;
    final segmentStartMicros = _segmentStartMicros(segmentId);
    if (enrollment &&
        minimumEnrollmentMicros != null &&
        segmentStartMicros != null &&
        segmentStartMicros < minimumEnrollmentMicros) {
      state = 'waiting_for_enrollment_speech';
      log(
        'Conversation',
        '[WorkBench][Conversation] state=enrollment_segment_skipped '
            'reason=started_before_reset',
      );
      onChanged();
      return;
    }
    if (enrollment &&
        (_activeJobEnrollment || _jobs.any((job) => job.enrollment))) {
      log(
        'Conversation',
        '[WorkBench][Conversation] state=enrollment_segment_skipped '
            'reason=sample_analysis_in_progress '
            'accepted=$acceptedEnrollmentSamples '
            'required=$requiredEnrollmentSamples',
      );
      onChanged();
      return;
    }
    if (enrollment) {
      _minimumEnrollmentSegmentMicros = null;
    }
    if (_jobs.length >= _maximumPendingJobs) {
      final dropped = _jobs.removeFirst();
      log(
        'Conversation',
        '[WorkBench][Conversation] state=queue_trimmed '
            'segment=${dropped.segmentId} maximum=$_maximumPendingJobs '
            'capture=unaffected transcription=unaffected',
        isError: true,
      );
    }
    _jobs.addLast(
      ConversationPendingJob(
        segmentId: segmentId,
        wavPath: wavPath,
        enrollment: enrollment,
        queuedAt: DateTime.now().toUtc(),
      ),
    );
    state = enrollment ? 'enrolling' : 'queued';
    unawaited(_persistJobs());
    if (_supervisor == null && _memoryPressureRelease == null) {
      unawaited(_start());
    } else {
      _dispatch();
    }
    onChanged();
  }

  Future<void> _start() async {
    if (_starting) {
      final settled = _startSettled;
      if (settled != null) {
        await settled.future;
      }
      if (!_disposed && enabled && !isReady && _jobs.isNotEmpty) {
        await _start();
      }
      return;
    }
    if (_disposed || !enabled || isReady || _jobs.isEmpty) {
      return;
    }
    _idleWorkerReleaseTimer?.cancel();
    _idleWorkerReleaseTimer = null;
    _starting = true;
    _startSettled = Completer<void>();
    state = 'starting';
    error = null;
    onChanged();
    try {
      _status('verifying speaker models');
      final models = await _modelStore.prepare();
      final transcription = await _speechModelStore.prepareTranscriptionModel(
        definition: parakeet110mModel,
        onStatus: (message) => _status(message),
      );
      if (_disposed || !enabled || _jobs.isEmpty) {
        return;
      }
      final supervisor = ConversationAnalysisSupervisor(
        models: models,
        transcription: transcription,
        onResult: _onResult,
        onFailure: _onFailure,
        onStatus: (message, {bool isError = false}) =>
            log('Conversation', message, isError: isError),
        signatureMatchThreshold: _speakerMatchThreshold,
      );
      _supervisor = supervisor;
      await supervisor.start();
      if (_disposed || !enabled || _jobs.isEmpty) {
        if (identical(_supervisor, supervisor)) {
          _supervisor = null;
        }
        await supervisor.dispose();
        return;
      }
      state = needsEnrollment ? 'waiting_for_enrollment_speech' : 'ready';
      if (needsEnrollment) {
        _enrollmentRequested = true;
      }
      log(
        'Conversation',
        '[WorkBench][Conversation] state=$state provider=cpu '
            'independent_stt=${parakeet110mModel.id} '
            'capture=unaffected transcription=unaffected',
      );
      _dispatch();
    } catch (caught) {
      await _supervisor?.dispose();
      _supervisor = null;
      _fail(caught, stateName: 'unavailable');
    } finally {
      _starting = false;
      final settled = _startSettled;
      _startSettled = null;
      if (settled != null && !settled.isCompleted) {
        settled.complete();
      }
      onChanged();
    }
  }

  void _dispatch() {
    final supervisor = _supervisor;
    if (_jobActive ||
        _jobs.isEmpty ||
        supervisor == null ||
        !supervisor.isReady ||
        _disposed) {
      return;
    }
    final job = _jobs.first;
    if (!File(job.wavPath).existsSync()) {
      _jobs.removeFirst();
      unawaited(_persistJobs());
      _dispatch();
      _scheduleIdleWorkerRelease();
      return;
    }
    _jobActive = true;
    _activeJobEnrollment = job.enrollment;
    state = job.enrollment ? 'enrolling' : 'analyzing';
    supervisor.analyze(
      segmentId: job.segmentId,
      wavPath: job.wavPath,
      profiles: _profiles,
      enrollment: job.enrollment,
      signatureMatchThreshold: _speakerMatchThreshold,
    );
    onChanged();
  }

  void _onResult(ConversationAnalysisResult result) {
    unawaited(_retainResult(result));
  }

  Future<void> _retainResult(ConversationAnalysisResult result) async {
    _removeJob(result.record.id);
    await _persistJobs();
    try {
      _profiles = retainBoundedSpeakerProfiles(result.profiles);
      final completedEnrollment = result.enrollment && !needsEnrollment;
      if (completedEnrollment) {
        _enrollmentRequested = false;
        _minimumEnrollmentSegmentMicros = null;
      }
      await _saveProfilesAndBackup();
      await _reconcilePrimarySpeakerHistoryIfNeeded();
      if (!result.enrollment) {
        final retained = await _recordStore.retainRecord(result.record);
        await _sharedAudioExportStore.indexConversation(retained);
        await _sharedAudioExportStore.exportFiles(<String>[retained.textPath]);
        completedConversations++;
      }
      final primary = _primaryProfile;
      if (result.enrollment &&
          (primary == null || primary.enrollmentInProgress)) {
        _enrollmentRequested = true;
        _minimumEnrollmentSegmentMicros = _nowMicros();
        state = 'waiting_for_enrollment_speech';
        error = null;
        log(
          'Conversation',
          '[WorkBench][Conversation] state=enrollment_waiting '
              'accepted=$acceptedEnrollmentSamples '
              'required=$requiredEnrollmentSamples',
        );
      } else {
        _enrollmentRequested = false;
        _minimumEnrollmentSegmentMicros = null;
        state = 'ready';
        error = null;
        if (result.enrollment && primary != null) {
          log(
            'Conversation',
            '[WorkBench][Conversation] state=enrollment_complete '
                'accepted=$requiredEnrollmentSamples '
                'signature_match_threshold='
                '${primary.signatureMatchThreshold.toStringAsFixed(3)}',
          );
        }
      }
    } catch (caught) {
      _fail(caught, stateName: 'storage_failed');
    } finally {
      _jobActive = false;
      _activeJobEnrollment = false;
      _dispatch();
      _scheduleIdleWorkerRelease();
      onChanged();
    }
  }

  void _onFailure(String segmentId, Object caught) {
    final failedEnrollment = _activeJobEnrollment;
    _removeJob(segmentId);
    _jobActive = false;
    _activeJobEnrollment = false;
    error = _oneLine(caught);
    state = failedEnrollment
        ? 'waiting_for_enrollment_speech'
        : 'analysis_failed';
    if (failedEnrollment || needsEnrollment) {
      _enrollmentRequested = true;
      _minimumEnrollmentSegmentMicros = _nowMicros();
    }
    unawaited(_persistJobs());
    _dispatch();
    _scheduleIdleWorkerRelease();
    onChanged();
  }

  Future<void> _reconcilePrimarySpeakerHistoryIfNeeded() async {
    final primary = _primaryProfile;
    if (primary == null ||
        !primary.calibrationComplete ||
        !primary.historyReconciliationPending) {
      return;
    }
    final equivalentScores = <String, double>{};
    final equivalentProfiles = <SpeakerProfile>[];
    for (final profile in _profiles) {
      if (profile.isPrimary || !profile.calibrationComplete) {
        continue;
      }
      final score = speakerProfilesSimilarity(primary, profile);
      if (!speakerSignatureMatches(
        score,
        threshold: primary.signatureMatchThreshold,
      )) {
        continue;
      }
      equivalentProfiles.add(profile);
      equivalentScores[profile.id] = score;
    }

    final reconciliation = await _recordStore.reconcilePrimarySpeaker(
      primary: primary,
      equivalentSpeakerScores: equivalentScores,
    );
    await _sharedAudioExportStore.indexConversations(
      reconciliation.recordsToIndex,
    );
    await _sharedAudioExportStore.exportFiles(reconciliation.updatedTextPaths);

    final equivalentIds = equivalentProfiles
        .map((profile) => profile.id)
        .toSet();
    final consolidated = consolidatePrimarySpeakerProfiles(
      primary,
      equivalentProfiles,
    );
    _profiles = retainBoundedSpeakerProfiles(<SpeakerProfile>[
      consolidated,
      ..._profiles.where(
        (profile) => !profile.isPrimary && !equivalentIds.contains(profile.id),
      ),
    ]);
    await _saveProfilesAndBackup();
    log(
      'Conversation',
      '[WorkBench][Conversation] state=history_reconciled '
          'profiles=${equivalentProfiles.length} '
          'records=${reconciliation.updatedRecordCount} '
          'turns=${reconciliation.updatedTurnCount}',
    );
  }

  Future<void> _applySpeakerMatchThresholdToPrimary() async {
    final primaryIndex = _profiles.indexWhere((profile) => profile.isPrimary);
    if (primaryIndex < 0 ||
        _profiles[primaryIndex].signatureMatchThreshold ==
            _speakerMatchThreshold) {
      return;
    }
    final updated = _profiles.toList(growable: true);
    updated[primaryIndex] = updated[primaryIndex].copyWith(
      signatureMatchThreshold: _speakerMatchThreshold,
    );
    _profiles = retainBoundedSpeakerProfiles(updated);
    await _saveProfilesAndBackup();
  }

  Future<void> _saveProfilesAndBackup() async {
    await _recordStore.saveProfiles(_profiles);
    await _backupSharedRecovery();
  }

  Future<ConversationProfileRecovery?> _readSharedRecovery() async {
    if (!_sharedAudioExportStore.hasSharedFolder) {
      return null;
    }
    try {
      final bytes = await _sharedAudioExportStore
          .readSpeakerSignatureRecovery();
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      return ConversationProfileRecovery.decode(bytes);
    } on Object {
      log(
        'Conversation',
        '[WorkBench][Conversation] state=signature_restore_failed '
            'private_profiles=unchanged',
        isError: true,
      );
      return null;
    }
  }

  Future<void> _backupSharedRecovery() async {
    if (!_sharedAudioExportStore.hasSharedFolder || _profiles.isEmpty) {
      return;
    }
    try {
      final recovery = ConversationProfileRecovery(
        profiles: _profiles,
        enabled: enabled,
        speakerMatchThreshold: _speakerMatchThreshold,
      );
      await _sharedAudioExportStore.writeSpeakerSignatureRecovery(
        recovery.encode(),
      );
      log(
        'Conversation',
        '[WorkBench][Conversation] state=signatures_backed_up '
            'profiles=${_profiles.length}',
      );
    } on Object {
      log(
        'Conversation',
        '[WorkBench][Conversation] state=signature_backup_failed '
            'private_profiles=retained',
        isError: true,
      );
    }
  }

  void _removeJob(String segmentId) {
    if (_jobs.isNotEmpty && _jobs.first.segmentId == segmentId) {
      _jobs.removeFirst();
    } else {
      _jobs.removeWhere((job) => job.segmentId == segmentId);
    }
  }

  Future<void> _persistJobs() async {
    try {
      await _recordStore.savePendingJobs(_jobs);
    } on Object {
      log(
        'Conversation',
        '[WorkBench][Conversation] state=queue_persistence_failed '
            'capture=unaffected transcription=unaffected',
        isError: true,
      );
    }
  }

  int _nowMicros() => _clock().toUtc().microsecondsSinceEpoch;

  void _status(String message) {
    log('Conversation', '[WorkBench][Conversation] state=model $message');
  }

  void _fail(Object caught, {required String stateName}) {
    state = stateName;
    error = _oneLine(caught);
    log(
      'Conversation',
      '[WorkBench][Conversation] state=$stateName '
          'capture=unaffected transcription=unaffected '
          'error=${_oneLine(caught)}',
      isError: true,
    );
    onChanged();
  }

  Future<void> restartWorkerForTest() async {
    await _supervisor?.restartForTest();
  }

  Future<void> handleMemoryPressure() async {
    if (!enabled || _disposed) {
      return;
    }
    _idleWorkerReleaseTimer?.cancel();
    _idleWorkerReleaseTimer = null;
    await _releaseWorker(reason: 'memory_pressure');
    if (_disposed) {
      return;
    }
    state = 'paused_for_memory';
    log(
      'Conversation',
      '[WorkBench][Conversation] state=$state '
          'capture=unaffected transcription=unaffected',
    );
    onChanged();
  }

  Future<void> resumeAfterMemoryPressure() async {
    await _memoryPressureRelease;
    if (!enabled || _disposed) {
      return;
    }
    if (_jobs.isNotEmpty && _supervisor == null) {
      await _start();
      return;
    }
    state = _idleState;
    onChanged();
  }

  String get _idleState =>
      needsEnrollment ? 'waiting_for_enrollment_speech' : 'ready';

  void _scheduleIdleWorkerRelease() {
    _idleWorkerReleaseTimer?.cancel();
    _idleWorkerReleaseTimer = null;
    if (_disposed || _jobActive || _jobs.isNotEmpty || _supervisor == null) {
      return;
    }
    _idleWorkerReleaseTimer = Timer(_idleWorkerReleaseDelay, () {
      _idleWorkerReleaseTimer = null;
      unawaited(_releaseIdleWorker());
    });
  }

  Future<void> _releaseIdleWorker() async {
    if (_disposed || _jobActive || _jobs.isNotEmpty) {
      return;
    }
    await _releaseWorker(reason: 'idle');
    if (_disposed || _jobs.isNotEmpty) {
      return;
    }
    state = _idleState;
    onChanged();
  }

  Future<void> _releaseWorker({required String reason}) async {
    final existing = _memoryPressureRelease;
    if (existing != null) {
      await existing;
      return;
    }
    final release = _disposeWorker(reason: reason);
    _memoryPressureRelease = release;
    try {
      await release;
    } finally {
      if (identical(_memoryPressureRelease, release)) {
        _memoryPressureRelease = null;
      }
    }
  }

  Future<void> _disposeWorker({required String reason}) async {
    final supervisor = _supervisor;
    _supervisor = null;
    _jobActive = false;
    _activeJobEnrollment = false;
    await supervisor?.dispose();
    if (supervisor != null && !_disposed) {
      log(
        'Conversation',
        '[WorkBench][Conversation] state=worker_released reason=$reason '
            'capture=unaffected transcription=unaffected',
      );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _idleWorkerReleaseTimer?.cancel();
    _idleWorkerReleaseTimer = null;
    await _memoryPressureRelease;
    await _persistJobs();
    await _supervisor?.dispose();
    _supervisor = null;
  }
}

String _oneLine(Object value) =>
    '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();

int? _segmentStartMicros(String segmentId) {
  final separator = segmentId.indexOf('-');
  final prefix = separator < 0 ? segmentId : segmentId.substring(0, separator);
  final value = int.tryParse(prefix);
  return value == null || value < 1 ? null : value;
}
