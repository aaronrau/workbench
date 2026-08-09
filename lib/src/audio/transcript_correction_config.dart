import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

typedef SharedCorrectionInstructionsAvailable = bool Function();
typedef SharedCorrectionInstructionsReader = Future<String?> Function();
typedef SharedCorrectionInstructionsWriter =
    Future<void> Function(String instructions);

const _legacyTranscriptCorrectionInstructions =
    'You correct short automatic speech recognition transcripts from smart '
    'glasses and return only corrected text. Preserve the speaker’s meaning '
    'and requested action. Correct obvious phonetic errors, command names, '
    'verbs, capitalization, punctuation, and light grammar. A leading local '
    'command name or attention word may be dropped or misheard. Use only the '
    'known command names and acoustic aliases supplied after these instructions; '
    'never invent a name. Restore a name only when the remaining words form a '
    'plausible imperative. With Flux supplied as a known name, for example, '
    '"Plus, all the latest changes." becomes "Flux, pull the latest changes." '
    'Ordinary prose such as "Plus, this is already complete." stays ordinary '
    'prose. Preserve numbers, paths, flags, identifiers, and uncertainty. Do '
    'not summarize, remove requested actions, add facts, answer the transcript, '
    'or use markdown.';

const _previousAgentRoutingPolicy =
    'In routing position before an engineering command, rewrite "flex" or '
    '"fox" as "Flux", "block" or "brook" as "Brock", "pipe" as "Pike", '
    'and "wolfe" as "Wolf". Do not rewrite an ordinary reference to a fox. ';

const _currentAgentRoutingPolicy =
    'Only after a leading attention word "Hey", rewrite "flex" or "fox" as '
    '"Flux", "block" or "brook" as "Brock", "pipe" as "Pike", and "wolfe" '
    'as "Wolf". Never promote a bare alias into an agent invocation. Do not '
    'rewrite an ordinary reference to a fox. ';

const _latestChangesCorrectionPolicy =
    'In a repository update command, rewrite "ladies changes" as "latest '
    'changes" when the sentence clearly means the most recent changes. ';

const defaultTranscriptCorrectionInstructions =
    'You clean short ASR transcript chunks from smart glasses. Fix obvious '
    'speech recognition errors, capitalization, punctuation, and light grammar '
    'only. Preserve these established pronunciation corrections in every '
    'transcript: Always rewrite every occurrence of "length view", "lang fuse", '
    '"land fuse", "ling few", "lane view", and "lanefuse" as "Langfuse". '
    'Rewrite "code x", "condex", "codec", and "kodex" as "Codex" when '
    'referring to the coding agent or product. Rewrite "yaws", "evalues", '
    '"e values", "e vals", and "evals" as "EVALS" when referring to the '
    'evaluation system. Treat Simcha and simcha.ai as fixed product and domain '
    'names. When context clearly refers to the Simcha product, company, app, '
    'login, or email domain, rewrite observed sound-alikes such as Semcha, '
    'Symtra, Simchot, Simchad, sim chat, asim chat, SMCAT, and their .ai forms '
    'as Simcha or simcha.ai as appropriate. When software, testing, integration, '
    'or workflow context clearly means complete-path coverage, rewrite ASR '
    'variants such as "N to N", "N two N", "end to N", "N to end", '
    '"end two end", and "E to E" as "end-to-end". Do not rewrite literal '
    'letters, ranges, or unrelated uses. Preserve the speaker\'s meaning and '
    'wording. Do not remove command words after a routing target; keep '
    '"Wolf terminate session" as "Wolf terminate session", not "Wolf". Do not '
    'add facts, commands, explanations, or markdown. If uncertain, keep the '
    'original wording. Return only the cleaned transcript text. When the '
    'transcript addresses a known local AI coding agent supplied after these '
    'instructions, begin the cleaned transcript with its canonical target name '
    'and omit only greetings or filler that precede that target. Treat the '
    'remaining speech as an engineering task or planning prompt. '
    '$_currentAgentRoutingPolicy'
    'When the audio '
    'supports it, prefer common coding actions and terms such as analyze, '
    'inspect, search, plan, implement, fix, refactor, update, debug, reproduce, '
    'verify, run, test, build, lint, type-check, commit, push, pull, branch, '
    'pull request, issue, ticket, repository, worktree, terminal, shell, '
    'dependency, endpoint, API, prompt, trace, and logs, and technical names '
    'such as Codex, tmux, Git, GitHub, Langfuse, npm, pnpm, pytest, Docker, GPT, '
    'Linear, Datadog, and EVALS. '
    '$_latestChangesCorrectionPolicy'
    'Preserve the requested order, scope, constraints, existing filenames, '
    'paths, flags, explicitly dictated exact '
    'identifiers, versions, and polite command phrasing such as "can you", '
    '"please", and "make sure". When the speaker asks the agent to create or '
    'rename something, correct supported ASR mistakes inside the requested new '
    'title or identifier too; do not preserve a mishearing merely because it '
    'appears after "called" or "named". For an agent prompt, remove filler and '
    'false starts, collapse accidental repeated words, and repair obvious '
    'grammar so the instruction is coherent, while retaining every requested '
    'action and constraint. Never summarize, shorten, or omit an informational '
    'clause. The cleaned transcript must retain every goal, action, condition, '
    'sequence, and requested validation from the raw transcript. If a grammar '
    'repair might lose meaning, keep the awkward wording instead. Correct only '
    'context-supported ASR mistakes; do not improve the plan, invent steps, '
    'execute the task, or turn uncertain speech into a command. When "N to N" '
    'directly modifies conversation flow, test, workflow, or coverage, rewrite '
    'every such occurrence as "end-to-end", including as "End-to-End" inside a '
    'new title the speaker is asking the agent to create. After an agent target, '
    'rewrite the session-control sound-alikes "Claire session", "Clare session", '
    'and "clean session" as "clear session"; the word "session" must already be '
    'present. In an AI model or conversation-simulation context, rewrite "GBT" '
    'as "GPT". Rewrite "in PM" as "npm" when it directly precedes a package '
    'command such as test, install, run, or build. Rewrite "get status" and '
    '"get diff" as "git status" and "git diff" in repository context. Rewrite '
    '"hen all the chains push to death" and "did all the change got pushed to '
    'dev" as "did all the changes get pushed to dev". Repair "make sure that '
    'is successfully able to" as "make sure it can successfully". Otherwise '
    'repair "is successfully able to" as "can successfully" only when the '
    'original subject remains in the sentence. Use these guarded coding-context '
    'examples: Raw: "Hey Pipe, make an imp lamentation plan, then run get '
    'status and in PM test." Cleaned: "Pike, make an implementation plan, then '
    'run git status and npm test." Raw: "Hey Flux, can you create an N to N '
    'conversation flow test? Specifically a new one called N to N Conversation '
    'Flow Workshop Test. The goal is to connect to the workshop and create a '
    'workshop. Make sure it passes all workshop guides." Cleaned: "Flux, can '
    'you create an end-to-end conversation flow test? Specifically, a new one '
    'called End-to-End Conversation Flow Workshop Test. The goal is to connect '
    'to the workshop and create a workshop. Make sure it passes all workshop '
    'guides." Raw: "Hey Flux, can you pull the latest changes, make sure '
    'everything is at the dive branch, and clean any wood trees that are not '
    'there?" Cleaned: "Flux, can you pull the latest changes, make sure '
    'everything is on the dev branch, and clean up any worktrees that are not '
    'there?" Raw: "Hey Brock. Claire session." Cleaned: "Brock, clear '
    'session." Raw: "Hey Fox, use code x to inspect the length view traces and '
    'update the e values test." Cleaned: "Flux, use Codex to inspect the '
    'Langfuse traces and update the EVALS test."';

final class TranscriptCorrectionConfig {
  const TranscriptCorrectionConfig({
    required this.enabled,
    required this.instructions,
    this.modelId = 'gemma-4-e4b-it',
    this.backend = 'gpu',
    this.timeoutMs = 30000,
  });

  static const int schemaVersion = 1;
  static const int maximumInstructionCharacters = 10000;
  static const int minimumTimeoutMs = 5000;
  static const int maximumTimeoutMs = 120000;

  static const defaults = TranscriptCorrectionConfig(
    enabled: true,
    instructions: defaultTranscriptCorrectionInstructions,
  );

  final bool enabled;
  final String instructions;
  final String modelId;
  final String backend;
  final int timeoutMs;

  TranscriptCorrectionConfig copyWith({
    bool? enabled,
    String? instructions,
    String? modelId,
    String? backend,
    int? timeoutMs,
  }) => TranscriptCorrectionConfig(
    enabled: enabled ?? this.enabled,
    instructions: instructions ?? this.instructions,
    modelId: modelId ?? this.modelId,
    backend: backend ?? this.backend,
    timeoutMs: timeoutMs ?? this.timeoutMs,
  );

  Map<String, Object> toJson() => <String, Object>{
    'version': schemaVersion,
    'transcriptCorrection': <String, Object>{
      'enabled': enabled,
      'model': modelId,
      'backend': backend,
      'timeoutMs': timeoutMs,
      'instructions': instructions,
    },
  };

  static TranscriptCorrectionConfig fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('config.json must contain a JSON object.');
    }
    if (value['version'] != schemaVersion) {
      throw const FormatException('config.json version must be 1.');
    }
    final correction = value['transcriptCorrection'];
    if (correction is! Map<String, dynamic>) {
      throw const FormatException(
        'config.json must contain transcriptCorrection settings.',
      );
    }
    final enabled = correction['enabled'];
    final instructions = correction['instructions'];
    final model = correction['model'];
    final backend = correction['backend'];
    final timeoutMs = correction['timeoutMs'];
    if (enabled is! bool ||
        instructions is! String ||
        model is! String ||
        backend is! String ||
        timeoutMs is! int) {
      throw const FormatException(
        'Transcript correction settings have invalid value types.',
      );
    }
    if (model != 'gemma-4-e4b-it') {
      throw const FormatException(
        'Only the verified gemma-4-e4b-it model is supported.',
      );
    }
    if (backend != 'gpu') {
      throw const FormatException(
        'Transcript correction must use the fail-closed GPU backend.',
      );
    }
    if (timeoutMs < minimumTimeoutMs || timeoutMs > maximumTimeoutMs) {
      throw const FormatException(
        'Correction timeout must be between 5000 and 120000 milliseconds.',
      );
    }
    return TranscriptCorrectionConfig(
      enabled: enabled,
      instructions: validateInstructions(instructions),
      modelId: model,
      backend: backend,
      timeoutMs: timeoutMs,
    );
  }

  static String validateInstructions(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('LLM instructions cannot be empty.');
    }
    if (trimmed.length > maximumInstructionCharacters) {
      throw const FormatException(
        'LLM instructions cannot exceed 10000 characters.',
      );
    }
    for (final rune in trimmed.runes) {
      final allowedWhitespace = rune == 0x09 || rune == 0x0A || rune == 0x0D;
      if (rune < 0x20 && !allowedWhitespace) {
        throw const FormatException(
          'LLM instructions contain an unsupported control character.',
        );
      }
    }
    return trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is TranscriptCorrectionConfig &&
      other.enabled == enabled &&
      other.instructions == instructions &&
      other.modelId == modelId &&
      other.backend == backend &&
      other.timeoutMs == timeoutMs;

  @override
  int get hashCode =>
      Object.hash(enabled, instructions, modelId, backend, timeoutMs);
}

final class TranscriptCorrectionConfigStore extends ChangeNotifier {
  TranscriptCorrectionConfigStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
    SharedCorrectionInstructionsAvailable? sharedInstructionsAvailable,
    SharedCorrectionInstructionsReader? sharedInstructionsReader,
    SharedCorrectionInstructionsWriter? sharedInstructionsWriter,
    this.sharedInstructionsTimeout = const Duration(seconds: 5),
  }) : _supportDirectory = supportDirectory,
       _sharedInstructionsAvailable = sharedInstructionsAvailable,
       _sharedInstructionsReader = sharedInstructionsReader,
       _sharedInstructionsWriter = sharedInstructionsWriter;

  final Future<Directory> Function() _supportDirectory;
  final SharedCorrectionInstructionsAvailable? _sharedInstructionsAvailable;
  final SharedCorrectionInstructionsReader? _sharedInstructionsReader;
  final SharedCorrectionInstructionsWriter? _sharedInstructionsWriter;
  final Duration sharedInstructionsTimeout;
  File? _file;
  Future<void> _operationTail = Future<void>.value();

  TranscriptCorrectionConfig config = TranscriptCorrectionConfig.defaults;
  String? validationError;

  Future<void> initialize() => _serialize(_initialize);

  Future<void> _initialize() async {
    final support = await _supportDirectory();
    final workbench = Directory('${support.path}/workbench');
    await workbench.create(recursive: true);
    _file = File('${workbench.path}/config.json');
    if (!await _file!.exists()) {
      await _write(config);
    } else {
      await _reloadPrivateConfig();
    }
    await _reloadSharedInstructions();
  }

  Future<TranscriptCorrectionConfig> reloadForNextTranscript() =>
      _serialize(() async {
        await _reloadPrivateConfig();
        await _reloadSharedInstructions();
        return config;
      });

  Future<void> _reloadPrivateConfig() async {
    final file = _file;
    if (file == null) {
      throw StateError(
        'Transcript correction configuration is not initialized.',
      );
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      var loaded = TranscriptCorrectionConfig.fromJson(decoded);
      if (_isLegacyTranscriptCorrectionInstructions(loaded.instructions)) {
        loaded = loaded.copyWith(
          instructions: defaultTranscriptCorrectionInstructions,
        );
        await _write(loaded);
      }
      final changed = loaded != config || validationError != null;
      config = loaded;
      validationError = null;
      if (changed) {
        notifyListeners();
      }
    } on Object catch (error) {
      final message = _oneLine(error);
      if (validationError != message) {
        validationError = message;
        notifyListeners();
      }
      // The last validated snapshot remains active. A partial or externally
      // malformed config can never inject an unvalidated prompt into a job.
    }
  }

  Future<void> saveInstructions(String instructions) => _serialize(() async {
    final validated = TranscriptCorrectionConfig.validateInstructions(
      instructions,
    );
    final updated = config.copyWith(instructions: validated);
    if (_hasSharedInstructions) {
      await _sharedInstructionsWriter!(
        validated,
      ).timeout(sharedInstructionsTimeout);
    }
    await _write(updated);
    config = updated;
    validationError = null;
    notifyListeners();
  });

  Future<void> setEnabled(bool enabled) => _serialize(() async {
    final updated = config.copyWith(enabled: enabled);
    await _write(updated);
    config = updated;
    validationError = null;
    notifyListeners();
  });

  Future<void> resetInstructions() =>
      saveInstructions(defaultTranscriptCorrectionInstructions);

  bool get _hasSharedInstructions =>
      (_sharedInstructionsAvailable?.call() ?? false) &&
      _sharedInstructionsReader != null &&
      _sharedInstructionsWriter != null;

  Future<void> _reloadSharedInstructions() async {
    if (!_hasSharedInstructions) {
      return;
    }
    try {
      final shared = await _sharedInstructionsReader!().timeout(
        sharedInstructionsTimeout,
      );
      if (shared == null) {
        await _sharedInstructionsWriter!(
          config.instructions,
        ).timeout(sharedInstructionsTimeout);
        return;
      }
      var validated = TranscriptCorrectionConfig.validateInstructions(shared);
      if (_isLegacyTranscriptCorrectionInstructions(validated)) {
        validated = defaultTranscriptCorrectionInstructions;
        await _sharedInstructionsWriter!(
          validated,
        ).timeout(sharedInstructionsTimeout);
      }
      final updated = config.copyWith(instructions: validated);
      if (updated != config) {
        await _write(updated);
      }
      final changed = updated != config || validationError != null;
      config = updated;
      validationError = null;
      if (changed) {
        notifyListeners();
      }
    } on Object catch (error) {
      final message = 'Shared correction prompt: ${_oneLine(error)}';
      if (validationError != message) {
        validationError = message;
        notifyListeners();
      }
      // A missing provider, partial external write, or invalid shared prompt
      // cannot replace the app-private last-known-good configuration.
    }
  }

  Future<void> _write(TranscriptCorrectionConfig value) async {
    final file = _file;
    if (file == null) {
      throw StateError(
        'Transcript correction configuration is not initialized.',
      );
    }
    final partial = File('${file.path}.part');
    final formatted = const JsonEncoder.withIndent(
      '  ',
    ).convert(value.toJson());
    await partial.writeAsString('$formatted\n', flush: true);
    // Android's POSIX rename replaces the old file atomically, so a reader
    // sees either the previous validated config or the complete new config.
    await partial.rename(file.path);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completion = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completion.complete(await operation());
      } on Object catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }

  static String _oneLine(Object value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _isLegacyTranscriptCorrectionInstructions(String value) =>
    value == _legacyTranscriptCorrectionInstructions ||
    value == _legacyTranscriptCorrectionInstructions.replaceAll('’', "'") ||
    value ==
        defaultTranscriptCorrectionInstructions.replaceFirst(
          _currentAgentRoutingPolicy,
          _previousAgentRoutingPolicy,
        ) ||
    value ==
        defaultTranscriptCorrectionInstructions.replaceFirst(
          _latestChangesCorrectionPolicy,
          '',
        );
