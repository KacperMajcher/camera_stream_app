import 'dart:math';
import 'package:camera_stream_app/src/services/hand_tracking_service.dart';
import 'package:camera_stream_app/src/widgets/jewelry_ar_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum RingOption {
  classic('Classic', 'assets/ring.avif'),
  solitaire('Ring 2', 'assets/ring2.avif');

  const RingOption(this.label, this.asset);
  final String label;
  final String asset;
}

class CameraStreamView extends StatefulWidget {
  const CameraStreamView({super.key});

  @override
  State<CameraStreamView> createState() => _CameraStreamViewState();
}

class _CameraStreamViewState extends State<CameraStreamView> {
  final _handTracking = HandTrackingService();
  HandLandmarks3D? _landmarks;
  RingOption _selectedRing = RingOption.classic;
  MethodChannel? _platformChannel;
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
                // Native platform view: camera + ring overlay + MediaPipe
                Positioned.fill(
                  child: JewelryArView(
                    modelAsset: _selectedRing.asset,
                    onPlatformViewCreated: (id) {
                      _platformChannel = MethodChannel(
                        'jewelry_ar_view_methods_$id',
                      );
                      _setNativeRingAsset(_selectedRing.asset);

                      if (!_isTrackingStarted) {
                        _isTrackingStarted = true;
                        _handTracking.startListening();
                        _handTracking.landmarksStream.listen((lm) {
                          if (mounted) setState(() => _landmarks = lm);
                        });
                      }
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
          _RingAssetSelector(selected: _selectedRing, onChanged: _selectRing),
        ],
      ),
    );
  }

  Future<void> _setNativeRingAsset(String asset) async {
    try {
      await _platformChannel?.invokeMethod<void>('setRingAsset', {
        'asset': asset,
      });
    } on PlatformException {
      // Native view may not be ready yet; the selected asset is also passed
      // through creationParams when the platform view is created.
    }
  }

  void _selectRing(RingOption ring) {
    setState(() => _selectedRing = ring);
    _setNativeRingAsset(ring.asset);
  }
}

class _RingAssetSelector extends StatelessWidget {
  final RingOption selected;
  final ValueChanged<RingOption> onChanged;

  const _RingAssetSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: RingOption.values.map((ring) {
            final isSelected = ring == selected;
            return GestureDetector(
              onTap: () => onChanged(ring),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 88,
                height: 64,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.amber.withAlpha(36)
                      : Colors.white.withAlpha(12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? Colors.amber : Colors.white54,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: Image.asset(ring.asset, fit: BoxFit.contain),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      ring.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected ? Colors.amber : Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
