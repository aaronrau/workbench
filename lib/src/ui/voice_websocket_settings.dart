import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../websocket/voice_websocket_client.dart';
import '../websocket/voice_websocket_config.dart';
import '../websocket/voice_websocket_connections.dart';
import 'workbench_theme.dart';

final class VoiceWebSocketSettings extends StatefulWidget {
  const VoiceWebSocketSettings({
    required this.config,
    required this.endpointStates,
    required this.busy,
    required this.onSave,
    required this.onConnect,
    required this.onDisconnect,
    this.restoredSettings = VoiceWebSocketSharedSettings.empty,
    this.validationError,
    super.key,
  });

  final VoiceWebSocketConfig config;
  final VoiceWebSocketSharedSettings restoredSettings;
  final List<VoiceWebSocketEndpointState> endpointStates;
  final String? validationError;
  final bool busy;
  final Future<void> Function(VoiceWebSocketConfig config) onSave;
  final Future<void> Function(String endpointId) onConnect;
  final Future<void> Function(String endpointId) onDisconnect;

  @override
  State<VoiceWebSocketSettings> createState() => _VoiceWebSocketSettingsState();
}

final class _VoiceWebSocketSettingsState extends State<VoiceWebSocketSettings> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, String> _actionErrors = <String, String>{};
  List<_EndpointEditor> _editors = <_EndpointEditor>[];
  bool _saving = false;
  String? _formError;
  int _newEndpointSequence = 0;

  bool get _isEditing => _editors.any((editor) => editor.hasFocus);

  @override
  void initState() {
    super.initState();
    _replaceEditors(widget.config);
  }

  @override
  void didUpdateWidget(VoiceWebSocketSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditing &&
        (widget.config != oldWidget.config ||
            widget.restoredSettings != oldWidget.restoredSettings)) {
      _replaceEditors(widget.config);
    }
  }

  void _replaceEditors(VoiceWebSocketConfig config) {
    if (mounted) {
      for (final editor in _editors) {
        editor.dispose();
      }
    }
    _editors = config.endpoints.isEmpty
        ? widget.restoredSettings.endpoints.isEmpty
              ? <_EndpointEditor>[_newEditor()]
              : widget.restoredSettings.endpoints
                    .map(_EndpointEditor.fromSharedSettings)
                    .toList(growable: true)
        : config.endpoints
              .map(_EndpointEditor.fromConfig)
              .toList(growable: true);
  }

  _EndpointEditor _newEditor() {
    _newEndpointSequence++;
    return _EndpointEditor.blank(
      'endpoint-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
      '$_newEndpointSequence',
    );
  }

  @override
  void dispose() {
    for (final editor in _editors) {
      editor.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    VoiceWebSocketConfig config;
    try {
      final endpoints = _editors.map((editor) => editor.validated()).toList();
      config = VoiceWebSocketConfig.validateEndpoints(endpoints);
    } on FormatException catch (error) {
      setState(() => _formError = error.message);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(config);
      if (mounted) {
        FocusScope.of(context).unfocus();
        setState(() => _formError = null);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _addConnection() {
    if (_editors.length >= VoiceWebSocketConfig.maximumEndpointCount) {
      return;
    }
    setState(() {
      _formError = null;
      _editors.add(_newEditor());
    });
  }

  void _removeConnection(int index) {
    final editor = _editors.removeAt(index);
    editor.dispose();
    setState(() => _formError = null);
  }

  Future<void> _runEndpointAction(
    String endpointId,
    Future<void> Function(String endpointId) action,
  ) async {
    setState(() => _actionErrors.remove(endpointId));
    try {
      await action(endpointId);
    } on Object {
      if (mounted) {
        setState(() {
          _actionErrors[endpointId] =
              'This server is unavailable. Other servers are unaffected.';
        });
      }
    }
  }

  VoiceWebSocketEndpointState? _stateFor(String id) {
    for (final state in widget.endpointStates) {
      if (state.endpoint.id == id) {
        return state;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = widget.busy || _saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Agent servers', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Each server has its own IP address, port, authentication secret, '
          'and one to four agent names. Servers connect independently, and '
          'an agent name selects its server.',
          style: theme.textTheme.bodyMedium,
        ),
        if (widget.config.endpoints.isEmpty &&
            widget.restoredSettings.endpoints.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'Server settings restored from the shared folder. Enter each '
            'secret, then save to reconnect.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        Form(
          key: _formKey,
          child: Column(
            children: <Widget>[
              for (var index = 0; index < _editors.length; index++) ...<Widget>[
                if (index > 0) const Divider(height: 25),
                _buildEndpoint(
                  context,
                  editor: _editors[index],
                  index: index,
                  disabled: disabled,
                ),
              ],
            ],
          ),
        ),
        if (_formError != null || widget.validationError != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'Server validation: ${_formError ?? widget.validationError}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Connects to ws://IP:port/ws. Plain ws:// is unencrypted; use only '
          'trusted local servers.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              onPressed: disabled ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save servers'),
            ),
            OutlinedButton(
              key: const ValueKey<String>('voice-websocket-add'),
              onPressed:
                  disabled ||
                      _editors.length >=
                          VoiceWebSocketConfig.maximumEndpointCount
                  ? null
                  : _addConnection,
              child: const Text('Add server'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEndpoint(
    BuildContext context, {
    required _EndpointEditor editor,
    required int index,
    required bool disabled,
  }) {
    final theme = Theme.of(context);
    final state = _stateFor(editor.id);
    final connected = state?.status == VoiceWebSocketStatus.ready;
    final active =
        connected || state?.status == VoiceWebSocketStatus.connecting;
    final saved = widget.config.endpointById(editor.id) != null;
    final keySuffix = index == 0 ? '' : '-${editor.id}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              Icons.circle,
              size: 8,
              color: connected ? connectedStatusColor : inactiveStatusColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Server ${index + 1} · '
                '${state?.statusText ?? (saved ? 'Saved · disconnected' : 'Not saved')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(
              key: ValueKey<String>('voice-websocket-remove-${editor.id}'),
              onPressed: disabled ? null : () => _removeConnection(index),
              child: const Text('Remove server'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextFormField(
                key: ValueKey<String>('voice-websocket-ip$keySuffix'),
                controller: editor.host,
                focusNode: editor.hostFocus,
                enabled: !disabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  LengthLimitingTextInputFormatter(15),
                ],
                decoration: const InputDecoration(
                  labelText: 'IP address',
                  hintText: '127.0.0.1',
                ),
                validator: (value) {
                  try {
                    VoiceWebSocketConfig.validateIpv4(value ?? '');
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 104,
              child: TextFormField(
                key: ValueKey<String>('voice-websocket-port$keySuffix'),
                controller: editor.port,
                focusNode: editor.portFocus,
                enabled: !disabled,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                decoration: const InputDecoration(
                  labelText: 'Port',
                  hintText: '8787',
                ),
                validator: (value) {
                  final port = int.tryParse(value ?? '');
                  return port == null || port < 1 || port > 65535
                      ? 'Use 1–65535.'
                      : null;
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey<String>('voice-websocket-secret$keySuffix'),
          controller: editor.secret,
          focusNode: editor.secretFocus,
          enabled: !disabled,
          obscureText: editor.obscureSecret,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: VoiceWebSocketConfig.maximumSecretCharacters,
          decoration: InputDecoration(
            labelText: 'Secret',
            helperText: 'Stored only in app-private storage.',
            suffixIcon: IconButton(
              tooltip: editor.obscureSecret ? 'Show secret' : 'Hide secret',
              onPressed: disabled
                  ? null
                  : () => setState(
                      () => editor.obscureSecret = !editor.obscureSecret,
                    ),
              icon: Icon(
                editor.obscureSecret
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
          validator: (value) {
            try {
              VoiceWebSocketConfig.validateSecret(value ?? '');
              return null;
            } on FormatException catch (error) {
              return error.message;
            }
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<VoiceWebSocketAuthHeader>(
          key: ValueKey<String>('voice-websocket-auth$keySuffix'),
          initialValue: editor.authHeader,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Upgrade authentication',
          ),
          items: const <DropdownMenuItem<VoiceWebSocketAuthHeader>>[
            DropdownMenuItem(
              value: VoiceWebSocketAuthHeader.authorizationBearer,
              child: Text('Authorization: Bearer'),
            ),
            DropdownMenuItem(
              value: VoiceWebSocketAuthHeader.voiceApiToken,
              child: Text('X-Voice-Api-Token'),
            ),
          ],
          onChanged: disabled
              ? null
              : (value) {
                  if (value != null) editor.authHeader = value;
                },
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey<String>('voice-websocket-agents$keySuffix'),
          controller: editor.agents,
          focusNode: editor.agentsFocus,
          enabled: !disabled,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Agent names',
            hintText: 'Agent One\nAgent Two',
            helperText: 'Add one to four names, one per line.',
            alignLabelWithHint: true,
          ),
          validator: (value) {
            try {
              VoiceWebSocketConfig.validateAgentNames(
                (value ?? '').split(RegExp(r'[,\n]')),
              );
              return null;
            } on FormatException catch (error) {
              return error.message;
            }
          },
        ),
        if (_actionErrors[editor.id] case final String error) ...<Widget>[
          Text(
            error,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 8),
        ],
        OutlinedButton(
          onPressed: disabled || !saved
              ? null
              : () => unawaited(
                  _runEndpointAction(
                    editor.id,
                    active ? widget.onDisconnect : widget.onConnect,
                  ),
                ),
          child: Text(active ? 'Disconnect server' : 'Connect server'),
        ),
      ],
    );
  }
}

final class _EndpointEditor {
  _EndpointEditor({
    required this.id,
    required String host,
    required int port,
    required String secret,
    required String agents,
    required this.authHeader,
  }) : host = TextEditingController(text: host),
       port = TextEditingController(text: '$port'),
       secret = TextEditingController(text: secret),
       agents = TextEditingController(text: agents);

  factory _EndpointEditor.fromConfig(VoiceWebSocketEndpointConfig config) =>
      _EndpointEditor(
        id: config.id,
        host: config.host,
        port: config.port,
        secret: config.secret,
        agents: config.agentNames.join('\n'),
        authHeader: config.authHeader,
      );

  factory _EndpointEditor.fromSharedSettings(
    VoiceWebSocketSharedEndpointSettings settings,
  ) => _EndpointEditor(
    id: settings.id,
    host: settings.host,
    port: settings.port,
    secret: '',
    agents: settings.agentNames.join('\n'),
    authHeader: settings.authHeader,
  );

  factory _EndpointEditor.blank(String id) => _EndpointEditor(
    id: id,
    host: '127.0.0.1',
    port: 8787,
    secret: '',
    agents: '',
    authHeader: VoiceWebSocketAuthHeader.authorizationBearer,
  );

  final String id;
  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController secret;
  final TextEditingController agents;
  final FocusNode hostFocus = FocusNode();
  final FocusNode portFocus = FocusNode();
  final FocusNode secretFocus = FocusNode();
  final FocusNode agentsFocus = FocusNode();
  VoiceWebSocketAuthHeader authHeader;
  bool obscureSecret = true;

  bool get hasFocus =>
      hostFocus.hasFocus ||
      portFocus.hasFocus ||
      secretFocus.hasFocus ||
      agentsFocus.hasFocus;

  VoiceWebSocketEndpointConfig validated() =>
      VoiceWebSocketEndpointConfig.validate(
        id: id,
        host: host.text,
        port: int.parse(port.text),
        secret: secret.text,
        authHeader: authHeader,
        agentNames: agents.text.split(RegExp(r'[,\n]')),
      );

  void dispose() {
    host.dispose();
    port.dispose();
    secret.dispose();
    agents.dispose();
    hostFocus.dispose();
    portFocus.dispose();
    secretFocus.dispose();
    agentsFocus.dispose();
  }
}
