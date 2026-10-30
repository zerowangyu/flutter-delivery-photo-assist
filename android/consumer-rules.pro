# ONNX Runtime 的 JNI 会按完整类名和成员签名查找张量类型。
# Release 的 R8 改名或移除这些类型会在实际推理时导致 native abort。
-keep class ai.onnxruntime.** { *; }
