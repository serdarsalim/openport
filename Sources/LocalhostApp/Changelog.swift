import Foundation

struct ChangelogEntry: Identifiable {
    var id: String { version }
    let version: String
    let date: String
    let items: [String]
}

enum Changelog {
    /// Newest first. Bump the version when you ship and add an entry.
    /// Date format: yyyy-MM-dd.
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.2.0",
            date: "2026-06-10",
            items: [
                "Auto appearance — a new Light / Dark / Auto control where Auto follows the sun at your location, flipping to dark at local sunset and back at sunrise. No geolocation prompt; it derives your coordinates from the system timezone. Pick it from the appearance menu in the footer or Settings → General.",
                "Backend awareness — OpenPort now detects when a project has a Convex or Supabase backend, whether the dev script already starts it, and whether it's a local process or a cloud connection. Each row shows a backend line under the app name with live status.",
                "Auto-start backends — when an app has a local backend that its dev script doesn't launch, OpenPort runs it for you (npm run dev:backend, or npx convex dev / supabase start) so Run boots the whole stack instead of just the frontend.",
                "Node version pinning — respects a project's .nvmrc / .node-version when launching, and drops Convex projects to a compatible Node when your default is too new, so the local backend stops failing to deploy \"use node\" actions silently."
            ]
        ),
        ChangelogEntry(
            version: "1.1.0",
            date: "2026-05-07",
            items: [
                "In-app terminal tabs — click the terminal icon on any row (or the + in the tab bar) to open a real shell tab inside OpenPort, no more alt-tabbing to Terminal.app",
                "Context-aware search — the title-bar search filters apps on the Dashboard and finds in scrollback when you're on a terminal tab; ▲▼ jump between matches; per-tab query memory",
                "Terminal profiles — Settings → Terminal lets you pick a theme (System, Dark, Light, Solarized Dark/Light, Dracula, Nord) and font size; changes apply live to every open terminal",
                "Orphan reaper — process group kills + recursive descendant reap fix the EADDRINUSE bug after restart; dead OpenPort sessions no longer leak convex/next/esbuild zombies for days",
                "Settings reorganized — sidebar layout (General / go/ links / Terminal / Rows) instead of an ever-scrolling page; portfolio folder moved here from the footer",
                "Custom title bar — bold OpenPort flush left, soft search pill flush right, traffic lights in the same strip; no more icon-and-name duplication",
                "Footer cleanup — refresh + spinner now sit next to Stop All; help / settings / theme cluster on the right; the unseen-changelog blue dot now decorates the gear",
                "Use external Terminal.app toggle — Settings → Terminal lets you keep launching the row's terminal button into macOS Terminal.app if you prefer the old behavior"
            ]
        ),
        ChangelogEntry(
            version: "2026.05.05",
            date: "2026-05-05",
            items: [
                "Detect every $USER-owned listening port, not just node",
                "Show a green dot next to the port when an app is bound to multiple ports — click to see all of them with their command lines",
                "New \"Other ports in use\" section — surfaces dev servers you started outside OpenPort, with per-row stop",
                "Filter system processes (Tailscale, ssh tunnels, ControlCenter, etc.) out of \"Other ports\" so you can't accidentally kill them",
                "Settings → Action buttons: hide globe / copy / QR / terminal / VS Code / Finder per row",
                "Live logs viewer — modal sheet with search filter, auto-scroll, copy, and clear",
                "Cwd-based port matching: an app running on a different port than assigned now flips to detached and shows the actual port",
                "Settings: replaced checkboxes with macOS switches",
                "Settings and Help are now draggable, resizable windows instead of sheets",
                "Help redesigned with a sidebar, search, and 12 sections covering every feature"
            ]
        )
    ]

    static var latestVersion: String { entries.first?.version ?? "" }
}
