import Foundation

struct AppScanner: Sendable {
    let portfolioRoot: URL

    private let excluded: Set<String> = ["dev-dashboard", "localhost-3000", ".git", "node_modules"]

    /// Returns app names in sorted order.
    func scan() -> [String] {
        scanWithPorts().map(\.name)
    }

    struct ScannedApp: Sendable {
        let name: String
        let scriptPort: Int?
        let devScript: String?
        let devScriptName: String?      // npm script name to run for the frontend (dev or dev:frontend)
        let backendKind: BackendKind?   // Convex / Supabase, if the project has one
        let backendBundled: Bool        // the frontend dev script already starts the backend
        let backendNeedsLocal: Bool     // backend runs as a local process (vs a cloud connection)
        let backendCommand: String?     // sidecar command to spawn when the backend isn't bundled
    }

    /// Returns app names and any port hardcoded in their dev script.
    func scanWithPorts() -> [ScannedApp] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: portfolioRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url -> ScannedApp? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            guard !excluded.contains(name) else { return nil }

            let pkgPath = url.appendingPathComponent("package.json")
            guard fm.fileExists(atPath: pkgPath.path),
                  let data = try? Data(contentsOf: pkgPath),
                  let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let scripts = pkg["scripts"] as? [String: Any]
            else { return nil }

            // Prefer "dev"; fall back to "dev:frontend" for split frontend/backend setups.
            let devScriptName: String
            let devScript: String
            if let s = scripts["dev"] as? String {
                devScriptName = "dev"
                devScript = s
            } else if let s = scripts["dev:frontend"] as? String {
                devScriptName = "dev:frontend"
                devScript = s
            } else {
                return nil
            }

            let backend = detectBackend(in: url, devScript: devScript, scripts: scripts)

            return ScannedApp(
                name: name,
                scriptPort: extractPort(from: devScript),
                devScript: devScript,
                devScriptName: devScriptName,
                backendKind: backend.kind,
                backendBundled: backend.bundled,
                backendNeedsLocal: backend.needsLocal,
                backendCommand: backend.command
            )
        }.sorted { $0.name < $1.name }
    }

    private struct BackendInfo {
        var kind: BackendKind?
        var bundled: Bool
        var needsLocal: Bool
        var command: String?
    }

    /// Works out whether a project depends on a Convex/Supabase backend, whether its
    /// frontend `dev` script already launches it, whether that backend runs as a local
    /// process, and (if we must start it ourselves) the command to run.
    private func detectBackend(in url: URL, devScript: String, scripts: [String: Any]) -> BackendInfo {
        let fm = FileManager.default
        let hasConvex = fm.fileExists(atPath: url.appendingPathComponent("convex").path)
        let hasSupabase = fm.fileExists(atPath: url.appendingPathComponent("supabase").path)

        let kind: BackendKind? = hasConvex ? .convex : (hasSupabase ? .supabase : nil)
        guard let kind else { return BackendInfo(kind: nil, bundled: false, needsLocal: false, command: nil) }

        let env = readEnv(in: url)

        switch kind {
        case .convex:
            // `convex dev` is always a local watcher process — needed whether it deploys to a
            // local open-source backend or to the cloud. Bundled when dev already runs it.
            let bundled = devScript.contains("convex dev") || devScript.contains("convex ")
            let command: String? = bundled
                ? nil
                : (scripts["dev:backend"] != nil ? "npm run dev:backend" : "npx convex dev")
            return BackendInfo(kind: .convex, bundled: bundled, needsLocal: true, command: command)

        case .supabase:
            // Cloud Supabase (https URL) needs no local process — only `supabase start` (local
            // docker, URL on localhost) does.
            let url = (env["SUPABASE_URL"] ?? env["NEXT_PUBLIC_SUPABASE_URL"] ?? "")
            let needsLocal = url.contains("localhost") || url.contains("127.0.0.1")
            let bundled = devScript.contains("supabase start") || devScript.contains("supabase ")
            let command: String? = (needsLocal && !bundled)
                ? (scripts["dev:backend"] != nil ? "npm run dev:backend" : "npx supabase start")
                : nil
            return BackendInfo(kind: .supabase, bundled: bundled, needsLocal: needsLocal, command: command)
        }
    }

    /// Shallow parse of .env.local then .env into a key→value map. First file wins.
    private func readEnv(in url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for file in [".env.local", ".env"] {
            let path = url.appendingPathComponent(file)
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                // Strip surrounding quotes and any trailing inline comment.
                if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if result[key] == nil { result[key] = value }
            }
        }
        return result
    }

    /// Parses -p 3001 / --port 3001 / --port=3001 from a dev script string.
    private func extractPort(from script: String) -> Int? {
        let pattern = #"(?:-p|--port[= ])(\d{4,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script),
              let port = Int(script[range])
        else { return nil }
        return port
    }
}
