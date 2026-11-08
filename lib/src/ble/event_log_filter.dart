/// Events contains connection changes and speech-job milestones only.
/// Full diagnostics still go to Android logcat before this filter runs.
bool isConnectionOrTranscriptionEvent(String source, String message) {
  final category = RegExp(
    r'\[WorkBench\]\[(\w+)\]',
  ).firstMatch(message)?.group(1);
  if (const {
    'MOSS',
    'Transcription',
    'Correction',
    'Conversation',
    'Bluetooth',
    'Microphone',
  }.contains(category)) {
    return !message.contains('state=queue_status');
  }
  if (category == 'VAD') {
    return RegExp(
      r'state=(speech_started|speech_ended|speech_chunked)\b',
    ).hasMatch(message);
  }
  if (category != null) return false;
  if (source == 'BLE') return message.startsWith('Adapter:');
  if (source == 'G2' ||
      const {'G2 left', 'G2 right', 'G2 pairing'}.contains(source) ||
      source == 'R1') {
    return RegExp(
      r'\b(connecting|connected|disconnected|reconnecting|connection failed|protocol session is ready)\b',
      caseSensitive: false,
    ).hasMatch(message);
  }
  return false;
}
