import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../audio/shared_audio_export_store.dart';
import '../audio/voice_memo_models.dart';
import '../ble/ble_models.dart';
import '../websocket/agent_exchange_store.dart';
import '../websocket/voice_websocket_client.dart';
import '../websocket/voice_websocket_config.dart';
import 'workbench_theme.dart';

enum HomeHistoryTab { events, messages, conversations }

typedef DirectAgentMessageSender =
    Future<bool> Function({
      required String endpointId,
      required String agent,
      required String message,
    });

typedef QueuedAgentMessageDeleter =
    void Function({required String endpointId, required String queueId});

final class HomeHistoryPanel extends StatefulWidget {
  const HomeHistoryPanel({
    required this.events,
    required this.conversations,
    this.voiceMemos = const <VoiceMemoRecord>[],
    required this.analysisEnabled,
    required this.needsEnrollment,
    this.enrollmentPending = false,
    this.acceptedEnrollmentSamples = 0,
    this.requiredEnrollmentSamples = 3,
    required this.analysisState,
    required this.knownSpeakerCount,
    required this.pendingConversationCount,
    required this.isLoadingConversations,
    required this.isStorageBusy,
    this.messages = const <SharedWebSocketMessage>[],
    this.agentNames = const <String>[],
    this.agentTargets = const <VoiceWebSocketAgentTarget>[],
    this.queuedAgentMessages = const <VoiceWebSocketQueuedMessage>[],
    this.agentMessages = const <AgentMessageView>[],
    this.transcriptions = const <SharedTranscript>[],
    this.supportsSharedFolder = false,
    this.isLoadingMessages = false,
    this.isLoadingAgentMessages = false,
    this.sharedFolderName,
    this.messageError,
    this.agentMessageError,
    this.conversationError,
    this.onClearEvents,
    this.onChooseFolder,
    this.onRefreshMessages,
    this.onRefreshConversations,
    this.onLoadMessages,
    this.onLoadConversations,
    this.onSendAgentMessage,
    this.onDeleteQueuedAgentMessage,
    this.onTabChanged,
    this.onToggleTranscriptAudio,
    this.isPlayingTranscript,
    super.key,
  });

  final List<PooledLog> events;
  final List<SharedConversationTurn> conversations;
  final List<VoiceMemoRecord> voiceMemos;
  final bool analysisEnabled;
  final bool needsEnrollment;
  final bool enrollmentPending;
  final int acceptedEnrollmentSamples;
  final int requiredEnrollmentSamples;
  final String analysisState;
  final int knownSpeakerCount;
  final int pendingConversationCount;
  final bool isLoadingConversations;
  final bool isStorageBusy;
  final List<SharedWebSocketMessage> messages;
  final List<String> agentNames;
  final List<VoiceWebSocketAgentTarget> agentTargets;
  final List<VoiceWebSocketQueuedMessage> queuedAgentMessages;
  final List<AgentMessageView> agentMessages;
  final List<SharedTranscript> transcriptions;
  final bool supportsSharedFolder;
  final bool isLoadingMessages;
  final bool isLoadingAgentMessages;
  final String? sharedFolderName;
  final String? messageError;
  final String? agentMessageError;
  final String? conversationError;
  final VoidCallback? onClearEvents;
  final VoidCallback? onChooseFolder;
  final VoidCallback? onRefreshMessages;
  final VoidCallback? onRefreshConversations;
  final Future<void> Function()? onLoadMessages;
  final Future<void> Function()? onLoadConversations;
  final DirectAgentMessageSender? onSendAgentMessage;
  final QueuedAgentMessageDeleter? onDeleteQueuedAgentMessage;
  final ValueChanged<HomeHistoryTab>? onTabChanged;
  final ValueChanged<SharedTranscript>? onToggleTranscriptAudio;
  final bool Function(SharedTranscript transcript)? isPlayingTranscript;

  @override
  State<HomeHistoryPanel> createState() => _HomeHistoryPanelState();
}

final class _HomeHistoryPanelState extends State<HomeHistoryPanel>
    with SingleTickerProviderStateMixin {
  static const int _messagePageSize = 20;
  static const int _conversationPageSize = 100;
  static const Duration _minimumFirstLoadDuration = Duration(milliseconds: 500);

  late final TabController _tabController;
  int _visibleMessageCount = _messagePageSize;
  int _visibleConversationCount = _conversationPageSize;
  HomeHistoryTab _reportedTab = HomeHistoryTab.events;
  bool _isLoadingMessagesForTab = false;
  bool _isLoadingConversationsForTab = false;
  bool _messagesLoadedOnce = false;
  bool _conversationsLoadedOnce = false;
  final Set<String> _sendingAgentKeys = <String>{};
  final Map<String, String> _agentDrafts = <String, String>{};
  final Map<String, String> _agentSendStatuses = <String, String>{};
  VoiceWebSocketAgentTarget? _selectedMessageAgent;
  final TextEditingController _agentMessageController = TextEditingController();
  final FocusNode _agentMessageFocusNode = FocusNode();

  HomeHistoryTab get _selectedTab =>
      HomeHistoryTab.values[_tabController.index];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: HomeHistoryTab.values.length,
      vsync: this,
    )..addListener(_tabChanged);
  }

  @override
  void didUpdateWidget(HomeHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sharedFolderName != widget.sharedFolderName ||
        oldWidget.messages.length != widget.messages.length ||
        oldWidget.transcriptions.length != widget.transcriptions.length ||
        oldWidget.agentMessages.length != widget.agentMessages.length) {
      _visibleMessageCount = _messagePageSize;
    }
    final selectedAgent = _selectedMessageAgent;
    if (selectedAgent != null &&
        !_configuredAgentTargets().any(
          (target) => target.key == selectedAgent.key,
        )) {
      _agentMessageFocusNode.unfocus();
      _selectedMessageAgent = null;
      _agentMessageController.clear();
    }
    if (oldWidget.conversations.length != widget.conversations.length ||
        oldWidget.voiceMemos.length != widget.voiceMemos.length) {
      _visibleConversationCount = _conversationPageSize;
    }
  }

  @override
  void dispose() {
    if (_reportedTab != HomeHistoryTab.events) {
      widget.onTabChanged?.call(HomeHistoryTab.events);
    }
    _tabController
      ..removeListener(_tabChanged)
      ..dispose();
    _agentMessageController.dispose();
    _agentMessageFocusNode.dispose();
    super.dispose();
  }

  void _tabChanged() {
    if (!mounted) {
      return;
    }
    final selectedTab = _selectedTab;
    if (selectedTab != _reportedTab) {
      _reportedTab = selectedTab;
      widget.onTabChanged?.call(selectedTab);
      _startTabLoad(selectedTab);
    }
    setState(() {});
  }

  void _startTabLoad(HomeHistoryTab tab) {
    final loader = switch (tab) {
      HomeHistoryTab.messages => widget.onLoadMessages,
      HomeHistoryTab.conversations => widget.onLoadConversations,
      HomeHistoryTab.events => null,
    };
    if (loader == null) {
      return;
    }
    if (tab == HomeHistoryTab.messages) {
      if (_isLoadingMessagesForTab) {
        return;
      }
      _isLoadingMessagesForTab = true;
    } else {
      if (_isLoadingConversationsForTab) {
        return;
      }
      _isLoadingConversationsForTab = true;
    }
    final firstLoad = tab == HomeHistoryTab.messages
        ? !_messagesLoadedOnce
        : !_conversationsLoadedOnce;
    unawaited(_runTabLoad(tab, loader, firstLoad: firstLoad));
  }

  Future<void> _runTabLoad(
    HomeHistoryTab tab,
    Future<void> Function() loader, {
    required bool firstLoad,
  }) async {
    try {
      await Future.wait<void>(<Future<void>>[
        loader(),
        if (firstLoad) Future<void>.delayed(_minimumFirstLoadDuration),
      ]);
    } on Object {
      // The parent-provided error state replaces the loading indicator.
    } finally {
      if (mounted) {
        setState(() {
          if (tab == HomeHistoryTab.messages) {
            _isLoadingMessagesForTab = false;
            _messagesLoadedOnce = true;
          } else {
            _isLoadingConversationsForTab = false;
            _conversationsLoadedOnce = true;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TabBar(
                controller: _tabController,
                dividerColor: Theme.of(context).colorScheme.outlineVariant,
                indicatorColor: Theme.of(context).colorScheme.onSurface,
                indicatorSize: TabBarIndicatorSize.tab,
                labelStyle: Theme.of(context).textTheme.titleSmall,
                unselectedLabelStyle: Theme.of(context).textTheme.bodyMedium,
                tabs: const <Tab>[
                  Tab(height: 48, text: 'Events'),
                  Tab(height: 48, text: 'Messages'),
                  Tab(height: 48, text: 'Conversation'),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_selectedTab == HomeHistoryTab.events)
              IconButton(
                tooltip: 'Clear events',
                onPressed: widget.events.isEmpty ? null : widget.onClearEvents,
                icon: const Icon(Icons.clear_all),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
              )
            else if (_selectedTab == HomeHistoryTab.messages)
              IconButton(
                tooltip: 'Refresh messages',
                onPressed:
                    _isLoadingMessagesForTab ||
                        widget.isLoadingMessages ||
                        widget.isStorageBusy
                    ? null
                    : widget.onRefreshMessages,
                icon: const Icon(Icons.refresh),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
              )
            else
              IconButton(
                tooltip: 'Refresh conversations',
                onPressed:
                    _isLoadingConversationsForTab ||
                        widget.isLoadingConversations ||
                        widget.isStorageBusy
                    ? null
                    : widget.onRefreshConversations,
                icon: const Icon(Icons.refresh),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: <Widget>[
              _buildEvents(context),
              _buildMessages(context),
              _buildConversations(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEvents(BuildContext context) {
    final events = widget.events.take(30).toList(growable: false);
    if (events.isEmpty) {
      return Center(
        child: Text('No events', style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return ListView.builder(
      key: const ValueKey<String>('events-list'),
      itemCount: events.length,
      itemExtent: 28,
      itemBuilder: (context, index) {
        final entry = events[index];
        final time =
            '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
            '${entry.timestamp.minute.toString().padLeft(2, '0')}';
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '$time  ${entry.source}  ${_singleLine(entry.message)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: entry.isError ? Theme.of(context).colorScheme.error : null,
              fontFamily: 'monospace',
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessages(BuildContext context) {
    final agents = _configuredAgentTargets();
    final selectedAgent = _selectedMessageAgent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (agents.isNotEmpty) ...<Widget>[
          SizedBox(
            height: 48,
            child: ListView.separated(
              key: const ValueKey<String>('message-agent-chips'),
              scrollDirection: Axis.horizontal,
              itemCount: agents.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ChoiceChip(
                    key: const ValueKey<String>('message-agent-all'),
                    label: const Text('All'),
                    selected: selectedAgent == null,
                    showCheckmark: false,
                    onSelected: (_) => _selectMessageAgent(null),
                  );
                }
                final agent = agents[index - 1];
                final selected = selectedAgent?.key == agent.key;
                return ChoiceChip(
                  key: ValueKey<String>('message-agent-${agent.agentName}'),
                  label: Text(agent.agentName),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (value) =>
                      _selectMessageAgent(value ? agent : null),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: selectedAgent == null
              ? _buildAllMessages(context)
              : _buildAgentMessages(context, selectedAgent),
        ),
      ],
    );
  }

  Widget _buildAllMessages(BuildContext context) {
    final theme = Theme.of(context);
    final folderName = widget.sharedFolderName;
    final history = _messageHistory();
    if (folderName == null && history.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.supportsSharedFolder
                    ? 'No saved messages yet. Choose a folder to also save '
                          'messages, transcripts, and WAV audio there.'
                    : 'No saved messages yet.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (widget.supportsSharedFolder) ...<Widget>[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: widget.isStorageBusy
                      ? null
                      : widget.onChooseFolder,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Choose folder'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if ((_isLoadingMessagesForTab || widget.isLoadingMessages) &&
        history.isEmpty) {
      return _buildLoadingState(
        context,
        key: const ValueKey<String>('messages-loading'),
        label: 'Loading messages…',
      );
    }
    final error = widget.messageError;
    if (error != null && history.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                error,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.isStorageBusy
                    ? null
                    : widget.onRefreshMessages,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (history.isEmpty) {
      return Center(
        child: Text(
          'No saved messages in $folderName',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    final visibleCount = min(_visibleMessageCount, history.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          error != null
              ? 'Folder unavailable · showing saved messages'
              : 'Saved messages and transcripts',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) =>
                _loadMoreMessages(notification, history.length),
            child: ListView.separated(
              key: const ValueKey<String>('messages-list'),
              itemCount: visibleCount,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = history[index];
                final message = entry.message;
                if (message != null) {
                  return _buildWebSocketMessage(context, message);
                }
                final transcript = entry.transcript!;
                final isPlaying =
                    widget.isPlayingTranscript?.call(transcript) ?? false;
                return Padding(
                  key: ValueKey<String>('transcript-${transcript.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('Original', style: theme.textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                              transcript.originalText,
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Corrected',
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              transcript.correctedText ??
                                  'Correction pending or unavailable',
                              style: transcript.hasCorrection
                                  ? theme.textTheme.bodyMedium
                                  : theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${transcript.hasAudio ? 'WAV + transcript' : 'Transcript only'}'
                              ' · ${transcript.hasCorrection ? 'corrected' : 'original only'}'
                              ' · ${_savedLabel(context, transcript.updatedAt)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: transcript.hasAudio
                            ? isPlaying
                                  ? 'Stop audio'
                                  : 'Play audio'
                            : 'Audio unavailable',
                        onPressed: !transcript.hasAudio || widget.isStorageBusy
                            ? null
                            : () => widget.onToggleTranscriptAudio?.call(
                                transcript,
                              ),
                        icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow),
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAgentMessages(
    BuildContext context,
    VoiceWebSocketAgentTarget target,
  ) {
    final theme = Theme.of(context);
    final agent = target.agentName;
    final sending = _sendingAgentKeys.contains(target.key);
    final sendStatus = _agentSendStatuses[target.key];
    final messages =
        widget.agentMessages
            .where(
              (message) => message.agent.toLowerCase() == agent.toLowerCase(),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final byTime = right.updatedAt.compareTo(left.updatedAt);
            return byTime != 0 ? byTime : right.id.compareTo(left.id);
          });
    final queuedMessages = widget.queuedAgentMessages
        .where(
          (message) =>
              message.endpointId == target.endpointId &&
              message.agent.toLowerCase() == agent.toLowerCase(),
        )
        .toList(growable: false);
    final visibleCount = min(_visibleMessageCount, messages.length);
    final canSend =
        !sending &&
        _agentMessageController.text.trim().isNotEmpty &&
        widget.onSendAgentMessage != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${messages.length} saved '
          '${messages.length == 1 ? 'message' : 'messages'} with $agent'
          '${queuedMessages.isEmpty ? '' : ' · ${queuedMessages.length} queued'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey<String>('direct-agent-message-field'),
          controller: _agentMessageController,
          focusNode: _agentMessageFocusNode,
          enabled: !sending,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.send,
          decoration: InputDecoration(
            labelText: 'Message $agent',
            suffixIcon: IconButton(
              key: const ValueKey<String>('dismiss-agent-message-keyboard'),
              tooltip: 'Dismiss keyboard',
              onPressed: _agentMessageFocusNode.unfocus,
              icon: const Icon(Icons.close),
            ),
          ),
          onChanged: (_) {
            setState(() {
              _agentDrafts[target.key] = _agentMessageController.text;
              _agentSendStatuses.remove(target.key);
            });
          },
          onSubmitted: (_) {
            if (canSend) {
              unawaited(_sendSelectedAgentMessage());
            }
          },
        ),
        if (sendStatus case final String status) ...<Widget>[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: switch ((
            widget.isLoadingAgentMessages,
            messages.isEmpty && queuedMessages.isEmpty,
            widget.agentMessageError,
          )) {
            (true, true, _) => _buildLoadingState(
              context,
              key: const ValueKey<String>('agent-messages-loading'),
              label: 'Loading agent messages…',
            ),
            (_, true, final String error) => Center(
              child: Text(
                error,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            (_, true, _) => Center(
              child: Text(
                'No messages with $agent yet',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            _ => NotificationListener<ScrollNotification>(
              onNotification: (notification) =>
                  _loadMoreMessages(notification, messages.length),
              child: ListView.separated(
                key: const ValueKey<String>('agent-messages-list'),
                itemCount: queuedMessages.length + visibleCount,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index < queuedMessages.length) {
                    return _buildQueuedAgentMessage(
                      context,
                      queuedMessages[index],
                    );
                  }
                  return _buildAgentMessage(
                    context,
                    messages[index - queuedMessages.length],
                  );
                },
              ),
            ),
          },
        ),
      ],
    );
  }

  List<_MessageHistoryEntry> _messageHistory() {
    final history = <_MessageHistoryEntry>[
      for (final message in widget.messages)
        _MessageHistoryEntry.message(message),
      for (final transcript in widget.transcriptions)
        _MessageHistoryEntry.transcript(transcript),
    ];
    history.sort((left, right) {
      final byTime = right.updatedAt.compareTo(left.updatedAt);
      return byTime != 0 ? byTime : right.id.compareTo(left.id);
    });
    return history;
  }

  Widget _buildWebSocketMessage(
    BuildContext context,
    SharedWebSocketMessage message,
  ) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey<String>('message-${message.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(message.direction.label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(message.text, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            _savedLabel(context, message.updatedAt),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildAgentMessage(BuildContext context, AgentMessageView message) {
    final theme = Theme.of(context);
    final direction = switch (message.direction) {
      AgentMessageDirection.sent => 'Sent',
      AgentMessageDirection.received => 'Received',
    };
    return Padding(
      key: ValueKey<String>('agent-message-${message.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(direction, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            _withoutLeadingAgent(message.message, message.agent),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            _savedLabel(context, message.updatedAt),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildQueuedAgentMessage(
    BuildContext context,
    VoiceWebSocketQueuedMessage message,
  ) {
    final theme = Theme.of(context);
    final status = switch (message.state) {
      VoiceWebSocketQueuedMessageState.sending => 'Sending…',
      VoiceWebSocketQueuedMessageState.waitingForConnection =>
        'Unable to send. Queued and will retry when the connection returns.',
      VoiceWebSocketQueuedMessageState.waitingForAgent =>
        'Agent busy. Queued and will retry.',
    };
    return Semantics(
      liveRegion: true,
      child: Padding(
        key: ValueKey<String>('queued-agent-message-${message.id}'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Queued', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(message.message, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(status, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: ValueKey<String>(
                'delete-queued-agent-message-${message.id}',
              ),
              tooltip: 'Delete queued message',
              onPressed:
                  widget.onDeleteQueuedAgentMessage == null ||
                      message.endpointId == null
                  ? null
                  : () => widget.onDeleteQueuedAgentMessage!(
                      endpointId: message.endpointId!,
                      queueId: message.id,
                    ),
              icon: const Icon(Icons.delete_outline),
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            ),
          ],
        ),
      ),
    );
  }

  List<VoiceWebSocketAgentTarget> _configuredAgentTargets() {
    final seen = <String>{};
    final configured = widget.agentTargets.isNotEmpty
        ? widget.agentTargets
        : widget.agentNames.map(
            (agent) =>
                VoiceWebSocketAgentTarget(endpointId: '', agentName: agent),
          );
    return configured
        .where(
          (target) =>
              target.agentName.trim().isNotEmpty && seen.add(target.key),
        )
        .toList(growable: false);
  }

  void _selectMessageAgent(VoiceWebSocketAgentTarget? agent) {
    final prior = _selectedMessageAgent;
    if (prior != null) {
      _agentDrafts[prior.key] = _agentMessageController.text;
    }
    if (agent == null) {
      _agentMessageFocusNode.unfocus();
    }
    setState(() {
      _selectedMessageAgent = agent;
      _visibleMessageCount = _messagePageSize;
      _agentMessageController.text = agent == null
          ? ''
          : _agentDrafts[agent.key] ?? '';
    });
    if (agent != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedMessageAgent?.key == agent.key) {
          _agentMessageFocusNode.requestFocus();
        }
      });
    }
  }

  Future<void> _sendSelectedAgentMessage() async {
    final target = _selectedMessageAgent;
    final sender = widget.onSendAgentMessage;
    final message = _agentMessageController.text.trim();
    if (target == null ||
        sender == null ||
        message.isEmpty ||
        _sendingAgentKeys.contains(target.key)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _sendingAgentKeys.add(target.key);
      _agentSendStatuses.remove(target.key);
    });
    var sent = false;
    try {
      sent = await sender(
        endpointId: target.endpointId,
        agent: target.agentName,
        message: message,
      );
    } on Object {
      sent = false;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sendingAgentKeys.remove(target.key);
      if (sent) {
        _agentDrafts[target.key] = '';
        _agentSendStatuses.remove(target.key);
        if (_selectedMessageAgent?.key == target.key) {
          _agentMessageController.clear();
        }
      } else {
        _agentSendStatuses[target.key] =
            'Could not send to ${target.agentName}. Check the connection.';
      }
    });
  }

  String _withoutLeadingAgent(String value, String agent) {
    final trimmed = value.trim();
    final normalizedAgent = agent.trim().replaceFirst(RegExp(r':+$'), '');
    if (normalizedAgent.isEmpty) {
      return trimmed;
    }
    return trimmed
        .replaceFirst(
          RegExp(
            '^${RegExp.escape(normalizedAgent)}\\s*:\\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trimLeft();
  }

  Widget _buildConversations(BuildContext context) {
    final theme = Theme.of(context);
    final allChronological =
        <_ConversationHistoryEntry>[
          for (final turn in widget.conversations)
            _ConversationHistoryEntry.turn(turn),
          for (final memo in widget.voiceMemos)
            _ConversationHistoryEntry.memo(memo),
        ]..sort((left, right) {
          final byTime = left.updatedAt.compareTo(right.updatedAt);
          return byTime != 0 ? byTime : left.id.compareTo(right.id);
        });
    final chronological = allChronological.length <= _conversationPageSize
        ? allChronological
        : allChronological.sublist(
            allChronological.length - _conversationPageSize,
          );
    if ((_isLoadingConversationsForTab || widget.isLoadingConversations) &&
        chronological.isEmpty) {
      return _buildLoadingState(
        context,
        key: const ValueKey<String>('conversations-loading'),
        label: 'Loading conversations…',
      );
    }
    final enrollmentNeeded = widget.needsEnrollment || widget.enrollmentPending;
    final enrollmentPrompt =
        'Voice sample ${widget.acceptedEnrollmentSamples + 1} of '
        '${widget.requiredEnrollmentSamples}: speak one clear sentence, '
        'then pause while it is checked.';
    if (enrollmentNeeded && chronological.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(
            enrollmentPrompt,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    final error = widget.conversationError;
    if (error != null && chronological.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                error,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.isStorageBusy
                    ? null
                    : widget.onRefreshConversations,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (chronological.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.analysisEnabled
                    ? 'No conversations or voice memos yet. Say “Hey Memo” '
                          'to start a memo.'
                    : 'Say “Hey Memo” to create a note here. Enable '
                          'Conversation analysis in Tools to also identify '
                          'speakers. Messages and ordinary transcripts remain '
                          'in the separate Messages tab.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    final visibleCount = min(_visibleConversationCount, chronological.length);
    final visible = chronological
        .skip(chronological.length - visibleCount)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.analysisEnabled
              ? '${widget.knownSpeakerCount} saved speakers · '
                    '${widget.pendingConversationCount} pending · '
                    '${widget.voiceMemos.length} '
                    '${widget.voiceMemos.length == 1 ? 'memo' : 'memos'} · '
                    '${_stateLabel(widget.analysisState)}'
              : '${widget.voiceMemos.length} voice '
                    '${widget.voiceMemos.length == 1 ? 'memo' : 'memos'} · '
                    'speaker analysis disabled',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (widget.analysisEnabled) ...<Widget>[
          if (enrollmentNeeded)
            Text(enrollmentPrompt, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) =>
                _loadMoreConversations(notification, chronological.length),
            child: ListView.separated(
              reverse: true,
              key: const ValueKey<String>('conversation-list'),
              itemCount: visible.length,
              padding: const EdgeInsets.only(bottom: 8),
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final entry = visible[index];
                final memo = entry.memo;
                return memo == null
                    ? _buildConversationTurn(context, entry.turn!)
                    : _buildVoiceMemo(context, memo);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingState(
    BuildContext context, {
    required Key key,
    required String label,
  }) {
    return Center(
      key: key,
      child: Semantics(
        liveRegion: true,
        label: label,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTurn(
    BuildContext context,
    SharedConversationTurn turn,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final primary = turn.isPrimary && !turn.isOverlap;
    final alignment = turn.isOverlap
        ? Alignment.center
        : primary
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final markerColor = primary
        ? conversationUserMarkerColor
        : colors.surfaceContainerHighest;
    final foreground = colors.onSurface;
    final label = turn.isOverlap ? 'Overlapping speakers' : turn.speakerLabel;
    return Semantics(
      label: '$label said ${turn.text}',
      child: Align(
        key: ValueKey<String>('conversation-${turn.id}'),
        alignment: alignment,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      key: ValueKey<String>(
                        'conversation-speaker-color-${turn.id}',
                      ),
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: markerColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.outlineVariant),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foreground,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  turn.text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_savedLabel(context, turn.updatedAt)} · '
                  '${_durationLabel(turn.startMs, turn.endMs)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: foreground.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceMemo(BuildContext context, VoiceMemoRecord memo) {
    final theme = Theme.of(context);
    final note = memo.note.trim().isEmpty
        ? 'Waiting for dictated content…'
        : memo.note.trim();
    return Semantics(
      label: 'Voice memo ${memo.status.label}: $note',
      child: Align(
        key: ValueKey<String>('voice-memo-${memo.id}'),
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Voice memo', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(note, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text(
                  '${memo.status.label} · '
                  '${memo.sources.length} '
                  '${memo.sources.length == 1 ? 'utterance' : 'utterances'} · '
                  '${_savedLabel(context, memo.updatedAt)}'
                  '${memo.errorCode == null ? '' : ' · original retained'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _loadMoreMessages(ScrollNotification notification, int historyLength) {
    if (notification is! ScrollEndNotification ||
        notification.metrics.extentAfter > 160 ||
        _visibleMessageCount >= historyLength) {
      return false;
    }
    setState(() {
      _visibleMessageCount = min(
        _visibleMessageCount + _messagePageSize,
        historyLength,
      );
    });
    return false;
  }

  bool _loadMoreConversations(
    ScrollNotification notification,
    int historyLength,
  ) {
    if (notification is! ScrollEndNotification ||
        notification.metrics.extentAfter > 160 ||
        _visibleConversationCount >= historyLength) {
      return false;
    }
    setState(() {
      _visibleConversationCount = min(
        _visibleConversationCount + _conversationPageSize,
        historyLength,
      );
    });
    return false;
  }

  String _savedLabel(BuildContext context, DateTime updatedAt) {
    if (updatedAt.millisecondsSinceEpoch <= 0) {
      return 'shared folder';
    }
    final local = updatedAt.toLocal();
    final now = DateTime.now();
    final localizations = MaterialLocalizations.of(context);
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local));
    }
    return localizations.formatCompactDate(local);
  }

  String _durationLabel(int startMs, int endMs) {
    final start = (startMs / 1000).toStringAsFixed(1);
    final end = (endMs / 1000).toStringAsFixed(1);
    return '${start}s–${end}s';
  }

  String _stateLabel(String state) =>
      state.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  String _singleLine(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

final class _MessageHistoryEntry {
  const _MessageHistoryEntry._({
    required this.id,
    required this.updatedAt,
    this.message,
    this.transcript,
  });

  factory _MessageHistoryEntry.message(SharedWebSocketMessage value) =>
      _MessageHistoryEntry._(
        id: 'message-${value.id}',
        updatedAt: value.updatedAt,
        message: value,
      );

  factory _MessageHistoryEntry.transcript(SharedTranscript value) =>
      _MessageHistoryEntry._(
        id: 'transcript-${value.id}',
        updatedAt: value.updatedAt,
        transcript: value,
      );

  final String id;
  final DateTime updatedAt;
  final SharedWebSocketMessage? message;
  final SharedTranscript? transcript;
}

final class _ConversationHistoryEntry {
  const _ConversationHistoryEntry._({
    required this.id,
    required this.updatedAt,
    this.turn,
    this.memo,
  });

  factory _ConversationHistoryEntry.turn(SharedConversationTurn value) =>
      _ConversationHistoryEntry._(
        id: 'turn-${value.id}',
        updatedAt: value.updatedAt,
        turn: value,
      );

  factory _ConversationHistoryEntry.memo(VoiceMemoRecord value) =>
      _ConversationHistoryEntry._(
        id: 'memo-${value.id}',
        updatedAt: value.updatedAt,
        memo: value,
      );

  final String id;
  final DateTime updatedAt;
  final SharedConversationTurn? turn;
  final VoiceMemoRecord? memo;
}
