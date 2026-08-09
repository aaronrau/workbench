import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:even_g2_r1_poc/src/websocket/websocket_message_store.dart';
import 'package:even_g2_r1_poc/src/websocket/g2_agent_history_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late List<WebSocket> serverSockets;
  late List<Map<String, dynamic>> received;
  late List<String?> authorizationHeaders;
  late Completer<Map<String, dynamic>> resumed;
  late bool closeFirstModernRequestBeforeAcknowledgement;
  late int closedModernRequestCount;
  late int modernRouteCount;
  late Map<String, Map<String, Object?>> acceptedByRequestId;
  late Map<String, int> busyResponsesRemaining;
  late Map<String, int> ignoredResponsesRemaining;
  late Set<String> alwaysBusyMessages;
  late Set<String> negativeAcknowledgementBusyMessages;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync(
      'workbench-voice-websocket-client-test-',
    );
    serverSockets = <WebSocket>[];
    received = <Map<String, dynamic>>[];
    authorizationHeaders = <String?>[];
    resumed = Completer<Map<String, dynamic>>();
    closeFirstModernRequestBeforeAcknowledgement = false;
    closedModernRequestCount = 0;
    modernRouteCount = 0;
    acceptedByRequestId = <String, Map<String, Object?>>{};
    busyResponsesRemaining = <String, int>{};
    ignoredResponsesRemaining = <String, int>{};
    alwaysBusyMessages = <String>{};
    negativeAcknowledgementBusyMessages = <String>{};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      authorizationHeaders.add(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      final socket = await WebSocketTransformer.upgrade(request);
      serverSockets.add(socket);
      socket.listen((data) async {
        if (data is! String) {
          return;
        }
        final payload = jsonDecode(data) as Map<String, dynamic>;
        received.add(payload);
        if (payload['type'] == 'message.send') {
          final requestId = payload['request_id'] as String;
          final previous = acceptedByRequestId[requestId];
          if (previous != null) {
            socket.add(jsonEncode(previous));
            return;
          }
          final message = payload['message'] as String;
          final remainingBusyResponses = busyResponsesRemaining[message] ?? 0;
          if (alwaysBusyMessages.contains(message) ||
              remainingBusyResponses > 0) {
            modernRouteCount++;
            if (remainingBusyResponses > 0) {
              busyResponsesRemaining[message] = remainingBusyResponses - 1;
            }
            socket.add(
              jsonEncode(
                negativeAcknowledgementBusyMessages.contains(message)
                    ? _busyAcknowledgementPayload(payload)
                    : _busyPayload(payload),
              ),
            );
            return;
          }
          final remainingIgnoredResponses =
              ignoredResponsesRemaining[message] ?? 0;
          if (remainingIgnoredResponses > 0) {
            modernRouteCount++;
            ignoredResponsesRemaining[message] = remainingIgnoredResponses - 1;
            return;
          }
          if (closeFirstModernRequestBeforeAcknowledgement &&
              closedModernRequestCount == 0) {
            closedModernRequestCount++;
            modernRouteCount++;
            acceptedByRequestId[requestId] = _acceptedPayload(payload);
            await socket.close();
            return;
          }
          modernRouteCount++;
          final response = _acceptedPayload(payload);
          acceptedByRequestId[requestId] = response;
          socket.add(jsonEncode(response));
        } else if (payload['type'] == 'summary.request') {
          socket.add(
            jsonEncode(<String, Object?>{
              'type': 'summary.result',
              'request_id': payload['request_id'],
              'ok': true,
              'result': <String, Object?>{
                'agent': payload['agent'],
                'summary': 'The requested fixture is still running.',
                'detail': 'Synthetic fixture detail.',
                'detail_lines': <String>['Synthetic fixture detail.'],
                'source': 'tmux_capture',
              },
            }),
          );
        } else if (payload['type'] == 'connection.resume' &&
            !resumed.isCompleted) {
          resumed.complete(payload);
        }
      });
      socket.add(
        jsonEncode(<String, Object>{
          'type': 'connection.ready',
          'version': 1,
          'server_session_id': 'example-session',
          'agents': <String>['Agent One'],
          'agent_controls': <String>['Agent One clear terminal'],
          'session_controls': <String>['Session terminate'],
          'websocket_path': '/ws',
        }),
      );
    });
  });

  tearDown(() async {
    for (final socket in serverSockets) {
      await socket.close();
    }
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  test('authenticates, waits for ready and acknowledgement, displays inbound, '
      'then resumes after reconnect', () async {
    final inbound = <String>[];
    final store = VoiceWebSocketConfigStore(supportDirectory: () async => temp);
    final client = VoiceWebSocketClient(
      configStore: store,
      reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
      readyTimeout: const Duration(seconds: 1),
      acknowledgementTimeout: const Duration(seconds: 1),
      onInboundMessage: (message) async => inbound.add(message),
    );
    addTearDown(client.close);
    await client.initialize();
    final config = VoiceWebSocketConfig.validate(
      host: '127.0.0.1',
      port: server.port,
      secret: 'example-secret',
      authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
      agentNames: const <String>['Agent One', 'Agent Two', 'Flux'],
      useLegacyMessageShape: false,
    );
    await client.saveConfig(config);
    await _waitUntil(() => client.isReady);

    expect(authorizationHeaders.single, 'Bearer example-secret');
    expect(received, isEmpty, reason: 'No client hello is allowed.');
    expect(client.serverAgents, <String>['Agent One']);
    expect(client.agentControls, <String>['Agent One clear terminal']);
    expect(client.sessionControls, <String>['Session terminate']);

    final route = client.routeForTranscript(
      'Agent One, pull the latest changes',
    );
    expect(route?.agent, 'Agent One');
    expect(route?.message, 'pull the latest changes');
    final conversationalRoute = client.routeForTranscript(
      'Hey Flux, pull the latestest changes',
    );
    expect(conversationalRoute?.agent, 'Flux');
    expect(
      conversationalRoute?.message,
      'Hey Flux, pull the latestest changes',
      reason:
          'An agent named in conversational context keeps the full request.',
    );
    expect(
      client.routeForTranscript('An agent oneness task'),
      isNull,
      reason: 'Agent names must match a complete phrase.',
    );
    final leadingAttentionCorrection = client.routeForTranscript(
      'Flux, pull the latest changes',
      evidenceTranscript: 'Hey, pull the latest changes',
    );
    expect(leadingAttentionCorrection?.agent, 'Flux');
    expect(
      leadingAttentionCorrection?.message,
      'pull the latest changes',
      reason:
          'A complete leading Hey allows correction to recover a misheard target.',
    );
    expect(
      client.routeForTranscript(
        'Flux, pull the latest changes',
        evidenceTranscript: 'Plus, pull the latest changes',
      ),
      isNull,
      reason: 'A bare acoustic alias is not enough to invoke an agent.',
    );
    final aliasedCorrection = client.routeForTranscript(
      'Flux, pull the latest changes',
      evidenceTranscript: 'Hey flex, pull the latest changes',
    );
    expect(aliasedCorrection?.agent, 'Flux');
    final evidencedCorrection = client.routeForTranscript(
      'Flux, pull the latest changes',
      evidenceTranscript: 'flux pull latest changes',
    );
    expect(
      evidencedCorrection,
      isNull,
      reason: 'A live corrected route requires a leading Hey.',
    );
    expect(
      client.routeForTranscript(
        'Flux, pull the latest changes',
        evidenceTranscript: 'Please, hey Flux, pull the latest changes',
      ),
      isNull,
      reason: 'A mid-sentence Hey cannot activate an agent.',
    );
    expect(
      client.routeForTranscript(
        'Flux, pull the latest changes',
        evidenceTranscript: 'Heyday Flux, pull the latest changes',
      ),
      isNull,
      reason: 'Hey must be recognized as a complete word.',
    );
    final detail = G2AgentHistoryState()
      ..open(agents: config.agentNames, exchanges: const [])
      ..selectNext()
      ..selectNext()
      ..selectNext()
      ..showSelectedDetail()
      ..selectDetailListenMode();
    expect(detail.selectedSpeechAgent, 'Flux');
    expect(
      detail.render(),
      startsWith(
        '   [Flux · Listening] - Tap to stop\n'
        ' <  • Listen Mode - Tap to stop\n',
      ),
    );
    final selectedAgentRoute = client.routeTranscriptToSelectedAgent(
      selectedAgent: detail.selectedSpeechAgent!,
      transcript: 'pull the latest changes',
    );
    expect(selectedAgentRoute?.agent, 'Flux');
    expect(selectedAgentRoute?.message, 'pull the latest changes');
    expect(
      client.routeTranscriptToSelectedAgent(
        selectedAgent: 'Agent Not Configured',
        transcript: 'pull the latest changes',
      ),
      isNull,
      reason: 'A stale menu selection cannot bypass current configuration.',
    );
    expect(
      client.routeTranscriptToSelectedAgent(
        selectedAgent: 'Flux',
        transcript: '   ',
      ),
      isNull,
    );

    final sent = await client.sendTranscript(
      'Agent One, pull the latest changes',
    );
    expect(sent, isTrue);
    final send = received.single;
    expect(send['type'], 'message.send');
    expect(send['request_id'], isNotEmpty);
    expect(send['agent'], 'Agent One');
    expect(send['message'], 'pull the latest changes');

    final rejected = await client.sendAgentMessage(
      agent: 'Agent Two',
      message: 'run a rejected fixture request',
    );
    expect(rejected, isFalse);

    serverSockets.single.add(
      jsonEncode(<String, Object>{
        'type': 'message.progress',
        'event_id': 42,
        'agent': 'Agent One',
        'request_id': 'example-request',
        'payload': <String, Object>{
          'agent': 'Agent One',
          'summary': 'The requested task is still running.',
          'detail_lines': <String>['Private detail is not the summary.'],
          'phase': 'in_progress',
          'is_final': false,
        },
      }),
    );
    await _waitUntil(() => inbound.isNotEmpty);
    expect(inbound.single, 'Agent One: The requested task is still running.');

    serverSockets.single.add(
      jsonEncode(<String, Object>{
        'type': 'message.completed',
        'event_id': 43,
        'agent': 'Agent One',
        'request_id': 'example-request',
        'payload': <String, Object>{
          'agent': 'Agent One',
          'completion_message': 'The requested task completed.',
          'phase': 'final',
          'is_final': true,
        },
      }),
    );
    await _waitUntil(() => inbound.length == 2);
    expect(inbound.last, 'Agent One: The requested task completed.');
    await _waitUntil(
      () =>
          received.where((payload) => payload['type'] == 'event.ack').length ==
          2,
    );
    expect(
      received
          .where((payload) => payload['type'] == 'event.ack')
          .map((payload) => payload['event_id']),
      <int>[42, 43],
    );

    await serverSockets.single.close();
    await _waitUntil(() => serverSockets.length == 2);
    final resume = await resumed.future.timeout(const Duration(seconds: 2));
    expect(resume, <String, dynamic>{
      'type': 'connection.resume',
      'resume_after_event_id': 43,
    });
  });

  test('atomically saves every readable received socket message', () async {
    final messageStore = WebSocketMessageStore(
      supportDirectory: () async => temp,
    );
    await messageStore.initialize();
    final savedMessages = <String>[];
    final fourMessagesSaved = Completer<void>();
    final configStore = VoiceWebSocketConfigStore(
      supportDirectory: () async => temp,
    );
    final client = VoiceWebSocketClient(
      configStore: configStore,
      reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
      readyTimeout: const Duration(seconds: 1),
      onInboundEvent: (event) async {
        await messageStore.save(
          direction: WebSocketMessageDirection.received,
          message: event.message,
        );
        savedMessages.add(event.message);
        if (savedMessages.length == 4 && !fourMessagesSaved.isCompleted) {
          fourMessagesSaved.complete();
        }
      },
    );
    addTearDown(client.close);
    await client.initialize();
    await client.saveConfig(
      VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: server.port,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One'],
        useLegacyMessageShape: false,
      ),
    );
    await _waitUntil(() => client.isReady);

    serverSockets.single
      ..add('Plain synthetic update.')
      ..add(jsonEncode('JSON synthetic update.'))
      ..add(
        jsonEncode(<String, Object>{
          'type': 'message.progress',
          'event_id': 501,
          'agent': 'Agent One',
          'payload': <String, Object>{'summary': 'Synthetic progress update.'},
        }),
      )
      ..add(
        jsonEncode(<String, Object>{
          'type': 'message.error',
          'request_id': 'unmatched-synthetic-request',
          'message': 'Synthetic socket error update.',
        }),
      );

    await fourMessagesSaved.future.timeout(const Duration(seconds: 10));

    expect(savedMessages, <String>[
      'Plain synthetic update.',
      'JSON synthetic update.',
      'Agent One: Synthetic progress update.',
      'Synthetic socket error update.',
    ]);
    final paths = await messageStore.savedPaths();
    expect(paths, hasLength(4));
    for (final path in paths) {
      expect(path, endsWith('.received.message.txt'));
      expect(await File(path).readAsString(), isNotEmpty);
    }
  });

  test(
    'does not acknowledge an inbound event when durable delivery fails',
    () async {
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      final client = VoiceWebSocketClient(
        configStore: store,
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        readyTimeout: const Duration(seconds: 1),
        onInboundMessage: (_) async {
          throw FileSystemException('Fixture persistence failure');
        },
      );
      addTearDown(client.close);
      await client.initialize();
      await client.saveConfig(
        VoiceWebSocketConfig.validate(
          host: '127.0.0.1',
          port: server.port,
          secret: 'example-secret',
          authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
          agentNames: const <String>['Agent One'],
          useLegacyMessageShape: false,
        ),
      );
      await _waitUntil(() => client.isReady);

      serverSockets.single.add(
        jsonEncode(<String, Object>{
          'type': 'message.completed',
          'event_id': 91,
          'agent': 'Agent One',
          'payload': <String, Object>{
            'summary': 'A response that could not be stored.',
          },
        }),
      );

      await _waitUntil(() => serverSockets.length == 2);
      expect(
        received.where(
          (payload) =>
              payload['type'] == 'event.ack' && payload['event_id'] == 91,
        ),
        isEmpty,
      );
      expect(
        received.where((payload) => payload['type'] == 'connection.resume'),
        isEmpty,
      );
    },
  );

  test(
    'sends the exact legacy agent and message shape when selected',
    () async {
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      final client = VoiceWebSocketClient(
        configStore: store,
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        readyTimeout: const Duration(seconds: 1),
      );
      addTearDown(client.close);
      await client.initialize();
      await client.saveConfig(
        VoiceWebSocketConfig.validate(
          host: '127.0.0.1',
          port: server.port,
          secret: 'example-secret',
          authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
          agentNames: const <String>['Agent One'],
          useLegacyMessageShape: true,
        ),
      );
      await _waitUntil(() => client.isReady);

      final sent = await client.sendTranscript('Agent One, run the check');
      await _waitUntil(() => received.isNotEmpty);

      expect(sent, isTrue);
      expect(received.single, <String, dynamic>{
        'agent': 'Agent One',
        'message': 'run the check',
      });

      final summary = await client.requestLastSentAgentSummary();
      await _waitUntil(() => received.length == 2);

      expect(summary, VoiceWebSocketSummaryRequestOutcome.sent);
      expect(received.last, <String, dynamic>{
        'type': 'local',
        'agent': 'Agent One',
        'message': 'progress_summary',
      });
    },
  );

  test(
    'requests a summary for only the last acknowledged modern agent',
    () async {
      final inbound = <String>[];
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      final client = VoiceWebSocketClient(
        configStore: store,
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        readyTimeout: const Duration(seconds: 1),
        acknowledgementTimeout: const Duration(seconds: 1),
        onInboundMessage: (message) async => inbound.add(message),
      );
      addTearDown(client.close);
      await client.initialize();
      final config = VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: server.port,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One', 'Agent Two'],
        useLegacyMessageShape: false,
      );
      await client.saveConfig(config);
      await _waitUntil(() => client.isReady);

      expect(
        await client.requestLastSentAgentSummary(),
        VoiceWebSocketSummaryRequestOutcome.noSentAgent,
      );
      expect(received, isEmpty);

      expect(
        await client.sendAgentMessage(
          agent: 'Agent One',
          message: 'run the accepted fixture',
        ),
        isTrue,
      );
      expect(client.lastSentAgent, 'Agent One');
      expect(
        await client.sendAgentMessage(
          agent: 'Agent Two',
          message: 'run the rejected fixture',
        ),
        isFalse,
      );
      expect(
        client.lastSentAgent,
        'Agent One',
        reason: 'A rejected send must not replace the last successful agent.',
      );

      expect(
        await client.requestLastSentAgentSummary(),
        VoiceWebSocketSummaryRequestOutcome.sent,
      );
      await _waitUntil(
        () => received.any((payload) => payload['type'] == 'summary.request'),
      );
      final request = received.lastWhere(
        (payload) => payload['type'] == 'summary.request',
      );
      expect(
        request['request_id'],
        isA<String>().having((value) => value, 'request id', isNotEmpty),
      );
      expect(request['agent'], 'Agent One');
      expect(request.keys.toSet(), <String>{'type', 'request_id', 'agent'});
      await _waitUntil(() => inbound.isNotEmpty);
      expect(
        inbound.single,
        'Agent One: The requested fixture is still running.',
      );

      await client.saveConfig(config);
      await _waitUntil(() => client.isReady);
      expect(client.lastSentAgent, isNull);
      expect(
        await client.requestLastSentAgentSummary(),
        VoiceWebSocketSummaryRequestOutcome.noSentAgent,
      );
    },
  );

  test('exposes request IDs for exact send and summary correlation', () async {
    final inbound = Completer<VoiceWebSocketInboundEvent>();
    final store = VoiceWebSocketConfigStore(supportDirectory: () async => temp);
    final client = VoiceWebSocketClient(
      configStore: store,
      reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
      readyTimeout: const Duration(seconds: 1),
      acknowledgementTimeout: const Duration(seconds: 1),
      onInboundEvent: (event) async {
        if (event.kind == VoiceWebSocketInboundKind.summary &&
            !inbound.isCompleted) {
          inbound.complete(event);
        }
      },
    );
    addTearDown(client.close);
    await client.initialize();
    await client.saveConfig(
      VoiceWebSocketConfig.validate(
        host: '127.0.0.1',
        port: server.port,
        secret: 'example-secret',
        authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
        agentNames: const <String>['Agent One'],
        useLegacyMessageShape: false,
      ),
    );
    await _waitUntil(() => client.isReady);

    final send = await client.sendAgentMessageWithResult(
      agent: 'Agent One',
      message: 'run the correlated fixture',
    );
    final summary = await client.requestAgentSummary('Agent One');
    final event = await inbound.future.timeout(const Duration(seconds: 1));

    expect(send.sent, isTrue);
    expect(send.requestId, isNotEmpty);
    expect(send.legacy, isFalse);
    expect(summary.outcome, VoiceWebSocketSummaryRequestOutcome.sent);
    expect(summary.requestId, isNotEmpty);
    expect(event.requestId, summary.requestId);
    expect(event.agent, 'Agent One');
    expect(event.kind, VoiceWebSocketInboundKind.summary);
  });

  test(
    'reconnects and reuses the request id when acknowledgement is lost',
    () async {
      closeFirstModernRequestBeforeAcknowledgement = true;
      final store = VoiceWebSocketConfigStore(
        supportDirectory: () async => temp,
      );
      final client = VoiceWebSocketClient(
        configStore: store,
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        readyTimeout: const Duration(seconds: 1),
        acknowledgementTimeout: const Duration(seconds: 1),
      );
      addTearDown(client.close);
      await client.initialize();
      await client.saveConfig(
        VoiceWebSocketConfig.validate(
          host: '127.0.0.1',
          port: server.port,
          secret: 'example-secret',
          authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
          agentNames: const <String>['Flux'],
          useLegacyMessageShape: false,
        ),
      );
      await _waitUntil(() => client.isReady);

      final sent = await client.sendAgentMessage(
        agent: 'Flux',
        message: 'pull the latest changes',
      );
      final sends = received
          .where((payload) => payload['type'] == 'message.send')
          .toList(growable: false);

      expect(sent, isTrue);
      expect(serverSockets, hasLength(2));
      expect(sends, hasLength(2));
      expect(sends[0]['request_id'], isNotEmpty);
      expect(sends[1]['request_id'], sends[0]['request_id']);
      expect(sends[1]['agent'], 'Flux');
      expect(sends[1]['message'], 'pull the latest changes');
      expect(modernRouteCount, 1);
    },
  );

  test('keeps a timed-out queued delivery and reuses its request id', () async {
    const message = 'run the acknowledgement retry fixture';
    ignoredResponsesRemaining[message] = 2;
    final client = await _configuredClient(
      temp: temp,
      serverPort: server.port,
      acknowledgementTimeout: const Duration(milliseconds: 30),
      busyRetryDelays: const <Duration>[Duration(milliseconds: 20)],
      maximumBusyQueueAge: const Duration(seconds: 2),
    );
    addTearDown(client.close);

    final resultFuture = client.sendAgentMessageWithResult(
      agent: 'Agent One',
      message: message,
    );
    final result = await resultFuture.timeout(const Duration(seconds: 2));
    final sends = received
        .where(
          (payload) =>
              payload['type'] == 'message.send' &&
              payload['message'] == message,
        )
        .toList(growable: false);

    expect(result.sent, isTrue);
    expect(sends, hasLength(3));
    expect(
      sends.map((payload) => payload['request_id']).toSet(),
      hasLength(1),
      reason: 'An ambiguous retry must remain idempotent.',
    );
    expect(client.queuedMessageCount, 0);
  });

  test('queues busy commands and preserves FIFO order', () async {
    const firstMessage = 'run the first queued fixture';
    const secondMessage = 'run the second queued fixture';
    busyResponsesRemaining[firstMessage] = 2;
    final client = await _configuredClient(
      temp: temp,
      serverPort: server.port,
      busyRetryDelays: const <Duration>[Duration(milliseconds: 10)],
    );
    addTearDown(client.close);

    final first = client.sendAgentMessage(
      agent: 'Agent One',
      message: firstMessage,
    );
    final second = client.sendAgentMessage(
      agent: 'Agent One',
      message: secondMessage,
    );

    expect(await Future.wait(<Future<bool>>[first, second]), <bool>[
      true,
      true,
    ]);
    final sends = received
        .where((payload) => payload['type'] == 'message.send')
        .toList(growable: false);
    expect(sends.map((payload) => payload['message']), <String>[
      firstMessage,
      firstMessage,
      firstMessage,
      secondMessage,
    ]);
    expect(
      sends
          .where((payload) => payload['message'] == firstMessage)
          .map((payload) => payload['request_id'])
          .toSet(),
      hasLength(3),
      reason: 'Each explicit busy rejection starts a new delivery attempt.',
    );
    expect(client.queuedMessageCount, 0);
    expect(client.statusText, 'Connected · 1 server agents');
  });

  test('selected-agent delivery reuses the socket and retries busy', () async {
    const selectedMessage = 'send directly to the selected agent';
    busyResponsesRemaining[selectedMessage] = 1;
    final client = await _configuredClient(
      temp: temp,
      serverPort: server.port,
      busyRetryDelays: const <Duration>[Duration(minutes: 1)],
      agentNames: const <String>['Agent One', 'Flux'],
    );
    addTearDown(client.close);

    final detail = G2AgentHistoryState()
      ..open(agents: client.config.agentNames, exchanges: const [])
      ..selectNext()
      ..selectNext()
      ..showSelectedDetail()
      ..selectDetailListenMode();
    expect(detail.selectedSpeechAgent, 'Flux');
    expect(
      detail.render(),
      startsWith(
        '   [Flux · Listening] - Tap to stop\n'
        ' <  • Listen Mode - Tap to stop\n',
      ),
    );
    final selectedRoute = client.routeTranscriptToSelectedAgent(
      selectedAgent: detail.selectedSpeechAgent!,
      transcript: selectedMessage,
    );
    expect(selectedRoute?.agent, 'Flux');

    final selectedFuture = client.sendAgentMessageWithResult(
      agent: selectedRoute!.agent,
      message: selectedRoute.message,
      deliveryMode: VoiceWebSocketDeliveryMode.queued,
    );
    await _waitUntil(() => client.statusText.contains('agent busy'));
    expect(client.queuedMessageCount, 1);

    serverSockets.single.add(
      jsonEncode(<String, Object>{
        'type': 'message.completed',
        'event_id': 10,
        'agent': 'Flux',
        'payload': <String, Object>{
          'summary': 'The selected-agent fixture completed.',
        },
      }),
    );

    final selected = await selectedFuture.timeout(const Duration(seconds: 1));

    expect(selected.sent, isTrue);
    expect(selected.requestId, isNotEmpty);
    expect(client.queuedMessageCount, 0);
    expect(
      serverSockets,
      hasLength(1),
      reason: 'A busy retry must reuse the existing ready WebSocket.',
    );
    expect(
      received
          .where((payload) => payload['type'] == 'message.send')
          .map((payload) => (payload['agent'], payload['message'])),
      <(Object?, Object?)>[
        ('Flux', selectedMessage),
        ('Flux', selectedMessage),
      ],
    );
  });

  test(
    'immediate delivery returns an agent-busy result without queuing',
    () async {
      const message = 'do not queue the selected-agent fixture';
      alwaysBusyMessages.add(message);
      final client = await _configuredClient(
        temp: temp,
        serverPort: server.port,
        busyRetryDelays: const <Duration>[Duration(minutes: 1)],
      );
      addTearDown(client.close);

      final result = await client
          .sendAgentMessageWithResult(
            agent: 'Agent One',
            message: message,
            deliveryMode: VoiceWebSocketDeliveryMode.immediate,
          )
          .timeout(const Duration(seconds: 1));

      expect(result.sent, isFalse);
      expect(result.requestId, isNull);
      expect(client.queuedMessageCount, 0);
      expect(
        received.where((payload) => payload['type'] == 'message.send'),
        hasLength(1),
      );
    },
  );

  test('a completion event wakes the busy queue before its backoff', () async {
    const message = 'run after the current fixture completes';
    busyResponsesRemaining[message] = 1;
    final client = await _configuredClient(
      temp: temp,
      serverPort: server.port,
      busyRetryDelays: const <Duration>[Duration(minutes: 1)],
    );
    addTearDown(client.close);

    final sent = client.sendAgentMessage(agent: 'Agent One', message: message);
    await _waitUntil(() => client.statusText.contains('agent busy'));

    serverSockets.single.add(
      jsonEncode(<String, Object>{
        'type': 'message.completed',
        'event_id': 7,
        'agent': 'Agent One',
        'payload': <String, Object>{
          'summary': 'The previous fixture completed.',
        },
      }),
    );

    expect(
      await sent.timeout(const Duration(seconds: 1)),
      isTrue,
      reason: 'Completion should wake the queue without waiting one minute.',
    );
    expect(
      received.where((payload) => payload['type'] == 'message.send'),
      hasLength(2),
    );
  });

  test('an unrelated completion does not wake the busy queue', () async {
    const message = 'wait for the matching agent to complete';
    busyResponsesRemaining[message] = 1;
    final client = await _configuredClient(
      temp: temp,
      serverPort: server.port,
      busyRetryDelays: const <Duration>[Duration(minutes: 1)],
    );
    addTearDown(client.close);

    var completed = false;
    final sent = client.sendAgentMessage(agent: 'Agent One', message: message);
    unawaited(sent.then((_) => completed = true));
    await _waitUntil(() => client.statusText.contains('agent busy'));

    serverSockets.single.add(
      jsonEncode(<String, Object>{
        'type': 'message.completed',
        'event_id': 8,
        'agent': 'Agent Two',
        'payload': <String, Object>{
          'summary': 'An unrelated fixture completed.',
        },
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(completed, isFalse);
    expect(
      received.where((payload) => payload['type'] == 'message.send'),
      hasLength(1),
    );

    serverSockets.single.add(
      jsonEncode(<String, Object>{
        'type': 'message.completed',
        'event_id': 9,
        'agent': 'Agent One',
        'payload': <String, Object>{
          'summary': 'The matching fixture completed.',
        },
      }),
    );

    expect(await sent.timeout(const Duration(seconds: 1)), isTrue);
  });

  test('queues agent_busy from a negative acknowledgement', () async {
    const message = 'run after a negative busy acknowledgement';
    busyResponsesRemaining[message] = 1;
    negativeAcknowledgementBusyMessages.add(message);
    final client = await _configuredClient(temp: temp, serverPort: server.port);
    addTearDown(client.close);

    final sent = await client.sendAgentMessage(
      agent: 'Agent One',
      message: message,
    );

    expect(sent, isTrue);
    expect(
      received.where((payload) => payload['type'] == 'message.send'),
      hasLength(2),
    );
  });

  test('expires a perpetually busy queue item without getting stuck', () async {
    const message = 'run an expiring busy fixture';
    alwaysBusyMessages.add(message);
    final client = await _configuredClient(
      temp: temp,
      serverPort: server.port,
      maximumBusyQueueAge: const Duration(milliseconds: 60),
      busyRetryDelays: const <Duration>[Duration(milliseconds: 10)],
    );
    addTearDown(client.close);

    final sent = await client
        .sendAgentMessage(agent: 'Agent One', message: message)
        .timeout(const Duration(seconds: 1));

    expect(sent, isFalse);
    expect(client.queuedMessageCount, 0);
    expect(
      received.where((payload) => payload['type'] == 'message.send').length,
      greaterThanOrEqualTo(2),
    );
  });

  test(
    'configuration changes cancel the busy queue before reconnecting',
    () async {
      const message = 'cancel this busy fixture during configuration';
      alwaysBusyMessages.add(message);
      final client = await _configuredClient(
        temp: temp,
        serverPort: server.port,
        busyRetryDelays: const <Duration>[Duration(minutes: 1)],
      );
      addTearDown(client.close);

      final sent = client.sendAgentMessage(
        agent: 'Agent One',
        message: message,
      );
      await _waitUntil(() => client.statusText.contains('agent busy'));

      await client.saveConfig(client.config);

      expect(await sent, isFalse);
      expect(client.queuedMessageCount, 0);
      await _waitUntil(() => client.isReady);
      expect(client.statusText, 'Connected · 1 server agents');
    },
  );

  test('bounds the busy queue and cancels it on close', () async {
    const firstMessage = 'run the retained busy fixture';
    alwaysBusyMessages.add(firstMessage);
    final client = await _configuredClient(
      temp: temp,
      serverPort: server.port,
      maximumQueuedMessages: 1,
      busyRetryDelays: const <Duration>[Duration(minutes: 1)],
    );

    final first = client.sendAgentMessage(
      agent: 'Agent One',
      message: firstMessage,
    );
    await _waitUntil(() => client.statusText.contains('agent busy'));
    final overflow = await client.sendAgentMessage(
      agent: 'Agent One',
      message: 'run the overflow fixture',
    );

    expect(overflow, isFalse);
    expect(client.queuedMessageCount, 1);
    await client.close();
    expect(await first, isFalse);
    expect(client.queuedMessageCount, 0);
  });
}

Future<VoiceWebSocketClient> _configuredClient({
  required Directory temp,
  required int serverPort,
  int maximumQueuedMessages = 32,
  Duration maximumBusyQueueAge = const Duration(minutes: 5),
  Duration acknowledgementTimeout = const Duration(seconds: 1),
  List<Duration> busyRetryDelays = const <Duration>[Duration(milliseconds: 10)],
  List<String> agentNames = const <String>['Agent One'],
}) async {
  final store = VoiceWebSocketConfigStore(supportDirectory: () async => temp);
  final client = VoiceWebSocketClient(
    configStore: store,
    reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
    readyTimeout: const Duration(seconds: 1),
    acknowledgementTimeout: acknowledgementTimeout,
    maximumQueuedMessages: maximumQueuedMessages,
    maximumBusyQueueAge: maximumBusyQueueAge,
    busyRetryDelays: busyRetryDelays,
  );
  await client.initialize();
  await client.saveConfig(
    VoiceWebSocketConfig.validate(
      host: '127.0.0.1',
      port: serverPort,
      secret: 'example-secret',
      authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
      agentNames: agentNames,
      useLegacyMessageShape: false,
    ),
  );
  await _waitUntil(() => client.isReady);
  return client;
}

Map<String, Object?> _acceptedPayload(Map<String, dynamic> payload) {
  final accepted = payload['agent'] != 'Agent Two';
  return <String, Object?>{
    'type': 'message.accepted',
    'version': 1,
    'request_id': payload['request_id'],
    'ok': accepted,
    'result': <String, Object?>{
      'ok': accepted,
      'agent': payload['agent'],
      'message': payload['message'],
      'focused': accepted,
      'sent': accepted,
    },
  };
}

Map<String, Object?> _busyPayload(Map<String, dynamic> payload) =>
    <String, Object?>{
      'type': 'message.error',
      'version': 1,
      'request_id': payload['request_id'],
      'ok': false,
      'error': <String, Object?>{'code': 'agent_busy', 'status': 'busy'},
    };

Map<String, Object?> _busyAcknowledgementPayload(
  Map<String, dynamic> payload,
) => <String, Object?>{
  'type': 'message.accepted',
  'version': 1,
  'request_id': payload['request_id'],
  'ok': false,
  'result': <String, Object?>{'sent': false, 'reason': 'agent_busy'},
};

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached before timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
