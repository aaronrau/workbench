import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/audio/pcm_gain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'phone gain boosts quiet input and saturates without changing source',
    () {
      final input = _pcm(<int>[-5000, -100, 0, 100, 5000]);

      expect(_samples(applyMicrophonePcmGain(input)), <int>[
        -32768,
        -800,
        0,
        800,
        32767,
      ]);
      expect(_samples(input), <int>[-5000, -100, 0, 100, 5000]);
    },
  );

  test('amplifies little-endian PCM16 samples', () {
    final input = _pcm(<int>[-100, 0, 100]);

    expect(_samples(applyG2PcmGain(input, gain: 16)), <int>[-1600, 0, 1600]);
  });

  test('clips amplified samples to the PCM16 range', () {
    final input = _pcm(<int>[-3000, 3000]);

    expect(_samples(applyG2PcmGain(input, gain: 16)), <int>[-32768, 32767]);
  });

  test('rejects incomplete PCM16 input', () {
    expect(
      () => applyG2PcmGain(Uint8List.fromList(<int>[1])),
      throwsFormatException,
    );
  });
}

Uint8List _pcm(List<int> samples) {
  final output = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(output);
  for (var index = 0; index < samples.length; index++) {
    data.setInt16(index * 2, samples[index], Endian.little);
  }
  return output;
}

List<int> _samples(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  return <int>[
    for (var offset = 0; offset < pcm.length; offset += 2)
      data.getInt16(offset, Endian.little),
  ];
}
