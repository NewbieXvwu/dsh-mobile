#!/bin/bash
# Prints a hash of every input that can change the linked KMP framework.
# Shared by scripts/build_kmp_framework.sh (to decide whether to call Gradle)
# and the CI workflow (to decide whether Kotlin/Native caches are needed).
set -eu
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
{
  find "$root/shared" -path "$root/shared/build" -prune -o -type f -print
  find "$root/gradle" -type f -print 2>/dev/null || true
  for f in build.gradle.kts settings.gradle.kts gradle.properties \
           scripts/patch_kmp_framework_maccatalyst.sh; do
    [ -f "$root/$f" ] && printf '%s\n' "$root/$f"
  done
} | LC_ALL=C sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1
