//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI

extension EdgeInsets {

    /// ```swift
    /// ScrollView {
    ///     // ...
    /// }
    /// .contentMargins(.vertical, .top(50), for: .scrollContent)
    /// ```
    static func top(_ inset: CGFloat) -> EdgeInsets {
        return .init(top: inset, leading: 0, bottom: 0, trailing: 0)
    }

    /// ```swift
    /// ScrollView {
    ///     // ...
    /// }
    /// .contentMargins(.vertical, .leading(50), for: .scrollContent)
    /// ```
    static func leading(_ inset: CGFloat) -> EdgeInsets {
        return .init(top: 0, leading: inset, bottom: 0, trailing: 0)
    }

    /// ```swift
    /// ScrollView {
    ///     // ...
    /// }
    /// .contentMargins(.vertical, .bottom(50), for: .scrollContent)
    /// ```
    static func bottom(_ inset: CGFloat) -> EdgeInsets {
        return .init(top: 0, leading: 0, bottom: inset, trailing: 0)
    }

    /// ```swift
    /// ScrollView {
    ///     // ...
    /// }
    /// .contentMargins(.vertical, .trailing(50), for: .scrollContent)
    /// ```
    static func trailing(_ inset: CGFloat) -> EdgeInsets {
        return .init(top: 0, leading: 0, bottom: 0, trailing: inset)
    }
}
