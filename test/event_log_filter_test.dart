import 'package:even_g2_r1_poc/src/ble/event_log_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'keeps connection and transcription milestones without continuous diagnostics',
    () {
      for (final message in [
        '[WorkBench][MOSS] state=queued segment=sample pending=3',
        '[WorkBench][MOSS] state=processing segment=sample',
        '[WorkBench][MOSS] state=invalid_output reason=incomplete_speaker_timestamps',
        '[WorkBench][Transcription] state=job_preserved segment=sample',
        '[WorkBench][Correction] state=completed',
        '[WorkBench][VAD] state=speech_ended segment=sample',
        '[WorkBench][Bluetooth] state=disconnected expected=false',
      ]) {
        expect(
          isConnectionOrTranscriptionEvent('Pipeline', message),
          isTrue,
          reason: message,
        );
      }
      expect(isConnectionOrTranscriptionEvent('G2 left', 'connected'), isTrue);
      expect(isConnectionOrTranscriptionEvent('G2', 'Disconnected'), isTrue);
      for (final entry in [
        ('Audio', '100 frames/s · level 10/255'),
        ('PCM', '[WorkBench][PCM] rms=5.0 peak=100 samples=16000'),
        ('Pipeline', '[WorkBench][Capture] state=streaming sequence=1'),
        ('Pipeline', '[WorkBench][SharedStorage] state=list_ready count=1'),
        ('Pipeline', '[WorkBench][MOSS] state=queue_status queued=3 held=1'),
        ('G2 left', 'MTU 512'),
        ('G2 protocol', 'notification received'),
        (
          'G2 display',
          '[WorkBench][G2Display] state=generation_changed owner=disconnected',
        ),
        ('Pipeline', '[WorkBench][VAD] state=buffer_cleared segment=sample'),
      ]) {
        expect(
          isConnectionOrTranscriptionEvent(entry.$1, entry.$2),
          isFalse,
          reason: entry.$2,
        );
      }
    },
  );
}
