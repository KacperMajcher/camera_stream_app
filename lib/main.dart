import 'package:camera/camera.dart';
import 'package:camera_stream_app/src/screens/camera_stream_screen.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final backCamera = cameras.firstWhere(
    (c) => c.lensDirection == CameraLensDirection.back,
    orElse: () => cameras.first,
  );
  runApp(CameraStreamApp(camera: backCamera));
}

class CameraStreamApp extends StatelessWidget {
  final CameraDescription camera;

  const CameraStreamApp({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraStreamView(camera: camera),
    );
  }
}
