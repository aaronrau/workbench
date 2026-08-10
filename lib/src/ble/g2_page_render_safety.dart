import 'dart:convert';

/// Maximum UTF-8 payload accepted by the G2 text-container upgrade path.
const int g2MaximumTextPageUtf8Bytes = 2000;

enum G2PageRenderAction { skip, updateInPlace, replacePage, deferReplacement }

/// A validated, normalized description of one full-page G2 text render.
final class G2PageRenderFrame {
  factory G2PageRenderFrame.validate({
    required String content,
    required bool showPageIndicator,
    required int pageIndex,
    required int pageCount,
    required int borderWidth,
    required int borderColor,
    required int paddingLength,
    int? maximumTextRows,
  }) {
    if (RegExp(
      r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]',
    ).hasMatch(content)) {
      throw const FormatException(
        'G2 full-page text contains an unsupported control character.',
      );
    }
    final utf8Bytes = utf8.encode(content).length;
    if (utf8Bytes > g2MaximumTextPageUtf8Bytes) {
      throw FormatException(
        'G2 full-page text exceeds the $g2MaximumTextPageUtf8Bytes-byte '
        'firmware limit.',
      );
    }
    if (maximumTextRows != null) {
      if (maximumTextRows < 1) {
        throw ArgumentError.value(
          maximumTextRows,
          'maximumTextRows',
          'must be at least one',
        );
      }
      final textRows = '\n'.allMatches(content).length + 1;
      if (textRows > maximumTextRows) {
        throw FormatException(
          'G2 full-page text has $textRows rows; the active surface allows '
          'at most $maximumTextRows.',
        );
      }
    }
    final normalizedPageCount = pageCount < 1 ? 1 : pageCount;
    return G2PageRenderFrame._(
      content: content,
      utf8Bytes: utf8Bytes,
      showPageIndicator: showPageIndicator && normalizedPageCount > 1,
      pageIndex: pageIndex.clamp(0, normalizedPageCount - 1),
      pageCount: normalizedPageCount,
      borderWidth: borderWidth.clamp(0, 32),
      borderColor: borderColor.clamp(0, 15),
      paddingLength: paddingLength.clamp(0, 32),
    );
  }

  const G2PageRenderFrame._({
    required this.content,
    required this.utf8Bytes,
    required this.showPageIndicator,
    required this.pageIndex,
    required this.pageCount,
    required this.borderWidth,
    required this.borderColor,
    required this.paddingLength,
  });

  final String content;
  final int utf8Bytes;
  final bool showPageIndicator;
  final int pageIndex;
  final int pageCount;
  final int borderWidth;
  final int borderColor;
  final int paddingLength;

  bool hasSamePageStructure(G2PageRenderFrame other) =>
      showPageIndicator == other.showPageIndicator &&
      borderWidth == other.borderWidth &&
      borderColor == other.borderColor &&
      paddingLength == other.paddingLength;

  @override
  bool operator ==(Object other) =>
      other is G2PageRenderFrame &&
      content == other.content &&
      showPageIndicator == other.showPageIndicator &&
      pageIndex == other.pageIndex &&
      pageCount == other.pageCount &&
      borderWidth == other.borderWidth &&
      borderColor == other.borderColor &&
      paddingLength == other.paddingLength;

  @override
  int get hashCode => Object.hash(
    content,
    showPageIndicator,
    pageIndex,
    pageCount,
    borderWidth,
    borderColor,
    paddingLength,
  );
}

/// Chooses the only safe transport operation for a validated page frame.
final class G2PageRenderSafety {
  const G2PageRenderSafety._();

  static G2PageRenderAction decide({
    required G2PageRenderFrame? current,
    required G2PageRenderFrame next,
    required bool pageCreated,
    required bool allowPageReplacement,
  }) {
    if (current != null && pageCreated && current == next) {
      return G2PageRenderAction.skip;
    }
    if (current != null && pageCreated && current.hasSamePageStructure(next)) {
      return G2PageRenderAction.updateInPlace;
    }
    if (!allowPageReplacement) {
      return G2PageRenderAction.deferReplacement;
    }
    return G2PageRenderAction.replacePage;
  }
}
