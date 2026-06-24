import Foundation
import SwiftUI
import AppKit

/// Light / Dark / Auto / System. "Auto" follows the sun at the user's location:
/// it flips the app to dark between local sunset and sunrise. We never ask for
/// geolocation — we map the current IANA timezone to approximate coordinates and
/// run a standard sunrise/sunset calculation, the same trick the Claude apps use.
enum ThemeMode: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:   return "Auto"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .auto:   return "sun.horizon.fill"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }
}

/// Owns the resolved appearance for the whole app. In `.auto` it schedules a single
/// timer that fires at the next sunrise or sunset — no polling — and recomputes on
/// wake and timezone changes. Inject as an `@EnvironmentObject` and bind
/// `.preferredColorScheme(theme.resolvedScheme)` at the root.
@MainActor
final class ThemeController: ObservableObject {
    @Published private(set) var mode: ThemeMode
    /// nil = follow the OS appearance (System, or Auto at the poles where there's no sun event).
    @Published private(set) var resolvedScheme: ColorScheme?

    private let defaults = UserDefaults.standard
    private let storeKey = "colorScheme"
    private var flipTimer: Timer?

    init() {
        let raw = UserDefaults.standard.string(forKey: storeKey)
        self.mode = ThemeMode(rawValue: raw ?? "") ?? .auto
        self.resolvedScheme = nil
        recompute()

        // Auto must re-resolve when the machine wakes or its timezone shifts.
        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(self, selector: #selector(envChanged),
                        name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(envChanged),
                        name: .NSSystemTimeZoneDidChange, object: nil)
    }

    func setMode(_ newMode: ThemeMode) {
        mode = newMode
        defaults.set(newMode.rawValue, forKey: storeKey)
        recompute()
    }

    @objc private func envChanged() { recompute() }

    private func recompute() {
        flipTimer?.invalidate()
        flipTimer = nil

        switch mode {
        case .light:  resolvedScheme = .light
        case .dark:   resolvedScheme = .dark
        case .auto:
            let coords = SunCalc.coordsForTimezone(TimeZone.current.identifier)
            guard let times = SunCalc.sunTimes(date: Date(), lat: coords.lat, lng: coords.lng) else {
                resolvedScheme = nil  // polar day/night — defer to the OS
                return
            }
            let now = Date()
            let dark = now < times.sunrise || now >= times.sunset
            resolvedScheme = dark ? .dark : .light
            scheduleNextFlip(coords: coords)
        }
    }

    private func scheduleNextFlip(coords: (lat: Double, lng: Double)) {
        guard let next = SunCalc.nextFlip(after: Date(), lat: coords.lat, lng: coords.lng) else { return }
        // Fire a second past the boundary, and cap the delay so a long-asleep app still recovers.
        let delay = min(max(next.timeIntervalSinceNow + 1, 1), 6 * 60 * 60)
        flipTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }
}

/// Sunrise / sunset via the NOAA algorithm (adapted from SunCalc, public domain).
/// Pure value type, no dependencies. Ported from the time-off app's `lib/theme.ts`
/// so OpenPort and the web apps share the same behavior.
enum SunCalc {
    private static let rad = Double.pi / 180
    private static let dayMs: Double = 86_400_000
    private static let J1970: Double = 2440588
    private static let J2000: Double = 2451545
    private static let obliquity = rad * 23.4397
    private static let J0 = 0.0009
    private static let H0 = -0.833 * rad  // sun's angular radius + atmospheric refraction

    private static func toJulian(_ d: Date) -> Double { d.timeIntervalSince1970 * 1000 / dayMs - 0.5 + J1970 }
    private static func fromJulian(_ j: Double) -> Date { Date(timeIntervalSince1970: (j + 0.5 - J1970) * dayMs / 1000) }
    private static func toDays(_ d: Date) -> Double { toJulian(d) - J2000 }

    private static func solarMeanAnomaly(_ d: Double) -> Double { rad * (357.5291 + 0.98560028 * d) }

    private static func eclipticLongitude(_ M: Double) -> Double {
        let C = rad * (1.9148 * sin(M) + 0.02 * sin(2 * M) + 0.0003 * sin(3 * M))
        let P = rad * 102.9372  // perihelion of the Earth
        return M + C + P + Double.pi
    }

    private static func solarTransitJ(_ ds: Double, _ M: Double, _ L: Double) -> Double {
        J2000 + ds + 0.0053 * sin(M) - 0.0069 * sin(2 * L)
    }

    private static func hourAngle(_ h: Double, _ phi: Double, _ dec: Double) -> Double {
        acos((sin(h) - sin(phi) * sin(dec)) / (cos(phi) * cos(dec)))
    }

    /// Sunrise/sunset for a date at a coordinate, or nil during polar day/night.
    static func sunTimes(date: Date, lat: Double, lng: Double) -> (sunrise: Date, sunset: Date)? {
        let lw = rad * -lng
        let phi = rad * lat
        let d = toDays(date)

        let n = (d - J0 - lw / (2 * Double.pi)).rounded()
        let ds = J0 + (0 + lw) / (2 * Double.pi) + n
        let M = solarMeanAnomaly(ds)
        let L = eclipticLongitude(M)
        let dec = asin(sin(L) * sin(obliquity))
        let Jnoon = solarTransitJ(ds, M, L)

        let w0 = hourAngle(H0, phi, dec)
        if w0.isNaN { return nil }

        let Jset = solarTransitJ(J0 + (w0 + lw) / (2 * Double.pi) + n, M, L)
        let Jrise = Jnoon - (Jset - Jnoon)
        return (fromJulian(Jrise), fromJulian(Jset))
    }

    /// The next moment "auto" should flip value, so callers can set one precise timer.
    static func nextFlip(after now: Date, lat: Double, lng: Double) -> Date? {
        guard let today = sunTimes(date: now, lat: lat, lng: lng) else { return nil }
        if now < today.sunrise { return today.sunrise }
        if now < today.sunset { return today.sunset }
        let tomorrow = sunTimes(date: now.addingTimeInterval(86_400), lat: lat, lng: lng)
        return tomorrow?.sunrise
    }

    /// Coordinates for an IANA timezone, falling back to a longitude estimate from the
    /// current UTC offset (15° per hour) at a temperate latitude.
    static func coordsForTimezone(_ tz: String) -> (lat: Double, lng: Double) {
        if let hit = tzCoords[tz] { return (hit.0, hit.1) }
        let offsetHours = Double(TimeZone.current.secondsFromGMT()) / 3600
        return (40, offsetHours * 15)
    }

    /// Representative coordinates per zone (≈ the zone.tab anchor city). Not exhaustive;
    /// unknown zones fall back to the UTC-offset estimate above.
    private static let tzCoords: [String: (Double, Double)] = [
        "Europe/Dublin": (53.33, -6.25), "Europe/Istanbul": (41.01, 28.96), "Europe/London": (51.51, -0.13),
        "Europe/Lisbon": (38.72, -9.14), "Europe/Madrid": (40.42, -3.7), "Europe/Paris": (48.85, 2.35),
        "Europe/Brussels": (50.85, 4.35), "Europe/Amsterdam": (52.37, 4.9), "Europe/Berlin": (52.52, 13.41),
        "Europe/Zurich": (47.38, 8.54), "Europe/Rome": (41.9, 12.5), "Europe/Vienna": (48.21, 16.37),
        "Europe/Prague": (50.08, 14.44), "Europe/Warsaw": (52.23, 21.01), "Europe/Copenhagen": (55.68, 12.57),
        "Europe/Oslo": (59.91, 10.75), "Europe/Stockholm": (59.33, 18.07), "Europe/Helsinki": (60.17, 24.94),
        "Europe/Athens": (37.98, 23.73), "Europe/Bucharest": (44.43, 26.1), "Europe/Budapest": (47.5, 19.04),
        "Europe/Kyiv": (50.45, 30.52), "Europe/Kiev": (50.45, 30.52), "Europe/Moscow": (55.76, 37.62),
        "Atlantic/Reykjavik": (64.15, -21.94), "America/New_York": (40.71, -74.01), "America/Toronto": (43.65, -79.38),
        "America/Chicago": (41.88, -87.63), "America/Denver": (39.74, -104.99), "America/Phoenix": (33.45, -112.07),
        "America/Los_Angeles": (34.05, -118.24), "America/Vancouver": (49.28, -123.12), "America/Anchorage": (61.22, -149.9),
        "Pacific/Honolulu": (21.31, -157.86), "America/Mexico_City": (19.43, -99.13), "America/Bogota": (4.71, -74.07),
        "America/Lima": (-12.05, -77.04), "America/Sao_Paulo": (-23.55, -46.63),
        "America/Argentina/Buenos_Aires": (-34.61, -58.38), "America/Santiago": (-33.45, -70.67),
        "Africa/Casablanca": (33.57, -7.59), "Africa/Lagos": (6.52, 3.38), "Africa/Cairo": (30.04, 31.24),
        "Africa/Johannesburg": (-26.2, 28.05), "Africa/Nairobi": (-1.29, 36.82), "Asia/Jerusalem": (31.78, 35.22),
        "Asia/Dubai": (25.2, 55.27), "Asia/Tehran": (35.69, 51.39), "Asia/Karachi": (24.86, 67.0),
        "Asia/Kolkata": (22.57, 88.36), "Asia/Calcutta": (22.57, 88.36), "Asia/Dhaka": (23.81, 90.41),
        "Asia/Bangkok": (13.76, 100.5), "Asia/Jakarta": (-6.21, 106.85), "Asia/Singapore": (1.35, 103.82),
        "Asia/Hong_Kong": (22.32, 114.17), "Asia/Shanghai": (31.23, 121.47), "Asia/Taipei": (25.03, 121.57),
        "Asia/Seoul": (37.57, 126.98), "Asia/Tokyo": (35.68, 139.69), "Asia/Kuala_Lumpur": (3.14, 101.69),
        "Australia/Perth": (-31.95, 115.86), "Australia/Adelaide": (-34.93, 138.6), "Australia/Sydney": (-33.87, 151.21),
        "Australia/Melbourne": (-37.81, 144.96), "Australia/Brisbane": (-27.47, 153.03), "Pacific/Auckland": (-36.85, 174.76),
    ]
}
