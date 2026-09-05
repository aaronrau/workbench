import 'dart:async';

import 'package:flutter/foundation.dart';

enum MicrophonePhase { off, starting, recording, stopping, error }

/// Claims microphone ownership before any asynchronous permission or startup work.
/// A stop always waits for startup and drains capture before releasing ownership.
final class PhoneMicrophoneSession extends ChangeNotifier {
  PhoneMicrophoneSession({
    required this.canStart,
    required this.requestPermission,
    required this.prepareCapture,
    required this.startRecorder,
    required this.stopRecorder,
    required this.finishCapture,
  });

  final bool Function() canStart;
  final Future<void> Function() requestPermission;
  final Future<void> Function() prepareCapture;
  final Future<void> Function() startRecorder;
  final Future<void> Function() stopRecorder;
  final Future<void> Function() finishCapture;
  MicrophonePhase phase = MicrophonePhase.off;
  String? error;
  Future<void>? _starting;
  Future<void>? _stopping;
  bool _cancelStart = false;
  bool _disposed = false;
  bool _cleanupIncomplete = false;
  bool get ownsInput =>
      _cleanupIncomplete ||
      (phase != MicrophonePhase.off && phase != MicrophonePhase.error);
  bool get recording => phase == MicrophonePhase.recording;

  void _setPhase(MicrophonePhase value) {
    phase = value;
    if (!_disposed) notifyListeners();
  }

  Future<void> start() {
    if (_disposed || ownsInput || !canStart()) {
      return Future<void>.error(
        StateError(
          'Disconnect the glasses and wait for local audio before starting the microphone.',
        ),
      );
    }
    _cancelStart = false;
    error = null;
    _setPhase(MicrophonePhase.starting);
    return _starting = _start();
  }

  Future<void> _start() async {
    try {
      await requestPermission();
      if (_cancelStart) return;
      await prepareCapture();
      if (_cancelStart) return;
      await startRecorder();
      if (!_cancelStart) _setPhase(MicrophonePhase.recording);
    } on Object {
      _cancelStart = true;
      try {
        await _cleanup();
      } finally {
        error =
            'Microphone could not start. Check microphone permission and audio readiness.';
        _setPhase(MicrophonePhase.error);
      }
      rethrow;
    }
  }

  Future<void> stop({bool failed = false}) {
    if (_stopping != null) return _stopping!;
    if (!ownsInput) return Future<void>.value();
    _cancelStart = true;
    _setPhase(MicrophonePhase.stopping);
    return _stopping = _stop(failed).whenComplete(() => _stopping = null);
  }

  Future<void> _cleanup() async {
    _cleanupIncomplete = true;
    try {
      await stopRecorder();
    } finally {
      await finishCapture();
    }
    _cleanupIncomplete = false;
  }

  Future<void> _stop(bool failed) async {
    try {
      try {
        await _starting;
      } on Object {
        /* Startup already reported failure. */
      }
      await _cleanup();
      error = failed
          ? 'Microphone stopped. Check input and available storage, then retry.'
          : null;
      _setPhase(failed ? MicrophonePhase.error : MicrophonePhase.off);
    } on Object {
      error = 'Microphone cleanup needs retry. Tap Stop microphone.';
      _setPhase(MicrophonePhase.error);
      rethrow;
    } finally {
      _starting = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
