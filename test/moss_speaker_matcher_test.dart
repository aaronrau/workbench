import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:even_g2_r1_poc/src/audio/moss_speaker_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

SpeakerProfile _profile(
  String id,
  List<double> signature, {
  bool primary = false,
  bool calibrated = true,
}) => SpeakerProfile(
  id: id,
  label: primary ? 'You' : id,
  embedding: normalizeSpeakerEmbedding(signature),
  sampleCount: 3,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  isPrimary: primary,
  calibrationComplete: calibrated,
);
ConversationUtterance _turn(String speaker, int start, int end) =>
    ConversationUtterance(
      id: '$speaker-$start',
      conversationId: 'moss-synthetic',
      speakerId: 'moss:synthetic:$speaker',
      speakerLabel: 'Speaker 1 (clip)',
      text: 'Synthetic phrase.',
      startMs: start,
      endMs: end,
      confidence: 0,
      updatedAt: DateTime.utc(2026),
    );
ConversationRecord _record(List<ConversationUtterance> turns) =>
    ConversationRecord(
      id: 'moss-synthetic',
      audioPath: '/private/synthetic.wav',
      textPath: '/private/synthetic.conversation.txt',
      metadataPath: '/private/synthetic.conversation.json',
      utterances: turns,
      updatedAt: DateTime.utc(2026),
    );
void main() {
  test(
    'excludes overlap and merges repeated intervals before taking voice signatures',
    () {
      final windows = mossSpeakerWindows(
        _record([
          _turn('S01', 0, 2000),
          _turn('S01', 500, 1500),
          _turn('S02', 800, 1200),
        ]),
      );
      expect(windows['S01'], [
        [0, 800],
        [1200, 2000],
      ]);
      expect(windows['S02'], isEmpty);
    },
  );
  test(
    'matches saved voices across clips while keeping signatures out of readable exports',
    () {
      final input = _record([_turn('S01', 0, 2000), _turn('S02', 2000, 4000)]);
      final profiles = [
        _profile('primary', [1, 0], primary: true),
        _profile('Speaker 2', [0, 1]),
      ];
      final result = matchMossSpeakerProfiles(
        input,
        {
          'S01': [1, 0],
          'S02': [0, 1],
        },
        profiles,
        0.64,
      );
      expect(result.utterances.map((turn) => turn.speakerLabel), [
        'You',
        'Speaker 2',
      ]);
      expect(result.utterances.first.isPrimary, isTrue);
      expect(result.utterances.first.localSpeakerId, 'S01');
      expect(result.utterances.first.speakerSignature, [1, 0]);
      expect(
        result.utterances.map((turn) => turn.text),
        input.utterances.map((turn) => turn.text),
      );
      expect(
        encodeConversationText(result.utterances),
        isNot(contains('embedding')),
      );
      final restored = ConversationRecord.fromJson(result.toJson());
      expect(restored.speakerIdentificationVersion, 1);
      expect(restored.speakerProfileRevision, result.speakerProfileRevision);
      expect(restored.utterances.first.localSpeakerId, 'S01');
      expect(restored.utterances.first.speakerSignature, [1, 0]);
    },
  );
  test('refuses ambiguous, incomplete, weak, and missing voice matches', () {
    final input = _record([_turn('S01', 0, 2000)]);
    for (final profiles in [
      [
        _profile('one', [1, 0]),
        _profile('two', [1, 0.01]),
      ],
      [
        _profile('one', [1, 0], calibrated: false),
      ],
      [
        _profile('one', [0, 1]),
      ],
      <SpeakerProfile>[],
    ]) {
      final result = matchMossSpeakerProfiles(
        input,
        {
          'S01': [1, 0],
        },
        profiles,
        0.64,
      );
      expect(result.utterances.single.speakerId, 'moss:synthetic:S01');
      expect(result.utterances.single.isPrimary, isFalse);
      expect(result.utterances.single.confidence, 0);
    }
    final result = matchMossSpeakerProfiles(input, {}, [
      _profile('primary', [1, 0], primary: true),
    ], 0.64);
    expect(result.utterances.single.speakerLabel, 'Speaker 1 (clip)');
  });
  test('does not collapse two local speakers into the same saved identity', () {
    final result = matchMossSpeakerProfiles(
      _record([_turn('S01', 0, 2000), _turn('S02', 2000, 4000)]),
      {
        'S01': [1, 0],
        'S02': normalizeSpeakerEmbedding([1, 0.1]),
      },
      [
        _profile('primary', [1, 0], primary: true),
      ],
      0.64,
    );
    expect(result.utterances.where((turn) => turn.isPrimary), hasLength(1));
    expect(result.utterances.last.speakerId, 'moss:synthetic:S02');
  });
}
