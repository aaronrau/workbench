import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'speech_model.dart';

typedef ModelStageStatus = void Function(String message);

final class SpeechModelPaths {
  const SpeechModelPaths({
    required this.vad,
    required this.transcription,
    required this.audioRoot,
  });

  final String vad;
  final TranscriptionModelPaths transcription;
  final String audioRoot;

  Map<String, Object> toMessage() => <String, Object>{
    'vad': vad,
    'transcription': transcription.toMessage(),
    'audioRoot': audioRoot,
  };
}

final class ModelAssetStore {
  ModelAssetStore({
    AssetBundle? bundle,
    Future<Directory> Function() supportDirectory =
        getApplicationSupportDirectory,
  }) : _bundle = bundle ?? rootBundle,
       _supportDirectory = supportDirectory;

  final AssetBundle _bundle;
  final Future<Directory> Function() _supportDirectory;

  Future<String> prepareVad({required ModelStageStatus onStatus}) async {
    final support = await _supportDirectory();
    final root = Directory('${support.path}/workbench/models');
    await root.create(recursive: true);
    final manifest =
        jsonDecode(await _bundle.loadString('assets/models/vad/model.json'))
            as Map<String, dynamic>;
    return (await _stage(
      asset: 'assets/models/vad/${manifest['file']}',
      sha256Hex: manifest['sha256'] as String,
      root: root,
      onStatus: onStatus,
      label: 'voice detector',
    )).path;
  }

  Future<SpeechModelPaths> prepare({
    required SpeechModelDefinition transcriptionModel,
    required ModelStageStatus onStatus,
  }) async {
    final support = await _supportDirectory();
    final modelRoot = Directory('${support.path}/workbench/models');
    final audioRoot = Directory('${support.path}/workbench/audio');
    await modelRoot.create(recursive: true);
    await audioRoot.create(recursive: true);

    final vadManifest =
        jsonDecode(await _bundle.loadString('assets/models/vad/model.json'))
            as Map<String, dynamic>;
    final vad = await _stage(
      asset: 'assets/models/vad/${vadManifest['file']}',
      sha256Hex: vadManifest['sha256']! as String,
      root: modelRoot,
      onStatus: onStatus,
      label: 'voice detector',
    );
    final transcription = await _prepareTranscriptionModel(
      definition: transcriptionModel,
      modelRoot: modelRoot,
      onStatus: onStatus,
    );

    return SpeechModelPaths(
      vad: vad.path,
      transcription: transcription,
      audioRoot: audioRoot.path,
    );
  }

  Future<TranscriptionModelPaths> prepareTranscriptionModel({
    required SpeechModelDefinition definition,
    required ModelStageStatus onStatus,
  }) async {
    final support = await _supportDirectory();
    final modelRoot = Directory('${support.path}/workbench/models');
    await modelRoot.create(recursive: true);
    return _prepareTranscriptionModel(
      definition: definition,
      modelRoot: modelRoot,
      onStatus: onStatus,
    );
  }

  Future<TranscriptionModelPaths> _prepareTranscriptionModel({
    required SpeechModelDefinition definition,
    required Directory modelRoot,
    required ModelStageStatus onStatus,
  }) async {
    final directory = definition.bundledAssetDirectory == null
        ? Directory('${modelRoot.path}/${definition.id}')
        : modelRoot;
    await directory.create(recursive: true);
    final bundled = definition.bundledAssetDirectory;

    Future<File> prepareFile(String fileName, String sha256Hex, String label) {
      if (bundled != null) {
        return _stage(
          asset: '$bundled/$fileName',
          sha256Hex: sha256Hex,
          root: directory,
          onStatus: onStatus,
          label: label,
        );
      }
      return _verifyPreinstalled(
        file: File('${directory.path}/$fileName'),
        sha256Hex: sha256Hex,
        onStatus: onStatus,
        label: label,
      );
    }

    final tokens = await prepareFile(
      definition.tokensFile,
      definition.tokensSha256,
      '${definition.displayName} tokens',
    );
    final model = definition.modelFile == null
        ? null
        : await prepareFile(
            definition.modelFile!,
            definition.modelSha256!,
            '${definition.displayName} model',
          );
    final encoder = definition.encoderFile == null
        ? null
        : await prepareFile(
            definition.encoderFile!,
            definition.encoderSha256!,
            '${definition.displayName} encoder',
          );
    final decoder = definition.decoderFile == null
        ? null
        : await prepareFile(
            definition.decoderFile!,
            definition.decoderSha256!,
            '${definition.displayName} decoder',
          );
    final joiner = definition.joinerFile == null
        ? null
        : await prepareFile(
            definition.joinerFile!,
            definition.joinerSha256!,
            '${definition.displayName} joiner',
          );

    return TranscriptionModelPaths(
      definition: definition,
      tokens: tokens.path,
      model: model?.path,
      encoder: encoder?.path,
      decoder: decoder?.path,
      joiner: joiner?.path,
    );
  }

  Future<File> _stage({
    required String asset,
    required String sha256Hex,
    required Directory root,
    required String label,
    required ModelStageStatus onStatus,
  }) async {
    final fileName = asset.split('/').last;
    final target = File('${root.path}/$fileName');
    final marker = File('${target.path}.verified');
    if (await target.exists() &&
        await marker.exists() &&
        (await marker.readAsString()).trim() == sha256Hex) {
      onStatus('$label ready');
      return target;
    }

    onStatus('Preparing $label…');
    final byteData = await _bundle.load(asset);
    final bytes = Uint8List.sublistView(byteData);
    final actual = sha256.convert(bytes).toString();
    if (actual != sha256Hex) {
      throw StateError(
        '$label failed integrity validation ($actual != $sha256Hex).',
      );
    }

    final partial = File('${target.path}.part');
    if (await partial.exists()) {
      await partial.delete();
    }
    await partial.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await partial.rename(target.path);
    await marker.writeAsString('$sha256Hex\n', flush: true);
    onStatus('$label ready');
    return target;
  }

  Future<File> _verifyPreinstalled({
    required File file,
    required String sha256Hex,
    required String label,
    required ModelStageStatus onStatus,
  }) async {
    if (!await file.exists()) {
      throw StateError(
        '$label is not installed. Run '
        './tool/stage_android_stt_model.sh ${file.parent.path.split('/').last}.',
      );
    }
    final marker = File('${file.path}.verified');
    if (await marker.exists() &&
        (await marker.readAsString()).trim() == sha256Hex) {
      onStatus('$label ready');
      return file;
    }

    onStatus('Verifying $label…');
    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual != sha256Hex) {
      throw StateError(
        '$label failed integrity validation ($actual != $sha256Hex).',
      );
    }
    await marker.writeAsString('$sha256Hex\n', flush: true);
    onStatus('$label ready');
    return file;
  }
}
