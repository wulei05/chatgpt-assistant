#!/bin/bash
# Fully detach chatgpt-assistant so agent/IDE shells cannot reap it.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
pkill -x chatgpt-assistant 2>/dev/null || true
sleep 0.4
rm -f STOP
/usr/bin/python3 - <<PY
import os, sys, time
base = "$ROOT"
bin_path = os.path.join(base, "chatgpt-assistant")
stdout = open(os.path.join(base, "stdout.log"), "a")
stderr = open(os.path.join(base, "daemon.err"), "a")
if os.fork() > 0:
    time.sleep(0.3)
    sys.exit(0)
os.setsid()
if os.fork() > 0:
    sys.exit(0)
os.chdir(base)
os.umask(0)
devnull = open(os.devnull, "rb")
os.dup2(devnull.fileno(), 0)
os.dup2(stdout.fileno(), 1)
os.dup2(stderr.fileno(), 2)
os.execv(bin_path, [bin_path])
PY
sleep 0.6
if pgrep -x chatgpt-assistant >/dev/null; then
  echo "OK pid=$(pgrep -x chatgpt-assistant)"
else
  echo "FAIL: chatgpt-assistant did not stay up"; exit 1
fi
