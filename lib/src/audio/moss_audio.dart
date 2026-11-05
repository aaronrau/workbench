import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum AudioSystem { modular, moss }

enum MossExecutionProvider { cpu, opencl }

const mossModelSha256 =
    '6fe985fd9a9cd043728f7be49659d10de6901872dad73b49e3c30e1340582e79';
const mossModelBytes = 648174592;
const mossGgmlRevision = 'eced84c86f8b012c752c016f7fe789adea168e1e';
const mossRuntimeRevision = '190a569c13b4b247450f2fb3b2a431244e84833e';
const mossPreferredSegmentDuration = Duration(seconds: 8);
const mossMaximumSegmentDuration = Duration(seconds: 12);
const mossEndpointDelay = Duration(milliseconds: 300);

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
      });
  Future<Map<String, dynamic>> transcribe(String wavPath) async =>
      (await _channel.invokeMapMethod<String, dynamic>('transcribe', {
        'wavPath': wavPath,
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
  var end = 0;
  var lastStart = 0.0;
  for (final match in pattern.allMatches(value)) {
    if (value.substring(end, match.start).trim().isNotEmpty) {
      throw const FormatException('Invalid MOSS transcript framing.');
    }
    final start = double.parse(match[1]!);
    final finish = double.parse(match[4]!);
    if (finish < start || start < lastStart || finish > audioSeconds + 1) {
      throw const FormatException('Invalid MOSS timestamps.');
    }
    final text = match[3]!.trim();
    if (text.isNotEmpty) {
      result.add(MossUtterance(start, finish, match[2]!, text));
    }
    lastStart = start;
    end = match.end;
  }
  if (value.substring(end).trim().isNotEmpty || result.isEmpty) {
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
