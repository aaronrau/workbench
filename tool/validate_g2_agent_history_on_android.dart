import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/agent_exchange_store.dart';
import 'package:even_g2_r1_poc/src/websocket/g2_agent_history_state.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:even_g2_r1_poc/src/websocket/websocket_message_store.dart';
import 'package:flutter/widgets.dart';

const _fixturePort = int.fromEnvironment(
  'WORKBENCH_HISTORY_FIXTURE_PORT',
  defaultValue: 18789,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await Directory.systemTemp.createTemp(
    'workbench-history-validation-',
  );
  final messages = WebSocketMessageStore(supportDirectory: () async => support);
  final exchanges = AgentExchangeStore(supportDirectory: () async => support);
  final summaryReceived = Completer<void>();
  VoiceWebSocketClient? client;
  var passed = false;

  try {
    await messages.initialize();
    await exchanges.initialize();
    client = VoiceWebSocketClient(
      configStore: VoiceWebSocketConfigStore(
        supportDirectory: () async => support,
      ),
      onInboundEvent: (event) async {
        final saved = await messages.save(
          direction: WebSocketMessageDirection.received,
          message: event.message,
        );
        await exchanges.attachResponse(
          responsePath: saved.path,
          kind: event.kind.name,
          requestId: event.requestId,
          agent: event.agent,
        );
        if (event.kind == VoiceWebSocketInboundKind.summary &&
            !summaryReceived.isCompleted) {
          summaryReceived.complete();
        }
      },
      readyTimeout: const Duration(seconds: 5),
      acknowledgementTimeout: const Duration(seconds: 5),
      reconnectDelays: const <Duration>[Duration(milliseconds: 100)],
    );
    await client.initialize();
    await client.saveConfig(
      VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: _fixturePort,
        secret: 'synthetic-fixture-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>[
          'Pike',
          'Agent Two',
          'Agent Three',
          'Agent Four',
          'Agent Five',
        ],
      ),
    );

    final delivery = await client
        .sendAgentMessageWithResult(
          agent: 'Pike',
          message: 'validate the isolated selector flow',
        )
        .timeout(const Duration(seconds: 10));
    if (!delivery.sent || delivery.requestId == null) {
      throw StateError('Synthetic Pike delivery was not acknowledged.');
    }
    final sent = await messages.save(
      direction: WebSocketMessageDirection.sent,
      message: 'Pike: validate the isolated selector flow',
    );
    final exchangeId = await exchanges.recordSent(
      agent: delivery.agent,
      messagePath: sent.path,
      legacy: delivery.legacy,
      requestId: delivery.requestId,
    );

    final state = G2AgentHistoryState();
    state.open(
      agents: client.config.agentNames,
      exchanges: await exchanges.latestForAgents(client.config.agentNames),
      memo: 'Synthetic Memo is available on the device.',
    );
    final dismissFirst =
        state.selected?.kind == G2AgentHistoryEntryKind.dismiss;
    state.selectNext();
    final memoSelected = state.selected?.kind == G2AgentHistoryEntryKind.memo;
    state.showSelectedDetail();
    final memoDisplayed = state.render().contains('Synthetic Memo');
    state.close();

    state.open(
      agents: client.config.agentNames,
      exchanges: await exchanges.latestForAgents(client.config.agentNames),
      memo: 'Synthetic Memo is available on the device.',
    );
    state
      ..selectNext()
      ..selectNext();
    final pike = state.selected?.exchange;
    if (pike == null || pike.id != exchangeId || pike.response != null) {
      throw StateError('Synthetic Pike row was not ready for summary.');
    }
    state.showWaiting(pike);
    final summary = await client
        .requestAgentSummary(pike.agent)
        .timeout(const Duration(seconds: 10));
    if (summary.outcome != VoiceWebSocketSummaryRequestOutcome.sent) {
      throw StateError('Synthetic Pike summary was not sent.');
    }
    await summaryReceived.future.timeout(const Duration(seconds: 10));
    await exchanges.associateSummary(
      exchangeId: exchangeId,
      requestId: summary.requestId,
    );
    final updated = await exchanges.viewById(exchangeId);
    final responseMatched =
        updated?.response != null &&
        state.acceptResponse(exchangeId, updated!.response!);
    final responseDisplayed = state.render().contains('progress summary');
    state.close();

    passed =
        dismissFirst &&
        memoSelected &&
        memoDisplayed &&
        state.mode == G2AgentHistoryMode.closed &&
        responseMatched &&
        responseDisplayed;
    debugPrint(
      '[WorkBench][AgentHistoryDeviceTest] '
      'state=${passed ? 'completed' : 'failed'} '
      'agents=5 dismiss_first=$dismissFirst memo=$memoDisplayed '
      'pike_response=$responseDisplayed',
    );
  } on Object catch (error) {
    debugPrint(
      '[WorkBench][AgentHistoryDeviceTest] '
      'state=failed reason=${error.runtimeType}',
    );
  } finally {
    try {
      await client?.close();
    } on Object {
      // Cleanup is best effort after an earlier validation failure.
    }
    await support.delete(recursive: true);
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  exit(passed ? 0 : 1);
}
