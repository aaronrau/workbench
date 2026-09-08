import 'package:even_g2_r1_poc/src/ui/conversation_enrollment_prompt.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows rejection inline and allows reset while checking', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ConversationEnrollmentPrompt(
              acceptedSamples: 1,
              requiredSamples: 3,
              preparing: false,
              checking: true,
              resetting: false,
              error:
                  'This enrollment sample does not match the earlier voice samples.',
              onReset: () => resets++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Checking voice sample 2 of 3…'), findsOneWidget);
    expect(find.textContaining('does not match'), findsOneWidget);
    final reset = find.byKey(const ValueKey<String>('reset-voice-samples'));
    expect(tester.getSize(reset).height, greaterThanOrEqualTo(48));
    await tester.tap(reset);
    expect(resets, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocks duplicate taps only during reset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: ConversationEnrollmentPrompt(
            acceptedSamples: 0,
            requiredSamples: 3,
            preparing: true,
            checking: false,
            resetting: true,
            onReset: () => fail('Reset must not run twice'),
          ),
        ),
      ),
    );
    expect(find.text('Resetting voice samples…'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
  });
}
