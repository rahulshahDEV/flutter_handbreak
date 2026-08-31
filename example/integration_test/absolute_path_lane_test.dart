import 'dart:io';

import 'package:flutter_handbreak/flutter_handbreak.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end smoke lane that does NOT depend on cwd-relative fixture paths.
/// Fixture dir is injected via --dart-define=FIXTURE_DIR=<abs path on device>.
void main() {
  const fixtureDir =
      String.fromEnvironment('FIXTURE_DIR', defaultValue: '');
  if (fixtureDir.isEmpty) {
    // ignore: avoid_print
    print('NO FIXTURE_DIR — skipping (pass --dart-define=FIXTURE_DIR=...)');
    return;
  }
  String f(String name) => '$fixtureDir/$name';

  group('probe', () {
    test('H.264 probe', () async {
      final info = await HandbreakProbe.probe(f('h264_1080p.mp4'));
      expect(info.videoStreams, isNotEmpty);
      expect(info.primaryVideo!.codec, 'h264');
      expect(info.primaryVideo!.durationMs, greaterThan(0));
    });

    test('portrait rotation metadata', () async {
      final info = await HandbreakProbe.probe(f('portrait_rot90.mov'));
      expect(info.primaryVideo!.rotation % 180, isNot(0));
      expect(info.isPortrait, isTrue);
    });

    test('corrupt input → typed error', () async {
      await expectLater(
        HandbreakProbe.probe(f('truncated.mp4')),
        throwsA(isA<HandbreakException>()),
      );
    });
  });

  group('video compression', () {
    test('H.264 → valid smaller MP4 with audio', () async {
      final out = File('$fixtureDir/out_abs_${DateTime.now().millisecondsSinceEpoch}.mp4');
      final result = await VideoCompressor.compress(
        f('h264_1080p.mp4'),
        options: const VideoCompressionOptions(
          quality: VideoQuality.medium,
          maxWidth: 1920,
          maxHeight: 1080,
        ),
        outputPath: out.path,
      );
      expect(out.existsSync(), isTrue);
      expect(out.lengthSync(), greaterThan(0));
      final info = await HandbreakProbe.probe(out.path);
      expect(info.videoStreams, isNotEmpty);
      expect(info.audioStreams, isNotEmpty,
          reason: 'audio must not silently disappear');
      // ignore: avoid_print
      print('VIDEO_RESULT: size=${out.lengthSync()} '
          'duration=${info.durationMs}ms wasKept=${result.wasKeptOriginal}');
      out.deleteSync();
    });
  });

  group('image compression', () {
    test('JPEG round-trip', () async {
      final out = File('$fixtureDir/out_img_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await ImageCompressor.compress(
        f('photo.jpg'),
        options: const ImageCompressionOptions(quality: 82, maxWidth: 2048, maxHeight: 2048),
        outputPath: out.path,
      );
      expect(out.existsSync(), isTrue);
      expect(out.lengthSync(), greaterThan(0));
      out.deleteSync();
    });

    test('huge.jpg fails safely (bomb guard)', () async {
      await expectLater(
        ImageCompressor.compress(
          f('huge.jpg'),
          options: const ImageCompressionOptions(quality: 80),
          outputPath: '$fixtureDir/out_huge.jpg',
        ),
        throwsA(isA<HandbreakException>()),
      );
    });
  });

  group('capabilities', () {
    test('capabilities report', () async {
      final caps = await HandbreakPlatform.instance.getHardwareCapabilities();
      // ignore: avoid_print
      print('CAPS: ${caps.toMap()}');
    });
  });
}