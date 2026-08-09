import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/transcript_correction_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-correction-config-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('default instructions include the full guarded correction policy', () {
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('Always rewrite every occurrence of "length view"'),
    );
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('rewrite "flex" or "fox" as "Flux"'),
    );
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('Do not rewrite an ordinary reference to a fox.'),
    );
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('"code x", "condex", "codec", and "kodex" as "Codex"'),
    );
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('"N to N" directly modifies conversation flow'),
    );
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('"Claire session", "Clare session"'),
    );
    expect(
      defaultTranscriptCorrectionInstructions,
      contains('Never summarize, shorten, or omit an informational clause.'),
    );
    expect(defaultTranscriptCorrectionInstructions.length, greaterThan(2000));
    expect(
      defaultTranscriptCorrectionInstructions.length,
      lessThanOrEqualTo(
        TranscriptCorrectionConfig.maximumInstructionCharacters,
      ),
    );
  });

  test('migrates untouched legacy private and shared defaults', () async {
    const legacyInstructions =
        'You correct short automatic speech recognition transcripts from smart '
        'glasses and return only corrected text. Preserve the speaker\'s meaning '
        'and requested action. Correct obvious phonetic errors, command names, '
        'verbs, capitalization, punctuation, and light grammar. A leading local '
        'command name or attention word may be dropped or misheard. Use only the '
        'known command names and acoustic aliases supplied after these instructions; '
        'never invent a name. Restore a name only when the remaining words form a '
        'plausible imperative. With Flux supplied as a known name, for example, '
        '"Plus, all the latest changes." becomes "Flux, pull the latest changes." '
        'Ordinary prose such as "Plus, this is already complete." stays ordinary '
        'prose. Preserve numbers, paths, flags, identifiers, and uncertainty. Do '
        'not summarize, remove requested actions, add facts, answer the transcript, '
        'or use markdown.';
    final workbench = Directory('${temp.path}/workbench');
    await workbench.create(recursive: true);
    final file = File('${workbench.path}/config.json');
    await file.writeAsString(
      jsonEncode(
        TranscriptCorrectionConfig.defaults
            .copyWith(instructions: legacyInstructions)
            .toJson(),
      ),
      flush: true,
    );
    var sharedPrompt = legacyInstructions;
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
      sharedInstructionsAvailable: () => true,
      sharedInstructionsReader: () async => sharedPrompt,
      sharedInstructionsWriter: (value) async => sharedPrompt = value,
    );
    addTearDown(store.dispose);

    await store.initialize();

    expect(store.config.instructions, defaultTranscriptCorrectionInstructions);
    expect(sharedPrompt, defaultTranscriptCorrectionInstructions);
    final privateConfig =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(
      (privateConfig['transcriptCorrection']
          as Map<String, dynamic>)['instructions'],
      defaultTranscriptCorrectionInstructions,
    );
  });

  test('migrates the prior bare-alias default to the guarded policy', () async {
    final priorDefault = defaultTranscriptCorrectionInstructions.replaceFirst(
      'Only after a leading attention word "Hey", rewrite "flex" or "fox" as '
          '"Flux", "block" or "brook" as "Brock", "pipe" as "Pike", and '
          '"wolfe" as "Wolf". Never promote a bare alias into an agent '
          'invocation. Do not rewrite an ordinary reference to a fox. ',
      'In routing position before an engineering command, rewrite "flex" or '
          '"fox" as "Flux", "block" or "brook" as "Brock", "pipe" as '
          '"Pike", and "wolfe" as "Wolf". Do not rewrite an ordinary '
          'reference to a fox. ',
    );
    final workbench = Directory('${temp.path}/workbench');
    await workbench.create(recursive: true);
    final file = File('${workbench.path}/config.json');
    await file.writeAsString(
      jsonEncode(
        TranscriptCorrectionConfig.defaults
            .copyWith(instructions: priorDefault)
            .toJson(),
      ),
      flush: true,
    );
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
    );
    addTearDown(store.dispose);

    await store.initialize();

    expect(store.config.instructions, defaultTranscriptCorrectionInstructions);
    expect(store.config.instructions, contains('leading attention word "Hey"'));
  });

  test('migrates the untouched prior default to latest-changes policy', () async {
    final previousDefault = defaultTranscriptCorrectionInstructions.replaceFirst(
      'In a repository update command, rewrite "ladies changes" as "latest '
          'changes" when the sentence clearly means the most recent changes. ',
      '',
    );
    final workbench = Directory('${temp.path}/workbench');
    await workbench.create(recursive: true);
    final file = File('${workbench.path}/config.json');
    await file.writeAsString(
      jsonEncode(
        TranscriptCorrectionConfig.defaults
            .copyWith(instructions: previousDefault)
            .toJson(),
      ),
      flush: true,
    );
    var sharedPrompt = previousDefault;
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
      sharedInstructionsAvailable: () => true,
      sharedInstructionsReader: () async => sharedPrompt,
      sharedInstructionsWriter: (value) async => sharedPrompt = value,
    );
    addTearDown(store.dispose);

    await store.initialize();

    expect(store.config.instructions, defaultTranscriptCorrectionInstructions);
    expect(
      store.config.instructions,
      contains('rewrite "ladies changes" as "latest changes"'),
    );
    expect(sharedPrompt, defaultTranscriptCorrectionInstructions);
  });

  test('creates and atomically updates validated config.json', () async {
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
    );
    addTearDown(store.dispose);

    await store.initialize();
    await store.saveInstructions('Correct only obvious ASR errors.');

    final file = File('${temp.path}/workbench/config.json');
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final correction = decoded['transcriptCorrection'] as Map<String, dynamic>;
    expect(correction['instructions'], 'Correct only obvious ASR errors.');
    expect(correction['backend'], 'gpu');
    expect(File('${file.path}.part').existsSync(), isFalse);
  });

  test('reloads an external valid edit for the next transcript', () async {
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
    );
    addTearDown(store.dispose);
    await store.initialize();
    final file = File('${temp.path}/workbench/config.json');
    final updated = TranscriptCorrectionConfig.defaults.copyWith(
      instructions: 'Use the second validated instruction.',
    );
    await file.writeAsString(jsonEncode(updated.toJson()), flush: true);

    final loaded = await store.reloadForNextTranscript();

    expect(loaded.instructions, 'Use the second validated instruction.');
    expect(store.validationError, isNull);
  });

  test(
    'loads the shared prompt at startup and before the next transcript',
    () async {
      var sharedPrompt = 'Use the shared startup instruction.';
      final store = TranscriptCorrectionConfigStore(
        supportDirectory: () async => temp,
        sharedInstructionsAvailable: () => true,
        sharedInstructionsReader: () async => sharedPrompt,
        sharedInstructionsWriter: (value) async => sharedPrompt = value,
      );
      addTearDown(store.dispose);

      await store.initialize();
      expect(store.config.instructions, sharedPrompt);
      var privateConfig =
          jsonDecode(
                await File('${temp.path}/workbench/config.json').readAsString(),
              )
              as Map<String, dynamic>;
      expect(
        (privateConfig['transcriptCorrection']
            as Map<String, dynamic>)['instructions'],
        sharedPrompt,
      );

      sharedPrompt = 'Apply this external edit to the next transcription.';
      final loaded = await store.reloadForNextTranscript();

      expect(loaded.instructions, sharedPrompt);
      privateConfig =
          jsonDecode(
                await File('${temp.path}/workbench/config.json').readAsString(),
              )
              as Map<String, dynamic>;
      expect(
        (privateConfig['transcriptCorrection']
            as Map<String, dynamic>)['instructions'],
        sharedPrompt,
      );
    },
  );

  test('creates a missing shared prompt from the private fallback', () async {
    String? sharedPrompt;
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
      sharedInstructionsAvailable: () => true,
      sharedInstructionsReader: () async => sharedPrompt,
      sharedInstructionsWriter: (value) async => sharedPrompt = value,
    );
    addTearDown(store.dispose);

    await store.initialize();

    expect(sharedPrompt, defaultTranscriptCorrectionInstructions);
    expect(store.config.instructions, defaultTranscriptCorrectionInstructions);
  });

  test(
    'does not lose the last good prompt after an invalid shared edit',
    () async {
      var sharedPrompt = 'Keep this shared instruction.';
      final store = TranscriptCorrectionConfigStore(
        supportDirectory: () async => temp,
        sharedInstructionsAvailable: () => true,
        sharedInstructionsReader: () async => sharedPrompt,
        sharedInstructionsWriter: (value) async => sharedPrompt = value,
      );
      addTearDown(store.dispose);
      await store.initialize();

      sharedPrompt = ' \u0000 ';
      final loaded = await store.reloadForNextTranscript();

      expect(loaded.instructions, 'Keep this shared instruction.');
      expect(store.validationError, contains('Shared correction prompt'));
    },
  );

  test('bounds a stalled shared prompt read and keeps the fallback', () async {
    var stallRead = false;
    final stalled = Completer<String?>();
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
      sharedInstructionsAvailable: () => true,
      sharedInstructionsReader: () async =>
          stallRead ? stalled.future : defaultTranscriptCorrectionInstructions,
      sharedInstructionsWriter: (_) async {},
      sharedInstructionsTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(store.dispose);
    await store.initialize();
    stallRead = true;

    final loaded = await store.reloadForNextTranscript().timeout(
      const Duration(seconds: 1),
    );

    expect(loaded.instructions, defaultTranscriptCorrectionInstructions);
    expect(store.validationError, contains('Shared correction prompt'));
    expect(store.validationError, contains('TimeoutException'));
  });

  test('a failed shared save cannot replace the private fallback', () async {
    var sharedPrompt = 'Original shared instruction.';
    var failWrites = false;
    final store = TranscriptCorrectionConfigStore(
      supportDirectory: () async => temp,
      sharedInstructionsAvailable: () => true,
      sharedInstructionsReader: () async => sharedPrompt,
      sharedInstructionsWriter: (value) async {
        if (failWrites) {
          throw FileSystemException('Shared folder unavailable');
        }
        sharedPrompt = value;
      },
    );
    addTearDown(store.dispose);
    await store.initialize();
    failWrites = true;

    await expectLater(
      store.saveInstructions('Do not persist this failed update.'),
      throwsA(isA<FileSystemException>()),
    );

    expect(store.config.instructions, 'Original shared instruction.');
    final privateConfig =
        jsonDecode(
              await File('${temp.path}/workbench/config.json').readAsString(),
            )
            as Map<String, dynamic>;
    expect(
      (privateConfig['transcriptCorrection']
          as Map<String, dynamic>)['instructions'],
      'Original shared instruction.',
    );
  });

  test(
    'serializes a prompt reload and save so neither write is lost',
    () async {
      var sharedPrompt = 'Original shared instruction.';
      Completer<String?>? pendingRead;
      final store = TranscriptCorrectionConfigStore(
        supportDirectory: () async => temp,
        sharedInstructionsAvailable: () => true,
        sharedInstructionsReader: () async {
          final pending = pendingRead;
          return pending == null ? sharedPrompt : pending.future;
        },
        sharedInstructionsWriter: (value) async => sharedPrompt = value,
      );
      addTearDown(store.dispose);
      await store.initialize();

      pendingRead = Completer<String?>();
      final reload = store.reloadForNextTranscript();
      await Future<void>.delayed(Duration.zero);
      final save = store.saveInstructions('Saved after the in-flight reload.');
      await Future<void>.delayed(Duration.zero);

      expect(sharedPrompt, 'Original shared instruction.');
      pendingRead.complete(sharedPrompt);
      await reload;
      await save;

      expect(sharedPrompt, 'Saved after the in-flight reload.');
      expect(store.config.instructions, sharedPrompt);
    },
  );

  test(
    'keeps the last good snapshot when an external edit is invalid',
    () async {
      final store = TranscriptCorrectionConfigStore(
        supportDirectory: () async => temp,
      );
      addTearDown(store.dispose);
      await store.initialize();
      await store.saveInstructions('Keep this validated instruction.');
      final file = File('${temp.path}/workbench/config.json');
      await file.writeAsString(
        '{"version":1,"transcriptCorrection":{"backend":"cpu"}}',
        flush: true,
      );

      final loaded = await store.reloadForNextTranscript();

      expect(loaded.instructions, 'Keep this validated instruction.');
      expect(store.validationError, isNotNull);
    },
  );

  test('rejects empty, oversized, and control-character instructions', () {
    expect(
      () => TranscriptCorrectionConfig.validateInstructions('  '),
      throwsFormatException,
    );
    expect(
      () => TranscriptCorrectionConfig.validateInstructions(
        'x' * (TranscriptCorrectionConfig.maximumInstructionCharacters + 1),
      ),
      throwsFormatException,
    );
    expect(
      () => TranscriptCorrectionConfig.validateInstructions('invalid\u0000'),
      throwsFormatException,
    );
  });
}
