#!/bin/bash
# Build ChatGPT助手 — loose binaries and/or .app bundle.
# ARCH=arm64|x86_64|both  (default: host arch)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

OUT="${1:-dist}"
MODE="${2:-all}"   # all | bin | app
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|x86_64) DEFAULT_ARCH="$HOST_ARCH" ;;
  *) DEFAULT_ARCH=arm64 ;;
esac
ARCH="${ARCH:-$DEFAULT_ARCH}"
MACOS_MIN="${MACOS_MIN:-13.0}"
mkdir -p "$OUT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 0.0.0)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist 2>/dev/null || echo com.wulei05.chatgpt-assistant)"
APP_NAME="ChatGPT Assistant"

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

build_bins_for_arch() {
  local arch="$1" dest="$2"
  mkdir -p "$dest"
  local tmp
  tmp="$(mktemp -d)"
  # Bar includes watch core so monitoring can run in-process (Accessibility TCC).
  cat Paths.swift watch3.swift > "$tmp/daemon.swift"
  cat Paths.swift watch3.swift statusbar.swift > "$tmp/bar.swift"

  echo "Building binaries (ARCH=$arch, macosx${MACOS_MIN})…"
  compile_one "$arch" "$tmp/daemon.swift" "$dest/cgpt-daemon" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework Vision
  compile_one "$arch" "$tmp/bar.swift" "$dest/CGPTBar" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework Vision
  chmod +x "$dest/cgpt-daemon" "$dest/CGPTBar"
  rm -rf "$tmp"
  lipo -info "$dest/cgpt-daemon" || true
  lipo -info "$dest/CGPTBar" || true
}

maybe_copy_helper() {
  local arch="$1" src="$2" dest_dir="$3"
  [[ -f "$src" ]] || return 0
  local info
  info="$(lipo -info "$src" 2>/dev/null || true)"
  if echo "$info" | grep -q "$arch"; then
    cp "$src" "$dest_dir/"
    chmod +x "$dest_dir/$(basename "$src")"
  else
    echo "  skip helper $(basename "$src") (no $arch)"
  fi
}

package_app_for_arch() {
  local arch="$1"
  local app_dir
  if [[ "$ARCH" == "both" ]]; then
    app_dir="$OUT/$arch/${APP_NAME}.app"
  else
    app_dir="$OUT/${APP_NAME}.app"
  fi
  rm -rf "$app_dir"
  mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
  build_bins_for_arch "$arch" "$app_dir/Contents/MacOS"
  cp Info.plist "$app_dir/Contents/Info.plist"
  echo -n 'APPL????' > "$app_dir/Contents/PkgInfo"
  cp settings.json SPEC.md "$app_dir/Contents/Resources/"
  if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
    cp "$ROOT/assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
  fi
  maybe_copy_helper "$arch" "$ROOT/cli" "$app_dir/Contents/MacOS"
  maybe_copy_helper "$arch" "$ROOT/key" "$app_dir/Contents/MacOS"
  # Sign bundle first, then re-stamp every Mach-O with the app Bundle ID.
  # (--deep alone leaves helpers with unique ad-hoc IDs, so Accessibility TCC
  # granted to ChatGPT助手 would not cover cgpt-daemon, where AX actually runs.)
  codesign --force --deep --sign - "$app_dir" 2>/dev/null || true
  for bin in CGPTBar cgpt-daemon cli key; do
    if [[ -f "$app_dir/Contents/MacOS/$bin" ]]; then
      codesign --force --sign - --identifier "$BUNDLE_ID" \
        "$app_dir/Contents/MacOS/$bin" 2>/dev/null || true
    fi
  done
  codesign --force --sign - --identifier "$BUNDLE_ID" "$app_dir" 2>/dev/null || true
  echo "App: $app_dir (v${VERSION}, ARCH=$arch, id=$BUNDLE_ID)"
}

package_loose_for_arch() {
  local arch="$1"
  local dest
  if [[ "$ARCH" == "both" ]]; then
    dest="$OUT/$arch"
  else
    dest="$OUT"
  fi
  mkdir -p "$dest"
  build_bins_for_arch "$arch" "$dest"
  if [[ "$(cd "$dest" && pwd)" != "$ROOT" ]]; then
    cp start-daemon.sh start-bar.sh settings.json SPEC.md README.md "$dest/"
    chmod +x "$dest/start-daemon.sh" "$dest/start-bar.sh"
    maybe_copy_helper "$arch" "$ROOT/cli" "$dest"
    maybe_copy_helper "$arch" "$ROOT/key" "$dest"
  fi
}

run_for_archs() {
  local fn="$1"
  case "$ARCH" in
    arm64|x86_64) "$fn" "$ARCH" ;;
    both)
      "$fn" arm64
      "$fn" x86_64
      ;;
    *)
      echo "ARCH must be arm64|x86_64|both (got: $ARCH)" >&2
      exit 1
      ;;
  esac
}

case "$MODE" in
  bin) run_for_archs package_loose_for_arch ;;
  app) run_for_archs package_app_for_arch ;;
  all)
    run_for_archs package_loose_for_arch
    run_for_archs package_app_for_arch
    ;;
  *)
    echo "Usage: ARCH=arm64|x86_64|both $0 [outdir] [all|bin|app]"
    exit 1
    ;;
esac

echo "Built into $OUT/ (ARCH=$ARCH)"
ls -la "$OUT" | head -40
