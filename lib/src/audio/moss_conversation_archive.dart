import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import 'conversation_models.dart';
import 'conversation_record_store.dart';
import 'conversation_text_export_queue.dart';
import 'moss_audio.dart';
import 'moss_speaker_matcher.dart';
import 'shared_audio_export_store.dart';

/// Converts already completed MOSS files into the shared conversation format.
/// Capture, primary STT, correction, and delivery never await this consumer.
/// Source JSON/raw/WAV files are its durable input queue. Its record/export
/// ledgers are separate from the optional legacy speaker-analysis worker.
final class MossConversationArchive {
  MossConversationArchive({
    required this.sharedStore,
    required this.onChanged,
    required this.onStatus,
    this.speakerProfilesProvider,
    this.speakerMatchThresholdProvider,
    this.speakerExtractorFactory,
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory,
       _records = ConversationRecordStore(
         supportDirectory: supportDirectory,
         namespace: 'moss',
       );

  final SharedAudioExportStore sharedStore;
  final void Function() onChanged;
  final void Function(String message, {bool isError}) onStatus;
  final Future<Directory> Function() _supportDirectory;
  final ConversationRecordStore _records;
  final List<SpeakerProfile> Function()? speakerProfilesProvider;
  final double Function()? speakerMatchThresholdProvider;
  final MossSpeakerSignatureExtractor Function()? speakerExtractorFactory;
  final _identityPending = <String, DateTime>{};
  MossSpeakerSignatureExtractor? _identityWorker;
  bool _identityRunning = false;
  bool _identitySuspended = false;
  Timer? _identityRetry;
  Timer? _identityIdle;
  int _identityGeneration = 0;
  late final _exports = ConversationTextExportQueue(
    recordStore: _records,
    exportStore: sharedStore,
    onFailure: () => _warn('export_deferred'),
  );
  final _queuedSources = <String>{};
  final _retrySources = <String>{};
  final _indexPending = <String, int>{};
  Future<void> _imports = Future<void>.value();
  Future<void>? _ready;
  Future<void>? _recovery;
  Directory? _source;
  Timer? _importRetry;
  Timer? _indexRetry;
  bool _indexing = false;
  bool _disposed = false;
  int _revision = 0;
  String? error;
  int get pendingCount =>
      _queuedSources.length +
      _retrySources.length +
      _indexPending.length +
      _identityPending.length;

  Future<void> initialize() =>
      _ready ??= _initialize().catchError((Object caught) {
        _ready = null;
        _warn('storage_unavailable');
        throw caught;
      });

  Future<void> _initialize() async {
    final support = await _supportDirectory();
    _source = Directory('${support.path}/workbench/audio/moss');
    await _records.initialize();
    await _exports.initialize();
  }

  /// Startup and explicit refresh recover both pending imports and index loss.
  /// The return value covers local persistence only, never a native consumer.
  Future<void> recover() => _recovery ??= _recover().whenComplete(() {
    _recovery = null;
  });

  Future<void> _recover() async {
    if (_disposed) return;
    await initialize();
    final exportBatch = <String>[];
    await for (final record in _records.streamRecords()) {
      if (_disposed) return;
      _enqueueIndex(record.id);
      _queueIdentity(record);
      exportBatch.add(record.textPath);
      if (exportBatch.length == 8) {
        await _exports.enqueue(exportBatch);
        exportBatch.clear();
      }
    }
    if (exportBatch.isNotEmpty) await _exports.enqueue(exportBatch);
    final source = _source!;
    if (await source.exists()) {
      await for (final file in source.list()) {
        if (_disposed) return;
        if (file is File && file.path.endsWith('.moss.json')) accept(file.path);
        if (_queuedSources.length >= 64) await _imports;
      }
    }
    await _imports;
    _exports.resume();
  }

  void accept(String metadataPath) {
    if (_disposed || !_queuedSources.add(metadataPath)) return;
    onChanged();
    final operation = _imports
        .then((_) async {
          if (_disposed) return;
          await initialize();
          await _import(metadataPath);
          _retrySources.remove(metadataPath);
          error = null;
        })
        .catchError((Object caught) {
          if (_disposed) return;
          if (caught is FormatException) {
            _warn('invalid_metadata');
          } else {
            _retrySources.add(metadataPath);
            _warn('save_deferred');
            _importRetry?.cancel();
            _importRetry = Timer(const Duration(seconds: 30), () {
              for (final path in _retrySources.toList()) {
                accept(path);
              }
            });
          }
        })
        .whenComplete(() {
          _queuedSources.remove(metadataPath);
          if (!_disposed) onChanged();
        });
    _imports = operation;
  }

  Future<void> drainImports() => _imports;

  Future<void> _import(String path) async {
    final metadata = File(path);
    final source = _source!;
    final name = metadata.uri.pathSegments.last;
    if (!name.endsWith('.moss.json') ||
        metadata.absolute.parent.path != source.absolute.path) {
      throw const FormatException('Invalid MOSS source path.');
    }
    final id = name.substring(0, name.length - '.moss.json'.length);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(id) ||
        id.contains('..')) {
      throw const FormatException('Invalid MOSS source ID.');
    }
    final wav = File('${source.path}/$id.wav');
    final raw = File('${source.path}/$id.raw.txt');
    // Raw is the final commit marker. Partial generation must not appear here.
    if (!await raw.exists() || !await wav.exists()) return;
    final annotated = File('${source.path}/$id.moss.txt');
    // New raw transcripts contain only spoken words. Older builds stored the
    // annotated output in raw, so retain that fallback for existing recordings.
    final conversationSource = await annotated.exists() ? annotated : raw;
    if (await metadata.length() > 1024 * 1024 ||
        await raw.length() > 65536 ||
        await conversationSource.length() > 65536) {
      throw const FormatException('MOSS source exceeds the record limit.');
    }
    final decoded = jsonDecode(await metadata.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['utterances'] is! List<dynamic>) {
      throw const FormatException('Invalid MOSS metadata.');
    }
    final model = MossQuantization.values.where(
      (value) => value.modelId == decoded['model'],
    );
    if (model.length != 1 ||
        decoded['model_sha256'] != model.single.sha256 ||
        (decoded['speaker_scope'] != null && decoded['speaker_scope'] != id)) {
      throw const FormatException('Invalid MOSS model metadata.');
    }
    final audioMs = decoded['audio_ms'];
    if (audioMs is! int || audioMs < 1 || audioMs > 90000) {
      throw const FormatException('Invalid MOSS audio duration.');
    }
    final turns = parseMossTranscript(
      await conversationSource.readAsString(),
      audioSeconds: audioMs / 1000,
    );
    final rows = decoded['utterances']! as List<dynamic>;
    if (turns.isEmpty || turns.length > 256 || rows.length != turns.length) {
      throw const FormatException('Invalid MOSS turns.');
    }
    for (var i = 0; i < turns.length; i++) {
      final row = rows[i];
      final turn = turns[i];
      if (row is! Map<String, dynamic> ||
          row['speaker'] != turn.speaker ||
          row['text'] != turn.text ||
          row['start_seconds'] != turn.start ||
          row['end_seconds'] != turn.end) {
        throw const FormatException('MOSS annotations and metadata disagree.');
      }
    }
    if (_disposed) return;
    final recordId = 'moss-$id';
    final updatedAt = (await metadata.lastModified()).toUtc();
    final text = File('${source.path}/$recordId.conversation.txt');
    final retainedBefore = await _records.readRecord(recordId);
    if (retainedBefore != null &&
        retainedBefore.updatedAt == updatedAt &&
        await text.exists()) {
      return;
    }
    final utterances = <ConversationUtterance>[];
    for (var i = 0; i < turns.length; i++) {
      final turn = turns[i];
      final number = turn.speaker.substring(1).replaceFirst(RegExp(r'^0+'), '');
      final startMs = (turn.start * 1000).round();
      utterances.add(
        ConversationUtterance(
          id: '$recordId-turn-${i + 1}',
          conversationId: recordId,
          speakerId: 'moss:$id:${turn.speaker}',
          localSpeakerId: turn.speaker,
          speakerLabel: 'Speaker ${number.isEmpty ? '0' : number} (clip)',
          text: turn.text,
          startMs: startMs,
          endMs: max(startMs + 1, (turn.end * 1000).round()),
          // MOSS supplies no profile match confidence or enrolled identity.
          confidence: 0,
          updatedAt: updatedAt,
          isOverlap: turns.any(
            (other) =>
                other.speaker != turn.speaker &&
                other.start < turn.end &&
                turn.start < other.end,
          ),
        ),
      );
    }
    final partial = File('${text.path}.part');
    await partial.writeAsString(
      encodeConversationText(utterances),
      flush: true,
    );
    await partial.rename(text.path);
    final retained = await _records.retainRecord(
      ConversationRecord(
        id: recordId,
        audioPath: wav.path,
        textPath: text.path,
        metadataPath: '',
        utterances: utterances,
        updatedAt: updatedAt,
      ),
    );
    // Index and export failures cannot undo the durable record or stall STT.
    _enqueueIndex(retained.id);
    _queueIdentity(retained);
    await _exports.enqueue([retained.textPath]);
    if (!_disposed) {
      onStatus(
        '[WorkBench][Conversation] state=saved source=moss turns=${utterances.length}',
      );
    }
  }

  void _queueIdentity(ConversationRecord record) {
    if (_disposed || speakerProfilesProvider == null) return;
    _identityPending[record.id] = record.updatedAt;
    resumeSpeakerMatching();
  }

  void resumeSpeakerMatching() {
    if (_disposed ||
        _identityRunning ||
        (_identityRetry?.isActive ?? false) ||
        _identitySuspended ||
        _identityPending.isEmpty ||
        !(speakerProfilesProvider?.call().any(
              (profile) =>
                  profile.calibrationComplete && !profile.enrollmentInProgress,
            ) ??
            false)) {
      return;
    }
    _identityIdle?.cancel();
    unawaited(_matchPendingSpeakers());
  }

  Future<void> _matchPendingSpeakers() async {
    _identityRunning = true;
    final generation = _identityGeneration;
    try {
      while (!_disposed && !_identitySuspended && _identityPending.isNotEmpty) {
        // New recordings can refine their labels before an older backfill.
        final id = _identityPending.entries
            .reduce((a, b) => a.value.isAfter(b.value) ? a : b)
            .key;
        final record = await _records.readRecord(id);
        if (_disposed || generation != _identityGeneration) return;
        if (record == null) {
          _identityPending.remove(id);
          continue;
        }
        final profiles =
            speakerProfilesProvider?.call() ?? const <SpeakerProfile>[];
        if (profiles.isEmpty) break;
        final threshold =
            speakerMatchThresholdProvider?.call() ??
            defaultSpeakerSignatureMatchThreshold;
        final revision = mossSpeakerProfileRevision(profiles, threshold);
        if (record.speakerIdentificationVersion == 1 &&
            record.speakerProfileRevision == revision) {
          _identityPending.remove(id);
          continue;
        }
        Map<String, List<double>> signatures;
        if (record.speakerIdentificationVersion == 1) {
          signatures = {
            for (final turn in record.utterances)
              if (turn.speakerSignature != null)
                turn.localSpeakerId ?? turn.speakerId.split(':').last:
                    turn.speakerSignature!,
          };
        } else {
          final worker = _identityWorker ??=
              speakerExtractorFactory?.call() ??
              MossSpeakerSignatureWorker(onStatus: onStatus);
          signatures = await worker.extract(record);
        }
        if (_disposed || generation != _identityGeneration) return;
        final matched = matchMossSpeakerProfiles(
          record,
          signatures,
          profiles,
          threshold,
        );
        // Identity is optional enrichment. Raw MOSS files and primary routing
        // are never changed, even if any of these persistence steps fail.
        final partial = File('${matched.textPath}.part');
        await partial.writeAsString(
          encodeConversationText(matched.utterances),
          flush: true,
        );
        await partial.rename(matched.textPath);
        final retained = await _records.retainRecord(matched);
        _enqueueIndex(retained.id);
        await _exports.enqueue([retained.textPath]);
        if (mossSpeakerProfileRevision(
              speakerProfilesProvider?.call() ?? [],
              speakerMatchThresholdProvider?.call() ??
                  defaultSpeakerSignatureMatchThreshold,
            ) ==
            revision) {
          _identityPending.remove(id);
        }
        onChanged();
        onStatus(
          '[WorkBench][MossSpeakers] state=completed provider=cpu turns=${matched.utterances.length} matched=${matched.utterances.where((turn) => !turn.speakerId.startsWith('moss:')).length}',
        );
      }
    } on Object {
      if (!_disposed && generation == _identityGeneration) {
        _warn('speaker_match_deferred');
        final worker = _identityWorker;
        _identityWorker = null;
        if (worker != null) {
          unawaited(worker.dispose().catchError((Object _) {}));
        }
        _identityRetry?.cancel();
        _identityRetry = Timer(const Duration(seconds: 30), () {
          _identityRetry = null;
          resumeSpeakerMatching();
        });
      }
    } finally {
      _identityRunning = false;
      if (!_disposed && !_identitySuspended) {
        _identityIdle?.cancel();
        _identityIdle = Timer(const Duration(seconds: 30), () {
          final worker = _identityWorker;
          _identityWorker = null;
          if (worker != null) {
            unawaited(worker.dispose().catchError((Object _) {}));
          }
        });
      }
    }
  }

  void handleMemoryPressure() {
    _identitySuspended = true;
    _identityGeneration++;
    _identityRetry?.cancel();
    _identityIdle?.cancel();
    final worker = _identityWorker;
    _identityWorker = null;
    if (worker != null) unawaited(worker.dispose().catchError((Object _) {}));
  }

  void resumeAfterMemoryPressure() {
    _identitySuspended = false;
    resumeSpeakerMatching();
  }

  void _enqueueIndex(String id) {
    if (_disposed) return;
    _indexPending[id] = ++_revision;
    unawaited(_flushIndex());
  }

  Future<void> _flushIndex() async {
    if (_disposed || _indexing || _indexPending.isEmpty) return;
    _indexing = true;
    try {
      while (!_disposed && _indexPending.isNotEmpty) {
        final batch = _indexPending.entries.take(8).toList();
        final records = <ConversationRecord>[];
        for (final entry in batch) {
          final record = await _records.readRecord(entry.key);
          if (record != null) records.add(record);
        }
        if (_disposed) return;
        await sharedStore.indexConversations(records);
        if (_disposed) return;
        for (final entry in batch) {
          if (_indexPending[entry.key] == entry.value) {
            _indexPending.remove(entry.key);
          }
        }
        onChanged();
      }
    } on Object {
      if (!_disposed) {
        _warn('index_deferred');
        _indexRetry?.cancel();
        _indexRetry = Timer(
          const Duration(seconds: 30),
          () => unawaited(_flushIndex()),
        );
      }
    } finally {
      _indexing = false;
    }
  }

  void _warn(String state) {
    error =
        'Some MOSS conversation updates are waiting. Original audio and transcripts remain saved.';
    onStatus(
      '[WorkBench][Conversation] state=$state source=moss',
      isError: true,
    );
    onChanged();
  }

  Future<void> dispose() async {
    _disposed = true;
    _identityGeneration++;
    _identityRetry?.cancel();
    _identityIdle?.cancel();
    final worker = _identityWorker;
    _identityWorker = null;
    if (worker != null) unawaited(worker.dispose().catchError((Object _) {}));
    _importRetry?.cancel();
    _indexRetry?.cancel();
    await _imports;
    if (_ready != null) {
      try {
        await _ready;
      } on Object {
        return;
      }
      await _exports.dispose();
    }
  }
}
