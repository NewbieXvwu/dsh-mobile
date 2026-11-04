#!/bin/bash
# Builds the Kotlin/Native framework that the Xcode target links against, and —
# on Mac Catalyst — rewrites its load commands so UIKit/Catalyst accepts it.
#
# Called from the "Build KMP Framework" run-script phase. Xcode re-runs that
# phase on every build ("Based on dependency analysis" is off), so the phase
# itself is cheap: it hashes the Kotlin inputs and only invokes Gradle when they
# changed. The Catalyst patch below rewrites the framework in place, which makes
# Gradle's own up-to-date check permanently miss; the stamp file replaces it.
set -eu

cd "${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -z "${ANDROID_HOME:-}" ]; then
  export ANDROID_HOME="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
fi

case "${CONFIGURATION:-Debug}" in
  *[Rr]elease*) KMP_BUILD_TYPE=Release ;;
  *) KMP_BUILD_TYPE=Debug ;;
esac

if [ "${EFFECTIVE_PLATFORM_NAME:-}" = "-maccatalyst" ] || [ "${PLATFORM_NAME:-}" = "macosx" ]; then
  KMP_TARGET=MacosArm64
  KMP_FRAMEWORK_DIR="$PWD/shared/build/bin/macosArm64/$(echo "$KMP_BUILD_TYPE" | tr '[:upper:]' '[:lower:]')Framework"
elif [ "${PLATFORM_NAME:-}" = "iphonesimulator" ]; then
  case "${ARCHS:-}" in
    *x86_64*) KMP_TARGET=IosX64 ;;
    *) KMP_TARGET=IosSimulatorArm64 ;;
  esac
  KMP_FRAMEWORK_DIR=""
else
  KMP_TARGET=IosArm64
  KMP_FRAMEWORK_DIR=""
fi

STAMP_DIR="$PWD/shared/build"
STAMP="$STAMP_DIR/.kmp-input-stamp-$(echo "$KMP_TARGET" | tr '[:upper:]' '[:lower:]')-$(echo "$KMP_BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
FRAMEWORK_BIN="${KMP_FRAMEWORK_DIR:+$KMP_FRAMEWORK_DIR/DeepSeekHarnessShared.framework/Versions/A/DeepSeekHarnessShared}"

# Hash everything that can change the linked framework. `shared/build` is the
# output directory, so it is pruned; `shared/` still covers sources, the module
# build script and proguard rules.
input_hash() {
  {
    find "$PWD/shared" -path "$PWD/shared/build" -prune -o -type f -print
    find "$PWD/gradle" -type f -print 2>/dev/null || true
    for f in build.gradle.kts settings.gradle.kts gradle.properties \
             scripts/patch_kmp_framework_maccatalyst.sh; do
      [ -f "$PWD/$f" ] && printf '%s\n' "$PWD/$f"
    done
  } | LC_ALL=C sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}

current_hash=$(input_hash)

if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$current_hash" ] \
   && { [ -z "$FRAMEWORK_BIN" ] || [ -f "$FRAMEWORK_BIN" ]; }; then
  echo "[kmp] Kotlin inputs unchanged ($current_hash); skipping Gradle link"
else
  echo "[kmp] inputs changed or framework missing; running Gradle link${KMP_TARGET}${KMP_BUILD_TYPE}"
  "$PWD/gradlew" ":shared:link${KMP_BUILD_TYPE}Framework${KMP_TARGET}" --quiet
  mkdir -p "$STAMP_DIR"
  printf '%s\n' "$current_hash" > "$STAMP"
fi

# Only Mac Catalyst needs the load-command rewrite; the script is idempotent and
# fast when the framework is already patched.
if [ -n "$FRAMEWORK_BIN" ]; then
  "$PWD/scripts/patch_kmp_framework_maccatalyst.sh" "$FRAMEWORK_BIN" "${IPHONEOS_DEPLOYMENT_TARGET:-16.1}"
fi
