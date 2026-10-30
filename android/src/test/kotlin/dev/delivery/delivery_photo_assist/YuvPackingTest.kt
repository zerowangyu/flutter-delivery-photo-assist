package dev.delivery.delivery_photo_assist

import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertThrows

class YuvPackingTest {
    private fun plane(bytes: List<Int>, row: Int, pixel: Int = 1) =
        YuvPacking.Plane(bytes.map { it.toByte() }.toByteArray(), row, pixel)
    private val expected = byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 31, 21, 32, 22, 33, 23, 34, 24)

    @Test fun planarPaddingAndShortLastRow() {
        val y = plane(listOf(1, 2, 3, 4, 0, 0, 5, 6, 7, 8, 0, 0, 9, 10, 11, 12, 0, 0, 13, 14, 15, 16), 6)
        val u = plane(listOf(21, 22, 0, 23, 24), 3)
        val v = plane(listOf(31, 32, 0, 33, 34), 3)
        assertArrayEquals(expected, YuvPacking.nv21(4, 4, listOf(y, u, v)))
    }
    @Test fun interleavedChromaWithPixelStrideTwo() {
        val y = plane((1..16).toList(), 4)
        val u = plane(listOf(21, 0, 22, 0, 0, 0, 23, 0, 24), 6, 2)
        val v = plane(listOf(31, 0, 32, 0, 0, 0, 33, 0, 34), 6, 2)
        assertArrayEquals(expected, YuvPacking.nv21(4, 4, listOf(y, u, v)))
    }
    @Test fun tightSinglePlaneNv21() {
        assertArrayEquals(expected, YuvPacking.nv21(4, 4, listOf(YuvPacking.Plane(expected, 4, 1))))
    }
    @Test fun paddedSinglePlaneNv21() {
        val rows = (1..16).toList().chunked(4).flatMap { it + listOf(0, 0) }
        val bytes = rows + listOf(31, 21, 32, 22, 0, 0, 33, 23, 34, 24)
        assertArrayEquals(expected, YuvPacking.nv21(4, 4, listOf(plane(bytes, 6))))
    }
    @Test fun lumaPixelStrideTwo() {
        val y = plane((1..16).flatMap { listOf(it, 0) }.dropLast(1), 8, 2)
        assertArrayEquals(expected, YuvPacking.nv21(4, 4, listOf(y, plane(listOf(21, 22, 23, 24), 2), plane(listOf(31, 32, 33, 34), 2))))
    }
    @Test fun malformedInputRejectedBeforeIndexing() {
        val valid = plane((1..16).toList(), 4)
        val uv = plane(listOf(21, 22, 23, 24), 2)
        for (planes in listOf(emptyList(), listOf(valid, uv), listOf(valid.copy(bytes = byteArrayOf(1)), uv, uv), listOf(valid, uv.copy(pixelStride = 0), uv), listOf(valid.copy(rowStride = 1), uv, uv))) {
            assertThrows(IllegalArgumentException::class.java) { YuvPacking.nv21(4, 4, planes) }
        }
        assertThrows(IllegalArgumentException::class.java) { YuvPacking.nv21(3, 4, listOf(valid, uv, uv)) }
    }
}
