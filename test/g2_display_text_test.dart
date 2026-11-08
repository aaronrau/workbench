import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:even_g2_r1_poc/src/protocol/g2_display_text.dart';

void main() {
  test(
    'firmware text contains only ASCII letters digits and layout whitespace',
    () {
      const original = 'Hello “world”… 中文 😀\u202e\u0000\nNext 123';
      final safe = sanitizeG2DisplayText(original);
      expect(RegExp(r'^[A-Za-z0-9 \n]+$').hasMatch(safe), isTrue);
      expect(safe, contains('world'));
      expect(safe, endsWith('\nNext 123'));
      expect(ascii.encode(safe), isNotEmpty);
      expect(original, contains('中文'));
    },
  );
  test('display byte limit and blank clearing survive filtering', () {
    final safe = sanitizeG2DisplayText('${'a' * 1998}…😀');
    expect(utf8.encode(safe).length, lessThanOrEqualTo(2000));
    expect(sanitizeG2DisplayText('a' * 10000).length, 2000);
    expect(sanitizeG2DisplayText('\n'), '\n');
    expect(sanitizeG2DisplayText('中文😀[]!?\u0000'), '\n');
    expect(sanitizeG2DisplayText(''), '\n');
    expect(sanitizeG2DisplayText('Part-1/Next_2'), 'Part 1 Next 2');
    expect(sanitizeG2DisplayText('A  B\nC\tD\rE'), 'A  B\nC D E');
    expect(sanitizeG2DisplayText(safe), safe);
  });
}
