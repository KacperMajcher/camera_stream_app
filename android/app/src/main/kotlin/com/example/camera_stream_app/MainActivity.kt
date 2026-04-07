package com.example.camera_stream_app

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine
            .platformViewsController
            .registry
            .registerViewFactory("jewelry_ar_view", JewelryArViewFactory(flutterEngine.dartExecutor.binaryMessenger))
    }
}
