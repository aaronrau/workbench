import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-voice-websocket-config-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test(
    'validates and atomically saves app-private connection settings',
    () async {
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      addTearDown(store.dispose);
      await store.initialize();
      final config = VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: 8787,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.voiceApiToken,
        agentNames: const <String>['Agent One', 'Agent Two', 'agent one'],
      );

      await store.save(config);

      final file = File('${temp.path}/workbench/voice_websocket.json');
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(decoded['version'], 2);
      final sockets = decoded['voiceWebSockets'] as List<dynamic>;
      final socket = sockets.single as Map<String, dynamic>;
      expect(socket['host'], '127.0.0.1');
      expect(socket['port'], 8787);
      expect(socket['path'], '/ws');
      expect(socket['secret'], 'example-secret');
      expect(socket['authHeader'], 'xVoiceApiToken');
      expect(socket['agentNames'], <String>['Agent One', 'Agent Two']);
      expect(socket, isNot(contains('useLegacyMessageShape')));
      expect(File('${file.path}.part').existsSync(), isFalse);
    },
  );

  test(
    'keeps the last valid configuration after an invalid external edit',
    () async {
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      addTearDown(store.dispose);
      await store.initialize();
      final valid = VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: 8787,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One'],
      );
      await store.save(valid);
      final file = File('${temp.path}/workbench/voice_websocket.json');
      await file.writeAsString(
        '{"version":1,"voiceWebSocket":{"host":"999.1.1.1"}}',
        flush: true,
      );

      final loaded = await store.reload();

      expect(loaded, valid);
      expect(store.validationError, isNotNull);
    },
  );

  test('rejects unsafe addresses, ports, secrets, and empty agent lists', () {
    expect(
      () => VoiceWebSocketConfig.validateIpv4('192.168.1'),
      throwsFormatException,
    );
    expect(
      () => VoiceWebSocketConfig.validateIpv4('256.1.1.1'),
      throwsFormatException,
    );
    expect(
      () => VoiceWebSocketConfig.validateSecret('line\nbreak'),
      throwsFormatException,
    );
    expect(
      () => VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: 0,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One'],
      ),
      throwsFormatException,
    );
    expect(
      () => VoiceWebSocketConfig.validateAgentNames(const <String>[' ', '']),
      throwsFormatException,
    );
  });

  test('builds only the selected upgrade authentication header', () {
    final bearer = VoiceWebSocketConfig.validate(
      host: '127.0.0.1',
      port: 8787,
      secret: 'example-secret',
      authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
      agentNames: const <String>['Agent One'],
    );
    final token = bearer.copyWith(
      authHeader: VoiceWebSocketAuthHeader.voiceApiToken,
    );

    expect(bearer.upgradeHeaders, <String, Object>{
      HttpHeaders.authorizationHeader: 'Bearer example-secret',
    });
    expect(token.upgradeHeaders, <String, Object>{
      'X-Voice-Api-Token': 'example-secret',
    });
  });

  test('migrates version 1 and ignores the removed legacy flag', () {
    final migrated = VoiceWebSocketConfig.fromJson(<String, Object>{
      'version': 1,
      'voiceWebSocket': <String, Object>{
        'host': '192.0.2.10',
        'port': 8787,
        'path': '/ws',
        'secret': 'synthetic-secret',
        'authHeader': 'authorizationBearer',
        'agentNames': <String>['Flux'],
        'useLegacyMessageShape': true,
      },
    });

    expect(migrated.endpoints, hasLength(1));
    expect(migrated.endpoints.single.id, 'endpoint-1');
    expect(migrated.agentNames, <String>['Flux']);
    expect(
      migrated.endpoints.single.toJson(),
      isNot(contains('useLegacyMessageShape')),
    );
  });

  test('limits each endpoint to four globally unique agent names', () {
    expect(
      () => VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: 8787,
        secret: 'synthetic-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['One', 'Two', 'Three', 'Four', 'Five'],
      ),
      throwsFormatException,
    );

    final first = VoiceWebSocketConfig.validate(
      id: 'first',
      host: '127.0.0.1',
      port: 8787,
      secret: 'synthetic-secret',
      authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
      agentNames: const <String>['Flux'],
    ).endpoints.single;
    final second = VoiceWebSocketConfig.validate(
      id: 'second',
      host: '127.0.0.2',
      port: 8788,
      secret: 'synthetic-secret',
      authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
      agentNames: const <String>['flux'],
    ).endpoints.single;
    expect(
      () => VoiceWebSocketConfig.validateEndpoints(
        <VoiceWebSocketEndpointConfig>[first, second],
      ),
      throwsFormatException,
    );
  });

  test('requires a different IP address for every server', () {
    final first = VoiceWebSocketConfig.validate(
      id: 'first',
      host: '192.0.2.10',
      port: 8787,
      secret: 'first-server-secret',
      authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
      agentNames: const <String>['Alpha'],
    ).endpoints.single;
    final duplicateIp = VoiceWebSocketConfig.validate(
      id: 'second',
      host: '192.0.2.10',
      port: 9000,
      secret: 'second-server-secret',
      authHeader: VoiceWebSocketAuthHeader.voiceApiToken,
      agentNames: const <String>['Beta'],
    ).endpoints.single;

    expect(
      () => VoiceWebSocketConfig.validateEndpoints(
        <VoiceWebSocketEndpointConfig>[first, duplicateIp],
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Each server must use a different IP address.',
        ),
      ),
    );
  });

  test('shared settings round trip without a secret', () {
    final privateConfig = VoiceWebSocketConfig.validate(
      id: 'server-one',
      host: '192.0.2.10',
      port: 8787,
      secret: 'never-export-this-secret',
      authHeader: VoiceWebSocketAuthHeader.voiceApiToken,
      agentNames: const <String>['Agent One', 'Flux'],
    );

    final encoded = VoiceWebSocketSharedSettings.fromConfig(
      privateConfig,
    ).encode();
    final restored = VoiceWebSocketSharedSettings.decode(encoded);

    expect(encoded, isNot(contains('never-export-this-secret')));
    expect(encoded, isNot(contains('"secret"')));
    expect(restored.endpoints, hasLength(1));
    expect(restored.endpoints.single.host, '192.0.2.10');
    expect(restored.endpoints.single.port, 8787);
    expect(restored.endpoints.single.agentNames, <String>['Agent One', 'Flux']);
    expect(
      restored.endpoints.single.authHeader,
      VoiceWebSocketAuthHeader.voiceApiToken,
    );
  });

  test('shared settings reject a secret field', () {
    expect(
      () => VoiceWebSocketSharedSettings.decode(
        jsonEncode(<String, Object>{
          'version': 1,
          'agentServers': <Object>[
            <String, Object>{
              'id': 'server-one',
              'host': '192.0.2.10',
              'port': 8787,
              'path': '/ws',
              'authHeader': 'authorizationBearer',
              'agentNames': <String>['Flux'],
              'secret': 'must-not-be-here',
            },
          ],
        }),
      ),
      throwsFormatException,
    );

    expect(
      () => VoiceWebSocketSharedSettings.decode(
        jsonEncode(<String, Object>{
          'version': 1,
          'agentServers': <Object>[],
          'secret': 'must-not-be-here',
        }),
      ),
      throwsFormatException,
    );
  });
}
