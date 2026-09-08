import 'package:even_g2_r1_poc/src/ui/conversation_analysis_settings.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows one reset action and three-sample guidance in Tools', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var resetCount = 0;
    double? savedThreshold;
    await tester.pumpWidget(
      _app(
        ConversationAnalysisSettings(
          enabled: true,
          state: 'ready',
          knownSpeakerCount: 3,
          pendingConversationCount: 0,
          enrollmentPending: false,
          acceptedEnrollmentSamples: 0,
          requiredEnrollmentSamples: 3,
          speakerMatchThreshold: 0.64,
          busy: false,
          onEnabledChanged: (_) {},
          onSpeakerMatchThresholdChanged: (value) => savedThreshold = value,
          onResetSpeakerIdentification: () => resetCount++,
        ),
      ),
    );

    final reset = find.byKey(
      const ValueKey<String>('reset-speaker-identification'),
    );
    expect(reset, findsOneWidget);
    expect(tester.getSize(reset).height, greaterThanOrEqualTo(48));
    expect(find.text('Update my voice'), findsNothing);
    expect(find.text('Listen for my voice'), findsNothing);
    expect(find.text('Reset speaker signatures'), findsNothing);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('speaker-match-threshold')),
    );
    slider.onChanged!(0.72);
    await tester.pump();
    expect(find.text('Speaker match threshold: 0.72'), findsOneWidget);
    slider.onChangeEnd!(0.72);
    expect(savedThreshold, 0.72);
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    expect(resetCount, 1);
  });

  testWidgets('allows resetting enrollment before any speaker is saved', (
    tester,
  ) async {
    var resets = 0;
    await tester.pumpWidget(
      _app(
        ConversationAnalysisSettings(
          enabled: true,
          state: 'enrolling',
          knownSpeakerCount: 0,
          pendingConversationCount: 1,
          enrollmentPending: true,
          acceptedEnrollmentSamples: 1,
          requiredEnrollmentSamples: 3,
          speakerMatchThreshold: 0.70,
          busy: true,
          onEnabledChanged: (_) {},
          onSpeakerMatchThresholdChanged: (_) {},
          onResetSpeakerIdentification: () => resets++,
        ),
      ),
    );

    expect(find.textContaining('Voice sample 2 of 3'), findsOneWidget);
    final reset = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('reset-speaker-identification')),
    );
    expect(reset.onPressed, isNotNull);
    expect(find.text('Reset voice samples'), findsOneWidget);
    await tester.ensureVisible(find.text('Reset voice samples'));
    await tester.tap(find.text('Reset voice samples'));
    expect(resets, 1);
  });
}

Widget _app(Widget child) => MaterialApp(
  theme: buildWorkBenchTheme(),
  home: Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  ),
);
