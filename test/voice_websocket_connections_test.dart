import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_connections.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('routes by agent while a failed endpoint remains isolated', () async {
    final good = await _MockAgentServer.start(<String>['Beta']);
    addTearDown(good.close);
    final config = VoiceWebSocketConfig.validateEndpoints(
      <VoiceWebSocketEndpointConfig>[
        _endpoint(
          id: 'failed',
          host: '127.0.0.2',
          port: 1,
          secret: 'failed-server-secret',
          agents: <String>['Alpha'],
        ),
        _endpoint(
          id: 'good',
          host: '127.0.0.3',
          port: good.port,
          secret: 'good-server-secret',
          agents: <String>['Beta'],
        ),
      ],
    );
    final inbound = Completer<VoiceWebSocketInboundEvent>();
    final connections = VoiceWebSocketConnections(
      configStore: VoiceWebSocketConfigStore.inMemory(config),
      readyTimeout: const Duration(milliseconds: 300),
      acknowledgementTimeout: const Duration(seconds: 2),
      reconnectDelays: const <Duration>[],
      onInboundEvent: (event) async {
        if (!inbound.isCompleted) inbound.complete(event);
      },
    );
    addTearDown(connections.close);

    await connections.initialize();
    await _waitFor(
      () =>
          connections.stateForEndpoint('good')?.status ==
          VoiceWebSocketStatus.ready,
    );

    final route = connections.routeForTranscript(
      'Hey Beta run the synthetic check',
      evidenceTranscript: 'Hey Beta run the synthetic check',
    );
    expect(route?.endpointId, 'good');
    expect(route?.agent, 'Beta');
    expect(route?.message, 'Hey Beta run the synthetic check');

    final result = await connections.sendAgentMessageWithResult(
      endpointId: route!.endpointId!,
      agent: route.agent,
      message: route.message,
    );
    expect(result.sent, isTrue);
    expect(result.endpointId, 'good');
    expect(good.received.single['agent'], 'Beta');
    expect((await inbound.future).endpointId, 'good');
    expect(
      connections.stateForEndpoint('failed')?.status,
      isNot(VoiceWebSocketStatus.ready),
    );
    expect(
      connections.stateForEndpoint('good')?.status,
      VoiceWebSocketStatus.ready,
    );
  });

  test('one endpoint acknowledgement never blocks another endpoint', () async {
    final releaseSlow = Completer<void>();
    final slow = await _MockAgentServer.start(<String>[
      'Alpha',
    ], acknowledgementGate: releaseSlow.future);
    final fast = await _MockAgentServer.start(<String>['Beta']);
    addTearDown(slow.close);
    addTearDown(fast.close);
    final config = VoiceWebSocketConfig.validateEndpoints(
      <VoiceWebSocketEndpointConfig>[
        _endpoint(
          id: 'slow',
          host: '127.0.0.2',
          port: slow.port,
          secret: 'slow-server-secret',
          agents: <String>['Alpha'],
        ),
        _endpoint(
          id: 'fast',
          host: '127.0.0.3',
          port: fast.port,
          secret: 'fast-server-secret',
          agents: <String>['Beta'],
        ),
      ],
    );
    final connections = VoiceWebSocketConnections(
      configStore: VoiceWebSocketConfigStore.inMemory(config),
      acknowledgementTimeout: const Duration(seconds: 3),
      reconnectDelays: const <Duration>[],
    );
    addTearDown(connections.close);
    await connections.initialize();
    await _waitFor(
      () => connections.endpointStates.every(
        (state) => state.status == VoiceWebSocketStatus.ready,
      ),
    );

    var slowCompleted = false;
    final slowSend = connections
        .sendAgentMessageWithResult(
          endpointId: 'slow',
          agent: 'Alpha',
          message: 'slow command',
        )
        .then((result) {
          slowCompleted = true;
          return result;
        });
    await _waitFor(() => slow.received.isNotEmpty);

    final fastResult = await connections.sendAgentMessageWithResult(
      endpointId: 'fast',
      agent: 'Beta',
      message: 'fast command',
    );
    expect(fastResult.sent, isTrue);
    expect(slowCompleted, isFalse);
    expect(fast.received.single['message'], 'fast command');

    releaseSlow.complete();
    expect((await slowSend).sent, isTrue);
  });

  test(
    'editing one endpoint keeps the other socket and routing alive',
    () async {
      final first = await _MockAgentServer.start(<String>['Alpha']);
      final second = await _MockAgentServer.start(<String>['Beta']);
      addTearDown(first.close);
      addTearDown(second.close);
      final initial = VoiceWebSocketConfig.validateEndpoints(
        <VoiceWebSocketEndpointConfig>[
          _endpoint(
            id: 'first',
            host: '127.0.0.2',
            port: first.port,
            secret: 'first-server-secret',
            agents: <String>['Alpha'],
          ),
          _endpoint(
            id: 'second',
            host: '127.0.0.3',
            port: second.port,
            secret: 'second-server-secret',
            agents: <String>['Beta'],
          ),
        ],
      );
      final connections = VoiceWebSocketConnections(
        configStore: VoiceWebSocketConfigStore.inMemory(initial),
        reconnectDelays: const <Duration>[],
      );
      addTearDown(connections.close);
      await connections.initialize();
      await _waitFor(() => second.connectionCount == 1);

      await connections.saveConfig(
        VoiceWebSocketConfig.validateEndpoints(<VoiceWebSocketEndpointConfig>[
          _endpoint(
            id: 'first',
            host: '127.0.0.2',
            port: 2,
            secret: 'replacement-server-secret',
            agents: <String>['Alpha'],
          ),
          initial.endpointById('second')!,
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(second.connectionCount, 1);
      final result = await connections.sendAgentMessageWithResult(
        endpointId: 'second',
        agent: 'Beta',
        message: 'still connected',
      );
      expect(result.sent, isTrue);
      expect(second.connectionCount, 1);
    },
  );

  test('removing one server leaves the remaining server connected', () async {
    final first = await _MockAgentServer.start(<String>['Alpha']);
    final second = await _MockAgentServer.start(<String>['Beta']);
    addTearDown(first.close);
    addTearDown(second.close);
    final initial = VoiceWebSocketConfig.validateEndpoints(
      <VoiceWebSocketEndpointConfig>[
        _endpoint(
          id: 'first',
          host: '127.0.0.2',
          port: first.port,
          secret: 'first-server-secret',
          agents: <String>['Alpha'],
        ),
        _endpoint(
          id: 'second',
          host: '127.0.0.3',
          port: second.port,
          secret: 'second-server-secret',
          agents: <String>['Beta'],
        ),
      ],
    );
    final connections = VoiceWebSocketConnections(
      configStore: VoiceWebSocketConfigStore.inMemory(initial),
      reconnectDelays: const <Duration>[],
    );
    addTearDown(connections.close);
    await connections.initialize();
    await _waitFor(
      () => connections.endpointStates.every(
        (state) => state.status == VoiceWebSocketStatus.ready,
      ),
    );

    await connections.saveConfig(
      VoiceWebSocketConfig.validateEndpoints(<VoiceWebSocketEndpointConfig>[
        initial.endpointById('second')!,
      ]),
    );

    expect(connections.stateForEndpoint('first'), isNull);
    expect(
      connections.stateForEndpoint('second')?.status,
      VoiceWebSocketStatus.ready,
    );
    expect(second.connectionCount, 1);
    final result = await connections.sendAgentMessageWithResult(
      endpointId: 'second',
      agent: 'Beta',
      message: 'still routed after removal',
    );
    expect(result.sent, isTrue);
    expect(second.received.single['message'], 'still routed after removal');
    expect(second.connectionCount, 1);
  });
}

VoiceWebSocketEndpointConfig _endpoint({
  required String id,
  required String host,
  required int port,
  required String secret,
  required List<String> agents,
}) => VoiceWebSocketEndpointConfig.validate(
  id: id,
  host: host,
  port: port,
  secret: secret,
  authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
  agentNames: agents,
);

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _MockAgentServer {
  _MockAgentServer._(this._server, this.agents, this.acknowledgementGate);

  final HttpServer _server;
  final List<String> agents;
  final Future<void>? acknowledgementGate;
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];
  final List<WebSocket> _sockets = <WebSocket>[];
  int connectionCount = 0;

  int get port => _server.port;

  static Future<_MockAgentServer> start(
    List<String> agents, {
    Future<void>? acknowledgementGate,
  }) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final mock = _MockAgentServer._(server, agents, acknowledgementGate);
    server.transform(WebSocketTransformer()).listen(mock._accept);
    return mock;
  }

  void _accept(WebSocket socket) {
    connectionCount++;
    _sockets.add(socket);
    socket.add(
      jsonEncode(<String, Object>{
        'type': 'connection.ready',
        'version': 1,
        'agents': agents,
      }),
    );
    socket.listen((value) async {
      final decoded = jsonDecode('$value');
      if (decoded is! Map<String, dynamic> ||
          decoded['type'] != 'message.send') {
        return;
      }
      received.add(decoded);
      await acknowledgementGate;
      final requestId = decoded['request_id'];
      socket.add(
        jsonEncode(<String, Object?>{
          'type': 'message.accepted',
          'request_id': requestId,
          'ok': true,
          'result': <String, Object>{'sent': true},
        }),
      );
      socket.add(
        jsonEncode(<String, Object?>{
          'type': 'message.progress',
          'event_id': received.length,
          'request_id': requestId,
          'agent': decoded['agent'],
          'payload': <String, Object>{'message': 'mock signal received'},
        }),
      );
    });
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
