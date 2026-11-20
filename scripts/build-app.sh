#!/bin/zsh
# Builds Fulcrum.app (release) into ./build
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Fulcrum.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Fulcrum "$APP/Contents/MacOS/Fulcrum"

if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset; mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Saira (SIL Open Font Licence) for engraved figures — see DESIGN.md
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/Saira-Variable.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Fulcrum</string>
  <key>CFBundleDisplayName</key><string>Fulcrum</string>
  <key>CFBundleIdentifier</key><string>local.fulcrum.photo</string>
  <key>CFBundleExecutable</key><string>Fulcrum</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPhotoLibraryAddUsageDescription</key><string>Fulcrum adds your edited photos to Photos when you upload.</string>
  <key>NSPhotoLibraryUsageDescription</key><string>Fulcrum adds your edited photos to Photos when you upload.</string>
  <key>NSAppleEventsUsageDescription</key><string>Fulcrum sets keywords and favourites on photos it adds to Photos.</string>
  <key>NSCameraUsageDescription</key><string>Fulcrum reads photos from your connected camera so you can pick which to import.</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array>
        <string>public.camera-raw-image</string><string>com.adobe.raw-image</string>
        <string>public.jpeg</string><string>public.heic</string><string>public.heif</string>
        <string>public.png</string><string>public.tiff</string>
      </array>
    </dict>
  </array>
</dict></plist>
PLIST
codesign --force --sign "${FULCRUM_SIGN_IDENTITY:-Apple Development}" "$APP" >/dev/null
echo "Built $APP"
