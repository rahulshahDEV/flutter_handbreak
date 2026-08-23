import 'dart:io';
import '../errors/handbreak_exception.dart';

class Validation {
  const Validation._();

  static void requireFileExists(String path) {
    if (path.isEmpty) throw const InvalidInputException('Input path is empty');
    final f = File(path);
    if (!f.existsSync()) {
      throw InvalidInputException('Input file not found: $path');
    }
  }

  static void requireOutputWritable(
    String outputPath, {
    bool overwriteExisting = false,
  }) {
    if (outputPath.isEmpty) {
      throw const InvalidInputException('Output path is empty');
    }
    final f = File(outputPath);
    if (f.existsSync() && !overwriteExisting) {
      throw OutputCreationException(
        'Output already exists (set overwriteExisting=true to replace): $outputPath',
      );
    }
    final dir = Directory(File(outputPath).parent.path);
    if (!dir.existsSync()) {
      throw OutputCreationException(
        'Output directory does not exist: ${dir.path}',
      );
    }
  }

  static void requireNotSameFile(String input, String output) {
    if (File(input).absolute.path == File(output).absolute.path) {
      throw const InvalidInputException(
        'Input and output must be different files',
      );
    }
  }

  static bool fileExistsQuietly(String path) {
    try {
      final f = File(path);
      return f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  static String normalizeOutputPath(
    String inputPath,
    String desiredOutput,
    String defaultExtension,
  ) {
    if (desiredOutput.contains('.')) return desiredOutput;
    return '$desiredOutput$defaultExtension';
  }
}
