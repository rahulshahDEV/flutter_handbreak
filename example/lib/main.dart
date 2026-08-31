import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_handbreak/handbreak.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
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
  bool keepOriginalResolution = true;
  bool isProbeLoading = false;

  Future<void> pickFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.single.path == null) return;
    final path = res.files.single.path!;
    await _onPicked(path);
  }

  Future<void> pickFromCameraRoll() async {
    final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (file == null) return;
    await _onPicked(file.path);
  }

  Future<void> pickImageFromGallery() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return;
    await _onPicked(file.path);
  }

  Future<void> _onPicked(String path) async {
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
        status =
            'Ready — ${info.videoStreams.length} video / ${info.audioStreams.length} audio, ${info.durationMs}ms, ${info.fileSizeBytes} bytes';
      });
    } catch (e) {
      setState(() => status = 'Probe failed: $e');
    } finally {
      setState(() => isProbeLoading = false);
    }
  }

  Future<String> _outputPath(String input, String ext, String tag) async {
    // Documents dir — persists across runs and is user-visible in the Files
    // app (iOS exposes it via UIFileSharingEnabled; Android via file managers).
    final dir = await getApplicationDocumentsDirectory();
    final base = input.split('/').last.split('.').first;
    // Unique per run — repeated compressions (e.g. different presets) must
    // never collide with a previous output file.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}/${base}_${tag}_handbreak_out_$stamp$ext';
  }

  Future<void> compressVideo() async {
    if (inputPath == null) return;
    final opts = selectedPreset.toOptions();
    // Keep original resolution (size-preserving compression) or apply caps.
    final resolved = keepOriginalResolution
        ? _atSourceResolution(opts)
        : opts.copyWith(maxWidth: 1920, maxHeight: 1080);
    final out = await _outputPath(inputPath!, '.mp4', selectedPreset.name);
    setState(() {
      status = 'Compressing with ${selectedPreset.displayName} ...';
      progress = null;
      lastResult = null;
    });
    try {
      final job = await VideoCompressor.start(
        inputPath!,
        options: resolved,
        outputPath: out,
      );
      setState(() => activeJob = job);
      job.progress.listen(
        (p) {
          setState(() => progress = p);
        },
        onError: (e) => setState(() => status = 'Progress error: $e'),
      );
      final result = await job.result;
      setState(() {
        lastResult = result;
        status = _videoDoneStatus(result, out);
        activeJob = null;
      });
    } on CancelledCompressionException {
      setState(() {
        status = 'Cancelled';
        activeJob = null;
      });
    } catch (e) {
      setState(() {
        status = 'Failed: $e';
        activeJob = null;
      });
    }
  }

  /// Same-resolution compression must still SAVE space (HandBrake target-size
  /// idea): target ~70% of the source bitrate when the source rate is known,
  /// and never replace the original with a larger file.
  VideoCompressionOptions _atSourceResolution(VideoCompressionOptions opts) {
    final srcBr = mediaInfo?.overallBitrate ?? 0;
    return opts.copyWith(
      preserveResolution: true,
      keepOriginalIfSmaller: true,
      rateControl: srcBr > 0
          ? RateControl.averageBitrate(
              ((srcBr * 0.7) / 1000).round().clamp(64, 40000),
            )
          : opts.rateControl,
    );
  }

  String _videoDoneStatus(CompressionResult result, String out) {
    if (result.wasKeptOriginal) {
      return 'Kept original — compressed output would be larger (source already efficient)';
    }
    if (result.savedBytes == 0) {
      return 'No savings — output not smaller at this quality (source already compressed)';
    }
    return 'Done: ${result.compressionPercentage.toStringAsFixed(1)}% saved → $out, hw=${result.usedHardwareAcceleration}';
  }

  Future<void> compressImage() async {
    if (inputPath == null) return;
    final out = await _outputPath(inputPath!, '.jpg', 'image');
    setState(() => status = 'Compressing image ...');
    try {
      final job = await ImageCompressor.start(
        inputPath!,
        options: keepOriginalResolution
            ? const ImageCompressionOptions(quality: 82)
            : const ImageCompressionOptions(
                quality: 82,
                maxWidth: 2048,
                maxHeight: 2048,
              ),
        outputPath: out,
      );
      setState(() => activeJob = job);
      job.progress.listen((p) => setState(() => progress = p));
      final result = await job.result;
      setState(() {
        // ImageCompressor returns CompressionResult as well
        lastResult = result;
        status = result.wasKeptOriginal
            ? 'Kept original — recompressed output would be larger (source may be HEIC or already compressed)'
            : 'Image done: ${result.compressionPercentage.toStringAsFixed(1)}% saved → $out';
        activeJob = null;
      });
    } catch (e) {
      setState(() {
        status = 'Image failed: $e';
        activeJob = null;
      });
    }
  }

  Future<void> cancel() async {
    await activeJob?.cancel();
    setState(() => status = 'Cancelling ...');
  }

  /// Open the compressed file with the platform's default viewer
  /// (Android intent / iOS QuickLook).
  Future<void> openOutput(String path) async {
    final res = await OpenFilex.open(path);
    setState(() {
      status = switch (res.type) {
        ResultType.done => 'Opened output with default viewer',
        ResultType.noAppToOpen => 'No app found to open: $path',
        ResultType.fileNotFound => 'Output file not found: $path',
        _ => 'Could not open output: ${res.message}',
      };
    });
  }

  Future<void> copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    setState(() => status = 'Output path copied to clipboard');
  }

  /// Quality summary of the compressed output (re-probed by native side).
  String? _outputQualitySummary() {
    final raw = lastResult?.outputMediaInfo;
    if (raw == null) return null;
    try {
      final m = MediaInfo.fromMap(raw);
      final v = m.primaryVideo;
      final sizeMB = (m.fileSizeBytes / (1024 * 1024)).toStringAsFixed(2);
      if (v == null) {
        return 'Output: ${m.container}  $sizeMB MB';
      }
      final br = v.bitRate > 0
          ? '${(v.bitRate / 1000).toStringAsFixed(0)}kbps'
          : 'n/a';
      return 'Output: ${v.width}x${v.height} ${v.codec} ${v.frameRate.toStringAsFixed(1)}fps  $br  $sizeMB MB';
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Handbreak — HandBrake-inspired Demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            onPressed: pickFile,
            icon: const Icon(Icons.file_open),
            label: const Text('Pick Video / Image (Files)'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: pickFromCameraRoll,
            icon: const Icon(Icons.photo_library),
            label: const Text('Pick Video from Camera Roll'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: pickImageFromGallery,
            icon: const Icon(Icons.image),
            label: const Text('Pick Image from Camera Roll'),
          ),
          const SizedBox(height: 12),
          if (inputPath != null)
            Text('Input: $inputPath', style: const TextStyle(fontSize: 12)),
          if (isProbeLoading) const LinearProgressIndicator(),
          if (mediaInfo != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Container: ${mediaInfo!.container}  Duration: ${mediaInfo!.durationMs}ms  Size: ${mediaInfo!.fileSizeBytes}',
                    ),
                    if (mediaInfo!.primaryVideo != null)
                      Text(
                        'Video: ${mediaInfo!.primaryVideo!.width}x${mediaInfo!.primaryVideo!.height} ${mediaInfo!.primaryVideo!.codec} ${mediaInfo!.primaryVideo!.frameRate.toStringAsFixed(1)}fps rot=${mediaInfo!.primaryVideo!.rotation} hdr=${mediaInfo!.primaryVideo!.isHdr}',
                      ),
                    if (mediaInfo!.primaryAudio != null)
                      Text(
                        'Audio: ${mediaInfo!.primaryAudio!.codec} ${mediaInfo!.primaryAudio!.sampleRate}Hz ${mediaInfo!.primaryAudio!.channelCount}ch',
                      ),
                    Text(
                      'Streams: ${mediaInfo!.videoStreams.length}v / ${mediaInfo!.audioStreams.length}a  Bitrate: ${mediaInfo!.overallBitrate}',
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text('Preset', style: Theme.of(context).textTheme.titleSmall),
          DropdownButton<VideoPresetId>(
            value: selectedPreset,
            isExpanded: true,
            items: VideoPresetId.values
                .map(
                  (p) => DropdownMenuItem(value: p, child: Text(p.displayName)),
                )
                .toList(),
            onChanged: (v) => setState(() => selectedPreset = v!),
          ),
          Text(
            selectedPreset.description,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          CheckboxListTile(
            value: keepOriginalResolution,
            onChanged: (v) => setState(() => keepOriginalResolution = v ?? true),
            title: const Text('Keep original resolution'),
            subtitle: const Text(
              'Same width & height — video targets ~70% of source bitrate; '
              'never outputs a larger file',
              style: TextStyle(fontSize: 11),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: inputPath == null || activeJob != null
                    ? null
                    : compressVideo,
                child: const Text('Compress Video'),
              ),
              OutlinedButton(
                onPressed: inputPath == null || activeJob != null
                    ? null
                    : compressImage,
                child: const Text('Compress Image'),
              ),
              if (activeJob != null)
                FilledButton.tonalIcon(
                  onPressed: cancel,
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(status),
          if (progress != null)
            Column(
              children: [
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress!.progress),
                Text(
                  '${(progress!.progress * 100).toStringAsFixed(1)}%  ${progress!.encodedFrames}/${progress!.totalFrames}  ${progress!.currentFps.toStringAsFixed(1)} fps  stage:${progress!.stage}',
                ),
                if (progress!.estimatedRemaining != null)
                  Text('ETA: ${progress!.estimatedRemaining}'),
              ],
            ),
          if (lastResult != null)
            Card(
              color: Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Output: ${lastResult!.outputPath}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (_outputQualitySummary() != null)
                      Text(
                        _outputQualitySummary()!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () => openOutput(lastResult!.outputPath),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open Output'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => copyPath(lastResult!.outputPath),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy Path'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Size: ${lastResult!.originalSizeBytes} → ${lastResult!.outputSizeBytes}  Saved: ${lastResult!.savedBytes} (${lastResult!.compressionPercentage.toStringAsFixed(1)}%)',
                    ),
                    Text(
                      'Ratio: ${lastResult!.compressionRatio.toStringAsFixed(2)}x  Codec: ${lastResult!.codec}/${lastResult!.container}  HW: ${lastResult!.usedHardwareAcceleration}  Time: ${lastResult!.durationMs}ms',
                    ),
                    if (lastResult!.qualityWarning != null)
                      Text(
                        'Warning: ${lastResult!.qualityWarning}',
                        style: const TextStyle(color: Colors.orange),
                      ),
                    if (lastResult!.wasKeptOriginal)
                      const Text(
                        'Kept original — output would have been larger',
                        style: TextStyle(color: Colors.blue),
                      ),
                  ],
                ),
              ),
            ),
          const Divider(height: 32),
          const Text(
            'Quality mapping (codec-aware):',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          ...VideoQuality.values.map(
            (q) => Text(
              '  $q → H264:${QualityMapper.crfFor(q, VideoCodec.h264)}  H265:${QualityMapper.crfFor(q, VideoCodec.h265)}  AV1:${QualityMapper.crfFor(q, VideoCodec.av1)}',
            ),
          ),
        ],
      ),
    );
  }
}
