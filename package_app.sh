#!/bin/bash

# Comprehensive script to package RichVideoDownloader as a portable macOS .app
set -e

APP_NAME="RichVideoDownloader"
BUNDLE_ID="io.antigravity.RichVideoDownloader"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
ICON_PATH="/Users/rakeshmohan/.gemini/antigravity/brain/18200527-08ac-4555-b993-a42f2f870958/app_icon_minimalist_kinetic_downloader_1773490551525.png"

echo "🚀 Building $APP_NAME in Release mode..."
swift build -c release

echo "📁 Creating app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"

echo "⚙️ Copying binary..."
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

echo "📦 Bundling toolchain (yt-dlp, ffmpeg, aria2c, etc.)..."
TOOLS=("yt-dlp" "ffmpeg" "ffprobe" "aria2c" "dash-mpd-cli")
for tool in "${TOOLS[@]}"; do
    TOOL_PATH=$(which "$tool" || true)
    if [ -n "$TOOL_PATH" ]; then
        echo "   + Adding $tool from $TOOL_PATH"
        cp "$TOOL_PATH" "$APP_BUNDLE/Contents/Resources/bin/"
    else
        echo "   ! Warning: $tool not found in PATH, skipping bundling for this tool."
    fi
done

echo "📝 Creating Info.plist..."
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF

if [ -f "$ICON_PATH" ]; then
    echo "🎨 Generating icon set..."
    ICONSET="AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$ICON_PATH" --out "$ICONSET/icon_16x16.png"
    sips -z 32 32     "$ICON_PATH" --out "$ICONSET/icon_16x16@2x.png"
    sips -z 32 32     "$ICON_PATH" --out "$ICONSET/icon_32x32.png"
    sips -z 64 64     "$ICON_PATH" --out "$ICONSET/icon_32x32@2x.png"
    sips -z 128 128   "$ICON_PATH" --out "$ICONSET/icon_128x128.png"
    sips -z 256 256   "$ICON_PATH" --out "$ICONSET/icon_128x128@2x.png"
    sips -z 256 256   "$ICON_PATH" --out "$ICONSET/icon_256x256.png"
    sips -z 512 512   "$ICON_PATH" --out "$ICONSET/icon_256x256@2x.png"
    sips -z 512 512   "$ICON_PATH" --out "$ICONSET/icon_512x512.png"
    sips -z 1024 1024 "$ICON_PATH" --out "$ICONSET/icon_512x512@2x.png"
    
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

echo "✅ Portable app bundle created at $APP_BUNDLE"

read -p "🚀 Do you want to install $APP_NAME to your /Applications folder? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "📂 Installing to /Applications..."
    rm -rf "/Applications/$APP_BUNDLE"
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "✨ Done! You can now launch $APP_NAME from your Applications folder or Spotlight."
else
    echo "💡 You can find the app bundle in the current directory: $(pwd)/$APP_BUNDLE"
fi
