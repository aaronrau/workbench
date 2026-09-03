import 'package:even_g2_r1_poc/src/ui/voice_websocket_settings.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_connections.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('validates and saves a private connection on a phone viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VoiceWebSocketConfig? saved;
    var connectCalls = 0;
    var disconnectCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: VoiceWebSocketSettings(
                config: VoiceWebSocketConfig.defaults,
                endpointStates: const <VoiceWebSocketEndpointState>[],
                busy: false,
                onSave: (value) async => saved = value,
                onConnect: (_) async => connectCalls++,
                onDisconnect: (_) async => disconnectCalls++,
              ),
            ),
          ),
        ),
      ),
    );

    final ipField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-ip')),
        matching: find.byType(EditableText),
      ),
    );
    final portField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-port')),
        matching: find.byType(EditableText),
      ),
    );
    final secretField = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-secret')),
        matching: find.byType(EditableText),
      ),
    );
    expect(
      ipField.keyboardType,
      const TextInputType.numberWithOptions(decimal: true),
    );
    expect(portField.keyboardType, TextInputType.number);
    expect(secretField.obscureText, isTrue);
    expect(find.textContaining('unencrypted'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('voice-websocket-ip')),
      '127.0.0.1',
    );
    await tester.enterText(
      find.byKey(const Key('voice-websocket-port')),
      '8787',
    );
    await tester.enterText(
      find.byKey(const Key('voice-websocket-secret')),
      'example-secret',
    );
    await tester.enterText(
      find.byKey(const Key('voice-websocket-agents')),
      'Agent One\nAgent Two',
    );
    final save = find.widgetWithText(FilledButton, 'Save servers');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(saved?.host, '127.0.0.1');
    expect(saved?.port, 8787);
    expect(saved?.secret, 'example-secret');
    expect(saved?.agentNames, <String>['Agent One', 'Agent Two']);
    expect(saved?.authHeader, VoiceWebSocketAuthHeader.authorizationBearer);
    expect(find.text('Use legacy message shape'), findsNothing);
    expect(find.textContaining('without acknowledgement'), findsNothing);
    expect(connectCalls, 0);
    expect(disconnectCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows validation without saving invalid fields', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    VoiceWebSocketConfig? saved;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: VoiceWebSocketSettings(
              config: VoiceWebSocketConfig.defaults,
              endpointStates: const <VoiceWebSocketEndpointState>[],
              busy: false,
              onSave: (value) async => saved = value,
              onConnect: (_) async {},
              onDisconnect: (_) async {},
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('voice-websocket-ip')),
      '999.0.0.1',
    );
    final save = find.widgetWithText(FilledButton, 'Save servers');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();

    expect(
      find.text('Each IP address number must be from 0 to 255.'),
      findsOneWidget,
    );
    expect(find.text('Secret cannot be empty.'), findsOneWidget);
    expect(find.text('Add at least one agent name.'), findsOneWidget);
    expect(saved, isNull);
  });

  testWidgets(
    'adds three servers, removes one, and saves distinct server settings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      VoiceWebSocketConfig? saved;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildWorkBenchTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: VoiceWebSocketSettings(
                config: VoiceWebSocketConfig.defaults,
                endpointStates: const <VoiceWebSocketEndpointState>[],
                busy: false,
                onSave: (value) async => saved = value,
                onConnect: (_) async {},
                onDisconnect: (_) async {},
              ),
            ),
          ),
        ),
      );

      final add = find.byKey(const ValueKey<String>('voice-websocket-add'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();

      Finder fields(String prefix) => find.byWidgetPredicate(
        (widget) =>
            widget is TextFormField &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(prefix),
      );

      expect(fields('voice-websocket-ip'), findsNWidgets(3));
      final removeServers = find.widgetWithText(TextButton, 'Remove server');
      await tester.ensureVisible(removeServers.at(1));
      await tester.tap(removeServers.at(1));
      await tester.pumpAndSettle();

      expect(fields('voice-websocket-ip'), findsNWidgets(2));
      await tester.enterText(fields('voice-websocket-ip').at(0), '127.0.0.2');
      await tester.enterText(fields('voice-websocket-ip').at(1), '127.0.0.3');
      await tester.enterText(fields('voice-websocket-port').at(0), '8787');
      await tester.enterText(fields('voice-websocket-port').at(1), '8788');
      await tester.enterText(
        fields('voice-websocket-secret').at(0),
        'alpha-server-secret',
      );
      await tester.enterText(
        fields('voice-websocket-secret').at(1),
        'beta-server-secret',
      );
      await tester.enterText(
        fields('voice-websocket-agents').at(0),
        'Alpha One\nAlpha Two',
      );
      await tester.enterText(
        fields('voice-websocket-agents').at(1),
        'Beta One\nBeta Two',
      );

      final save = find.widgetWithText(FilledButton, 'Save servers');
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(saved?.endpoints, hasLength(2));
      expect(saved?.endpoints[0].host, '127.0.0.2');
      expect(saved?.endpoints[0].port, 8787);
      expect(saved?.endpoints[0].secret, 'alpha-server-secret');
      expect(saved?.endpoints[0].agentNames, <String>[
        'Alpha One',
        'Alpha Two',
      ]);
      expect(saved?.endpoints[1].host, '127.0.0.3');
      expect(saved?.endpoints[1].port, 8788);
      expect(saved?.endpoints[1].secret, 'beta-server-secret');
      expect(saved?.endpoints[1].agentNames, <String>['Beta One', 'Beta Two']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('restores shared server fields but requires the secret', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: VoiceWebSocketSettings(
              config: VoiceWebSocketConfig.defaults,
              restoredSettings: const VoiceWebSocketSharedSettings(
                endpoints: <VoiceWebSocketSharedEndpointSettings>[
                  VoiceWebSocketSharedEndpointSettings(
                    id: 'server-one',
                    host: '192.0.2.10',
                    port: 8787,
                    authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
                    agentNames: <String>['Flux'],
                  ),
                ],
              ),
              endpointStates: const <VoiceWebSocketEndpointState>[],
              busy: false,
              onSave: (_) async {},
              onConnect: (_) async {},
              onDisconnect: (_) async {},
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('restored from the shared folder'), findsOne);
    final ip = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-ip')),
        matching: find.byType(EditableText),
      ),
    );
    final secret = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-secret')),
        matching: find.byType(EditableText),
      ),
    );
    final agents = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('voice-websocket-agents')),
        matching: find.byType(EditableText),
      ),
    );
    expect(ip.controller.text, '192.0.2.10');
    expect(secret.controller.text, isEmpty);
    expect(agents.controller.text, 'Flux');
    expect(find.widgetWithText(OutlinedButton, 'Connect server'), findsOne);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Connect server'),
          )
          .onPressed,
      isNull,
    );
  });
}
