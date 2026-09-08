import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_models.dart';

const conversationAnalysisEnabledPreferenceKey =
    'conversation_analysis_enabled';
const conversationSpeakerMatchThresholdPreferenceKey =
    'conversation_speaker_match_threshold';

final class ConversationAnalysisPreferences {
  const ConversationAnalysisPreferences();

  Future<bool> loadEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(conversationAnalysisEnabledPreferenceKey) ??
        true;
  }

  Future<void> saveEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(
      conversationAnalysisEnabledPreferenceKey,
      enabled,
    )) {
      throw StateError('Could not save the speaker identification setting.');
    }
  }

  Future<double> loadSpeakerMatchThreshold() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getDouble(
      conversationSpeakerMatchThresholdPreferenceKey,
    );
    if (stored == null || !isAdjustableSpeakerSignatureThreshold(stored)) {
      return defaultSpeakerSignatureMatchThreshold;
    }
    return normalizeAdjustableSpeakerSignatureThreshold(stored);
  }

  Future<void> saveSpeakerMatchThreshold(double threshold) async {
    if (!isAdjustableSpeakerSignatureThreshold(threshold)) {
      throw ArgumentError.value(
        threshold,
        'threshold',
        'The speaker match threshold is outside the adjustable range.',
      );
    }
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setDouble(
      conversationSpeakerMatchThresholdPreferenceKey,
      normalizeAdjustableSpeakerSignatureThreshold(threshold),
    )) {
      throw StateError('Could not save the speaker match threshold.');
    }
  }
}
