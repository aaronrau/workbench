import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

final class AgentExchangeView {
  const AgentExchangeView({
    required this.id,
    required this.agent,
    required this.message,
    required this.sentAt,
    required this.legacy,
    this.response,
    this.responseAt,
    this.responseMessages = const <AgentResponseView>[],
  });

  final String id;
  final String agent;
  final String message;
  final DateTime sentAt;
  final bool legacy;
  final String? response;
  final DateTime? responseAt;
  final List<AgentResponseView> responseMessages;
}

final class AgentResponseView {
  const AgentResponseView({required this.message, required this.receivedAt});

  final String message;
  final DateTime receivedAt;
}

enum AgentMessageDirection { sent, received }

final class AgentMessageView {
  const AgentMessageView({
    required this.id,
    required this.agent,
    required this.direction,
    required this.message,
    required this.updatedAt,
  });

  final String id;
  final String agent;
  final AgentMessageDirection direction;
  final String message;
  final DateTime updatedAt;
}

final class AgentExchangeStore {
  AgentExchangeStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
    DateTime Function() now = DateTime.now,
  }) : _supportDirectory = supportDirectory,
       _now = now;

  static const int maximumExchanges = 32;

  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _now;
  final List<_AgentExchangeRecord> _records = <_AgentExchangeRecord>[];
  final List<_AgentMessageRecord> _messages = <_AgentMessageRecord>[];
  final Map<String, List<_PendingResponse>> _orphanResponses =
      <String, List<_PendingResponse>>{};
  Future<void> _persistTail = Future<void>.value();
  File? _file;
  int _sequence = 0;
  bool _legacyImportComplete = false;

  Future<void> initialize() async {
    final support = await _supportDirectory();
    final directory = Directory('${support.path}/workbench');
    await directory.create(recursive: true);
    _file = File('${directory.path}/agent_exchanges.json');
    _records.clear();
    _messages.clear();
    final file = _file!;
    if (!await file.exists()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Unsupported exchange ledger.');
      }
      final records = decoded['exchanges'];
      if (records is! List<dynamic>) {
        throw const FormatException('Invalid exchange ledger.');
      }
      for (final value in records) {
        if (value is Map<String, dynamic>) {
          _records.add(_AgentExchangeRecord.fromJson(value));
        }
      }
      if (decoded['messages'] case final List<dynamic> messages) {
        for (final value in messages) {
          if (value is Map<String, dynamic>) {
            _messages.add(_AgentMessageRecord.fromJson(value));
          }
        }
      }
      _legacyImportComplete = decoded['legacy_import_complete'] == true;
      _records.sort((a, b) => b.sentAt.compareTo(a.sentAt));
      if (_records.length > maximumExchanges) {
        _records.removeRange(maximumExchanges, _records.length);
      }
      for (final record in _records) {
        _indexMessage(
          agent: record.agent,
          direction: AgentMessageDirection.sent,
          path: record.sentMessagePath,
          updatedAt: record.sentAt,
        );
        for (final response in record.responses) {
          _indexMessage(
            agent: record.agent,
            direction: AgentMessageDirection.received,
            path: response.path,
            updatedAt: response.receivedAt,
          );
        }
      }
      _sortMessages();
    } on Object {
      final invalid = File('${file.path}.invalid');
      if (await invalid.exists()) {
        await invalid.delete();
      }
      await file.rename(invalid.path);
      _records.clear();
      _messages.clear();
      _legacyImportComplete = false;
    }
  }

  Future<void> importExistingSentMessages({
    required List<String> paths,
    required List<String> agents,
    required bool legacy,
  }) async {
    _requireInitialized();
    if (agents.isEmpty) {
      return;
    }
    final normalizedAgents = <String, String>{
      for (final agent in agents)
        if (agent.trim().isNotEmpty) agent.trim().toLowerCase(): agent.trim(),
    };
    for (final path in paths) {
      final direction = path.endsWith('.sent.message.txt')
          ? AgentMessageDirection.sent
          : path.endsWith('.received.message.txt')
          ? AgentMessageDirection.received
          : null;
      if (direction == null ||
          _messages.any((message) => message.path == path)) {
        continue;
      }
      final file = File(path);
      try {
        final text = (await file.readAsString()).trim();
        String? matchedAgent;
        for (final entry in normalizedAgents.entries) {
          if (text.toLowerCase().startsWith('${entry.key}:')) {
            matchedAgent = entry.value;
            break;
          }
        }
        if (matchedAgent == null) {
          continue;
        }
        _indexMessage(
          agent: matchedAgent,
          direction: direction,
          path: path,
          updatedAt: (await file.lastModified()).toUtc(),
        );
      } on Object {
        // One missing or unreadable historical file cannot block recovery of
        // the remaining durable messages.
      }
    }

    final importedAgents = _records
        .map((record) => record.agent.toLowerCase())
        .toSet();
    if (importedAgents.length < normalizedAgents.length) {
      for (final path in paths.reversed) {
        if (importedAgents.length >= normalizedAgents.length ||
            _records.length >= maximumExchanges) {
          break;
        }
        if (!path.endsWith('.sent.message.txt')) {
          continue;
        }
        final file = File(path);
        try {
          final text = (await file.readAsString()).trim();
          String? matchedKey;
          String? matchedAgent;
          for (final entry in normalizedAgents.entries) {
            if (!importedAgents.contains(entry.key) &&
                text.toLowerCase().startsWith('${entry.key}:')) {
              matchedKey = entry.key;
              matchedAgent = entry.value;
              break;
            }
          }
          if (matchedKey == null || matchedAgent == null) {
            continue;
          }
          importedAgents.add(matchedKey);
          final sentAt = (await file.lastModified()).toUtc();
          _sequence++;
          _records.add(
            _AgentExchangeRecord(
              id: 'import-${sentAt.microsecondsSinceEpoch}-$_sequence',
              agent: matchedAgent,
              sentMessagePath: path,
              sentAt: sentAt,
              legacy: legacy,
            ),
          );
        } on Object {
          // Exchange previews are an optional cache over durable messages.
        }
      }
      _records.sort((a, b) => b.sentAt.compareTo(a.sentAt));
    }
    _legacyImportComplete = true;
    _sortMessages();
    await _persist();
  }

  Future<String> recordSent({
    required String agent,
    required String messagePath,
    required bool legacy,
    String? requestId,
  }) async {
    _requireInitialized();
    final now = _now().toUtc();
    _sequence++;
    final id = '${now.microsecondsSinceEpoch}-$_sequence';
    final record = _AgentExchangeRecord(
      id: id,
      agent: agent.trim(),
      sentMessagePath: messagePath,
      sentAt: now,
      legacy: legacy,
      deliveryRequestId: requestId,
    );
    final orphans = requestId == null
        ? null
        : _orphanResponses.remove(requestId);
    if (orphans != null) {
      for (final orphan in orphans) {
        record.appendResponse(orphan);
        _indexMessage(
          agent: record.agent,
          direction: AgentMessageDirection.received,
          path: orphan.path,
          updatedAt: orphan.receivedAt,
        );
      }
    }
    _records.insert(0, record);
    _indexMessage(
      agent: record.agent,
      direction: AgentMessageDirection.sent,
      path: messagePath,
      updatedAt: now,
    );
    if (_records.length > maximumExchanges) {
      _records.removeRange(maximumExchanges, _records.length);
    }
    await _persist();
    return id;
  }

  Future<void> associateSummary({
    required String exchangeId,
    String? requestId,
  }) async {
    final record = _recordById(exchangeId);
    record.pendingSummaryRequestId = requestId;
    final orphans = requestId == null
        ? null
        : _orphanResponses.remove(requestId);
    if (orphans != null) {
      for (final orphan in orphans) {
        record.appendResponse(orphan);
        _indexMessage(
          agent: record.agent,
          direction: AgentMessageDirection.received,
          path: orphan.path,
          updatedAt: orphan.receivedAt,
        );
      }
      record.pendingSummaryRequestId = null;
    }
    await _persist();
  }

  Future<String?> attachResponse({
    required String responsePath,
    required String kind,
    String? requestId,
    String? agent,
    bool allowLegacyAgentMatch = false,
  }) async {
    _requireInitialized();
    final receivedAt = _now().toUtc();
    _AgentExchangeRecord? record;
    if (requestId != null && requestId.trim().isNotEmpty) {
      final normalized = requestId.trim();
      record = _records.cast<_AgentExchangeRecord?>().firstWhere(
        (candidate) =>
            candidate?.deliveryRequestId == normalized ||
            candidate?.pendingSummaryRequestId == normalized,
        orElse: () => null,
      );
      if (record == null) {
        final pending = _orphanResponses.putIfAbsent(
          normalized,
          () => <_PendingResponse>[],
        );
        pending.add(
          _PendingResponse(
            path: responsePath,
            kind: kind,
            receivedAt: receivedAt,
          ),
        );
        if (pending.length > maximumExchanges) {
          pending.removeAt(0);
        }
        while (_orphanResponses.length > maximumExchanges) {
          _orphanResponses.remove(_orphanResponses.keys.first);
        }
        if (agent != null && agent.trim().isNotEmpty) {
          _indexMessage(
            agent: agent,
            direction: AgentMessageDirection.received,
            path: responsePath,
            updatedAt: receivedAt,
          );
          await _persist();
        }
        return null;
      }
    } else if (allowLegacyAgentMatch && agent != null) {
      final normalized = agent.trim().toLowerCase();
      record = _records.cast<_AgentExchangeRecord?>().firstWhere(
        (candidate) =>
            candidate?.legacy == true &&
            candidate?.agent.toLowerCase() == normalized,
        orElse: () => null,
      );
    }
    if (record == null) {
      if (agent != null && agent.trim().isNotEmpty) {
        _indexMessage(
          agent: agent,
          direction: AgentMessageDirection.received,
          path: responsePath,
          updatedAt: receivedAt,
        );
        await _persist();
      }
      return null;
    }
    _indexMessage(
      agent: record.agent,
      direction: AgentMessageDirection.received,
      path: responsePath,
      updatedAt: receivedAt,
    );
    record
      ..appendResponse(
        _PendingResponse(
          path: responsePath,
          kind: kind,
          receivedAt: receivedAt,
        ),
      )
      ..pendingSummaryRequestId = null;
    await _persist();
    return record.id;
  }

  Future<List<AgentExchangeView>> latestForAgents(
    List<String> agents, {
    int maximumAgents = 5,
  }) async {
    _requireInitialized();
    final selected = <_AgentExchangeRecord>[];
    final configured = agents
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);
    final latestByAgent = <String, _AgentExchangeRecord>{};
    for (final record in _records) {
      latestByAgent.putIfAbsent(record.agent.toLowerCase(), () => record);
    }
    final ranked = configured.toList(growable: false)
      ..sort((a, b) {
        final aTime = latestByAgent[a.toLowerCase()]?.sentAt;
        final bTime = latestByAgent[b.toLowerCase()]?.sentAt;
        if (aTime == null && bTime == null) {
          return agents.indexOf(a).compareTo(agents.indexOf(b));
        }
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });
    final chosen = ranked.take(maximumAgents).toSet();
    for (final agent in agents) {
      if (!chosen.contains(agent)) {
        continue;
      }
      final record = latestByAgent[agent.toLowerCase()];
      if (record != null) {
        selected.add(record);
      }
    }
    final views = <AgentExchangeView>[];
    for (final record in selected) {
      views.add(await _readView(record));
    }
    return views;
  }

  Future<List<AgentExchangeView>> recentForAgent(
    String agent, {
    int maximumExchanges = 5,
  }) async {
    _requireInitialized();
    final normalizedAgent = agent.trim().toLowerCase();
    if (normalizedAgent.isEmpty || maximumExchanges <= 0) {
      return const <AgentExchangeView>[];
    }
    final records = _records
        .where((record) => record.agent.toLowerCase() == normalizedAgent)
        .take(maximumExchanges)
        .toList(growable: false);
    return Future.wait(records.map(_readView));
  }

  Future<AgentExchangeView?> viewById(String exchangeId) async {
    _requireInitialized();
    final record = _records.cast<_AgentExchangeRecord?>().firstWhere(
      (candidate) => candidate?.id == exchangeId,
      orElse: () => null,
    );
    return record == null ? null : _readView(record);
  }

  Future<List<AgentMessageView>> retainedMessagesForAgents(
    Iterable<String> agents, {
    int? maximumMessagesPerAgent,
  }) async {
    _requireInitialized();
    final normalizedAgents = agents
        .map((agent) => agent.trim().toLowerCase())
        .where((agent) => agent.isNotEmpty)
        .toSet();
    if (normalizedAgents.isEmpty ||
        (maximumMessagesPerAgent != null && maximumMessagesPerAgent <= 0)) {
      return const <AgentMessageView>[];
    }
    final rankedRecords =
        _messages
            .where(
              (record) => normalizedAgents.contains(record.agent.toLowerCase()),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final byTime = right.updatedAt.compareTo(left.updatedAt);
            return byTime != 0 ? byTime : right.id.compareTo(left.id);
          });
    final records = <_AgentMessageRecord>[];
    final selectedByAgent = <String, int>{};
    for (final record in rankedRecords) {
      final normalizedAgent = record.agent.toLowerCase();
      final selected = selectedByAgent[normalizedAgent] ?? 0;
      if (maximumMessagesPerAgent != null &&
          selected >= maximumMessagesPerAgent) {
        continue;
      }
      records.add(record);
      selectedByAgent[normalizedAgent] = selected + 1;
    }
    final messages = <AgentMessageView>[];
    for (final record in records) {
      final text = await _readText(record.path);
      if (text.isEmpty) {
        continue;
      }
      final prefix = '${record.agent}:';
      final message = text.toLowerCase().startsWith(prefix.toLowerCase())
          ? text.substring(prefix.length).trim()
          : text;
      messages.add(
        AgentMessageView(
          id: record.id,
          agent: record.agent,
          direction: record.direction,
          message: message,
          updatedAt: record.updatedAt,
        ),
      );
    }
    messages.sort((left, right) {
      final byTime = right.updatedAt.compareTo(left.updatedAt);
      return byTime != 0 ? byTime : right.id.compareTo(left.id);
    });
    return List<AgentMessageView>.unmodifiable(messages);
  }

  Future<void> clear() async {
    _requireInitialized();
    _records.clear();
    _messages.clear();
    _orphanResponses.clear();
    _legacyImportComplete = true;
    await _persist();
  }

  Future<AgentExchangeView> _readView(_AgentExchangeRecord record) async {
    final responses = List<_AgentResponseRecord>.of(record.responses);
    final sent = await _readText(record.sentMessagePath);
    final prefix = '${record.agent}:';
    final message = sent.toLowerCase().startsWith(prefix.toLowerCase())
        ? sent.substring(prefix.length).trim()
        : sent;
    final responseMessages = <AgentResponseView>[];
    for (final response in responses) {
      final message = await _readText(response.path);
      if (message.isEmpty) {
        continue;
      }
      responseMessages.add(
        AgentResponseView(message: message, receivedAt: response.receivedAt),
      );
    }
    final latestResponse = responseMessages.isEmpty
        ? null
        : responseMessages.last;
    return AgentExchangeView(
      id: record.id,
      agent: record.agent,
      message: message,
      sentAt: record.sentAt,
      legacy: record.legacy,
      response: latestResponse?.message,
      responseAt: latestResponse?.receivedAt,
      responseMessages: List<AgentResponseView>.unmodifiable(responseMessages),
    );
  }

  Future<String> _readText(String path) async {
    try {
      return (await File(path).readAsString()).trim();
    } on Object {
      return '';
    }
  }

  _AgentExchangeRecord _recordById(String id) =>
      _records.cast<_AgentExchangeRecord?>().firstWhere(
        (candidate) => candidate?.id == id,
        orElse: () => null,
      ) ??
      (throw StateError('The selected exchange is no longer available.'));

  Future<void> _persist() {
    final completion = Completer<void>();
    _persistTail = _persistTail.then((_) async {
      try {
        await _writeSnapshot();
        completion.complete();
      } on Object catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }

  Future<void> _writeSnapshot() async {
    final file = _file!;
    final partial = File('${file.path}.part');
    final encoded = const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'version': 1,
      'legacy_import_complete': _legacyImportComplete,
      'exchanges': _records
          .map((record) => record.toJson())
          .toList(growable: false),
      'messages': _messages
          .map((message) => message.toJson())
          .toList(growable: false),
    });
    await partial.writeAsString('$encoded\n', flush: true);
    await partial.rename(file.path);
  }

  void _requireInitialized() {
    if (_file == null) {
      throw StateError('Agent exchange storage is not initialized.');
    }
  }

  void _indexMessage({
    required String agent,
    required AgentMessageDirection direction,
    required String path,
    required DateTime updatedAt,
  }) {
    final normalizedAgent = agent.trim();
    if (normalizedAgent.isEmpty || path.isEmpty) {
      return;
    }
    final existingIndex = _messages.indexWhere(
      (message) => message.path == path,
    );
    final record = _AgentMessageRecord(
      id: path,
      agent: normalizedAgent,
      direction: direction,
      path: path,
      updatedAt: updatedAt.toUtc(),
    );
    if (existingIndex < 0) {
      _messages.add(record);
    } else {
      _messages[existingIndex] = record;
    }
  }

  void _sortMessages() {
    _messages.sort((left, right) {
      final byTime = right.updatedAt.compareTo(left.updatedAt);
      return byTime != 0 ? byTime : right.id.compareTo(left.id);
    });
  }
}

final class _AgentMessageRecord {
  const _AgentMessageRecord({
    required this.id,
    required this.agent,
    required this.direction,
    required this.path,
    required this.updatedAt,
  });

  factory _AgentMessageRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final agent = json['agent'];
    final path = json['path'];
    final updatedAt = DateTime.tryParse('${json['updated_at']}');
    final direction = AgentMessageDirection.values
        .where((value) => value.name == json['direction'])
        .firstOrNull;
    if (id is! String ||
        id.isEmpty ||
        agent is! String ||
        agent.isEmpty ||
        path is! String ||
        path.isEmpty ||
        updatedAt == null ||
        direction == null) {
      throw const FormatException('Invalid agent message record.');
    }
    return _AgentMessageRecord(
      id: id,
      agent: agent,
      direction: direction,
      path: path,
      updatedAt: updatedAt.toUtc(),
    );
  }

  final String id;
  final String agent;
  final AgentMessageDirection direction;
  final String path;
  final DateTime updatedAt;

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'agent': agent,
    'direction': direction.name,
    'path': path,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

final class _PendingResponse {
  const _PendingResponse({
    required this.path,
    required this.kind,
    required this.receivedAt,
  });

  final String path;
  final String kind;
  final DateTime receivedAt;
}

final class _AgentExchangeRecord {
  _AgentExchangeRecord({
    required this.id,
    required this.agent,
    required this.sentMessagePath,
    required this.sentAt,
    required this.legacy,
    this.deliveryRequestId,
    this.responsePath,
    this.responseAt,
    this.responseKind,
    this.pendingSummaryRequestId,
    List<_AgentResponseRecord>? responses,
  }) : responses = responses ?? <_AgentResponseRecord>[];

  factory _AgentExchangeRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final agent = json['agent'];
    final sentMessagePath = json['sent_message_path'];
    final sentAt = DateTime.tryParse('${json['sent_at']}');
    final legacy = json['legacy'];
    if (id is! String ||
        id.isEmpty ||
        agent is! String ||
        agent.isEmpty ||
        sentMessagePath is! String ||
        sentMessagePath.isEmpty ||
        sentAt == null ||
        legacy is! bool) {
      throw const FormatException('Invalid exchange record.');
    }
    final responsePath = json['response_path'] as String?;
    final responseAt = json['response_at'] == null
        ? null
        : DateTime.tryParse('${json['response_at']}')?.toUtc();
    final responseKind = json['response_kind'] as String?;
    final responses = <_AgentResponseRecord>[
      if (json['responses'] case final List<dynamic> values)
        for (final value in values)
          if (value case final Map<String, dynamic> response)
            _AgentResponseRecord.fromJson(response),
    ];
    if (responses.isEmpty && responsePath != null) {
      responses.add(
        _AgentResponseRecord(
          path: responsePath,
          receivedAt: responseAt ?? sentAt.toUtc(),
          kind: responseKind ?? 'message',
        ),
      );
    }
    return _AgentExchangeRecord(
      id: id,
      agent: agent,
      sentMessagePath: sentMessagePath,
      sentAt: sentAt.toUtc(),
      legacy: legacy,
      deliveryRequestId: json['delivery_request_id'] as String?,
      responsePath: responsePath,
      responseAt: responseAt,
      responseKind: responseKind,
      pendingSummaryRequestId: json['pending_summary_request_id'] as String?,
      responses: responses,
    );
  }

  final String id;
  final String agent;
  final String sentMessagePath;
  final DateTime sentAt;
  final bool legacy;
  final String? deliveryRequestId;
  String? responsePath;
  DateTime? responseAt;
  String? responseKind;
  String? pendingSummaryRequestId;
  final List<_AgentResponseRecord> responses;

  void appendResponse(_PendingResponse response) {
    responsePath = response.path;
    responseAt = response.receivedAt;
    responseKind = response.kind;
    responses.add(
      _AgentResponseRecord(
        path: response.path,
        receivedAt: response.receivedAt,
        kind: response.kind,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'agent': agent,
    'sent_message_path': sentMessagePath,
    'sent_at': sentAt.toUtc().toIso8601String(),
    'legacy': legacy,
    'delivery_request_id': deliveryRequestId,
    'response_path': responsePath,
    'response_at': responseAt?.toUtc().toIso8601String(),
    'response_kind': responseKind,
    'responses': responses
        .map((response) => response.toJson())
        .toList(growable: false),
    'pending_summary_request_id': pendingSummaryRequestId,
  };
}

final class _AgentResponseRecord {
  const _AgentResponseRecord({
    required this.path,
    required this.receivedAt,
    required this.kind,
  });

  factory _AgentResponseRecord.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final receivedAt = DateTime.tryParse('${json['received_at']}');
    final kind = json['kind'];
    if (path is! String ||
        path.isEmpty ||
        receivedAt == null ||
        kind is! String ||
        kind.isEmpty) {
      throw const FormatException('Invalid exchange response record.');
    }
    return _AgentResponseRecord(
      path: path,
      receivedAt: receivedAt.toUtc(),
      kind: kind,
    );
  }

  final String path;
  final DateTime receivedAt;
  final String kind;

  Map<String, Object> toJson() => <String, Object>{
    'path': path,
    'received_at': receivedAt.toUtc().toIso8601String(),
    'kind': kind,
  };
}
