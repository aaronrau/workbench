import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'voice_websocket_config.dart';

enum VoiceWebSocketStatus {
  unconfigured,
  disconnected,
  connecting,
  ready,
  error,
}

enum VoiceWebSocketSummaryRequestOutcome { sent, noSentAgent, unavailable }

enum VoiceWebSocketInboundKind { message, progress, completed, summary }

enum VoiceWebSocketDeliveryMode { queued, immediate }

typedef VoiceWebSocketConnector =
    Future<WebSocket> Function(Uri uri, Map<String, Object> headers);

typedef VoiceWebSocketInboundMessage = Future<void> Function(String message);
typedef VoiceWebSocketInboundEventHandler =
    Future<void> Function(VoiceWebSocketInboundEvent event);

final class VoiceWebSocketInboundEvent {
  const VoiceWebSocketInboundEvent({
    required this.message,
    required this.kind,
    this.agent,
    this.requestId,
  });

  final String message;
  final VoiceWebSocketInboundKind kind;
  final String? agent;
  final String? requestId;
}

final class VoiceWebSocketSendResult {
  const VoiceWebSocketSendResult({
    required this.sent,
    required this.agent,
    required this.message,
    required this.legacy,
    this.requestId,
  });

  final bool sent;
  final String agent;
  final String message;
  final bool legacy;
  final String? requestId;
}

final class VoiceWebSocketSummaryRequestResult {
  const VoiceWebSocketSummaryRequestResult({
    required this.outcome,
    required this.agent,
    required this.legacy,
    this.requestId,
  });

  final VoiceWebSocketSummaryRequestOutcome outcome;
  final String? agent;
  final bool legacy;
  final String? requestId;
}

final class AgentTranscriptRoute {
  const AgentTranscriptRoute({required this.agent, required this.message});

  final String agent;
  final String message;
}

final class VoiceWebSocketClient extends ChangeNotifier {
  VoiceWebSocketClient({
    VoiceWebSocketConfigStore? configStore,
    VoiceWebSocketConnector connector = _connect,
    VoiceWebSocketInboundMessage? onInboundMessage,
    VoiceWebSocketInboundEventHandler? onInboundEvent,
    Duration readyTimeout = const Duration(seconds: 10),
    Duration acknowledgementTimeout = const Duration(seconds: 10),
    List<Duration> reconnectDelays = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
    ],
    int maximumQueuedMessages = 32,
    Duration maximumBusyQueueAge = const Duration(minutes: 5),
    List<Duration> busyRetryDelays = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ],
  }) : _configStore = configStore ?? VoiceWebSocketConfigStore(),
       _connector = connector,
       _onInboundMessage = onInboundMessage,
       _onInboundEvent = onInboundEvent,
       _readyTimeout = readyTimeout,
       _acknowledgementTimeout = acknowledgementTimeout,
       _reconnectDelays = reconnectDelays,
       _maximumQueuedMessages = maximumQueuedMessages,
       _maximumBusyQueueAge = maximumBusyQueueAge,
       _busyRetryDelays = busyRetryDelays;

  final VoiceWebSocketConfigStore _configStore;
  final VoiceWebSocketConnector _connector;
  final VoiceWebSocketInboundMessage? _onInboundMessage;
  final VoiceWebSocketInboundEventHandler? _onInboundEvent;
  final Duration _readyTimeout;
  final Duration _acknowledgementTimeout;
  final List<Duration> _reconnectDelays;
  final int _maximumQueuedMessages;
  final Duration _maximumBusyQueueAge;
  final List<Duration> _busyRetryDelays;
  final Random _random = Random.secure();
  final Map<String, _PendingAcknowledgement> _pending =
      <String, _PendingAcknowledgement>{};
  final Queue<_QueuedAgentMessage> _outboundQueue =
      Queue<_QueuedAgentMessage>();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _readyTimer;
  Timer? _reconnectTimer;
  Timer? _outboundRetryTimer;
  Completer<void>? _readyCompleter;
  bool _initialized = false;
  bool _disposed = false;
  bool _manualDisconnect = false;
  bool _everReady = false;
  int _generation = 0;
  int _reconnectAttempt = 0;
  int? _lastEventId;
  String? _lastSentAgent;
  Future<void> _inboundTail = Future<void>.value();
  bool _pumpingOutboundQueue = false;
  bool _outboundPumpRequested = false;

  VoiceWebSocketStatus status = VoiceWebSocketStatus.unconfigured;
  String statusText = 'Not configured';
  List<String> serverAgents = const <String>[];
  List<String> agentControls = const <String>[];
  List<String> sessionControls = const <String>[];

  VoiceWebSocketConfig get config => _configStore.config;
  String? get validationError => _configStore.validationError;

  bool get isReady => status == VoiceWebSocketStatus.ready;

  int get queuedMessageCount => _outboundQueue.length;

  String? get lastSentAgent => _lastSentAgent;

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    _configStore.addListener(_configChanged);
    await _configStore.initialize();
    if (!config.isConfigured) {
      _setStatus(VoiceWebSocketStatus.unconfigured, 'Not configured');
      return;
    }
    _setStatus(VoiceWebSocketStatus.disconnected, 'Saved · disconnected');
    unawaited(_connectIgnoringErrors());
  }

  Future<void> saveConfig(VoiceWebSocketConfig value) async {
    _requireInitialized();
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _cancelOutboundQueue();
    await _closeSocket(reconnect: false);
    await _configStore.save(value);
    _manualDisconnect = false;
    _reconnectAttempt = 0;
    _everReady = false;
    _lastEventId = null;
    _lastSentAgent = null;
    serverAgents = const <String>[];
    agentControls = const <String>[];
    sessionControls = const <String>[];
    _setStatus(VoiceWebSocketStatus.disconnected, 'Saved · disconnected');
    unawaited(_connectIgnoringErrors());
  }

  Future<void> connect() async {
    _requireInitialized();
    if (!config.isConfigured) {
      throw StateError('Save a valid connection before connecting.');
    }
    if (_disposed) {
      throw StateError('The WebSocket client is closed.');
    }
    if (isReady) {
      return;
    }
    final waiting = _readyCompleter;
    if (status == VoiceWebSocketStatus.connecting &&
        waiting != null &&
        !waiting.isCompleted) {
      return waiting.future;
    }

    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _generation++;
    final generation = _generation;
    final ready = Completer<void>();
    _readyCompleter = ready;
    _setStatus(VoiceWebSocketStatus.connecting, 'Connecting…');

    try {
      final socket = await _connector(config.uri, config.upgradeHeaders);
      if (_disposed || generation != _generation) {
        await socket.close();
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('The WebSocket connection was replaced.'),
          );
        }
        return ready.future;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 20);
      _subscription = socket.listen(
        (data) {
          _inboundTail = _inboundTail
              .then((_) => _handleSocketData(data, generation))
              .catchError((_) {
                // Delivery failures publish a generic status and reconnect
                // without exposing private message content.
              });
        },
        onDone: () => _handleSocketClosed(generation),
        onError: (_) => _handleSocketClosed(generation),
        cancelOnError: true,
      );
      _readyTimer = Timer(_readyTimeout, () {
        if (generation != _generation || isReady) {
          return;
        }
        _setStatus(VoiceWebSocketStatus.error, 'Server did not become ready');
        if (!ready.isCompleted) {
          ready.completeError(
            TimeoutException(
              'The WebSocket server did not send connection.ready.',
            ),
          );
        }
        unawaited(_closeSocket(reconnect: true));
      });
    } on Object {
      if (generation == _generation && !_disposed) {
        _setStatus(
          VoiceWebSocketStatus.error,
          'Could not connect · check address, port, and server',
        );
        _scheduleReconnect();
      }
      if (!ready.isCompleted) {
        ready.completeError(
          StateError('The WebSocket server could not be reached.'),
        );
      }
    }
    return ready.future;
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _cancelOutboundQueue();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocket(reconnect: false);
    if (!_disposed) {
      _setStatus(
        config.isConfigured
            ? VoiceWebSocketStatus.disconnected
            : VoiceWebSocketStatus.unconfigured,
        config.isConfigured ? 'Saved · disconnected' : 'Not configured',
      );
    }
  }

  AgentTranscriptRoute? routeForTranscript(
    String transcript, {
    String? evidenceTranscript,
  }) {
    final text = transcript.trim();
    if (text.isEmpty) {
      return null;
    }
    _AgentMatch? selected;
    for (final agent in config.agentNames) {
      final match = RegExp(
        '(^|[^A-Za-z0-9_])(${RegExp.escape(agent)})(?=\$|[^A-Za-z0-9_])',
        caseSensitive: false,
      ).firstMatch(text);
      if (match == null) {
        continue;
      }
      if (evidenceTranscript != null &&
          !_hasLeadingAttentionEvidence(evidenceTranscript)) {
        continue;
      }
      final nameStart = match.start + (match.group(1)?.length ?? 0);
      final candidate = _AgentMatch(
        agent: agent,
        start: nameStart,
        end: match.end,
      );
      if (selected == null ||
          candidate.start < selected.start ||
          candidate.start == selected.start &&
              candidate.agent.length > selected.agent.length) {
        selected = candidate;
      }
    }
    if (selected == null) {
      return null;
    }

    var message = text;
    if (selected.start == 0) {
      message = text
          .substring(selected.end)
          .replaceFirst(RegExp(r'^[\s,:;.!?\-–—]+'), '')
          .trim();
      if (message.isEmpty) {
        message = text;
      }
    }
    return AgentTranscriptRoute(agent: selected.agent, message: message);
  }

  /// Routes speech directly to an explicitly selected configured agent.
  ///
  /// The G2 selector supplies the user intent, so spoken attention and agent
  /// matching are deliberately unnecessary. The selection is canonicalized
  /// against the current configuration so a stale row cannot send a command.
  AgentTranscriptRoute? routeTranscriptToSelectedAgent({
    required String selectedAgent,
    required String transcript,
  }) {
    final message = transcript.trim();
    if (message.isEmpty) {
      return null;
    }
    final selectedKey = selectedAgent.trim().toLowerCase();
    String? canonicalAgent;
    for (final agent in config.agentNames) {
      if (agent.toLowerCase() == selectedKey) {
        canonicalAgent = agent;
        break;
      }
    }
    if (canonicalAgent == null) {
      return null;
    }
    return AgentTranscriptRoute(agent: canonicalAgent, message: message);
  }

  static bool _hasLeadingAttentionEvidence(String rawTranscript) => RegExp(
    r'^\s*hey(?=$|[^A-Za-z0-9_])',
    caseSensitive: false,
  ).hasMatch(rawTranscript);

  Future<bool> sendTranscript(String transcript) async {
    final route = routeForTranscript(transcript);
    if (route == null) {
      return false;
    }
    return sendAgentMessage(agent: route.agent, message: route.message);
  }

  Future<bool> sendAgentMessage({
    required String agent,
    required String message,
  }) async =>
      (await sendAgentMessageWithResult(agent: agent, message: message)).sent;

  Future<VoiceWebSocketSendResult> sendAgentMessageWithResult({
    required String agent,
    required String message,
    VoiceWebSocketDeliveryMode deliveryMode = VoiceWebSocketDeliveryMode.queued,
  }) async {
    final canonicalAgent = config.agentNames.firstWhere(
      (name) => name.toLowerCase() == agent.trim().toLowerCase(),
      orElse: () => '',
    );
    final trimmedMessage = message.trim();
    if (canonicalAgent.isEmpty || trimmedMessage.isEmpty) {
      return VoiceWebSocketSendResult(
        sent: false,
        agent: canonicalAgent,
        message: trimmedMessage,
        legacy: config.useLegacyMessageShape,
      );
    }

    if (!config.useLegacyMessageShape) {
      if (deliveryMode == VoiceWebSocketDeliveryMode.immediate) {
        return _sendImmediateModernAgentMessage(
          agent: canonicalAgent,
          message: trimmedMessage,
        );
      }
      if (_disposed ||
          _maximumQueuedMessages <= 0 ||
          _outboundQueue.length >= _maximumQueuedMessages) {
        return VoiceWebSocketSendResult(
          sent: false,
          agent: canonicalAgent,
          message: trimmedMessage,
          legacy: false,
        );
      }
      final queued = _QueuedAgentMessage(
        agent: canonicalAgent,
        message: trimmedMessage,
        enqueuedAt: DateTime.now(),
      );
      _outboundQueue.addLast(queued);
      _publishQueueStatus();
      _requestOutboundPump();
      return queued.completer.future;
    }

    try {
      await connect();
    } on Object {
      return VoiceWebSocketSendResult(
        sent: false,
        agent: canonicalAgent,
        message: trimmedMessage,
        legacy: true,
      );
    }
    final socket = _socket;
    if (socket == null || !isReady) {
      return VoiceWebSocketSendResult(
        sent: false,
        agent: canonicalAgent,
        message: trimmedMessage,
        legacy: true,
      );
    }

    try {
      socket.add(
        jsonEncode(<String, Object>{
          'agent': canonicalAgent,
          'message': trimmedMessage,
        }),
      );
      _lastSentAgent = canonicalAgent;
      return VoiceWebSocketSendResult(
        sent: true,
        agent: canonicalAgent,
        message: trimmedMessage,
        legacy: true,
      );
    } on Object {
      return VoiceWebSocketSendResult(
        sent: false,
        agent: canonicalAgent,
        message: trimmedMessage,
        legacy: true,
      );
    }
  }

  Future<VoiceWebSocketSendResult> _sendImmediateModernAgentMessage({
    required String agent,
    required String message,
  }) async {
    if (_disposed) {
      return VoiceWebSocketSendResult(
        sent: false,
        agent: agent,
        message: message,
        legacy: false,
      );
    }
    final attempt = await _sendModernAgentMessage(
      _QueuedAgentMessage(
        agent: agent,
        message: message,
        enqueuedAt: DateTime.now(),
      ),
      maximumAttempts: 1,
    );
    final sent = attempt.outcome == _AcknowledgementOutcome.accepted;
    if (sent) {
      _lastSentAgent = agent;
    }
    return VoiceWebSocketSendResult(
      sent: sent,
      agent: agent,
      message: message,
      legacy: false,
      requestId: sent ? attempt.requestId : null,
    );
  }

  Future<VoiceWebSocketSummaryRequestOutcome>
  requestLastSentAgentSummary() async {
    final agent = _lastSentAgent;
    if (agent == null) {
      return VoiceWebSocketSummaryRequestOutcome.noSentAgent;
    }
    return (await requestAgentSummary(agent)).outcome;
  }

  Future<VoiceWebSocketSummaryRequestResult> requestAgentSummary(
    String agent,
  ) async {
    final canonicalAgent = config.agentNames.firstWhere(
      (name) => name.toLowerCase() == agent.trim().toLowerCase(),
      orElse: () => '',
    );
    if (canonicalAgent.isEmpty) {
      return VoiceWebSocketSummaryRequestResult(
        outcome: VoiceWebSocketSummaryRequestOutcome.noSentAgent,
        agent: null,
        legacy: config.useLegacyMessageShape,
      );
    }
    try {
      await connect();
    } on Object {
      return VoiceWebSocketSummaryRequestResult(
        outcome: VoiceWebSocketSummaryRequestOutcome.unavailable,
        agent: canonicalAgent,
        legacy: config.useLegacyMessageShape,
      );
    }
    final socket = _socket;
    if (socket == null ||
        socket.readyState != WebSocket.open ||
        !isReady ||
        _disposed) {
      return VoiceWebSocketSummaryRequestResult(
        outcome: VoiceWebSocketSummaryRequestOutcome.unavailable,
        agent: canonicalAgent,
        legacy: config.useLegacyMessageShape,
      );
    }

    final requestId = config.useLegacyMessageShape ? null : _newRequestId();
    try {
      socket.add(
        jsonEncode(
          config.useLegacyMessageShape
              ? <String, Object>{
                  'type': 'local',
                  'agent': canonicalAgent,
                  'message': 'progress_summary',
                }
              : <String, Object>{
                  'type': 'summary.request',
                  'request_id': requestId!,
                  'agent': canonicalAgent,
                },
        ),
      );
      return VoiceWebSocketSummaryRequestResult(
        outcome: VoiceWebSocketSummaryRequestOutcome.sent,
        agent: canonicalAgent,
        legacy: config.useLegacyMessageShape,
        requestId: requestId,
      );
    } on Object {
      return VoiceWebSocketSummaryRequestResult(
        outcome: VoiceWebSocketSummaryRequestOutcome.unavailable,
        agent: canonicalAgent,
        legacy: config.useLegacyMessageShape,
      );
    }
  }

  Future<_ModernSendAttempt> _sendModernAgentMessage(
    _QueuedAgentMessage queued, {
    int maximumAttempts = 2,
  }) async {
    final requestId = queued.requestId ??= _newRequestId();
    var reconnectBeforeAttempt = false;
    for (var attempt = 0; attempt < maximumAttempts; attempt++) {
      if (reconnectBeforeAttempt ||
          _socket == null ||
          _socket!.readyState != WebSocket.open ||
          !isReady) {
        if (_socket != null) {
          await _closeSocket(reconnect: false);
        }
        try {
          await connect();
        } on Object {
          return _ModernSendAttempt(
            outcome: _AcknowledgementOutcome.connectionLost,
            requestId: requestId,
          );
        }
      }

      final activeSocket = _socket;
      if (activeSocket == null ||
          activeSocket.readyState != WebSocket.open ||
          !isReady) {
        continue;
      }
      final completer = Completer<_AcknowledgementOutcome>();
      final timer = Timer(_acknowledgementTimeout, () {
        final pending = _pending.remove(requestId);
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(_AcknowledgementOutcome.timedOut);
        }
      });
      _pending[requestId] = _PendingAcknowledgement(
        completer: completer,
        timer: timer,
      );
      try {
        activeSocket.add(
          jsonEncode(<String, Object>{
            'type': 'message.send',
            'request_id': requestId,
            'agent': queued.agent,
            'message': queued.message,
          }),
        );
      } on Object {
        final pending = _pending.remove(requestId);
        pending?.timer.cancel();
        if (!(pending?.completer.isCompleted ?? true)) {
          pending!.completer.complete(_AcknowledgementOutcome.connectionLost);
        }
      }
      final outcome = await completer.future;
      if (outcome == _AcknowledgementOutcome.accepted ||
          outcome == _AcknowledgementOutcome.rejected ||
          outcome == _AcknowledgementOutcome.agentBusy) {
        return _ModernSendAttempt(outcome: outcome, requestId: requestId);
      }
      reconnectBeforeAttempt =
          outcome == _AcknowledgementOutcome.connectionLost;
    }
    return _ModernSendAttempt(
      outcome: _AcknowledgementOutcome.timedOut,
      requestId: requestId,
    );
  }

  Future<void> _pumpOutboundQueue() async {
    if (_pumpingOutboundQueue || _outboundRetryTimer != null || _disposed) {
      return;
    }
    _pumpingOutboundQueue = true;
    try {
      while (_outboundQueue.isNotEmpty && !_disposed) {
        final queued = _outboundQueue.first;
        if (_queueAgeExpired(queued)) {
          _completeQueuedMessage(queued, sent: false);
          continue;
        }

        final attempt = await _sendModernAgentMessage(queued);
        if (_outboundQueue.isEmpty ||
            !identical(_outboundQueue.first, queued)) {
          continue;
        }
        if (attempt.outcome == _AcknowledgementOutcome.accepted) {
          _completeQueuedMessage(
            queued,
            sent: true,
            requestId: attempt.requestId,
          );
          continue;
        }
        if (attempt.outcome == _AcknowledgementOutcome.agentBusy) {
          queued
            ..requestId = null
            ..retryAttempts += 1
            ..retryReason = _QueuedRetryReason.agentBusy;
          if (_scheduleQueuedRetry(queued)) {
            break;
          }
          continue;
        }
        if (attempt.outcome == _AcknowledgementOutcome.connectionLost ||
            attempt.outcome == _AcknowledgementOutcome.timedOut) {
          queued
            ..retryAttempts += 1
            ..retryReason = _QueuedRetryReason.delivery;
          if (_scheduleQueuedRetry(queued)) {
            break;
          }
          continue;
        }
        _completeQueuedMessage(queued, sent: false);
      }
    } finally {
      _pumpingOutboundQueue = false;
      if (_outboundPumpRequested && !_disposed) {
        _outboundPumpRequested = false;
        _requestOutboundPump();
      }
    }
  }

  void _requestOutboundPump() {
    if (_disposed || _outboundQueue.isEmpty) {
      return;
    }
    if (_pumpingOutboundQueue) {
      _outboundPumpRequested = true;
      return;
    }
    unawaited(_pumpOutboundQueue());
  }

  bool _queueAgeExpired(_QueuedAgentMessage queued) {
    if (_maximumBusyQueueAge <= Duration.zero) {
      return true;
    }
    return DateTime.now().difference(queued.enqueuedAt) >= _maximumBusyQueueAge;
  }

  bool _scheduleQueuedRetry(_QueuedAgentMessage queued) {
    if (_disposed ||
        _outboundQueue.isEmpty ||
        !identical(_outboundQueue.first, queued)) {
      return false;
    }
    final elapsed = DateTime.now().difference(queued.enqueuedAt);
    final remaining = _maximumBusyQueueAge - elapsed;
    if (remaining <= Duration.zero) {
      _completeQueuedMessage(queued, sent: false);
      return false;
    }
    final configuredDelay = _busyRetryDelays.isEmpty
        ? const Duration(seconds: 2)
        : _busyRetryDelays[(queued.retryAttempts - 1).clamp(
            0,
            _busyRetryDelays.length - 1,
          )];
    final delay = configuredDelay < remaining ? configuredDelay : remaining;
    _outboundRetryTimer?.cancel();
    _outboundRetryTimer = Timer(delay, () {
      _outboundRetryTimer = null;
      queued.retryReason = null;
      _publishQueueStatus();
      _requestOutboundPump();
    });
    _publishQueueStatus();
    return true;
  }

  void _wakeBusyQueueFor(Map<String, dynamic> payload) {
    if (_outboundRetryTimer == null ||
        _outboundQueue.isEmpty ||
        _outboundQueue.first.retryReason != _QueuedRetryReason.agentBusy ||
        _disposed) {
      return;
    }
    final completedAgent = _extractEventAgent(payload);
    if (completedAgent == null ||
        completedAgent.toLowerCase() !=
            _outboundQueue.first.agent.toLowerCase()) {
      return;
    }
    _outboundRetryTimer?.cancel();
    _outboundRetryTimer = null;
    _outboundQueue.first.retryReason = null;
    _publishQueueStatus();
    _requestOutboundPump();
  }

  static String? _extractEventAgent(
    Map<String, dynamic> payload, {
    int depth = 0,
  }) {
    if (depth > 3) {
      return null;
    }
    final agent = payload['agent'];
    if (agent is String && agent.trim().isNotEmpty) {
      return agent.trim();
    }
    for (final key in const <String>['payload', 'result', 'data']) {
      final nested = payload[key];
      if (nested is Map<String, dynamic>) {
        final nestedAgent = _extractEventAgent(nested, depth: depth + 1);
        if (nestedAgent != null) {
          return nestedAgent;
        }
      }
    }
    return null;
  }

  void _completeQueuedMessage(
    _QueuedAgentMessage queued, {
    required bool sent,
    String? requestId,
  }) {
    if (_outboundQueue.isNotEmpty && identical(_outboundQueue.first, queued)) {
      _outboundQueue.removeFirst();
    } else {
      _outboundQueue.remove(queued);
    }
    if (sent) {
      _lastSentAgent = queued.agent;
    }
    if (!queued.completer.isCompleted) {
      queued.completer.complete(
        VoiceWebSocketSendResult(
          sent: sent,
          agent: queued.agent,
          message: queued.message,
          legacy: false,
          requestId: sent ? requestId : null,
        ),
      );
    }
    _publishQueueStatus();
  }

  void _cancelOutboundQueue() {
    _outboundRetryTimer?.cancel();
    _outboundRetryTimer = null;
    _outboundPumpRequested = false;
    for (final queued in _outboundQueue) {
      if (!queued.completer.isCompleted) {
        queued.completer.complete(
          VoiceWebSocketSendResult(
            sent: false,
            agent: queued.agent,
            message: queued.message,
            legacy: false,
          ),
        );
      }
    }
    final changed = _outboundQueue.isNotEmpty;
    _outboundQueue.clear();
    if (changed) {
      _publishQueueStatus();
    }
  }

  Future<void> _handleSocketData(Object? data, int generation) async {
    if (_disposed || generation != _generation || data is! String) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      final message = data.trim();
      if (message.isNotEmpty) {
        await _deliverInbound(
          VoiceWebSocketInboundEvent(
            message: message,
            kind: VoiceWebSocketInboundKind.message,
          ),
          generation,
        );
      }
      return;
    }
    if (decoded is String) {
      final message = decoded.trim();
      if (message.isNotEmpty) {
        await _deliverInbound(
          VoiceWebSocketInboundEvent(
            message: message,
            kind: VoiceWebSocketInboundKind.message,
          ),
          generation,
        );
      }
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    final type = decoded['type'];
    if (type == 'connection.ready') {
      _handleReady(decoded, generation);
      return;
    }
    if (type == 'message.accepted') {
      _handleAcknowledgement(decoded);
      return;
    }
    if (type == 'message.error') {
      _handleRejection(decoded);
    }
    if (type is String &&
        (type.startsWith('connection.') || type == 'pong' || type == 'ping')) {
      return;
    }
    final message = _extractMessage(decoded);
    if (message != null) {
      final delivered = await _deliverInbound(
        VoiceWebSocketInboundEvent(
          message: message,
          kind: switch (type) {
            'summary.result' => VoiceWebSocketInboundKind.summary,
            'message.completed' => VoiceWebSocketInboundKind.completed,
            'message.progress' => VoiceWebSocketInboundKind.progress,
            _ => VoiceWebSocketInboundKind.message,
          },
          agent: _extractEventAgent(decoded),
          requestId: _extractRequestId(decoded),
        ),
        generation,
      );
      if (!delivered || generation != _generation) {
        return;
      }
    }
    _captureAndAcknowledgeEvent(decoded);
    if (type == 'message.completed') {
      _wakeBusyQueueFor(decoded);
    }
  }

  void _handleReady(Map<String, dynamic> payload, int generation) {
    if (generation != _generation || payload['version'] != 1) {
      return;
    }
    _readyTimer?.cancel();
    _readyTimer = null;
    serverAgents = _stringList(payload['agents']);
    agentControls = _stringList(payload['agent_controls']);
    sessionControls = _stringList(payload['session_controls']);
    final socket = _socket;
    if (_everReady && _lastEventId != null && socket != null) {
      socket.add(
        jsonEncode(<String, Object>{
          'type': 'connection.resume',
          'resume_after_event_id': _lastEventId!,
        }),
      );
    }
    _everReady = true;
    _reconnectAttempt = 0;
    _setStatus(VoiceWebSocketStatus.ready, _connectedStatusText);
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
  }

  void _handleAcknowledgement(Map<String, dynamic> payload) {
    final requestId = payload['request_id'];
    if (requestId is! String) {
      return;
    }
    final pending = _pending.remove(requestId);
    if (pending == null) {
      return;
    }
    pending.timer.cancel();
    final result = payload['result'];
    final resultSent = result is Map<String, dynamic> ? result['sent'] : null;
    final accepted = payload['ok'] == true && resultSent != false;
    if (!pending.completer.isCompleted) {
      pending.completer.complete(
        accepted
            ? _AcknowledgementOutcome.accepted
            : _hasAgentBusyCode(payload)
            ? _AcknowledgementOutcome.agentBusy
            : _AcknowledgementOutcome.rejected,
      );
    }
  }

  void _handleRejection(Map<String, dynamic> payload) {
    final requestId = payload['request_id'];
    if (requestId is! String) {
      return;
    }
    final pending = _pending.remove(requestId);
    if (pending == null) {
      return;
    }
    pending.timer.cancel();
    if (!pending.completer.isCompleted) {
      pending.completer.complete(
        _hasAgentBusyCode(payload)
            ? _AcknowledgementOutcome.agentBusy
            : _AcknowledgementOutcome.rejected,
      );
    }
  }

  static bool _hasAgentBusyCode(
    Object? value, {
    int depth = 0,
    bool codeValue = false,
  }) {
    if (depth > 4) {
      return false;
    }
    if (value is String && codeValue) {
      final normalized = value.trim().toLowerCase().replaceAll(
        RegExp(r'[\s-]+'),
        '_',
      );
      return normalized == 'agent_busy';
    }
    if (value is! Map) {
      return false;
    }
    for (final entry in value.entries) {
      final key = entry.key.toString().toLowerCase();
      final nestedIsCode =
          key == 'code' ||
          key == 'error' ||
          key == 'error_code' ||
          key == 'reason' ||
          key == 'status';
      final nestedContainer =
          nestedIsCode || key == 'payload' || key == 'result' || key == 'data';
      if (nestedContainer &&
          _hasAgentBusyCode(
            entry.value,
            depth: depth + 1,
            codeValue: nestedIsCode,
          )) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _deliverInbound(
    VoiceWebSocketInboundEvent event,
    int generation,
  ) async {
    final eventHandler = _onInboundEvent;
    final messageHandler = _onInboundMessage;
    if (eventHandler == null && messageHandler == null) {
      return true;
    }
    try {
      if (eventHandler != null) {
        await eventHandler(event);
      } else {
        await messageHandler!(event.message);
      }
      return true;
    } on Object {
      if (!_disposed && generation == _generation) {
        _setStatus(
          VoiceWebSocketStatus.error,
          'Could not save server message · retrying',
        );
        unawaited(_closeSocket(reconnect: true));
      }
      return false;
    }
  }

  static String? _extractRequestId(
    Map<String, dynamic> payload, {
    int depth = 0,
  }) {
    if (depth > 3) {
      return null;
    }
    final requestId = payload['request_id'];
    if (requestId is String && requestId.trim().isNotEmpty) {
      return requestId.trim();
    }
    for (final key in const <String>['payload', 'result', 'data']) {
      final nested = payload[key];
      if (nested is Map<String, dynamic>) {
        final nestedRequestId = _extractRequestId(nested, depth: depth + 1);
        if (nestedRequestId != null) {
          return nestedRequestId;
        }
      }
    }
    return null;
  }

  void _captureAndAcknowledgeEvent(Map<String, dynamic> payload) {
    final eventId = payload['event_id'];
    final parsed = switch (eventId) {
      int value => value,
      String value => int.tryParse(value),
      _ => null,
    };
    if (parsed != null && parsed >= 0) {
      _lastEventId = parsed;
      final socket = _socket;
      if (socket != null && socket.readyState == WebSocket.open) {
        try {
          socket.add(
            jsonEncode(<String, Object>{
              'type': 'event.ack',
              'event_id': parsed,
            }),
          );
        } on Object {
          // The durable cursor is retained for connection.resume if this ACK
          // was lost with the socket.
        }
      }
    }
  }

  String? _extractMessage(Map<String, dynamic> payload) {
    String? message;
    for (final key in const <String>[
      'summary',
      'completion_message',
      'message',
      'text',
      'content',
      'detail',
    ]) {
      final value = payload[key];
      if (value is String && value.trim().isNotEmpty) {
        message = value.trim();
        break;
      }
    }
    if (message == null) {
      final detailLines = payload['detail_lines'];
      if (detailLines is List<dynamic>) {
        final lines = detailLines
            .whereType<String>()
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList(growable: false);
        if (lines.isNotEmpty) {
          message = lines.join('\n');
        }
      }
    }
    for (final key in const <String>['payload', 'result', 'data']) {
      if (message != null) {
        break;
      }
      final nested = payload[key];
      if (nested is Map<String, dynamic>) {
        message = _extractMessage(nested);
      }
    }
    if (message == null) {
      return null;
    }
    final agent = payload['agent'];
    if (agent is String &&
        agent.trim().isNotEmpty &&
        !message.toLowerCase().startsWith(agent.trim().toLowerCase())) {
      return '${agent.trim()}: $message';
    }
    return message;
  }

  void _handleSocketClosed(int generation) {
    if (_disposed || generation != _generation) {
      return;
    }
    _readyTimer?.cancel();
    _readyTimer = null;
    _socket = null;
    _subscription = null;
    _completePending(_AcknowledgementOutcome.connectionLost);
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('The WebSocket connection closed.'));
    }
    if (_manualDisconnect) {
      return;
    }
    _setStatus(VoiceWebSocketStatus.disconnected, 'Connection lost · retrying');
    _scheduleReconnect();
  }

  Future<void> _closeSocket({required bool reconnect}) async {
    _generation++;
    _readyTimer?.cancel();
    _readyTimer = null;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.close();
    _completePending(_AcknowledgementOutcome.connectionLost);
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('The WebSocket connection closed.'));
    }
    if (reconnect && !_manualDisconnect) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed ||
        _manualDisconnect ||
        !config.isConfigured ||
        _reconnectTimer != null ||
        _reconnectDelays.isEmpty) {
      return;
    }
    final index = _reconnectAttempt.clamp(0, _reconnectDelays.length - 1);
    final delay = _reconnectDelays[index];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connectIgnoringErrors());
    });
  }

  Future<void> _connectIgnoringErrors() async {
    try {
      await connect();
    } on Object {
      // Status and retry state are published without exposing endpoint or
      // authentication values through logs.
    }
  }

  void _completePending(_AcknowledgementOutcome outcome) {
    for (final pending in _pending.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(outcome);
      }
    }
    _pending.clear();
  }

  void _configChanged() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  String get _connectedStatusText {
    if (_outboundQueue.isNotEmpty) {
      final waiting = _outboundRetryTimer == null
          ? ''
          : switch (_outboundQueue.first.retryReason) {
              _QueuedRetryReason.agentBusy => ' · agent busy',
              _QueuedRetryReason.delivery => ' · retrying delivery',
              null => '',
            };
      return 'Connected · ${_outboundQueue.length} queued$waiting';
    }
    return serverAgents.isEmpty
        ? 'Connected · ready'
        : 'Connected · ${serverAgents.length} server agents';
  }

  void _publishQueueStatus() {
    if (_disposed) {
      return;
    }
    if (isReady) {
      _setStatus(VoiceWebSocketStatus.ready, _connectedStatusText);
    } else {
      notifyListeners();
    }
  }

  void _setStatus(VoiceWebSocketStatus next, String text) {
    final changed = status != next || statusText != text;
    status = next;
    statusText = text;
    if (changed && !_disposed) {
      notifyListeners();
    }
  }

  String _newRequestId() {
    final random = List<int>.generate(12, (_) => _random.nextInt(256));
    final suffix = random
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw StateError('Voice WebSocket configuration is not initialized.');
    }
  }

  Future<void> close() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _manualDisconnect = true;
    _cancelOutboundQueue();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _configStore.removeListener(_configChanged);
    await _closeSocket(reconnect: false);
    _configStore.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  static Future<WebSocket> _connect(Uri uri, Map<String, Object> headers) =>
      WebSocket.connect(uri.toString(), headers: headers);

  static List<String> _stringList(Object? value) {
    if (value is! List<dynamic>) {
      return const <String>[];
    }
    return List<String>.unmodifiable(
      value
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty),
    );
  }
}

final class _AgentMatch {
  const _AgentMatch({
    required this.agent,
    required this.start,
    required this.end,
  });

  final String agent;
  final int start;
  final int end;
}

final class _PendingAcknowledgement {
  const _PendingAcknowledgement({required this.completer, required this.timer});

  final Completer<_AcknowledgementOutcome> completer;
  final Timer timer;
}

final class _QueuedAgentMessage {
  _QueuedAgentMessage({
    required this.agent,
    required this.message,
    required this.enqueuedAt,
  });

  final String agent;
  final String message;
  final DateTime enqueuedAt;
  final Completer<VoiceWebSocketSendResult> completer =
      Completer<VoiceWebSocketSendResult>();
  String? requestId;
  int retryAttempts = 0;
  _QueuedRetryReason? retryReason;
}

enum _QueuedRetryReason { agentBusy, delivery }

final class _ModernSendAttempt {
  const _ModernSendAttempt({required this.outcome, required this.requestId});

  final _AcknowledgementOutcome outcome;
  final String requestId;
}

enum _AcknowledgementOutcome {
  accepted,
  rejected,
  agentBusy,
  connectionLost,
  timedOut,
}
