import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct LocalhostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("OpenPort") {
            ContentView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.terminalStore)
                .environmentObject(appDelegate.theme)
        }
        .windowResizability(.contentMinSize)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.terminalStore)
                .environmentObject(appDelegate.theme)
        }
        .windowResizability(.contentSize)

        Window("OpenPort — Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let terminalStore = TerminalSessionStore()
    let theme = ThemeController()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupMenuBarIcon()

        // Reap leftover processes from a previous OpenPort session that quit without cleanup.
        model.reapPortfolioOrphans()

        model.$apps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous SIGTERM → 500ms → SIGKILL on every spawned PID. Without this, children
        // get reparented to launchd (PPID=1) and outlive every future OpenPort launch invisibly.
        model.nukeAllSync()
    }

    private func setupMenuBarIcon() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let quickLaunch = UserDefaults.standard.bool(forKey: "menuBarQuickLaunch")

        // Remove icon entirely when quick launch is off
        guard quickLaunch else {
            statusItem = nil
            return
        }

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Localhost")
        }

        let menu = NSMenu()

        if !model.apps.isEmpty {
            for app in model.apps {
                let isActive = app.isRunning || app.portStatus == .detached
                let port = app.detectedPort ?? app.port
                let appName = app.name
                let item = NSMenuItem()
                item.view = QuickLaunchMenuItemView(
                    name: appName,
                    port: port,
                    isRunning: isActive,
                    canOpenBrowser: isActive,
                    onToggle: { [weak self] in
                        guard let self,
                              let target = self.model.apps.first(where: { $0.name == appName }) else { return }
                        if target.isRunning { self.model.stop(app: target) }
                        else { self.model.start(app: target) }
                        self.rebuildMenu()
                    },
                    onOpenBrowser: {
                        SystemClient.openBrowser(port: port)
                    }
                )
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Show OpenPort", action: #selector(showWindow), keyEquivalent: ""))

        let whatsNewItem = NSMenuItem(title: "What's new", action: #selector(showWhatsNew), keyEquivalent: "")
        whatsNewItem.target = self
        menu.addItem(whatsNewItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func showWhatsNew() {
        showWindow()
        NotificationCenter.default.post(name: .openPortShowWhatsNew, object: nil)
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let app = model.apps.first(where: { $0.name == name }) else { return }
        if app.isRunning { model.stop(app: app) } else { model.start(app: app) }
        rebuildMenu()
    }

    @objc private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let openPortShowWhatsNew = Notification.Name("OpenPortShowWhatsNew")
}
