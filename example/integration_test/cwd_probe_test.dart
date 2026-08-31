import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('probe cwd', (tester) async {
    // ignore: avoid_print
    print('CWD_PROBE: ${Directory.current.path}');
    // ignore: avoid_print
    print('FIXTURE_EXISTS: ${File('tool/fixtures/h264_1080p.mp4').existsSync()}');
    // ignore: avoid_print
    print('ABS_EXISTS: ${File('/tool/fixtures/h264_1080p.mp4').existsSync()}');
  });
}