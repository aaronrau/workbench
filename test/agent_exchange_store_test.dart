import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/agent_exchange_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-agent-exchange-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test(
    'persists latest acknowledged command and correlated response',
    () async {
      final sent = File('${temp.path}/sent.message.txt')
        ..writeAsStringSync('Pike: validate synthetic fixture\n');
      final received = File('${temp.path}/received.message.txt')
        ..writeAsStringSync('Pike: synthetic result\n');
      final store = AgentExchangeStore(
        supportDirectory: () async => temp,
        now: () => DateTime.utc(2026, 1, 1),
      );
      await store.initialize();
      final id = await store.recordSent(
        agent: 'Pike',
        messagePath: sent.path,
        legacy: false,
        requestId: 'delivery-request',
      );
      expect(
        await store.attachResponse(
          responsePath: received.path,
          kind: 'progress',
          requestId: 'delivery-request',
          agent: 'Pike',
        ),
        id,
      );

      final reopened = AgentExchangeStore(supportDirectory: () async => temp);
      await reopened.initialize();
      final view = await reopened.viewById(id);
      expect(view?.message, 'validate synthetic fixture');
      expect(view?.response, 'Pike: synthetic result');
      expect(view?.responseAt, DateTime.utc(2026, 1, 1));
      expect(view?.responseMessages, hasLength(1));
      expect(view?.responseMessages.single.message, 'Pike: synthetic result');
    },
  );

  test('retains every correlated response update in received order', () async {
    var now = DateTime.utc(2026, 1, 1, 12);
    final sent = File('${temp.path}/sent.message.txt')
      ..writeAsStringSync('Flux: inspect synthetic fixture\n');
    final progress = File('${temp.path}/progress.received.message.txt')
      ..writeAsStringSync('Flux: inspection in progress\n');
    final completed = File('${temp.path}/completed.received.message.txt')
      ..writeAsStringSync('Flux: inspection complete\n');
    final store = AgentExchangeStore(
      supportDirectory: () async => temp,
      now: () => now,
    );
    await store.initialize();
    final id = await store.recordSent(
      agent: 'Flux',
      messagePath: sent.path,
      legacy: false,
      requestId: 'synthetic-request',
    );

    now = now.add(const Duration(seconds: 30));
    await store.attachResponse(
      responsePath: progress.path,
      kind: 'progress',
      requestId: 'synthetic-request',
      agent: 'Flux',
    );
    now = now.add(const Duration(seconds: 30));
    await store.attachResponse(
      responsePath: completed.path,
      kind: 'completed',
      requestId: 'synthetic-request',
      agent: 'Flux',
    );

    final reopened = AgentExchangeStore(supportDirectory: () async => temp);
    await reopened.initialize();
    final view = await reopened.viewById(id);

    expect(view?.responseMessages.map((response) => response.message), <String>[
      'Flux: inspection in progress',
      'Flux: inspection complete',
    ]);
    expect(
      view?.responseMessages.map((response) => response.receivedAt),
      <DateTime>[
        DateTime.utc(2026, 1, 1, 12, 0, 30),
        DateTime.utc(2026, 1, 1, 12, 1),
      ],
    );
    expect(view?.response, 'Flux: inspection complete');
    expect(view?.responseAt, DateTime.utc(2026, 1, 1, 12, 1));

    final messages = await reopened.retainedMessagesForAgents(const <String>[
      'Flux',
    ]);
    expect(
      messages.map((message) => message.direction),
      <AgentMessageDirection>[
        AgentMessageDirection.received,
        AgentMessageDirection.received,
        AgentMessageDirection.sent,
      ],
    );
    expect(messages.every((message) => message.agent == 'Flux'), isTrue);
    expect(messages.last.message, 'inspect synthetic fixture');
  });

  test('loads a legacy single response into timestamped history', () async {
    final workbench = Directory('${temp.path}/workbench')
      ..createSync(recursive: true);
    final sent = File('${temp.path}/legacy.sent.message.txt')
      ..writeAsStringSync('Flux: inspect synthetic fixture\n');
    final response = File('${temp.path}/legacy.received.message.txt')
      ..writeAsStringSync('Flux: legacy synthetic result\n');
    File('${workbench.path}/agent_exchanges.json').writeAsStringSync(
      jsonEncode(<String, Object>{
        'version': 1,
        'legacy_import_complete': true,
        'exchanges': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'legacy-exchange',
            'agent': 'Flux',
            'sent_message_path': sent.path,
            'sent_at': '2026-01-01T12:00:00Z',
            'legacy': false,
            'delivery_request_id': 'synthetic-request',
            'response_path': response.path,
            'response_at': '2026-01-01T12:01:00Z',
            'response_kind': 'completed',
            'pending_summary_request_id': null,
          },
        ],
      }),
    );

    final store = AgentExchangeStore(supportDirectory: () async => temp);
    await store.initialize();
    final view = await store.viewById('legacy-exchange');

    expect(view?.responseMessages, hasLength(1));
    expect(
      view?.responseMessages.single.message,
      'Flux: legacy synthetic result',
    );
    expect(
      view?.responseMessages.single.receivedAt,
      DateTime.utc(2026, 1, 1, 12, 1),
    );
  });

  test(
    'holds a fast summary response until request association is saved',
    () async {
      final sent = File('${temp.path}/sent.message.txt')
        ..writeAsStringSync('Pike: request update\n');
      final response = File('${temp.path}/received.message.txt')
        ..writeAsStringSync('Pike: ready\n');
      final store = AgentExchangeStore(supportDirectory: () async => temp);
      await store.initialize();
      final id = await store.recordSent(
        agent: 'Pike',
        messagePath: sent.path,
        legacy: false,
        requestId: 'delivery-request',
      );

      expect(
        await store.attachResponse(
          responsePath: response.path,
          kind: 'summary',
          requestId: 'summary-request',
          agent: 'Pike',
        ),
        isNull,
      );
      await store.associateSummary(
        exchangeId: id,
        requestId: 'summary-request',
      );

      expect((await store.viewById(id))?.response, 'Pike: ready');
    },
  );

  test(
    'indexes an early response after its sent record supplies the agent',
    () async {
      final response = File('${temp.path}/early.received.message.txt')
        ..writeAsStringSync('Flux: early synthetic result\n');
      final sent = File('${temp.path}/late.sent.message.txt')
        ..writeAsStringSync('Flux: synthetic request\n');
      final store = AgentExchangeStore(supportDirectory: () async => temp);
      await store.initialize();

      expect(
        await store.attachResponse(
          responsePath: response.path,
          kind: 'completed',
          requestId: 'early-request',
        ),
        isNull,
      );
      await store.recordSent(
        agent: 'Flux',
        messagePath: sent.path,
        legacy: false,
        requestId: 'early-request',
      );

      final history = await store.retainedMessagesForAgents(const <String>[
        'Flux',
      ]);
      expect(
        history.map((message) => message.message),
        unorderedEquals(<String>[
          'early synthetic result',
          'synthetic request',
        ]),
      );
    },
  );

  test('serializes concurrent sent and response index snapshots', () async {
    final store = AgentExchangeStore(supportDirectory: () async => temp);
    await store.initialize();

    for (var index = 0; index < 8; index++) {
      final sent = File('${temp.path}/sent-$index.message.txt')
        ..writeAsStringSync('Flux: synthetic request $index\n');
      final received = File('${temp.path}/received-$index.message.txt')
        ..writeAsStringSync('Flux: synthetic response $index\n');
      await Future.wait<String?>(<Future<String?>>[
        store.recordSent(
          agent: 'Flux',
          messagePath: sent.path,
          legacy: false,
          requestId: 'request-$index',
        ),
        store.attachResponse(
          responsePath: received.path,
          kind: 'progress',
          requestId: 'request-$index',
          agent: 'Flux',
        ),
      ]);
    }

    final reopened = AgentExchangeStore(supportDirectory: () async => temp);
    await reopened.initialize();
    final history = await reopened.retainedMessagesForAgents(const <String>[
      'Flux',
    ]);

    expect(history, hasLength(16));
    expect(
      history.map((message) => message.message),
      containsAll(<String>[
        for (var index = 0; index < 8; index++) ...<String>[
          'synthetic request $index',
          'synthetic response $index',
        ],
      ]),
    );
  });

  test('does not attach an unrelated same-agent modern event', () async {
    final sent = File('${temp.path}/sent.message.txt')
      ..writeAsStringSync('Pike: request update\n');
    final response = File('${temp.path}/received.message.txt')
      ..writeAsStringSync('Pike: unrelated\n');
    final store = AgentExchangeStore(supportDirectory: () async => temp);
    await store.initialize();
    final id = await store.recordSent(
      agent: 'Pike',
      messagePath: sent.path,
      legacy: false,
      requestId: 'expected-request',
    );
    await store.attachResponse(
      responsePath: response.path,
      kind: 'progress',
      requestId: 'different-request',
      agent: 'Pike',
    );

    expect((await store.viewById(id))?.response, isNull);
    final history = await store.retainedMessagesForAgents(const <String>[
      'Pike',
    ]);
    expect(
      history.map((message) => message.message),
      <String>['unrelated', 'request update'],
      reason:
          'The event remains independent of the exchange but visible in history.',
    );
  });

  test(
    'recovers every durable sent and received message into history',
    () async {
      final older = File(
        '${temp.path}/workbench-websocket-20260101.sent.message.txt',
      )..writeAsStringSync('Pike: older request\n');
      final newest = File(
        '${temp.path}/workbench-websocket-20260102.sent.message.txt',
      )..writeAsStringSync('Pike: newest request\n');
      final other = File(
        '${temp.path}/workbench-websocket-20260103.sent.message.txt',
      )..writeAsStringSync('Agent Two: other request\n');
      final received = File(
        '${temp.path}/workbench-websocket-20260104.received.message.txt',
      )..writeAsStringSync('Pike: recovered response\n');
      older.setLastModifiedSync(DateTime.utc(2026, 1, 1));
      newest.setLastModifiedSync(DateTime.utc(2026, 1, 2));
      other.setLastModifiedSync(DateTime.utc(2026, 1, 3));
      received.setLastModifiedSync(DateTime.utc(2026, 1, 4));
      final store = AgentExchangeStore(supportDirectory: () async => temp);
      await store.initialize();

      await store.importExistingSentMessages(
        paths: <String>[older.path, newest.path, other.path, received.path]
          ..sort(),
        agents: const <String>['Pike', 'Agent Two'],
        legacy: false,
      );
      final views = await store.latestForAgents(const <String>[
        'Pike',
        'Agent Two',
      ]);

      expect(views, hasLength(2));
      expect(
        views.firstWhere((view) => view.agent == 'Pike').message,
        'newest request',
      );
      expect(
        views.firstWhere((view) => view.agent == 'Agent Two').message,
        'other request',
      );
      final history = await store.retainedMessagesForAgents(const <String>[
        'Pike',
        'Agent Two',
      ]);
      expect(history.map((message) => message.message), <String>[
        'recovered response',
        'other request',
        'newest request',
        'older request',
      ]);
      expect(history.first.direction, AgentMessageDirection.received);

      await store.clear();
      await store.importExistingSentMessages(
        paths: <String>[newest.path],
        agents: const <String>['Pike'],
        legacy: false,
      );
      expect(
        (await store.latestForAgents(const <String>['Pike'])).single.message,
        'newest request',
      );
      expect(
        (await store.retainedMessagesForAgents(const <String>[
          'Pike',
        ])).single.message,
        'newest request',
        reason:
            'Durable files recover even after the performance index clears.',
      );
    },
  );

  test('loads only the five newest exchanges for one selected agent', () async {
    var now = DateTime.utc(2026, 1, 1);
    final store = AgentExchangeStore(
      supportDirectory: () async => temp,
      now: () => now,
    );
    await store.initialize();
    for (var index = 0; index < 6; index++) {
      final sent = File('${temp.path}/pike-$index.sent.message.txt')
        ..writeAsStringSync('Pike: synthetic request $index\n');
      await store.recordSent(
        agent: 'Pike',
        messagePath: sent.path,
        legacy: false,
      );
      now = now.add(const Duration(minutes: 1));
    }
    final other = File('${temp.path}/other.sent.message.txt')
      ..writeAsStringSync('Agent Two: unrelated synthetic request\n');
    await store.recordSent(
      agent: 'Agent Two',
      messagePath: other.path,
      legacy: false,
    );

    final recent = await store.recentForAgent('pike');
    final allRetained = await store.recentForAgent(
      'pike',
      maximumExchanges: AgentExchangeStore.maximumExchanges,
    );

    expect(recent, hasLength(5));
    expect(recent.map((exchange) => exchange.message), <String>[
      'synthetic request 5',
      'synthetic request 4',
      'synthetic request 3',
      'synthetic request 2',
      'synthetic request 1',
    ]);
    expect(allRetained, hasLength(6));
    expect(allRetained.last.message, 'synthetic request 0');
  });

  test('message history outlives the bounded exchange preview cache', () async {
    var now = DateTime.utc(2026, 1, 1);
    final store = AgentExchangeStore(
      supportDirectory: () async => temp,
      now: () => now,
    );
    await store.initialize();

    for (
      var index = 0;
      index < AgentExchangeStore.maximumExchanges + 8;
      index++
    ) {
      final sent = File('${temp.path}/flux-$index.sent.message.txt')
        ..writeAsStringSync('Flux: retained request $index\n');
      await store.recordSent(
        agent: 'Flux',
        messagePath: sent.path,
        legacy: false,
      );
      now = now.add(const Duration(minutes: 1));
    }

    final history = await store.retainedMessagesForAgents(const <String>[
      'Flux',
    ]);
    expect(history, hasLength(AgentExchangeStore.maximumExchanges + 8));
    expect(history.first.message, 'retained request 39');
    expect(history.last.message, 'retained request 0');
  });
}
