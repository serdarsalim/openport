import Foundation

/// Picks which Node a project's dev process should run under. Convex's local backend
/// refuses to deploy `"use node"` actions on Node > 24, yet a Homebrew default can sit
/// at v25+. We honor an explicit `.nvmrc` / `.node-version` pin first, and otherwise drop
/// Convex projects to a compatible installed Node so the backend doesn't fail silently.
enum NodeResolver {
    /// Returns the bin directory to prepend to PATH and a short human note, or nil to use
    /// the inherited Node. `convexCompat` asks for the safety net on Convex projects.
    static func resolve(directory: URL, convexCompat: Bool) -> (binDir: String, note: String)? {
        let installed = installedNodes()

        // 1. Explicit pin wins.
        if let pin = readPin(in: directory) {
            if let match = installed.first(where: { $0.major == pin }) {
                return (match.binDir, ".nvmrc → Node \(match.version)")
            }
            // Pinned but not installed — let it fall through to the inherited Node.
        }

        // 2. Convex safety net: if the inherited Node is newer than 24 and we have an
        //    older one installed, use the newest Node ≤ 22 (Convex's safe LTS line).
        if convexCompat, currentNodeMajor() > 24,
           let safe = installed.filter({ $0.major <= 22 }).max(by: { $0.major < $1.major }) {
            return (safe.binDir, "Node \(safe.version) for Convex")
        }

        return nil
    }

    private struct NodeInstall { let major: Int; let version: String; let binDir: String }

    /// `.nvmrc` / `.node-version` major version, if pinned. Handles "20", "v20.10.0", "lts/*" is skipped.
    private static func readPin(in directory: URL) -> Int? {
        for file in [".nvmrc", ".node-version"] {
            let path = directory.appendingPathComponent(file)
            guard let raw = try? String(contentsOf: path, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "v", with: "")
            if let major = Int(trimmed.split(separator: ".").first.map(String.init) ?? "") {
                return major
            }
        }
        return nil
    }

    // The default Node major rarely changes within a session; resolve it once.
    nonisolated(unsafe) private static var cachedNodeMajor: Int?

    private static func currentNodeMajor() -> Int {
        if let cached = cachedNodeMajor { return cached }
        guard let out = run("/opt/homebrew/bin/node", ["-v"]) ?? run("/usr/local/bin/node", ["-v"]) else { return 0 }
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
        let major = Int(v.split(separator: ".").first.map(String.init) ?? "") ?? 0
        cachedNodeMajor = major
        return major
    }

    /// All Node installs we can find: nvm versions and Homebrew node@N kegs.
    private static func installedNodes() -> [NodeInstall] {
        let fm = FileManager.default
        var result: [NodeInstall] = []

        let nvmRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let entries = try? fm.contentsOfDirectory(atPath: nvmRoot.path) {
            for entry in entries where entry.hasPrefix("v") {
                let version = String(entry.dropFirst())
                guard let major = Int(version.split(separator: ".").first.map(String.init) ?? "") else { continue }
                result.append(NodeInstall(major: major, version: version,
                                          binDir: nvmRoot.appendingPathComponent("\(entry)/bin").path))
            }
        }

        // Homebrew versioned kegs: /opt/homebrew/opt/node@22/bin
        if let kegs = try? fm.contentsOfDirectory(atPath: "/opt/homebrew/opt") {
            for keg in kegs where keg.hasPrefix("node@") {
                guard let major = Int(keg.dropFirst("node@".count)) else { continue }
                let binDir = "/opt/homebrew/opt/\(keg)/bin"
                guard fm.fileExists(atPath: binDir) else { continue }
                if !result.contains(where: { $0.major == major }) {
                    result.append(NodeInstall(major: major, version: "\(major)", binDir: binDir))
                }
            }
        }

        return result
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
