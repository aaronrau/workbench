enum TranscriptPreviewStatus {
  original,
  corrected,
  sending,
  sent,
  saved;

  String get label => switch (this) {
    original => 'Original',
    corrected => 'Corrected',
    sending => 'Sending',
    sent => 'Sent',
    saved => 'Saved',
  };
}

final class TranscriptTurnState {
  String? _currentSegmentId;
  String? _visibleText;
  String? _resultId;
  TranscriptPreviewStatus status = TranscriptPreviewStatus.original;

  String? get currentSegmentId => _currentSegmentId;
  String? get visibleText => _visibleText;

  void startTurn(String segmentId) {
    _currentSegmentId = segmentId;
    _visibleText = null;
    _resultId = null;
    status = TranscriptPreviewStatus.original;
  }

  bool completeTurn(String segmentId, String text, {String? resultId}) {
    if (segmentId != _currentSegmentId) {
      return false;
    }
    final normalized = text.trim();
    _visibleText = normalized.isEmpty ? null : normalized;
    _resultId = resultId ?? segmentId;
    status = TranscriptPreviewStatus.original;
    return true;
  }

  /// A late correction or acknowledgement must not replace a newer turn.
  bool updateDelivery(
    String resultId,
    String text,
    TranscriptPreviewStatus nextStatus,
  ) {
    if (_resultId != resultId) return false;
    _visibleText = text.trim().isEmpty ? null : text.trim();
    status = nextStatus;
    return true;
  }

  void endSession() {
    _currentSegmentId = null;
    _visibleText = null;
    _resultId = null;
    status = TranscriptPreviewStatus.original;
  }
}
