/// Conservative firmware text boundary; phone records retain the original text.
const g2DisplayMaximumBytes = 2000;

String sanitizeG2DisplayText(String value) {
  final result = StringBuffer();
  for (final rune in value.runes) {
    final String piece;
    if (rune == 10 ||
        rune == 32 ||
        (rune >= 48 && rune <= 57) ||
        (rune >= 65 && rune <= 90) ||
        (rune >= 97 && rune <= 122)) {
      piece = String.fromCharCode(rune);
    } else if (rune == 9 || rune == 13) {
      piece = ' ';
    } else if (rune < 32 ||
        rune == 127 ||
        (rune >= 0x200b && rune <= 0x200f) ||
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069)) {
      continue;
    } else {
      // Keep word boundaries without sending punctuation or replacement glyphs.
      piece = ' ';
    }
    // Output is ASCII: byte count equals length and no UTF-8 character splits.
    if (result.length + piece.length > g2DisplayMaximumBytes) break;
    result.write(piece);
  }
  final safe = result.toString();
  // A zero-length update is a firmware no-op. Clear stale text when filtering
  // removes every visible character, while retaining intentional line layout.
  return safe.trim().isEmpty ? '\n' : safe;
}
