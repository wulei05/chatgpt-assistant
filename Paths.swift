import AppKit
import Foundation

/// Shared layout for ChatGPT助手:
/// - Inside `.app`: binaries in Contents/MacOS, defaults in Resources, writable data in Application Support
/// - Dev / zip layout: everything next to the executable
enum AppPaths {
    static let supportFolderName = "ChatGPT助手"
    /// Keep ≤15 chars so `pgrep -x` / process table names stay exact.
    static let daemonBinaryName = "cgpt-daemon"
    static let barBinaryName = "CGPTBar"

    private static let resolved: (data: String, resources: String, macOS: String, inApp: Bool) = {
        if let env = ProcessInfo.processInfo.environment["CHATGPT_ASSISTANT_HOME"], !env.isEmpty {
            try? FileManager.default.createDirectory(atPath: env, withIntermediateDirectories: true)
            let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                .deletingLastPathComponent().path
            return (env, env, exeDir, false)
        }

        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exeDir = exe.deletingLastPathComponent()

        if exeDir.lastPathComponent == "MacOS" {
            let contents = exeDir.deletingLastPathComponent()
            let appBundle = contents.deletingLastPathComponent()
            if appBundle.pathExtension == "app" {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(supportFolderName, isDirectory: true)
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                let resources = contents.appendingPathComponent("Resources", isDirectory: true).path
                seedDefaultsIfNeeded(dataDir: support.path, resourcesDir: resources)
                migrateFromDevFolderIfNeeded(dataDir: support.path)
                return (support.path, resources, exeDir.path, true)
            }
        }

        let dir = exeDir.path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir, dir, dir, false)
    }()

    static var dataDir: String { resolved.data }
    static var resourcesDir: String { resolved.resources }
    static var macOSDir: String { resolved.macOS }
    static var runningInAppBundle: Bool { resolved.inApp }

    /// macOS 27+ renames Privacy → Accessibility UI to「设备控制和数据访问」.
    static var isMacOS27OrNewer: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
    }

    /// User-visible name of the TCC pane that gates AXIsProcessTrusted.
    static var accessibilityPrivacyName: String {
        isMacOS27OrNewer ? "设备控制和数据访问" : "辅助功能"
    }

    static var accessibilitySettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(accessibilitySettingsURL)
    }

    static var statePath: String { dataDir + "/state.json" }
    static var settingsPath: String { dataDir + "/settings.json" }
    static var pausePath: String { dataDir + "/PAUSE" }
    static var stopPath: String { dataDir + "/STOP" }
    static var scanNowPath: String { dataDir + "/SCAN_NOW" }
    static var logPath: String { dataDir + "/chatgpt-assistant.log" }
    static var handledPath: String { dataDir + "/handled.txt" }
    /// Tracks last launched app CDHash to detect upgrade → AX re-grant needed.
    static var axIdentityPath: String { dataDir + "/ax-identity.json" }
    static var specPath: String {
        let inResources = resourcesDir + "/SPEC.md"
        if FileManager.default.fileExists(atPath: inResources) { return inResources }
        return dataDir + "/SPEC.md"
    }
    static var daemonPath: String { macOSDir + "/" + daemonBinaryName }
    static var startDaemonScript: String { dataDir + "/start-daemon.sh" }

    private static func seedDefaultsIfNeeded(dataDir: String, resourcesDir: String) {
        let dest = dataDir + "/settings.json"
        let src = resourcesDir + "/settings.json"
        if !FileManager.default.fileExists(atPath: dest),
           FileManager.default.fileExists(atPath: src) {
            try? FileManager.default.copyItem(atPath: src, toPath: dest)
        }
    }

    /// One-time: copy runtime files from previous project folder if Application Support is empty.
    private static func migrateFromDevFolderIfNeeded(dataDir: String) {
        let marker = dataDir + "/.migrated"
        if FileManager.default.fileExists(atPath: marker) { return }
        let candidates = [
            NSString(string: "~/Develop/charles/chatgpt-assistant").expandingTildeInPath,
            NSString(string: "~/Develop/charles/codex-watch").expandingTildeInPath
        ]
        for old in candidates {
            let oldHandled = old + "/handled.txt"
            guard FileManager.default.fileExists(atPath: oldHandled) else { continue }
            for name in ["handled.txt", "settings.json", "state.json"] {
                let from = old + "/" + name
                let to = dataDir + "/" + name
                if FileManager.default.fileExists(atPath: from),
                   !FileManager.default.fileExists(atPath: to) {
                    try? FileManager.default.copyItem(atPath: from, toPath: to)
                }
            }
            break
        }
        FileManager.default.createFile(atPath: marker, contents: nil)
    }

    private static var daemonThread: Thread?
    private static var daemonProcess: Process?

    /// In the .app, run monitoring in-process so Accessibility TCC from `open` applies.
    /// (Spawning `cgpt-daemon` as a child of a LaunchServices-launched app loses AX trust.)
    @discardableResult
    static func launchDaemon() -> Bool {
        stopDaemon()
        try? FileManager.default.removeItem(atPath: stopPath)

        if runningInAppBundle {
            if let t = daemonThread, t.isExecuting { return true }
            let t = Thread {
                runWatchDaemon()
            }
            t.name = "cgpt-watch"
            t.qualityOfService = .userInitiated
            daemonThread = t
            t.start()
            return true
        }

        let bin = daemonPath
        guard FileManager.default.isExecutableFile(atPath: bin) else { return false }
        let outPath = dataDir + "/stdout.log"
        let errPath = dataDir + "/daemon.err"
        FileManager.default.createFile(atPath: outPath, contents: nil, attributes: nil)
        FileManager.default.createFile(atPath: errPath, contents: nil, attributes: nil)
        guard let out = FileHandle(forWritingAtPath: outPath),
              let err = FileHandle(forWritingAtPath: errPath) else { return false }
        out.seekToEndOfFile()
        err.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        var env = ProcessInfo.processInfo.environment
        env["CHATGPT_ASSISTANT_HOME"] = dataDir
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: dataDir)
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            daemonProcess = p
            return true
        } catch {
            return false
        }
    }

    /// Stop daemon so Finder can replace/move the .app bundle.
    static func stopDaemon() {
        FileManager.default.createFile(atPath: stopPath, contents: nil)
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        if let st = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
           let obj = try? JSONSerialization.jsonObject(with: st) as? [String: Any],
           let pid = obj["pid"] as? Int, pid > 0, pid != myPid {
            kill(pid_t(pid), SIGTERM)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", daemonBinaryName]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        if let t = daemonThread {
            let deadline = Date().addingTimeInterval(4)
            while t.isExecuting && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        daemonProcess = nil
    }
}
