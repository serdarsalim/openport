import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("menuBarQuickLaunch") private var menuBarQuickLaunch = false
    @AppStorage("goLinksEnabled") private var goLinksEnabled = false
    @AppStorage("goLinksSystemSetup") private var goLinksSystemSetup = false
    @AppStorage("launcherEnabled") private var launcherEnabled = false
    @AppStorage("showActionBrowser") private var showActionBrowser = true
    @AppStorage("showActionCopy") private var showActionCopy = true
    @AppStorage("showActionQR") private var showActionQR = false
    @AppStorage("showActionTerminal") private var showActionTerminal = true
    @AppStorage("showActionEditor") private var showActionEditor = true
    @AppStorage("showActionFinder") private var showActionFinder = true
    @AppStorage("showActionLogs") private var showActionLogs = true
    @AppStorage("useExternalTerminal") private var useExternalTerminal = false
    @AppStorage("terminalTheme") private var terminalTheme = TerminalThemeID.system.rawValue
    @AppStorage("terminalFontSize") private var terminalFontSize: Double = 13
    @AppStorage("lastSeenChangelogVersion") private var lastSeenChangelogVersion = ""
    @EnvironmentObject private var terminalStore: TerminalSessionStore
    @EnvironmentObject private var theme: ThemeController
    @State private var launchAtStartup = false
    @State private var isSettingUp = false
    @State private var setupError: String?
    @State private var showWhatsNew = false
    @State private var whatsNewHovered = false
    @State private var selectedSection: SettingsSection = .general
    @Environment(\.dismiss) private var dismiss

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, goLinks, launcher, terminal, rows
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .goLinks: return "go/ links"
            case .launcher: return "LAN Launcher"
            case .terminal: return "Terminal"
            case .rows: return "Rows"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .goLinks: return "link"
            case .launcher: return "wifi"
            case .terminal: return "terminal"
            case .rows: return "list.bullet"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }
            Divider()
            footer
        }
        .sheet(isPresented: $showWhatsNew, onDismiss: {
            lastSeenChangelogVersion = Changelog.latestVersion
        }) { WhatsNewSheet() }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 460, idealHeight: 520)
        .onAppear {
            launchAtStartup = SMAppService.mainApp.status == .enabled
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SettingsSidebarRow(
                    section: section,
                    isSelected: selectedSection == section,
                    action: { selectedSection = section }
                )
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 200)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: selectedSection.symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(selectedSection.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                }
                .padding(.bottom, 4)

                switch selectedSection {
                case .general: generalTab
                case .goLinks: goLinksTab
                case .launcher: launcherTab
                case .terminal: terminalTab
                case .rows: rowsTab
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                showWhatsNew = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("What's new")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(whatsNewHovered ? 0.10 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onHover { whatsNewHovered = $0 }
            Spacer()
            Button("Done") {
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.return)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var appearanceRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Appearance")
                    .font(.system(size: 13, weight: .medium))
                Text("Auto follows sunrise and sunset at your location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(get: { theme.mode }, set: { theme.setMode($0) })) {
                ForEach(ThemeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            portfolioRow
            Divider()
            appearanceRow
            Divider()
            settingRow(
                title: "Launch at startup",
                subtitle: "Start Localhost automatically when you log in.",
                binding: $launchAtStartup
            )
            .onChange(of: launchAtStartup) { _, enabled in
                if enabled { try? SMAppService.mainApp.register() }
                else { try? SMAppService.mainApp.unregister() }
            }
            Divider()
            settingRow(
                title: "Menu bar quick launch",
                subtitle: "Access your apps from the menu bar.",
                binding: $menuBarQuickLaunch
            )
            Spacer()
        }
        .padding(.top, 8)
    }

    private var goLinksTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(
                title: "go/ links",
                subtitle: "Type http://go/alias in your browser to open any app instantly. Click an app name in the main window to set its alias.",
                binding: $goLinksEnabled
            )
            .onChange(of: goLinksEnabled) { _, enabled in
                model.setGoLinksEnabled(enabled)
            }

            if goLinksEnabled {
                Divider()
                if goLinksSystemSetup {
                    HStack {
                        Label("System routing active — go/alias works in any browser.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Spacer()
                        Button(isSettingUp ? "Reinstalling…" : "Reinstall") {
                            Task { await runSetup() }
                        }
                        .font(.caption)
                        .disabled(isSettingUp)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("One-time setup required. Adds a local hostname and installs a port forwarder so go/alias works in any browser. Requires your password once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(isSettingUp ? "Setting up…" : "Setup System") {
                                Task { await runSetup() }
                            }
                            .disabled(isSettingUp)
                            if let err = setupError {
                                Text(err).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var launcherTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(
                title: "LAN Launcher",
                subtitle: "Serve a phone-friendly page at port \(LauncherServer.port) listing every app with tap-to-open links and live status. Reachable from any device on the same Wi-Fi.",
                binding: $launcherEnabled
            )
            .onChange(of: launcherEnabled) { _, enabled in
                model.setLauncherEnabled(enabled)
            }

            if launcherEnabled {
                Divider()
                HStack(alignment: .top, spacing: 18) {
                    QRPopover(port: Int(LauncherServer.port))
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Scan to open the launcher on your phone")
                            .font(.system(size: 13, weight: .medium))
                        Text(model.launcherURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Open in browser") {
                            if let url = URL(string: model.launcherURL) { NSWorkspace.shared.open(url) }
                        }
                        .controlSize(.small)
                        Text("Apps you Run from OpenPort are auto-exposed on the LAN (Vite, Next, CRA). macOS may ask to allow incoming connections the first time — click Allow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var terminalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingRow(
                title: "Use external Terminal.app",
                subtitle: "Open the terminal button in macOS Terminal.app instead of a tab inside OpenPort.",
                binding: $useExternalTerminal
            )

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Terminal profile")
                    .fontWeight(.medium)
                Text("Theme and font size for in-app terminal tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Theme")
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: $terminalTheme) {
                        ForEach(TerminalThemeID.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: terminalTheme) { _, _ in
                        terminalStore.applyAppearance()
                    }
                    Spacer()
                }

                HStack {
                    Text("Font size")
                        .frame(width: 90, alignment: .leading)
                    Slider(value: $terminalFontSize, in: 10...20, step: 1) {
                        EmptyView()
                    }
                    .frame(maxWidth: 220)
                    .onChange(of: terminalFontSize) { _, _ in
                        terminalStore.applyAppearance()
                    }
                    Text("\(Int(terminalFontSize)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var rowsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Action buttons")
                .fontWeight(.medium)
            Text("Hide buttons you don't use to keep rows compact.")
                .font(.caption)
                .foregroundStyle(.secondary)

            actionToggle("Open in browser", systemImage: "globe", binding: $showActionBrowser)
            actionToggle("Copy network URL", systemImage: "doc.on.doc", binding: $showActionCopy)
            actionToggle("QR code", systemImage: "qrcode", binding: $showActionQR)
            actionToggle("View live logs", systemImage: "doc.text.magnifyingglass", binding: $showActionLogs)
            actionToggle("Open in Terminal", systemImage: "terminal", binding: $showActionTerminal)
            actionToggle("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right", binding: $showActionEditor)
            actionToggle("Open in Finder", systemImage: "folder", binding: $showActionFinder)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var portfolioRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Portfolio folder")
                Text(model.portfolioRoot?.path ?? "No folder selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Change…") {
                pickFolder(model: model)
            }
            .controlSize(.small)
        }
    }

    private func settingRow(title: String, subtitle: String, binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private func actionToggle(_ label: String, systemImage: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(label)
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private func runSetup() async {
        isSettingUp = true
        setupError = nil
        let success = await GoLinksSetup.install()
        isSettingUp = false
        if success {
            goLinksSystemSetup = true
        } else {
            setupError = "Setup failed or was cancelled."
        }
    }
}

enum GoLinksSetup {
    static let label    = "com.serdarsalim.localhost3000.port80"
    static let plistDst = "/Library/LaunchDaemons/\(label).plist"

    // Python TCP forwarder: listens on :80, forwards every connection to :9080
    static let pythonScript = """
import socket,threading
def handle(c):
    s=socket.socket()
    s.connect(('127.0.0.1',9080))
    def fwd(a,b):
        try:
            while True:
                d=a.recv(4096)
                if not d:break
                b.sendall(d)
        except:pass
        finally:a.close();b.close()
    threading.Thread(target=fwd,args=(c,s),daemon=True).start()
    threading.Thread(target=fwd,args=(s,c),daemon=True).start()
s=socket.socket()
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',80))
s.listen(100)
while True:handle(s.accept()[0])
"""

    static func install() async -> Bool {
        let plist = buildPlist()
        let tempPath = NSTemporaryDirectory() + "localhost3000.port80.plist"
        guard (try? plist.write(toFile: tempPath, atomically: true, encoding: .utf8)) != nil else { return false }

        let cmd = [
            "grep -q '127.0.0.1 go' /etc/hosts || printf '\\n127.0.0.1 go\\n' >> /etc/hosts",
            "cp '\(tempPath)' '\(plistDst)'",
            "launchctl load -w '\(plistDst)'"
        ].joined(separator: "; ")

        return await runAppleScript("do shell script \"\(escaped(cmd))\" with administrator privileges")
    }

    static func uninstall() async -> Bool {
        let cmd = [
            "launchctl unload '\(plistDst)' 2>/dev/null || true",
            "rm -f '\(plistDst)'",
            "sed -i '' '/127\\.0\\.0\\.1 go$/d' /etc/hosts"
        ].joined(separator: "; ")

        return await runAppleScript("do shell script \"\(escaped(cmd))\" with administrator privileges")
    }

    private static func buildPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/python3</string>
                <string>-c</string>
                <string>\(pythonScript)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/tmp/localhost3000-port80.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/localhost3000-port80.log</string>
        </dict>
        </plist>
        """
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ script: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            try? p.run()
        }
    }
}

@MainActor
private struct SettingsSidebarRow: View {
    let section: SettingsView.SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var background: Color {
        if isSelected { return Color.accentColor }
        if isHovered { return Color.primary.opacity(0.08) }
        return Color.clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                Text(section.title)
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
