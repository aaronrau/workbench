import 'package:even_g2_r1_poc/src/websocket/selected_agent_transcript_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SelectedAgentTranscriptSession createSession() =>
      SelectedAgentTranscriptSession(
        id: 'agent-listen-1',
        agent: 'Flux',
        source: 'agent_detail',
      );

  test('accumulates ordered STT chunks without VAD ending the session', () {
    final session = createSession();

    expect(session.registerSegment('segment-1'), isTrue);
    expect(session.completeSegment('segment-1', 'first thought'), isTrue);
    expect(session.isListening, isTrue);
    expect(session.transcript, 'first thought');

    expect(session.registerSegment('segment-2'), isTrue);
    expect(session.completeSegment('segment-2', 'second thought'), isTrue);
    expect(session.isListening, isTrue);
    expect(session.transcript, 'first thought\nsecond thought');
  });

  test('second tap waits for every queued STT chunk before submission', () {
    final session = createSession();
    session
      ..registerSegment('segment-1')
      ..completeSegment('segment-1', 'already transcribed')
      ..registerSegment('segment-2');

    expect(session.requestFinish(), isTrue);
    expect(session.canSubmit, isFalse);
    expect(session.hasPendingSegments, isTrue);

    expect(session.completeSegment('segment-2', 'last queued chunk'), isTrue);
    expect(session.canSubmit, isTrue);
    expect(session.transcript, 'already transcribed\nlast queued chunk');
    expect(session.markSubmitted(), isTrue);
    expect(session.markSubmitted(), isFalse);
  });

  test('flush can register a final segment after finish was requested', () {
    final session = createSession();

    expect(session.requestFinish(), isTrue);
    expect(session.registerSegment('flush-segment'), isTrue);
    expect(session.canSubmit, isFalse);
    expect(session.completeSegment('flush-segment', 'final words'), isTrue);
    expect(session.canSubmit, isTrue);
  });

  test('long sessions retain every VAD-separated transcript chunk', () {
    final session = createSession();

    for (var index = 0; index < 40; index++) {
      final segmentId = 'segment-$index';
      expect(session.registerSegment(segmentId), isTrue);
      expect(
        session.completeSegment(segmentId, 'synthetic phrase $index'),
        isTrue,
      );
    }

    expect(session.isListening, isTrue);
    expect(session.segmentIds, hasLength(40));
    expect(session.transcript, startsWith('synthetic phrase 0\n'));
    expect(session.transcript, endsWith('synthetic phrase 39'));
    expect(session.requestFinish(), isTrue);
    expect(session.canSubmit, isTrue);
  });

  test('cancel drains in-flight chunks but can never submit them', () {
    final session = createSession();

    expect(session.cancel(), isTrue);
    expect(session.registerSegment('in-flight-segment'), isTrue);
    expect(session.completeSegment('in-flight-segment', 'do not send'), isTrue);
    expect(session.isCanceled, isTrue);
    expect(session.canSubmit, isFalse);
    expect(session.markSubmitted(), isFalse);
  });

  test('an empty manual session completes exactly once without sending', () {
    final session = createSession();

    expect(session.requestFinish(), isTrue);
    expect(session.finishedWithoutTranscript, isTrue);
    expect(session.markFinishedWithoutTranscript(), isTrue);
    expect(session.markFinishedWithoutTranscript(), isFalse);
    expect(session.canSubmit, isFalse);
  });

  test('preview correction becomes current for the complete raw revision', () {
    final session = createSession();

    expect(session.enablePreview(), isTrue);
    expect(session.previewState, SelectedAgentCorrectionPreviewState.waiting);
    session
      ..registerSegment('segment-1')
      ..completeSegment('segment-1', 'raw first thought');

    final snapshot = session.correctionSnapshot();
    expect(snapshot?.revision, 1);
    expect(snapshot?.transcript, 'raw first thought');
    expect(session.markPreviewQueued(1), isTrue);
    expect(session.markPreviewCorrecting(1), isTrue);
    expect(
      session.acceptPreview(
        revision: 1,
        correctedTranscript: 'Corrected first thought.',
      ),
      isTrue,
    );

    expect(session.isPreviewCurrent, isTrue);
    expect(session.displayTranscript, 'Corrected first thought.');
    expect(session.previewNeedsCorrection, isFalse);
  });

  test(
    'speech appended during correction automatically makes preview stale',
    () {
      final session = createSession()
        ..enablePreview()
        ..registerSegment('segment-1')
        ..completeSegment('segment-1', 'first raw thought');
      final first = session.correctionSnapshot()!;
      session
        ..markPreviewQueued(first.revision)
        ..markPreviewCorrecting(first.revision)
        ..registerSegment('segment-2')
        ..completeSegment('segment-2', 'second raw thought');

      expect(
        session.previewState,
        SelectedAgentCorrectionPreviewState.updatePending,
      );
      expect(
        session.acceptPreview(
          revision: first.revision,
          correctedTranscript: 'Corrected first thought.',
        ),
        isTrue,
      );
      expect(session.displayTranscript, contains('Corrected first thought.'));
      expect(session.displayTranscript, endsWith('second raw thought'));
      expect(session.isPreviewCurrent, isFalse);

      final second = session.correctionSnapshot()!;
      expect(second.revision, 2);
      expect(second.transcript, 'first raw thought\nsecond raw thought');
      session
        ..markPreviewQueued(second.revision)
        ..markPreviewCorrecting(second.revision)
        ..acceptPreview(
          revision: second.revision,
          correctedTranscript: 'Corrected first and second thoughts.',
        );
      expect(session.isPreviewCurrent, isTrue);
      expect(session.displayTranscript, 'Corrected first and second thoughts.');
    },
  );

  test('a current preview remains reusable when send is requested', () {
    final session = createSession()
      ..enablePreview()
      ..registerSegment('segment-1')
      ..completeSegment('segment-1', 'raw command');
    final snapshot = session.correctionSnapshot()!;
    session
      ..markPreviewQueued(snapshot.revision)
      ..markPreviewCorrecting(snapshot.revision)
      ..acceptPreview(
        revision: snapshot.revision,
        correctedTranscript: 'Corrected command.',
      );

    expect(session.requestFinish(), isTrue);
    expect(session.canSubmit, isTrue);
    expect(session.isPreviewCurrent, isTrue);
    expect(session.correctionSnapshot(), isNull);
    expect(
      session.sendCorrectionMode,
      SelectedAgentSendCorrectionMode.reusePreview,
    );
  });

  test(
    'Preview Off corrects at Send while failed Preview On preserves raw',
    () {
      final previewOff = createSession()
        ..registerSegment('segment-1')
        ..completeSegment('segment-1', 'raw command')
        ..requestFinish();
      expect(
        previewOff.sendCorrectionMode,
        SelectedAgentSendCorrectionMode.correctAtSend,
      );

      final previewOn = createSession()
        ..enablePreview()
        ..registerSegment('segment-1')
        ..completeSegment('segment-1', 'raw command');
      final snapshot = previewOn.correctionSnapshot()!;
      previewOn
        ..markPreviewQueued(snapshot.revision)
        ..markPreviewCorrecting(snapshot.revision)
        ..failPreview(snapshot.revision)
        ..requestFinish();
      expect(
        previewOn.sendCorrectionMode,
        SelectedAgentSendCorrectionMode.preserveRaw,
      );
    },
  );

  test('failed preview waits for new STT before auto-correcting again', () {
    final session = createSession()
      ..enablePreview()
      ..registerSegment('segment-1')
      ..completeSegment('segment-1', 'first raw thought');
    final first = session.correctionSnapshot()!;
    session
      ..markPreviewQueued(first.revision)
      ..markPreviewCorrecting(first.revision);

    expect(session.failPreview(first.revision), isTrue);
    expect(session.previewState, SelectedAgentCorrectionPreviewState.failed);
    expect(session.correctionSnapshot(), isNull);

    session
      ..registerSegment('segment-2')
      ..completeSegment('segment-2', 'second raw thought');
    expect(session.correctionSnapshot()?.revision, 2);
  });

  test('cancel rejects an in-flight preview result', () {
    final session = createSession()
      ..enablePreview()
      ..registerSegment('segment-1')
      ..completeSegment('segment-1', 'raw command');
    final snapshot = session.correctionSnapshot()!;
    session
      ..markPreviewQueued(snapshot.revision)
      ..markPreviewCorrecting(snapshot.revision);

    expect(session.cancel(), isTrue);
    expect(session.previewEnabled, isFalse);
    expect(
      session.acceptPreview(
        revision: snapshot.revision,
        correctedTranscript: 'Late corrected command.',
      ),
      isFalse,
    );
    expect(session.previewTranscript, isNull);
  });
}
