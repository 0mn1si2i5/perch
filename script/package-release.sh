#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT_DIR/VERSION")"
export PERCH_CONFIGURATION=release
export PERCH_ARCHS="arm64 x86_64"
"$ROOT_DIR/script/build_and_run.sh" --build
APP="$ROOT_DIR/dist.noindex/Perch.app"
OUT="$ROOT_DIR/dist.noindex/releases"
STAGING="$ROOT_DIR/.build/release-staging"
mkdir -p "$OUT"
for binary in "$APP/Contents/MacOS/Perch" "$APP/Contents/Resources/MediaRemoteAdapter.framework/MediaRemoteAdapter"; do
  architectures="$(lipo -archs "$binary")"
  for required in arm64 x86_64; do
    case " $architectures " in *" $required "*) ;; *) echo "Missing $required in $binary" >&2; exit 1 ;; esac
  done
done
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Perch.app"
ln -s /Applications "$STAGING/Applications"
ZIP="Perch-$VERSION-universal.zip"
DMG="Perch-$VERSION-universal.dmg"
rm -f "$OUT/$ZIP" "$OUT/$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
hdiutil create -volname "Perch $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$OUT/$DMG"
(cd "$OUT" && shasum -a 256 "$ZIP" "$DMG" > SHA256SUMS)
echo "Release files: $OUT"
