#!/bin/bash
# Kullanım: ./install.sh <TV-IP>   — TV'ye APK'yı, bu Mac'e EkranYansit.app'i kurar.
set -euo pipefail
cd "$(dirname "$0")"
TV="${1:?Kullanım: ./install.sh <TV-IP>  (ör. 192.168.1.50)}"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
JAR="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -1)/android.jar"
OUT=build
rm -rf "$OUT"; mkdir -p "$OUT/classes"

echo "▸ Simgeler"
swift icons/make-icons.swift
iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"

echo "▸ APK derleniyor"
"$BT/aapt2" compile --dir tv/res -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$JAR" --manifest tv/AndroidManifest.xml \
    --min-sdk-version 24 --target-sdk-version 34 "$OUT/res.zip"
javac -Xlint:-options -nowarn --release 11 -classpath "$JAR" -d "$OUT/classes" $(find tv/src -name '*.java')
java -cp "$OUT/classes" tv/test/com/alper/ekranyansit/PacerCheck.java
"$BT/d8" --release --lib "$JAR" --min-api 24 --output "$OUT" $(find "$OUT/classes" -name '*.class')
(cd "$OUT" && zip -q base.apk classes.dex)
KS="$HOME/.android/debug.keystore"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias androiddebugkey \
    -dname "CN=Android Debug" -keyalg RSA -validity 10000 >/dev/null
"$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --out "$OUT/EkranYansit.apk" "$OUT/aligned.apk" 2>/dev/null

echo "▸ TV'ye kuruluyor ($TV)"
"$ADB" connect "$TV:5555" >/dev/null
"$ADB" -s "$TV:5555" install -r "$OUT/EkranYansit.apk"

echo "▸ Mac uygulaması derleniyor"
(cd mac && swift build -c release -q && .build/release/EkranYansit --selftest)
APP="$OUT/EkranYansit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp mac/.build/release/EkranYansit "$APP/Contents/MacOS/"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.alper.ekranyansit</string>
  <key>CFBundleName</key><string>Ekran Yansıt</string>
  <key>CFBundleDisplayName</key><string>Ekran Yansıt</string>
  <key>CFBundleExecutable</key><string>EkranYansit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
# Ad-hoc imza her derlemede değişir ve macOS Ekran Kaydı iznini unutur; sabit, yerel bir sertifikayla imzala
ID="EkranYansit Local Signing"
if ! security find-certificate -c "$ID" >/dev/null 2>&1; then
    echo "▸ Yerel imza sertifikası oluşturuluyor (bir kerelik)"
    T="$(mktemp -d)"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$ID" \
        -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout pass:ekranyansit
    security import "$T/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P ekranyansit -T /usr/bin/codesign >/dev/null
    rm -rf "$T"
fi
codesign --force -s "$ID" "$APP"
pkill -f EkranYansit.app/Contents/MacOS/EkranYansit || true
rm -rf /Applications/EkranYansit.app && cp -R "$APP" /Applications/
defaults write com.alper.ekranyansit tvIP "$TV"
defaults write com.alper.ekranyansit adbPath "$ADB"

echo "✓ Bitti. Ekran Yansıt açılıyor."
open /Applications/EkranYansit.app
