import 'continuous_transcript_store.dart';

/// The durable transcript state produced when one STT chunk completes.
final class TranscriptTurnAssembly {
  const TranscriptTurnAssembly({
    required this.path,
    required this.text,
    required this.appendedText,
    required this.actionText,
  });

  final String path;
  final String text;
  final String appendedText;

  /// The complete logical turn when it is ready for a downstream action.
  ///
  /// A null value means STT should keep collecting conversation chunks. An
  /// empty non-null value is a final turn with no recognized text.
  final String? actionText;
}

/// Appends STT chunks immediately but opens the action boundary only when VAD
/// has finalized the logical conversation.
final class TranscriptTurnAssembler {
  const TranscriptTurnAssembler({required ContinuousTranscriptStore store})
    : _store = store;

  final ContinuousTranscriptStore _store;

  Future<TranscriptTurnAssembly> append({
    required String conversationId,
    required String text,
    required bool isConversationFinal,
    bool deduplicateOverlap = false,
  }) async {
    final snapshot = await _store.append(
      conversationId: conversationId,
      text: text,
      deduplicateOverlap: deduplicateOverlap,
    );
    return TranscriptTurnAssembly(
      path: snapshot.path,
      text: snapshot.text,
      appendedText: snapshot.appendedText,
      actionText: isConversationFinal ? snapshot.text.trim() : null,
    );
  }
}
