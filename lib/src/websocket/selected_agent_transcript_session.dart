import 'dart:collection';

enum SelectedAgentTranscriptSessionState {
  listening,
  finishing,
  canceled,
  submitted,
}

enum SelectedAgentCorrectionPreviewState {
  off,
  waiting,
  queued,
  correcting,
  updatePending,
  current,
  failed,
}

enum SelectedAgentSendCorrectionMode {
  correctAtSend,
  reusePreview,
  preserveRaw,
}

final class SelectedAgentTranscriptSnapshot {
  const SelectedAgentTranscriptSnapshot({
    required this.revision,
    required this.transcript,
  });

  final int revision;
  final String transcript;
}

/// Owns the ordered STT chunks collected between the user's two Listen Mode
/// taps. VAD endpoints close audio chunks, never this manual session.
final class SelectedAgentTranscriptSession {
  SelectedAgentTranscriptSession({
    required this.id,
    required this.agent,
    required this.source,
  });

  final String id;
  final String agent;
  final String source;
  final LinkedHashMap<String, String?> _segments =
      LinkedHashMap<String, String?>();
  final Map<String, int> _segmentRevisions = <String, int>{};

  SelectedAgentTranscriptSessionState state =
      SelectedAgentTranscriptSessionState.listening;
  SelectedAgentCorrectionPreviewState previewState =
      SelectedAgentCorrectionPreviewState.off;
  int _transcriptRevision = 0;
  int? _previewRevision;
  String? _previewTranscript;
  int? _previewRequestRevision;
  int? _previewFailureRevision;

  Iterable<String> get segmentIds => _segments.keys;
  bool get hasSegments => _segments.isNotEmpty;
  bool get hasPendingSegments => _segments.values.any((text) => text == null);
  bool get isListening =>
      state == SelectedAgentTranscriptSessionState.listening;
  bool get isFinishing =>
      state == SelectedAgentTranscriptSessionState.finishing;
  bool get isCanceled => state == SelectedAgentTranscriptSessionState.canceled;
  int get transcriptRevision => _transcriptRevision;
  bool get previewEnabled =>
      previewState != SelectedAgentCorrectionPreviewState.off;
  int? get previewRevision => _previewRevision;
  int? get previewRequestRevision => _previewRequestRevision;
  String? get previewTranscript => _previewTranscript;

  String get transcript => _segments.values
      .whereType<String>()
      .map((text) => text.trim())
      .where((text) => text.isNotEmpty)
      .join('\n');

  String get transcriptAfterPreview {
    final previewRevision = _previewRevision;
    if (previewRevision == null) {
      return transcript;
    }
    return _segments.entries
        .where(
          (entry) =>
              (_segmentRevisions[entry.key] ?? 0) > previewRevision &&
              (entry.value?.trim().isNotEmpty ?? false),
        )
        .map((entry) => entry.value!.trim())
        .join('\n');
  }

  String get displayTranscript {
    if (!previewEnabled) {
      return transcript;
    }
    final corrected = (_previewTranscript ?? '').trim();
    if (corrected.isEmpty) {
      return transcript;
    }
    final tail = transcriptAfterPreview;
    return tail.isEmpty ? corrected : '$corrected\n$tail';
  }

  bool get isPreviewCurrent =>
      previewEnabled &&
      _previewRevision == _transcriptRevision &&
      (_previewTranscript?.trim().isNotEmpty ?? false) &&
      !hasPendingSegments;

  bool get previewNeedsCorrection =>
      previewEnabled &&
      transcript.isNotEmpty &&
      _previewFailureRevision != _transcriptRevision &&
      (_previewRevision != _transcriptRevision ||
          !(_previewTranscript?.trim().isNotEmpty ?? false));

  SelectedAgentSendCorrectionMode get sendCorrectionMode {
    if (!previewEnabled) {
      return SelectedAgentSendCorrectionMode.correctAtSend;
    }
    return isPreviewCurrent
        ? SelectedAgentSendCorrectionMode.reusePreview
        : SelectedAgentSendCorrectionMode.preserveRaw;
  }

  bool ownsSegment(String segmentId) => _segments.containsKey(segmentId);

  bool registerSegment(String segmentId) {
    if (segmentId.isEmpty ||
        (state != SelectedAgentTranscriptSessionState.listening &&
            state != SelectedAgentTranscriptSessionState.finishing &&
            state != SelectedAgentTranscriptSessionState.canceled)) {
      return false;
    }
    if (_segments.containsKey(segmentId)) {
      return false;
    }
    _segments[segmentId] = null;
    return true;
  }

  bool completeSegment(String segmentId, String transcript) {
    if (!_segments.containsKey(segmentId) || _segments[segmentId] != null) {
      return false;
    }
    _segments[segmentId] = transcript.trim();
    _transcriptRevision++;
    _segmentRevisions[segmentId] = _transcriptRevision;
    if (previewEnabled) {
      previewState = _previewRequestRevision == null
          ? SelectedAgentCorrectionPreviewState.queued
          : SelectedAgentCorrectionPreviewState.updatePending;
    }
    return true;
  }

  bool enablePreview() {
    if (previewEnabled ||
        state != SelectedAgentTranscriptSessionState.listening) {
      return false;
    }
    previewState = transcript.isEmpty
        ? SelectedAgentCorrectionPreviewState.waiting
        : _previewRevision == _transcriptRevision &&
              (_previewTranscript?.trim().isNotEmpty ?? false)
        ? SelectedAgentCorrectionPreviewState.current
        : SelectedAgentCorrectionPreviewState.queued;
    return true;
  }

  bool disablePreview() {
    if (!previewEnabled ||
        state != SelectedAgentTranscriptSessionState.listening) {
      return false;
    }
    previewState = SelectedAgentCorrectionPreviewState.off;
    _previewRequestRevision = null;
    _previewFailureRevision = null;
    return true;
  }

  SelectedAgentTranscriptSnapshot? correctionSnapshot() {
    final value = transcript;
    if (!previewEnabled || value.isEmpty || !previewNeedsCorrection) {
      return null;
    }
    return SelectedAgentTranscriptSnapshot(
      revision: _transcriptRevision,
      transcript: value,
    );
  }

  bool markPreviewQueued(int revision) {
    if (!previewEnabled ||
        revision > _transcriptRevision ||
        _previewRequestRevision != null) {
      return false;
    }
    _previewRequestRevision = revision;
    previewState = revision == _transcriptRevision
        ? SelectedAgentCorrectionPreviewState.queued
        : SelectedAgentCorrectionPreviewState.updatePending;
    return true;
  }

  bool markPreviewCorrecting(int revision) {
    if (!previewEnabled || _previewRequestRevision != revision) {
      return false;
    }
    previewState = revision == _transcriptRevision
        ? SelectedAgentCorrectionPreviewState.correcting
        : SelectedAgentCorrectionPreviewState.updatePending;
    return true;
  }

  bool acceptPreview({
    required int revision,
    required String correctedTranscript,
  }) {
    final corrected = correctedTranscript.trim();
    if (!previewEnabled ||
        _previewRequestRevision != revision ||
        corrected.isEmpty ||
        (_previewRevision != null && revision < _previewRevision!)) {
      return false;
    }
    _previewRequestRevision = null;
    _previewRevision = revision;
    _previewTranscript = corrected;
    _previewFailureRevision = null;
    previewState = revision == _transcriptRevision
        ? SelectedAgentCorrectionPreviewState.current
        : SelectedAgentCorrectionPreviewState.queued;
    return true;
  }

  bool failPreview(int revision) {
    if (!previewEnabled || _previewRequestRevision != revision) {
      return false;
    }
    _previewRequestRevision = null;
    _previewFailureRevision = revision;
    previewState = revision == _transcriptRevision
        ? SelectedAgentCorrectionPreviewState.failed
        : SelectedAgentCorrectionPreviewState.queued;
    return true;
  }

  bool requestFinish() {
    if (state != SelectedAgentTranscriptSessionState.listening) {
      return false;
    }
    state = SelectedAgentTranscriptSessionState.finishing;
    return true;
  }

  bool cancel() {
    if (state != SelectedAgentTranscriptSessionState.listening) {
      return false;
    }
    state = SelectedAgentTranscriptSessionState.canceled;
    previewState = SelectedAgentCorrectionPreviewState.off;
    _previewRequestRevision = null;
    return true;
  }

  bool get canSubmit =>
      state == SelectedAgentTranscriptSessionState.finishing &&
      !hasPendingSegments &&
      transcript.isNotEmpty;

  bool get finishedWithoutTranscript =>
      state == SelectedAgentTranscriptSessionState.finishing &&
      !hasPendingSegments &&
      transcript.isEmpty;

  bool markSubmitted() {
    if (!canSubmit) {
      return false;
    }
    state = SelectedAgentTranscriptSessionState.submitted;
    return true;
  }

  bool markFinishedWithoutTranscript() {
    if (!finishedWithoutTranscript) {
      return false;
    }
    state = SelectedAgentTranscriptSessionState.submitted;
    return true;
  }
}
