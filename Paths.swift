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

    static var statePath: String { dataDir + "/state.json" }
    static var settingsPath: String { dataDir + "/settings.json" }
    static var pausePath: String { dataDir + "/PAUSE" }
    static var stopPath: String { dataDir + "/STOP" }
    static var scanNowPath: String { dataDir + "/SCAN_NOW" }
    static var logPath: String { dataDir + "/chatgpt-assistant.log" }
    static var handledPath: String { dataDir + "/handled.txt" }
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

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Launch the daemon detached, writing logs under dataDir.
    @discardableResult
    static func launchDaemon() -> Bool {
        try? FileManager.default.removeItem(atPath: stopPath)
        let bin = daemonPath
        guard FileManager.default.isExecutableFile(atPath: bin) else { return false }

        let script = """
        export CHATGPT_ASSISTANT_HOME=\(shellEscape(dataDir))
        cd "$CHATGPT_ASSISTANT_HOME" || exit 1
        # Kill previous instance if any
        /usr/bin/pkill -x \(daemonBinaryName) 2>/dev/null || true
        /bin/sleep 0.2
        /usr/bin/nohup \(shellEscape(bin)) >>stdout.log 2>>daemon.err </dev/null &
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
