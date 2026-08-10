import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio/audio_pipeline_coordinator.dart';
import 'audio/conversation_analysis_service.dart';
import 'audio/shared_audio_export_store.dart';
import 'audio/speech_model.dart';
import 'audio/speech_model_preferences.dart';
import 'audio/transcript_correction_config.dart';
import 'audio/transcript_correction_supervisor.dart';
import 'audio/vad_worker.dart';
import 'audio/voice_memo_models.dart';
import 'audio/voice_memo_service.dart';
import 'background/app_runtime_coordinator.dart';
import 'background/background_service.dart';
import 'ble/ble_models.dart';
import 'ble/g2_connection.dart';
import 'ble/glasses_status_queue.dart';
import 'ble/r1_connection.dart';
import 'protocol/g2_protocol.dart';
import 'util/hex.dart';
import 'startup/startup_state.dart';
import 'websocket/agent_exchange_store.dart';
import 'websocket/g2_agent_history_state.dart';
import 'websocket/selected_agent_transcript_session.dart';
import 'websocket/voice_websocket_client.dart';
import 'websocket/voice_websocket_config.dart';
import 'websocket/websocket_message_store.dart';

enum WearableGestureAction { ignore, finishMemo, requestAgentSummary }

enum AgentHistorySelectionMove { none, previous, next }

enum AgentDetailSwipeAction {
  none,
  focusBack,
  focusListen,
  previousPage,
  nextPage,
}

enum QueuedTranscriptTapAction { none, save, correctAndRoute }

enum AgentDetailTranscriptTapAction {
  none,
  activateListenMode,
  exitListenMode,
  finishSpeech,
  returnToSelector,
  dismiss,
}

final class _SelectedAgentSpeechRoute {
  const _SelectedAgentSpeechRoute({required this.agent, required this.source});

  final String agent;
  final String source;
}

/// Serializes display work and keeps only the newest page requested while a
/// BLE render is active.
final class CoalescedDisplayQueue {
  Object? _renderedKey;
  _QueuedDisplayRender? _active;
  _QueuedDisplayRender? _pending;
  Completer<void>? _idleCompleter;
  int _resetRevision = 0;

  Future<void> schedule({
    required Object key,
    required Future<void> Function() render,
    void Function(Object error)? onError,
  }) {
    final completion = Completer<void>();
    final guarded = completion.future.then<void>(
      (_) {},
      onError: (Object error) {
        onError?.call(error);
      },
    );

    final active = _active;
    if (active?.key == key) {
      _supersedePending();
      active!.completions.add(completion);
      return guarded;
    }
    final pending = _pending;
    if (pending?.key == key) {
      pending!.completions.add(completion);
      return guarded;
    }
    if (active == null && pending == null && _renderedKey == key) {
      completion.complete();
      return guarded;
    }

    _supersedePending();
    _pending = _QueuedDisplayRender(
      key: key,
      render: render,
      completions: <Completer<void>>[completion],
      resetRevision: _resetRevision,
    );
    if (_active == null) {
      _idleCompleter = Completer<void>();
      unawaited(_drain());
    }
    return guarded;
  }

  void reset() {
    _renderedKey = null;
    _resetRevision++;
  }

  Future<void> waitForIdle() => _idleCompleter?.future ?? Future<void>.value();

  void _supersedePending() {
    final pending = _pending;
    _pending = null;
    if (pending == null) {
      return;
    }
    for (final completion in pending.completions) {
      if (!completion.isCompleted) {
        completion.complete();
      }
    }
  }

  Future<void> _drain() async {
    while (_pending != null) {
      final operation = _pending!;
      _pending = null;
      _active = operation;
      try {
        await operation.render();
        if (operation.resetRevision == _resetRevision) {
          _renderedKey = operation.key;
        }
        for (final completion in operation.completions) {
          if (!completion.isCompleted) {
            completion.complete();
          }
        }
      } on Object catch (error, stackTrace) {
        if (_renderedKey == operation.key) {
          _renderedKey = null;
        }
        for (final completion in operation.completions) {
          if (!completion.isCompleted) {
            completion.completeError(error, stackTrace);
          }
        }
      } finally {
        _active = null;
      }
    }
    final idleCompleter = _idleCompleter;
    _idleCompleter = null;
    if (idleCompleter != null && !idleCompleter.isCompleted) {
      idleCompleter.complete();
    }
  }
}

final class _QueuedDisplayRender {
  const _QueuedDisplayRender({
    required this.key,
    required this.render,
    required this.completions,
    required this.resetRevision,
  });

  final Object key;
  final Future<void> Function() render;
  final List<Completer<void>> completions;
  final int resetRevision;
}

WearableGestureAction resolveWearableGestureAction({
  required int gestureType,
  required bool memoActive,
}) {
  if (gestureType != 3) {
    return WearableGestureAction.ignore;
  }
  return memoActive
      ? WearableGestureAction.finishMemo
      : WearableGestureAction.requestAgentSummary;
}

AgentHistorySelectionMove resolveAgentHistorySelectionMove(int gestureType) {
  return switch (gestureType) {
    1 => AgentHistorySelectionMove.previous,
    2 => AgentHistorySelectionMove.next,
    _ => AgentHistorySelectionMove.none,
  };
}

AgentDetailSwipeAction resolveAgentDetailSwipeAction({
  required int gestureType,
  required bool isAgentDetail,
  required G2AgentDetailControl detailControl,
}) {
  final move = resolveAgentHistorySelectionMove(gestureType);
  if (isAgentDetail) {
    if (move == AgentHistorySelectionMove.previous &&
        detailControl == G2AgentDetailControl.listen) {
      return AgentDetailSwipeAction.focusBack;
    }
    if (move == AgentHistorySelectionMove.next &&
        detailControl == G2AgentDetailControl.back) {
      return AgentDetailSwipeAction.focusListen;
    }
  }
  return switch (move) {
    AgentHistorySelectionMove.previous => AgentDetailSwipeAction.previousPage,
    AgentHistorySelectionMove.next => AgentDetailSwipeAction.nextPage,
    AgentHistorySelectionMove.none => AgentDetailSwipeAction.none,
  };
}

QueuedTranscriptTapAction resolveQueuedTranscriptTapAction({
  required int gestureType,
  required bool memoActive,
  required String? queuedTranscript,
}) {
  if (gestureType != 0 || memoActive || queuedTranscript == null) {
    return QueuedTranscriptTapAction.none;
  }
  return transcriptBeginsWithWakeWord(queuedTranscript)
      ? QueuedTranscriptTapAction.correctAndRoute
      : QueuedTranscriptTapAction.save;
}

AgentDetailTranscriptTapAction resolveAgentDetailTranscriptTapAction({
  required int gestureType,
  required bool isAgentDetail,
  required G2AgentDetailControl detailControl,
  required bool listenModeSelected,
  required G2AgentDetailSpeechState? speechState,
}) {
  if (gestureType != 0) {
    return AgentDetailTranscriptTapAction.none;
  }
  if (speechState == G2AgentDetailSpeechState.sending) {
    return AgentDetailTranscriptTapAction.dismiss;
  }
  if (!isAgentDetail) {
    return AgentDetailTranscriptTapAction.none;
  }
  if (detailControl == G2AgentDetailControl.back) {
    return AgentDetailTranscriptTapAction.returnToSelector;
  }
  if (!listenModeSelected) {
    return AgentDetailTranscriptTapAction.activateListenMode;
  }
  return speechState == G2AgentDetailSpeechState.listening
      ? AgentDetailTranscriptTapAction.finishSpeech
      : AgentDetailTranscriptTapAction.exitListenMode;
}

@visibleForTesting
Future<void> completeAgentRouteConsumers({
  required Future<void> Function() updateDisplay,
  Future<void> Function()? persistAcknowledgedMessage,
}) async {
  final operations = <Future<void>>[updateDisplay()];
  if (persistAcknowledgedMessage != null) {
    operations.add(persistAcknowledgedMessage());
  }
  await Future.wait(operations);
}

@visibleForTesting
bool finalTranscriptCanRoute(FinalTranscriptDelivery delivery) =>
    delivery.isCorrected;

@visibleForTesting
VoiceWebSocketDeliveryMode deliveryModeForAgentRoute({
  required bool explicitlySelected,
}) => VoiceWebSocketDeliveryMode.queued;

final class WearableController extends ChangeNotifier
    with WidgetsBindingObserver {
  static const int _maximumSelectedAgentSpeechRoutes = 32;

  WearableController({
    FlutterReactiveBle? ble,
    SpeechModelPreferences speechModelPreferences =
        const SpeechModelPreferences(),
    SharedAudioExportStore? sharedAudioExportStore,
    WebSocketMessageStore? webSocketMessageStore,
    AgentExchangeStore? agentExchangeStore,
    VoiceWebSocketConfigStore? voiceWebSocketConfigStore,
  }) : _ble = ble ?? FlutterReactiveBle(),
       _speechModelPreferences = speechModelPreferences,
       _sharedAudioExportStore =
           sharedAudioExportStore ?? SharedAudioExportStore(),
       _webSocketMessageStore =
           webSocketMessageStore ?? WebSocketMessageStore(),
       _agentExchangeStore = agentExchangeStore ?? AgentExchangeStore() {
    _sharedAudioExportStore.addListener(_sharedStorageChanged);
    _runtime = AppRuntimeCoordinator(log: addLog);
    _voiceWebSocket = VoiceWebSocketClient(
      configStore: voiceWebSocketConfigStore,
      onInboundEvent: _handleInboundWebSocketEvent,
    );
    _voiceWebSocket.addListener(_voiceWebSocketChanged);
    _conversationAnalysis = ConversationAnalysisService(
      log: addLog,
      onChanged: _safeNotify,
      sharedAudioExportStore: _sharedAudioExportStore,
    );
    _voiceMemo = VoiceMemoService(log: addLog, onChanged: _memoChanged);
    _audioPipeline = AudioPipelineCoordinator(
      log: addLog,
      onChanged: _safeNotify,
      onCaptureUnsafe: _handleUnsafeCapture,
      onQueuedTranscript: _handleQueuedTranscript,
      onFinalTranscript: _handleFinalTranscript,
      onFinalizedSpeechSegment: _handleFinalizedSpeechSegment,
      onVadSpeechEvent: _handleVadSpeechEvent,
      correctionTermsProvider: () => <String>[
        VoiceMemoService.wakePhrase,
        ..._voiceWebSocket.config.agentNames,
      ],
      explicitCorrectionEligibilityProvider: (segmentId) =>
          _selectedAgentSpeechRoutes.containsKey(segmentId),
      transcriptCollectionEligibilityProvider: (segmentId) =>
          _selectedAgentCollectionSegments.containsKey(segmentId),
      onCollectedTranscript: _handleCollectedTranscript,
      sharedAudioExportStore: _sharedAudioExportStore,
    );
    g2 = G2Connection(
      ble: _ble,
      log: addLog,
      onChanged: _connectionChanged,
      onAudioChanged: _audioChanged,
      onLc3Audio: _audioPipeline.acceptLc3,
      onUnexpectedDisconnect: _unexpectedG2Disconnect,
      onGesture: _handleG2Gesture,
    );
    _glassesStatusQueue = GlassesStatusQueue(
      isConnected: () => g2.isConnected,
      // Transcript and inbound-message text own the full-height page. Using
      // sendText here would keep it inside the two-row visualizer container.
      showPage: g2.showFullPageText,
      exitPage: g2.exitFullPageText,
      log: (message, {bool isError = false}) =>
          addLog('Glasses status', message, isError: isError),
    );
    r1 = R1Connection(ble: _ble, log: addLog, onChanged: _connectionChanged);
  }

  final FlutterReactiveBle _ble;
  final SpeechModelPreferences _speechModelPreferences;
  final SharedAudioExportStore _sharedAudioExportStore;
  final WebSocketMessageStore _webSocketMessageStore;
  final AgentExchangeStore _agentExchangeStore;
  late final AppRuntimeCoordinator _runtime;
  late final VoiceWebSocketClient _voiceWebSocket;
  late final ConversationAnalysisService _conversationAnalysis;
  late final VoiceMemoService _voiceMemo;
  late final AudioPipelineCoordinator _audioPipeline;
  late final G2Connection g2;
  late final GlassesStatusQueue _glassesStatusQueue;
  late final R1Connection r1;
  StreamSubscription<BleStatus>? _statusSubscription;
  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  Timer? _scanTimer;
  Timer? _notifyTimer;
  Timer? _audioNotifyTimer;
  Timer? _backgroundNotifyTimer;
  Future<void> _memoDisplayTail = Future<void>.value();
  final CoalescedDisplayQueue _historyDisplayQueue = CoalescedDisplayQueue();
  final G2AgentHistoryState _agentHistory = G2AgentHistoryState();
  final LinkedHashMap<String, _SelectedAgentSpeechRoute>
  _selectedAgentSpeechRoutes =
      LinkedHashMap<String, _SelectedAgentSpeechRoute>();
  final Map<String, SelectedAgentTranscriptSession>
  _selectedAgentCollectionSegments = <String, SelectedAgentTranscriptSession>{};
  final Map<String, Future<void>> _selectedAgentPreviewPumps =
      <String, Future<void>>{};
  final Map<String, TranscriptCorrectionPreviewResult>
  _selectedAgentPreviewResults = <String, TranscriptCorrectionPreviewResult>{};
  final Map<String, Future<void>> _selectedAgentSubmissions =
      <String, Future<void>>{};
  SelectedAgentTranscriptSession? _selectedAgentListenSession;
  int _selectedAgentListenSessionRevision = 0;
  Timer? _selectedAgentTranscriptionBlinkTimer;
  bool _selectedAgentTranscriptionIndicatorVisible = true;
  Timer? _agentHistoryWaitTimer;
  bool _agentExchangeStoreReady = false;
  bool _agentHistoryOpening = false;
  bool _agentHistoryClosing = false;
  bool _isLoadingAgentMessages = false;
  int _agentHistoryGeneration = 0;
  int _agentMessageRefreshGeneration = 0;
  bool _disposed = false;
  bool _g2UnexpectedlyDisconnected = false;
  bool _linkingController = false;
  bool _sharedMessageViewActive = false;
  bool? _runtimeSessionActive;
  String? _lastControllerLinkKey;
  String? _announcedFinalizedMemoId;
  String? _agentMessageError;
  List<AgentMessageView> _agentMessages = const <AgentMessageView>[];
  SpeechModelDefinition _selectedSpeechModel = defaultSpeechModel();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  static const Duration _audioUiFrameInterval = Duration(milliseconds: 33);
  static const int _maximumLogEntries = 30;
  static const int _memoryPressureLogEntries = _maximumLogEntries;
  static const int _maximumLogMessageCharacters = 2048;

  BleStatus bleStatus = BleStatus.unknown;
  bool scanning = false;
  String? rememberedG2Serial;
  String? rememberedR1Id;
  final Map<String, G2PairCandidate> _g2ByKey = <String, G2PairCandidate>{};
  final Map<String, DiscoveredDevice> _r1ById = <String, DiscoveredDevice>{};
  final Set<String> _loggedR1Advertisements = <String>{};
  final List<PooledLog> logs = <PooledLog>[];

  StartupSnapshot get startup => _audioPipeline.startup;
  bool get canConnect => _audioPipeline.canConnect;
  String? get audioFolder => _audioPipeline.audioFolder;
  SharedAudioFolder? get sharedAudioFolder => _sharedAudioExportStore.folder;
  bool get supportsSharedAudioFolder => _sharedAudioExportStore.isSupported;
  bool get isExportingSharedAudio => _audioPipeline.isExportingSharedAudio;
  String? get sharedAudioExportError => _audioPipeline.sharedExportError;
  int get sharedExportedFiles => _audioPipeline.sharedExportedFiles;
  List<SharedTranscript> get sharedTranscripts =>
      _sharedAudioExportStore.transcripts;
  List<SharedWebSocketMessage> get sharedWebSocketMessages =>
      _sharedAudioExportStore.messages;
  List<AgentMessageView> get agentMessages => _agentMessages;
  bool get isLoadingAgentMessages => _isLoadingAgentMessages;
  String? get agentMessageError => _agentMessageError;
  bool get isLoadingSharedMessages =>
      _sharedAudioExportStore.isLoadingTranscripts ||
      _sharedAudioExportStore.isLoadingMessages;
  String? get sharedMessageError =>
      _sharedAudioExportStore.messageLoadError ??
      _sharedAudioExportStore.transcriptLoadError;
  String? get lastTranscript => _audioPipeline.lastTranscript;
  int get completedTranscripts => _audioPipeline.completedTranscripts;
  String? get transcriptionProvider => _audioPipeline.activeProvider;
  String? get vadProvider => _audioPipeline.activeVadProvider;
  String? get correctionProvider => _audioPipeline.activeCorrectionProvider;
  String get correctionState => _audioPipeline.correctionState;
  int get pendingCorrections => _audioPipeline.pendingCorrections;
  int get completedCorrections => _audioPipeline.completedCorrections;
  TranscriptCorrectionConfig get correctionConfig =>
      _audioPipeline.correctionConfig;
  String? get correctionConfigValidationError =>
      _audioPipeline.correctionConfigValidationError;
  bool get hasWearableSession => _hasWearableSession;
  List<SpeechModelDefinition> get speechModels => availableSpeechModels;
  String get selectedSpeechModelId => _selectedSpeechModel.id;
  String get selectedSpeechModelName => _selectedSpeechModel.displayName;
  bool get isSwitchingSpeechModel => _audioPipeline.isSwitchingModel;
  VoiceWebSocketConfig get voiceWebSocketConfig => _voiceWebSocket.config;
  VoiceWebSocketStatus get voiceWebSocketStatus => _voiceWebSocket.status;
  String get voiceWebSocketStatusText => _voiceWebSocket.statusText;
  String? get voiceWebSocketValidationError => _voiceWebSocket.validationError;
  List<SharedConversationTurn> get conversations =>
      _sharedAudioExportStore.conversations;
  bool get isLoadingConversations =>
      _sharedAudioExportStore.isLoadingConversations;
  String? get conversationLoadError =>
      _sharedAudioExportStore.conversationLoadError;
  bool get conversationAnalysisEnabled => _conversationAnalysis.enabled;
  bool get conversationAnalysisStarting => _conversationAnalysis.isStarting;
  bool get conversationAnalysisReady => _conversationAnalysis.isReady;
  bool get conversationNeedsEnrollment => _conversationAnalysis.needsEnrollment;
  bool get conversationEnrollmentPending =>
      _conversationAnalysis.isEnrollmentPending;
  int get acceptedConversationEnrollmentSamples =>
      _conversationAnalysis.acceptedEnrollmentSamples;
  int get requiredConversationEnrollmentSamples =>
      _conversationAnalysis.requiredEnrollmentSamples;
  double get conversationSpeakerMatchThreshold =>
      _conversationAnalysis.speakerMatchThreshold;
  String get conversationAnalysisState => _conversationAnalysis.state;
  String? get conversationAnalysisError => _conversationAnalysis.error;
  int get knownSpeakerCount => _conversationAnalysis.knownSpeakerCount;
  int get pendingConversationCount => _conversationAnalysis.pendingCount;
  int get completedConversations =>
      _conversationAnalysis.completedConversations;
  List<VoiceMemoRecord> get voiceMemos => _voiceMemo.records;
  bool get voiceMemoActive => _voiceMemo.isActive;

  List<G2PairCandidate> get g2Candidates {
    final values = _g2ByKey.values.toList(growable: false);
    values.sort((left, right) {
      if (left.isComplete != right.isComplete) {
        return left.isComplete ? -1 : 1;
      }
      return left.serialNumber.compareTo(right.serialNumber);
    });
    return values;
  }

  List<DiscoveredDevice> get r1Candidates {
    final values = _r1ById.values.toList(growable: false);
    values.sort((left, right) => right.rssi.compareTo(left.rssi));
    return values;
  }

  List<PooledLog> get eventLogs => logs.toList(growable: false);

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    await _runtime.initialize();
    try {
      await _sharedAudioExportStore.initialize();
    } catch (error) {
      addLog(
        'Storage',
        '[WorkBench][SharedStorage] state=unavailable '
            'action=choose_folder_again error=$error',
        isError: true,
      );
    }
    try {
      await _webSocketMessageStore.initialize();
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=archive_unavailable '
            'action=check_app_storage',
        isError: true,
      );
    }
    try {
      await _agentExchangeStore.initialize();
      _agentExchangeStoreReady = true;
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][AgentHistory] state=unavailable '
            'action=check_app_storage',
        isError: true,
      );
    }
    try {
      await _voiceWebSocket.initialize();
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=unavailable '
            'action=check_app_storage',
        isError: true,
      );
    }
    if (_agentExchangeStoreReady &&
        _voiceWebSocket.config.agentNames.isNotEmpty) {
      try {
        await _agentExchangeStore.importExistingSentMessages(
          paths: await _webSocketMessageStore.savedPaths(),
          agents: _voiceWebSocket.config.agentNames,
          legacy: _voiceWebSocket.config.useLegacyMessageShape,
        );
      } on Object {
        addLog(
          'WebSocket',
          '[WorkBench][AgentHistory] state=history_import_failed '
              'fallback=new_messages_only',
          isError: true,
        );
      }
    }
    try {
      await _voiceMemo.initialize();
    } on Object {
      addLog(
        'Memo',
        '[WorkBench][Memo] state=storage_unavailable '
            'capture=unaffected transcription=unaffected',
        isError: true,
      );
    }
    if (_sharedAudioExportStore.hasSharedFolder) {
      unawaited(_syncWebSocketMessages());
    }
    _selectedSpeechModel = await _speechModelPreferences.load();
    try {
      await _audioPipeline.initialize(transcriptionModel: _selectedSpeechModel);
    } catch (_) {
      // The pipeline publishes an actionable startup failure. Bluetooth stays
      // gated because connecting without durable capture would violate the
      // audio-safety contract.
    }
    unawaited(_conversationAnalysis.initialize());
    final preferences = await SharedPreferences.getInstance();
    rememberedG2Serial = preferences.getString('remembered_g2_serial');
    rememberedR1Id = preferences.getString('remembered_r1_id');
    await preferences.remove('r1_direct_input_mode');
    _statusSubscription = _ble.statusStream.listen((status) {
      bleStatus = status;
      addLog('BLE', 'Adapter: ${status.name}');
      _safeNotify();
    });
    if (_audioPipeline.canConnect) {
      addLog(
        'App',
        'Ready. R1 input uses the supported Tri-Sync path through G2.',
      );
    } else {
      addLog(
        'App',
        'Choose an installed transcription model in Tools, then retry.',
        isError: true,
      );
    }
  }

  Future<void> startScan({
    Duration duration = const Duration(seconds: 12),
  }) async {
    if (!canConnect) {
      throw StateError('Wait for the local audio system to become ready.');
    }
    if (scanning) {
      return;
    }
    await _requestPermissions();
    await stopScan();
    _g2ByKey.clear();
    _r1ById.clear();
    _loggedR1Advertisements.clear();
    scanning = true;
    _safeNotify();
    addLog('BLE', 'Low-latency scan started for ${duration.inSeconds}s');

    _scanSubscription = _ble
        .scanForDevices(
          withServices: const <Uuid>[],
          scanMode: ScanMode.lowLatency,
          requireLocationServicesEnabled: false,
        )
        .listen(
          _onDiscovered,
          onError: (Object error) {
            scanning = false;
            addLog('BLE scan', '$error', isError: true);
            _safeNotify();
          },
        );
    _scanTimer = Timer(duration, () {
      unawaited(stopScan());
    });
  }

  void _onDiscovered(DiscoveredDevice device) {
    final pair = G2PairCandidate.fromDevice(device);
    if (pair != null) {
      final existing = _g2ByKey[pair.key];
      _g2ByKey[pair.key] = (existing ?? pair).merge(device);
    } else if (isR1(device)) {
      _r1ById[device.id] = device;
      if (_loggedR1Advertisements.add(device.id)) {
        final serviceData = device.serviceData.entries
            .map(
              (entry) =>
                  '${entry.key}='
                  '${hexOf(entry.value, maxBytes: entry.value.length)}',
            )
            .join(', ');
        addLog(
          'R1 advertisement',
          '${device.name} (${device.id}) • RSSI ${device.rssi} dBm • '
              'connectable=${device.connectable.name} • '
              'services=${device.serviceUuids.isEmpty ? 'none' : device.serviceUuids.join(', ')} • '
              'manufacturer='
              '${device.manufacturerData.isEmpty ? 'none' : hexOf(device.manufacturerData, maxBytes: device.manufacturerData.length)} • '
              'serviceData=${serviceData.isEmpty ? 'none' : serviceData}',
        );
      }
    } else {
      return;
    }
    _notifyTimer ??= Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      _safeNotify();
    });
  }

  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (scanning) {
      scanning = false;
      addLog(
        'BLE',
        'Scan stopped: ${g2Candidates.length} G2 pair candidate(s), '
            '${r1Candidates.length} R1 ring(s)',
      );
      _safeNotify();
    }
  }

  Future<void> connectG2(G2PairCandidate pair) async {
    if (!canConnect) {
      throw StateError('Local audio safety checks are not ready.');
    }
    await stopScan();
    await _runtime.setWearableSessionActive(true);
    try {
      await g2.connect(pair);
      rememberedG2Serial = pair.serialNumber;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('remembered_g2_serial', pair.serialNumber);
      await _linkRingAndGlasses();
    } finally {
      await _syncBackgroundService();
    }
  }

  Future<void> connectR1(DiscoveredDevice device) async {
    await stopScan();
    await _runtime.setWearableSessionActive(true);
    try {
      await r1.connect(device, glassesMac: g2.rightMac);
      rememberedR1Id = device.id;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('remembered_r1_id', device.id);
      await _linkRingAndGlasses();
    } finally {
      await _syncBackgroundService();
    }
  }

  Future<void> disconnectG2() async {
    await g2.disconnect();
    _lastControllerLinkKey = null;
    _audioPipeline.handleWearableDisconnect(expected: true);
    _voiceMemo.handleWearableDisconnect();
    await _syncBackgroundService();
  }

  Future<void> disconnectR1() async {
    await r1.disconnect();
    _lastControllerLinkKey = null;
    await _syncBackgroundService();
  }

  Future<void> disconnectAll() async {
    await stopScan();
    await Future.wait(<Future<void>>[g2.disconnect(), r1.disconnect()]);
    _g2UnexpectedlyDisconnected = false;
    // A Tri-Sync handoff belongs to the current BLE session. Retaining this
    // deduplication key across a reset makes the next connection skip the
    // handoff and leaves Android directly attached to R1.
    _lastControllerLinkKey = null;
    _audioPipeline.handleWearableDisconnect(expected: true);
    _voiceMemo.handleWearableDisconnect();
    await _syncBackgroundService();
  }

  Future<void> restartTranscriptionForTest() =>
      _audioPipeline.restartTranscriptionForTest();

  Future<void> restartVadForTest() => _audioPipeline.restartVadForTest();

  Future<void> retryAudioPipeline() =>
      _audioPipeline.retryInitialize(transcriptionModel: _selectedSpeechModel);

  Future<void> selectSpeechModel(String modelId) async {
    final model = speechModelForId(modelId);
    if (model == null) {
      throw ArgumentError.value(modelId, 'modelId', 'Unknown speech model');
    }
    if (model.id == _selectedSpeechModel.id && startup.isReady) {
      return;
    }
    await _audioPipeline.selectTranscriptionModel(model);
    await _speechModelPreferences.save(model);
    _selectedSpeechModel = model;
    addLog(
      'Pipeline',
      '[WorkBench][Transcription] state=preference_saved model=${model.id}',
    );
    _safeNotify();
  }

  Future<void> saveCorrectionInstructions(String instructions) async {
    await _audioPipeline.saveCorrectionInstructions(instructions);
    addLog(
      'Pipeline',
      '[WorkBench][CorrectionConfig] state=saved applies=next_transcript',
    );
    _safeNotify();
  }

  Future<void> resetCorrectionInstructions() async {
    await _audioPipeline.resetCorrectionInstructions();
    addLog(
      'Pipeline',
      '[WorkBench][CorrectionConfig] state=reset applies=next_transcript',
    );
    _safeNotify();
  }

  Future<void> setCorrectionEnabled(bool enabled) async {
    await _audioPipeline.setCorrectionEnabled(enabled);
    addLog(
      'Pipeline',
      '[WorkBench][CorrectionConfig] state=${enabled ? 'enabled' : 'disabled'} '
          'applies=next_transcript',
    );
    _safeNotify();
  }

  Future<void> setConversationAnalysisEnabled(bool enabled) async {
    await _conversationAnalysis.setEnabled(enabled);
    _safeNotify();
  }

  Future<void> resetConversationSpeakerIdentification() async {
    await _conversationAnalysis.resetSpeakerIdentification();
    _safeNotify();
  }

  Future<void> setConversationSpeakerMatchThreshold(double value) async {
    await _conversationAnalysis.setSpeakerMatchThreshold(value);
    _safeNotify();
  }

  Future<void> refreshConversations() =>
      _sharedAudioExportStore.refreshConversations();

  Future<void> restartConversationWorkerForTest() =>
      _conversationAnalysis.restartWorkerForTest();

  Future<void> saveVoiceWebSocketConfig(VoiceWebSocketConfig config) async {
    await _closeAgentHistory(clearDisplay: true);
    await _voiceWebSocket.saveConfig(config);
    if (_agentExchangeStoreReady) {
      try {
        await _agentExchangeStore.importExistingSentMessages(
          paths: await _webSocketMessageStore.savedPaths(),
          agents: config.agentNames,
          legacy: config.useLegacyMessageShape,
        );
      } on Object {
        addLog(
          'WebSocket',
          '[WorkBench][AgentHistory] state=history_reindex_failed '
              'fallback=retained_index',
          isError: true,
        );
      }
    }
    await _refreshAgentMessages();
    addLog(
      'WebSocket',
      '[WorkBench][VoiceWebSocket] state=saved '
          'auth=${config.authHeader.serializedName} '
          'agents=${config.agentNames.length} '
          'legacy=${config.useLegacyMessageShape}',
    );
    _safeNotify();
  }

  Future<void> connectVoiceWebSocket() => _voiceWebSocket.connect();

  Future<void> disconnectVoiceWebSocket() => _voiceWebSocket.disconnect();

  Future<void> chooseSharedAudioFolder() async {
    final selected = await _sharedAudioExportStore.chooseFolder();
    if (selected == null) {
      return;
    }
    addLog(
      'Storage',
      '[WorkBench][SharedStorage] state=selected access=persisted',
    );
    _safeNotify();
    await _audioPipeline.syncSharedCorrectionInstructions();
    await _audioPipeline.syncSharedAudioExport();
    await _syncWebSocketMessages();
  }

  Future<void> clearSharedAudioFolder() async {
    await _sharedAudioExportStore.clearFolder();
    addLog(
      'Storage',
      '[WorkBench][SharedStorage] state=cleared fallback=app_private',
    );
    _safeNotify();
  }

  Future<void> refreshSharedMessages({bool reconcileShared = false}) async {
    Object? failure;
    try {
      await _sharedAudioExportStore.refreshMessages(
        reconcileShared: reconcileShared,
      );
    } on Object catch (error) {
      failure = error;
    }
    try {
      await _sharedAudioExportStore.refreshTranscriptions(
        reconcileShared: reconcileShared,
      );
    } on Object catch (error) {
      failure ??= error;
    }
    await _refreshAgentMessages();
    addLog(
      'Storage',
      '[WorkBench][SharedStorage] state=list_ready '
          'messages=${sharedWebSocketMessages.length} '
          'transcriptions=${sharedTranscripts.length} '
          'agent_messages=${agentMessages.length}',
    );
    if (failure != null) {
      throw StateError('Could not refresh the shared message history.');
    }
  }

  void setSharedMessageViewActive(bool active) {
    _sharedMessageViewActive = active;
    _audioPipeline.setSharedTranscriptRefreshEnabled(active);
  }

  Future<void> toggleTranscriptAudio(SharedTranscript transcript) async {
    final wasPlaying = isPlayingTranscript(transcript);
    await _sharedAudioExportStore.toggleAudio(transcript);
    addLog(
      'Storage',
      '[WorkBench][SharedStorage] '
          'state=${wasPlaying ? 'playback_stopped' : 'playback_started'} '
          'source=shared_folder',
    );
  }

  bool isPlayingTranscript(SharedTranscript transcript) =>
      transcript.audioFileName != null &&
      transcript.audioFileName == _sharedAudioExportStore.playingAudioFileName;

  Future<bool> sendDirectAgentMessage({
    required String agent,
    required String message,
  }) async {
    final route = _voiceWebSocket.routeTranscriptToSelectedAgent(
      selectedAgent: agent,
      transcript: message,
    );
    if (route == null) {
      return false;
    }
    final result = await _voiceWebSocket.sendAgentMessageWithResult(
      agent: route.agent,
      message: route.message,
      deliveryMode: VoiceWebSocketDeliveryMode.immediate,
    );
    if (!result.sent) {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=direct_send_failed '
            'characters=${route.message.length}',
        isError: true,
      );
      return false;
    }
    await _persistAcknowledgedAgentMessage(result);
    addLog(
      'WebSocket',
      '[WorkBench][VoiceWebSocket] state=direct_sent '
          'characters=${route.message.length}',
    );
    return true;
  }

  Future<void> linkRingAndGlasses() async {
    _lastControllerLinkKey = null;
    await _linkRingAndGlasses();
  }

  Future<void> _linkRingAndGlasses() async {
    if (_linkingController || !g2.isConnected || !r1.isConnected) {
      return;
    }
    // The production Even app gives the R1 the right lens address. The ring
    // forms its controller link with that lens and G2 then forwards gestures
    // through EvenHub.
    final glassesMac = g2.rightMac;
    final ringMac = r1.deviceId;
    if (glassesMac == null) {
      addLog(
        'Tri-Sync',
        'The scanned G2 advertisement did not contain a right-lens MAC.',
        isError: true,
      );
      return;
    }
    if (ringMac == null ||
        !RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(ringMac)) {
      addLog(
        'Tri-Sync',
        'R1 hardware MAC unavailable from BLE id "$ringMac"; '
            'automatic linking currently requires Android.',
        isError: true,
      );
      return;
    }
    final key = '$glassesMac/$ringMac';
    if (_lastControllerLinkKey == key) {
      return;
    }
    _linkingController = true;
    try {
      addLog('Tri-Sync', 'Linking R1 $ringMac to G2 right lens $glassesMac');
      await r1.startGlassesHandoff(glassesMac);
      await Future<void>.delayed(const Duration(seconds: 1));
      await g2.connectRing(ringMac, ringName: r1.deviceName ?? '');
      _lastControllerLinkKey = key;
      addLog(
        'Tri-Sync',
        'R1 handoff was attempted and the G2 ring-connect command was sent. '
            'Waiting for a source=2 R1 event as the definitive link signal.',
      );
      // In Tri-Sync the phone connection is only a setup/diagnostic link.
      // Keeping it open can prevent the ring from completing or maintaining
      // its controller role with the right lens.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await r1.disconnect();
      addLog(
        'Tri-Sync',
        'Released the temporary phone → R1 GATT link. The R1 now belongs to '
            'the G2 controller path; its events are observed through G2.',
      );
    } catch (error) {
      addLog('Tri-Sync', 'Pairing failed: $error', isError: true);
      rethrow;
    } finally {
      _linkingController = false;
      _safeNotify();
    }
  }

  Future<void> _syncBackgroundService() async {
    final active = _hasWearableSession;
    _runtimeSessionActive = active;
    await _runtime.setWearableSessionActive(active);
    _safeNotify();
  }

  bool get _hasWearableSession =>
      g2.state != LinkState.disconnected || r1.state != LinkState.disconnected;

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.notification,
      ].request();
      final denied = statuses.entries
          .where(
            (entry) =>
                entry.key != Permission.notification && !entry.value.isGranted,
          )
          .map((entry) => entry.key.toString())
          .toList(growable: false);
      if (denied.isNotEmpty) {
        addLog(
          'Permissions',
          'Bluetooth permission not granted: ${denied.join(', ')}',
          isError: true,
        );
      }
      // Android 11 and older use location permission for BLE scans. Never ask
      // for it on Android 12+, where Nearby Devices is the correct permission.
      final sdkInt = await BackgroundConnectionService.androidSdkInt();
      if (sdkInt != null && sdkInt <= 30) {
        await Permission.locationWhenInUse.request();
      }
    } else if (Platform.isIOS) {
      await Permission.bluetooth.request();
    }
  }

  void addLog(String source, String message, {bool isError = false}) {
    debugPrint('[Even G2/R1][$source]${isError ? '[ERROR]' : ''} $message');
    // Audio is a continuous stream, not an event history. Keep only its
    // latest summary so it cannot bury connection and gesture events.
    if (source == 'Audio') {
      logs.removeWhere((entry) => entry.source == source);
    }
    logs.insert(
      0,
      PooledLog(
        timestamp: DateTime.now(),
        source: source,
        message: message.length <= _maximumLogMessageCharacters
            ? message
            : '${message.substring(0, _maximumLogMessageCharacters)}…',
        isError: isError,
      ),
    );
    if (logs.length > _maximumLogEntries) {
      logs.removeRange(_maximumLogEntries, logs.length);
    }
    _safeNotify();
  }

  void clearLogs() {
    logs.clear();
    _safeNotify();
  }

  void _connectionChanged() {
    if (!g2.isConnected) {
      _historyDisplayQueue.reset();
    }
    if (_g2UnexpectedlyDisconnected && g2.isConnected) {
      _g2UnexpectedlyDisconnected = false;
      _audioPipeline.handleWearableReconnect();
    }
    _safeNotify();
    _glassesStatusQueue.connectionChanged();
    _queueMemoDisplaySync();
    final active = _hasWearableSession;
    if (_runtimeSessionActive != active) {
      _runtimeSessionActive = active;
      unawaited(_runtime.setWearableSessionActive(active));
    }
  }

  void _sharedStorageChanged() {
    _safeNotify();
  }

  void _voiceWebSocketChanged() {
    if (_agentHistory.mode == G2AgentHistoryMode.waiting &&
        (_voiceWebSocket.status == VoiceWebSocketStatus.disconnected ||
            _voiceWebSocket.status == VoiceWebSocketStatus.error)) {
      final title = _agentHistory.selected?.label ?? 'Agent';
      _agentHistoryWaitTimer?.cancel();
      _agentHistoryWaitTimer = null;
      _agentHistory.showError(title, 'Connection lost');
      _queueAgentHistoryDisplay();
    }
    _safeNotify();
  }

  void _memoChanged() {
    if (_voiceMemo.isActive) {
      _agentHistoryGeneration++;
      _agentHistoryWaitTimer?.cancel();
      _agentHistoryWaitTimer = null;
      _agentHistory.close();
      _syncSelectedAgentVadMode();
      _historyDisplayQueue.reset();
      _glassesStatusQueue.setPaused(true, owner: 'memo');
    }
    _safeNotify();
    _queueMemoDisplaySync();
  }

  void _queueMemoDisplaySync() {
    final operation = _memoDisplayTail.then((_) => _syncMemoDisplay());
    _memoDisplayTail = operation.then<void>(
      (_) {},
      onError: (Object error) {
        addLog(
          'Memo',
          '[WorkBench][MemoDisplay] state=failed '
              'error=${_oneLine(error)}',
          isError: true,
        );
      },
    );
  }

  Future<void> _syncMemoDisplay() async {
    if (_disposed) {
      return;
    }
    final active = _voiceMemo.activeMemo;
    if (active != null) {
      _glassesStatusQueue.setPaused(true, owner: 'memo');
      if (g2.isConnected) {
        await g2.showMemo(
          note: _voiceMemo.displayText,
          status: active.status.label,
        );
      }
      return;
    }
    if (g2.isConnected && g2.isMemoDisplayActive) {
      await g2.exitMemo();
    }
    if (_agentHistory.isOpen) {
      _glassesStatusQueue.setPaused(true, owner: 'history');
      await _showAgentHistory();
      return;
    }
    _glassesStatusQueue.setPaused(false);
    final finalizedId = _voiceMemo.lastFinalizedId;
    if (finalizedId != null && finalizedId != _announcedFinalizedMemoId) {
      _announcedFinalizedMemoId = finalizedId;
      await _glassesStatusQueue.queueTransient(
        prefix: 'Memo',
        message: 'Saved',
      );
    }
  }

  Future<void> _moveActiveMemoPage(AgentHistorySelectionMove move) async {
    try {
      switch (move) {
        case AgentHistorySelectionMove.previous:
          await g2.selectPreviousMemoPage();
        case AgentHistorySelectionMove.next:
          await g2.selectNextMemoPage();
        case AgentHistorySelectionMove.none:
          break;
      }
    } on Object {
      addLog(
        'Memo',
        '[WorkBench][MemoDisplay] state=page_failed',
        isError: true,
      );
    }
  }

  void _handleVadSpeechEvent(VadSpeechEvent event) {
    switch (event.type) {
      case VadSpeechEventType.started:
        final session = _selectedAgentListenSession;
        if (session != null && session.registerSegment(event.segmentId)) {
          _selectedAgentCollectionSegments[event.segmentId] = session;
          addLog(
            'WebSocket',
            '[WorkBench][VoiceRoute] state=speech_targeted '
                'source=${session.source} mode=manual_collection',
          );
          if (_agentHistory.activeDetailSpeechSegmentId == session.id) {
            _syncSelectedAgentTranscriptionStatus(session);
          }
        }
        _voiceMemo.speechStarted(event.segmentId);
      case VadSpeechEventType.ended:
        _voiceMemo.speechEnded(event.segmentId);
        final session = _selectedAgentCollectionSegments[event.segmentId];
        if (session != null) {
          addLog(
            'WebSocket',
            '[WorkBench][VoiceRoute] state=vad_endpoint '
                'source=${session.source} action=continue_collecting',
          );
        }
    }
  }

  void _handleFinalizedSpeechSegment(String segmentId, String wavPath) {
    _conversationAnalysis.acceptFinalizedSegment(segmentId, wavPath);
  }

  bool _handleG2Gesture(G2GestureEvent event) {
    if (_agentHistoryOpening || _agentHistoryClosing) {
      return true;
    }
    if (_agentHistory.isOpen) {
      if (event.type == 0) {
        final detailTapAction = resolveAgentDetailTranscriptTapAction(
          gestureType: event.type,
          isAgentDetail: _agentHistory.isAgentDetail,
          detailControl: _agentHistory.detailControl,
          listenModeSelected: _agentHistory.detailListenModeSelected,
          speechState: _agentHistory.detailSpeechState,
        );
        switch (detailTapAction) {
          case AgentDetailTranscriptTapAction.activateListenMode:
            _activateAgentDetailListenMode();
            return true;
          case AgentDetailTranscriptTapAction.exitListenMode:
            _exitAgentDetailListenMode(source: 'detail_tap');
            return true;
          case AgentDetailTranscriptTapAction.finishSpeech:
            _finishActiveAgentDetailSpeech();
            return true;
          case AgentDetailTranscriptTapAction.returnToSelector:
            _returnToAgentHistorySelector();
            return true;
          case AgentDetailTranscriptTapAction.dismiss:
            unawaited(_closeAgentHistory(clearDisplay: true));
            return true;
          case AgentDetailTranscriptTapAction.none:
            unawaited(_activateAgentHistorySelection());
        }
      } else if (_agentHistory.mode == G2AgentHistoryMode.selector) {
        switch (resolveAgentHistorySelectionMove(event.type)) {
          case AgentHistorySelectionMove.previous:
            _agentHistory.selectPrevious();
            _queueAgentHistoryDisplay(allowPageReplacement: false);
          case AgentHistorySelectionMove.next:
            _agentHistory.selectNext();
            _queueAgentHistoryDisplay(allowPageReplacement: false);
          case AgentHistorySelectionMove.none:
            break;
        }
      } else if (_agentHistory.mode == G2AgentHistoryMode.detail) {
        final swipeAction = resolveAgentDetailSwipeAction(
          gestureType: event.type,
          isAgentDetail: _agentHistory.isAgentDetail,
          detailControl: _agentHistory.detailControl,
        );
        final changed = switch (swipeAction) {
          AgentDetailSwipeAction.focusBack => _focusAgentBackControlFromSwipe(),
          AgentDetailSwipeAction.focusListen =>
            _agentHistory.focusAgentListenControl(),
          AgentDetailSwipeAction.previousPage =>
            _agentHistory.selectPreviousDetailPage(),
          AgentDetailSwipeAction.nextPage =>
            _agentHistory.selectNextDetailPage(),
          AgentDetailSwipeAction.none => false,
        };
        if (changed) {
          if (swipeAction == AgentDetailSwipeAction.previousPage ||
              swipeAction == AgentDetailSwipeAction.nextPage) {
            addLog(
              'WebSocket',
              '[WorkBench][AgentHistory] state=detail_page_changed '
                  'direction=${swipeAction.name} '
                  'page=${_agentHistory.detailPageIndex + 1}/'
                  '${_agentHistory.detailPageCount}',
            );
          }
          _queueAgentHistoryDisplay(allowPageReplacement: false);
        }
      }
      return true;
    }
    if (_voiceMemo.isActive) {
      final memoMove = resolveAgentHistorySelectionMove(event.type);
      if (memoMove != AgentHistorySelectionMove.none) {
        unawaited(_moveActiveMemoPage(memoMove));
        return true;
      }
    }
    if (event.type == 0) {
      if (_voiceMemo.isActive) {
        return true;
      }
      final queuedTranscript = _glassesStatusQueue.queuedTranscript;
      final queuedAction = resolveQueuedTranscriptTapAction(
        gestureType: event.type,
        memoActive: _voiceMemo.isActive,
        queuedTranscript: queuedTranscript?.transcript,
      );
      switch (queuedAction) {
        case QueuedTranscriptTapAction.none:
          break;
        case QueuedTranscriptTapAction.save:
        case QueuedTranscriptTapAction.correctAndRoute:
          unawaited(
            _commitQueuedTranscriptFromTap(queuedTranscript!, queuedAction),
          );
          return true;
      }
      unawaited(_openAgentHistory());
      return true;
    }
    switch (resolveWearableGestureAction(
      gestureType: event.type,
      memoActive: _voiceMemo.isActive,
    )) {
      case WearableGestureAction.ignore:
        return false;
      case WearableGestureAction.finishMemo:
        _audioPipeline.flushCurrentSpeech();
        _voiceMemo.requestFinalize(reason: 'double_tap');
        return true;
      case WearableGestureAction.requestAgentSummary:
        unawaited(_requestLastAgentSummary());
        return true;
    }
  }

  void _finishActiveAgentDetailSpeech() {
    final session = _selectedAgentListenSession;
    if (session == null ||
        _agentHistory.activeDetailSpeechSegmentId != session.id) {
      return;
    }
    unawaited(_finishAgentDetailSpeech(session, source: 'detail_tap'));
  }

  Future<void> _finishAgentDetailSpeech(
    SelectedAgentTranscriptSession session, {
    required String source,
  }) async {
    if (!_agentHistory.finishTargetedSpeechCapture(session.id) ||
        !session.requestFinish()) {
      return;
    }
    _stopSelectedAgentTranscriptionBlink();
    _syncSelectedAgentVadMode();
    _queueAgentHistoryDisplay();
    addLog(
      'WebSocket',
      '[WorkBench][VoiceRoute] state=detail_speech_finished '
          'source=$source action=flush_wait_correct_send',
    );
    try {
      await _audioPipeline.flushCurrentSpeechAndWait();
    } on Object catch (error) {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceRoute] state=flush_wait_failed '
            'source=$source error=${_oneLine(error)}',
        isError: true,
      );
    }
    await _submitSelectedAgentSessionIfReady(session);
  }

  void _activateAgentDetailListenMode() {
    if (!_agentHistory.selectDetailListenMode()) {
      return;
    }
    final agent = _agentHistory.selectedSpeechAgent;
    if (agent == null) {
      _agentHistory.exitDetailListenMode();
      return;
    }
    final revision = ++_selectedAgentListenSessionRevision;
    final session = SelectedAgentTranscriptSession(
      id:
          'agent-listen-'
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-$revision',
      agent: agent,
      source: 'agent_detail',
    );
    if (!_agentHistory.beginTargetedSpeech(session.id)) {
      _agentHistory.exitDetailListenMode();
      return;
    }
    _selectedAgentListenSession = session;
    _syncSelectedAgentVadMode();
    _syncSelectedAgentTranscriptionStatus(session);
    _queueAgentHistoryDisplay();
    addLog(
      'WebSocket',
      '[WorkBench][AgentHistory] state=listen_mode_selected '
          'source=detail_tap boundary=manual',
    );
  }

  void _projectSelectedAgentSession(SelectedAgentTranscriptSession session) {
    if (_agentHistory.updateTargetedSpeechPreview(
      segmentId: session.id,
      transcript: session.displayTranscript,
      previewState: session.previewState,
    )) {
      _queueAgentHistoryDisplay();
    }
  }

  Future<void> _ensureSelectedAgentPreviewCorrection(
    SelectedAgentTranscriptSession session,
  ) async {
    final existing = _selectedAgentPreviewPumps[session.id];
    if (existing != null) {
      await existing;
      return;
    }
    final pump = _runSelectedAgentPreviewCorrection(session);
    _selectedAgentPreviewPumps[session.id] = pump;
    try {
      await pump;
    } finally {
      if (identical(_selectedAgentPreviewPumps[session.id], pump)) {
        _selectedAgentPreviewPumps.remove(session.id);
      }
    }
  }

  Future<void> _runSelectedAgentPreviewCorrection(
    SelectedAgentTranscriptSession session,
  ) async {
    while (session.previewEnabled &&
        !session.isCanceled &&
        (session.isListening || session.isFinishing)) {
      final snapshot = session.correctionSnapshot();
      if (snapshot == null || !session.markPreviewQueued(snapshot.revision)) {
        return;
      }
      _projectSelectedAgentSession(session);
      await Future<void>.delayed(Duration.zero);
      if (!session.markPreviewCorrecting(snapshot.revision)) {
        continue;
      }
      _projectSelectedAgentSession(session);
      TranscriptCorrectionPreviewResult result;
      try {
        result = await _audioPipeline.correctCollectedTranscriptPreview(
          segmentId: '${session.id}-preview-${snapshot.revision}',
          transcript: snapshot.transcript,
        );
      } on Object catch (error) {
        session.failPreview(snapshot.revision);
        _projectSelectedAgentSession(session);
        addLog(
          'WebSocket',
          '[WorkBench][VoiceRoute] state=preview_failed '
              'source=${session.source} error=${_oneLine(error)}',
          isError: true,
        );
        return;
      }
      if (!result.isCorrected) {
        session.failPreview(snapshot.revision);
        _projectSelectedAgentSession(session);
        addLog(
          'WebSocket',
          '[WorkBench][VoiceRoute] state=preview_failed '
              'source=${session.source} reason=${result.failureReason ?? 'unavailable'}',
          isError: true,
        );
        return;
      }
      if (session.acceptPreview(
        revision: snapshot.revision,
        correctedTranscript: result.transcript,
      )) {
        _selectedAgentPreviewResults[session.id] = result;
        _projectSelectedAgentSession(session);
        addLog(
          'WebSocket',
          '[WorkBench][VoiceRoute] state=preview_updated '
              'source=${session.source} revision=${snapshot.revision} '
              'current=${session.isPreviewCurrent}',
        );
      }
    }
  }

  void _syncSelectedAgentTranscriptionStatus(
    SelectedAgentTranscriptSession session,
  ) {
    final pending = session.isListening && session.hasPendingSegments;
    if (!pending) {
      _stopSelectedAgentTranscriptionBlink();
    }
    final changed = _agentHistory.updateTargetedSpeechTranscription(
      segmentId: session.id,
      pending: pending,
      indicatorVisible: pending
          ? _selectedAgentTranscriptionIndicatorVisible
          : false,
    );
    if (changed) {
      _queueAgentHistoryDisplay();
    }
    if (!pending || _selectedAgentTranscriptionBlinkTimer != null) {
      return;
    }
    _selectedAgentTranscriptionIndicatorVisible = true;
    _selectedAgentTranscriptionBlinkTimer = Timer.periodic(
      const Duration(milliseconds: 650),
      (_) {
        final active = _selectedAgentListenSession;
        if (_disposed ||
            !identical(active, session) ||
            !session.isListening ||
            !session.hasPendingSegments) {
          _stopSelectedAgentTranscriptionBlink();
          return;
        }
        _selectedAgentTranscriptionIndicatorVisible =
            !_selectedAgentTranscriptionIndicatorVisible;
        if (_agentHistory.updateTargetedSpeechTranscription(
          segmentId: session.id,
          pending: true,
          indicatorVisible: _selectedAgentTranscriptionIndicatorVisible,
        )) {
          _queueAgentHistoryDisplay();
        }
      },
    );
  }

  void _stopSelectedAgentTranscriptionBlink() {
    _selectedAgentTranscriptionBlinkTimer?.cancel();
    _selectedAgentTranscriptionBlinkTimer = null;
    _selectedAgentTranscriptionIndicatorVisible = true;
  }

  bool _focusAgentBackControlFromSwipe() {
    var changed = false;
    if (_agentHistory.detailListenModeSelected) {
      changed = _exitAgentDetailListenMode(
        source: 'detail_swipe_up',
        queueDisplay: false,
      );
    }
    final focused = _agentHistory.focusAgentBackControl();
    if (focused) {
      addLog(
        'WebSocket',
        '[WorkBench][AgentHistory] state=detail_control_focused '
            'control=back',
      );
    }
    return changed || focused;
  }

  void _returnToAgentHistorySelector() {
    if (!_agentHistory.returnToSelector()) {
      return;
    }
    _cancelSelectedAgentListenSession(source: 'detail_return');
    _syncSelectedAgentVadMode();
    _queueAgentHistoryDisplay();
    addLog(
      'WebSocket',
      '[WorkBench][AgentHistory] state=detail_closed destination=selector',
    );
  }

  bool _exitAgentDetailListenMode({
    required String source,
    bool queueDisplay = true,
  }) {
    if (!_agentHistory.exitDetailListenMode()) {
      return false;
    }
    _cancelSelectedAgentListenSession(source: source);
    _syncSelectedAgentVadMode();
    if (queueDisplay) {
      _queueAgentHistoryDisplay();
    }
    addLog(
      'WebSocket',
      '[WorkBench][AgentHistory] state=listen_mode_exited source=$source',
    );
    return true;
  }

  void _cancelSelectedAgentListenSession({required String source}) {
    final session = _selectedAgentListenSession;
    if (session == null || !session.cancel()) {
      return;
    }
    _selectedAgentPreviewResults.remove(session.id);
    _stopSelectedAgentTranscriptionBlink();
    unawaited(_flushCanceledSelectedAgentSession(session, source: source));
  }

  Future<void> _flushCanceledSelectedAgentSession(
    SelectedAgentTranscriptSession session, {
    required String source,
  }) async {
    try {
      await _audioPipeline.flushCurrentSpeechAndWait();
    } on Object catch (error) {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceRoute] state=cancel_flush_failed '
            'source=$source error=${_oneLine(error)}',
        isError: true,
      );
    }
    if (identical(_selectedAgentListenSession, session)) {
      _selectedAgentListenSession = null;
    }
    addLog(
      'WebSocket',
      '[WorkBench][AgentHistory] state=listen_mode_canceled source=$source',
    );
  }

  Future<void> _handleCollectedTranscript(
    String segmentId,
    String transcript,
  ) async {
    final session = _selectedAgentCollectionSegments.remove(segmentId);
    if (session == null || !session.completeSegment(segmentId, transcript)) {
      return;
    }
    _projectSelectedAgentSession(session);
    _syncSelectedAgentTranscriptionStatus(session);
    addLog(
      'WebSocket',
      '[WorkBench][VoiceRoute] state=transcript_accumulated '
          'source=${session.source} pending=${session.hasPendingSegments}',
    );
    if (session.previewEnabled) {
      unawaited(_ensureSelectedAgentPreviewCorrection(session));
    }
    if (session.isFinishing) {
      await _submitSelectedAgentSessionIfReady(session);
    } else if (session.isCanceled &&
        !session.hasPendingSegments &&
        identical(_selectedAgentListenSession, session)) {
      _selectedAgentListenSession = null;
    }
  }

  Future<void> _submitSelectedAgentSessionIfReady(
    SelectedAgentTranscriptSession session,
  ) {
    final existing = _selectedAgentSubmissions[session.id];
    if (existing != null) {
      return existing;
    }
    if (!session.finishedWithoutTranscript && !session.canSubmit) {
      return Future<void>.value();
    }
    final submission = _performSelectedAgentSessionSubmission(session);
    _selectedAgentSubmissions[session.id] = submission;
    return submission.whenComplete(() {
      if (identical(_selectedAgentSubmissions[session.id], submission)) {
        _selectedAgentSubmissions.remove(session.id);
      }
    });
  }

  Future<void> _performSelectedAgentSessionSubmission(
    SelectedAgentTranscriptSession session,
  ) async {
    if (session.markFinishedWithoutTranscript()) {
      _selectedAgentPreviewResults.remove(session.id);
      if (identical(_selectedAgentListenSession, session)) {
        _selectedAgentListenSession = null;
      }
      if (_agentHistory.completeTargetedSpeech(
        segmentId: session.id,
        transcript: '',
        sent: false,
      )) {
        _queueAgentHistoryDisplay();
      }
      addLog(
        'WebSocket',
        '[WorkBench][VoiceRoute] state=manual_collection_empty '
            'source=${session.source} action=saved',
      );
      return;
    }
    if (session.previewEnabled) {
      await _ensureSelectedAgentPreviewCorrection(session);
    }
    if (!session.markSubmitted()) {
      return;
    }
    _selectedAgentSpeechRoutes[session.id] = _SelectedAgentSpeechRoute(
      agent: session.agent,
      source: session.source,
    );
    while (_selectedAgentSpeechRoutes.length >
        _maximumSelectedAgentSpeechRoutes) {
      _selectedAgentSpeechRoutes.remove(_selectedAgentSpeechRoutes.keys.first);
    }
    if (identical(_selectedAgentListenSession, session)) {
      _selectedAgentListenSession = null;
    }
    try {
      final correctionMode = session.sendCorrectionMode;
      final previewResult = _selectedAgentPreviewResults[session.id];
      final accepted = switch (correctionMode) {
        SelectedAgentSendCorrectionMode.reusePreview =>
          await _audioPipeline.submitCollectedTranscriptProjection(
            segmentId: session.id,
            rawTranscript: session.transcript,
            transcript: session.previewTranscript!,
            isCorrected: true,
            previewResult: previewResult,
          ),
        SelectedAgentSendCorrectionMode.preserveRaw =>
          await _audioPipeline.submitCollectedTranscriptProjection(
            segmentId: session.id,
            rawTranscript: session.transcript,
            transcript: session.transcript,
            isCorrected: false,
          ),
        SelectedAgentSendCorrectionMode.correctAtSend =>
          await _audioPipeline.correctCollectedTranscript(
            segmentId: session.id,
            transcript: session.transcript,
          ),
      };
      if (!accepted) {
        throw StateError('Collected transcript was not accepted.');
      }
      addLog(
        'WebSocket',
        '[WorkBench][VoiceRoute] state=manual_collection_submitted '
            'source=${session.source} correction='
            '${correctionMode.name}',
      );
    } on Object catch (error) {
      _selectedAgentSpeechRoutes.remove(session.id);
      await _completeTranscriptProjection(
        segmentId: session.id,
        transcript: session.transcript,
        sent: false,
      );
      addLog(
        'WebSocket',
        '[WorkBench][VoiceRoute] state=manual_collection_failed '
            'source=${session.source} error=${_oneLine(error)}',
        isError: true,
      );
    } finally {
      _selectedAgentPreviewResults.remove(session.id);
    }
  }

  Future<void> _commitQueuedTranscriptFromTap(
    QueuedGlassesTranscript queued,
    QueuedTranscriptTapAction action,
  ) async {
    if (action == QueuedTranscriptTapAction.correctAndRoute) {
      final markedSending = await _glassesStatusQueue.markTranscriptSending(
        segmentId: queued.segmentId,
      );
      if (!markedSending) {
        addLog(
          'WebSocket',
          '[WorkBench][VoiceRoute] state=queued_tap '
              'action=superseded',
        );
        return;
      }
      final prioritized = await _audioPipeline.prioritizeQueuedCorrection(
        queued.segmentId,
      );
      addLog(
        'WebSocket',
        '[WorkBench][VoiceRoute] state=queued_tap '
            'action=${prioritized ? 'correction_prioritized' : 'correction_in_flight'}',
      );
      return;
    }
    if (action != QueuedTranscriptTapAction.save) {
      return;
    }
    await _glassesStatusQueue.completeTranscript(
      segmentId: queued.segmentId,
      transcript: queued.transcript,
      outcome: GlassesTranscriptOutcome.saved,
    );
    addLog(
      'WebSocket',
      '[WorkBench][VoiceRoute] state=queued_tap action=saved '
          'reason=no_leading_hey',
    );
  }

  Future<void> _openAgentHistory() async {
    if (_disposed ||
        _voiceMemo.isActive ||
        _agentHistory.isOpen ||
        _agentHistoryOpening ||
        _agentHistoryClosing) {
      return;
    }
    _agentHistoryOpening = true;
    final generation = ++_agentHistoryGeneration;
    try {
      _glassesStatusQueue.setPaused(true, owner: 'history');
      List<AgentExchangeView> exchanges = const <AgentExchangeView>[];
      List<AgentMessageView> messages = const <AgentMessageView>[];
      if (_agentExchangeStoreReady) {
        try {
          final loaded = await Future.wait<Object>(<Future<Object>>[
            _agentExchangeStore.latestForAgents(
              _voiceWebSocket.config.agentNames,
              maximumAgents: G2AgentHistoryState.maximumAgents,
            ),
            _agentExchangeStore.retainedMessagesForAgents(
              _voiceWebSocket.config.agentNames,
            ),
          ]);
          exchanges = loaded[0] as List<AgentExchangeView>;
          messages = loaded[1] as List<AgentMessageView>;
        } on Object {
          addLog(
            'WebSocket',
            '[WorkBench][AgentHistory] state=load_failed',
            isError: true,
          );
        }
      }
      if (_disposed ||
          _voiceMemo.isActive ||
          generation != _agentHistoryGeneration) {
        _agentHistory.close();
        _syncSelectedAgentVadMode();
        return;
      }
      final memo = _voiceMemo.records
          .where((record) => !record.isActive && record.note.trim().isNotEmpty)
          .firstOrNull;
      _agentHistory.open(
        agents: _voiceWebSocket.config.agentNames,
        exchanges: exchanges,
        messages: messages,
        memo: memo?.note,
      );
      _syncSelectedAgentVadMode();
      await _showAgentHistory();
      addLog(
        'WebSocket',
        '[WorkBench][AgentHistory] state=opened '
            'agents=${_agentHistory.entries.length - 2}',
      );
    } finally {
      _agentHistoryOpening = false;
    }
  }

  Future<void> _activateAgentHistorySelection() async {
    if (_agentHistory.mode != G2AgentHistoryMode.selector) {
      await _closeAgentHistory(clearDisplay: true);
      return;
    }
    final selected = _agentHistory.selected;
    if (selected == null || selected.kind == G2AgentHistoryEntryKind.dismiss) {
      await _closeAgentHistory(clearDisplay: true);
      return;
    }
    if (selected.kind == G2AgentHistoryEntryKind.memo) {
      _agentHistory.showSelectedDetail();
      _syncSelectedAgentVadMode();
      await _showAgentHistory();
      return;
    }
    List<AgentMessageView>? messages;
    if (_agentExchangeStoreReady) {
      try {
        messages = await _agentExchangeStore.retainedMessagesForAgents(<String>[
          selected.label,
        ]);
      } on Object {
        addLog(
          'WebSocket',
          '[WorkBench][AgentHistory] state=message_load_failed '
              'fallback=latest',
          isError: true,
        );
      }
    }
    if (_agentHistory.mode != G2AgentHistoryMode.selector ||
        _agentHistory.selected?.label != selected.label) {
      return;
    }
    if (messages == null) {
      _agentHistory.showAgentConversations(
        selected.exchange == null
            ? const <AgentExchangeView>[]
            : <AgentExchangeView>[selected.exchange!],
      );
    } else {
      _agentHistory.showAgentMessages(messages);
    }
    _syncSelectedAgentVadMode();
    await _showAgentHistory();
    addLog(
      'WebSocket',
      '[WorkBench][AgentHistory] state=messages_opened '
          'messages=${messages?.length ?? (selected.exchange == null ? 0 : 1)}',
    );
  }

  void _queueAgentHistoryDisplay({bool allowPageReplacement = true}) {
    unawaited(_showAgentHistory(allowPageReplacement: allowPageReplacement));
  }

  void _syncSelectedAgentVadMode() {
    _audioPipeline.setSelectedAgentDetailVadMode(
      _agentHistory.isAgentDetailSpeechTarget,
    );
  }

  Future<void> sendTestDetailThumb() async {
    if (_agentHistory.isOpen) {
      await _closeAgentHistory(clearDisplay: false);
    }
    await _historyDisplayQueue.waitForIdle();
    await g2.sendTestDetailThumb();
  }

  Future<void> _showAgentHistory({bool allowPageReplacement = true}) async {
    if (_disposed || !_agentHistory.isOpen || !g2.isConnected) {
      return;
    }
    final generation = _agentHistoryGeneration;
    final isDetail = _agentHistory.mode == G2AgentHistoryMode.detail;
    final content = _agentHistory.render();
    final pageIndex = isDetail ? _agentHistory.detailPageIndex : 0;
    final pageCount = isDetail ? _agentHistory.detailPageCount : 1;
    final key =
        '$generation\u0000${_agentHistory.mode.name}\u0000'
        '$pageIndex\u0000$pageCount\u0000$content';
    await _historyDisplayQueue.schedule(
      key: key,
      render: () async {
        if (_disposed ||
            generation != _agentHistoryGeneration ||
            !_agentHistory.isOpen ||
            !g2.isConnected) {
          return;
        }
        await g2.showFullPageText(
          content,
          showPageIndicator: isDetail,
          pageIndex: pageIndex,
          pageCount: pageCount,
          borderWidth: G2Protocol.expandedTextBorderWidth,
          borderColor: G2Protocol.expandedTextBorderColor,
          paddingLength: G2Protocol.expandedTextPaddingLength,
          allowPageReplacement: allowPageReplacement,
        );
      },
      onError: (_) {
        addLog(
          'WebSocket',
          '[WorkBench][AgentHistory] state=display_failed',
          isError: true,
        );
      },
    );
  }

  Future<void> _closeAgentHistory({required bool clearDisplay}) async {
    if (_agentHistoryClosing ||
        (!_agentHistory.isOpen && !_agentHistoryOpening)) {
      return;
    }
    _agentHistoryClosing = true;
    _agentHistoryGeneration++;
    try {
      _agentHistoryWaitTimer?.cancel();
      _agentHistoryWaitTimer = null;
      _cancelSelectedAgentListenSession(source: 'history_close');
      _agentHistory.close();
      _syncSelectedAgentVadMode();
      _historyDisplayQueue.reset();
      if (clearDisplay && g2.isConnected && !g2.isMemoDisplayActive) {
        try {
          await g2.exitFullPageText();
        } on Object {
          addLog(
            'WebSocket',
            '[WorkBench][AgentHistory] state=clear_display_failed',
            isError: true,
          );
        }
      }
      if (!_voiceMemo.isActive) {
        _glassesStatusQueue.setPaused(false);
      }
      addLog('WebSocket', '[WorkBench][AgentHistory] state=closed');
    } finally {
      _agentHistoryClosing = false;
    }
  }

  Future<void> _requestLastAgentSummary() async {
    if (_voiceWebSocket.lastSentAgent == null) {
      await _glassesStatusQueue.queueTransient(
        prefix: 'Update',
        message: 'Send a command first',
      );
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=summary_skipped '
            'reason=no_sent_agent',
      );
      return;
    }
    await _glassesStatusQueue.queueTransient(
      prefix: 'Update',
      message: 'Requesting',
    );
    final outcome = await _voiceWebSocket.requestLastSentAgentSummary();
    if (outcome == VoiceWebSocketSummaryRequestOutcome.sent) {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=summary_requested',
      );
      return;
    }
    await _glassesStatusQueue.queueTransient(
      prefix: 'Update',
      message: outcome == VoiceWebSocketSummaryRequestOutcome.noSentAgent
          ? 'Send a command first'
          : 'Unavailable',
    );
    addLog(
      'WebSocket',
      '[WorkBench][VoiceWebSocket] state=summary_failed '
          'reason=${outcome.name}',
      isError: outcome == VoiceWebSocketSummaryRequestOutcome.unavailable,
    );
  }

  Future<void> _handleFinalTranscript(FinalTranscriptDelivery delivery) =>
      _handleFinalTranscriptDelivery(delivery);

  Future<void> _handleFinalTranscriptDelivery(
    FinalTranscriptDelivery delivery,
  ) async {
    final segmentId = delivery.segmentId;
    final transcript = delivery.transcript;
    final selectedRoute = _selectedAgentSpeechRoutes.remove(segmentId);
    _syncSelectedAgentVadMode();
    if (selectedRoute == null &&
        await _voiceMemo.acceptFinalTranscript(segmentId, transcript)) {
      addLog(
        'Memo',
        '[WorkBench][Memo] state=transcript_consumed stage=final '
            'websocket=skipped',
      );
      return;
    }
    if (!finalTranscriptCanRoute(delivery)) {
      await _completeTranscriptProjection(
        segmentId: segmentId,
        transcript: transcript,
        sent: false,
      );
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=saved routed=false '
            'reason=correction_not_completed',
      );
      return;
    }
    final correctedRoute = selectedRoute == null
        ? _voiceWebSocket.routeForTranscript(transcript)
        : null;
    final route = selectedRoute == null
        ? _voiceWebSocket.routeForTranscript(
            transcript,
            evidenceTranscript: delivery.rawTranscript,
          )
        : _voiceWebSocket.routeTranscriptToSelectedAgent(
            selectedAgent: selectedRoute.agent,
            transcript: transcript,
          );
    if (route == null) {
      await _completeTranscriptProjection(
        segmentId: segmentId,
        transcript: transcript,
        sent: false,
      );
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=saved routed=false '
            'reason=${selectedRoute != null
                ? 'selected_agent_unavailable'
                : correctedRoute == null
                ? 'no_match'
                : 'missing_leading_hey_evidence'}',
      );
      return;
    }
    if (selectedRoute == null) {
      await _glassesStatusQueue.markTranscriptSending(segmentId: segmentId);
    }
    final sendResult = await _voiceWebSocket.sendAgentMessageWithResult(
      agent: route.agent,
      message: route.message,
      deliveryMode: deliveryModeForAgentRoute(
        explicitlySelected: selectedRoute != null,
      ),
    );
    final sent = sendResult.sent;
    await completeAgentRouteConsumers(
      updateDisplay: () => _completeTranscriptProjection(
        segmentId: segmentId,
        transcript: transcript,
        sent: sent,
      ),
      persistAcknowledgedMessage: sent
          ? () => _persistAcknowledgedAgentMessage(sendResult)
          : null,
    );
    addLog(
      'WebSocket',
      '[WorkBench][VoiceWebSocket] '
          'state=${sent ? 'sent' : 'saved'} routed=true '
          'source=${selectedRoute?.source ?? 'spoken_invocation'}',
    );
  }

  Future<void> _completeTranscriptProjection({
    required String segmentId,
    required String transcript,
    required bool sent,
  }) async {
    if (_agentHistory.completeTargetedSpeech(
      segmentId: segmentId,
      transcript: transcript,
      sent: sent,
    )) {
      _queueAgentHistoryDisplay();
      return;
    }
    await _glassesStatusQueue.completeTranscript(
      segmentId: segmentId,
      transcript: transcript,
      outcome: sent
          ? GlassesTranscriptOutcome.sent
          : GlassesTranscriptOutcome.saved,
    );
  }

  Future<void> _handleQueuedTranscript(
    String segmentId,
    String transcript,
  ) async {
    final selectedRoute = _selectedAgentSpeechRoutes[segmentId];
    if (selectedRoute == null &&
        _voiceMemo.acceptRawTranscript(segmentId, transcript)) {
      addLog(
        'Memo',
        '[WorkBench][Memo] state=transcript_consumed stage=raw '
            'websocket=skipped',
      );
      return;
    }
    if (selectedRoute != null) {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceRoute] state=queued '
            'source=${selectedRoute.source} correction=required',
      );
      if (_agentHistory.showTargetedSpeechTranscript(
        segmentId: segmentId,
        transcript: transcript,
      )) {
        _queueAgentHistoryDisplay();
        return;
      }
    }
    await _glassesStatusQueue.queueTranscript(
      segmentId: segmentId,
      transcript: transcript,
    );
  }

  Future<void> _handleInboundWebSocketEvent(
    VoiceWebSocketInboundEvent event,
  ) async {
    final message = event.message;
    Object? persistenceError;
    SavedWebSocketMessage? savedMessage;
    try {
      final saved = await _webSocketMessageStore.save(
        direction: WebSocketMessageDirection.received,
        message: message,
      );
      savedMessage = saved;
      try {
        final exported = await _sharedAudioExportStore.exportFiles(<String>[
          saved.path,
        ]);
        addLog(
          'WebSocket',
          '[WorkBench][VoiceWebSocket] state=received_saved '
              'shared=${exported > 0}',
        );
        if (exported > 0 && _sharedMessageViewActive) {
          unawaited(_refreshSharedWebSocketMessages());
        }
      } on Object {
        addLog(
          'WebSocket',
          '[WorkBench][VoiceWebSocket] state=received_export_failed '
              'fallback=app_private',
          isError: true,
        );
      }
    } on Object catch (error) {
      persistenceError = error;
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=received_save_failed '
            'action=check_app_storage',
        isError: true,
      );
    }
    if (savedMessage != null && _agentExchangeStoreReady) {
      try {
        var indexedAgent = event.agent;
        final exchangeId = await _agentExchangeStore.attachResponse(
          responsePath: savedMessage.path,
          kind: event.kind.name,
          requestId: event.requestId,
          agent: event.agent,
          allowLegacyAgentMatch: _voiceWebSocket.config.useLegacyMessageShape,
        );
        final exchange = exchangeId == null
            ? null
            : await _agentExchangeStore.viewById(exchangeId);
        indexedAgent ??= exchange?.agent;
        if (exchangeId != null &&
            _agentHistory.waitingExchangeId == exchangeId) {
          final response = exchange?.response;
          if (response != null &&
              _agentHistory.acceptResponse(
                exchangeId,
                response,
                receivedAt: exchange?.responseAt,
              )) {
            _agentHistoryWaitTimer?.cancel();
            _agentHistoryWaitTimer = null;
            _queueAgentHistoryDisplay();
          }
        }
        await _refreshOpenAgentHistoryFor(indexedAgent);
      } on Object {
        addLog(
          'WebSocket',
          '[WorkBench][AgentHistory] state=response_index_failed '
              'fallback=message_file',
          isError: true,
        );
      }
    }
    if (_sharedMessageViewActive) {
      unawaited(_refreshAgentMessages());
    }
    await _glassesStatusQueue.queueTransient(
      prefix: 'Received',
      message: message,
    );
    addLog(
      'WebSocket',
      '[WorkBench][VoiceWebSocket] state=received '
          'characters=${message.length}',
    );
    if (persistenceError != null) {
      throw StateError('Inbound message persistence failed.');
    }
  }

  Future<SavedWebSocketMessage?> _archiveWebSocketMessage({
    required WebSocketMessageDirection direction,
    required String message,
    required String failureState,
  }) async {
    try {
      final saved = await _webSocketMessageStore.save(
        direction: direction,
        message: message,
      );
      try {
        final exported = await _sharedAudioExportStore.exportFiles(<String>[
          saved.path,
        ]);
        if (exported > 0 && _sharedMessageViewActive) {
          unawaited(_refreshSharedWebSocketMessages());
        }
      } on Object {
        addLog(
          'WebSocket',
          '[WorkBench][VoiceWebSocket] state=message_export_failed '
              'fallback=app_private',
          isError: true,
        );
      }
      return saved;
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=$failureState '
            'action=check_app_storage',
        isError: true,
      );
      return null;
    }
  }

  Future<void> _persistAcknowledgedAgentMessage(
    VoiceWebSocketSendResult result,
  ) async {
    final saved = await _archiveWebSocketMessage(
      direction: WebSocketMessageDirection.sent,
      message: '${result.agent}: ${result.message}',
      failureState: 'sent_save_failed',
    );
    if (saved == null || !_agentExchangeStoreReady) {
      return;
    }
    try {
      await _agentExchangeStore.recordSent(
        agent: result.agent,
        messagePath: saved.path,
        legacy: result.legacy,
        requestId: result.requestId,
      );
      await _refreshOpenAgentHistoryFor(result.agent);
      if (_sharedMessageViewActive) {
        await _refreshAgentMessages();
      }
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][AgentHistory] state=sent_index_failed '
            'fallback=message_file',
        isError: true,
      );
    }
  }

  Future<void> _refreshAgentMessages() async {
    final generation = ++_agentMessageRefreshGeneration;
    if (!_agentExchangeStoreReady) {
      _agentMessages = const <AgentMessageView>[];
      _agentMessageError = 'Agent message history is unavailable.';
      _isLoadingAgentMessages = false;
      _safeNotify();
      return;
    }
    final agents = _voiceWebSocket.config.agentNames;
    if (agents.isEmpty) {
      _agentMessages = const <AgentMessageView>[];
      _agentMessageError = null;
      _isLoadingAgentMessages = false;
      _safeNotify();
      return;
    }
    _isLoadingAgentMessages = true;
    _agentMessageError = null;
    _safeNotify();
    try {
      final messages = await _agentExchangeStore.retainedMessagesForAgents(
        agents,
      );
      if (generation == _agentMessageRefreshGeneration) {
        _agentMessages = messages;
      }
    } on Object {
      if (generation == _agentMessageRefreshGeneration) {
        _agentMessageError = 'Could not load agent messages. Retry.';
      }
    } finally {
      if (generation == _agentMessageRefreshGeneration) {
        _isLoadingAgentMessages = false;
        _safeNotify();
      }
    }
  }

  Future<bool> _refreshOpenAgentHistoryFor(String? agent) async {
    final openAgent = _agentHistory.openDetailAgent;
    final normalizedAgent = agent?.trim().toLowerCase();
    if (_disposed ||
        !_agentExchangeStoreReady ||
        openAgent == null ||
        normalizedAgent == null ||
        normalizedAgent.isEmpty ||
        openAgent.trim().toLowerCase() != normalizedAgent) {
      return false;
    }
    try {
      final messages = await _agentExchangeStore.retainedMessagesForAgents(
        <String>[openAgent],
      );
      if (!_agentHistory.refreshOpenAgentMessages(
        agent: openAgent,
        messages: messages,
      )) {
        return false;
      }
      _syncSelectedAgentVadMode();
      _queueAgentHistoryDisplay();
      addLog(
        'WebSocket',
        '[WorkBench][AgentHistory] state=messages_refreshed '
            'source=socket messages=${messages.length}',
      );
      return true;
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][AgentHistory] state=message_refresh_failed '
            'fallback=durable_history',
        isError: true,
      );
      return false;
    }
  }

  Future<void> _syncWebSocketMessages() async {
    if (!_sharedAudioExportStore.hasSharedFolder) {
      return;
    }
    try {
      final paths = await _webSocketMessageStore.savedPaths();
      if (paths.isEmpty) {
        return;
      }
      final exported = await _sharedAudioExportStore.exportFiles(paths);
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=message_sync '
            'files=$exported',
      );
    } on Object {
      addLog(
        'WebSocket',
        '[WorkBench][VoiceWebSocket] state=message_sync_failed '
            'action=choose_folder_again',
        isError: true,
      );
    }
  }

  Future<void> _refreshSharedWebSocketMessages() async {
    try {
      await _sharedAudioExportStore.refreshMessages();
    } on Object {
      // The Messages view exposes the retained load error and a manual retry.
    }
  }

  void _unexpectedG2Disconnect(String side) {
    if (_g2UnexpectedlyDisconnected || _disposed) {
      return;
    }
    _g2UnexpectedlyDisconnected = true;
    _lastControllerLinkKey = null;
    addLog(
      'Pipeline',
      '[WorkBench][Bluetooth] state=disconnected expected=false side=$side',
      isError: true,
    );
    _audioPipeline.handleWearableDisconnect(expected: false);
    _voiceMemo.handleWearableDisconnect();
  }

  void _handleUnsafeCapture() {
    if (_disposed) {
      return;
    }
    addLog(
      'Pipeline',
      '[WorkBench][Capture] state=dropped action=disconnect',
      isError: true,
    );
    unawaited(disconnectAll());
  }

  void _audioChanged() {
    if (_disposed) {
      return;
    }
    if (_lifecycleState != AppLifecycleState.resumed) {
      _safeNotify();
      return;
    }
    if (_audioNotifyTimer != null) {
      return;
    }
    // G2 delivers about 100 LC3 frames per second. Keep processing every
    // frame, but repaint the Flutter UI at a smooth 30 FPS so BLE callbacks
    // and latency-sensitive gesture writes are not competing with 100 full
    // home-page rebuilds every second.
    _audioNotifyTimer = Timer(_audioUiFrameInterval, () {
      _audioNotifyTimer = null;
      _safeNotify();
    });
  }

  void _safeNotify() {
    if (_disposed) {
      return;
    }
    if (_lifecycleState == AppLifecycleState.resumed) {
      notifyListeners();
      return;
    }
    // BLE and audio stay fully active in the background. Only coalesce
    // non-visible Flutter UI notifications so they cannot build avoidable
    // rendering/state pressure while another app is in front.
    _backgroundNotifyTimer ??= Timer(const Duration(seconds: 1), () {
      _backgroundNotifyTimer = null;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  static String _oneLine(Object value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    addLog('Lifecycle', state.name);
    if (state != AppLifecycleState.resumed) {
      _audioNotifyTimer?.cancel();
      _audioNotifyTimer = null;
    }
    if (state == AppLifecycleState.resumed) {
      _backgroundNotifyTimer?.cancel();
      _backgroundNotifyTimer = null;
      unawaited(_conversationAnalysis.resumeAfterMemoryPressure());
      _safeNotify();
    }
    unawaited(
      _runtime.handleLifecycleState(
        state,
        wearableSessionActive: _hasWearableSession,
      ),
    );
  }

  @override
  void didHaveMemoryPressure() {
    _backgroundNotifyTimer?.cancel();
    _backgroundNotifyTimer = null;
    if (logs.length > _memoryPressureLogEntries) {
      logs.removeRange(_memoryPressureLogEntries, logs.length);
    }
    if (!scanning) {
      _g2ByKey.clear();
      _r1ById.clear();
      _loggedR1Advertisements.clear();
    }
    addLog(
      'Runtime',
      'Released nonessential diagnostic history after memory pressure',
    );
    unawaited(_audioPipeline.handleMemoryPressure());
    unawaited(_conversationAnalysis.handleMemoryPressure());
    unawaited(_voiceMemo.handleMemoryPressure());
    unawaited(_closeAgentHistory(clearDisplay: true));
  }

  @override
  void dispose() {
    _disposed = true;
    _stopSelectedAgentTranscriptionBlink();
    _selectedAgentPreviewResults.clear();
    _agentHistoryWaitTimer?.cancel();
    _agentHistoryWaitTimer = null;
    _agentHistory.close();
    WidgetsBinding.instance.removeObserver(this);
    _sharedAudioExportStore.removeListener(_sharedStorageChanged);
    _voiceWebSocket.removeListener(_voiceWebSocketChanged);
    _glassesStatusQueue.dispose();
    _sharedAudioExportStore.dispose();
    _scanTimer?.cancel();
    _notifyTimer?.cancel();
    _audioNotifyTimer?.cancel();
    _backgroundNotifyTimer?.cancel();
    unawaited(_scanSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    unawaited(g2.dispose());
    unawaited(r1.dispose());
    unawaited(_conversationAnalysis.dispose());
    unawaited(_voiceMemo.dispose());
    unawaited(_audioPipeline.dispose());
    unawaited(_voiceWebSocket.close());
    unawaited(_runtime.dispose());
    super.dispose();
  }
}
