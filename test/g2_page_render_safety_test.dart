import 'package:even_g2_r1_poc/src/ble/g2_page_render_safety.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  G2PageRenderFrame frame(
    String content, {
    bool indicator = false,
    int pageIndex = 0,
    int pageCount = 1,
  }) => G2PageRenderFrame.validate(
    content: content,
    showPageIndicator: indicator,
    pageIndex: pageIndex,
    pageCount: pageCount,
    borderWidth: 0,
    borderColor: 5,
    paddingLength: 4,
  );

  test('suppresses an identical frame before issuing another render', () {
    final current = frame('[Pike] 4min synthetic update');

    expect(
      G2PageRenderSafety.decide(
        current: current,
        next: frame('[Pike] 4min synthetic update'),
        pageCreated: true,
        allowPageReplacement: false,
      ),
      G2PageRenderAction.skip,
    );
  });

  test('allows a changed prompt only as an in-place update', () {
    expect(
      G2PageRenderSafety.decide(
        current: frame(' >  [x] - Swipe to Select'),
        next: frame('     [x] - Swipe to Select\n >  [Pike] 4min update'),
        pageCreated: true,
        allowPageReplacement: false,
      ),
      G2PageRenderAction.updateInPlace,
    );
  });

  test('defers a swipe render when the page is not safely upgradable', () {
    expect(
      G2PageRenderSafety.decide(
        current: frame('old prompt'),
        next: frame('new prompt'),
        pageCreated: false,
        allowPageReplacement: false,
      ),
      G2PageRenderAction.deferReplacement,
    );
    expect(
      G2PageRenderSafety.decide(
        current: frame('selector'),
        next: frame('detail', indicator: true, pageCount: 2),
        pageCreated: true,
        allowPageReplacement: false,
      ),
      G2PageRenderAction.deferReplacement,
    );
  });

  test('allows a settled non-gesture transition to replace the page', () {
    expect(
      G2PageRenderSafety.decide(
        current: frame('selector'),
        next: frame('detail', indicator: true, pageCount: 2),
        pageCreated: true,
        allowPageReplacement: true,
      ),
      G2PageRenderAction.replacePage,
    );
  });

  test('normalizes page metadata before the safety decision', () {
    final normalized = G2PageRenderFrame.validate(
      content: 'synthetic',
      showPageIndicator: true,
      pageIndex: 9,
      pageCount: 0,
      borderWidth: 99,
      borderColor: -1,
      paddingLength: 99,
    );

    expect(normalized.showPageIndicator, isFalse);
    expect(normalized.pageIndex, 0);
    expect(normalized.pageCount, 1);
    expect(normalized.borderWidth, 32);
    expect(normalized.borderColor, 0);
    expect(normalized.paddingLength, 32);
  });

  test('rejects unsafe text before any render decision', () {
    expect(() => frame('unsafe\u0000text'), throwsA(isA<FormatException>()));
    expect(
      () => frame(List<String>.filled(1001, 'é').join()),
      throwsA(isA<FormatException>()),
    );
  });
}
