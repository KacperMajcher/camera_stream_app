import 'package:camera/camera.dart';
import 'package:camera_stream_app/src/widgets/camera_stream_preview.dart';
import 'package:flutter/material.dart';

class CameraStreamView extends StatefulWidget {
  final CameraDescription? camera;

  const CameraStreamView({super.key, required this.camera});

  @override
  State<CameraStreamView> createState() => _CameraStreamViewState();
}

class _CameraStreamViewState extends State<CameraStreamView> {
  CameraController? _controller;
  late Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    if (widget.camera != null) {
      _controller = CameraController(
        widget.camera!,
        ResolutionPreset.high,
        enableAudio: false,
      );
      _initFuture = _controller!.initialize().then((_) {
        if (!mounted) return;
        _controller!.startImageStream((CameraImage image) {});
        setState(() {});
      });
    } else {
      _initFuture = Future.error('Nie znaleziono dostępnych kamer.');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.error == null &&
              _controller != null) {
            return CameraStreamPreview(controller: _controller!);
          } else if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  snapshot.error.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
            );
          } else {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
        },
      ),
    );
  }
}
