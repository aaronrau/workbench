import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'conversation_model_store.dart';
import 'conversation_models.dart';

String mossSpeakerProfileRevision(
  List<SpeakerProfile> profiles,
  double threshold,
) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'profiles': profiles.map((profile) => profile.toJson()).toList(),
          'threshold': threshold,
        }),
      ),
    )
    .toString();

/// Only exclusive speech supplies a voice signature. Overlap and silence must
/// not teach a profile, and MOSS's local speaker number is never an identity.
Map<String, List<List<int>>> mossSpeakerWindows(ConversationRecord record) {
  final windows = <String, List<List<int>>>{};
  for (final turn in record.utterances) {
    final local = turn.localSpeakerId ?? turn.speakerId.split(':').last;
    var pieces = <List<int>>[
      [turn.startMs, turn.endMs],
    ];
    for (final other in record.utterances) {
      if ((other.localSpeakerId ?? other.speakerId.split(':').last) == local) {
        continue;
      }
      pieces = [
        for (final piece in pieces)
          if (other.endMs <= piece[0] || other.startMs >= piece[1])
            piece
          else ...[
            if (other.startMs > piece[0]) [piece[0], other.startMs],
            if (other.endMs < piece[1]) [other.endMs, piece[1]],
          ],
      ];
    }
    windows.putIfAbsent(local, () => []).addAll(pieces);
  }
  return windows.map((key, values) {
    values.sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<int>>[];
    for (final value in values) {
      if (merged.isEmpty || merged.last[1] < value[0]) {
        merged.add(value.toList());
      } else {
        merged.last[1] = max(merged.last[1], value[1]);
      }
    }
    return MapEntry(key, merged);
  });
}

/// Saved profiles are read-only here. An uncertain match keeps its local label;
/// no text-based guesses or automatic profile learning happen in this path.
ConversationRecord matchMossSpeakerProfiles(
  ConversationRecord record,
  Map<String, List<double>> signatures,
  List<SpeakerProfile> profiles,
  double threshold,
) {
  final matches = <String, ({SpeakerProfile profile, double score})>{};
  final candidates = <({String local, SpeakerProfile profile, double score})>[];
  for (final entry in signatures.entries) {
    final scores = [
      for (final profile in profiles)
        if (profile.calibrationComplete && !profile.enrollmentInProgress)
          (
            profile: profile,
            score: speakerProfileSimilarity(profile, entry.value),
          ),
    ]..sort((a, b) => b.score.compareTo(a.score));
    if (scores.isEmpty) continue;
    final best = scores.first;
    final cutoff = best.profile.isPrimary
        ? best.profile.signatureMatchThreshold
        : threshold;
    if (speakerSignatureMatches(best.score, threshold: cutoff) &&
        (scores.length == 1 || best.score - scores[1].score >= 0.03)) {
      candidates.add((
        local: entry.key,
        profile: best.profile,
        score: best.score,
      ));
    }
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));
  final used = <String>{};
  for (final candidate in candidates) {
    if (used.add(candidate.profile.id)) {
      matches[candidate.local] = (
        profile: candidate.profile,
        score: candidate.score,
      );
    }
  }
  return ConversationRecord(
    id: record.id,
    audioPath: record.audioPath,
    textPath: record.textPath,
    metadataPath: record.metadataPath,
    updatedAt: record.updatedAt,
    speakerIdentificationVersion: 1,
    speakerProfileRevision: mossSpeakerProfileRevision(profiles, threshold),
    utterances: [
      for (final turn in record.utterances)
        (() {
          final local = turn.localSpeakerId ?? turn.speakerId.split(':').last;
          final signature = signatures[local];
          final match = matches[local];
          final number = int.tryParse(local.replaceFirst('S', ''));
          return ConversationUtterance(
            id: turn.id,
            conversationId: turn.conversationId,
            speakerId:
                match?.profile.id ?? 'moss:${record.id.substring(5)}:$local',
            speakerLabel:
                match?.profile.label ?? 'Speaker ${number ?? local} (clip)',
            text: turn.text,
            startMs: turn.startMs,
            endMs: turn.endMs,
            confidence: match?.score.clamp(0, 1) ?? 0,
            updatedAt: turn.updatedAt,
            isPrimary: (match?.profile.isPrimary ?? false) && !turn.isOverlap,
            isOverlap: turn.isOverlap,
            speakerSignature: signature,
            localSpeakerId: local,
          );
        })(),
    ],
  );
}

abstract interface class MossSpeakerSignatureExtractor {
  Future<Map<String, List<double>>> extract(ConversationRecord record);
  Future<void> dispose();
}

/// One serial CPU embedding worker; it loads neither segmentation nor Parakeet.
final class MossSpeakerSignatureWorker
    implements MossSpeakerSignatureExtractor {
  MossSpeakerSignatureWorker({required this.onStatus});
  final void Function(String message, {bool isError}) onStatus;
  Future<SendPort>? _startup;
  SendPort? _commands;
  Isolate? _isolate;
  ReceivePort? _events;
  StreamSubscription<Object?>? _subscription;
  final _pending = <int, Completer<Map<String, List<double>>>>{};
  int _nextId = 0;
  bool _disposed = false;
  Completer<void>? _closed;

  Future<SendPort> _start() async {
    final model = await ConversationModelStore().prepareEmbedding();
    if (_disposed) throw StateError('Speaker worker closed');
    await _subscription?.cancel();
    _events?.close();
    final ready = Completer<SendPort>();
    _closed = Completer<void>();
    final events = ReceivePort();
    _events = events;
    _subscription = events.listen((Object? event) {
      if (event is SendPort) {
        _commands = event;
        if (!ready.isCompleted) ready.complete(event);
        onStatus(
          '[WorkBench][MossSpeakers] state=ready provider=cpu model=titanet-small',
        );
      } else if (event is Map && event['id'] is int) {
        final result = _pending.remove(event['id']);
        if (event['signatures'] is Map) {
          result?.complete(
            (event['signatures'] as Map).map(
              (key, value) =>
                  MapEntry(key as String, (value as List).cast<double>()),
            ),
          );
        } else {
          result?.completeError(StateError('Speaker extraction failed'));
        }
      } else {
        if (event == null && !(_closed?.isCompleted ?? true)) {
          _closed!.complete();
        }
        if (!ready.isCompleted) {
          ready.completeError(StateError('Speaker worker unavailable'));
        }
        for (final result in _pending.values) {
          if (!result.isCompleted) {
            result.completeError(StateError('Speaker worker stopped'));
          }
        }
        _pending.clear();
        _startup = null;
        _commands = null;
      }
    });
    final values = await Future.wait<Object>([
      Isolate.spawn<Map<String, Object>>(
        _speakerWorker,
        {'events': events.sendPort, 'model': model},
        onError: events.sendPort,
        onExit: events.sendPort,
        debugName: 'workbench-moss-speakers',
      ).then((isolate) {
        _isolate = isolate;
        return isolate;
      }),
      ready.future.timeout(const Duration(seconds: 30)),
    ]);
    return values[1] as SendPort;
  }

  @override
  Future<Map<String, List<double>>> extract(ConversationRecord record) async {
    final commands = await (_startup ??= _start());
    if (_disposed) throw StateError('Speaker worker closed');
    final id = ++_nextId;
    final result = Completer<Map<String, List<double>>>();
    _pending[id] = result;
    commands.send({
      'id': id,
      'path': record.audioPath,
      'windows': mossSpeakerWindows(record),
    });
    return result.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () async {
        await dispose();
        throw TimeoutException('Speaker extraction timed out');
      },
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _commands?.send(null);
    // This worker is optional. Its cleanup is never awaited by primary audio.
    final closed = _closed;
    if (closed != null) {
      await closed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _isolate?.kill(priority: Isolate.immediate);
        },
      );
    }
    for (final result in _pending.values) {
      if (!result.isCompleted) {
        result.completeError(StateError('Speaker worker closed'));
      }
    }
    _pending.clear();
    await _subscription?.cancel();
    _events?.close();
  }
}

void _speakerWorker(Map<String, Object> initial) {
  final events = initial['events']! as SendPort;
  sherpa.SpeakerEmbeddingExtractor? extractor;
  final commands = ReceivePort();
  try {
    sherpa.initBindings();
    extractor = sherpa.SpeakerEmbeddingExtractor(
      config: sherpa.SpeakerEmbeddingExtractorConfig(
        model: initial['model']! as String,
        numThreads: 1,
        debug: false,
        provider: 'cpu',
      ),
    );
    if (extractor.ptr == nullptr || extractor.dim <= 0) {
      throw StateError('Embedding model unavailable');
    }
    events.send(commands.sendPort);
    commands.listen((Object? message) {
      if (message == null) {
        extractor?.free();
        commands.close();
        return;
      }
      final job = message as Map;
      try {
        final wave = sherpa.readWave(job['path'] as String);
        if (wave.sampleRate != 16000 || wave.samples.length > 90 * 16000) {
          throw const FormatException('Invalid speaker WAV');
        }
        final signatures = <String, List<double>>{};
        for (final entry in (job['windows'] as Map).entries) {
          final intervals = (entry.value as List).cast<List<int>>().toList()
            ..sort((a, b) => (b[1] - b[0]).compareTo(a[1] - a[0]));
          final samples = <Float32List>[];
          var count = 0;
          for (final interval in intervals) {
            final start = (interval[0] * 16).clamp(0, wave.samples.length);
            final end = min(
              (interval[1] * 16).clamp(start, wave.samples.length),
              start + 12 * 16000 - count,
            );
            if (end <= start) continue;
            samples.add(Float32List.sublistView(wave.samples, start, end));
            count += end - start;
            if (count >= 12 * 16000) break;
          }
          if (count < 16000) continue;
          final joined = Float32List(count);
          var offset = 0;
          for (final piece in samples) {
            joined.setRange(offset, offset + piece.length, piece);
            offset += piece.length;
          }
          final stream = extractor!.createStream();
          try {
            stream.acceptWaveform(samples: joined, sampleRate: 16000);
            stream.inputFinished();
            final values = extractor
                .compute(stream)
                .map((value) => value.toDouble())
                .toList();
            if (values.isNotEmpty &&
                values.every((value) => value.isFinite) &&
                values.any((value) => value != 0)) {
              signatures[entry.key as String] = normalizeSpeakerEmbedding(
                values,
              );
            }
          } finally {
            stream.free();
          }
        }
        events.send({'id': job['id'], 'signatures': signatures});
      } on Object {
        events.send({'id': job['id'], 'failed': true});
      }
    });
  } on Object {
    extractor?.free();
    commands.close();
    events.send('failed');
  }
}
