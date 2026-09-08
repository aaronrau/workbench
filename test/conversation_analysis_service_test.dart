import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/conversation_analysis_preferences.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_analysis_service.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_model_store.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_record_store.dart';
import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'defaults on but starts independent models only after a durable WAV is queued',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final temporary = await Directory.systemTemp.createTemp(
        'workbench-conversation-on-demand.',
      );
      final service = ConversationAnalysisService(
        log: (_, _, {bool isError = false}) {},
        onChanged: () {},
        sharedAudioExportStore: SharedAudioExportStore(isAndroid: false),
        recordStore: ConversationRecordStore(
          supportDirectory: () async => temporary,
        ),
        modelStore: ConversationModelStore(
          supportDirectory: () async => temporary,
        ),
      );
      addTearDown(() async {
        await service.dispose();
        await temporary.delete(recursive: true);
      });

      await service.initialize();

      expect(service.enabled, isTrue);
      expect(service.state, 'waiting_for_enrollment_speech');
      expect(service.isStarting, isFalse);
      expect(service.isReady, isFalse);
      expect(service.error, isNull);

      final queuedWav = File('${temporary.path}/selected-agent.wav')
        ..writeAsBytesSync(const <int>[0, 0]);
      service.acceptFinalizedSegment('selected-agent-segment', queuedWav.path);
      expect(service.pendingCount, 1);
      expect(service.isStarting, isTrue);
      expect(service.isReady, isFalse);

      await _waitUntil(() => !service.isStarting);
      expect(service.pendingCount, 1, reason: 'The durable job is preserved.');
    },
  );

  test(
    'compacts legacy profiles and resets You before the next new segment',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final temporary = await Directory.systemTemp.createTemp(
        'workbench-conversation-reset.',
      );
      final store = ConversationRecordStore(
        supportDirectory: () async => temporary,
      );
      await store.initialize();
      final now = DateTime.utc(2026, 7, 28, 12);
      await store.saveProfiles(<SpeakerProfile>[
        for (var index = 0; index < 20; index++)
          SpeakerProfile(
            id: 'speaker-$index',
            label: 'Speaker ${index + 2}',
            embedding: const <double>[0, 1],
            sampleCount: 1,
            createdAt: now,
            updatedAt: now.add(Duration(minutes: index)),
          ),
        SpeakerProfile(
          id: 'primary-user',
          label: 'You',
          embedding: const <double>[1, 0],
          sampleCount: 1,
          createdAt: now,
          updatedAt: now,
          isPrimary: true,
        ),
      ]);
      final logs = <String>[];
      final service = ConversationAnalysisService(
        log: (_, message, {bool isError = false}) => logs.add(message),
        onChanged: () {},
        sharedAudioExportStore: SharedAudioExportStore(isAndroid: false),
        recordStore: store,
        modelStore: ConversationModelStore(
          supportDirectory: () async => temporary,
        ),
        clock: () => now,
      );
      addTearDown(() async {
        await service.dispose();
        await temporary.delete(recursive: true);
      });

      await service.initialize();

      expect(service.knownSpeakerCount, maximumNonPrimarySpeakerProfiles + 1);
      expect(logs, contains(contains('state=profiles_compacted')));

      // Enabling directly keeps this unit test independent from native model
      // startup while exercising the same reset and handoff state machine.
      service.enabled = true;
      await service.setSpeakerMatchThreshold(0.72);
      expect(service.speakerMatchThreshold, 0.72);
      await service.resetSpeakerIdentification();

      expect(service.needsEnrollment, isTrue);
      expect(service.isEnrollmentPending, isTrue);
      expect(service.knownSpeakerCount, maximumNonPrimarySpeakerProfiles);
      expect(
        service.speakerMatchThreshold,
        defaultSpeakerSignatureMatchThreshold,
      );
      expect(
        await const ConversationAnalysisPreferences()
            .loadSpeakerMatchThreshold(),
        defaultSpeakerSignatureMatchThreshold,
      );
      final savedAfterReset = await store.loadProfiles();
      expect(savedAfterReset.any((profile) => profile.isPrimary), isFalse);

      final resetMicros = now.microsecondsSinceEpoch;
      service.acceptFinalizedSegment(
        '${resetMicros - 1}-old',
        '${temporary.path}/old.wav',
      );
      expect(service.pendingCount, 0);
      expect(service.state, 'waiting_for_enrollment_speech');
      expect(logs, contains(contains('reason=started_before_reset')));

      service.acceptFinalizedSegment(
        '${resetMicros + 1}-new',
        '${temporary.path}/new.wav',
      );
      expect(service.pendingCount, 1);
      expect(service.isEnrollmentPending, isTrue);
      expect(service.isStarting, isTrue);

      service.acceptFinalizedSegment(
        '${resetMicros + 2}-too-soon',
        '${temporary.path}/too-soon.wav',
      );
      expect(service.pendingCount, 1);
      expect(logs, contains(contains('sample_analysis_in_progress')));
      await _waitUntil(() => !service.isStarting);
    },
  );

  test(
    'completed enrollment relabels matching durable history and removes duplicates',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final temporary = await Directory.systemTemp.createTemp(
        'workbench-conversation-reconcile.',
      );
      final store = ConversationRecordStore(
        supportDirectory: () async => temporary,
      );
      await store.initialize();
      final now = DateTime.utc(2026, 7, 28, 12);
      final primary = SpeakerProfile(
        id: 'primary-user',
        label: 'You',
        embedding: const <double>[1, 0],
        signatures: const <List<double>>[
          <double>[1, 0],
          <double>[0.9, 0.4358899],
          <double>[0.8, 0.6],
        ],
        sampleCount: 3,
        createdAt: now,
        updatedAt: now,
        isPrimary: true,
        historyReconciliationPending: true,
      );
      final duplicate = SpeakerProfile(
        id: 'speaker-2',
        label: 'Speaker 2',
        embedding: const <double>[0.7, 0.7141428],
        sampleCount: 1,
        createdAt: now,
        updatedAt: now,
      );
      final unrelated = SpeakerProfile(
        id: 'speaker-3',
        label: 'Speaker 3',
        embedding: const <double>[0, 1],
        sampleCount: 1,
        createdAt: now,
        updatedAt: now,
      );
      await store.saveProfiles(<SpeakerProfile>[primary, duplicate, unrelated]);
      final sourceText = File('${temporary.path}/synthetic.conversation.txt');
      await sourceText.writeAsString(
        'Speaker 2 [0.00–1.00]\nSynthetic retained text.\n',
      );
      await store.retainRecord(
        ConversationRecord(
          id: 'synthetic',
          audioPath: '${temporary.path}/synthetic.wav',
          textPath: sourceText.path,
          metadataPath: '${temporary.path}/source.json',
          updatedAt: now,
          utterances: <ConversationUtterance>[
            ConversationUtterance(
              id: 'synthetic-1',
              conversationId: 'synthetic',
              speakerId: duplicate.id,
              speakerLabel: duplicate.label,
              text: 'Synthetic retained text.',
              startMs: 0,
              endMs: 1000,
              confidence: 0.9,
              updatedAt: now,
            ),
            ConversationUtterance(
              id: 'synthetic-2',
              conversationId: 'synthetic',
              speakerId: 'evicted-speaker',
              speakerLabel: 'Speaker 1',
              text: 'Synthetic signature-backed text.',
              startMs: 1100,
              endMs: 2100,
              confidence: 0.5,
              updatedAt: now,
              speakerSignature: const <double>[0.68, 0.7332121],
            ),
          ],
        ),
      );
      final sharedStore = SharedAudioExportStore(isAndroid: false);
      final logs = <String>[];
      final service = ConversationAnalysisService(
        log: (_, message, {bool isError = false}) => logs.add(message),
        onChanged: () {},
        sharedAudioExportStore: sharedStore,
        recordStore: store,
        clock: () => now,
      );
      addTearDown(() async {
        await service.dispose();
        sharedStore.dispose();
        await temporary.delete(recursive: true);
      });

      await service.initialize();

      final profiles = await store.loadProfiles();
      expect(profiles.map((profile) => profile.label), <String>[
        'You',
        'Speaker 3',
      ]);
      expect(profiles.first.historyReconciliationPending, isFalse);
      final record = (await store.loadRecords()).single;
      expect(record.utterances.map((turn) => turn.speakerLabel), <String>[
        'You',
        'You',
      ]);
      expect(record.utterances.every((turn) => turn.isPrimary), isTrue);
      expect(
        sharedStore.conversations.map((turn) => turn.speakerLabel),
        <String>['You', 'You'],
      );
      expect(await sourceText.readAsString(), contains('You [0.00–1.00]'));
      expect(logs, contains(contains('state=history_reconciled')));
    },
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for the synthetic worker.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
