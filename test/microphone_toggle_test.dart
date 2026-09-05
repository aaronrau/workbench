import 'package:even_g2_r1_poc/src/ui/home_page.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('microphone is an accessible 48dp toggle with disabled state', (
    tester,
  ) async {
    var presses = 0;
    Future<void> show({required bool active, required bool enabled}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: buildWorkBenchTheme(),
            home: Scaffold(
              body: MicrophoneToggle(
                active: active,
                enabled: enabled,
                onPressed: () {
                  presses++;
                },
              ),
            ),
          ),
        );
    await show(active: false, enabled: true);
    expect(
      tester.getSize(find.byType(IconButton)).width,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byType(IconButton)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.byTooltip('Start microphone'));
    expect(presses, 1);
    await show(active: true, enabled: true);
    await tester.tap(find.byTooltip('Stop microphone'));
    expect(presses, 2);
    await show(active: false, enabled: false);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
  });
}
