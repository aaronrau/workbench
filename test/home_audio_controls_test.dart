import 'dart:async';

import 'package:even_g2_r1_poc/src/audio/phone_microphone_session.dart';
import 'package:even_g2_r1_poc/src/ui/home_history_panel.dart';
import 'package:even_g2_r1_poc/src/ui/home_page.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:even_g2_r1_poc/src/wearable_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'history refresh cannot block microphone restart or claim Bluetooth is connecting',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      ReactiveBlePlatform.instance = _FakeReactiveBlePlatform();
      final controller = _AudioControlsController();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWorkBenchTheme(),
          home: HomePage(controller: controller),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('Start microphone'));
      await tester.pump();
      expect(controller.microphoneActive, isTrue);

      tester
          .widget<HomeHistoryPanel>(find.byType(HomeHistoryPanel))
          .onRefreshMessages!();
      await tester.pump();
      expect(controller.refresh.isCompleted, isFalse);
      await tester.tap(find.byTooltip('Stop microphone'));
      await tester.pump();
      expect(controller.microphoneActive, isFalse);
      expect(find.text('Connecting…'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: find.byType(MicrophoneToggle),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byTooltip('Start microphone'));
      await tester.pump();
      expect(controller.microphoneActive, isTrue);
      await tester.tap(find.byTooltip('Stop microphone'));
      await tester.pump();

      // Bluetooth still owns its own controls while the history refresh waits.
      await tester.tap(find.text('Connect devices'));
      await tester.pump();
      expect(controller.scanStarted, isTrue);
      expect(find.text('Connecting…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: find.byType(MicrophoneToggle),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      controller.scan.completeError(StateError('Synthetic scan failure'));
      await tester.pump();
      expect(find.text('Connect devices'), findsOneWidget);
      expect(controller.refresh.isCompleted, isFalse);
      await tester.tap(find.byTooltip('Start microphone'));
      await tester.pump();
      expect(controller.microphoneActive, isTrue);
      await tester.tap(find.byTooltip('Stop microphone'));
      await tester.pump();
      controller.refresh.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

final class _AudioControlsController extends WearableController {
  final refresh = Completer<void>();
  final scan = Completer<void>();
  bool scanStarted = false;
  bool _recording = false;

  @override
  bool get supportsMicrophone => true;
  @override
  bool get microphoneActive => _recording;
  @override
  bool get microphoneOwnsInput => _recording;
  @override
  bool get canStartMicrophone => !_recording;
  @override
  bool get canConnect => !_recording;
  @override
  MicrophonePhase get microphonePhase =>
      _recording ? MicrophonePhase.recording : MicrophonePhase.off;
  @override
  Future<void> toggleMicrophone() async {
    _recording = !_recording;
    notifyListeners();
  }

  @override
  Future<void> refreshSharedMessages({bool reconcileShared = false}) =>
      reconcileShared ? refresh.future : Future<void>.value();

  @override
  Future<void> startScan({
    Duration duration = const Duration(seconds: 12),
  }) async {
    scanStarted = true;
    await scan.future;
  }
}

final class _FakeReactiveBlePlatform extends ReactiveBlePlatform {
  @override
  Stream<BleStatus> get bleStatusStream => Stream.value(BleStatus.ready);
  @override
  Future<void> initialize() async {}
  @override
  Future<void> deinitialize() async {}
}
