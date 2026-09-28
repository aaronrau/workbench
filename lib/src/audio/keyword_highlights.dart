import 'package:shared_preferences/shared_preferences.dart';

const keywordHighlightPreferenceKey = 'keyword_highlight_phrases';
const defaultKeywordHighlightPhrases = <String>['yeah', 'so', 'i think', 'hmm'];

final class KeywordHighlight {
  const KeywordHighlight({
    required this.phrase,
    required this.count,
    required this.expiresAt,
  });

  final String phrase;
  final int count;
  final DateTime expiresAt;

  String get label => count == 1 ? phrase : '$phrase($count)';
}

/// App-private settings. An empty saved list intentionally disables matching.
final class KeywordHighlightPreferences {
  const KeywordHighlightPreferences();

  Future<List<String>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getStringList(keywordHighlightPreferenceKey);
    if (saved == null) {
      return defaultKeywordHighlightPhrases;
    }
    try {
      return KeywordHighlights.validatePhrases(saved);
    } on FormatException {
      return defaultKeywordHighlightPhrases;
    }
  }

  Future<void> save(List<String> phrases) async {
    final validated = KeywordHighlights.validatePhrases(phrases);
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setStringList(
      keywordHighlightPreferenceKey,
      validated,
    )) {
      throw StateError('Could not save keyword highlights.');
    }
  }
}

/// Tracks matches in live, uncorrected STT text. This state is never exported.
final class KeywordHighlights {
  KeywordHighlights({
    List<String> phrases = defaultKeywordHighlightPhrases,
    this.lifetime = const Duration(minutes: 2),
  }) : _phrases = validatePhrases(phrases);

  static const int maximumPhrases = 20;
  static const int maximumPhraseCharacters = 40;
  static final RegExp _wordPattern = RegExp(
    r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)?",
  );

  final Duration lifetime;
  List<String> _phrases;
  final Map<String, KeywordHighlight> _active = <String, KeywordHighlight>{};
  final Set<String> _seenSegments = <String>{};
  final List<String> _recentSegments = <String>[];

  List<String> get phrases => List<String>.unmodifiable(_phrases);
  List<KeywordHighlight> get active => List<KeywordHighlight>.unmodifiable(
    _phrases
        .map((phrase) => _active[phrase.toLowerCase()])
        .whereType<KeywordHighlight>(),
  );

  DateTime? get nextExpiry {
    DateTime? earliest;
    for (final item in _active.values) {
      if (earliest == null || item.expiresAt.isBefore(earliest)) {
        earliest = item.expiresAt;
      }
    }
    return earliest;
  }

  static List<String> validatePhrases(Iterable<String> phrases) {
    final result = <String>[];
    final seen = <String>{};
    for (final phrase in phrases) {
      final normalized = phrase.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (normalized.isEmpty) {
        continue;
      }
      if (normalized.length > maximumPhraseCharacters) {
        throw const FormatException('Keep each keyword under 40 characters.');
      }
      final words = _tokens(normalized);
      if (words.isEmpty || words.join(' ') != normalized.toLowerCase()) {
        throw const FormatException(
          'Use words or phrases with letters, numbers, and apostrophes.',
        );
      }
      if (!seen.add(normalized.toLowerCase())) {
        throw const FormatException('Remove duplicate keywords.');
      }
      result.add(normalized);
      if (result.length > maximumPhrases) {
        throw const FormatException('Use no more than 20 keywords.');
      }
    }
    return List<String>.unmodifiable(result);
  }

  void setPhrases(List<String> phrases, DateTime now) {
    _phrases = validatePhrases(phrases);
    final retained = _phrases.map((phrase) => phrase.toLowerCase()).toSet();
    _active.removeWhere((phrase, _) => !retained.contains(phrase));
    for (final phrase in _phrases) {
      final key = phrase.toLowerCase();
      final previous = _active[key];
      if (previous != null && previous.phrase != phrase) {
        _active[key] = KeywordHighlight(
          phrase: phrase,
          count: previous.count,
          expiresAt: previous.expiresAt,
        );
      }
    }
    prune(now);
  }

  /// Returns true only when the visible highlight list changes.
  bool accept({
    required String segmentId,
    required String rawText,
    required DateTime now,
  }) {
    var changed = prune(now);
    if (!_seenSegments.add(segmentId)) {
      return changed;
    }
    _recentSegments.add(segmentId);
    if (_recentSegments.length > 256) {
      _seenSegments.remove(_recentSegments.removeAt(0));
    }
    final tokens = _tokens(rawText);
    for (final phrase in _phrases) {
      final phraseTokens = _tokens(phrase);
      var matches = 0;
      for (
        var start = 0;
        start + phraseTokens.length <= tokens.length;
        start++
      ) {
        var matched = true;
        for (var offset = 0; offset < phraseTokens.length; offset++) {
          if (tokens[start + offset] != phraseTokens[offset]) {
            matched = false;
            break;
          }
        }
        if (matched) {
          matches++;
        }
      }
      if (matches == 0) {
        continue;
      }
      final key = phrase.toLowerCase();
      final previous = _active[key];
      _active[key] = KeywordHighlight(
        phrase: phrase,
        count: (previous?.count ?? 0) + matches,
        expiresAt: now.add(lifetime),
      );
      changed = true;
    }
    return changed;
  }

  bool prune(DateTime now) {
    final before = _active.length;
    _active.removeWhere((_, value) => !value.expiresAt.isAfter(now));
    return _active.length != before;
  }

  static List<String> _tokens(String text) => _wordPattern
      .allMatches(text.toLowerCase())
      .map((match) => match.group(0)!)
      .toList(growable: false);
}
