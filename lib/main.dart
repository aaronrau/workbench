import 'dart:async';

import 'package:flutter/material.dart';

import 'src/debug/r1_gesture_simulator.dart';
import 'src/ui/home_page.dart';
import 'src/ui/workbench_theme.dart';
import 'src/wearable_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = WearableController();
  installDebugR1GestureSimulator(controller);
  runApp(EvenG2R1App(controller: controller));
  unawaited(controller.initialize());
}

final class EvenG2R1App extends StatelessWidget {
  const EvenG2R1App({required this.controller, super.key});

  final WearableController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Work Bench',
      debugShowCheckedModeBanner: false,
      theme: buildWorkBenchTheme(),
      home: HomePage(controller: controller),
    );
  }
}
