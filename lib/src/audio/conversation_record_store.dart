import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'conversation_models.dart';

final class ConversationProfileRecovery {
  const ConversationProfileRecovery({
    required this.profiles,
    required this.enabled,
    required this.speakerMatchThreshold,
  });

  static const int schemaVersion = 1;
  static const int maximumBytes = 2 * 1024 * 1024;

  factory ConversationProfileRecovery.decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maximumBytes) {
      throw const FormatException(
        'The speaker signature recovery has an invalid size.',
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != schemaVersion ||
        decoded['profiles'] is! List<dynamic> ||
        decoded['enabled'] is! bool ||
        decoded['speakerMatchThreshold'] is! num) {
      throw const FormatException(
        'The speaker signature recovery has an unsupported format.',
      );
    }
    final threshold = (decoded['speakerMatchThreshold']! as num).toDouble();
    if (!isAdjustableSpeakerSignatureThreshold(threshold)) {
      throw const FormatException(
        'The recovered speaker match threshold is invalid.',
      );
    }
    final profiles = (decoded['profiles']! as List<dynamic>)
        .map((value) {
          if (value is! Map<String, dynamic>) {
            throw const FormatException(
              'The recovered speaker profile is invalid.',
            );
          }
          return SpeakerProfile.fromJson(value);
        })
        .toList(growable: false);
    return ConversationProfileRecovery(
      profiles: List<SpeakerProfile>.unmodifiable(profiles),
      enabled: decoded['enabled']! as bool,
      speakerMatchThreshold: normalizeAdjustableSpeakerSignatureThreshold(
        threshold,
      ),
    );
  }

  final List<SpeakerProfile> profiles;
  final bool enabled;
  final double speakerMatchThreshold;

  Uint8List encode() {
    final value = const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'version': schemaVersion,
      'profiles': profiles.map((profile) => profile.toJson()).toList(),
      'enabled': enabled,
      'speakerMatchThreshold': speakerMatchThreshold,
    });
    final bytes = Uint8List.fromList(utf8.encode('$value\n'));
    if (bytes.length > maximumBytes) {
      throw StateError('The speaker signature recovery is too large.');
    }
    return bytes;
  }
}

final class ConversationReconciliationResult {
  const ConversationReconciliationResult({
    required this.recordsToIndex,
    required this.updatedTextPaths,
    required this.updatedRecordCount,
    required this.updatedTurnCount,
  });

  final List<ConversationRecord> recordsToIndex;
  final List<String> updatedTextPaths;
  final int updatedRecordCount;
  final int updatedTurnCount;
}

final class ConversationRecordStore {
  ConversationRecordStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory;

  final Future<Directory> Function() _supportDirectory;
  Directory? _root;

  Future<void> initialize() async {
    final support = await _supportDirectory();
    _root = Directory('${support.path}/workbench/conversation');
    await _root!.create(recursive: true);
  }

  Future<List<SpeakerProfile>> loadProfiles() async {
    final file = File('${_requireRoot().path}/speaker-profiles.json');
    if (!await file.exists()) {
      return const <SpeakerProfile>[];
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['profiles'] is! List<Object?>) {
        throw const FormatException('Invalid speaker profile document.');
      }
      return (decoded['profiles']! as List<Object?>)
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => SpeakerProfile.fromJson(
              value.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .toList(growable: false);
    } on Object {
      final invalid = File('${file.path}.invalid');
      if (await invalid.exists()) {
        await invalid.delete();
      }
      await file.rename(invalid.path);
      return const <SpeakerProfile>[];
    }
  }

  Future<void> saveProfiles(Iterable<SpeakerProfile> profiles) async {
    final file = File('${_requireRoot().path}/speaker-profiles.json');
    await _atomicWrite(
      file,
      '${const JsonEncoder.withIndent('  ').convert(<String, Object>{'version': 1, 'profiles': profiles.map((profile) => profile.toJson()).toList(growable: false)})}\n',
    );
  }

  Future<List<ConversationRecord>> loadRecords() async {
    final records = <ConversationRecord>[];
    await for (final entity in _requireRoot().list()) {
      if (entity is! File || !entity.path.endsWith('.conversation.json')) {
        continue;
      }
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map<String, Object?>) {
          records.add(ConversationRecord.fromJson(decoded));
        }
      } on Object {
        continue;
      }
    }
    records.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return records;
  }

  Future<List<ConversationPendingJob>> loadPendingJobs() async {
    final file = File('${_requireRoot().path}/pending-jobs.json');
    if (!await file.exists()) {
      return const <ConversationPendingJob>[];
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['jobs'] is! List<Object?>) {
        throw const FormatException('Invalid conversation job document.');
      }
      final jobs = (decoded['jobs']! as List<Object?>)
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => ConversationPendingJob.fromJson(
              value.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .where((job) => File(job.wavPath).existsSync())
          .toList(growable: false);
      return jobs;
    } on Object {
      return const <ConversationPendingJob>[];
    }
  }

  Future<void> savePendingJobs(Iterable<ConversationPendingJob> jobs) async {
    final file = File('${_requireRoot().path}/pending-jobs.json');
    await _atomicWrite(
      file,
      '${const JsonEncoder.withIndent('  ').convert(<String, Object>{'version': 1, 'jobs': jobs.map((job) => job.toJson()).toList(growable: false)})}\n',
    );
  }

  Future<ConversationRecord> retainRecord(ConversationRecord source) async {
    final metadata = File(
      '${_requireRoot().path}/${source.id}.conversation.json',
    );
    final retained = ConversationRecord(
      id: source.id,
      audioPath: source.audioPath,
      textPath: source.textPath,
      metadataPath: metadata.path,
      utterances: source.utterances,
      updatedAt: source.updatedAt,
    );
    await _atomicWrite(metadata, '${retained.encode()}\n');
    return retained;
  }

  Future<ConversationReconciliationResult> reconcilePrimarySpeaker({
    required SpeakerProfile primary,
    required Map<String, double> equivalentSpeakerScores,
  }) async {
    final recordsToIndex = <ConversationRecord>[];
    final updatedTextPaths = <String>[];
    var updatedRecordCount = 0;
    var updatedTurnCount = 0;
    for (final record in await loadRecords()) {
      var changed = false;
      var shouldReindex = record.utterances.any(
        (utterance) =>
            utterance.isPrimary ||
            utterance.speakerId == primary.id ||
            equivalentSpeakerScores.containsKey(utterance.speakerId),
      );
      final utterances = <ConversationUtterance>[];
      for (final utterance in record.utterances) {
        if (utterance.isOverlap || utterance.isPrimary) {
          utterances.add(utterance);
          continue;
        }
        final signature = utterance.speakerSignature;
        final signatureScore = signature == null
            ? null
            : speakerProfileSimilarity(primary, signature);
        final legacyScore = equivalentSpeakerScores[utterance.speakerId];
        final score = signatureScore ?? legacyScore;
        if (score == null ||
            !speakerSignatureMatches(
              score,
              threshold: primary.signatureMatchThreshold,
            )) {
          utterances.add(utterance);
          continue;
        }
        changed = true;
        shouldReindex = true;
        updatedTurnCount++;
        utterances.add(
          ConversationUtterance(
            id: utterance.id,
            conversationId: utterance.conversationId,
            speakerId: primary.id,
            speakerLabel: primary.label,
            text: utterance.text,
            startMs: utterance.startMs,
            endMs: utterance.endMs,
            confidence: score.clamp(0, 1),
            updatedAt: utterance.updatedAt,
            isPrimary: true,
            speakerSignature: utterance.speakerSignature,
          ),
        );
      }
      if (!changed) {
        if (shouldReindex) {
          recordsToIndex.add(record);
        }
        continue;
      }
      final updated = ConversationRecord(
        id: record.id,
        audioPath: record.audioPath,
        textPath: record.textPath,
        metadataPath: record.metadataPath,
        utterances: utterances,
        updatedAt: record.updatedAt,
      );
      final retained = await retainRecord(updated);
      await _rewriteSourceFiles(retained);
      updatedRecordCount++;
      updatedTextPaths.add(retained.textPath);
      recordsToIndex.add(retained);
    }
    return ConversationReconciliationResult(
      recordsToIndex: recordsToIndex,
      updatedTextPaths: updatedTextPaths,
      updatedRecordCount: updatedRecordCount,
      updatedTurnCount: updatedTurnCount,
    );
  }

  Directory _requireRoot() {
    final root = _root;
    if (root == null) {
      throw StateError('Conversation storage is not initialized.');
    }
    return root;
  }

  Future<void> _atomicWrite(File target, String value) async {
    final partial = File('${target.path}.part');
    if (await partial.exists()) {
      await partial.delete();
    }
    await partial.writeAsString(value, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await partial.rename(target.path);
  }

  Future<void> _rewriteSourceFiles(ConversationRecord record) async {
    final text = File(record.textPath);
    if (await text.exists()) {
      await _atomicWrite(text, encodeConversationText(record.utterances));
    }
    final wavSuffix = RegExp(r'\.(?:recovered\.)?wav$');
    if (!wavSuffix.hasMatch(record.audioPath)) {
      return;
    }
    final sourceMetadata = File(
      record.audioPath.replaceFirst(wavSuffix, '.conversation.json'),
    );
    if (sourceMetadata.path == record.metadataPath ||
        !await sourceMetadata.exists()) {
      return;
    }
    final sourceRecord = ConversationRecord(
      id: record.id,
      audioPath: record.audioPath,
      textPath: record.textPath,
      metadataPath: sourceMetadata.path,
      utterances: record.utterances,
      updatedAt: record.updatedAt,
    );
    await _atomicWrite(sourceMetadata, '${sourceRecord.encode()}\n');
  }
}
