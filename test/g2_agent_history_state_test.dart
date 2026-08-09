import 'package:even_g2_r1_poc/src/websocket/agent_exchange_store.dart';
import 'package:even_g2_r1_poc/src/websocket/g2_agent_history_state.dart';
import 'package:even_g2_r1_poc/src/websocket/selected_agent_transcript_session.dart';
import 'package:even_g2_r1_poc/src/protocol/g2_text_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sentAt = DateTime.utc(2026, 1, 1);

  String stamp(DateTime value) {
    final local = value.toLocal();
    return '[${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}]';
  }

  test('opens with [x] first, five agents, and Memo last', () {
    final state = G2AgentHistoryState();
    state.open(
      agents: const <String>[
        'Pike',
        'Agent Two',
        'Agent Three',
        'Agent Four',
        'Agent Five',
        'Agent Six',
      ],
      exchanges: <AgentExchangeView>[
        AgentExchangeView(
          id: 'pike-exchange',
          agent: 'Pike',
          message: 'validate the isolated device fixture',
          sentAt: sentAt,
          legacy: false,
        ),
      ],
      memo: 'Remember the synthetic validation result.',
    );

    expect(state.mode, G2AgentHistoryMode.selector);
    expect(state.entries, hasLength(7));
    expect(state.selected?.kind, G2AgentHistoryEntryKind.dismiss);
    expect(state.entries[1].label, 'Pike');
    expect(state.entries.last.kind, G2AgentHistoryEntryKind.memo);
    expect(
      state.render(),
      startsWith(' >  [x] - Swipe to Select\n     Pike - validate'),
    );
    final rows = state.render().split('\n');
    expect(rows, hasLength(7));
    expect(rows.last, '     Memo - Remember the synthetic validation result.');
    expect(state.render(), contains('[x] - Swipe to Select'));

    for (var index = 0; index < 4; index++) {
      state.selectNext();
    }
    expect(state.render(), contains(' >  Agent Four - No messages'));
    expect(
      state.render().runes.length,
      lessThanOrEqualTo(G2AgentHistoryState.maximumPageCharacters),
    );
  });

  test('selector previews each agent newest sent or received message', () {
    final state = G2AgentHistoryState();
    state.open(
      agents: const <String>['Pike', 'Vale'],
      exchanges: const <AgentExchangeView>[],
      messages: <AgentMessageView>[
        AgentMessageView(
          id: 'pike-sent',
          agent: 'Pike',
          direction: AgentMessageDirection.sent,
          message: 'older sent preview',
          updatedAt: sentAt,
        ),
        AgentMessageView(
          id: 'pike-received',
          agent: 'Pike',
          direction: AgentMessageDirection.received,
          message: 'Pike: newest received preview',
          updatedAt: sentAt.add(const Duration(minutes: 2)),
        ),
        AgentMessageView(
          id: 'vale-received',
          agent: 'Vale',
          direction: AgentMessageDirection.received,
          message: 'older received preview',
          updatedAt: sentAt,
        ),
        AgentMessageView(
          id: 'vale-sent',
          agent: 'Vale',
          direction: AgentMessageDirection.sent,
          message: 'Vale: newest sent preview',
          updatedAt: sentAt.add(const Duration(minutes: 3)),
        ),
      ],
    );

    expect(state.entries[1].preview, 'newest received preview');
    expect(state.entries[2].preview, 'newest sent preview');
  });

  test('swipes wrap and empty Memo opens a dismissible detail', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: const <AgentExchangeView>[],
      );

    state.selectPrevious();
    expect(state.selected?.label, 'Memo');
    expect(state.selectedSpeechAgent, isNull);
    state.selectNext();
    expect(state.selected?.label, '[x]');
    expect(state.selectedSpeechAgent, isNull);
    state.selectNext();
    expect(state.selected?.label, 'Pike');
    expect(state.selectedSpeechAgent, isNull);
    state.selectNext();
    expect(state.selected?.label, 'Memo');
    expect(state.selectedSpeechAgent, isNull);
    state.showSelectedDetail();
    expect(state.selectedSpeechAgent, isNull);

    expect(state.mode, G2AgentHistoryMode.detail);
    expect(state.render(), startsWith('[ Memo · Tap to dismiss ]\n'));
    expect(state.render(), contains('No saved memo'));
    expect(state.render().split('\n'), hasLength(9));
  });

  test('Pike waits for only its exchange and then shows the response', () {
    final exchange = AgentExchangeView(
      id: 'pike-exchange',
      agent: 'Pike',
      message: 'report synthetic progress',
      sentAt: sentAt,
      legacy: false,
    );
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: <AgentExchangeView>[exchange],
      )
      ..selectNext();

    state.showWaiting(exchange);
    expect(state.selectedSpeechAgent, isNull);
    expect(
      state.render(),
      startsWith('< [Pike - Tap to cancel]\n  · Listen Mode\n'),
    );
    expect(state.render(), contains('Waiting for response'));
    expect(state.acceptResponse('different-exchange', 'Wrong response'), false);
    expect(state.mode, G2AgentHistoryMode.waiting);
    expect(
      state.acceptResponse(
        'pike-exchange',
        'Pike: Synthetic device response received.',
        receivedAt: sentAt.add(const Duration(minutes: 1)),
      ),
      true,
    );
    expect(state.mode, G2AgentHistoryMode.detail);
    expect(
      state.render(),
      contains(
        '${stamp(sentAt.add(const Duration(minutes: 1)))} '
        'Synthetic device response received.',
      ),
    );
  });

  test(
    'agent detail remains an active target and renders speech lifecycle',
    () {
      final state = G2AgentHistoryState()
        ..open(
          agents: const <String>['Pike'],
          exchanges: const <AgentExchangeView>[],
        )
        ..selectNext()
        ..showSelectedDetail();

      expect(state.selectedSpeechAgent, isNull);
      expect(state.beginTargetedSpeech('segment-1'), isFalse);
      expect(
        state.render(),
        startsWith('   [Pike]\n> • Listen Mode - Tap to start\n'),
      );

      expect(state.selectDetailListenMode(), isTrue);
      expect(state.selectDetailListenMode(), isFalse);
      expect(state.selectedSpeechAgent, 'Pike');
      expect(
        state.render(),
        startsWith(
          '   [Pike]\n'
          '< • Listen Mode - Tap to stop\n',
        ),
      );

      expect(state.beginTargetedSpeech('segment-1'), isTrue);
      expect(
        state.render(),
        startsWith('   [Pike]\n< • Listening - Tap to send\n'),
      );

      expect(
        state.updateTargetedSpeechTranscript(
          segmentId: 'segment-1',
          transcript: 'pull the latest',
        ),
        isTrue,
      );
      expect(state.detailSpeechState, G2AgentDetailSpeechState.listening);
      expect(state.render(), contains('Listening: pull the latest'));
      expect(
        state.updateTargetedSpeechTranscript(
          segmentId: 'segment-1',
          transcript: 'pull the latest changes',
        ),
        isTrue,
      );
      expect(state.render(), contains('Listening: pull the latest changes'));

      expect(state.finishTargetedSpeechCapture('segment-1'), isTrue);
      expect(state.detailSpeechState, G2AgentDetailSpeechState.sending);
      expect(state.detailListenModeSelected, isFalse);
      expect(
        state.render(),
        startsWith(
          '   [Pike - Tap to dismiss]\n'
          '< • Sending - Tap to dismiss\n',
        ),
      );
      expect(state.render(), contains('Sending: pull the latest changes'));
      expect(state.markTargetedSpeechSending('segment-1'), isFalse);
      expect(state.beginTargetedSpeech('segment-2'), isFalse);

      expect(
        state.showTargetedSpeechTranscript(
          segmentId: 'segment-1',
          transcript: 'pull the latest changes',
        ),
        isTrue,
      );
      expect(state.render(), contains('< • Sending - Tap to dismiss'));
      expect(state.render(), contains('Sending: pull the latest changes'));

      expect(
        state.completeTargetedSpeech(
          segmentId: 'segment-1',
          transcript: 'pull the latest changes',
          sent: true,
        ),
        isTrue,
      );
      expect(state.render(), contains('> • Sent - Tap to start'));
      expect(state.render(), contains('No conversation yet'));
    },
  );

  test('finishing speech replaces Listening with its delivery transcript', () {
    final messages = <AgentMessageView>[
      for (var index = 0; index < 40; index++)
        AgentMessageView(
          id: 'delivery-message-$index',
          agent: 'Pike',
          direction: AgentMessageDirection.sent,
          message: 'Pike: retained delivery history row $index',
          updatedAt: sentAt.add(Duration(minutes: index)),
        ),
    ];
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showAgentMessages(messages);

    expect(state.selectNextDetailPage(), isTrue);
    expect(state.selectDetailListenMode(), isTrue);
    expect(state.beginTargetedSpeech('delivery-segment'), isTrue);
    expect(state.finishTargetedSpeechCapture('delivery-segment'), isTrue);

    expect(state.detailSpeechState, G2AgentDetailSpeechState.sending);
    expect(state.detailPageIndex, 0);
    expect(state.render(), contains('< • Sending - Tap to dismiss'));
    expect(state.render(), contains('Sending…'));
    expect(state.selectPreviousDetailPage(), isFalse);
    expect(state.selectNextDetailPage(), isFalse);

    expect(
      state.showTargetedSpeechTranscript(
        segmentId: 'delivery-segment',
        transcript: 'send the retained synthetic command',
      ),
      isTrue,
    );
    expect(state.detailPageIndex, 0);
    expect(
      state.render(),
      contains('Sending: send the retained synthetic command'),
    );

    expect(
      state.completeTargetedSpeech(
        segmentId: 'delivery-segment',
        transcript: 'send the retained synthetic command',
        sent: true,
      ),
      isTrue,
    );
    expect(state.render(), contains('> • Sent - Tap to start'));
    expect(state.detailPageIndex, 0);
    expect(state.render(), contains('retained delivery history row 39'));
  });

  test('a newer detail utterance cannot be overwritten by an older result', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showSelectedDetail()
      ..selectDetailListenMode()
      ..beginTargetedSpeech('segment-1')
      ..beginTargetedSpeech('segment-2');

    expect(
      state.completeTargetedSpeech(
        segmentId: 'segment-1',
        transcript: 'older command',
        sent: true,
      ),
      isFalse,
    );
    expect(state.render(), contains('Listening…'));
  });

  test(
    'stopping Listen Mode restores history and clears its transient turn',
    () {
      final messages = <AgentMessageView>[
        for (var index = 0; index < 40; index++)
          AgentMessageView(
            id: 'message-$index',
            agent: 'Pike',
            direction: index.isEven
                ? AgentMessageDirection.sent
                : AgentMessageDirection.received,
            message: 'Pike: retained synthetic history row $index',
            updatedAt: sentAt.add(Duration(minutes: index)),
          ),
      ];
      final state = G2AgentHistoryState()
        ..open(
          agents: const <String>['Pike'],
          exchanges: const <AgentExchangeView>[],
        )
        ..selectNext()
        ..showAgentMessages(messages);

      expect(state.selectNextDetailPage(), isTrue);
      final historyPageIndex = state.detailPageIndex;
      final historyBody = state.render().split('\n').skip(2).join('\n');

      expect(state.selectDetailListenMode(), isTrue);
      expect(state.detailPageIndex, historyPageIndex);
      expect(state.beginTargetedSpeech('segment-1'), isTrue);
      expect(state.detailPageIndex, 0);
      expect(state.render(), contains('Listening…'));

      expect(state.exitDetailListenMode(), isTrue);
      expect(state.exitDetailListenMode(), isFalse);
      expect(state.selectedSpeechAgent, isNull);
      expect(state.activeDetailSpeechSegmentId, isNull);
      expect(state.detailSpeechState, isNull);
      expect(state.detailPageIndex, historyPageIndex);
      expect(state.render().split('\n').skip(2).join('\n'), historyBody);
      expect(state.beginTargetedSpeech('segment-2'), isFalse);
      expect(
        state.render(),
        startsWith('   [Pike]\n> • Listen Mode - Tap to start\n'),
      );
      expect(
        state.showTargetedSpeechTranscript(
          segmentId: 'segment-1',
          transcript: 'finish the active synthetic turn',
        ),
        isFalse,
      );
      expect(
        state.completeTargetedSpeech(
          segmentId: 'segment-1',
          transcript: 'finish the active synthetic turn',
          sent: true,
        ),
        isFalse,
      );
      expect(state.selectPreviousDetailPage(), isTrue);
      expect(state.selectNextDetailPage(), isTrue);
      expect(state.detailPageIndex, historyPageIndex);
    },
  );

  test('closing a sending detail revokes its target for new speech', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showSelectedDetail()
      ..selectDetailListenMode()
      ..beginTargetedSpeech('segment-1')
      ..markTargetedSpeechSending('segment-1')
      ..exitDetailListenMode(preserveActiveSpeech: true);

    expect(state.selectedSpeechAgent, isNull);
    expect(state.activeDetailSpeechSegmentId, 'segment-1');

    state.close();

    expect(state.selectedSpeechAgent, isNull);
    expect(state.activeDetailSpeechSegmentId, isNull);
    expect(state.beginTargetedSpeech('segment-2'), isFalse);
  });

  test('swipes focus the back and Listen controls without losing history', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showSelectedDetail();

    expect(state.detailControl, G2AgentDetailControl.listen);
    expect(
      state.render(),
      startsWith('   [Flux]\n> • Listen Mode - Tap to start\n'),
    );

    expect(state.selectDetailListenMode(), isTrue);
    expect(
      state.render(),
      startsWith('   [Flux]\n< • Listen Mode - Tap to stop\n'),
    );
    expect(state.exitDetailListenMode(), isTrue);
    expect(state.focusAgentBackControl(), isTrue);
    expect(state.focusAgentBackControl(), isFalse);
    expect(
      state.render(),
      startsWith('< [Flux]\n  • Listen Mode - Tap to start\n'),
    );
    expect(state.selectDetailListenMode(), isFalse);

    expect(state.focusAgentListenControl(), isTrue);
    expect(state.focusAgentListenControl(), isFalse);
    expect(
      state.render(),
      startsWith('   [Flux]\n> • Listen Mode - Tap to start\n'),
    );

    expect(state.focusAgentBackControl(), isTrue);
    expect(state.returnToSelector(), isTrue);
    expect(state.mode, G2AgentHistoryMode.selector);
    expect(state.selected?.label, 'Flux');
    expect(state.returnToSelector(), isFalse);
  });

  test('active listening renders Preview Correction and explicit status', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showSelectedDetail()
      ..selectDetailListenMode()
      ..beginTargetedSpeech('manual-session');

    expect(state.detailBodyLinesPerPage, 5);
    expect(state.render(), contains('• Preview Correction · Off'));
    expect(state.render(), contains('Status: Listening'));
    expect(state.render().split('\n'), hasLength(9));

    expect(state.focusAgentPreviewCorrectionControl(), isTrue);
    expect(
      state.updateTargetedSpeechPreview(
        segmentId: 'manual-session',
        transcript: 'first raw thought',
        previewState: SelectedAgentCorrectionPreviewState.queued,
      ),
      isTrue,
    );
    expect(state.render(), contains('> • Preview Correction · On'));
    expect(state.render(), contains('Status: Correction queued'));

    expect(
      state.updateTargetedSpeechTranscription(
        segmentId: 'manual-session',
        pending: true,
        indicatorVisible: true,
      ),
      isTrue,
    );
    expect(state.render(), contains('Transcribing'));
    expect(
      state.updateTargetedSpeechTranscription(
        segmentId: 'manual-session',
        pending: true,
        indicatorVisible: false,
      ),
      isTrue,
    );
    expect(state.render(), contains('Transcribing'));

    expect(state.focusAgentListenControl(), isTrue);
    expect(
      state.render(),
      startsWith('   [Flux]\n< • Listening - Tap to send\n'),
    );
  });

  test('a matching response refreshes page one and preserves detail state', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux', 'Pike'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showAgentMessages(<AgentMessageView>[
        AgentMessageView(
          id: 'old-flux-message',
          agent: 'Flux',
          direction: AgentMessageDirection.received,
          message: 'Flux: older synthetic response',
          updatedAt: sentAt,
        ),
      ]);

    expect(state.focusAgentBackControl(), isTrue);
    expect(
      state.refreshOpenAgentMessages(
        agent: 'Pike',
        messages: const <AgentMessageView>[],
      ),
      isFalse,
    );
    expect(state.detailControl, G2AgentDetailControl.back);

    expect(
      state.refreshOpenAgentMessages(
        agent: 'Flux',
        messages: <AgentMessageView>[
          AgentMessageView(
            id: 'new-flux-message',
            agent: 'Flux',
            direction: AgentMessageDirection.received,
            message: 'Flux: newest synthetic response',
            updatedAt: sentAt.add(const Duration(minutes: 1)),
          ),
          AgentMessageView(
            id: 'old-flux-message',
            agent: 'Flux',
            direction: AgentMessageDirection.received,
            message: 'Flux: older synthetic response',
            updatedAt: sentAt,
          ),
        ],
      ),
      isTrue,
    );
    expect(state.detailControl, G2AgentDetailControl.back);
    expect(state.detailPageIndex, 0);
    expect(state.render(), startsWith('< [Flux]\n'));
    expect(state.render(), contains('newest synthetic response'));
    expect(
      state.render().indexOf('newest synthetic response'),
      lessThan(state.render().indexOf('older synthetic response')),
    );
  });

  test('a response refresh remains underneath active listening', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showSelectedDetail()
      ..selectDetailListenMode()
      ..beginTargetedSpeech('active-flux-segment');

    expect(
      state.refreshOpenAgentMessages(
        agent: 'Flux',
        messages: <AgentMessageView>[
          AgentMessageView(
            id: 'live-flux-response',
            agent: 'Flux',
            direction: AgentMessageDirection.received,
            message: 'Flux: live synthetic response',
            updatedAt: sentAt,
          ),
        ],
      ),
      isTrue,
    );
    expect(state.detailListenModeSelected, isTrue);
    expect(state.activeDetailSpeechSegmentId, 'active-flux-segment');
    expect(state.render(), contains('Listening…'));

    expect(state.exitDetailListenMode(), isTrue);
    expect(state.detailPageIndex, 0);
    expect(state.render(), contains('live synthetic response'));
  });

  test('selector collapses returns and ellipsizes previews on one row', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'pike-exchange',
            agent: 'Pike',
            message:
                'ready for review\r\nsecond line\rthird line with a long synthetic payload '
                'that must be safely shortened for the glasses and keeps '
                'overflowing beyond the permitted display row',
            sentAt: sentAt,
            legacy: false,
          ),
        ],
      );

    final rows = state.render().split('\n');
    expect(rows, hasLength(3));
    expect(rows[1], startsWith('     Pike - ready for review second line'));
    expect(rows[1], isNot(contains('\r')));
    expect(rows[1], endsWith('…'));
    expect(
      G2TextLayout.history.textWidth(rows[1]),
      lessThanOrEqualTo(G2TextLayout.history.wrappingWidthPixels),
    );
    expect(rows.last, '     Memo - No saved memo');

    const layout = G2TextLayout.history;
    final unselectedPrefix = rows[1].substring(0, rows[1].indexOf('Pike'));
    state.selectNext();
    final selectedRow = state
        .render()
        .split('\n')
        .firstWhere((line) => line.contains('Pike -'));
    final selectedPrefix = selectedRow.substring(
      0,
      selectedRow.indexOf('Pike'),
    );
    expect(
      layout.textWidth(unselectedPrefix),
      layout.textWidth(selectedPrefix),
    );
    expect(selectedRow, startsWith(' >  Pike -'));
    expect(
      state.render().split('\n').where((line) => line.contains('Pike -')),
      hasLength(1),
    );
  });

  test('selector keeps all maximum entries visible on one page', () {
    final longMessage = List<String>.filled(40, 'synthetic-content').join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>[
          'Agent One',
          'Agent Two',
          'Agent Three',
          'Agent Four',
          'Agent Five',
        ],
        exchanges: <AgentExchangeView>[
          for (var index = 1; index <= 5; index++)
            AgentExchangeView(
              id: 'agent-$index',
              agent:
                  'Agent ${<String>['One', 'Two', 'Three', 'Four', 'Five'][index - 1]}',
              message: '$longMessage $index',
              sentAt: sentAt.add(Duration(minutes: index)),
              legacy: false,
            ),
        ],
        memo: longMessage,
      );

    final firstPage = state.render().split('\n');
    expect(firstPage, hasLength(7));
    expect(firstPage.first, ' >  [x] - Swipe to Select');
    expect(firstPage.any((line) => line.contains('Agent Five')), isTrue);
    expect(firstPage, contains(startsWith('     Memo -')));
    expect(firstPage.skip(1).every((line) => line.endsWith('…')), isTrue);

    for (var index = 0; index < 4; index++) {
      state.selectNext();
    }
    final selectedFourth = state.render().split('\n');
    expect(selectedFourth[1], startsWith('     Agent One -'));
    expect(selectedFourth, contains(startsWith(' >  Agent Four -')));
    expect(selectedFourth.any((line) => line.contains('Agent Five -')), isTrue);

    state.selectNext();
    final selectedFifth = state.render().split('\n');
    expect(selectedFifth[1], startsWith('     Agent One -'));
    expect(selectedFifth, contains(startsWith(' >  Agent Five -')));
    expect(selectedFifth, contains(startsWith('     Memo -')));
    expect(selectedFifth, hasLength(7));
    expect(selectedFifth.first, '     [x] - Swipe to Select');
    expect(selectedFifth.join('\n'), isNot(contains(RegExp(r'\d+/\d+'))));
  });

  test('selector moves only the cursor while every entry stays visible', () {
    final longMessage = List<String>.filled(30, 'synthetic-content').join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux', 'Pike', 'Vale', 'Brock'],
        exchanges: <AgentExchangeView>[
          for (final agent in <String>['Flux', 'Pike', 'Vale', 'Brock'])
            AgentExchangeView(
              id: agent.toLowerCase(),
              agent: agent,
              message: longMessage,
              sentAt: sentAt,
              legacy: false,
            ),
        ],
        memo: longMessage,
      );

    state.selectNext();
    expect(state.selected?.label, 'Flux');
    expect(state.render().split('\n')[1], startsWith(' >  Flux -'));

    state.selectNext();
    expect(state.selected?.label, 'Pike');
    expect(state.render().split('\n')[1], startsWith('     Flux -'));
    expect(state.render(), contains(' >  Pike -'));
    expect(state.render(), contains('Vale -'));

    state.selectNext();
    expect(state.selected?.label, 'Vale');
    expect(state.render().split('\n')[1], startsWith('     Flux -'));
    expect(state.render(), contains(' >  Vale -'));

    state.selectNext();
    expect(state.selected?.label, 'Brock');
    expect(state.render().split('\n')[1], startsWith('     Flux -'));
    expect(state.render(), contains('Flux -'));
    expect(state.render(), contains(' >  Brock -'));
    expect(state.render(), contains('Memo -'));

    state.selectNext();
    expect(state.selected?.label, 'Memo');
    expect(state.render().split('\n')[1], startsWith('     Flux -'));
    expect(state.render(), contains(' >  Memo -'));

    state.selectPrevious();
    expect(state.selected?.label, 'Brock');
    expect(state.render().split('\n')[1], startsWith('     Flux -'));
    expect(state.render(), contains(' >  Brock -'));

    state.selectPrevious();
    expect(state.selected?.label, 'Vale');
    expect(state.render().split('\n')[1], startsWith('     Flux -'));
    expect(state.render(), contains(' >  Vale -'));

    state.selectPrevious();
    expect(state.selected?.label, 'Pike');
    expect(state.render().split('\n')[1], startsWith('     Flux -'));
    expect(state.render(), contains(' >  Pike -'));
    expect(state.render(), contains('Pike -'));
    expect(state.render(), isNot(contains(RegExp(r'\d+/\d+'))));
  });

  test('selector keeps mixed-length previews to one row each', () {
    final longMessage = List<String>.filled(30, 'synthetic-content').join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux', 'Pike', 'Vale', 'Brock', 'Nova'],
        exchanges: <AgentExchangeView>[
          for (final agent in <String>['Flux', 'Pike', 'Vale', 'Brock', 'Nova'])
            AgentExchangeView(
              id: agent.toLowerCase(),
              agent: agent,
              message: agent == 'Pike' || agent == 'Brock'
                  ? longMessage
                  : 'short update',
              sentAt: sentAt,
              legacy: false,
            ),
        ],
        memo: longMessage,
      );

    for (var index = 0; index < 5; index++) {
      state.selectNext();
    }
    expect(state.selected?.label, 'Nova');
    expect(state.render(), contains('Flux -'));
    expect(state.render(), contains(' >  Nova -'));
    expect(state.render(), contains('Memo -'));
    final rows = state.render().split('\n');
    expect(rows, hasLength(7));
    expect(rows[1], startsWith('     Flux -'));
    expect(rows, contains(startsWith('     Memo -')));
    expect(rows.skip(1).every((line) => line.isNotEmpty), isTrue);
  });

  test('long Memo detail pages forward and backward without wrapping', () {
    final memo = List<String>.generate(
      120,
      (index) => 'memo${index.toString().padLeft(3, '0')}',
    ).join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: const <AgentExchangeView>[],
        memo: memo,
      )
      ..selectNext()
      ..selectNext()
      ..showSelectedDetail();

    expect(state.detailPageCount, greaterThan(1));
    expect(state.detailPageIndex, 0);
    expect(state.selectPreviousDetailPage(), isFalse);
    final firstPageLastRow = state.render().split('\n').last;
    expect(state.selectNextDetailPage(), isTrue);
    expect(state.detailPageIndex, 1);
    expect(state.render().split('\n')[1], firstPageLastRow);
    expect(state.selectPreviousDetailPage(), isTrue);
    expect(state.detailPageIndex, 0);

    while (state.selectNextDetailPage()) {}
    expect(state.detailPageIndex, state.detailPageCount - 1);
    expect(state.render(), contains('memo119'));
    expect(state.selectNextDetailPage(), isFalse);
  });

  test('long cached agent response uses the same detail pager', () {
    final response = List<String>.generate(
      120,
      (index) => 'result${index.toString().padLeft(3, '0')}',
    ).join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'pike-exchange',
            agent: 'Pike',
            message: 'report synthetic progress',
            response: response,
            sentAt: sentAt,
            legacy: false,
          ),
        ],
      )
      ..selectNext()
      ..showSelectedDetail();

    expect(state.detailPageCount, greaterThan(1));
    expect(
      state.render(),
      startsWith('   [Pike]\n> • Listen Mode - Tap to start\n'),
    );
    while (state.selectNextDetailPage()) {}
    expect(
      state.render(),
      startsWith('   [Pike]\n> • Listen Mode - Tap to start\n'),
    );
    expect(state.render(), contains('result119'));
    expect(state.render().split('\n'), hasLength(9));
  });

  test(
    'agent detail shows every retained conversation and pages both ways',
    () {
      final exchanges = <AgentExchangeView>[
        for (var index = 0; index < 6; index++)
          AgentExchangeView(
            id: 'pike-$index',
            agent: 'Pike',
            message: 'synthetic request $index with enough detail to wrap',
            response: 'synthetic response $index with enough detail to wrap',
            sentAt: sentAt.add(Duration(minutes: index)),
            legacy: false,
          ),
      ];
      final state = G2AgentHistoryState()
        ..open(agents: const <String>['Pike'], exchanges: exchanges)
        ..selectNext()
        ..showAgentConversations(exchanges);

      expect(state.detailPageCount, greaterThan(1));
      expect(state.selectedSpeechAgent, isNull);
      expect(state.selectDetailListenMode(), isTrue);
      expect(state.selectedSpeechAgent, 'Pike');
      expect(
        state.render(),
        startsWith(
          '   [Pike]\n'
          '< • Listen Mode - Tap to stop\n',
        ),
      );
      final pages = <String>[state.render()];
      while (state.selectNextDetailPage()) {
        pages.add(state.render());
      }
      expect(state.detailListenModeSelected, isTrue);
      expect(state.selectedSpeechAgent, 'Pike');
      final rendered = pages.join('\n');
      expect(rendered, contains('synthetic request 5'));
      expect(rendered, contains('synthetic response 0'));
      expect(rendered, contains('synthetic request 0'));
      expect(state.selectPreviousDetailPage(), isTrue);
    },
  );

  test('detail pages preserve carriage returns and paragraph breaks', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Pike'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'pike-exchange',
            agent: 'Pike',
            message: 'report synthetic progress',
            response:
                'First result\r\nSecond result\rThird result\n\nFinal paragraph.',
            sentAt: sentAt,
            legacy: false,
          ),
        ],
      )
      ..selectNext()
      ..showSelectedDetail();

    expect(
      state.render(),
      contains(
        '   [Pike]\n> • Listen Mode - Tap to start\n${stamp(sentAt)} '
        'report synthetic progress\n${stamp(sentAt)} First result\n'
        'Second result\nThird result\n\n'
        'Final paragraph.',
      ),
    );
  });

  test('shows the agent name once in selector and detail rows', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'flux-exchange',
            agent: 'Flux',
            message: 'Flux: inspect the synthetic build',
            response: 'Flux: synthetic build is ready',
            sentAt: sentAt,
            legacy: false,
          ),
        ],
      )
      ..selectNext();

    expect(state.render(), contains(' >  Flux - inspect the synthetic build'));
    expect(state.render(), isNot(contains('Flux - Flux:')));

    state.showSelectedDetail();
    expect(
      state.render(),
      startsWith('   [Flux]\n> • Listen Mode - Tap to start\n'),
    );
    expect(
      state.render(),
      contains('${stamp(sentAt)} synthetic build is ready'),
    );
    expect(state.render(), isNot(contains('Flux: Flux:')));
    expect(state.render(), isNot(contains('Flux: synthetic build is ready')));
    expect(state.render(), isNot(contains('Agent:')));
  });

  test('lists every response update by timestamp without speaker labels', () {
    final firstResponseAt = sentAt.add(const Duration(seconds: 30));
    final finalResponseAt = sentAt.add(const Duration(minutes: 1));
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'flux-exchange',
            agent: 'Flux',
            message: 'Flux: inspect the synthetic build',
            sentAt: sentAt,
            legacy: false,
            response: 'Flux: synthetic build is ready',
            responseAt: finalResponseAt,
            responseMessages: <AgentResponseView>[
              AgentResponseView(
                message: 'Flux: inspection in progress',
                receivedAt: firstResponseAt,
              ),
              AgentResponseView(
                message: 'Flux: synthetic build is ready',
                receivedAt: finalResponseAt,
              ),
            ],
          ),
        ],
      )
      ..selectNext()
      ..showSelectedDetail();

    final rendered = state.render();
    expect(rendered, contains('${stamp(sentAt)} inspect the synthetic build'));
    expect(
      rendered,
      contains('${stamp(firstResponseAt)} inspection in progress'),
    );
    expect(
      rendered,
      contains('${stamp(finalResponseAt)} synthetic build is ready'),
    );
    expect(
      rendered.indexOf('synthetic build is ready'),
      lessThan(rendered.indexOf('inspection in progress')),
    );
    expect(
      rendered.indexOf('inspection in progress'),
      lessThan(rendered.indexOf('inspect the synthetic build')),
    );
    expect(rendered, isNot(contains('You:')));
    expect(rendered, isNot(contains('Flux: inspection')));
  });

  test('loads the same newest-first agent messages as the phone tab', () {
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showAgentMessages(<AgentMessageView>[
        AgentMessageView(
          id: 'sent-oldest',
          agent: 'Flux',
          direction: AgentMessageDirection.sent,
          message: 'Flux: inspect the synthetic build',
          updatedAt: sentAt,
        ),
        AgentMessageView(
          id: 'received-newest',
          agent: 'Flux',
          direction: AgentMessageDirection.received,
          message: 'Flux: synthetic build is ready',
          updatedAt: sentAt.add(const Duration(minutes: 2)),
        ),
        AgentMessageView(
          id: 'received-middle',
          agent: 'Flux',
          direction: AgentMessageDirection.received,
          message: 'Flux: inspection in progress',
          updatedAt: sentAt.add(const Duration(minutes: 1)),
        ),
        AgentMessageView(
          id: 'other-agent',
          agent: 'Pike',
          direction: AgentMessageDirection.received,
          message: 'Pike: unrelated synthetic update',
          updatedAt: sentAt.add(const Duration(minutes: 3)),
        ),
      ]);

    final rendered = state.render();
    expect(
      rendered.indexOf('synthetic build is ready'),
      lessThan(rendered.indexOf('inspection in progress')),
    );
    expect(
      rendered.indexOf('inspection in progress'),
      lessThan(rendered.indexOf('inspect the synthetic build')),
    );
    expect(rendered, isNot(contains('unrelated synthetic update')));
    expect(rendered, isNot(contains('Flux: synthetic build is ready')));
  });

  test('does not truncate retained conversation messages between pages', () {
    final response = List<String>.generate(
      1800,
      (index) => 'history${index.toString().padLeft(4, '0')}',
    ).join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux'],
        exchanges: <AgentExchangeView>[
          AgentExchangeView(
            id: 'flux-long-history',
            agent: 'Flux',
            message: 'inspect complete retained history',
            response: response,
            sentAt: sentAt,
            legacy: false,
          ),
        ],
      )
      ..selectNext()
      ..showSelectedDetail();

    while (state.selectNextDetailPage()) {}

    expect(state.render(), contains('history1799'));
  });

  test(
    'long targeted transcript uses every page without truncating its tail',
    () {
      final transcript = List<String>.generate(
        120,
        (index) => 'spoken${index.toString().padLeft(3, '0')}',
      ).join(' ');
      final state = G2AgentHistoryState()
        ..open(
          agents: const <String>['Pike'],
          exchanges: const <AgentExchangeView>[],
        )
        ..selectNext()
        ..showSelectedDetail()
        ..selectDetailListenMode()
        ..beginTargetedSpeech('segment-long');

      expect(
        state.showTargetedSpeechTranscript(
          segmentId: 'segment-long',
          transcript: transcript,
        ),
        isTrue,
      );
      expect(state.detailPageCount, greaterThan(1));
      expect(state.render().split('\n'), hasLength(9));

      while (state.selectNextDetailPage()) {}

      expect(state.render(), contains('spoken119'));
      expect(state.render().split('\n'), hasLength(9));
    },
  );

  test('live transcript accumulation follows the newest visible page', () {
    final transcript = List<String>.generate(
      120,
      (index) => 'live${index.toString().padLeft(3, '0')}',
    ).join(' ');
    final state = G2AgentHistoryState()
      ..open(
        agents: const <String>['Flux'],
        exchanges: const <AgentExchangeView>[],
      )
      ..selectNext()
      ..showSelectedDetail()
      ..selectDetailListenMode()
      ..beginTargetedSpeech('manual-session');

    expect(
      state.updateTargetedSpeechTranscript(
        segmentId: 'manual-session',
        transcript: transcript,
      ),
      isTrue,
    );
    expect(state.detailPageCount, greaterThan(1));
    expect(state.detailPageIndex, state.detailPageCount - 1);
    expect(state.render(), contains('live119'));
    expect(state.detailSpeechState, G2AgentDetailSpeechState.listening);
  });
}
