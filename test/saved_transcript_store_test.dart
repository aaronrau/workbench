import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/saved_transcript_store.dart';
import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'restores a manual correction for its original transcript only',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'workbench-history-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final speech = await Directory(
        '${root.path}/workbench/audio/moss',
      ).create(recursive: true);
      final original = File('${speech.path}/sample.raw.txt');
      await original.writeAsString('Run the chek.\n');

      final store = SavedTranscriptStore(supportDirectory: () async => root);
      const empty = <SharedTranscript>[];
      await store.refresh(empty);
      final transcript = store.history(empty).single;
      expect(transcript.originalText, 'Run the chek.');
      await store.saveCorrection(transcript, 'Run the check.');
      expect(await original.readAsString(), 'Run the chek.\n');

      final restored = SavedTranscriptStore(supportDirectory: () async => root);
      await restored.refresh(empty);
      expect(restored.history(empty).single.correctedText, 'Run the check.');
      await original.writeAsString('A different saved transcript.\n');
      await restored.refresh(empty);
      expect(restored.history(empty).single.correctedText, isNull);
    },
  );
}
