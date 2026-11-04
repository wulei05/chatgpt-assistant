#!/bin/bash
# Build release binaries for ChatGPT助手 (chatgpt-assistant).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

OUT="${1:-dist}"
mkdir -p "$OUT"

swiftc -O -o "$OUT/chatgpt-assistant" watch3.swift \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework Vision

swiftc -O -o "$OUT/ChatGPTAssistantBar" statusbar.swift \
  -framework AppKit

chmod +x "$OUT/chatgpt-assistant" "$OUT/ChatGPTAssistantBar"

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

echo "Built into $OUT/"
ls -la "$OUT/chatgpt-assistant" "$OUT/ChatGPTAssistantBar"
