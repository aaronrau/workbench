import 'package:even_g2_r1_poc/src/websocket/agent_check_in_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('annotates only the agent with an outstanding check-in', () {
    final tracker = AgentCheckInTracker();

    expect(tracker.begin('Pike'), true);
    expect(tracker.isChecking('Pike'), true);
    expect(tracker.annotations, <String, String>{
      'pike': AgentCheckInTracker.checkingLabel,
    });
    expect(tracker.annotations.containsKey('agent two'), false);
  });

  test('refuses a second check-in while one is in flight', () {
    final tracker = AgentCheckInTracker();

    expect(tracker.begin('Pike'), true);
    tracker.bindRequest('Pike', 'request-1');
    expect(tracker.begin('Pike'), false);
    expect(tracker.begin('  pike  '), false);
    expect(tracker.agentForRequest('request-1'), 'Pike');

    expect(tracker.begin('Agent Two'), true);
    expect(tracker.annotations, hasLength(2));
  });

  test('matches an agent by request id regardless of name casing', () {
    final tracker = AgentCheckInTracker();
    tracker.begin('Agent One');
    tracker.bindRequest('agent one', ' request-7 ');

    expect(tracker.agentForRequest('request-7'), 'Agent One');
    expect(tracker.agentForRequest('other-request'), isNull);
    expect(tracker.agentForRequest(null), isNull);
    expect(tracker.agentForRequest('   '), isNull);
  });

  test('retires the annotation for a correlated response', () {
    final tracker = AgentCheckInTracker();
    tracker.begin('Pike');
    tracker.bindRequest('Pike', 'request-1');

    expect(tracker.completeForRequest('request-1'), true);
    expect(tracker.annotations, isEmpty);
    expect(tracker.agentForRequest('request-1'), isNull);
    expect(tracker.completeForRequest('request-1'), false);
  });

  test('leaves other agents untouched when one response arrives', () {
    final tracker = AgentCheckInTracker();
    tracker.begin('Pike');
    tracker.bindRequest('Pike', 'request-1');
    tracker.begin('Agent Two');
    tracker.bindRequest('Agent Two', 'request-2');

    expect(tracker.completeForRequest('request-2'), true);
    expect(tracker.annotations, <String, String>{
      'pike': AgentCheckInTracker.checkingLabel,
    });
  });

  test('replaces an in-flight check-in with a bounded notice', () {
    final tracker = AgentCheckInTracker();
    tracker.begin('Pike');
    tracker.bindRequest('Pike', 'request-1');

    expect(tracker.fail('Pike', AgentCheckInPhase.unavailable), true);
    expect(tracker.annotations, <String, String>{
      'pike': AgentCheckInTracker.unavailableLabel,
    });
    expect(tracker.isChecking('Pike'), false);
    // A late response can no longer clear a retired request.
    expect(tracker.agentForRequest('request-1'), isNull);

    expect(tracker.clearNotice('Pike'), true);
    expect(tracker.annotations, isEmpty);
  });

  test('renders the timeout notice separately from the failure notice', () {
    final tracker = AgentCheckInTracker();
    tracker.begin('Pike');

    expect(tracker.fail('Pike', AgentCheckInPhase.noUpdate), true);
    expect(tracker.annotations, <String, String>{
      'pike': AgentCheckInTracker.noUpdateLabel,
    });
  });

  test(
    'never downgrades a check-in to the checking phase or an unknown agent',
    () {
      final tracker = AgentCheckInTracker();

      expect(tracker.fail('Pike', AgentCheckInPhase.unavailable), false);
      tracker.begin('Pike');
      expect(tracker.fail('Pike', AgentCheckInPhase.checking), false);
      expect(tracker.annotations, <String, String>{
        'pike': AgentCheckInTracker.checkingLabel,
      });
    },
  );

  test('keeps a newer check-in when an older notice expires', () {
    final tracker = AgentCheckInTracker();
    tracker.begin('Pike');
    tracker.fail('Pike', AgentCheckInPhase.noUpdate);

    // The wearer reselects the agent before the notice cleared.
    expect(tracker.begin('Pike'), true);
    expect(tracker.clearNotice('Pike'), false);
    expect(tracker.annotations, <String, String>{
      'pike': AgentCheckInTracker.checkingLabel,
    });
  });

  test('ignores an empty agent name and an unbound request id', () {
    final tracker = AgentCheckInTracker();

    expect(tracker.begin('   '), false);
    tracker.begin('Pike');
    tracker.bindRequest('Pike', '   ');
    expect(tracker.agentForRequest('   '), isNull);
    tracker.bindRequest('Unknown Agent', 'request-9');
    expect(tracker.agentForRequest('request-9'), isNull);
  });

  test('clears every check-in for a configuration change', () {
    final tracker = AgentCheckInTracker();
    tracker.begin('Pike');
    tracker.bindRequest('Pike', 'request-1');
    tracker.begin('Agent Two');

    tracker.clearAll();

    expect(tracker.annotations, isEmpty);
    expect(tracker.agentForRequest('request-1'), isNull);
    expect(tracker.isChecking('Pike'), false);
  });
}
