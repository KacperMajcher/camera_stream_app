import 'dart:async';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

/// 3D hand landmark from MediaPipe Hands.
/// x, y: normalized screen coords [0,1]. z: depth in metres (world landmark).
class HandLandmark3D {
  final double x;
  final double y;
  final double z;

  const HandLandmark3D(this.x, this.y, this.z);

  Vector3 toVector3() => Vector3(x, y, z);
}

/// Full set of 21 MediaPipe hand landmarks with 3D coordinates.
class HandLandmarks3D {
  /// Indexed 0-20 matching MediaPipe joint indices.
  final Map<int, HandLandmark3D> joints;
  
  /// Current calculated 3D position of the ring in camera space.
  final Vector3? ringPosition;
  
  /// Current calculated scale of the ring.
  final double? ringScale;

  const HandLandmarks3D(this.joints, {this.ringPosition, this.ringScale});

  HandLandmark3D? operator [](int index) => joints[index];

  /// Convenience accessors for the ring-placement joints.
  HandLandmark3D? get wrist => joints[0];
  HandLandmark3D? get ringMCP => joints[13];
  HandLandmark3D? get ringPIP => joints[14];
}

/// Receives 3D hand landmarks from native MediaPipe integration.
///
/// The native platform view owns the camera and MediaPipe session.
/// This service only listens for landmark results via EventChannel.
class HandTrackingService {
  static const _events = EventChannel('jewelry_ar_view_events');

  StreamSubscription<dynamic>? _eventSub;
  final _controller = StreamController<HandLandmarks3D>.broadcast();

  Stream<HandLandmarks3D> get landmarksStream => _controller.stream;

  void startListening() {
    if (_eventSub != null) return;
    _eventSub = _events.receiveBroadcastStream().listen((data) {
      if (data is! Map) return;
      final landmarksRaw = data['landmarks'];
      if (landmarksRaw is! Map) return;

      final joints = <int, HandLandmark3D>{};
      landmarksRaw.forEach((key, value) {
        if (value is Map) {
          final x = (value['x'] as num?)?.toDouble();
          final y = (value['y'] as num?)?.toDouble();
          final z = (value['z'] as num?)?.toDouble();
          if (x != null && y != null && z != null) {
            joints[key is int ? key : int.parse(key.toString())] =
                HandLandmark3D(x, y, z);
          }
        }
      });

      Vector3? ringPos;
      final ringPosRaw = data['ringPosition'];
      if (ringPosRaw is Map) {
        ringPos = Vector3(
          (ringPosRaw['x'] as num).toDouble(),
          (ringPosRaw['y'] as num).toDouble(),
          (ringPosRaw['z'] as num).toDouble(),
        );
      }

      final ringScale = (data['ringScale'] as num?)?.toDouble();

      if (joints.isNotEmpty) {
        _controller.add(HandLandmarks3D(
          joints,
          ringPosition: ringPos,
          ringScale: ringScale,
        ));
      }
    }, onError: (Object error, StackTrace stackTrace) {
      // Platform view may not be ready yet; avoid crashing the UI.
      if (error is MissingPluginException) return;
      _controller.addError(error, stackTrace);
    });
  }

  void dispose() {
    _eventSub?.cancel();
    _controller.close();
  }
}

/// MediaPipe hand bone connections (joint index pairs) for skeleton debug overlay.
const List<(int, int)> handBones = [
  // Wrist to finger bases
  (0, 1), (0, 5), (0, 9), (0, 13), (0, 17),
  // Transverse metacarpal
  (5, 9), (9, 13), (13, 17),
  // Thumb
  (1, 2), (2, 3), (3, 4),
  // Index
  (5, 6), (6, 7), (7, 8),
  // Middle
  (9, 10), (10, 11), (11, 12),
  // Ring
  (13, 14), (14, 15), (15, 16),
  // Pinky
  (17, 18), (18, 19), (19, 20),
];
