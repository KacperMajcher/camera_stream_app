import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CameraStreamView extends StatefulWidget {
  const CameraStreamView({super.key});

  @override
  State<CameraStreamView> createState() => _CameraStreamViewState();
}

class _CameraStreamViewState extends State<CameraStreamView> {
  static const _channel = MethodChannel('ring_ar_channel');

  bool _gloveEnabled = true;

  Future<void> _toggleGlove() async {
    final next = !_gloveEnabled;
    setState(() => _gloveEnabled = next);
    try {
      await _channel.invokeMethod('setDebugGlove', {'enabled': next});
    } on PlatformException {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Natywny widok ARKit (kamera + tracking dłoni + szkielet 3D)
          const UiKitView(
            viewType: 'ring_ar_view',
            creationParamsCodec: StandardMessageCodec(),
          ),

          // Przycisk włącz/wyłącz szkielet dłoni.
          Positioned(
            top: 56,
            right: 16,
            child: GestureDetector(
              onTap: _toggleGlove,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _gloveEnabled ? Colors.deepOrange : Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white38),
                ),
                child: Text(
                  _gloveEnabled ? 'GLOVE ON' : 'GLOVE OFF',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
