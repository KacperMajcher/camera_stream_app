import 'package:flutter/material.dart';
import 'package:camera_stream_app/src/widgets/jewelry_ar_view.dart';

/// Backward-compatible wrapper kept to avoid breaking imports.
/// Internally delegates to the native Jewelry AR platform view.
class CameraStreamPreview extends StatelessWidget {
  final int ringSize;

  const CameraStreamPreview({
    super.key,
    this.ringSize = 3,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(child: JewelryArView(ringSize: ringSize));
  }
}
