import 'dart:async';

import 'package:even_g2_r1_poc/src/audio/audio_pipeline_coordinator.dart';
import 'package:even_g2_r1_poc/src/wearable_controller.dart';
import 'package:even_g2_r1_poc/src/websocket/g2_agent_history_state.dart';
import 'package:even_g2_r1_poc/src/websocket/voice_websocket_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'primary STT dispatch does not await conversation analysis handoff',
    () async {
      var primaryDispatched = false;
      var conversationDispatched = false;
      Object? conversationError;

      dispatchFinalizedSpeechConsumers(
        dispatchPrimaryTranscription: () => primaryDispatched = true,
        dispatchConversationAnalysis: () {
          conversationDispatched = true;
          throw StateError('synthetic independent worker failure');
        },
        onConversationDispatchError: (error) => conversationError = error,
      );

      expect(primaryDispatched, isTrue);
      expect(
        conversationDispatched,
        isFalse,
        reason: 'The optional path must be scheduled independently.',
      );

      await Future<void>.delayed(Duration.zero);
      expect(conversationDispatched, isTrue);
      expect(conversationError, isA<StateError>());
    },
  );

  test(
    'coalesces duplicate display work while the first render is active',
    () async {
      final queue = CoalescedDisplayQueue();
      final started = Completer<void>();
      final release = Completer<void>();
      var renders = 0;

      Future<void> render() async {
        renders++;
        if (!started.isCompleted) {
          started.complete();
        }
        await release.future;
      }

      final first = queue.schedule(key: 'same-page', render: render);
      await started.future;
      final duplicates = List<Future<void>>.generate(
        20,
        (_) => queue.schedule(key: 'same-page', render: render),
      );
      release.complete();
      await Future.wait(<Future<void>>[first, ...duplicates]);

      expect(renders, 1);
    },
  );

  test('renders a changed display once after the active render', () async {
    final queue = CoalescedDisplayQueue();
    final started = Completer<void>();
    final release = Completer<void>();
    final rendered = <String>[];

    final first = queue.schedule(
      key: 'selector',
      render: () async {
        rendered.add('selector');
        started.complete();
        await release.future;
      },
    );
    await started.future;
    final detail = queue.schedule(
      key: 'detail-1',
      render: () async => rendered.add('detail-1'),
    );
    final duplicate = queue.schedule(
      key: 'detail-1',
      render: () async => rendered.add('duplicate'),
    );
    release.complete();
    await Future.wait(<Future<void>>[first, detail, duplicate]);

    expect(rendered, <String>['selector', 'detail-1']);
  });

  test('renders only the latest swipe page after an active render', () async {
    final queue = CoalescedDisplayQueue();
    final started = Completer<void>();
    final release = Completer<void>();
    final rendered = <String>[];

    final first = queue.schedule(
      key: 'detail-1',
      render: () async {
        rendered.add('detail-1');
        started.complete();
        await release.future;
      },
    );
    await started.future;
    final second = queue.schedule(
      key: 'detail-2',
      render: () async => rendered.add('detail-2'),
    );
    final third = queue.schedule(
      key: 'detail-3',
      render: () async => rendered.add('detail-3'),
    );
    final fourth = queue.schedule(
      key: 'detail-4',
      render: () async => rendered.add('detail-4'),
    );
    release.complete();
    await Future.wait(<Future<void>>[first, second, third, fourth]);

    expect(rendered, <String>['detail-1', 'detail-4']);
  });

  test('retries a display key after a failed render', () async {
    final queue = CoalescedDisplayQueue();
    var attempts = 0;
    var failures = 0;

    await queue.schedule(
      key: 'detail',
      render: () async {
        attempts++;
        throw StateError('synthetic display failure');
      },
      onError: (_) => failures++,
    );
    await queue.schedule(key: 'detail', render: () async => attempts++);

    expect(attempts, 2);
    expect(failures, 1);
  });

  test('double tap requests an agent update outside a voice memo', () {
    expect(
      resolveWearableGestureAction(gestureType: 3, memoActive: false),
      WearableGestureAction.requestAgentSummary,
    );
  });

  test('double tap keeps voice memo finalization priority', () {
    expect(
      resolveWearableGestureAction(gestureType: 3, memoActive: true),
      WearableGestureAction.finishMemo,
    );
  });

  test('other gestures remain available to the normal gesture flow', () {
    for (final gestureType in <int>[0, 1, 2, 4]) {
      expect(
        resolveWearableGestureAction(
          gestureType: gestureType,
          memoActive: false,
        ),
        WearableGestureAction.ignore,
      );
    }
  });

  test('single tap commits a queued transcript before opening history', () {
    expect(
      resolveQueuedTranscriptTapAction(
        gestureType: 0,
        memoActive: false,
        queuedTranscript: 'Hey Flux, run the checks.',
      ),
      QueuedTranscriptTapAction.correctAndRoute,
    );
    expect(
      resolveQueuedTranscriptTapAction(
        gestureType: 0,
        memoActive: false,
        queuedTranscript: 'Save this locally.',
      ),
      QueuedTranscriptTapAction.save,
    );
    expect(
      resolveQueuedTranscriptTapAction(
        gestureType: 0,
        memoActive: false,
        queuedTranscript: 'Please, hey Flux, run the checks.',
      ),
      QueuedTranscriptTapAction.save,
    );
  });

  test('queued transcript tap does not override active Memo', () {
    expect(
      resolveQueuedTranscriptTapAction(
        gestureType: 0,
        memoActive: true,
        queuedTranscript: 'Hey Flux, run the checks.',
      ),
      QueuedTranscriptTapAction.none,
    );
  });

  test('detail tap activates, exits, sends, and dismisses by state', () {
    expect(
      resolveAgentDetailTranscriptTapAction(
        gestureType: 0,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
        listenModeSelected: false,
        speechState: null,
      ),
      AgentDetailTranscriptTapAction.activateListenMode,
    );
    expect(
      resolveAgentDetailTranscriptTapAction(
        gestureType: 0,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
        listenModeSelected: true,
        speechState: null,
      ),
      AgentDetailTranscriptTapAction.exitListenMode,
    );
    expect(
      resolveAgentDetailTranscriptTapAction(
        gestureType: 0,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
        listenModeSelected: true,
        speechState: G2AgentDetailSpeechState.listening,
      ),
      AgentDetailTranscriptTapAction.finishSpeech,
    );
    expect(
      resolveAgentDetailTranscriptTapAction(
        gestureType: 0,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
        listenModeSelected: false,
        speechState: G2AgentDetailSpeechState.sending,
      ),
      AgentDetailTranscriptTapAction.dismiss,
    );
    expect(
      resolveAgentDetailTranscriptTapAction(
        gestureType: 1,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
        listenModeSelected: false,
        speechState: G2AgentDetailSpeechState.sending,
      ),
      AgentDetailTranscriptTapAction.none,
    );
    expect(
      resolveAgentDetailTranscriptTapAction(
        gestureType: 0,
        isAgentDetail: false,
        detailControl: G2AgentDetailControl.listen,
        listenModeSelected: false,
        speechState: null,
      ),
      AgentDetailTranscriptTapAction.none,
    );
    expect(
      resolveAgentDetailTranscriptTapAction(
        gestureType: 0,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.back,
        listenModeSelected: false,
        speechState: null,
      ),
      AgentDetailTranscriptTapAction.returnToSelector,
    );
  });

  test('detail swipes move between controls before paging', () {
    expect(
      resolveAgentDetailSwipeAction(
        gestureType: 2,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
      ),
      AgentDetailSwipeAction.nextPage,
    );
    expect(
      resolveAgentDetailSwipeAction(
        gestureType: 2,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
      ),
      AgentDetailSwipeAction.nextPage,
    );
    expect(
      resolveAgentDetailSwipeAction(
        gestureType: 1,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
      ),
      AgentDetailSwipeAction.focusBack,
    );
    expect(
      resolveAgentDetailSwipeAction(
        gestureType: 2,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.back,
      ),
      AgentDetailSwipeAction.focusListen,
    );
    expect(
      resolveAgentDetailSwipeAction(
        gestureType: 1,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.back,
      ),
      AgentDetailSwipeAction.previousPage,
    );
    expect(
      resolveAgentDetailSwipeAction(
        gestureType: 0,
        isAgentDetail: true,
        detailControl: G2AgentDetailControl.listen,
      ),
      AgentDetailSwipeAction.none,
    );
    expect(
      resolveAgentDetailSwipeAction(
        gestureType: 2,
        isAgentDetail: false,
        detailControl: G2AgentDetailControl.listen,
      ),
      AgentDetailSwipeAction.nextPage,
    );
  });

  test('only a Gemma-corrected final transcript can route', () {
    expect(
      finalTranscriptCanRoute(
        const FinalTranscriptDelivery(
          segmentId: 'segment-1',
          rawTranscript: 'pull the ladies changes',
          transcript: 'Pull the latest changes.',
          isCorrected: true,
        ),
      ),
      isTrue,
    );
    expect(
      finalTranscriptCanRoute(
        const FinalTranscriptDelivery(
          segmentId: 'segment-1',
          rawTranscript: 'pull the ladies changes',
          transcript: 'pull the ladies changes',
          isCorrected: false,
        ),
      ),
      isFalse,
    );
  });

  test('selected-agent delivery uses the retrying outbound queue', () {
    expect(
      deliveryModeForAgentRoute(explicitlySelected: true),
      VoiceWebSocketDeliveryMode.queued,
    );
    expect(
      deliveryModeForAgentRoute(explicitlySelected: false),
      VoiceWebSocketDeliveryMode.queued,
    );
  });

  test('history swipes follow the G2 viewport direction', () {
    expect(
      resolveAgentHistorySelectionMove(1),
      AgentHistorySelectionMove.previous,
    );
    expect(resolveAgentHistorySelectionMove(2), AgentHistorySelectionMove.next);
    expect(resolveAgentHistorySelectionMove(3), AgentHistorySelectionMove.none);
  });

  test(
    'updates Sent display while acknowledged message persistence runs',
    () async {
      final persistenceStarted = Completer<void>();
      final releasePersistence = Completer<void>();
      var displayUpdated = false;

      final completed = completeAgentRouteConsumers(
        updateDisplay: () async {
          displayUpdated = true;
        },
        persistAcknowledgedMessage: () async {
          persistenceStarted.complete();
          await releasePersistence.future;
        },
      );

      await persistenceStarted.future;
      expect(displayUpdated, isTrue);

      var routeCompleted = false;
      unawaited(completed.then((_) => routeCompleted = true));
      await Future<void>.delayed(Duration.zero);
      expect(routeCompleted, isFalse);

      releasePersistence.complete();
      await completed;
      expect(routeCompleted, isTrue);
    },
  );

  test(
    'does not persist a message when the send was not acknowledged',
    () async {
      var displayUpdated = false;

      await completeAgentRouteConsumers(
        updateDisplay: () async {
          displayUpdated = true;
        },
      );

      expect(displayUpdated, isTrue);
    },
  );
}
