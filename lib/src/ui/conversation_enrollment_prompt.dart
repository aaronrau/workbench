import 'package:flutter/material.dart';

final class ConversationEnrollmentPrompt extends StatelessWidget {
  const ConversationEnrollmentPrompt({
    required this.acceptedSamples,
    required this.requiredSamples,
    required this.preparing,
    required this.checking,
    required this.resetting,
    required this.onReset,
    this.error,
    super.key,
  });

  final int acceptedSamples;
  final int requiredSamples;
  final bool preparing;
  final bool checking;
  final bool resetting;
  final VoidCallback onReset;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = resetting
        ? 'Resetting voice samples…'
        : preparing
        ? 'Preparing private speaker analysis…'
        : checking
        ? 'Checking voice sample ${acceptedSamples + 1} of $requiredSamples…'
        : 'Voice sample ${acceptedSamples + 1} of $requiredSamples: speak one '
              'clear sentence, then pause while it is checked.';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (preparing || resetting)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.record_voice_over_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
            ],
          ),
          if (error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(error!, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey<String>('reset-voice-samples'),
            onPressed: resetting ? null : onReset,
            child: const Text('Reset voice samples'),
          ),
        ],
      ),
    );
  }
}
