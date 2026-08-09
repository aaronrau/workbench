import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/continuous_transcript_store.dart';
import 'package:even_g2_r1_poc/src/audio/transcript_correction_supervisor.dart';
import 'package:even_g2_r1_poc/src/audio/transcript_turn_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync(
      'workbench-continuous-transcript-test-',
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test(
    'appends forced chunks to one atomically replaced conversation file',
    () async {
      final store = ContinuousTranscriptStore(speechPath: temp.path);

      final first = await store.append(
        conversationId: 'conversation-1',
        text: 'The first fifteen seconds.',
      );
      final second = await store.append(
        conversationId: 'conversation-1',
        text: 'The next fifteen seconds.',
      );

      expect(second.path, first.path);
      expect(second.appendedText, 'The next fifteen seconds.');
      expect(
        second.text,
        'The first fifteen seconds.\nThe next fifteen seconds.',
      );
      expect(File(second.path).readAsStringSync(), '${second.text}\n');
      expect(File('${second.path}.part').existsSync(), isFalse);
    },
  );

  test('deduplicates words repeated by a hard rollover overlap', () async {
    final store = ContinuousTranscriptStore(speechPath: temp.path);

    await store.append(
      conversationId: 'conversation-overlap',
      text: 'Please keep the final boundary word.',
    );
    final second = await store.append(
      conversationId: 'conversation-overlap',
      text: 'boundary word and continue safely.',
      deduplicateOverlap: true,
    );

    expect(second.appendedText, 'and continue safely.');
    expect(
      second.text,
      'Please keep the final boundary word.\nand continue safely.',
    );
  });

  test('preserves repeated wording when the audio did not overlap', () async {
    final store = ContinuousTranscriptStore(speechPath: temp.path);

    await store.append(
      conversationId: 'conversation-pause',
      text: 'Repeat this instruction.',
    );
    final second = await store.append(
      conversationId: 'conversation-pause',
      text: 'Repeat this instruction.',
    );

    expect(second.appendedText, 'Repeat this instruction.');
    expect(second.text, 'Repeat this instruction.\nRepeat this instruction.');
  });

  test('collects queued STT chunks and acts once on the final chunk', () async {
    final assembler = TranscriptTurnAssembler(
      store: ContinuousTranscriptStore(speechPath: temp.path),
    );

    final intermediate = await assembler.append(
      conversationId: 'conversation-action',
      text: 'Hey Flux inspect the current',
      isConversationFinal: false,
    );
    expect(intermediate.text, 'Hey Flux inspect the current');
    expect(intermediate.actionText, isNull);

    final finalChunk = await assembler.append(
      conversationId: 'conversation-action',
      text: 'queued state and send it.',
      isConversationFinal: true,
    );
    expect(
      finalChunk.actionText,
      'Hey Flux inspect the current\nqueued state and send it.',
    );
    expect(
      isLiveTranscriptCorrectionEligible(
        finalChunk.actionText!,
        explicitlyTargeted: false,
      ),
      isTrue,
      reason: 'The leading wake word from the first STT chunk must be kept.',
    );
    expect(
      isLiveTranscriptCorrectionEligible(
        finalChunk.appendedText,
        explicitlyTargeted: false,
      ),
      isFalse,
      reason: 'Routing only the final chunk would reproduce the original bug.',
    );
  });

  test('a single final STT chunk is immediately action-ready', () async {
    final assembler = TranscriptTurnAssembler(
      store: ContinuousTranscriptStore(speechPath: temp.path),
    );

    final result = await assembler.append(
      conversationId: 'conversation-short',
      text: 'Hey Flux send this.',
      isConversationFinal: true,
    );

    expect(result.actionText, 'Hey Flux send this.');
  });

  test('requires the complete wake word at the beginning', () {
    expect(transcriptBeginsWithWakeWord('HEY Flux, check progress.'), isTrue);
    expect(transcriptBeginsWithWakeWord('  hey, Memo, take this.'), isTrue);
    expect(transcriptBeginsWithWakeWord('hey'), isTrue);
    expect(
      transcriptBeginsWithWakeWord('Please, Hey Memo, take this.'),
      isFalse,
    );
    expect(transcriptBeginsWithWakeWord('they should continue'), isFalse);
    expect(transcriptBeginsWithWakeWord('a heyday story'), isFalse);
  });
}
