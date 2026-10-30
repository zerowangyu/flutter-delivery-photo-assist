# Flutter 配送拍照辅助（通用模型验证版）

一个面向 iOS / Android 的 Flutter 插件：第一张拍清配送物品及其放置位置，第二张扩大环境取景。提供清晰度、取景变化和物体参考提示；任何状态均可拍照。组件不负责订单、上传或配送完成状态。

当前状态：**公开通用组件与验证示例。业务照片、训练数据和私有模型独立管理，不在本仓库中。**

当前版本：**0.1.1 接入预览**。使用官方 Flutter camera + ONNX Runtime，可接入 PP-PicoDet-S / XS。源码不依赖 Ultralytics。配送纸箱、软袋、保温袋、整箱饮料、成提水和大件物品的专项效果，需要另外训练并验证业务模型。附带的本机演示准备脚本使用 COCO 通用权重，不能用于证明这些类别已被识别。

## 已有能力

- 两张照片按步骤拍摄，第二张可对照第一张；拍齐后直接返回本地文件。
- 返回页可分别修改第一张或第二张；只重拍选中的一张，保存后直接返回，另一张保留。
- 相对取景扩大、模糊、过暗、过亮提示；不测量米数、不验证地址。
- 状态色提示、固定布局、识别框默认关闭、相册入口。
- 默认使用后置广角 1×，支持设备允许范围内的按钮和双指缩放。当前不切换到独立超广角镜头。
- 默认分析上限每秒 3 次；省电、低内存或分析过慢时降低频率并暂停 OCR/远景比较。待发布修复中，持续分析过慢仍保留每秒最多一次的物品检测；严重发热或前台内存压力可暂停检测。
- 取景建议不阻止快门与保存，没有拍后合规复核、摆放确认或倾倒检测。
- 本机处理，模型加载失败时仍可拍照；诊断报告把“拍齐两张”与识别结论分开。

## 公开范围

本仓库包含 Flutter 接口、相机与取景辅助代码、原生桥接、通用验证示例及构建说明。演示模型由脚本从上游下载到本机，仓库和发行附件均不提供权重。自训模型通过宿主的本地文件路径接入，训练样本、业务照片、订单信息和签名资料应保存在工程之外。

## 平台和工具

当前验证环境为 Flutter 3.44 / Dart 3.12。iOS 最低 **16.0**（本版 ONNX Runtime 包的要求），Android 最低 **API 24**。更早 iOS 版本需要单独更换/适配推理运行时；本版不声称支持。

相机可选能力不支持时分别降级：无法缩放时隐藏缩放控件，补光或方向锁定失败不影响识别初始化。模型或分析流失败时明确提示“识别暂不可用，仍可拍照”，可从相机设置重新打开。慢机保留低频检测；真正的严重热压力或内存压力下暂停识别。接入时仍需在目标机型验证前后台切换、系统相机中断及相册返回。

自定义 manifest 的 `iosInterpolation` 是沿用的双端协议字段名。当前仅接受省略（默认插值）或 `opencv_cubic_uint8`；后者双端均限定 320 输入。不支持的组合会明确报错，避免两端静默使用不同的预处理。

远景比较使用 OpenCV Native Assets，构建机须安装 CMake 和 Ninja。Android 可使用 Android SDK 自带工具。项目内包含 dartcv4 2.2.2 的 Apache-2.0 修改版：默认启用 features2d/calib3d，并修正 Apple 目标构建，宿主无需复制额外 hooks 配置。

## 接入

仓库：https://github.com/zerowangyu/flutter-delivery-photo-assist （公开通用组件）。业务训练权重、图片和数据集独立存放，不在仓库中。

```yaml
dependencies:
  delivery_photo_assist:
    git:
      url: https://github.com/zerowangyu/flutter-delivery-photo-assist.git
      ref: v0.1.1
```

在宿主 iOS 的 Info.plist 添加 `NSCameraUsageDescription`、`NSPhotoLibraryUsageDescription`。宿主保持自己的签名配置，部署目标至少 iOS 16。Android 声明相机权限；系统相册选择沿用 image_picker。照片不需要写入系统相册。

```dart
import 'package:delivery_photo_assist/delivery_photo_assist.dart';

final model = await PicoDetModel.fromFiles(
  modelPath: localModelPath,
  manifestPath: localManifestPath,
);
if (!context.mounted) return;
final result = await DeliveryPhotoAssist.capture(context, model: model);
if (result == null) return; // 用户取消
// result.parcelPhoto / environmentPhoto 是本地 File。
// 复用宿主已有上传、订单和配送完成流程。
```

`capture` 返回成功后，宿主负责文件留存及上传后清理；取消时只删除插件本次创建的会话副本，相册原图不会被删除。不要把本地文件路径当作服务器 URL。宿主横竖屏策略由宿主管理；示例采用竖屏，当前拍摄界面按竖屏设计。

### 修改某一张照片

宿主订单页面展示 `result` 的两张缩略图，每张绑定自己的修改按钮。首次调用 `capture` 连拍两张；修改时调用 `retake` 并指定对应的 `ShotStage`：

```dart
final updated = await DeliveryPhotoAssist.retake(
  context,
  model: model,
  previous: result,
  stage: ShotStage.parcel, // 第二张使用 ShotStage.environment
);
if (!context.mounted || updated == null) return; // 取消则继续展示原结果
setState(() => result = updated);
```

进入后显示“重拍第一张”或“重拍第二张”，锁定对应步骤；按一次快门（或从相册替换一张）后直接返回，不继续跳转下一张。另一张照片的内容保持原样。重拍第一张不会强制重拍第二张；若实际放置位置变化，司机可自行修改第二张。

修改使用独立的会话副本，原结果的照片与报告不会被覆盖或删除。成功返回的 `updated` 包含两张照片和新报告，请整体替换当前结果；未修改照片的文件路径也可能变化，内容不变。宿主采用并完成必要上传后，可按自己的文件管理策略清理旧的插件会话目录。连续修改会产生多个独立会话，组件不会擅自清理宿主仍在引用的旧结果。

保留结果的会话目录（包含 `report.json` 及第一张的预览参考），重新进入第二张时即可恢复取景对照。缺少旧版预览参考时只提示参考暂不可用，仍可查看第一张、拍照和保存。所有判断仍仅作提醒，没有拍后复核。

完整输入输出、类别命名和训练交付要求见 [模型接入约定](docs/模型接入约定.md)。权重不含在组件工程中，可使用授权的自训模型；业务影像也不包含在仓库中。

## 运行示例

运行插件自身 example 时，克隆目录使用 `delivery_photo_assist`，避开 Flutter 插件示例在 SwiftPM 下按目录名解析的冲突。先在本机准备官方通用演示模型（只下载模型，无照片上传）：

```bash
git clone https://github.com/zerowangyu/flutter-delivery-photo-assist.git delivery_photo_assist
cd delivery_photo_assist
python3 -m venv .venv
.venv/bin/pip install onnx==1.18.0
.venv/bin/python scripts/prepare_demo_models.py
# 仅在 macOS 编译 iOS 时执行，Android 跳过下面这行
swift run --package-path scripts/xcode_config DeliveryExampleConfig example/ios/Runner.xcodeproj
cd example
flutter pub get
flutter run
```

`xcode_config` 通过 XcodeProj API 设置 iOS 16、清除模板个人签名团队并移除重复的本地 SwiftPM 引用。安装真机时在 Xcode 选择自己的开发团队。项目未包含证书、描述文件或私人设备信息。Android 发布到商店须使用宿主自己的正式签名。

示例首页可选 S 或 XS。绿色表示当前建议较合适，红色表示需要注意，黄色表示待确认，均不限制拍摄。正式接入仍建议保留旧版相机作为设置项和异常回退。

## 验证与边界

[验证记录](docs/验证记录.md) 记载真实执行结果；没有实测的数据不作为性能承诺。远景比较依赖共同视觉特征，纯墙面、玻璃反光、遮挡或大角度变化可能无法匹配。文字、物体检测和清晰度均为建议，不能证明地址正确、物品齐全或客户一定能找回。

## 许可

组件原创代码采用 Apache-2.0，可在遵守声明要求的情况下用于闭源 APP，无需为该代码购买商业授权。第三方依赖、权重和训练数据各自遵循其许可，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。代码开源不等于业务照片和模型必须公开。
