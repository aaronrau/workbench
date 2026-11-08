import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum AudioSystem { modular, moss }

enum MossExecutionProvider { cpu, opencl }

const mossTranscriptionLanguage = 'en';
const mossLanguagePolicy = 'english-latin-v2';
const mossNativeAdapter = 'strict-provider-f16-1';

const mossModelSha256 =
    '6fe985fd9a9cd043728f7be49659d10de6901872dad73b49e3c30e1340582e79';
const mossModelBytes = 648174592;
const mossGgmlRevision = 'eced84c86f8b012c752c016f7fe789adea168e1e';
const mossRuntimeRevision = '190a569c13b4b247450f2fb3b2a431244e84833e';
const mossPreferredSegmentDuration = Duration(seconds: 20);
// Leave room for pre-roll and the endpoint tail under the native 90 s limit.
const mossMaximumSegmentDuration = Duration(seconds: 80);
// Require more than three seconds of VAD-inactive PCM before ending a turn.
// Silero's separate 500 ms silence qualification precedes this retained tail.
const mossEndpointDelay = Duration(milliseconds: 3010);

enum MossQuantization {
  q5K('q5_k', 'Q5_K', mossModelBytes, mossModelSha256, 'moss-0.9b'),
  q4Zero(
    'q4_0',
    'Q4_0',
    535272448,
    '571dc83e4dd4567bcf2070151d209454be4f6396d98b590ab92dfb49cddde178',
    'moss-0.9b-q4_0',
  );

  const MossQuantization(
    this.id,
    this.label,
    this.bytes,
    this.sha256,
    this.directory,
  );
  final String id;
  final String label;
  final int bytes;
  final String sha256;
  final String directory;
  String get modelId => 'moss-0.9b-$id';
  String get choiceLabel => '$label · ${(bytes / 1000000).round()} MB';
}

MossQuantization mossQuantizationForId(String? id) =>
    MossQuantization.values.firstWhere(
      (quantization) => quantization.id == id,
      orElse: () => MossQuantization.q5K,
    );

final _verifiedModelStamps = <String, String>{};

Future<String> prepareMossModel({
  MossQuantization quantization = MossQuantization.q5K,
}) async {
  final root = await getApplicationSupportDirectory();
  final model = File(
    '${root.path}/workbench/models/${quantization.directory}/model.gguf',
  );
  if (!await model.exists() || await model.length() != quantization.bytes) {
    throw StateError(
      'Install MOSS ${quantization.label} with tool/stage_android_moss_model.py --quantization ${quantization.id} first.',
    );
  }
  final stat = await model.stat();
  final stamp =
      '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
  if (_verifiedModelStamps[model.path] == stamp) return model.path;
  if ((await sha256.bind(model.openRead()).first).toString() !=
      quantization.sha256) {
    throw StateError('MOSS model integrity check failed. Reinstall the model.');
  }
  _verifiedModelStamps[model.path] = stamp;
  return model.path;
}

class MossClient {
  const MossClient({
    this.provider = MossExecutionProvider.opencl,
    this.quantization = MossQuantization.q5K,
  });
  final MossExecutionProvider provider;
  final MossQuantization quantization;
  static const _channel = MethodChannel('dev.opensourceglasses/workbench_moss');
  Future<void> prepare(String modelPath) =>
      _channel.invokeMethod<void>('prepare', {
        'modelPath': modelPath,
        'provider': provider.name,
        'modelId': quantization.modelId,
        'language': mossTranscriptionLanguage,
      });
  Future<Map<String, dynamic>> transcribe(String wavPath) async =>
      (await _channel.invokeMapMethod<String, dynamic>('transcribe', {
        'wavPath': wavPath,
        'language': mossTranscriptionLanguage,
      }))!;
  Future<void> close() => _channel.invokeMethod<void>('close');
}

final class MossUtterance {
  const MossUtterance(this.start, this.end, this.speaker, this.text);
  final double start;
  final double end;
  final String speaker;
  final String text;
  Map<String, Object> toJson() => {
    'start_seconds': start,
    'end_seconds': end,
    'speaker': speaker,
    'text': text,
  };
}

/// Only conversation records retain MOSS timestamps, speaker IDs, and events.
/// An unfinished bracket suppresses the remaining annotation, too.
String stripMossAnnotations(String value) {
  final text = StringBuffer();
  var depth = 0;
  for (final rune in value.runes) {
    if (rune == 0x5b) {
      if (depth == 0) text.write(' ');
      depth++;
    } else if (rune == 0x5d) {
      if (depth > 0) {
        depth--;
      } else {
        text.write(' ');
      }
    } else if (depth == 0) {
      text.writeCharCode(rune);
    }
  }
  return text
      .toString()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(RegExp(r'\s+([,.;:!?])'), (match) => match[1]!)
      .trim();
}

/// Defense at the app boundary, even if a worker reports the expected policy.
/// This checks script and framing characters, not semantic language identity.
void validateMossEnglishOutput(String text) {
  if (text.trim().isEmpty || text.length > 65536) {
    throw const FormatException('Empty or oversized MOSS output.');
  }
  var brackets = 0;
  for (final rune in text.runes) {
    final allowed =
        rune == 9 ||
        rune == 10 ||
        rune == 13 ||
        (rune >= 0x20 && rune <= 0x7e) ||
        const [
          0xa0,
          0xa3,
          0xa9,
          0xae,
          0xb0,
          0xb7,
          0x2026,
          0x202f,
          0x20ac,
          0x2122,
        ].contains(rune) ||
        (rune >= 0xc0 && rune <= 0xd6) ||
        (rune >= 0xd8 && rune <= 0xf6) ||
        (rune >= 0xf8 && rune <= 0x24f) ||
        (rune >= 0x300 && rune <= 0x36f) ||
        (rune >= 0x1e00 && rune <= 0x1eff) ||
        (rune >= 0x2010 && rune <= 0x2015) ||
        (rune >= 0x2018 && rune <= 0x201f) ||
        (rune >= 0x2032 && rune <= 0x2033);
    if (!allowed) {
      throw const FormatException('Unsupported MOSS script or control.');
    }
    if (rune == 0x5b) brackets++;
    if (rune == 0x5d && --brackets < 0) {
      throw const FormatException('Unbalanced MOSS annotations.');
    }
  }
  if (brackets != 0) throw const FormatException('Truncated MOSS annotations.');
}

/// Reject malformed/truncated generation instead of routing an unfinished command.
List<MossUtterance> parseMossTranscript(
  String value, {
  required double audioSeconds,
}) {
  if (value.trim().isEmpty) return [];
  final pattern = RegExp(
    r'\[(\d+(?:\.\d+)?)\]\[(S\d{2,})\]([\s\S]*?)\[(\d+(?:\.\d+)?)\]',
  );
  final result = <MossUtterance>[];
  var framedTurns = 0;
  var end = 0;
  var lastStart = 0.0;
  for (final match in pattern.allMatches(value)) {
    framedTurns++;
    if (value.substring(end, match.start).trim().isNotEmpty) {
      throw const FormatException('Invalid MOSS transcript framing.');
    }
    final start = double.parse(match[1]!);
    final finish = double.parse(match[4]!);
    if (!start.isFinite ||
        !finish.isFinite ||
        !audioSeconds.isFinite ||
        finish < start ||
        start < lastStart ||
        finish > audioSeconds + 1) {
      throw const FormatException('Invalid MOSS timestamps.');
    }
    final text = match[3]!.trim();
    if (text.isNotEmpty) {
      result.add(MossUtterance(start, finish, match[2]!, text));
    }
    lastStart = start;
    end = match.end;
  }
  if (value.substring(end).trim().isNotEmpty || framedTurns == 0) {
    throw const FormatException('Incomplete MOSS transcript.');
  }
  return result;
}

Uint8List mossWav(Uint8List pcm) {
  if (pcm.length.isOdd) {
    throw ArgumentError('PCM must contain complete samples.');
  }
  final bytes = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}

/// Only this explicit public test fixture may enter structured transcript logs.
/// Do not allow prefixes: a real utterance can append private words to a fixture.
bool isMossKokoroFixture(String text) {
  if (RegExp(r'[^\x00-\x7F]').hasMatch(text) ||
      RegExp(r'\d').hasMatch(text.replaceAll(RegExp(r'\b7\b'), 'seven'))) {
    return false;
  }
  final normalized = text
      .toLowerCase()
      .replaceAll('workbench', 'work bench')
      .replaceAll(RegExp(r'\b7\b'), 'seven')
      .replaceAll(RegExp(r'[^a-z\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return normalized ==
      'work bench audio safety check number seven the glasses should transcribe every word';
}
