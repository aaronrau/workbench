import 'package:even_g2_r1_poc/src/audio/moss_audio.dart';
import 'package:even_g2_r1_poc/src/ui/audio_system_settings.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'phone layout permits choosing MOSS and explains its window scope',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      AudioSystem? selected;
      MossQuantization? weights;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWorkBenchTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: AudioSystemSettings(
                system: AudioSystem.moss,
                enabled: true,
                onChanged: (value) => selected = value,
                onQuantizationChanged: (value) => weights = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<MossQuantization>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Q4_0 · 535 MB').last);
      await tester.pumpAndSettle();
      expect(weights, MossQuantization.q4Zero);
      expect(find.textContaining('labels restart'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(DropdownButtonFormField<AudioSystem>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current system').last);
      await tester.pumpAndSettle();
      expect(selected, AudioSystem.modular);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('GPU selection is explicit and disabled during input', (
    tester,
  ) async {
    MossExecutionProvider? selected;
    Future<void> show(bool enabled) => tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: AudioSystemSettings(
            system: AudioSystem.moss,
            enabled: enabled,
            onChanged: (_) {},
            onProviderChanged: (value) => selected = value,
          ),
        ),
      ),
    );
    await show(true);
    await tester.tap(
      find.byType(DropdownButtonFormField<MossExecutionProvider>),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPU · OpenCL').last);
    await tester.pumpAndSettle();
    expect(selected, MossExecutionProvider.opencl);
    await show(false);
    expect(
      tester
          .widget<DropdownButtonFormField<MossQuantization>>(
            find.byType(DropdownButtonFormField<MossQuantization>),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<MossExecutionProvider>>(
            find.byType(DropdownButtonFormField<MossExecutionProvider>),
          )
          .onChanged,
      isNull,
    );
  });
}
