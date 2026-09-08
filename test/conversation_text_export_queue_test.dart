import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/conversation_record_store.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_text_export_queue.dart';
import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/workbench_text_export_queue');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  late ConversationRecordStore records;
  late SharedAudioExportStore shared;
  late ConversationTextExportQueue queue;
  late Future<int> Function(List<String>) export;
  var failures = 0;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('workbench-text-export.');
    records = ConversationRecordStore(supportDirectory: () async => temporary);
    await records.initialize();
    failures = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'currentDirectory' => <String, Object>{'displayName': 'Shared'},
        'exportFiles' => export(
          ((call.arguments as Map<Object?, Object?>)['paths'] as List<Object?>)
              .cast<String>(),
        ),
        _ => fail('Unexpected method ${call.method}'),
      };
    });
    shared = SharedAudioExportStore(channel: channel, isAndroid: true);
    await shared.initialize();
    queue = ConversationTextExportQueue(
      recordStore: records,
      exportStore: shared,
      onFailure: () => failures++,
    );
    await queue.initialize();
  });

  tearDown(() async {
    await queue.dispose();
    shared.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  test('migration restores retained text without waiting for export', () async {
    await queue.dispose();
    final text = File('${temporary.path}/legacy.conversation.txt')
      ..writeAsStringSync('Synthetic retained conversation.');
    await records.retainRecord(
      ConversationRecord(
        id: 'legacy',
        audioPath: '${temporary.path}/legacy.wav',
        textPath: text.path,
        metadataPath: '${temporary.path}/legacy.conversation.json',
        utterances: const <ConversationUtterance>[],
        updatedAt: DateTime.utc(2026),
      ),
    );
    await File(
      '${temporary.path}/workbench/conversation/pending-exports.json',
    ).delete();
    final blocked = Completer<void>();
    var calls = 0;
    export = (paths) async {
      calls++;
      expect(paths, <String>[text.path]);
      await blocked.future;
      return paths.length;
    };
    addTearDown(() {
      if (!blocked.isCompleted) blocked.complete();
    });
    queue = ConversationTextExportQueue(
      recordStore: records,
      exportStore: shared,
      onFailure: () => failures++,
    );
    await queue.initialize().timeout(const Duration(seconds: 1));
    await _waitUntil(() async => calls == 1);
    expect(blocked.isCompleted, isFalse);
    expect((await records.loadPendingTextExports()).keys, <String>[text.path]);
    blocked.complete();
    await _waitUntil(
      () async => (await records.loadPendingTextExports()).isEmpty,
    );
  });

  test('a late export cannot clear a newer rewrite of the same text', () async {
    final blocked = Completer<void>();
    final calls = <List<String>>[];
    export = (paths) async {
      calls.add(paths);
      if (calls.length == 1) await blocked.future;
      return paths.length;
    };
    addTearDown(() {
      if (!blocked.isCompleted) blocked.complete();
    });
    final first = File('${temporary.path}/first.conversation.txt')
      ..writeAsStringSync('Synthetic first turn.');
    final second = File('${temporary.path}/second.conversation.txt')
      ..writeAsStringSync('Synthetic second turn.');
    await queue.enqueue(<String>[first.path]);
    await _waitUntil(() async => calls.length == 1);
    first.writeAsStringSync('Synthetic relabeled turn.');
    await queue.enqueue(<String>[first.path, second.path]);
    expect(calls, hasLength(1));
    expect(await records.loadPendingTextExports(), hasLength(2));
    blocked.complete();
    await _waitUntil(
      () async => (await records.loadPendingTextExports()).isEmpty,
    );
    expect(calls, <List<String>>[
      <String>[first.path],
      <String>[first.path, second.path],
    ]);
    expect(failures, 0);
    expect(await first.readAsString(), 'Synthetic relabeled turn.');
  });

  for (final neverReplies in <bool>[false, true]) {
    test(
      'restart restores exports after ${neverReplies ? 'an unanswered call' : 'a failure'}',
      () async {
        final blocked = Completer<void>();
        var calls = 0;
        export = (paths) async {
          calls++;
          if (neverReplies) {
            await blocked.future;
            return paths.length;
          }
          throw PlatformException(code: 'synthetic_export_failure');
        };
        final file = File('${temporary.path}/pending.conversation.txt')
          ..writeAsStringSync('Synthetic retained speech.');
        await queue.enqueue(<String>[file.path]);
        await _waitUntil(() async => neverReplies ? calls == 1 : failures == 1);
        await queue.dispose().timeout(const Duration(seconds: 1));
        expect((await records.loadPendingTextExports()).keys, <String>[
          file.path,
        ]);
        if (neverReplies) blocked.complete();
        final restored = ConversationRecordStore(
          supportDirectory: () async => temporary,
        );
        await restored.initialize();
        export = (paths) async {
          calls++;
          return paths.length;
        };
        queue = ConversationTextExportQueue(
          recordStore: restored,
          exportStore: shared,
          onFailure: () => failures++,
        );
        await queue.initialize().timeout(const Duration(seconds: 1));
        await _waitUntil(
          () async => (await restored.loadPendingTextExports()).isEmpty,
        );
        expect(calls, 2);
        expect(await file.exists(), isTrue);
      },
    );
  }
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Synthetic export did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
