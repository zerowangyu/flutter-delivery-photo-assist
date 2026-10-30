import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:delivery_photo_assist/delivery_photo_assist.dart';

// 自定义权重仅从宿主本地资源打包，不进入通用组件仓库。
const _customModelAsset = String.fromEnvironment('DELIVERY_MODEL_ASSET');
const _customModelName = String.fromEnvironment(
  'DELIVERY_MODEL_NAME',
  defaultValue: '自定义配送模型',
);
const _confidenceText = String.fromEnvironment(
  'DELIVERY_MODEL_CONFIDENCE',
  defaultValue: '0.35',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '配送拍照·PicoDet',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF62676E),
          primary: const Color(0xFF24272B),
          surface: const Color(0xFFF6F7F9),
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F7F9),
      ),
      home: const ExampleHome(),
    ),
  );
}

class ExampleHome extends StatefulWidget {
  const ExampleHome({super.key});
  @override
  State<ExampleHome> createState() => _ExampleHomeState();
}

class _ExampleHomeState extends State<ExampleHome> {
  String _variant = 's';
  bool _opening = false;
  DeliveryPhotoResult? _result;
  String? _error;
  Future<PicoDetModel> _model() async {
    final dir = await getApplicationSupportDirectory();
    final base = _customModelAsset.isEmpty
        ? 'picodet_${_variant}_320'
        : _customModelAsset;
    for (final ext in ['onnx', 'json']) {
      final name = '$base.$ext';
      final data = await rootBundle.load('assets/models/$name');
      await File('${dir.path}/$name').writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    return PicoDetModel.fromFiles(
      modelPath: '${dir.path}/$base.onnx',
      manifestPath: '${dir.path}/$base.json',
    );
  }

  Future<void> _open({ShotStage? retakeStage}) async {
    if (_opening) return;
    final previous = _result;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final model = await _model();
      if (!mounted) return;
      final confidence = double.tryParse(_confidenceText) ?? .35;
      final settings = GuideSettings(
        confidence: confidence.isFinite ? confidence.clamp(0, 1) : .35,
      );
      final result = retakeStage != null && previous != null
          ? await DeliveryPhotoAssist.retake(
              context,
              model: model,
              previous: previous,
              stage: retakeStage,
              settings: settings,
            )
          : await DeliveryPhotoAssist.capture(
              context,
              model: model,
              settings: settings,
            );
      if (mounted && result != null) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _error = '暂时无法打开：$error');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        '配送拍照助手',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            '拍清包裹\n也拍清放在哪里',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '第一张拍包裹与位置，第二张拍更多周围环境。提示仅供参考，任何状态都可以拍照。',
            style: TextStyle(height: 1.8),
          ),
          const SizedBox(height: 28),
          if (_customModelAsset.isEmpty)
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 's', label: Text('PicoDet-S')),
                ButtonSegment(value: 'xs', label: Text('PicoDet-XS')),
              ],
              selected: {_variant},
              onSelectionChanged: _opening
                  ? null
                  : (v) => setState(() => _variant = v.first),
            ),
          const SizedBox(height: 16),
          Text(
            _customModelAsset.isEmpty
                ? '接入验证版 · 当前为 COCO 通用模型\n纸箱、配送软袋、整箱饮料等专项类别待训练模型接入。'
                : '已启用 $_customModelName\n识别结果仅作提醒，请以实际拍摄效果为准。',
            style: const TextStyle(
              fontSize: 12,
              color: Colors.black54,
              height: 1.7,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _opening ? null : _open,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            icon: const Icon(Icons.camera_alt_outlined),
            label: Text(
              _opening
                  ? '准备中'
                  : _result == null
                  ? '开始拍照'
                  : '重新拍摄两张',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!),
            ),
          if (_result != null) ...[
            const SizedBox(height: 28),
            const Text('本次照片', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final stage in ShotStage.values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _PhotoCard(
                        stage: stage,
                        file: stage == ShotStage.parcel
                            ? _result!.parcelPhoto
                            : _result!.environmentPhoto,
                        onEdit: _opening
                            ? null
                            : () => _open(retakeStage: stage),
                      ),
                    ),
                  ),
              ],
            ),
            const Text(
              '点击图片或修改按钮，只重拍对应的一张；拍完直接返回，另一张保留。',
              style: TextStyle(fontSize: 12, height: 1.7),
            ),
          ],
        ],
      ),
    ),
  );
}

class _PhotoCard extends StatelessWidget {
  const _PhotoCard({required this.stage, required this.file, this.onEdit});
  final ShotStage stage;
  final File file;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onEdit,
          child: Semantics(
            label: '${stage.label}，${stage.title}，点击重新拍摄',
            child: Image.file(
              file,
              key: ValueKey('photo-${stage.name}'),
              height: 180,
              fit: BoxFit.cover,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Text(
            '${stage.label} · ${stage.title}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton.icon(
          key: ValueKey('edit-${stage.name}'),
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('修改'),
        ),
      ],
    ),
  );
}
