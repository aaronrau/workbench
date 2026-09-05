import 'dart:io';

import 'package:even_g2_r1_poc/src/websocket/websocket_message_store.dart';
import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-websocket-message-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('atomically saves a normalized received message', () async {
    final store = WebSocketMessageStore(
      supportDirectory: () async => temp,
      now: () => DateTime.utc(2026, 7, 27, 12),
    );
    await store.initialize();

    final saved = await store.save(
      direction: WebSocketMessageDirection.received,
      message: '  Agent One: Task complete.\u0000\r\nSecond line.  ',
    );

    expect(saved.fileName, startsWith('workbench-websocket-'));
    expect(saved.fileName, endsWith('.received.message.txt'));
    expect(saved.direction, WebSocketMessageDirection.received);
    expect(
      store.recentMessages.single.text,
      'Agent One: Task complete.\nSecond line.',
    );
    expect(store.recentMessages.single.id, saved.fileName);
    final file = File(saved.path);
    expect(await file.exists(), isTrue);
    expect(
      await file.readAsString(),
      'Agent One: Task complete.\nSecond line.\n',
    );
    final partials = await temp
        .list(recursive: true)
        .where((entity) => entity.path.endsWith('.part.txt'))
        .toList();
    expect(partials, isEmpty);
  });

  test(
    'restores saved message paths and keeps rapid messages separate',
    () async {
      final store = WebSocketMessageStore(
        supportDirectory: () async => temp,
        now: () => DateTime.utc(2026, 7, 27, 12),
      );
      await store.initialize();

      final first = await store.save(
        direction: WebSocketMessageDirection.sent,
        message: 'Agent One: First request.',
      );
      final second = await store.save(
        direction: WebSocketMessageDirection.received,
        message: 'Agent One: Second response.',
      );
      final restored = WebSocketMessageStore(
        supportDirectory: () async => temp,
      );
      await restored.initialize();

      expect(first.path, isNot(second.path));
      expect(await restored.savedPaths(), <String>[first.path, second.path]);
      expect(restored.recentMessages.map((message) => message.id), [
        second.fileName,
        first.fileName,
      ]);
      expect(
        restored.recentMessages.first.direction,
        SharedWebSocketMessageDirection.received,
      );
      expect(
        restored.recentMessages.first.updatedAt,
        DateTime.utc(2026, 7, 27, 12),
      );
    },
  );

  test('rejects a message with no readable content', () async {
    final store = WebSocketMessageStore(supportDirectory: () async => temp);
    await store.initialize();

    await expectLater(
      store.save(
        direction: WebSocketMessageDirection.received,
        message: '\u0000\u0001',
      ),
      throwsFormatException,
    );
  });

  test(
    'local messages remain visible and deduplicate their exported copies',
    () async {
      final store = WebSocketMessageStore(supportDirectory: () async => temp);
      await store.initialize();
      await store.save(
        direction: WebSocketMessageDirection.sent,
        message: 'Agent One: Request.',
      );
      final local = store.recentMessages.single;
      final shared = SharedWebSocketMessage(
        id: local.id,
        direction: local.direction,
        text: 'Stale exported copy',
        updatedAt: local.updatedAt,
      );
      expect(
        mergeMessageHistory([shared], store.recentMessages).single.text,
        local.text,
      );
      expect(
        mergeMessageHistory([], store.recentMessages).single.text,
        local.text,
      );
    },
  );
}
