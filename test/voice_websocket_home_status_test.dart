import 'package:even_g2_r1_poc/src/ui/voice_websocket_home_status.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_connections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows one independently colored dot for every endpoint', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: VoiceWebSocketHomeStatus(
            states: <VoiceWebSocketEndpointState>[
              _state(
                'endpoint-a',
                '192.0.2.10',
                8787,
                VoiceWebSocketStatus.ready,
              ),
              _state(
                'endpoint-b',
                '192.0.2.20',
                9000,
                VoiceWebSocketStatus.disconnected,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('192.0.2.10:8787'), findsOneWidget);
    expect(find.text('192.0.2.20:9000 · Disconnected'), findsOneWidget);
    expect(
      tester
          .widget<Icon>(
            find.byKey(
              const ValueKey<String>('voice-websocket-status-dot-endpoint-a'),
            ),
          )
          .color,
      connectedStatusColor,
    );
    expect(
      tester
          .widget<Icon>(
            find.byKey(
              const ValueKey<String>('voice-websocket-status-dot-endpoint-b'),
            ),
          )
          .color,
      inactiveStatusColor,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a clear empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: const Scaffold(
          body: VoiceWebSocketHomeStatus(
            states: <VoiceWebSocketEndpointState>[],
          ),
        ),
      ),
    );

    expect(find.text('No agent servers'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

VoiceWebSocketEndpointState _state(
  String id,
  String host,
  int port,
  VoiceWebSocketStatus status,
) => VoiceWebSocketEndpointState(
  endpoint: VoiceWebSocketEndpointConfig.validate(
    id: id,
    host: host,
    port: port,
    secret: 'synthetic-secret',
    authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
    agentNames: <String>['Agent $id'],
  ),
  status: status,
  statusText: status.name,
  queuedMessageCount: 0,
);
