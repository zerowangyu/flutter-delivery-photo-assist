import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:crypto/crypto.dart' as hashing;
import '../domain/guidance.dart';

/// 模型、类别和后处理协议必须一起交付。模型只从本机文件加载。
class PicoDetModel {
  const PicoDetModel({
    required this.path,
    required this.labels,
    this.name = 'PP-PicoDet',
    this.inputSize = 320,
    this.boxesOutput = 'multiclass_nms3_0.tmp_0',
    this.countOutput = 'multiclass_nms3_0.tmp_2',
    this.iosInterpolation,
  });
  final String path, name, boxesOutput, countOutput;
  final List<String> labels;
  final int inputSize;
  final String? iosInterpolation;
  static Future<PicoDetModel> fromFiles({
    required String modelPath,
    required String manifestPath,
  }) async {
    final data = jsonDecode(await File(manifestPath).readAsString()) as Map;
    final expected = data['sha256'] as String?;
    if (expected != null) {
      final actual = await hashing.sha256
          .bind(File(modelPath).openRead())
          .first;
      if (actual.toString() != expected.toLowerCase()) {
        throw const FormatException('模型文件与 manifest 的 SHA-256 不一致');
      }
    }
    if (data['resize'] != null && data['resize'] != 'stretch') {
      throw const FormatException('当前接入协议要求 stretch 预处理');
    }
    return PicoDetModel(
      path: modelPath,
      name: data['name'] as String,
      labels: List<String>.from(data['labels'] as List),
      inputSize: (data['inputSize'] as num).toInt(),
      boxesOutput: data['boxesOutput'] as String,
      countOutput: data['countOutput'] as String,
      iosInterpolation: data['iosInterpolation'] as String?,
    );
  }
}

class PicoDetDetector {
  PicoDetDetector(this.model);
  final PicoDetModel model;
  OrtSession? _session;
  Future<void> open() async {
    if (model.inputSize < 32 ||
        model.inputSize > 1280 ||
        model.labels.isEmpty) {
      throw ArgumentError('模型尺寸或类别清单无效');
    }
    if (model.iosInterpolation != null &&
        model.iosInterpolation != 'opencv_cubic_uint8') {
      throw ArgumentError('不支持该模型预处理插值协议');
    }
    if (model.iosInterpolation == 'opencv_cubic_uint8' &&
        model.inputSize != 320) {
      throw ArgumentError('双端 opencv_cubic_uint8 协议目前仅支持 320 输入');
    }
    _session = await OnnxRuntime().createSession(
      model.path,
      options: OrtSessionOptions(
        intraOpNumThreads: 2,
        interOpNumThreads: 1,
        providers: [OrtProvider.CPU],
      ),
    );
  }

  Future<List<SceneObject>> detect(Float32List input, double confidence) async {
    final session = _session;
    if (session == null) return [];
    OrtValue? image, scale;
    Map<String, OrtValue> outputs = {};
    try {
      image = await OrtValue.fromList(input, [
        1,
        3,
        model.inputSize,
        model.inputSize,
      ]);
      // 输出保持为模型输入坐标，再归一化到完整的竖屏画面。
      scale = await OrtValue.fromList(Float32List.fromList([1, 1]), [1, 2]);
      outputs = await session.run({'image': image, 'scale_factor': scale});
      final rows = await outputs[model.boxesOutput]?.asFlattenedList();
      final counts = await outputs[model.countOutput]?.asFlattenedList();
      if (rows == null || counts == null || counts.isEmpty) {
        throw const FormatException('PicoDet 输出与 manifest 不匹配');
      }
      return decodePicoDet(
        rows,
        (counts.first as num).toInt(),
        model,
        confidence,
      );
    } finally {
      for (final value in outputs.values) {
        await value.dispose();
      }
      await image?.dispose();
      await scale?.dispose();
    }
  }

  Future<void> close() async {
    await _session?.close();
    _session = null;
  }
}

/// 每行 [class_id, score, xmin, ymin, xmax, ymax]，类别从 0 开始。
List<SceneObject> decodePicoDet(
  List<dynamic> values,
  int count,
  PicoDetModel model,
  double threshold,
) {
  if (count < 0 || count * 6 > values.length) {
    throw const FormatException('PicoDet 检测数量无效');
  }
  final result = <SceneObject>[];
  for (var i = 0; i < count; i++) {
    final row = List.generate(6, (j) => (values[i * 6 + j] as num).toDouble());
    if (row.any((v) => !v.isFinite) || row[0] != row[0].roundToDouble())
      continue;
    final label = row[0].toInt();
    if (label < 0 ||
        label >= model.labels.length ||
        row[1] < threshold ||
        row[1] > 1)
      continue;
    final object = SceneObject(
      model.labels[label],
      row[1],
      Rect.fromLTRB(
        row[2] / model.inputSize,
        row[3] / model.inputSize,
        row[4] / model.inputSize,
        row[5] / model.inputSize,
      ),
    );
    if (object.isValid) result.add(object);
  }
  result.sort((a, b) => b.confidence.compareTo(a.confidence));
  return result.take(20).toList();
}
