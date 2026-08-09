import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/gemma_correction_client.dart';
import 'package:even_g2_r1_poc/src/audio/voice_memo_models.dart';
import 'package:even_g2_r1_poc/src/audio/voice_memo_service.dart';
import 'package:even_g2_r1_poc/src/audio/voice_memo_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late _FakeGemmaClient client;
  late VoiceMemoService service;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('workbench-voice-memo-test.');
    client = _FakeGemmaClient();
    service = VoiceMemoService(
      log: (_, _, {bool isError = false}) {},
      onChanged: () {},
      store: VoiceMemoStore(supportDirectory: () async => temp),
      client: client,
      modelPathProvider: () async => '/private/synthetic-model.litertlm',
      totalSilenceDuration: const Duration(milliseconds: 120),
      closedTurnSilenceDuration: const Duration(milliseconds: 50),
      finalizationTimeout: const Duration(milliseconds: 500),
    );
    await service.initialize();
  });

  tearDown(() async {
    await service.dispose();
    temp.deleteSync(recursive: true);
  });

  test('recognizes only a leading exact local memo invocation', () {
    expect(
      MemoInvocation.parse('Hey Memo, capture this')?.body,
      'capture this',
    );
    expect(
      MemoInvocation.parse('hey, memo: capture this')?.body,
      'capture this',
    );
    expect(MemoInvocation.parse('I wrote a memo yesterday.'), isNull);
    expect(MemoInvocation.parse('Hey me mo, capture this'), isNull);
    expect(MemoInvocation.hasWakeEvidence('Hey Memo, capture this'), isTrue);
    expect(MemoInvocation.hasWakeEvidence('Hey me mo, capture this'), isTrue);
    expect(MemoInvocation.hasWakeEvidence('Hey mimo, capture this'), isTrue);
    expect(MemoInvocation.hasWakeEvidence('Hey'), isFalse);
    expect(MemoInvocation.hasWakeEvidence('Hey, capture this'), isFalse);
  });

  test(
    'iterates one travel agenda across rambling utterances and pauses',
    () async {
      client.scriptedNotes.addAll(const <String>[
        'Weekend visit plan\n'
            '- Consider a weekend trip next month; the exact weekend is open.',
        'Weekend visit plan\n'
            '- Saturday morning: visit the city museum.\n'
            '- Saturday afternoon: browse the food market.',
        'Weekend visit plan\n'
            '- Saturday morning: visit the city museum.\n'
            '- Saturday afternoon: keep the schedule open.\n'
            '- Sunday: browse the food market.',
        'Weekend visit plan\n'
            '- Saturday morning: visit the city museum.\n'
            '- Saturday afternoon: keep the schedule open.\n'
            '- Sunday: browse the food market, then take a river walk.\n'
            '- Compare train and hotel prices; keep the total under \$800.',
      ]);

      expect(
        service.acceptRawTranscript(
          'segment-1',
          'Hey Memo, hmm, I want to plan a weekend visit next month, '
              'maybe, well, I am not sure which weekend yet',
        ),
        isTrue,
      );
      expect(service.isActive, isTrue);
      expect(service.records.single.status, VoiceMemoStatus.listening);

      expect(
        await service.acceptFinalTranscript(
          'segment-1',
          'Hey Memo, hmm, I want to plan a weekend visit next month. '
              'I am not sure which weekend yet.',
        ),
        isTrue,
      );
      await _waitFor(() => service.activeMemo?.revision == 1);
      service.speechEnded('segment-1');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      service.speechStarted('segment-2');
      expect(
        service.acceptRawTranscript(
          'segment-2',
          'hmm put the city museum Saturday morning and the food market '
              'after lunch',
        ),
        isTrue,
      );
      expect(
        await service.acceptFinalTranscript(
          'segment-2',
          'Hmm, put the city museum on Saturday morning and browse the '
              'food market after lunch.',
        ),
        isTrue,
      );
      await _waitFor(() => service.activeMemo?.revision == 2);
      service.speechEnded('segment-2');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      service.speechStarted('segment-3');
      expect(
        service.acceptRawTranscript(
          'segment-3',
          'actually move the food market to Sunday and leave Saturday '
              'afternoon open',
        ),
        isTrue,
      );
      expect(
        await service.acceptFinalTranscript(
          'segment-3',
          'Actually, move the food market to Sunday and leave Saturday '
              'afternoon open.',
        ),
        isTrue,
      );
      await _waitFor(() => service.activeMemo?.revision == 3);
      service.speechEnded('segment-3');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      service.speechStarted('segment-4');
      expect(
        service.acceptRawTranscript(
          'segment-4',
          'hmm add a river walk and remember compare the train and hotel '
              'but keep it under eight hundred dollars',
        ),
        isTrue,
      );
      expect(
        await service.acceptFinalTranscript(
          'segment-4',
          'Hmm, add a river walk. Compare train and hotel prices, but keep '
              'the total under \$800.',
        ),
        isTrue,
      );
      await _waitFor(() => service.activeMemo?.revision == 4);
      service.speechEnded('segment-4');
      await _waitFor(() => !service.isActive);

      expect(client.requests, hasLength(4));
      expect(
        client.requests.every(
          (request) => request.task == GemmaTextTask.memoRevision,
        ),
        isTrue,
      );
      expect(
        client.requests.every(
          (request) => request.instructions.contains('Never invent a fact'),
        ),
        isTrue,
      );

      final secondInput =
          jsonDecode(client.requests[1].transcript) as Map<String, Object?>;
      final finalInput =
          jsonDecode(client.requests.last.transcript) as Map<String, Object?>;
      expect(secondInput['currentNote'], client.scriptedNotesUsed.first);
      expect((finalInput['utterances']! as List<Object?>), hasLength(4));
      expect(finalInput['currentNote'], client.scriptedNotesUsed[2]);

      final memo = service.records.single;
      expect(memo.status, VoiceMemoStatus.finalized);
      expect(memo.revision, 4);
      expect(memo.sources, hasLength(4));
      expect(memo.note, client.scriptedNotesUsed.last);
      expect(memo.note, isNot(contains('hmm')));
      expect(memo.note, contains('Sunday: browse the food market'));
      expect(memo.note, contains('under \$800'));
    },
  );

  test('uses a memo-specific Gemma task and iterates the same note', () async {
    expect(
      service.acceptRawTranscript(
        'segment-1',
        'Hey Memo, the first rough thought',
      ),
      isTrue,
    );
    expect(service.isActive, isTrue);
    expect(service.records.single.status, VoiceMemoStatus.listening);

    expect(
      await service.acceptFinalTranscript(
        'segment-1',
        'Hey Memo, the first clear thought.',
      ),
      isTrue,
    );
    await _waitFor(() => service.activeMemo?.revision == 1);

    service.speechStarted('segment-2');
    expect(
      service.acceptRawTranscript('segment-2', 'and a second rough item'),
      isTrue,
    );
    expect(
      await service.acceptFinalTranscript(
        'segment-2',
        'Add a second clear item.',
      ),
      isTrue,
    );
    await _waitFor(() => service.activeMemo?.revision == 2);

    expect(client.requests, hasLength(2));
    expect(
      client.requests.every(
        (request) => request.task == GemmaTextTask.memoRevision,
      ),
      isTrue,
    );
    expect(client.requests.last.instructions, contains('Never invent a fact'));
    expect(
      service.activeMemo?.note,
      'Project note\n- the first clear thought.\n- Add a second clear item.',
    );
  });

  test('corrected wake phrase activates when raw ASR misses it', () async {
    expect(
      service.acceptRawTranscript('segment-1', 'Hey me mo, buy tea'),
      isFalse,
    );
    expect(
      await service.acceptFinalTranscript('segment-1', 'Hey Memo, buy tea.'),
      isTrue,
    );
    await _waitFor(() => service.activeMemo?.revision == 1);

    expect(service.isActive, isTrue);
    expect(service.activeMemo?.sources.single.memoText, 'buy tea.');
  });

  test('corrected text cannot expand standalone Hey into Hey Memo', () async {
    expect(service.acceptRawTranscript('segment-1', 'Hey'), isFalse);
    expect(
      await service.acceptFinalTranscript('segment-1', 'Hey Memo.'),
      isFalse,
    );

    expect(service.isActive, isFalse);
    expect(service.records, isEmpty);
    expect(client.requests, isEmpty);
  });

  test('corrected text requires memo-like raw wake evidence', () async {
    expect(
      service.acceptRawTranscript('segment-1', 'Hey, capture this'),
      isFalse,
    );
    expect(
      await service.acceptFinalTranscript(
        'segment-1',
        'Hey Memo, capture this.',
      ),
      isFalse,
    );

    expect(service.isActive, isFalse);
    expect(service.records, isEmpty);
    expect(client.requests, isEmpty);
  });

  test(
    'corrected wake phrase claims later utterances from the pending backlog',
    () async {
      service.speechStarted('segment-1');
      service.speechEnded('segment-1');
      expect(service.acceptRawTranscript('segment-1', 'Hey me mo'), isFalse);

      service.speechStarted('segment-2');
      service.speechEnded('segment-2');
      expect(
        service.acceptRawTranscript(
          'segment-2',
          'hmm plan a weekend visit next month',
        ),
        isFalse,
      );

      service.speechStarted('segment-3');
      service.speechEnded('segment-3');
      expect(
        service.acceptRawTranscript(
          'segment-3',
          'actually move the food market to Sunday',
        ),
        isFalse,
      );

      expect(
        await service.acceptFinalTranscript('segment-1', 'Hey Memo.'),
        isTrue,
      );
      expect(service.activeMemo?.sources, hasLength(3));

      expect(
        await service.acceptFinalTranscript(
          'segment-2',
          'Hmm, plan a weekend visit next month.',
        ),
        isTrue,
      );
      expect(
        await service.acceptFinalTranscript(
          'segment-3',
          'Actually, move the food market to Sunday.',
        ),
        isTrue,
      );
      await _waitFor(() => !service.isActive);

      final memo = service.records.single;
      expect(memo.status, VoiceMemoStatus.finalized);
      expect(memo.sources, hasLength(3));
      expect(memo.note, contains('plan a weekend visit next month'));
      expect(memo.note, contains('move the food market to Sunday'));
    },
  );

  test('five seconds includes the default two-second VAD boundary', () {
    final production = VoiceMemoService(
      log: (_, _, {bool isError = false}) {},
      onChanged: () {},
      store: VoiceMemoStore(supportDirectory: () async => temp),
      client: client,
      modelPathProvider: () async => '/private/synthetic-model.litertlm',
    );

    expect(production.totalSilenceDuration, const Duration(seconds: 5));
    expect(
      production.totalSilenceDuration - production.closedTurnSilenceDuration,
      const Duration(seconds: 3),
    );
  });

  test(
    'new speech cancels silence and a settled turn auto-finalizes',
    () async {
      service.acceptRawTranscript('segment-1', 'Hey Memo, first item');
      await service.acceptFinalTranscript('segment-1', 'Hey Memo, first item.');
      await _waitFor(() => service.activeMemo?.revision == 1);

      service.speechStarted('segment-2');
      service.speechEnded('segment-2');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      service.speechStarted('segment-3');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.isActive, isTrue);

      service.acceptRawTranscript('segment-3', 'second item');
      await service.acceptFinalTranscript('segment-3', 'Second item.');
      service.speechEnded('segment-3');
      await _waitFor(() => !service.isActive);

      expect(service.records.single.status, VoiceMemoStatus.finalized);
      expect(service.records.single.sources, hasLength(2));
    },
  );

  test('finalization waits for the last claimed transcript', () async {
    service.acceptRawTranscript('segment-1', 'Hey Memo, first item');
    await service.acceptFinalTranscript('segment-1', 'Hey Memo, first item.');
    await _waitFor(() => service.activeMemo?.revision == 1);

    service.speechStarted('segment-2');
    service.speechEnded('segment-2');
    await _waitFor(() => service.isFinalizing);
    expect(service.isActive, isTrue);

    service.acceptRawTranscript('segment-2', 'last rough words');
    await service.acceptFinalTranscript('segment-2', 'Last clear words.');
    await _waitFor(() => !service.isActive);

    expect(service.records.single.note, contains('Last clear words.'));
  });

  test('manual finalization saves the current note immediately', () async {
    service.acceptRawTranscript('segment-1', 'Hey Memo, save this');
    await service.acceptFinalTranscript('segment-1', 'Hey Memo, save this.');
    await _waitFor(() => service.activeMemo?.revision == 1);

    service.requestFinalize(reason: 'double_tap');
    await _waitFor(() => !service.isActive);

    expect(service.records.single.status, VoiceMemoStatus.finalized);
    expect(service.lastFinalizedId, service.records.single.id);
  });

  test('restores an unfinished memo as interrupted without resuming', () async {
    final store = VoiceMemoStore(supportDirectory: () async => temp);
    await store.initialize();
    final now = DateTime.utc(2026, 1, 1);
    await store.save(
      VoiceMemoRecord(
        id: 'memo-synthetic',
        status: VoiceMemoStatus.listening,
        note: '',
        sources: const <VoiceMemoSource>[
          VoiceMemoSource(
            segmentId: 'segment-synthetic',
            rawTranscript: 'Synthetic source',
            memoText: 'Synthetic source',
          ),
        ],
        revision: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await service.dispose();
    service = VoiceMemoService(
      log: (_, _, {bool isError = false}) {},
      onChanged: () {},
      store: VoiceMemoStore(supportDirectory: () async => temp),
      client: client,
      modelPathProvider: () async => '/private/synthetic-model.litertlm',
    );

    await service.initialize();

    expect(service.isActive, isFalse);
    expect(service.records.single.status, VoiceMemoStatus.interrupted);
    expect(service.records.single.note, 'Synthetic source');
  });
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the memo state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _FakeGemmaClient implements GemmaCorrectionClient {
  final List<GemmaCorrectionRequest> requests = <GemmaCorrectionRequest>[];
  final List<String> scriptedNotes = <String>[];
  final List<String> scriptedNotesUsed = <String>[];

  @override
  Future<void> prepareEngine({
    required String modelPath,
    required String modelId,
  }) async {}

  @override
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request) async {
    requests.add(request);
    final input = jsonDecode(request.transcript) as Map<String, Object?>;
    final utterances = (input['utterances']! as List<Object?>).cast<String>();
    final note = scriptedNotes.isEmpty
        ? <String>[
            'Project note',
            for (final utterance in utterances) '- $utterance',
          ].join('\n')
        : scriptedNotes.removeAt(0);
    scriptedNotesUsed.add(note);
    return GemmaCorrectionResult(
      correctedText: note,
      provider: 'gpu',
      engineLoadMs: 1,
      inferenceMs: 1,
      totalMs: 2,
      timeToFirstTokenMs: 1,
      prefillTokensPerSecond: 1,
      decodeTokensPerSecond: 1,
    );
  }

  @override
  Future<void> releaseEngine() async {}
}
