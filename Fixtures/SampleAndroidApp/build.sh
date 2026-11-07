#!/bin/sh
# Builds the sample Android app into $1/app.apk with the SDK's own tools, no
# Gradle: aapt2 links the manifest, javac and d8 compile the activity, and
# apksigner signs it with a debug key made on first use.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "$1" && cd "$1" && pwd)
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
tools=$sdk/build-tools/$(ls "$sdk/build-tools" | sort -V | tail -1)
platform=$sdk/platforms/$(ls "$sdk/platforms" | sort -V | tail -1)
rm -rf "$out/classes" "$out/dex" "$out/unsigned.apk" "$out/aligned.apk"
mkdir -p "$out/classes" "$out/dex"
"$tools/aapt2" link -o "$out/unsigned.apk" -I "$platform/android.jar" --manifest "$here/AndroidManifest.xml" \
    --min-sdk-version 26 --target-sdk-version 34
javac --release 11 -classpath "$platform/android.jar" -d "$out/classes" "$here/src/com/productpagekit/sample/MainActivity.java"
"$tools/d8" --lib "$platform/android.jar" --min-api 26 --output "$out/dex" $(find "$out/classes" -name '*.class')
# A fixed date and no extra attributes, so the same sources make the same APK.
touch -t 198001010000 "$out/dex/classes.dex"
(cd "$out/dex" && zip -q -X -j "$out/unsigned.apk" classes.dex)
"$tools/zipalign" -f 4 "$out/unsigned.apk" "$out/aligned.apk"
if [ ! -f "$out/debug.keystore" ]; then
    keytool -genkeypair -keystore "$out/debug.keystore" -storepass android -keypass android -alias debug -keyalg RSA \
        -dname CN=debug -validity 10000 >/dev/null 2>&1
fi
"$tools/apksigner" sign --ks "$out/debug.keystore" --ks-pass pass:android --out "$out/app.apk" "$out/aligned.apk"
