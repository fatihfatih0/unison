#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
make -C Vendor/m1ddc
swift build -c release
./Scripts/build-icons.sh
app="$PWD/build/Products.noindex/Unison.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Unison "$app/Contents/MacOS/Unison"
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Vendor/m1ddc/m1ddc "$app/Contents/Resources/m1ddc"
cp Vendor/m1ddc/LICENSE "$app/Contents/Resources/m1ddc-LICENSE.txt"
cp LICENSE "$app/Contents/Resources/Unison-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Unison</string>
<key>CFBundleIdentifier</key><string>org.unison.mac</string>
<key>CFBundleName</key><string>Unison</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Unison, HDMI ve diğer çıkışların sesini kontrol etmek için sistem sesini yalnızca bu Mac'te işler. Ses kaydedilmez veya gönderilmez.</string>
</dict></plist>
PLIST
# Prefer an installed Apple development identity for a stable privacy identity.
signing_identity="${UNISON_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')
fi
if [[ -n "$signing_identity" ]]; then
    codesign --force --sign "$signing_identity" "$app/Contents/Resources/m1ddc"
    codesign --force --sign "$signing_identity" "$app"
else
    codesign --force --sign - "$app/Contents/Resources/m1ddc"
    codesign --force --sign - --requirements '=designated => identifier "org.unison.mac"' "$app"
fi
codesign --verify --strict "$app"
echo "Uygulama hazır: $app"
