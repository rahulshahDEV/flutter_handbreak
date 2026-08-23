import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_handbreak/handbreak.dart';

void main() {
  group('Validation', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hb_validation');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('requireFileExists passes for existing non-empty file', () {
      final f = File('${tmp.path}/a.mp4')..writeAsStringSync('x');
      expect(() => Validation.requireFileExists(f.path), returnsNormally);
    });
    test('requireFileExists throws for missing file', () {
      expect(() => Validation.requireFileExists('${tmp.path}/nope.mp4'),
          throwsA(isA<InvalidInputException>()));
    });
    test('requireFileExists throws for empty path', () {
      expect(() => Validation.requireFileExists(''), throwsA(isA<InvalidInputException>()));
    });
    test('requireOutputWritable rejects existing without overwrite flag', () {
      final f = File('${tmp.path}/out.mp4')..writeAsStringSync('x');
      expect(() => Validation.requireOutputWritable(f.path),
          throwsA(isA<OutputCreationException>()));
      expect(() => Validation.requireOutputWritable(f.path, overwriteExisting: true), returnsNormally);
    });
    test('requireNotSameFile catches identical absolute paths', () {
      final f = File('${tmp.path}/same.mp4')..writeAsStringSync('x');
      final abs = f.absolute.path;
      expect(() => Validation.requireNotSameFile(abs, abs), throwsA(isA<InvalidInputException>()));
      // relative vs absolute same file
      expect(() => Validation.requireNotSameFile(f.path, f.absolute.path),
          throwsA(isA<InvalidInputException>()));
    });
    test('fileExistsQuietly handles garbage gracefully', () {
      expect(Validation.fileExistsQuietly('/dev/null/is/not/a/file'), isFalse);
      final empty = File('${tmp.path}/e.mp4')..createSync();
      expect(Validation.fileExistsQuietly(empty.path), isFalse); // zero-byte rejected
    });
  });

  group('Error mapping parity', () {
    test('all documented native codes map to typed exceptions', () {
      const codes = {
        'INVALID_INPUT': InvalidInputException,
        'UNSUPPORTED_FORMAT': UnsupportedFormatException,
        'CODEC_UNAVAILABLE': CodecUnavailableException,
        'HARDWARE_UNAVAILABLE': HardwareEncoderUnavailableException,
        'OUTPUT_CREATION_FAILED': OutputCreationException,
        'CANCELLED': CancelledCompressionException,
        'INSUFFICIENT_STORAGE': InsufficientStorageException,
        'OUT_OF_MEMORY': OutOfMemoryException,
        'SOMETHING_NEW': EncodingException, // unknown → generic Encoding
      };
      codes.forEach((code, type) {
        final e = mapNativeError({'code': code, 'message': 'm'});
        expect(e.runtimeType, type, reason: 'code $code should map to $type');
      });
    });
  });

  group('Filters toMap contract', () {
    test('each filter emits a stable type key natives understand', () {
      const expected = <String, String>{
        'crop': 'crop', 'scale': 'scale', 'pad': 'pad', 'rotate': 'rotate',
        'deinterlace': 'deinterlace', 'denoise': 'denoise',
        'sharpen': 'sharpen', 'grayscale': 'grayscale',
      };
      final filters = <VideoFilter>[
        const CropFilter(), const ScaleFilter(), const PadFilter(width: 2, height: 2),
        const RotateFilter(90), const DeinterlaceFilter(), const DenoiseFilter(),
        const SharpenFilter(), const GrayscaleFilter(),
      ];
      for (final f in filters) {
        final m = f.toMap();
        expect(expected.containsKey(m['type']), isTrue,
            reason: '${f.runtimeType} emits unknown type ${m['type']}');
      }
    });
  });
}
