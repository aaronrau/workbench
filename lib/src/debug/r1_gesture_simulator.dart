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
    if (call.method != 'simulateR1Gesture') {
      throw MissingPluginException('Unsupported debug gesture method.');
    }
    final arguments = call.arguments;
    if (arguments is! Map<Object?, Object?> || arguments['type'] is! int) {
      throw const FormatException('A simulated R1 gesture type is required.');
    }
    return Future<bool>.value(
      controller.simulateR1GestureForDebug(arguments['type']! as int),
    );
  });
}
