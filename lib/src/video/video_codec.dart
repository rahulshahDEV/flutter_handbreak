/// Pluggable video codecs. Default is H.264 for broad mobile compatibility.
enum VideoCodec {
  h264('h264', 'video/avc', 'avc1'),
  h265('h265', 'video/hevc', 'hvc1'),
  av1('av1', 'video/av01', 'av01'),
  vp9('vp9', 'video/x-vnd.on2.vp9', 'vp09');

  const VideoCodec(this.id, this.mimeType, this.fourCC);
  final String id;
  final String mimeType;
  final String fourCC;

  static VideoCodec fromId(String id) =>
      values.firstWhere((c) => c.id == id, orElse: () => VideoCodec.h264);
}

/// Container. MP4 is default; MKV used where Opus/AV1 passthrough prefers it.
enum VideoContainer {
  mp4('mp4', '.mp4'),
  mov('mov', '.mov'),
  mkv('mkv', '.mkv');

  const VideoContainer(this.id, this.extension);
  final String id;
  final String extension;

  static VideoContainer fromId(String id) =>
      values.firstWhere((c) => c.id == id, orElse: () => VideoContainer.mp4);
}

/// Audio codec/mode. We never destroy audio silently.
enum AudioCodec {
  aac('aac'),
  opus('opus'),
  copy('copy'); // passthrough when safe

  const AudioCodec(this.id);
  final String id;
}

enum AudioMode {
  /// Re-encode (default).
  encode,
  /// Passthrough when source already matches target and container allows it.
  copy,
  /// Strip audio.
  remove,
}
