import 'dart:async';
import 'dart:io';

import 'package:even_g2_r1_poc/src/audio/conversation_analysis_preferences.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_analysis_service.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_analysis_worker.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_model_store.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_models.dart';
import 'package:even_g2_r1_poc/src/audio/conversation_record_store.dart';
import 'package:even_g2_r1_poc/src/audio/shared_audio_export_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failSharedWrite in <bool>[false, true]) {
    test(
      'reset survives restart with ${failSharedWrite ? 'failed' : 'successful'} shared recovery update',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final temporary = await Directory.systemTemp.createTemp(
          'workbench-enrollment-recovery.',
        );
        final store = ConversationRecordStore(
          supportDirectory: () async => temporary,
        );
        await store.initialize();
        await store.saveProfiles(<SpeakerProfile>[
          acceptPrimarySpeakerEnrollmentSample(
            primary: null,
            candidate: const <double>[1, 0],
            now: DateTime.utc(2026, 1, 1),
          ),
        ]);
        const channel = MethodChannel('test/workbench_enrollment_recovery');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        Uint8List? sharedRecovery;
        var rejectWrites = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'currentDirectory':
              return <String, Object>{'displayName': 'Shared'};
            case 'readSpeakerSignatureRecovery':
              return sharedRecovery;
            case 'writeSpeakerSignatureRecovery':
              if (rejectWrites) {
                throw PlatformException(code: 'synthetic_write_failure');
              }
              sharedRecovery =
                  (call.arguments as Map<Object?, Object?>)['recovery']
                      as Uint8List;
              return null;
            default:
              fail('Unexpected method ${call.method}');
          }
        });
        final shared = SharedAudioExportStore(
          channel: channel,
          isAndroid: true,
        );
        await shared.initialize();
        ConversationAnalysisService createService() =>
            ConversationAnalysisService(
              log: (_, _, {bool isError = false}) {},
              onChanged: () {},
              sharedAudioExportStore: shared,
              recordStore: store,
            );
        final service = createService();
        final restored = createService();
        addTearDown(() async {
          await service.dispose();
          await restored.dispose();
          shared.dispose();
          messenger.setMockMethodCallHandler(channel, null);
          await temporary.delete(recursive: true);
        });
        await service.initialize();
        expect(
          ConversationProfileRecovery.decode(sharedRecovery!).profiles,
          hasLength(1),
        );
        rejectWrites = failSharedWrite;
        await service.resetSpeakerIdentification();
        expect(
          ConversationProfileRecovery.decode(sharedRecovery!).profiles,
          failSharedWrite ? hasLength(1) : isEmpty,
        );
        await service.dispose();
        await restored.initialize();
        await restored.syncSharedRecovery();
        expect(restored.acceptedEnrollmentSamples, 0);
        expect(restored.needsEnrollment, isTrue);
        expect(await store.loadProfiles(), isEmpty);
      },
    );
  }

  for (final finishBeforeReset in <bool>[false, true]) {
    test(
      'reset discards ${finishBeforeReset ? 'completing' : 'active'} enrollment and ignores stale callbacks',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final temporary = await Directory.systemTemp.createTemp(
          'workbench-enrollment-reset.',
        );
        final store = ConversationRecordStore(
          supportDirectory: () async => temporary,
        );
        await store.initialize();
        var now = DateTime.utc(2026, 1, 1);
        final partial = acceptPrimarySpeakerEnrollmentSample(
          primary: null,
          candidate: const <double>[1, 0],
          now: now,
        );
        final other = SpeakerProfile(
          id: 'speaker-2',
          label: 'Speaker 2',
          embedding: const <double>[0, 1],
          sampleCount: 1,
          createdAt: now,
          updatedAt: now,
        );
        await store.saveProfiles(<SpeakerProfile>[partial, other]);
        final workers = <_FakeConversationWorker>[];
        final cleanup = Completer<void>();
        final service = ConversationAnalysisService(
          log: (_, _, {bool isError = false}) {},
          onChanged: () {},
          sharedAudioExportStore: SharedAudioExportStore(isAndroid: false),
          recordStore: store,
          clock: () => now,
          workerLoader:
              ({
                required onResult,
                required onFailure,
                required signatureMatchThreshold,
              }) async {
                final worker = _FakeConversationWorker(
                  onResult,
                  onFailure,
                  cleanup: workers.isEmpty ? cleanup.future : null,
                );
                workers.add(worker);
                return worker;
              },
        );
        addTearDown(() async {
          if (!cleanup.isCompleted) cleanup.complete();
          await service.dispose();
          await temporary.delete(recursive: true);
        });
        await service.initialize();
        expect(service.acceptedEnrollmentSamples, 1);
        final wav = File('${temporary.path}/synthetic.wav')
          ..writeAsBytesSync(<int>[0, 0]);
        final raw = File('${temporary.path}/synthetic.raw.txt')
          ..writeAsStringSync('Synthetic transcript.');
        final oldId = '${now.microsecondsSinceEpoch + 1}-old';
        service.acceptFinalizedSegment(oldId, wav.path);
        await _waitUntil(
          () => workers.isNotEmpty && workers.first.analyzed.isNotEmpty,
        );
        final old = workers.first;
        if (finishBeforeReset) {
          old.complete(oldId, wav.path, partial, now);
        }
        now = now.add(const Duration(seconds: 10));
        await service.resetSpeakerIdentification().timeout(
          const Duration(seconds: 2),
        );
        expect(
          cleanup.isCompleted,
          isFalse,
          reason: 'Reset must not wait for native cleanup.',
        );
        expect(service.acceptedEnrollmentSamples, 0);
        expect(service.pendingCount, 0);
        expect(service.state, 'waiting_for_enrollment_speech');
        expect(await store.loadPendingJobs(), isEmpty);
        expect((await store.loadProfiles()).map((p) => p.id), <String>[
          other.id,
        ]);
        expect(await wav.exists(), isTrue);
        expect(await raw.readAsString(), 'Synthetic transcript.');
        old.complete(oldId, wav.path, partial, now);
        old.onFailure(oldId, StateError('Synthetic late failure'));
        expect(service.error, isNull);
        expect(service.acceptedEnrollmentSamples, 0);
        service.acceptFinalizedSegment(oldId, wav.path);
        expect(
          service.pendingCount,
          0,
          reason: 'Speech begun before reset cannot enroll.',
        );
        final nextId = '${now.microsecondsSinceEpoch + 1}-new';
        service.acceptFinalizedSegment(nextId, wav.path);
        expect(service.pendingCount, 1);
        expect(workers, hasLength(1));
        cleanup.complete();
        await _waitUntil(
          () => workers.length == 2 && workers.last.analyzed.isNotEmpty,
        );
        expect(workers.last.analyzed, <String>[nextId]);
        workers.last.complete(nextId, wav.path, partial, now);
        await _waitUntil(
          () => service.state == 'waiting_for_enrollment_speech',
        );
        expect(service.acceptedEnrollmentSamples, 1);
        expect(service.pendingCount, 0);
      },
    );
  }

  test(
    'reset during model loading discards the old startup and accepts new speech',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final temporary = await Directory.systemTemp.createTemp(
        'workbench-enrollment-loading.',
      );
      final store = ConversationRecordStore(
        supportDirectory: () async => temporary,
      );
      final loaded = Completer<void>();
      final workers = <_FakeConversationWorker>[];
      var now = DateTime.utc(2026, 1, 1);
      final service = ConversationAnalysisService(
        log: (_, _, {bool isError = false}) {},
        onChanged: () {},
        sharedAudioExportStore: SharedAudioExportStore(isAndroid: false),
        recordStore: store,
        clock: () => now,
        workerLoader:
            ({
              required onResult,
              required onFailure,
              required signatureMatchThreshold,
            }) async {
              final worker = _FakeConversationWorker(onResult, onFailure);
              workers.add(worker);
              if (workers.length == 1) await loaded.future;
              return worker;
            },
      );
      addTearDown(() async {
        if (!loaded.isCompleted) loaded.complete();
        await service.dispose();
        await temporary.delete(recursive: true);
      });
      await service.initialize();
      final wav = File('${temporary.path}/synthetic.wav')
        ..writeAsBytesSync(<int>[0, 0]);
      service.acceptFinalizedSegment(
        '${now.microsecondsSinceEpoch + 1}-old',
        wav.path,
      );
      await _waitUntil(() => workers.length == 1);
      now = now.add(const Duration(seconds: 10));
      await service.resetSpeakerIdentification();
      expect(service.isStarting, isFalse);
      final nextId = '${now.microsecondsSinceEpoch + 1}-new';
      service.acceptFinalizedSegment(nextId, wav.path);
      loaded.complete();
      await _waitUntil(
        () => workers.length == 2 && workers.last.analyzed.isNotEmpty,
      );
      expect(workers.first.disposed, isTrue);
      expect(workers.first.analyzed, isEmpty);
      expect(workers.last.analyzed, <String>[nextId]);
      expect(service.error, isNull);
      expect(service.state, 'enrolling');
    },
  );

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

final class _FakeConversationWorker implements ConversationAnalysisWorker {
  _FakeConversationWorker(this.onResult, this.onFailure, {this.cleanup});

  final ConversationAnalysisResultSink onResult;
  final ConversationAnalysisFailureSink onFailure;
  final Future<void>? cleanup;
  final List<String> analyzed = <String>[];
  bool disposed = false;
  @override
  bool isReady = false;

  @override
  Future<void> start() async {
    isReady = true;
  }

  @override
  void analyze({
    required String segmentId,
    required String wavPath,
    required Iterable<SpeakerProfile> profiles,
    required bool enrollment,
    double? signatureMatchThreshold,
  }) {
    analyzed.add(segmentId);
  }

  void complete(
    String id,
    String wavPath,
    SpeakerProfile primary,
    DateTime now,
  ) {
    onResult(
      ConversationAnalysisResult(
        record: ConversationRecord(
          id: id,
          audioPath: wavPath,
          textPath: '$wavPath.conversation.txt',
          metadataPath: '$wavPath.conversation.json',
          updatedAt: now,
          utterances: const <ConversationUtterance>[],
        ),
        profiles: <SpeakerProfile>[primary],
        enrollment: true,
        audioMs: 1000,
        analysisMs: 10,
      ),
    );
  }

  @override
  Future<void> restartForTest() async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    isReady = false;
    await cleanup;
  }
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
