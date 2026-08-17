import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'voice_websocket_client.dart';
import 'voice_websocket_config.dart';

final class VoiceWebSocketEndpointState {
  const VoiceWebSocketEndpointState({
    required this.endpoint,
    required this.status,
    required this.statusText,
    required this.queuedMessageCount,
  });

  final VoiceWebSocketEndpointConfig endpoint;
  final VoiceWebSocketStatus status;
  final String statusText;
  final int queuedMessageCount;
}

/// Owns a set of deliberately independent WebSocket clients.
///
/// This class is only a routing registry. Every endpoint client owns its own
/// socket, inbound tail, acknowledgement map, FIFO, generation, timers, and
/// reconnect lifecycle. No connection waits for another connection to become
/// ready and no cross-endpoint delivery queue exists.
final class VoiceWebSocketConnections extends ChangeNotifier {
  VoiceWebSocketConnections({
    VoiceWebSocketConfigStore? configStore,
    VoiceWebSocketConnector connector = _connect,
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
  }) : _configStore = configStore ?? VoiceWebSocketConfigStore(),
       _connector = connector,
       _onInboundEvent = onInboundEvent,
       _readyTimeout = readyTimeout,
       _acknowledgementTimeout = acknowledgementTimeout,
       _reconnectDelays = reconnectDelays;

  final VoiceWebSocketConfigStore _configStore;
  final VoiceWebSocketConnector _connector;
  final VoiceWebSocketInboundEventHandler? _onInboundEvent;
  final Duration _readyTimeout;
  final Duration _acknowledgementTimeout;
  final List<Duration> _reconnectDelays;
  final Map<String, _ManagedEndpoint> _connections =
      <String, _ManagedEndpoint>{};

  bool _initialized = false;
  bool _disposed = false;
  VoiceWebSocketAgentTarget? _lastSentTarget;

  VoiceWebSocketConfig get config => _configStore.config;
  String? get validationError => _configStore.validationError;
  List<String> get agentNames => config.agentNames;
  List<VoiceWebSocketAgentTarget> get agentTargets => config.agentTargets;
  VoiceWebSocketAgentTarget? get lastSentTarget => _lastSentTarget;
  String? get lastSentAgent => _lastSentTarget?.agentName;

  List<VoiceWebSocketEndpointState> get endpointStates => List.unmodifiable(
    config.endpoints.map((endpoint) {
      final managed = _connections[endpoint.id];
      return VoiceWebSocketEndpointState(
        endpoint: endpoint,
        status: managed?.startupFailed == true
            ? VoiceWebSocketStatus.error
            : managed?.client.status ?? VoiceWebSocketStatus.disconnected,
        statusText: managed?.startupFailed == true
            ? 'Connection unavailable'
            : managed?.client.statusText ?? 'Saved · disconnected',
        queuedMessageCount: managed?.client.queuedMessageCount ?? 0,
      );
    }),
  );

  VoiceWebSocketEndpointState? stateForEndpoint(String endpointId) {
    for (final state in endpointStates) {
      if (state.endpoint.id == endpointId) {
        return state;
      }
    }
    return null;
  }

  VoiceWebSocketStatus statusForAgent(String agent) {
    final target = config.targetForAgent(agent);
    return target == null
        ? VoiceWebSocketStatus.unconfigured
        : stateForEndpoint(target.endpointId)?.status ??
              VoiceWebSocketStatus.disconnected;
  }

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    _configStore.addListener(_configChanged);
    await _configStore.initialize();
    await _installAll(config.endpoints);
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> saveConfig(VoiceWebSocketConfig value) async {
    _requireInitialized();
    final validated = VoiceWebSocketConfig.validateEndpoints(value.endpoints);
    final priorById = <String, VoiceWebSocketEndpointConfig>{
      for (final endpoint in config.endpoints) endpoint.id: endpoint,
    };
    await _configStore.save(validated);

    final desiredIds = validated.endpoints
        .map((endpoint) => endpoint.id)
        .toSet();
    final removals = _connections.keys
        .where((id) => !desiredIds.contains(id))
        .toList(growable: false);
    final replacements = validated.endpoints
        .where((endpoint) => priorById[endpoint.id] != endpoint)
        .toList(growable: false);

    await Future.wait<void>(
      <Future<void>>[
        for (final id in removals) _remove(id),
        for (final endpoint in replacements) _replace(endpoint),
      ].map((operation) => operation.catchError((Object _) {})),
    );

    final last = _lastSentTarget;
    if (last != null && config.endpointById(last.endpointId) == null) {
      _lastSentTarget = null;
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> connectEndpoint(String endpointId) async {
    _requireInitialized();
    final managed = _connections[endpointId];
    if (managed == null) {
      throw StateError('The selected agent connection is unavailable.');
    }
    await managed.client.connect();
  }

  Future<void> disconnectEndpoint(String endpointId) async {
    _requireInitialized();
    await _connections[endpointId]?.client.disconnect();
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
    for (final target in config.agentTargets) {
      final match = RegExp(
        '(^|[^A-Za-z0-9_])(${RegExp.escape(target.agentName)})(?=\$|[^A-Za-z0-9_])',
        caseSensitive: false,
      ).firstMatch(text);
      if (match == null ||
          evidenceTranscript != null &&
              !_hasLeadingAttentionEvidence(evidenceTranscript)) {
        continue;
      }
      final nameStart = match.start + (match.group(1)?.length ?? 0);
      final candidate = _AgentMatch(
        target: target,
        start: nameStart,
        end: match.end,
      );
      if (selected == null ||
          candidate.start < selected.start ||
          candidate.start == selected.start &&
              candidate.target.agentName.length >
                  selected.target.agentName.length) {
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
    return AgentTranscriptRoute(
      endpointId: selected.target.endpointId,
      agent: selected.target.agentName,
      message: message,
    );
  }

  AgentTranscriptRoute? routeTranscriptToSelectedAgent({
    String? endpointId,
    required String selectedAgent,
    required String transcript,
  }) {
    final message = transcript.trim();
    final target = config.targetForAgent(selectedAgent);
    if (message.isEmpty ||
        target == null ||
        endpointId != null && target.endpointId != endpointId) {
      return null;
    }
    return AgentTranscriptRoute(
      endpointId: target.endpointId,
      agent: target.agentName,
      message: message,
    );
  }

  Future<VoiceWebSocketSendResult> sendAgentMessageWithResult({
    required String endpointId,
    required String agent,
    required String message,
    VoiceWebSocketDeliveryMode deliveryMode = VoiceWebSocketDeliveryMode.queued,
  }) async {
    final target = config.targetForAgent(agent);
    final endpoint = config.endpointById(endpointId);
    final trimmed = message.trim();
    if (target == null ||
        target.endpointId != endpointId ||
        endpoint == null ||
        trimmed.isEmpty) {
      return VoiceWebSocketSendResult(
        sent: false,
        endpointId: endpointId,
        agent: target?.agentName ?? '',
        message: trimmed,
        legacy: false,
      );
    }
    final client = _connections[endpointId]?.client;
    if (client == null) {
      return VoiceWebSocketSendResult(
        sent: false,
        endpointId: endpointId,
        agent: target.agentName,
        message: trimmed,
        legacy: false,
      );
    }
    final result = await client.sendAgentMessageWithResult(
      agent: target.agentName,
      message: trimmed,
      deliveryMode: deliveryMode,
    );
    final routed = VoiceWebSocketSendResult(
      sent: result.sent,
      endpointId: endpointId,
      agent: result.agent,
      message: result.message,
      legacy: result.legacy,
      requestId: result.requestId,
    );
    if (routed.sent) {
      _lastSentTarget = target;
    }
    return routed;
  }

  Future<VoiceWebSocketSummaryRequestOutcome>
  requestLastSentAgentSummary() async {
    final target = _lastSentTarget;
    if (target == null) {
      return VoiceWebSocketSummaryRequestOutcome.noSentAgent;
    }
    return (await requestAgentSummary(target)).outcome;
  }

  Future<VoiceWebSocketSummaryRequestResult> requestAgentSummary(
    VoiceWebSocketAgentTarget target,
  ) async {
    final configured = config.targetForAgent(target.agentName);
    final endpoint = config.endpointById(target.endpointId);
    if (configured == null ||
        configured.endpointId != target.endpointId ||
        endpoint == null) {
      return const VoiceWebSocketSummaryRequestResult(
        outcome: VoiceWebSocketSummaryRequestOutcome.noSentAgent,
        agent: null,
        legacy: false,
      );
    }
    final client = _connections[target.endpointId]?.client;
    if (client == null) {
      return VoiceWebSocketSummaryRequestResult(
        outcome: VoiceWebSocketSummaryRequestOutcome.unavailable,
        endpointId: target.endpointId,
        agent: target.agentName,
        legacy: false,
      );
    }
    final result = await client.requestAgentSummary(target.agentName);
    return VoiceWebSocketSummaryRequestResult(
      outcome: result.outcome,
      endpointId: target.endpointId,
      agent: result.agent,
      legacy: result.legacy,
      requestId: result.requestId,
    );
  }

  Future<void> _installAll(Iterable<VoiceWebSocketEndpointConfig> endpoints) =>
      Future.wait<void>(
        endpoints.map(
          (endpoint) => _install(endpoint).catchError((Object _) {}),
        ),
      );

  Future<void> _replace(VoiceWebSocketEndpointConfig endpoint) async {
    await _remove(endpoint.id);
    await _install(endpoint);
  }

  Future<void> _install(VoiceWebSocketEndpointConfig endpoint) async {
    if (_disposed || _connections.containsKey(endpoint.id)) {
      return;
    }
    final endpointStore = VoiceWebSocketConfigStore.inMemory(
      VoiceWebSocketConfig.single(endpoint),
    );
    final client = VoiceWebSocketClient(
      configStore: endpointStore,
      connector: _connector,
      readyTimeout: _readyTimeout,
      acknowledgementTimeout: _acknowledgementTimeout,
      reconnectDelays: _reconnectDelays,
      onInboundEvent: (event) {
        final handler = _onInboundEvent;
        if (handler == null) {
          return Future<void>.value();
        }
        return handler(
          VoiceWebSocketInboundEvent(
            endpointId: endpoint.id,
            message: event.message,
            kind: event.kind,
            agent: event.agent,
            requestId: event.requestId,
          ),
        );
      },
    );
    late final VoidCallback listener;
    listener = () {
      if (!_disposed) {
        notifyListeners();
      }
    };
    final managed = _ManagedEndpoint(client: client, listener: listener);
    _connections[endpoint.id] = managed;
    client.addListener(listener);
    try {
      await client.initialize();
    } on Object {
      managed.startupFailed = true;
    }
  }

  Future<void> _remove(String endpointId) async {
    final managed = _connections.remove(endpointId);
    if (managed == null) {
      return;
    }
    managed.client.removeListener(managed.listener);
    await managed.client.close();
  }

  void _configChanged() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  static bool _hasLeadingAttentionEvidence(String rawTranscript) => RegExp(
    r'^\s*hey(?=$|[^A-Za-z0-9_])',
    caseSensitive: false,
  ).hasMatch(rawTranscript);

  void _requireInitialized() {
    if (!_initialized || _disposed) {
      throw StateError('Voice WebSocket connections are not initialized.');
    }
  }

  Future<void> close() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _configStore.removeListener(_configChanged);
    final ids = _connections.keys.toList(growable: false);
    await Future.wait(ids.map(_remove));
    _configStore.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  static Future<WebSocket> _connect(Uri uri, Map<String, Object> headers) =>
      WebSocket.connect(uri.toString(), headers: headers);
}

final class _ManagedEndpoint {
  _ManagedEndpoint({required this.client, required this.listener});

  final VoiceWebSocketClient client;
  final VoidCallback listener;
  bool startupFailed = false;
}

final class _AgentMatch {
  const _AgentMatch({
    required this.target,
    required this.start,
    required this.end,
  });

  final VoiceWebSocketAgentTarget target;
  final int start;
  final int end;
}
