class AudioStreamInfo {
  const AudioStreamInfo({
    required this.index,
    required this.codec,
    required this.codecString,
    required this.sampleRate,
    required this.channelCount,
    required this.bitRate,
    this.language,
    this.title,
    this.channelLayout,
  });

  final int index;
  final String codec;
  final String codecString;
  final int sampleRate;
  final int channelCount;
  final int bitRate;
  final String? language;
  final String? title;
  final String? channelLayout;

  factory AudioStreamInfo.fromMap(Map<String, dynamic> m) => AudioStreamInfo(
        index: m['index'] as int? ?? 0,
        codec: m['codec'] as String? ?? 'unknown',
        codecString: m['codecString'] as String? ?? m['codec'] as String? ?? 'unknown',
        sampleRate: m['sampleRate'] as int? ?? 0,
        channelCount: m['channelCount'] as int? ?? 0,
        bitRate: m['bitRate'] as int? ?? 0,
        language: m['language'] as String?,
        title: m['title'] as String?,
        channelLayout: m['channelLayout'] as String?,
      );

  Map<String, dynamic> toMap() => {
        'index': index, 'codec': codec, 'codecString': codecString,
        'sampleRate': sampleRate, 'channelCount': channelCount, 'bitRate': bitRate,
        'language': language, 'title': title, 'channelLayout': channelLayout,
      };
}
