import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android bridge forwards every successful MOSS service reply field', () {
    const root =
        'android/app/src/main/kotlin/dev/opensourceglasses/even_g2_r1_poc';
    final service = File('$root/MossService.kt').readAsStringSync();
    final bridge = File('$root/MossBridge.kt').readAsStringSync();
    final fields = RegExp(r'response\.put\w+\("(\w+)"')
        .allMatches(service)
        .map((match) => match[1]!)
        .where((field) => field != 'failed')
        .toSet();
    expect(fields, containsAll(['text', 'profile', 'nativeAdapter']));
    for (final field in fields) {
      expect(
        RegExp(
          '"$field" to message\\.data\\.get\\w+\\("$field"\\)',
        ).hasMatch(bridge),
        isTrue,
        reason: 'Service reply field $field must survive the Flutter bridge.',
      );
    }
  });
}
