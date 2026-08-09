import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../startup/startup_state.dart';
import 'capture_journal.dart';
import 'continuous_transcript_store.dart';
import 'gemma_model.dart';
import 'inference_capabilities.dart';
import 'lc3_decoder.dart';
import 'model_asset_store.dart';
import 'pcm_gain.dart';
import 'shared_audio_export_store.dart';
import 'speech_model.dart';
import 'transcript_turn_state.dart';
import 'transcript_correction_config.dart';
import 'transcript_correction_supervisor.dart';
import 'transcript_turn_assembler.dart';
import 'transcription_worker.dart';
import 'vad_worker.dart';

typedef AudioPipelineLog =
    void Function(String source, String message, {bool isError});
typedef TranscriptHandler =
    Future<void> Function(String segmentId, String transcript);
typedef FinalTranscriptHandler =
    Future<void> Function(FinalTranscriptDelivery delivery);
typedef CorrectionTermsProvider = Iterable<String> Function();
typedef ExplicitCorrectionEligibilityProvider = bool Function(String segmentId);
typedef FinalizedSpeechSegmentHandler =
    void Function(String segmentId, String wavPath);

/// Fans a durable speech WAV out to two strictly independent paths.
///
/// Primary STT must always be dispatched first. Conversation analysis is an
/// optional parallel consumer and must never become an awaited dependency of
/// primary STT, correction, or delivery, even when its handoff is slow or
/// fails.
void dispatchFinalizedSpeechConsumers({
  required void Function() dispatchPrimaryTranscription,
  required void Function(Object error) onConversationDispatchError,
  void Function()? dispatchConversationAnalysis,
}) {
  dispatchPrimaryTranscription();
  final conversation = dispatchConversationAnalysis;
  if (conversation == null) {
    return;
  }
  unawaited(
    Future<void>(() => conversation()).catchError((Object error) {
      onConversationDispatchError(error);
    }),
  );
}

final class FinalTranscriptDelivery {
  const FinalTranscriptDelivery({
    required this.segmentId,
    required this.rawTranscript,
    required this.transcript,
    required this.isCorrected,
  });

  final String segmentId;
  final String rawTranscript;
  final String transcript;
  final bool isCorrected;
}

final class AudioPipelineCoordinator {
  AudioPipelineCoordinator({
    required this.log,
    required this.onChanged,
    required this.onCaptureUnsafe,
    required SharedAudioExportStore sharedAudioExportStore,
    this.onQueuedTranscript,
    this.onFinalTranscript,
    this.onFinalizedSpeechSegment,
    this.onVadSpeechEvent,
    this.correctionTermsProvider,
    this.explicitCorrectionEligibilityProvider,
    ModelAssetStore? modelStore,
    GemmaModelStore? gemmaModelStore,
    TranscriptCorrectionConfigStore? correctionConfigStore,
    Lc3Decoder? decoder,
  }) : _modelStore = modelStore ?? ModelAssetStore(),
       _gemmaModelStore = gemmaModelStore ?? GemmaModelStore(),
       _correctionConfigStore =
           correctionConfigStore ??
           TranscriptCorrectionConfigStore(
             sharedInstructionsAvailable: () =>
                 sharedAudioExportStore.hasSharedFolder,
             sharedInstructionsReader:
                 sharedAudioExportStore.readCorrectionInstructions,
             sharedInstructionsWriter:
                 sharedAudioExportStore.writeCorrectionInstructions,
           ),
       _decoder = decoder ?? Lc3Decoder(),
       _sharedAudioExportStore = sharedAudioExportStore {
    _correctionConfigStore.addListener(onChanged);
  }

  static const int _maximumVadRecoveryBytes = 16000 * 2 * 30;
  static const int _maximumPendingDecodePackets = 600;

  final AudioPipelineLog log;
  final void Function() onChanged;
  final void Function() onCaptureUnsafe;
  final TranscriptHandler? onQueuedTranscript;
  final FinalTranscriptHandler? onFinalTranscript;
  final FinalizedSpeechSegmentHandler? onFinalizedSpeechSegment;
  final VadSpeechEventSink? onVadSpeechEvent;
  final CorrectionTermsProvider? correctionTermsProvider;
  final ExplicitCorrectionEligibilityProvider?
  explicitCorrectionEligibilityProvider;
  final ModelAssetStore _modelStore;
  final GemmaModelStore _gemmaModelStore;
  final TranscriptCorrectionConfigStore _correctionConfigStore;
  final Lc3Decoder _decoder;
  final SharedAudioExportStore _sharedAudioExportStore;
  final Queue<_CapturedLc3Packet> _decodeQueue = Queue<_CapturedLc3Packet>();
  final Queue<Uint8List> _vadRecovery = Queue<Uint8List>();
  final TranscriptTurnState _transcriptTurn = TranscriptTurnState();
  final Map<String, VadSpeechSegment> _speechSegments =
      <String, VadSpeechSegment>{};

  CaptureJournalSupervisor? _capture;
  VadSupervisor? _vad;
  TranscriptionSupervisor? _transcription;
  TranscriptCorrectionSupervisor? _correction;
  TranscriptTurnAssembler? _transcriptTurnAssembler;
  Future<void>? _decodePump;
  Future<void> _transcriptHandlingTail = Future<void>.value();
  bool _initialized = false;
  bool _initialStartupComplete = false;
  bool _disposed = false;
  bool _vadWasReady = false;
  VadEndpointMode _vadEndpointMode = VadEndpointMode.defaultFlow;
  bool _modelSwitching = false;
  bool _refreshSharedTranscriptsAfterExport = false;
  bool _decodeBackpressureReported = false;
  int _vadRecoveryBytes = 0;
  int _meterSamples = 0;
  double _meterSquareSum = 0;
  int _meterPeak = 0;
  DateTime? _meterStartedAt;
  SpeechModelDefinition _selectedModel = defaultSpeechModel();
  TranscriptionModelPaths? _transcriptionPaths;
  String? _speechPath;
  List<String>? _inferenceProviders;
  int _sharedExportOperations = 0;

  StartupSnapshot startup = const StartupSnapshot.starting();
  String? audioFolder;
  String? activeModelId;
  String? activeModelName;
  String? activeProvider;
  String? activeVadProvider;
  String? activeCorrectionProvider;
  String? get lastTranscript => _transcriptTurn.visibleText;
  String? lastCorrectedTranscript;
  String? lastTranscriptPath;
  String? lastCorrectedTranscriptPath;
  String? sharedExportError;
  int sharedExportedFiles = 0;
  int completedTranscripts = 0;
  int completedCorrections = 0;

  bool get canConnect => startup.isReady;
  bool get isSwitchingModel => _modelSwitching;
  bool get isExportingSharedAudio => _sharedExportOperations > 0;
  String get selectedModelId => _selectedModel.id;
  TranscriptCorrectionConfig get correctionConfig =>
      _correctionConfigStore.config;
  String? get correctionConfigValidationError =>
      _correctionConfigStore.validationError;
  String get correctionState => _correction?.state ?? 'starting';
  int get pendingCorrections => _correction?.pendingCount ?? 0;

  void setSharedTranscriptRefreshEnabled(bool enabled) {
    _refreshSharedTranscriptsAfterExport = enabled;
  }

  Future<void> initialize({SpeechModelDefinition? transcriptionModel}) async {
    if (_initialized || _disposed) {
      return;
    }
    final requestedModel = transcriptionModel ?? _selectedModel;
    _initialized = true;
    try {
      try {
        await _correctionConfigStore.initialize();
      } catch (error) {
        log(
          'Pipeline',
          '[WorkBench][CorrectionConfig] state=unavailable '
              'error=${_oneLine(error)} correction=disabled',
          isError: true,
        );
      }
      _setStartup(StartupPhase.storage, 'Preparing safe local audio storage…');
      final paths = await _modelStore.prepare(
        transcriptionModel: requestedModel,
        onStatus: (message) {
          _setStartup(StartupPhase.storage, message);
        },
      );
      audioFolder = paths.audioRoot;

      _capture = CaptureJournalSupervisor(
        rootPath: '${paths.audioRoot}/journal',
        onCaptured: _decodeCaptured,
        onStatus: _pipelineStatus,
        onFatalBackpressure: onCaptureUnsafe,
      );
      await _capture!.start();

      _setStartup(StartupPhase.decoder, 'Checking the LC3 audio decoder…');
      await _decoder.initialize();
      log(
        'Pipeline',
        '[WorkBench][Decoder] state=ready sample_rate=16000 '
            'pcm_gain=${g2PcmGain}x',
      );

      _setStartup(
        StartupPhase.transcription,
        'Checking on-device acceleration…',
      );
      final capabilities = await InferenceCapabilities.detect();
      _inferenceProviders = capabilities.providers;
      log(
        'Pipeline',
        '[WorkBench][Inference] '
            'gpu_hardware=${capabilities.hasGpuHardware} '
            'nnapi_api=${capabilities.hasNnapiApi} '
            'providers=${capabilities.providers.join(',')} '
            'runtime=${capabilities.description}',
      );

      _setStartup(StartupPhase.vad, 'Loading voice activity detection…');
      _vad = VadSupervisor(
        modelPath: paths.vad,
        outputPath: '${paths.audioRoot}/speech',
        providers: capabilities.providers,
        onSegment: _onSpeechSegment,
        onStatus: _vadStatus,
        onSpeechEvent: onVadSpeechEvent,
        endpointMode: _vadEndpointMode,
      );
      activeVadProvider = await _vad!.start();
      _vadWasReady = true;

      _speechPath = '${paths.audioRoot}/speech';
      _transcriptTurnAssembler = TranscriptTurnAssembler(
        store: ContinuousTranscriptStore(speechPath: _speechPath!),
      );
      _transcription = TranscriptionSupervisor(
        model: paths.transcription,
        speechPath: _speechPath!,
        providers: capabilities.providers,
        onTranscript: _onTranscript,
        onStatus: _transcriptionStatus,
      );
      _transcriptionPaths = paths.transcription;
      activeModelId = paths.transcription.definition.id;
      activeModelName = paths.transcription.definition.displayName;
      activeProvider = await _transcription!.start();
      _selectedModel = requestedModel;
      final correction = TranscriptCorrectionSupervisor(
        speechPath: _speechPath!,
        configStore: _correctionConfigStore,
        modelStore: _gemmaModelStore,
        onCorrected: _onCorrectedTranscript,
        onUncorrected: _onUncorrectedTranscript,
        onStatus: _correctionStatus,
      );
      try {
        await correction.start();
        _correction = correction;
      } catch (error) {
        await correction.dispose();
        log(
          'Pipeline',
          '[WorkBench][Correction] state=unavailable '
              'error=${_oneLine(error)} raw_transcription=available',
          isError: true,
        );
      }

      _setStartup(
        StartupPhase.ready,
        'Local audio ready · $activeModelName · $activeProvider',
        provider: activeProvider,
      );
      log(
        'Pipeline',
        '[WorkBench][Pipeline] state=ready '
            'model=${paths.transcription.definition.id} '
            'stt_provider=$activeProvider '
            'vad_provider=$activeVadProvider',
      );
      _initialStartupComplete = true;
      if (_sharedAudioExportStore.hasSharedFolder) {
        unawaited(syncSharedAudioExport());
      }
    } catch (error, stackTrace) {
      _setStartup(
        StartupPhase.failed,
        'Local audio could not start: ${_oneLine(error)}',
      );
      log(
        'Pipeline',
        '[WorkBench][Pipeline] state=failed error=${_oneLine(error)} '
            'stack=${_oneLine(stackTrace)}',
        isError: true,
      );
      rethrow;
    }
  }

  void acceptLc3(Uint8List packet) {
    if (_disposed || !_initialized || packet.isEmpty) {
      return;
    }
    _capture?.accept(packet);
  }

  void _decodeCaptured(int sequence, Uint8List packet) {
    if (_disposed || _decodeBackpressureReported) {
      return;
    }
    if (_decodeQueue.length >= _maximumPendingDecodePackets) {
      _decodeBackpressureReported = true;
      log(
        'Pipeline',
        '[WorkBench][Decoder] state=failed reason=pending_overflow '
            'pending=${_decodeQueue.length}',
        isError: true,
      );
      onCaptureUnsafe();
      return;
    }
    _decodeQueue.addLast(_CapturedLc3Packet(sequence: sequence, bytes: packet));
    _startDecodePump();
  }

  void _startDecodePump() {
    if (_disposed || _decodePump != null || _decodeQueue.isEmpty) {
      return;
    }
    final pump = _pumpDecodeQueue();
    _decodePump = pump;
    unawaited(
      pump.whenComplete(() {
        _decodePump = null;
        if (!_disposed && _decodeQueue.isNotEmpty) {
          _startDecodePump();
        }
      }),
    );
  }

  Future<void> _pumpDecodeQueue() async {
    while (!_disposed && _decodeQueue.isNotEmpty) {
      final captured = _decodeQueue.removeFirst();
      try {
        final decoded = await _decoder.decode(captured.bytes);
        final pcm = applyG2PcmGain(decoded);
        _meterPcm(pcm);
        final vad = _vad;
        if (vad?.isReady ?? false) {
          vad!.acceptPcm(pcm);
        } else {
          _queueVadRecovery(pcm);
        }
      } catch (error) {
        log(
          'Pipeline',
          '[WorkBench][Decoder] state=failed sequence=${captured.sequence} '
              'error=${_oneLine(error)}',
          isError: true,
        );
      }
    }
  }

  Future<void> _drainDecodeQueue() async {
    while (_decodePump != null) {
      await _decodePump!.catchError((Object _) {});
    }
  }

  void _meterPcm(Uint8List pcm) {
    final data = ByteData.sublistView(pcm);
    for (var offset = 0; offset + 1 < pcm.length; offset += 2) {
      final sample = data.getInt16(offset, Endian.little);
      final magnitude = sample.abs();
      if (magnitude > _meterPeak) {
        _meterPeak = magnitude;
      }
      _meterSquareSum += sample * sample;
      _meterSamples++;
    }
    final now = DateTime.now();
    _meterStartedAt ??= now;
    if (now.difference(_meterStartedAt!) < const Duration(seconds: 1) ||
        _meterSamples == 0) {
      return;
    }
    final rms = sqrt(_meterSquareSum / _meterSamples);
    log(
      'PCM',
      '[WorkBench][PCM] rms=${rms.toStringAsFixed(1)} '
          'peak=$_meterPeak samples=$_meterSamples',
    );
    _meterSamples = 0;
    _meterSquareSum = 0;
    _meterPeak = 0;
    _meterStartedAt = now;
  }

  void _queueVadRecovery(Uint8List pcm) {
    final stable = Uint8List.fromList(pcm);
    _vadRecovery.addLast(stable);
    _vadRecoveryBytes += stable.length;
    while (_vadRecoveryBytes > _maximumVadRecoveryBytes &&
        _vadRecovery.isNotEmpty) {
      _vadRecoveryBytes -= _vadRecovery.removeFirst().length;
    }
  }

  void _replayVadRecovery() {
    final vad = _vad;
    if (vad == null || !vad.isReady || _vadRecovery.isEmpty) {
      return;
    }
    for (final pcm in _vadRecovery) {
      vad.acceptPcm(pcm);
    }
    log(
      'Pipeline',
      '[WorkBench][VAD] state=recovered '
          'pcm_bytes=$_vadRecoveryBytes',
    );
    _vadRecovery.clear();
    _vadRecoveryBytes = 0;
  }

  void _onSpeechSegment(VadSpeechSegment segment) {
    final id = segment.id;
    final wavPath = segment.wavPath;
    _speechSegments[id] = segment;
    unawaited(
      _exportSharedFiles(<String>[wavPath], reason: 'audio', segmentId: id),
    );
    dispatchFinalizedSpeechConsumers(
      dispatchPrimaryTranscription: () =>
          _transcription?.transcribe(id, wavPath),
      dispatchConversationAnalysis: onFinalizedSpeechSegment == null
          ? null
          : () => onFinalizedSpeechSegment!(id, wavPath),
      onConversationDispatchError: (error) {
        log(
          'Conversation',
          '[WorkBench][Conversation] state=handoff_failed segment=$id '
              'capture=unaffected transcription=unaffected '
              'error=${_oneLine(error)}',
          isError: true,
        );
      },
    );
  }

  void _onTranscript(TranscriptionResult result) {
    final segment = _speechSegments.remove(result.segmentId);
    final operation = _transcriptHandlingTail.then(
      (_) => _processTranscript(result, segment),
    );
    _transcriptHandlingTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        log(
          'Pipeline',
          '[WorkBench][Transcript] state=handling_failed '
              'segment=${result.segmentId} error=${_oneLine(error)} '
              'raw=preserved',
          isError: true,
        );
      },
    );
  }

  Future<void> _processTranscript(
    TranscriptionResult result,
    VadSpeechSegment? segment,
  ) async {
    final id = result.segmentId;
    lastTranscriptPath = result.transcriptPath;
    var displayedText = result.text;
    String? actionText = segment == null || segment.isConversationFinal
        ? result.text.trim()
        : null;
    final exportPaths = <String>[result.transcriptPath];
    final turnAssembler = _transcriptTurnAssembler;
    if (result.routeEligible && segment != null && turnAssembler != null) {
      try {
        final assembly = await turnAssembler.append(
          conversationId: segment.conversationId,
          text: result.text,
          isConversationFinal: segment.isConversationFinal,
          deduplicateOverlap: segment.leadingOverlapMs > 0,
        );
        displayedText = assembly.text;
        actionText = assembly.actionText;
        lastTranscriptPath = assembly.path;
        exportPaths.add(assembly.path);
        log(
          'Pipeline',
          '[WorkBench][Transcript] state=conversation_saved '
              'segment=$id final=${segment.isConversationFinal}',
        );
      } on Object catch (error) {
        log(
          'Pipeline',
          '[WorkBench][Transcript] state=conversation_save_failed '
              'segment=$id raw=preserved error=${_oneLine(error)}',
          isError: true,
        );
      }
    }
    unawaited(
      _exportSharedFiles(exportPaths, reason: 'transcript', segmentId: id),
    );
    completedTranscripts++;
    final displayed = _transcriptTurn.completeTurn(
      segment?.conversationId ?? id,
      displayedText,
    );
    if (!displayed) {
      log(
        'Pipeline',
        '[WorkBench][TranscriptUI] state=suppressed segment=$id '
            'latest=${_transcriptTurn.currentSegmentId ?? 'none'}',
      );
    }
    if (!result.routeEligible) {
      log(
        'Pipeline',
        '[WorkBench][VoiceRoute] state=suppressed segment=$id '
            'reason=recovered_transcription',
      );
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Local audio ready · $activeModelName · $activeProvider',
        provider: activeProvider,
      );
      onChanged();
      return;
    }
    final routableText = actionText;
    if (routableText == null) {
      log(
        'Pipeline',
        '[WorkBench][VoiceRoute] state=collecting segment=$id '
            'reason=conversation_continues action=deferred',
      );
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Listening · transcription queue remains active',
        provider: activeProvider,
      );
      onChanged();
      return;
    }
    final correction = _correction;
    final correctionTerms =
        correctionTermsProvider?.call().toList(growable: false) ??
        const <String>[];
    final correctionJob = TranscriptCorrectionJob(
      segmentId: id,
      rawPath: result.transcriptPath,
      sttModel: result.model,
      sttProvider: result.provider,
      audioMs: result.audioMs,
      sttDecodeMs: result.decodeMs,
      sttTotalMs: result.totalMs,
      queuedAt: result.queuedAt,
      correctionTerms: correctionTerms,
      routeWhenCorrected: true,
      liveTranscript: routableText,
    );
    if (routableText.isEmpty) {
      log(
        'Pipeline',
        '[WorkBench][VoiceRoute] state=suppressed segment=$id '
            'reason=overlap_only',
      );
      await TranscriptCorrectionSupervisor.persistSkipped(
        correctionJob,
        reason: 'overlap_only',
      );
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Local audio ready · $activeModelName · $activeProvider',
        provider: activeProvider,
      );
      onChanged();
      return;
    }
    final queuedTranscriptHandler = onQueuedTranscript;
    if (queuedTranscriptHandler != null) {
      await _publishTranscript(queuedTranscriptHandler, id, routableText);
    }
    final explicitlyTargeted =
        explicitCorrectionEligibilityProvider?.call(id) ?? false;
    final correctionEligible = isLiveTranscriptCorrectionEligible(
      routableText,
      explicitlyTargeted: explicitlyTargeted,
    );
    if (correction != null) {
      if (correctionEligible) {
        log(
          'Pipeline',
          '[WorkBench][VoiceRoute] state=awaiting_correction segment=$id '
              'source=${explicitlyTargeted ? 'selected_agent' : 'wake_word'} '
              'terms=${correctionTerms.length}',
        );
        await correction.queue(correctionJob, prioritize: explicitlyTargeted);
      } else {
        log(
          'Pipeline',
          '[WorkBench][VoiceRoute] state=correction_skipped segment=$id '
              'reason=no_wake_word',
        );
        await correction.skipIneligible(
          correctionJob,
          routableText,
          reason: 'no_wake_word',
        );
      }
    } else {
      await TranscriptCorrectionSupervisor.persistSkipped(
        correctionJob,
        reason: correctionEligible ? 'correction_unavailable' : 'no_wake_word',
      );
      final finalTranscriptHandler = onFinalTranscript;
      if (finalTranscriptHandler != null) {
        log(
          'Pipeline',
          '[WorkBench][VoiceRoute] state=raw_fallback segment=$id '
              'reason=${correctionEligible ? 'correction_unavailable' : 'no_wake_word'}',
        );
        await _publishFinalTranscript(
          finalTranscriptHandler,
          FinalTranscriptDelivery(
            segmentId: id,
            rawTranscript: routableText,
            transcript: routableText,
            isCorrected: false,
          ),
        );
      }
    }
    startup = StartupSnapshot(
      phase: StartupPhase.ready,
      message: 'Local audio ready · $activeModelName · $activeProvider',
      provider: activeProvider,
    );
    onChanged();
  }

  Future<void> _publishTranscript(
    TranscriptHandler handler,
    String segmentId,
    String transcript,
  ) async {
    try {
      await handler(segmentId, transcript);
    } on Object catch (error) {
      log(
        'Pipeline',
        '[WorkBench][TranscriptDisplay] state=failed '
            'error=${_oneLine(error)}',
        isError: true,
      );
    }
  }

  Future<void> _publishFinalTranscript(
    FinalTranscriptHandler handler,
    FinalTranscriptDelivery delivery,
  ) async {
    try {
      await handler(delivery);
    } on Object catch (error) {
      log(
        'Pipeline',
        '[WorkBench][TranscriptDisplay] state=failed '
            'error=${_oneLine(error)}',
        isError: true,
      );
    }
  }

  void _onCorrectedTranscript(CorrectedTranscriptResult result) {
    lastCorrectedTranscript = result.correctedText;
    lastCorrectedTranscriptPath = result.correctedPath;
    activeCorrectionProvider = result.provider;
    completedCorrections++;
    unawaited(
      _exportSharedFiles(
        <String>[result.correctedPath],
        reason: 'correction',
        segmentId: result.segmentId,
      ),
    );
    if (result.routeWhenCorrected) {
      final finalTranscriptHandler = onFinalTranscript;
      if (finalTranscriptHandler != null) {
        log(
          'Pipeline',
          '[WorkBench][VoiceRoute] state=corrected_ready '
              'segment=${result.segmentId} provider=${result.provider}',
        );
        unawaited(
          _publishFinalTranscript(
            finalTranscriptHandler,
            FinalTranscriptDelivery(
              segmentId: result.segmentId,
              rawTranscript: result.originalText,
              transcript: result.correctedText,
              isCorrected: true,
            ),
          ),
        );
      }
    } else {
      log(
        'Pipeline',
        '[WorkBench][VoiceRoute] state=suppressed '
            'segment=${result.segmentId} reason=recovered_job',
      );
    }
    onChanged();
  }

  void _onUncorrectedTranscript(
    TranscriptCorrectionJob job,
    String transcript,
    String reason,
  ) {
    if (!job.routeWhenCorrected) {
      log(
        'Pipeline',
        '[WorkBench][VoiceRoute] state=suppressed '
            'segment=${job.segmentId} reason=recovered_job',
      );
      return;
    }
    final finalTranscriptHandler = onFinalTranscript;
    if (finalTranscriptHandler == null) {
      return;
    }
    log(
      'Pipeline',
      '[WorkBench][VoiceRoute] state=raw_fallback '
          'segment=${job.segmentId} reason=$reason',
    );
    unawaited(
      _publishFinalTranscript(
        finalTranscriptHandler,
        FinalTranscriptDelivery(
          segmentId: job.segmentId,
          rawTranscript: transcript,
          transcript: transcript,
          isCorrected: false,
        ),
      ),
    );
  }

  Future<void> syncSharedAudioExport() async {
    final speechPath = _speechPath;
    if (speechPath == null || !_sharedAudioExportStore.hasSharedFolder) {
      return;
    }
    final directory = Directory(speechPath);
    if (!await directory.exists()) {
      return;
    }
    final paths = await directory
        .list()
        .where(
          (entity) =>
              entity is File &&
              (entity.path.endsWith('.wav') || entity.path.endsWith('.txt')),
        )
        .map((entity) => entity.path)
        .toList();
    await _exportSharedFiles(paths, reason: 'sync');
  }

  Future<void> _exportSharedFiles(
    Iterable<String> paths, {
    required String reason,
    String? segmentId,
  }) async {
    if (!_sharedAudioExportStore.hasSharedFolder) {
      return;
    }
    _sharedExportOperations++;
    sharedExportError = null;
    onChanged();
    var refreshTranscriptions = false;
    try {
      final count = await _sharedAudioExportStore.exportFiles(paths);
      sharedExportedFiles += count;
      refreshTranscriptions =
          _refreshSharedTranscriptsAfterExport &&
          (reason == 'transcript' ||
              reason == 'correction' ||
              reason == 'sync');
      log(
        'Pipeline',
        '[WorkBench][SharedStorage] state=exported reason=$reason '
            'files=$count${segmentId == null ? '' : ' segment=$segmentId'}',
      );
    } catch (error) {
      sharedExportError =
          'Shared-folder export failed. Choose the save folder again.';
      log(
        'Pipeline',
        '[WorkBench][SharedStorage] state=failed reason=$reason '
            'error=${_oneLine(error)}',
        isError: true,
      );
    } finally {
      _sharedExportOperations--;
      onChanged();
    }
    if (refreshTranscriptions) {
      try {
        await _sharedAudioExportStore.refreshTranscriptions();
      } catch (error) {
        log(
          'Pipeline',
          '[WorkBench][SharedStorage] state=list_failed '
              'error=${_oneLine(error)}',
          isError: true,
        );
      }
    }
  }

  void _pipelineStatus(String message, {bool isError = false}) {
    log('Pipeline', message, isError: isError);
  }

  void _vadStatus(String message, {bool isError = false}) {
    log('Pipeline', message, isError: isError);
    if (message.contains('state=ready')) {
      activeVadProvider =
          RegExp(r'provider=(\S+)').firstMatch(message)?.group(1) ??
          activeVadProvider;
    }
    if (message.contains('state=speech_started')) {
      final segmentId = RegExp(
        r'\bsegment=(\S+)',
      ).firstMatch(message)?.group(1);
      if (segmentId != null) {
        _transcriptTurn.startTurn(segmentId);
        log(
          'Pipeline',
          '[WorkBench][TranscriptUI] state=cleared '
              'reason=speech_started segment=$segmentId',
        );
        onChanged();
      }
    }
    final ready = message.contains('state=ready');
    if (!ready && (message.contains('state=restarting') || isError)) {
      _vadWasReady = false;
      if (startup.isReady) {
        startup = StartupSnapshot(
          phase: StartupPhase.degraded,
          message: 'Audio safely recording · restarting voice detection…',
          provider: activeProvider,
          recoverable: true,
        );
        onChanged();
      }
    } else if (ready && !_vadWasReady) {
      _vadWasReady = true;
      _replayVadRecovery();
      if (startup.phase == StartupPhase.degraded) {
        startup = StartupSnapshot(
          phase: StartupPhase.ready,
          message: 'Voice detection recovered · audio remained safe',
          provider: activeProvider,
        );
        onChanged();
      }
    }
  }

  void _transcriptionStatus(String message, {bool isError = false}) {
    log('Pipeline', message, isError: isError);
    if (!_initialStartupComplete) {
      if (message.contains('state=loading')) {
        final provider = RegExp(
          r'provider=(\S+)',
        ).firstMatch(message)?.group(1);
        _setStartup(
          StartupPhase.transcription,
          'Loading transcription${provider == null ? '' : ' · $provider'}…',
        );
      }
      return;
    }
    if (message.contains('state=restarting') ||
        message.contains('state=failed')) {
      startup = StartupSnapshot(
        phase: StartupPhase.degraded,
        message: 'Audio safely recording · restarting transcription…',
        provider: activeProvider,
        recoverable: true,
      );
      onChanged();
    } else if (message.contains('state=ready') &&
        message.contains('recovered=true')) {
      activeProvider =
          RegExp(r'provider=(\S+)').firstMatch(message)?.group(1) ??
          activeProvider;
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Transcription recovered · audio remained safe',
        provider: activeProvider,
      );
      onChanged();
    } else if (message.contains('state=processing')) {
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Transcribing speech locally…',
        provider: activeProvider,
      );
      onChanged();
    }
  }

  void _correctionStatus(String message, {bool isError = false}) {
    log('Pipeline', message, isError: isError);
    final provider = RegExp(r'provider=(\S+)').firstMatch(message)?.group(1);
    if (provider != null && message.contains('state=completed')) {
      activeCorrectionProvider = provider;
    }
    onChanged();
  }

  Future<void> saveCorrectionInstructions(String instructions) =>
      _correctionConfigStore.saveInstructions(instructions);

  Future<void> resetCorrectionInstructions() =>
      _correctionConfigStore.resetInstructions();

  Future<void> setCorrectionEnabled(bool enabled) =>
      _correctionConfigStore.setEnabled(enabled);

  Future<void> syncSharedCorrectionInstructions() async {
    await _correctionConfigStore.reloadForNextTranscript();
    final rejected = _correctionConfigStore.validationError != null;
    log(
      'Pipeline',
      '[WorkBench][CorrectionConfig] '
          'state=${rejected ? 'shared_rejected' : 'shared_synced'} '
          '${rejected ? 'fallback=last_validated' : 'applies=next_transcript'}',
      isError: rejected,
    );
  }

  Future<void> handleMemoryPressure() async {
    await _correction?.releaseIdleEngine();
  }

  void _setStartup(StartupPhase phase, String message, {String? provider}) {
    startup = StartupSnapshot(
      phase: phase,
      message: message,
      provider: provider,
    );
    onChanged();
  }

  void handleWearableDisconnect({required bool expected}) {
    _transcriptTurn.endSession();
    _vad?.flush();
    log(
      'Pipeline',
      '[WorkBench][Bluetooth] state=disconnected expected=$expected '
          'capture=preserved transcription=available',
    );
    log(
      'Pipeline',
      '[WorkBench][TranscriptUI] state=cleared reason=disconnect',
    );
    if (startup.isReady) {
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: expected
            ? 'Devices disconnected · local models remain ready'
            : 'Connection lost · audio flushed safely · reconnecting…',
        provider: activeProvider,
      );
    }
    onChanged();
  }

  void handleWearableReconnect() {
    log(
      'Pipeline',
      '[WorkBench][Bluetooth] state=connected recovered=true '
          'capture=ready transcription=available',
    );
    if (startup.isReady) {
      startup = StartupSnapshot(
        phase: StartupPhase.ready,
        message: 'Connection recovered · local audio ready',
        provider: activeProvider,
      );
      onChanged();
    }
  }

  Future<void> restartTranscriptionForTest() async {
    await _transcription?.restartForTest();
  }

  Future<void> restartVadForTest() async {
    await _vad?.restartForTest();
  }

  void flushCurrentSpeech() {
    _vad?.flush();
  }

  void setSelectedAgentDetailVadMode(bool enabled) {
    final mode = enabled
        ? VadEndpointMode.selectedAgent
        : VadEndpointMode.defaultFlow;
    if (_disposed || mode == _vadEndpointMode) {
      return;
    }
    _vadEndpointMode = mode;
    final delay = vadEndpointDelayForMode(mode);
    _vad?.setEndpointMode(mode);
    log(
      'Pipeline',
      '[WorkBench][VAD] state=endpoint_mode '
          'source=${enabled ? 'selected_agent_detail' : 'default'} '
          'delay_ms=${delay.inMilliseconds}',
    );
  }

  Future<bool> prioritizeQueuedCorrection(String segmentId) async {
    final correction = _correction;
    if (_disposed || correction == null) {
      return false;
    }
    return correction.prioritize(segmentId);
  }

  Future<void> selectTranscriptionModel(
    SpeechModelDefinition requestedModel,
  ) async {
    if (_disposed) {
      throw StateError('The local audio system is closed.');
    }
    if (_modelSwitching) {
      throw StateError('A transcription model is already loading.');
    }
    if (requestedModel.id == activeModelId &&
        _transcription != null &&
        startup.isReady) {
      return;
    }

    _modelSwitching = true;
    try {
      final speechPath = _speechPath;
      final providers = _inferenceProviders;
      final oldSupervisor = _transcription;
      final oldPaths = _transcriptionPaths;
      final oldModel = _selectedModel;
      if (speechPath == null ||
          providers == null ||
          oldSupervisor == null ||
          oldPaths == null) {
        await _resetAndInitialize(requestedModel);
        return;
      }

      _setStartup(
        StartupPhase.transcription,
        'Verifying ${requestedModel.displayName}…',
      );
      late final TranscriptionModelPaths requestedPaths;
      try {
        requestedPaths = await _modelStore.prepareTranscriptionModel(
          definition: requestedModel,
          onStatus: (message) {
            _setStartup(StartupPhase.transcription, message);
          },
        );
      } catch (error) {
        _setStartup(
          StartupPhase.ready,
          'Local audio ready · $activeModelName · $activeProvider',
          provider: activeProvider,
        );
        log(
          'Pipeline',
          '[WorkBench][Transcription] state=switch_failed '
              'model=${requestedModel.id} error=${_oneLine(error)} '
              'action=keep_current',
          isError: true,
        );
        throw StateError(
          'Could not prepare ${requestedModel.displayName}: '
          '${_oneLine(error)} '
          '$activeModelName remains active.',
        );
      }

      log(
        'Pipeline',
        '[WorkBench][Transcription] state=switching '
            'from=${oldModel.id} to=${requestedModel.id} '
            'capture=continuous vad=continuous',
      );
      _transcription = null;
      await oldSupervisor.dispose();

      final candidate = _newTranscriptionSupervisor(
        model: requestedPaths,
        speechPath: speechPath,
        providers: providers,
      );
      _transcription = candidate;
      try {
        final provider = await candidate.start();
        _transcriptionPaths = requestedPaths;
        _selectedModel = requestedModel;
        activeModelId = requestedModel.id;
        activeModelName = requestedModel.displayName;
        activeProvider = provider;
        _setStartup(
          StartupPhase.ready,
          'Local audio ready · $activeModelName · $activeProvider',
          provider: activeProvider,
        );
        log(
          'Pipeline',
          '[WorkBench][Transcription] state=switched '
              'model=${requestedModel.id} provider=$provider '
              'capture=continuous vad=continuous',
        );
      } catch (switchError) {
        await candidate.dispose();
        _transcription = null;
        log(
          'Pipeline',
          '[WorkBench][Transcription] state=switch_failed '
              'model=${requestedModel.id} error=${_oneLine(switchError)} '
              'action=restore_previous',
          isError: true,
        );
        try {
          final fallback = _newTranscriptionSupervisor(
            model: oldPaths,
            speechPath: speechPath,
            providers: providers,
          );
          _transcription = fallback;
          final provider = await fallback.start();
          _transcriptionPaths = oldPaths;
          _selectedModel = oldModel;
          activeModelId = oldModel.id;
          activeModelName = oldModel.displayName;
          activeProvider = provider;
          _setStartup(
            StartupPhase.ready,
            'Restored $activeModelName · $activeProvider',
            provider: activeProvider,
          );
          log(
            'Pipeline',
            '[WorkBench][Transcription] state=restored '
                'model=${oldModel.id} provider=$provider',
          );
        } catch (restoreError) {
          _setStartup(
            StartupPhase.failed,
            'Transcription models could not load: ${_oneLine(restoreError)}',
          );
          throw StateError(
            'Could not load ${requestedModel.displayName}, and restoring '
            '${oldModel.displayName} also failed: ${_oneLine(restoreError)}',
          );
        }
        throw StateError(
          'Could not load ${requestedModel.displayName}. '
          '${oldModel.displayName} was restored.',
        );
      }
    } finally {
      _modelSwitching = false;
      onChanged();
    }
  }

  TranscriptionSupervisor _newTranscriptionSupervisor({
    required TranscriptionModelPaths model,
    required String speechPath,
    required List<String> providers,
  }) {
    return TranscriptionSupervisor(
      model: model,
      speechPath: speechPath,
      providers: providers,
      onTranscript: _onTranscript,
      onStatus: _transcriptionStatus,
    );
  }

  Future<void> retryInitialize({
    SpeechModelDefinition? transcriptionModel,
  }) async {
    if (_disposed || startup.isBusy) {
      return;
    }
    await _resetAndInitialize(transcriptionModel ?? _selectedModel);
  }

  Future<void> _resetAndInitialize(
    SpeechModelDefinition transcriptionModel,
  ) async {
    _initialized = false;
    _initialStartupComplete = false;
    await _capture?.dispose();
    await _drainDecodeQueue();
    await _vad?.dispose();
    await _transcription?.dispose();
    await _transcriptHandlingTail;
    await _correction?.dispose();
    await _decoder.dispose();
    _capture = null;
    _vad = null;
    _transcription = null;
    _correction = null;
    _transcriptTurnAssembler = null;
    _transcriptionPaths = null;
    _speechPath = null;
    _inferenceProviders = null;
    activeModelId = null;
    activeModelName = null;
    activeProvider = null;
    activeVadProvider = null;
    activeCorrectionProvider = null;
    _vadRecovery.clear();
    _speechSegments.clear();
    _vadRecoveryBytes = 0;
    _decodeQueue.clear();
    _decodeBackpressureReported = false;
    _setStartup(StartupPhase.starting, 'Restarting local audio system…');
    await initialize(transcriptionModel: transcriptionModel);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _capture?.dispose();
    await _drainDecodeQueue();
    await _vad?.dispose();
    await _transcription?.dispose();
    await _transcriptHandlingTail;
    await _correction?.dispose();
    _speechSegments.clear();
    _decodeQueue.clear();
    await _decoder.dispose();
    _correctionConfigStore.removeListener(onChanged);
  }

  String _oneLine(Object? value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}

final class _CapturedLc3Packet {
  const _CapturedLc3Packet({required this.sequence, required this.bytes});

  final int sequence;
  final Uint8List bytes;
}
