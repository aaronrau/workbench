import 'package:even_g2_r1_poc/src/audio/transcription_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows elapsed processing, queue, saving, failure and retry states', (
    tester,
  ) async {
    var now = DateTime(2026);
    var changes = 0;
    final progress = TranscriptionProgress(
      onChanged: () => changes++,
      now: () => now,
    );
    addTearDown(progress.dispose);
    progress.accept('[WorkBench][MOSS] state=queue_status queued=2 held=1');
    progress.accept(
      '[WorkBench][MOSS] state=processing segment=synthetic-clip',
    );
    now = now.add(const Duration(seconds: 31));
    final beforeTick = changes;
    await tester.pump(const Duration(seconds: 1));
    expect(changes, greaterThan(beforeTick));
    expect(
      progress.summary,
      contains('31s elapsed · still waiting for a result'),
    );
    expect(progress.summary, contains('2 queued · 1 unable to transcribe'));
    progress.accept('[WorkBench][MOSS] state=saving segment=synthetic-clip');
    expect(progress.summary, contains('Saving transcript'));
    progress.accept('[WorkBench][MOSS] state=completed segment=synthetic-clip');
    expect(progress.summary, isNot(contains('elapsed')));
    expect(progress.summary, contains('1 completed'));
    final afterResult = changes;
    await tester.pump(const Duration(seconds: 2));
    expect(changes, afterResult);
    progress.accept('[WorkBench][MOSS] state=processing segment=synthetic-bad');
    progress.accept(
      '[WorkBench][MOSS] state=job_preserved segment=synthetic-bad reason=incomplete_speaker_timestamps',
    );
    expect(
      progress.summary,
      contains(
        'Unable to transcribe synthetic-bad · incomplete speaker timestamps · audio saved',
      ),
    );
    progress.accept(
      '[WorkBench][MOSS] state=retry_deferred segment=synthetic-retry attempt=2',
    );
    expect(progress.summary, contains('Waiting to retry synthetic-retry'));
    progress.accept('[WorkBench][MOSS] state=worker_wait');
    expect(progress.summary, contains('worker to recover'));
    progress.dispose();
    await tester.pump(const Duration(seconds: 2));
  });
}
