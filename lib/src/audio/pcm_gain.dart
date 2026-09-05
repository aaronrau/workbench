import 'dart:typed_data';

const int g2PcmGain = 16;
const int microphonePcmGain = 8;

Uint8List applyG2PcmGain(Uint8List pcm16, {int gain = g2PcmGain}) =>
    _applyPcmGain(pcm16, gain: gain);

/// Boost quiet phone input by about 18 dB using the shared PCM16 saturation.
Uint8List applyMicrophonePcmGain(Uint8List pcm16) =>
    _applyPcmGain(pcm16, gain: microphonePcmGain);

Uint8List _applyPcmGain(Uint8List pcm16, {required int gain}) {
  if (gain < 1) {
    throw RangeError.range(gain, 1, null, 'gain');
  }
  if (pcm16.length.isOdd) {
    throw const FormatException('PCM16 input must contain complete samples.');
  }
  final input = ByteData.sublistView(pcm16);
  final output = Uint8List(pcm16.length);
  final outputData = ByteData.sublistView(output);
  for (var offset = 0; offset < pcm16.length; offset += 2) {
    final sample = input.getInt16(offset, Endian.little);
    final amplified = (sample * gain).clamp(-32768, 32767);
    outputData.setInt16(offset, amplified, Endian.little);
  }
  return output;
}
