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

if [ -n "$GRADLE_BIN" ] && [ -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platforms" ]; then
  echo "== 5/6 Android JVM tests =="
  (cd android && FLUTTER_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")" \
    "$GRADLE_BIN" testDebugUnitTest --no-daemon)
  echo "== 6/6 Android AAR =="
  (cd android && "$GRADLE_BIN" assembleRelease --no-daemon)
else
  echo "== 5-6/6 SKIPPED: Android SDK/gradle not found =="
fi

echo "ALL VERIFICATION PASSED"
