import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'conversation_models.dart';

final class ConversationModelStore {
  ConversationModelStore({
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _supportDirectory = supportDirectory;

  static const String segmentationSha256 =
      'd582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d';
  static const String embeddingSha256 =
      'ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e';

  final Future<Directory> Function() _supportDirectory;

  Future<ConversationModelPaths> prepare() async {
    final support = await _supportDirectory();
    final root = Directory('${support.path}/workbench/models/diarization');
    final segmentation = await _verify(
      File('${root.path}/segmentation.int8.onnx'),
      segmentationSha256,
      'speaker segmentation model',
    );
    final embedding = await _verify(
      File('${root.path}/nemo_en_titanet_small.onnx'),
      embeddingSha256,
      'speaker embedding model',
    );
    return ConversationModelPaths(
      segmentation: segmentation.path,
      embedding: embedding.path,
    );
  }

  Future<String> prepareEmbedding() async {
    final support = await _supportDirectory();
    final file = await _verify(
      File(
        '${support.path}/workbench/models/diarization/nemo_en_titanet_small.onnx',
      ),
      embeddingSha256,
      'speaker embedding model',
    );
    return file.path;
  }

  Future<File> _verify(File file, String expected, String label) async {
    if (!await file.exists()) {
      throw StateError(
        '$label is not installed. Run '
        './tool/stage_android_diarization_models.sh.',
      );
    }
    final marker = File('${file.path}.verified');
    if (await marker.exists() &&
        (await marker.readAsString()).trim() == expected) {
      return file;
    }
    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual != expected) {
      throw StateError('$label failed integrity validation.');
    }
    await marker.writeAsString('$expected\n', flush: true);
    return file;
  }
}
