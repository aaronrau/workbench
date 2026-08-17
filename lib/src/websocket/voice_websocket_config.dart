import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum VoiceWebSocketAuthHeader {
  authorizationBearer,
  voiceApiToken;

  String get serializedName => switch (this) {
    authorizationBearer => 'authorizationBearer',
    voiceApiToken => 'xVoiceApiToken',
  };

  static VoiceWebSocketAuthHeader parse(Object? value) {
    return switch (value) {
      'authorizationBearer' => authorizationBearer,
      'xVoiceApiToken' => voiceApiToken,
      _ => throw const FormatException(
        'Authentication header must be Authorization bearer or '
        'X-Voice-Api-Token.',
      ),
    };
  }
}

final class VoiceWebSocketAgentTarget {
  const VoiceWebSocketAgentTarget({
    required this.endpointId,
    required this.agentName,
  });

  final String endpointId;
  final String agentName;

  String get key => '$endpointId\u0000${agentName.toLowerCase()}';

  @override
  bool operator ==(Object other) =>
      other is VoiceWebSocketAgentTarget &&
      other.endpointId == endpointId &&
      other.agentName.toLowerCase() == agentName.toLowerCase();

  @override
  int get hashCode => Object.hash(endpointId, agentName.toLowerCase());
}

final class VoiceWebSocketEndpointConfig {
  const VoiceWebSocketEndpointConfig({
    required this.id,
    required this.host,
    required this.port,
    required this.secret,
    required this.authHeader,
    required this.agentNames,
  });

  final String id;
  final String host;
  final int port;
  final String secret;
  final VoiceWebSocketAuthHeader authHeader;
  final List<String> agentNames;

  bool get isConfigured => secret.isNotEmpty && agentNames.isNotEmpty;

  Uri get uri => Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: VoiceWebSocketConfig.websocketPath,
  );

  Map<String, Object> get upgradeHeaders => switch (authHeader) {
    VoiceWebSocketAuthHeader.authorizationBearer => <String, Object>{
      HttpHeaders.authorizationHeader: 'Bearer $secret',
    },
    VoiceWebSocketAuthHeader.voiceApiToken => <String, Object>{
      'X-Voice-Api-Token': secret,
    },
  };

  VoiceWebSocketEndpointConfig copyWith({
    String? id,
    String? host,
    int? port,
    String? secret,
    VoiceWebSocketAuthHeader? authHeader,
    List<String>? agentNames,
  }) => VoiceWebSocketEndpointConfig(
    id: id ?? this.id,
    host: host ?? this.host,
    port: port ?? this.port,
    secret: secret ?? this.secret,
    authHeader: authHeader ?? this.authHeader,
    agentNames: agentNames ?? this.agentNames,
  );

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'host': host,
    'port': port,
    'path': VoiceWebSocketConfig.websocketPath,
    'secret': secret,
    'authHeader': authHeader.serializedName,
    'agentNames': agentNames,
  };

  static VoiceWebSocketEndpointConfig fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException(
        'Every WebSocket endpoint must be an object.',
      );
    }
    final id = value['id'];
    final host = value['host'];
    final port = value['port'];
    final path = value['path'];
    final secret = value['secret'];
    final authHeader = value['authHeader'];
    final agentNames = value['agentNames'];
    final legacy = value['useLegacyMessageShape'];
    if (id is! String ||
        host is! String ||
        port is! int ||
        path is! String ||
        secret is! String ||
        agentNames is! List<dynamic> ||
        legacy != null && legacy is! bool) {
      throw const FormatException(
        'Voice WebSocket endpoint settings have invalid value types.',
      );
    }
    if (path != VoiceWebSocketConfig.websocketPath) {
      throw const FormatException('The WebSocket path must be /ws.');
    }
    return validate(
      id: id,
      host: host,
      port: port,
      secret: secret,
      authHeader: VoiceWebSocketAuthHeader.parse(authHeader),
      agentNames: agentNames.map((value) {
        if (value is! String) {
          throw const FormatException('Every agent name must be text.');
        }
        return value;
      }),
    );
  }

  static VoiceWebSocketEndpointConfig validate({
    required String id,
    required String host,
    required int port,
    required String secret,
    required VoiceWebSocketAuthHeader authHeader,
    required Iterable<String> agentNames,
  }) {
    final validatedId = VoiceWebSocketConfig.validateEndpointId(id);
    final validatedHost = VoiceWebSocketConfig.validateIpv4(host);
    if (port < 1 || port > 65535) {
      throw const FormatException('Port must be between 1 and 65535.');
    }
    final validatedSecret = VoiceWebSocketConfig.validateSecret(secret);
    final validatedAgents = VoiceWebSocketConfig.validateAgentNames(agentNames);
    return VoiceWebSocketEndpointConfig(
      id: validatedId,
      host: validatedHost,
      port: port,
      secret: validatedSecret,
      authHeader: authHeader,
      agentNames: List<String>.unmodifiable(validatedAgents),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceWebSocketEndpointConfig &&
      other.id == id &&
      other.host == host &&
      other.port == port &&
      other.secret == secret &&
      other.authHeader == authHeader &&
      listEquals(other.agentNames, agentNames);

  @override
  int get hashCode => Object.hash(
    id,
    host,
    port,
    secret,
    authHeader,
    Object.hashAll(agentNames),
  );
}

final class VoiceWebSocketConfig {
  const VoiceWebSocketConfig({required this.endpoints});

  static const int schemaVersion = 2;
  static const int maximumSecretCharacters = 512;
  static const int maximumEndpointCount = 8;
  static const int maximumAgentNamesPerEndpoint = 4;
  static const int maximumAgentNames =
      maximumEndpointCount * maximumAgentNamesPerEndpoint;
  static const int maximumAgentNameCharacters = 64;
  static const String websocketPath = '/ws';

  static const defaults = VoiceWebSocketConfig(
    endpoints: <VoiceWebSocketEndpointConfig>[],
  );

  final List<VoiceWebSocketEndpointConfig> endpoints;

  List<String> get agentNames => List<String>.unmodifiable(
    endpoints.expand((endpoint) => endpoint.agentNames),
  );

  List<VoiceWebSocketAgentTarget> get agentTargets => List.unmodifiable(
    endpoints.expand(
      (endpoint) => endpoint.agentNames.map(
        (agent) => VoiceWebSocketAgentTarget(
          endpointId: endpoint.id,
          agentName: agent,
        ),
      ),
    ),
  );

  bool get isConfigured => endpoints.isNotEmpty;

  VoiceWebSocketEndpointConfig? endpointById(String id) {
    for (final endpoint in endpoints) {
      if (endpoint.id == id) {
        return endpoint;
      }
    }
    return null;
  }

  VoiceWebSocketAgentTarget? targetForAgent(String agent) {
    final normalized = agent.trim().toLowerCase();
    for (final target in agentTargets) {
      if (target.agentName.toLowerCase() == normalized) {
        return target;
      }
    }
    return null;
  }

  // Single-endpoint compatibility accessors keep VoiceWebSocketClient focused
  // on one connection while the manager owns the aggregate configuration.
  VoiceWebSocketEndpointConfig get _onlyEndpoint {
    if (endpoints.length != 1) {
      throw StateError('A WebSocket client requires exactly one endpoint.');
    }
    return endpoints.single;
  }

  String get endpointId => _onlyEndpoint.id;
  String get host => endpoints.isEmpty ? '127.0.0.1' : _onlyEndpoint.host;
  int get port => endpoints.isEmpty ? 8787 : _onlyEndpoint.port;
  String get secret => endpoints.isEmpty ? '' : _onlyEndpoint.secret;
  VoiceWebSocketAuthHeader get authHeader => endpoints.isEmpty
      ? VoiceWebSocketAuthHeader.authorizationBearer
      : _onlyEndpoint.authHeader;
  Uri get uri => _onlyEndpoint.uri;
  Map<String, Object> get upgradeHeaders => _onlyEndpoint.upgradeHeaders;

  VoiceWebSocketConfig copyWith({
    String? host,
    int? port,
    String? secret,
    VoiceWebSocketAuthHeader? authHeader,
    List<String>? agentNames,
  }) {
    final endpoint = _onlyEndpoint;
    return VoiceWebSocketConfig.single(
      VoiceWebSocketEndpointConfig.validate(
        id: endpoint.id,
        host: host ?? endpoint.host,
        port: port ?? endpoint.port,
        secret: secret ?? endpoint.secret,
        authHeader: authHeader ?? endpoint.authHeader,
        agentNames: agentNames ?? endpoint.agentNames,
      ),
    );
  }

  factory VoiceWebSocketConfig.single(VoiceWebSocketEndpointConfig endpoint) =>
      VoiceWebSocketConfig(
        endpoints: List<VoiceWebSocketEndpointConfig>.unmodifiable(
          <VoiceWebSocketEndpointConfig>[endpoint],
        ),
      );

  factory VoiceWebSocketConfig.validate({
    String id = 'endpoint-1',
    required String host,
    required int port,
    required String secret,
    required VoiceWebSocketAuthHeader authHeader,
    required Iterable<String> agentNames,
  }) => VoiceWebSocketConfig.single(
    VoiceWebSocketEndpointConfig.validate(
      id: id,
      host: host,
      port: port,
      secret: secret,
      authHeader: authHeader,
      agentNames: agentNames,
    ),
  );

  factory VoiceWebSocketConfig.validateEndpoints(
    Iterable<VoiceWebSocketEndpointConfig> values,
  ) {
    final endpoints = values.toList(growable: false);
    if (endpoints.length > maximumEndpointCount) {
      throw const FormatException('Add no more than 8 servers.');
    }
    final validated = <VoiceWebSocketEndpointConfig>[];
    final ids = <String>{};
    final serverIps = <String>{};
    final agents = <String>{};
    for (final value in endpoints) {
      final endpoint = VoiceWebSocketEndpointConfig.validate(
        id: value.id,
        host: value.host,
        port: value.port,
        secret: value.secret,
        authHeader: value.authHeader,
        agentNames: value.agentNames,
      );
      if (!ids.add(endpoint.id)) {
        throw const FormatException('Every server must have a unique ID.');
      }
      if (!serverIps.add(endpoint.host)) {
        throw const FormatException(
          'Each server must use a different IP address.',
        );
      }
      for (final agent in endpoint.agentNames) {
        if (!agents.add(agent.toLowerCase())) {
          throw FormatException(
            'Agent name "$agent" is already assigned to another server.',
          );
        }
      }
      validated.add(endpoint);
    }
    return VoiceWebSocketConfig(
      endpoints: List<VoiceWebSocketEndpointConfig>.unmodifiable(validated),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'version': schemaVersion,
    'voiceWebSockets': endpoints.map((endpoint) => endpoint.toJson()).toList(),
  };

  static VoiceWebSocketConfig fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException(
        'voice_websocket.json must contain a JSON object.',
      );
    }
    if (value['version'] == 1) {
      final socket = value['voiceWebSocket'];
      if (socket is! Map<String, dynamic>) {
        throw const FormatException(
          'voice_websocket.json must contain voiceWebSocket settings.',
        );
      }
      return VoiceWebSocketConfig.single(
        VoiceWebSocketEndpointConfig.fromJson(<String, dynamic>{
          ...socket,
          'id': 'endpoint-1',
        }),
      );
    }
    if (value['version'] != schemaVersion) {
      throw const FormatException(
        'voice_websocket.json version must be 1 or 2.',
      );
    }
    final sockets = value['voiceWebSockets'];
    if (sockets is! List<dynamic>) {
      throw const FormatException(
        'voice_websocket.json must contain voiceWebSockets settings.',
      );
    }
    return VoiceWebSocketConfig.validateEndpoints(
      sockets.map(VoiceWebSocketEndpointConfig.fromJson),
    );
  }

  static String validateEndpointId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(trimmed)) {
      throw const FormatException('Connection ID is invalid.');
    }
    return trimmed;
  }

  static String validateIpv4(String value) {
    final trimmed = value.trim();
    final parts = trimmed.split('.');
    if (parts.length != 4) {
      throw const FormatException(
        'IP address must contain four numbers separated by dots.',
      );
    }
    for (final part in parts) {
      if (part.isEmpty || part.length > 3 || !RegExp(r'^\d+$').hasMatch(part)) {
        throw const FormatException('Enter a valid IPv4 address.');
      }
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) {
        throw const FormatException(
          'Each IP address number must be from 0 to 255.',
        );
      }
    }
    return parts.map((part) => int.parse(part)).join('.');
  }

  static String validateSecret(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Secret cannot be empty.');
    }
    if (trimmed.length > maximumSecretCharacters) {
      throw const FormatException('Secret cannot exceed 512 characters.');
    }
    if (trimmed.contains('\r') || trimmed.contains('\n')) {
      throw const FormatException('Secret must fit on one line.');
    }
    for (final rune in trimmed.runes) {
      if (rune < 0x20 || rune == 0x7f) {
        throw const FormatException(
          'Secret contains an unsupported control character.',
        );
      }
    }
    return trimmed;
  }

  static List<String> validateAgentNames(Iterable<String> values) {
    final result = <String>[];
    final normalized = <String>{};
    for (final value in values) {
      final name = value.trim();
      if (name.isEmpty) {
        continue;
      }
      if (name.length > maximumAgentNameCharacters) {
        throw const FormatException(
          'Each agent name must be 64 characters or fewer.',
        );
      }
      for (final rune in name.runes) {
        if (rune < 0x20 || rune == 0x7f) {
          throw const FormatException(
            'Agent names contain an unsupported control character.',
          );
        }
      }
      if (normalized.add(name.toLowerCase())) {
        result.add(name);
      }
    }
    if (result.isEmpty) {
      throw const FormatException('Add at least one agent name.');
    }
    if (result.length > maximumAgentNamesPerEndpoint) {
      throw const FormatException(
        'Add no more than 4 agent names to each server.',
      );
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceWebSocketConfig && listEquals(other.endpoints, endpoints);

  @override
  int get hashCode => Object.hashAll(endpoints);
}

final class VoiceWebSocketConfigStore extends ChangeNotifier {
  VoiceWebSocketConfigStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory,
       _memoryOnly = false,
       config = VoiceWebSocketConfig.defaults;

  VoiceWebSocketConfigStore.inMemory(VoiceWebSocketConfig initialConfig)
    : _supportDirectory = getApplicationSupportDirectory,
      _memoryOnly = true,
      config = initialConfig;

  final Future<Directory> Function() _supportDirectory;
  final bool _memoryOnly;
  File? _file;
  bool _initialized = false;

  VoiceWebSocketConfig config;
  String? validationError;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    if (_memoryOnly) {
      return;
    }
    final support = await _supportDirectory();
    final workbench = Directory('${support.path}/workbench');
    await workbench.create(recursive: true);
    _file = File('${workbench.path}/voice_websocket.json');
    if (!await _file!.exists()) {
      return;
    }
    await reload();
  }

  Future<VoiceWebSocketConfig> reload() async {
    if (_memoryOnly) {
      return config;
    }
    final file = _file;
    if (file == null) {
      throw StateError('Voice WebSocket configuration is not initialized.');
    }
    try {
      final loaded = VoiceWebSocketConfig.fromJson(
        jsonDecode(await file.readAsString()),
      );
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
    }
    return config;
  }

  Future<void> save(VoiceWebSocketConfig value) async {
    if (!_initialized) {
      throw StateError('Voice WebSocket configuration is not initialized.');
    }
    final validated = VoiceWebSocketConfig.validateEndpoints(value.endpoints);
    if (!_memoryOnly) {
      final file = _file;
      if (file == null) {
        throw StateError('Voice WebSocket configuration is not initialized.');
      }
      final partial = File('${file.path}.part');
      final formatted = const JsonEncoder.withIndent(
        '  ',
      ).convert(validated.toJson());
      await partial.writeAsString('$formatted\n', flush: true);
      await partial.rename(file.path);
    }
    config = validated;
    validationError = null;
    notifyListeners();
  }

  static String _oneLine(Object value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}
