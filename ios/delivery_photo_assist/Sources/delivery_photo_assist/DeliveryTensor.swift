// SPDX-License-Identifier: Apache-2.0
import Foundation

/// OpenCV INTER_CUBIC for uint8 RGB: A=-0.75, half-pixel coordinates,
/// replicated borders and 11-bit separable coefficients; no letterbox.
enum DeliveryTensor {
  static func axis(_ length: Int) -> [(indices: [Int], weights: [Int64])] {
    (0..<320).map { target in
      let position = (Double(target) + 0.5) * Double(length) / 320 - 0.5
      let start = Int(floor(position))
      let x = Float(position - floor(position)), a: Float = -0.75
      let t = x + 1, u = 1 - x
      let c0 = ((a * t - 5 * a) * t + 8 * a) * t - 4 * a
      let c1 = ((a + 2) * x - (a + 3)) * x * x + 1
      let c2 = ((a + 2) * u - (a + 3)) * u * u + 1
      let c3: Float = 1 - c0 - c1 - c2
      return ((-1...2).map { min(max(start + $0, 0), length - 1) },
              [c0, c1, c2, c3].map { Int64(($0 * 2048).rounded(.toNearestOrEven)) })
    }
  }

  static func make(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int,
                   stride: Int, rgb: [Int], rotation: Int = 0) -> [Float] {
    let uprightWidth = (rotation == 90 || rotation == 270) ? height : width
    let uprightHeight = (rotation == 90 || rotation == 270) ? width : height
    let horizontal = axis(uprightWidth), vertical = axis(uprightHeight)
    let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
    var output = [Float](repeating: 0, count: 3 * 320 * 320)
    for y in 0..<320 {
      let rows = vertical[y]
      for x in 0..<320 {
        let cols = horizontal[x]
        for channel in 0..<3 {
          var value: Int64 = 0
          for row in 0..<4 {
            var subtotal: Int64 = 0
            for col in 0..<4 {
              let x = cols.indices[col], y = rows.indices[row]
              let sourceX: Int, sourceY: Int
              switch rotation {
              case 90: sourceX = y; sourceY = height - 1 - x
              case 270: sourceX = width - 1 - y; sourceY = x
              case 180: sourceX = width - 1 - x; sourceY = height - 1 - y
              default: sourceX = x; sourceY = y
              }
              subtotal += Int64(pixels[sourceY * stride + sourceX * 4 + rgb[channel]]) * cols.weights[col]
            }
            value += subtotal * rows.weights[row]
          }
          let byte = min(max((value + (1 << 21)) >> 22, 0), 255)
          output[channel * 320 * 320 + y * 320 + x] = (Float(byte) * (1 / 255) - mean[channel]) / std[channel]
        }
      }
    }
    return output
  }
}
