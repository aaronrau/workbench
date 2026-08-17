import 'package:flutter/material.dart';

import '../websocket/voice_websocket_client.dart';
import '../websocket/voice_websocket_connections.dart';
import 'workbench_theme.dart';

final class VoiceWebSocketHomeStatus extends StatelessWidget {
  const VoiceWebSocketHomeStatus({required this.states, super.key});

  final List<VoiceWebSocketEndpointState> states;

  @override
  Widget build(BuildContext context) {
    if (states.isEmpty) {
      return Semantics(
        label: 'No agent servers configured',
        child: Text(
          'No agent servers',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final maximumWidth = MediaQuery.sizeOf(context).width * 0.58;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maximumWidth, minHeight: 28),
      child: ListView.separated(
        key: const ValueKey<String>('voice-websocket-status-list'),
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        itemCount: states.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) => _EndpointStatus(state: states[index]),
      ),
    );
  }
}

final class _EndpointStatus extends StatelessWidget {
  const _EndpointStatus({required this.state});

  final VoiceWebSocketEndpointState state;

  @override
  Widget build(BuildContext context) {
    final endpoint = '${state.endpoint.host}:${state.endpoint.port}';
    final label = switch (state.status) {
      VoiceWebSocketStatus.ready => 'Connected',
      VoiceWebSocketStatus.connecting => 'Connecting',
      VoiceWebSocketStatus.disconnected => 'Disconnected',
      VoiceWebSocketStatus.error => 'Error',
      VoiceWebSocketStatus.unconfigured => 'Not configured',
    };
    final connected = state.status == VoiceWebSocketStatus.ready;
    return Semantics(
      label:
          'Agent server ${indexLabel(state.endpoint.id)}, '
          '$endpoint, $label',
      container: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.circle,
            key: ValueKey<String>(
              'voice-websocket-status-dot-${state.endpoint.id}',
            ),
            size: 8,
            color: connected ? connectedStatusColor : inactiveStatusColor,
          ),
          const SizedBox(width: 5),
          Text(
            connected ? endpoint : '$endpoint · $label',
            key: ValueKey<String>(
              'voice-websocket-status-text-${state.endpoint.id}',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  static String indexLabel(String endpointId) => endpointId;
}
