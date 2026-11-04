#!/bin/bash
# Build ChatGPT助手 — loose binaries and/or .app bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

OUT="${1:-dist}"
MODE="${2:-all}"   # all | bin | app
mkdir -p "$OUT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 0.0.0)"
# ASCII bundle name for Launch Services reliability; CFBundleDisplayName stays 中文.
APP_NAME="ChatGPT Assistant"
APP="$OUT/${APP_NAME}.app"

build_bins() {
  local dest="$1"
  mkdir -p "$dest"
  local tmp
  tmp="$(mktemp -d)"
  # Concatenate so top-level executable code stays in a single swiftc "main" file.
  cat Paths.swift watch3.swift > "$tmp/daemon.swift"
  cat Paths.swift statusbar.swift > "$tmp/bar.swift"
  swiftc -O -o "$dest/cgpt-daemon" "$tmp/daemon.swift" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework Vision
  swiftc -O -o "$dest/CGPTBar" "$tmp/bar.swift" \
    -framework AppKit
  rm -rf "$tmp"
  chmod +x "$dest/cgpt-daemon" "$dest/CGPTBar"
}

package_app() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  build_bins "$APP/Contents/MacOS"
  cp Info.plist "$APP/Contents/Info.plist"
  echo -n 'APPL????' > "$APP/Contents/PkgInfo"
  cp settings.json SPEC.md "$APP/Contents/Resources/"
  if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
    cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  fi
  for bin in cli key; do
    if [[ -f "$ROOT/$bin" ]]; then
      cp "$ROOT/$bin" "$APP/Contents/MacOS/"
      chmod +x "$APP/Contents/MacOS/$bin"
    fi
  done
  # Ad-hoc sign so Gatekeeper / Accessibility identity is stable locally
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "App: $APP (v${VERSION})"
}

package_loose() {
  build_bins "$OUT"
  if [[ "$(cd "$OUT" && pwd)" != "$ROOT" ]]; then
    cp start-daemon.sh start-bar.sh settings.json SPEC.md README.md "$OUT/"
    chmod +x "$OUT/start-daemon.sh" "$OUT/start-bar.sh"
    for bin in cli key; do
      if [[ -f "$ROOT/$bin" ]]; then
        cp "$ROOT/$bin" "$OUT/"
        chmod +x "$OUT/$bin"
      fi
    done
  fi
}

case "$MODE" in
  bin) package_loose ;;
  app) package_app ;;
  all)
    package_loose
    package_app
    ;;
  *)
    echo "Usage: $0 [outdir] [all|bin|app]"; exit 1 ;;
esac

echo "Built into $OUT/"
if [[ -d "$APP" ]]; then ls -la "$APP/Contents/MacOS"; fi
ls -la "$OUT" | head -30
