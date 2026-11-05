import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/audio/moss_audio.dart';
import 'package:even_g2_r1_poc/src/audio/moss_pipeline.dart';
import 'package:even_g2_r1_poc/src/audio/transcription_worker.dart';
import 'package:even_g2_r1_poc/src/audio/vad_worker.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends MossClient {
  _Client({
    super.provider = MossExecutionProvider.cpu,
    super.quantization = MossQuantization.q5K,
  });
  int loads = 0;
  int calls = 0;
  final outputs = <Completer<Map<String, dynamic>>>[];
  @override
  Future<void> prepare(String path) async {
    loads++;
  }

  @override
  Future<Map<String, dynamic>> transcribe(String path) {
    calls++;
    final result = Completer<Map<String, dynamic>>();
    outputs.add(result);
    return result.future;
  }

  @override
  Future<void> close() async {
    for (final output in outputs) {
      if (!output.isCompleted) {
        output.completeError(StateError('worker stopped'));
      }
    }
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 1200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('MOSS test operation did not complete');
}

Future<void> _enqueue(
  MossPipeline pipeline,
  Directory directory,
  String id,
) async {
  final wav = File('${directory.path}/$id.wav');
  await wav.writeAsBytes(mossWav(Uint8List(32000)), flush: true);
  pipeline.transcribeSegment(
    VadSpeechSegment(
      id: id,
      wavPath: wav.path,
      conversationId: 'synthetic-turn',
      isConversationFinal: false,
      endReason: VadSegmentEndReason.durationWordBoundary,
    ),
  );
}

void main() {
  for (final mode in ['stalled', 'sync_failure', 'async_failure']) {
    test(
      'conversation handoff $mode never delays or retries primary STT',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'workbench-moss-handoff.',
        );
        final client = _Client();
        final blocked = Completer<void>();
        final primary = <TranscriptionResult>[];
        final handedOff = <String>[];
        final pipeline = MossPipeline(
          speechPath: directory.path,
          modelPath: 'synthetic-model',
          client: client,
          onTranscript: primary.add,
          onUnsafe: () => fail('unsafe'),
          onStatus: (_, {bool isError = false}) {},
          onDiarizationReady: (path) {
            final id = File(
              path,
            ).uri.pathSegments.last.replaceFirst('.moss.json', '');
            expect(primary.any((result) => result.segmentId == id), isTrue);
            expect(File('${directory.path}/$id.raw.txt').existsSync(), isTrue);
            handedOff.add(path);
            if (mode == 'sync_failure') throw StateError('synthetic failure');
            if (mode == 'async_failure') {
              return Future<void>.error(StateError('synthetic failure'));
            }
            return blocked.future;
          },
        );
        addTearDown(() async {
          if (!blocked.isCompleted) blocked.complete();
          await pipeline.dispose();
          await directory.delete(recursive: true);
        });
        await pipeline.start();
        await _enqueue(pipeline, directory, 'first');
        await _enqueue(pipeline, directory, 'second');
        await _until(() => client.calls == 1);
        client.outputs[0].complete({
          'text': '[0][S01]First synthetic phrase.[0.9]',
          'decodeMs': 10,
        });
        await _until(() => client.calls == 2 && handedOff.length == 1);
        client.outputs[1].complete({
          'text': '[0][S01]Second synthetic phrase.[0.9]',
          'decodeMs': 10,
        });
        await _until(() => primary.length == 2 && handedOff.length == 2);
        expect(pipeline.pendingCount, 0);
        expect(pipeline.failedCount, 0);
        expect(client.calls, 2);
      },
    );
  }

  test(
    'existing preferences retain Q5 while explicit Q4 has separate pinned weights',
    () {
      expect(mossQuantizationForId(null), MossQuantization.q5K);
      expect(mossQuantizationForId('unknown'), MossQuantization.q5K);
      final q4 = mossQuantizationForId('q4_0');
      expect(q4, MossQuantization.q4Zero);
      expect(q4.directory, isNot(MossQuantization.q5K.directory));
      expect(q4.sha256, isNot(MossQuantization.q5K.sha256));
    },
  );

  test('only the explicit Kokoro fixture can enter text logs', () {
    const fixture =
        'Work Bench audio safety check number seven. The glasses should transcribe every word.';
    expect(isMossKokoroFixture(fixture), isTrue);
    expect(isMossKokoroFixture(fixture.replaceAll('seven', '7')), isTrue);
    expect(isMossKokoroFixture('$fixture Additional private words.'), isFalse);
    expect(isMossKokoroFixture('My private recording'), isFalse);
    expect(isMossKokoroFixture('$fixture 123456789'), isFalse);
    expect(isMossKokoroFixture('$fixture 私人'), isFalse);
  });

  test(
    'parses overlapping speaker turns without inventing cross-window identities',
    () {
      final parsed = parseMossTranscript(
        '[0.00][S01]Hello[0.75][0.50][S02]Hi[0.90]',
        audioSeconds: 1,
      );
      expect(parsed.map((turn) => turn.speaker), ['S01', 'S02']);
      expect(parsed.map((turn) => turn.text), ['Hello', 'Hi']);
    },
  );
  test(
    'refuses malformed, truncated, or out-of-bounds output before delivery',
    () {
      for (final text in [
        '[0][S01]Hello',
        'unframed command',
        '[0][S01]Hello[8]',
        '[1][S01]Hello[0]',
        '[0][S01]Hello[1]unframed tail',
      ]) {
        expect(
          () => parseMossTranscript(text, audioSeconds: 1),
          throwsFormatException,
        );
      }
    },
  );
  test('WAV encodes mono 16k PCM exactly', () {
    final pcm = Uint8List.fromList([1, 2, 3, 4]);
    final wav = mossWav(pcm);
    expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 16000);
    expect(wav.sublist(44), pcm);
  });
  test(
    'durable capture does not wait for inference and jobs remain serial',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workbench-moss-test.',
      );
      final client = _Client();
      final results = <TranscriptionResult>[];
      final logs = <String>[];
      final pipeline = MossPipeline(
        speechPath: directory.path,
        modelPath: 'synthetic-model',
        onTranscript: results.add,
        onUnsafe: () => fail('unsafe'),
        onStatus: (message, {bool isError = false}) => logs.add(message),
        client: client,
      );
      addTearDown(() async {
        await pipeline.dispose();
        await directory.delete(recursive: true);
      });
      await pipeline.start();
      for (var i = 0; i < 2; i++) {
        await _enqueue(pipeline, directory, "synthetic-$i");
      }
      await _until(() => client.calls == 1);
      expect(
        directory.listSync().where((file) => file.path.endsWith('.wav')).length,
        2,
      );
      expect(results, isEmpty);
      client.outputs[0].complete({
        'text': '[0][S01]Synthetic phrase[0.9]',
        'decodeMs': 10,
      });
      await _until(() => client.calls == 2);
      client.outputs[1].complete({
        'text': '[0][S01]Second phrase[0.9]',
        'decodeMs': 10,
      });
      await _until(() => results.length == 2);
      expect(results.every((result) => result.routeEligible), isTrue);
      expect(logs.join(), isNot(contains('Synthetic phrase')));
      expect(
        File(results.first.transcriptPath).readAsStringSync(),
        '[0][S01]Synthetic phrase[0.9]',
      );
    },
  );
  test(
    'restored durable WAV finishes locally and never becomes live routing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workbench-moss-recovery.',
      );
      await File(
        '${directory.path}/moss_recovered.wav',
      ).writeAsBytes(mossWav(Uint8List(32000)));
      final client = _Client();
      final result = Completer<TranscriptionResult>();
      final pipeline = MossPipeline(
        speechPath: directory.path,
        modelPath: 'synthetic-model',
        onTranscript: result.complete,
        onUnsafe: () => fail('unsafe'),
        onStatus: (_, {bool isError = false}) {},
        client: client,
        recoveryIdleDelay: Duration.zero,
      );
      addTearDown(() async {
        await pipeline.dispose();
        await directory.delete(recursive: true);
      });
      await pipeline.start();
      await _until(() => client.calls == 1);
      client.outputs.single.complete({
        'text': '[0][S01]Saved words[0.5]',
        'decodeMs': 12,
      });
      expect((await result.future).routeEligible, isFalse);
      expect(
        await File('${directory.path}/moss_recovered.moss.json').exists(),
        isTrue,
      );
    },
  );
  test(
    'stopping the native worker leaves unfinished WAV available for recovery',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workbench-moss-stop.',
      );
      final client = _Client();
      final pipeline = MossPipeline(
        speechPath: directory.path,
        modelPath: 'synthetic-model',
        onTranscript: (_) => fail('must not route a stopped job'),
        onUnsafe: () => fail('unsafe'),
        onStatus: (_, {bool isError = false}) {},
        client: client,
      );
      await pipeline.start();
      await _enqueue(pipeline, directory, "synthetic-stop");
      await _until(() => client.calls == 1);
      await pipeline.dispose();
      expect(
        directory.listSync().where((file) => file.path.endsWith('.wav')),
        hasLength(1),
      );
      expect(
        directory.listSync().where((file) => file.path.endsWith('.raw.txt')),
        isEmpty,
      );
      await directory.delete(recursive: true);
    },
  );
  test('GPU completion requires hardware events and zero CPU nodes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'workbench-moss-gpu.',
    );
    final client = _Client(provider: MossExecutionProvider.opencl);
    final results = <TranscriptionResult>[];
    final pipeline = MossPipeline(
      speechPath: directory.path,
      modelPath: 'synthetic-model',
      client: client,
      onTranscript: results.add,
      onStatus: (_, {bool isError = false}) {},
      onUnsafe: () => fail('unsafe'),
    );
    addTearDown(() async {
      await pipeline.dispose();
      await directory.delete(recursive: true);
    });
    await pipeline.start();
    await _enqueue(pipeline, directory, 'gpu-valid');
    await _until(() => client.calls == 1);
    client.outputs.single.complete({
      'text': '[0][S01]Verified words[0.8]',
      'decodeMs': 8,
      'provider': 'opencl',
      'profile': [2, 12, 0, 1000, 8],
    });
    await _until(() => results.length == 1);
    await _enqueue(pipeline, directory, 'gpu-fallback');
    for (var attempt = 0; attempt < 3; attempt++) {
      await _until(() => client.calls == attempt + 2);
      client.outputs[attempt + 1].complete({
        'text': '[0][S01]Unverified words[0.8]',
        'decodeMs': 8,
        'provider': 'opencl',
        'profile': [2, 12, 1, 1000, 8],
      });
    }
    await _until(() => pipeline.failedCount == 1);
    expect(results, hasLength(1));
    expect(
      File('${directory.path}/gpu-fallback.raw.txt').existsSync(),
      isFalse,
    );
    expect(File('${directory.path}/gpu-fallback.wav').existsSync(), isTrue);
    expect(pipeline.pendingCount, 1);
  });
  test(
    'live input pauses recovered jobs and malformed output is not retried',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workbench-moss-priority.',
      );
      await File(
        '${directory.path}/old.wav',
      ).writeAsBytes(mossWav(Uint8List(32000)));
      final client = _Client();
      final results = <TranscriptionResult>[];
      final pipeline = MossPipeline(
        speechPath: directory.path,
        modelPath: 'synthetic-model',
        client: client,
        recoveryIdleDelay: Duration.zero,
        onTranscript: results.add,
        onStatus: (_, {bool isError = false}) {},
        onUnsafe: () => fail('unsafe'),
      );
      addTearDown(() async {
        await pipeline.dispose();
        await directory.delete(recursive: true);
      });
      await pipeline.start();
      pipeline.setInputActive(true);
      await _enqueue(pipeline, directory, 'live');
      await _until(() => client.calls == 1);
      client.outputs[0].complete({
        'text': '[0][S01]Live words[0.5]',
        'decodeMs': 5,
      });
      await _until(() => results.length == 1);
      expect(results.single.segmentId, 'live');
      expect(client.calls, 1);
      pipeline.setInputActive(false);
      await _until(() => client.calls == 2);
      client.outputs[1].complete({'text': 'Incomplete output', 'decodeMs': 5});
      await _until(() => pipeline.failedCount == 1);
      expect(client.calls, 2);
      expect(client.loads, 1);
      expect(File('${directory.path}/old.wav').existsSync(), isTrue);
      expect(
        File('${directory.path}/old.moss.txt').readAsStringSync(),
        'Incomplete output',
      );
      expect(File('${directory.path}/old.raw.txt').existsSync(), isFalse);
    },
  );
  test(
    'VAD recovery owns partial WAVs and cannot turn them into live commands',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workbench-moss-partial.',
      );
      final part = File('${directory.path}/interrupted.part.wav');
      await part.writeAsBytes(mossWav(Uint8List(32000)));
      final client = _Client();
      final results = <TranscriptionResult>[];
      final pipeline = MossPipeline(
        speechPath: directory.path,
        modelPath: 'synthetic-model',
        client: client,
        recoveryIdleDelay: Duration.zero,
        onTranscript: results.add,
        onStatus: (_, {bool isError = false}) {},
        onUnsafe: () => fail('unsafe'),
      );
      addTearDown(() async {
        await pipeline.dispose();
        await directory.delete(recursive: true);
      });
      await pipeline.start();
      expect(pipeline.pendingCount, 0);
      final finalized = await part.rename('${directory.path}/interrupted.wav');
      pipeline.transcribeSegment(
        VadSpeechSegment(
          id: 'interrupted',
          wavPath: finalized.path,
          conversationId: 'interrupted',
          isConversationFinal: true,
          endReason: VadSegmentEndReason.recovery,
        ),
      );
      await _until(() => client.calls == 1);
      client.outputs.single.complete({
        'text': '[0][S01]Recovered words[0.5]',
        'decodeMs': 5,
      });
      await _until(() => results.length == 1);
      expect(results.single.routeEligible, isFalse);
    },
  );
  test(
    'starting input preempts only restored decoding and preserves its WAV',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workbench-moss-preempt.',
      );
      await File(
        '${directory.path}/old.wav',
      ).writeAsBytes(mossWav(Uint8List(32000)));
      final client = _Client();
      final results = <TranscriptionResult>[];
      final pipeline = MossPipeline(
        speechPath: directory.path,
        modelPath: 'synthetic-model',
        client: client,
        recoveryIdleDelay: Duration.zero,
        onTranscript: results.add,
        onStatus: (_, {bool isError = false}) {},
        onUnsafe: () => fail('unsafe'),
      );
      addTearDown(() async {
        await pipeline.dispose();
        await directory.delete(recursive: true);
      });
      await pipeline.start();
      await _until(() => client.calls == 1);
      pipeline.setInputActive(true);
      await _enqueue(pipeline, directory, 'live-preempt');
      await _until(() => client.calls == 2);
      client.outputs[1].complete({
        'text': '[0][S01]Live words[0.5]',
        'decodeMs': 5,
      });
      await _until(() => results.length == 1);
      expect(results.single.segmentId, 'live-preempt');
      expect(client.loads, 2);
      expect(pipeline.pendingCount, 1);
      expect(pipeline.failedCount, 0);
      expect(File('${directory.path}/old.wav').existsSync(), isTrue);
      expect(File('${directory.path}/old.raw.txt').existsSync(), isFalse);
    },
  );
  test(
    'Q4 results retain their actual model identity and weight hash',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workbench-moss-q4.',
      );
      final client = _Client(
        provider: MossExecutionProvider.opencl,
        quantization: MossQuantization.q4Zero,
      );
      final results = <TranscriptionResult>[];
      final logs = <String>[];
      final pipeline = MossPipeline(
        speechPath: directory.path,
        modelPath: 'synthetic-q4',
        client: client,
        onTranscript: results.add,
        onStatus: (message, {bool isError = false}) => logs.add(message),
        onUnsafe: () => fail('unsafe'),
      );
      addTearDown(() async {
        await pipeline.dispose();
        await directory.delete(recursive: true);
      });
      await pipeline.start();
      await _enqueue(pipeline, directory, 'q4-live');
      await _until(() => client.calls == 1);
      client.outputs.single.complete({
        'text': '[0][S01]Synthetic words[0.5]',
        'decodeMs': 5,
        'model': 'moss-0.9b-q4_0',
        'provider': 'opencl',
        'profile': [2, 12, 0, 1000, 8],
      });
      await _until(() => results.length == 1);
      expect(results.single.model, 'moss-0.9b-q4_0');
      final metadata =
          jsonDecode(
                File('${directory.path}/q4-live.moss.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(metadata['model'], 'moss-0.9b-q4_0');
      expect(metadata['model_sha256'], MossQuantization.q4Zero.sha256);
      expect(
        logs.where((line) => line.contains('state=completed')).single,
        contains('model=moss-0.9b-q4_0'),
      );
    },
  );
}
