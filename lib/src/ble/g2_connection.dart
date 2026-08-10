import 'dart:async';
import 'dart:io';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter/services.dart';

import '../audio/g2_audio_analysis_worker.dart';
import '../protocol/g2_protocol.dart';
import '../util/hex.dart';
import 'ble_models.dart';
import 'g2_page_render_safety.dart';

typedef G2GestureConsumer = bool Function(G2GestureEvent event);

final class G2PairingException implements Exception {
  const G2PairingException(this.side);

  final String side;

  @override
  String toString() {
    return '$side G2 lens pairing was rejected or timed out. '
        'Confirm “Pair” in the Android Bluetooth request, then retry.';
  }
}

final class G2Connection {
  static const Duration _pulseRefreshInterval = Duration(milliseconds: 350);
  static const Duration _gestureDisplayHoldoff = Duration(milliseconds: 500);
  static const Duration _pageReplacementSettleInterval = Duration(
    milliseconds: 750,
  );
  static const MethodChannel _bondChannel = MethodChannel(
    'dev.opensourceglasses/r1_bond',
  );

  G2Connection({
    required FlutterReactiveBle ble,
    required WearableLogSink log,
    required void Function() onChanged,
    required void Function() onAudioChanged,
    required void Function(Uint8List bytes) onLc3Audio,
    required void Function(String side) onUnexpectedDisconnect,
    G2GestureConsumer? onGesture,
  }) : _ble = ble,
       _log = log,
       _onChanged = onChanged,
       _onAudioChanged = onAudioChanged,
       _onLc3Audio = onLc3Audio,
       _onUnexpectedDisconnect = onUnexpectedDisconnect,
       _onGesture = onGesture {
    _audioAnalysisWorker = G2AudioAnalysisWorker(
      onSnapshot: _handleAudioAnalysis,
    );
    unawaited(_audioAnalysisWorker.start());
  }

  final FlutterReactiveBle _ble;
  final WearableLogSink _log;
  final void Function() _onChanged;
  final void Function() _onAudioChanged;
  final void Function(Uint8List bytes) _onLc3Audio;
  final void Function(String side) _onUnexpectedDisconnect;
  final G2GestureConsumer? _onGesture;
  late final G2AudioAnalysisWorker _audioAnalysisWorker;
  final G2Protocol _protocol = G2Protocol();
  final G2ReceiveAssembler _receiveAssembler = G2ReceiveAssembler();

  final _Lens _left = _Lens(G2Side.left);
  final _Lens _right = _Lens(G2Side.right);
  Timer? _evenHubHeartbeat;
  Timer? _deviceHeartbeat;
  Timer? _audioWatchdog;
  Timer? _reconnectTimer;
  Timer? _pageRestoreTimer;
  Timer? _inferredHoldAudioTimer;
  Timer? _pulseTimer;
  Timer? _visibleGestureTimer;
  G2PairCandidate? _target;
  bool _manualDisconnect = false;
  bool _pageCreated = false;
  String _lastPageContent = '';
  bool _memoDisplayActive = false;
  bool _fullPageTextActive = false;
  bool _fullPageTextIndicatorActive = false;
  int _fullPageTextPageIndex = 0;
  int _fullPageTextPageCount = 1;
  int _fullPageTextBorderWidth = G2Protocol.fullPageTextBorderWidth;
  int _fullPageTextBorderColor = G2Protocol.fullPageTextBorderColor;
  int _fullPageTextPaddingLength = G2Protocol.fullPageTextPaddingLength;
  String _memoDisplayNote = '';
  String _memoDisplayStatus = '';
  List<String> _memoDisplayPages = const <String>[];
  int _memoDisplayPageIndex = 0;
  Uint8List? _lastAudioPacket;
  String? _activeAudioSource;
  DateTime? _lastAudioSummaryAt;
  int _audioSummaryBytes = 0;
  int _audioSummaryFrames = 0;
  double? _audioNoiseFloor;
  DateTime? _lastPulseUpdateAt;
  int? _lastPulseSignature;
  bool _pulseUpdateInFlight = false;
  bool _pulseUpdatePending = false;
  bool _audioRecoveryInFlight = false;
  DateTime? _lastAudioRecoveryAt;
  DateTime? _lastGestureEventAt;
  DateTime? _lastTypedUserInputAt;
  String? _lastGestureSignature;
  String? _visibleGesturePageLabel;
  DateTime? _lastR1SourceActivityAt;
  DateTime? _lastPageExitAt;
  DateTime? _lastForegroundExitAt;
  DateTime? _lastCapturedLongPressAt;
  DateTime? _lastHubAudioToggleAt;
  bool _hubAudioToggleInFlight = false;
  bool _nativeMenuOpen = false;
  bool _awaitingNativeMenuOpenConfirm = false;
  int _generation = 0;
  int _batteryHeartbeatCount = 0;
  int _controlledPageRendersInFlight = 0;

  LinkState state = LinkState.disconnected;
  bool audioEnabled = false;
  int audioPackets = 0;
  int audioBytes = 0;
  int audioFrames = 0;
  DateTime? lastAudioAt;
  String? lastGesture;
  String? lastGestureSource;
  DateTime? lastGestureAt;
  int gestureControlPackets = 0;
  String? lastGestureControlSummary;
  DateTime? lastGestureControlAt;
  int evenHubTouchPackets = 0;
  int unknownEvenHubTouchPackets = 0;
  int r1ActivityPackets = 0;
  int terminalPackets = 0;
  bool terminalModeEnabled = false;
  String terminalModeStatus = 'not requested';
  String terminalSessionStatus = 'not advertised';
  String? lastTerminalEvent;
  DateTime? lastTerminalEventAt;
  String? lastTouchDiagnostic;
  String? ringLinkStatus;
  DateTime? ringLinkStatusAt;
  String? lastR1ViaG2Event;
  DateTime? lastR1ViaG2EventAt;
  static const bool hubVisualizerMode = true;
  bool keepPageActive = true;
  bool captureLongPressForApp = true;
  bool startAudioOnInferredHold = false;
  bool doubleTapTogglesHubAudio = false;
  bool inferredHoldAudioActive = false;
  String hubHoldStatus =
      'Hub visualizer: continuous LC3; hold is inferred from Menu takeover';
  int pageExitEvents = 0;
  int pageRestoreAttempts = 0;
  String pageSessionStatus = 'not started';
  int pulseUpdates = 0;
  int pulseUpdatesSkipped = 0;
  int? lastPulseWriteDurationMs;
  int? lastGestureDisplayLatencyMs;
  int audioActivityLevel = 0;
  int? lastLc3GlobalGain;
  int? batteryLevel;
  bool? batteryCharging;
  String pulseStatus = 'waiting for LC3 audio';

  bool get isConnected => state == LinkState.connected;
  bool get isMemoDisplayActive => _memoDisplayActive;
  bool get isFullPageTextActive => _fullPageTextActive;
  String? get leftMac => _target?.leftMac;
  String? get rightMac => _target?.rightMac;

  Future<void> connect(G2PairCandidate target) async {
    if (!target.isComplete) {
      throw StateError('A G2 pair requires both the left and right lens.');
    }
    _target = target;
    _manualDisconnect = true;
    await _teardownLinks();
    _resetPulseState();
    batteryLevel = null;
    batteryCharging = null;
    _lastPageContent = '';
    audioEnabled = false;
    _manualDisconnect = false;
    final generation = ++_generation;
    state = LinkState.connecting;
    _onChanged();
    _log('G2', 'Connecting both lenses for ${target.serialNumber}');

    _left
      ..deviceId = target.left!.id
      ..name = target.left!.name;
    _right
      ..deviceId = target.right!.id
      ..name = target.right!.name;

    try {
      await _ensureAndroidBond(_right, generation);
      await _ensureAndroidBond(_left, generation);
      // Establish the control-side right lens first. Some Android Bluetooth
      // stacks serialize simultaneous LE connection establishment and let
      // the second G2 attempt expire with status 133. Connecting the pair in
      // a deterministic order avoids that race; protocol initialization still
      // starts only after both lenses are configured.
      await _connectLens(_right, generation);
      await _connectLens(_left, generation);
      if (generation != _generation) {
        return;
      }
      await _initializeProtocol();
      state = LinkState.connected;
      _onChanged();
      _log('G2', 'Both lenses initialized; protocol session is ready');
      _startHeartbeats();
    } catch (error) {
      if (generation == _generation) {
        state = LinkState.error;
        _onChanged();
        _log('G2', 'Connection failed: $error', isError: true);
        _scheduleReconnect();
      }
      rethrow;
    }
  }

  Future<void> _connectLens(_Lens lens, int generation) async {
    final deviceId = lens.deviceId;
    if (deviceId == null) {
      throw StateError('${lens.label} lens has no BLE id');
    }
    final completer = Completer<void>();
    var configuring = false;
    final controlService = Uuid.parse(G2Ids.controlService);
    final audioService = Uuid.parse(G2Ids.audioService);

    lens.connectionSubscription = _ble
        .connectToDevice(
          id: deviceId,
          servicesWithCharacteristicsToDiscover: <Uuid, List<Uuid>>{
            controlService: <Uuid>[
              Uuid.parse(G2Ids.write),
              Uuid.parse(G2Ids.notify),
            ],
            audioService: <Uuid>[Uuid.parse(G2Ids.audioNotify)],
          },
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen(
          (update) {
            if (generation != _generation) {
              return;
            }
            _log('G2 ${lens.label}', update.connectionState.name);
            switch (update.connectionState) {
              case DeviceConnectionState.connected:
                if (!configuring) {
                  configuring = true;
                  unawaited(
                    _configureLens(lens)
                        .then((_) {
                          if (!completer.isCompleted) {
                            completer.complete();
                          }
                        })
                        .catchError((Object error, StackTrace stackTrace) {
                          if (!completer.isCompleted) {
                            completer.completeError(error, stackTrace);
                          }
                        }),
                  );
                }
              case DeviceConnectionState.disconnected:
                if (!completer.isCompleted) {
                  completer.completeError(
                    StateError('${lens.label} lens disconnected during setup'),
                  );
                } else if (!_manualDisconnect) {
                  _handleUnexpectedDisconnect(lens.label);
                }
              case DeviceConnectionState.connecting:
              case DeviceConnectionState.disconnecting:
                break;
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
            if (!_manualDisconnect) {
              _handleUnexpectedDisconnect(lens.label);
            }
          },
        );
    return completer.future;
  }

  Future<void> _ensureAndroidBond(_Lens lens, int generation) async {
    if (!Platform.isAndroid) {
      return;
    }
    final deviceId = lens.deviceId;
    if (deviceId == null) {
      throw StateError('${lens.label} lens has no BLE id');
    }

    const bondNone = 10;
    const bondBonding = 11;
    const bondBonded = 12;

    Future<int?> readBondState() async {
      return _bondChannel.invokeMethod<int>('bondState', <String, Object>{
        'address': deviceId,
      });
    }

    var bondState = await readBondState();
    if (bondState == bondBonded) {
      _log('G2 pairing', '${lens.label} lens Android LE bond is ready');
      return;
    }

    final requested =
        await _bondChannel.invokeMethod<bool>('createBond', <String, Object>{
          'address': deviceId,
        }) ??
        false;
    if (!requested && bondState != bondBonding) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      bondState = await readBondState();
      if (bondState == bondBonded) {
        _log('G2 pairing', '${lens.label} lens Android LE bond is ready');
        return;
      }
      if (bondState != bondBonding) {
        throw G2PairingException(lens.label);
      }
    }

    _log('G2 pairing', 'Confirm “Pair” for the ${lens.label} lens in Android');
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    var sawBonding = bondState == bondBonding;
    while (DateTime.now().isBefore(deadline)) {
      if (generation != _generation) {
        throw StateError('G2 pairing was cancelled');
      }
      bondState = await readBondState();
      if (bondState == bondBonded) {
        _log('G2 pairing', '${lens.label} lens Android LE bond established');
        return;
      }
      if (bondState == bondBonding) {
        sawBonding = true;
      } else if (bondState == bondNone && sawBonding) {
        throw G2PairingException(lens.label);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw G2PairingException(lens.label);
  }

  Future<void> _configureLens(_Lens lens) async {
    final deviceId = lens.deviceId!;
    try {
      final mtu = await _ble.requestMtu(deviceId: deviceId, mtu: 247);
      _log('G2 ${lens.label}', 'MTU $mtu');
    } catch (error) {
      _log('G2 ${lens.label}', 'MTU request unavailable: $error');
    }
    if (Platform.isAndroid) {
      try {
        await _ble.requestConnectionPriority(
          deviceId: deviceId,
          priority: ConnectionPriority.highPerformance,
        );
      } catch (error) {
        _log('G2 ${lens.label}', 'High-priority request failed: $error');
      }
    }

    lens.write = QualifiedCharacteristic(
      serviceId: Uuid.parse(G2Ids.controlService),
      characteristicId: Uuid.parse(G2Ids.write),
      deviceId: deviceId,
    );
    final notify = QualifiedCharacteristic(
      serviceId: Uuid.parse(G2Ids.controlService),
      characteristicId: Uuid.parse(G2Ids.notify),
      deviceId: deviceId,
    );
    final audio = QualifiedCharacteristic(
      serviceId: Uuid.parse(G2Ids.audioService),
      characteristicId: Uuid.parse(G2Ids.audioNotify),
      deviceId: deviceId,
    );

    lens.notifySubscription = _ble
        .subscribeToCharacteristic(notify)
        .listen(
          (value) => _handleProtocolNotification(
            Uint8List.fromList(value),
            lens.side == G2Side.left ? 'L' : 'R',
          ),
          onError: (Object error) {
            _log(
              'G2 ${lens.label}',
              'Protocol notification error: $error',
              isError: true,
            );
          },
        );
    lens.audioSubscription = _ble
        .subscribeToCharacteristic(audio)
        .listen(
          (value) => _handleAudio(Uint8List.fromList(value), lens.label),
          onError: (Object error) {
            _log(
              'G2 ${lens.label}',
              'Audio notification error: $error',
              isError: true,
            );
          },
        );

    // Give both CCCD subscriptions time to settle before protocol writes.
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  Future<void> _initializeProtocol() async {
    await _sendPayload(
      G2Ids.serviceDeviceSettings,
      _protocol.authentication(isIos: Platform.isIOS),
      left: true,
      right: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _sendPayload(
      G2Ids.serviceDeviceSettings,
      _protocol.authentication(isIos: Platform.isIOS),
      left: false,
      right: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _sendPayload(
      G2Ids.serviceDeviceSettings,
      _protocol.pipeRoleRight(),
      left: false,
      right: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _sendPayload(
      G2Ids.serviceDeviceSettings,
      _protocol.timeSync(DateTime.now()),
      left: true,
      right: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _sendPayload(
      G2Ids.serviceOnboarding,
      _protocol.skipOnboarding(),
      reserveFlag: true,
    );
    await _sendPayload(
      G2Ids.serviceGesture,
      _protocol.gestureInit(),
      reserveFlag: true,
    );
    await _sendPayload(
      G2Ids.serviceUiSettings,
      _protocol.uiSettingsQuery(),
      reserveFlag: true,
    );
    await _sendPayload(
      G2Ids.serviceDashboard,
      _protocol.dashboardInit(),
      reserveFlag: true,
      left: true,
      right: true,
    );
    await _sendPayload(
      G2Ids.serviceEvenAi,
      _protocol.disableHeyEven(),
      reserveFlag: true,
    );
    // The visualizer is a Daily/Hub surface. Terminal is intentionally kept
    // off because it is mutually exclusive with this page.
    await _setTerminalMode(
      false,
      advertiseHostConnected: false,
      initialization: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await _createPage('');
    await Future<void>.delayed(const Duration(milliseconds: 180));
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.audioControl(true),
      reserveFlag: true,
    );
    await _requestDeviceInfo();
    audioEnabled = true;
    hubHoldStatus =
        'Hub visualizer active: continuous LC3; ring gestures do not stop it';
    _log(
      'G2 audio',
      'Continuous LC3 stream requested automatically for Hub visualizer',
    );
    _onChanged();
  }

  Future<void> _createPage(String content) async {
    if (_memoDisplayActive) {
      await _createMemoPage();
      return;
    }
    if (_fullPageTextActive) {
      await _createFullPageText(content);
      return;
    }
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.createTextPage(''),
      reserveFlag: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.rebuildAudioVisualizerPage(gesture: content),
      reserveFlag: true,
    );
    _lastPageContent = content;
    _pageCreated = true;
    pageSessionStatus = 'audio visualizer page created';
    _onChanged();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    await _sendPulse(force: true);
  }

  Future<void> sendText(String content) async {
    _requireConnected();
    if (_memoDisplayActive || _fullPageTextActive) {
      _log(
        'G2 TX',
        'Text update suppressed while a private full-page view owns the display',
      );
      return;
    }
    _lastPageContent = content;
    if (!_pageCreated) {
      await _createPage(content);
    } else {
      await _sendPayload(
        G2Ids.serviceEvenHub,
        _protocol.updateText(content),
        reserveFlag: true,
        priority: AsyncWritePriority.high,
      );
    }
    _log(
      'G2 TX',
      'Text update sent (${content.runes.length} characters; content private)',
    );
  }

  Future<void> clearText() async {
    _requireConnected();
    if (_memoDisplayActive || _fullPageTextActive) {
      _log(
        'G2 TX',
        'Text clear suppressed while a private full-page view owns the display',
      );
      return;
    }
    if (!_pageCreated) {
      return;
    }
    // EvenHub text updates have no ACK. Send the clear twice so a single
    // dropped write cannot leave stale private text visible on-glass.
    for (var send = 0; send < 2; send++) {
      await _sendPayload(
        G2Ids.serviceEvenHub,
        _protocol.clearText(),
        reserveFlag: true,
        priority: AsyncWritePriority.high,
      );
    }
    _lastPageContent = '';
    _log('G2 TX', 'Text cleared');
  }

  Future<void> showFullPageText(
    String content, {
    bool showPageIndicator = false,
    int pageIndex = 0,
    int pageCount = 1,
    int borderWidth = G2Protocol.fullPageTextBorderWidth,
    int borderColor = G2Protocol.fullPageTextBorderColor,
    int paddingLength = G2Protocol.fullPageTextPaddingLength,
    bool allowPageReplacement = true,
    int? maximumTextRows,
  }) async {
    final nextFrame = G2PageRenderFrame.validate(
      content: content,
      showPageIndicator: showPageIndicator,
      pageIndex: pageIndex,
      pageCount: pageCount,
      borderWidth: borderWidth,
      borderColor: borderColor,
      paddingLength: paddingLength,
      maximumTextRows: maximumTextRows,
    );
    _requireConnected();
    if (_memoDisplayActive) {
      _log(
        'G2 TX',
        'Full-page text suppressed while the private memo page owns the display',
      );
      return;
    }
    final currentFrame = _fullPageTextActive
        ? G2PageRenderFrame.validate(
            content: _lastPageContent,
            showPageIndicator: _fullPageTextIndicatorActive,
            pageIndex: _fullPageTextPageIndex,
            pageCount: _fullPageTextPageCount,
            borderWidth: _fullPageTextBorderWidth,
            borderColor: _fullPageTextBorderColor,
            paddingLength: _fullPageTextPaddingLength,
          )
        : null;
    final renderAction = G2PageRenderSafety.decide(
      current: currentFrame,
      next: nextFrame,
      pageCreated: _pageCreated,
      allowPageReplacement: allowPageReplacement,
    );
    if (renderAction == G2PageRenderAction.skip) {
      _log(
        'G2 TX',
        'Duplicate full-page text render suppressed after safety check',
      );
      return;
    }
    // This controlled replacement makes any previously scheduled recovery
    // obsolete. Lifecycle events emitted by this rebuild may schedule a new
    // one, which is cancelled only after the replacement fully settles.
    _pageRestoreTimer?.cancel();
    _pageRestoreTimer = null;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _visibleGestureTimer?.cancel();
    _visibleGestureTimer = null;
    _visibleGesturePageLabel = null;
    _fullPageTextPageCount = nextFrame.pageCount;
    _fullPageTextPageIndex = nextFrame.pageIndex;
    _fullPageTextBorderWidth = nextFrame.borderWidth;
    _fullPageTextBorderColor = nextFrame.borderColor;
    _fullPageTextPaddingLength = nextFrame.paddingLength;
    _fullPageTextIndicatorActive = nextFrame.showPageIndicator;
    if (renderAction == G2PageRenderAction.deferReplacement) {
      // A gesture may arrive while firmware is transitioning the current page
      // out of the foreground. Replacing the page in that interval can wedge
      // the glasses or drop the G2 link. Retain only the validated newest
      // frame and let the settled page-recovery path recreate it.
      _fullPageTextActive = true;
      _lastPageContent = content;
      _pageCreated = false;
      if (keepPageActive && !_nativeMenuOpen) {
        _schedulePageRestore('deferred gesture page replacement');
      }
      _log(
        'G2 TX',
        'Full-page replacement deferred after safety check '
            '(${nextFrame.utf8Bytes} UTF-8 bytes)',
      );
      return;
    }
    _controlledPageRendersInFlight++;
    var completed = false;
    try {
      if (renderAction == G2PageRenderAction.replacePage) {
        _fullPageTextActive = true;
        await _createFullPageText(content);
        completed = _pageCreated;
      } else {
        // Detail pages are pre-paginated on the phone. Keep the page and its
        // event-capture/image containers stable, then upgrade only the bounded
        // text and thumb bitmap. Rebuilding here can race the firmware's page
        // lifecycle during a physical swipe and drop the G2 link.
        await _sendPayload(
          G2Ids.serviceEvenHub,
          _protocol.updateText(content),
          reserveFlag: true,
          priority: AsyncWritePriority.high,
        );
        _lastPageContent = content;
        if (await _sendFullPageTextIndicator(settleAfterRebuild: false)) {
          _finishControlledPageRebuild('full-page text upgraded');
          completed = true;
        }
      }
      _log(
        'G2 TX',
        'Full-page text sent (${content.runes.length} characters; content private; '
            'page_indicator=${_fullPageTextIndicatorActive ? '${_fullPageTextPageIndex + 1}/$_fullPageTextPageCount' : 'hidden'})',
      );
    } finally {
      _controlledPageRendersInFlight--;
      if (!completed &&
          _controlledPageRendersInFlight == 0 &&
          isConnected &&
          keepPageActive &&
          !_pageCreated &&
          !_nativeMenuOpen) {
        _schedulePageRestore('incomplete controlled full-page render');
      }
    }
  }

  Future<void> exitFullPageText() async {
    if (!_fullPageTextActive) {
      return;
    }
    _fullPageTextActive = false;
    _fullPageTextIndicatorActive = false;
    _fullPageTextPageIndex = 0;
    _fullPageTextPageCount = 1;
    _fullPageTextBorderWidth = G2Protocol.fullPageTextBorderWidth;
    _fullPageTextBorderColor = G2Protocol.fullPageTextBorderColor;
    _fullPageTextPaddingLength = G2Protocol.fullPageTextPaddingLength;
    _lastPageContent = '';
    if (!isConnected || terminalModeEnabled) {
      _pageCreated = false;
      return;
    }
    _pageCreated = false;
    await _createPage('');
    _log('G2 TX', 'Full-page text closed and audio visualizer restored');
  }

  Future<void> _createFullPageText(String content) async {
    if (!_pageCreated) {
      await _sendPayload(
        G2Ids.serviceEvenHub,
        _protocol.createTextPage(
          content,
          showPageIndicator: _fullPageTextIndicatorActive,
          pageIndex: _fullPageTextPageIndex,
          pageCount: _fullPageTextPageCount,
          borderWidth: _fullPageTextBorderWidth,
          borderColor: _fullPageTextBorderColor,
          paddingLength: _fullPageTextPaddingLength,
        ),
        reserveFlag: true,
        priority: AsyncWritePriority.high,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.rebuildTextPage(
        content,
        showPageIndicator: _fullPageTextIndicatorActive,
        pageIndex: _fullPageTextPageIndex,
        pageCount: _fullPageTextPageCount,
        borderWidth: _fullPageTextBorderWidth,
        borderColor: _fullPageTextBorderColor,
        paddingLength: _fullPageTextPaddingLength,
      ),
      reserveFlag: true,
      priority: AsyncWritePriority.high,
    );
    _lastPageContent = content;
    if (await _sendFullPageTextIndicator(settleAfterRebuild: true)) {
      _finishControlledPageRebuild('full-page text created');
    }
  }

  Future<bool> _sendFullPageTextIndicator({
    required bool settleAfterRebuild,
  }) async {
    if (!_fullPageTextIndicatorActive) {
      return isConnected && _fullPageTextActive;
    }
    final pageIndex = _fullPageTextPageIndex;
    final pageCount = _fullPageTextPageCount;
    // A full-page rebuild can emit abnormal_exit/system_exit while firmware
    // replaces its prior container. Give that transition a conservative settle
    // interval before uploading the separately validated thumb bitmap.
    if (settleAfterRebuild) {
      await Future<void>.delayed(_pageReplacementSettleInterval);
    }
    if (!isConnected ||
        !_fullPageTextActive ||
        !_fullPageTextIndicatorActive ||
        pageIndex != _fullPageTextPageIndex ||
        pageCount != _fullPageTextPageCount) {
      return false;
    }
    final geometry = G2Protocol.detailPageIndicatorGeometry(
      pageIndex: pageIndex,
      pageCount: pageCount,
    );
    final bitmap = G2Protocol.detailPageIndicatorBitmap(
      pageIndex: pageIndex,
      pageCount: pageCount,
    );
    final bitmapMetadata = G2Protocol.validateDetailPageIndicatorBitmap(bitmap);
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.updateDetailPageIndicatorImage(bitmap),
      reserveFlag: true,
      priority: AsyncWritePriority.high,
    );
    _log(
      'G2 TX',
      'Detail page thumb sent (${pageIndex + 1}/$pageCount; '
          'bitmap=${bitmapMetadata.wireSignature}; '
          'thumb_y=${geometry.y}; thumb_height=${geometry.height}; '
          'container_y=${G2Protocol.fullPageIndicatorY}; '
          'container_height=${G2Protocol.fullPageIndicatorHeight})',
    );
    return true;
  }

  void _finishControlledPageRebuild(String status) {
    // Lifecycle exits produced by our own page replacement may have scheduled
    // recovery while the write was in flight. The completed rebuild already
    // owns the foreground, so that recovery is stale and must not race a
    // second page/image sequence onto BLE.
    _pageRestoreTimer?.cancel();
    _pageRestoreTimer = null;
    _pageCreated = true;
    pageSessionStatus = status;
    _onChanged();
  }

  Future<void> showMemo({required String note, required String status}) async {
    _requireConnected();
    _fullPageTextActive = false;
    final wasActive = _memoDisplayActive;
    final wasAtLastPage =
        _memoDisplayPages.isEmpty ||
        _memoDisplayPageIndex >= _memoDisplayPages.length - 1;
    _memoDisplayNote = _boundedMemoText(note);
    _memoDisplayStatus = status.replaceAll(RegExp(r'\s+'), ' ').trim();
    _memoDisplayPages = G2Protocol.memoPageContents(
      _memoDisplayNote,
      status: _memoDisplayStatus,
    );
    if (!wasActive || wasAtLastPage) {
      _memoDisplayPageIndex = _memoDisplayPages.length - 1;
    } else {
      _memoDisplayPageIndex = _memoDisplayPageIndex.clamp(
        0,
        _memoDisplayPages.length - 1,
      );
    }
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _visibleGestureTimer?.cancel();
    _visibleGestureTimer = null;
    _visibleGesturePageLabel = null;
    if (!_memoDisplayActive || !_pageCreated) {
      _memoDisplayActive = true;
      await _createMemoPage();
    } else {
      await _sendPayload(
        G2Ids.serviceEvenHub,
        _protocol.updateText(_currentMemoPage),
        reserveFlag: true,
        priority: AsyncWritePriority.high,
      );
      _lastPageContent = _currentMemoPage;
    }
    _log(
      'G2 TX',
      'Memo page updated (${_memoDisplayNote.runes.length} private characters)',
    );
  }

  Future<void> exitMemo() async {
    if (!_memoDisplayActive) {
      return;
    }
    _memoDisplayActive = false;
    _memoDisplayNote = '';
    _memoDisplayStatus = '';
    _memoDisplayPages = const <String>[];
    _memoDisplayPageIndex = 0;
    _lastPageContent = '';
    if (!isConnected || terminalModeEnabled) {
      _pageCreated = false;
      return;
    }
    _pageCreated = false;
    await _createPage('');
    _log('G2 TX', 'Memo page closed and the audio visualizer was restored');
  }

  Future<void> _createMemoPage() async {
    _fullPageTextActive = false;
    if (!_pageCreated) {
      await _sendPayload(
        G2Ids.serviceEvenHub,
        _protocol.createTextPage(_currentMemoPage),
        reserveFlag: true,
        priority: AsyncWritePriority.high,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.rebuildTextPage(_currentMemoPage),
      reserveFlag: true,
      priority: AsyncWritePriority.high,
    );
    _lastPageContent = _currentMemoPage;
    _pageCreated = true;
    pageSessionStatus = 'memo page created';
    _onChanged();
  }

  static String _boundedMemoText(String value) {
    final normalized = value
        .replaceAll(
          RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'),
          '',
        )
        .trim();
    final runes = normalized.runes.toList(growable: false);
    if (runes.length <= G2Protocol.maximumMemoRunes) {
      return normalized;
    }
    return '${String.fromCharCodes(runes.take(G2Protocol.maximumMemoRunes - 1))}…';
  }

  String get _currentMemoPage => _memoDisplayPages.isEmpty
      ? G2Protocol.memoPageContent(_memoDisplayNote, status: _memoDisplayStatus)
      : _memoDisplayPages[_memoDisplayPageIndex];

  Future<bool> selectPreviousMemoPage() =>
      _selectMemoPage(_memoDisplayPageIndex - 1);

  Future<bool> selectNextMemoPage() =>
      _selectMemoPage(_memoDisplayPageIndex + 1);

  Future<bool> _selectMemoPage(int index) async {
    if (!_memoDisplayActive ||
        index < 0 ||
        index >= _memoDisplayPages.length ||
        index == _memoDisplayPageIndex) {
      return false;
    }
    _memoDisplayPageIndex = index;
    // Rebuild rather than update so the firmware does not retain the native
    // scroll offset produced by the swipe that selected this logical page.
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.rebuildTextPage(_currentMemoPage),
      reserveFlag: true,
      priority: AsyncWritePriority.high,
    );
    _lastPageContent = _currentMemoPage;
    _onChanged();
    _log(
      'G2 TX',
      'Memo display page ${index + 1}/${_memoDisplayPages.length} sent',
    );
    return true;
  }

  Future<void> sendTestDrawing() async {
    _requireConnected();
    _fullPageTextActive = false;
    final bitmap = G2Bitmap.testPattern();
    _lastPageContent = 'Flutter BLE POC\n64x64 G2 bitmap test';
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.rebuildPageWithImage(content: _lastPageContent),
      reserveFlag: true,
    );
    _pageCreated = true;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.updateImage(bitmap),
      reserveFlag: true,
    );
    _log('G2 drawing TX', 'img-10 • 64x64 • ${bitmap.length} byte 4-bit BMP');
  }

  /// Exercises the exact detail-thumb page and image sequence without opening
  /// private history or requiring a wearable gesture.
  Future<void> sendTestDetailThumb() async {
    _requireConnected();
    if (_memoDisplayActive) {
      throw StateError(
        'Finish the active Memo before testing the detail thumb.',
      );
    }
    const content =
        '[ Detail thumb test ]\n'
        'Synthetic display content\n'
        'No private history is used\n'
        '\n'
        '[ Test restores automatically ]';
    try {
      for (var pageIndex = 0; pageIndex < 3; pageIndex++) {
        await showFullPageText(
          content,
          showPageIndicator: true,
          pageIndex: pageIndex,
          pageCount: 3,
          borderWidth: G2Protocol.expandedTextBorderWidth,
          borderColor: G2Protocol.expandedTextBorderColor,
          paddingLength: G2Protocol.expandedTextPaddingLength,
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      await exitFullPageText();
    }
  }

  Future<void> setTerminalMode(bool enabled) {
    _requireConnected();
    if (hubVisualizerMode && enabled) {
      throw StateError(
        'Terminal mode is disabled while the continuous Hub visualizer is active.',
      );
    }
    return _setTerminalModeAndRefreshPage(enabled);
  }

  Future<void> _setTerminalModeAndRefreshPage(bool enabled) async {
    if (audioEnabled) {
      await _sendPayload(
        G2Ids.serviceEvenHub,
        _protocol.audioControl(false),
        reserveFlag: true,
      );
      audioEnabled = false;
    }
    _cancelInferredHoldAudio();
    await _setTerminalMode(
      enabled,
      advertiseHostConnected: enabled,
      initialization: false,
    );
    if (enabled) {
      hubHoldStatus =
          'Terminal mode: true hold start/stop is available; Hub page is not';
      _pageCreated = false;
      _onChanged();
      return;
    }

    hubHoldStatus =
        'Daily/Hub mode restored; hold is inferred from Menu takeover only';
    _pageCreated = false;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await _restorePage('return to Daily/Hub mode');
  }

  Future<void> _setTerminalMode(
    bool enabled, {
    required bool advertiseHostConnected,
    required bool initialization,
  }) async {
    terminalModeEnabled = enabled;
    terminalModeStatus =
        '${enabled ? 'MODE_TERMINAL' : 'MODE_DAILY'} requested';
    _onChanged();
    _log(
      'G2 Terminal TX',
      '${enabled ? 'MODE_TERMINAL (2)' : 'MODE_DAILY (1)'} via '
          'private service 0x30'
          '${initialization ? ' during initialization' : ''}',
    );
    await _sendPayload(
      G2Ids.serviceTerminal,
      _protocol.terminalModeSync(terminal: enabled),
      reserveFlag: true,
    );
    if (enabled && advertiseHostConnected) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      _log(
        'G2 Terminal TX',
        'TERMINAL_SESSION_LIST host=1 session=1 state=AGENT_AWAIT_USER',
      );
      await _sendPayload(
        G2Ids.serviceTerminal,
        _protocol.terminalSessionList(),
        reserveFlag: true,
      );
      terminalSessionStatus = 'session 1 advertised';
      _onChanged();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _log(
        'G2 Terminal TX',
        'PC_STATUS_CONNECTED (2) with an active mock host/session',
      );
      await _sendPayload(
        G2Ids.serviceTerminal,
        _protocol.terminalPcStatusSync(connected: true),
        reserveFlag: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _log('G2 Terminal TX', 'AGENT_RESET (4) for session 1');
      await _sendPayload(
        G2Ids.serviceTerminal,
        _protocol.terminalAgentStatus(state: 4),
        reserveFlag: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _log(
        'G2 Terminal TX',
        'AGENT_AWAIT_USER (2) for session 1; hold-to-talk should now route',
      );
      await _sendPayload(
        G2Ids.serviceTerminal,
        _protocol.terminalAgentStatus(state: 2),
        reserveFlag: true,
      );
      terminalSessionStatus = 'session 1 ready • AGENT_AWAIT_USER';
      _onChanged();
    } else if (!enabled) {
      terminalSessionStatus = 'disabled';
      _onChanged();
    }
  }

  void setKeepPageActive(bool enabled) {
    if (hubVisualizerMode && !enabled) {
      _log(
        'G2 page session',
        'Ignored page auto-restore disable request in Hub visualizer mode',
      );
      return;
    }
    keepPageActive = enabled;
    _onChanged();
    _log(
      'G2 page session',
      enabled
          ? 'Auto-restore enabled: the POC page will reopen after a '
                'foreground/system exit'
          : 'Auto-restore disabled: double-tap may leave the POC in the '
                'built-in G2 dashboard/menu',
    );
    if (enabled && isConnected && !_pageCreated) {
      _schedulePageRestore('auto-restore re-enabled');
    } else if (!enabled) {
      _pageRestoreTimer?.cancel();
      _pageRestoreTimer = null;
    }
  }

  void setCaptureLongPressForApp(bool enabled) {
    if (hubVisualizerMode && !enabled) {
      _log(
        'G2 input mode',
        'Ignored hold-inference disable request in Hub visualizer mode',
      );
      return;
    }
    captureLongPressForApp = enabled;
    _onChanged();
    _log(
      'G2 input mode',
      enabled
          ? 'Experimental Hub hold inference enabled: native Menu takeover '
                'evidence is reported as inferred_long_press and the POC '
                'attempts to reclaim its page'
          : 'Hub hold inference disabled: long press is left to the native '
                'G2 Menu',
    );
  }

  void setStartAudioOnInferredHold(bool enabled) {
    if (hubVisualizerMode) {
      _log(
        'G2 Hub hold',
        'Audio already runs continuously; inferred-hold audio control is disabled',
      );
      return;
    }
    startAudioOnInferredHold = enabled;
    if (!enabled && inferredHoldAudioActive) {
      unawaited(_stopInferredHoldAudio('inferred-hold audio option disabled'));
    } else if (!enabled) {
      _cancelInferredHoldAudio();
    }
    _onChanged();
    _log(
      'G2 Hub hold',
      enabled
          ? 'An inferred Hub hold will start LC3 for at most 30 seconds; '
                'single/double tap or the phone switch stops it'
          : 'Inferred holds will be logged without starting audio',
    );
  }

  void setDoubleTapTogglesHubAudio(bool enabled) {
    if (hubVisualizerMode) {
      _log(
        'G2 Hub input',
        'Double-tap audio control is disabled; continuous audio remains active',
      );
      return;
    }
    doubleTapTogglesHubAudio = enabled;
    _onChanged();
    _log(
      'G2 Hub input',
      enabled
          ? 'Double-tap will toggle Hub audio; this is the reliable '
                'non-firmware alternative to hold-to-talk'
          : 'Double-tap audio toggle disabled',
    );
  }

  Future<void> restorePageNow() async {
    _requireConnected();
    _pageRestoreTimer?.cancel();
    _pageRestoreTimer = null;
    _nativeMenuOpen = false;
    _awaitingNativeMenuOpenConfirm = false;
    _pageCreated = false;
    await _restorePage('manual request', dismissNativeForeground: true);
  }

  Future<void> connectRing(String ringMac, {String ringName = ''}) async {
    _requireConnected();
    final mac = _parseMac(ringMac);
    if (mac == null) {
      throw FormatException('Invalid R1 MAC address: $ringMac');
    }
    await _sendPayload(
      G2Ids.serviceDeviceSettings,
      _protocol.ringConnectInfo(
        connect: true,
        ringMac: mac,
        ringName: ringName,
      ),
    );
    _log('G2 Tri-Sync', 'RING_CONNECT_INFO sent for $ringMac');
  }

  Future<void> disconnectRing(String ringMac, {String ringName = ''}) async {
    _requireConnected();
    final mac = _parseMac(ringMac);
    if (mac == null) {
      throw FormatException('Invalid R1 MAC address: $ringMac');
    }
    await _sendPayload(
      G2Ids.serviceDeviceSettings,
      _protocol.ringConnectInfo(
        connect: false,
        ringMac: mac,
        ringName: ringName,
      ),
    );
    ringLinkStatus = 'release requested for direct phone connection';
    ringLinkStatusAt = DateTime.now();
    _onChanged();
    _log('G2 Tri-Sync', 'RING_DISCONNECT_INFO sent for $ringMac');
  }

  Future<void> setAudioEnabled(bool enabled) async {
    _requireConnected();
    if (hubVisualizerMode && !enabled) {
      _log(
        'G2 audio',
        'Ignored stop request: Hub visualizer keeps LC3 streaming continuously',
      );
      return;
    }
    _cancelInferredHoldAudio();
    if (enabled && !_pageCreated) {
      if (_memoDisplayActive) {
        await _createMemoPage();
      } else if (_fullPageTextActive) {
        await _createFullPageText(_lastPageContent);
      } else {
        await _createPage(_lastPageContent);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await _sendPayload(
      G2Ids.serviceEvenHub,
      _protocol.audioControl(enabled),
      reserveFlag: true,
    );
    audioEnabled = enabled;
    _onChanged();
    _log('G2 audio', enabled ? 'LC3 stream requested' : 'Stream stopped');
  }

  Future<void> sendRawPacket(
    Uint8List bytes, {
    G2Side side = G2Side.right,
  }) async {
    _requireConnected();
    await _writePackets(
      <Uint8List>[bytes],
      left: side == G2Side.left,
      right: side == G2Side.right,
    );
    _log('G2 raw TX', '${side.name}: ${hexOf(bytes)}');
  }

  Future<void> _sendPayload(
    int service,
    Uint8List payload, {
    bool reserveFlag = false,
    bool left = false,
    bool right = true,
    AsyncWritePriority priority = AsyncWritePriority.normal,
  }) {
    return _writePackets(
      _protocol.frame(service, payload, reserveFlag: reserveFlag),
      left: left,
      right: right,
      priority: priority,
    );
  }

  Future<void> _writePackets(
    List<Uint8List> packets, {
    required bool left,
    required bool right,
    AsyncWritePriority priority = AsyncWritePriority.normal,
  }) async {
    final writes = <Future<void>>[];
    if (left) {
      writes.add(_enqueueLensPackets(_left, packets, priority: priority));
    }
    if (right) {
      writes.add(_enqueueLensPackets(_right, packets, priority: priority));
    }
    await Future.wait(writes);
  }

  Future<void> _enqueueLensPackets(
    _Lens lens,
    List<Uint8List> packets, {
    required AsyncWritePriority priority,
  }) {
    final characteristic = lens.write;
    if (characteristic == null) {
      throw StateError('${lens.label} write characteristic is unavailable');
    }
    return lens.writeQueue.addBatch(
      <Future<void> Function()>[
        for (final packet in packets)
          () => _ble.writeCharacteristicWithoutResponse(
            characteristic,
            value: packet,
          ),
      ],
      priority: priority,
      interOperationDelay: const Duration(milliseconds: 8),
    );
  }

  void _handleProtocolNotification(Uint8List raw, String source) {
    final message = _receiveAssembler.add(raw, source);
    if (message == null) {
      _log('G2 $source RX', 'Fragment: ${hexOf(raw)}');
      return;
    }
    _log(
      'G2 $source RX',
      'service=0x${message.serviceId.toRadixString(16).padLeft(2, '0')} '
          'crc=${message.crcValid ? 'ok' : 'bad'} ${hexOf(message.payload)}',
      isError: !message.crcValid,
    );

    if (message.serviceId == G2Ids.serviceDeviceSettings) {
      final fields = ProtoReader(message.payload).readFields();
      final auth = fields[3];
      if (fields[1] == 4 && auth is Uint8List) {
        final authFields = ProtoReader(auth).readFields();
        _log('G2 auth', '$source secure=${authFields[1] == 1}');
      }
      if (fields[1] == 6) {
        final ringPayload = fields[5];
        final ringFields = ringPayload is Uint8List
            ? ProtoReader(ringPayload).readFields()
            : <int, Object>{};
        final connect = ringFields[1];
        final firmwareStatus = ringFields[4];
        final firmwareSummary = ringFields.isEmpty
            ? '$source: R1 status acknowledged with no state details'
            : '$source: connect=${connect ?? 'not reported'}, '
                  'firmwareStatus=${firmwareStatus ?? 'not reported'}';
        ringLinkStatus = lastR1ViaG2Event == null
            ? firmwareSummary
            : 'active: $lastR1ViaG2Event • latest $firmwareSummary';
        ringLinkStatusAt = DateTime.now();
        _onChanged();
        _log(
          'G2 Tri-Sync RX',
          '$firmwareSummary • outer=${_protoSummary(fields)}'
              '${ringFields.isEmpty ? ' • empty response is not treated as a disconnect' : ' • ring=${_protoSummary(ringFields)}'}',
        );
      }
    }

    if (message.serviceId == G2Ids.serviceG2Settings) {
      final battery = decodeG2BatteryStatus(message.payload);
      if (battery != null) {
        final changed =
            batteryLevel != battery.level ||
            (battery.charging != null && batteryCharging != battery.charging);
        batteryLevel = battery.level;
        batteryCharging = battery.charging ?? batteryCharging;
        _onChanged();
        if (changed) {
          _log(
            'G2 battery',
            '${battery.level}%'
                '${batteryCharging == true ? ' · charging' : ''}',
          );
        }
      }
    }

    if (message.serviceId == G2Ids.serviceGesture) {
      final fields = ProtoReader(message.payload).readFields();
      final nestedPayload = fields[3];
      final nested = nestedPayload is Uint8List
          ? ProtoReader(nestedPayload).readFields()
          : <int, Object>{};
      gestureControlPackets++;
      lastGestureControlSummary =
          '$source outer=${_protoSummary(fields)}'
          '${nested.isEmpty ? '' : ' nested3=${_protoSummary(nested)}'}';
      lastGestureControlAt = DateTime.now();
      _onChanged();
      _log(
        'G2 gesture_ctrl RX',
        '$lastGestureControlSummary • firmware lifecycle/control traffic; '
            'it is not a decoded R1 touch event',
      );
      if (_bytesEqual(
        message.payload,
        Uint8List.fromList(const <int>[0x08, 0x01, 0x1a, 0x00]),
      )) {
        _handleNativeMenuToggle(DateTime.now());
      }
    }

    if (message.serviceId == G2Ids.serviceTerminal) {
      _handleTerminalMessage(message.payload, source);
    }

    if (message.serviceId == G2Ids.serviceEvenHub) {
      final outer = ProtoReader(message.payload).readFields();
      final decodedEvent = decodeG2Gesture(message.payload);
      final receivedAt = DateTime.now();
      final recentR1Activity =
          _lastR1SourceActivityAt != null &&
          receivedAt.difference(_lastR1SourceActivityAt!).inMilliseconds < 1500;
      final event =
          decodedEvent != null &&
              decodedEvent.path == G2GesturePath.textEvent &&
              recentR1Activity
          ? decodedEvent.withSource(2)
          : decodedEvent;
      if (outer[1] == 2) {
        evenHubTouchPackets++;
        final eventPayload = outer[13];
        final eventFields = eventPayload is Uint8List
            ? ProtoReader(eventPayload).readFields()
            : <int, Object>{};
        final systemPayload = eventFields[3];
        final systemFields = systemPayload is Uint8List
            ? ProtoReader(systemPayload).readFields()
            : <int, Object>{};
        final textPayload = eventFields[2];
        final textFields = textPayload is Uint8List
            ? ProtoReader(textPayload).readFields()
            : <int, Object>{};
        lastTouchDiagnostic =
            '$source outer=${_protoSummary(outer)}'
            '${eventFields.isEmpty ? '' : ' deviceEvent=${_protoSummary(eventFields)}'}'
            '${systemFields.isEmpty ? '' : ' sysEvent=${_protoSummary(systemFields)}'}'
            '${textFields.isEmpty ? '' : ' textEvent=${_protoSummary(textFields)}'}';
        final defaultEncodedR1Tap =
            event?.isFromR1 == true &&
            event?.type == 0 &&
            event?.typeWasOmitted == true &&
            systemFields[2] == 2;
        final r1SourceActivity = event == null && systemFields[2] == 2;
        if (r1SourceActivity || defaultEncodedR1Tap) {
          if (r1SourceActivity) {
            r1ActivityPackets++;
          }
          _lastR1SourceActivityAt = receivedAt;
          lastR1ViaG2Event = defaultEncodedR1Tap
              ? 'single_tap received through G2'
              : 'R1 source activity received through G2';
          lastR1ViaG2EventAt = DateTime.now();
          ringLinkStatus = 'active: $lastR1ViaG2Event';
          ringLinkStatusAt = DateTime.now();
          _recognizeR1LongPressAfterExit(receivedAt);
        } else if (event == null) {
          unknownEvenHubTouchPackets++;
        }
        _onChanged();
        _log(
          r1SourceActivity ? 'R1 activity via G2' : 'G2 EvenHub input RX',
          '$lastTouchDiagnostic • '
          '${r1SourceActivity
              ? 'source=2 activity/state packet with no forwardable gesture '
                    'type (a firmware-consumed hold can look like this)'
              : event == null
              ? 'input envelope not yet decoded'
              : 'decoded ${event.name} via ${event.path.name}'
                    '${defaultEncodedR1Tap ? ' (protobuf default type=0)' : ''}'}',
          isError: event == null && !r1SourceActivity,
        );
      }
      if (event != null) {
        if (event.isFromR1 && !event.isLifecycle && !event.typeWasOmitted) {
          // A typed R1 event consumes the preceding source=2 activity marker.
          // Leaving it pending could make a later, unrelated page exit look
          // like a long press.
          _lastR1SourceActivityAt = null;
        }
        final eventSource = event.isFromR1
            ? 'R1 controller'
            : event.path == G2GesturePath.textEvent
            ? 'event-capture container; source omitted by firmware'
            : 'glasses source ${event.source ?? 'unknown'}';
        final signature = '${event.type}:${event.source}:${event.path.name}';
        final now = receivedAt;
        final duplicate =
            _lastGestureSignature == signature &&
            _lastGestureEventAt != null &&
            now.difference(_lastGestureEventAt!).inMilliseconds < 150;
        _lastGestureSignature = signature;
        _lastGestureEventAt = now;
        if (!duplicate) {
          var consumed = false;
          if (!event.isLifecycle) {
            try {
              consumed = _onGesture?.call(event) ?? false;
            } on Object catch (error) {
              _log(
                'G2 gesture',
                'Application gesture handler failed: $error',
                isError: true,
              );
            }
          }
          if (!event.isLifecycle && !consumed) {
            _setVisibleGesture(
              event.name,
              source: eventSource,
              receivedAt: now,
            );
            _lastTypedUserInputAt = now;
          }
          if (event.isFromR1) {
            lastR1ViaG2Event = '${event.name} received through G2 EvenHub';
            lastR1ViaG2EventAt = now;
            ringLinkStatus = 'active: $lastR1ViaG2Event';
            ringLinkStatusAt = now;
          }
          _onChanged();
          _log(
            event.isFromR1 ? 'R1 gesture via G2' : 'G2 gesture',
            '${event.name} • $eventSource • type=${event.type} • '
            'path=${event.path.name} • consumed=$consumed',
          );
          if (!event.isLifecycle && !consumed) {
            _showGestureOnVisualizer(event.type, receivedAt: now);
          }
          if (!consumed &&
              inferredHoldAudioActive &&
              !event.isLifecycle &&
              (event.type == 0 || event.type == 3)) {
            unawaited(
              _stopInferredHoldAudio(
                '${event.name} received after inferred hold',
              ),
            );
          } else if (!consumed &&
              doubleTapTogglesHubAudio &&
              !terminalModeEnabled &&
              event.type == 3) {
            unawaited(_toggleHubAudioFromDoubleTap(eventSource));
          }
        }
        _handlePageLifecycle(event);
      }
    }
  }

  void _showGestureOnVisualizer(int type, {required DateTime receivedAt}) {
    if (_memoDisplayActive || _fullPageTextActive) {
      return;
    }
    final label = switch (type) {
      0 => 'Tap',
      1 => 'Swipe up',
      2 => 'Swipe down',
      3 => 'Double tap',
      _ => null,
    };
    if (label == null) {
      return;
    }
    _lastPageContent = label;
    _visibleGesturePageLabel = label;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _schedulePulseUpdate();
    if (isConnected && _pageCreated && !terminalModeEnabled) {
      final stopwatch = Stopwatch()..start();
      unawaited(
        _sendPayload(
          G2Ids.serviceEvenHub,
          _protocol.updateText(label),
          reserveFlag: true,
          priority: AsyncWritePriority.high,
        ).then<void>(
          (_) {
            stopwatch.stop();
            lastGestureDisplayLatencyMs = DateTime.now()
                .difference(receivedAt)
                .inMilliseconds;
            _onChanged();
            _log(
              'G2 gesture display',
              '$label • priority write completed in '
                  '${stopwatch.elapsedMilliseconds} ms • '
                  '$lastGestureDisplayLatencyMs ms from RX',
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            stopwatch.stop();
            _log(
              'G2 gesture display',
              '$label failed after ${stopwatch.elapsedMilliseconds} ms: '
                  '$error',
              isError: true,
            );
          },
        ),
      );
    } else {
      _log('G2 gesture display', '$label • page unavailable');
    }
  }

  void _handleTerminalMessage(Uint8List payload, String source) {
    final fields = ProtoReader(payload).readFields();
    final command = fields[1] as int?;
    final receivedAt = DateTime.now();
    terminalPackets++;
    lastTerminalEventAt = receivedAt;

    switch (command) {
      case 0xa1:
        final statusPayload = fields[9];
        final status = statusPayload is Uint8List
            ? ProtoReader(statusPayload).readFields()
            : <int, Object>{};
        final mode = status[1] as int?;
        final error = status[2] as int? ?? 0;
        terminalModeEnabled = mode == 2;
        terminalModeStatus =
            '${_terminalModeName(mode)} • ${_terminalErrorName(error)}';
        lastTerminalEvent = 'status_reply $terminalModeStatus';
        break;
      case 0xa2:
        final voicePayload = fields[10];
        final voice = voicePayload is Uint8List
            ? ProtoReader(voicePayload).readFields()
            : <int, Object>{};
        final voiceCommand = voice[1] as int?;
        final name = _terminalVoiceCommandName(voiceCommand);
        lastTerminalEvent = 'voice_input $name';
        if (voiceCommand != null && voiceCommand != 0) {
          _setVisibleGesture(
            name,
            source: 'G2 Terminal service 0x30',
            receivedAt: receivedAt,
          );
          if (voiceCommand == 1) {
            lastR1ViaG2Event = 'long_press_start via Terminal';
            lastR1ViaG2EventAt = receivedAt;
            ringLinkStatus = 'active: $lastR1ViaG2Event';
            ringLinkStatusAt = receivedAt;
          }
        }
        break;
      case 0xf0:
        final responsePayload = fields[13];
        final response = responsePayload is Uint8List
            ? ProtoReader(responsePayload).readFields()
            : <int, Object>{};
        final error = response[1] as int? ?? 0;
        lastTerminalEvent = 'comm_resp ${_terminalErrorName(error)}';
        if (error != 0) {
          terminalModeStatus = lastTerminalEvent!;
        }
        break;
      case 1:
        final modePayload = fields[3];
        final mode = modePayload is Uint8List
            ? ProtoReader(modePayload).readFields()
            : <int, Object>{};
        lastTerminalEvent =
            'mode_sync ${_terminalModeName(mode[1] as int?)} '
            '${_terminalErrorName(mode[2] as int? ?? 0)}';
        break;
      case 2:
        final statusPayload = fields[4];
        final status = statusPayload is Uint8List
            ? ProtoReader(statusPayload).readFields()
            : <int, Object>{};
        lastTerminalEvent =
            'pc_status_sync ${_terminalPcStatusName(status[1] as int?)} '
            '${_terminalErrorName(status[2] as int? ?? 0)}';
        break;
      case 4:
        final statusPayload = fields[6];
        final status = statusPayload is Uint8List
            ? ProtoReader(statusPayload).readFields()
            : <int, Object>{};
        lastTerminalEvent =
            'agent_status ${_terminalAgentStateName(status[1] as int?)} '
            'session=${status[2] ?? 'missing'}';
        break;
      case 8:
        final sessionsPayload = fields[16];
        final sessions = sessionsPayload is Uint8List
            ? ProtoReader(sessionsPayload).readFields()
            : <int, Object>{};
        lastTerminalEvent =
            'session_list host=${sessions[1] ?? 'missing'} '
            'current=${sessions[2] ?? 'missing'}';
        terminalSessionStatus = lastTerminalEvent!;
        break;
      case 0xa7:
        final selectPayload = fields[20];
        final select = selectPayload is Uint8List
            ? ProtoReader(selectPayload).readFields()
            : <int, Object>{};
        final state = select[1] as int?;
        lastTerminalEvent =
            'session_select_notify ${_terminalSessionSelectStateName(state)}';
        terminalSessionStatus = lastTerminalEvent!;
        break;
      default:
        lastTerminalEvent =
            'command=${command == null ? 'missing' : '0x${command.toRadixString(16)}'}';
    }
    _onChanged();
    _log(
      'G2 Terminal RX',
      '$source $lastTerminalEvent • outer=${_protoSummary(fields)}',
      isError: command == null,
    );
  }

  String _terminalModeName(int? value) => switch (value) {
    1 => 'MODE_DAILY',
    2 => 'MODE_TERMINAL',
    0 => 'MODE_NONE',
    null => 'mode missing',
    _ => 'mode $value',
  };

  String _terminalPcStatusName(int? value) => switch (value) {
    1 => 'PC_STATUS_DISCONNECTED',
    2 => 'PC_STATUS_CONNECTED',
    3 => 'PC_STATUS_SETUP_PENDING',
    0 => 'PC_STATUS_NONE',
    null => 'pc status missing',
    _ => 'pc status $value',
  };

  String _terminalAgentStateName(int? value) => switch (value) {
    0 => 'AGENT_NONE',
    1 => 'AGENT_THINKING',
    2 => 'AGENT_AWAIT_USER',
    3 => 'AGENT_DONE',
    4 => 'AGENT_RESET',
    null => 'agent state missing',
    _ => 'agent state $value',
  };

  String _terminalSessionSelectStateName(int? value) => switch (value) {
    0 => 'SESSION_SELECT_CLOSED',
    1 => 'SESSION_SELECT_OPENED',
    2 => 'SESSION_SELECT_STATE_2 (newer firmware)',
    null => 'session-select state missing',
    _ => 'session-select state $value',
  };

  String _terminalErrorName(int value) => switch (value) {
    0 => 'TERMINAL_SUCCESS',
    1 => 'TERMINAL_ERR_FAIL',
    2 => 'TERMINAL_ERR_ASR_FAILED',
    _ => 'terminal error $value',
  };

  String _terminalVoiceCommandName(int? value) => switch (value) {
    1 => 'long_press_start',
    2 => 'long_press_stop_manual',
    3 => 'long_press_stop_timeout',
    4 => 'voice_confirm',
    5 => 'voice_cancel',
    0 => 'voice_cmd_none',
    null => 'voice command missing',
    _ => 'voice command $value',
  };

  void _handlePageLifecycle(G2GestureEvent event) {
    switch (event.type) {
      case 4:
        _pageCreated = true;
        _nativeMenuOpen = false;
        _awaitingNativeMenuOpenConfirm = false;
        _lastPageExitAt = null;
        _lastForegroundExitAt = null;
        pageSessionStatus = 'foreground_enter received';
        _pageRestoreTimer?.cancel();
        _pageRestoreTimer = null;
        _onChanged();
        break;
      case 5:
      case 6:
      case 7:
        _pulseTimer?.cancel();
        _pulseTimer = null;
        final receivedAt = DateTime.now();
        final foregroundExitAt = _lastForegroundExitAt;
        final isNativeMenuExitSequence =
            event.type == 7 &&
            foregroundExitAt != null &&
            receivedAt.difference(foregroundExitAt).abs() <
                const Duration(milliseconds: 1200);
        if (event.type == 5) {
          _lastForegroundExitAt = receivedAt;
        }
        _pageCreated = false;
        _lastPageExitAt = receivedAt;
        pageExitEvents++;
        pageSessionStatus = '${event.name} received';
        _onChanged();
        _log(
          'G2 page session',
          '${event.name}: the POC left the foreground and input routing may '
              'fall back to the built-in G2 dashboard/menu',
        );
        if (_controlledPageRendersInFlight > 0) {
          // Rebuilds can emit lifecycle exits while firmware replaces its
          // container. Do not misclassify that expected transition as a ring
          // hold or interleave an automatic rebuild with the bitmap upload.
          pageSessionStatus =
              '${event.name} received during controlled page replacement';
          _onChanged();
          _log(
            'G2 page session',
            'Deferring recovery until the validated page replacement finishes',
          );
        } else if (_hasRecentR1Activity(receivedAt)) {
          _recognizeR1MenuLongPress(receivedAt, event.name);
        } else if (isNativeMenuExitSequence) {
          _recognizeR1MenuLongPress(
            receivedAt,
            'foreground_exit → system_exit lifecycle sequence',
            r1SourceConfirmed: false,
          );
        } else if (captureLongPressForApp &&
            keepPageActive &&
            event.type == 5 &&
            !_nativeMenuOpen &&
            !_hasRecentTypedUserInput(receivedAt)) {
          // Current G2 firmware does not consistently follow FOREGROUND_EXIT
          // with SYSTEM_EXIT when its native menu/End feature layer wins.
          // Capture mode is an explicit app-lock mode, so answer every
          // untyped native foreground takeover instead of rebuilding behind
          // that layer.
          _recognizeR1MenuLongPress(
            receivedAt,
            'untyped foreground takeover',
            r1SourceConfirmed: false,
          );
        } else if (keepPageActive && !_nativeMenuOpen) {
          _schedulePageRestore(event.name);
        }
        break;
      default:
        break;
    }
  }

  bool _hasRecentR1Activity(DateTime now) {
    final activityAt = _lastR1SourceActivityAt;
    return activityAt != null &&
        now.difference(activityAt).abs() < const Duration(milliseconds: 2600);
  }

  bool _hasRecentTypedUserInput(DateTime now) {
    final inputAt = _lastTypedUserInputAt;
    return inputAt != null &&
        now.difference(inputAt).abs() < const Duration(milliseconds: 900);
  }

  void _recognizeR1LongPressAfterExit(DateTime receivedAt) {
    final exitAt = _lastPageExitAt;
    if (exitAt == null ||
        receivedAt.difference(exitAt).abs() >=
            const Duration(milliseconds: 2600)) {
      return;
    }
    _recognizeR1MenuLongPress(receivedAt, 'native menu transition');
  }

  void _recognizeR1MenuLongPress(
    DateTime receivedAt,
    String trigger, {
    bool r1SourceConfirmed = true,
  }) {
    final lastCaptured = _lastCapturedLongPressAt;
    if (_nativeMenuOpen ||
        (captureLongPressForApp &&
            lastCaptured != null &&
            receivedAt.difference(lastCaptured).abs() <
                const Duration(milliseconds: 1500))) {
      return;
    }
    _lastCapturedLongPressAt = receivedAt;
    _nativeMenuOpen = !captureLongPressForApp;
    _awaitingNativeMenuOpenConfirm = !captureLongPressForApp;
    _lastR1SourceActivityAt = null;
    _pageRestoreTimer?.cancel();
    _pageRestoreTimer = null;
    _setVisibleGesture(
      'inferred_long_press',
      source: r1SourceConfirmed
          ? 'R1 controller (inferred from native menu transition)'
          : 'controller source unavailable (native menu transition)',
      receivedAt: receivedAt,
    );
    _lastPageContent = 'Long press (inferred)';
    _visibleGesturePageLabel = _lastPageContent;
    if (r1SourceConfirmed) {
      lastR1ViaG2Event = 'long_press opened the native G2 menu';
      lastR1ViaG2EventAt = receivedAt;
      ringLinkStatus = 'active: $lastR1ViaG2Event';
      ringLinkStatusAt = receivedAt;
    }
    pageSessionStatus = captureLongPressForApp
        ? 'inferred hold detected; reclaiming EvenHub page'
        : 'native menu open after controller long_press'
              '${r1SourceConfirmed ? ' (R1 confirmed)' : ' (source unavailable)'}';
    _onChanged();
    _log(
      r1SourceConfirmed ? 'R1 gesture via G2' : 'G2 native input',
      'inferred_long_press • inferred from $trigger • '
      '${r1SourceConfirmed ? 'R1 source marker observed' : 'firmware omitted the controller source'} • '
      'the G2 firmware consumes hold locally and does not publish hold '
      'down/up to Hub apps • '
      '${captureLongPressForApp ? 'the POC will attempt to exit the native foreground layer and restore the Hub page' : 'auto-restore is paused so the Menu stays open'}',
    );
    if (captureLongPressForApp && keepPageActive) {
      hubHoldStatus =
          'Inferred hold detected; restoring visualizer with audio continuous';
      _onChanged();
      _schedulePageRestore(
        'captured controller long_press',
        dismissNativeForeground: true,
      );
    }
  }

  void _handleNativeMenuToggle(DateTime receivedAt) {
    if (!_nativeMenuOpen && _hasRecentR1Activity(receivedAt)) {
      _recognizeR1MenuLongPress(receivedAt, 'dashboard/menu toggle');
      _awaitingNativeMenuOpenConfirm = false;
      pageSessionStatus = 'native menu open confirmed';
      _onChanged();
      return;
    }
    if (!_nativeMenuOpen) {
      return;
    }
    if (_awaitingNativeMenuOpenConfirm) {
      _awaitingNativeMenuOpenConfirm = false;
      pageSessionStatus = 'native menu open confirmed';
      _onChanged();
      _log(
        'G2 native menu',
        'Open transition confirmed; leaving the native menu in the foreground',
      );
      return;
    }

    _nativeMenuOpen = false;
    pageSessionStatus = 'native menu close received';
    _onChanged();
    _log(
      'G2 native menu',
      'Close transition received; POC page recovery is allowed again',
    );
    if (keepPageActive && !_pageCreated) {
      _schedulePageRestore('native menu close');
    }
  }

  void _schedulePageRestore(
    String reason, {
    bool dismissNativeForeground = false,
    bool startAudioAfterRestore = false,
  }) {
    _pageRestoreTimer?.cancel();
    pageSessionStatus = 'waiting to restore after $reason';
    _onChanged();
    _pageRestoreTimer = Timer(const Duration(milliseconds: 700), () {
      _pageRestoreTimer = null;
      if (!isConnected || !keepPageActive || _pageCreated || _nativeMenuOpen) {
        return;
      }
      unawaited(
        _restorePage(
          reason,
          dismissNativeForeground: dismissNativeForeground,
          startAudioAfterRestore: startAudioAfterRestore,
        ),
      );
    });
  }

  Future<void> _restorePage(
    String reason, {
    bool dismissNativeForeground = false,
    bool startAudioAfterRestore = false,
  }) async {
    pageRestoreAttempts++;
    pageSessionStatus = 'restoring after $reason';
    _onChanged();
    _log(
      'G2 page session',
      'Restoring POC page and gesture routing after $reason '
          '(attempt $pageRestoreAttempts)',
    );
    try {
      if (dismissNativeForeground) {
        _log(
          'G2 page session',
          'Sending SHUTDOWN_PAGE exitMode=0 to dismiss the native '
              'End feature layer before page recreation',
        );
        await _sendPayload(
          G2Ids.serviceEvenHub,
          _protocol.shutdownPage(),
          reserveFlag: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await _sendPayload(
        G2Ids.serviceGesture,
        _protocol.gestureInit(),
        reserveFlag: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (_memoDisplayActive) {
        await _createMemoPage();
      } else if (_fullPageTextActive) {
        await _createFullPageText(_lastPageContent);
      } else {
        await _createPage(_lastPageContent);
      }
      final shouldStartAudio = audioEnabled || startAudioAfterRestore;
      if (shouldStartAudio) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await _sendPayload(
          G2Ids.serviceEvenHub,
          _protocol.audioControl(true),
          reserveFlag: true,
        );
      }
      if (startAudioAfterRestore && !audioEnabled) {
        audioEnabled = true;
        inferredHoldAudioActive = true;
        hubHoldStatus =
            'Inferred hold audio active; tap/double-tap or 30 s timeout stops';
        _inferredHoldAudioTimer?.cancel();
        _inferredHoldAudioTimer = Timer(const Duration(seconds: 30), () {
          _inferredHoldAudioTimer = null;
          unawaited(_stopInferredHoldAudio('30 second safety timeout'));
        });
        _log(
          'G2 Hub hold',
          'LC3 started after inferred hold; this is not a firmware hold-up '
              'event. It will stop on tap/double-tap or after 30 seconds.',
        );
      }
      pageSessionStatus = 'restored after $reason';
      _onChanged();
      _log('G2 page session', pageSessionStatus);
    } catch (error) {
      pageSessionStatus = 'restore failed: $error';
      _onChanged();
      _log('G2 page session', pageSessionStatus, isError: true);
    }
  }

  Future<void> _stopInferredHoldAudio(String reason) async {
    if (!inferredHoldAudioActive) {
      return;
    }
    _inferredHoldAudioTimer?.cancel();
    _inferredHoldAudioTimer = null;
    inferredHoldAudioActive = false;
    if (isConnected && audioEnabled) {
      try {
        await _sendPayload(
          G2Ids.serviceEvenHub,
          _protocol.audioControl(false),
          reserveFlag: true,
        );
      } catch (error) {
        _log(
          'G2 Hub hold',
          'Could not stop inferred audio: $error',
          isError: true,
        );
      }
    }
    audioEnabled = false;
    hubHoldStatus = 'Inferred hold audio stopped: $reason';
    _onChanged();
    _log('G2 Hub hold', hubHoldStatus);
  }

  Future<void> _toggleHubAudioFromDoubleTap(String source) async {
    if (!isConnected || terminalModeEnabled) {
      return;
    }
    final now = DateTime.now();
    final previousToggle = _lastHubAudioToggleAt;
    if (_hubAudioToggleInFlight ||
        (previousToggle != null &&
            now.difference(previousToggle) <
                const Duration(milliseconds: 800))) {
      _log(
        'G2 Hub input',
        'Ignored duplicate double-tap audio event within 800 ms',
      );
      return;
    }
    _hubAudioToggleInFlight = true;
    _lastHubAudioToggleAt = now;
    final enable = !audioEnabled;
    try {
      await setAudioEnabled(enable);
      hubHoldStatus =
          'Hub audio ${enable ? 'started' : 'stopped'} by double-tap ($source)';
      _onChanged();
      _log(
        'G2 Hub input',
        '$hubHoldStatus • reliable typed Hub event, not a long-press',
      );
    } catch (error) {
      hubHoldStatus = 'Double-tap audio toggle failed: $error';
      _onChanged();
      _log('G2 Hub input', hubHoldStatus, isError: true);
    } finally {
      _hubAudioToggleInFlight = false;
    }
  }

  void _cancelInferredHoldAudio() {
    _inferredHoldAudioTimer?.cancel();
    _inferredHoldAudioTimer = null;
    inferredHoldAudioActive = false;
  }

  void _setVisibleGesture(
    String gesture, {
    required String source,
    required DateTime receivedAt,
  }) {
    _visibleGestureTimer?.cancel();
    lastGesture = gesture;
    lastGestureSource = source;
    lastGestureAt = receivedAt;
    _visibleGesturePageLabel = null;
    _visibleGestureTimer = Timer(const Duration(seconds: 3), () {
      _visibleGestureTimer = null;
      final pageLabel = _visibleGesturePageLabel;
      _visibleGesturePageLabel = null;
      lastGesture = null;
      lastGestureSource = null;
      _onChanged();

      if (pageLabel == null || _lastPageContent != pageLabel) {
        return;
      }
      if (_memoDisplayActive) {
        return;
      }
      _lastPageContent = '';
      if (isConnected && _pageCreated && !terminalModeEnabled) {
        unawaited(_clearExpiredGesture(pageLabel));
      }
    });
  }

  Future<void> _clearExpiredGesture(String pageLabel) async {
    try {
      await clearText();
      _log('G2 gesture display', '$pageLabel cleared after 3 seconds');
    } catch (error) {
      _log(
        'G2 gesture display',
        'Could not clear expired event: $error',
        isError: true,
      );
    }
  }

  void _resetPulseState() {
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _lastAudioPacket = null;
    _activeAudioSource = null;
    _lastAudioSummaryAt = null;
    _lastAudioRecoveryAt = null;
    _audioRecoveryInFlight = false;
    _audioSummaryBytes = 0;
    _audioSummaryFrames = 0;
    _audioNoiseFloor = null;
    _audioAnalysisWorker.reset();
    audioPackets = 0;
    audioBytes = 0;
    audioFrames = 0;
    lastAudioAt = null;
    audioActivityLevel = 0;
    lastLc3GlobalGain = null;
    _lastPulseUpdateAt = null;
    _lastPulseSignature = null;
    _pulseUpdateInFlight = false;
    _pulseUpdatePending = false;
    pulseStatus = 'waiting for LC3 audio';
    pulseUpdates = 0;
    pulseUpdatesSkipped = 0;
    lastPulseWriteDurationMs = null;
    lastGestureDisplayLatencyMs = null;
  }

  String _protoSummary(Map<int, Object> fields) {
    if (fields.isEmpty) {
      return '{}';
    }
    return '{${fields.entries.map((entry) {
      final value = entry.value;
      if (value is Uint8List) {
        return '${entry.key}:bytes[${value.length}]='
            '${hexOf(value, maxBytes: value.length)}';
      }
      return '${entry.key}:$value';
    }).join(', ')}}';
  }

  void _handleAudio(Uint8List raw, String source) {
    // G2 microphone notifications use a two-byte transport envelope:
    // 0xF1, packet sequence, then exactly 200 bytes of LC3. G2 uses 40-byte
    // frames (10 ms at 16 kHz). Both lenses can publish the same microphone
    // stream, so pin the session to whichever lens supplies the first valid
    // packet instead of decoding duplicated audio at 2x real time.
    final payload = raw.length >= 202 && raw[0] == 0xf1
        ? Uint8List.sublistView(raw, 2, 202)
        : raw;
    final usable = (payload.length.clamp(0, 200) ~/ 40) * 40;
    if (usable == 0) {
      return;
    }
    _activeAudioSource ??= source;
    if (_activeAudioSource != source) {
      return;
    }
    final packet = Uint8List.fromList(payload.take(usable).toList());
    if (_lastAudioPacket != null && _bytesEqual(_lastAudioPacket!, packet)) {
      return;
    }
    _lastAudioPacket = packet;
    audioPackets++;
    audioBytes += packet.length;
    audioFrames += packet.length ~/ 40;
    lastAudioAt = DateTime.now();
    _onLc3Audio(packet);
    _audioAnalysisWorker.addPacket(packet);
    _schedulePulseUpdate();
    _logAudioSummary(source, packet);
  }

  void _logAudioSummary(String source, Uint8List packet) {
    final now = DateTime.now();
    _audioSummaryBytes += packet.length;
    _audioSummaryFrames += packet.length ~/ 40;
    final previous = _lastAudioSummaryAt;
    if (previous == null) {
      _lastAudioSummaryAt = now;
      _audioSummaryBytes = 0;
      _audioSummaryFrames = 0;
      _log('Audio', 'Streaming started • 16 kHz mono LC3 • source $source');
      return;
    }
    final elapsedMs = now.difference(previous).inMilliseconds;
    if (elapsedMs < 1000) {
      return;
    }
    final seconds = elapsedMs / 1000;
    final kilobitsPerSecond = (_audioSummaryBytes * 8 / 1000) / seconds;
    final framesPerSecond = _audioSummaryFrames / seconds;
    _log(
      'Audio',
      '${kilobitsPerSecond.toStringAsFixed(1)} kbit/s • '
          '${framesPerSecond.toStringAsFixed(0)} frames/s • '
          'level $audioActivityLevel/255 • gain ${lastLc3GlobalGain ?? '—'}',
    );
    _lastAudioSummaryAt = now;
    _audioSummaryBytes = 0;
    _audioSummaryFrames = 0;
  }

  void _handleAudioAnalysis(G2AudioAnalysisSnapshot snapshot) {
    lastLc3GlobalGain = snapshot.globalGain;
    audioActivityLevel = snapshot.activityLevel;
    _audioNoiseFloor = snapshot.noiseFloor;
    pulseStatus =
        'LC3 gain ${lastLc3GlobalGain ?? '—'} • '
        'silence ${_audioNoiseFloor?.toStringAsFixed(1) ?? '—'} • '
        'voice $audioActivityLevel/255 • $pulseUpdates pulse updates';
    _schedulePulseUpdate();
    _onAudioChanged();
  }

  void _schedulePulseUpdate() {
    if (!isConnected ||
        !audioEnabled ||
        !_pageCreated ||
        _memoDisplayActive ||
        _fullPageTextActive ||
        terminalModeEnabled ||
        _pulseTimer != null) {
      return;
    }
    final now = DateTime.now();
    final previous = _lastPulseUpdateAt;
    final elapsed = previous == null
        ? _pulseRefreshInterval
        : now.difference(previous);
    var delay = elapsed >= _pulseRefreshInterval
        ? Duration.zero
        : _pulseRefreshInterval - elapsed;
    final inputAt = _lastTypedUserInputAt;
    if (inputAt != null) {
      final inputElapsed = now.difference(inputAt);
      if (inputElapsed < _gestureDisplayHoldoff) {
        final inputDelay = _gestureDisplayHoldoff - inputElapsed;
        if (inputDelay > delay) {
          delay = inputDelay;
        }
      }
    }
    _pulseTimer = Timer(delay, () {
      _pulseTimer = null;
      unawaited(
        _sendPulse().catchError((Object error) {
          pulseStatus = 'pulse update failed: $error';
          _onChanged();
          _log('G2 pulse', '$error', isError: true);
        }),
      );
    });
  }

  Future<void> _sendPulse({bool force = false}) async {
    if ((!isConnected && !force) ||
        !_pageCreated ||
        _memoDisplayActive ||
        _fullPageTextActive ||
        terminalModeEnabled ||
        (!audioEnabled && !force)) {
      return;
    }
    if (_pulseUpdateInFlight) {
      _pulseUpdatePending = true;
      return;
    }
    _pulseUpdateInFlight = true;
    try {
      final streaming = audioEnabled && lastAudioAt != null;
      final signature = streaming
          ? G2Bitmap.audioActivityPulseState(audioActivityLevel) + 1
          : 0;
      if (!force && signature == _lastPulseSignature) {
        _lastPulseUpdateAt = DateTime.now();
        pulseUpdatesSkipped++;
        return;
      }
      final bitmap = G2Bitmap.audioActivityPulse(
        level: audioActivityLevel,
        streaming: streaming,
        width: G2Protocol.visualizerPulseWidth,
        height: G2Protocol.visualizerPulseHeight,
      );
      final stopwatch = Stopwatch()..start();
      await _sendPayload(
        G2Ids.serviceEvenHub,
        _protocol.updateImage(bitmap),
        reserveFlag: true,
        priority: AsyncWritePriority.low,
      );
      stopwatch.stop();
      _lastPulseUpdateAt = DateTime.now();
      _lastPulseSignature = signature;
      lastPulseWriteDurationMs = stopwatch.elapsedMilliseconds;
      pulseUpdates++;
      pulseStatus =
          'LC3 gain ${lastLc3GlobalGain ?? '—'} • '
          'silence ${_audioNoiseFloor?.toStringAsFixed(1) ?? '—'} • '
          'voice $audioActivityLevel/255 • $pulseUpdates pulse updates • '
          '${lastPulseWriteDurationMs}ms last write';
      _onChanged();
    } finally {
      _pulseUpdateInFlight = false;
      if (_pulseUpdatePending) {
        _pulseUpdatePending = false;
        _schedulePulseUpdate();
      }
    }
  }

  bool _bytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  void _startHeartbeats() {
    _stopHeartbeats();
    _batteryHeartbeatCount = 0;
    Timer(const Duration(seconds: 1), () {
      if (isConnected) {
        unawaited(_requestDeviceInfo(priority: AsyncWritePriority.low));
      }
    });
    _evenHubHeartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(
        _sendPayload(
          G2Ids.serviceEvenHub,
          _protocol.evenHubHeartbeat(),
          reserveFlag: true,
          left: true,
          right: true,
          priority: AsyncWritePriority.low,
        ).catchError((Object error) {
          _log('G2 heartbeat', '$error', isError: true);
        }),
      );
      _batteryHeartbeatCount++;
      if (_batteryHeartbeatCount % 5 == 0) {
        unawaited(_requestDeviceInfo(priority: AsyncWritePriority.low));
      }
    });
    _deviceHeartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(
        _sendPayload(
          G2Ids.serviceDeviceSettings,
          _protocol.deviceHeartbeat(),
          left: true,
          right: true,
          priority: AsyncWritePriority.low,
        ).catchError((Object error) {
          _log('G2 heartbeat', '$error', isError: true);
        }),
      );
    });
    _audioWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_recoverStalledAudio());
    });
  }

  void _stopHeartbeats() {
    _evenHubHeartbeat?.cancel();
    _deviceHeartbeat?.cancel();
    _audioWatchdog?.cancel();
    _evenHubHeartbeat = null;
    _deviceHeartbeat = null;
    _audioWatchdog = null;
    _audioRecoveryInFlight = false;
    _batteryHeartbeatCount = 0;
  }

  Future<void> _requestDeviceInfo({
    AsyncWritePriority priority = AsyncWritePriority.normal,
  }) {
    return _sendPayload(
      G2Ids.serviceG2Settings,
      _protocol.deviceInfoRequest(),
      reserveFlag: true,
      priority: priority,
    ).catchError((Object error) {
      _log('G2 battery', 'Status request failed: $error', isError: true);
    });
  }

  Future<void> _recoverStalledAudio() async {
    if (!isConnected ||
        !hubVisualizerMode ||
        !audioEnabled ||
        _audioRecoveryInFlight) {
      return;
    }
    final now = DateTime.now();
    final receivedAt = lastAudioAt;
    if (receivedAt != null &&
        now.difference(receivedAt) < const Duration(seconds: 3)) {
      return;
    }
    final attemptedAt = _lastAudioRecoveryAt;
    if (attemptedAt != null &&
        now.difference(attemptedAt) < const Duration(seconds: 5)) {
      return;
    }
    _lastAudioRecoveryAt = now;
    _audioRecoveryInFlight = true;
    try {
      _log(
        'G2 audio',
        'LC3 notifications stalled; re-requesting the Hub audio stream '
            'without restarting Bluetooth',
      );
      await _sendPayload(
        G2Ids.serviceEvenHub,
        _protocol.audioControl(true),
        reserveFlag: true,
        priority: AsyncWritePriority.high,
      );
    } catch (error) {
      _log('G2 audio', 'Audio recovery request failed: $error', isError: true);
    } finally {
      _audioRecoveryInFlight = false;
    }
  }

  void _handleUnexpectedDisconnect(String side) {
    if (_manualDisconnect) {
      return;
    }
    // Stop timers immediately. Otherwise they continue queuing writes against
    // characteristics that Android has already invalidated and can obscure
    // the first disconnect cause with repetitive heartbeat failures.
    _stopHeartbeats();
    _pageRestoreTimer?.cancel();
    _pageRestoreTimer = null;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _log('G2', '$side link dropped', isError: true);
    _onUnexpectedDisconnect(side);
    state = LinkState.reconnecting;
    _onChanged();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _target == null || _reconnectTimer != null) {
      return;
    }
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      _reconnectTimer = null;
      final target = _target;
      if (target != null && !_manualDisconnect) {
        unawaited(
          connect(target).catchError((Object _) {
            // connect() logs and schedules the next retry.
          }),
        );
      }
    });
  }

  void _requireConnected() {
    if (!isConnected) {
      throw StateError('Connect both G2 lenses first.');
    }
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pageRestoreTimer?.cancel();
    _pageRestoreTimer = null;
    _pulseTimer?.cancel();
    _pulseTimer = null;
    _visibleGestureTimer?.cancel();
    _visibleGestureTimer = null;
    _visibleGesturePageLabel = null;
    lastGesture = null;
    lastGestureSource = null;
    _cancelInferredHoldAudio();
    _stopHeartbeats();
    if (audioEnabled && _right.write != null) {
      try {
        await _sendPayload(
          G2Ids.serviceEvenHub,
          _protocol.audioControl(false),
          reserveFlag: true,
        );
      } catch (_) {
        // Best-effort shutdown while a link may already be gone.
      }
    }
    await _teardownLinks();
    audioEnabled = false;
    batteryLevel = null;
    batteryCharging = null;
    _resetPulseState();
    _pageCreated = false;
    _memoDisplayActive = false;
    _fullPageTextActive = false;
    _fullPageTextIndicatorActive = false;
    _fullPageTextPageIndex = 0;
    _fullPageTextPageCount = 1;
    _fullPageTextBorderWidth = G2Protocol.fullPageTextBorderWidth;
    _fullPageTextBorderColor = G2Protocol.fullPageTextBorderColor;
    _fullPageTextPaddingLength = G2Protocol.fullPageTextPaddingLength;
    _memoDisplayNote = '';
    _memoDisplayStatus = '';
    _memoDisplayPages = const <String>[];
    _memoDisplayPageIndex = 0;
    _nativeMenuOpen = false;
    _awaitingNativeMenuOpenConfirm = false;
    _lastR1SourceActivityAt = null;
    _lastPageExitAt = null;
    _lastTypedUserInputAt = null;
    _lastHubAudioToggleAt = null;
    _hubAudioToggleInFlight = false;
    pageSessionStatus = 'disconnected';
    state = LinkState.disconnected;
    _onChanged();
    _log('G2', 'Disconnected');
  }

  Future<void> _teardownLinks() async {
    await Future.wait(<Future<void>>[_left.cancel(), _right.cancel()]);
  }

  Future<void> dispose() async {
    await disconnect();
    await _audioAnalysisWorker.dispose();
    _target = null;
  }

  Uint8List? _parseMac(String value) {
    final compact = value.replaceAll(':', '').replaceAll('-', '');
    if (!RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(compact)) {
      return null;
    }
    return Uint8List.fromList(<int>[
      for (var offset = 0; offset < 12; offset += 2)
        int.parse(compact.substring(offset, offset + 2), radix: 16),
    ]);
  }
}

final class _Lens {
  _Lens(this.side);

  final G2Side side;
  final AsyncWriteQueue writeQueue = AsyncWriteQueue();
  String? deviceId;
  String? name;
  QualifiedCharacteristic? write;
  StreamSubscription<ConnectionStateUpdate>? connectionSubscription;
  StreamSubscription<List<int>>? notifySubscription;
  StreamSubscription<List<int>>? audioSubscription;

  String get label => side == G2Side.left ? 'LEFT' : 'RIGHT';

  Future<void> cancel() async {
    final subscriptions = <StreamSubscription<dynamic>?>[
      notifySubscription,
      audioSubscription,
      connectionSubscription,
    ];
    notifySubscription = null;
    audioSubscription = null;
    connectionSubscription = null;
    for (final subscription in subscriptions) {
      await subscription?.cancel();
    }
    write = null;
  }
}
