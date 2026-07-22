#!/usr/bin/env bash
# Build TokenBar.app and copy it to /Applications.
# Usage:
#   ./scripts/build-app.sh           # build & copy to /Applications
#   ./scripts/build-app.sh --no-copy # build but don't install
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="TokenBar"
BUILD_DIR="$ROOT/.build/release"
APP_BUNDLE="$ROOT/$APP_NAME.app"
INSTALL_DIR="/Applications"
ICONSET_DIR="$ROOT/.build/icon.iconset"
ICON_PNG="$ROOT/.build/icon_1024.png"

COPY=true
for arg in "$@"; do
  case "$arg" in
    --no-copy) COPY=false ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

echo "==> 1. Compiling release binary"
swift build -c release

if [[ ! -x "$BUILD_DIR/$APP_NAME" ]]; then
  echo "binary not found at $BUILD_DIR/$APP_NAME" >&2
  exit 1
fi

echo "==> 2. Generating app icon"
mkdir -p "$ROOT/.build"
python3 "$ROOT/scripts/make_icon.py" "$ICON_PNG"
mkdir -p "$ICONSET_DIR"
sips -z 16 16     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png"     >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png"  >/dev/null
sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png"     >/dev/null
sips -z 64 64     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png"  >/dev/null
sips -z 128 128   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png"   >/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png">/dev/null
sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png"   >/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png">/dev/null
sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png"   >/dev/null
cp "$ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$ROOT/.build/AppIcon.icns"

echo "==> 3. Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/.build/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT/scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# SwiftPM's generated Bundle.module accessor looks for this bundle directly
# inside the .app (not under Contents/Resources) - it's where the real tool
# product icons live.
RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/${APP_NAME}_${APP_NAME}.bundle"
fi

# Ad-hoc sign so Gatekeeper / TCC will allow the unsigned binary to run.
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

# Refresh Launch Services so the new icon shows up in Finder / Launchpad.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> Built $APP_BUNDLE"

if $COPY; then
  echo "==> Copying to $INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP_BUNDLE" "$INSTALL_DIR/$APP_NAME.app"
  xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true
  echo "Installed: $INSTALL_DIR/$APP_NAME.app"
fi
