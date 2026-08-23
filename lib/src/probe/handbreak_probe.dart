import '../models/media_info.dart';
import '../platform/handbreak_platform_interface.dart';

/// Robust source analysis — must run before encode when safe processing
/// requires it. Mirrors HandBrake's scan.c → hb_title_t.
///
/// Usage:
/// ```dart
/// final info = await HandbreakProbe.probe('/path/clip.mp4');
/// ```
class HandbreakProbe {
  HandbreakProbe._();

  static Future<MediaInfo> probe(String inputPath) {
    HandbreakPlatform.ensureInitialized();
    return HandbreakPlatform.instance.probe(inputPath);
  }
}
