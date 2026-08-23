import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_handbreak/handbreak.dart';

void main() {
  group('ResolutionCalculator', () {
    test('preserves aspect for maxWidth constraint', () {
      final r = ResolutionCalculator.calculate(srcWidth: 3840, srcHeight: 2160, maxWidth: 1920);
      expect(r.width, 1920);
      expect(r.height, 1080);
    });
    test('preserves aspect for maxHeight constraint', () {
      final r = ResolutionCalculator.calculate(srcWidth: 1080, srcHeight: 1920, maxHeight: 720);
      // portrait 1080x1920 -> maxHeight 720 => 405x720 (1080/1920 aspect)
      expect(r.height, 720);
      expect(r.width, 406); // even modulus 2 -> 406
    });
    test('portrait stays portrait', () {
      final r = ResolutionCalculator.calculate(srcWidth: 1080, srcHeight: 1920, maxWidth: 720, maxHeight: 720);
      expect(r.height > r.width, true, reason: 'portrait must remain portrait');
    });
    test('never upscales without explicit target', () {
      final r = ResolutionCalculator.calculate(srcWidth: 640, srcHeight: 480, maxWidth: 1920, maxHeight: 1080);
      expect(r.width, 640);
      expect(r.height, 480);
    });
    test('explicit targetWidth does upscale', () {
      final r = ResolutionCalculator.calculate(srcWidth: 640, srcHeight: 480, targetWidth: 1280);
      expect(r.width, 1280);
      expect(r.height, 960);
    });
    test('scale 0.5 halves dimensions', () {
      final r = ResolutionCalculator.calculate(srcWidth: 1920, srcHeight: 1080, scale: 0.5);
      expect(r.width, 960);
      expect(r.height, 540);
    });
    test('modulus 2 produces even dimensions', () {
      final r = ResolutionCalculator.calculate(srcWidth: 1921, srcHeight: 1081, maxWidth: 1920);
      expect(r.width % 2, 0);
      expect(r.height % 2, 0);
    });
    test('applyRotation swaps for 90 degrees', () {
      final s = ResolutionCalculator.applyRotation(1920, 1080, 90);
      expect(s.width, 1080);
      expect(s.height, 1920);
    });
    test('applyRotation preserves for 0/180', () {
      expect(ResolutionCalculator.applyRotation(1920, 1080, 0).width, 1920);
      expect(ResolutionCalculator.applyRotation(1920, 1080, 180).width, 1920);
    });
    test('progress clamping', () {
      expect(ResolutionCalculator.progress(encodedFrames: 50, totalFrames: 100), 0.5);
      expect(ResolutionCalculator.progress(encodedFrames: 150, totalFrames: 100), 1.0);
      expect(ResolutionCalculator.progress(encodedFrames: 0, totalFrames: 0), 0.0);
    });
    test('estimatedTotalFrames', () {
      expect(ResolutionCalculator.estimateTotalFrames(durationMs: 10000, fps: 30), 300);
      expect(ResolutionCalculator.estimateTotalFrames(durationMs: 0, fps: 30), 0);
    });
  });
}
