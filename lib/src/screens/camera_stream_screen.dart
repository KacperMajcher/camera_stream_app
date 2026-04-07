import 'dart:math';
import 'package:camera_stream_app/src/services/hand_tracking_service.dart';
import 'package:camera_stream_app/src/widgets/jewelry_ar_view.dart';
import 'package:flutter/material.dart';

enum RingSize {
  r1('1', 1),
  r2('2', 2),
  r3('3', 3),
  r4('4', 4),
  r5('5', 5);

  const RingSize(this.label, this.assetIndex);
  final String label;
  final int assetIndex;
}

class CameraStreamView extends StatefulWidget {
  const CameraStreamView({super.key});

  @override
  State<CameraStreamView> createState() => _CameraStreamViewState();
}

class _CameraStreamViewState extends State<CameraStreamView> {
  final _handTracking = HandTrackingService();
  HandLandmarks3D? _landmarks;
  RingSize _selectedSize = RingSize.r3;
  bool _isTrackingStarted = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _handTracking.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lm = _landmarks;

    // Compute debug values from landmarks 0 (wrist), 13 (ring MCP), 14 (ring PIP).
    double? fingerScale;
    double? fingerAngleDeg;
    double? depthDelta;
    if (lm != null) {
      final wrist = lm.wrist;
      final l13 = lm.ringMCP;
      final l14 = lm.ringPIP;
      if (l13 != null && l14 != null) {
        final dx = l14.x - l13.x;
        final dy = l14.y - l13.y;
        fingerScale = sqrt(dx * dx + dy * dy);
        fingerAngleDeg = atan2(dy, dx) * 180 / pi;
      }
      if (wrist != null && l13 != null) {
        depthDelta = l13.z - wrist.z;
      }
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                // Native platform view: camera + SceneKit/Filament + MediaPipe
                Positioned.fill(
                  child: JewelryArView(
                    ringSize: _selectedSize.assetIndex,
                    onPlatformViewCreated: (_) {
                      if (_isTrackingStarted) return;
                      _isTrackingStarted = true;
                      _handTracking.startListening();
                      _handTracking.landmarksStream.listen((lm) {
                        if (mounted) setState(() => _landmarks = lm);
                      });
                    },
                  ),
                ),
                // Debug overlay
                Positioned(
                  top: MediaQuery.of(context).padding.top + 12,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (fingerScale != null)
                          Text(
                            'fingerScale: ${fingerScale.toStringAsFixed(4)}\n'
                            'fingerAngle: ${fingerAngleDeg?.toStringAsFixed(1)}°\n'
                            'depthΔ (L13-wrist): ${depthDelta?.toStringAsFixed(4) ?? '—'}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w500,
                              height: 1.5,
                            ),
                          ),
                        if (lm?.ringPosition != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'RING POSITION:\n'
                            '  X: ${lm!.ringPosition!.x.toStringAsFixed(4)}\n'
                            '  Y: ${lm.ringPosition!.y.toStringAsFixed(4)}\n'
                            '  Z: ${lm.ringPosition!.z.toStringAsFixed(4)}',
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              height: 1.3,
                            ),
                          ),
                        ],
                        if (lm?.ringScale != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'RING SCALE: ${lm!.ringScale!.toStringAsFixed(4)}',
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          _SizeSelector(
            selected: _selectedSize,
            onChanged: (s) => setState(() => _selectedSize = s),
          ),
        ],
      ),
    );
  }
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
