import 'dart:convert';
import 'dart:typed_data';

import 'package:even_g2_r1_poc/src/protocol/g2_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('G2 GATT layout', () {
    test(
      'qualifies control and audio characteristics under firmware services',
      () {
        expect(G2Ids.advertisedService, endsWith('72e0000'));
        expect(G2Ids.controlService, endsWith('72e5450'));
        expect(G2Ids.audioService, endsWith('72e6450'));
        expect(G2Ids.write, endsWith('72e5401'));
        expect(G2Ids.notify, endsWith('72e5402'));
        expect(G2Ids.audioNotify, endsWith('72e6402'));
      },
    );
  });

  group('G2 CRC and transport', () {
    test('matches the standard CRC-16 check vector', () {
      expect(g2Crc16(ascii.encode('123456789')), 0x29b1);
    });

    test('builds the expected empty reserved packet', () {
      final packets = G2Transport.buildPackets(
        syncId: 0,
        serviceId: G2Ids.serviceEvenHub,
        payload: const <int>[],
        reserveFlag: true,
      );

      expect(packets.single, <int>[
        0xaa,
        0x21,
        0,
        2,
        1,
        1,
        0xe0,
        0x20,
        0xff,
        0xff,
      ]);
    });

    test('splits payloads at 236 bytes and reassembles them', () {
      final payload = Uint8List.fromList(
        List<int>.generate(237, (index) => index & 0xff),
      );
      final packets = G2Transport.buildPackets(
        syncId: 7,
        serviceId: G2Ids.serviceEvenHub,
        payload: payload,
      );
      final receiver = G2ReceiveAssembler();

      expect(packets, hasLength(2));
      expect(receiver.add(packets.first, 'R'), isNull);
      final result = receiver.add(packets.last, 'R');
      expect(result, isNotNull);
      expect(result!.serviceId, G2Ids.serviceEvenHub);
      expect(result.crcValid, isTrue);
      expect(result.payload, payload);
    });
  });

  group('G2 command subset', () {
    test('encodes Android authentication with phone type 4', () {
      final protocol = G2Protocol();

      expect(protocol.authentication(isIos: false), <int>[
        0x08,
        0x04,
        0x10,
        0x00,
        0x1a,
        0x04,
        0x08,
        0x01,
        0x10,
        0x04,
      ]);
    });

    test('encodes iOS authentication with phone type 3', () {
      final protocol = G2Protocol();

      expect(protocol.authentication(isIos: true).last, 0x03);
    });

    test('creates and updates the single POC text container', () {
      final protocol = G2Protocol();
      final create = protocol.createTextPage('hello');
      final update = protocol.updateText('world');
      final outer = ProtoReader(create).readFields();
      final page = ProtoReader(outer[3]! as Uint8List).readFields();
      final text = ProtoReader(page[3]! as Uint8List).readFields();

      expect(create, containsAllInOrder(utf8.encode('hello')));
      expect(create, containsAllInOrder(utf8.encode('evt-0')));
      expect(text[1], G2Protocol.fullPageTextX);
      expect(text[2], G2Protocol.fullPageTextY);
      expect(text[3], G2Protocol.fullPageTextWidth);
      expect(text[4], G2Protocol.fullPageTextHeight);
      expect(text[5], G2Protocol.fullPageTextBorderWidth);
      expect(text[6], G2Protocol.fullPageTextBorderColor);
      expect(text[8], G2Protocol.fullPageTextPaddingLength);
      expect(text[4]! as int, greaterThan(G2Protocol.visualizerTextHeight));
      expect(update, containsAllInOrder(utf8.encode('world')));
    });

    test('rebuilds an active page with a stable history inset', () {
      final protocol = G2Protocol();
      final rebuild = protocol.rebuildTextPage(
        'Agent - content flowing into row two',
        borderWidth: G2Protocol.expandedTextBorderWidth,
        borderColor: G2Protocol.expandedTextBorderColor,
        paddingLength: G2Protocol.expandedTextPaddingLength,
      );
      final outer = ProtoReader(rebuild).readFields();
      final page = ProtoReader(outer[7]! as Uint8List).readFields();
      final text = ProtoReader(page[3]! as Uint8List).readFields();

      expect(outer[1], 7);
      expect(page[1], 2);
      expect(text[1], G2Protocol.fullPageTextX);
      expect(text[2], G2Protocol.fullPageTextY);
      expect(text[3], G2Protocol.fullPageTextWidth);
      expect(text[4], G2Protocol.fullPageTextHeight);
      expect(text[5], G2Protocol.expandedTextBorderWidth);
      expect(text[6], G2Protocol.expandedTextBorderColor);
      expect(text[8], G2Protocol.expandedTextPaddingLength);
      expect(text[8], 4);
      expect(
        rebuild,
        containsAllInOrder(utf8.encode('Agent - content flowing into row two')),
      );
    });

    test('adds one proportional right-side image thumb to detail pages', () {
      final protocol = G2Protocol();
      final rebuild = protocol.rebuildTextPage(
        'synthetic detail page',
        showPageIndicator: true,
        pageIndex: 1,
        pageCount: 4,
        borderWidth: G2Protocol.expandedTextBorderWidth,
        borderColor: G2Protocol.expandedTextBorderColor,
        paddingLength: G2Protocol.expandedTextPaddingLength,
      );
      final outer = ProtoReader(rebuild).readFields();
      final page = ProtoReader(outer[7]! as Uint8List).readFields();
      final body = ProtoReader(page[3]! as Uint8List).readFields();
      final indicator = ProtoReader(page[4]! as Uint8List).readFields();
      final geometry = G2Protocol.detailPageIndicatorGeometry(
        pageIndex: 1,
        pageCount: 4,
      );
      final bitmap = G2Protocol.detailPageIndicatorBitmap(
        pageIndex: 1,
        pageCount: 4,
      );
      final metadata = G2Protocol.validateDetailPageIndicatorBitmap(bitmap);
      final header = ByteData.sublistView(bitmap);

      expect(G2Protocol.fullPageIndicatorBarWidth, 4);
      expect(G2Protocol.fullPageIndicatorTrailingClearance, 2);
      expect(
        G2Protocol.fullPageIndicatorWidth,
        inInclusiveRange(
          G2Protocol.fullPageIndicatorMinimumWidth,
          G2Protocol.fullPageIndicatorMaximumWidth,
        ),
      );
      expect(
        G2Protocol.fullPageIndicatorHeight,
        inInclusiveRange(
          G2Protocol.fullPageIndicatorMinimumHeight,
          G2Protocol.fullPageIndicatorMaximumHeight,
        ),
      );
      expect(metadata.paletteIndices, orderedEquals(<int>[0, 15]));
      expect(metadata.wireSignature, 'BM 20x144 4bpp values=0,15 bytes=1846');
      expect(page[1], 3);
      expect(
        body[3],
        G2Protocol.fullPageTextWidth,
        reason: 'The edge thumb must not narrow the detail text viewport.',
      );
      expect(body[5], G2Protocol.expandedTextBorderWidth);
      expect(body[6], G2Protocol.expandedTextBorderColor);
      expect(body[8], G2Protocol.expandedTextPaddingLength);
      expect(indicator[1], G2Protocol.fullPageIndicatorX);
      expect(indicator[2], G2Protocol.fullPageIndicatorY);
      expect(indicator[3], G2Protocol.fullPageIndicatorWidth);
      expect(indicator[4], G2Protocol.fullPageIndicatorHeight);
      expect(indicator[5], 10);
      expect(utf8.decode(indicator[6]! as Uint8List), 'img-10');
      expect(
        (indicator[1]! as int) + (indicator[3]! as int),
        G2Protocol.fullPageTextWidth - G2Protocol.fullPageIndicatorInset,
        reason: 'The black mask must end at the right display edge.',
      );
      expect(
        utf8.decode(rebuild, allowMalformed: true),
        isNot(contains('poc-scroll')),
      );
      expect(
        header.getInt32(18, Endian.little),
        G2Protocol.fullPageIndicatorWidth,
      );
      expect(
        header.getInt32(22, Endian.little),
        G2Protocol.fullPageIndicatorHeight,
      );
      final packedRowBytes = (G2Protocol.fullPageIndicatorWidth + 1) ~/ 2;
      final paddedRowBytes = (packedRowBytes + 3) & ~3;
      final leadingBlackBytes =
          (G2Protocol.fullPageIndicatorWidth -
              G2Protocol.fullPageIndicatorBarWidth -
              G2Protocol.fullPageIndicatorTrailingClearance) ~/
          2;
      final barBytes = G2Protocol.fullPageIndicatorBarWidth ~/ 2;
      final trailingBlackBytes =
          G2Protocol.fullPageIndicatorTrailingClearance ~/ 2;
      final thumbStart = geometry.y - G2Protocol.fullPageIndicatorY;
      final thumbEnd = thumbStart + geometry.height;
      for (var row = 0; row < G2Protocol.fullPageIndicatorHeight; row++) {
        final offset = 118 + row * paddedRowBytes;
        final displayRow = G2Protocol.fullPageIndicatorHeight - row - 1;
        expect(
          bitmap.sublist(offset, offset + leadingBlackBytes),
          everyElement(0x00),
        );
        expect(
          bitmap.sublist(
            offset + leadingBlackBytes,
            offset + leadingBlackBytes + barBytes,
          ),
          everyElement(
            displayRow >= thumbStart && displayRow < thumbEnd ? 0xff : 0x00,
          ),
        );
        expect(
          bitmap.sublist(
            offset + leadingBlackBytes + barBytes,
            offset + leadingBlackBytes + barBytes + trailingBlackBytes,
          ),
          everyElement(0x00),
        );
        expect(
          bitmap.sublist(offset + packedRowBytes, offset + paddedRowBytes),
          everyElement(0x00),
        );
      }
    });

    test('rejects half-value or malformed detail thumb wire bytes', () {
      final valid = G2Protocol.detailPageIndicatorBitmap(
        pageIndex: 1,
        pageCount: 3,
      );
      final halfValue = Uint8List.fromList(valid);
      final dataOffset = ByteData.sublistView(
        halfValue,
      ).getUint32(10, Endian.little);
      halfValue[dataOffset] = 0x88;
      final invalidSignature = Uint8List.fromList(valid)..[0] = 0;
      final protocol = G2Protocol();

      expect(
        () => G2Protocol.validateDetailPageIndicatorBitmap(halfValue),
        throwsArgumentError,
      );
      expect(
        () => protocol.updateDetailPageIndicatorImage(halfValue),
        throwsArgumentError,
      );
      expect(
        () => G2Protocol.validateDetailPageIndicatorBitmap(invalidSignature),
        throwsArgumentError,
      );
      expect(
        protocol.updateDetailPageIndicatorImage(valid),
        containsAllInOrder(valid),
      );
    });

    test('positions one continuous thumb at top, middle, and bottom', () {
      final top = G2Protocol.detailPageIndicatorGeometry(
        pageIndex: 0,
        pageCount: 3,
      );
      final middle = G2Protocol.detailPageIndicatorGeometry(
        pageIndex: 1,
        pageCount: 3,
      );
      final bottom = G2Protocol.detailPageIndicatorGeometry(
        pageIndex: 2,
        pageCount: 3,
      );
      final single = G2Protocol.detailPageIndicatorGeometry(
        pageIndex: 0,
        pageCount: 1,
      );

      expect(top, (y: 72, height: 48));
      expect(middle, (y: 120, height: 48));
      expect(bottom, (y: 168, height: 48));
      expect(single, (
        y: G2Protocol.fullPageIndicatorY,
        height: G2Protocol.fullPageIndicatorHeight,
      ));
    });

    test('keeps the image container fixed while the thumb moves', () {
      final protocol = G2Protocol();
      final containers = <Map<int, Object>>[];
      for (final pageIndex in <int>[0, 1, 2]) {
        final rebuild = protocol.rebuildTextPage(
          'synthetic page $pageIndex',
          showPageIndicator: true,
          pageIndex: pageIndex,
          pageCount: 3,
        );
        final outer = ProtoReader(rebuild).readFields();
        final page = ProtoReader(outer[7]! as Uint8List).readFields();
        containers.add(ProtoReader(page[4]! as Uint8List).readFields());
      }

      expect(
        containers.map((container) => container[2]),
        everyElement(G2Protocol.fullPageIndicatorY),
      );
      expect(
        containers.map((container) => container[4]),
        everyElement(G2Protocol.fullPageIndicatorHeight),
      );
      expect(<int>[
        for (var pageIndex = 0; pageIndex < 3; pageIndex++)
          G2Protocol.detailPageIndicatorGeometry(
            pageIndex: pageIndex,
            pageCount: 3,
          ).y,
      ], orderedEquals(<int>[72, 120, 168]));
    });

    test('keeps every retained-history thumb inside G2 image limits', () {
      for (var pageCount = 2; pageCount <= 200; pageCount++) {
        for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
          final geometry = G2Protocol.detailPageIndicatorGeometry(
            pageIndex: pageIndex,
            pageCount: pageCount,
          );
          expect(
            geometry.height,
            inInclusiveRange(
              G2Protocol.fullPageIndicatorMinimumThumbHeight,
              G2Protocol.fullPageIndicatorHeight,
            ),
            reason: 'page ${pageIndex + 1}/$pageCount',
          );
          expect(
            geometry.y,
            greaterThanOrEqualTo(G2Protocol.fullPageIndicatorY),
            reason: 'page ${pageIndex + 1}/$pageCount',
          );
          expect(
            geometry.y + geometry.height,
            lessThanOrEqualTo(
              G2Protocol.fullPageIndicatorY +
                  G2Protocol.fullPageIndicatorHeight,
            ),
            reason: 'page ${pageIndex + 1}/$pageCount',
          );
        }
      }
    });

    test('omits the image container when a detail has one page', () {
      final protocol = G2Protocol();
      final rebuild = protocol.rebuildTextPage(
        'one page',
        showPageIndicator: true,
        pageIndex: 0,
        pageCount: 1,
      );
      final outer = ProtoReader(rebuild).readFields();
      final page = ProtoReader(outer[7]! as Uint8List).readFields();
      final body = ProtoReader(page[3]! as Uint8List).readFields();

      expect(page[1], 2);
      expect(page[4], isNull);
      expect(body[3], G2Protocol.fullPageTextWidth);
    });

    test('builds a memo page with a persistent double-tap action header', () {
      final protocol = G2Protocol();
      final create = protocol.createMemoPage(
        'Project note\nRemember the second item.',
        status: 'Updating',
      );
      final update = protocol.updateMemoPage(
        'Project note\nRemember the final item.',
        status: 'Finalizing',
      );

      expect(create, containsAllInOrder(utf8.encode('Double Tap to finish')));
      expect(create, containsAllInOrder(utf8.encode('Updating')));
      expect(create, containsAllInOrder(utf8.encode('Remember the second')));
      expect(update, containsAllInOrder(utf8.encode('Finalizing')));
      expect(update, containsAllInOrder(utf8.encode('Remember the final')));
    });

    test('paginates a long live Memo into fixed-height swipe pages', () {
      final note = List<String>.generate(
        120,
        (index) => 'memo${index.toString().padLeft(3, '0')}',
      ).join(' ');
      final pages = G2Protocol.memoPageContents(note, status: 'Updating');

      expect(pages.length, greaterThan(1));
      expect(pages.first, contains('[ Double Tap to finish ]'));
      expect(pages.first, contains('[ 1/${pages.length} · Swipe to scroll ]'));
      expect(pages.last, contains('memo119'));
      expect(pages.last.split('\n'), hasLength(10));
      expect(
        pages.last,
        contains('[ ${pages.length}/${pages.length} · Swipe to scroll ]'),
      );
    });

    test('clears text with the firmware-compatible newline update', () {
      final protocol = G2Protocol();
      final command = protocol.clearText();
      final fields = ProtoReader(command).readFields();
      final update = ProtoReader(fields[9]! as Uint8List).readFields();

      expect(update[4], 1);
      expect(utf8.decode(update[5]! as Uint8List), '\n');
    });

    test('encodes the immediate native foreground exit response', () {
      final protocol = G2Protocol();
      final command = protocol.shutdownPage();
      final fields = ProtoReader(command).readFields();
      final shutdown = ProtoReader(fields[11]! as Uint8List).readFields();

      expect(fields[1], 9);
      expect(shutdown[1], 0);
    });

    test('encodes the official private Terminal mode and host status', () {
      final protocol = G2Protocol();
      final modeCommand = protocol.terminalModeSync(terminal: true);
      final modeOuter = ProtoReader(modeCommand).readFields();
      final mode = ProtoReader(modeOuter[3]! as Uint8List).readFields();

      expect(G2Ids.serviceTerminal, 0x30);
      expect(modeOuter[1], 1);
      expect(mode[1], 2);
      expect(mode[2], 0);

      final pcCommand = protocol.terminalPcStatusSync(connected: true);
      final pcOuter = ProtoReader(pcCommand).readFields();
      final pcStatus = ProtoReader(pcOuter[4]! as Uint8List).readFields();

      expect(pcOuter[1], 2);
      expect(pcStatus[1], 2);
      expect(pcStatus[2], 0);

      final sessionCommand = protocol.terminalSessionList(
        hostId: 7,
        sessionId: 9,
        title: 'POC',
      );
      final sessionOuter = ProtoReader(sessionCommand).readFields();
      final sessions = ProtoReader(sessionOuter[16]! as Uint8List).readFields();
      final item = ProtoReader(sessions[3]! as Uint8List).readFields();

      expect(sessionOuter[1], 8);
      expect(sessions[1], 7);
      expect(sessions[2], 9);
      expect(item[1], 9);
      expect(utf8.decode(item[2]! as Uint8List), 'POC');
      expect(item[3], 2);

      final agentCommand = protocol.terminalAgentStatus(state: 2, sessionId: 9);
      final agentOuter = ProtoReader(agentCommand).readFields();
      final agent = ProtoReader(agentOuter[6]! as Uint8List).readFields();

      expect(agentOuter[1], 4);
      expect(agent[1], 2);
      expect(agent[2], 9);
    });

    test('encodes the G2 ring connection command', () {
      final protocol = G2Protocol();
      final command = protocol.ringConnectInfo(
        connect: true,
        ringMac: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
      );
      final fields = ProtoReader(command).readFields();
      final ring = ProtoReader(fields[5]! as Uint8List).readFields();

      expect(fields[1], 6);
      expect(ring[1], 1);
      expect(ring[2], Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]));
    });

    test('encodes and decodes G2 battery status', () {
      final protocol = G2Protocol();
      expect(
        protocol.deviceInfoRequest(),
        Uint8List.fromList(const <int>[
          0x08,
          0x02,
          0x10,
          0x00,
          0x22,
          0x02,
          0x08,
          0x01,
        ]),
      );

      final status = decodeG2BatteryStatus(
        Uint8List.fromList(const <int>[
          0x08,
          0x02,
          0x22,
          0x04,
          0x60,
          0x52,
          0x68,
          0x01,
        ]),
      );
      expect(status?.level, 82);
      expect(status?.charging, isTrue);
    });

    test('encodes the G2 ring release command for direct input mode', () {
      final protocol = G2Protocol();
      final command = protocol.ringConnectInfo(
        connect: false,
        ringMac: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
      );
      final fields = ProtoReader(command).readFields();
      final ring = ProtoReader(fields[5]! as Uint8List).readFields();

      expect(fields[1], 6);
      expect(ring[1], 0);
      expect(ring[2], Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]));
    });

    test('decodes an R1 gesture forwarded by EvenHub', () {
      final systemEvent = ProtoWriter()
        ..writeInt32(1, 3)
        ..writeInt32(2, 2);
      final deviceEvent = ProtoWriter()
        ..writeMessage(3, systemEvent.takeBytes());
      final payload = ProtoWriter()
        ..writeInt32(1, 2)
        ..writeMessage(13, deviceEvent.takeBytes());

      final event = decodeG2Gesture(payload.takeBytes());
      expect(event?.name, 'double_tap');
      expect(event?.isFromR1, isTrue);
    });

    test('decodes an omitted default enum as an R1 single tap', () {
      final systemEvent = ProtoWriter()..writeInt32(2, 2);
      final deviceEvent = ProtoWriter()
        ..writeMessage(3, systemEvent.takeBytes());
      final payload = ProtoWriter()
        ..writeInt32(1, 2)
        ..writeMessage(13, deviceEvent.takeBytes());

      final event = decodeG2Gesture(payload.takeBytes());
      expect(event?.name, 'single_tap');
      expect(event?.isFromR1, isTrue);
      expect(event?.typeWasOmitted, isTrue);
    });

    test('decodes swipe events from the evt-0 text capture container', () {
      G2GestureEvent? decodeTextEvent(int type) {
        final textEvent = ProtoWriter()
          ..writeString(2, 'evt-0')
          ..writeInt32(3, type);
        final deviceEvent = ProtoWriter()
          ..writeMessage(2, textEvent.takeBytes());
        final payload = ProtoWriter()
          ..writeInt32(1, 2)
          ..writeMessage(13, deviceEvent.takeBytes());
        return decodeG2Gesture(payload.takeBytes());
      }

      final up = decodeTextEvent(1);
      final down = decodeTextEvent(2);

      expect(up?.name, 'swipe_up');
      expect(up?.path, G2GesturePath.textEvent);
      expect(up?.source, isNull);
      expect(down?.name, 'swipe_down');
      expect(down?.path, G2GesturePath.textEvent);
    });

    test('builds and sends a firmware-compatible test drawing', () {
      final protocol = G2Protocol();
      final bitmap = G2Bitmap.testPattern(width: 20, height: 20);
      final header = ByteData.sublistView(bitmap);
      final rebuild = protocol.rebuildPageWithImage(content: 'drawing');
      final update = protocol.updateImage(bitmap);

      expect(bitmap.take(2), <int>[0x42, 0x4d]);
      expect(header.getInt32(18, Endian.little), 20);
      expect(header.getInt32(22, Endian.little), 20);
      expect(header.getUint16(28, Endian.little), 4);
      expect(rebuild, containsAllInOrder(utf8.encode('img-10')));
      expect(update, containsAllInOrder(bitmap));
    });

    test('rejects invalid source values and out-of-range G2 dimensions', () {
      expect(
        () => G2Bitmap.build4Bit(
          width: 20,
          height: 20,
          grayscale: <int>[-1, ...List<int>.filled(399, 0)],
        ),
        throwsArgumentError,
      );
      expect(
        () => G2Bitmap.solid(width: 20, height: 20, grayscale: 256),
        throwsArgumentError,
      );

      for (final dimensions in <({int width, int height})>[
        (width: 20, height: 20),
        (width: 288, height: 144),
      ]) {
        final metadata = G2Bitmap.validateG2Image(
          G2Bitmap.solid(width: dimensions.width, height: dimensions.height),
        );
        expect(metadata.width, dimensions.width);
        expect(metadata.height, dimensions.height);
      }

      for (final dimensions in <({int width, int height})>[
        (width: 19, height: 20),
        (width: 289, height: 20),
        (width: 20, height: 19),
        (width: 20, height: 145),
      ]) {
        final bitmap = G2Bitmap.solid(
          width: dimensions.width,
          height: dimensions.height,
        );
        expect(
          () => G2Bitmap.validateG2Image(bitmap),
          throwsArgumentError,
          reason: '${dimensions.width}x${dimensions.height}',
        );
        expect(
          () => G2Protocol().updateImage(bitmap),
          throwsArgumentError,
          reason: '${dimensions.width}x${dimensions.height}',
        );
      }
    });

    test('builds the blank visualizer page with text right of the pulse', () {
      final protocol = G2Protocol();
      final command = protocol.rebuildAudioVisualizerPage();
      final outer = ProtoReader(command).readFields();
      final page = ProtoReader(outer[7]! as Uint8List).readFields();
      final gesture = ProtoReader(page[3]! as Uint8List).readFields();
      final image = ProtoReader(page[4]! as Uint8List).readFields();

      expect(outer[1], 7);
      expect(page[1], 3);
      expect(gesture[1], G2Protocol.visualizerTextX);
      expect(gesture[2], G2Protocol.visualizerTextY);
      expect(gesture[3], G2Protocol.visualizerTextWidth);
      expect(gesture[4], G2Protocol.visualizerTextHeight);
      expect(utf8.decode(gesture[12]! as Uint8List), isEmpty);
      expect(image[1], G2Protocol.visualizerPulseX);
      expect(image[2], G2Protocol.visualizerPulseY);
      expect(image[3], G2Protocol.visualizerPulseWidth);
      expect(image[4], G2Protocol.visualizerPulseHeight);
      expect(
        gesture[1]! as int,
        greaterThanOrEqualTo((image[1]! as int) + (image[3]! as int)),
      );
      expect(gesture[2], image[2]);
    });

    test('renders a dim-to-bright quantized LC3 activity pulse', () {
      final stopped = G2Bitmap.audioActivityPulse(
        level: 255,
        streaming: false,
        width: G2Protocol.visualizerPulseWidth,
        height: G2Protocol.visualizerPulseHeight,
      );
      final quiet = G2Bitmap.audioActivityPulse(
        level: 0,
        streaming: true,
        width: G2Protocol.visualizerPulseWidth,
        height: G2Protocol.visualizerPulseHeight,
      );
      final active = G2Bitmap.audioActivityPulse(
        level: 255,
        streaming: true,
        width: G2Protocol.visualizerPulseWidth,
        height: G2Protocol.visualizerPulseHeight,
      );
      final protocol = G2Protocol();
      final packets = protocol.frame(
        G2Ids.serviceEvenHub,
        protocol.updateImage(active),
        reserveFlag: true,
      );
      final header = ByteData.sublistView(active);

      expect(active.length, lessThan(600));
      expect(packets.length, lessThan(4));
      expect(
        header.getInt32(18, Endian.little),
        G2Protocol.visualizerPulseWidth,
      );
      expect(
        header.getInt32(22, Endian.little),
        G2Protocol.visualizerPulseHeight,
      );
      expect(_litPulsePixels(stopped), 0);
      expect(_litPulsePixels(quiet), greaterThan(0));
      expect(_litPulsePixels(active), greaterThan(_litPulsePixels(quiet)));
      expect(_brightestPulseShade(quiet), 5);
      expect(_brightestPulseShade(active), 15);
      expect(active, isNot(orderedEquals(quiet)));
      expect(G2Bitmap.audioActivityPulseState(31), 0);
      expect(G2Bitmap.audioActivityPulseState(32), 1);
      expect(G2Bitmap.audioActivityPulseState(223), 4);
      expect(G2Bitmap.audioActivityPulseState(224), 5);
    });

    test('extracts global gain from a 40-byte G2 LC3 frame', () {
      const expectedGain = 178;
      final frame = Uint8List(40);
      for (var index = 0; index < 8; index++) {
        if ((expectedGain >> index) & 1 == 1) {
          final bit = 9 + index;
          frame[frame.length - 1 - bit ~/ 8] |= 1 << (bit & 7);
        }
      }

      expect(G2AudioAnalysis.globalGainIndex(frame), expectedGain);
      expect(G2AudioAnalysis.globalGainIndex(Uint8List(39)), isNull);
    });

    test('includes the remaining firmware session initialization commands', () {
      final protocol = G2Protocol();

      expect(protocol.uiSettingsQuery(), isNotEmpty);
      expect(protocol.dashboardInit(), isNotEmpty);
      expect(protocol.disableHeyEven(), isNotEmpty);
    });
  });
}

int _litPulsePixels(Uint8List bitmap) {
  final dataOffset = ByteData.sublistView(bitmap).getUint32(10, Endian.little);
  var count = 0;
  for (final byte in bitmap.skip(dataOffset)) {
    if ((byte >> 4) != 0) count++;
    if ((byte & 0x0f) != 0) count++;
  }
  return count;
}

int _brightestPulseShade(Uint8List bitmap) {
  final dataOffset = ByteData.sublistView(bitmap).getUint32(10, Endian.little);
  var brightest = 0;
  for (final byte in bitmap.skip(dataOffset)) {
    final high = byte >> 4;
    final low = byte & 0x0f;
    if (high > brightest) brightest = high;
    if (low > brightest) brightest = low;
  }
  return brightest;
}
