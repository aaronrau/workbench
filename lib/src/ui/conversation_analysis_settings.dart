import 'package:flutter/material.dart';

import '../audio/conversation_models.dart';

final class ConversationAnalysisSettings extends StatefulWidget {
  const ConversationAnalysisSettings({
    required this.enabled,
    required this.state,
    required this.knownSpeakerCount,
    required this.pendingConversationCount,
    required this.enrollmentPending,
    required this.acceptedEnrollmentSamples,
    required this.requiredEnrollmentSamples,
    required this.speakerMatchThreshold,
    required this.busy,
    required this.onEnabledChanged,
    required this.onSpeakerMatchThresholdChanged,
    required this.onResetSpeakerIdentification,
    this.error,
    this.resetBusy = false,
    super.key,
  });

  final bool enabled;
  final String state;
  final int knownSpeakerCount;
  final int pendingConversationCount;
  final bool enrollmentPending;
  final int acceptedEnrollmentSamples;
  final int requiredEnrollmentSamples;
  final double speakerMatchThreshold;
  final bool busy;
  final bool resetBusy;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<double> onSpeakerMatchThresholdChanged;
  final VoidCallback onResetSpeakerIdentification;
  final String? error;

  @override
  State<ConversationAnalysisSettings> createState() =>
      _ConversationAnalysisSettingsState();
}

final class _ConversationAnalysisSettingsState
    extends State<ConversationAnalysisSettings> {
  late double _draftThreshold = widget.speakerMatchThreshold;

  @override
  void didUpdateWidget(ConversationAnalysisSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speakerMatchThreshold != widget.speakerMatchThreshold) {
      _draftThreshold = widget.speakerMatchThreshold;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stateLabel = widget.state.replaceAll('_', ' ');
    final thresholdBlocked =
        widget.busy || widget.resetBusy || widget.pendingConversationCount > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Conversation analysis', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Optional speaker diarization runs in a supervised worker with '
              'its own speech recognizer. It reuses each finalized WAV; the '
              'live transcription, correction, and agent connection never '
              'wait for it.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable speaker-labeled conversations'),
              subtitle: Text(
                widget.enabled
                    ? 'State: $stateLabel · ${widget.knownSpeakerCount} saved '
                          'speakers · ${widget.pendingConversationCount} pending'
                    : 'Disabled',
                style: theme.textTheme.bodySmall,
              ),
              value: widget.enabled,
              onChanged: widget.busy || widget.resetBusy
                  ? null
                  : widget.onEnabledChanged,
            ),
            if (widget.enabled) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Speaker match threshold: ${_draftThreshold.toStringAsFixed(2)}',
                style: theme.textTheme.titleSmall,
              ),
              Slider(
                key: const ValueKey<String>('speaker-match-threshold'),
                value: _draftThreshold,
                min: minimumAdjustableSpeakerSignatureMatchThreshold,
                max: maximumAdjustableSpeakerSignatureMatchThreshold,
                divisions: 40,
                label: _draftThreshold.toStringAsFixed(2),
                onChanged: thresholdBlocked
                    ? null
                    : (value) => setState(
                        () => _draftThreshold =
                            normalizeAdjustableSpeakerSignatureThreshold(value),
                      ),
                onChangeEnd: thresholdBlocked
                    ? null
                    : (value) => widget.onSpeakerMatchThresholdChanged(
                        normalizeAdjustableSpeakerSignatureThreshold(value),
                      ),
              ),
              Text(
                'Lower values accept more voice variation; higher values '
                'require a closer match. This value compares the three '
                'enrollment samples and identifies future speech.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                widget.enrollmentPending
                    ? 'Voice sample ${widget.acceptedEnrollmentSamples + 1} of '
                          '${widget.requiredEnrollmentSamples}: speak one clear '
                          'sentence, then pause while it is checked. Only you '
                          'should speak for all three samples.'
                    : 'Reset identification to record three new samples. '
                          'Matching saved turns will be relabeled You, and '
                          'the same calibration applies to future speech.',
                style: theme.textTheme.bodyMedium,
              ),
              if (widget.error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(widget.error!, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey<String>('reset-speaker-identification'),
                onPressed:
                    widget.resetBusy ||
                        (!widget.enrollmentPending &&
                            (widget.pendingConversationCount > 0 ||
                                widget.knownSpeakerCount == 0))
                    ? null
                    : widget.onResetSpeakerIdentification,
                icon: const Icon(Icons.person_search_outlined),
                label: Text(
                  widget.enrollmentPending
                      ? 'Reset voice samples'
                      : 'Reset speaker identification',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
