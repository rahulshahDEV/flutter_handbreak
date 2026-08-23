import 'audio_stream_info.dart';
import 'video_stream_info.dart';

/// Robust source analysis — mirrors HandBrake's scan.c title probe.
/// Every field that can influence the encode decision is surfaced here.
class MediaInfo {
  const MediaInfo({
    required this.path,
    required this.container,
    required this.durationMs,
    required this.fileSizeBytes,
    required this.overallBitrate,
    required this.videoStreams,
    required this.audioStreams,
    required this.metadata,
    this.estimatedSourceBitrate,
    this.creationTime,
    this.hasBFrames,
  });

  final String path;
  final String container;
  final int durationMs;
  final int fileSizeBytes;
  final int overallBitrate; // bps
  final List<VideoStreamInfo> videoStreams;
  final List<AudioStreamInfo> audioStreams;
  final Map<String, String> metadata;
  final int? estimatedSourceBitrate;
  final DateTime? creationTime;
  final bool? hasBFrames;

  VideoStreamInfo? get primaryVideo =>
      videoStreams.isEmpty ? null : videoStreams.first;
  AudioStreamInfo? get primaryAudio =>
      audioStreams.isEmpty ? null : audioStreams.first;

  bool get hasVideo => videoStreams.isNotEmpty;
  bool get hasAudio => audioStreams.isNotEmpty;
  bool get isHdr => videoStreams.any((v) => v.isHdr);
  bool get isPortrait => primaryVideo?.isPortrait ?? false;

  double get durationSeconds => durationMs / 1000.0;

  factory MediaInfo.fromMap(Map<String, dynamic> m) => MediaInfo(
        path: m['path'] as String? ?? '',
        container: m['container'] as String? ?? 'unknown',
        durationMs: m['durationMs'] as int? ?? 0,
        fileSizeBytes: m['fileSizeBytes'] as int? ?? 0,
        overallBitrate: m['overallBitrate'] as int? ?? 0,
        videoStreams: ((m['videoStreams'] as List?) ?? [])
            .map(
              (e) =>
                  VideoStreamInfo.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .toList(),
        audioStreams: ((m['audioStreams'] as List?) ?? [])
            .map(
              (e) =>
                  AudioStreamInfo.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .toList(),
        metadata: Map<String, String>.from(m['metadata'] as Map? ?? {}),
        estimatedSourceBitrate: m['estimatedSourceBitrate'] as int?,
        creationTime: m['creationTime'] != null
            ? DateTime.tryParse(m['creationTime'] as String)
            : null,
        hasBFrames: m['hasBFrames'] as bool?,
      );

  Map<String, dynamic> toMap() => {
        'path': path,
        'container': container,
        'durationMs': durationMs,
        'fileSizeBytes': fileSizeBytes,
        'overallBitrate': overallBitrate,
        'videoStreams': videoStreams.map((v) => v.toMap()).toList(),
        'audioStreams': audioStreams.map((a) => a.toMap()).toList(),
        'metadata': metadata,
        'estimatedSourceBitrate': estimatedSourceBitrate,
        'creationTime': creationTime?.toIso8601String(),
        'hasBFrames': hasBFrames,
      };

  @override
  String toString() =>
      'MediaInfo($container ${durationMs}ms ${videoStreams.length}v/${audioStreams.length}a ${fileSizeBytes}B)';
}
