#!/bin/bash
# Fully detach ChatGPTAssistantBar (menu bar). Avoid osascript — it often hangs for Automation permission.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
pkill -x ChatGPTAssistantBar 2>/dev/null || true
sleep 0.3
/usr/bin/python3 - <<PY
import os, sys, time
base = "$ROOT"
bin_path = os.path.join(base, "ChatGPTAssistantBar")
if os.fork() > 0:
    time.sleep(0.4)
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
os.chdir(base)
os.umask(0)
devnull = open(os.devnull, "rb")
log = open(os.path.join(base, "bar.log"), "a")
os.dup2(devnull.fileno(), 0)
os.dup2(log.fileno(), 1)
os.dup2(log.fileno(), 2)
os.execv(bin_path, [bin_path])
PY
sleep 0.5
if pgrep -x ChatGPTAssistantBar >/dev/null; then
  echo "OK pid=$(pgrep -x ChatGPTAssistantBar)"
else
  echo "FAIL: ChatGPTAssistantBar did not stay up"; exit 1
fi
