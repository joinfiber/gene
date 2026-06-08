import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gene/src/editor/editor_api.g.dart';

/// The on-device editor engine (native; Android impl under android .../editor).
///
/// Exposed through a provider so callers depend on the boundary, not a concrete
/// instance — which makes it trivially overridable in tests.
final editorApiProvider = Provider<EditorApi>((ref) => EditorApi());
