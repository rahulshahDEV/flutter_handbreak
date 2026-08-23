import 'dart:async';

import '../errors/handbreak_exception.dart';
import 'compression_progress.dart';
import 'compression_result.dart';

/// Live handle returned by `VideoCompressor.start` / `ImageCompressor.start`.
/// Mirrors HandBrake's job lifecycle (HB_STATE_WORKING → HB_STATE_DONE) with Dart streams.
class CompressionJob {
  CompressionJob({
    required this.id,
    required Stream<CompressionProgress> progress,
    required Future<CompressionResult> result,
    required Future<void> Function() cancelFn,
  })  : _progress = progress,
        _result = result,
        _cancelFn = cancelFn;

  final String id;

  final Stream<CompressionProgress> _progress;
  final Future<CompressionResult> _result;
  final Future<void> Function() _cancelFn;

  bool _isCancelled = false;
  bool get isCancelled => _isCancelled;

  /// Broadcast progress — based on real PTS/frame counts (never synthetic).
  Stream<CompressionProgress> get progress => _progress;

  /// Completes with [CompressionResult] on success, or throws typed [HandbreakException].
  Future<CompressionResult> get result => _result;

  /// Idempotent cancellation: stops native encoder, releases codecs, deletes partial file.
  Future<void> cancel() async {
    if (_isCancelled) return;
    _isCancelled = true;
    await _cancelFn();
  }
}

/// Internal convenience used by platform impls that back jobs with EventChannel + MethodChannel.
class JobHandle {
  JobHandle(this.id, this.progressController, this.resultCompleter);
  final String id;
  final StreamController<CompressionProgress> progressController;
  final Completer<CompressionResult> resultCompleter;

  void fail(Object e, [StackTrace? st]) {
    if (!progressController.isClosed) progressController.close();
    if (!resultCompleter.isCompleted) resultCompleter.completeError(e, st);
  }

  void complete(CompressionResult r) {
    if (!progressController.isClosed) progressController.close();
    if (!resultCompleter.isCompleted) resultCompleter.complete(r);
  }
}
