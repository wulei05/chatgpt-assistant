# ChatGPT助手 · chatgpt-assistant

macOS **菜单栏 App**：根据本地 Codex **运行记录（rollout）** 发现失败会话，优先用 `codex queue` 发送 `continue`，失败再短暂抢焦点，用 agent-desktop / AX 打开并继续。

中文名：**ChatGPT助手** · App：`ChatGPT Assistant.app` · Bundle ID：`com.wulei05.chatgpt-assistant`

## 安装（推荐）

1. 从 [Releases](https://github.com/wulei05/chatgpt-assistant/releases) 下载 `ChatGPT-Assistant-*-macos-universal.zip`
2. 解压得到 `ChatGPT Assistant.app`，拖到「应用程序」（Apple Silicon / Intel 通用）
3. 首次如被拦截：右键 → 打开
4. 菜单栏出现圆点（无 Dock 图标）
5. 「系统设置 → 隐私与安全性 → 辅助功能」勾选 **ChatGPT助手**

运行数据：`~/Library/Application Support/ChatGPT助手/`

应用图标源文件在 `assets/AppIcon.icns`（青绿对话泡 + 珊瑚色继续按钮）。

## 本地构建

```bash
ARCH=universal ./build.sh dist app   # 默认也是 universal（arm64 + x86_64）
ARCH=arm64 ./build.sh dist app       # 仅 Apple Silicon
ARCH=x86_64 ./build.sh dist app      # 仅 Intel
open "dist/ChatGPT Assistant.app"
```

## 开发模式（不装 .app）

```bash
ARCH=arm64 ./build.sh . bin
./start-daemon.sh
./start-bar.sh
```

## 停止

菜单栏 → **关闭监控** / **退出菜单栏**，或：

```bash
pkill -x cgpt-daemon
pkill -x CGPTBar
```

## 行为约定

- 只处理运行记录上一轮带 `error`、且当前未 running 的会话
- **优先** `codex queue`；失败且卡住时再短暂抢焦点用 AX / agent-desktop（无盲发）
- 失败按 0→1.5→3→5→10 分钟退避；**立即扫描**（⌘R）会清退避并重试

## Release

```bash
git tag v0.2.0
git push origin v0.2.0
```

推送 `v*` tag 会打包 `ChatGPT Assistant.app` 上传到 GitHub Release。
