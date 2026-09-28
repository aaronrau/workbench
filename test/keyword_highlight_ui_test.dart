import 'package:even_g2_r1_poc/src/audio/keyword_highlights.dart';
import 'package:even_g2_r1_poc/src/ble/ble_models.dart';
import 'package:even_g2_r1_poc/src/ui/home_history_panel.dart';
import 'package:even_g2_r1_poc/src/ui/keyword_highlight_settings.dart';
import 'package:even_g2_r1_poc/src/ui/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pinned keyword row remains above scrolling events on a phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 1, 1);
    final events = List<PooledLog>.generate(
      30,
      (index) => PooledLog(
        timestamp: now,
        source: 'Test',
        message: 'Synthetic event $index',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: HomeHistoryPanel(
              events: events,
              keywordHighlights: [
                KeywordHighlight(
                  phrase: 'yeah',
                  count: 2,
                  expiresAt: now.add(const Duration(minutes: 2)),
                ),
              ],
              conversations: const [],
              analysisEnabled: false,
              needsEnrollment: false,
              analysisState: 'disabled',
              knownSpeakerCount: 0,
              pendingConversationCount: 0,
              isLoadingConversations: false,
              isStorageBusy: false,
            ),
          ),
        ),
      ),
    );

    final pinned = find.byKey(const ValueKey('pinned-keyword-highlights'));
    expect(pinned, findsOneWidget);
    expect(find.text('yeah(2)'), findsOneWidget);
    final initialTop = tester.getTopLeft(pinned);
    await tester.drag(
      find.byKey(const ValueKey('events-list')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(pinned), initialTop);
    final container = tester.widget<Container>(pinned);
    expect(container.color, keywordHighlightBackgroundColor);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings save edits phrases and rejects duplicates', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<String>? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWorkBenchTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: KeywordHighlightSettings(
              phrases: const ['yeah', 'hmm'],
              onSave: (phrases) async => saved = phrases,
            ),
          ),
        ),
      ),
    );

    final field = find.byKey(const ValueKey('keyword-phrases-field'));
    await tester.enterText(field, 'yeah\nYeah');
    await tester.ensureVisible(
      find.byKey(const ValueKey('save-keywords-button')),
    );
    await tester.tap(find.byKey(const ValueKey('save-keywords-button')));
    await tester.pump();
    expect(find.text('Remove duplicate keywords.'), findsOneWidget);
    expect(saved, isNull);

    await tester.enterText(field, 'yeah\ni think');
    await tester.tap(find.byKey(const ValueKey('save-keywords-button')));
    await tester.pump();
    expect(saved, ['yeah', 'i think']);
    expect(tester.takeException(), isNull);
  });
}
