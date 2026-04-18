//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

#if os(iOS) || os(macOS) || os(tvOS)

import SwiftUI
import SettingsUI

/// A color scheme option for the app.
///
/// `AppColorScheme` defines how the app’s UI colors should be displayed,
/// letting users choose between light, dark, or automatic system-based
/// appearance.
///
/// Example:
/// ```swift
/// let scheme: AppColorScheme = .dark
/// ```
///
public enum AppColorScheme: SettingPickable, CaseIterable, Codable, Sendable {

    /// Always use the light appearance.
    case light
    /// Always use the dark appearance.
    case dark
    /// Follow the system’s appearance settings automatically.
    case system

    /// The identifier for this case, used for `Identifiable` conformance.
    public var id: Self { self }

    public var value: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    public var icon: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        case .system: "gearshape.fill"
        }
    }

    public var description: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

#endif
