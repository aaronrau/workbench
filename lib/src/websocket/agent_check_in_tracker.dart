/// Phase of an on-demand agent check-in started from the G2 agent menu.
///
/// Selecting an agent sends one `summary.request` for it. While that request
/// is outstanding the glasses annotate the agent name; a correlated
/// `summary.result`, a bounded timeout, or an unavailable endpoint retires the
/// annotation.
enum AgentCheckInPhase { checking, noUpdate, unavailable }

/// Tracks which configured agents have an outstanding check-in and which
/// annotation each one currently contributes to the G2 agent menu.
///
/// The tracker is pure: it owns no timers, sockets, or storage. The controller
/// arms the bounded timers and pushes [annotations] into the render state.
final class AgentCheckInTracker {
  static const String checkingLabel = ' · Checking in';
  static const String noUpdateLabel = ' · No update';
  static const String unavailableLabel = ' · Unavailable';

  final Map<String, _AgentCheckIn> _checkIns = <String, _AgentCheckIn>{};
  final Map<String, String> _agentsByRequestId = <String, String>{};

  /// Agent-name key to its rendered annotation, keyed by lowercase name.
  Map<String, String> get annotations => Map<String, String>.unmodifiable(
    _checkIns.map((key, value) => MapEntry(key, _labelFor(value.phase))),
  );

  bool isChecking(String agent) =>
      _checkIns[_key(agent)]?.phase == AgentCheckInPhase.checking;

  /// Starts a check-in for [agent]. Returns false when one is already in
  /// flight, so a repeated selection cannot send a second request.
  bool begin(String agent) {
    final key = _key(agent);
    if (key.isEmpty || isChecking(key)) {
      return false;
    }
    _releaseRequestIds(key);
    _checkIns[key] = _AgentCheckIn(
      agent: agent.trim(),
      phase: AgentCheckInPhase.checking,
    );
    return true;
  }

  /// Associates the accepted `summary.request` id with an in-flight check-in.
  void bindRequest(String agent, String requestId) {
    final key = _key(agent);
    final normalized = requestId.trim();
    final checkIn = _checkIns[key];
    if (normalized.isEmpty ||
        checkIn == null ||
        checkIn.phase != AgentCheckInPhase.checking) {
      return;
    }
    _releaseRequestIds(key);
    checkIn.requestId = normalized;
    _agentsByRequestId[normalized] = key;
  }

  /// Canonical agent name awaiting the response for [requestId], or null.
  ///
  /// The inbound funnel uses this so a `summary.result` that omits the agent
  /// name still indexes under the agent the wearer selected.
  String? agentForRequest(String? requestId) {
    final normalized = requestId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return _checkIns[_agentsByRequestId[normalized]]?.agent;
  }

  /// Retires the check-in whose request produced this response.
  bool completeForRequest(String? requestId) {
    final normalized = requestId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return false;
    }
    final key = _agentsByRequestId[normalized];
    return key == null ? false : complete(key);
  }

  /// Retires the check-in for [agent] without leaving a notice.
  bool complete(String agent) {
    final key = _key(agent);
    if (!_checkIns.containsKey(key)) {
      return false;
    }
    _releaseRequestIds(key);
    _checkIns.remove(key);
    return true;
  }

  /// Replaces an in-flight check-in with a short-lived failure notice.
  bool fail(String agent, AgentCheckInPhase phase) {
    final key = _key(agent);
    final checkIn = _checkIns[key];
    if (checkIn == null || phase == AgentCheckInPhase.checking) {
      return false;
    }
    _releaseRequestIds(key);
    checkIn
      ..phase = phase
      ..requestId = null;
    return true;
  }

  /// Clears a retained [fail] notice. An agent that started a newer check-in
  /// keeps its `Checking in` annotation.
  bool clearNotice(String agent) {
    final key = _key(agent);
    final checkIn = _checkIns[key];
    if (checkIn == null || checkIn.phase == AgentCheckInPhase.checking) {
      return false;
    }
    _checkIns.remove(key);
    return true;
  }

  void clearAll() {
    _checkIns.clear();
    _agentsByRequestId.clear();
  }

  void _releaseRequestIds(String key) {
    _agentsByRequestId.removeWhere((_, value) => value == key);
  }

  static String _labelFor(AgentCheckInPhase phase) => switch (phase) {
    AgentCheckInPhase.checking => checkingLabel,
    AgentCheckInPhase.noUpdate => noUpdateLabel,
    AgentCheckInPhase.unavailable => unavailableLabel,
  };

  static String _key(String agent) => agent.trim().toLowerCase();
}

final class _AgentCheckIn {
  _AgentCheckIn({required this.agent, required this.phase});

  final String agent;
  AgentCheckInPhase phase;
  String? requestId;
}
