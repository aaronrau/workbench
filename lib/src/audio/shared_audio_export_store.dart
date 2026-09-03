import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'conversation_models.dart';

final class SharedAudioFolder {
  const SharedAudioFolder({required this.displayName});

  final String displayName;
}

final class SharedTranscript {
  const SharedTranscript({
    required this.id,
    required this.originalText,
    required this.updatedAt,
    this.correctedText,
    this.audioFileName,
  });

  final String id;
  final String originalText;
  final String? correctedText;
  final DateTime updatedAt;
  final String? audioFileName;

  bool get hasAudio => audioFileName != null;
  bool get hasCorrection => correctedText != null;
  String get text => correctedText ?? originalText;
}

enum SharedWebSocketMessageDirection {
  sent,
  received;

  String get label => switch (this) {
    sent => 'Sent',
    received => 'Received',
  };
}

final class SharedWebSocketMessage {
  const SharedWebSocketMessage({
    required this.id,
    required this.direction,
    required this.text,
    required this.updatedAt,
  });

  final String id;
  final SharedWebSocketMessageDirection direction;
  final String text;
  final DateTime updatedAt;
}

final class SharedConversationTurn {
  const SharedConversationTurn({
    required this.id,
    required this.conversationId,
    required this.speakerId,
    required this.speakerLabel,
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.confidence,
    required this.updatedAt,
    required this.isPrimary,
    required this.isOverlap,
  });

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
}

final class SharedAudioExportStore extends ChangeNotifier {
  static const String correctionPromptFileName =
      'workbench-correction-prompt.txt';
  static const String agentServerSettingsFileName =
      'workbench-agent-servers.json';
  static const String speakerSignatureRecoveryFileName =
      'workbench-speaker-signatures.wbprofiles';
  static const int maximumVisibleTranscripts = 100;
  static const int maximumVisibleMessages = 100;
  static const int maximumVisibleConversationTurns = 100;

  SharedAudioExportStore({
    MethodChannel channel = const MethodChannel(
      'dev.opensourceglasses/workbench_storage',
    ),
    bool? isAndroid,
  }) : _channel = channel,
       _isAndroid = isAndroid ?? Platform.isAndroid {
    if (_isAndroid) {
      _channel.setMethodCallHandler(_handlePlatformCall);
    }
  }

  final MethodChannel _channel;
  final bool _isAndroid;

  SharedAudioFolder? folder;
  List<SharedTranscript> transcripts = const <SharedTranscript>[];
  List<SharedWebSocketMessage> messages = const <SharedWebSocketMessage>[];
  List<SharedConversationTurn> conversations = const <SharedConversationTurn>[];
  bool isLoadingTranscripts = false;
  bool isLoadingMessages = false;
  bool isLoadingConversations = false;
  String? transcriptLoadError;
  String? messageLoadError;
  String? conversationLoadError;
  String? playingAudioFileName;

  bool get isSupported => _isAndroid;
  bool get hasSharedFolder => folder != null;

  Future<void> initialize() async {
    if (!_isAndroid) {
      return;
    }
    folder = _folderFromMessage(
      await _channel.invokeMapMethod<String, Object?>('currentDirectory'),
    );
  }

  Future<SharedAudioFolder?> chooseFolder() async {
    if (!_isAndroid) {
      throw UnsupportedError(
        'Shared audio folders are currently available on Android.',
      );
    }
    final selected = _folderFromMessage(
      await _channel.invokeMapMethod<String, Object?>('chooseDirectory'),
    );
    if (selected != null) {
      folder = selected;
      transcripts = const <SharedTranscript>[];
      messages = const <SharedWebSocketMessage>[];
      transcriptLoadError = null;
      messageLoadError = null;
      notifyListeners();
    }
    return selected;
  }

  Future<void> clearFolder() async {
    if (!_isAndroid) {
      return;
    }
    await stopAudio();
    await _channel.invokeMethod<void>('clearDirectory');
    folder = null;
    transcripts = const <SharedTranscript>[];
    messages = const <SharedWebSocketMessage>[];
    transcriptLoadError = null;
    messageLoadError = null;
    notifyListeners();
  }

  Future<int> exportFiles(Iterable<String> paths) async {
    if (!_isAndroid || folder == null) {
      return 0;
    }
    final stablePaths = paths
        .where(_isShareablePath)
        .toSet()
        .toList(growable: false);
    if (stablePaths.isEmpty) {
      return 0;
    }
    final exported = await _channel.invokeMethod<int>(
      'exportFiles',
      <String, Object>{'paths': stablePaths},
    );
    return exported ?? 0;
  }

  Future<void> indexConversation(ConversationRecord record) =>
      indexConversations(<ConversationRecord>[record]);

  Future<void> indexConversations(Iterable<ConversationRecord> records) async {
    final retained = records
        .where((record) => record.utterances.isNotEmpty)
        .toList(growable: false);
    if (retained.isEmpty) {
      return;
    }
    if (!_isAndroid) {
      final conversationIds = retained.map((record) => record.id).toSet();
      final updated = <SharedConversationTurn>[
        ...conversations.where(
          (turn) => !conversationIds.contains(turn.conversationId),
        ),
        for (final record in retained)
          ...record.utterances.map(_conversationFromUtterance),
      ]..sort(_compareConversationTurns);
      conversations = _latestConversationTurns(updated);
      notifyListeners();
      return;
    }
    const maximumBatchTurns = 200;
    var batch = <Map<String, Object>>[];
    Future<void> flush() async {
      if (batch.isEmpty) {
        return;
      }
      await _channel.invokeMethod<void>('indexConversation', <String, Object>{
        'turns': batch,
      });
      batch = <Map<String, Object>>[];
    }

    for (final record in retained) {
      final turns = record.utterances.map(_conversationIndexEntry).toList();
      if (batch.isNotEmpty && batch.length + turns.length > maximumBatchTurns) {
        await flush();
      }
      batch.addAll(turns);
    }
    await flush();
    await refreshConversations();
  }

  Future<void> refreshConversations() async {
    if (!_isAndroid) {
      conversationLoadError = null;
      return;
    }
    isLoadingConversations = true;
    conversationLoadError = null;
    notifyListeners();
    try {
      final records =
          await _channel.invokeMethod<List<Object?>>('listConversations') ??
          const <Object?>[];
      final loaded =
          records
              .whereType<Map<Object?, Object?>>()
              .map(_conversationFromRecord)
              .whereType<SharedConversationTurn>()
              .toList(growable: false)
            ..sort(_compareConversationTurns);
      conversations = _latestConversationTurns(loaded);
    } catch (_) {
      conversationLoadError =
          'Could not read saved conversations. Retry or keep recording.';
      rethrow;
    } finally {
      isLoadingConversations = false;
      notifyListeners();
    }
  }

  Future<String?> readCorrectionInstructions() async {
    if (!_isAndroid || folder == null) {
      return null;
    }
    return _channel.invokeMethod<String>('readCorrectionInstructions');
  }

  Future<void> writeCorrectionInstructions(String instructions) async {
    if (!_isAndroid || folder == null) {
      throw StateError('Choose a shared folder before saving instructions.');
    }
    await _channel.invokeMethod<void>(
      'writeCorrectionInstructions',
      <String, Object>{'instructions': instructions},
    );
  }

  Future<String?> readAgentServerSettings() async {
    if (!_isAndroid || folder == null) {
      return null;
    }
    return _channel.invokeMethod<String>('readAgentServerSettings');
  }

  Future<void> writeAgentServerSettings(String settings) async {
    if (!_isAndroid || folder == null) {
      throw StateError('Choose a shared folder before saving server settings.');
    }
    await _channel.invokeMethod<void>(
      'writeAgentServerSettings',
      <String, Object>{'settings': settings},
    );
  }

  Future<Uint8List?> readSpeakerSignatureRecovery() async {
    if (!_isAndroid || folder == null) {
      return null;
    }
    return _channel.invokeMethod<Uint8List>('readSpeakerSignatureRecovery');
  }

  Future<void> writeSpeakerSignatureRecovery(Uint8List recovery) async {
    if (!_isAndroid || folder == null) {
      throw StateError(
        'Choose a shared folder before saving speaker signatures.',
      );
    }
    await _channel.invokeMethod<void>(
      'writeSpeakerSignatureRecovery',
      <String, Object>{'recovery': recovery},
    );
  }

  Future<List<String>> suggestAgentNames() async {
    if (!_isAndroid || folder == null) {
      return const <String>[];
    }
    final names =
        await _channel.invokeMethod<List<Object?>>('suggestAgentNames') ??
        const <Object?>[];
    return names.whereType<String>().toList(growable: false);
  }

  Future<void> refreshTranscriptions({bool reconcileShared = false}) async {
    if (!_isAndroid || folder == null) {
      transcripts = const <SharedTranscript>[];
      transcriptLoadError = null;
      notifyListeners();
      return;
    }
    isLoadingTranscripts = true;
    transcriptLoadError = null;
    notifyListeners();
    try {
      final messages =
          await _channel.invokeMethod<List<Object?>>(
            'listTranscriptions',
            <String, Object>{'reconcileShared': reconcileShared},
          ) ??
          const <Object?>[];
      final loaded = messages
          .whereType<Map<Object?, Object?>>()
          .map(_transcriptFromMessage)
          .whereType<SharedTranscript>()
          .toList(growable: false);
      loaded.sort((left, right) {
        final byTime = right.updatedAt.compareTo(left.updatedAt);
        return byTime != 0 ? byTime : right.id.compareTo(left.id);
      });
      transcripts = loaded
          .take(maximumVisibleTranscripts)
          .toList(growable: false);
    } catch (_) {
      transcriptLoadError =
          'Could not read the selected folder. Choose it again or retry.';
      rethrow;
    } finally {
      isLoadingTranscripts = false;
      notifyListeners();
    }
  }

  Future<void> refreshMessages({bool reconcileShared = false}) async {
    if (!_isAndroid || folder == null) {
      messages = const <SharedWebSocketMessage>[];
      messageLoadError = null;
      notifyListeners();
      return;
    }
    isLoadingMessages = true;
    messageLoadError = null;
    notifyListeners();
    try {
      final records =
          await _channel.invokeMethod<List<Object?>>(
            'listMessages',
            <String, Object>{'reconcileShared': reconcileShared},
          ) ??
          const <Object?>[];
      final loaded = records
          .whereType<Map<Object?, Object?>>()
          .map(_messageFromRecord)
          .whereType<SharedWebSocketMessage>()
          .toList(growable: false);
      loaded.sort((left, right) {
        final byTime = right.updatedAt.compareTo(left.updatedAt);
        return byTime != 0 ? byTime : right.id.compareTo(left.id);
      });
      messages = loaded.take(maximumVisibleMessages).toList(growable: false);
    } catch (_) {
      messageLoadError =
          'Could not read saved messages. Choose the folder again or retry.';
      rethrow;
    } finally {
      isLoadingMessages = false;
      notifyListeners();
    }
  }

  Future<void> toggleAudio(SharedTranscript transcript) async {
    final audioFileName = transcript.audioFileName;
    if (!_isAndroid || audioFileName == null) {
      return;
    }
    if (playingAudioFileName == audioFileName) {
      await stopAudio();
      return;
    }
    playingAudioFileName = audioFileName;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('playAudio', <String, Object>{
        'fileName': audioFileName,
      });
    } catch (_) {
      if (playingAudioFileName == audioFileName) {
        playingAudioFileName = null;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> stopAudio() async {
    if (!_isAndroid || playingAudioFileName == null) {
      return;
    }
    await _channel.invokeMethod<void>('stopAudio');
    playingAudioFileName = null;
    notifyListeners();
  }

  SharedAudioFolder? _folderFromMessage(Map<String, Object?>? message) {
    final displayName = message?['displayName'];
    if (displayName is! String || displayName.trim().isEmpty) {
      return null;
    }
    return SharedAudioFolder(displayName: displayName.trim());
  }

  SharedTranscript? _transcriptFromMessage(Map<Object?, Object?> message) {
    final id = message['id'];
    final originalText = message['originalText'];
    final correctedText = message['correctedText'];
    final updatedAtMillis = message['updatedAtMillis'];
    if (id is! String ||
        id.trim().isEmpty ||
        originalText is! String ||
        originalText.trim().isEmpty ||
        updatedAtMillis is! int) {
      return null;
    }
    final audioFileName = message['audioFileName'];
    return SharedTranscript(
      id: id.trim(),
      originalText: originalText.trim(),
      correctedText: correctedText is String && correctedText.trim().isNotEmpty
          ? correctedText.trim()
          : null,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMillis),
      audioFileName: audioFileName is String && audioFileName.trim().isNotEmpty
          ? audioFileName.trim()
          : null,
    );
  }

  SharedWebSocketMessage? _messageFromRecord(Map<Object?, Object?> message) {
    final id = message['id'];
    final directionName = message['direction'];
    final text = message['text'];
    final updatedAtMillis = message['updatedAtMillis'];
    final direction = switch (directionName) {
      'sent' => SharedWebSocketMessageDirection.sent,
      'received' => SharedWebSocketMessageDirection.received,
      _ => null,
    };
    if (id is! String ||
        id.trim().isEmpty ||
        direction == null ||
        text is! String ||
        text.trim().isEmpty ||
        updatedAtMillis is! int) {
      return null;
    }
    return SharedWebSocketMessage(
      id: id.trim(),
      direction: direction,
      text: text.trim(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMillis),
    );
  }

  SharedConversationTurn? _conversationFromRecord(
    Map<Object?, Object?> message,
  ) {
    final id = message['id'];
    final conversationId = message['conversationId'];
    final speakerId = message['speakerId'];
    final speakerLabel = message['speakerLabel'];
    final text = message['text'];
    final startMs = message['startMs'];
    final endMs = message['endMs'];
    final confidence = message['confidence'];
    final updatedAtMillis = message['updatedAtMillis'];
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
        updatedAtMillis is! int) {
      return null;
    }
    return SharedConversationTurn(
      id: id,
      conversationId: conversationId,
      speakerId: speakerId,
      speakerLabel: speakerLabel,
      text: text.trim(),
      startMs: startMs,
      endMs: endMs,
      confidence: confidence.toDouble().clamp(0, 1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMillis),
      isPrimary: message['isPrimary'] == true,
      isOverlap: message['isOverlap'] == true,
    );
  }

  SharedConversationTurn _conversationFromUtterance(
    ConversationUtterance utterance,
  ) => SharedConversationTurn(
    id: utterance.id,
    conversationId: utterance.conversationId,
    speakerId: utterance.speakerId,
    speakerLabel: utterance.speakerLabel,
    text: utterance.text,
    startMs: utterance.startMs,
    endMs: utterance.endMs,
    confidence: utterance.confidence,
    updatedAt: utterance.updatedAt,
    isPrimary: utterance.isPrimary,
    isOverlap: utterance.isOverlap,
  );

  Map<String, Object> _conversationIndexEntry(
    ConversationUtterance utterance,
  ) => <String, Object>{
    'id': utterance.id,
    'conversationId': utterance.conversationId,
    'speakerId': utterance.speakerId,
    'speakerLabel': utterance.speakerLabel,
    'text': utterance.text,
    'startMs': utterance.startMs,
    'endMs': utterance.endMs,
    'confidence': utterance.confidence,
    'updatedAtMillis': utterance.updatedAt.millisecondsSinceEpoch,
    'isPrimary': utterance.isPrimary,
    'isOverlap': utterance.isOverlap,
  };

  Future<void> _handlePlatformCall(MethodCall call) async {
    if (call.method != 'playbackCompleted') {
      return;
    }
    final arguments = call.arguments;
    final fileName = arguments is Map<Object?, Object?>
        ? arguments['fileName']
        : null;
    if (fileName == playingAudioFileName) {
      playingAudioFileName = null;
      notifyListeners();
    }
  }

  bool _isShareablePath(String path) {
    final lower = path.toLowerCase();
    return (lower.endsWith('.wav') || lower.endsWith('.txt')) &&
        !lower.endsWith('.part.wav') &&
        !lower.endsWith('.part.txt');
  }

  static int _compareConversationTurns(
    SharedConversationTurn left,
    SharedConversationTurn right,
  ) {
    final byTime = left.updatedAt.compareTo(right.updatedAt);
    if (byTime != 0) {
      return byTime;
    }
    final byConversation = left.conversationId.compareTo(right.conversationId);
    return byConversation != 0
        ? byConversation
        : left.startMs.compareTo(right.startMs);
  }

  static List<SharedConversationTurn> _latestConversationTurns(
    List<SharedConversationTurn> turns,
  ) {
    if (turns.length <= maximumVisibleConversationTurns) {
      return List<SharedConversationTurn>.unmodifiable(turns);
    }
    return List<SharedConversationTurn>.unmodifiable(
      turns.sublist(turns.length - maximumVisibleConversationTurns),
    );
  }

  Future<void> _stopAudioForDispose() async {
    try {
      await _channel.invokeMethod<void>('stopAudio');
    } catch (_) {
      // The Flutter engine may already be detaching during app shutdown.
    }
  }

  @override
  void dispose() {
    if (_isAndroid) {
      if (playingAudioFileName != null) {
        unawaited(_stopAudioForDispose());
      }
      playingAudioFileName = null;
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
