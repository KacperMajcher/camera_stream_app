package com.example.camera_stream_app

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class JewelryArViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val creationParams = (args as? Map<*, *>)?.mapKeys { it.key.toString() } ?: emptyMap()
        return JewelryArPlatformView(
            context = context,
            viewId = viewId,
            messenger = messenger,
            args = creationParams,
        )
    }
}

