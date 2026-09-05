import 'dart:async';

import 'package:even_g2_r1_poc/src/audio/android_microphone_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/workbench_microphone');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'stop drains in-flight PCM and native tail before releasing recorder',
    () async {
      final readStarted = Completer<void>();
      final firstRead = Completer<Uint8List>();
      final stopped = Completer<void>();
      var reads = 0;
      var failures = 0;
      final received = <List<int>>[];
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'start':
            return null;
          case 'read':
            reads++;
            if (reads == 1) {
              readStarted.complete();
              return firstRead.future;
            }
            if (reads == 2) return Uint8List.fromList([2, 0]);
            return null;
          case 'stop':
            stopped.complete();
            return null;
          case 'release':
            return null;
        }
        throw StateError('Unexpected command');
      });
      final source = AndroidMicrophoneSource(channel: channel);
      await source.start(
        onPcm: received.add,
        onFailure: () {
          failures++;
        },
      );
      await readStarted.future;
      final stop = source.stop();
      await stopped.future;
      firstRead.complete(Uint8List.fromList([1, 0]));
      await stop;
      expect(received, [
        [1, 0],
        [2, 0],
      ]);
      expect(calls.last, 'release');
      expect(failures, 0);
    },
  );

  test(
    'malformed native PCM fails capture without feeding processing',
    () async {
      final failed = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'read') return Uint8List(3);
        return null;
      });
      final source = AndroidMicrophoneSource(channel: channel);
      await source.start(
        onPcm: (_) => fail('Invalid PCM must not reach processing'),
        onFailure: failed.complete,
      );
      await failed.future;
      await source.stop();
    },
  );

  test('read failure during stop is reported after native release', () async {
    final readStarted = Completer<void>();
    final pendingRead = Completer<Uint8List>();
    final pendingStop = Completer<void>();
    var released = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'read':
          readStarted.complete();
          return pendingRead.future;
        case 'stop':
          await pendingStop.future;
          return null;
        case 'release':
          released = true;
          return null;
      }
      return null;
    });
    final source = AndroidMicrophoneSource(channel: channel);
    await source.start(onPcm: (_) {}, onFailure: () {});
    await readStarted.future;
    final stopped = source.stop();
    final expectation = expectLater(stopped, throwsA(isA<PlatformException>()));
    pendingRead.completeError(
      PlatformException(code: 'synthetic_read_failure'),
    );
    await Future<void>.delayed(Duration.zero);
    pendingStop.complete();
    await expectation;
    expect(released, isTrue);
  });

  test('failed native startup releases its service', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') throw PlatformException(code: 'permission');
      return null;
    });
    final source = AndroidMicrophoneSource(channel: channel);
    await expectLater(
      source.start(onPcm: (_) {}, onFailure: () {}),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, ['start', 'stop', 'release']);
  });
}
