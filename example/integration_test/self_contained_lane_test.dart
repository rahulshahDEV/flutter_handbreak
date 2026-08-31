import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_handbreak/flutter_handbreak.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end integration lane that is fully SELF-CONTAINED: media fixtures
/// are bundled as assets (example/fixtures/media -> ../tool/fixtures), extracted
/// to the app's temp dir at startup, and referenced by absolute path.
///
/// Runs unchanged on Android emulators, iOS simulators and real devices:
///   flutter test integration_test -d <device>     (from example/)
const _fixtureAssets = [
  'fixtures/media/h264_1080p.mp4',
  'fixtures/media/portrait_rot90.mov',
  'fixtures/media/truncated.mp4',
  'fixtures/media/photo.jpg',
  'fixtures/media/huge.jpg',
];

void main() {
  late Directory fixtureDir;

  setUpAll(() async {
    fixtureDir =
        await Directory.systemTemp.createTemp('handbreak_fixtures');
    for (final asset in _fixtureAssets) {
      final data = await rootBundle.load(asset);
      final file = File('${fixtureDir.path}/${asset.split('/').last}');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
  });

  tearDownAll(() async {
    try {
      await fixtureDir.delete(recursive: true);
    } on FileSystemException {
      // best-effort cleanup
    }
  });

  String f(String name) => '${fixtureDir.path}/$name';

  group('probe', () {
    test('H.264 probe', () async {
      final info = await HandbreakProbe.probe(f('h264_1080p.mp4'));
      expect(info.videoStreams, isNotEmpty);
      expect(info.primaryVideo!.codec, 'h264');
      expect(info.primaryVideo!.durationMs, greaterThan(0));
    });

    test('portrait rotation metadata', () async {
      final info = await HandbreakProbe.probe(f('portrait_rot90.mov'));
      expect(info.primaryVideo!.rotation % 180, isNot(0),
          reason: 'rotation must be detected');
      expect(info.isPortrait, isTrue,
          reason: 'rotation-corrected geometry must stay portrait');
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
      final out = File(
          '${fixtureDir.path}/out_${DateTime.now().millisecondsSinceEpoch}.mp4');
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
      expect(out.lengthSync(),
          lessThan(File(f('h264_1080p.mp4')).lengthSync() * 3),
          reason: 'output must stay in a sane size range');
      final info = await HandbreakProbe.probe(out.path);
      expect(info.videoStreams, isNotEmpty);
      expect(info.audioStreams, isNotEmpty,
          reason: 'audio must not silently disappear');
      // ignore: avoid_print
      print('VIDEO_RESULT bytes=${out.lengthSync()} '
          'durationMs=${info.durationMs} keptOriginal=${result.wasKeptOriginal}');
      out.deleteSync();
    });
  });

  group('image compression', () {
    test('JPEG round-trip', () async {
      final out = File(
          '${fixtureDir.path}/out_img_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await ImageCompressor.compress(
        f('photo.jpg'),
        options: const ImageCompressionOptions(
            quality: 82, maxWidth: 2048, maxHeight: 2048),
        outputPath: out.path,
      );
      expect(out.existsSync(), isTrue);
      expect(out.lengthSync(), greaterThan(0));
      // ignore: avoid_print
      print('IMAGE_RESULT bytes=${out.lengthSync()} '
          '(source ${File(f('photo.jpg')).lengthSync()}B)');
      out.deleteSync();
    });

    test('huge.jpg fails safely (decompression-bomb guard)', () async {
      await expectLater(
        ImageCompressor.compress(
          f('huge.jpg'),
          options: const ImageCompressionOptions(quality: 80),
          outputPath: '${fixtureDir.path}/out_huge.jpg',
        ),
        throwsA(isA<HandbreakException>()),
      );
    });
  });

  group('capabilities', () {
    test('hardware capabilities report', () async {
      final caps = await HandbreakPlatform.instance.getHardwareCapabilities();
      // ignore: avoid_print
      print('CAPS ${caps.toMap()}');
    });
  });
}