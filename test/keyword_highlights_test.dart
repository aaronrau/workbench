import 'package:even_g2_r1_poc/src/audio/keyword_highlights.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('counts whole words and phrases in distinct raw segments', () {
    final tracker = KeywordHighlights();
    final now = DateTime(2026, 1, 1);

    expect(
      tracker.accept(
        segmentId: 'one',
        rawText: 'Yeah, yeah. So I think: hmm. Somehow.',
        now: now,
      ),
      isTrue,
    );
    expect(tracker.active.map((item) => item.label), [
      'yeah(2)',
      'so',
      'i think',
      'hmm',
    ]);
    expect(tracker.accept(segmentId: 'one', rawText: 'hmm', now: now), isFalse);
    expect(
      tracker.accept(
        segmentId: 'two',
        rawText: 'hmm... HMM',
        now: now.add(const Duration(seconds: 30)),
      ),
      isTrue,
    );
    expect(tracker.active.last.label, 'hmm(3)');
    expect(
      tracker.active.last.expiresAt,
      now.add(const Duration(minutes: 2, seconds: 30)),
    );
  });

  test('each keyword expires independently and a new hit resets its count', () {
    final tracker = KeywordHighlights();
    final now = DateTime(2026, 1, 1);
    tracker.accept(segmentId: 'one', rawText: 'yeah hmm', now: now);
    tracker.accept(
      segmentId: 'two',
      rawText: 'hmm',
      now: now.add(const Duration(minutes: 1)),
    );

    expect(tracker.prune(now.add(const Duration(minutes: 2))), isTrue);
    expect(tracker.active.map((item) => item.label), ['hmm(2)']);
    expect(tracker.prune(now.add(const Duration(minutes: 3))), isTrue);
    expect(tracker.active, isEmpty);
    tracker.accept(
      segmentId: 'three',
      rawText: 'hmm',
      now: now.add(const Duration(minutes: 4)),
    );
    expect(tracker.active.single.label, 'hmm');
  });

  test('editing phrases removes old highlights and keeps unchanged counts', () {
    final tracker = KeywordHighlights();
    final now = DateTime(2026, 1, 1);
    tracker.accept(segmentId: 'one', rawText: 'yeah hmm', now: now);
    tracker.setPhrases(['hmm', 'new phrase'], now);
    expect(tracker.active.map((item) => item.label), ['hmm']);
    tracker.accept(segmentId: 'two', rawText: 'new phrase', now: now);
    expect(tracker.active.map((item) => item.label), ['hmm', 'new phrase']);
    tracker.setPhrases([], now);
    expect(tracker.active, isEmpty);
  });

  test('rejects duplicate or invalid phrases', () {
    expect(
      () => KeywordHighlights.validatePhrases(['Yeah', ' yeah ']),
      throwsFormatException,
    );
    expect(
      () => KeywordHighlights.validatePhrases(['hmm!']),
      throwsFormatException,
    );
  });

  test('saves only its setting and preserves existing preferences', () async {
    SharedPreferences.setMockInitialValues({'existing_data': 'retain'});
    const store = KeywordHighlightPreferences();
    expect(await store.load(), defaultKeywordHighlightPhrases);
    await store.save(['hello', 'i think']);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('existing_data'), 'retain');
    expect(await store.load(), ['hello', 'i think']);
    await store.save([]);
    expect(await store.load(), isEmpty);
    expect(preferences.getString('existing_data'), 'retain');
  });
}
