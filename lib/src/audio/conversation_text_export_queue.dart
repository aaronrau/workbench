import 'dart:async';

import 'conversation_record_store.dart';
import 'shared_audio_export_store.dart';

/// Mirrors already durable conversation text without owning an analysis job.
final class ConversationTextExportQueue {
  ConversationTextExportQueue({
    required this.recordStore,
    required this.exportStore,
    required this.onFailure,
  });

  final ConversationRecordStore recordStore;
  final SharedAudioExportStore exportStore;
  final void Function() onFailure;
  final Map<String, int> _pending = <String, int>{};
  Future<void> _writes = Future<void>.value();
  Timer? _retry;
  int _revision = 0;
  bool _running = false;
  bool _disposed = false;

  Future<void> initialize() async {
    _pending.addAll(await recordStore.loadPendingTextExports());
    for (final revision in _pending.values) {
      if (revision > _revision) _revision = revision;
    }
    // Persist migration from retained records before any native handoff.
    await _persist();
    resume();
  }

  Future<void> enqueue(Iterable<String> paths) async {
    if (_disposed) return;
    for (final path in paths) {
      _pending[path] = ++_revision;
    }
    await _persist();
    resume();
  }

  void resume() {
    if (_disposed ||
        _running ||
        _pending.isEmpty ||
        !exportStore.hasSharedFolder) {
      return;
    }
    _retry?.cancel();
    _retry = null;
    _running = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (!_disposed && _pending.isNotEmpty && exportStore.hasSharedFolder) {
        final folder = exportStore.folder;
        final batch = _pending.entries.take(8).toList(growable: false);
        // One native call at a time, even if a provider never responds. New
        // results only append to the app-private ledger while this is waiting.
        await exportStore.exportFiles(batch.map((entry) => entry.key));
        if (_disposed) return;
        if (!identical(folder, exportStore.folder)) continue;
        for (final entry in batch) {
          // Reconciliation may have rewritten this text during its export.
          if (_pending[entry.key] == entry.value) _pending.remove(entry.key);
        }
        try {
          await _persist();
        } on Object {
          for (final entry in batch) {
            _pending.putIfAbsent(entry.key, () => entry.value);
          }
          rethrow;
        }
      }
    } on Object {
      if (!_disposed) {
        onFailure();
        _retry = Timer(const Duration(seconds: 30), resume);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _persist() {
    final snapshot = Map<String, int>.of(_pending);
    final write = _writes.then(
      (_) => recordStore.savePendingTextExports(snapshot),
    );
    _writes = write.catchError((Object error) {});
    return write;
  }

  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
    await _writes;
  }
}
