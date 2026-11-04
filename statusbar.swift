import AppKit
import Foundation

let statePath = AppPaths.statePath
let settingsPath = AppPaths.settingsPath
let pausePath = AppPaths.pausePath
let stopPath = AppPaths.stopPath
let scanNowPath = AppPaths.scanNowPath
// `logPath` is declared in watch3.swift (CGPTBar links both).

func readJSON(_ path: String) -> [String: Any]? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o
}
func writeJSON(_ path: String, _ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
func readSettings() -> [String: Any] {
    var s = readJSON(settingsPath) ?? [:]
        if s["maxRuntimeHours"] == nil { s["maxRuntimeHours"] = 0 }
    if s["pollSec"] == nil { s["pollSec"] = 8 }
    if s["targetPid"] == nil { s["targetPid"] = 0 }
    if s["targetBundleId"] == nil { s["targetBundleId"] = "com.openai.codex" }
    if s["discoverMode"] == nil { s["discoverMode"] = "files" }
    return s
}
func candidateApps() -> [(pid: Int, name: String, bundleId: String)] {
    var out: [(pid: Int, name: String, bundleId: String)] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let pid = Int(app.processIdentifier)
        let name = app.localizedName ?? app.bundleURL?.lastPathComponent ?? "pid-\(pid)"
        let bid = app.bundleIdentifier ?? ""
        out.append((pid, name, bid))
    }
    return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
func saveSettings(_ mutate: (inout [String: Any]) -> Void) {
    var s = readSettings()
    mutate(&s)
    writeJSON(settingsPath, s)
}
func pidAlive(_ pid: Int) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid_t(pid), 0) == 0
}
func ageText(_ secs: Double) -> String {
    if secs < 0 { return "—" }
    if secs < 60 { return "\(Int(secs)) 秒前" }
    if secs < 3600 { return "\(Int(secs/60)) 分钟前" }
    return "\(Int(secs/3600)) 小时前"
}
func durationText(_ secs: Int) -> String {
    if secs < 60 { return "\(secs) 秒" }
    if secs < 3600 { return "\(secs/60) 分 \(secs%60) 秒" }
    return "\(secs/3600) 小时 \(secs%3600/60) 分"
}
func hoursLabel(_ h: Double) -> String {
    if h <= 0 { return "永久" }
    if h < 1 { return "\(Int(h * 60)) 分钟" }
    if h == floor(h) { return "\(Int(h)) 小时" }
    return String(format: "%.1f 小时", h)
}
/// Short method label from action detail ("codex queue · rollout 确认" → "queue").
func actionMethod(from detail: String) -> String? {
    let head = detail.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    guard !head.isEmpty, head != "rollout 确认" else { return nil }
    return head
}
func shortMethod(_ method: String) -> String {
    let m = method.lowercased()
    if m.contains("codex queue") { return "queue" }
    if m.contains("抢焦点") { return "抢焦点" }
    if m.contains("agent-desktop") { return "AD" }
    if m == "ax" || m.hasPrefix("ax") || m.contains("·ax") { return "AX" }
    if m.contains("posttopid") { return "键鼠" }
    if m.contains("盲发") { return "盲发" }
    if m.contains("草稿") { return "草稿" }
    if m.contains("已有continue") { return "已有" }
    return method
}
/// Compact session error for menu (429 / capacity / etc).
func shortError(_ err: String) -> String {
    let e = err.lowercased()
    if e.contains("429") || e.contains("too many requests") { return "429 限流" }
    if e.contains("at capacity") || e.contains("capacity") { return "模型容量满" }
    if err.count <= 28 { return err }
    return String(err.prefix(28)) + "…"
}
/// Truncate by character count (CJK-friendly enough for menu width).
func clipTitle(_ s: String, _ maxChars: Int) -> String {
    guard maxChars > 1, s.count > maxChars else { return s }
    return String(s.prefix(maxChars - 1)) + "…"
}

final class Controller: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    let menu = NSMenu()
    var timer: Timer?
    var menuIsOpen = false
    var lastMenuFingerprint = ""
    var menuKeyMonitor: Any?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        lastMenuFingerprint = ""
        installMenuKeyMonitor()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        removeMenuKeyMonitor()
    }

    func installMenuKeyMonitor() {
        removeMenuKeyMonitor()
        // Custom-view items often drop NSMenu keyEquivalents; catch ⌘R while menu is open.
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.menuIsOpen else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCmd = flags.contains(.command) && !flags.contains(.shift) && !flags.contains(.option) && !flags.contains(.control)
            let ch = event.charactersIgnoringModifiers?.lowercased()
            if isCmd, ch == "r" {
                self.scanNowKeepOpen(nil)
                return nil
            }
            return event
        }
    }
    func removeMenuKeyMonitor() {
        if let m = menuKeyMonitor {
            NSEvent.removeMonitor(m)
            menuKeyMonitor = nil
        }
    }

    let isoLoose: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    let isoBasic = ISO8601DateFormatter()
    func parseISO(_ s: String) -> Date? {
        isoLoose.date(from: s) ?? isoBasic.date(from: s)
    }
    func badgeNextRunSec(_ b: [String: Any]) -> Int {
        if let at = (b["nextRunAt"] as? String).flatMap(parseISO) {
            return max(0, Int(ceil(at.timeIntervalSinceNow)))
        }
        return max(0, (b["nextRunSec"] as? Int) ?? 0)
    }
    func menuFingerprint(from s: (state: [String: Any]?, alive: Bool, paused: Bool, heartbeatAge: Double, badges: [[String: Any]], actions: [[String: Any]], backoff: [[String: Any]])) -> String {
        let ms = (s.state?["manualScanAt"] as? String) ?? ""
        let pending = FileManager.default.fileExists(atPath: scanNowPath) ? "1" : "0"
        let act = (s.actions.last?["ts"] as? String) ?? ""
        let actRes = (s.actions.last?["result"] as? String) ?? ""
        let next = s.badges.map { "\(badgeNextRunSec($0))" }.joined(separator: ",")
        return "\(s.alive)-\(Int(s.heartbeatAge))-\(s.badges.count)-\(ms)-\(pending)-\(act)-\(actRes)-\(s.paused)-\(next)"
    }

    /// Custom view button — clicking does not dismiss the status menu. Shows ⌘R affordance.
    /// `width` also acts as the menu width rail (narrow when idle, wider with pending work).
    func makeStayOpenScanItem(width: CGFloat = 240) -> NSMenuItem {
        let item = NSMenuItem(title: "立即扫描", action: #selector(scanNowKeepOpen(_:)), keyEquivalent: "r")
        item.target = self
        item.keyEquivalentModifierMask = .command
        let height: CGFloat = 26
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let btn = NSButton(frame: NSRect(x: 14, y: 2, width: max(80, width - 70), height: 22))
        btn.title = "立即扫描"
        btn.bezelStyle = .recessed
        btn.isBordered = false
        btn.alignment = .left
        btn.font = NSFont.menuFont(ofSize: 13)
        btn.contentTintColor = .labelColor
        btn.target = self
        btn.action = #selector(scanNowKeepOpen(_:))
        btn.setButtonType(.momentaryChange)
        let shortcut = NSTextField(labelWithString: "⌘R")
        shortcut.font = NSFont.menuFont(ofSize: 13)
        shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right
        shortcut.isEditable = false
        shortcut.isBezeled = false
        shortcut.drawsBackground = false
        shortcut.frame = NSRect(x: width - 52, y: 3, width: 38, height: 20)
        box.addSubview(btn)
        box.addSubview(shortcut)
        item.view = box
        return item
    }

    func snapshot() -> (state: [String: Any]?, alive: Bool, paused: Bool, heartbeatAge: Double, badges: [[String: Any]], actions: [[String: Any]], backoff: [[String: Any]]) {
        let st = readJSON(statePath)
        let pid = (st?["pid"] as? Int) ?? -1
        let alive = pidAlive(pid)
        var age: Double = -1
        if let hb = st?["heartbeat"] as? String {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: hb) { age = Date().timeIntervalSince(d) }
        }
        return (st, alive, FileManager.default.fileExists(atPath: pausePath), age,
                (st?["badges"] as? [[String: Any]]) ?? [],
                (st?["actions"] as? [[String: Any]]) ?? [],
                (st?["backoff"] as? [[String: Any]]) ?? [])
    }

    func refresh() {
        let s = snapshot()
        let color: NSColor
        let blind = (s.state?["blind"] as? Bool) ?? false
        if !s.alive { color = .systemRed }
        else if blind { color = .systemYellow }
        else if s.paused { color = .systemGray }
        else if !s.badges.isEmpty { color = .systemOrange }
        else { color = .systemGreen }

        let count = s.badges.count
        if let btn = item.button {
            // Keep a vivid ● — SF Symbol alone is easy to miss in the menu bar.
            let mark = (!s.alive || s.heartbeatAge > 120) ? "●!" : "●"
            let title = NSMutableAttributedString(string: mark, attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 13, weight: .bold)
            ])
            if count > 0 {
                title.append(NSAttributedString(string: " \(count)", attributes: [
                    .foregroundColor: color,
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
                ]))
            }
            btn.image = nil
            btn.attributedTitle = title
            btn.toolTip = s.alive
                ? (count > 0 ? "ChatGPT助手 · \(count) 条待继续" : "ChatGPT助手 · 空闲")
                : "ChatGPT助手 · 未运行"
        }
        // Keep open menu fresh (scan results / heartbeat) without dismissing it.
        if menuIsOpen {
            let fp = menuFingerprint(from: s)
            if fp != lastMenuFingerprint {
                lastMenuFingerprint = fp
                menuNeedsUpdate(menu)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = snapshot()
        let cfg = readSettings()
        let maxH: Double = {
            if let d = cfg["maxRuntimeHours"] as? Double { return d }
            if let i = cfg["maxRuntimeHours"] as? Int { return Double(i) }
            return 0
        }()

        let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let bodyMed = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let cap = NSFont.systemFont(ofSize: 13, weight: .regular)
        let sectionFont = NSFont.systemFont(ofSize: 12, weight: .bold)
        // Vibrancy menus wash out .secondaryLabelColor — use fixed readable greys.
        let ink = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.95, alpha: 1)
                : NSColor(calibratedWhite: 0.12, alpha: 1)
        }
        let mute = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.78, alpha: 1)
                : NSColor(calibratedWhite: 0.35, alpha: 1)
        }

        func add(_ text: String, color: NSColor = ink, font: NSFont = bodyMed, enabled: Bool = false) {
            let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            i.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: color, .font: font
            ])
            i.isEnabled = enabled
            menu.addItem(i)
        }
        func section(_ text: String) {
            add(text, color: mute, font: sectionFont)
        }
        func meta(_ text: String, color: NSColor = mute) {
            add(text, color: color, font: cap)
        }
        func rich(_ parts: [(String, NSColor, NSFont)]) {
            let s = NSMutableAttributedString()
            for (t, c, f) in parts {
                s.append(NSAttributedString(string: t, attributes: [.foregroundColor: c, .font: f]))
            }
            let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            i.attributedTitle = s
            i.isEnabled = false
            menu.addItem(i)
        }

        // —— Status ——
        let poll = s.state?["pollSec"] as? Int ?? Int(cfg["pollSec"] as? Double ?? 8)
        let pid = s.state?["pid"] as? Int ?? -1
        if !s.alive {
            add("●  监控未运行", color: .systemRed)
            meta("   \(s.state == nil ? "找不到 state.json" : "助手进程已退出")")
        } else if s.heartbeatAge > 120 {
            add("●  心跳中断", color: .systemRed)
            meta("   已 \(Int(s.heartbeatAge)) 秒无更新")
        } else if s.paused {
            add("●  已暂停", color: .systemGray)
            meta("   轮询 \(ageText(s.heartbeatAge)) · PID \(pid)")
        } else {
            add("●  监控中", color: .systemGreen)
            meta("   轮询 \(ageText(s.heartbeatAge)) · 每 \(poll)s · PID \(pid)")
        }

        let pinnedPid: Int = {
            if let i = cfg["targetPid"] as? Int { return i }
            if let d = cfg["targetPid"] as? Double { return Int(d) }
            return 0
        }()
        let bundleId = (cfg["targetBundleId"] as? String) ?? "com.openai.codex"
        if let tgt = s.state?["target"] as? [String: Any] {
            let tName = (tgt["name"] as? String) ?? "ChatGPT"
            let tPid = (tgt["pid"] as? Int) ?? 0
            let tMode = (tgt["mode"] as? String) ?? ""
            meta("   \(tName) · \(tMode) · \(tPid)")
        } else if pinnedPid > 0 {
            meta("   锁定 PID \(pinnedPid)")
        }

        let permanent = (s.state?["permanent"] as? Bool) ?? (maxH <= 0)
        if !permanent {
            if let remain = s.state?["remainSec"] as? Int {
                meta("   最长 \(hoursLabel(maxH)) · 剩余 \(durationText(remain))")
            } else {
                meta("   最长 \(hoursLabel(maxH))")
            }
        }
        if FileManager.default.fileExists(atPath: scanNowPath) {
            meta("   立即扫描处理中…", color: .systemBlue)
        }
        if (s.state?["offscreen"] as? Bool) == true {
            meta("   ⚠ 窗口在其他 Space", color: .systemOrange)
        }
        if (s.state?["ax"] as? Bool) == false {
            let pane = AppPaths.accessibilityPrivacyName
            meta("   ⚠ 未开「\(pane)」", color: .systemYellow)
            meta("   系统设置 → 隐私与安全性 → \(pane) → 勾选 ChatGPT助手", color: .systemYellow)
            meta("   改完后退出应用再打开（macOS 27+ 已无「辅助功能」入口）", color: .systemYellow)
            let openAx = NSMenuItem(title: "打开「\(pane)」设置…", action: #selector(openAccessibilityPrivacy), keyEquivalent: "")
            openAx.target = self
            menu.addItem(openAx)
        }

        // Width: idle comfortable, pending a bit wider (scan-row view is the width rail).
        let hasWork = !s.badges.isEmpty || !s.backoff.isEmpty
        let titleChars = hasWork ? 24 : 20
        let actionLimit = hasWork ? 6 : 5
        let menuWidth: CGFloat = hasWork ? 380 : 300

        // —— Pending ——
        menu.addItem(.separator())
        let discoverMode = (s.state?["discoverMode"] as? String)
            ?? (cfg["discoverMode"] as? String)
            ?? "files"
        if s.badges.isEmpty {
            add("○  没有待继续", color: mute)
            meta("   \(discoverMode == "files" ? "运行记录无失败会话" : "无红色感叹号")")
        } else {
            section("待继续 · \(s.badges.count)")
            for b in s.badges {
                let t = clipTitle((b["title"] as? String) ?? "?", titleChars)
                let w = (b["waitingSec"] as? Int) ?? 0
                let err = (b["error"] as? String) ?? ""
                let when: String = {
                    if s.paused { return "已暂停" }
                    let n = badgeNextRunSec(b)
                    if n <= 0 { return "下一轮即执行" }
                    let hint = (b["nextRunHint"] as? String) ?? ""
                    if hint.contains("冷却") { return "冷却 \(durationText(n))" }
                    return "约 \(durationText(n)) 后"
                }()
                add("●  \(t)", color: ink)
                if !err.isEmpty {
                    rich([
                        ("   \(shortError(err))", .systemOrange, cap),
                        (" · \(when)", mute, cap)
                    ])
                    meta("   已等 \(durationText(w))")
                } else {
                    meta("   已等 \(durationText(w)) · \(when)")
                }
            }
        }

        if !s.backoff.isEmpty {
            menu.addItem(.separator())
            section("退避中 · \(s.backoff.count)")
            for b in s.backoff {
                let t = clipTitle((b["title"] as? String) ?? "?", titleChars)
                let r = (b["remainSec"] as? Int) ?? 0
                let why = (b["reason"] as? String) ?? ""
                add("●  \(t)", color: .systemYellow)
                meta(why.isEmpty
                     ? "   还差 \(durationText(r))"
                     : "   还差 \(durationText(r)) · \(clipTitle(why, hasWork ? 24 : 14))")
            }
        }

        // —— Recent actions ——
        menu.addItem(.separator())
        section("最近动作")
        if s.actions.isEmpty {
            meta("   暂无记录")
        } else {
            var shown = 0
            var lastKey = ""
            for a in s.actions.suffix(12).reversed() {
                if shown >= actionLimit { break }
                let clock = (a["clock"] as? String) ?? ""
                let title = (a["title"] as? String) ?? ""
                let result = (a["result"] as? String) ?? ""
                let detail = (a["detail"] as? String) ?? ""
                let method = actionMethod(from: detail)
                let key = "\(result)|\(title)|\(method ?? "")"
                if key == lastKey { continue }
                lastKey = key
                shown += 1

                let tagColor: NSColor
                let mark: String
                let tag: String
                switch result {
                case "sent":
                    tagColor = .systemGreen; mark = "✓"; tag = shortMethod(method ?? "已发送")
                case "failed":
                    tagColor = .systemRed; mark = "✗"; tag = "失败"
                case "skipped":
                    tagColor = .systemOrange; mark = "–"; tag = "跳过"
                case "backoff":
                    tagColor = .systemYellow; mark = "…"; tag = "退避"
                case "paused":
                    tagColor = .systemGray; mark = "‖"; tag = "暂停"
                case "scan":
                    tagColor = .systemBlue; mark = "↻"; tag = "扫描"
                default:
                    tagColor = .labelColor; mark = "·"; tag = result
                }

                // Two high-contrast rows (semantic greys wash out under menu vibrancy).
                let rawTitle = (title.isEmpty || title == "立即扫描") ? tag : title
                let displayTitle = clipTitle(rawTitle, titleChars)
                rich([
                    ("\(mark)  ", tagColor, bodyMed),
                    (displayTitle, ink, bodyMed)
                ])
                let tail: String = {
                    if result == "sent" { return "已确认" }
                    if !detail.isEmpty { return clipTitle(detail, 18) }
                    return ""
                }()
                rich([
                    ("   ", mute, cap),
                    (clock.isEmpty ? "" : "\(clock)  ", mute, mono),
                    (tag, tagColor, NSFont.systemFont(ofSize: 13, weight: .bold)),
                    (tail.isEmpty ? "" : " · \(tail)", mute, cap)
                ])
            }
        }

        menu.addItem(.separator())

        // Start / Stop monitoring
        if s.alive {
            menu.addItem(makeStayOpenScanItem(width: menuWidth))
            let stop = NSMenuItem(title: "关闭监控", action: #selector(stopWatch), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            let paused = FileManager.default.fileExists(atPath: pausePath)
            let toggle = NSMenuItem(title: paused ? "恢复自动发送" : "暂停自动发送", action: #selector(togglePause), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
        } else {
            let start = NSMenuItem(title: "开启监控", action: #selector(startWatch), keyEquivalent: "")
            start.target = self
            menu.addItem(start)
        }

        // Max runtime submenu
        let runtimeMenu = NSMenu(title: "最长运行时间")
        let choices: [(String, Double)] = [
            ("1 小时", 1),
            ("6 小时", 6),
            ("12 小时", 12),
            ("24 小时", 24),
            ("7 天", 168),
            ("永久", 0)
        ]
        for (label, hours) in choices {
            let mi = NSMenuItem(title: label, action: #selector(setRuntime(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = hours
            let selected = (hours <= 0 && maxH <= 0) || abs(hours - maxH) < 0.01
            mi.state = selected ? .on : .off
            runtimeMenu.addItem(mi)
        }
        let runtimeItem = NSMenuItem(title: "最长运行时间", action: nil, keyEquivalent: "")
        runtimeItem.submenu = runtimeMenu
        menu.addItem(runtimeItem)

        // Poll interval submenu
        let pollMenu = NSMenu(title: "轮询间隔")
        for sec in [5, 8, 15, 30, 60] {
            let mi = NSMenuItem(title: "\(sec) 秒", action: #selector(setPoll(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = sec
            let cur: Int = {
                if let i = cfg["pollSec"] as? Int { return i }
                if let d = cfg["pollSec"] as? Double { return Int(d) }
                return 8
            }()
            mi.state = (cur == sec) ? .on : .off
            pollMenu.addItem(mi)
        }
        let pollItem = NSMenuItem(title: "轮询间隔", action: nil, keyEquivalent: "")
        pollItem.submenu = pollMenu
        menu.addItem(pollItem)

        // Target app submenu: auto by bundle, or pin a running PID
        let targetMenu = NSMenu(title: "监控目标")
        let autoItem = NSMenuItem(title: "自动（\(bundleId)）", action: #selector(setTargetAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = pinnedPid <= 0 ? .on : .off
        targetMenu.addItem(autoItem)
        targetMenu.addItem(.separator())
        let apps = candidateApps()
        let prefer = apps.filter {
            let n = $0.name.lowercased()
            let b = $0.bundleId.lowercased()
            return b.contains("openai") || b.contains("codex") || n.contains("chatgpt") || n.contains("codex")
        }
        let rest = apps.filter { app in !prefer.contains(where: { $0.pid == app.pid }) }
        let listed = prefer + rest.prefix(24)
        if listed.isEmpty {
            let empty = NSMenuItem(title: "（没有前台应用）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            targetMenu.addItem(empty)
        } else {
            for app in listed {
                let mark = prefer.contains(where: { $0.pid == app.pid }) ? "★ " : ""
                let title = "\(mark)\(app.name) · \(app.pid)"
                let mi = NSMenuItem(title: title, action: #selector(setTargetPid(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ["pid": app.pid, "bundleId": app.bundleId] as [String: Any]
                mi.state = (pinnedPid == app.pid) ? .on : .off
                targetMenu.addItem(mi)
            }
        }
        let targetItem = NSMenuItem(title: "监控目标", action: nil, keyEquivalent: "")
        targetItem.submenu = targetMenu
        menu.addItem(targetItem)

        // How it works (SPEC summary)
        let adOn = (cfg["useAgentDesktop"] as? Bool) ?? true
        let howMenu = NSMenu(title: "实现原理")
        func how(_ text: String, color: NSColor = .secondaryLabelColor) {
            let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            i.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: NSFont.menuFont(ofSize: 12)
            ])
            i.isEnabled = false
            howMenu.addItem(i)
        }
        how("agent-desktop \(adOn ? "开" : "关")", color: .labelColor)
        howMenu.addItem(.separator())
        how("① 发现：运行记录 task_complete + error")
        how("② 命名：session_index.thread_name")
        how("③ 优先：codex queue --message continue")
        how("④ 兜底：短暂抢焦点 → 打开会话")
        how("   agent-desktop / AX set-value 发送")
        how("⑤ 确认：运行记录变为 running")
        how("   成功则写入 handled.txt")
        howMenu.addItem(.separator())
        how("立即扫描：清退避并马上重试")
        how("已去掉：盲发 / 无 AX 坐标注入")
        how("抢焦点仅在 queue 失败且卡住时")
        howMenu.addItem(.separator())
        let openSpec = NSMenuItem(title: "打开 SPEC.md…", action: #selector(openSpec), keyEquivalent: "")
        openSpec.target = self
        howMenu.addItem(openSpec)
        let howItem = NSMenuItem(title: "实现原理", action: nil, keyEquivalent: "")
        howItem.submenu = howMenu
        menu.addItem(howItem)

        let reveal = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let quit = NSMenuItem(title: "退出应用", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc func startWatch() {
        _ = AppPaths.launchDaemon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refresh() }
    }

    @objc func stopWatch() {
        FileManager.default.createFile(atPath: stopPath, contents: nil)
        // Fallback if STOP ignored
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 2.5)
            if let st = readJSON(statePath), let pid = st["pid"] as? Int, pidAlive(pid) {
                kill(pid_t(pid), SIGTERM)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    @objc func togglePause() {
        if FileManager.default.fileExists(atPath: pausePath) {
            try? FileManager.default.removeItem(atPath: pausePath)
        } else {
            FileManager.default.createFile(atPath: pausePath, contents: nil)
        }
        refresh()
    }

    @objc func scanNowKeepOpen(_ sender: Any?) {
        FileManager.default.createFile(atPath: scanNowPath, contents: nil)
        item.button?.toolTip = "已请求立即扫描…"
        lastMenuFingerprint = ""
        // Rebuild in place so「上次立即扫描 / 最近动作」能在菜单不关时更新。
        menuNeedsUpdate(menu)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.lastMenuFingerprint = ""
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.lastMenuFingerprint = ""
            self?.refresh()
        }
    }

    @objc func setRuntime(_ sender: NSMenuItem) {
        guard let hours = sender.representedObject as? Double else { return }
        saveSettings { $0["maxRuntimeHours"] = hours }
        // Running watch3 reloads settings each poll — no restart needed for the cap.
        refresh()
    }

    @objc func setPoll(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Int else { return }
        saveSettings { $0["pollSec"] = sec }
        refresh()
    }

    @objc func setDiscoverMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        saveSettings { $0["discoverMode"] = mode }
        refresh()
    }

    @objc func setTargetAuto() {
        saveSettings {
            $0["targetPid"] = 0
            let bid = ($0["targetBundleId"] as? String) ?? ""
            if bid.isEmpty { $0["targetBundleId"] = "com.openai.codex" }
        }
        refresh()
    }

    @objc func setTargetPid(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let pid = info["pid"] as? Int else { return }
        saveSettings {
            $0["targetPid"] = pid
            if let bid = info["bundleId"] as? String, !bid.isEmpty {
                $0["targetBundleId"] = bid
            }
        }
        refresh()
    }

    @objc func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: logPath)])
    }
    @objc func openSpec() {
        NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.specPath))
    }
    @objc func openAccessibilityPrivacy() {
        AppPaths.openAccessibilitySettings()
    }
    @objc func quit() {
        // 退出菜单栏时一并停掉守护进程，否则 .app 会被占用无法覆盖安装
        AppPaths.stopDaemon()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
// App 启动时自动拉起监控（若未运行且无 STOP）
DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
    if !FileManager.default.fileExists(atPath: AppPaths.stopPath) {
        let alive: Bool = {
            guard let st = readJSON(AppPaths.statePath), let pid = st["pid"] as? Int else { return false }
            return pidAlive(pid)
        }()
        if !alive { _ = AppPaths.launchDaemon() }
    }
}
withExtendedLifetime(controller) { app.run() }
