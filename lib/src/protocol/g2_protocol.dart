import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Even Realities G2 BLE identifiers recovered in MentraOS.
abstract final class G2Ids {
  /// UUID advertised by the G2. It is not the parent GATT service for the
  /// control/audio characteristics on current firmware.
  static const advertisedService = '00002760-08c2-11e1-9073-0e8ac72e0000';

  /// GATT service containing the 0x5401 write and 0x5402 notify channels.
  static const controlService = '00002760-08c2-11e1-9073-0e8ac72e5450';

  /// GATT service containing the 0x6402 microphone notification channel.
  static const audioService = '00002760-08c2-11e1-9073-0e8ac72e6450';

  static const write = '00002760-08c2-11e1-9073-0e8ac72e5401';
  static const notify = '00002760-08c2-11e1-9073-0e8ac72e5402';
  static const audioNotify = '00002760-08c2-11e1-9073-0e8ac72e6402';

  static const serviceDashboard = 0x01;
  static const serviceEvenAi = 0x07;
  static const serviceG2Settings = 0x09;
  static const serviceGesture = 0x0d;
  static const serviceUiSettings = 0x0c;
  static const serviceOnboarding = 0x10;
  static const serviceTerminal = 0x30;
  static const serviceDeviceSettings = 0x80;
  static const serviceEvenHub = 0xe0;
}

/// Reads loudness-related side information from the G2's fixed LC3 format.
abstract final class G2AudioAnalysis {
  /// Extracts the LC3 spectral global-gain index from one 40-byte G2 frame.
  ///
  /// G2 uses LC3 at 16 kHz, mono, and 10 ms. LC3 side information is packed
  /// backward from the end of the frame. For this sample rate, global gain
  /// follows one bandwidth bit, seven coded-coefficient bits, and one
  /// least-significant-bit-mode flag.
  static int? globalGainIndex(List<int> frame) {
    if (frame.length != 40) {
      return null;
    }
    return _readBackwardBits(frame, bitOffset: 9, bitCount: 8);
  }

  static int _readBackwardBits(
    List<int> bytes, {
    required int bitOffset,
    required int bitCount,
  }) {
    var value = 0;
    for (var index = 0; index < bitCount; index++) {
      final bit = bitOffset + index;
      final byte = bytes[bytes.length - 1 - bit ~/ 8];
      value |= ((byte >> (bit & 7)) & 1) << index;
    }
    return value;
  }
}

int g2Crc16(List<int> data) {
  var crc = 0xffff;
  for (final value in data) {
    final byte = value & 0xff;
    crc = (((crc >> 8) | ((crc << 8) & 0xff00)) ^ byte) & 0xffff;
    crc ^= (crc & 0xff) >> 4;
    crc ^= (crc << 12) & 0xffff;
    crc ^= ((crc & 0xff) << 5) & 0xffff;
  }
  return crc & 0xffff;
}

/// Parsed properties of a validated G2 bitmap.
final class G2BitmapMetadata {
  G2BitmapMetadata({
    required this.width,
    required this.height,
    required this.fileBytes,
    required Iterable<int> paletteIndices,
  }) : paletteIndices = List<int>.unmodifiable(
         paletteIndices.toList(growable: false)..sort(),
       );

  final int width;
  final int height;
  final int fileBytes;
  final List<int> paletteIndices;

  /// A content-free description that can be logged before the image is sent.
  String get wireSignature =>
      'BM ${width}x$height 4bpp values=${paletteIndices.join(',')} '
      'bytes=$fileBytes';
}

/// Encodes and validates the 4-bit grayscale BMP format accepted by G2 image
/// containers.
abstract final class G2Bitmap {
  static const int minimumG2ImageWidth = 20;
  static const int maximumG2ImageWidth = 288;
  static const int minimumG2ImageHeight = 20;
  static const int maximumG2ImageHeight = 144;
  static const int _headerBytes = 14 + 40 + 64;

  static Uint8List build4Bit({
    required int width,
    required int height,
    required List<int> grayscale,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Bitmap dimensions must be positive.');
    }
    if (grayscale.length != width * height) {
      throw ArgumentError(
        'Expected ${width * height} grayscale pixels, '
        'received ${grayscale.length}.',
      );
    }
    for (var index = 0; index < grayscale.length; index++) {
      final value = grayscale[index];
      if (value < 0 || value > 0xff) {
        throw ArgumentError.value(
          value,
          'grayscale[$index]',
          'Grayscale values must be in the inclusive 0..255 range.',
        );
      }
    }

    final packedRowBytes = (width + 1) ~/ 2;
    final paddedRowBytes = (packedRowBytes + 3) & ~3;
    final pixelBytes = paddedRowBytes * height;
    final output = Uint8List(_headerBytes + pixelBytes);
    final header = ByteData.sublistView(output);

    output[0] = 0x42;
    output[1] = 0x4d;
    header
      ..setUint32(2, output.length, Endian.little)
      ..setUint32(10, _headerBytes, Endian.little)
      ..setUint32(14, 40, Endian.little)
      ..setInt32(18, width, Endian.little)
      ..setInt32(22, height, Endian.little)
      ..setUint16(26, 1, Endian.little)
      ..setUint16(28, 4, Endian.little)
      ..setUint32(34, pixelBytes, Endian.little)
      ..setInt32(38, 2835, Endian.little)
      ..setInt32(42, 2835, Endian.little)
      ..setUint32(46, 16, Endian.little);

    for (var index = 0; index < 16; index++) {
      final value = index * 17;
      final offset = 54 + index * 4;
      output[offset] = value;
      output[offset + 1] = value;
      output[offset + 2] = value;
    }

    for (var bitmapRow = 0; bitmapRow < height; bitmapRow++) {
      final sourceY = height - 1 - bitmapRow;
      final destination = _headerBytes + bitmapRow * paddedRowBytes;
      for (var x = 0; x < width; x++) {
        final shade = grayscale[sourceY * width + x] >> 4;
        final byteIndex = destination + x ~/ 2;
        if (x.isEven) {
          output[byteIndex] = shade << 4;
        } else {
          output[byteIndex] |= shade;
        }
      }
    }
    return output;
  }

  /// Validates the complete BMP immediately before it crosses the G2 protocol
  /// boundary. This rejects malformed headers, dimensions outside the image
  /// container contract, noncanonical palettes, and nonzero padding.
  static G2BitmapMetadata validateG2Image(
    Uint8List bitmap, {
    Set<int>? allowedPaletteIndices,
  }) {
    if (allowedPaletteIndices != null &&
        allowedPaletteIndices.any((value) => value < 0 || value > 15)) {
      throw ArgumentError.value(
        allowedPaletteIndices,
        'allowedPaletteIndices',
        '4-bit palette indices must be in the inclusive 0..15 range.',
      );
    }
    if (bitmap.length < _headerBytes) {
      throw ArgumentError('G2 bitmap is shorter than its 118-byte header.');
    }
    if (bitmap[0] != 0x42 || bitmap[1] != 0x4d) {
      throw ArgumentError('G2 bitmap must have the BM file signature.');
    }

    final header = ByteData.sublistView(bitmap);
    final fileBytes = header.getUint32(2, Endian.little);
    final dataOffset = header.getUint32(10, Endian.little);
    final dibBytes = header.getUint32(14, Endian.little);
    final width = header.getInt32(18, Endian.little);
    final height = header.getInt32(22, Endian.little);
    final planes = header.getUint16(26, Endian.little);
    final bitsPerPixel = header.getUint16(28, Endian.little);
    final compression = header.getUint32(30, Endian.little);
    final declaredPixelBytes = header.getUint32(34, Endian.little);
    final paletteEntries = header.getUint32(46, Endian.little);

    if (fileBytes != bitmap.length ||
        dataOffset != _headerBytes ||
        dibBytes != 40 ||
        planes != 1 ||
        bitsPerPixel != 4 ||
        compression != 0 ||
        paletteEntries != 16) {
      throw ArgumentError(
        'G2 bitmap header does not match the 4-bit contract.',
      );
    }
    if (width < minimumG2ImageWidth || width > maximumG2ImageWidth) {
      throw ArgumentError.value(
        width,
        'bitmap width',
        'G2 image width must be in the inclusive '
            '$minimumG2ImageWidth..$maximumG2ImageWidth range.',
      );
    }
    if (height < minimumG2ImageHeight || height > maximumG2ImageHeight) {
      throw ArgumentError.value(
        height,
        'bitmap height',
        'G2 image height must be in the inclusive '
            '$minimumG2ImageHeight..$maximumG2ImageHeight range.',
      );
    }

    for (var index = 0; index < 16; index++) {
      final expected = index * 17;
      final offset = 54 + index * 4;
      if (bitmap[offset] != expected ||
          bitmap[offset + 1] != expected ||
          bitmap[offset + 2] != expected ||
          bitmap[offset + 3] != 0) {
        throw ArgumentError(
          'G2 bitmap must use the canonical grayscale palette.',
        );
      }
    }

    final packedRowBytes = (width + 1) ~/ 2;
    final paddedRowBytes = (packedRowBytes + 3) & ~3;
    final pixelBytes = paddedRowBytes * height;
    if (declaredPixelBytes != pixelBytes ||
        dataOffset + pixelBytes != bitmap.length) {
      throw ArgumentError('G2 bitmap pixel length does not match its header.');
    }

    final usedPaletteIndices = <int>{};
    for (var row = 0; row < height; row++) {
      final rowOffset = dataOffset + row * paddedRowBytes;
      for (var x = 0; x < width; x++) {
        final packed = bitmap[rowOffset + x ~/ 2];
        final paletteIndex = x.isEven ? packed >> 4 : packed & 0x0f;
        if (allowedPaletteIndices != null &&
            !allowedPaletteIndices.contains(paletteIndex)) {
          throw ArgumentError.value(
            paletteIndex,
            'bitmap palette index',
            'This G2 bitmap permits only '
                '${allowedPaletteIndices.toList()..sort()}.',
          );
        }
        usedPaletteIndices.add(paletteIndex);
      }
      if (width.isOdd && (bitmap[rowOffset + packedRowBytes - 1] & 0x0f) != 0) {
        throw ArgumentError('G2 bitmap has a nonzero unused pixel nibble.');
      }
      for (var byte = packedRowBytes; byte < paddedRowBytes; byte++) {
        if (bitmap[rowOffset + byte] != 0) {
          throw ArgumentError('G2 bitmap has nonzero row padding.');
        }
      }
    }

    return G2BitmapMetadata(
      width: width,
      height: height,
      fileBytes: fileBytes,
      paletteIndices: usedPaletteIndices,
    );
  }

  /// A single solid rectangle with no background or segmented text glyphs.
  static Uint8List solid({
    required int width,
    required int height,
    int grayscale = 0xff,
  }) {
    return build4Bit(
      width: width,
      height: height,
      grayscale: List<int>.filled(width * height, grayscale),
    );
  }

  /// A high-contrast pattern used to prove the complete page/image data path.
  static Uint8List testPattern({int width = 64, int height = 64}) {
    final pixels = List<int>.filled(width * height, 0);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final border = x < 2 || y < 2 || x >= width - 2 || y >= height - 2;
        final diagonal = (x - y).abs() <= 2 || (x + y - width + 1).abs() <= 2;
        final center =
            (x - width ~/ 2).abs() <= 1 || (y - height ~/ 2).abs() <= 1;
        if (border || diagonal || center) {
          pixels[y * width + x] = 0xff;
        }
      }
    }
    return build4Bit(width: width, height: height, grayscale: pixels);
  }

  /// Draws a quantized grayscale audio-activity pulse for the G2.
  ///
  /// The direct BLE transport receives compressed LC3 rather than PCM, so
  /// [level] is an activity estimate derived from LC3 frame gain. Quantizing
  /// the radius and shade keeps the dot stable and avoids redundant bitmap
  /// writes for insignificant noise-floor changes.
  static Uint8List audioActivityPulse({
    required int level,
    required bool streaming,
    int width = 32,
    int height = 24,
  }) {
    if (width < 5 || height < 5) {
      throw ArgumentError('Pulse dimensions must be at least 5x5.');
    }
    final pixels = List<int>.filled(width * height, 0);
    if (!streaming) {
      return build4Bit(width: width, height: height, grayscale: pixels);
    }

    final state = audioActivityPulseState(level);
    const radii = <int>[2, 3, 4, 5, 7, 9];
    const shades = <int>[0x55, 0x77, 0x99, 0xbb, 0xdd, 0xff];
    final maximumRadius = ((width < height ? width : height) - 2) ~/ 2;
    final radius = radii[state].clamp(1, maximumRadius);
    final radiusSquared = radius * radius;
    final centerX = (width - 1) / 2;
    final centerY = (height - 1) / 2;
    for (var y = 0; y < height; y++) {
      final deltaY = y - centerY;
      for (var x = 0; x < width; x++) {
        final deltaX = x - centerX;
        if ((deltaX * deltaX) + (deltaY * deltaY) <= radiusSquared) {
          pixels[y * width + x] = shades[state];
        }
      }
    }

    return build4Bit(width: width, height: height, grayscale: pixels);
  }

  /// Maps the adaptive 0-255 activity signal to six stable visual states.
  static int audioActivityPulseState(int level) {
    final clamped = level.clamp(0, 255);
    if (clamped < 32) return 0;
    if (clamped < 80) return 1;
    if (clamped < 128) return 2;
    if (clamped < 176) return 3;
    if (clamped < 224) return 4;
    return 5;
  }
}

final class ProtoWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void writeVarint(int value) {
    var remaining = value;
    while (remaining > 0x7f) {
      _bytes.addByte((remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    _bytes.addByte(remaining & 0x7f);
  }

  void writeInt32(int field, int value) {
    writeVarint(field << 3);
    writeVarint(value);
  }

  void writeBool(int field, bool value) => writeInt32(field, value ? 1 : 0);

  void writeBytes(int field, List<int> value) {
    writeVarint((field << 3) | 2);
    writeVarint(value.length);
    _bytes.add(value);
  }

  void writeString(int field, String value) =>
      writeBytes(field, utf8.encode(value));

  void writeMessage(int field, Uint8List value) => writeBytes(field, value);

  Uint8List takeBytes() => _bytes.takeBytes();
}

/// A deliberately small protobuf reader for diagnostic responses.
final class ProtoReader {
  ProtoReader(this.data);

  final Uint8List data;
  int _offset = 0;

  int? readVarint() {
    var result = 0;
    var shift = 0;
    while (_offset < data.length && shift <= 63) {
      final byte = data[_offset++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return result;
      }
      shift += 7;
    }
    return null;
  }

  Uint8List? readBytes() {
    final length = readVarint();
    if (length == null || length < 0 || _offset + length > data.length) {
      return null;
    }
    final value = Uint8List.sublistView(data, _offset, _offset + length);
    _offset += length;
    return Uint8List.fromList(value);
  }

  Map<int, Object> readFields() {
    final fields = <int, Object>{};
    while (_offset < data.length) {
      final tag = readVarint();
      if (tag == null) {
        break;
      }
      final field = tag >> 3;
      final wireType = tag & 0x07;
      switch (wireType) {
        case 0:
          final value = readVarint();
          if (value != null) {
            fields[field] = value;
          }
          break;
        case 2:
          final value = readBytes();
          if (value != null) {
            fields[field] = value;
          }
          break;
        case 1:
          _offset = min(_offset + 8, data.length);
          break;
        case 5:
          _offset = min(_offset + 4, data.length);
          break;
        default:
          _offset = data.length;
          break;
      }
    }
    return fields;
  }
}

final class G2GestureEvent {
  const G2GestureEvent({
    required this.type,
    required this.source,
    required this.name,
    this.path = G2GesturePath.systemEvent,
    this.typeWasOmitted = false,
  });

  final int type;
  final int? source;
  final String name;
  final G2GesturePath path;
  final bool typeWasOmitted;

  bool get isFromR1 => source == 2;

  bool get isLifecycle => type >= 4 && type <= 7;

  G2GestureEvent withSource(int value) {
    return G2GestureEvent(
      type: type,
      source: value,
      name: name,
      path: path,
      typeWasOmitted: typeWasOmitted,
    );
  }
}

final class G2BatteryStatus {
  const G2BatteryStatus({required this.level, this.charging});

  final int level;
  final bool? charging;
}

G2BatteryStatus? decodeG2BatteryStatus(Uint8List payload) {
  final outer = ProtoReader(payload).readFields();
  final command = outer[1];
  if (command != 2 && command != 3) {
    return null;
  }
  for (final field in const <int>[4, 5]) {
    final nested = outer[field];
    if (nested is! Uint8List) {
      continue;
    }
    final values = ProtoReader(nested).readFields();
    final level = values[12];
    if (level is int && level >= 0 && level <= 100) {
      final charging = values[13];
      return G2BatteryStatus(
        level: level,
        charging: charging is int ? charging != 0 : null,
      );
    }
  }
  return null;
}

enum G2GesturePath { systemEvent, textEvent }

/// Decodes both EvenHub input paths:
/// * field13 -> SendDeviceEvent.field3 -> SysEvent
/// * field13 -> SendDeviceEvent.field2 -> TextEvent
///
/// TextEvent is used by the invisible `evt-0` capture container and carries
/// the same event type enum, but the firmware omits its source field.
G2GestureEvent? decodeG2Gesture(Uint8List evenHubPayload) {
  final outer = ProtoReader(evenHubPayload).readFields();
  if (outer[1] != 2 || outer[13] is! Uint8List) {
    return null;
  }
  final deviceEvent = ProtoReader(outer[13]! as Uint8List).readFields();
  final systemPayload = deviceEvent[3];
  if (systemPayload is Uint8List) {
    final systemEvent = ProtoReader(systemPayload).readFields();
    // SINGLE_TAP is enum value zero. Proto3 omits scalar fields carrying their
    // default value, so a valid R1 tap can contain only source=2.
    final encodedType = systemEvent[1];
    final type = encodedType is int ? encodedType : 0;
    return G2GestureEvent(
      type: type,
      source: systemEvent[2] as int?,
      name: _g2GestureName(type),
      typeWasOmitted: encodedType == null,
    );
  }

  final textPayload = deviceEvent[2];
  if (textPayload is Uint8List) {
    final textEvent = ProtoReader(textPayload).readFields();
    final encodedType = textEvent[3];
    final type = encodedType is int ? encodedType : 0;
    return G2GestureEvent(
      type: type,
      source: null,
      name: _g2GestureName(type),
      path: G2GesturePath.textEvent,
      typeWasOmitted: encodedType == null,
    );
  }
  return null;
}

String _g2GestureName(int type) {
  return switch (type) {
    0 => 'single_tap',
    1 => 'swipe_up',
    2 => 'swipe_down',
    3 => 'double_tap',
    4 => 'foreground_enter',
    5 => 'foreground_exit',
    6 => 'abnormal_exit',
    7 => 'system_exit',
    8 => 'imu_data',
    _ => 'unknown_$type',
  };
}

final class G2Transport {
  static const maxPayload = 236;

  static List<Uint8List> buildPackets({
    required int syncId,
    required int serviceId,
    required List<int> payload,
    bool reserveFlag = false,
  }) {
    final chunks = <Uint8List>[];
    for (var offset = 0; offset < payload.length; offset += maxPayload) {
      final end = (offset + maxPayload).clamp(0, payload.length);
      chunks.add(Uint8List.fromList(payload.sublist(offset, end)));
    }
    if (chunks.isEmpty) {
      chunks.add(Uint8List(0));
    }
    if (chunks.last.length == maxPayload) {
      chunks.add(Uint8List(0));
    }

    final crc = g2Crc16(payload);
    final total = chunks.length;
    return <Uint8List>[
      for (var index = 0; index < chunks.length; index++)
        () {
          final chunk = chunks[index];
          final serial = index + 1;
          final isLast = serial == total;
          final output = BytesBuilder(copy: false)
            ..add(<int>[
              0xaa,
              0x21, // destination glasses (2), source phone (1)
              syncId & 0xff,
              (chunk.length + (isLast ? 2 : 0)) & 0xff,
              total & 0xff,
              serial & 0xff,
              serviceId & 0xff,
              reserveFlag ? 0x20 : 0x00,
            ])
            ..add(chunk);
          if (isLast) {
            output.add(<int>[crc & 0xff, (crc >> 8) & 0xff]);
          }
          return output.takeBytes();
        }(),
    ];
  }
}

final class G2ReceivedMessage {
  const G2ReceivedMessage({
    required this.serviceId,
    required this.payload,
    required this.crcValid,
  });

  final int serviceId;
  final Uint8List payload;
  final bool crcValid;
}

final class G2ReceiveAssembler {
  final Map<String, BytesBuilder> _partials = <String, BytesBuilder>{};

  G2ReceivedMessage? add(Uint8List raw, String source) {
    if (raw.length < 10 || raw[0] != 0xaa) {
      return null;
    }
    final payloadLength = raw[3];
    final expectedLength = payloadLength + 8;
    if (raw.length < expectedLength) {
      return null;
    }
    final total = raw[4];
    final serial = raw[5];
    final service = raw[6];
    final resultCode = (raw[7] >> 1) & 0x0f;
    if (resultCode != 0 || total == 0 || serial == 0 || serial > total) {
      return null;
    }

    final isLast = serial == total;
    if (isLast && payloadLength < 2) {
      return null;
    }
    final contentEnd = 8 + payloadLength - (isLast ? 2 : 0);
    final content = Uint8List.sublistView(raw, 8, contentEnd);
    final key = '$source-$service-${raw[2]}';

    BytesBuilder builder;
    if (serial == 1) {
      builder = BytesBuilder(copy: false);
      if (total > 1) {
        _partials[key] = builder;
      }
    } else {
      builder = _partials[key] ?? BytesBuilder(copy: false);
    }
    builder.add(content);
    if (!isLast) {
      return null;
    }

    _partials.remove(key);
    final payload = builder.takeBytes();
    final expectedCrc = raw[contentEnd] | (raw[contentEnd + 1] << 8);
    return G2ReceivedMessage(
      serviceId: service,
      payload: payload,
      crcValid: expectedCrc == g2Crc16(payload),
    );
  }
}

/// Builds the subset of G2 commands needed by this transport POC.
final class G2Protocol {
  static const int fullPageTextX = 0;
  static const int fullPageTextY = 0;
  static const int fullPageTextWidth = 576;
  static const int fullPageTextHeight = 288;
  static const int fullPageTextBorderWidth = 0;
  static const int fullPageTextBorderColor = 5;
  static const int fullPageTextPaddingLength = 4;
  static const int expandedTextBorderWidth = 0;
  static const int expandedTextBorderColor = 5;
  // Keep the history selector and every detail page on the same firmware
  // inset. Without a non-zero inset, the first glyph can appear to shift at
  // the display edge as selection and detail content change.
  static const int expandedTextPaddingLength = 4;
  // G2 image containers accept width 20–288 and height 20–144. Keep one stable
  // 20x144 container centered at the right edge, and move only the visible
  // 4-pixel thumb inside its bitmap. A stable container lets detail page turns
  // use the firmware's in-place text/image upgrade path instead of rebuilding
  // the complete page for every physical swipe.
  static const int fullPageIndicatorInset = expandedTextBorderWidth;
  static const int fullPageIndicatorX =
      fullPageTextWidth - fullPageIndicatorWidth - fullPageIndicatorInset;
  static const int fullPageIndicatorWidth = 20;
  static const int fullPageIndicatorBarWidth = 4;
  // Leave black pixels after the thumb so the uploaded image masks the native
  // right-edge scroll artifact instead of drawing a second line beside it.
  static const int fullPageIndicatorTrailingClearance = 2;
  static const int fullPageIndicatorMinimumWidth = G2Bitmap.minimumG2ImageWidth;
  static const int fullPageIndicatorMaximumWidth = G2Bitmap.maximumG2ImageWidth;
  static const int fullPageIndicatorMinimumHeight =
      G2Bitmap.minimumG2ImageHeight;
  static const int fullPageIndicatorMaximumHeight =
      G2Bitmap.maximumG2ImageHeight;
  static const int fullPageIndicatorHeight = fullPageIndicatorMaximumHeight;
  static const int fullPageIndicatorY =
      (fullPageTextHeight - fullPageIndicatorHeight) ~/ 2;
  static const int fullPageIndicatorMinimumThumbHeight = 8;
  static const int maximumMemoRunes = 4096;
  static const int memoLineRunes = 48;
  static const int memoBodyLinesPerPage = 7;
  static const int visualizerPulseX = 16;
  static const int visualizerPulseY = 12;
  static const int visualizerPulseWidth = 32;
  static const int visualizerPulseHeight = 24;
  static const int visualizerTextX =
      visualizerPulseX + visualizerPulseWidth + 8;
  static const int visualizerTextY = visualizerPulseY;
  static const int visualizerTextWidth = 576 - visualizerTextX;
  static const int visualizerTextHeight = 64;

  int _syncId = 0;
  int _magicRandom = 0;
  int _imageSession = 0;

  int _nextMagic() {
    final value = _magicRandom;
    _magicRandom = (_magicRandom + 1) & 0xff;
    return value;
  }

  List<Uint8List> frame(
    int serviceId,
    Uint8List payload, {
    bool reserveFlag = false,
  }) {
    final packets = G2Transport.buildPackets(
      syncId: _syncId,
      serviceId: serviceId,
      payload: payload,
      reserveFlag: reserveFlag,
    );
    _syncId = (_syncId + 1) & 0xff;
    return packets;
  }

  Uint8List authentication({required bool isIos}) {
    final auth = ProtoWriter()
      ..writeBool(1, true)
      ..writeInt32(2, isIos ? 3 : 4);
    final package = ProtoWriter()
      ..writeInt32(1, 4)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(3, auth.takeBytes());
    return package.takeBytes();
  }

  Uint8List pipeRoleRight() {
    final role = ProtoWriter()..writeInt32(1, 1);
    final package = ProtoWriter()
      ..writeInt32(1, 5)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(4, role.takeBytes());
    return package.takeBytes();
  }

  Uint8List timeSync(DateTime now) {
    final localEpochSeconds =
        now.millisecondsSinceEpoch ~/ 1000 + now.timeZoneOffset.inSeconds;
    final time = ProtoWriter()..writeInt32(1, localEpochSeconds);
    final package = ProtoWriter()
      ..writeInt32(1, 128)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(128, time.takeBytes());
    return package.takeBytes();
  }

  Uint8List deviceHeartbeat() {
    final package = ProtoWriter()
      ..writeInt32(1, 14)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(13, Uint8List(0));
    return package.takeBytes();
  }

  Uint8List ringConnectInfo({
    required bool connect,
    required Uint8List ringMac,
    String ringName = '',
  }) {
    if (ringMac.length != 6) {
      throw ArgumentError.value(ringMac.length, 'ringMac', 'must be 6 bytes');
    }
    final ring = ProtoWriter()
      ..writeBool(1, connect)
      ..writeBytes(2, ringMac);
    if (ringName.isNotEmpty) {
      ring.writeBytes(3, utf8.encode(ringName));
    }
    final package = ProtoWriter()
      ..writeInt32(1, 6)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(5, ring.takeBytes());
    return package.takeBytes();
  }

  Uint8List skipOnboarding() {
    final config = ProtoWriter()..writeInt32(1, 4);
    final package = ProtoWriter()
      ..writeInt32(1, 1)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(3, config.takeBytes());
    return package.takeBytes();
  }

  Uint8List gestureInit() {
    final package = ProtoWriter()
      ..writeInt32(1, 0)
      ..writeInt32(2, _nextMagic());
    return package.takeBytes();
  }

  Uint8List uiSettingsQuery() {
    final package = ProtoWriter()
      ..writeInt32(1, 2)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(4, Uint8List.fromList(<int>[0x08, 0x01, 0x10, 0x00]));
    return package.takeBytes();
  }

  Uint8List deviceInfoRequest() {
    final request = ProtoWriter()..writeInt32(1, 1);
    final package = ProtoWriter()
      ..writeInt32(1, 2)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(4, request.takeBytes());
    return package.takeBytes();
  }

  Uint8List dashboardInit() {
    final display = ProtoWriter()
      ..writeInt32(1, 4)
      ..writeInt32(2, 3)
      ..writeMessage(3, Uint8List.fromList(<int>[1, 2, 3]))
      ..writeInt32(4, 4)
      ..writeMessage(5, Uint8List.fromList(<int>[3, 1, 2, 4, 5]))
      ..writeInt32(6, 1)
      ..writeInt32(7, 2);
    final receive = ProtoWriter()..writeMessage(2, display.takeBytes());
    final package = ProtoWriter()
      ..writeInt32(1, 2)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(4, receive.takeBytes());
    return package.takeBytes();
  }

  Uint8List disableHeyEven() {
    final config = ProtoWriter()..writeInt32(2, 32);
    final package = ProtoWriter()
      ..writeInt32(1, 10)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(13, config.takeBytes());
    return package.takeBytes();
  }

  /// Selects the private firmware mode used by the official Even Terminal.
  ///
  /// Recovered from the official app's `terminal.proto`:
  /// TerminalDataPackage {
  ///   commandId = TERMINAL_MODE_SYNC (1);
  ///   magicRandom = ...;
  ///   modeSync = TerminalModeSync {
  ///     targetMode = MODE_TERMINAL (2) / MODE_DAILY (1);
  ///     errCode = TERMINAL_SUCCESS (0);
  ///   };
  /// }
  Uint8List terminalModeSync({required bool terminal}) {
    final modeSync = ProtoWriter()
      ..writeInt32(1, terminal ? 2 : 1)
      ..writeInt32(2, 0);
    final package = ProtoWriter()
      ..writeInt32(1, 1)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(3, modeSync.takeBytes());
    return package.takeBytes();
  }

  /// Tells Terminal firmware whether its phone/host endpoint is available.
  ///
  /// The official app sends this separately from the mode switch. Advertising
  /// CONNECTED allows the firmware to forward VOICE_START/STOP events instead
  /// of opening the Terminal setup prompt.
  Uint8List terminalPcStatusSync({required bool connected}) {
    final statusSync = ProtoWriter()
      ..writeInt32(1, connected ? 2 : 1)
      ..writeInt32(2, 0);
    final package = ProtoWriter()
      ..writeInt32(1, 2)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(4, statusSync.takeBytes());
    return package.takeBytes();
  }

  /// Publishes the host/session that the G2 Terminal UI can route input to.
  ///
  /// `TERMINAL_SESSION_LIST` is command 8 and field 16 of
  /// `TerminalDataPackage`. The current G2 firmware reports a session-select
  /// notification immediately after entering Terminal mode when this state is
  /// absent.
  Uint8List terminalSessionList({
    int hostId = 1,
    int sessionId = 1,
    String title = 'Flutter BLE POC',
    int agentState = 2,
  }) {
    final item = ProtoWriter()
      ..writeInt32(1, sessionId)
      ..writeString(2, title)
      ..writeInt32(3, agentState);
    final sessions = ProtoWriter()
      ..writeInt32(1, hostId)
      ..writeInt32(2, sessionId)
      ..writeMessage(3, item.takeBytes());
    final package = ProtoWriter()
      ..writeInt32(1, 8)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(16, sessions.takeBytes());
    return package.takeBytes();
  }

  /// Sets the current Terminal agent state.
  ///
  /// States recovered from the official app are NONE=0, THINKING=1,
  /// AWAIT_USER=2, DONE=3 and RESET=4.
  Uint8List terminalAgentStatus({required int state, int sessionId = 1}) {
    final status = ProtoWriter()
      ..writeInt32(1, state)
      ..writeInt32(2, sessionId);
    final package = ProtoWriter()
      ..writeInt32(1, 4)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(6, status.takeBytes());
    return package.takeBytes();
  }

  Uint8List createTextPage(
    String content, {
    bool showPageIndicator = false,
    int pageIndex = 0,
    int pageCount = 1,
    int borderWidth = fullPageTextBorderWidth,
    int borderColor = fullPageTextBorderColor,
    int paddingLength = fullPageTextPaddingLength,
  }) {
    return _textPageMessage(
      content,
      command: 0,
      subField: 3,
      showPageIndicator: showPageIndicator,
      pageIndex: pageIndex,
      pageCount: pageCount,
      borderWidth: borderWidth,
      borderColor: borderColor,
      paddingLength: paddingLength,
    );
  }

  /// Replaces an existing Hub page with the full-height text surface.
  ///
  /// The startup create command is only accepted once for a page session.
  /// Switching away from the audio visualizer therefore requires the rebuild
  /// command; another startup create leaves the visualizer's compact text
  /// container active on current G2 firmware.
  Uint8List rebuildTextPage(
    String content, {
    bool showPageIndicator = false,
    int pageIndex = 0,
    int pageCount = 1,
    int borderWidth = fullPageTextBorderWidth,
    int borderColor = fullPageTextBorderColor,
    int paddingLength = fullPageTextPaddingLength,
  }) {
    return _textPageMessage(
      content,
      command: 7,
      subField: 7,
      showPageIndicator: showPageIndicator,
      pageIndex: pageIndex,
      pageCount: pageCount,
      borderWidth: borderWidth,
      borderColor: borderColor,
      paddingLength: paddingLength,
    );
  }

  Uint8List _textPageMessage(
    String content, {
    required int command,
    required int subField,
    required bool showPageIndicator,
    required int pageIndex,
    required int pageCount,
    required int borderWidth,
    required int borderColor,
    required int paddingLength,
  }) {
    final renderPageIndicator = showPageIndicator && pageCount > 1;
    final resolvedBorderWidth = borderWidth.clamp(0, 32);
    final resolvedBorderColor = borderColor.clamp(0, 15);
    final resolvedPadding = paddingLength.clamp(0, 32);
    final eventCapture = ProtoWriter()
      ..writeInt32(1, 0)
      ..writeInt32(2, 0)
      ..writeInt32(3, 1)
      ..writeInt32(4, 1)
      ..writeInt32(5, 0)
      ..writeInt32(6, 0)
      ..writeInt32(7, 0)
      ..writeInt32(8, 0)
      ..writeInt32(9, 0)
      ..writeString(10, 'evt-0')
      ..writeInt32(11, 1)
      ..writeString(12, '');
    final text = ProtoWriter()
      ..writeInt32(1, fullPageTextX)
      ..writeInt32(2, fullPageTextY)
      ..writeInt32(3, fullPageTextWidth)
      ..writeInt32(4, fullPageTextHeight)
      ..writeInt32(5, resolvedBorderWidth)
      ..writeInt32(6, resolvedBorderColor)
      ..writeInt32(7, 0)
      ..writeInt32(8, resolvedPadding)
      ..writeInt32(9, 1)
      ..writeString(10, 'poc-text')
      ..writeInt32(11, 0)
      ..writeString(12, content);

    final page = ProtoWriter()
      ..writeInt32(1, renderPageIndicator ? 3 : 2)
      ..writeMessage(3, eventCapture.takeBytes());
    // Keep the body last so the diagnostic reader, which retains the final
    // repeated protobuf field, continues to expose the primary text object.
    page.writeMessage(3, text.takeBytes());
    if (renderPageIndicator) {
      final indicator = ProtoWriter()
        ..writeInt32(1, fullPageIndicatorX)
        ..writeInt32(2, fullPageIndicatorY)
        ..writeInt32(3, fullPageIndicatorWidth)
        ..writeInt32(4, fullPageIndicatorHeight)
        ..writeInt32(5, 10)
        ..writeString(6, 'img-10');
      page.writeMessage(4, indicator.takeBytes());
    }
    return _evenHubMessage(
      command: command,
      subField: subField,
      subMessage: page.takeBytes(),
    );
  }

  static ({int y, int height}) detailPageIndicatorGeometry({
    required int pageIndex,
    required int pageCount,
  }) {
    _validateDetailPageIndicatorContract();
    final count = pageCount < 1 ? 1 : pageCount;
    final index = pageIndex.clamp(0, count - 1);
    final height = (fullPageIndicatorHeight / count).ceil().clamp(
      fullPageIndicatorMinimumThumbHeight,
      fullPageIndicatorHeight,
    );
    final travel = fullPageIndicatorHeight - height;
    final y =
        fullPageIndicatorY +
        (count == 1 ? 0 : ((travel * index) / (count - 1)).round());
    return (y: y, height: height);
  }

  static Uint8List detailPageIndicatorBitmap({
    required int pageIndex,
    required int pageCount,
  }) {
    final geometry = detailPageIndicatorGeometry(
      pageIndex: pageIndex,
      pageCount: pageCount,
    );
    final pixels = List<int>.filled(
      fullPageIndicatorWidth * fullPageIndicatorHeight,
      0x00,
    );
    final barStart =
        fullPageIndicatorWidth -
        fullPageIndicatorTrailingClearance -
        fullPageIndicatorBarWidth;
    final thumbStart = geometry.y - fullPageIndicatorY;
    final thumbEnd = thumbStart + geometry.height;
    for (var y = thumbStart; y < thumbEnd; y++) {
      final rowStart = y * fullPageIndicatorWidth;
      pixels.fillRange(
        rowStart + barStart,
        rowStart + barStart + fullPageIndicatorBarWidth,
        0xff,
      );
    }
    final bitmap = G2Bitmap.build4Bit(
      width: fullPageIndicatorWidth,
      height: fullPageIndicatorHeight,
      grayscale: pixels,
    );
    validateDetailPageIndicatorBitmap(bitmap);
    return bitmap;
  }

  /// Revalidates the final wire bytes for the detail scrollbar. The scroll
  /// bitmap is binary by design: only palette index 0 (black) and 15 (full
  /// white) may occur, so a half-gray or corrupt nibble cannot reach G2.
  static G2BitmapMetadata validateDetailPageIndicatorBitmap(Uint8List bitmap) {
    _validateDetailPageIndicatorContract();
    final metadata = G2Bitmap.validateG2Image(
      bitmap,
      allowedPaletteIndices: const <int>{0, 15},
    );
    if (metadata.width != fullPageIndicatorWidth ||
        metadata.height != fullPageIndicatorHeight) {
      throw ArgumentError(
        'Detail page indicator bitmap must be '
        '${fullPageIndicatorWidth}x$fullPageIndicatorHeight.',
      );
    }
    if (metadata.paletteIndices.length != 2 ||
        metadata.paletteIndices[0] != 0 ||
        metadata.paletteIndices[1] != 15) {
      throw ArgumentError(
        'Detail page indicator bitmap must contain full black and full white.',
      );
    }
    return metadata;
  }

  static void _validateDetailPageIndicatorContract() {
    final barStart =
        fullPageIndicatorWidth -
        fullPageIndicatorTrailingClearance -
        fullPageIndicatorBarWidth;
    if (fullPageIndicatorWidth < fullPageIndicatorMinimumWidth ||
        fullPageIndicatorWidth > fullPageIndicatorMaximumWidth ||
        fullPageIndicatorHeight < fullPageIndicatorMinimumHeight ||
        fullPageIndicatorHeight > fullPageIndicatorMaximumHeight ||
        fullPageIndicatorX < 0 ||
        fullPageIndicatorY < 0 ||
        fullPageIndicatorX + fullPageIndicatorWidth > fullPageTextWidth ||
        fullPageIndicatorY + fullPageIndicatorHeight > fullPageTextHeight ||
        fullPageIndicatorBarWidth < 1 ||
        fullPageIndicatorTrailingClearance < 0 ||
        barStart < 0 ||
        fullPageIndicatorMinimumThumbHeight < 1 ||
        fullPageIndicatorMinimumThumbHeight > fullPageIndicatorHeight) {
      throw StateError('Detail page indicator geometry is outside G2 limits.');
    }
  }

  Uint8List createMemoPage(String note, {required String status}) {
    return createTextPage(memoPageContent(note, status: status));
  }

  Uint8List updateMemoPage(String note, {required String status}) {
    return updateText(memoPageContent(note, status: status));
  }

  static String memoPageContent(String note, {required String status}) {
    return memoPageContents(note, status: status).first;
  }

  static List<String> memoPageContents(String note, {required String status}) {
    final normalizedStatus = status.replaceAll(RegExp(r'\s+'), ' ').trim();
    final normalizedNote = note
        .replaceAll(
          RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'),
          '',
        )
        .trim();
    final boundedNote = _truncateRunes(normalizedNote, maximumMemoRunes);
    final wrapped = _wrapDisplayLines(boundedNote, memoLineRunes);
    final bodyLines = wrapped.isEmpty ? const <String>[''] : wrapped;
    final chunks = <List<String>>[];
    for (
      var start = 0;
      start < bodyLines.length;
      start += memoBodyLinesPerPage
    ) {
      final end = (start + memoBodyLinesPerPage).clamp(0, bodyLines.length);
      chunks.add(bodyLines.sublist(start, end));
    }
    return List<String>.generate(chunks.length, (index) {
      final lines = <String>[
        '[ Double Tap to finish ]',
        _truncateRunes(normalizedStatus, memoLineRunes),
        ...chunks[index],
      ];
      while (lines.length < memoBodyLinesPerPage + 2) {
        lines.add('');
      }
      lines.add(
        chunks.length == 1
            ? ''
            : '[ ${index + 1}/${chunks.length} · Swipe to scroll ]',
      );
      return lines.join('\n');
    }, growable: false);
  }

  static List<String> _wrapDisplayLines(String value, int maximumRunes) {
    final words = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty);
    final lines = <String>[];
    var line = '';
    for (final sourceWord in words) {
      var remaining = sourceWord;
      while (remaining.runes.length > maximumRunes) {
        if (line.isNotEmpty) {
          lines.add(line);
          line = '';
        }
        final runes = remaining.runes.toList(growable: false);
        lines.add(String.fromCharCodes(runes.take(maximumRunes)));
        remaining = String.fromCharCodes(runes.skip(maximumRunes));
      }
      if (remaining.isEmpty) {
        continue;
      }
      final candidate = line.isEmpty ? remaining : '$line $remaining';
      if (candidate.runes.length <= maximumRunes) {
        line = candidate;
      } else {
        lines.add(line);
        line = remaining;
      }
    }
    if (line.isNotEmpty) {
      lines.add(line);
    }
    return lines;
  }

  static String _truncateRunes(String value, int maximumRunes) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= maximumRunes) {
      return value;
    }
    return '${String.fromCharCodes(runes.take(maximumRunes - 1))}…';
  }

  Uint8List updateText(String content) {
    final update = ProtoWriter()
      ..writeInt32(1, 1)
      ..writeInt32(3, 0)
      ..writeInt32(4, utf8.encode(content).length)
      ..writeString(5, content);
    return _evenHubMessage(
      command: 5,
      subField: 9,
      subMessage: update.takeBytes(),
    );
  }

  /// Clears the text container by forcing the glasses to repaint a blank.
  ///
  /// The G2 firmware treats a zero-length text update as a no-op, leaving the
  /// previously rendered text on screen. A newline is the firmware-compatible
  /// blank used to replace retained text without rebuilding the page.
  Uint8List clearText() => updateText('\n');

  /// Rebuilds the active page with a text container and a 64x64 image slot.
  Uint8List rebuildPageWithImage({
    required String content,
    int imageX = 256,
    int imageY = 208,
    int imageWidth = 64,
    int imageHeight = 64,
    int textX = 0,
    int textY = 0,
    int textWidth = 576,
    int textHeight = 190,
  }) {
    final eventCapture = ProtoWriter()
      ..writeInt32(1, 0)
      ..writeInt32(2, 0)
      ..writeInt32(3, 1)
      ..writeInt32(4, 1)
      ..writeInt32(5, 0)
      ..writeInt32(6, 0)
      ..writeInt32(7, 0)
      ..writeInt32(8, 0)
      ..writeInt32(9, 0)
      ..writeString(10, 'evt-0')
      ..writeInt32(11, 1)
      ..writeString(12, '');
    final text = ProtoWriter()
      ..writeInt32(1, textX)
      ..writeInt32(2, textY)
      ..writeInt32(3, textWidth)
      ..writeInt32(4, textHeight)
      ..writeInt32(5, 0)
      ..writeInt32(6, 0)
      ..writeInt32(7, 0)
      ..writeInt32(8, 4)
      ..writeInt32(9, 1)
      ..writeString(10, 'poc-text')
      ..writeInt32(11, 0)
      ..writeString(12, content);
    final image = ProtoWriter()
      ..writeInt32(1, imageX)
      ..writeInt32(2, imageY)
      ..writeInt32(3, imageWidth)
      ..writeInt32(4, imageHeight)
      ..writeInt32(5, 10)
      ..writeString(6, 'img-10');
    final page = ProtoWriter()
      ..writeInt32(1, 3)
      ..writeMessage(3, eventCapture.takeBytes())
      ..writeMessage(3, text.takeBytes())
      ..writeMessage(4, image.takeBytes());
    return _evenHubMessage(
      command: 7,
      subField: 7,
      subMessage: page.takeBytes(),
    );
  }

  /// Rebuilds the Hub page with gesture text to the right of the audio pulse.
  Uint8List rebuildAudioVisualizerPage({String gesture = ''}) {
    return rebuildPageWithImage(
      content: gesture,
      imageX: visualizerPulseX,
      imageY: visualizerPulseY,
      imageWidth: visualizerPulseWidth,
      imageHeight: visualizerPulseHeight,
      textX: visualizerTextX,
      textY: visualizerTextY,
      textWidth: visualizerTextWidth,
      textHeight: visualizerTextHeight,
    );
  }

  /// Wraps one complete BMP as an EvenHub image-container update.
  ///
  /// The 64x64 POC bitmap is below the 4096-byte application fragment limit,
  /// so it uses one image fragment. The outer 0xAA transport still fragments
  /// it across the negotiated BLE MTU.
  Uint8List updateImage(Uint8List bmp) {
    G2Bitmap.validateG2Image(bmp);
    _imageSession = (_imageSession + 1) & 0xff;
    final update = ProtoWriter()
      ..writeInt32(1, 10)
      ..writeString(2, 'img-10')
      ..writeInt32(3, _imageSession)
      ..writeInt32(4, bmp.length)
      ..writeInt32(5, 0)
      ..writeInt32(6, 0)
      ..writeInt32(7, bmp.length)
      ..writeBytes(8, bmp);
    return _evenHubMessage(
      command: 3,
      subField: 5,
      subMessage: update.takeBytes(),
    );
  }

  /// Wraps a binary detail scrollbar after applying its stricter contract.
  Uint8List updateDetailPageIndicatorImage(Uint8List bitmap) {
    validateDetailPageIndicatorBitmap(bitmap);
    return updateImage(bitmap);
  }

  Uint8List audioControl(bool enabled) {
    final audio = ProtoWriter()..writeInt32(1, enabled ? 1 : 0);
    return _evenHubMessage(
      command: 15,
      subField: 18,
      subMessage: audio.takeBytes(),
    );
  }

  /// Answers the G2 foreground "End feature" layer.
  ///
  /// `exitMode=0` tells the firmware to exit immediately. `exitMode=1` asks
  /// the native foreground layer to let the wearer decide, which is the
  /// confirmation screen normally opened by a controller hold.
  Uint8List shutdownPage({int exitMode = 0}) {
    final shutdown = ProtoWriter()..writeInt32(1, exitMode);
    return _evenHubMessage(
      command: 9,
      subField: 11,
      subMessage: shutdown.takeBytes(),
    );
  }

  Uint8List evenHubHeartbeat() =>
      _evenHubMessage(command: 12, subField: 14, subMessage: Uint8List(0));

  Uint8List _evenHubMessage({
    required int command,
    required int subField,
    required Uint8List subMessage,
  }) {
    final package = ProtoWriter()
      ..writeInt32(1, command)
      ..writeInt32(2, _nextMagic())
      ..writeMessage(subField, subMessage);
    return package.takeBytes();
  }
}

enum AsyncWritePriority { high, normal, low }

/// Keeps async BLE writes ordered while allowing latency-sensitive control
/// messages to pass queued, nonessential visual updates.
final class AsyncWriteQueue {
  AsyncWriteQueue({Duration operationTimeout = const Duration(seconds: 2)})
    : _operationTimeout = operationTimeout;

  final Queue<_QueuedAsyncWrite> _high = Queue<_QueuedAsyncWrite>();
  final Queue<_QueuedAsyncWrite> _normal = Queue<_QueuedAsyncWrite>();
  final Queue<_QueuedAsyncWrite> _low = Queue<_QueuedAsyncWrite>();
  final Duration _operationTimeout;
  bool _draining = false;

  Future<void> add(
    Future<void> Function() operation, {
    AsyncWritePriority priority = AsyncWritePriority.normal,
  }) {
    final completer = Completer<void>();
    final queued = _QueuedAsyncWrite(operation, completer);
    switch (priority) {
      case AsyncWritePriority.high:
        _high.addLast(queued);
        break;
      case AsyncWritePriority.normal:
        _normal.addLast(queued);
        break;
      case AsyncWritePriority.low:
        _low.addLast(queued);
        break;
    }
    if (!_draining) {
      _draining = true;
      unawaited(_drain());
    }
    return completer.future;
  }

  /// Runs a packetized write as independently queued fragments.
  ///
  /// A higher-priority operation can run between fragments instead of waiting
  /// for an entire bitmap transfer. G2 transport packets carry a sync ID, so
  /// the firmware can reassemble an interleaved one-packet text update while
  /// the lower-priority image transfer remains in progress.
  Future<void> addBatch(
    Iterable<Future<void> Function()> operations, {
    AsyncWritePriority priority = AsyncWritePriority.normal,
    Duration interOperationDelay = Duration.zero,
  }) async {
    final items = operations.toList(growable: false);
    for (var index = 0; index < items.length; index++) {
      await add(items[index], priority: priority);
      if (interOperationDelay > Duration.zero && index + 1 < items.length) {
        await Future<void>.delayed(interOperationDelay);
      }
    }
  }

  Future<void> _drain() async {
    while (_high.isNotEmpty || _normal.isNotEmpty || _low.isNotEmpty) {
      final queued = _high.isNotEmpty
          ? _high.removeFirst()
          : _normal.isNotEmpty
          ? _normal.removeFirst()
          : _low.removeFirst();
      try {
        await queued.operation().timeout(_operationTimeout);
        queued.completer.complete();
      } catch (error, stackTrace) {
        queued.completer.completeError(error, stackTrace);
      }
    }
    _draining = false;
  }
}

final class _QueuedAsyncWrite {
  const _QueuedAsyncWrite(this.operation, this.completer);

  final Future<void> Function() operation;
  final Completer<void> completer;
}
