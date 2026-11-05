import 'dart:convert';
import 'dart:math';

const int maximumNonPrimarySpeakerProfiles = 16;
// Lower than the legacy 0.65 cutoff while remaining above the pinned
// af_maple/af_sol near-collision measured at 0.6390.
const double defaultSpeakerSignatureMatchThreshold = 0.64;
const double minimumAdjustableSpeakerSignatureMatchThreshold = 0.50;
const double maximumAdjustableSpeakerSignatureMatchThreshold = 0.90;
const double speakerSignatureLearningThreshold = 0.78;
const int minimumPrimarySpeakerEnrollmentSamples = 3;
const int maximumSpeakerSignaturesPerProfile = 6;

final class ConversationModelPaths {
  const ConversationModelPaths({
    required this.segmentation,
    required this.embedding,
  });

  final String segmentation;
  final String embedding;

  Map<String, Object> toMessage() => <String, Object>{
    'segmentation': segmentation,
    'embedding': embedding,
  };
}

final class ConversationPendingJob {
  const ConversationPendingJob({
    required this.segmentId,
    required this.wavPath,
    required this.enrollment,
    required this.queuedAt,
  });

  factory ConversationPendingJob.fromJson(Map<String, Object?> json) {
    final segmentId = json['segmentId'];
    final wavPath = json['wavPath'];
    final queuedAt = DateTime.tryParse('${json['queuedAt']}');
    if (segmentId is! String ||
        segmentId.trim().isEmpty ||
        wavPath is! String ||
        wavPath.trim().isEmpty ||
        queuedAt == null) {
      throw const FormatException('The saved conversation job is invalid.');
    }
    return ConversationPendingJob(
      segmentId: segmentId.trim(),
      wavPath: wavPath.trim(),
      enrollment: json['enrollment'] == true,
      queuedAt: queuedAt.toUtc(),
    );
  }

  final String segmentId;
  final String wavPath;
  final bool enrollment;
  final DateTime queuedAt;

  Map<String, Object> toJson() => <String, Object>{
    'segmentId': segmentId,
    'wavPath': wavPath,
    'enrollment': enrollment,
    'queuedAt': queuedAt.toUtc().toIso8601String(),
  };
}

final class SpeakerProfile {
  const SpeakerProfile({
    required this.id,
    required this.label,
    required this.embedding,
    required this.sampleCount,
    required this.createdAt,
    required this.updatedAt,
    this.signatures = const <List<double>>[],
    this.isPrimary = false,
    this.signatureMatchThreshold = defaultSpeakerSignatureMatchThreshold,
    this.calibrationComplete = true,
    this.enrollmentSignatures = const <List<double>>[],
    this.historyReconciliationPending = false,
  });

  factory SpeakerProfile.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final label = json['label'];
    final embedding = json['embedding'];
    final sampleCount = json['sampleCount'];
    final createdAt = DateTime.tryParse('${json['createdAt']}');
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    if (id is! String ||
        id.trim().isEmpty ||
        label is! String ||
        label.trim().isEmpty ||
        embedding is! List<Object?> ||
        embedding.isEmpty ||
        sampleCount is! int ||
        sampleCount < 1 ||
        createdAt == null ||
        updatedAt == null) {
      throw const FormatException('The saved speaker profile is invalid.');
    }
    final values = embedding
        .whereType<num>()
        .map((value) => value.toDouble())
        .toList(growable: false);
    if (values.length != embedding.length ||
        values.any((value) => !value.isFinite)) {
      throw const FormatException('The saved speaker signature is invalid.');
    }
    final rawSignatures = json['signatures'];
    final signatures = <List<double>>[];
    if (rawSignatures != null) {
      if (rawSignatures is! List<Object?>) {
        throw const FormatException(
          'The saved speaker signature bank is invalid.',
        );
      }
      for (final rawSignature in rawSignatures) {
        if (rawSignature is! List<Object?>) {
          throw const FormatException(
            'The saved speaker signature bank is invalid.',
          );
        }
        final signature = rawSignature
            .whereType<num>()
            .map((value) => value.toDouble())
            .toList(growable: false);
        if (signature.length != values.length ||
            signature.length != rawSignature.length ||
            signature.any((value) => !value.isFinite)) {
          throw const FormatException(
            'The saved speaker signature bank is invalid.',
          );
        }
        signatures.add(signature);
      }
    }
    final rawEnrollmentSignatures = json['enrollmentSignatures'];
    final enrollmentSignatures = <List<double>>[];
    if (rawEnrollmentSignatures != null) {
      if (rawEnrollmentSignatures is! List<Object?>) {
        throw const FormatException(
          'The saved speaker enrollment samples are invalid.',
        );
      }
      for (final rawSignature in rawEnrollmentSignatures) {
        if (rawSignature is! List<Object?>) {
          throw const FormatException(
            'The saved speaker enrollment samples are invalid.',
          );
        }
        final signature = rawSignature
            .whereType<num>()
            .map((value) => value.toDouble())
            .toList(growable: false);
        if (signature.length != values.length ||
            signature.length != rawSignature.length ||
            signature.any((value) => !value.isFinite)) {
          throw const FormatException(
            'The saved speaker enrollment samples are invalid.',
          );
        }
        enrollmentSignatures.add(signature);
      }
    }
    final rawThreshold = json['signatureMatchThreshold'];
    final signatureMatchThreshold = rawThreshold == null
        ? defaultSpeakerSignatureMatchThreshold
        : rawThreshold is num
        ? rawThreshold.toDouble()
        : double.nan;
    if (!isValidSpeakerSignatureThreshold(signatureMatchThreshold) ||
        enrollmentSignatures.length >= minimumPrimarySpeakerEnrollmentSamples) {
      throw const FormatException('The saved speaker calibration is invalid.');
    }
    return SpeakerProfile(
      id: id.trim(),
      label: label.trim(),
      embedding: values,
      signatures: signatures,
      sampleCount: sampleCount,
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      isPrimary: json['isPrimary'] == true,
      signatureMatchThreshold: signatureMatchThreshold,
      // Profiles written before calibrated enrollment existed remain valid.
      calibrationComplete: json['calibrationComplete'] != false,
      enrollmentSignatures: enrollmentSignatures,
      historyReconciliationPending:
          json['historyReconciliationPending'] == true,
    );
  }

  final String id;
  final String label;
  final List<double> embedding;
  final List<List<double>> signatures;
  final int sampleCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isPrimary;
  final double signatureMatchThreshold;
  final bool calibrationComplete;
  final List<List<double>> enrollmentSignatures;
  final bool historyReconciliationPending;

  int get acceptedEnrollmentSamples => enrollmentSignatures.length;

  bool get enrollmentInProgress =>
      !calibrationComplete || enrollmentSignatures.isNotEmpty;

  SpeakerProfile merge(List<double> candidate, DateTime now) {
    if (candidate.length != embedding.length ||
        candidate.any((value) => !value.isFinite)) {
      return this;
    }
    final nextCount = min(sampleCount + 1, 20);
    final retainedWeight = nextCount - 1;
    final merged = List<double>.generate(
      embedding.length,
      (index) =>
          (embedding[index] * retainedWeight + candidate[index]) / nextCount,
      growable: false,
    );
    final retainedSignatures = signatures.isEmpty
        ? <List<double>>[embedding]
        : signatures;
    final nextSignatures = <List<double>>[
      ...retainedSignatures,
      normalizeSpeakerEmbedding(candidate),
    ];
    if (nextSignatures.length > maximumSpeakerSignaturesPerProfile) {
      nextSignatures.removeRange(
        0,
        nextSignatures.length - maximumSpeakerSignaturesPerProfile,
      );
    }
    return SpeakerProfile(
      id: id,
      label: label,
      embedding: normalizeSpeakerEmbedding(merged),
      signatures: nextSignatures,
      sampleCount: nextCount,
      createdAt: createdAt,
      updatedAt: now.toUtc(),
      isPrimary: isPrimary,
      signatureMatchThreshold: signatureMatchThreshold,
      calibrationComplete: calibrationComplete,
      enrollmentSignatures: enrollmentSignatures,
      historyReconciliationPending: historyReconciliationPending,
    );
  }

  SpeakerProfile copyWith({
    List<List<double>>? signatures,
    int? sampleCount,
    double? signatureMatchThreshold,
    bool? historyReconciliationPending,
  }) => SpeakerProfile(
    id: id,
    label: label,
    embedding: embedding,
    signatures: signatures ?? this.signatures,
    sampleCount: sampleCount ?? this.sampleCount,
    createdAt: createdAt,
    updatedAt: updatedAt,
    isPrimary: isPrimary,
    signatureMatchThreshold:
        signatureMatchThreshold ?? this.signatureMatchThreshold,
    calibrationComplete: calibrationComplete,
    enrollmentSignatures: enrollmentSignatures,
    historyReconciliationPending:
        historyReconciliationPending ?? this.historyReconciliationPending,
  );

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'label': label,
    'embedding': embedding,
    'signatures': signatures.isEmpty ? <List<double>>[embedding] : signatures,
    'sampleCount': sampleCount,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'isPrimary': isPrimary,
    'signatureMatchThreshold': signatureMatchThreshold,
    'calibrationComplete': calibrationComplete,
    'enrollmentSignatures': enrollmentSignatures,
    'historyReconciliationPending': historyReconciliationPending,
  };
}

/// Adds one verified single-speaker sample to a primary enrollment session.
///
/// An existing calibrated profile remains unchanged until all three update
/// samples agree. A new profile is deliberately marked incomplete so it can
/// never identify ordinary speech as `You` before calibration finishes.
SpeakerProfile acceptPrimarySpeakerEnrollmentSample({
  required SpeakerProfile? primary,
  required List<double> candidate,
  required DateTime now,
  double signatureMatchThreshold = defaultSpeakerSignatureMatchThreshold,
}) {
  if (candidate.isEmpty || candidate.any((value) => !value.isFinite)) {
    throw StateError('Enrollment did not contain a valid voice signature.');
  }
  final normalized = normalizeSpeakerEmbedding(candidate);
  if (speakerSimilarity(normalized, normalized) < 0) {
    throw StateError('Enrollment did not contain a usable voice signature.');
  }
  if (primary != null && normalized.length != primary.embedding.length) {
    throw StateError('Enrollment voice signature dimensions did not match.');
  }
  if (!isAdjustableSpeakerSignatureThreshold(signatureMatchThreshold)) {
    throw ArgumentError.value(
      signatureMatchThreshold,
      'signatureMatchThreshold',
      'The enrollment threshold is outside the adjustable range.',
    );
  }

  final priorEnrollment =
      primary?.enrollmentSignatures ?? const <List<double>>[];
  if (priorEnrollment.isEmpty && primary?.calibrationComplete == true) {
    final priorSimilarity = speakerProfileSimilarity(primary!, normalized);
    if (!speakerSignatureMatches(
      priorSimilarity,
      threshold: signatureMatchThreshold,
    )) {
      throw StateError(
        'This enrollment sample does not match the saved You signature. '
        'Reset speaker identification first if the saved signature is no longer valid.',
      );
    }
  }
  for (final prior in priorEnrollment) {
    if (!speakerSignatureMatches(
      speakerSimilarity(prior, normalized),
      threshold: signatureMatchThreshold,
    )) {
      throw StateError(
        'This enrollment sample does not match the earlier voice samples. '
        'Only the same person should speak for all three samples.',
      );
    }
  }

  final pending = <List<double>>[...priorEnrollment, normalized];
  if (pending.length < minimumPrimarySpeakerEnrollmentSamples) {
    if (primary == null) {
      return SpeakerProfile(
        id: 'primary-user',
        label: 'You',
        embedding: normalized,
        signatures: <List<double>>[normalized],
        sampleCount: 1,
        createdAt: now.toUtc(),
        updatedAt: now.toUtc(),
        isPrimary: true,
        signatureMatchThreshold: signatureMatchThreshold,
        calibrationComplete: false,
        enrollmentSignatures: pending,
      );
    }
    return SpeakerProfile(
      id: primary.id,
      label: primary.label,
      embedding: primary.embedding,
      signatures: primary.signatures,
      sampleCount: primary.sampleCount,
      createdAt: primary.createdAt,
      updatedAt: now.toUtc(),
      isPrimary: true,
      signatureMatchThreshold: signatureMatchThreshold,
      calibrationComplete: primary.calibrationComplete,
      enrollmentSignatures: pending,
    );
  }

  final calibratedThreshold = calibrateSpeakerSignatureMatchThreshold(
    pending,
    threshold: signatureMatchThreshold,
  );
  if (primary == null || !primary.calibrationComplete) {
    final centroid = normalizeSpeakerEmbedding(
      List<double>.generate(
        normalized.length,
        (index) =>
            pending.fold<double>(
              0,
              (sum, signature) => sum + signature[index],
            ) /
            pending.length,
        growable: false,
      ),
    );
    return SpeakerProfile(
      id: primary?.id ?? 'primary-user',
      label: 'You',
      embedding: centroid,
      signatures: pending,
      sampleCount: pending.length,
      createdAt: primary?.createdAt ?? now.toUtc(),
      updatedAt: now.toUtc(),
      isPrimary: true,
      signatureMatchThreshold: calibratedThreshold,
      historyReconciliationPending: true,
    );
  }

  var updated = primary;
  for (final signature in pending) {
    updated = updated.merge(signature, now);
  }
  return SpeakerProfile(
    id: updated.id,
    label: updated.label,
    embedding: updated.embedding,
    signatures: updated.signatures,
    sampleCount: updated.sampleCount,
    createdAt: updated.createdAt,
    updatedAt: now.toUtc(),
    isPrimary: true,
    signatureMatchThreshold: calibratedThreshold,
    historyReconciliationPending: true,
  );
}

double calibrateSpeakerSignatureMatchThreshold(
  List<List<double>> signatures, {
  double threshold = defaultSpeakerSignatureMatchThreshold,
}) {
  if (signatures.length < minimumPrimarySpeakerEnrollmentSamples) {
    throw ArgumentError.value(
      signatures.length,
      'signatures',
      'At least three enrollment samples are required.',
    );
  }
  if (!isAdjustableSpeakerSignatureThreshold(threshold)) {
    throw ArgumentError.value(
      threshold,
      'threshold',
      'The enrollment threshold is outside the adjustable range.',
    );
  }
  for (var left = 0; left < signatures.length; left++) {
    for (var right = left + 1; right < signatures.length; right++) {
      final similarity = speakerSimilarity(signatures[left], signatures[right]);
      if (!similarity.isFinite || similarity < 0) {
        throw ArgumentError.value(
          signatures,
          'signatures',
          'Enrollment samples must contain compatible non-zero signatures.',
        );
      }
      if (!speakerSignatureMatches(similarity, threshold: threshold)) {
        throw ArgumentError.value(
          signatures,
          'signatures',
          'Enrollment samples must pass the speaker match boundary.',
        );
      }
    }
  }
  return threshold;
}

List<SpeakerProfile> retainNonPrimarySpeakerProfiles(
  Iterable<SpeakerProfile> profiles,
) => List<SpeakerProfile>.unmodifiable(
  profiles.where((profile) => !profile.isPrimary),
);

/// Keeps one primary profile and a bounded, most-recent non-primary bank.
///
/// Profile matching runs for every finalized segment, so an unbounded bank
/// would increase both memory and analysis time indefinitely. Duplicate IDs
/// and older duplicate primary records are also removed during compaction.
List<SpeakerProfile> retainBoundedSpeakerProfiles(
  Iterable<SpeakerProfile> profiles, {
  int maximumNonPrimary = maximumNonPrimarySpeakerProfiles,
}) {
  if (maximumNonPrimary < 0) {
    throw ArgumentError.value(
      maximumNonPrimary,
      'maximumNonPrimary',
      'The maximum must not be negative.',
    );
  }
  final newestById = <String, SpeakerProfile>{};
  for (final profile in profiles) {
    final retained = newestById[profile.id];
    if (retained == null ||
        profile.updatedAt.isAfter(retained.updatedAt) ||
        (profile.updatedAt == retained.updatedAt &&
            profile.sampleCount > retained.sampleCount)) {
      newestById[profile.id] = profile;
    }
  }
  final primaries =
      newestById.values
          .where((profile) => profile.isPrimary)
          .toList(growable: false)
        ..sort(_compareSpeakerProfileRetention);
  final others =
      newestById.values
          .where((profile) => !profile.isPrimary)
          .toList(growable: false)
        ..sort(_compareSpeakerProfileRetention);
  return List<SpeakerProfile>.unmodifiable(<SpeakerProfile>[
    if (primaries.isNotEmpty) primaries.first,
    ...others.take(maximumNonPrimary),
  ]);
}

String nextNonPrimarySpeakerLabel(Iterable<SpeakerProfile> profiles) {
  final pattern = RegExp(r'^Speaker (\d+)$');
  var maximum = 1;
  for (final profile in profiles) {
    final match = pattern.firstMatch(profile.label);
    final number = match == null ? null : int.tryParse(match.group(1)!);
    if (number != null && number > maximum) {
      maximum = number;
    }
  }
  return 'Speaker ${maximum + 1}';
}

int _compareSpeakerProfileRetention(SpeakerProfile left, SpeakerProfile right) {
  final updated = right.updatedAt.compareTo(left.updatedAt);
  if (updated != 0) {
    return updated;
  }
  final samples = right.sampleCount.compareTo(left.sampleCount);
  if (samples != 0) {
    return samples;
  }
  return left.id.compareTo(right.id);
}

final class ConversationUtterance {
  const ConversationUtterance({
    required this.id,
    required this.conversationId,
    required this.speakerId,
    required this.speakerLabel,
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.confidence,
    required this.updatedAt,
    this.isPrimary = false,
    this.isOverlap = false,
    this.speakerSignature,
    this.localSpeakerId,
  });

  factory ConversationUtterance.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final conversationId = json['conversationId'];
    final speakerId = json['speakerId'];
    final speakerLabel = json['speakerLabel'];
    final text = json['text'];
    final startMs = json['startMs'];
    final endMs = json['endMs'];
    final confidence = json['confidence'];
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    final rawSpeakerSignature = json['speakerSignature'];
    if (id is! String ||
        conversationId is! String ||
        speakerId is! String ||
        speakerLabel is! String ||
        text is! String ||
        text.trim().isEmpty ||
        startMs is! int ||
        endMs is! int ||
        endMs <= startMs ||
        confidence is! num ||
        updatedAt == null) {
      throw const FormatException('The saved conversation turn is invalid.');
    }
    List<double>? speakerSignature;
    if (rawSpeakerSignature != null) {
      if (rawSpeakerSignature is! List<Object?> ||
          rawSpeakerSignature.isEmpty) {
        throw const FormatException(
          'The saved conversation speaker signature is invalid.',
        );
      }
      final values = rawSpeakerSignature
          .whereType<num>()
          .map((value) => value.toDouble())
          .toList(growable: false);
      if (values.length != rawSpeakerSignature.length ||
          values.any((value) => !value.isFinite)) {
        throw const FormatException(
          'The saved conversation speaker signature is invalid.',
        );
      }
      speakerSignature = normalizeSpeakerEmbedding(values);
    }
    return ConversationUtterance(
      id: id,
      conversationId: conversationId,
      speakerId: speakerId,
      speakerLabel: speakerLabel,
      text: text.trim(),
      startMs: startMs,
      endMs: endMs,
      confidence: confidence.toDouble().clamp(0, 1),
      updatedAt: updatedAt.toUtc(),
      isPrimary: json['isPrimary'] == true,
      isOverlap: json['isOverlap'] == true,
      speakerSignature: speakerSignature,
      localSpeakerId: json['localSpeakerId'] as String?,
    );
  }

  final String id;
  final String conversationId;
  final String speakerId;
  final String speakerLabel;
  final String text;
  final int startMs;
  final int endMs;
  final double confidence;
  final DateTime updatedAt;
  final bool isPrimary;
  final bool isOverlap;
  final List<double>? speakerSignature;
  final String? localSpeakerId;

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'conversationId': conversationId,
    'speakerId': speakerId,
    'speakerLabel': speakerLabel,
    'text': text,
    'startMs': startMs,
    'endMs': endMs,
    'confidence': confidence,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'isPrimary': isPrimary,
    'isOverlap': isOverlap,
    'speakerSignature': ?speakerSignature,
    'localSpeakerId': ?localSpeakerId,
  };
}

final class ConversationRecord {
  const ConversationRecord({
    required this.id,
    required this.audioPath,
    required this.textPath,
    required this.metadataPath,
    required this.utterances,
    required this.updatedAt,
    this.speakerIdentificationVersion = 0,
    this.speakerProfileRevision,
  });

  factory ConversationRecord.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final audioPath = json['audioPath'];
    final textPath = json['textPath'];
    final metadataPath = json['metadataPath'];
    final utterances = json['utterances'];
    final updatedAt = DateTime.tryParse('${json['updatedAt']}');
    if (id is! String ||
        audioPath is! String ||
        textPath is! String ||
        metadataPath is! String ||
        utterances is! List<Object?> ||
        updatedAt == null) {
      throw const FormatException('The saved conversation record is invalid.');
    }
    return ConversationRecord(
      id: id,
      audioPath: audioPath,
      textPath: textPath,
      metadataPath: metadataPath,
      utterances: utterances
          .whereType<Map<Object?, Object?>>()
          .map(
            (value) => ConversationUtterance.fromJson(
              value.map((key, value) => MapEntry('$key', value)),
            ),
          )
          .toList(growable: false),
      updatedAt: updatedAt.toUtc(),
      speakerIdentificationVersion:
          json['speakerIdentificationVersion'] as int? ?? 0,
      speakerProfileRevision: json['speakerProfileRevision'] as String?,
    );
  }

  final String id;
  final String audioPath;
  final String textPath;
  final String metadataPath;
  final List<ConversationUtterance> utterances;
  final DateTime updatedAt;
  final int speakerIdentificationVersion;
  final String? speakerProfileRevision;

  Map<String, Object> toJson() => <String, Object>{
    'version': 1,
    if (speakerIdentificationVersion > 0)
      'speakerIdentificationVersion': speakerIdentificationVersion,
    'speakerProfileRevision': ?speakerProfileRevision,
    'id': id,
    'audioPath': audioPath,
    'textPath': textPath,
    'metadataPath': metadataPath,
    'utterances': utterances
        .map((utterance) => utterance.toJson())
        .toList(growable: false),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

String encodeConversationText(Iterable<ConversationUtterance> utterances) =>
    '${utterances.map((utterance) {
      final start = (utterance.startMs / 1000).toStringAsFixed(2);
      final end = (utterance.endMs / 1000).toStringAsFixed(2);
      return '${utterance.speakerLabel} [$start–$end]\n${utterance.text}';
    }).join('\n\n')}\n';

double speakerSimilarity(List<double> left, List<double> right) {
  if (left.isEmpty || left.length != right.length) {
    return -1;
  }
  var dot = 0.0;
  var leftSquare = 0.0;
  var rightSquare = 0.0;
  for (var index = 0; index < left.length; index++) {
    dot += left[index] * right[index];
    leftSquare += left[index] * left[index];
    rightSquare += right[index] * right[index];
  }
  if (leftSquare <= 0 || rightSquare <= 0) {
    return -1;
  }
  return dot / sqrt(leftSquare * rightSquare);
}

double speakerProfileSimilarity(
  SpeakerProfile profile,
  List<double> candidate,
) {
  var best = speakerSimilarity(profile.embedding, candidate);
  for (final signature in profile.signatures) {
    best = max(best, speakerSimilarity(signature, candidate));
  }
  return best;
}

double speakerProfilesSimilarity(SpeakerProfile left, SpeakerProfile right) {
  final leftSignatures = left.signatures.isEmpty
      ? <List<double>>[left.embedding]
      : left.signatures;
  final rightSignatures = right.signatures.isEmpty
      ? <List<double>>[right.embedding]
      : right.signatures;
  var best = speakerSimilarity(left.embedding, right.embedding);
  for (final leftSignature in leftSignatures) {
    for (final rightSignature in rightSignatures) {
      best = max(best, speakerSimilarity(leftSignature, rightSignature));
    }
  }
  return best;
}

SpeakerProfile consolidatePrimarySpeakerProfiles(
  SpeakerProfile primary,
  Iterable<SpeakerProfile> matches,
) {
  final matched = matches.toList(growable: false)
    ..sort((left, right) => left.updatedAt.compareTo(right.updatedAt));
  final retained = <List<double>>[
    for (final profile in matched)
      ...(profile.signatures.isEmpty
          ? <List<double>>[profile.embedding]
          : profile.signatures),
    ...(primary.signatures.isEmpty
        ? <List<double>>[primary.embedding]
        : primary.signatures),
  ];
  if (retained.length > maximumSpeakerSignaturesPerProfile) {
    retained.removeRange(
      0,
      retained.length - maximumSpeakerSignaturesPerProfile,
    );
  }
  final sampleCount = min(
    20,
    primary.sampleCount +
        matched.fold<int>(0, (sum, value) => sum + value.sampleCount),
  );
  return primary.copyWith(
    signatures: retained,
    sampleCount: sampleCount,
    historyReconciliationPending: false,
  );
}

bool isValidSpeakerSignatureThreshold(double threshold) =>
    threshold.isFinite && threshold > 0 && threshold <= 1;

bool isAdjustableSpeakerSignatureThreshold(double threshold) =>
    threshold.isFinite &&
    threshold >= minimumAdjustableSpeakerSignatureMatchThreshold &&
    threshold <= maximumAdjustableSpeakerSignatureMatchThreshold;

double normalizeAdjustableSpeakerSignatureThreshold(double threshold) {
  final clamped = threshold.clamp(
    minimumAdjustableSpeakerSignatureMatchThreshold,
    maximumAdjustableSpeakerSignatureMatchThreshold,
  );
  return (clamped * 100).roundToDouble() / 100;
}

bool speakerSignatureMatches(
  double similarity, {
  double threshold = defaultSpeakerSignatureMatchThreshold,
}) {
  if (!isValidSpeakerSignatureThreshold(threshold)) {
    throw ArgumentError.value(
      threshold,
      'threshold',
      'The signature threshold must be greater than 0 and at most 1.',
    );
  }
  return similarity.isFinite && similarity >= threshold;
}

List<double> normalizeSpeakerEmbedding(List<double> values) {
  var squareSum = 0.0;
  for (final value in values) {
    squareSum += value * value;
  }
  if (squareSum <= 0) {
    return List<double>.from(values, growable: false);
  }
  final magnitude = sqrt(squareSum);
  return values.map((value) => value / magnitude).toList(growable: false);
}
