import 'package:camera_stream_app/src/screens/camera_stream_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const CameraStreamApp());
}

class CameraStreamApp extends StatelessWidget {
  const CameraStreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraStreamView(),
    );
  }
}
