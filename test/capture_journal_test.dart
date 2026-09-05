import 'dart:io';
import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/audio/capture_journal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'PCM is flushed with format metadata before downstream handoff',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workbench-journal-test-',
      );
      final received = <int>[];
      final pcm = Uint8List.fromList([0, 128, 255, 127, 1, 0]);
      final original = Uint8List.fromList(pcm);
      final journal = CaptureJournalSupervisor(
        rootPath: directory.path,
        pcm16: true,
        onCaptured: (sequence, bytes) {
          final saved = directory
              .listSync()
              .whereType<File>()
              .single
              .readAsBytesSync();
          expect(saved.sublist(saved.length - original.length), original);
          expect(bytes, original);
          received.add(sequence);
        },
        onStatus: (_, {bool isError = false}) {},
        onFatalBackpressure: () => fail('Unexpected capture overflow'),
      );
      try {
        await journal.start();
        journal.accept(pcm);
        pcm[0] = 42; // The journal owns a stable copy.
        await journal.drain();
        expect(received, [1]);
        final bytes = directory
            .listSync()
            .whereType<File>()
            .single
            .readAsBytesSync();
        expect(String.fromCharCodes(bytes.take(6)), 'WBPCM\x01');
        final format = ByteData.sublistView(bytes, 6, 14);
        expect(format.getUint32(0, Endian.little), 16000);
        expect(format.getUint16(4, Endian.little), 1);
        expect(format.getUint16(6, Endian.little), 16);
        expect(() => journal.accept(Uint8List(1)), throwsFormatException);
      } finally {
        await journal.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('PCM overflow stops accepting data at the byte bound', () async {
    var unsafe = 0;
    final journal = CaptureJournalSupervisor(
      rootPath: '',
      pcm16: true,
      onCaptured: (_, _) => fail('Unstarted journal cannot acknowledge'),
      onStatus: (_, {bool isError = false}) {},
      onFatalBackpressure: () {
        unsafe++;
      },
    );
    for (var i = 0; i < 100; i++) {
      journal.accept(Uint8List(3200));
    }
    expect(unsafe, 1);
    await journal.dispose();
  });

  test('existing LC3 journal header and records stay compatible', () async {
    final directory = await Directory.systemTemp.createTemp(
      'workbench-lc3-test-',
    );
    final journal = CaptureJournalSupervisor(
      rootPath: directory.path,
      onCaptured: (_, _) {},
      onStatus: (_, {bool isError = false}) {},
      onFatalBackpressure: () => fail('Unexpected capture overflow'),
    );
    try {
      await journal.start();
      journal.accept(Uint8List(40));
      await journal.drain();
      final file = directory.listSync().whereType<File>().single;
      expect(file.path.endsWith('.wblc3'), isTrue);
      final bytes = file.readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(6)), 'WBLC3\x01');
      expect(bytes.length, 6 + 24 + 40);
    } finally {
      await journal.dispose();
      await directory.delete(recursive: true);
    }
  });
}
