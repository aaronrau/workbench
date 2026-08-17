import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:flutter/widgets.dart';

const _fixturePort = int.fromEnvironment(
  'WORKBENCH_QUEUE_FIXTURE_PORT',
  defaultValue: 18787,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await Directory.systemTemp.createTemp(
    'workbench-queue-validation-',
  );
  final client = VoiceWebSocketClient(
    configStore: VoiceWebSocketConfigStore(
      supportDirectory: () async => support,
    ),
    readyTimeout: const Duration(seconds: 5),
    acknowledgementTimeout: const Duration(seconds: 5),
    reconnectDelays: const <Duration>[Duration(milliseconds: 100)],
    busyRetryDelays: const <Duration>[Duration(milliseconds: 100)],
    maximumBusyQueueAge: const Duration(seconds: 30),
  );
  var passed = false;
  try {
    await client.initialize();
    await client.saveConfig(
      VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: _fixturePort,
        secret: 'synthetic-queue-validation-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One'],
      ),
    );
    final results = await Future.wait(<Future<bool>>[
      client.sendAgentMessage(
        agent: 'Agent One',
        message: 'run the first synthetic queue validation',
      ),
      client.sendAgentMessage(
        agent: 'Agent One',
        message: 'run the second synthetic queue validation',
      ),
    ]).timeout(const Duration(seconds: 20));
    passed = results.every((sent) => sent) && client.queuedMessageCount == 0;
    debugPrint(
      '[WorkBench][VoiceWebSocketQueueTest] '
      'state=${passed ? 'completed' : 'failed'} '
      'first=${results.first} second=${results.last} '
      'remaining=${client.queuedMessageCount}',
    );
  } on Object catch (error) {
    debugPrint(
      '[WorkBench][VoiceWebSocketQueueTest] '
      'state=failed reason=${error.runtimeType}',
    );
  } finally {
    await client.close();
    await support.delete(recursive: true);
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  exit(passed ? 0 : 1);
}
