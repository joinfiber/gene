import 'package:flutter/material.dart';

import 'package:gene/src/contacts/contacts_screen.dart';
import 'package:gene/src/theme.dart';

/// Root widget. Routing is intentionally trivial (one screen pushes another)
/// until the backend introduces more destinations — at which point it can
/// graduate to a declarative router without touching the features.
class GeneApp extends StatelessWidget {
  const GeneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'gene',
      debugShowCheckedModeBanner: false,
      theme: buildGeneTheme(),
      home: const ContactsScreen(),
    );
  }
}
