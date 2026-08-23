import 'package:flutter/material.dart';
import 'package:flutter_handbreak/handbreak.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const HandbreakDemoApp());

class HandbreakDemoApp extends StatelessWidget {
  const HandbreakDemoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Handbreak Demo',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const DemoHome(),
    );
  }
}

class DemoHome extends StatefulWidget {
  const DemoHome({super.key});
  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  String? inputPath;
  MediaInfo? mediaInfo;
  CompressionProgress? progress;
  CompressionResult? lastResult;
  CompressionJob? activeJob;
  String status = 'Pick a video or image to begin';
  VideoPresetId selectedPreset = VideoPresetId.balanced;
  bool isProbeLoading = false;

  Future<void> pickFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.single.path == null) return;
    final path = res.files.single.path!;
    setState(() {
      inputPath = path;
      mediaInfo = null;
      lastResult = null;
      progress = null;
      status = 'Probing $path ...';
      isProbeLoading = true;
    });
    try {
      final info = await HandbreakProbe.probe(path);
      setState(() {
        mediaInfo = info;
        status = 'Ready — ${info.videoStreams.length} video / ${info.audioStreams.length} audio, ${info.durationMs}ms, ${info.fileSizeBytes} bytes';
      });
    } catch (e) {
      setState(() => status = 'Probe failed: $e');
    } finally {
      setState(() => isProbeLoading = false);
    }
  }

  Future<String> _outputPath(String input, String ext) async {
    final dir = await getTemporaryDirectory();
    final base = input.split('/').last.split('.').first;
    return '${dir.path}/${base}_handbreak_out$ext';
  }

  Future<void> compressVideo() async {
    if (inputPath == null) return;
    final opts = selectedPreset.toOptions();
    // Demonstrate explicit options override: cap at 1080p, hardware auto
    final resolved = opts.copyWith(maxWidth: 1920, maxHeight: 1080);
    final out = await _outputPath(inputPath!, '.mp4');
    setState(() {
      status = 'Compressing with ${selectedPreset.displayName} ...';
      progress = null;
      lastResult = null;
    });
    try {
      final job = await VideoCompressor.start(inputPath!, options: resolved, outputPath: out);
      setState(() => activeJob = job);
      job.progress.listen((p) {
        setState(() => progress = p);
      }, onError: (e) => setState(() => status = 'Progress error: $e'));
      final result = await job.result;
      setState(() {
        lastResult = result;
        status = 'Done: ${result.compressionPercentage.toStringAsFixed(1)}% saved, hw=${result.usedHardwareAcceleration}';
        activeJob = null;
      });
    } on CancelledCompressionException {
      setState(() { status = 'Cancelled'; activeJob = null; });
    } catch (e) {
      setState(() { status = 'Failed: $e'; activeJob = null; });
    }
  }

  Future<void> compressImage() async {
    if (inputPath == null) return;
    final out = await _outputPath(inputPath!, '.jpg');
    setState(() => status = 'Compressing image ...');
    try {
      final job = await ImageCompressor.start(inputPath!,
          options: const ImageCompressionOptions(quality: 82, maxWidth: 2048, maxHeight: 2048, format: ImageFormat.auto),
          outputPath: out);
      setState(() => activeJob = job);
      job.progress.listen((p) => setState(() => progress = p));
      final result = await job.result;
      setState(() {
        // ImageCompressor returns CompressionResult as well
        status = 'Image done: ${result.compressionPercentage.toStringAsFixed(1)}% saved';
        activeJob = null;
      });
    } catch (e) {
      setState(() { status = 'Image failed: $e'; activeJob = null; });
    }
  }

  Future<void> cancel() async {
    await activeJob?.cancel();
    setState(() => status = 'Cancelling ...');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Handbreak — HandBrake-inspired Demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(onPressed: pickFile, icon: const Icon(Icons.file_open), label: const Text('Pick Video / Image')),
          const SizedBox(height: 12),
          if (inputPath != null) Text('Input: $inputPath', style: const TextStyle(fontSize: 12)),
          if (isProbeLoading) const LinearProgressIndicator(),
          if (mediaInfo != null) Card(
            child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Container: ${mediaInfo!.container}  Duration: ${mediaInfo!.durationMs}ms  Size: ${mediaInfo!.fileSizeBytes}'),
              if (mediaInfo!.primaryVideo != null) Text('Video: ${mediaInfo!.primaryVideo!.width}x${mediaInfo!.primaryVideo!.height} ${mediaInfo!.primaryVideo!.codec} ${mediaInfo!.primaryVideo!.frameRate.toStringAsFixed(1)}fps rot=${mediaInfo!.primaryVideo!.rotation} hdr=${mediaInfo!.primaryVideo!.isHdr}'),
              if (mediaInfo!.primaryAudio != null) Text('Audio: ${mediaInfo!.primaryAudio!.codec} ${mediaInfo!.primaryAudio!.sampleRate}Hz ${mediaInfo!.primaryAudio!.channelCount}ch'),
              Text('Streams: ${mediaInfo!.videoStreams.length}v / ${mediaInfo!.audioStreams.length}a  Bitrate: ${mediaInfo!.overallBitrate}'),
            ])),
          ),
          const SizedBox(height: 12),
          Text('Preset', style: Theme.of(context).textTheme.titleSmall),
          DropdownButton<VideoPresetId>(
            value: selectedPreset,
            isExpanded: true,
            items: VideoPresetId.values.map((p) => DropdownMenuItem(value: p, child: Text(p.displayName))).toList(),
            onChanged: (v) => setState(() => selectedPreset = v!),
          ),
          Text(selectedPreset.description, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: inputPath == null || activeJob != null ? null : compressVideo, child: const Text('Compress Video')),
            OutlinedButton(onPressed: inputPath == null || activeJob != null ? null : compressImage, child: const Text('Compress Image')),
            if (activeJob != null) FilledButton.tonalIcon(onPressed: cancel, icon: const Icon(Icons.cancel), label: const Text('Cancel')),
          ]),
          const SizedBox(height: 12),
          Text(status),
          if (progress != null) Column(children: [
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress!.progress),
            Text('${(progress!.progress * 100).toStringAsFixed(1)}%  ${progress!.encodedFrames}/${progress!.totalFrames}  ${progress!.currentFps.toStringAsFixed(1)} fps  stage:${progress!.stage}'),
            if (progress!.estimatedRemaining != null) Text('ETA: ${progress!.estimatedRemaining}'),
          ]),
          if (lastResult != null) Card(
            color: Colors.green.shade50,
            child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Output: ${lastResult!.outputPath}', style: const TextStyle(fontSize: 12)),
              Text('Size: ${lastResult!.originalSizeBytes} → ${lastResult!.outputSizeBytes}  Saved: ${lastResult!.savedBytes} (${lastResult!.compressionPercentage.toStringAsFixed(1)}%)'),
              Text('Ratio: ${lastResult!.compressionRatio.toStringAsFixed(2)}x  Codec: ${lastResult!.codec}/${lastResult!.container}  HW: ${lastResult!.usedHardwareAcceleration}  Time: ${lastResult!.durationMs}ms'),
              if (lastResult!.qualityWarning != null) Text('Warning: ${lastResult!.qualityWarning}', style: const TextStyle(color: Colors.orange)),
              if (lastResult!.wasKeptOriginal) const Text('Kept original — output would have been larger', style: TextStyle(color: Colors.blue)),
            ])),
          ),
          const Divider(height: 32),
          const Text('Quality mapping (codec-aware):', style: TextStyle(fontWeight: FontWeight.bold)),
          ...VideoQuality.values.map((q) => Text('  $q → H264:${QualityMapper.crfFor(q, VideoCodec.h264)}  H265:${QualityMapper.crfFor(q, VideoCodec.h265)}  AV1:${QualityMapper.crfFor(q, VideoCodec.av1)}')),
        ],
      ),
    );
  }
}
