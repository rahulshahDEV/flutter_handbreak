// Benchmark harness — measures encode time, size, CPU, HW vs SW delta per preset.
// Run: dart benchmark/compress_bench.dart --fixtures=benchmark/fixtures
// Produces handbreak_bench_results.json; compare vs baseline to detect regressions.

import 'dart:io';
import 'dart:convert';

/// Fixture descriptor — real media files must be provided separately (not checked into git).
class Fixture {
  const Fixture(this.path, this.label);
  final String path;
  final String label;
}

Future<void> main(List<String> args) async {
  final fixtures = [
    // Add your local fixture paths here; example placeholders:
    // Fixture('benchmark/fixtures/4k_hevc_30s.mp4', '4K HEVC 30s'),
    // Fixture('benchmark/fixtures/1080p_60fps_portrait.mp4', '1080p 60fps portrait'),
  ];

  if (fixtures.isEmpty) {
    print('No fixtures configured. Add paths in benchmark/compress_bench.dart.');
    print('Each preset is then compressed; metrics: source size, output size, ratio, encode time, resolution, fps, codec, quality.');
    return;
  }

  final results = <Map<String, dynamic>>[];
  for (final f in fixtures) {
    if (!File(f.path).existsSync()) {
      print('Skip missing ${f.path}');
      continue;
    }
    // In a real bench, invoke VideoCompressor per preset via HandbreakPlatform (requires device).
    // This stub shows the collection schema.
    results.add({
      'fixture': f.label,
      'path': f.path,
      'sourceSize': File(f.path).lengthSync(),
      'note': 'Run on device via flutter drive to populate encode metrics',
    });
  }

  final out = File('handbreak_bench_results.json');
  out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  print('Wrote ${out.path}');
}
