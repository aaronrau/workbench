import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/conversation_record_store.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:even_g2_r1_poc/src/audio/moss_speaker_matcher.dart';
import 'package:even_g2_r1_poc/src/audio/moss_audio.dart';
import 'package:even_g2_r1_poc/src/audio/moss_conversation_archive.dart';
import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _annotated =
    '[0.10][S01]First synthetic phrase.[1.20]'
    '[0.80][S02]Second synthetic phrase.[1.80]';

Future<File> _source(
  Directory support,
  String id, {
  MossQuantization model = MossQuantization.q5K,
  String annotated = _annotated,
}) async {
  final source = Directory('${support.path}/workbench/audio/moss');
  await source.create(recursive: true);
  await File('${source.path}/$id.wav').writeAsBytes(mossWav(Uint8List(64000)));
  await File('${source.path}/$id.raw.txt').writeAsString(annotated);
  final metadata = File('${source.path}/$id.moss.json');
  await metadata.writeAsString(
    jsonEncode({
      'model': model.modelId,
      'model_sha256': model.sha256,
      'speaker_scope': id,
      'audio_ms': 2000,
      'utterances': parseMossTranscript(
        annotated,
        audioSeconds: 2,
      ).map((turn) => turn.toJson()).toList(),
    }),
  );
  return metadata;
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 1000; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Conversation operation did not complete');
}

final class _Signatures implements MossSpeakerSignatureExtractor {
  final outputs = <Completer<Map<String, List<double>>>>[];
  @override
  Future<Map<String, List<double>>> extract(ConversationRecord record) {
    final result = Completer<Map<String, List<double>>>();
    outputs.add(result);
    return result.future;
  }

  @override
  Future<void> dispose() async {
    for (final result in outputs) {
      if (!result.isCompleted) result.complete({});
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'voice matching cannot block saves; restart reuses private signatures when saved labels change',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'workbench-moss-voices.',
      );
      final shared = SharedAudioExportStore(isAndroid: false);
      final fake = _Signatures();
      var label = 'Speaker 2';
      List<SpeakerProfile> profiles() => [
        SpeakerProfile(
          id: 'primary',
          label: 'You',
          embedding: [1, 0],
          sampleCount: 3,
          isPrimary: true,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        SpeakerProfile(
          id: 'second',
          label: label,
          embedding: [0, 1],
          sampleCount: 3,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ];
      MossConversationArchive create() => MossConversationArchive(
        sharedStore: shared,
        onChanged: () {},
        onStatus: (_, {bool isError = false}) {},
        supportDirectory: () async => support,
        speakerProfilesProvider: profiles,
        speakerExtractorFactory: () => fake,
      );
      var archive = create();
      addTearDown(() async {
        await archive.dispose();
        await fake.dispose();
        shared.dispose();
        await support.delete(recursive: true);
      });
      archive.accept((await _source(support, 'first')).path);
      await archive.drainImports();
      await _until(() => fake.outputs.length == 1);
      archive.accept((await _source(support, 'second')).path);
      await archive.drainImports().timeout(const Duration(seconds: 2));
      await _until(() => shared.conversations.length == 4);
      expect(shared.conversations.every((turn) => !turn.isPrimary), isTrue);
      fake.outputs[0].complete({
        'S01': [1, 0],
        'S02': [0, 1],
      });
      await _until(() => fake.outputs.length == 2);
      fake.outputs[1].complete({
        'S01': [1, 0],
        'S02': [0, 1],
      });
      await _until(
        () =>
            shared.conversations
                    .where((turn) => turn.speakerId == 'primary')
                    .length ==
                2 &&
            archive.pendingCount == 0,
      );
      for (final id in ['first', 'second']) {
        expect(
          await File(
            '${support.path}/workbench/audio/moss/$id.raw.txt',
          ).readAsString(),
          _annotated,
        );
      }
      await archive.dispose();
      label = 'Saved guest';
      archive = create();
      await archive.recover();
      await _until(
        () =>
            shared.conversations
                    .where((turn) => turn.speakerLabel == label)
                    .length ==
                2 &&
            archive.pendingCount == 0,
      );
      expect(fake.outputs, hasLength(2));
      final store = ConversationRecordStore(
        supportDirectory: () async => support,
        namespace: 'moss',
      );
      await store.initialize();
      expect(
        (await store.readRecord('moss-first'))!.speakerIdentificationVersion,
        1,
      );
    },
  );

  test('Q5 and Q4 save scoped speaker turns and preserve legacy storage', () async {
    final support = await Directory.systemTemp.createTemp(
      'workbench-moss-archive.',
    );
    final legacy = ConversationRecordStore(
      supportDirectory: () async => support,
    );
    await legacy.initialize();
    await legacy.savePendingJobs([]);
    await legacy.saveProfiles([]);
    await legacy.savePendingTextExports({
      'synthetic-legacy.conversation.txt': 7,
    });
    final legacyFiles = <String, String>{
      for (final file in Directory(
        '${support.path}/workbench/conversation',
      ).listSync().whereType<File>())
        file.path: await file.readAsString(),
    };
    final shared = SharedAudioExportStore(isAndroid: false);
    final logs = <String>[];
    final archive = MossConversationArchive(
      sharedStore: shared,
      onChanged: () {},
      onStatus: (message, {bool isError = false}) => logs.add(message),
      supportDirectory: () async => support,
    );
    addTearDown(() async {
      await archive.dispose();
      shared.dispose();
      await support.delete(recursive: true);
    });
    for (final model in MossQuantization.values) {
      archive.accept((await _source(support, model.name, model: model)).path);
    }
    await archive.drainImports();
    await _until(() => shared.conversations.length == 4);
    expect(
      shared.conversations.map((turn) => turn.speakerId).toSet(),
      hasLength(4),
    );
    expect(shared.conversations.every((turn) => turn.isOverlap), isTrue);
    expect(
      shared.conversations.every(
        (turn) => !turn.isPrimary && turn.confidence == 0,
      ),
      isTrue,
    );
    expect(
      shared.conversations.map((turn) => turn.startMs),
      containsAll([100, 800]),
    );
    expect(
      shared.conversations.map((turn) => turn.endMs),
      containsAll([1200, 1800]),
    );
    for (final model in MossQuantization.values) {
      final base = '${support.path}/workbench/audio/moss/${model.name}';
      expect(await File('$base.raw.txt').readAsString(), _annotated);
      expect(await File('$base.wav').length(), 64044);
      final text = await File(
        '${support.path}/workbench/audio/moss/moss-${model.name}.conversation.txt',
      ).readAsString();
      expect(text, contains('Speaker 1 (clip) [0.10–1.20]'));
      expect(text, contains('Speaker 2 (clip) [0.80–1.80]'));
      final record = await File(
        '${support.path}/workbench/conversation/moss/moss-${model.name}.conversation.json',
      ).readAsString();
      expect(record, isNot(contains('speakerSignature')));
    }
    for (final entry in legacyFiles.entries) {
      expect(await File(entry.key).readAsString(), entry.value);
    }
    expect(await legacy.loadRecords(), isEmpty);
    expect(logs.join(), isNot(contains('synthetic phrase')));
  });

  test(
    'startup backfills completed sources and restart restores a lost index without duplicates',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'workbench-moss-recover.',
      );
      final shared = SharedAudioExportStore(isAndroid: false);
      MossConversationArchive create() => MossConversationArchive(
        sharedStore: shared,
        onChanged: () {},
        onStatus: (_, {bool isError = false}) {},
        supportDirectory: () async => support,
      );
      var archive = create();
      addTearDown(() async {
        await archive.dispose();
        shared.dispose();
        await support.delete(recursive: true);
      });
      await _source(support, 'saved');
      final incomplete = await _source(support, 'incomplete');
      await File(
        incomplete.path.replaceFirst('.moss.json', '.raw.txt'),
      ).delete();
      final first = archive.recover();
      expect(identical(first, archive.recover()), isTrue);
      await first;
      await _until(() => shared.conversations.length == 2);
      final ids = shared.conversations.map((turn) => turn.id).toSet();
      expect(
        shared.conversations.every(
          (turn) => turn.conversationId == 'moss-saved',
        ),
        isTrue,
      );
      final text = File(
        '${support.path}/workbench/audio/moss/moss-saved.conversation.txt',
      );
      final record = File(
        '${support.path}/workbench/conversation/moss/moss-saved.conversation.json',
      );
      final sentinel = DateTime.utc(2025);
      await text.setLastModified(sentinel);
      await record.setLastModified(sentinel);
      await archive.dispose();
      shared.conversations = [];
      archive = create();
      await archive.recover();
      await _until(() => shared.conversations.length == 2);
      expect(shared.conversations.map((turn) => turn.id).toSet(), ids);
      expect((await text.lastModified()).toUtc(), sentinel);
      expect((await record.lastModified()).toUtc(), sentinel);
      await archive.recover();
      expect(shared.conversations, hasLength(2));
    },
  );

  test(
    'invalid and partial sources never change originals or enter history',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'workbench-moss-invalid.',
      );
      final shared = SharedAudioExportStore(isAndroid: false);
      final logs = <String>[];
      final archive = MossConversationArchive(
        sharedStore: shared,
        onChanged: () {},
        onStatus: (message, {bool isError = false}) => logs.add(message),
        supportDirectory: () async => support,
      );
      addTearDown(() async {
        await archive.dispose();
        shared.dispose();
        await support.delete(recursive: true);
      });
      for (final field in ['model_sha256', 'speaker_scope', 'utterances']) {
        final file = await _source(support, field);
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        data[field] = field == 'utterances' ? [] : 'invalid';
        await file.writeAsString(jsonEncode(data));
        archive.accept(file.path);
      }
      final malformed = await _source(support, 'malformed');
      final raw = File(malformed.path.replaceFirst('.moss.json', '.raw.txt'));
      await raw.writeAsString('Unframed synthetic text');
      archive.accept(malformed.path);
      await archive.drainImports();
      expect(shared.conversations, isEmpty);
      expect(await raw.readAsString(), 'Unframed synthetic text');
      expect(archive.error, isNotNull);
      expect(logs.join(), isNot(contains('synthetic text')));
      final saved = Directory(
        '${support.path}/workbench/conversation/moss',
      ).listSync().where((file) => file.path.endsWith('.conversation.json'));
      expect(saved, isEmpty);
    },
  );

  test(
    'stalled native index and export cannot block later durable imports or disposal',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'workbench-moss-stalled.',
      );
      const channel = MethodChannel('test/workbench_moss_archive');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final blocked = Completer<void>();
      var indexCalls = 0;
      var exportCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'currentDirectory':
            return {'displayName': 'Synthetic folder'};
          case 'indexConversation':
            indexCalls++;
            await blocked.future;
            return null;
          case 'exportFiles':
            exportCalls++;
            await blocked.future;
            return 1;
          case 'listConversations':
            return [];
          default:
            fail('Unexpected method ${call.method}');
        }
      });
      final shared = SharedAudioExportStore(channel: channel, isAndroid: true);
      await shared.initialize();
      final archive = MossConversationArchive(
        sharedStore: shared,
        onChanged: () {},
        onStatus: (_, {bool isError = false}) {},
        supportDirectory: () async => support,
      );
      addTearDown(() async {
        await archive.dispose();
        if (!blocked.isCompleted) blocked.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        shared.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        await support.delete(recursive: true);
      });
      for (var i = 0; i < 3; i++) {
        archive.accept((await _source(support, 'saved-$i')).path);
      }
      await archive.drainImports().timeout(const Duration(seconds: 3));
      await _until(() => indexCalls == 1 && exportCalls == 1);
      final records = Directory(
        '${support.path}/workbench/conversation/moss',
      ).listSync().where((file) => file.path.endsWith('.conversation.json'));
      expect(records, hasLength(3));
      final ledger =
          jsonDecode(
                await File(
                  '${support.path}/workbench/conversation/moss/pending-exports.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(ledger['paths'], hasLength(3));
      await archive.dispose().timeout(const Duration(seconds: 1));
      expect(indexCalls, 1);
      expect(exportCalls, 1);
    },
  );

  test(
    'zero-duration model turns retain text with valid millisecond bounds',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'workbench-moss-zero.',
      );
      final shared = SharedAudioExportStore(isAndroid: false);
      final archive = MossConversationArchive(
        sharedStore: shared,
        onChanged: () {},
        onStatus: (_, {bool isError = false}) {},
        supportDirectory: () async => support,
      );
      addTearDown(() async {
        await archive.dispose();
        shared.dispose();
        await support.delete(recursive: true);
      });
      archive.accept(
        (await _source(
          support,
          'zero',
          annotated: '[1][S01]Brief synthetic phrase.[1]',
        )).path,
      );
      await archive.drainImports();
      await _until(() => shared.conversations.length == 1);
      expect(shared.conversations.single.startMs, 1000);
      expect(shared.conversations.single.endMs, 1001);
      expect(shared.conversations.single.text, 'Brief synthetic phrase.');
    },
  );
}
