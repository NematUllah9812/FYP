#!/usr/bin/env bash
# =============================================================================
# TerraSteps — Android Manifest & Gradle Patcher for CI / Clean Checkouts
# Run from apps/mobile/ after `flutter create --platforms=android .`
#
# 1. Injects GPS, ACTIVITY_RECOGNITION, Foreground Service, WakeLock, and
#    Supabase Auth callback intent-filter into AndroidManifest.xml.
# 2. Upgrades Gradle wrapper (8.11.1), AGP (8.9.1), Kotlin (2.1.0),
#    compileSdk (35), minSdk (24), targetSdk (35), and ndkVersion (27.0.12077973)
#    required by Mapbox Maps SDK v11 (`mapbox_maps_flutter` 2.18.x) + SQLite FFI.
# =============================================================================
set -euo pipefail

MANIFEST="android/app/src/main/AndroidManifest.xml"

if [ ! -f "$MANIFEST" ]; then
  echo "Error: $MANIFEST not found. Run 'flutter create --platforms=android .' inside apps/mobile first." >&2
  exit 1
fi

python3 - << 'PY'
import pathlib, re, sys

manifest_path = pathlib.Path("android/app/src/main/AndroidManifest.xml")
xml = manifest_path.read_text(encoding="utf-8")

needed_perms = [
    ("INTERNET", '    <uses-permission android:name="android.permission.INTERNET"/>'),
    ("ACCESS_COARSE_LOCATION", '    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>'),
    ("ACCESS_FINE_LOCATION", '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>'),
    ("ACCESS_BACKGROUND_LOCATION", '    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>'),
    ("ACTIVITY_RECOGNITION", '    <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>'),
    ('FOREGROUND_SERVICE"', '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>'),
    ("FOREGROUND_SERVICE_LOCATION", '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>'),
    ("WAKE_LOCK", '    <uses-permission android:name="android.permission.WAKE_LOCK"/>'),
    ("POST_NOTIFICATIONS", '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>'),
]

insert_lines = []
for key, tag in needed_perms:
    if key not in xml:
        insert_lines.append(tag)

if "android.hardware.sensor.stepcounter" not in xml:
    insert_lines.append('    <uses-feature android:name="android.hardware.sensor.stepcounter" android:required="false"/>')
    insert_lines.append('    <uses-feature android:name="android.hardware.location.gps" android:required="false"/>')

if insert_lines:
    header = '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
    if header in xml:
        xml = xml.replace(header, header + "\n" + "\n".join(insert_lines), 1)
    else:
        xml = xml.replace("<application", "\n".join(insert_lines) + "\n\n    <application", 1)

if "io.terrasteps.app" not in xml and "</activity>" in xml:
    callback = """            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="io.terrasteps.app" android:host="login-callback"/>
            </intent-filter>
        </activity>"""
    xml = xml.replace("        </activity>", callback, 1)

manifest_path.write_text(xml, encoding="utf-8")
print("Patched AndroidManifest.xml permissions & auth callback.")

# 2. Patch Gradle Wrapper -> 8.11.1
wrapper = pathlib.Path("android/gradle/wrapper/gradle-wrapper.properties")
if wrapper.exists():
    wtxt = wrapper.read_text(encoding="utf-8")
    wtxt = re.sub(
        r"distributionUrl=.*",
        r"distributionUrl=https\\://services.gradle.org/distributions/gradle-8.11.1-bin.zip",
        wtxt,
    )
    wrapper.write_text(wtxt, encoding="utf-8")
    print("Patched gradle-wrapper.properties -> Gradle 8.11.1")

# 3. Patch settings.gradle / settings.gradle.kts -> AGP 8.9.1 & Kotlin 2.1.0
for sname in ("android/settings.gradle", "android/settings.gradle.kts"):
    spath = pathlib.Path(sname)
    if spath.exists():
        stxt = spath.read_text(encoding="utf-8")
        stxt = re.sub(
            r'(id\s*\(?\s*["\']com\.android\.application["\']\s*\)?\s*version\s*["\'])[^"\']+(["\'])',
            r"\g<1>8.9.1\2",
            stxt,
        )
        stxt = re.sub(
            r'(id\s*\(?\s*["\']org\.jetbrains\.kotlin\.android["\']\s*\)?\s*version\s*["\'])[^"\']+(["\'])',
            r"\g<1>2.1.0\2",
            stxt,
        )
        spath.write_text(stxt, encoding="utf-8")
        print(f"Patched {sname} -> AGP 8.9.1, Kotlin 2.1.0")

# 4. Patch android/app/build.gradle or build.gradle.kts -> compileSdk 35, minSdk 24, targetSdk 35, ndkVersion 27.0.12077973
for bname in ("android/app/build.gradle", "android/app/build.gradle.kts"):
    bpath = pathlib.Path(bname)
    if bpath.exists():
        btxt = bpath.read_text(encoding="utf-8")
        btxt = re.sub(r"compileSdk\s*=?\s*flutter\.compileSdkVersion", "compileSdk = 35", btxt)
        btxt = re.sub(r"compileSdkVersion\s+flutter\.compileSdkVersion", "compileSdkVersion 35", btxt)
        btxt = re.sub(r"ndkVersion\s*=?\s*flutter\.ndkVersion", 'ndkVersion = "27.0.12077973"', btxt)
        btxt = re.sub(r"minSdk\s*=?\s*flutter\.minSdkVersion", "minSdk = 24", btxt)
        btxt = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 24", btxt)
        btxt = re.sub(r"targetSdk\s*=?\s*flutter\.targetSdkVersion", "targetSdk = 35", btxt)
        btxt = re.sub(r"targetSdkVersion\s+flutter\.targetSdkVersion", "targetSdkVersion 35", btxt)
        btxt = re.sub(r"jvmTarget\s*=\s*JavaVersion\.VERSION_1_8(?:\.toString\(\))?", 'jvmTarget = "1.8"', btxt)
        bpath.write_text(btxt, encoding="utf-8")
        print(f"Patched {bname} -> compileSdk 35, minSdk 24, targetSdk 35, NDK 27.0.12077973")
PY
