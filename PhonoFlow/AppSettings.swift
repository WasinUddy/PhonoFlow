//
//  AppSettings.swift
//  PhonoFlow
//

import ServiceManagement
import SwiftUI

nonisolated protocol AppSettingsPreferences: AnyObject {
    func string(forKey key: String) -> String?
    func array(forKey key: String) -> [Any]?
    func integer(forKey key: String) -> Int
    func bool(forKey key: String) -> Bool
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: AppSettingsPreferences {}

enum ColorTheme: String, CaseIterable, Identifiable {
    case midnight = "Midnight"
    case ember = "Ember"
    case ocean = "Ocean"
    case forest = "Forest"
    case lavender = "Lavender"

    var id: String { rawValue }

    var accent: Color {
        switch self {
        case .midnight: return Color(red: 0.35, green: 0.55, blue: 1.0)
        case .ember: return Color(red: 0.95, green: 0.45, blue: 0.25)
        case .ocean: return Color(red: 0.2, green: 0.75, blue: 0.85)
        case .forest: return Color(red: 0.3, green: 0.8, blue: 0.45)
        case .lavender: return Color(red: 0.7, green: 0.5, blue: 0.95)
        }
    }

    var meterGreen: Color {
        switch self {
        case .midnight: return Color(red: 0.25, green: 0.85, blue: 0.55)
        case .ember: return Color(red: 1.0, green: 0.65, blue: 0.2)
        case .ocean: return Color(red: 0.2, green: 0.75, blue: 0.85)
        case .forest: return Color(red: 0.3, green: 0.8, blue: 0.45)
        case .lavender: return Color(red: 0.65, green: 0.5, blue: 0.95)
        }
    }

    var activeColor: Color {
        switch self {
        case .midnight: return Color(red: 0.25, green: 0.85, blue: 0.55)
        case .ember: return Color(red: 0.95, green: 0.55, blue: 0.2)
        case .ocean: return Color(red: 0.2, green: 0.82, blue: 0.9)
        case .forest: return Color(red: 0.25, green: 0.85, blue: 0.45)
        case .lavender: return Color(red: 0.7, green: 0.5, blue: 0.95)
        }
    }

    var sliderTint: Color {
        switch self {
        case .midnight: return Color(red: 0.35, green: 0.6, blue: 1.0)
        case .ember: return Color(red: 0.95, green: 0.5, blue: 0.25)
        case .ocean: return Color(red: 0.2, green: 0.7, blue: 0.85)
        case .forest: return Color(red: 0.3, green: 0.75, blue: 0.45)
        case .lavender: return Color(red: 0.65, green: 0.45, blue: 0.95)
        }
    }
}

private enum SettingsKeys {
    static let theme = "colorTheme"
    static let allowedHosts = "radioAllowedHosts"
    static let radioPort = "radioPort"
    static let remoteAccessEnabled = "remoteAccessEnabled"
    static let remoteAccessPort = "remoteAccessPort"
    static let allowLegacyUnauthenticatedStream = "allowLegacyUnauthenticatedStream"
    static let proMode = "proMode"
    static let launchAtLogin = "launchAtLogin"
    static let hasAskedLaunchAtLogin = "hasAskedLaunchAtLogin"
    static let showAdvancedVisualizations = "showAdvancedVisualizations"
    static let showDiagnostics = "showDiagnostics"
}

// Shared colors used across the UI — centralised to avoid scattered literal RGB values.
enum AppColors {
    static let closeRed = Color(red: 0.85, green: 0.25, blue: 0.25)
    static let onAirRed = Color(red: 1.0, green: 0.2, blue: 0.2)  // Red for "On Air" status
    static let streamingYellow = Color(red: 1.0, green: 0.75, blue: 0.0)  // Yellow for streaming only
    static let standbyGray = Color(red: 0.45, green: 0.45, blue: 0.5)
    static let proBadgeStart = Color(red: 0.55, green: 0.3, blue: 1.0)
    static let proBadgeEnd = Color(red: 0.35, green: 0.55, blue: 1.0)
    static let meterPeakRed = Color(red: 1.0, green: 0.25, blue: 0.25)
    static let meterWarningYellow = Color(red: 1.0, green: 0.75, blue: 0.15)
}

// LED meter segment thresholds on dB-scaled meter (0-1 fraction maps to -40 to 0 dB).
//   -3 dB → fraction 0.925   (red: near clipping)
//  -10 dB → fraction 0.75    (yellow: getting hot)
enum MeterThresholds {
    static let peak: Float = 0.925  // -3 dB
    static let warning: Float = 0.75  // -10 dB
}

@Observable
class AppSettings {
    static let defaultRadioPort: UInt16 = 7865
    static let defaultRemoteAccessPort: UInt16 = 7866

    private let defaults: any AppSettingsPreferences
    private let managesLaunchAtLogin: Bool

    var theme: ColorTheme {
        didSet { defaults.set(theme.rawValue, forKey: SettingsKeys.theme) }
    }
    var allowedHosts: [String] {
        didSet { defaults.set(allowedHosts, forKey: SettingsKeys.allowedHosts) }
    }
    var radioPort: UInt16 {
        didSet { defaults.set(Int(radioPort), forKey: SettingsKeys.radioPort) }
    }
    /// Enables the paired control surface. The remote-access coordinator observes
    /// this preference and owns the server lifecycle.
    var remoteAccessEnabled: Bool {
        didSet {
            defaults.set(remoteAccessEnabled, forKey: SettingsKeys.remoteAccessEnabled)
        }
    }
    var remoteAccessPort: UInt16 {
        didSet {
            defaults.set(Int(remoteAccessPort), forKey: SettingsKeys.remoteAccessPort)
        }
    }
    /// Compatibility escape hatch for existing VLC/mpv users. New installations
    /// keep the legacy endpoint behind pairing by default.
    var allowLegacyUnauthenticatedStream: Bool {
        didSet {
            defaults.set(
                allowLegacyUnauthenticatedStream,
                forKey: SettingsKeys.allowLegacyUnauthenticatedStream
            )
        }
    }
    var isProMode: Bool {
        didSet { defaults.set(isProMode, forKey: SettingsKeys.proMode) }
    }

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: SettingsKeys.launchAtLogin)
            if managesLaunchAtLogin {
                updateLaunchAtLogin(launchAtLogin)
            }
        }
    }

    var hasAskedLaunchAtLogin: Bool {
        get { defaults.bool(forKey: SettingsKeys.hasAskedLaunchAtLogin) }
        set { defaults.set(newValue, forKey: SettingsKeys.hasAskedLaunchAtLogin) }
    }

    var showAdvancedVisualizations: Bool {
        didSet {
            defaults.set(showAdvancedVisualizations, forKey: SettingsKeys.showAdvancedVisualizations)
        }
    }

    var showDiagnostics: Bool {
        didSet {
            defaults.set(showDiagnostics, forKey: SettingsKeys.showDiagnostics)
        }
    }

    init(defaults: any AppSettingsPreferences = UserDefaults.standard) {
        self.defaults = defaults
        // Production uses the standard domain. Tests can inject an isolated suite
        // without registering or unregistering the application with launchd.
        managesLaunchAtLogin =
            (defaults as? UserDefaults) === UserDefaults.standard

        let ud = defaults
        if let raw = ud.string(forKey: SettingsKeys.theme),
            let t = ColorTheme(rawValue: raw)
        {
            theme = t
        } else {
            theme = .midnight
        }
        if let hosts = ud.array(forKey: SettingsKeys.allowedHosts) as? [String] {
            allowedHosts = hosts
        } else {
            allowedHosts = []
        }
        let port = ud.integer(forKey: SettingsKeys.radioPort)
        radioPort =
            (1...65_535).contains(port)
            ? UInt16(port)
            : AppSettings.defaultRadioPort

        remoteAccessEnabled = ud.bool(forKey: SettingsKeys.remoteAccessEnabled)
        let remotePort = ud.integer(forKey: SettingsKeys.remoteAccessPort)
        remoteAccessPort =
            (1...65_535).contains(remotePort)
            ? UInt16(remotePort)
            : AppSettings.defaultRemoteAccessPort
        allowLegacyUnauthenticatedStream =
            ud.object(
                forKey: SettingsKeys.allowLegacyUnauthenticatedStream
            ) == nil ? false : ud.bool(forKey: SettingsKeys.allowLegacyUnauthenticatedStream)

        // Pro mode defaults to false (basic mode)
        if ud.object(forKey: SettingsKeys.proMode) != nil {
            isProMode = ud.bool(forKey: SettingsKeys.proMode)
        } else {
            isProMode = false
        }

        // Launch at login
        launchAtLogin = ud.bool(forKey: SettingsKeys.launchAtLogin)

        // Advanced visualizations toggle (default off)
        showAdvancedVisualizations =
            ud.object(forKey: SettingsKeys.showAdvancedVisualizations) == nil
            ? false : ud.bool(forKey: SettingsKeys.showAdvancedVisualizations)

        showDiagnostics =
            ud.object(forKey: SettingsKeys.showDiagnostics) == nil
            ? false
            : ud.bool(forKey: SettingsKeys.showDiagnostics)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update launch at login: \(error)")
            }
        }
    }
}
