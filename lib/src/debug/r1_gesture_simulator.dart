import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../wearable_controller.dart';

const String debugR1GestureChannelName =
    'dev.opensourceglasses/workbench_debug_gesture';

/// Installs the Android-to-Dart gesture hook only in a debug build.
void installDebugR1GestureSimulator(WearableController controller) {
  if (!kDebugMode) {
    return;
  }
  const MethodChannel(debugR1GestureChannelName).setMethodCallHandler((call) {
    final arguments = call.arguments;
    if (arguments is! Map<Object?, Object?>) {
      throw const FormatException('Debug simulation arguments are required.');
    }
    return switch (call.method) {
      'simulateR1Gesture' when arguments['type'] is int => Future<bool>.value(
        controller.simulateR1GestureForDebug(arguments['type']! as int),
      ),
      'showAgentSelectorFixture' when arguments['fixture'] is int =>
        Future<bool>.value(
          controller.showAgentSelectorFixtureForDebug(
            arguments['fixture']! as int,
          ),
        ),
      'showAgentSendingFixture' => Future<bool>.value(
        controller.showAgentSendingFixtureForDebug(),
      ),
      'simulateR1Gesture' ||
      'showAgentSelectorFixture' ||
      'showAgentSendingFixture' => throw const FormatException(
        'A debug simulation integer is required.',
      ),
      _ => throw MissingPluginException('Unsupported debug simulation method.'),
    };
  });
}
