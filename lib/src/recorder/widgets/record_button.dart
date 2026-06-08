import 'package:flutter/material.dart';

/// The record / stop control: a white ring whose red core morphs from a circle
/// (idle) to a rounded square (recording). A null [onTap] renders it inert.
class RecordButton extends StatelessWidget {
  const RecordButton({super.key, required this.recording, required this.onTap});

  final bool recording;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: recording ? 30 : 62,
            height: recording ? 30 : 62,
            decoration: BoxDecoration(
              color: Colors.redAccent,
              borderRadius: BorderRadius.circular(recording ? 6 : 40),
            ),
          ),
        ),
      ),
    );
  }
}
