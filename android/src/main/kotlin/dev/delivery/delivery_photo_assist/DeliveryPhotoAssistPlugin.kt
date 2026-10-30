package dev.delivery.delivery_photo_assist

import android.app.ActivityManager
import android.content.Context
import android.graphics.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.max

class DeliveryPhotoAssistPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val images = Executors.newSingleThreadExecutor()
    private val text = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "delivery_photo_assist")
        channel.setMethodCallHandler(this)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "performanceState") {
            val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val ram = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val thermal = if (Build.VERSION.SDK_INT >= 29) power.currentThermalStatus else 0
            result.success(mapOf("thermalLevel" to when { thermal >= 3 -> 2; thermal >= 1 -> 1; else -> 0 },
                "lowPower" to power.isPowerSaveMode, "lowRam" to ram.isLowRamDevice)); return
        }
        val args = call.arguments as? Map<*, *> ?: run { result.error("arguments", "缺少图片参数", null); return }
        (if (call.method == "analyzeSceneText") text else images).execute {
            try {
                val packet: Any? = when (call.method) {
                    "prepareCameraFrame" -> CameraFrame.prepare(args)
                    "prepareProbeImage" -> CameraFrame.probe(args)
                    "prepareImportedPhoto" -> FrameQuality.normalizeImported(args["image"] as ByteArray)?.let { mapOf("jpeg" to it) }
                    "analyzeSceneText" -> SceneTextScanner.jpeg(args["image"] as ByteArray)
                    else -> null
                }
                main.post { if (packet == null) result.error("image", "无法处理图片", null) else result.success(packet) }
            } catch (_: Exception) { main.post { result.error("image", "无法处理图片", null) } }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null); images.shutdown(); text.shutdown()
    }
}

private object CameraFrame {
    // 本机诊断入口：直接复用实时识别的张量生成器，不参与拍照保存或合规判断。
    fun probe(args: Map<*, *>): Map<String, Any> {
        val bytes = args["image"] as ByteArray
        val image = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: error("image")
        try {
            val size = (args["inputSize"] as Number).toInt()
            require(size in 32..1280)
            val output = if ((args["interpolation"] ?: args["iosInterpolation"]) == "opencv_cubic_uint8") {
                DeliveryTensor.make(image, size)
            } else tensor(image, size)
            return mapOf("tensor" to output, "width" to image.width, "height" to image.height)
        } finally { image.recycle() }
    }

    fun prepare(args: Map<*, *>): Map<String, Any> {
        val width = (args["width"] as Number).toInt(); val height = (args["height"] as Number).toInt()
        require(width in 1..8192 && height in 1..8192)
        require(args["format"] == "yuv420" || args["format"] == "nv21") { "Unsupported camera format" }
        val planes = (args["planes"] as List<*>).map {
            val plane = it as Map<*, *>
            YuvPacking.Plane(plane["bytes"] as ByteArray,
                (plane["rowStride"] as Number).toInt(), (plane["pixelStride"] as Number).toInt())
        }
        val nv21 = YuvPacking.nv21(width, height, planes)
        val encoded = ByteArrayOutputStream().use { out ->
            require(YuvImage(nv21, ImageFormat.NV21, width, height, null).compressToJpeg(Rect(0, 0, width, height), 90, out))
            out.toByteArray()
        }
        val raw = BitmapFactory.decodeByteArray(encoded, 0, encoded.size) ?: error("image")
        val rotation = (args["rotation"] as? Number)?.toInt() ?: 0
        val upright = if (rotation == 0) raw else Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height,
            Matrix().apply { postRotate(rotation.toFloat()) }, true)
        try {
            val scale = minOf(1.0, 768.0 / max(upright.width, upright.height))
            val small = Bitmap.createScaledBitmap(upright, max(1, (upright.width * scale).toInt()), max(1, (upright.height * scale).toInt()), true)
            try {
                val jpeg = ByteArrayOutputStream().use { out -> small.compress(Bitmap.CompressFormat.JPEG, 85, out); out.toByteArray() }
                val box = (args["packageBox"] as? List<*>)?.map { (it as Number).toFloat() }
                val roi = box?.takeIf { it.size == 4 }?.let { RectF(it[0], it[1], it[2], it[3]) }
                val result = mutableMapOf<String, Any>("jpeg" to jpeg, "width" to upright.width,
                    "height" to upright.height, "quality" to FrameQuality.bitmap(small, roi).toMutableMap().apply { put("scope", "live_preview; heuristic; not saved photo validation") })
                if (args["prepareTensor"] == true) {
                    val size = (args["inputSize"] as Number).toInt(); require(size in 32..1280)
                    // 兼容先前自训 manifest 中的字段名，语义为双端输入插值方式。
                    val interpolation = args["interpolation"] ?: args["iosInterpolation"]
                    result["tensor"] = if (interpolation == "opencv_cubic_uint8") {
                        DeliveryTensor.make(upright, size)
                    } else tensor(upright, size)
                }
                return result
            } finally { if (small !== upright) small.recycle() }
        } finally { if (upright !== raw) upright.recycle(); raw.recycle() }
    }
    private fun tensor(image: Bitmap, size: Int): ByteArray {
        val small = Bitmap.createScaledBitmap(image, size, size, true)
        try {
            val pixels = IntArray(size * size); small.getPixels(pixels, 0, size, 0, 0, size, size)
            val buffer = ByteBuffer.allocate(size * size * 3 * 4).order(ByteOrder.LITTLE_ENDIAN)
            val means = floatArrayOf(.485f, .456f, .406f); val stds = floatArrayOf(.229f, .224f, .225f)
            for (c in 0..2) for (pixel in pixels) {
                val value = (pixel shr (16 - c * 8)) and 255
                buffer.putFloat((value / 255f - means[c]) / stds[c])
            }
            return buffer.array()
        } finally { if (small !== image) small.recycle() }
    }
}
