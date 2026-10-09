#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR"
APP_BUNDLE="$ROOT_DIR/dist.noindex/Perch.app"
BUNDLE_ID="com.omnis.perch"
LEGACY_ID="com.pox.desktop"
MODE="${1:-run}"

case "$MODE" in run|--verify|--build|--install|--logs|--debug) ;; *) echo "Usage: $0 [--build|--verify|--install|--logs|--debug]"; exit 2 ;; esac

VERSION="$(cat "$ROOT_DIR/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION" >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=14.0
CONFIGURATION="${PERCH_CONFIGURATION:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "Invalid PERCH_CONFIGURATION" >&2; exit 2 ;; esac
SIGNING_IDENTITY="${PERCH_SIGNING_IDENTITY:--}"
SWIFT_FLAGS=(--package-path "$PACKAGE_DIR" -c "$CONFIGURATION")
CLANG_FLAGS=(-mmacosx-version-min=14.0)
for arch in ${PERCH_ARCHS:-}; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 2 ;; esac
  SWIFT_FLAGS+=(--arch "$arch")
  CLANG_FLAGS+=(-arch "$arch")
done
SIGN_FLAGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
swift build "${SWIFT_FLAGS[@]}"
BUILD_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
# Recreate only the generated bundle, preventing removed resources from surviving upgrades.
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/Perch" "$APP_BUNDLE/Contents/MacOS/Perch"
cp "$PACKAGE_DIR/Resources/pox-atlas.png" "$APP_BUNDLE/Contents/Resources/pox-atlas.png"
rm -f "$APP_BUNDLE/Contents/Resources/codex-home.txt"
rm -rf "$PACKAGE_DIR/.build/Perch.iconset"
swift "$ROOT_DIR/script/make-app-icon.swift" "$PACKAGE_DIR/Resources/AppIcon.svg" "$PACKAGE_DIR/.build/Perch.iconset"
iconutil -c icns "$PACKAGE_DIR/.build/Perch.iconset" -o "$APP_BUNDLE/Contents/Resources/Perch.icns"
MEDIA_VENDOR="$PACKAGE_DIR/Vendor/MediaRemoteAdapter"
MEDIA_FRAMEWORK="$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter.framework"
mkdir -p "$MEDIA_FRAMEWORK"
clang "${CLANG_FLAGS[@]}" -dynamiclib -fobjc-arc -fvisibility=default \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -I "$MEDIA_VENDOR/include" -I "$MEDIA_VENDOR/src" \
  "$MEDIA_VENDOR"/src/adapter/*.m "$MEDIA_VENDOR"/src/private/*.m "$MEDIA_VENDOR"/src/utility/*.m \
  -o "$MEDIA_FRAMEWORK/MediaRemoteAdapter"
cp "$MEDIA_VENDOR/bin/mediaremote-adapter.pl" "$APP_BUNDLE/Contents/Resources/"
cp "$MEDIA_VENDOR/LICENSE" "$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter-LICENSE"
codesign "${SIGN_FLAGS[@]}" "$MEDIA_FRAMEWORK/MediaRemoteAdapter" >/dev/null
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Perch</string>
<key>CFBundleIdentifier</key><string>com.omnis.perch</string>
<key>CFBundleName</key><string>Perch</string>
<key>CFBundleDisplayName</key><string>Perch</string>
<key>CFBundleIconFile</key><string>Perch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null

if [[ "$MODE" == "--build" ]]; then echo "$APP_BUNDLE"; exit 0; fi
# Every launch uses the installed copy so macOS has one application entry.
INSTALL_PATH="$HOME/Applications/Perch.app"
if [[ -d "$INSTALL_PATH" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then echo "Another Perch.app already exists; leaving it untouched." >&2; exit 1; fi
fi
pkill -x Perch >/dev/null 2>&1 || true
pkill -x PoxDesktop >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
ditto "$APP_BUNDLE" "$INSTALL_PATH"
# ditto keeps the bundle folder's old mtime, so Finder and the Dock keep showing a cached icon.
# Bump it and re-register so icon changes appear right away.
touch "$INSTALL_PATH"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_PATH" >/dev/null 2>&1 || true
# The renamed app replaces the old Pox.app. Move it to the Trash only when it is really ours.
LEGACY_PATH="$HOME/Applications/Pox.app"
if [[ -d "$LEGACY_PATH" ]]; then
  LEGACY_FOUND="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$LEGACY_FOUND" == "$LEGACY_ID" ]]; then
    mv "$LEGACY_PATH" "$HOME/.Trash/Pox-$(date +%Y%m%d-%H%M%S).app"
    echo "Moved the old Pox.app to the Trash."
  fi
fi
APP_BUNDLE="$INSTALL_PATH"

if [[ "$MODE" == "--debug" ]]; then lldb -- "$APP_BUNDLE/Contents/MacOS/Perch"; exit 0; fi
/usr/bin/open -n "$APP_BUNDLE"
if [[ "$MODE" == "--logs" ]]; then
  /usr/bin/log stream --info --style compact --predicate 'process == "Perch"'
else
  sleep 1
  pgrep -x Perch >/dev/null
  echo "Perch is running: $APP_BUNDLE"
fi
