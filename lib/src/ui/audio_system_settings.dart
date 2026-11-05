import 'package:flutter/material.dart';
import '../audio/moss_audio.dart';

final class AudioSystemSettings extends StatelessWidget {
  const AudioSystemSettings({
    required this.system,
    required this.enabled,
    required this.onChanged,
    this.provider = MossExecutionProvider.opencl,
    this.onProviderChanged,
    this.quantization = MossQuantization.q5K,
    this.onQuantizationChanged,
    super.key,
  });
  final AudioSystem system;
  final bool enabled;
  final ValueChanged<AudioSystem> onChanged;
  final MossExecutionProvider provider;
  final ValueChanged<MossExecutionProvider>? onProviderChanged;
  final MossQuantization quantization;
  final ValueChanged<MossQuantization>? onQuantizationChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DropdownButtonFormField<AudioSystem>(
        key: ValueKey(system),
        initialValue: system,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Audio system'),
        items: const [
          DropdownMenuItem(
            value: AudioSystem.modular,
            child: Text('Current system'),
          ),
          DropdownMenuItem(
            value: AudioSystem.moss,
            child: Text('MOSS 0.9B · experimental'),
          ),
        ],
        onChanged: enabled
            ? (value) {
                if (value != null) onChanged(value);
              }
            : null,
      ),
      const SizedBox(height: 8),
      if (system == AudioSystem.moss) ...[
        DropdownButtonFormField<MossQuantization>(
          key: ValueKey(quantization),
          initialValue: quantization,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'MOSS weights'),
          items: [
            for (final choice in MossQuantization.values)
              DropdownMenuItem(value: choice, child: Text(choice.choiceLabel)),
          ],
          onChanged: enabled && onQuantizationChanged != null
              ? (value) {
                  if (value != null) onQuantizationChanged!(value);
                }
              : null,
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<MossExecutionProvider>(
          key: ValueKey(provider),
          initialValue: provider,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'MOSS execution'),
          items: const [
            DropdownMenuItem(
              value: MossExecutionProvider.opencl,
              child: Text('GPU · OpenCL'),
            ),
            DropdownMenuItem(
              value: MossExecutionProvider.cpu,
              child: Text('CPU'),
            ),
          ],
          onChanged: enabled && onProviderChanged != null
              ? (value) {
                  if (value != null) onProviderChanged!(value);
                }
              : null,
        ),
        const SizedBox(height: 8),
      ],
      Text(
        system == AudioSystem.moss
            ? 'Voice detection closes chunks at pauses (about 0.8 s quiet), or after 8–12 s of continuous speech. MOSS transcribes each chunk and labels speakers; '
                  'saved voice profiles can refine labels afterwards. Unmatched labels restart in each chunk. '
                  'GPU execution never silently falls back to CPU. '
                  'Parakeet, speaker segmentation, and Gemma stay unloaded.'
            : 'Uses the selected speech model, voice detection, optional speaker analysis, and Gemma correction.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Text(
        'Disconnect devices and stop the microphone before switching. The choice is saved.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}
