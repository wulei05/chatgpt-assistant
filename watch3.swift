import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import Vision

let base = AppPaths.dataDir
let logPath = AppPaths.logPath
let stopFile = AppPaths.stopPath
let scanNowFile = AppPaths.scanNowPath
let settingsFile = AppPaths.settingsPath
let handledFile = AppPaths.handledPath
let cliPath = AppPaths.macOSDir + "/cli"
let keyPath = AppPaths.macOSDir + "/key"
let sessionsRoot = NSString(string: "~/.codex/sessions").expandingTildeInPath
let indexFile = NSString(string: "~/.codex/session_index.jsonl").expandingTildeInPath

struct WatchSettings {
    /// ≤0 = permanent (until STOP / kill)
    var maxRuntimeHours: Double
    var pollSec: Double
    /// >0 = pin this PID; 0 = auto-discover via bundleId / ChatGPT path
    var targetPid: pid_t
    var targetBundleId: String
    /// hybrid | files | ui — see SPEC.md
    var discoverMode: String
    var useAgentDesktop: Bool
    var agentDesktopPath: String
    /// Fallback when UI/AX unavailable (other Space): `codex queue --thread … --message continue`
    var useCodexQueue: Bool
    var codexPath: String
}
func loadSettings() -> WatchSettings {
    var s = WatchSettings(maxRuntimeHours: 0, pollSec: 8, targetPid: 0, targetBundleId: "com.openai.codex",
                          discoverMode: "files", useAgentDesktop: true,
                          agentDesktopPath: "/opt/homebrew/bin/agent-desktop",
                          useCodexQueue: true, codexPath: "/opt/homebrew/bin/codex")
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: settingsFile)),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return s }
    if let h = o["maxRuntimeHours"] as? Double { s.maxRuntimeHours = h }
    else if let h = o["maxRuntimeHours"] as? Int { s.maxRuntimeHours = Double(h) }
    if let p = o["pollSec"] as? Double { s.pollSec = max(3, min(p, 120)) }
    else if let p = o["pollSec"] as? Int { s.pollSec = max(3, min(Double(p), 120)) }
    if let p = o["targetPid"] as? Int { s.targetPid = pid_t(p) }
    else if let p = o["targetPid"] as? Double { s.targetPid = pid_t(p) }
    if let b = o["targetBundleId"] as? String, !b.isEmpty { s.targetBundleId = b }
    if let m = o["discoverMode"] as? String {
        let v = m.lowercased()
        // OCR/UI 旁证已废弃：hybrid/ui 一律按 files（只信 rollout）
        if v == "files" || v == "hybrid" || v == "ui" { s.discoverMode = "files" }
    }
    if let u = o["useAgentDesktop"] as? Bool { s.useAgentDesktop = u }
    if let p = o["agentDesktopPath"] as? String, !p.isEmpty { s.agentDesktopPath = p }
    if let u = o["useCodexQueue"] as? Bool { s.useCodexQueue = u }
    if let p = o["codexPath"] as? String, !p.isEmpty { s.codexPath = p }
    return s
}
/// Shared mutable settings (used by helpers + runWatchDaemon).
var settings = loadSettings()
func pidAlive(_ pid: pid_t) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}
func appInfo(for pid: pid_t) -> (name: String, bundleId: String)? {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    return (app.localizedName ?? app.bundleURL?.lastPathComponent ?? "pid-\(pid)",
            app.bundleIdentifier ?? "")
}
/// Resolve monitoring target: pinned PID → bundle id → ChatGPT binary path.
func resolveTargetPid(_ settings: WatchSettings) -> (pid: pid_t, name: String, bundleId: String, mode: String)? {
    if settings.targetPid > 0 {
        if pidAlive(settings.targetPid) {
            let info = appInfo(for: settings.targetPid)
            return (settings.targetPid, info?.name ?? "pid-\(settings.targetPid)", info?.bundleId ?? settings.targetBundleId, "pid")
        }
        log("⚠ 设定的 targetPid=\(settings.targetPid) 已退出，回退自动发现")
    }
    let bid = settings.targetBundleId
    for app in NSWorkspace.shared.runningApplications {
        if let id = app.bundleIdentifier, id.caseInsensitiveCompare(bid) == .orderedSame {
            return (app.processIdentifier, app.localizedName ?? bid, id, "bundle")
        }
    }
    // Legacy ChatGPT path match
    let s = run("/usr/bin/pgrep", ["-f", "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"])
    if let p = s.split(separator: "\n").compactMap({ Int32($0.trimmingCharacters(in: .whitespaces)) }).first.map({ pid_t($0) }),
       pidAlive(p) {
        let info = appInfo(for: p)
        return (p, info?.name ?? "ChatGPT", info?.bundleId ?? "com.openai.codex", "pgrep")
    }
    return nil
}

func stamp() -> String { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f.string(from: Date()) }
func log(_ m: String) {
    let line = "[\(stamp())] \(m)"
    print(line); fflush(stdout)
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write((line+"\n").data(using:.utf8)!); try? h.close() }
    else { try? (line+"\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
}
/// Set by waitPoll when SCAN_NOW wakes the loop; cleared after the scan is reported.
var pendingManualScan = false
var lastManualScanAt: Date?
/// Sleep in short slices so SCAN_NOW / STOP can wake the poll loop immediately.
@discardableResult
func waitPoll(_ seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(max(0, seconds))
    while true {
        if FileManager.default.fileExists(atPath: stopFile) { return false }
        if FileManager.default.fileExists(atPath: scanNowFile) {
            try? FileManager.default.removeItem(atPath: scanNowFile)
            pendingManualScan = true
            log("▶ 手动立即扫描")
            return true
        }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { return false }
        Thread.sleep(forTimeInterval: min(0.25, left))
    }
}
/// GUI apps launched from Finder/Dock only get `/usr/bin:/bin:/usr/sbin:/sbin`.
/// Homebrew CLIs (codex → `#!/usr/bin/env node`) need `/opt/homebrew/bin` etc.
func cliEnvironment(extraBinDirs: [String] = []) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extras = extraBinDirs.filter { !$0.isEmpty } + [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        NSString(string: "~/.local/bin").expandingTildeInPath,
    ]
    let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    var seen = Set(existing)
    var prefix: [String] = []
    for d in extras where FileManager.default.fileExists(atPath: d) && !seen.contains(d) {
        prefix.append(d)
        seen.insert(d)
    }
    env["PATH"] = (prefix + existing).joined(separator: ":")
    return env
}
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = cliEnvironment(extraBinDirs: [URL(fileURLWithPath: path).deletingLastPathComponent().path])
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
func runCapture(_ path: String, _ args: [String], timeoutSec: Double = 45) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = cliEnvironment(extraBinDirs: [URL(fileURLWithPath: path).deletingLastPathComponent().path])
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch {
        return (-1, "", "无法启动 \(path): \(error.localizedDescription)")
    }
    let deadline = Date().addingTimeInterval(timeoutSec)
    while p.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if p.isRunning {
        p.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if p.isRunning { p.interrupt() }
        return (-1, "", "超时 \(Int(timeoutSec))s")
    }
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out, err)
}
/// Space-proof continue via Codex CLI. nil = queued ok; else short error.
func queueContinue(threadId: String, message: String = "continue") -> String? {
    let bin = settings.codexPath
    guard FileManager.default.isExecutableFile(atPath: bin) else {
        return "找不到 codex：\(bin)"
    }
    log("  · codex queue --thread \(threadId.prefix(12))… --message \(message)")
    let r = runCapture(bin, ["queue", "--thread", threadId, "--message", message], timeoutSec: 60)
    let joined = (r.out + "\n" + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
    if r.code == 0, joined.localizedCaseInsensitiveContains("queued") || joined.isEmpty {
        if !joined.isEmpty { log("  · codex queue: \(joined.prefix(120))") }
        return nil
    }
    let detail = joined.isEmpty ? "exit \(r.code)" : String(joined.prefix(160))
    return "codex queue 失败：\(detail)"
}
var preferredWin: Int = -1
var targetMeta: (pid: pid_t, name: String, bundleId: String, mode: String)?

func candidateWindows(_ pid: pid_t) -> [(Int, CGRect, Bool)] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [(Int, CGRect, Bool)] = []
    for w in list {
        guard let opid = w[kCGWindowOwnerPID as String] as? Int, opid == Int(pid) else { continue }
        guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
              let num = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
              let wd = b["Width"] as? CGFloat, let ht = b["Height"] as? CGFloat, wd > 400, ht > 300 else { continue }
        out.append((num, CGRect(x: x, y: y, width: wd, height: ht), (w[kCGWindowIsOnscreen as String] as? Int) == 1))
    }
    return out
}
func isSidebarTitleLine(_ l: Line) -> Bool {
    // Nested project threads sit ~x=180–300; keep band wide for indentation / resolution drift.
    // Y upper bound used to clip at 1680 and miss rows on taller captures.
    l.box.minX > 80 && l.box.minX < 480 && l.box.minY > 200 && l.box.minY < 2400 && l.box.width > 40
}
// Prefer cached window id; pick largest otherwise. No OCR.
func windowInfo(_ pid: pid_t, verifySidebar: Bool = false) -> (Int, CGRect, Bool)? {
    let cands = candidateWindows(pid)
    guard !cands.isEmpty else { return nil }
    if let p = cands.first(where: { $0.0 == preferredWin }) { return p }
    let fb = cands.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
    if let f = fb { preferredWin = f.0 }
    return fb
}
func capture(_ winID: Int) -> CGImage? {
    let tmp = base + "/_cap2.png"
    _ = run("/usr/sbin/screencapture", ["-x","-o","-l","\(winID)", tmp])
    guard let img = NSImage(contentsOfFile: tmp) else { return nil }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
}
struct Line { let text: String; let box: CGRect }
func ocr(_ img: CGImage, fast: Bool = false) -> [Line] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = fast ? .fast : .accurate
    req.recognitionLanguages = ["zh-Hans","en-US"]; req.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    let W = CGFloat(img.width), H = CGFloat(img.height)
    return (req.results ?? []).compactMap { o in
        guard let t = o.topCandidates(1).first?.string else { return nil }
        let b = o.boundingBox
        return Line(text: t, box: CGRect(x: b.minX*W, y: (1-b.maxY)*H, width: b.width*W, height: b.height*H))
    }
}
func ocrRegion(_ img: CGImage, _ rect: CGRect, fast: Bool = false) -> [Line] {
    let bounds = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    let clipped = rect.intersection(bounds)
    guard !clipped.isNull, clipped.width > 8, clipped.height > 8,
          let sub = img.cropping(to: clipped) else { return [] }
    return ocr(sub, fast: fast).map { Line(text: $0.text, box: $0.box.offsetBy(dx: clipped.minX, dy: clipped.minY)) }
}
let composerRect = CGRect(x: 900, y: 1640, width: 2000, height: 294)
let composerTextRect = CGRect(x: 1000, y: 1690, width: 1800, height: 110)
func sidebarRect(for img: CGImage) -> CGRect {
    let w = CGFloat(img.width), h = CGFloat(img.height)
    return CGRect(x: 0, y: 0, width: min(900, max(700, w * 0.26)), height: h)
}
func sidebarLines(_ img: CGImage, fast: Bool = false) -> [Line] {
    ocrRegion(img, sidebarRect(for: img), fast: fast)
}
/// Refine badge titles with accurate OCR (geometry stays from fast — accurate Y often drifts).
func refineBadgeTitles(_ badges: [Badge], accurate: [Line]) -> [Badge] {
    guard !badges.isEmpty, !accurate.isEmpty else { return badges }
    let titles = accurate.filter(isSidebarTitleLine)
    guard !titles.isEmpty else { return badges }
    return badges.map { b in
        guard let best = titles.min(by: { abs($0.box.midY - b.y) < abs($1.box.midY - b.y) }),
              abs(best.box.midY - b.y) < 45 else { return b }
        return Badge(title: best.text, y: b.y, source: b.source, errorMsg: b.errorMsg,
                     threadId: b.threadId, errorTurn: b.errorTurn, path: b.path)
    }
}
func composerHasContinue(_ img: CGImage) -> Bool {
    let t = ocrRegion(img, composerTextRect, fast: true).map { $0.text.lowercased() }.joined()
    return t.contains("continue") || t.contains("继续")
}
func isRunning(_ ls: [Line]) -> Bool {
    ls.contains { $0.box.minY > 1620 && $0.box.minY < 1720 && $0.text.contains("理") && $0.text.rangeOfCharacter(from: .decimalDigits) != nil }
}
// ---------- rollout 扫描 ----------
struct ThreadInfo {
    let id: String
    var name: String
    var running: Bool
    var errorTurn: String?
    var errorMsg: String?
    var mtime: Date
    var path: String
}
let turnRe = try! NSRegularExpression(pattern: "\"turn_id\":\"([0-9a-fA-F-]+)\"")
let errRe  = try! NSRegularExpression(pattern: "\"error\":\\{")
func firstMatch(_ re: NSRegularExpression, _ s: String) -> String? {
    guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}
func lastTurnState(_ path: String) -> (running: Bool, errorTurn: String?, errorMsg: String?) {
    guard let fh = FileHandle(forReadingAtPath: path) else { return (false,nil,nil) }
    defer { try? fh.close() }
    let size = fh.seekToEndOfFile()
    let chunk: UInt64 = 400_000
    let start = size > chunk ? size - chunk : 0
    fh.seek(toFileOffset: start)
    guard let data = try? fh.readToEnd() else { return (false,nil,nil) }
    // 注意：400KB 切割点可能落在多字节字符中间，不能用会失败的严格解码
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    var startedAt = -1, completedAt = -1
    var eTurn: String?; var eMsg: String?
    for (i, ln) in lines.enumerated() {
        guard ln.contains("\"task_started\"") || ln.contains("\"task_complete\"") else { continue }
        guard let d = try? JSONSerialization.jsonObject(with: Data(ln.utf8)) as? [String: Any],
              let pl = d["payload"] as? [String: Any], let ty = pl["type"] as? String else { continue }
        if ty == "task_started" { startedAt = i }
        else if ty == "task_complete" {
            completedAt = i
            if let err = pl["error"] as? [String: Any] {
                eTurn = pl["turn_id"] as? String
                eMsg = err["message"] as? String
            } else { eTurn = nil; eMsg = nil }
        }
    }
    let running = startedAt > completedAt
    return (running, running ? nil : eTurn, running ? nil : eMsg)
}
func scanThreads() -> [ThreadInfo] {
    var names: [String:String] = [:]
    if let txt = try? String(contentsOfFile: indexFile, encoding: .utf8) {
        for ln in txt.split(separator: "\n") {
            guard ln.contains("\"thread_name\""), let d = try? JSONSerialization.jsonObject(with: Data(ln.utf8)) as? [String:Any],
                  let id = d["id"] as? String, let nm = d["thread_name"] as? String else { continue }
            names[id] = nm
        }
    }
    var out: [ThreadInfo] = []
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: sessionsRoot) else { return out }
    let cutoff = Date().addingTimeInterval(-7200)
    for case let p as String in en where p.hasSuffix(".jsonl") {
        let full = sessionsRoot + "/" + p
        guard let attrs = try? fm.attributesOfItem(atPath: full),
              let m = attrs[.modificationDate] as? Date, m > cutoff else { continue }
        let fn = (p as NSString).lastPathComponent
        guard fn.hasPrefix("rollout-") else { continue }
        let parts = fn.replacingOccurrences(of: "rollout-", with: "").replacingOccurrences(of: ".jsonl", with: "").split(separator: "-")
        guard parts.count >= 8 else { continue }
        let id = parts.suffix(5).joined(separator: "-")
        let st = lastTurnState(full)
        out.append(ThreadInfo(id: id, name: names[id] ?? "", running: st.running, errorTurn: st.errorTurn, errorMsg: st.errorMsg, mtime: m, path: full))
    }
    return out
}
func handledKey(_ threadId: String, _ errorTurn: String) -> String { "\(threadId):\(errorTurn)" }
func fileWorkItems(_ threads: [ThreadInfo], handled: Set<String>) -> [Badge] {
    var out: [Badge] = []
    for t in threads {
        guard !t.running, let msg = t.errorMsg, !msg.isEmpty, !t.name.isEmpty else { continue }
        let turn = t.errorTurn ?? "unknown"
        if handled.contains(handledKey(t.id, turn)) { continue }
        out.append(Badge(title: t.name, y: -1, source: "file", errorMsg: msg, threadId: t.id, errorTurn: turn, path: t.path))
    }
    return out
}
func mergeWork(file: [Badge], ui: [Badge]) -> [Badge] {
    var byTitle: [String: Badge] = [:]
    func put(_ b: Badge) {
        let key = norm(b.title)
        guard !key.isEmpty else { return }
        guard let old = byTitle[key] else { byTitle[key] = b; return }
        let fileSide = b.source == "file" ? b : (old.source == "file" || old.source == "hybrid" ? old : nil)
        let uiSide = (b.source == "ui-red" || b.source == "ui-blue") ? b : ((old.source == "ui-red" || old.source == "ui-blue" || old.source == "hybrid") ? old : nil)
        if let f = fileSide, uiSide != nil {
            byTitle[key] = Badge(title: f.title, y: uiSide!.y >= 0 ? uiSide!.y : f.y, source: "hybrid",
                                 errorMsg: f.errorMsg, threadId: f.threadId, errorTurn: f.errorTurn, path: f.path)
        } else if b.title.count > old.title.count {
            byTitle[key] = Badge(title: b.title, y: old.y >= 0 ? old.y : b.y, source: old.source,
                                 errorMsg: old.errorMsg ?? b.errorMsg, threadId: old.threadId ?? b.threadId,
                                 errorTurn: old.errorTurn ?? b.errorTurn, path: old.path ?? b.path)
        }
    }
    for b in file { put(b) }
    for b in ui { put(b) }
    return Array(byTitle.values).sorted { $0.title < $1.title }
}
func waitRolloutStarted(path: String, timeout: Double = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let st = lastTurnState(path)
        if st.running { return true }
        Thread.sleep(forTimeInterval: 0.6)
    }
    return lastTurnState(path).running
}
// ---------- 模糊匹配 ----------
func norm(_ s: String) -> String {
    s.lowercased().filter { $0.isLetter || $0.isNumber }
}
func lcs(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty || b.isEmpty { return 0 }
    var prev = [Int](repeating: 0, count: b.count+1)
    for i in 1...a.count {
        var cur = [Int](repeating: 0, count: b.count+1)
        for j in 1...b.count {
            cur[j] = a[i-1] == b[j-1] ? prev[j-1]+1 : max(prev[j], cur[j-1])
        }
        prev = cur
    }
    return prev[b.count]
}
func similarity(_ x: String, _ y: String) -> Double {
    let a = Array(norm(x)), b = Array(norm(y))
    if a.isEmpty || b.isEmpty { return 0 }
    return Double(lcs(a,b)) / Double(max(a.count,b.count))
}
/// Recent Codex thread names from session_index — used to repair OCR-garbled sidebar titles.
var cachedThreadNames: [String] = []
var cachedThreadNamesAt: Date = .distantPast
func refreshThreadNames(force: Bool = false) {
    if !force, Date().timeIntervalSince(cachedThreadNamesAt) < 60, !cachedThreadNames.isEmpty { return }
    var names: [String] = []
    if let fh = FileHandle(forReadingAtPath: indexFile) {
        defer { try? fh.close() }
        let size = fh.seekToEndOfFile()
        let chunk: UInt64 = 800_000
        let start = size > chunk ? size - chunk : 0
        fh.seek(toFileOffset: start)
        if let data = try? fh.readToEnd() {
            let text = String(decoding: data, as: UTF8.self)
            for ln in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let d = try? JSONSerialization.jsonObject(with: Data(ln.utf8)) as? [String: Any],
                      let n = d["thread_name"] as? String, !n.isEmpty else { continue }
                names.append(n)
            }
        }
    }
    // Prefer fresher names; keep unique while preserving order.
    var seen = Set<String>()
    var uniq: [String] = []
    for n in names.reversed() {
        if seen.insert(n).inserted { uniq.append(n) }
        if uniq.count >= 400 { break }
    }
    cachedThreadNames = uniq
    cachedThreadNamesAt = Date()
}
/// Map OCR garbage (e.g. "SttkL OpenClaw ci *>.") onto the real sidebar title.
var loggedTitleFixes = Set<String>()
func canonicalizeTitle(_ raw: String) -> String {
    refreshThreadNames()
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return raw }
    var best: (Double, String)?
    for t in cachedThreadNames {
        let s = similarity(trimmed, t)
        if s >= 0.55, best == nil || s > best!.0 { best = (s, t) }
    }
    if let b = best, b.0 >= 0.55, b.1 != trimmed {
        let key = "\(trimmed)→\(b.1)"
        if loggedTitleFixes.insert(key).inserted {
            log("  · 标题校正「\(trimmed.prefix(28))」→「\(b.1.prefix(40))」(sim=\(String(format: "%.2f", b.0)))")
        }
        return b.1
    }
    return trimmed
}
// ---------- 侧边栏定位 ----------
func findRow(_ name: String, _ ls: [Line]) -> (CGFloat, CGFloat, Double)? {
    var best: (CGFloat, CGFloat, Double)?
    for l in ls {
        guard isSidebarTitleLine(l) else { continue }
        let s = similarity(name, l.text)
        if s > 0.62 && (best == nil || s > best!.2) { best = (l.box.minX, l.box.midY, s) }
    }
    return best
}
// ---------- CUA Accessibility layer (AX first, like Codex Sky) ----------
final class AxBridge {
    private(set) var trusted: Bool
    private var lastPromptAt: Date = .distantPast
    init() {
        // No prompt on init — LaunchServices + ad-hoc TCC often returns false for the first
        // few hundred ms even when Settings already shows ON. Prompting here races and sticks.
        trusted = AXIsProcessTrusted()
    }
    func refreshTrust(promptIfNeeded: Bool = false) {
        if promptIfNeeded, !AXIsProcessTrusted(), Date().timeIntervalSince(lastPromptAt) > 45 {
            trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            lastPromptAt = Date()
        } else {
            trusted = AXIsProcessTrusted()
        }
    }
    /// Retry briefly so a Settings-ON grant that hasn't attached yet is not reported as off.
    func settleTrust(attempts: Int = 6, interval: TimeInterval = 0.35) {
        for i in 0..<attempts {
            refreshTrust(promptIfNeeded: i == attempts - 1)
            if trusted { return }
            Thread.sleep(forTimeInterval: interval)
        }
    }
    private func str(_ el: AXUIElement, _ name: String) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }
    private func kids(_ el: AXUIElement) -> [AXUIElement] {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }
    private func role(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute as String) ?? "" }
    private func label(_ el: AXUIElement) -> String {
        for n in [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                  kAXValueAttribute as String, "AXLabel", kAXPlaceholderValueAttribute as String] {
            if let s = str(el, n), !s.isEmpty { return s }
        }
        return ""
    }
    private func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }
    private func press(_ el: AXUIElement) -> Bool {
        let a = actions(el)
        if a.contains(kAXPressAction as String) {
            return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
        }
        // Some rows only expose AXOpen / confirm.
        for name in ["AXOpen", kAXConfirmAction as String, "AXShowMenu"] {
            if a.contains(name), AXUIElementPerformAction(el, name as CFString) == .success { return true }
        }
        return false
    }
    private func setFocused(_ el: AXUIElement) -> Bool {
        let n = kAXFocusedAttribute as CFString
        return AXUIElementSetAttributeValue(el, n, kCFBooleanTrue) == .success
    }
    private func setValue(_ el: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }
    private func getValue(_ el: AXUIElement) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
    /// Read composer AXValue directly (no OCR).
    func composerText(pid: pid_t) -> String? {
        guard let box = findComposer(pid: pid) else { return nil }
        return getValue(box)
    }
    /// Quartz/CGWindow (top-left, Y down, points) → Cocoa/AX (bottom-left, Y up, points).
    func quartzToCocoa(_ p: CGPoint) -> CGPoint {
        // Must use NSScreen points — CGDisplayBounds is often pixel-backed on Retina and breaks Y.
        let h = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }
    func hitTest(pid: pid_t, quartzPoint: CGPoint) -> AXUIElement? {
        guard trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let c = quartzToCocoa(quartzPoint)
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app, Float(c.x), Float(c.y), &hit)
        return err == .success ? hit : nil
    }
    /// Walk AX tree for a pressable node whose label fuzzy-matches `title`.
    func findByTitle(pid: pid_t, title: String, limit: Int = 4000) -> AXUIElement? {
        guard trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var q: [(AXUIElement, Int)] = [(app, 0)]
        var seen = 0
        var best: (Double, AXUIElement)?
        while !q.isEmpty && seen < limit {
            let (el, d) = q.removeFirst(); seen += 1
            let t = label(el)
            if !t.isEmpty {
                let s = similarity(title, t)
                if s >= 0.62, (best == nil || s > best!.0) {
                    let a = actions(el)
                    let r = role(el)
                    let pressable = a.contains(kAXPressAction as String) || a.contains("AXOpen")
                        || r == "AXButton" || r == "AXLink" || r == "AXStaticText" || r == "AXRow" || r == "AXCell"
                    if pressable { best = (s, el) }
                }
            }
            if d < 16 {
                for c in kids(el).prefix(60) { q.append((c, d + 1)) }
            }
        }
        return best?.1
    }
    func findComposer(pid: pid_t, limit: Int = 5000) -> AXUIElement? {
        guard trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var q: [(AXUIElement, Int)] = [(app, 0)]
        var seen = 0
        var scored: [(Int, AXUIElement)] = []
        while !q.isEmpty && seen < limit {
            let (el, d) = q.removeFirst(); seen += 1
            let r = role(el)
            let t = label(el).lowercased()
            var ph = ""
            var pref: AnyObject?
            if AXUIElementCopyAttributeValue(el, "AXPlaceholderValue" as CFString, &pref) == .success,
               let s = pref as? String { ph = s.lowercased() }
            let editableRoles = ["AXTextArea", "AXTextField", "AXComboBox"]
            if editableRoles.contains(r) || (r == "AXGroup" && (t.contains("message") || ph.contains("codex") || ph.contains("message"))) {
                var score = 0
                if t.contains("codex") || ph.contains("codex") { score += 5 }
                if t.contains("message") || ph.contains("message") || ph.contains("继续") { score += 4 }
                if t.contains("continue") || t.contains("继续") { score += 3 }
                if r == "AXTextArea" { score += 2 }
                if t.isEmpty && ph.isEmpty { score += 1 }
                if score > 0 { scored.append((score, el)) }
            }
            if d < 18 {
                for c in kids(el).prefix(80) { q.append((c, d + 1)) }
            }
        }
        return scored.max(by: { $0.0 < $1.0 })?.1
    }
    /// Returns the AX label that was pressed (canonical UI title), or nil.
    @discardableResult
    func pressTitle(pid: pid_t, title: String) -> String? {
        guard let el = findByTitle(pid: pid, title: title) else { return nil }
        let lab = label(el)
        log("  · AXPress 标题匹配 \(lab.prefix(40))")
        return press(el) ? lab : nil
    }
    @discardableResult
    func pressAt(pid: pid_t, quartzPoint: CGPoint) -> Bool {
        guard let el = hitTest(pid: pid, quartzPoint: quartzPoint) else { return false }
        log("  · AX hit-test \(role(el)) \(label(el).prefix(30))")
        if press(el) { return true }
        return setFocused(el)
    }
    /// Set composer to continue via AX. Trusts AXSetValue success even when readback is empty/stale.
    func typeContinue(pid: pid_t) -> Bool {
        guard let box = findComposer(pid: pid) else { return false }
        if let cur = getValue(box), textLooksLikeContinue(cur) {
            log("  · AX 输入框已有 continue")
            return true
        }
        _ = setFocused(box)
        _ = setValue(box, "")
        Thread.sleep(forTimeInterval: 0.05)
        guard setValue(box, "continue") else { return false }
        let got = getValue(box) ?? ""
        if textLooksLikeContinue(got) {
            log("  · AXSetValue continue 确认")
        } else {
            // Readback often lags or stays empty; do not treat as failure (that caused re-paste loops).
            log("  · AXSetValue 已写入（读回「\(got.prefix(24))」，按成功处理）")
        }
        return true
    }
    func pressSendLike(pid: pid_t) -> Bool {
        // Do NOT match generic 「提交」— Codex UI has unrelated buttons like 「提交信息」.
        guard trusted else { return false }
        let app = AXUIElementCreateApplication(pid)
        var q: [AXUIElement] = [app]
        var seen = 0
        let allow = ["send message", "send", "发送", "发送消息"]
        let deny = ["提交信息", "commit", "查找", "search", "copy", "复制"]
        while !q.isEmpty && seen < 3000 {
            let el = q.removeFirst(); seen += 1
            let raw = label(el)
            let t = raw.lowercased()
            let r = role(el)
            if r == "AXButton" {
                if deny.contains(where: { t.contains($0) || raw.contains($0) }) {
                    q.append(contentsOf: kids(el).prefix(40)); continue
                }
                if allow.contains(where: { t == $0 || t.hasPrefix($0) }) {
                    if press(el) { log("  · AXPress send \(raw.prefix(24))"); return true }
                }
            }
            q.append(contentsOf: kids(el).prefix(40))
        }
        return false
    }
}
let axBridge = AxBridge()

// ---------- CUA-style PID input (no system cursor / no focus steal) ----------
// Mirrors Codex Computer Use: SLEventPostToPid + window-local stamp fields.
final class PidInput {
    private typealias PostToPID = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGFloat, CGFloat) -> Void
    private typealias SetIntegerField = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private let library: UnsafeMutableRawPointer?
    private let postToPID: PostToPID?
    private let setWindowLocation: SetWindowLocation?
    private let setIntegerField: SetIntegerField?
    init() {
        let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        library = lib
        func sym(_ n: String) -> UnsafeMutableRawPointer? {
            if let lib, let a = dlsym(lib, n) { return a }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), n)
        }
        postToPID = sym("SLEventPostToPid").map { unsafeBitCast($0, to: PostToPID.self) }
        setWindowLocation = sym("CGEventSetWindowLocation").map { unsafeBitCast($0, to: SetWindowLocation.self) }
        setIntegerField = sym("SLEventSetIntegerValueField").map { unsafeBitCast($0, to: SetIntegerField.self) }
    }
    deinit { if let library { dlclose(library) } }
    private func post(_ event: CGEvent, to pid: pid_t) {
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        if let postToPID { postToPID(pid, event) } else { event.postToPid(pid) }
    }
    private func stampWindow(_ event: CGEvent, pid: pid_t, windowID: UInt32, local: CGPoint) -> Bool {
        guard let setWindowLocation, let setIntegerField else { return false }
        setWindowLocation(event, local.x, local.y)
        setIntegerField(event, 40, Int64(pid))
        for f: UInt32 in [51, 91, 92] { setIntegerField(event, f, Int64(windowID)) }
        return true
    }
    private func stamp(_ event: CGEvent, field: UInt32, value: Int64) {
        setIntegerField?(event, field, value)
    }
    private func mouse(_ type: CGEventType, screen: CGPoint, local: CGPoint,
                       pid: pid_t, wid: Int, button: CGMouseButton = .left,
                       clickState: Int64 = 1, subtype: Int64 = 3, group: Int64,
                       number: Int64? = nil) -> CGEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let e = CGEvent(mouseEventSource: src, mouseType: type,
                              mouseCursorPosition: screen, mouseButton: button) else { return nil }
        e.flags = []
        guard stampWindow(e, pid: pid, windowID: UInt32(wid), local: local) else { return nil }
        stamp(e, field: 1, value: clickState)
        stamp(e, field: 3, value: Int64(button.rawValue))
        stamp(e, field: 7, value: subtype)
        stamp(e, field: 58, value: group)
        if let number { stamp(e, field: 0, value: number) }
        return e
    }
    /// Window-local click; does not move the real cursor or activate the app.
    func click(pid: pid_t, wid: Int, win: CGRect, localX: CGFloat, localY: CGFloat) -> Bool {
        let local = CGPoint(x: localX, y: localY)
        let screen = CGPoint(x: win.minX + localX, y: win.minY + localY)
        let group = Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
        guard let move = mouse(.mouseMoved, screen: screen, local: local, pid: pid, wid: wid,
                               clickState: 0, group: group, number: 2),
              let down = mouse(.leftMouseDown, screen: screen, local: local, pid: pid, wid: wid, group: group, number: 3),
              let up = mouse(.leftMouseUp, screen: screen, local: local, pid: pid, wid: wid, group: group, number: 3)
        else { return false }
        post(move, to: pid); Thread.sleep(forTimeInterval: 0.015)
        post(down, to: pid); Thread.sleep(forTimeInterval: 0.001)
        post(up, to: pid)
        return true
    }
    func scroll(pid: pid_t, wid: Int, win: CGRect, localX: CGFloat, localY: CGFloat, lines: Int32) -> Bool {
        let local = CGPoint(x: localX, y: localY)
        let screen = CGPoint(x: win.minX + localX, y: win.minY + localY)
        let group = Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
        guard let move = mouse(.mouseMoved, screen: screen, local: local, pid: pid, wid: wid,
                               clickState: 0, group: group),
              let src = CGEventSource(stateID: .hidSystemState),
              let wheel = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                                  wheel1: lines, wheel2: 0, wheel3: 0)
        else { return false }
        wheel.location = screen
        wheel.flags = []
        guard stampWindow(wheel, pid: pid, windowID: UInt32(wid), local: local) else { return false }
        post(move, to: pid); Thread.sleep(forTimeInterval: 0.012)
        post(wheel, to: pid); Thread.sleep(forTimeInterval: 0.030)
        return true
    }
    private func keyEvent(code: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return nil }
        e.flags = flags
        return e
    }
    /// Optional window stamp helps Electron accept keys while off-Space / unfocused.
    func key(_ code: CGKeyCode, pid: pid_t, flags: CGEventFlags = [],
             wid: Int? = nil, win: CGRect? = nil, localX: CGFloat? = nil, localY: CGFloat? = nil) {
        guard let down = keyEvent(code: code, down: true, flags: flags),
              let up = keyEvent(code: code, down: false, flags: flags) else { return }
        if let wid, let win, let localX, let localY {
            let local = CGPoint(x: localX, y: localY)
            _ = stampWindow(down, pid: pid, windowID: UInt32(wid), local: local)
            _ = stampWindow(up, pid: pid, windowID: UInt32(wid), local: local)
            down.location = CGPoint(x: win.minX + localX, y: win.minY + localY)
            up.location = down.location
        }
        post(down, to: pid); Thread.sleep(forTimeInterval: 0.008)
        post(up, to: pid)
    }
    func chord(key code: CGKeyCode, modifiers: [(CGKeyCode, CGEventFlags)], pid: pid_t) {
        var flags: CGEventFlags = []
        var downs: [CGEvent] = []; var ups: [CGEvent] = []
        for (mk, mf) in modifiers {
            flags.insert(mf)
            if let d = keyEvent(code: mk, down: true, flags: flags) { downs.append(d) }
            var released = flags; released.remove(mf)
            if let u = keyEvent(code: mk, down: false, flags: released) { ups.append(u) }
        }
        guard let kd = keyEvent(code: code, down: true, flags: flags),
              let ku = keyEvent(code: code, down: false, flags: flags) else { return }
        for d in downs { post(d, to: pid); Thread.sleep(forTimeInterval: 0.008) }
        post(kd, to: pid); Thread.sleep(forTimeInterval: 0.008)
        post(ku, to: pid)
        for u in ups.reversed() { post(u, to: pid); Thread.sleep(forTimeInterval: 0.008) }
    }
    /// Type ASCII/Unicode without touching the system clipboard.
    @discardableResult
    func typeText(_ text: String, pid: pid_t) -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        for scalar in text.unicodeScalars {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return false }
            var chars = Array(String(scalar).utf16)
            chars.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
            }
            post(down, to: pid); Thread.sleep(forTimeInterval: 0.012)
            post(up, to: pid); Thread.sleep(forTimeInterval: 0.012)
        }
        return true
    }
}
let pidInput = PidInput()

func scrollSidebar(pid: pid_t, wid: Int, win: CGRect, _ lines: Int32) {
    _ = pidInput.scroll(pid: pid, wid: wid, win: win, localX: 200, localY: 520, lines: lines)
    Thread.sleep(forTimeInterval: 0.5)
}
func clickImage(pid: pid_t, wid: Int, win: CGRect, _ imgX: CGFloat, _ imgY: CGFloat) {
    // Capture is retina (2x); convert image pixels → window-local points.
    _ = pidInput.click(pid: pid, wid: wid, win: win, localX: imgX / 2, localY: imgY / 2)
}
let titleRect = CGRect(x: 600, y: 0, width: 1500, height: 80)
func titleMatches(_ name: String, _ img: CGImage) -> Bool {
    ocrRegion(img, titleRect).contains { similarity(name, $0.text) > 0.6 }
}
func pbpasteData() -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
    let out = Pipe(); p.standardOutput = out
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}
func setClipboard(_ d: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let inp = Pipe(); p.standardInput = inp
    do { try p.run() } catch { return }
    inp.fileHandleForWriting.write(d)
    try? inp.fileHandleForWriting.close()
    p.waitUntilExit()
}
func saveClip() {
    if let d = pbpasteData() { try? d.write(to: URL(fileURLWithPath: base + "/clip.bak")) }
}
func restoreClip() {
    if let d = try? Data(contentsOf: URL(fileURLWithPath: base + "/clip.bak")) { setClipboard(d) }
}
func pasteText(_ s: String, pid: pid_t) {
    // Prefer Unicode key delivery (no clipboard / no AppKit pasteboard abort).
    if pidInput.typeText(s, pid: pid) { Thread.sleep(forTimeInterval: 0.3); return }
    // Fallback: clipboard + cmd+v
    saveClip()
    setClipboard(s.data(using: .utf8)!)
    pidInput.chord(key: 9, modifiers: [(55, .maskCommand)], pid: pid)
    Thread.sleep(forTimeInterval: 0.7)
    restoreClip()
}
func activateApp(_ pid: pid_t) -> Bool {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
    // osascript tends to switch to the app's Space; NSRunningApplication.activate often won't on macOS 14+.
    _ = run("/usr/bin/osascript", ["-e", "tell application id \"com.openai.codex\" to activate"])
    if let app = NSRunningApplication(processIdentifier: pid) {
        if #available(macOS 14.0, *) { app.activate() }
        else { app.activate(options: [.activateIgnoringOtherApps]) }
    }
    for _ in 1...25 {
        Thread.sleep(forTimeInterval: 0.12)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
    }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
}
/// Non-placeholder composer text worth sending (draft or our continue). nil = empty/ready.
func composerSendableText(_ txtRaw: String) -> String? {
    var txt = txtRaw
    for ph in ["和 Codex 一起工作", "和Codex一起工作", "Codex 一起工作", "Working with Codex",
               "Itl Codex", "Iti Codex", "with Codex", "Codex -"] {
        txt = txt.replacingOccurrences(of: ph, with: "", options: .caseInsensitive)
    }
    if similarity(txt, "和 Codex 一起工作") > 0.4 { txt = "" }
    var trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
    let meaningful = trimmed.filter { $0.isLetter || $0.isNumber || ($0 >= "\u{4e00}" && $0 <= "\u{9fff}") }
    if meaningful.count < 2 { trimmed = "" }
    let low = trimmed.lowercased()
    let placeholderNoise = trimmed.count < 24 && low.contains("codex")
    if trimmed.isEmpty || placeholderNoise { return nil }
    return String(trimmed.prefix(40))
}
func composerOCRJoined(_ img: CGImage) -> String {
    ocrRegion(img, composerTextRect, fast: true).map { $0.text }.joined()
}
func textLooksLikeContinue(_ s: String) -> Bool {
    let low = s.lowercased()
    return low.contains("continue") || low.contains("contin") || low.contains("继续")
}
func composerHasOurContinue(_ img: CGImage) -> Bool {
    textLooksLikeContinue(composerOCRJoined(img))
}
/// AX / agent-desktop only — never OCR.
func readComposerText(pid: pid_t, img: CGImage? = nil, appName: String = "ChatGPT") -> String? {
    if axBridge.trusted, let t = axBridge.composerText(pid: pid) { return t }
    if settings.useAgentDesktop, !agentDesktopDisabled,
       let t = agentDesktopComposerText(bin: settings.agentDesktopPath, appName: appName, pid: pid) {
        return t
    }
    return nil
}
func composerHasContinueNow(pid: pid_t, img: CGImage? = nil, appName: String = "ChatGPT") -> Bool {
    guard let t = readComposerText(pid: pid, appName: appName) else { return false }
    return textLooksLikeContinue(t)
}
func composerLooksClearedNow(pid: pid_t, img: CGImage? = nil, appName: String = "ChatGPT") -> Bool {
    guard let t = readComposerText(pid: pid, appName: appName) else { return false }
    return composerSendableText(t) == nil
}
func composerAXReady(pid: pid_t, appName: String = "ChatGPT") -> Bool {
    if axBridge.trusted, axBridge.findComposer(pid: pid) != nil { return true }
    if settings.useAgentDesktop, !agentDesktopDisabled,
       agentDesktopComposerRef(bin: settings.agentDesktopPath, appName: appName, pid: pid) != nil {
        return true
    }
    return false
}
/// Locate the light send disc in the composer (image pixels → window-local points).
func findSendButtonLocal(_ img: CGImage, win: CGRect) -> (CGFloat, CGFloat)? {
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let x0 = Int(Double(w) * 0.62), x1 = Int(Double(w) * 0.98)
    let y0 = Int(Double(h) * 0.86), y1 = Int(Double(h) * 0.99)
    var best: (Int, Int, Int)? // score, x, y
    var y = y0
    while y < y1 {
        var x = x0
        while x < x1 {
            let i = (y * w + x) * 4
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            let bri = r + g + b
            if bri > 520, abs(r - g) < 30, abs(g - b) < 30 {
                // sample a small neighborhood for disc-like brightness
                var n = 0, sumX = 0, sumY = 0
                for dy in -10...10 {
                    for dx in -10...10 {
                        let xx = x + dx, yy = y + dy
                        if xx < x0 || xx >= x1 || yy < y0 || yy >= y1 { continue }
                        let j = (yy * w + xx) * 4
                        let rr = Int(data[j]), gg = Int(data[j + 1]), bb = Int(data[j + 2])
                        if rr + gg + bb > 500 { n += 1; sumX += xx; sumY += yy }
                    }
                }
                if n > 80, best == nil || n > best!.0 {
                    best = (n, sumX / max(n, 1), sumY / max(n, 1))
                }
            }
            x += 4
        }
        y += 4
    }
    guard let b = best else { return nil }
    // retina capture is 2× window points
    let scale = CGFloat(w) / win.width
    let lx = CGFloat(b.1) / scale, ly = CGFloat(b.2) / scale
    return (lx, ly)
}

/// True when the failure is server-side capacity — UI continue cannot help and only stacks text.
func isServerBusyError(_ msg: String) -> Bool {
    let low = msg.lowercased()
    return low.contains("429") || low.contains("503") || low.contains("rate limit")
        || low.contains("too many") || low.contains("overloaded") || low.contains("capacity")
}

/// CUA tiers: write continue at most once → submit. Never activate / switch Space here.
/// On success `method` is a short tag for 最近动作（agent-desktop / AX / PostToPid …）.
func sendContinue(win: CGRect, wid: Int, name: String, pid: pid_t) -> (method: String?, error: String?) {
    guard let (fwid, freshWin, onscreen) = windowInfo(pid) else {
        log("  ✗ 找不到窗口，放弃 [\(name)]"); return (nil, "找不到窗口")
    }
    let win = freshWin
    if !onscreen {
        log("  · 窗口在外屏/其他 Space，后台发送（不切回）")
    }
    axBridge.refreshTrust()
    let lx = win.width * 0.563, ly = win.height * 0.91
    let capWid = fwid
    // Fallback ratios from calibrated external-display capture (send disc ≈ 0.73× / 0.977×).
    var sendX = win.width * 0.730, sendY = win.height * 0.977
    if let img0 = capture(capWid), let found = findSendButtonLocal(img0, win: win) {
        sendX = found.0; sendY = found.1
        log("  · 定位发送按钮 local=(\(Int(sendX)),\(Int(sendY)))")
    } else {
        log("  · 发送按钮用默认坐标 local=(\(Int(sendX)),\(Int(sendY)))")
    }
    let appName = targetMeta?.name.isEmpty == false ? targetMeta!.name : "ChatGPT"
    func clickSubmitOnce() {
        // Focus composer, then Return (window-stamped) + PostToPid click on send disc.
        _ = pidInput.click(pid: pid, wid: fwid, win: win, localX: lx, localY: ly)
        Thread.sleep(forTimeInterval: 0.08)
        pidInput.key(36, pid: pid, wid: fwid, win: win, localX: lx, localY: ly)
        Thread.sleep(forTimeInterval: 0.12)
        pidInput.key(36, pid: pid, flags: .maskCommand, wid: fwid, win: win, localX: lx, localY: ly)
        Thread.sleep(forTimeInterval: 0.1)
        _ = pidInput.click(pid: pid, wid: fwid, win: win, localX: sendX, localY: sendY)
    }
    /// Returns true if composer cleared, or if we cannot read it (rollout confirms later).
    func submitBackground(tag: String) -> Bool {
        clickSubmitOnce()
        var sawReadable = false
        for _ in 1...8 {
            Thread.sleep(forTimeInterval: 0.4)
            if let t = readComposerText(pid: pid, appName: appName) {
                sawReadable = true
                if composerSendableText(t) == nil {
                    log("  ✓ 已提交(\(tag)·后台)")
                    return true
                }
            }
        }
        if !sawReadable {
            // Unreadable after click — do not loop paste; let finishContinue wait on rollout.
            log("  · 提交后无法读回输入框（\(tag)），交由 rollout 确认")
            return true
        }
        return false
    }

    // Already has continue → submit only (never write again).
    if composerHasContinueNow(pid: pid, appName: appName) {
        let cur = readComposerText(pid: pid, appName: appName) ?? ""
        log("  · 输入框已有 continue，直接提交: \(cur.prefix(40))")
        for attempt in 1...3 {
            if submitBackground(tag: "已有·第\(attempt)轮") { return ("已有continue", nil) }
        }
        return (nil, "已有 continue 但提交失败")
    }

    // Draft already in the box → send it as-is (do not overwrite with continue).
    if let raw = readComposerText(pid: pid, appName: appName),
       let draft = composerSendableText(raw),
       !textLooksLikeContinue(raw) {
        log("  · 输入框已有草稿，直接发送: \(draft.prefix(28))")
        for attempt in 1...3 {
            if submitBackground(tag: "草稿·第\(attempt)轮") { return ("草稿直发", nil) }
            log("  … 草稿第 \(attempt) 轮未提交")
        }
        return (nil, "草稿提交失败")
    }

    // ---- Write continue at most once (AD → AX → PostToPid replace) ----
    var method: String?
    var wrote = false

    if settings.useAgentDesktop, !agentDesktopDisabled {
        log("  · CUA Tier0 agent-desktop set-value")
        if agentDesktopSetComposer("continue", bin: settings.agentDesktopPath, appName: appName, pid: pid) {
            wrote = true
            method = "agent-desktop"
        }
    }

    if !wrote {
        if axBridge.trusted {
            log("  · CUA Tier1 AX 输入")
            if axBridge.typeContinue(pid: pid) {
                wrote = true
                method = "AX"
            } else {
                log("  · AX 输入框未找到/SetValue 失败，降级")
            }
        } else {
            log("  · 无\(AppPaths.accessibilityPrivacyName)权限，跳过 AX")
        }
    }

    if !wrote {
        // One replace inject: Cmd+A then type — never append in a retry loop.
        log("  · CUA Tier2 PostToPid 输入一次（Cmd+A 覆盖）")
        _ = pidInput.click(pid: pid, wid: fwid, win: win, localX: lx, localY: ly)
        Thread.sleep(forTimeInterval: 0.2)
        pidInput.chord(key: 0, modifiers: [(55, .maskCommand)], pid: pid) // Cmd+A
        Thread.sleep(forTimeInterval: 0.05)
        pasteText("continue", pid: pid)
        Thread.sleep(forTimeInterval: 0.35)
        wrote = true
        method = "PostToPid"
    }

    Thread.sleep(forTimeInterval: 0.25)
    if let t = readComposerText(pid: pid, appName: appName) {
        if textLooksLikeContinue(t) {
            log("  · 写入后读回确认: \(t.prefix(40))")
        } else if composerSendableText(t) != nil {
            log("  · 写入后读回非 continue「\(t.prefix(40))」，仍尝试提交")
        }
    } else {
        log("  · 写入后读不到输入框，仍尝试提交（不重写）")
    }

    for attempt in 1...3 {
        if submitBackground(tag: "\(method ?? "UI")·第\(attempt)轮") {
            return (method, nil)
        }
        log("  … 第 \(attempt) 轮未提交")
    }
    if let t = readComposerText(pid: pid, appName: appName), textLooksLikeContinue(t) {
        return (nil, "已输入但提交失败")
    }
    return (nil, "已写入但提交失败")
}

/// Last-resort: bring ChatGPT to current Space / front so AX & agent-desktop work.
@discardableResult
func stealFocusBriefly(pid: pid_t, appName: String) -> Bool {
    log("  · 兜底：短暂抢焦点（可切 Space）")
    if settings.useAgentDesktop, !agentDesktopDisabled {
        var args = ["focus-window", "--app", appName, "--timeout-ms", "8000"]
        if let wid = agentDesktopWindowId(path: settings.agentDesktopPath, appName: appName, pid: pid) {
            args = ["focus-window", "--window-id", wid, "--timeout-ms", "8000"]
        }
        if let obj = agentDesktopJSON(settings.agentDesktopPath, args), (obj["ok"] as? Bool) == true {
            log("  · agent-desktop focus-window ok")
        } else {
            log("  · agent-desktop focus-window 未成功，改 activate")
        }
    }
    let ok = activateApp(pid)
    Thread.sleep(forTimeInterval: 0.7)
    axBridge.refreshTrust()
    if let (wid, _, on) = windowInfo(pid) {
        preferredWin = wid
        log("  · 抢焦点后 onscreen=\(on) wid=\(wid)")
    }
    return ok
}
// ---------- 已处理集合 ----------
func loadHandled() -> Set<String> {
    guard let t = try? String(contentsOfFile: handledFile, encoding: .utf8) else { return [] }
    return Set(t.split(separator: "\n").map(String.init))
}
func markHandled(_ key: String) {
    if let h = FileHandle(forWritingAtPath: handledFile) { h.seekToEndOfFile(); h.write((key+"\n").data(using:.utf8)!); try? h.close() }
    else { try? (key+"\n").write(toFile: handledFile, atomically: true, encoding: .utf8) }
}
// ---------- 红叹号检测 ----------
struct Badge {
    let title: String
    let y: CGFloat
    var source: String // file | ui-red | ui-blue | hybrid
    var errorMsg: String?
    var threadId: String?
    var errorTurn: String?
    var path: String?
    init(title: String, y: CGFloat, source: String = "ui-red", errorMsg: String? = nil,
         threadId: String? = nil, errorTurn: String? = nil, path: String? = nil) {
        self.title = title; self.y = y; self.source = source
        self.errorMsg = errorMsg; self.threadId = threadId; self.errorTurn = errorTurn; self.path = path
    }
}
enum BadgeKind { case red, blue }
func badgeRows(_ img: CGImage, _ kind: BadgeKind, lines: [Line]) -> [Badge] {
    let w = img.width, h = img.height
    // Sample every 2px — badge blobs are large enough; full scan was a major CPU sink.
    let step = 2
    var data = [UInt8](repeating: 0, count: w*h*4)
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    func count(_ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int) -> Int {
        var n = 0
        var yy = max(0,y0)
        while yy < min(h,y1) {
            var xx = max(0,x0)
            while xx < min(w,x1) {
                let i = (yy*w + xx)*4
                let r = Int(data[i]), g = Int(data[i+1]), b = Int(data[i+2])
                switch kind {
                case .red:  if r > 150 && r - g > 60 && r - b > 60 { n += 1 }
                case .blue: if b > 140 && b - r > 55 && b - g > 25 { n += 1 }
                }
                xx += step
            }
            yy += step
        }
        return n
    }
    // step=2 samples ~1/4 pixels; threshold kept low (red ⓘ / ① icons are small).
    let need = 2
    var out: [Badge] = []
    let titles = lines.filter(isSidebarTitleLine)
    for l in titles {
        let cy = Int(l.box.midY)
        // Badge column ~640px in 2x capture; keep a wide band.
        let redish = count(cy - 26, cy + 26, 560, 780) >= need
        // OCR sometimes reads the red mark as ① / ! near the same row.
        let glyph = lines.contains {
            abs($0.box.midY - l.box.midY) < 22 && $0.box.minX > 560 && $0.box.minX < 780
            && ($0.text.contains("①") || $0.text.contains("!") || $0.text.contains("ⓘ") || $0.text == "i")
        }
        if kind == .red && (redish || glyph) {
            out.append(Badge(title: l.text, y: l.box.midY, source: "ui-red"))
        } else if kind == .blue && count(cy - 26, cy + 26, 560, 780) >= need {
            out.append(Badge(title: l.text, y: l.box.midY, source: "ui-blue"))
        }
    }
    var uniq: [Badge] = []
    for b in out.sorted(by: { $0.y < $1.y }) {
        if let idx = uniq.firstIndex(where: { abs($0.y - b.y) < 18 }) {
            if b.title.count > uniq[idx].title.count { uniq[idx] = b }
        } else { uniq.append(b) }
    }
    return uniq
}
func redBadgeRows(_ img: CGImage, lines: [Line]) -> [Badge] { badgeRows(img, .red, lines: lines) }
func blueBadgeRows(_ img: CGImage, lines: [Line]) -> [Badge] { badgeRows(img, .blue, lines: lines) }

// 蓝点=未读，会盖住红叹号。用 rollout 判定该会话上一轮是否真的报错。
func threadErrorFor(_ title: String, _ threads: [ThreadInfo]) -> String? {
    var best: (Double, ThreadInfo)?
    var second: Double = 0
    for t in threads where !t.name.isEmpty {
        let s = similarity(title, t.name)
        if best == nil || s > best!.0 {
            if let b = best { second = max(second, b.0) }
            best = (s, t)
        } else if s > second { second = s }
    }
    guard let b = best, b.0 >= 0.6 else { return nil }
    if second >= 0.6 && b.0 - second < 0.03 { return nil }   // 两条标题太接近，别猜
    guard !b.1.running, b.1.errorTurn != nil else { return nil }
    return b.1.errorMsg ?? "error"
}
func waitComposerAX(pid: pid_t, appName: String, secs: Int) -> Bool {
    for i in 0..<max(1, secs) {
        if i > 0 { Thread.sleep(forTimeInterval: 0.35) }
        if composerAXReady(pid: pid, appName: appName) { return true }
    }
    return false
}
// ---------- agent-desktop (AX refs; see SPEC.md) ----------
var agentDesktopDisabled = false
var agentDesktopDisabledReason = ""
func agentDesktopRaw(_ path: String, _ args: [String]) -> String {
    run(path, args)
}
func agentDesktopJSON(_ path: String, _ args: [String]) -> [String: Any]? {
    let out = agentDesktopRaw(path, args)
    guard let i = out.firstIndex(of: "{"),
          let obj = try? JSONSerialization.jsonObject(with: Data(out[i...].utf8)) as? [String: Any] else { return nil }
    return obj
}
/// agent-desktop `find --first` returns `data.match`; without --first returns `data.matches`.
func agentDesktopMatchRows(_ obj: [String: Any]) -> [[String: Any]] {
    guard (obj["ok"] as? Bool) == true else { return [] }
    if let data = obj["data"] as? [String: Any] {
        if let arr = data["matches"] as? [[String: Any]] { return arr }
        if let one = data["match"] as? [String: Any] { return [one] }
    }
    if let arr = obj["data"] as? [[String: Any]] { return arr }
    return []
}
func agentDesktopWindows(path: String, appName: String) -> [[String: Any]] {
    guard let obj = agentDesktopJSON(path, ["list-windows", "--app", appName]),
          (obj["ok"] as? Bool) == true else { return [] }
    if let arr = obj["data"] as? [[String: Any]] { return arr }
    return []
}
func agentDesktopWindowId(path: String, appName: String, pid: pid_t) -> String? {
    let arr = agentDesktopWindows(path: path, appName: appName)
    let scored: [(Int, String)] = arr.compactMap { w in
        guard let id = w["id"] as? String else { return nil }
        let title = (w["title"] as? String) ?? ""
        if title.localizedCaseInsensitiveContains("Computer Use") { return nil }
        let wpid = (w["pid"] as? Int).map { pid_t($0) } ?? -1
        var score = 0
        if wpid == pid { score += 100 }
        if (w["accessible"] as? Bool) == true { score += 10 }
        if (w["visible"] as? Bool) == true { score += 5 }
        // Prefer accessible even if off-primary-display (y negative still ok).
        if let b = w["bounds"] as? [String: Any],
           let wd = b["width"] as? Double, let ht = b["height"] as? Double {
            score += Int(min(wd * ht / 10000.0, 50))
        }
        return (score, id)
    }
    return scored.max(by: { $0.0 < $1.0 })?.1
}
func agentDesktopCurrentTitle(path: String, appName: String, pid: pid_t) -> String? {
    let arr = agentDesktopWindows(path: path, appName: appName)
    let main = arr.filter {
        let t = ($0["title"] as? String) ?? ""
        return !t.localizedCaseInsensitiveContains("Computer Use")
            && (($0["pid"] as? Int).map { pid_t($0) } ?? -1) == pid
    }
    return main.first?["title"] as? String ?? arr.first?["title"] as? String
}
func cgWindowTitle(_ windowId: Int) -> String? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowId)) as? [[String: Any]],
          let w = list.first else {
        // Fallback: scan all
        guard let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return all.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowId })?[kCGWindowName as String] as? String
    }
    return w[kCGWindowName as String] as? String
}
func titleLooksOpen(_ got: String?, _ wantTitles: [String]) -> Bool {
    guard let got = got, !got.isEmpty else { return false }
    return wantTitles.contains { similarity($0, got) > 0.62 }
}
/// Click sidebar session by formal title. nil = opened/already there; else short fail reason.
func agentDesktopOpenTitle(_ title: String, pid: pid_t, appName: String, bin: String) -> String? {
    if agentDesktopDisabled {
        return agentDesktopDisabledReason.isEmpty ? "agent-desktop已禁用" : agentDesktopDisabledReason
    }
    if !FileManager.default.isExecutableFile(atPath: bin) {
        agentDesktopDisabled = true
        agentDesktopDisabledReason = "找不到 \(bin)"
        log("⚠ agent-desktop 不可用：\(agentDesktopDisabledReason)，本进程改用 AX")
        return agentDesktopDisabledReason
    }
    // Already on this session — no click needed.
    if let cur = agentDesktopCurrentTitle(path: bin, appName: appName, pid: pid),
       similarity(cur, title) > 0.72 {
        log("  · agent-desktop 窗口已是「\(cur.prefix(32))」")
        return nil
    }
    guard let wid = agentDesktopWindowId(path: bin, appName: appName, pid: pid) else {
        log("  · agent-desktop 无可用窗口")
        return "agent-desktop无可用窗口"
    }
    // Prefer exact button name; then fuzzy text match.
    let attempts: [[String]] = [
        ["find", "--window-id", wid, "--name", title, "--role", "button", "--exact", "--first", "--timeout-ms", "12000"],
        ["find", "--window-id", wid, "--name", title, "--role", "button", "--first", "--timeout-ms", "12000"],
        ["find", "--window-id", wid, "--text", title, "--role", "button", "--first", "--timeout-ms", "12000"]
    ]
    var ref: String?
    for args in attempts {
        guard let obj = agentDesktopJSON(bin, args) else { continue }
        if let r = agentDesktopMatchRows(obj).first?["ref_id"] as? String, !r.isEmpty {
            ref = r; break
        }
    }
    guard let refId = ref else {
        log("  · agent-desktop 找不到按钮「\(title.prefix(32))」")
        return "侧栏找不到「\(String(title.prefix(24)))」"
    }
    guard let clk = agentDesktopJSON(bin, ["click", refId, "--timeout-ms", "8000"]),
          (clk["ok"] as? Bool) == true else {
        log("  · agent-desktop click 失败 \(refId)")
        return "agent-desktop点击失败"
    }
    log("  · agent-desktop click \(title.prefix(40))")
    return nil
}
func agentDesktopComposerRef(bin: String, appName: String, pid: pid_t) -> (windowId: String, ref: String, value: String)? {
    if agentDesktopDisabled || !FileManager.default.isExecutableFile(atPath: bin) { return nil }
    guard let wid = agentDesktopWindowId(path: bin, appName: appName, pid: pid) else { return nil }
    let attempts: [[String]] = [
        ["find", "--window-id", wid, "--role", "textfield", "--first", "--timeout-ms", "8000"],
        ["find", "--window-id", wid, "--role", "textarea", "--first", "--timeout-ms", "8000"]
    ]
    for args in attempts {
        guard let obj = agentDesktopJSON(bin, args),
              let first = agentDesktopMatchRows(obj).first,
              let ref = first["ref_id"] as? String, !ref.isEmpty else { continue }
        let val = (first["value"] as? String) ?? ""
        return (wid, ref, val)
    }
    return nil
}
func agentDesktopComposerText(bin: String, appName: String, pid: pid_t) -> String? {
    agentDesktopComposerRef(bin: bin, appName: appName, pid: pid)?.value
}
@discardableResult
func agentDesktopSetComposer(_ text: String, bin: String, appName: String, pid: pid_t) -> Bool {
    guard let info = agentDesktopComposerRef(bin: bin, appName: appName, pid: pid) else { return false }
    if textLooksLikeContinue(info.value) && textLooksLikeContinue(text) {
        log("  · agent-desktop 输入框已有 continue")
        return true
    }
    guard let obj = agentDesktopJSON(bin, ["set-value", info.ref, text, "--timeout-ms", "8000"]),
          (obj["ok"] as? Bool) == true else {
        log("  · agent-desktop set-value 失败")
        return false
    }
    // Re-read to confirm (avoid OCR).
    if let again = agentDesktopComposerText(bin: bin, appName: appName, pid: pid), textLooksLikeContinue(again) {
        log("  · agent-desktop set-value continue 确认")
        return true
    }
    // set-value reported ok; trust it if we asked for continue
    if textLooksLikeContinue(text) {
        log("  · agent-desktop set-value 已调用")
        return true
    }
    return false
}

func acceptOpen(_ wid: Int, _ win: CGRect, pid: pid_t, appName: String, titles: [String], why: String) -> (Int, CGRect, [Line])? {
    let cg = cgWindowTitle(wid)
    let ad = settings.useAgentDesktop
        ? agentDesktopCurrentTitle(path: settings.agentDesktopPath, appName: appName, pid: pid)
        : nil
    if titleLooksOpen(cg, titles) || titleLooksOpen(ad, titles) {
        log("  · \(why)，窗口标题已是目标")
        _ = waitComposerAX(pid: pid, appName: appName, secs: 4)
        return (wid, win, [])
    }
    // 操作已发出：等 AX 输入框出现即视为打开
    if waitComposerAX(pid: pid, appName: appName, secs: 5) {
        log("  · \(why)，输入框 AX 已就绪")
        return (wid, win, [])
    }
    // 仍信任点击结果：外屏标题刷新可能滞后
        log("  · \(why)，信任切换")
        return (wid, win, [])
}
/// Open session. On failure `ok` is nil and `fail` holds the concrete reason for menu/backoff.
func ensureOpen(_ title: String, pid: pid_t, appName: String = "ChatGPT") -> (ok: (Int, CGRect, [Line])?, fail: String?) {
    let want = canonicalizeTitle(title)
    guard let (wid, win, onscreen) = windowInfo(pid) else {
        return (nil, "找不到 ChatGPT 窗口")
    }
    var hints: [String] = []
    if !onscreen {
        hints.append("其他Space")
        log("  · ensureOpen: 外屏/其他 Space，后台切会话（不拉回）")
    }
    axBridge.refreshTrust()
    var verifyTitles = [want]
    if want != title { verifyTitles.append(title) }

    // Already on this session (window title from CG / agent-desktop).
    if titleLooksOpen(cgWindowTitle(wid), verifyTitles)
        || titleLooksOpen(agentDesktopCurrentTitle(path: settings.agentDesktopPath, appName: appName, pid: pid), verifyTitles) {
        log("  · 已在目标会话「\(want.prefix(32))」")
        _ = waitComposerAX(pid: pid, appName: appName, secs: 3)
        return ((wid, win, []), nil)
    }

    // Tier0: agent-desktop
    if settings.useAgentDesktop {
        if let adFail = agentDesktopOpenTitle(want, pid: pid, appName: appName, bin: settings.agentDesktopPath) {
            hints.append(adFail)
        } else {
            Thread.sleep(forTimeInterval: 0.45)
            if let opened = acceptOpen(wid, win, pid: pid, appName: appName, titles: verifyTitles, why: "agent-desktop") {
                return (opened, nil)
            }
            hints.append("agent-desktop切换未确认")
        }
    }

    // Tier1: AXPress by title
    if !axBridge.trusted {
        hints.append("AX未授权")
    } else if let axLabel = axBridge.pressTitle(pid: pid, title: want) {
        Thread.sleep(forTimeInterval: 0.45)
        verifyTitles.insert(axLabel, at: 0)
        if let opened = acceptOpen(wid, win, pid: pid, appName: appName, titles: verifyTitles, why: "AXPress") {
            return (opened, nil)
        }
        hints.append("AXPress未确认")
    } else {
        hints.append("AX找不到「\(String(want.prefix(24)))」")
    }

    let why = hints.isEmpty
        ? "打不开会话"
        : "打不开会话 · " + hints.joined(separator: " · ")
    log("  · 无法打开会话（\(why)）")
    return (nil, why)
}
if CommandLine.arguments.contains("--scan-badges") {
    print("OCR_DISABLED: use discoverMode=files / rollout errors instead")
    exit(0)
}
// ---------- main ----------
func runWatchDaemon() {
    let stateFile = AppPaths.statePath
    let pauseFile = AppPaths.pausePath
    // Keep AppKit services alive for Vision/NSImage without becoming a dock app.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    try? FileManager.default.removeItem(atPath: stopFile)
    try? FileManager.default.removeItem(atPath: scanNowFile)
    axBridge.settleTrust()
    settings = loadSettings()
    let startDate = Date()
    let iso = ISO8601DateFormatter()
    let runtimeDesc = settings.maxRuntimeHours <= 0 ? "永久" : "\(settings.maxRuntimeHours) 小时"
    let targetHint: String = {
        if settings.targetPid > 0 { return "targetPid=\(settings.targetPid)" }
        return "bundle=\(settings.targetBundleId)"
    }()
    log("=== ChatGPT助手 启动 pid=\(ProcessInfo.processInfo.processIdentifier) AX=\(axBridge.trusted ? "on" : "off") 最长=\(runtimeDesc) 轮询=\(Int(settings.pollSec))s \(targetHint) agent-desktop=\(settings.useAgentDesktop ? "on" : "off") codex-queue=\(settings.useCodexQueue ? "on" : "off") ===")
    if !axBridge.trusted {
        log("⚠ 系统 API 仍返回未授权「\(AppPaths.accessibilityPrivacyName)」（设置开关开着也可能）：列表删除 ChatGPT助手 → 再添加 → 完全退出应用再开")
    }
    var lastBadgeTitles = ""
    var lastBadges: [Badge] = []
    var lastSendAt: [String: Date] = [:]
    /// title → `threadId:errorTurn` that was successfully continued; used to tell real false-success from a fresh 429.
    var lastSentKey: [String: String] = [:]
    var lastAttemptAt: [String: Date] = [:]
    var quickFails: [String: Int] = [:]
    var lastFailReason: [String: String] = [:]
    var lastBackoffNoteLeft: [String: Int] = [:]
    var badgeFirstSeen: [String: Date] = [:]
    var recentActions: [[String: String]] = []

    func clockString() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }
    func note(_ title: String, _ result: String, _ detail: String = "") {
        recentActions.append(["ts": iso.string(from: Date()), "clock": clockString(),
                              "title": title, "result": result, "detail": detail])
        if recentActions.count > 25 { recentActions.removeFirst(recentActions.count - 25) }
    }
    var isBlind = false
    var isOffscreen = false
    func writeState(badges: [Badge], lastPoll: Date) {
        let waits: [Double] = [0, 90, 180, 300, 600]
        func nextRunInfo(title: String) -> (sec: Int, hint: String) {
            var sec = 0
            var hint = ""
            if let sentAt = lastSendAt[title] {
                let cool = 40 - lastPoll.timeIntervalSince(sentAt)
                if cool > 0 {
                    sec = max(sec, Int(ceil(cool)))
                    hint = "刚发送过，冷却中"
                }
            }
            let fails = quickFails[title] ?? 0
            if fails > 0 {
                let wait = waits[min(fails, waits.count - 1)]
                let since = lastPoll.timeIntervalSince(lastAttemptAt[title] ?? lastSendAt[title] ?? .distantPast)
                let left = wait - since
                if left > 0 {
                    sec = max(sec, Int(ceil(left)))
                    hint = lastFailReason[title] ?? "退避中"
                }
            }
            return (sec, hint)
        }
        var badgeArr: [[String: Any]] = []
        for b in badges {
            let first = badgeFirstSeen[b.title] ?? lastPoll
            let next = nextRunInfo(title: b.title)
            var row: [String: Any] = ["title": b.title,
                                      "source": b.source,
                                      "firstSeen": iso.string(from: first),
                                      "waitingSec": Int(lastPoll.timeIntervalSince(first)),
                                      "nextRunSec": next.sec,
                                      "nextRunAt": iso.string(from: lastPoll.addingTimeInterval(Double(next.sec)))]
            if !next.hint.isEmpty { row["nextRunHint"] = next.hint }
            if let e = b.errorMsg, !e.isEmpty { row["error"] = String(e.prefix(120)) }
            if let id = b.threadId { row["threadId"] = id }
            badgeArr.append(row)
        }
        var backoffArr: [[String: Any]] = []
        for (t, n) in quickFails where n > 0 {
            let since = lastPoll.timeIntervalSince(lastAttemptAt[t] ?? lastSendAt[t] ?? .distantPast)
            let w = waits[min(n, waits.count - 1)]
            var row: [String: Any] = ["title": t, "count": n, "remainSec": max(0, Int(w - since))]
            if let why = lastFailReason[t], !why.isEmpty { row["reason"] = why }
            backoffArr.append(row)
        }
        let elapsed = lastPoll.timeIntervalSince(startDate)
        let permanent = settings.maxRuntimeHours <= 0
        let limitSec = permanent ? 0.0 : settings.maxRuntimeHours * 3600
        var remain: Any = NSNull()
        if !permanent { remain = max(0, Int(limitSec - elapsed)) }
        var targetObj: [String: Any] = [
            "mode": targetMeta?.mode ?? "none",
            "pid": Int(targetMeta?.pid ?? 0),
            "name": targetMeta?.name ?? "",
            "bundleId": targetMeta?.bundleId ?? settings.targetBundleId,
            "pinnedPid": Int(settings.targetPid)
        ]
        if preferredWin > 0 { targetObj["windowId"] = preferredWin }
        let obj: [String: Any] = [
            "pid": Int(getpid()),
            "startedAt": iso.string(from: startDate),
            "heartbeat": iso.string(from: lastPoll),
            "pollSec": settings.pollSec,
            "discoverMode": settings.discoverMode,
            "paused": FileManager.default.fileExists(atPath: pauseFile),
            "blind": isBlind,
            "offscreen": isOffscreen,
            "ax": axBridge.trusted,
            "permanent": permanent,
            "maxRuntimeHours": settings.maxRuntimeHours,
            "remainSec": remain,
            "target": targetObj,
            "badges": badgeArr,
            "actions": recentActions,
            "backoff": backoffArr,
            "manualScanAt": lastManualScanAt.map { iso.string(from: $0) } as Any? ?? NSNull(),
            "version": 1
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: stateFile))
        }
    }

    // 立刻写心跳，避免首轮扫描时菜单栏仍显示「监控未运行」
    writeState(badges: [], lastPoll: startDate)

    while true {
        axBridge.refreshTrust(promptIfNeeded: true)
        settings = loadSettings()
        if settings.maxRuntimeHours > 0 {
            let limit = settings.maxRuntimeHours * 3600
            let elapsed = Date().timeIntervalSince(startDate)
            if elapsed >= limit {
                log("达到设定最长运行时间 \(settings.maxRuntimeHours) 小时，退出")
                break
            }
        }
        if FileManager.default.fileExists(atPath: stopFile) { log("检测到 STOP，退出"); break }
        let now = Date()
        let paused = FileManager.default.fileExists(atPath: pauseFile)
        writeState(badges: lastBadges, lastPoll: now)
        let t0 = Date()
        // PID first, then windows owned by that PID (works off-Space via CGWindowList + screencapture -l).
        guard let target = resolveTargetPid(settings) else {
            targetMeta = nil
            isOffscreen = false
            if Int(now.timeIntervalSince1970) % 30 < Int(settings.pollSec) {
                log("⚠ 找不到监控目标（targetPid / \(settings.targetBundleId)）")
            }
            waitPoll(settings.pollSec); continue
        }
        if targetMeta?.pid != target.pid {
            preferredWin = -1
            log("ℹ 监控目标 \(target.name) pid=\(target.pid) mode=\(target.mode) bundle=\(target.bundleId)")
        }
        targetMeta = target
        let pid = target.pid
        let appName = target.name.isEmpty ? "ChatGPT" : target.name
        let mode = "files"
        let handled = loadHandled()
        let threads = scanThreads()
        let badges = fileWorkItems(threads, handled: handled)
        isBlind = false
        // 仅在有待办时解析窗口几何（发送要用）
        if !badges.isEmpty, let (wid, _, on0) = windowInfo(pid) {
            preferredWin = wid
            let wasOff = isOffscreen
            isOffscreen = !on0
            if isOffscreen && !wasOff { log("ℹ \(target.name) 不在当前屏(其他 Space/被切走)，仍可后台操作") }
            if !isOffscreen && wasOff { log("ℹ \(target.name) 已回到当前屏") }
        } else if badges.isEmpty {
            isOffscreen = false
        }

        let pollMs = Int(Date().timeIntervalSince(t0) * 1000)
        if pollMs > 1500 { log("⏱ 本轮检测 \(pollMs)ms mode=\(mode)") }
        lastBadges = badges
        let titles = Set(badges.map { $0.title })
        for t in titles where badgeFirstSeen[t] == nil { badgeFirstSeen[t] = now }
        for t in Array(badgeFirstSeen.keys) where !titles.contains(t) { badgeFirstSeen.removeValue(forKey: t) }
        let sig = badges.map { "\($0.title)[\($0.source)]" }.joined(separator: " | ")
        if sig != lastBadgeTitles {
            log("待处理 \(badges.count) 个: \(sig.isEmpty ? "(无)" : sig)")
            lastBadgeTitles = sig
        }
        var manualForceRetry = false
        if pendingManualScan {
            pendingManualScan = false
            lastManualScanAt = Date()
            manualForceRetry = !badges.isEmpty
            let detail = badges.isEmpty ? "无待处理" : "发现 \(badges.count) 条 · 立即重试"
            log("▶ 立即扫描完成 · \(detail)")
            note("立即扫描", "scan", detail)
            // 手动扫描：清退避，马上再试（不要只挂在「待继续」里等分钟级冷却）
            for b in badges {
                quickFails[b.title] = 0
                lastAttemptAt.removeValue(forKey: b.title)
                lastBackoffNoteLeft.removeValue(forKey: b.title)
                lastSendAt.removeValue(forKey: b.title)
                lastSentKey.removeValue(forKey: b.title)
            }
        }
        // Also honor SCAN_NOW dropped while we were busy in this iteration.
        if FileManager.default.fileExists(atPath: scanNowFile) {
            try? FileManager.default.removeItem(atPath: scanNowFile)
            pendingManualScan = true
            log("▶ 手动立即扫描（轮询中收到）")
        }
        writeState(badges: badges, lastPoll: now)

        for b in badges {
            if FileManager.default.fileExists(atPath: stopFile) { break }
            if paused { note(b.title, "paused", "监控已暂停"); continue }
            // Same error-turn still pending after a claimed send → false success.
            // A *new* errorTurn (typical: continue 后又 429) is fresh work — do not punish.
            if !manualForceRetry, let sentAt = lastSendAt[b.title], now.timeIntervalSince(sentAt) > 45 {
                let curKey: String? = {
                    guard let tid = b.threadId, let turn = b.errorTurn else { return nil }
                    return handledKey(tid, turn)
                }()
                let prevKey = lastSentKey[b.title]
                lastSendAt.removeValue(forKey: b.title)
                if let curKey, let prevKey, curKey == prevKey {
                    lastAttemptAt[b.title] = sentAt
                    quickFails[b.title] = min((quickFails[b.title] ?? 0) + 1, 4)
                    lastFailReason[b.title] = "发送后仍待处理"
                    log("· [\(b.title)] 发送后仍待处理（同一 errorTurn），作废上次成功标记")
                } else {
                    lastSentKey.removeValue(forKey: b.title)
                    quickFails[b.title] = 0
                    lastFailReason[b.title] = b.errorMsg.map { "发送后又失败 · \(String($0.prefix(36)))" } ?? "发送后又失败"
                    log("· [\(b.title)] 发送后又新失败（新 errorTurn / 429），不退避，马上再试")
                }
            }
            if !manualForceRetry, let sentAt = lastSendAt[b.title], now.timeIntervalSince(sentAt) < 40 {
                continue
            }
            let waits: [Double] = [0, 90, 180, 300, 600]
            let fails = quickFails[b.title] ?? 0
            let wait = manualForceRetry ? 0 : waits[min(fails, waits.count - 1)]
            let sinceAttempt = now.timeIntervalSince(lastAttemptAt[b.title] ?? .distantPast)
            if wait > 0 && sinceAttempt < wait {
                let left = Int(ceil((wait - sinceAttempt) / 60))
                let why = lastFailReason[b.title] ?? "上次失败"
                if lastBackoffNoteLeft[b.title] != left {
                    lastBackoffNoteLeft[b.title] = left
                    log("⏳ [\(b.title)] 退避中：\(why) · 还差 \(left) 分钟")
                    note(b.title, "backoff", "\(why) · 还差 \(left) 分钟")
                }
                continue
            }
            if let tid = b.threadId, let th = threads.first(where: { $0.id == tid }), th.running {
                log("⚠ [\(b.title)] rollout 仍在 running，跳过")
                note(b.title, "skipped", "仍在运行")
                continue
            }
            /// Confirm rollout after a claimed send. `punish=false` when another tier will still try.
            func finishContinue(via: String, punish: Bool = true) -> Bool {
                var confirmed = true
                if let path = b.path, !path.isEmpty {
                    confirmed = waitRolloutStarted(path: path, timeout: 25)
                    if confirmed {
                        if let tid = b.threadId, let turn = b.errorTurn {
                            markHandled(handledKey(tid, turn))
                        }
                        log("✓ [\(b.title)] \(via) · rollout 已开始")
                        note(b.title, "sent", "\(via) · rollout 确认")
                    } else {
                        log("⚠ [\(b.title)] \(via) 但 rollout 未开始")
                        note(b.title, "failed", "\(via) 后 rollout 未开始")
                        if punish {
                            lastFailReason[b.title] = "\(via) 后 rollout 未开始"
                            quickFails[b.title] = min(fails + 1, 4)
                        }
                        return false
                    }
                } else {
                    log("✓ [\(b.title)] \(via)")
                    note(b.title, "sent", via)
                }
                lastSendAt[b.title] = Date()
                if let tid = b.threadId, let turn = b.errorTurn {
                    lastSentKey[b.title] = handledKey(tid, turn)
                } else {
                    lastSentKey.removeValue(forKey: b.title)
                }
                lastFailReason.removeValue(forKey: b.title)
                quickFails[b.title] = 0
                return true
            }

            let whyErr = b.errorMsg.map { String($0.prefix(40)) } ?? ""
            lastAttemptAt[b.title] = Date()
            var done = false
            var skipUI = false

            // ---- Tier A: codex queue first（不依赖窗口 / Space）----
            if settings.useCodexQueue, let tid = b.threadId, !tid.isEmpty {
                log("继续 [\(b.title)] source=\(b.source)\(whyErr.isEmpty ? "" : " ← \(whyErr)") → codex queue 优先")
                if let qerr = queueContinue(threadId: tid) {
                    note(b.title, "failed", "codex queue：\(qerr)")
                    if isServerBusyError(qerr) || isServerBusyError(whyErr) {
                        // 429/503：UI 再塞 continue 只会堆字，帮不上忙
                        log("⚠ [\(b.title)] 服务端限流/过载，跳过 UI 兜底：\(qerr)")
                        lastFailReason[b.title] = String(qerr.prefix(48))
                        quickFails[b.title] = min(fails + 1, 4)
                        skipUI = true
                    } else {
                        log("⚠ [\(b.title)] codex queue 失败：\(qerr) → UI 兜底")
                    }
                } else if finishContinue(via: "codex queue", punish: false) {
                    done = true
                } else if isServerBusyError(whyErr) {
                    log("⚠ [\(b.title)] queue 后 rollout 未起且会话为限流，跳过 UI")
                    lastFailReason[b.title] = whyErr.isEmpty ? "限流·rollout 未开始" : whyErr
                    quickFails[b.title] = min(fails + 1, 4)
                    skipUI = true
                } else {
                    log("⚠ [\(b.title)] codex queue 后 rollout 未开始 → UI 兜底")
                }
            } else if isServerBusyError(whyErr) {
                // queue 未开时：限流也不要抢焦点堆 continue
                log("⚠ [\(b.title)] 服务端限流/过载，跳过 UI：\(whyErr)")
                lastFailReason[b.title] = whyErr
                quickFails[b.title] = min(fails + 1, 4)
                skipUI = true
            }

            // ---- Tier B: UI 兜底（写一次 continue → 提交；限流时跳过）----
            if !done && !skipUI {
                let axReady = composerAXReady(pid: pid, appName: appName)
                if isOffscreen || !axReady {
                    log("继续 [\(b.title)] → 抢焦点兜底发送（offscreen=\(isOffscreen) ax=\(axReady)）")
                    _ = stealFocusBriefly(pid: pid, appName: appName)
                } else {
                    log("继续 [\(b.title)] → UI 兜底发送（当前屏）")
                }
                let open = ensureOpen(b.title, pid: pid, appName: appName)
                guard let (wid, win, _) = open.ok else {
                    let why = open.fail ?? "打不开会话"
                    log("✗ [\(b.title)] 抢焦点后仍：\(why)")
                    note(b.title, "failed", "抢焦点·\(why)")
                    lastFailReason[b.title] = "抢焦点·\(why)"
                    quickFails[b.title] = min(fails + 1, 4)
                    writeState(badges: badges, lastPoll: Date())
                    Thread.sleep(forTimeInterval: 2)
                    continue
                }
                let send = sendContinue(win: win, wid: wid, name: b.title, pid: pid)
                if let reason = send.error {
                    log("✗ [\(b.title)] UI 发送失败：\(reason)")
                    note(b.title, "failed", "UI·\(reason)")
                    lastFailReason[b.title] = "UI·\(reason)"
                    quickFails[b.title] = min(fails + 1, 4)
                } else {
                    let method = "UI·\(send.method ?? "submit")"
                    _ = finishContinue(via: method)
                }
            }
            writeState(badges: badges, lastPoll: Date())
            Thread.sleep(forTimeInterval: 2)
        }
        waitPoll(settings.pollSec)
    }
    log("=== 监控结束(运行 \(Int(Date().timeIntervalSince(startDate)/60)) 分钟) ===")
    writeState(badges: [], lastPoll: Date())

}

let _watchExeName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
if _watchExeName == AppPaths.daemonBinaryName || CommandLine.arguments.contains("--daemon") {
    runWatchDaemon()
}
