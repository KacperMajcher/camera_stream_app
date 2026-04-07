package com.example.camera_stream_app

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max

class JewelryArPlatformView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
    args: Map<String, Any>,
) : PlatformView, DefaultLifecycleObserver {

    private val rootView = FrameLayout(context)
    private val previewView = PreviewView(context)
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val eventChannel = EventChannel(messenger, "jewelry_ar_view_events")
    private var eventSink: EventChannel.EventSink? = null

    private var handLandmarker: HandLandmarker? = null
    private val modelAsset = (args["modelAsset"] as? String) ?: "assets/ring.glb"

    init {
        previewView.layoutParams =
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            )
        rootView.addView(previewView)

        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )

        initMediaPipe(context)
        startCamera(context)
    }

    override fun getView(): View = rootView

    override fun dispose() {
        handLandmarker?.close()
        cameraExecutor.shutdown()
        eventChannel.setStreamHandler(null)
    }

    @SuppressLint("UnsafeOptInUsageError")
    private fun startCamera(context: Context) {
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener(
            {
                val cameraProvider = providerFuture.get()
                val preview =
                    Preview.Builder().build().also {
                        it.surfaceProvider = previewView.surfaceProvider
                    }

                val imageAnalyzer =
                    ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                        .also {
                            it.setAnalyzer(cameraExecutor) { imageProxy ->
                                processFrame(imageProxy)
                            }
                        }

                try {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        context as LifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        imageAnalyzer,
                    )
                } catch (error: Exception) {
                    Log.e(TAG, "Camera bind failed", error)
                }
            },
            ContextCompat.getMainExecutor(context),
        )
    }

    private fun initMediaPipe(context: Context) {
        try {
            val modelPath = ensureHandLandmarkerModel(context)
            val options =
                HandLandmarker.HandLandmarkerOptions.builder()
                    .setBaseOptions(BaseOptions.builder().setModelAssetPath(modelPath).build())
                    .setNumHands(1)
                    .setMinHandDetectionConfidence(0.5f)
                    .setMinHandPresenceConfidence(0.5f)
                    .setMinTrackingConfidence(0.5f)
                    .setRunningMode(RunningMode.IMAGE)
                    .build()
            handLandmarker = HandLandmarker.createFromOptions(context, options)
        } catch (error: Exception) {
            Log.e(TAG, "MediaPipe initialization failed", error)
        }
    }

    private fun ensureHandLandmarkerModel(context: Context): String {
        val outFile = File(context.filesDir, "hand_landmarker.task")
        if (outFile.exists() && outFile.length() > 0) {
            return outFile.absolutePath
        }

        context.assets.open("flutter_assets/assets/hand_landmarker.task").use { input ->
            FileOutputStream(outFile).use { output ->
                input.copyTo(output)
            }
        }
        return outFile.absolutePath
    }

    private fun processFrame(imageProxy: ImageProxy) {
        val bitmap = imageProxy.toBitmap()
        if (bitmap == null) {
            imageProxy.close()
            return
        }

        val mpImage: MPImage = BitmapImageBuilder(bitmap).build()
        val result = handLandmarker?.detect(mpImage)
        if (result != null) {
            emitLandmarks(result)
        }
        imageProxy.close()
    }

    private fun emitLandmarks(result: HandLandmarkerResult) {
        val sink = eventSink ?: return
        if (result.landmarks().isEmpty() || result.worldLandmarks().isEmpty()) return

        val normalized = result.landmarks()[0]
        val world = result.worldLandmarks()[0]
        val size = max(normalized.size, world.size)
        val joints = HashMap<Int, Map<String, Double>>(size)

        for (index in 0 until size) {
            val n = normalized.getOrNull(index)
            val w = world.getOrNull(index)
            joints[index] =
                mapOf(
                    "x" to ((n?.x() ?: w?.x() ?: 0f).toDouble()),
                    "y" to ((n?.y() ?: w?.y() ?: 0f).toDouble()),
                    "z" to ((w?.z() ?: 0f).toDouble()),
                )
        }

        sink.success(mapOf("landmarks" to joints))
    }

    companion object {
        private const val TAG = "JewelryArPlatformView"
    }
}

