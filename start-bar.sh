#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
pkill -x CGPTBar 2>/dev/null || true
sleep 0.3

APP="$ROOT/ChatGPT Assistant.app"
if [[ -d "$APP" ]]; then
  open "$APP"
  sleep 1
  if pgrep -x CGPTBar >/dev/null; then
    echo "OK app pid=$(pgrep -x CGPTBar)"
    exit 0
  fi
fi

export CHATGPT_ASSISTANT_HOME="${CHATGPT_ASSISTANT_HOME:-$ROOT}"
BIN="$ROOT/CGPTBar"
nohup env CHATGPT_ASSISTANT_HOME="$CHATGPT_ASSISTANT_HOME" "$BIN" \
  >>"$CHATGPT_ASSISTANT_HOME/bar.log" 2>&1 </dev/null &
sleep 0.5
if pgrep -x CGPTBar >/dev/null; then
  echo "OK pid=$(pgrep -x CGPTBar)"
else
  echo "FAIL: CGPTBar did not stay up"; exit 1
fi
