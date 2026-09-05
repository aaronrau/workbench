import 'dart:async';

import 'package:even_g2_r1_poc/src/audio/phone_microphone_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> events;
  PhoneMicrophoneSession session({
    bool Function()? canStart,
    Future<void> Function()? permission,
    Future<void> Function()? stop,
  }) => PhoneMicrophoneSession(
    canStart: canStart ?? () => true,
    requestPermission:
        permission ??
        () async {
          events.add('permission');
        },
    prepareCapture: () async {
      events.add('journal');
    },
    startRecorder: () async {
      events.add('record');
    },
    stopRecorder:
        stop ??
        () async {
          events.add('stop');
        },
    finishCapture: () async {
      events.add('flush');
    },
  );
  setUp(() {
    events = [];
  });

  test('claims input before permission; rejects duplicate start', () async {
    final permission = Completer<void>();
    final mic = session(permission: () => permission.future);
    final start = mic.start();
    expect(mic.ownsInput, isTrue);
    expect(mic.phase, MicrophonePhase.starting);
    await expectLater(mic.start(), throwsStateError);
    permission.complete();
    await start;
    expect(events, ['journal', 'record']);
    await mic.stop();
    expect(events, ['journal', 'record', 'stop', 'flush']);
    expect(mic.ownsInput, isFalse);
    mic.dispose();
  });

  test('glasses or readiness gate prevents permission and capture', () async {
    final mic = session(canStart: () => false);
    await expectLater(mic.start(), throwsStateError);
    expect(events, isEmpty);
    expect(mic.ownsInput, isFalse);
    mic.dispose();
  });

  test('stop during permission prevents later recorder startup', () async {
    final permission = Completer<void>();
    final mic = session(permission: () => permission.future);
    final start = mic.start();
    final stop = mic.stop();
    expect(mic.ownsInput, isTrue);
    permission.complete();
    await Future.wait([start, stop]);
    expect(events, ['stop', 'flush']);
    expect(mic.phase, MicrophonePhase.off);
    mic.dispose();
  });

  test('denied permission never opens capture and allows retry', () async {
    var denied = true;
    final mic = session(
      permission: () async {
        if (denied) throw StateError('synthetic denied permission');
      },
    );
    await expectLater(mic.start(), throwsStateError);
    expect(events, ['stop', 'flush']);
    expect(mic.phase, MicrophonePhase.error);
    expect(mic.ownsInput, isFalse);
    denied = false;
    await mic.start();
    expect(mic.recording, isTrue);
    await mic.stop();
    mic.dispose();
  });

  test(
    'failed cleanup holds ownership until a successful stop retry',
    () async {
      var fails = true;
      final mic = session(
        stop: () async {
          events.add('stop');
          if (fails) throw StateError('synthetic stop failure');
        },
      );
      await mic.start();
      await expectLater(mic.stop(), throwsStateError);
      expect(events.last, 'flush');
      expect(mic.ownsInput, isTrue);
      await expectLater(mic.start(), throwsStateError);
      fails = false;
      await mic.stop();
      expect(mic.ownsInput, isFalse);
      mic.dispose();
    },
  );

  test(
    'input remains owned while the final durable flush is pending',
    () async {
      final flush = Completer<void>();
      final mic = PhoneMicrophoneSession(
        canStart: () => true,
        requestPermission: () async {},
        prepareCapture: () async {},
        startRecorder: () async {},
        stopRecorder: () async {},
        finishCapture: () => flush.future,
      );
      await mic.start();
      final first = mic.stop();
      final second = mic.stop();
      expect(mic.phase, MicrophonePhase.stopping);
      expect(mic.ownsInput, isTrue);
      flush.complete();
      await Future.wait([first, second]);
      expect(mic.ownsInput, isFalse);
      mic.dispose();
    },
  );
}
