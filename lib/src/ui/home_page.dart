import 'package:flutter/material.dart';

import '../audio/conversation_models.dart';
import '../audio/phone_microphone_session.dart';
import '../audio/speech_model.dart';
import '../ble/ble_models.dart';
import '../startup/startup_state.dart';
import '../util/hex.dart';
import '../wearable_controller.dart';
import '../websocket/voice_websocket_connections.dart';
import 'app_version_label.dart';
import 'conversation_analysis_settings.dart';
import 'home_history_panel.dart';
import 'transcript_correction_settings.dart';
import 'voice_websocket_home_status.dart';
import 'voice_websocket_settings.dart';
import 'workbench_theme.dart';

final class HomePage extends StatefulWidget {
  const HomePage({required this.controller, super.key});

  final WearableController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  final TextEditingController _displayTextController = TextEditingController();
  final TextEditingController _g2RawController = TextEditingController(
    text: 'AA 21',
  );
  G2Side _rawSide = G2Side.right;
  bool _busy = false;
  bool _showTools = false;

  WearableController get controller => widget.controller;

  @override
  void dispose() {
    _displayTextController.dispose();
    _g2RawController.dispose();
    controller.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggleMicrophone() async {
    try {
      await controller.toggleMicrophone();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _connectOrDisconnectDevices() async {
    if (controller.hasWearableSession) {
      await controller.disconnectAll();
      return;
    }

    await controller.startScan(duration: const Duration(seconds: 8));
    for (var attempt = 0; attempt < 40; attempt++) {
      final hasG2 = controller.g2Candidates.any((pair) => pair.isComplete);
      if (hasG2 && controller.r1Candidates.isNotEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await controller.stopScan();

    final pair = controller.g2Candidates
        .where((candidate) => candidate.isComplete)
        .firstOrNull;
    if (pair == null) {
      throw StateError('No complete G2 pair found.');
    }
    await controller.connectG2(pair);

    final ring = controller.r1Candidates.firstOrNull;
    if (ring != null) {
      await controller.connectR1(ring);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasSession = controller.hasWearableSession;
        return PopScope(
          canPop: !_showTools,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _showTools) {
              setState(() => _showTools = false);
            }
          },
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: 52,
              automaticallyImplyLeading: false,
              leading: _showTools
                  ? BackButton(
                      onPressed: () => setState(() => _showTools = false),
                    )
                  : null,
              titleSpacing: 12,
              title: _showTools
                  ? null
                  : Row(
                      children: <Widget>[
                        Flexible(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                            ),
                            onPressed:
                                _busy ||
                                    controller.microphoneOwnsInput ||
                                    (!hasSession && !controller.canConnect)
                                ? null
                                : () => _run(_connectOrDisconnectDevices),
                            icon: Icon(
                              hasSession
                                  ? Icons.link_off
                                  : Icons.bluetooth_searching,
                            ),
                            label: Text(
                              hasSession
                                  ? 'Disconnect'
                                  : !controller.canConnect &&
                                        !controller.microphoneOwnsInput
                                  ? 'Preparing audio…'
                                  : _busy || controller.scanning
                                  ? 'Connecting…'
                                  : 'Connect devices',
                            ),
                          ),
                        ),
                        if (controller.supportsMicrophone) ...<Widget>[
                          const SizedBox(width: 8),
                          MicrophoneToggle(
                            active: controller.microphoneOwnsInput,
                            enabled:
                                controller.microphonePhase !=
                                    MicrophonePhase.starting &&
                                controller.microphonePhase !=
                                    MicrophonePhase.stopping &&
                                (controller.microphoneOwnsInput ||
                                    (!_busy && controller.canStartMicrophone)),
                            onPressed: _toggleMicrophone,
                          ),
                        ],
                      ],
                    ),
              actions: <Widget>[
                if (!_showTools) ...<Widget>[
                  const AppVersionLabel(),
                  IconButton(
                    tooltip: 'Tools',
                    onPressed: () => setState(() => _showTools = true),
                    icon: const Icon(Icons.tune_outlined),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                ],
              ],
            ),
            body: SafeArea(
              child: _showTools ? _buildToolsTab() : _buildHomeTab(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHomeTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        children: <Widget>[
          _buildStartupStatus(),
          if (controller.conversationAnalysisEnabled &&
              (controller.conversationNeedsEnrollment ||
                  controller.conversationEnrollmentPending)) ...<Widget>[
            const SizedBox(height: 8),
            _buildConversationEnrollmentPrompt(),
          ],
          const SizedBox(height: 6),
          _buildConnectionsCard(),
          const Divider(height: 16),
          _buildHistoryPanel(),
        ],
      ),
    );
  }

  Widget _buildStartupStatus() {
    final startup = controller.startup;
    return SizedBox(
      height: 28,
      child: Row(
        children: <Widget>[
          if (startup.isBusy) ...<Widget>[
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ] else
            Icon(
              startup.hasError
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline,
              size: 16,
            ),
          if (!startup.isBusy) const SizedBox(width: 8),
          Expanded(
            child: Text(
              controller.microphoneStatus ?? startup.message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          VoiceWebSocketHomeStatus(
            states: controller.voiceWebSocketEndpointStates,
          ),
          if (startup.phase == StartupPhase.failed)
            IconButton(
              tooltip: 'Retry local audio',
              onPressed: _busy
                  ? null
                  : () => _run(controller.retryAudioPipeline),
              icon: const Icon(Icons.refresh, size: 18),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _buildConversationEnrollmentPrompt() {
    final theme = Theme.of(context);
    final preparing = controller.conversationAnalysisStarting;
    final checking = controller.conversationAnalysisState == 'enrolling';
    final accepted = controller.acceptedConversationEnrollmentSamples;
    final required = controller.requiredConversationEnrollmentSamples;
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          if (preparing)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.record_voice_over_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              preparing
                  ? 'Preparing private speaker analysis…'
                  : checking
                  ? 'Checking voice sample ${accepted + 1} of $required…'
                  : 'Voice sample ${accepted + 1} of $required: speak one '
                        'clear sentence, then pause while it is checked.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionsCard() {
    final g2 = controller.g2;
    final transcript = controller.lastTranscript?.trim();
    final g2Status = switch (g2.state) {
      LinkState.connected => 'Connected',
      LinkState.connecting || LinkState.reconnecting => 'Connecting',
      LinkState.error => 'Error',
      LinkState.disconnected => 'Off',
    };
    final r1Connected =
        g2.isConnected && g2.lastR1ViaG2EventAt != null ||
        g2.isConnected &&
            controller.r1.batteryLevel != null &&
            controller.r1.handoffAt != null ||
        controller.r1.isConnected;
    final r1Status = r1Connected
        ? 'Connected'
        : controller.r1.state == LinkState.connecting
        ? 'Connecting'
        : g2.isConnected && g2.ringLinkStatus != null
        ? 'Waiting'
        : 'Off';
    final recentAudio =
        g2.lastAudioAt != null &&
        DateTime.now().difference(g2.lastAudioAt!).inSeconds < 3;
    final streaming = controller.microphoneActive
        ? controller.microphoneReceivingAudio
        : g2.isConnected && g2.audioEnabled && recentAudio;
    final audioStatus = streaming
        ? 'Streaming'
        : controller.microphoneActive || (g2.isConnected && g2.audioEnabled)
        ? 'Waiting'
        : 'Off';

    return Column(
      children: <Widget>[
        if (controller.scanning) ...<Widget>[
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
        ],
        Row(
          children: <Widget>[
            Expanded(
              child: _buildDeviceStatus(
                label: 'G2',
                status: g2Status,
                connected: g2.isConnected,
                battery: g2.isConnected ? g2.batteryLevel : null,
                charging: g2.batteryCharging,
              ),
            ),
            Expanded(
              child: _buildDeviceStatus(
                label: 'R1',
                status: r1Status,
                connected: r1Connected,
                battery: r1Connected ? controller.r1.batteryLevel : null,
              ),
            ),
            Expanded(
              child: _buildDeviceStatus(
                label: 'Audio',
                status: audioStatus,
                connected: streaming,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: controller.audioActivityLevel / 255,
          minHeight: 4,
          borderRadius: BorderRadius.circular(999),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Text(
              'Level ${controller.audioActivityLevel}/255',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            Flexible(
              child: Text(
                'Ring event: '
                '${g2.lastGesture == null ? 'Waiting' : _gestureLabel(g2.lastGesture!)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (transcript != null && transcript.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Semantics(
            label: 'Latest transcript',
            liveRegion: true,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${controller.transcriptPreviewStatus.label}: $transcript',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDeviceStatus({
    required String label,
    required String status,
    required bool connected,
    int? battery,
    bool? charging,
  }) {
    final showBattery = connected && battery != null;
    final semanticLabel = showBattery
        ? '$label battery $battery percent, connected'
        : '$label $status';
    return Semantics(
      label: semanticLabel,
      container: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.circle,
            size: 8,
            color: connected ? connectedStatusColor : inactiveStatusColor,
          ),
          const SizedBox(width: 5),
          if (showBattery) ...<Widget>[
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(width: 3),
            Icon(_batteryIcon(battery, charging: charging == true), size: 14),
            const SizedBox(width: 2),
            Text('$battery%', style: Theme.of(context).textTheme.bodySmall),
          ] else
            Flexible(
              child: Text(
                '$label $status',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHistoryPanel() {
    return Expanded(
      child: HomeHistoryPanel(
        events: controller.eventLogs,
        conversations: controller.conversations,
        voiceMemos: controller.voiceMemos,
        messages: controller.sharedWebSocketMessages,
        agentNames: controller.voiceWebSocketConfig.agentNames,
        agentTargets: controller.voiceWebSocketAgentTargets,
        queuedAgentMessages: controller.voiceWebSocketQueuedMessages,
        agentMessages: controller.agentMessages,
        transcriptions: controller.sharedTranscripts,
        supportsSharedFolder: controller.supportsSharedAudioFolder,
        sharedFolderName: controller.sharedAudioFolder?.displayName,
        analysisEnabled: controller.conversationAnalysisEnabled,
        needsEnrollment: controller.conversationNeedsEnrollment,
        enrollmentPending: controller.conversationEnrollmentPending,
        acceptedEnrollmentSamples:
            controller.acceptedConversationEnrollmentSamples,
        requiredEnrollmentSamples:
            controller.requiredConversationEnrollmentSamples,
        analysisState: controller.conversationAnalysisState,
        knownSpeakerCount: controller.knownSpeakerCount,
        pendingConversationCount: controller.pendingConversationCount,
        isLoadingConversations: controller.isLoadingConversations,
        isLoadingMessages: controller.isLoadingSharedMessages,
        isLoadingAgentMessages: controller.isLoadingAgentMessages,
        isStorageBusy: _busy || controller.isExportingSharedAudio,
        messageError: controller.sharedMessageError,
        agentMessageError: controller.agentMessageError,
        conversationError:
            controller.conversationAnalysisError ??
            controller.conversationLoadError,
        onClearEvents: controller.clearLogs,
        onChooseFolder: () => _run(controller.chooseSharedAudioFolder),
        onRefreshMessages: () =>
            _run(() => controller.refreshSharedMessages(reconcileShared: true)),
        onRefreshConversations: () => _run(controller.refreshConversations),
        onLoadMessages: controller.refreshSharedMessages,
        onLoadConversations: controller.refreshConversations,
        onSendAgentMessage: controller.sendDirectAgentMessage,
        onDeleteQueuedAgentMessage: controller.deleteQueuedAgentMessage,
        onTabChanged: (tab) {
          final messagesSelected = tab == HomeHistoryTab.messages;
          controller.setSharedMessageViewActive(messagesSelected);
        },
        isPlayingTranscript: controller.isPlayingTranscript,
        onToggleTranscriptAudio: (transcript) {
          _run(() => controller.toggleTranscriptAudio(transcript));
        },
      ),
    );
  }

  Widget _buildToolsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        _buildVoiceWebSocketCard(),
        const SizedBox(height: 12),
        _buildTranscriptionSettingsCard(),
        const SizedBox(height: 12),
        _buildConversationAnalysisCard(),
        const SizedBox(height: 12),
        _buildDisplayToolsCard(),
        const SizedBox(height: 12),
        _buildRawG2Card(),
        const SizedBox(height: 12),
        _buildDiagnosticsCard(),
        const SizedBox(height: 12),
        _buildStyleGuideSection(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildConversationAnalysisCard() {
    final enabled = controller.conversationAnalysisEnabled;
    final enrollmentPending =
        controller.conversationNeedsEnrollment ||
        controller.conversationEnrollmentPending;
    return ConversationAnalysisSettings(
      enabled: enabled,
      state: controller.conversationAnalysisState,
      knownSpeakerCount: controller.knownSpeakerCount,
      pendingConversationCount: controller.pendingConversationCount,
      enrollmentPending: enrollmentPending,
      acceptedEnrollmentSamples:
          controller.acceptedConversationEnrollmentSamples,
      requiredEnrollmentSamples:
          controller.requiredConversationEnrollmentSamples,
      speakerMatchThreshold: controller.conversationSpeakerMatchThreshold,
      busy: _busy,
      error: controller.conversationAnalysisError,
      onEnabledChanged: (value) =>
          _run(() => controller.setConversationAnalysisEnabled(value)),
      onSpeakerMatchThresholdChanged: (value) =>
          _run(() => controller.setConversationSpeakerMatchThreshold(value)),
      onResetSpeakerIdentification: () =>
          _run(controller.resetConversationSpeakerIdentification),
    );
  }

  Widget _buildVoiceWebSocketCard() {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey<String>('tools-agent-connection'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Agent connection', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            VoiceWebSocketSettings(
              config: controller.voiceWebSocketConfig,
              restoredSettings: controller.restoredVoiceWebSocketSettings,
              endpointStates: controller.voiceWebSocketEndpointStates,
              validationError: controller.voiceWebSocketValidationError,
              busy: _busy,
              onSave: (config) =>
                  _run(() => controller.saveVoiceWebSocketConfig(config)),
              onConnect: controller.connectVoiceWebSocket,
              onDisconnect: controller.disconnectVoiceWebSocket,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscriptionSettingsCard() {
    final theme = Theme.of(context);
    final selectionEnabled =
        !_busy &&
        !controller.isSwitchingSpeechModel &&
        !controller.startup.isBusy;
    return Card(
      key: const ValueKey<String>('tools-transcription'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Transcription', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Choose the local speech model. Parakeet 0.6B is the default.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey<String>(controller.selectedSpeechModelId),
              initialValue: controller.selectedSpeechModelId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Speech model'),
              items: <DropdownMenuItem<String>>[
                for (final model in controller.speechModels)
                  DropdownMenuItem<String>(
                    value: model.id,
                    child: Text(
                      model.id == defaultSpeechModelId
                          ? '${model.displayName} · default'
                          : model.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: selectionEnabled
                  ? (modelId) async {
                      if (modelId != null &&
                          modelId != controller.selectedSpeechModelId) {
                        await _run(() => controller.selectSpeechModel(modelId));
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              controller.isSwitchingSpeechModel
                  ? controller.startup.message
                  : controller.startup.provider == null
                  ? 'Selected: ${controller.selectedSpeechModelName} · '
                        'not loaded'
                  : 'Active: ${controller.selectedSpeechModelName} · '
                        'STT ${controller.transcriptionProvider} · '
                        'VAD ${controller.vadProvider ?? 'loading'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Changes apply immediately and persist. Audio capture and ring '
              'input continue while transcription reloads.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TranscriptCorrectionSettings(
              config: controller.correctionConfig,
              runtimeState: controller.correctionState,
              provider: controller.correctionProvider,
              validationError: controller.correctionConfigValidationError,
              pendingCount: controller.pendingCorrections,
              completedCount: controller.completedCorrections,
              busy: _busy,
              onEnabledChanged: (enabled) =>
                  _run(() => controller.setCorrectionEnabled(enabled)),
              onSaveInstructions: (instructions) => _run(
                () => controller.saveCorrectionInstructions(instructions),
              ),
              onResetInstructions: () =>
                  _run(controller.resetCorrectionInstructions),
            ),
            const SizedBox(height: 16),
            Text('File storage', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Choose a device folder for Files-visible WAV audio and text '
              'transcripts, sent and received agent messages, and the '
              'correction prompt. Home can read and play transcript files; '
              'private durable copies remain available if shared access is '
              'interrupted.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              controller.sharedAudioExportError ??
                  (controller.sharedAudioFolder == null
                      ? 'Save location: app-only storage'
                      : controller.isExportingSharedAudio
                      ? 'Saving existing files to '
                            '${controller.sharedAudioFolder!.displayName}…'
                      : 'Save location: '
                            '${controller.sharedAudioFolder!.displayName} · '
                            '${controller.sharedExportedFiles} files exported'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed:
                      _busy ||
                          controller.isExportingSharedAudio ||
                          !controller.supportsSharedAudioFolder
                      ? null
                      : () => _run(controller.chooseSharedAudioFolder),
                  icon: const Icon(Icons.folder_open_outlined),
                  label: Text(
                    controller.sharedAudioFolder == null
                        ? 'Choose folder'
                        : 'Change folder',
                  ),
                ),
                if (controller.sharedAudioFolder != null)
                  OutlinedButton(
                    onPressed: _busy || controller.isExportingSharedAudio
                        ? null
                        : () => _run(controller.clearSharedAudioFolder),
                    child: const Text('Use app-only storage'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisplayToolsCard() {
    final g2 = controller.g2;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Glasses display',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _displayTextController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Text to display',
                hintText: 'Manual message',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  onPressed: _busy || !g2.isConnected
                      ? null
                      : () => _run(
                          () => g2.sendText(_displayTextController.text),
                        ),
                  child: const Text('Send text'),
                ),
                OutlinedButton(
                  onPressed: _busy || !g2.isConnected
                      ? null
                      : () => _run(g2.restorePageNow),
                  child: const Text('Restore Hub page'),
                ),
                OutlinedButton(
                  onPressed: _busy || !g2.isConnected
                      ? null
                      : () => _run(g2.sendTestDrawing),
                  child: const Text('Test drawing'),
                ),
                OutlinedButton(
                  onPressed: _busy || !g2.isConnected
                      ? null
                      : () => _run(controller.sendTestDetailThumb),
                  child: const Text('Test detail thumb'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRawG2Card() {
    final g2 = controller.g2;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Raw G2 packet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Advanced diagnostic write. Send only known-safe packets.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _g2RawController,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Hex bytes'),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: SegmentedButton<G2Side>(
                    segments: const <ButtonSegment<G2Side>>[
                      ButtonSegment<G2Side>(
                        value: G2Side.left,
                        label: Text('Left'),
                      ),
                      ButtonSegment<G2Side>(
                        value: G2Side.right,
                        label: Text('Right'),
                      ),
                    ],
                    selected: <G2Side>{_rawSide},
                    onSelectionChanged: (value) {
                      setState(() => _rawSide = value.single);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _busy || !g2.isConnected
                      ? null
                      : () => _run(
                          () => g2.sendRawPacket(
                            parseHex(_g2RawController.text),
                            side: _rawSide,
                          ),
                        ),
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiagnosticsCard() {
    final g2 = controller.g2;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Text('Hub page: ${g2.pageSessionStatus}'),
            Text('R1: ${g2.ringLinkStatus ?? 'waiting for Tri-Sync activity'}'),
            Text(
              'Audio: ${g2.audioPackets} packets • '
              '${g2.pulseUpdates} pulse updates',
            ),
            Text(
              'Recovery: ${g2.pageExitEvents} exits • '
              '${g2.pageRestoreAttempts} attempts',
            ),
            Text(
              'Transcripts: ${controller.completedTranscripts} • '
              'STT ${controller.transcriptionProvider ?? 'loading'} • '
              'VAD ${controller.vadProvider ?? 'loading'}',
            ),
            Text(
              'Storage: ${controller.sharedAudioFolder == null ? 'app-only' : 'shared folder'}',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton(
                  onPressed: _busy || !controller.startup.isReady
                      ? null
                      : () => _run(controller.restartTranscriptionForTest),
                  child: const Text('Restart transcription'),
                ),
                OutlinedButton(
                  onPressed: _busy || !controller.startup.isReady
                      ? null
                      : () => _run(controller.restartVadForTest),
                  child: const Text('Restart VAD'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStyleGuideSection() {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('UI/UX examples', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Use these exact patterns for new Work Bench controls.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text('Audio input', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            IgnorePointer(
              child: Row(
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('Connect devices'),
                  ),
                  const SizedBox(width: 8),
                  MicrophoneToggle(
                    active: false,
                    enabled: true,
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start the phone microphone while glasses are disconnected.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text('Section title', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Body copy explains one action in a short sentence.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                const Icon(Icons.circle, size: 8, color: connectedStatusColor),
                const SizedBox(width: 8),
                Text('G2', style: theme.textTheme.bodySmall),
                const SizedBox(width: 3),
                const Icon(Icons.battery_6_bar, size: 14),
                const SizedBox(width: 2),
                Text('82%', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            const VoiceWebSocketHomeStatus(
              states: <VoiceWebSocketEndpointState>[],
            ),
            const SizedBox(height: 16),
            Text('Peer views', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            DefaultTabController(
              length: 3,
              child: IgnorePointer(
                child: TabBar(
                  dividerColor: theme.colorScheme.outlineVariant,
                  indicatorColor: theme.colorScheme.onSurface,
                  indicatorSize: TabBarIndicatorSize.tab,
                  labelStyle: theme.textTheme.titleSmall,
                  unselectedLabelStyle: theme.textTheme.bodyMedium,
                  tabs: const <Tab>[
                    Tab(height: 48, text: 'Events'),
                    Tab(height: 48, text: 'Messages'),
                    Tab(height: 48, text: 'Conversation'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Agent messages', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            IgnorePointer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      ChoiceChip(
                        label: Text('All'),
                        selected: false,
                        showCheckmark: false,
                      ),
                      ChoiceChip(
                        label: Text('Flux'),
                        selected: true,
                        showCheckmark: false,
                      ),
                      ChoiceChip(
                        label: Text('Pike'),
                        selected: false,
                        showCheckmark: false,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const TextField(
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(labelText: 'Message Flux'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('Queued', style: theme.textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                              'Run the synthetic check.',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Unable to send. Queued and will retry when the connection returns.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const IconButton(
                        tooltip: 'Delete queued message',
                        onPressed: null,
                        icon: Icon(Icons.delete_outline),
                        constraints: BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('Conversation turn', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: conversationUserMarkerColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('You', style: theme.textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Speaker-labeled text',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Setting', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            IgnorePointer(
              child: DropdownButtonFormField<String>(
                initialValue: 'local',
                decoration: const InputDecoration(labelText: 'Speech model'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                    value: 'local',
                    child: Text('Parakeet 0.6B'),
                  ),
                ],
                onChanged: (_) {},
              ),
            ),
            const SizedBox(height: 16),
            Text('Adjustable threshold', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            const IgnorePointer(
              child: Slider(
                value: defaultSpeakerSignatureMatchThreshold,
                min: minimumAdjustableSpeakerSignatureMatchThreshold,
                max: maximumAdjustableSpeakerSignatureMatchThreshold,
                divisions: 40,
                onChanged: null,
              ),
            ),
            Text(
              'Show the exact value and explain the low/high tradeoff.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text('Editable instructions', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            const IgnorePointer(
              child: TextField(
                minLines: 2,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'LLM instructions',
                  alignLabelWithHint: true,
                  helperText: 'Save validated changes explicitly.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('Sensitive setting', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            const IgnorePointer(
              child: TextField(
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Secret',
                  helperText: 'Store privately and never include in logs.',
                  suffixIcon: Icon(Icons.visibility_outlined),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              label:
                  'Button examples: filled primary, outlined secondary, '
                  'and tonal advanced',
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton(
                        onPressed: () {},
                        child: const Text('Connect'),
                      ),
                      OutlinedButton(
                        onPressed: () {},
                        child: const Text('Retry'),
                      ),
                      FilledButton.tonal(
                        onPressed: () {},
                        child: const Text('Advanced'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '16dp section padding • 12dp group gap • 8dp control gap\n'
              '48dp minimum targets • grayscale UI • green status dots only\n'
              'Agent socket status right-aligns IP:port and non-ready text\n'
              'Text tabs with an underline switch between peer views\n'
              'Agent chips filter both directions and reveal one direct-send '
              'field\n'
              'Speaker turns use aligned labels with grayscale color markers\n'
              'Labeled dropdowns select one persisted setting\n'
              'Discrete sliders expose bounded numeric thresholds\n'
              'Multiline settings use a labeled field and explicit Save action\n'
              'Secrets are masked, app-private, and excluded from logs\n'
              'Connected devices replace “Connected” with a battery icon '
              'and percentage',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  IconData _batteryIcon(int level, {required bool charging}) {
    if (charging) {
      return Icons.battery_charging_full;
    }
    return switch (level) {
      <= 5 => Icons.battery_0_bar,
      <= 20 => Icons.battery_1_bar,
      <= 35 => Icons.battery_2_bar,
      <= 50 => Icons.battery_3_bar,
      <= 65 => Icons.battery_4_bar,
      <= 80 => Icons.battery_5_bar,
      <= 95 => Icons.battery_6_bar,
      _ => Icons.battery_full,
    };
  }

  String _gestureLabel(String value) {
    if (value == 'inferred_long_press') {
      return 'Long press (inferred)';
    }
    return value
        .split('_')
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
  }
}

/// Compact secondary audio-source control, shared with the Tools examples.
class MicrophoneToggle extends StatelessWidget {
  const MicrophoneToggle({
    required this.active,
    required this.enabled,
    required this.onPressed,
    super.key,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    toggled: active,
    child: IconButton.outlined(
      tooltip: active ? 'Stop microphone' : 'Start microphone',
      onPressed: enabled ? onPressed : null,
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 40),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      icon: Icon(active ? Icons.mic : Icons.mic_none),
    ),
  );
}
