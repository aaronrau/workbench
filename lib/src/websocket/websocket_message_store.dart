import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../audio/shared_audio_export_store.dart';

/// Prefer authoritative local records when their exported copies also exist.
List<SharedWebSocketMessage> mergeMessageHistory(
  Iterable<SharedWebSocketMessage> shared,
  Iterable<SharedWebSocketMessage> local,
) {
  final byId = <String, SharedWebSocketMessage>{
    for (final message in shared) message.id: message,
    for (final message in local) message.id: message,
  };
  final messages = byId.values.toList()
    ..sort((a, b) {
      final time = b.updatedAt.compareTo(a.updatedAt);
      return time != 0 ? time : b.id.compareTo(a.id);
    });
  return messages.take(SharedAudioExportStore.maximumVisibleMessages).toList();
}

enum WebSocketMessageDirection {
  sent,
  received;

  String get serializedName => name;
}

final class SavedWebSocketMessage {
  const SavedWebSocketMessage({
    required this.path,
    required this.fileName,
    required this.direction,
  });

  final String path;
  final String fileName;
  final WebSocketMessageDirection direction;
}

final class WebSocketMessageStore {
  WebSocketMessageStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
    DateTime Function() now = DateTime.now,
  }) : _supportDirectory = supportDirectory,
       _now = now;

  static const int maximumMessageCharacters = 65536;
  static const String fileSuffix = '.message.txt';

  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _now;
  Directory? _directory;
  int _sequence = 0;
  int _cacheRevision = 0;
  int _refreshGeneration = 0;
  List<SharedWebSocketMessage> _recent = const [];
  List<SharedWebSocketMessage> get recentMessages => List.unmodifiable(_recent);

  Future<void> initialize() async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/workbench/websocket_messages');
    await directory.create(recursive: true);
    _directory = directory;
    await refreshRecent();
  }

  Future<void> refreshRecent() async {
    final generation = ++_refreshGeneration;
    final revision = _cacheRevision;
    final paths = await savedPaths();
    final loaded = <SharedWebSocketMessage>[];
    for (final path in paths.reversed.take(
      SharedAudioExportStore.maximumVisibleMessages,
    )) {
      final file = File(path);
      final name = file.uri.pathSegments.last;
      final direction = name.endsWith('.sent.message.txt')
          ? SharedWebSocketMessageDirection.sent
          : name.endsWith('.received.message.txt')
          ? SharedWebSocketMessageDirection.received
          : null;
      if (direction == null) continue;
      try {
        final stat = await file.stat();
        if (stat.size > maximumMessageCharacters * 4 + 1) continue;
        final text = _normalize(await file.readAsString());
        if (text.isEmpty) continue;
        final stamp = RegExp(
          r'^workbench-websocket-(\d{8})T(\d{6})(\d{3,6})Z-',
        ).firstMatch(name);
        final savedAt = stamp == null
            ? null
            : DateTime.tryParse('${stamp[1]}T${stamp[2]}.${stamp[3]}Z');
        loaded.add(
          SharedWebSocketMessage(
            id: name,
            direction: direction,
            text: text,
            updatedAt: savedAt ?? stat.modified,
          ),
        );
      } on FileSystemException {
        // One unavailable record must not hide the rest of the durable history.
      } on FormatException {
        // Ignore malformed text records; keep their original files intact.
      }
    }
    if (generation != _refreshGeneration) return;
    _recent = mergeMessageHistory(
      loaded,
      revision == _cacheRevision ? const [] : _recent,
    );
  }

  Future<SavedWebSocketMessage> save({
    required WebSocketMessageDirection direction,
    required String message,
  }) async {
    final directory = _directory;
    if (directory == null) {
      throw StateError('WebSocket message storage is not initialized.');
    }
    final normalized = _normalize(message);
    if (normalized.isEmpty) {
      throw const FormatException('WebSocket message cannot be empty.');
    }
    final receivedAt = _now().toUtc();
    late File target;
    late File partial;
    while (true) {
      _sequence++;
      final stamp = receivedAt.toIso8601String().replaceAll(
        RegExp(r'[-:.]'),
        '',
      );
      final base =
          'workbench-websocket-$stamp-'
          '${_sequence.toString().padLeft(4, '0')}';
      target = File(
        '${directory.path}/$base.${direction.serializedName}$fileSuffix',
      );
      partial = File('${directory.path}/$base.part.txt');
      if (!await target.exists() && !await partial.exists()) {
        break;
      }
    }
    await partial.writeAsString('$normalized\n', flush: true);
    await partial.rename(target.path);
    _cacheRevision++;
    _recent = mergeMessageHistory(_recent, [
      SharedWebSocketMessage(
        id: target.uri.pathSegments.last,
        direction: direction == WebSocketMessageDirection.sent
            ? SharedWebSocketMessageDirection.sent
            : SharedWebSocketMessageDirection.received,
        text: normalized,
        updatedAt: receivedAt,
      ),
    ]);
    return SavedWebSocketMessage(
      path: target.path,
      fileName: target.uri.pathSegments.last,
      direction: direction,
    );
  }

  Future<List<String>> savedPaths() async {
    final directory = _directory;
    if (directory == null) {
      throw StateError('WebSocket message storage is not initialized.');
    }
    final paths = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith(fileSuffix))
        .map((entity) => entity.path)
        .toList();
    paths.sort();
    return paths;
  }

  static String _normalize(String value) {
    final output = StringBuffer();
    var characters = 0;
    final normalizedNewlines = value
        .trim()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    for (final rune in normalizedNewlines.runes) {
      if (characters >= maximumMessageCharacters) {
        break;
      }
      if (rune == 0x09 ||
          rune == 0x0A ||
          rune >= 0x20 && (rune < 0x7F || rune > 0x9F)) {
        output.writeCharCode(rune);
      }
      characters++;
    }
    return output.toString().trim();
  }
}
