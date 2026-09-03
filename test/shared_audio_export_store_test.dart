import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/workbench_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('restores a persisted shared folder without exposing its URI', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{
          'displayName': 'Work Bench Audio',
        },
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);

    await store.initialize();

    expect(store.folder?.displayName, 'Work Bench Audio');
    expect(store.hasSharedFolder, isTrue);
    expect(store.transcripts, isEmpty);
    expect(store.messages, isEmpty);
  });

  test('keeps the current folder when the picker is cancelled', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Current'},
        'chooseDirectory' => null,
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    await store.initialize();

    expect(await store.chooseFolder(), isNull);
    expect(store.folder?.displayName, 'Current');
  });

  test('exports only final WAV and text files once', () async {
    List<String>? exportedPaths;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'exportFiles' => () {
          exportedPaths =
              ((call.arguments as Map<Object?, Object?>)['paths']!
                      as List<Object?>)
                  .cast<String>();
          return exportedPaths!.length;
        }(),
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    await store.initialize();

    final count = await store.exportFiles(<String>[
      '/private/segment.wav',
      '/private/segment.wav',
      '/private/segment.txt',
      '/private/segment.part.wav',
      '/private/transcripts.jsonl',
    ]);

    expect(count, 2);
    expect(exportedPaths, <String>[
      '/private/segment.wav',
      '/private/segment.txt',
    ]);
  });

  test(
    'reads and writes correction instructions in the shared folder',
    () async {
      String? savedInstructions;
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'currentDirectory' => <String, Object>{'displayName': 'Shared'},
          'readCorrectionInstructions' => 'Preserve device names exactly.',
          'writeCorrectionInstructions' => () {
            savedInstructions =
                (call.arguments as Map<Object?, Object?>)['instructions']
                    as String;
            return null;
          }(),
          _ => fail('Unexpected method ${call.method}'),
        };
      });
      final store = SharedAudioExportStore(channel: channel, isAndroid: true);
      addTearDown(store.dispose);
      await store.initialize();

      expect(
        await store.readCorrectionInstructions(),
        'Preserve device names exactly.',
      );
      await store.writeCorrectionInstructions('Keep command names unchanged.');

      expect(savedInstructions, 'Keep command names unchanged.');
      expect(
        SharedAudioExportStore.correctionPromptFileName,
        'workbench-correction-prompt.txt',
      );
    },
  );

  test('does not read or write a prompt without a selected folder', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => null,
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    await store.initialize();

    expect(await store.readCorrectionInstructions(), isNull);
    await expectLater(
      store.writeCorrectionInstructions('Validated prompt.'),
      throwsStateError,
    );
  });

  test(
    'reads and writes shared recovery settings without interpretation',
    () async {
      String? savedServerSettings;
      Uint8List? savedSignatures;
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'currentDirectory' => <String, Object>{'displayName': 'Shared'},
          'readAgentServerSettings' => '{"version":1,"agentServers":[]}',
          'writeAgentServerSettings' => () {
            savedServerSettings =
                (call.arguments as Map<Object?, Object?>)['settings'] as String;
            return null;
          }(),
          'readSpeakerSignatureRecovery' => Uint8List.fromList(<int>[1, 2, 3]),
          'writeSpeakerSignatureRecovery' => () {
            savedSignatures =
                (call.arguments as Map<Object?, Object?>)['recovery']
                    as Uint8List;
            return null;
          }(),
          'suggestAgentNames' => <Object?>['Flux'],
          _ => fail('Unexpected method ${call.method}'),
        };
      });
      final store = SharedAudioExportStore(channel: channel, isAndroid: true);
      addTearDown(store.dispose);
      await store.initialize();

      expect(
        await store.readAgentServerSettings(),
        '{"version":1,"agentServers":[]}',
      );
      await store.writeAgentServerSettings('server-settings');
      expect(savedServerSettings, 'server-settings');
      expect(await store.readSpeakerSignatureRecovery(), <int>[1, 2, 3]);
      await store.writeSpeakerSignatureRecovery(
        Uint8List.fromList(<int>[4, 5]),
      );
      expect(savedSignatures, <int>[4, 5]);
      expect(await store.suggestAgentNames(), <String>['Flux']);
      expect(
        SharedAudioExportStore.agentServerSettingsFileName,
        'workbench-agent-servers.json',
      );
      expect(
        SharedAudioExportStore.speakerSignatureRecoveryFileName,
        'workbench-speaker-signatures.wbprofiles',
      );
    },
  );

  test('clears shared folder access', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'clearDirectory' => null,
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    await store.initialize();

    await store.clearFolder();

    expect(store.folder, isNull);
    expect(store.hasSharedFolder, isFalse);
  });

  test('loads saved transcripts and controls shared WAV playback', () async {
    final calls = <String>[];
    final transcriptReconciliations = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'listTranscriptions' => () {
          transcriptReconciliations.add(
            (call.arguments as Map<Object?, Object?>)['reconcileShared']
                as bool,
          );
          return <Object?>[
            <Object?, Object?>{
              'id': 'older',
              'originalText': 'Older raw transcript',
              'correctedText': 'Older transcript',
              'audioFileName': 'older.wav',
              'updatedAtMillis': 1000,
            },
            <Object?, Object?>{
              'id': 'newer',
              'originalText': 'Newer raw transcript',
              'correctedText': 'Newer transcript',
              'audioFileName': 'newer.wav',
              'updatedAtMillis': 2000,
            },
            <Object?, Object?>{
              'id': 'invalid',
              'originalText': '',
              'updatedAtMillis': 3000,
            },
          ];
        }(),
        'playAudio' => null,
        'stopAudio' => null,
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);

    await store.initialize();
    expect(store.transcripts, isEmpty);
    await store.refreshTranscriptions();
    await store.refreshTranscriptions(reconcileShared: true);

    expect(store.transcripts.map((transcript) => transcript.text), <String>[
      'Newer transcript',
      'Older transcript',
    ]);
    expect(transcriptReconciliations, <bool>[false, true]);
    final newest = store.transcripts.first;
    await store.toggleAudio(newest);
    expect(store.playingAudioFileName, 'newer.wav');

    await store.toggleAudio(newest);
    expect(store.playingAudioFileName, isNull);
    expect(calls, containsAllInOrder(<String>['playAudio', 'stopAudio']));
  });

  test('loads sent and received WebSocket messages newest first', () async {
    final messageReconciliations = <bool>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'listMessages' => () {
          messageReconciliations.add(
            (call.arguments as Map<Object?, Object?>)['reconcileShared']
                as bool,
          );
          return <Object?>[
            <Object?, Object?>{
              'id': 'older.sent.message.txt',
              'direction': 'sent',
              'text': 'Agent One: Start the task.',
              'updatedAtMillis': 1000,
            },
            <Object?, Object?>{
              'id': 'newer.received.message.txt',
              'direction': 'received',
              'text': 'Agent One: Task complete.',
              'updatedAtMillis': 2000,
            },
            <Object?, Object?>{
              'id': 'invalid.message.txt',
              'direction': 'unknown',
              'text': 'Ignore this record.',
              'updatedAtMillis': 3000,
            },
          ];
        }(),
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);

    await store.initialize();
    await store.refreshMessages();
    await store.refreshMessages(reconcileShared: true);

    expect(store.messages.map((message) => message.text), <String>[
      'Agent One: Task complete.',
      'Agent One: Start the task.',
    ]);
    expect(
      store.messages.map((message) => message.direction),
      <SharedWebSocketMessageDirection>[
        SharedWebSocketMessageDirection.received,
        SharedWebSocketMessageDirection.sent,
      ],
    );
    expect(messageReconciliations, <bool>[false, true]);
  });

  test('bounds all in-memory history collections to recent content', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'listTranscriptions' => List<Object?>.generate(
          125,
          (index) => <Object?, Object?>{
            'id': 'transcript-$index',
            'originalText': 'Transcript $index',
            'updatedAtMillis': index,
          },
        ),
        'listMessages' => List<Object?>.generate(
          125,
          (index) => <Object?, Object?>{
            'id': 'message-$index',
            'direction': 'received',
            'text': 'Message $index',
            'updatedAtMillis': index,
          },
        ),
        'listConversations' => List<Object?>.generate(
          125,
          (index) => <Object?, Object?>{
            'id': 'turn-$index',
            'conversationId': 'sample',
            'speakerId': 'speaker',
            'speakerLabel': 'Speaker',
            'text': 'Turn $index',
            'startMs': index * 1000,
            'endMs': (index + 1) * 1000,
            'confidence': 0.9,
            'updatedAtMillis': index,
            'isPrimary': false,
            'isOverlap': false,
          },
        ),
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);

    await store.initialize();
    await store.refreshTranscriptions();
    await store.refreshMessages();
    await store.refreshConversations();

    expect(
      store.transcripts,
      hasLength(SharedAudioExportStore.maximumVisibleTranscripts),
    );
    expect(store.transcripts.first.id, 'transcript-124');
    expect(
      store.messages,
      hasLength(SharedAudioExportStore.maximumVisibleMessages),
    );
    expect(store.messages.first.id, 'message-124');
    expect(
      store.conversations,
      hasLength(SharedAudioExportStore.maximumVisibleConversationTurns),
    );
    expect(store.conversations.first.id, 'turn-25');
    expect(store.conversations.last.id, 'turn-124');
  });

  test('indexes and loads speaker conversation turns from SQLite', () async {
    List<Object?>? indexedTurns;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => null,
        'indexConversation' => () {
          indexedTurns =
              (call.arguments as Map<Object?, Object?>)['turns']!
                  as List<Object?>;
          return null;
        }(),
        'listConversations' => <Object?>[
          <Object?, Object?>{
            'id': 'turn-2',
            'conversationId': 'sample',
            'speakerId': 'speaker-2',
            'speakerLabel': 'Speaker 2',
            'text': 'Second synthetic turn.',
            'startMs': 1200,
            'endMs': 2400,
            'confidence': 0.8,
            'updatedAtMillis': 2000,
            'isPrimary': false,
            'isOverlap': false,
          },
          <Object?, Object?>{
            'id': 'turn-1',
            'conversationId': 'sample',
            'speakerId': 'primary-user',
            'speakerLabel': 'You',
            'text': 'First synthetic turn.',
            'startMs': 0,
            'endMs': 1000,
            'confidence': 0.9,
            'updatedAtMillis': 1000,
            'isPrimary': true,
            'isOverlap': false,
          },
        ],
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    await store.initialize();
    final now = DateTime.fromMillisecondsSinceEpoch(1000);
    await store.indexConversation(
      ConversationRecord(
        id: 'sample',
        audioPath: '/private/sample.wav',
        textPath: '/private/sample.conversation.txt',
        metadataPath: '/private/sample.conversation.json',
        updatedAt: now,
        utterances: <ConversationUtterance>[
          ConversationUtterance(
            id: 'turn-1',
            conversationId: 'sample',
            speakerId: 'primary-user',
            speakerLabel: 'You',
            text: 'First synthetic turn.',
            startMs: 0,
            endMs: 1000,
            confidence: 0.9,
            updatedAt: now,
            isPrimary: true,
          ),
        ],
      ),
    );

    expect(indexedTurns, hasLength(1));
    expect(
      (indexedTurns!.single as Map<Object?, Object?>)['speakerLabel'],
      'You',
    );
    expect(store.conversations.map((turn) => turn.speakerLabel), <String>[
      'You',
      'Speaker 2',
    ]);
    expect(store.conversations.first.isPrimary, isTrue);
  });

  test(
    'reports shared-folder read failures without dropping the grant',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'currentDirectory' => <String, Object>{'displayName': 'Shared'},
          'listTranscriptions' => throw PlatformException(code: 'list_failed'),
          _ => fail('Unexpected method ${call.method}'),
        };
      });
      final store = SharedAudioExportStore(channel: channel, isAndroid: true);
      addTearDown(store.dispose);

      await store.initialize();
      await expectLater(
        store.refreshTranscriptions(),
        throwsA(isA<PlatformException>()),
      );

      expect(store.folder?.displayName, 'Shared');
      expect(store.transcriptLoadError, contains('Could not read'));
      expect(store.isLoadingTranscripts, isFalse);
    },
  );

  test('clears optimistic playback state when native playback fails', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'playAudio' => throw PlatformException(code: 'audio_playback'),
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    final store = SharedAudioExportStore(channel: channel, isAndroid: true);
    addTearDown(store.dispose);
    final transcript = SharedTranscript(
      id: 'sample',
      originalText: 'Generic sample transcript',
      audioFileName: 'sample.wav',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    await expectLater(
      store.toggleAudio(transcript),
      throwsA(isA<PlatformException>()),
    );

    expect(store.playingAudioFileName, isNull);
  });
}
