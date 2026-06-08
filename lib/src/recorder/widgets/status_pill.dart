import 'package:flutter/material.dart';

/// A small rounded, translucent label for top-of-frame status text.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, this.highlighted = false});

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: highlighted ? Colors.redAccent : Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
