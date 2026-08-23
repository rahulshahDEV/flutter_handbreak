/// handbreak — production-grade Flutter media compression
/// inspired by HandBrake's pipeline architecture.
///
/// See `ARCHITECTURE.md` for the HandBrake analysis that drives this design.
library handbreak;

export 'src/errors/handbreak_exception.dart';

export 'src/hardware/hardware_capabilities.dart';
export 'src/hardware/hardware_acceleration.dart';

export 'src/models/media_info.dart';
export 'src/models/video_stream_info.dart';
export 'src/models/audio_stream_info.dart';
export 'src/models/compression_progress.dart';
export 'src/models/compression_result.dart';
export 'src/models/compression_job.dart';

export 'src/video/video_codec.dart';
export 'src/video/rate_control.dart';
export 'src/video/frame_rate_mode.dart';
export 'src/video/video_compression_options.dart';
export 'src/video/video_compressor.dart';
export 'src/video/filters.dart';
export 'src/video/encode_plan_resolver.dart';

export 'src/image/image_format.dart';
export 'src/image/image_compression_options.dart';
export 'src/image/image_compressor.dart';

export 'src/presets/video_preset.dart';

export 'src/probe/handbreak_probe.dart';

export 'src/utils/resolution_calculator.dart';
export 'src/utils/quality_mapper.dart';
export 'src/utils/validation.dart';
