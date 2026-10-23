#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NODE_VERSION=v24.22.1
VERSION=0.1.0
CACHE="$ROOT/macos/.build/moot-node"
OUT="$ROOT/macos/dist.noindex/moot"
mkdir -p "$CACHE" "$OUT"
curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" -o "$CACHE/SHASUMS256.txt"
source "$ROOT/macos/script/signing-identity.sh"
MOOT_SIGNER="$(perch_resolve_signing_identity "$HOME/Applications/Perch.app")"
for ARCH in ${MOOT_ARCHS:-arm64 x86_64}; do
  case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
  NODE_ARCH="$ARCH"; [[ "$ARCH" != x86_64 ]] || NODE_ARCH=x64
  ARCHIVE="node-$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
  [[ -f "$CACHE/$ARCHIVE" ]] || curl -fSL "https://nodejs.org/dist/$NODE_VERSION/$ARCHIVE" -o "$CACHE/$ARCHIVE"
  (cd "$CACHE" && awk -v file="$ARCHIVE" '$2 == file' SHASUMS256.txt | shasum -a 256 -c -)
  tar -xzf "$CACHE/$ARCHIVE" -C "$CACHE"
  PACKAGE="$OUT/Moot-$VERSION-$ARCH.mootpkg"
  rm -rf "$PACKAGE"
  mkdir -p "$PACKAGE"
  cp "$CACHE/node-$NODE_VERSION-darwin-$NODE_ARCH/bin/node" "$PACKAGE/node"
  cp "$CACHE/node-$NODE_VERSION-darwin-$NODE_ARCH/LICENSE" "$PACKAGE/Node-LICENSE"
  cp -R "$ROOT/extensions/moot/bin" "$ROOT/extensions/moot/lib" "$ROOT/extensions/moot/skills" "$PACKAGE/"
  cp "$ROOT/extensions/moot/package.json" "$ROOT/LICENSE" "$PACKAGE/"
  cat > "$PACKAGE/moot" <<'LAUNCH'
#!/bin/sh
RUNTIME="$(cd "$(dirname "$0")" && pwd -P)"
exec "$RUNTIME/node" "$RUNTIME/bin/moot.js" "$@"
LAUNCH
  chmod +x "$PACKAGE/moot" "$PACKAGE/node"
  HELPER="${MOOT_CREDENTIAL_HELPER:-}"
  if [[ -z "$HELPER" ]] || ! lipo -verify_arch "$ARCH" "$HELPER" >/dev/null 2>&1; then
    swift build --package-path "$ROOT/macos" --product PerchMootCredentials -c release --arch "$ARCH"
    HELPER="$(swift build --package-path "$ROOT/macos" -c release --arch "$ARCH" --show-bin-path)/PerchMootCredentials"
  fi
  cp "$HELPER" "$PACKAGE/PerchMootCredentials"
  codesign --force --sign "$MOOT_SIGNER" "$PACKAGE/PerchMootCredentials"
  python3 - "$PACKAGE" "$ARCH" "$VERSION" "$NODE_VERSION" <<'PY'
import sys,pathlib,json,hashlib
p=pathlib.Path(sys.argv[1]); files={str(f.relative_to(p)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(p.rglob('*')) if f.is_file()}
(p/'manifest.json').write_text(json.dumps({'version':sys.argv[3],'protocolVersion':1,'platform':'macos','architecture':sys.argv[2],'minOS':14,'nodeVersion':sys.argv[4],'files':files},indent=2)+'\n')
PY
  echo "$PACKAGE"
done
