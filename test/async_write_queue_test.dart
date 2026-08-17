import 'dart:async';

import 'package:even_g2_r1_poc/src/protocol/g2_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AsyncWriteQueue', () {
    test('runs queued control writes before visual writes', () async {
      final queue = AsyncWriteQueue();
      final gate = Completer<void>();
      final order = <String>[];

      final active = queue.add(() async {
        order.add('active');
        await gate.future;
      });
      await Future<void>.delayed(Duration.zero);

      final low = queue.add(
        () async => order.add('low'),
        priority: AsyncWritePriority.low,
      );
      final normal = queue.add(() async => order.add('normal'));
      final high = queue.add(
        () async => order.add('high'),
        priority: AsyncWritePriority.high,
      );

      gate.complete();
      await Future.wait(<Future<void>>[active, low, normal, high]);

      expect(order, <String>['active', 'high', 'normal', 'low']);
    });

    test('continues after a failed write', () async {
      final queue = AsyncWriteQueue();
      var nextWriteRan = false;

      await expectLater(
        queue.add(() async => throw StateError('write failed')),
        throwsStateError,
      );
      await queue.add(() async => nextWriteRan = true);

      expect(nextWriteRan, isTrue);
    });

    test('continues after a stalled BLE write times out', () async {
      final queue = AsyncWriteQueue(
        operationTimeout: const Duration(milliseconds: 10),
      );
      final stalled = Completer<void>();
      var nextWriteRan = false;

      await expectLater(
        queue.add(() => stalled.future),
        throwsA(isA<TimeoutException>()),
      );
      await queue.add(() async => nextWriteRan = true);

      expect(nextWriteRan, isTrue);
    });

    test('preempts a visual transfer between BLE packet fragments', () async {
      final queue = AsyncWriteQueue();
      final firstFragmentStarted = Completer<void>();
      final releaseFirstFragment = Completer<void>();
      final order = <String>[];

      final visual = queue.addBatch(<Future<void> Function()>[
        () async {
          order.add('visual-1');
          firstFragmentStarted.complete();
          await releaseFirstFragment.future;
        },
        () async => order.add('visual-2'),
      ], priority: AsyncWritePriority.low);
      await firstFragmentStarted.future;

      final gesture = queue.add(
        () async => order.add('gesture'),
        priority: AsyncWritePriority.high,
      );
      releaseFirstFragment.complete();
      await Future.wait(<Future<void>>[visual, gesture]);

      expect(order, <String>['visual-1', 'gesture', 'visual-2']);
    });

    test('cancels remaining visual fragments after a surface change', () async {
      final queue = AsyncWriteQueue();
      final firstFragmentStarted = Completer<void>();
      final releaseFirstFragment = Completer<void>();
      final order = <String>[];
      var generation = 1;
      var cancellations = 0;

      final visual = queue.addBatch(
        <Future<void> Function()>[
          () async {
            order.add('visual-1');
            firstFragmentStarted.complete();
            await releaseFirstFragment.future;
          },
          () async => order.add('visual-2'),
          () async => order.add('visual-3'),
        ],
        priority: AsyncWritePriority.low,
        shouldContinue: () => generation == 1,
        onCanceled: () => cancellations++,
      );
      await firstFragmentStarted.future;

      generation = 2;
      final menu = queue.add(
        () async => order.add('menu-page'),
        priority: AsyncWritePriority.high,
      );
      releaseFirstFragment.complete();
      await Future.wait(<Future<void>>[visual, menu]);

      expect(order, <String>['visual-1', 'menu-page']);
      expect(cancellations, 1);
    });

    test('rechecks a queued fragment before it starts writing', () async {
      final queue = AsyncWriteQueue();
      final blockerStarted = Completer<void>();
      final releaseBlocker = Completer<void>();
      var current = true;
      var visualWrites = 0;
      var cancellations = 0;

      final blocker = queue.add(() async {
        blockerStarted.complete();
        await releaseBlocker.future;
      });
      await blockerStarted.future;
      final visual = queue.addBatch(
        <Future<void> Function()>[() async => visualWrites++],
        priority: AsyncWritePriority.low,
        shouldContinue: () => current,
        onCanceled: () => cancellations++,
      );

      current = false;
      releaseBlocker.complete();
      await Future.wait(<Future<void>>[blocker, visual]);

      expect(visualWrites, 0);
      expect(cancellations, 1);
    });
  });
}
