import 'dart:math';
import 'package:camera/camera.dart';
import 'package:camera_stream_app/src/services/hand_tracking_service.dart';
import 'package:flutter/material.dart';

enum RingSize {
  ct0_5('0.5 ct', 5.0),
  ct1_0('1.0 ct', 6.5),
  ct2_0('2.0 ct', 8.0);

  const RingSize(this.label, this.mm);
  final String label;
  final double mm;
}

class CameraStreamView extends StatefulWidget {
  final CameraDescription? camera;

  const CameraStreamView({super.key, required this.camera});

  @override
  State<CameraStreamView> createState() => _CameraStreamViewState();
}

class _CameraStreamViewState extends State<CameraStreamView> {
  CameraController? _controller;
  late Future<void> _initFuture;
  final _handTracking = HandTrackingService();
  HandLandmarks? _landmarks;
  RingSize _selectedSize = RingSize.ct1_0;

  @override
  void initState() {
    super.initState();
    _handTracking.startListening();
    _handTracking.landmarksStream.listen((lm) {
      if (mounted) setState(() => _landmarks = lm);
    });

    if (widget.camera != null) {
      _controller = CameraController(
        widget.camera!,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );
      _initFuture = _controller!.initialize().then((_) {
        if (!mounted) return;
        _controller!.startImageStream((CameraImage image) {
          _handTracking.sendFrame(image);
        });
        setState(() {});
      });
    } else {
      _initFuture = Future.error('Nie znaleziono dostępnych kamer.');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _handTracking.dispose();
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
            return Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1.0 / _controller!.value.aspectRatio,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final w = constraints.maxWidth;
                          final h = constraints.maxHeight;
                          return Stack(
                            children: [
                              Positioned.fill(
                                child: CameraPreview(_controller!),
                              ),
                              if (_landmarks != null)
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _HandSkeletonPainter(
                                      landmarks: _landmarks!,
                                      selectedSize: _selectedSize,
                                      width: w,
                                      height: h,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                _SizeSelector(
                  selected: _selectedSize,
                  onChanged: (s) => setState(() => _selectedSize = s),
                ),
              ],
            );
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

class _HandSkeletonPainter extends CustomPainter {
  final HandLandmarks landmarks;
  final RingSize selectedSize;
  final double width;
  final double height;

  _HandSkeletonPainter({
    required this.landmarks,
    required this.selectedSize,
    required this.width,
    required this.height,
  });

  Offset _s(Offset n) => Offset(n.dx * width, n.dy * height);

  @override
  void paint(Canvas canvas, Size size) {
    final bonePaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    debugPrint('Klucze landmarks: ${landmarks.joints.keys.toList()}');

    for (final (a, b) in handBones) {
      final ptA = landmarks.get(a);
      final ptB = landmarks.get(b);
      if (ptA != null && ptB != null) {
        canvas.drawLine(_s(ptA), _s(ptB), bonePaint);
      }
    }

    for (final pt in landmarks.joints.values) {
      canvas.drawCircle(_s(pt), 4, dotPaint);
    }

    final ringMCP = landmarks.get('VNHLKRMCP');
    final ringPIP = landmarks.get('VNHLKRPIP');
    final indexMCP = landmarks.get('VNHLKIMCP');
    final middleMCP = landmarks.get('VNHLKMMCP');

    if (ringMCP == null || ringPIP == null) return;

    final mcpPx = _s(ringMCP);
    final pipPx = _s(ringPIP);
    final vec = pipPx - mcpPx;
    final anchor = mcpPx + Offset(vec.dx * 0.7, vec.dy * 0.7);

    double mmToPx = 8.0;
    if (indexMCP != null && middleMCP != null) {
      final d = (_s(indexMCP) - _s(middleMCP)).distance;
      mmToPx = d / 20.0;
    }

    final diameter = selectedSize.mm * mmToPx;

    final angle = atan2(vec.dy, vec.dx);

    canvas.save();
    canvas.translate(anchor.dx, anchor.dy);
    canvas.rotate(angle);

    final ringFill = Paint()
      ..color = Colors.amber.withValues(alpha: 0.45)
      ..style = PaintingStyle.fill;
    final ringBorder = Paint()
      ..color = Colors.amber
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(Offset.zero, diameter / 2, ringFill);
    canvas.drawCircle(Offset.zero, diameter / 2, ringBorder);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HandSkeletonPainter old) =>
      old.landmarks != landmarks || old.selectedSize != selectedSize;
}

class _SizeSelector extends StatelessWidget {
  final RingSize selected;
  final ValueChanged<RingSize> onChanged;

  const _SizeSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: RingSize.values.map((size) {
          final isSelected = size == selected;
          return GestureDetector(
            onTap: () => onChanged(size),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.amber : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? Colors.amber : Colors.white54,
                  width: 1.5,
                ),
              ),
              child: Text(
                size.label,
                style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
