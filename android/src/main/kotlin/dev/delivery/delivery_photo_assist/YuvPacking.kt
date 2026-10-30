package dev.delivery.delivery_photo_assist

/** 不依赖 Android Bitmap，可单独验证厂商相机的行填充和交错色度布局。 */
internal object YuvPacking {
    data class Plane(val bytes: ByteArray, val rowStride: Int, val pixelStride: Int)

    fun nv21(width: Int, height: Int, planes: List<Plane>): ByteArray {
        require(width in 2..8192 && height in 2..8192 && width % 2 == 0 && height % 2 == 0) {
            "YUV420 requires even dimensions"
        }
        require(planes.size == 1 || planes.size == 3) { "Unsupported YUV plane count" }
        val out = ByteArray(width * height * 3 / 2)
        fun check(plane: Plane, columns: Int, rows: Int, offset: Int = 0) {
            require(plane.pixelStride > 0 && plane.rowStride > 0 && offset >= 0)
            val rowBytes = (columns - 1L) * plane.pixelStride + 1
            // Android 的最后一行可以不带尾部 padding，不能要求 stride * rows 字节。
            val required = offset + (rows - 1L) * plane.rowStride + rowBytes
            require(plane.rowStride >= rowBytes && required <= plane.bytes.size) { "Truncated YUV plane" }
        }
        fun copy(plane: Plane, columns: Int, rows: Int, inputOffset: Int, outputOffset: Int, outputRow: Int, outputPixel: Int) {
            check(plane, columns, rows, inputOffset)
            for (row in 0 until rows) for (column in 0 until columns) {
                out[outputOffset + row * outputRow + column * outputPixel] =
                    plane.bytes[inputOffset + row * plane.rowStride + column * plane.pixelStride]
            }
        }
        val y = planes[0]
        copy(y, width, height, 0, 0, width, 1)
        if (planes.size == 1) {
            // 单平面 NV21：Y 后紧接 VU，UV 沿用同一行距。
            require(y.pixelStride == 1)
            copy(y, width, height / 2, y.rowStride * height, width * height, width, 1)
        } else {
            copy(planes[2], width / 2, height / 2, 0, width * height, width, 2)
            copy(planes[1], width / 2, height / 2, 0, width * height + 1, width, 2)
        }
        return out
    }
}
