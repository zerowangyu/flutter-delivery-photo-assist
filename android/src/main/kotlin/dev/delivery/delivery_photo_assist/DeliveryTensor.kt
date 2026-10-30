// SPDX-License-Identifier: Apache-2.0
package dev.delivery.delivery_photo_assist

import android.graphics.Bitmap
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor
import kotlin.math.round

/** OpenCV uint8 INTER_CUBIC: A=-0.75, half-pixel, replicated borders, 11-bit coefficients. */
internal object DeliveryTensor {
    private class Axis(val indices: IntArray, val weights: IntArray)

    private fun axis(length: Int, size: Int): Array<Axis> = Array(size) { target ->
        val position = (target + 0.5) * length / size - 0.5
        val start = floor(position).toInt()
        val x = (position - floor(position)).toFloat()
        val a = -0.75f
        val t = x + 1; val u = 1 - x
        val c0 = ((a * t - 5 * a) * t + 8 * a) * t - 4 * a
        val c1 = ((a + 2) * x - (a + 3)) * x * x + 1
        val c2 = ((a + 2) * u - (a + 3)) * u * u + 1
        val c3 = 1 - c0 - c1 - c2
        Axis(IntArray(4) { (start + it - 1).coerceIn(0, length - 1) },
            intArrayOf(round(c0 * 2048).toInt(), round(c1 * 2048).toInt(),
                round(c2 * 2048).toInt(), round(c3 * 2048).toInt()))
    }

    fun make(image: Bitmap, size: Int): ByteArray {
        require(size in 32..1280)
        val width = image.width; val height = image.height
        val pixels = IntArray(width * height)
        image.getPixels(pixels, 0, width, 0, 0, width, height)
        val horizontal = axis(width, size); val vertical = axis(height, size)
        val mean = floatArrayOf(.485f, .456f, .406f)
        val std = floatArrayOf(.229f, .224f, .225f)
        val buffer = ByteBuffer.allocate(size * size * 3 * 4).order(ByteOrder.LITTLE_ENDIAN)
        // 最多缓存四行，避免老手机在每个输出像素重复计算水平插值。
        val rows = LinkedHashMap<Int, IntArray>()
        for (y in 0 until size) {
            val row = vertical[y]
            rows.keys.retainAll(row.indices.toSet())
            for (sourceY in row.indices) {
                if (rows.containsKey(sourceY)) continue
                val values = IntArray(size * 3)
                for (x in 0 until size) {
                    val col = horizontal[x]
                    for (channel in 0..2) {
                        var value = 0
                        for (c in 0..3) {
                            val pixel = pixels[sourceY * width + col.indices[c]]
                            value += ((pixel ushr (16 - channel * 8)) and 255) * col.weights[c]
                        }
                        values[x * 3 + channel] = value
                    }
                }
                rows[sourceY] = values
            }
            for (x in 0 until size) for (channel in 0..2) {
                var value = 0L
                for (r in 0..3) value += rows.getValue(row.indices[r])[x * 3 + channel].toLong() * row.weights[r]
                val byte = ((value + (1L shl 21)) shr 22).coerceIn(0, 255).toFloat()
                val index = (channel * size * size + y * size + x) * 4
                buffer.putFloat(index, (byte * (1f / 255f) - mean[channel]) / std[channel])
            }
        }
        return buffer.array()
    }
}
