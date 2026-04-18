//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import Foundation

/// Cleanup transforms applied to raw `Text` values read from SEB XLSX
/// exports. The XLSX format writes merchant descriptions in ALL CAPS
/// and often suffixes them with a short `/YY-MM-DD` token — e.g.
/// `"ICA SUPERMAR/26-04-07"`. `cleanXLSXText` strips the suffix and
/// converts the remainder to localized title case, so the example
/// becomes `"Ica Supermar"`.
///
/// PDF-sourced text already arrives richly described and properly
/// cased; it should NOT be passed through this cleanup.
enum TextCleanup {

    /// Matches a trailing `[whitespace]/YY-MM-DD[whitespace]` suffix.
    /// Anchored to end-of-string with `$` so only the suffix is stripped.
    private nonisolated static let trailingSlashDateRegex: NSRegularExpression = {
        let pattern = #"\s*/\s*\d{2}-\d{2}-\d{2}\s*$"#
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            fatalError("TextCleanup regex failed: \(error)")
        }
    }()

    /// Cleans a SEB XLSX `Text` cell:
    ///   1. Trims whitespace.
    ///   2. Strips any trailing `/YY-MM-DD` suffix.
    ///   3. Converts the result to localized title case.
    ///
    /// Idempotent: applying `cleanXLSXText` to an already-cleaned
    /// string returns the same string.
    nonisolated static func cleanXLSXText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let stripped = trailingSlashDateRegex.stringByReplacingMatches(
            in: trimmed,
            options: [],
            range: range,
            withTemplate: ""
        )
        let final = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.localizedCapitalized
    }
}
