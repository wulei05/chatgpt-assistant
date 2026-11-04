#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export CHATGPT_ASSISTANT_HOME="${CHATGPT_ASSISTANT_HOME:-$ROOT}"
pkill -x cgpt-daemon 2>/dev/null || true
sleep 0.3
rm -f "$CHATGPT_ASSISTANT_HOME/STOP"

BIN="$ROOT/cgpt-daemon"
if [[ ! -x "$BIN" && -x "$ROOT/ChatGPT Assistant.app/Contents/MacOS/cgpt-daemon" ]]; then
  BIN="$ROOT/ChatGPT Assistant.app/Contents/MacOS/cgpt-daemon"
fi
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: cgpt-daemon not found"; exit 1
fi

nohup env CHATGPT_ASSISTANT_HOME="$CHATGPT_ASSISTANT_HOME" "$BIN" \
  >>"$CHATGPT_ASSISTANT_HOME/stdout.log" 2>>"$CHATGPT_ASSISTANT_HOME/daemon.err" </dev/null &
sleep 0.5
if pgrep -x cgpt-daemon >/dev/null; then
  echo "OK pid=$(pgrep -x cgpt-daemon)"
else
  echo "FAIL: cgpt-daemon did not stay up"; exit 1
fi
