import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/wearable_controller.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:flutter/widgets.dart';

const _fixturePort = int.fromEnvironment(
  'WORKBENCH_SUMMARY_FIXTURE_PORT',
  defaultValue: 18788,
);
const _expectedSummary = 'Agent One: Synthetic progress summary from fixture.';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await Directory.systemTemp.createTemp(
    'workbench-summary-validation-',
  );
  final inbound = Completer<String>();
  final client = VoiceWebSocketClient(
    configStore: VoiceWebSocketConfigStore(
      supportDirectory: () async => support,
    ),
    onInboundMessage: (message) async {
      if (message == _expectedSummary && !inbound.isCompleted) {
        inbound.complete(message);
      }
    },
    readyTimeout: const Duration(seconds: 5),
    acknowledgementTimeout: const Duration(seconds: 5),
    reconnectDelays: const <Duration>[Duration(milliseconds: 100)],
  );
  var passed = false;
  try {
    final gestureAction = resolveWearableGestureAction(
      gestureType: 3,
      memoActive: false,
    );
    await client.initialize();
    await client.saveConfig(
      VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: _fixturePort,
        secret: 'synthetic-summary-validation-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One'],
      ),
    );
    final commandSent = await client
        .sendAgentMessage(
          agent: 'Agent One',
          message: 'run the synthetic summary validation',
        )
        .timeout(const Duration(seconds: 10));
    final summaryOutcome = await client.requestLastSentAgentSummary().timeout(
      const Duration(seconds: 10),
    );
    final summary = await inbound.future.timeout(const Duration(seconds: 10));
    passed =
        gestureAction == WearableGestureAction.requestAgentSummary &&
        commandSent &&
        client.lastSentAgent == 'Agent One' &&
        summaryOutcome == VoiceWebSocketSummaryRequestOutcome.sent &&
        summary == _expectedSummary;
    debugPrint(
      '[WorkBench][VoiceWebSocketSummaryTest] '
      'state=${passed ? 'completed' : 'failed'} '
      'gesture=${gestureAction.name} command_sent=$commandSent '
      'request=${summaryOutcome.name} response_received=${summary.isNotEmpty}',
    );
  } on Object catch (error) {
    debugPrint(
      '[WorkBench][VoiceWebSocketSummaryTest] '
      'state=failed reason=${error.runtimeType}',
    );
  } finally {
    await client.close();
    await support.delete(recursive: true);
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  exit(passed ? 0 : 1);
}
