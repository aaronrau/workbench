import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

typedef WearableLogSink =
    void Function(String source, String message, {bool isError});

enum LinkState { disconnected, connecting, connected, reconnecting, error }

enum G2Side { left, right }

final class G2PairCandidate {
  const G2PairCandidate({
    required this.key,
    required this.serialNumber,
    this.left,
    this.right,
    this.leftMac,
    this.rightMac,
  });

  final String key;
  final String serialNumber;
  final DiscoveredDevice? left;
  final DiscoveredDevice? right;
  final String? leftMac;
  final String? rightMac;

  bool get isComplete => left != null && right != null;

  G2PairCandidate merge(DiscoveredDevice device) {
    final side = g2SideFromName(device.name);
    return G2PairCandidate(
      key: key,
      serialNumber: serialNumber,
      left: side == G2Side.left ? device : left,
      right: side == G2Side.right ? device : right,
      leftMac: side == G2Side.left
          ? (extractG2Mac(device.manufacturerData) ?? leftMac)
          : leftMac,
      rightMac: side == G2Side.right
          ? (extractG2Mac(device.manufacturerData) ?? rightMac)
          : rightMac,
    );
  }

  static G2PairCandidate? fromDevice(DiscoveredDevice device) {
    final side = g2SideFromName(device.name);
    if (side == null) {
      return null;
    }
    final serial = extractG2Serial(device.manufacturerData);
    final nameKey = extractG2NameKey(device.name);
    final key = serial ?? nameKey;
    if (key == null || key.isEmpty) {
      return null;
    }
    return G2PairCandidate(
      key: key,
      serialNumber: serial ?? key,
      left: side == G2Side.left ? device : null,
      right: side == G2Side.right ? device : null,
      leftMac: side == G2Side.left
          ? extractG2Mac(device.manufacturerData)
          : null,
      rightMac: side == G2Side.right
          ? extractG2Mac(device.manufacturerData)
          : null,
    );
  }
}

G2Side? g2SideFromName(String name) {
  final upper = name.toUpperCase();
  if (!upper.contains('G2')) {
    return null;
  }
  if (upper.contains('_L_')) {
    return G2Side.left;
  }
  if (upper.contains('_R_')) {
    return G2Side.right;
  }
  return null;
}

String? extractG2NameKey(String name) {
  final match = RegExp(r'G2_([^_]+)_', caseSensitive: false).firstMatch(name);
  return match?.group(1);
}

String? extractG2Serial(Uint8List manufacturerData) {
  if (manufacturerData.length < 14) {
    return null;
  }
  final offsets = manufacturerData.length >= 16 ? <int>[2, 0] : <int>[0];
  for (final offset in offsets) {
    if (offset + 14 > manufacturerData.length) {
      continue;
    }
    final candidate = ascii
        .decode(
          manufacturerData.sublist(offset, offset + 14),
          allowInvalid: true,
        )
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .trim();
    if (candidate.length >= 6 &&
        RegExp(r'^[A-Za-z0-9-]+$').hasMatch(candidate)) {
      return candidate;
    }
  }
  return null;
}

String? extractG2Mac(Uint8List manufacturerData) {
  // flutter_reactive_ble includes the two-byte company identifier.
  const macOffset = 2 + 14;
  if (manufacturerData.length < macOffset + 6) {
    return null;
  }
  return manufacturerData
      .sublist(macOffset, macOffset + 6)
      .reversed
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

bool isR1(DiscoveredDevice device) {
  final name = device.name.toUpperCase();
  return name.contains('EVEN R1') || name.contains('BCL60');
}

/// How prominently an event row is rendered in the Events tab.
enum PooledLogSeverity { info, warning, error }

final class PooledLog {
  const PooledLog({
    required this.timestamp,
    required this.source,
    required this.message,
    this.isError = false,
    this.isWarning = false,
  });

  final DateTime timestamp;
  final String source;
  final String message;
  final bool isError;

  /// A degraded-but-continuing condition, such as a command routed without
  /// Gemma correction. It stays readable next to normal events but must be
  /// visually distinct from them.
  final bool isWarning;

  PooledLogSeverity get severity => isError
      ? PooledLogSeverity.error
      : isWarning
      ? PooledLogSeverity.warning
      : PooledLogSeverity.info;
}
