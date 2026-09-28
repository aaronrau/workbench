import 'package:flutter/material.dart';

import '../audio/keyword_highlights.dart';

final class KeywordHighlightSettings extends StatefulWidget {
  const KeywordHighlightSettings({
    required this.phrases,
    required this.onSave,
    super.key,
  });

  final List<String> phrases;
  final Future<void> Function(List<String> phrases) onSave;

  @override
  State<KeywordHighlightSettings> createState() =>
      _KeywordHighlightSettingsState();
}

final class _KeywordHighlightSettingsState
    extends State<KeywordHighlightSettings> {
  final _formKey = GlobalKey<FormState>();
  final _focusNode = FocusNode();
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.phrases.join('\n'));
  }

  @override
  void didUpdateWidget(KeywordHighlightSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    final saved = widget.phrases.join('\n');
    if (!_focusNode.hasFocus && _controller.text != saved) {
      _controller.text = saved;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    try {
      final phrases = KeywordHighlights.validatePhrases(
        _controller.text.split('\n'),
      );
      await widget.onSave(phrases);
      _focusNode.unfocus();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save keyword highlights.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Keyword highlights', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Match words or phrases in raw transcripts. Active counts stay '
              'at the top of Events for two minutes after the last match.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Form(
              key: _formKey,
              child: TextFormField(
                key: const ValueKey<String>('keyword-phrases-field'),
                controller: _controller,
                focusNode: _focusNode,
                minLines: 3,
                maxLines: 6,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Keywords, one per line',
                  alignLabelWithHint: true,
                  helperText: 'Save an empty list to turn highlights off.',
                ),
                validator: (value) {
                  try {
                    KeywordHighlights.validatePhrases(
                      (value ?? '').split('\n'),
                    );
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey<String>('save-keywords-button'),
              onPressed: _saving ? null : _save,
              child: const Text('Save keywords'),
            ),
          ],
        ),
      ),
    );
  }
}
