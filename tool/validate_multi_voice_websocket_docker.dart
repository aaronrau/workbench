import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_connections.dart';
import 'package:flutter_test/flutter_test.dart';

const firstPort = int.fromEnvironment('FIRST_PORT');
const secondPort = int.fromEnvironment('SECOND_PORT');
const firstHost = String.fromEnvironment('FIRST_HOST');
const secondHost = String.fromEnvironment('SECOND_HOST');
const firstSecret = String.fromEnvironment('FIRST_SECRET');
const secondSecret = String.fromEnvironment('SECOND_SECRET');
const expectFirstFailure = bool.fromEnvironment('EXPECT_FIRST_FAILURE');

void main() {
  test('validates independent Docker WebSocket mocks', () async {
    if (firstPort == 0 ||
        secondPort == 0 ||
        firstHost.isEmpty ||
        secondHost.isEmpty ||
        firstSecret.isEmpty ||
        secondSecret.isEmpty) {
      throw StateError('Docker server settings were not supplied.');
    }
    final received = <String>[];
    final config =
        VoiceWebSocketConfig.validateEndpoints(<VoiceWebSocketEndpointConfig>[
          _endpoint(
            id: 'docker-first',
            host: firstHost,
            port: firstPort,
            secret: firstSecret,
            agent: 'Mock Alpha',
          ),
          _endpoint(
            id: 'docker-second',
            host: secondHost,
            port: secondPort,
            secret: secondSecret,
            agent: 'Mock Beta',
          ),
        ]);
    final connections = VoiceWebSocketConnections(
      configStore: VoiceWebSocketConfigStore.inMemory(config),
      readyTimeout: const Duration(milliseconds: 750),
      acknowledgementTimeout: const Duration(seconds: 3),
      reconnectDelays: const <Duration>[],
      onInboundEvent: (event) async {
        if (event.endpointId != null) received.add(event.endpointId!);
      },
    );

    try {
      await connections.initialize();
      await _waitFor(
        () =>
            connections.stateForEndpoint('docker-second')?.status ==
            VoiceWebSocketStatus.ready,
      );
      if (expectFirstFailure) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(
          connections.stateForEndpoint('docker-first')?.status,
          isNot(VoiceWebSocketStatus.ready),
        );
        final result = await connections.sendAgentMessageWithResult(
          endpointId: 'docker-second',
          agent: 'Mock Beta',
          message: 'synthetic isolation signal',
        );
        expect(result.sent, isTrue);
        await _waitFor(() => received.contains('docker-second'));
        stdout.writeln(
          'docker_validation_pass mode=isolation sent=1 received=1',
        );
        return;
      }

      await _waitFor(
        () => connections.endpointStates.every(
          (state) => state.status == VoiceWebSocketStatus.ready,
        ),
      );
      final routes = <AgentTranscriptRoute>[
        connections.routeForTranscript('Mock Alpha synthetic first signal')!,
        connections.routeForTranscript('Mock Beta synthetic second signal')!,
      ];
      final results = await Future.wait(
        routes.map(
          (route) => connections.sendAgentMessageWithResult(
            endpointId: route.endpointId!,
            agent: route.agent,
            message: route.message,
          ),
        ),
      );
      expect(results.every((result) => result.sent), isTrue);
      await _waitFor(
        () =>
            received.contains('docker-first') &&
            received.contains('docker-second'),
      );
      stdout.writeln('docker_validation_pass mode=dual sent=2 received=2');
    } finally {
      await connections.close();
    }
  });
}

VoiceWebSocketEndpointConfig _endpoint({
  required String id,
  required String host,
  required int port,
  required String secret,
  required String agent,
}) => VoiceWebSocketEndpointConfig.validate(
  id: id,
  host: host,
  port: port,
  secret: secret,
  authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
  agentNames: <String>[agent],
);

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Docker validation timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
