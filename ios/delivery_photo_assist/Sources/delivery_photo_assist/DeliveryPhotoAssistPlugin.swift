import Flutter
import UIKit
import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

public final class DeliveryPhotoAssistPlugin: NSObject, FlutterPlugin {
  private let imageQueue = DispatchQueue(label: "delivery-photo-images", qos: .userInitiated)
  private let textQueue = DispatchQueue(label: "delivery-photo-text", qos: .utility)
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "delivery_photo_assist", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(DeliveryPhotoAssistPlugin(), channel: channel)
  }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "requestCameraPermission" {
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async { result(granted) }
      }
      return
    }
    if call.method == "performanceState" {
      let info = ProcessInfo.processInfo
      let thermal: Int
      switch info.thermalState { case .nominal: thermal = 0; case .fair: thermal = 1; case .serious: thermal = 2; case .critical: thermal = 3; @unknown default: thermal = 0 }
      result(["thermalLevel": thermal, "lowPower": info.isLowPowerModeEnabled,
              "lowRam": info.physicalMemory <= 2 * 1024 * 1024 * 1024])
      return
    }
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "arguments", message: "缺少图片参数", details: nil)); return
    }
    let method = call.method
    let queue = method == "analyzeSceneText" ? textQueue : imageQueue
    queue.async {
      let value: Any
      do {
        switch method {
        case "prepareCameraFrame": value = try CameraFrame.prepare(args)
        case "prepareImportedPhoto":
          guard let data = (args["image"] as? FlutterStandardTypedData)?.data,
                let jpeg = FrameQuality.normalizeImported(data) else { throw FrameError.invalid }
          value = ["jpeg": FlutterStandardTypedData(bytes: jpeg)]
        case "analyzeSceneText":
          guard let data = (args["image"] as? FlutterStandardTypedData)?.data else { throw FrameError.invalid }
          value = SceneText.jpeg(data)
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }; return
        }
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "image", message: "无法处理图片", details: nil)) }
      }
    }
  }
}

private enum FrameError: Error { case invalid }

private enum CameraFrame {
  static func prepare(_ args: [String: Any]) throws -> [String: Any] {
    guard let width = args["width"] as? Int, let height = args["height"] as? Int,
          width > 0, height > 0, width <= 8192, height <= 8192,
          let planes = args["planes"] as? [[String: Any]], let plane = planes.first,
          let data = (plane["bytes"] as? FlutterStandardTypedData)?.data,
          let stride = plane["rowStride"] as? Int, stride >= width * 4,
          data.count >= stride * height,
          let provider = CGDataProvider(data: data as CFData),
          let raw = CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw FrameError.invalid }
    let rotation = args["rotation"] as? Int ?? 0
    let orientation: UIImage.Orientation = rotation == 90 ? .right : rotation == 270 ? .left : rotation == 180 ? .down : .up
    let swap = rotation == 90 || rotation == 270
    let oriented = UIImage(cgImage: raw, scale: 1, orientation: orientation)
    let frameWidth = swap ? height : width, frameHeight = swap ? width : height
    let scale = min(1, 768.0 / Double(max(frameWidth, frameHeight)))
    let size = CGSize(width: Double(frameWidth) * scale, height: Double(frameHeight) * scale)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let upright = renderer.image { _ in oriented.draw(in: CGRect(origin: .zero, size: size)) }
    guard let jpeg = upright.jpegData(compressionQuality: 0.85), let image = upright.cgImage else { throw FrameError.invalid }
    let roi = (args["packageBox"] as? [Double]).flatMap { b -> CGRect? in
      b.count == 4 ? CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]) : nil
    }
    var quality = FrameQuality.jpeg(jpeg, packageRect: roi, previewAspect: nil)
    quality["scope"] = "live_preview; heuristic; not saved photo validation"
    var result: [String: Any] = ["jpeg": FlutterStandardTypedData(bytes: jpeg),
      "width": frameWidth, "height": frameHeight,
      "quality": quality]
    if args["prepareTensor"] as? Bool == true {
      let inputSize = args["inputSize"] as? Int ?? 320
      guard inputSize >= 32, inputSize <= 1280 else { throw FrameError.invalid }
      if args["iosInterpolation"] as? String == "opencv_cubic_uint8" {
        guard inputSize == 320, [0, 90, 180, 270].contains(rotation) else { throw FrameError.invalid }
        let values = data.withUnsafeBytes { memory in
          DeliveryTensor.make(memory.baseAddress!.assumingMemoryBound(to: UInt8.self),
            width: width, height: height, stride: stride, rgb: [2, 1, 0], rotation: rotation)
        }
        result["tensor"] = FlutterStandardTypedData(bytes: values.withUnsafeBytes { Data($0) })
      } else {
        result["tensor"] = FlutterStandardTypedData(bytes: try tensor(image, size: inputSize))
      }
    }
    return result
  }
  static func tensor(_ image: CGImage, size: Int) throws -> Data {
    var rgba = [UInt8](repeating: 0, count: size * size * 4)
    let drawn = rgba.withUnsafeMutableBytes { memory -> Bool in
      guard let ctx = CGContext(data: memory.baseAddress, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
      return true
    }
    guard drawn else { throw FrameError.invalid }
    let count = size * size
    var values = [Float](repeating: 0, count: count * 3)
    let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
    for c in 0..<3 { for p in 0..<count {
      values[c * count + p] = (Float(rgba[p * 4 + c]) / 255 - mean[c]) / std[c]
    }}
    return values.withUnsafeBytes { Data($0) }
  }
}
