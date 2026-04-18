//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation
import Constructs

/// A utility class for accessing the app's version and build information,
/// as defined in the app bundle's Info.plist.
///
/// `AppVersion` provides convenient accessors for:
/// - The semantic app version (CFBundleShortVersionString) as a `String`
/// - The build version (CFBundleVersion) as a `String`
/// - A parsed `VersionNumber` (from the Constructs module), if the version string is valid
///
/// It also conforms to `CustomStringConvertible` to present a human-readable
/// combined version and build string in the format: "X.Y.Z (Build)".
///
public class AppVersion: CustomStringConvertible {

    /// The app's semantic version parsed into a `VersionNumber`.
    public static var appVersion: VersionNumber? {
        guard let versionString = appVersionString else {
            return nil
        }
        return try? VersionNumber(versionString)
    }

    /// The app's semantic version as a string.
    public static var appVersionString: String? {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The app's build version as a string.
    public static var buildVersionString: String? {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// Returns the app version and build version as a string on the format 1.2.3 (456)
    public var description: String {
        "\(Self.appVersionString ?? "N/A") (\(Self.buildVersionString ?? "N/A"))"
    }
}
