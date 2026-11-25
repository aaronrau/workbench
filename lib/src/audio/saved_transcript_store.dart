import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'shared_audio_export_store.dart';

/// Reads the durable speech files and retains corrections made from history.
final class SavedTranscriptStore {
  SavedTranscriptStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory;

  static const int _maximumTextBytes = 256 * 1024;
  final Future<Directory> Function() _supportDirectory;
  List<SharedTranscript> _local = const [];
  Iterable<SharedTranscript>? _shared;
  List<SharedTranscript>? _merged;
  final Map<String, String> _corrections = {};

  Future<void> refresh(Iterable<SharedTranscript> shared) async {
    final support = await _supportDirectory();
    final root = '${support.path}/workbench/audio';
    final candidates = <({File file, String id, DateTime updatedAt})>[];
    for (final system in ['speech', 'moss']) {
      final directory = Directory('$root/$system');
      if (!await directory.exists()) continue;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        final raw = name.endsWith('.raw.txt');
        if (!raw && !name.endsWith('.continuous.txt')) continue;
        final stat = await entry.stat();
        if (stat.size == 0 || stat.size > _maximumTextBytes) continue;
        final id = name.substring(0, name.length - (raw ? 8 : 4));
        candidates.add((file: entry, id: id, updatedAt: stat.modified));
      }
    }
    candidates.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final local = <SharedTranscript>[];
    for (final entry in candidates.take(
      SharedAudioExportStore.maximumVisibleTranscripts,
    )) {
      final original = await _readText(entry.file);
      if (original == null) continue;
      final corrected = File(
        '${entry.file.parent.path}/${entry.id}.corrected.txt',
      );
      local.add(
        SharedTranscript(
          id: entry.id,
          originalText: original,
          updatedAt: entry.updatedAt,
          correctedText: await _readText(corrected),
        ),
      );
    }
    _local = local;
    _merged = null;
    final visibleKeys = history(shared).map(_correctionKey).toSet();
    _corrections.removeWhere((key, _) => !visibleKeys.contains(key));
    for (final key in visibleKeys) {
      if (_corrections.containsKey(key)) continue;
      final corrected = await _readText(_correctionFile(root, key));
      if (corrected != null) {
        _corrections.putIfAbsent(key, () => corrected);
      }
    }
    _merged = null;
  }

  List<SharedTranscript> history(Iterable<SharedTranscript> shared) {
    final merged = _merged;
    if (merged != null && identical(shared, _shared)) return merged;
    final byId = <String, SharedTranscript>{};
    for (final transcript in _local) {
      byId.putIfAbsent(transcript.id, () => transcript);
    }
    for (final transcript in shared) {
      final local = byId[transcript.id];
      byId[transcript.id] =
          !transcript.hasCorrection &&
              local?.originalText == transcript.originalText &&
              local?.correctedText != null
          ? transcript.withCorrection(local!.correctedText!)
          : transcript;
    }
    final sorted = byId.values.toList()
      ..sort((a, b) {
        final byTime = b.updatedAt.compareTo(a.updatedAt);
        return byTime == 0 ? b.id.compareTo(a.id) : byTime;
      });
    _shared = shared;
    return _merged = sorted
        .take(SharedAudioExportStore.maximumVisibleTranscripts)
        .map((transcript) {
          final corrected = _corrections.isEmpty
              ? null
              : _corrections[_correctionKey(transcript)];
          return corrected == null
              ? transcript
              : transcript.withCorrection(corrected);
        })
        .toList(growable: false);
  }

  Future<void> saveCorrection(SharedTranscript transcript, String text) async {
    final support = await _supportDirectory();
    final key = _correctionKey(transcript);
    final file = _correctionFile('${support.path}/workbench/audio', key);
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.part');
    await partial.writeAsString('$text\n', flush: true);
    await partial.rename(file.path);
    _corrections[key] = text;
    _merged = null;
  }

  static File _correctionFile(String root, String key) =>
      File('$root/history-corrections/$key.corrected.txt');

  static String _correctionKey(SharedTranscript transcript) => sha256
      .convert(utf8.encode('${transcript.id}\u0000${transcript.originalText}'))
      .toString();

  static Future<String?> _readText(File file) async {
    try {
      final stat = await file.stat();
      if (stat.size == 0 || stat.size > _maximumTextBytes) return null;
      final text = (await file.readAsString()).trim();
      return text.isEmpty ? null : text;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}
