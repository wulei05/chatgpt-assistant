# ChatGPT助手 · chatgpt-assistant

macOS 菜单栏工具：根据本地 Codex **运行记录（rollout）** 发现失败会话，优先用 `codex queue` 发送 `continue`，失败再短暂抢焦点，用 agent-desktop / AX 打开并继续。

中文名：**ChatGPT助手** · 仓库名：**chatgpt-assistant**

## 组成

| 文件 | 作用 |
|---|---|
| `chatgpt-assistant` | 监控守护进程（由 `watch3.swift` 编译） |
| `ChatGPTAssistantBar` | 菜单栏常驻（由 `statusbar.swift` 编译） |
| `start-daemon.sh` / `start-bar.sh` | 后台启动脚本 |
| `SPEC.md` | 主路径设计 |

## 本地构建

```bash
./build.sh          # 产出到 dist/
# 或原地编译：
./build.sh .
```

## 运行

```bash
cd /path/to/chatgpt-assistant   # 或解压 Release zip 后的目录
./start-daemon.sh
./start-bar.sh
```

需在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 `chatgpt-assistant`。

## 停止

```bash
pkill -x chatgpt-assistant
pkill -x ChatGPTAssistantBar
touch STOP
```

## 菜单栏

| 图标 | 含义 |
|---|---|
| 绿点 | 监控中，没有待继续会话 |
| 橙点 + 数字 | 监控中，有 N 条待继续 |
| 红点 | 监控进程已退出 |

支持：立即扫描（⌘R）、开启/关闭监控、暂停自动发送、最长运行时间、轮询间隔、监控目标、实现原理。

## 行为约定

- 只处理运行记录上一轮带 `error`、且当前未 running 的会话
- **优先** `codex queue`；失败且卡住时再短暂抢焦点用 AX / agent-desktop（无盲发）
- 失败按 0→1.5→3→5→10 分钟退避；**立即扫描**会清退避并重试
- 输入框已有草稿时，直接发送该草稿（不覆盖成 continue）

## Release

推送形如 `v0.1.0` 的 tag 会触发 GitHub Actions，在 macOS 上编译并上传 zip 产物：

```bash
git tag v0.1.0
git push origin v0.1.0
```

也可在 Actions 里手动跑 **Release** workflow。
