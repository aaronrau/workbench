import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/gemma_correction_client.dart';
import 'package:even_g2_r1_poc/src/audio/gemma_model.dart';
import 'package:even_g2_r1_poc/src/audio/transcript_correction_config.dart';
import 'package:even_g2_r1_poc/src/audio/transcript_correction_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late Directory speech;
  late TranscriptCorrectionConfigStore configStore;
  late GemmaModelStore modelStore;
  late _FakeGemmaClient client;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync(
      'workbench-correction-supervisor-test-',
    );
    speech = Directory('${temp.path}/workbench/audio/speech')
      ..createSync(recursive: true);
    configStore = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
    );
    await configStore.initialize();
    modelStore = GemmaModelStore(supportDirectory: () async => temp);
    final modelDirectory = Directory(
      '${temp.path}/workbench/models/${gemma4E4bModel.id}',
    )..createSync(recursive: true);
    final model = File('${modelDirectory.path}/${gemma4E4bModel.fileName}');
    model.openSync(mode: FileMode.write)
      ..truncateSync(gemma4E4bModel.byteLength)
      ..closeSync();
    File(
      '${model.path}.verified',
    ).writeAsStringSync('${gemma4E4bModel.sha256}\n', flush: true);
    client = _FakeGemmaClient();
  });

  tearDown(() {
    configStore.dispose();
    temp.deleteSync(recursive: true);
  });

  test('prepares the verified correction engine during startup', () async {
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {},
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);

    await supervisor.start();

    expect(client.preparedModelPaths, hasLength(1));
    expect(client.preparedModelPaths.single, endsWith(gemma4E4bModel.fileName));
  });

  test('does not prepare the engine when correction is disabled', () async {
    await configStore.setEnabled(false);
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {},
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);

    await supervisor.start();

    expect(client.preparedModelPaths, isEmpty);
  });

  test('starts ready correction without a zero-duration timer', () async {
    final completed = Completer<CorrectedTranscriptResult>();
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: completed.complete,
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);

    await runZoned(
      () async {
        await supervisor.start();
        await _queue(
          supervisor,
          speech,
          'immediate-pump',
          'Hey Flux run the timer-independent fixture',
        );
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == Duration.zero) {
            return _InactiveTimer();
          }
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );

    final result = await completed.future.timeout(const Duration(seconds: 5));
    expect(result.segmentId, 'immediate-pump');
    expect(supervisor.pendingCount, 0);
  });

  test('explicit agent selection makes a non-Hey transcript correctable', () {
    expect(
      isLiveTranscriptCorrectionEligible(
        'pull the ladies changes',
        explicitlyTargeted: true,
      ),
      isTrue,
    );
    expect(
      isLiveTranscriptCorrectionEligible(
        'pull the ladies changes',
        explicitlyTargeted: false,
      ),
      isFalse,
      reason: 'Unselected ambient speech remains wake-gated.',
    );
    expect(
      isLiveTranscriptCorrectionEligible(
        'Hey Flux, pull the ladies changes',
        explicitlyTargeted: false,
      ),
      isTrue,
    );
  });

  test(
    'persists corrected text separately with complete timing metadata',
    () async {
      final completed = Completer<CorrectedTranscriptResult>();
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: completed.complete,
        onUncorrected: (_, _, _) {},
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      final raw = File('${speech.path}/sample.raw.txt')
        ..writeAsStringSync('run test 15 with --verbose\n');

      await supervisor.queue(
        TranscriptCorrectionJob(
          segmentId: 'sample',
          rawPath: raw.path,
          sttModel: 'parakeet-0.6b',
          sttProvider: 'cpu',
          audioMs: 1200,
          sttDecodeMs: 80,
          sttTotalMs: 100,
          queuedAt: DateTime.now().toUtc(),
        ),
      );
      final result = await completed.future.timeout(const Duration(seconds: 5));

      expect(result.correctedText, 'Run test 15 with --verbose.');
      expect(
        File('${speech.path}/sample.corrected.txt').readAsStringSync().trim(),
        result.correctedText,
      );
      final metadata = File(
        '${speech.path}/sample.transcript.json',
      ).readAsStringSync();
      expect(metadata, contains('"runtime":"litertlm-0.14.0"'));
      expect(metadata, contains('"decodeMs":80'));
      expect(
        File('${speech.path}/pending-corrections.json').readAsStringSync(),
        '{}',
      );
    },
  );

  test('corrects the overlap-deduplicated live transcript', () async {
    final completed = Completer<CorrectedTranscriptResult>();
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: completed.complete,
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);
    await supervisor.start();
    final raw = File('${speech.path}/overlap.raw.txt')
      ..writeAsStringSync('boundary words Hey Flux check status\n');

    await supervisor.queue(
      TranscriptCorrectionJob(
        segmentId: 'overlap',
        rawPath: raw.path,
        sttModel: 'parakeet-0.6b',
        sttProvider: 'cpu',
        audioMs: 18000,
        sttDecodeMs: 80,
        sttTotalMs: 100,
        queuedAt: DateTime.now().toUtc(),
        liveTranscript: 'Hey Flux check status',
      ),
    );
    final result = await completed.future.timeout(const Duration(seconds: 5));

    expect(client.transcripts.single, 'Hey Flux check status');
    expect(result.originalText, 'Hey Flux check status');
  });

  test(
    'uses a newly saved instruction on the next queued transcript',
    () async {
      final completions =
          StreamController<CorrectedTranscriptResult>.broadcast();
      addTearDown(completions.close);
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: completions.add,
        onUncorrected: (_, _, _) {},
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      await configStore.saveInstructions('First validated instruction.');
      final firstCompletion = completions.stream.first;
      await _queue(supervisor, speech, 'first', 'first transcript');
      await firstCompletion.timeout(const Duration(seconds: 5));
      await configStore.saveInstructions('Second validated instruction.');
      final secondCompletion = completions.stream.first;
      await _queue(supervisor, speech, 'second', 'second transcript');
      await secondCompletion.timeout(const Duration(seconds: 5));

      expect(client.instructions, <String>[
        'First validated instruction.',
        'Second validated instruction.',
      ]);
    },
  );

  test('rejects correction output that removes protected values', () {
    expect(
      () => TranscriptCorrectionSupervisor.validateCorrectedTranscript(
        original: 'Run version 15 with --verbose.',
        candidate: 'Run the version.',
      ),
      throwsFormatException,
    );
    expect(
      TranscriptCorrectionSupervisor.validateCorrectedTranscript(
        original: 'run version 15 with --verbose',
        candidate: 'Run version 15 with --verbose.',
      ),
      'Run version 15 with --verbose.',
    );
  });

  test('adds conservative Hey Memo correction guidance', () {
    final instructions =
        TranscriptCorrectionSupervisor.buildCorrectionInstructions(
          'Correct only clear ASR errors.',
          const <String>['Hey Memo'],
        );

    expect(instructions, contains('exactly "Hey Memo"'));
    expect(instructions, contains('hey me mo'));
    expect(instructions, contains('I wrote a memo yesterday'));
    expect(instructions, contains('standalone "Hey"'));
    expect(instructions, contains('memo-like second word'));
    expect(instructions, contains('Never rewrite an ordinary use'));
  });

  test(
    'adds known command names and marks a live correction routable',
    () async {
      final completed = Completer<CorrectedTranscriptResult>();
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: completed.complete,
        onUncorrected: (_, _, _) {},
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      final raw = File('${speech.path}/live.raw.txt')
        ..writeAsStringSync('Hey flex, pull the latest changes.\n');

      await supervisor.queue(
        TranscriptCorrectionJob(
          segmentId: 'live',
          rawPath: raw.path,
          sttModel: 'parakeet-0.6b',
          sttProvider: 'nnapi',
          audioMs: 5000,
          sttDecodeMs: 500,
          sttTotalMs: 550,
          queuedAt: DateTime.now().toUtc(),
          correctionTerms: const <String>['Flux', 'Brock', 'Flux'],
          routeWhenCorrected: true,
        ),
      );
      final result = await completed.future.timeout(const Duration(seconds: 5));

      expect(result.correctedText, 'Flux, pull the latest changes.');
      expect(result.routeWhenCorrected, isTrue);
      expect(client.instructions.single, contains('["Flux","Brock"]'));
      expect(
        client.instructions.single,
        contains('"Flux":["plus","plux","flex","flax","fox"]'),
      );
      expect(
        client.instructions.single,
        contains('source begins with "Hey" followed by that alias'),
      );
      expect(
        client.instructions.single,
        contains('Never promote a bare alias such as "Plus"'),
      );
    },
  );

  test(
    'corrects ladies to latest before routing selected-agent speech',
    () async {
      final completed = Completer<CorrectedTranscriptResult>();
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: completed.complete,
        onUncorrected: (_, _, _) {
          fail('Selected-agent speech should use the corrected result.');
        },
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      final raw = File('${speech.path}/selected-agent.raw.txt')
        ..writeAsStringSync('pull the ladies changes\n');

      await supervisor.queue(
        TranscriptCorrectionJob(
          segmentId: 'selected-agent',
          rawPath: raw.path,
          sttModel: 'parakeet-0.6b',
          sttProvider: 'nnapi',
          audioMs: 3000,
          sttDecodeMs: 400,
          sttTotalMs: 450,
          queuedAt: DateTime.now().toUtc(),
          correctionTerms: const <String>['Flux'],
          routeWhenCorrected: true,
          liveTranscript: 'pull the ladies changes',
        ),
      );
      final result = await completed.future.timeout(const Duration(seconds: 5));

      expect(client.transcripts.single, 'pull the ladies changes');
      expect(result.originalText, 'pull the ladies changes');
      expect(result.correctedText, 'Pull the latest changes.');
      expect(result.routeWhenCorrected, isTrue);
      expect(
        client.instructions.single,
        contains('rewrite "ladies changes" as "latest changes"'),
      );
    },
  );

  test('a restored correction job can never route an old command', () {
    final original = TranscriptCorrectionJob(
      segmentId: 'pending',
      rawPath: '/private/app/pending.raw.txt',
      sttModel: 'parakeet-0.6b',
      sttProvider: 'nnapi',
      audioMs: 5000,
      sttDecodeMs: 500,
      sttTotalMs: 550,
      queuedAt: DateTime.now().toUtc(),
      correctionTerms: const <String>['Flux'],
      routeWhenCorrected: true,
    );

    final restored = TranscriptCorrectionJob.fromJson(
      original.segmentId,
      original.toJson(),
    );

    expect(restored, isNotNull);
    expect(restored!.routeWhenCorrected, isFalse);
    expect(restored.correctionTerms, isEmpty);
  });

  test(
    'disabled correction returns the live raw transcript explicitly',
    () async {
      await configStore.setEnabled(false);
      final bypassed = Completer<(TranscriptCorrectionJob, String, String)>();
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: client,
        onCorrected: (_) {},
        onUncorrected: (job, transcript, reason) {
          bypassed.complete((job, transcript, reason));
        },
        onStatus: (_, {isError = false}) {},
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();
      final raw = File('${speech.path}/disabled.raw.txt')
        ..writeAsStringSync('Flux, pull the latest changes.\n');

      await supervisor.queue(
        TranscriptCorrectionJob(
          segmentId: 'disabled',
          rawPath: raw.path,
          sttModel: 'parakeet-0.6b',
          sttProvider: 'nnapi',
          audioMs: 5000,
          sttDecodeMs: 500,
          sttTotalMs: 550,
          queuedAt: DateTime.now().toUtc(),
          routeWhenCorrected: true,
        ),
      );
      final result = await bypassed.future.timeout(const Duration(seconds: 5));

      expect(result.$1.routeWhenCorrected, isTrue);
      expect(result.$2, 'Flux, pull the latest changes.');
      expect(result.$3, 'correction_disabled');
    },
  );

  test('oversize correction input reports a terminal raw fallback', () async {
    final statuses = <String>[];
    final fallback = Completer<(String, String)>();
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {},
      onUncorrected: (_, transcript, reason) {
        fallback.complete((transcript, reason));
      },
      onStatus: (message, {isError = false}) {
        statuses.add(message);
      },
    );
    addTearDown(supervisor.dispose);
    await supervisor.start();
    final text =
        'a' * (TranscriptCorrectionSupervisor.maximumTranscriptCharacters + 1);
    final raw = File('${speech.path}/oversize.raw.txt')
      ..writeAsStringSync('$text\n');

    await supervisor.queue(
      TranscriptCorrectionJob(
        segmentId: 'oversize',
        rawPath: raw.path,
        sttModel: 'parakeet-0.6b',
        sttProvider: 'nnapi',
        audioMs: 5000,
        sttDecodeMs: 500,
        sttTotalMs: 550,
        queuedAt: DateTime.now().toUtc(),
        routeWhenCorrected: true,
      ),
    );
    await _waitFor(() => supervisor.pendingCount == 0);
    final fallbackResult = await fallback.future;

    expect(client.instructions, isEmpty);
    expect(fallbackResult.$1, text);
    expect(fallbackResult.$2, 'input_too_long');
    expect(supervisor.pendingCount, 0);
    expect(statuses, contains(contains('state=skipped_oversize')));
    expect(
      File(
        '${speech.path}/oversize.correction-skipped.json',
      ).readAsStringSync(),
      contains('"reason":"input_too_long"'),
    );
    expect(
      File('${speech.path}/pending-corrections.json').readAsStringSync(),
      '{}',
    );
  });

  test('abandons invalid model output after the retry ceiling', () async {
    final statuses = <String>[];
    final invalidClient = _InvalidGemmaClient();
    final fallback = Completer<(String, String)>();
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: invalidClient,
      onCorrected: (_) {
        fail('Invalid correction output must not complete.');
      },
      onUncorrected: (_, transcript, reason) {
        fallback.complete((transcript, reason));
      },
      onStatus: (message, {isError = false}) {
        statuses.add(message);
      },
    );
    addTearDown(supervisor.dispose);
    await supervisor.start();
    final raw = File('${speech.path}/invalid.raw.txt')
      ..writeAsStringSync('Keep protected value 15.\n');

    await supervisor.queue(
      TranscriptCorrectionJob(
        segmentId: 'invalid',
        rawPath: raw.path,
        sttModel: 'parakeet-0.6b',
        sttProvider: 'nnapi',
        audioMs: 5000,
        sttDecodeMs: 500,
        sttTotalMs: 550,
        queuedAt: DateTime.now().toUtc(),
        routeWhenCorrected: true,
        attempts: TranscriptCorrectionSupervisor.maximumCorrectionAttempts - 1,
      ),
    );
    await _waitFor(() => supervisor.pendingCount == 0);
    final fallbackResult = await fallback.future;

    expect(invalidClient.calls, 1);
    expect(fallbackResult.$1, 'Keep protected value 15.');
    expect(fallbackResult.$2, 'retry_exhausted');
    expect(statuses, contains(contains('state=abandoned')));
    expect(statuses, contains(contains('error_code=invalid_output')));
    expect(
      File('${speech.path}/invalid.correction-skipped.json').readAsStringSync(),
      contains('"reason":"retry_exhausted"'),
    );
    expect(
      File('${speech.path}/pending-corrections.json').readAsStringSync(),
      '{}',
    );
  });

  test('keeps a live request queued across Gemma process restarts', () async {
    final statuses = <String>[];
    final completed = Completer<CorrectedTranscriptResult>();
    final restartingClient = _RestartingGemmaClient(
      disconnectsBeforeSuccess: 4,
    );
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: restartingClient,
      transientRetryDelayOverride: Duration.zero,
      onCorrected: completed.complete,
      onUncorrected: (_, _, _) {
        fail('A transient service restart must keep the request queued.');
      },
      onStatus: (message, {isError = false}) {
        statuses.add(message);
      },
    );
    addTearDown(supervisor.dispose);
    await supervisor.start();
    final raw = File('${speech.path}/service-restart.raw.txt')
      ..writeAsStringSync('Flux, pull the latest changes.\n');

    await supervisor.queue(
      TranscriptCorrectionJob(
        segmentId: 'service-restart',
        rawPath: raw.path,
        sttModel: 'parakeet-0.6b',
        sttProvider: 'nnapi',
        audioMs: 5000,
        sttDecodeMs: 500,
        sttTotalMs: 550,
        queuedAt: DateTime.now().toUtc(),
        routeWhenCorrected: true,
        attempts: TranscriptCorrectionSupervisor.maximumCorrectionAttempts - 1,
      ),
    );
    final result = await completed.future.timeout(const Duration(seconds: 5));

    expect(result.correctedText, 'Flux, pull the latest changes.');
    expect(restartingClient.calls, 5);
    expect(
      statuses.where((status) => status.contains('state=deferred')),
      hasLength(4),
    );
    expect(statuses, isNot(contains(contains('state=abandoned'))));
    expect(supervisor.pendingCount, 0);
    expect(
      File(
        '${speech.path}/service-restart.correction-skipped.json',
      ).existsSync(),
      isFalse,
    );
  });

  test('persists no-wake skips without invoking Gemma', () async {
    final uncorrected = Completer<String>();
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {
        fail('A transcript without Hey must not be corrected.');
      },
      onUncorrected: (_, transcript, reason) {
        expect(reason, 'no_wake_word');
        uncorrected.complete(transcript);
      },
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);
    await supervisor.start();
    final raw = File('${speech.path}/ambient.raw.txt')
      ..writeAsStringSync('ordinary ambient conversation\n');
    final job = TranscriptCorrectionJob(
      segmentId: 'ambient',
      rawPath: raw.path,
      sttModel: 'parakeet-0.6b',
      sttProvider: 'cpu',
      audioMs: 15000,
      sttDecodeMs: 100,
      sttTotalMs: 120,
      queuedAt: DateTime.now().toUtc(),
      routeWhenCorrected: true,
    );

    await supervisor.skipIneligible(
      job,
      raw.readAsStringSync().trim(),
      reason: 'no_wake_word',
    );

    expect(await uncorrected.future, 'ordinary ambient conversation');
    expect(client.instructions, isEmpty);
    expect(
      File('${speech.path}/ambient.correction-skipped.json').readAsStringSync(),
      contains('"reason":"no_wake_word"'),
    );
    expect(
      File('${speech.path}/pending-corrections.json').readAsStringSync(),
      '{}',
    );
  });

  test(
    'prioritizes a tapped correction behind only active inference',
    () async {
      final blockingClient = _BlockingGemmaClient();
      final statuses = <String>[];
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: blockingClient,
        onCorrected: (_) {},
        onUncorrected: (_, _, _) {},
        onStatus: (message, {isError = false}) => statuses.add(message),
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();

      await _queue(supervisor, speech, 'first', 'Hey Flux, first task');
      await blockingClient.firstStarted.future;
      await _queue(supervisor, speech, 'second', 'Hey Flux, second task');
      await _queue(supervisor, speech, 'third', 'Hey Flux, tapped task');

      expect(await supervisor.prioritize('third'), isTrue);
      blockingClient.releaseFirst.complete();
      await _waitFor(() => supervisor.pendingCount == 0);

      expect(blockingClient.transcripts, <String>[
        'Hey Flux, first task',
        'Hey Flux, tapped task',
        'Hey Flux, second task',
      ]);
      expect(statuses, contains(contains('state=prioritized segment=third')));
    },
  );

  test(
    'queues a selected-agent correction behind only active inference',
    () async {
      final blockingClient = _BlockingGemmaClient();
      final statuses = <String>[];
      final supervisor = TranscriptCorrectionSupervisor(
        speechPath: speech.path,
        configStore: configStore,
        modelStore: modelStore,
        client: blockingClient,
        onCorrected: (_) {},
        onUncorrected: (_, _, _) {},
        onStatus: (message, {isError = false}) => statuses.add(message),
      );
      addTearDown(supervisor.dispose);
      await supervisor.start();

      await _queue(supervisor, speech, 'first', 'Hey Flux, first task');
      await blockingClient.firstStarted.future;
      await _queue(supervisor, speech, 'second', 'Hey Flux, second task');
      await _queue(
        supervisor,
        speech,
        'selected',
        'selected agent task',
        prioritize: true,
      );

      blockingClient.releaseFirst.complete();
      await _waitFor(() => supervisor.pendingCount == 0);

      expect(blockingClient.transcripts, <String>[
        'Hey Flux, first task',
        'selected agent task',
        'Hey Flux, second task',
      ]);
      expect(statuses, contains(contains('priority=selected_agent')));
    },
  );

  test('does not restore a transcript with a durable skip marker', () async {
    File(
      '${speech.path}/terminal.raw.txt',
    ).writeAsStringSync('Keep the durable raw transcript.\n');
    File(
      '${speech.path}/terminal.correction-skipped.json',
    ).writeAsStringSync('{"version":1,"reason":"retry_exhausted"}');
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {
        fail('A terminal correction must not be restored.');
      },
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);

    await supervisor.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(supervisor.pendingCount, 0);
    expect(client.instructions, isEmpty);
    expect(
      File('${speech.path}/pending-corrections.json').readAsStringSync(),
      '{}',
    );
  });

  test('wake-gates an unmarked ambient transcript during recovery', () async {
    File(
      '${speech.path}/unmarked.raw.txt',
    ).writeAsStringSync('Ambient words from before process restart.\n');
    final supervisor = TranscriptCorrectionSupervisor(
      speechPath: speech.path,
      configStore: configStore,
      modelStore: modelStore,
      client: client,
      onCorrected: (_) {
        fail('Recovered ambient text must not reach Gemma.');
      },
      onUncorrected: (_, _, _) {},
      onStatus: (_, {isError = false}) {},
    );
    addTearDown(supervisor.dispose);

    await supervisor.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(supervisor.pendingCount, 0);
    expect(client.instructions, isEmpty);
    expect(
      File(
        '${speech.path}/unmarked.correction-skipped.json',
      ).readAsStringSync(),
      contains('"reason":"no_wake_word"'),
    );
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for asynchronous correction state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _queue(
  TranscriptCorrectionSupervisor supervisor,
  Directory speech,
  String id,
  String text, {
  bool prioritize = false,
}) async {
  final raw = File('${speech.path}/$id.raw.txt')..writeAsStringSync('$text\n');
  await supervisor.queue(
    TranscriptCorrectionJob(
      segmentId: id,
      rawPath: raw.path,
      sttModel: 'parakeet-0.6b',
      sttProvider: 'cpu',
      audioMs: 1000,
      sttDecodeMs: 50,
      sttTotalMs: 60,
      queuedAt: DateTime.now().toUtc(),
    ),
    prioritize: prioritize,
  );
}

final class _FakeGemmaClient implements GemmaCorrectionClient {
  final List<String> instructions = <String>[];
  final List<String> preparedModelPaths = <String>[];
  final List<String> transcripts = <String>[];

  @override
  Future<void> prepareEngine({
    required String modelPath,
    required String modelId,
  }) async {
    preparedModelPaths.add(modelPath);
  }

  @override
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request) async {
    instructions.add(request.instructions);
    final source = request.transcript;
    transcripts.add(source);
    final corrected = switch (source) {
      'run test 15 with --verbose' => 'Run test 15 with --verbose.',
      'Plus, for the latest changes.'
          when request.instructions.contains('"Flux"') =>
        'Flux, pull the latest changes.',
      'Hey flex, pull the latest changes.'
          when request.instructions.contains('"Flux"') =>
        'Flux, pull the latest changes.',
      'pull the ladies changes'
          when request.instructions.contains(
            'rewrite "ladies changes" as "latest changes"',
          ) =>
        'Pull the latest changes.',
      _ => '${source[0].toUpperCase()}${source.substring(1)}.',
    };
    return GemmaCorrectionResult(
      correctedText: corrected,
      provider: 'gpu',
      engineLoadMs: 500,
      inferenceMs: 40,
      totalMs: 550,
      timeToFirstTokenMs: 20,
      prefillTokensPerSecond: 100,
      decodeTokensPerSecond: 20,
    );
  }

  @override
  Future<void> releaseEngine() async {}
}

final class _InactiveTimer implements Timer {
  @override
  bool get isActive => false;

  @override
  int get tick => 0;

  @override
  void cancel() {}
}

final class _BlockingGemmaClient implements GemmaCorrectionClient {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> releaseFirst = Completer<void>();
  final List<String> transcripts = <String>[];

  @override
  Future<void> prepareEngine({
    required String modelPath,
    required String modelId,
  }) async {}

  @override
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request) async {
    transcripts.add(request.transcript);
    if (transcripts.length == 1) {
      firstStarted.complete();
      await releaseFirst.future;
    }
    return GemmaCorrectionResult(
      correctedText: '${request.transcript}.',
      provider: 'gpu',
      engineLoadMs: 0,
      inferenceMs: 1,
      totalMs: 1,
      timeToFirstTokenMs: 1,
      prefillTokensPerSecond: 100,
      decodeTokensPerSecond: 20,
    );
  }

  @override
  Future<void> releaseEngine() async {}
}

final class _InvalidGemmaClient implements GemmaCorrectionClient {
  int calls = 0;

  @override
  Future<void> prepareEngine({
    required String modelPath,
    required String modelId,
  }) async {}

  @override
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request) async {
    calls++;
    return const GemmaCorrectionResult(
      correctedText: 'Protected value was removed.',
      provider: 'gpu',
      engineLoadMs: 500,
      inferenceMs: 40,
      totalMs: 550,
      timeToFirstTokenMs: 20,
      prefillTokensPerSecond: 100,
      decodeTokensPerSecond: 20,
    );
  }

  @override
  Future<void> releaseEngine() async {}
}

final class _RestartingGemmaClient implements GemmaCorrectionClient {
  _RestartingGemmaClient({required this.disconnectsBeforeSuccess});

  final int disconnectsBeforeSuccess;
  int calls = 0;

  @override
  Future<void> prepareEngine({
    required String modelPath,
    required String modelId,
  }) async {}

  @override
  Future<GemmaCorrectionResult> correct(GemmaCorrectionRequest request) async {
    calls++;
    if (calls <= disconnectsBeforeSuccess) {
      throw const GemmaCorrectionClientException('service_disconnected');
    }
    return GemmaCorrectionResult(
      correctedText: request.transcript,
      provider: 'gpu',
      engineLoadMs: 500,
      inferenceMs: 40,
      totalMs: 550,
      timeToFirstTokenMs: 20,
      prefillTokensPerSecond: 100,
      decodeTokensPerSecond: 20,
    );
  }

  @override
  Future<void> releaseEngine() async {}
}
