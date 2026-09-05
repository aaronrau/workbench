import 'dart:async';

import 'package:flutter/services.dart';

typedef MicrophonePcmSink = void Function(Uint8List pcm);

/// Pulls one bounded native chunk at a time; stopping drains the native tail.
final class AndroidMicrophoneSource {
  AndroidMicrophoneSource({
    MethodChannel channel = const MethodChannel(
      'dev.opensourceglasses/workbench_microphone',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;
  Future<void>? _pump;
  Future<void>? _stopping;
  bool _stopped = true;
  int _generation = 0;

  Future<void> start({
    required MicrophonePcmSink onPcm,
    required void Function() onFailure,
  }) async {
    if (!_stopped || _pump != null) {
      throw StateError('Microphone is already active.');
    }
    _stopped = false;
    final generation = ++_generation;
    try {
      await _channel
          .invokeMethod<void>('start')
          .timeout(const Duration(seconds: 10));
      _pump = _read(generation, onPcm, onFailure);
    } on Object {
      await stop();
      rethrow;
    }
  }

  Future<void> _read(
    int generation,
    MicrophonePcmSink onPcm,
    void Function() onFailure,
  ) async {
    try {
      while (generation == _generation) {
        final pcm = await _channel
            .invokeMethod<Uint8List>('read')
            .timeout(const Duration(seconds: 3));
        if (generation != _generation) return;
        if (pcm == null) {
          if (!_stopped) onFailure();
          return;
        }
        if (pcm.isNotEmpty) {
          if (pcm.length.isOdd || pcm.length > 3200) {
            throw const FormatException('Invalid microphone PCM chunk.');
          }
          onPcm(pcm);
        }
      }
    } on Object {
      if (_stopped) rethrow;
      if (generation == _generation) onFailure();
    }
  }

  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    _stopped = true;
    // Attach the error handler before stopping native capture: its pending
    // read can fail while the stop method is still completing.
    final drain = _pump?.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    try {
      await _channel
          .invokeMethod<void>('stop')
          .timeout(const Duration(seconds: 5));
      // read() returns remaining chunks followed by null after native stop.
      final error = await drain?.timeout(const Duration(seconds: 5));
      if (error != null) throw error;
    } finally {
      ++_generation;
      _pump = null;
      await _channel
          .invokeMethod<void>('release')
          .timeout(const Duration(seconds: 5));
    }
  }
}
