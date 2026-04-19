# Statement

A macOS app for importing and analyzing personal bank statements.

Statement reads exported statements from your bank, normalizes the data into accounts and transactions, and gives you a searchable history, category/rename rules, transfer pairing between your own accounts, and visual analytics of your spending.

## Features

- Drag-and-drop import of bank statements (SEB CSV/Excel and PDF exports)
- Multiple profiles, each with its own isolated SwiftData store
- Per-account browsing and an "All Transactions" view with search
- Category and rename rules that re-run safely without clobbering manual edits
- Automatic transfer detection between your own accounts, with a review sheet for ambiguous pairs
- Net-worth, category breakdown, and other analytics views
- Export/backup of rules and data
- Automatic updates via Sparkle

## Installation

Download the latest `Statement-<version>.dmg` from the [Releases](https://github.com/memfrag/Statement/releases) page and drag the app into `/Applications`. The app is signed and notarized, and will update itself via Sparkle.

## License

See the [LICENSE](LICENSE) file. Statement is distributed under the BSD Zero Clause License.
