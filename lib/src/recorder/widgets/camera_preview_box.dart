import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Full-bleed, cover-fit camera preview. Sizes itself to the camera's true
/// aspect ratio (previewSize is landscape, so width/height are swapped), then
/// lets [FittedBox] scale it to fill the screen with no distortion.
class CameraPreviewBox extends StatelessWidget {
  const CameraPreviewBox({super.key, required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.previewSize;
    final boxWidth = size?.height ?? 3.0;
    final boxHeight = size?.width ?? 4.0;
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: boxWidth,
            height: boxHeight,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }
}
