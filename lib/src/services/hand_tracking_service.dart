import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

// Wszystkie punkty dłoni z VNHumanHandPoseObservation (rawValue nazw jointów)
class HandLandmarks {
  final Map<String, Offset> joints; // nazwa → znormalizowane (x, y)

  const HandLandmarks(this.joints);

  Offset? get(String name) => joints[name];
}

class HandTrackingService {
  static const _method = MethodChannel('vision_hand_tracking');
  static const _events = EventChannel('vision_hand_tracking/events');

  StreamSubscription<dynamic>? _eventSub;
  final _controller = StreamController<HandLandmarks>.broadcast();

  Stream<HandLandmarks> get landmarksStream => _controller.stream;

  void startListening() {
    _eventSub = _events.receiveBroadcastStream().listen((data) {
      if (data is! Map) return;
      final jointsRaw = data['joints'];
      if (jointsRaw is! Map) return;

      final joints = <String, Offset>{};
      jointsRaw.forEach((key, value) {
        if (value is Map) {
          final x = (value['x'] as num?)?.toDouble();
          final y = (value['y'] as num?)?.toDouble();
          if (x != null && y != null) {
            joints[key as String] = Offset(x, y);
          }
        }
      });

      if (joints.isNotEmpty) {
        _controller.add(HandLandmarks(joints));
      }
    });
  }

  Future<void> sendFrame(CameraImage image) async {
    if (image.planes.isEmpty) return;
    try {
      await _method.invokeMethod('processFrame', {
        'pixels': image.planes[0].bytes,
        'width': image.width,
        'height': image.height,
        'bytesPerRow': image.planes[0].bytesPerRow,
      });
    } on PlatformException {
      // ignoruj błędy pojedynczych klatek
    }
  }

  void dispose() {
    _eventSub?.cancel();
    _controller.close();
  }
}

// Połączenia kości dłoni – klucze natywne Apple Vision (VNRecognizedPointKey.rawValue)
const List<(String, String)> handBones = [
  // Nadgarstek → baza każdego palca
  ('VNHLKWRI', 'VNHLKTCMC'),
  ('VNHLKWRI', 'VNHLKIMCP'),
  ('VNHLKWRI', 'VNHLKMMCP'),
  ('VNHLKWRI', 'VNHLKRMCP'),
  ('VNHLKWRI', 'VNHLKPMCP'),
  // Poprzeczna kość śródręcza
  ('VNHLKIMCP', 'VNHLKMMCP'),
  ('VNHLKMMCP', 'VNHLKRMCP'),
  ('VNHLKRMCP', 'VNHLKPMCP'),
  // Kciuk
  ('VNHLKTCMC', 'VNHLKTMP'),
  ('VNHLKTMP', 'VNHLKTIP'),
  ('VNHLKTIP', 'VNHLKTTIP'),
  // Wskazujący
  ('VNHLKIMCP', 'VNHLKIPIP'),
  ('VNHLKIPIP', 'VNHLKIDIP'),
  ('VNHLKIDIP', 'VNHLKITIP'),
  // Środkowy
  ('VNHLKMMCP', 'VNHLKMPIP'),
  ('VNHLKMPIP', 'VNHLKMDIP'),
  ('VNHLKMDIP', 'VNHLKMTIP'),
  // Serdeczny
  ('VNHLKRMCP', 'VNHLKRPIP'),
  ('VNHLKRPIP', 'VNHLKRDIP'),
  ('VNHLKRDIP', 'VNHLKRTIP'),
  // Mały
  ('VNHLKPMCP', 'VNHLKPPIP'),
  ('VNHLKPPIP', 'VNHLKPDIP'),
  ('VNHLKPDIP', 'VNHLKPTIP'),
];
