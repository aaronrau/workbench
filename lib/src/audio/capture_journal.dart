import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

typedef CaptureStatusSink = void Function(String message, {bool isError});
typedef CapturedPacketSink = void Function(int sequence, Uint8List packet);

final class CaptureJournalSupervisor {
  CaptureJournalSupervisor({
    required this.rootPath,
    required this.onCaptured,
    required this.onStatus,
    required this.onFatalBackpressure,
    this.pcm16 = false,
  });

  static const int _maximumPendingPackets = 600;

  final String rootPath;
  final bool pcm16;
  int _pendingBytes = 0;
  Completer<void>? _drained;
  bool _unsafe = false;
  final CapturedPacketSink onCaptured;
  final CaptureStatusSink onStatus;
  final void Function() onFatalBackpressure;

  final LinkedHashMap<int, Uint8List> _pending =
      LinkedHashMap<int, Uint8List>();
  ReceivePort? _events;
  ReceivePort? _errors;
  ReceivePort? _exit;
  StreamSubscription<Object?>? _eventSubscription;
  StreamSubscription<Object?>? _errorSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  SendPort? _commands;
  Isolate? _isolate;
  Completer<void>? _ready;
  Completer<void>? _closed;
  Timer? _restartTimer;
  bool _disposed = false;
  bool _restarting = false;
  int _nextSequence = 1;
  int _lastReportedSequence = 0;

  Future<void> start() async {
    if (_commands != null) {
      return;
    }
    await Directory(rootPath).create(recursive: true);
    await _spawn();
    await _ready!.future.timeout(const Duration(seconds: 10));
  }

  void accept(Uint8List packet) {
    if (_disposed || _unsafe || packet.isEmpty) {
      return;
    }
    if (pcm16 && packet.length.isOdd) {
      throw const FormatException('PCM16 requires complete samples.');
    }
    // Six seconds of PCM at 16 kHz. Refuse more data before allocating it.
    if (_pending.length >= _maximumPendingPackets ||
        (pcm16 && _pendingBytes + packet.length > 16000 * 2 * 6)) {
      _unsafe = true;
      onStatus(
        '[WorkBench][Capture] state=failed reason=pending_overflow',
        isError: true,
      );
      onFatalBackpressure();
      return;
    }
    final sequence = _nextSequence++;
    final stable = Uint8List.fromList(packet);
    _pending[sequence] = stable;
    _pendingBytes += stable.length;
    _sendPacket(sequence, stable);
  }

  Future<void> restartForTest() async {
    if (_disposed || _isolate == null) {
      return;
    }
    onStatus('[WorkBench][Capture] state=restarting reason=diagnostic');
    _isolate!.kill(priority: Isolate.immediate);
  }

  void _sendPacket(int sequence, Uint8List packet) {
    _commands?.send(<String, Object>{
      'type': 'packet',
      'sequence': sequence,
      'timestampUs': DateTime.now().microsecondsSinceEpoch,
      'bytes': TransferableTypedData.fromList(<Uint8List>[packet]),
    });
  }

  Future<void> _spawn() async {
    _commands = null;
    _ready = Completer<void>();
    _closed = Completer<void>();
    _events = ReceivePort();
    _errors = ReceivePort();
    _exit = ReceivePort();
    _eventSubscription = _events!.listen(_handleEvent);
    _errorSubscription = _errors!.listen((Object? error) {
      onStatus(
        '[WorkBench][Capture] state=failed error=${_oneLine(error)}',
        isError: true,
      );
    });
    _exitSubscription = _exit!.listen((_) {
      _commands = null;
      _isolate = null;
      final closed = _closed;
      if (closed != null && !closed.isCompleted) {
        closed.complete();
      }
      if (!_disposed) {
        _scheduleRestart();
      }
    });
    _isolate = await Isolate.spawn<Map<String, Object>>(
      _captureJournalWorker,
      <String, Object>{
        'events': _events!.sendPort,
        'rootPath': rootPath,
        'pcm16': pcm16,
      },
      debugName: 'workbench-capture-journal',
      errorsAreFatal: true,
      onError: _errors!.sendPort,
      onExit: _exit!.sendPort,
    );
  }

  void _handleEvent(Object? event) {
    if (event is! Map<Object?, Object?>) {
      return;
    }
    switch (event['type']) {
      case 'commands':
        _commands = event['port']! as SendPort;
        for (final entry in _pending.entries) {
          _sendPacket(entry.key, entry.value);
        }
      case 'ready':
        final recovered = _restarting;
        _restarting = false;
        onStatus(
          '[WorkBench][Capture] state=ready journal=writable '
          'recovered=$recovered',
        );
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.complete();
        }
      case 'ack':
        final sequences = (event['sequences']! as List<Object?>).cast<int>();
        for (final sequence in sequences) {
          final packet = _pending.remove(sequence);
          if (packet != null) {
            _pendingBytes -= packet.length;
            onCaptured(sequence, packet);
          }
        }
        if (_pending.isEmpty) {
          _drained?.complete();
          _drained = null;
        }
        if (sequences.isNotEmpty &&
            sequences.last - _lastReportedSequence >= 100) {
          _lastReportedSequence = sequences.last;
          onStatus(
            '[WorkBench][Capture] state=streaming '
            'sequence=${sequences.last}',
          );
        }
      case 'error':
        onStatus(
          '[WorkBench][Capture] state=failed '
          'error=${_oneLine(event['message'])}',
          isError: true,
        );
      case 'closed':
        final closed = _closed;
        if (closed != null && !closed.isCompleted) {
          closed.complete();
        }
    }
  }

  void _scheduleRestart() {
    if (_restartTimer != null || _disposed) {
      return;
    }
    _restarting = true;
    onStatus(
      '[WorkBench][Capture] state=restarting pending=${_pending.length}',
    );
    _restartTimer = Timer(const Duration(seconds: 1), () {
      _restartTimer = null;
      unawaited(
        _closePorts().then((_) => _spawn()).catchError((Object error) {
          onStatus(
            '[WorkBench][Capture] state=failed '
            'restart_error=${_oneLine(error)}',
            isError: true,
          );
          _scheduleRestart();
        }),
      );
    });
  }

  Future<void> _closePorts() async {
    await _eventSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _exitSubscription?.cancel();
    _eventSubscription = null;
    _errorSubscription = null;
    _exitSubscription = null;
    _events?.close();
    _errors?.close();
    _exit?.close();
    _events = null;
    _errors = null;
    _exit = null;
  }

  /// Wait for every accepted packet's disk flush and downstream handoff.
  Future<void> drain() async {
    if (_pending.isEmpty) return;
    final drained = _drained ??= Completer<void>();
    _commands?.send(<String, Object>{'type': 'flush'});
    await drained.future.timeout(const Duration(seconds: 10));
  }

  Future<void> dispose() async {
    _disposed = true;
    _restartTimer?.cancel();
    _restartTimer = null;
    final commands = _commands;
    final closed = _closed;
    commands?.send(<String, Object>{'type': 'close'});
    if (commands != null && closed != null && !closed.isCompleted) {
      try {
        await closed.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        onStatus(
          '[WorkBench][Capture] state=close_timeout cleanup=forced',
          isError: true,
        );
      }
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    await _closePorts();
  }

  String _oneLine(Object? value) =>
      '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
}

void _captureJournalWorker(Map<String, Object> bootstrap) {
  final events = bootstrap['events']! as SendPort;
  final rootPath = bootstrap['rootPath']! as String;
  final pcm16 = bootstrap['pcm16']! as bool;
  final commands = ReceivePort();
  final buffered = <_JournalRecord>[];
  RandomAccessFile? output;
  DateTime? openedAt;

  void closeOutput() {
    if (output == null) {
      return;
    }
    output!.flushSync();
    output!.closeSync();
    output = null;
    openedAt = null;
  }

  void ensureOutput() {
    final now = DateTime.now().toUtc();
    if (output != null &&
        openedAt != null &&
        now.difference(openedAt!) < const Duration(minutes: 15)) {
      return;
    }
    closeOutput();
    final stamp = now.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File(
      pcm16 ? '$rootPath/pcm-$stamp.wbpcm' : '$rootPath/lc3-$stamp.wblc3',
    );
    output = file.openSync(mode: FileMode.append);
    if (file.lengthSync() == 0) {
      output!.writeFromSync(utf8.encode(pcm16 ? 'WBPCM\x01' : 'WBLC3\x01'));
      if (pcm16) {
        // Version 1 PCM journal: rate, channels, bits; all little endian.
        final format = ByteData(8)
          ..setUint32(0, 16000, Endian.little)
          ..setUint16(4, 1, Endian.little)
          ..setUint16(6, 16, Endian.little);
        output!.writeFromSync(format.buffer.asUint8List());
      }
      output!.flushSync();
    }
    openedAt = now;
  }

  void flush() {
    if (buffered.isEmpty) {
      return;
    }
    try {
      ensureOutput();
      final acknowledged = <int>[];
      for (final record in buffered) {
        final header = ByteData(24)
          ..setUint32(0, record.bytes.length, Endian.little)
          ..setUint64(4, record.sequence, Endian.little)
          ..setUint64(12, record.timestampUs, Endian.little)
          ..setUint32(20, _checksum(record.bytes), Endian.little);
        output!.writeFromSync(header.buffer.asUint8List());
        output!.writeFromSync(record.bytes);
        acknowledged.add(record.sequence);
      }
      output!.flushSync();
      buffered.clear();
      events.send(<String, Object>{'type': 'ack', 'sequences': acknowledged});
    } catch (error) {
      events.send(<String, Object>{'type': 'error', 'message': '$error'});
      closeOutput();
      rethrow;
    }
  }

  final flushTimer = Timer.periodic(
    const Duration(milliseconds: 250),
    (_) => flush(),
  );
  commands.listen((Object? message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }
    switch (message['type']) {
      case 'packet':
        final data = message['bytes']! as TransferableTypedData;
        buffered.add(
          _JournalRecord(
            sequence: message['sequence']! as int,
            timestampUs: message['timestampUs']! as int,
            bytes: data.materialize().asUint8List(),
          ),
        );
        if (buffered.length >= 5) {
          flush();
        }
      case 'flush':
        flush();
      case 'close':
        flushTimer.cancel();
        flush();
        closeOutput();
        events.send(<String, Object>{'type': 'closed'});
        commands.close();
    }
  });
  events.send(<String, Object>{'type': 'commands', 'port': commands.sendPort});
  try {
    ensureOutput();
    events.send(<String, Object>{'type': 'ready'});
  } catch (error) {
    events.send(<String, Object>{'type': 'error', 'message': '$error'});
    rethrow;
  }
}

int _checksum(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

final class _JournalRecord {
  const _JournalRecord({
    required this.sequence,
    required this.timestampUs,
    required this.bytes,
  });

  final int sequence;
  final int timestampUs;
  final Uint8List bytes;
}
