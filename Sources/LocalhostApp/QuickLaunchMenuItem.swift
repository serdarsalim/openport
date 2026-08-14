import AppKit

/// Custom NSView used as the `view` of an NSMenuItem in the menu-bar quick-launch list.
/// 3-column layout: status icon + name (leading) | port (right-aligned) | globe button (trailing).
/// Clicking anywhere except the globe toggles start/stop. Clicking the globe opens the
/// running app in the browser.
@MainActor
final class QuickLaunchMenuItemView: NSView {
    private let isRunning: Bool
    private let status: PortStatus
    private let onToggle: () -> Void
    private let onOpenBrowser: () -> Void

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let portLabel = NSTextField(labelWithString: "")
    private let globeButton = NSButton()

    private var isHovered = false {
        didSet { applyHoverState() }
    }

    init(name: String,
         port: Int,
         isRunning: Bool,
         status: PortStatus,
         canOpenBrowser: Bool,
         onToggle: @escaping () -> Void,
         onOpenBrowser: @escaping () -> Void) {
        self.isRunning = isRunning
        self.status = status
        self.onToggle = onToggle
        self.onOpenBrowser = onOpenBrowser
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        wantsLayer = true
        setupSubviews(name: name, port: port, canOpenBrowser: canOpenBrowser)
        applyHoverState()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Dot color mirroring the dashboard's Status column. nil hides the dot (stopped).
    private var statusDotColor: NSColor? {
        switch status {
        case .running, .detached: return NSColor(srgbRed: 0.13, green: 0.60, blue: 0.22, alpha: 1.0)
        case .starting:           return .systemOrange
        case .crashed:            return .systemRed
        case .external:           return .systemOrange
        case .free:               return nil
        }
    }

    private func setupSubviews(name: String, port: Int, canOpenBrowser: Bool) {
        let menuFontSize = NSFont.menuFont(ofSize: 0).pointSize

        // Icon (play.circle.fill / stop.circle.fill)
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbolName = isRunning ? "stop.circle.fill" : "play.circle.fill"
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg)
        // Darker green than systemGreen — the default washes out against the
        // menu's translucent background. systemRed already reads well as-is.
        let runningColor = NSColor.systemRed
        let readyColor = NSColor(srgbRed: 0.13, green: 0.60, blue: 0.22, alpha: 1.0)
        iconView.contentTintColor = isRunning ? runningColor : readyColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Name
        nameLabel.stringValue = name
        nameLabel.font = NSFont.menuFont(ofSize: 0)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        // Status dot — the at-a-glance answer to "what's running" without opening the window.
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = (statusDotColor ?? .clear).cgColor
        statusDot.isHidden = statusDotColor == nil
        statusDot.toolTip = {
            switch status {
            case .running:  return "Running"
            case .detached: return "Running (started in a terminal)"
            case .starting: return "Starting…"
            case .crashed:  return "Crashed"
            case .external: return "Port in use by another project"
            case .free:     return nil
            }
        }()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)

        // Port (monospaced digits, right-aligned)
        portLabel.stringValue = ":\(port)"
        portLabel.font = NSFont.monospacedDigitSystemFont(ofSize: menuFontSize, weight: .regular)
        portLabel.textColor = .secondaryLabelColor
        portLabel.alignment = .right
        portLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(portLabel)

        // Globe button
        let globeCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        globeButton.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Open in browser")?
            .withSymbolConfiguration(globeCfg)
        globeButton.isBordered = false
        globeButton.bezelStyle = .regularSquare
        globeButton.imagePosition = .imageOnly
        globeButton.target = self
        globeButton.action = #selector(globeClicked)
        globeButton.contentTintColor = canOpenBrowser ? .systemBlue : .tertiaryLabelColor
        globeButton.isEnabled = canOpenBrowser
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        globeButton.toolTip = "Open in browser"
        addSubview(globeButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusDot.leadingAnchor, constant: -8),

            statusDot.trailingAnchor.constraint(equalTo: portLabel.leadingAnchor, constant: -8),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            portLabel.trailingAnchor.constraint(equalTo: globeButton.leadingAnchor, constant: -12),
            portLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            portLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            globeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            globeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            globeButton.widthAnchor.constraint(equalToConstant: 18),
            globeButton.heightAnchor.constraint(equalToConstant: 18),

            heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func applyHoverState() {
        layer?.backgroundColor = isHovered
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        nameLabel.textColor = isHovered ? NSColor.white : .labelColor
        portLabel.textColor = isHovered
            ? NSColor.white.withAlphaComponent(0.75)
            : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // Globe button handles its own clicks via target/action.
        if globeButton.frame.contains(loc) {
            super.mouseDown(with: event)
            return
        }
        onToggle()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    @objc private func globeClicked() {
        onOpenBrowser()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
