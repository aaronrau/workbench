import 'dart:async';

import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:even_g2_r1_poc/src/audio/voice_memo_models.dart';
import 'package:even_g2_r1_poc/src/ble/ble_models.dart';
import 'package:even_g2_r1_poc/src/ui/home_history_panel.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:even_g2_r1_poc/src/websocket/agent_exchange_store.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final folderUnavailable in [false, true]) {
    testWidgets(
      'shows local messages when shared folder unavailable=$folderUnavailable',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _app(
            HomeHistoryPanel(
              events: const [],
              conversations: const [],
              analysisEnabled: false,
              needsEnrollment: false,
              analysisState: 'disabled',
              knownSpeakerCount: 0,
              pendingConversationCount: 0,
              isLoadingConversations: false,
              isStorageBusy: false,
              sharedFolderName: folderUnavailable ? 'Synthetic folder' : null,
              messageError: folderUnavailable
                  ? 'Could not read the selected folder.'
                  : null,
              messages: [
                SharedWebSocketMessage(
                  id: 'local.sent.message.txt',
                  direction: SharedWebSocketMessageDirection.sent,
                  text: 'Agent One: Saved local request.',
                  updatedAt: DateTime(2026),
                ),
              ],
            ),
          ),
        );
        await tester.tap(find.text('Messages'));
        await tester.pumpAndSettle();
        expect(find.text('Agent One: Saved local request.'), findsOneWidget);
        expect(find.text('Sent'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('messages-list')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('switches between events and aligned speaker turns', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var clearCount = 0;
    var refreshCount = 0;
    final selectedTabs = <HomeHistoryTab>[];
    final now = DateTime(2026, 1, 2, 3, 4);

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: <PooledLog>[
            PooledLog(timestamp: now, source: 'BLE', message: 'Adapter ready'),
            PooledLog(
              timestamp: now.add(const Duration(minutes: 1)),
              source: 'Protocol RX',
              message: 'Raw event retained',
            ),
          ],
          conversations: <SharedConversationTurn>[
            _turn(
              id: 'turn-1',
              label: 'You',
              text: 'Start the safety check.',
              updatedAt: now,
              primary: true,
            ),
            _turn(
              id: 'turn-2',
              label: 'Speaker 2',
              text: 'The safety check is complete.',
              updatedAt: now.add(const Duration(seconds: 1)),
            ),
          ],
          analysisEnabled: true,
          needsEnrollment: false,
          analysisState: 'ready',
          knownSpeakerCount: 2,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          onClearEvents: () => clearCount++,
          onRefreshConversations: () => refreshCount++,
          onTabChanged: selectedTabs.add,
        ),
      ),
    );

    expect(find.textContaining('Adapter ready'), findsOneWidget);
    expect(find.textContaining('Raw event retained'), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(SegmentedButton), findsNothing);
    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('Conversation'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear events'));
    expect(clearCount, 1);

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(selectedTabs, <HomeHistoryTab>[HomeHistoryTab.conversations]);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Start the safety check.'), findsOneWidget);
    expect(find.text('Speaker 2'), findsOneWidget);
    expect(find.text('The safety check is complete.'), findsOneWidget);
    expect(find.textContaining('2 saved speakers'), findsOneWidget);
    final youMarkerFinder = find.byKey(
      const ValueKey<String>('conversation-speaker-color-turn-1'),
    );
    expect(tester.getSize(youMarkerFinder), const Size.square(12));
    final youMarker = tester.widget<Container>(youMarkerFinder);
    final youDecoration = youMarker.decoration as BoxDecoration;
    expect(youDecoration.color, conversationUserMarkerColor);
    expect(youDecoration.shape, BoxShape.circle);
    expect(
      conversationUserMarkerColor.computeLuminance(),
      greaterThan(
        Theme.of(
          tester.element(find.byType(HomeHistoryPanel)),
        ).colorScheme.surfaceContainerHighest.computeLuminance(),
      ),
    );
    expect(
      tester.widget<Text>(find.text('You')).style?.color,
      Theme.of(
        tester.element(find.byType(HomeHistoryPanel)),
      ).colorScheme.onSurface,
    );
    final youTurn = find.byKey(const ValueKey<String>('conversation-turn-1'));
    expect(
      find.descendant(
        of: youTurn,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).borderRadius != null,
        ),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('reset-primary-speaker')),
      findsNothing,
    );
    final refresh = find.byTooltip('Refresh conversations');
    expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
    await tester.tap(refresh);
    expect(refreshCount, 1);
    await tester.tap(find.text('Events'));
    await tester.pumpAndSettle();
    expect(selectedTabs, <HomeHistoryTab>[
      HomeHistoryTab.conversations,
      HomeHistoryTab.events,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains how to enable optional conversation analysis', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const HomeHistoryPanel(
          events: <PooledLog>[],
          conversations: <SharedConversationTurn>[],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Enable Conversation analysis in Tools'),
      findsOneWidget,
    );
  });

  testWidgets('keeps saved agent messages and transcripts in Messages only', (
    tester,
  ) async {
    SharedTranscript? played;
    final transcript = SharedTranscript(
      id: 'legacy',
      originalText: 'Original synthetic transcript.',
      correctedText: 'Corrected synthetic transcript.',
      audioFileName: 'legacy.wav',
      updatedAt: DateTime(2026, 1, 1),
    );
    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: <SharedWebSocketMessage>[
            SharedWebSocketMessage(
              id: 'received',
              direction: SharedWebSocketMessageDirection.received,
              text: 'Synthetic agent response.',
              updatedAt: DateTime(2026, 1, 1, 0, 0, 1),
            ),
          ],
          transcriptions: <SharedTranscript>[transcript],
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingMessages: false,
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          isPlayingTranscript: (_) => false,
          onToggleTranscriptAudio: (value) => played = value,
        ),
      ),
    );

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    expect(find.text('Received'), findsOneWidget);
    expect(find.text('Synthetic agent response.'), findsOneWidget);
    expect(find.text('Original synthetic transcript.'), findsOneWidget);
    expect(find.text('Corrected synthetic transcript.'), findsOneWidget);
    await tester.tap(find.byTooltip('Play audio'));
    expect(played, same(transcript));

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic agent response.'), findsNothing);
    expect(find.text('Original synthetic transcript.'), findsNothing);
    expect(find.textContaining('separate Messages tab'), findsOneWidget);
  });

  testWidgets('retains the original Messages folder picker', (tester) async {
    var chooseCount = 0;
    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          supportsSharedFolder: true,
          isLoadingMessages: false,
          onChooseFolder: () => chooseCount++,
        ),
      ),
    );

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No saved messages yet'), findsOneWidget);
    final chooseButton = find.widgetWithText(FilledButton, 'Choose folder');
    expect(chooseButton, findsOneWidget);
    await tester.tap(chooseButton);
    expect(chooseCount, 1);
  });

  testWidgets('filters agent messages and sends directly from its chip', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? sentAgent;
    String? sentMessage;
    final now = DateTime(2026, 1, 2, 3, 4);

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          agentNames: const <String>['Flux', 'Pike'],
          agentMessages: <AgentMessageView>[
            AgentMessageView(
              id: 'flux-sent',
              agent: 'Flux',
              direction: AgentMessageDirection.sent,
              message: 'Inspect the synthetic build.',
              updatedAt: now,
            ),
            AgentMessageView(
              id: 'flux-received',
              agent: 'Flux',
              direction: AgentMessageDirection.received,
              message: 'Flux: Synthetic build is ready.',
              updatedAt: now.add(const Duration(minutes: 1)),
            ),
            AgentMessageView(
              id: 'pike-received',
              agent: 'Pike',
              direction: AgentMessageDirection.received,
              message: 'Pike: Unrelated synthetic update.',
              updatedAt: now.add(const Duration(minutes: 2)),
            ),
          ],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          onSendAgentMessage:
              ({
                required String endpointId,
                required String agent,
                required String message,
              }) async {
                sentAgent = agent;
                sentMessage = message;
                return true;
              },
        ),
      ),
    );

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    expect(find.byType(ChoiceChip), findsNWidgets(3));
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey<String>('message-agent-all')),
          )
          .selected,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey<String>('direct-agent-message-field')),
      findsNothing,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('message-agent-Flux')))
          .height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.byKey(const ValueKey<String>('message-agent-Flux')));
    await tester.pumpAndSettle();

    final selectedAgentField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('direct-agent-message-field')),
    );
    expect(selectedAgentField.focusNode?.hasFocus, isTrue);
    expect(find.text('2 saved messages with Flux'), findsOneWidget);
    expect(find.text('Inspect the synthetic build.'), findsOneWidget);
    expect(find.text('Synthetic build is ready.'), findsOneWidget);
    expect(find.textContaining('Unrelated synthetic update'), findsNothing);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Received'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('direct-agent-message-field')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey<String>('direct-agent-message-field')),
          )
          .width,
      greaterThan(300),
    );
    expect(find.byIcon(Icons.send), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey<String>('direct-agent-message-field')),
      'Run the next synthetic check.',
    );
    await tester.pump();
    final dismissKeyboard = find.byKey(
      const ValueKey<String>('dismiss-agent-message-keyboard'),
    );
    expect(dismissKeyboard, findsOneWidget);
    expect(tester.getSize(dismissKeyboard).height, greaterThanOrEqualTo(48));
    await tester.tap(dismissKeyboard);
    await tester.pumpAndSettle();
    expect(selectedAgentField.focusNode?.hasFocus, isFalse);
    expect(find.text('Run the next synthetic check.'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('direct-agent-message-field')),
    );
    await tester.pumpAndSettle();
    expect(selectedAgentField.focusNode?.hasFocus, isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(sentAgent, 'Flux');
    expect(sentMessage, 'Run the next synthetic check.');
    expect(find.text('Sent to Flux.'), findsNothing);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('direct-agent-message-field')),
          )
          .controller
          ?.text,
      isEmpty,
    );

    await tester.tap(find.byKey(const ValueKey<String>('message-agent-Pike')));
    await tester.pumpAndSettle();
    expect(selectedAgentField.focusNode?.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('message-agent-all')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey<String>('message-agent-all')),
          )
          .selected,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey<String>('direct-agent-message-field')),
      findsNothing,
    );
    expect(selectedAgentField.focusNode?.hasFocus, isFalse);
    expect(find.textContaining('No saved messages yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retains a direct message draft when sending fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          agentNames: const <String>['Flux'],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          onSendAgentMessage:
              ({
                required String endpointId,
                required String agent,
                required String message,
              }) async => false,
        ),
      ),
    );

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Flux'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('direct-agent-message-field')),
      'Keep this synthetic draft.',
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(
      find.text('Could not send to Flux. Check the connection.'),
      findsOneWidget,
    );
    expect(find.text('Keep this synthetic draft.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shows and deletes an offline queued message on a phone viewport',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? deletedEndpoint;
      String? deletedQueue;

      await tester.pumpWidget(
        _app(
          HomeHistoryPanel(
            events: const <PooledLog>[],
            conversations: const <SharedConversationTurn>[],
            agentTargets: const <VoiceWebSocketAgentTarget>[
              VoiceWebSocketAgentTarget(
                endpointId: 'offline-endpoint',
                agentName: 'Flux',
              ),
            ],
            queuedAgentMessages: <VoiceWebSocketQueuedMessage>[
              VoiceWebSocketQueuedMessage(
                id: 'synthetic-queue-id',
                endpointId: 'offline-endpoint',
                agent: 'Flux',
                message: 'Run the queued synthetic check.',
                enqueuedAt: DateTime(2026, 1, 2, 3, 4),
                state: VoiceWebSocketQueuedMessageState.waitingForConnection,
              ),
            ],
            analysisEnabled: false,
            needsEnrollment: false,
            analysisState: 'disabled',
            knownSpeakerCount: 0,
            pendingConversationCount: 0,
            isLoadingConversations: false,
            isStorageBusy: false,
            onDeleteQueuedAgentMessage:
                ({required String endpointId, required String queueId}) {
                  deletedEndpoint = endpointId;
                  deletedQueue = queueId;
                },
          ),
        ),
      );

      await tester.tap(find.text('Messages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flux'));
      await tester.pumpAndSettle();

      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('Run the queued synthetic check.'), findsOneWidget);
      expect(
        find.text(
          'Unable to send. Queued and will retry when the connection returns.',
        ),
        findsOneWidget,
      );
      final delete = find.byKey(
        const ValueKey<String>(
          'delete-queued-agent-message-synthetic-queue-id',
        ),
      );
      expect(tester.getSize(delete), const Size(48, 48));

      await tester.tap(delete);
      await tester.pump();

      expect(deletedEndpoint, 'offline-endpoint');
      expect(deletedQueue, 'synthetic-queue-id');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loads more All and selected-agent messages while scrolling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 1, 2);

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: List<SharedWebSocketMessage>.generate(
            30,
            (index) => SharedWebSocketMessage(
              id: 'shared-$index',
              direction: SharedWebSocketMessageDirection.received,
              text: 'Shared synthetic message $index',
              updatedAt: now.add(Duration(minutes: index)),
            ),
          ),
          agentNames: const <String>['Flux'],
          agentMessages: List<AgentMessageView>.generate(
            30,
            (index) => AgentMessageView(
              id: 'agent-$index',
              agent: 'Flux',
              direction: AgentMessageDirection.received,
              message: 'Flux: Agent synthetic message $index',
              updatedAt: now.add(Duration(minutes: index)),
            ),
          ),
          sharedFolderName: 'Synthetic history',
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    int visibleItems(String key) {
      final list = tester.widget<ListView>(find.byKey(ValueKey<String>(key)));
      final separatedChildCount = list.childrenDelegate.estimatedChildCount!;
      return (separatedChildCount + 1) ~/ 2;
    }

    expect(visibleItems('messages-list'), 20);
    await tester.fling(
      find.byKey(const ValueKey<String>('messages-list')),
      const Offset(0, -5000),
      2500,
    );
    await tester.pumpAndSettle();
    expect(visibleItems('messages-list'), 30);

    await tester.tap(find.byKey(const ValueKey<String>('message-agent-Flux')));
    await tester.pumpAndSettle();

    expect(visibleItems('agent-messages-list'), 20);
    await tester.fling(
      find.byKey(const ValueKey<String>('agent-messages-list')),
      const Offset(0, -5000),
      2500,
    );
    await tester.pumpAndSettle();
    expect(visibleItems('agent-messages-list'), 30);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows first-load indicators for Messages and Conversation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messagesLoaded = Completer<void>();
    final conversationsLoaded = Completer<void>();
    var messageLoads = 0;
    var conversationLoads = 0;

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: const <SharedWebSocketMessage>[],
          transcriptions: const <SharedTranscript>[],
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingMessages: false,
          analysisEnabled: true,
          needsEnrollment: false,
          analysisState: 'ready',
          knownSpeakerCount: 1,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          onLoadMessages: () {
            messageLoads++;
            return messagesLoaded.future;
          },
          onLoadConversations: () {
            conversationLoads++;
            return conversationsLoaded.future;
          },
        ),
      ),
    );

    tester.widget<TabBar>(find.byType(TabBar)).controller!.index =
        HomeHistoryTab.messages.index;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(messageLoads, 1);
    expect(
      find.byKey(const ValueKey<String>('messages-loading')),
      findsOneWidget,
    );
    expect(find.text('Loading messages…'), findsOneWidget);
    expect(find.textContaining('No saved messages'), findsNothing);

    messagesLoaded.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('messages-loading')),
      findsNothing,
    );
    expect(find.textContaining('No saved messages'), findsOneWidget);

    tester.widget<TabBar>(find.byType(TabBar)).controller!.index =
        HomeHistoryTab.conversations.index;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(conversationLoads, 1);
    expect(
      find.byKey(const ValueKey<String>('conversations-loading')),
      findsOneWidget,
    );
    expect(find.text('Loading conversations…'), findsOneWidget);
    expect(
      find.textContaining('No conversations or voice memos'),
      findsNothing,
    );

    conversationsLoaded.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('conversations-loading')),
      findsNothing,
    );
    expect(
      find.textContaining('No conversations or voice memos'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps a fast first-load indicator visible through tab entry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: const <SharedWebSocketMessage>[],
          transcriptions: const <SharedTranscript>[],
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingMessages: false,
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          onLoadMessages: () async {},
        ),
      ),
    );

    tester.widget<TabBar>(find.byType(TabBar)).controller!.index =
        HomeHistoryTab.messages.index;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Loading messages…'), findsOneWidget);
    expect(find.textContaining('No saved messages'), findsNothing);

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('Loading messages…'), findsNothing);
    expect(find.textContaining('No saved messages'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows progress through three enrollment samples', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const HomeHistoryPanel(
          events: <PooledLog>[],
          conversations: <SharedConversationTurn>[],
          analysisEnabled: true,
          needsEnrollment: true,
          enrollmentPending: true,
          acceptedEnrollmentSamples: 1,
          requiredEnrollmentSamples: 3,
          analysisState: 'waiting_for_enrollment_speech',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Voice sample 2 of 3'), findsOneWidget);
    expect(find.textContaining('pause while it is checked'), findsOneWidget);
  });

  testWidgets('shows live and saved voice memos in Conversation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 1, 2, 3, 4);
    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          voiceMemos: <VoiceMemoRecord>[
            VoiceMemoRecord(
              id: 'memo-live',
              status: VoiceMemoStatus.revising,
              note: 'Project idea\n- Preserve the important details.',
              sources: const <VoiceMemoSource>[
                VoiceMemoSource(
                  segmentId: 'segment-synthetic',
                  rawTranscript: 'Synthetic source',
                  memoText: 'Preserve the important details.',
                ),
              ],
              revision: 1,
              createdAt: now,
              updatedAt: now,
            ),
          ],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );

    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(find.text('Voice memo'), findsOneWidget);
    expect(
      find.text('Project idea\n- Preserve the important details.'),
      findsOneWidget,
    );
    expect(find.textContaining('Updating · 1 utterance'), findsOneWidget);
    expect(find.textContaining('1 voice memo'), findsOneWidget);
    final memo = find.byKey(const ValueKey<String>('voice-memo-memo-live'));
    expect(memo, findsOneWidget);
    final memoBounds = tester.widget<ConstrainedBox>(
      find.descendant(of: memo, matching: find.byType(ConstrainedBox)).first,
    );
    expect(memoBounds.constraints.maxWidth, 360);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows only the thirty most recent supplied events', (
    tester,
  ) async {
    final events = List<PooledLog>.generate(
      35,
      (index) => PooledLog(
        timestamp: DateTime(2026, 1, 1).add(Duration(minutes: index)),
        source: 'Test',
        message: 'Event $index',
      ),
    ).reversed.toList();

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: events,
          conversations: const <SharedConversationTurn>[],
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey<String>('events-list')),
    );
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.estimatedChildCount, 30);
  });

  testWidgets('loads retained Messages items in twenty-row pages', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final transcriptions = List<SharedTranscript>.generate(
      45,
      (index) => SharedTranscript(
        id: 'sample-$index',
        originalText: 'Transcript $index',
        correctedText: 'Corrected transcript $index',
        audioFileName: 'sample-$index.wav',
        updatedAt: DateTime(2026, 1, 1).subtract(Duration(minutes: index)),
      ),
    );

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: const <SharedConversationTurn>[],
          messages: const <SharedWebSocketMessage>[],
          transcriptions: transcriptions,
          supportsSharedFolder: true,
          sharedFolderName: 'Work Bench Audio',
          isLoadingMessages: false,
          analysisEnabled: false,
          needsEnrollment: false,
          analysisState: 'disabled',
          knownSpeakerCount: 0,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
          isPlayingTranscript: (_) => false,
        ),
      ),
    );
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();

    expect(_visibleMessageItems(tester), 20);
    await _jumpListToEnd(tester, 'messages-list');
    expect(_visibleMessageItems(tester), 40);
    await _jumpListToEnd(tester, 'messages-list');
    expect(_visibleMessageItems(tester), 45);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retains only the hundred most recent conversation turns', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final turns = List<SharedConversationTurn>.generate(
      225,
      (index) => _turn(
        id: 'turn-$index',
        label: index.isEven ? 'You' : 'Speaker 2',
        text: 'Conversation turn $index',
        updatedAt: DateTime(2026, 1, 1).add(Duration(seconds: index)),
        primary: index.isEven,
      ),
    );

    await tester.pumpWidget(
      _app(
        HomeHistoryPanel(
          events: const <PooledLog>[],
          conversations: turns,
          analysisEnabled: true,
          needsEnrollment: false,
          analysisState: 'ready',
          knownSpeakerCount: 2,
          pendingConversationCount: 0,
          isLoadingConversations: false,
          isStorageBusy: false,
        ),
      ),
    );
    await tester.tap(find.text('Conversation'));
    await tester.pumpAndSettle();

    expect(_visibleConversationItems(tester), 100);
    expect(find.text('Conversation turn 224'), findsWidgets);
    await _jumpListToEnd(tester, 'conversation-list');
    expect(_visibleConversationItems(tester), 100);
    expect(find.text('Conversation turn 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shows all endpoint agents and does not block a second endpoint send',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final slowSend = Completer<bool>();
      final sent = <String>[];
      final targets = <VoiceWebSocketAgentTarget>[
        for (final agent in const <String>['A1', 'A2', 'A3', 'A4'])
          VoiceWebSocketAgentTarget(endpointId: 'endpoint-a', agentName: agent),
        for (final agent in const <String>['B1', 'B2', 'B3', 'B4'])
          VoiceWebSocketAgentTarget(endpointId: 'endpoint-b', agentName: agent),
      ];

      await tester.pumpWidget(
        _app(
          HomeHistoryPanel(
            events: const <PooledLog>[],
            conversations: const <SharedConversationTurn>[],
            agentTargets: targets,
            analysisEnabled: false,
            needsEnrollment: false,
            analysisState: 'disabled',
            knownSpeakerCount: 0,
            pendingConversationCount: 0,
            isLoadingConversations: false,
            isStorageBusy: false,
            onSendAgentMessage:
                ({
                  required String endpointId,
                  required String agent,
                  required String message,
                }) {
                  sent.add('$endpointId:$agent:$message');
                  return endpointId == 'endpoint-a'
                      ? slowSend.future
                      : Future<bool>.value(true);
                },
          ),
        ),
      );

      await tester.tap(find.text('Messages'));
      await tester.pumpAndSettle();
      final chips = tester.widget<ListView>(
        find.byKey(const ValueKey<String>('message-agent-chips')),
      );
      final chipDelegate = chips.childrenDelegate as SliverChildBuilderDelegate;
      expect((chipDelegate.estimatedChildCount! + 1) ~/ 2, 9);

      await tester.tap(find.byKey(const ValueKey<String>('message-agent-A1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-agent-message-field')),
        'slow',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();

      await tester.drag(
        find.byKey(const ValueKey<String>('message-agent-chips')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('message-agent-B1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('direct-agent-message-field')),
        'fast',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();

      expect(sent, contains('endpoint-a:A1:slow'));
      expect(sent, contains('endpoint-b:B1:fast'));
      expect(find.text('Sent to B1.'), findsNothing);
      expect(slowSend.isCompleted, isFalse);

      slowSend.complete(true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

SharedConversationTurn _turn({
  required String id,
  required String label,
  required String text,
  required DateTime updatedAt,
  bool primary = false,
}) => SharedConversationTurn(
  id: id,
  conversationId: 'conversation',
  speakerId: primary ? 'primary-user' : 'speaker-2',
  speakerLabel: label,
  text: text,
  startMs: 0,
  endMs: 1000,
  confidence: 0.9,
  updatedAt: updatedAt,
  isPrimary: primary,
  isOverlap: false,
);

Widget _app(Widget child) {
  return MaterialApp(
    theme: buildWorkBenchTheme(),
    home: Scaffold(
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
}

int _visibleConversationItems(WidgetTester tester) {
  final list = tester.widget<ListView>(
    find.byKey(const ValueKey<String>('conversation-list')),
  );
  final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
  final separatedChildCount = delegate.estimatedChildCount!;
  return (separatedChildCount + 1) ~/ 2;
}

int _visibleMessageItems(WidgetTester tester) {
  final list = tester.widget<ListView>(
    find.byKey(const ValueKey<String>('messages-list')),
  );
  final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
  final separatedChildCount = delegate.estimatedChildCount!;
  return (separatedChildCount + 1) ~/ 2;
}

Future<void> _jumpListToEnd(WidgetTester tester, String key) async {
  final list = find.byKey(ValueKey<String>(key));
  final scrollable = find.descendant(
    of: list,
    matching: find.byType(Scrollable),
  );
  final state = tester.state<ScrollableState>(scrollable);
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pump();
  await tester.pump();
}
