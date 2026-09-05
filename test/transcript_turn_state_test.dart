import 'package:even_g2_r1_poc/src/audio/transcript_turn_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'latest raw preview advances through corrected text and acknowledgement',
    () {
      final state = TranscriptTurnState()..startTurn('conversation-1');
      state.completeTurn(
        'conversation-1',
        'raw words',
        resultId: 'chunk-final',
      );
      expect(state.status, TranscriptPreviewStatus.original);
      expect(
        state.updateDelivery(
          'chunk-final',
          'Corrected words',
          TranscriptPreviewStatus.sending,
        ),
        isTrue,
      );
      expect(state.visibleText, 'Corrected words');
      expect(state.status, TranscriptPreviewStatus.sending);
      state.updateDelivery(
        'chunk-final',
        'Corrected words',
        TranscriptPreviewStatus.sent,
      );
      expect(state.status.label, 'Sent');
      state.startTurn('conversation-2');
      expect(
        state.updateDelivery(
          'chunk-final',
          'Old words',
          TranscriptPreviewStatus.sent,
        ),
        isFalse,
      );
      expect(state.visibleText, isNull);
    },
  );

  test('new speech clears the previous visible transcript', () {
    final state = TranscriptTurnState();

    state.startTurn('turn-1');
    expect(state.completeTurn('turn-1', 'First turn'), isTrue);
    expect(state.visibleText, 'First turn');

    state.startTurn('turn-2');

    expect(state.visibleText, isNull);
    expect(state.currentSegmentId, 'turn-2');
  });

  test('an older result cannot replace the active turn', () {
    final state = TranscriptTurnState()..startTurn('turn-1');
    state.startTurn('turn-2');

    expect(state.completeTurn('turn-1', 'Stale result'), isFalse);
    expect(state.visibleText, isNull);
    expect(state.completeTurn('turn-2', 'Current result'), isTrue);
    expect(state.visibleText, 'Current result');
  });

  test('disconnect clears text and suppresses a late result', () {
    final state = TranscriptTurnState()..startTurn('turn-1');
    state.endSession();

    expect(state.visibleText, isNull);
    expect(state.completeTurn('turn-1', 'Late result'), isFalse);
    expect(state.visibleText, isNull);
  });
}
