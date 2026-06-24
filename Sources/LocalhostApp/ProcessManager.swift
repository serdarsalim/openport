import Foundation

@MainActor
final class ProcessManager {
    private var running: [String: Process] = [:]
    private var backends: [String: Process] = [:]
    private var stopping: Set<String> = []
    private var logBuffers: [String: LogBuffer] = [:]
    private(set) var crashLogs: [String: String] = [:]  // name → last stderr on unexpected exit

    var onTerminated: ((String) -> Void)?

    func start(
        name: String,
        port: Int,
        in directory: URL,
        devScript: String? = nil,
        devScriptName: String? = nil,
        backendCommand: String? = nil,
        convexCompat: Bool = false,
        bindHost: Bool = false
    ) {
        guard !(running[name]?.isRunning == true) else { return }

        let framework = Self.detectFramework(devScript: devScript)
        let env = baseEnvironment(port: port, directory: directory, convexCompat: convexCompat,
                                  bindHost: bindHost, framework: framework)
        let scriptName = devScriptName ?? "dev"

        // When bindHost is on, expose the dev server on all interfaces so phones on the LAN
        // can reach it. The lever is framework-specific: Vite/Next take a flag, CRA reads HOST.
        let base: String
        let viaNpm: Bool
        if let script = devScript, script.contains("-p") || script.contains("--port") {
            base = patchPort(in: script, to: port); viaNpm = false
        } else {
            base = "npm run \(scriptName)"; viaNpm = true
        }
        let command = "exec \(bindHost ? Self.applyHostBinding(to: base, framework: framework, viaNpm: viaNpm) : base)"

        // Clear any previous crash log when restarting.
        crashLogs.removeValue(forKey: name)

        let buffer = LogBuffer()
        logBuffers[name] = buffer

        let frontend = makeProcess(directory: directory, env: env, command: command, logBuffer: buffer)
        frontend.terminationHandler = { [weak self, name] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let unexpected = !self.stopping.contains(name)
                self.stopping.remove(name)
                self.running.removeValue(forKey: name)
                if let backend = self.backends.removeValue(forKey: name), backend.isRunning {
                    backend.terminate()
                }
                if unexpected {
                    if let log = self.logBuffers[name]?.snapshot() {
                        self.crashLogs[name] = log
                    }
                    self.logBuffers.removeValue(forKey: name)
                    self.onTerminated?(name)
                } else {
                    self.logBuffers.removeValue(forKey: name)
                }
            }
        }

        if let backendCommand {
            let backend = makeProcess(directory: directory, env: env, command: "exec \(backendCommand)", logBuffer: buffer)
            backend.terminationHandler = { [weak self, name] _ in
                Task { @MainActor [weak self] in
                    self?.backends.removeValue(forKey: name)
                }
            }
            try? backend.run()
            backends[name] = backend
        }

        try? frontend.run()
        running[name] = frontend
    }

    func stop(name: String) {
        stopping.insert(name)
        crashLogs.removeValue(forKey: name)
        if let proc = running[name] { SystemClient.killTree(pid: proc.processIdentifier) }
        running.removeValue(forKey: name)
        logBuffers.removeValue(forKey: name)
        if let backend = backends.removeValue(forKey: name), backend.isRunning {
            SystemClient.killTree(pid: backend.processIdentifier)
        }
    }

    func stopAll() {
        for name in running.keys { stopping.insert(name) }
        for process in running.values where process.isRunning {
            SystemClient.killTree(pid: process.processIdentifier)
        }
        for process in backends.values where process.isRunning {
            SystemClient.killTree(pid: process.processIdentifier)
        }
        running.removeAll()
        backends.removeAll()
        logBuffers.removeAll()
        crashLogs.removeAll()
    }

    /// Synchronous nuke for app shutdown. SIGTERM → 500ms wait → SIGKILL, blocking briefly so
    /// children actually die before we exit (otherwise they reparent to launchd as orphans).
    func nukeAllSync() {
        let pids = (running.values.map(\.processIdentifier) + backends.values.map(\.processIdentifier))
            .filter { $0 > 0 }
        for pid in pids {
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
        }
        usleep(500_000)
        for pid in pids {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    func isRunning(name: String) -> Bool {
        running[name]?.isRunning == true
    }

    func isBackendRunning(name: String) -> Bool {
        backends[name]?.isRunning == true
    }

    func crashLog(for name: String) -> String? {
        crashLogs[name]
    }

    /// Live log snapshot (stdout + stderr, line-merged) for a running app.
    func liveLog(for name: String) -> String? {
        logBuffers[name]?.snapshot()
    }

    func clearLog(for name: String) {
        logBuffers[name]?.clear()
    }

    /// Frameworks we know how to expose on the LAN. `unknown` falls back to the HOST env var.
    enum Framework { case next, vite, cra, unknown }

    static func detectFramework(devScript: String?) -> Framework {
        guard let s = devScript?.lowercased() else { return .unknown }
        if s.contains("next") { return .next }
        if s.contains("vite") { return .vite }
        if s.contains("react-scripts") { return .cra }
        return .unknown
    }

    /// Build caches a framework's dev server reuses between runs, relative to the project dir.
    /// A corrupt or oversized cache is the usual reason `npm run dev` pegs CPU and never serves —
    /// a plain Stop→Run reuses it and wedges again, so a clean restart wipes these first.
    nonisolated static func cacheDirs(for framework: Framework) -> [String] {
        switch framework {
        case .next:    return [".next"]
        case .vite:    return ["node_modules/.vite", ".svelte-kit"]  // SvelteKit runs on Vite
        case .cra:     return ["node_modules/.cache"]
        case .unknown: return []
        }
    }

    /// Delete a framework's build caches off the main thread. No-op for unknown frameworks or
    /// caches that don't exist. Safe — these are regenerated on the next dev build.
    nonisolated static func clearCaches(in directory: URL, framework: Framework) {
        let fm = FileManager.default
        for rel in cacheDirs(for: framework) {
            let url = directory.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Append the right host flag for the framework. Vite and Next take a CLI flag (passed
    /// through `npm run … --` when invoked via npm); CRA/unknown rely on the HOST env var.
    static func applyHostBinding(to command: String, framework: Framework, viaNpm: Bool) -> String {
        // When the frontend runs inside a wrapper like `convex dev --start 'next dev …'`,
        // the host flag belongs on the inner command, not the wrapper — otherwise Convex
        // (or whatever launches the dev server) receives `-H` and aborts. Inject into the
        // quoted sub-command and re-wrap.
        if let open = command.range(of: "--start '"),
           let close = command[open.upperBound...].firstIndex(of: "'") {
            let inner = String(command[open.upperBound..<close])
            let patched = applyHostBinding(to: inner, framework: framework, viaNpm: false)
            return String(command[..<open.upperBound]) + patched + String(command[close...])
        }
        switch framework {
        case .vite:
            if command.contains("--host") { return command }
            return viaNpm ? "\(command) -- --host" : "\(command) --host"
        case .next:
            if command.contains("-H ") || command.contains("--hostname") { return command }
            return viaNpm ? "\(command) -- -H 0.0.0.0" : "\(command) -H 0.0.0.0"
        case .cra, .unknown:
            return command  // handled via HOST in the environment
        }
    }

    private func baseEnvironment(port: Int, directory: URL, convexCompat: Bool,
                                 bindHost: Bool = false, framework: Framework = .unknown) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = "\(port)"
        env["VITE_PORT"] = "\(port)"
        // CRA's react-scripts and many webpack-based servers bind all interfaces when HOST is set.
        // Only set it for those — Vite/Next get a CLI flag instead, and some apps read process.env.HOST
        // for their own logic, so we don't clobber it needlessly.
        if bindHost, framework == .cra || framework == .unknown {
            env["HOST"] = "0.0.0.0"
        }
        let localBin = directory.appendingPathComponent("node_modules/.bin").path
        // A pinned (.nvmrc) or Convex-compatible Node goes ahead of the Homebrew default so
        // `node`/`npm`/`npx` resolve to the right version for this project.
        let nodeBin = NodeResolver.resolve(directory: directory, convexCompat: convexCompat)?.binDir
        let extraPaths = [localBin, nodeBin, "/opt/homebrew/bin", "/usr/local/bin"]
            .compactMap { $0 }
            .joined(separator: ":")
        env["PATH"] = "\(extraPaths):\(env["PATH"] ?? "/usr/bin:/bin")"
        return env
    }

    private func makeProcess(directory: URL, env: [String: String], command: String, logBuffer: LogBuffer?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = env

        if let buffer = logBuffer {
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                buffer.append(text)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                buffer.append(text)
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        return process
    }

    private func patchPort(in script: String, to port: Int) -> String {
        var result = script
        let patterns = [
            (#"(-p\s+)\d{4,5}"#,       "$1\(port)"),
            (#"(--port=)\d{4,5}"#,      "$1\(port)"),
            (#"(--port\s+)\d{4,5}"#,    "$1\(port)")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}

// Collects stdout + stderr lines in a ring buffer; thread-safe via NSLock.
final class LogBuffer: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    private let maxLines = 1000

    func append(_ text: String) {
        let incoming = LogBuffer.stripANSI(text).components(separatedBy: "\n").filter { !$0.isEmpty }
        lock.lock()
        lines.append(contentsOf: incoming)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    // dev servers emit ANSI escapes (colors, cursor moves, hyperlinks). We render plain text,
    // so strip them at the source — otherwise the logs you read to debug a failed Run are
    // littered with [36m / [2m noise, and so is captured crash output.
    private static let ansiRegex = try? NSRegularExpression(
        pattern: "\\u001B(?:\\[[0-9;?]*[ -/]*[@-~]|\\][^\\u0007\\u001B]*(?:\\u0007|\\u001B\\\\))"
    )

    static func stripANSI(_ text: String) -> String {
        guard let regex = ansiRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    func snapshot() -> String? {
        lock.lock()
        let result = lines.isEmpty ? nil : lines.joined(separator: "\n")
        lock.unlock()
        return result
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}
