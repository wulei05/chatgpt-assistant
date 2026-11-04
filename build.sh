#!/bin/bash
# Build ChatGPT助手 — loose binaries and/or .app bundle.
# ARCH=universal|arm64|x86_64  (default: universal)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

OUT="${1:-dist}"
MODE="${2:-all}"   # all | bin | app
ARCH="${ARCH:-universal}"
MACOS_MIN="${MACOS_MIN:-13.0}"
mkdir -p "$OUT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 0.0.0)"
# ASCII bundle name for Launch Services reliability; CFBundleDisplayName stays 中文.
APP_NAME="ChatGPT Assistant"
APP="$OUT/${APP_NAME}.app"

swift_target() {
  case "$1" in
    arm64)  echo "arm64-apple-macosx${MACOS_MIN}" ;;
    x86_64) echo "x86_64-apple-macosx${MACOS_MIN}" ;;
    *) echo "unknown arch: $1" >&2; return 1 ;;
  esac
}

compile_one() {
  local arch="$1" src="$2" out="$3"
  shift 3
  local target
  target="$(swift_target "$arch")"
  echo "  swiftc [$arch] → $(basename "$out")"
  swiftc -O -target "$target" -o "$out" "$src" "$@"
}

# Build one binary as arm64 / x86_64 / universal (lipo).
build_binary() {
  local dest="$1" name="$2" src="$3"
  shift 3
  local frameworks=("$@")
  mkdir -p "$dest"
  case "$ARCH" in
    arm64|x86_64)
      compile_one "$ARCH" "$src" "$dest/$name" "${frameworks[@]}"
      ;;
    universal)
      local tmp
      tmp="$(mktemp -d)"
      compile_one arm64  "$src" "$tmp/${name}-arm64"  "${frameworks[@]}"
      compile_one x86_64 "$src" "$tmp/${name}-x86_64" "${frameworks[@]}"
      lipo -create "$tmp/${name}-arm64" "$tmp/${name}-x86_64" -output "$dest/$name"
      rm -rf "$tmp"
      ;;
    *)
      echo "ARCH must be universal|arm64|x86_64 (got: $ARCH)" >&2
      exit 1
      ;;
  esac
  chmod +x "$dest/$name"
}

build_bins() {
  local dest="$1"
  mkdir -p "$dest"
  local tmp
  tmp="$(mktemp -d)"
  # Concatenate so top-level executable code stays in a single swiftc "main" file.
  cat Paths.swift watch3.swift > "$tmp/daemon.swift"
  cat Paths.swift statusbar.swift > "$tmp/bar.swift"

  echo "Building binaries (ARCH=$ARCH, macosx${MACOS_MIN})…"
  build_binary "$dest" cgpt-daemon "$tmp/daemon.swift" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework Vision
  build_binary "$dest" CGPTBar "$tmp/bar.swift" \
    -framework AppKit
  rm -rf "$tmp"

  if command -v lipo >/dev/null; then
    lipo -info "$dest/cgpt-daemon" || true
    lipo -info "$dest/CGPTBar" || true
  fi
}

# Only copy helper tools when they match the requested arch (skip mismatched fat/thin).
maybe_copy_helper() {
  local src="$1" dest_dir="$2"
  [[ -f "$src" ]] || return 0
  local info
  info="$(lipo -info "$src" 2>/dev/null || true)"
  case "$ARCH" in
    universal)
      # Prefer universal helpers; otherwise skip to avoid arch breakage.
      if echo "$info" | grep -q 'Architectures in the fat file' && \
         echo "$info" | grep -q 'arm64' && echo "$info" | grep -q 'x86_64'; then
        cp "$src" "$dest_dir/"
        chmod +x "$dest_dir/$(basename "$src")"
      else
        echo "  skip helper $(basename "$src") (not universal)"
      fi
      ;;
    arm64|x86_64)
      if echo "$info" | grep -q "$ARCH"; then
        cp "$src" "$dest_dir/"
        chmod +x "$dest_dir/$(basename "$src")"
      else
        echo "  skip helper $(basename "$src") (no $ARCH)"
      fi
      ;;
  esac
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
  maybe_copy_helper "$ROOT/cli" "$APP/Contents/MacOS"
  maybe_copy_helper "$ROOT/key" "$APP/Contents/MacOS"
  # Ad-hoc sign so Gatekeeper / Accessibility identity is stable locally
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "App: $APP (v${VERSION}, ARCH=$ARCH)"
}

package_loose() {
  build_bins "$OUT"
  if [[ "$(cd "$OUT" && pwd)" != "$ROOT" ]]; then
    cp start-daemon.sh start-bar.sh settings.json SPEC.md README.md "$OUT/"
    chmod +x "$OUT/start-daemon.sh" "$OUT/start-bar.sh"
    maybe_copy_helper "$ROOT/cli" "$OUT"
    maybe_copy_helper "$ROOT/key" "$OUT"
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
    echo "Usage: ARCH=universal|arm64|x86_64 $0 [outdir] [all|bin|app]"
    exit 1
    ;;
esac

echo "Built into $OUT/"
if [[ -d "$APP" ]]; then ls -la "$APP/Contents/MacOS"; fi
ls -la "$OUT" | head -30
