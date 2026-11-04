# SPEC: 运行记录优先 continue

Status: implemented · discoverMode=`files` · **codex queue first**  
Product: **ChatGPT助手** (`chatgpt-assistant`)  
Date: 2026-11-04

## Goals

1. **发现**：只读本地 Codex 运行记录 / rollout（`task_complete` + `error`），且非 `running`。
2. **命名**：`session_index.thread_name` 正式标题。
3. **优先发送**：`codex queue --thread <id> --message continue`（不依赖窗口 / Space）。
4. **兜底**：queue 失败或运行记录未动 → 短暂抢焦点（可切 Space）→ `agent-desktop` / AX 打开并发送。
5. **确认**：运行记录进入 `running` / 新 `task_started`；写入 `handled.txt`。
6. 保留菜单栏、PID 目标、暂停/停止/立即扫描。

## Non-goals

- 盲发（无 AX 坐标粘贴）
- Cua Driver / LLM computer-use 环
- 给已运行 ChatGPT 挂 CDP

## Pipeline

```
each poll:
  resolve targetPid / bundle
  work = rollout errors in ~2h (skip handled threadId:errorTurn)
  write state.json
  for item in work (if not paused / not backoff):
    codex queue continue
      ok + rollout running → markHandled
      else:
        if offscreen / no AX → stealFocusBriefly (activate / focus-window)
        ensureOpen(title)     // agent-desktop → AX
        sendContinue(...)     // AD/AX/PostToPid；无盲发
        waitRolloutStarted
          ok  → markHandled
          fail → backoff
```

立即扫描：清退避并马上重试。

## Settings

```json
{
  "discoverMode": "files",
  "useAgentDesktop": true,
  "useCodexQueue": true,
  "codexPath": "/opt/homebrew/bin/codex"
}
```
