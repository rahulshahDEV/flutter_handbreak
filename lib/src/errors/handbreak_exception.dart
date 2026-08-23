/// Structured error hierarchy mirroring HandBrake's done_error categories.
/// Every native error is mapped to one of these; [nativeCode]/[nativeMessage]
/// are preserved for diagnostics without leaking internals.
abstract class HandbreakException implements Exception {
  const HandbreakException(
    this.message, {
    this.nativeCode,
    this.nativeMessage,
    this.isRecoverable = false,
  });

  final String message;
  final String? nativeCode;
  final String? nativeMessage;
  final bool isRecoverable;

  @override
  String toString() =>
      '$runtimeType: $message${nativeCode != null ? ' (native: $nativeCode)' : ''}'
      '${nativeMessage != null ? ' — $nativeMessage' : ''}';
}

class InvalidInputException extends HandbreakException {
  const InvalidInputException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
    super.isRecoverable = false,
  });
}

class UnsupportedFormatException extends HandbreakException {
  const UnsupportedFormatException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
    super.isRecoverable = false,
  });
}

class CodecUnavailableException extends HandbreakException {
  const CodecUnavailableException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
    super.isRecoverable = false,
  });
}

class HardwareEncoderUnavailableException extends HandbreakException {
  const HardwareEncoderUnavailableException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
    super.isRecoverable = true,
  });
}

class OutputCreationException extends HandbreakException {
  const OutputCreationException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
    super.isRecoverable = false,
  });
}

class EncodingException extends HandbreakException {
  const EncodingException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
    super.isRecoverable = false,
  });
}

class CancelledCompressionException extends HandbreakException {
  const CancelledCompressionException([
    super.message = 'Compression cancelled',
  ]);
}

class InsufficientStorageException extends HandbreakException {
  const InsufficientStorageException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
  });
}

class OutOfMemoryException extends HandbreakException {
  const OutOfMemoryException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
  });
}

/// Native watchdog/stall timeout — a codec stopped producing/consuming data
/// and the job was terminated instead of being allowed to hang (P3-1).
class CompressionTimeoutException extends HandbreakException {
  const CompressionTimeoutException(
    super.message, {
    super.nativeCode,
    super.nativeMessage,
  });
}

/// Map a native error code string to a typed exception.
HandbreakException mapNativeError(Map<String, dynamic> map) {
  final code = map['code'] as String? ?? 'UNKNOWN';
  final msg = map['message'] as String? ?? 'Unknown native error';
  final nativeMsg = map['nativeMessage'] as String?;
  switch (code) {
    case 'INVALID_INPUT':
      return InvalidInputException(
        msg,
        nativeCode: code,
        nativeMessage: nativeMsg,
      );
    case 'UNSUPPORTED_FORMAT':
      return UnsupportedFormatException(
        msg,
        nativeCode: code,
        nativeMessage: nativeMsg,
      );
    case 'CODEC_UNAVAILABLE':
      return CodecUnavailableException(
        msg,
        nativeCode: code,
        nativeMessage: nativeMsg,
      );
    case 'HARDWARE_UNAVAILABLE':
      return HardwareEncoderUnavailableException(
        msg,
        nativeCode: code,
        nativeMessage: nativeMsg,
      );
    case 'OUTPUT_CREATION_FAILED':
      return OutputCreationException(
        msg,
        nativeCode: code,
        nativeMessage: nativeMsg,
      );
    case 'CANCELLED':
      return const CancelledCompressionException();
    case 'INSUFFICIENT_STORAGE':
      return InsufficientStorageException(
        msg,
        nativeCode: code,
        nativeMessage: nativeMsg,
      );
    case 'OUT_OF_MEMORY':
      return OutOfMemoryException(
        msg,
        nativeCode: code,
        nativeMessage: nativeMsg,
      );
    case 'TIMEOUT':
      return CompressionTimeoutException(
        msg,
        nativeCode: code,
        nativeMessage: nativeMsg,
      );
    default:
      return EncodingException(msg, nativeCode: code, nativeMessage: nativeMsg);
  }
}
