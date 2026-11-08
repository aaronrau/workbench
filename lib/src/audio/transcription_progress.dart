import 'dart:async';

/// Visible job state, driven by worker events rather than guessed percentages.
final class TranscriptionProgress {
  TranscriptionProgress({required this.onChanged, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final void Function() onChanged;
  String? _active;
  String _stage = 'Transcribing';
  DateTime? _started;
  Timer? _ticker;
  bool _disposed = false;
  int _queued = 0;
  int _held = 0;
  int _completed = 0;
  String? _waiting;
  String? _issue;

  String get summary {
    final active = _active;
    final lines = <String>[];
    if (active != null) {
      final seconds = _now().difference(_started!).inSeconds;
      lines.add(
        '$_stage $active · ${seconds}s elapsed'
        '${seconds >= 30 ? ' · still waiting for a result' : ''}',
      );
    } else {
      lines.add(
        _waiting ??
            (_queued > 0 ? 'Waiting to transcribe' : 'Transcription idle'),
      );
    }
    lines.add(
      '$_queued queued · $_held unable to transcribe · $_completed completed',
    );
    if (_issue != null) lines.add('Last issue: $_issue');
    return lines.join('\n');
  }

  void accept(String message) {
    if (_disposed) return;
    if (!RegExp(r'\[WorkBench\]\[(?:MOSS|Transcription)\]').hasMatch(message)) {
      return;
    }
    String? field(String name) =>
        RegExp('\\b$name=(\\S+)').firstMatch(message)?.group(1);
    final state = field('state');
    final id = field('segment');
    final pending = int.tryParse(field('pending') ?? '');
    if (pending != null) _queued = pending;
    switch (state) {
      case 'loading':
        _clearActive();
        _waiting = 'Loading transcription model';
      case 'ready':
        _waiting = _queued > 0
            ? 'Waiting for live audio or recovery slot'
            : null;
      case 'processing':
        _active = id ?? 'current clip';
        _started = _now();
        _stage = 'Transcribing';
        _waiting = null;
        _ticker ??= Timer.periodic(
          const Duration(seconds: 1),
          (_) => onChanged(),
        );
      case 'saving':
        _stage = 'Saving transcript';
      case 'completed':
        _completed++;
        if (id == _active) _clearActive();
        if (_queued > 0) _queued--;
        _waiting = null;
      case 'queue_status':
        _queued = int.tryParse(field('queued') ?? '') ?? _queued;
        _held = int.tryParse(field('held') ?? '') ?? _held;
      case 'retry_deferred' || 'job_retry':
        _clearActive();
        _waiting = 'Waiting to retry $id';
        _issue = 'Retry ${field('attempt') ?? ''} · audio saved';
      case 'worker_wait' || 'restarting':
        _clearActive();
        _waiting = 'Waiting for transcription worker to recover · audio saved';
      case 'job_preserved':
        _clearActive();
        _waiting = null;
        _issue =
            'Unable to transcribe $id · ${(field('reason') ?? 'worker_error').replaceAll('_', ' ')} · audio saved';
      case 'invalid_output' || 'job_failed' || 'failed':
        _clearActive();
        _waiting = null;
        _issue =
            'Unable to transcribe ${id ?? 'current clip'} · ${(field('reason') ?? 'worker_error').replaceAll('_', ' ')} · audio saved';
    }
    onChanged();
  }

  void _clearActive() {
    _active = null;
    _started = null;
    _ticker?.cancel();
    _ticker = null;
  }

  void dispose() {
    _disposed = true;
    _clearActive();
  }
}
