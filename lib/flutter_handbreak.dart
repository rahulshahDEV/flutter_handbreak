/// flutter_handbreak — lightweight, quality-first video & image compression
/// Inspired by HandBrake's pipeline. No GPL code copied; concepts re-implemented MIT.
///
/// Quick start:
/// ```dart
/// import 'package:flutter_handbreak/flutter_handbreak.dart';
/// final result = await FlutterHandbreak.compressVideo('/path/in.mp4', quality: 80);
/// ```
library flutter_handbreak;

export 'handbreak.dart';

// Lightweight facade — one-liner for 90% of developers.
export 'src/api/flutter_handbreak_facade.dart';
