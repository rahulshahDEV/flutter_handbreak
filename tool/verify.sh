#!/usr/bin/env bash
# Reproducible local verification (CI substitute — GitHub Actions unavailable).
# Usage: tool/verify.sh   (requires Flutter SDK; Android SDK optional for Gradle lane)
set -euo pipefail
cd "$(dirname "$0")/.."

GRADLE_BIN="$(find "$HOME/.gradle/wrapper/dists" -path '*gradle-8.14*/bin/gradle' -type f 2>/dev/null | head -1 || true)"

echo "== 1/6 format =="
dart format --output=none --set-exit-if-changed lib test example/lib benchmark

echo "== 2/6 analyze =="
flutter analyze --fatal-infos

echo "== 3/6 Dart unit tests =="
flutter test

echo "== 4/6 package validation =="
dart pub publish --dry-run

echo "== 5/7 iOS Swift typecheck =="
if command -v xcrun >/dev/null; then
  IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
  if [ -n "$IOS_SDK" ]; then
    (cd ios/Classes && xcrun swiftc -typecheck -sdk "$IOS_SDK" -target arm64-apple-ios13.0-simulator \
      Support.swift HardwareProbe.swift JobManager.swift MediaProbe.swift \
      ImagePipeline.swift VideoPipeline.swift VideoPipelineSupport.swift)
  else
    echo "  (iphonesimulator SDK unavailable — skipped)"
  fi
else
  echo "  (xcode CLT unavailable — skipped)"
fi

if [ -n "$GRADLE_BIN" ] && [ -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platforms" ]; then
  echo "== 6/7 Android JVM tests =="
  (cd android && FLUTTER_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")" \
    "$GRADLE_BIN" testDebugUnitTest --no-daemon)
  echo "== 7/7 Android AAR =="
  (cd android && "$GRADLE_BIN" assembleRelease --no-daemon)
else
  echo "== 6-7/7 SKIPPED: Android SDK/gradle not found =="
fi

echo "ALL VERIFICATION PASSED"
