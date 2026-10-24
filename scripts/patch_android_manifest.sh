#!/usr/bin/env bash
# =============================================================================
# TerraSteps — Android Manifest & Gradle Patcher for CI / Clean Checkouts
# Injects GPS, Hardware Step Counter (ACTIVITY_RECOGNITION), Foreground Service
# permissions, and ensures minSdk >= 23 for Mapbox Maps SDK + SQLite FFI.
# =============================================================================
set -euo pipefail

MANIFEST="android/app/src/main/AndroidManifest.xml"

if [ ! -f "$MANIFEST" ]; then
  echo "Error: $MANIFEST not found. Run 'flutter create --platforms=android .' first." >&2
  exit 1
fi

python3 - "$MANIFEST" << 'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    xml = f.read()

permissions = [
    '<uses-permission android:name="android.permission.INTERNET"/>',
    '<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>',
    '<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>',
    '<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>',
    '<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>',
    '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>',
]

missing = [p for p in permissions if p not in xml]
if missing:
    inject = "\n    ".join(missing)
    xml = xml.replace("<application", f"    {inject}\n\n    <application", 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
print(f"Patched {path} ({len(missing)} permission tags ensured).")
PY

for GRADLE_FILE in android/app/build.gradle android/app/build.gradle.kts; do
  if [ -f "$GRADLE_FILE" ]; then
    sed -i 's/minSdk = flutter.minSdkVersion/minSdk = 23/g' "$GRADLE_FILE" || true
    sed -i 's/minSdkVersion flutter.minSdkVersion/minSdkVersion 23/g' "$GRADLE_FILE" || true
  fi
done
