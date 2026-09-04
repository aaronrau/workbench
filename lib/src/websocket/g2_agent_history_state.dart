import 'agent_exchange_store.dart';
import '../protocol/g2_text_layout.dart';
import 'selected_agent_transcript_session.dart';
import 'voice_websocket_config.dart';

enum G2AgentHistoryMode { closed, selector, waiting, detail }

enum G2AgentHistoryEntryKind { dismiss, memo, agent }

enum G2AgentDetailSpeechState { listening, sending, sent, saved }

enum G2AgentDetailControl { back, listen }

final class G2AgentHistoryEntry {
  const G2AgentHistoryEntry({
    required this.kind,
    required this.label,
    required this.preview,
    this.exchange,
    this.detail,
  });

  final G2AgentHistoryEntryKind kind;
  final String label;
  final String preview;
  final AgentExchangeView? exchange;
  final String? detail;
}

final class G2AgentHistoryState {
  static const int maximumAgents = VoiceWebSocketConfig.maximumAgentNames;
  static const int selectorEntryMaximumLines = 2;
  // Keep the selector shorter than the physical nine-row text surface. A
  // full-height text frame can enter the firmware's own scrolling path while
  // Work Bench is also handling the same swipe gesture.
  static const int selectorMaximumRenderedRows = 8;
  static const int maximumPageCharacters =
      G2TextLayout.historyMaximumPageCharacters;
  static const int standardDetailBodyLinesPerPage = 8;
  static const int agentDetailBodyLinesPerPage = 7;
  static const int detailPageOverlapLines = 1;
  static const int maximumLoadedMessagesPerAgent = 64;
  static const int maximumAgentHistoryDetailPages = 8;
  static const int maximumAgentHistorySourceRunes = 8192;
  static const String agentHistoryOverflowText =
      'More history is available on phone.';
  static const G2TextLayout _layout = G2TextLayout.history;
  // Keep selector and control content at the same horizontal position when
  // the cursor moves. Selected and empty gutters are all 25 px in the G2 font,
  // with two spaces after a cursor for visual separation.
  static const String _selectedPointerPrefix = ' >  ';
  static const String _emptyPointerPrefix = '     ';
  static const String _selectedBackControlPrefix = ' <  ';
  static const String _selectedForwardControlPrefix = ' >  ';
  static const String _emptyControlPrefix = '     ';

  G2AgentHistoryMode mode = G2AgentHistoryMode.closed;
  List<G2AgentHistoryEntry> entries = const <G2AgentHistoryEntry>[];
  int selectedIndex = 0;
  int _selectorWindowStart = 1;
  String? waitingExchangeId;
  String? detailTitle;
  String? detailText;
  bool detailTitleIsAgent = false;
  bool detailListenModeSelected = false;
  G2AgentDetailControl detailControl = G2AgentDetailControl.listen;
  int detailPageIndex = 0;
  int? _detailPageIndexBeforeListenMode;
  bool waitingTimedOut = false;
  String? detailSpeechSegmentId;
  String? detailSpeechTranscript;
  G2AgentDetailSpeechState? detailSpeechState;
  SelectedAgentCorrectionPreviewState detailCorrectionPreviewState =
      SelectedAgentCorrectionPreviewState.off;
  bool detailTranscriptionPending = false;
  bool detailTranscriptionIndicatorVisible = false;
  String? _cachedDetailBody;
  int? _cachedDetailRowsPerPage;
  bool? _cachedDetailHistoryBounded;
  List<List<String>>? _cachedDetailPages;

  bool get isOpen => mode != G2AgentHistoryMode.closed;
  bool get isAgentDetail =>
      detailTitleIsAgent && mode == G2AgentHistoryMode.detail;
  String? get openDetailAgent {
    if (!detailTitleIsAgent ||
        (mode != G2AgentHistoryMode.detail &&
            mode != G2AgentHistoryMode.waiting)) {
      return null;
    }
    final agent = detailTitle?.trim();
    return agent == null || agent.isEmpty ? null : agent;
  }

  G2AgentHistoryEntry? get selected =>
      entries.isEmpty ? null : entries[selectedIndex];
  bool get isAgentDetailSpeechTarget =>
      detailListenModeSelected &&
      detailTitleIsAgent &&
      (mode == G2AgentHistoryMode.detail || mode == G2AgentHistoryMode.waiting);
  String? get selectedSpeechAgent {
    if (!isAgentDetailSpeechTarget) {
      return null;
    }
    final title = detailTitle?.trim();
    return title == null || title.isEmpty ? null : title;
  }

  String? get activeDetailSpeechSegmentId => switch (detailSpeechState) {
    G2AgentDetailSpeechState.listening ||
    G2AgentDetailSpeechState.sending => detailSpeechSegmentId,
    _ => null,
  };

  int get detailPageCount => _detailPages().length;
  int get detailBodyLinesPerPage => detailTitleIsAgent
      ? agentDetailBodyLinesPerPage
      : standardDetailBodyLinesPerPage;

  void open({
    required List<String> agents,
    required List<AgentExchangeView> exchanges,
    List<AgentMessageView> messages = const <AgentMessageView>[],
    String? memo,
  }) {
    final byAgent = <String, AgentExchangeView>{
      for (final exchange in exchanges) exchange.agent.toLowerCase(): exchange,
    };
    final configuredAgents = agents
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final recentMessages = messages.toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final latestMessageByAgent = <String, AgentMessageView>{};
    for (final message in recentMessages) {
      latestMessageByAgent.putIfAbsent(
        message.agent.trim().toLowerCase(),
        () => message,
      );
    }
    final latestReceivedAtByAgent = <String, DateTime>{};
    for (final message in recentMessages) {
      if (message.direction != AgentMessageDirection.received) {
        continue;
      }
      latestReceivedAtByAgent.putIfAbsent(
        message.agent.trim().toLowerCase(),
        () => message.updatedAt.toUtc(),
      );
    }
    final recentExchanges = exchanges.toList(growable: false)
      ..sort((a, b) => _exchangeUpdatedAt(b).compareTo(_exchangeUpdatedAt(a)));
    for (final exchange in recentExchanges) {
      final receivedAt = _latestExchangeReceivedAt(exchange);
      if (receivedAt == null) {
        continue;
      }
      final key = exchange.agent.trim().toLowerCase();
      final indexed = latestReceivedAtByAgent[key];
      if (indexed == null || receivedAt.isAfter(indexed)) {
        latestReceivedAtByAgent[key] = receivedAt;
      }
    }
    final rows = <G2AgentHistoryEntry>[
      const G2AgentHistoryEntry(
        kind: G2AgentHistoryEntryKind.dismiss,
        label: '[x]',
        preview: '',
      ),
    ];
    final rankedAgents =
        configuredAgents.asMap().entries.toList(growable: false)
          ..sort((left, right) {
            final leftReceivedAt =
                latestReceivedAtByAgent[left.value.toLowerCase()];
            final rightReceivedAt =
                latestReceivedAtByAgent[right.value.toLowerCase()];
            if (leftReceivedAt == null && rightReceivedAt == null) {
              return left.key.compareTo(right.key);
            }
            if (leftReceivedAt == null) {
              return 1;
            }
            if (rightReceivedAt == null) {
              return -1;
            }
            final byRecency = rightReceivedAt.compareTo(leftReceivedAt);
            return byRecency != 0 ? byRecency : left.key.compareTo(right.key);
          });
    for (final rankedAgent in rankedAgents.take(maximumAgents)) {
      final agent = rankedAgent.value;
      final exchange = byAgent[agent.toLowerCase()];
      final latestMessage = latestMessageByAgent[agent.toLowerCase()];
      final message = latestMessage == null
          ? _latestExchangeMessage(exchange, agent)
          : _stripSpeakerPrefix(latestMessage.message, agent);
      rows.add(
        G2AgentHistoryEntry(
          kind: G2AgentHistoryEntryKind.agent,
          label: agent,
          preview: message.isEmpty ? 'No messages' : _oneLine(message),
          exchange: exchange,
        ),
      );
    }
    rows.add(
      G2AgentHistoryEntry(
        kind: G2AgentHistoryEntryKind.memo,
        label: 'Memo',
        preview: _oneLine(memo ?? '').isEmpty
            ? 'No saved memo'
            : _oneLine(memo!),
        detail: _oneLine(memo ?? '').isEmpty ? null : memo!.trim(),
      ),
    );
    entries = List<G2AgentHistoryEntry>.unmodifiable(rows);
    selectedIndex = 0;
    _selectorWindowStart = 1;
    waitingExchangeId = null;
    detailTitle = null;
    detailText = null;
    detailTitleIsAgent = false;
    detailListenModeSelected = false;
    detailControl = G2AgentDetailControl.listen;
    detailPageIndex = 0;
    _detailPageIndexBeforeListenMode = null;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.selector;
  }

  void selectNext() {
    if (mode != G2AgentHistoryMode.selector || entries.isEmpty) {
      return;
    }
    selectedIndex = (selectedIndex + 1) % entries.length;
    if (selectedIndex == 0) {
      _selectorWindowStart = 1;
      return;
    }
    final revealIndex = selectedIndex < entries.length - 1
        ? selectedIndex + 1
        : selectedIndex;
    while (!_selectorVisibleContentIndexes().contains(revealIndex) &&
        _selectorWindowStart < entries.length - 1) {
      _selectorWindowStart++;
    }
  }

  void selectPrevious() {
    if (mode != G2AgentHistoryMode.selector || entries.isEmpty) {
      return;
    }
    selectedIndex = (selectedIndex - 1 + entries.length) % entries.length;
    if (selectedIndex == entries.length - 1) {
      _selectorWindowStart = _lastSelectorWindowStart();
      return;
    }
    if (selectedIndex == 0) {
      _selectorWindowStart = 1;
      return;
    }
    final revealIndex = selectedIndex > 1 ? selectedIndex - 1 : selectedIndex;
    if (!_selectorVisibleContentIndexes().contains(revealIndex)) {
      _selectorWindowStart = revealIndex;
    }
  }

  void showSelectedDetail() {
    final entry = selected;
    if (entry == null) {
      return;
    }
    detailTitle = entry.label;
    detailTitleIsAgent = entry.kind == G2AgentHistoryEntryKind.agent;
    detailListenModeSelected = false;
    detailControl = G2AgentDetailControl.listen;
    _detailPageIndexBeforeListenMode = null;
    detailText = switch (entry.kind) {
      G2AgentHistoryEntryKind.dismiss => '',
      G2AgentHistoryEntryKind.memo =>
        entry.detail?.trim().isNotEmpty == true
            ? entry.detail
            : 'No saved memo',
      G2AgentHistoryEntryKind.agent => _renderAgentConversations(
        entry.exchange == null
            ? const <AgentExchangeView>[]
            : <AgentExchangeView>[entry.exchange!],
      ),
    };
    detailPageIndex = 0;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.detail;
  }

  void showAgentConversations(List<AgentExchangeView> exchanges) {
    showAgentMessages(_agentMessagesFromExchanges(exchanges));
  }

  /// Opens the exact newest-message-first view used by the phone's selected
  /// agent tab. Direction remains part of the durable item but is intentionally
  /// omitted from the compact G2 row.
  void showAgentMessages(List<AgentMessageView> messages) {
    final entry = selected;
    if (entry == null || entry.kind != G2AgentHistoryEntryKind.agent) {
      return;
    }
    final normalizedAgent = entry.label.trim().toLowerCase();
    final retained =
        messages
            .where(
              (message) =>
                  message.agent.trim().toLowerCase() == normalizedAgent,
            )
            .toList(growable: false)
          ..sort((left, right) {
            final byTime = right.updatedAt.compareTo(left.updatedAt);
            return byTime != 0 ? byTime : right.id.compareTo(left.id);
          });
    detailTitle = entry.label;
    detailTitleIsAgent = true;
    detailListenModeSelected = false;
    detailControl = G2AgentDetailControl.listen;
    _detailPageIndexBeforeListenMode = null;
    detailText = _renderAgentMessages(retained);
    detailPageIndex = 0;
    waitingExchangeId = null;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.detail;
  }

  void showWaiting(AgentExchangeView exchange) {
    waitingExchangeId = exchange.id;
    detailTitle = exchange.agent;
    detailTitleIsAgent = true;
    detailListenModeSelected = false;
    detailControl = G2AgentDetailControl.listen;
    _detailPageIndexBeforeListenMode = null;
    detailText = 'Waiting for response…';
    detailPageIndex = 0;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.waiting;
  }

  bool acceptResponse(
    String exchangeId,
    String response, {
    DateTime? receivedAt,
  }) {
    if (mode != G2AgentHistoryMode.waiting || waitingExchangeId != exchangeId) {
      return false;
    }
    final message = _stripSpeakerPrefix(response, detailTitle ?? '');
    detailText = message.isEmpty
        ? 'Response received'
        : '${_formatTime(receivedAt ?? DateTime.now())} $message';
    detailPageIndex = 0;
    waitingExchangeId = null;
    waitingTimedOut = false;
    mode = G2AgentHistoryMode.detail;
    return true;
  }

  void markWaitingTimedOut() {
    if (mode != G2AgentHistoryMode.waiting) {
      return;
    }
    waitingTimedOut = true;
    detailText = 'Still waiting';
  }

  void showError(String title, String message) {
    waitingExchangeId = null;
    detailTitle = title;
    detailTitleIsAgent = true;
    detailListenModeSelected = false;
    detailControl = G2AgentDetailControl.listen;
    _detailPageIndexBeforeListenMode = null;
    detailText = message;
    detailPageIndex = 0;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.detail;
  }

  bool beginTargetedSpeech(String segmentId) {
    if (!isAgentDetailSpeechTarget) {
      return false;
    }
    detailSpeechSegmentId = segmentId;
    detailSpeechTranscript = null;
    detailSpeechState = G2AgentDetailSpeechState.listening;
    detailCorrectionPreviewState = SelectedAgentCorrectionPreviewState.waiting;
    detailTranscriptionPending = false;
    detailTranscriptionIndicatorVisible = false;
    detailPageIndex = 0;
    return true;
  }

  bool selectDetailListenMode() {
    if (!isAgentDetail ||
        detailControl != G2AgentDetailControl.listen ||
        detailListenModeSelected) {
      return false;
    }
    _detailPageIndexBeforeListenMode = detailPageIndex;
    detailListenModeSelected = true;
    _clearDetailSpeech();
    return true;
  }

  bool focusAgentBackControl() {
    if (!isAgentDetail || detailControl == G2AgentDetailControl.back) {
      return false;
    }
    detailControl = G2AgentDetailControl.back;
    return true;
  }

  bool focusAgentListenControl() {
    if (!isAgentDetail || detailControl == G2AgentDetailControl.listen) {
      return false;
    }
    detailControl = G2AgentDetailControl.listen;
    return true;
  }

  bool returnToSelector() {
    if (mode != G2AgentHistoryMode.detail &&
        mode != G2AgentHistoryMode.waiting) {
      return false;
    }
    waitingExchangeId = null;
    detailTitle = null;
    detailText = null;
    detailTitleIsAgent = false;
    detailListenModeSelected = false;
    detailControl = G2AgentDetailControl.listen;
    detailPageIndex = 0;
    _detailPageIndexBeforeListenMode = null;
    waitingTimedOut = false;
    _clearDetailSpeech();
    mode = G2AgentHistoryMode.selector;
    return true;
  }

  /// Replaces the durable body for an already-open matching agent without
  /// resetting its focused control or active speech/send lifecycle.
  bool refreshOpenAgentMessages({
    required String agent,
    required List<AgentMessageView> messages,
  }) {
    final currentAgent = openDetailAgent;
    if (currentAgent == null ||
        currentAgent.toLowerCase() != agent.trim().toLowerCase()) {
      return false;
    }
    detailText = _renderAgentMessagesFor(messages, currentAgent);
    waitingExchangeId = null;
    waitingTimedOut = false;
    mode = G2AgentHistoryMode.detail;
    detailPageIndex = 0;
    if (_detailPageIndexBeforeListenMode != null) {
      _detailPageIndexBeforeListenMode = 0;
    }
    return true;
  }

  bool exitDetailListenMode({bool preserveActiveSpeech = false}) {
    if (!isAgentDetail || !detailListenModeSelected) {
      return false;
    }
    detailListenModeSelected = false;
    final pageBeforeListenMode = _detailPageIndexBeforeListenMode;
    _detailPageIndexBeforeListenMode = null;
    if (!preserveActiveSpeech) {
      _clearDetailSpeech();
    }
    final lastPageIndex = detailPageCount - 1;
    detailPageIndex = (pageBeforeListenMode ?? 0).clamp(0, lastPageIndex);
    return true;
  }

  bool markTargetedSpeechSending(String segmentId) {
    if (!_ownsTargetedSpeech(segmentId) ||
        detailSpeechState != G2AgentDetailSpeechState.listening) {
      return false;
    }
    detailSpeechState = G2AgentDetailSpeechState.sending;
    detailPageIndex = 0;
    return true;
  }

  bool updateTargetedSpeechTranscript({
    required String segmentId,
    required String transcript,
  }) {
    if (!_ownsTargetedSpeech(segmentId) ||
        (detailSpeechState != G2AgentDetailSpeechState.listening &&
            detailSpeechState != G2AgentDetailSpeechState.sending)) {
      return false;
    }
    detailSpeechTranscript = transcript.trim();
    detailPageIndex = detailPageCount - 1;
    return true;
  }

  bool updateTargetedSpeechPreview({
    required String segmentId,
    required String transcript,
    required SelectedAgentCorrectionPreviewState previewState,
  }) {
    if (!_ownsTargetedSpeech(segmentId) ||
        detailSpeechState != G2AgentDetailSpeechState.listening) {
      return false;
    }
    detailSpeechTranscript = transcript.trim();
    detailCorrectionPreviewState = previewState;
    detailPageIndex = detailPageCount - 1;
    return true;
  }

  bool updateTargetedSpeechTranscription({
    required String segmentId,
    required bool pending,
    bool? indicatorVisible,
  }) {
    if (!_ownsTargetedSpeech(segmentId) ||
        detailSpeechState != G2AgentDetailSpeechState.listening) {
      return false;
    }
    final nextIndicator = pending && (indicatorVisible ?? true);
    if (detailTranscriptionPending == pending &&
        detailTranscriptionIndicatorVisible == nextIndicator) {
      return false;
    }
    detailTranscriptionPending = pending;
    detailTranscriptionIndicatorVisible = nextIndicator;
    return true;
  }

  /// Closes the manually bounded Listen Mode session while retaining ownership
  /// of [segmentId] until its corrected transcript projection arrives.
  bool finishTargetedSpeechCapture(String segmentId) {
    if (!_ownsTargetedSpeech(segmentId) ||
        detailSpeechState != G2AgentDetailSpeechState.listening ||
        !detailListenModeSelected) {
      return false;
    }
    detailSpeechState = G2AgentDetailSpeechState.sending;
    detailListenModeSelected = false;
    detailControl = G2AgentDetailControl.listen;
    detailTranscriptionPending = false;
    detailTranscriptionIndicatorVisible = false;
    final pageBeforeListenMode = _detailPageIndexBeforeListenMode;
    _detailPageIndexBeforeListenMode = null;
    final lastPageIndex = detailPageCount - 1;
    detailPageIndex = (pageBeforeListenMode ?? 0).clamp(0, lastPageIndex);
    return true;
  }

  bool showTargetedSpeechTranscript({
    required String segmentId,
    required String transcript,
  }) {
    if (!_ownsTargetedSpeech(segmentId)) {
      return false;
    }
    detailSpeechTranscript = transcript.trim();
    detailSpeechState = G2AgentDetailSpeechState.sending;
    detailPageIndex = 0;
    return true;
  }

  bool completeTargetedSpeech({
    required String segmentId,
    required String transcript,
    required bool sent,
  }) {
    if (!_ownsTargetedSpeech(segmentId)) {
      return false;
    }
    detailSpeechTranscript = transcript.trim();
    detailSpeechState = sent
        ? G2AgentDetailSpeechState.sent
        : G2AgentDetailSpeechState.saved;
    if (detailListenModeSelected) {
      detailPageIndex = 0;
    }
    return true;
  }

  void close() {
    mode = G2AgentHistoryMode.closed;
    entries = const <G2AgentHistoryEntry>[];
    selectedIndex = 0;
    _selectorWindowStart = 1;
    waitingExchangeId = null;
    detailTitle = null;
    detailText = null;
    detailTitleIsAgent = false;
    detailListenModeSelected = false;
    detailControl = G2AgentDetailControl.listen;
    detailPageIndex = 0;
    _detailPageIndexBeforeListenMode = null;
    waitingTimedOut = false;
    _clearDetailSpeech();
  }

  bool selectPreviousDetailPage() {
    if (mode != G2AgentHistoryMode.detail || detailPageIndex <= 0) {
      return false;
    }
    detailPageIndex--;
    return true;
  }

  bool selectNextDetailPage() {
    if (mode != G2AgentHistoryMode.detail ||
        detailPageIndex >= detailPageCount - 1) {
      return false;
    }
    detailPageIndex++;
    return true;
  }

  String render() {
    final rendered = switch (mode) {
      G2AgentHistoryMode.closed => '',
      G2AgentHistoryMode.selector => _renderSelector(),
      G2AgentHistoryMode.waiting => _renderDetail(cancel: true),
      G2AgentHistoryMode.detail => _renderDetail(cancel: false),
    };
    return _truncate(rendered, _layout.maximumPageCharacters);
  }

  String _renderSelector() {
    final header = _layout.fitLineWithLeading(
      '[x] - Swipe to Select',
      leading: selectedIndex == 0
          ? _selectedPointerPrefix
          : _emptyPointerPrefix,
    );
    final lines = <String>[
      header,
      for (final index in _selectorVisibleContentIndexes())
        ..._renderSelectorEntry(index),
    ];
    return lines.join('\n');
  }

  List<int> _selectorVisibleContentIndexes() {
    if (entries.length <= 1) {
      return const <int>[];
    }
    final start = _selectorWindowStart.clamp(1, entries.length - 1);
    final visible = <int>[];
    var usedRows = 0;
    final rowBudget = selectorMaximumRenderedRows - 1;
    for (var index = start; index < entries.length; index++) {
      final rows = _selectorEntryLineCount(index);
      if (visible.isNotEmpty && usedRows + rows > rowBudget) {
        break;
      }
      visible.add(index);
      usedRows += rows;
    }
    return visible;
  }

  int _lastSelectorWindowStart() {
    if (entries.length <= 1) {
      return 1;
    }
    final rowBudget = selectorMaximumRenderedRows - 1;
    var usedRows = 0;
    var start = entries.length - 1;
    for (var index = entries.length - 1; index >= 1; index--) {
      final rows = _selectorEntryLineCount(index);
      if (usedRows + rows > rowBudget) {
        break;
      }
      usedRows += rows;
      start = index;
    }
    return start;
  }

  int _selectorEntryLineCount(int index) {
    return _selectorEntryContentLines(entries[index]).length;
  }

  List<String> _renderSelectorEntry(int index) {
    final entry = entries[index];
    final lines = _selectorEntryContentLines(entry);
    return <String>[
      for (var lineIndex = 0; lineIndex < lines.length; lineIndex++)
        '${lineIndex == 0 && index == selectedIndex ? _selectedPointerPrefix : _emptyPointerPrefix}'
            '${lines[lineIndex]}',
    ];
  }

  List<String> _selectorEntryContentLines(G2AgentHistoryEntry entry) {
    final normalizedLabel = _oneLine(entry.label);
    final label = entry.kind == G2AgentHistoryEntryKind.agent
        ? '[$normalizedLabel]'
        : normalizedLabel;
    final preview = _oneLine(entry.preview);
    final content = entry.kind == G2AgentHistoryEntryKind.agent
        ? <String>[label, if (preview.isNotEmpty) preview].join(' ')
        : preview.isEmpty
        ? label
        : '$label - $preview';
    final pointerGutterWidth = _layout.textWidth(_selectedPointerPrefix);
    return _layout.limitLines(
      content,
      selectorEntryMaximumLines,
      maximumWidthPixels: _layout.wrappingWidthPixels - pointerGutterWidth,
    );
  }

  String _renderDetail({required bool cancel}) {
    if (detailTitleIsAgent) {
      return _renderAgentDetail(cancel: cancel);
    }
    final titleLabel = _oneLine(detailTitle ?? 'History');
    final action = cancel ? 'cancel' : 'dismiss';
    final titleSuffix = ' · Tap to $action ]';
    final titleLabelWidth =
        _layout.wrappingWidthPixels -
        _layout.textWidth('[ ') -
        _layout.textWidth(titleSuffix);
    final title =
        '[ ${_layout.fitLine(titleLabel, titleLabelWidth)}$titleSuffix';
    final pages = _detailPages();
    final pageIndex = detailPageIndex.clamp(0, pages.length - 1);
    final lines = <String>[title, ...pages[pageIndex]];
    while (lines.length < _layout.maximumVisibleRows) {
      lines.add('');
    }
    return lines.join('\n');
  }

  String _renderAgentDetail({required bool cancel}) {
    final titlePrefix = cancel || detailControl == G2AgentDetailControl.back
        ? '< ['
        : '   [';
    final titleSuffix = cancel
        ? ' · Waiting] - Tap to cancel'
        : '] - Swipe to Navigate';
    final titleWidth =
        _layout.wrappingWidthPixels -
        _layout.textWidth(titlePrefix) -
        _layout.textWidth(titleSuffix);
    final name = _oneLine(
      detailTitle ?? 'Unknown',
    ).replaceFirst(RegExp(r':+$'), '');
    final title =
        '$titlePrefix${_layout.fitLine(name.isEmpty ? 'Unknown' : name, titleWidth)}$titleSuffix';
    final listenMode = cancel
        ? '$_emptyControlPrefix· Listen Mode'
        : _agentListenModeLine();
    final pages = _detailPages();
    final pageIndex = detailPageIndex.clamp(0, pages.length - 1);
    final lines = <String>[title, listenMode, ...pages[pageIndex]];
    while (lines.length < _layout.maximumVisibleRows) {
      lines.add('');
    }
    return lines.join('\n');
  }

  String _agentListenModeLine() {
    final focused = detailControl == G2AgentDetailControl.listen;
    final backwardAction =
        detailListenModeSelected ||
        detailSpeechState == G2AgentDetailSpeechState.sending;
    final prefix = focused
        ? backwardAction
              ? _selectedBackControlPrefix
              : _selectedForwardControlPrefix
        : _emptyControlPrefix;
    final label = switch ((detailListenModeSelected, detailSpeechState)) {
      (true, G2AgentDetailSpeechState.listening) => 'Send transcript - Tap',
      (true, G2AgentDetailSpeechState.sent) => 'Listen Mode - Tap to stop',
      (true, G2AgentDetailSpeechState.saved) => 'Listen Mode - Tap to stop',
      (true, _) => 'Listen Mode - Tap to stop',
      (false, G2AgentDetailSpeechState.sending) => 'Sending - Wait',
      (false, G2AgentDetailSpeechState.sent) => 'Listen Mode - Tap to start',
      (false, G2AgentDetailSpeechState.saved) => 'Listen Mode - Tap to start',
      (false, _) => 'Listen Mode - Tap to start',
    };
    return '$prefix• $label';
  }

  List<List<String>> _detailPages() {
    final body = _renderDetailBody();
    final rowsPerPage = detailBodyLinesPerPage;
    final boundRetainedHistory = _isRetainedAgentHistoryVisible;
    final cached = _cachedDetailPages;
    if (cached != null &&
        _cachedDetailRowsPerPage == rowsPerPage &&
        _cachedDetailHistoryBounded == boundRetainedHistory &&
        _cachedDetailBody == body) {
      return cached;
    }
    var wrapped = _layout.wrapText(
      boundRetainedHistory
          ? _truncate(body, maximumAgentHistorySourceRunes)
          : body,
    );
    if (boundRetainedHistory) {
      final maximumRows =
          rowsPerPage +
          (maximumAgentHistoryDetailPages - 1) *
              (rowsPerPage - detailPageOverlapLines);
      final maximumContentRows = maximumRows - 1;
      final sourceWasTruncated =
          body.runes.length > maximumAgentHistorySourceRunes;
      if (sourceWasTruncated || wrapped.length > maximumContentRows) {
        wrapped = <String>[
          ...wrapped.take(maximumContentRows),
          agentHistoryOverflowText,
        ];
      }
    }
    final pages = _layout.paginateLines(
      wrapped,
      rowsPerPage: rowsPerPage,
      overlapRows: detailPageOverlapLines,
    );
    final immutable = List<List<String>>.unmodifiable(
      pages.map(List<String>.unmodifiable),
    );
    _cachedDetailBody = body;
    _cachedDetailRowsPerPage = rowsPerPage;
    _cachedDetailHistoryBounded = boundRetainedHistory;
    _cachedDetailPages = immutable;
    return immutable;
  }

  bool get _isRetainedAgentHistoryVisible {
    if (!detailTitleIsAgent) {
      return false;
    }
    final speechState = detailSpeechState;
    return speechState == null ||
        (!detailListenModeSelected &&
            speechState != G2AgentDetailSpeechState.sending);
  }

  String _renderDetailBody() {
    final speechState = detailSpeechState;
    if (speechState == null ||
        (!detailListenModeSelected &&
            speechState != G2AgentDetailSpeechState.sending)) {
      return (detailText ?? '').trim();
    }
    return (detailSpeechTranscript ?? '').trim();
  }

  static String _renderAgentConversations(List<AgentExchangeView> exchanges) {
    return _renderAgentMessages(_agentMessagesFromExchanges(exchanges));
  }

  static DateTime _exchangeUpdatedAt(AgentExchangeView exchange) {
    final responseAt = exchange.responseAt;
    return responseAt != null && responseAt.isAfter(exchange.sentAt)
        ? responseAt
        : exchange.sentAt;
  }

  static DateTime? _latestExchangeReceivedAt(AgentExchangeView exchange) {
    DateTime? latest = exchange.responseAt?.toUtc();
    for (final response in exchange.responseMessages) {
      final receivedAt = response.receivedAt.toUtc();
      if (latest == null || receivedAt.isAfter(latest)) {
        latest = receivedAt;
      }
    }
    if (latest == null && exchange.response?.trim().isNotEmpty == true) {
      latest = exchange.sentAt.toUtc();
    }
    return latest;
  }

  static String _latestExchangeMessage(
    AgentExchangeView? exchange,
    String agent,
  ) {
    if (exchange == null) {
      return '';
    }
    final responseAt = exchange.responseAt;
    final response = exchange.response;
    final text =
        responseAt != null &&
            !responseAt.isBefore(exchange.sentAt) &&
            response != null &&
            response.trim().isNotEmpty
        ? response
        : exchange.message;
    return _stripSpeakerPrefix(text, agent);
  }

  static List<AgentMessageView> _agentMessagesFromExchanges(
    List<AgentExchangeView> exchanges,
  ) {
    final messages = <AgentMessageView>[];
    for (final exchange in exchanges) {
      if (exchange.message.trim().isNotEmpty) {
        messages.add(
          AgentMessageView(
            id: '${exchange.id}-sent',
            agent: exchange.agent,
            direction: AgentMessageDirection.sent,
            message: exchange.message,
            updatedAt: exchange.sentAt,
          ),
        );
      }
      final responses = exchange.responseMessages.isNotEmpty
          ? exchange.responseMessages
          : <AgentResponseView>[
              if (exchange.response case final String response)
                AgentResponseView(
                  message: response,
                  receivedAt: exchange.responseAt ?? exchange.sentAt,
                ),
            ];
      for (var index = 0; index < responses.length; index++) {
        final response = responses[index];
        if (response.message.trim().isNotEmpty) {
          messages.add(
            AgentMessageView(
              id: '${exchange.id}-received-$index',
              agent: exchange.agent,
              direction: AgentMessageDirection.received,
              message: response.message,
              updatedAt: response.receivedAt,
            ),
          );
        }
      }
    }
    messages.sort((left, right) {
      final byTime = right.updatedAt.compareTo(left.updatedAt);
      return byTime != 0 ? byTime : right.id.compareTo(left.id);
    });
    return messages;
  }

  static String _renderAgentMessages(List<AgentMessageView> messages) {
    final lines = <String>[];
    for (final message in messages) {
      final content = _stripSpeakerPrefix(message.message, message.agent);
      if (content.isNotEmpty) {
        lines.add('${_formatTime(message.updatedAt)} $content');
      }
    }
    return lines.isEmpty ? 'No conversation yet' : lines.join('\n');
  }

  static String _renderAgentMessagesFor(
    List<AgentMessageView> messages,
    String agent,
  ) {
    final normalizedAgent = agent.trim().toLowerCase();
    final retained =
        messages
            .where(
              (message) =>
                  message.agent.trim().toLowerCase() == normalizedAgent,
            )
            .toList(growable: false)
          ..sort((left, right) {
            final byTime = right.updatedAt.compareTo(left.updatedAt);
            return byTime != 0 ? byTime : right.id.compareTo(left.id);
          });
    return _renderAgentMessages(retained);
  }

  void _clearDetailSpeech() {
    detailSpeechSegmentId = null;
    detailSpeechTranscript = null;
    detailSpeechState = null;
    detailCorrectionPreviewState = SelectedAgentCorrectionPreviewState.off;
    detailTranscriptionPending = false;
    detailTranscriptionIndicatorVisible = false;
  }

  bool _ownsTargetedSpeech(String segmentId) =>
      detailTitleIsAgent &&
      (mode == G2AgentHistoryMode.detail ||
          mode == G2AgentHistoryMode.waiting) &&
      detailSpeechSegmentId == segmentId;

  static String _oneLine(String value) => _layout.oneLine(value);

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '[$hour:$minute]';
  }

  static String _stripSpeakerPrefix(String value, String speaker) {
    final trimmed = value.trim();
    final name = _oneLine(speaker).replaceFirst(RegExp(r':+$'), '');
    if (name.isEmpty) {
      return trimmed;
    }
    return trimmed
        .replaceFirst(
          RegExp('^${RegExp.escape(name)}\\s*:\\s*', caseSensitive: false),
          '',
        )
        .trimLeft();
  }

  static String _truncate(String value, int maximumRunes) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= maximumRunes) {
      return value;
    }
    if (maximumRunes <= 1) {
      return '…';
    }
    return '${String.fromCharCodes(runes.take(maximumRunes - 1))}…';
  }
}
