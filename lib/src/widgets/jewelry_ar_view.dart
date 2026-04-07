import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native platform view that composites:
///   - Live camera feed (AVCapture on iOS, CameraX on Android)
///   - 3D ring model (SceneKit on iOS, Sceneview/Filament on Android)
///   - MediaPipe Hands for real-time 3D landmark detection
///
/// All heavy processing stays on the native side; Flutter only receives
/// landmark events via EventChannel and sends commands via MethodChannel.
class JewelryArView extends StatelessWidget {
  final String modelAsset;
  final int ringSize;
  final ValueChanged<int>? onPlatformViewCreated;

  const JewelryArView({
    super.key,
    this.modelAsset = 'assets/ring.glb',
    this.ringSize = 3,
    this.onPlatformViewCreated,
  });

  static const String viewType = 'jewelry_ar_view';

  @override
  Widget build(BuildContext context) {
    final creationParams = <String, dynamic>{
      'modelAsset': modelAsset,
      'ringSize': ringSize,
    };

    if (Platform.isIOS) {
      return UiKitView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        onPlatformViewCreated: onPlatformViewCreated,
      );
    }

    if (Platform.isAndroid) {
      return AndroidView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        onPlatformViewCreated: onPlatformViewCreated,
      );
    }

    return const Center(
      child: Text(
        'Platform not supported',
        style: TextStyle(color: Colors.white),
      ),
    );
  }
}
