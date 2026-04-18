//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Observable coordinator for the drop-to-import flow. Holds transient UI state
/// that shouldn't live in SwiftData: hover state, current import progress, and
/// the last import result to display in a summary sheet.
@MainActor
@Observable
final class ImportCoordinator: Identifiable {
    var isTargeted: Bool = false
    var isImporting: Bool = false
    var importStatus: String = ""
    var lastResult: ImportRunResult?
    /// Populated after the user dismisses `lastResult`'s summary sheet so the
    /// Review Transfers sheet can chain open if there are unresolved cases.
    var pendingReview: TransferReviewRequest?

    /// Run a drop/⌘O import on a background `StatementImportWorker` so the
    /// main thread stays responsive and the progress sheet can render.
    func run(_ urls: [URL], container: ModelContainer) async {
        guard !urls.isEmpty else {
            return
        }
        isImporting = true
        importStatus = "Preparing…"

        let worker = StatementImportWorker(modelContainer: container)
        let result = await worker.importFiles(urls: urls) { [weak self] status in
            self?.importStatus = status
        }

        isImporting = false
        importStatus = ""
        lastResult = result
    }
}

// MARK: - ImportRunResult identifiable

extension ImportRunResult: Identifiable {
    public var id: Int {
        // Stable enough for sheet presentation — changes every run.
        files.reduce(into: Hasher()) { hasher, file in
            hasher.combine(file.id)
        }.finalize()
    }
}

// MARK: - Drop modifier

struct StatementDropModifier: ViewModifier {
    let coordinator: ImportCoordinator
    let container: ModelContainer
    let signals: AppSignals

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: Binding(
                get: { coordinator.isTargeted },
                set: { coordinator.isTargeted = $0 }
            )) { providers in
                Task { @MainActor in
                    let urls = await loadURLs(from: providers)
                    let accepted = urls.filter {
                        let ext = $0.pathExtension.lowercased()
                        return ext == "xlsx" || ext == "pdf"
                    }
                    if !accepted.isEmpty {
                        await coordinator.run(accepted, container: container)
                        signals.bump()
                    }
                }
                return true
            }
            .overlay {
                if coordinator.isTargeted {
                    DropOverlay()
                }
            }
    }

    private func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url: URL = await withCheckedContinuation({ cont in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    cont.resume(returning: url)
                }
            }) {
                urls.append(url)
            }
        }
        return urls
    }
}

extension View {
    func statementDropReceiver(coordinator: ImportCoordinator,
                               container: ModelContainer,
                               signals: AppSignals) -> some View {
        modifier(StatementDropModifier(coordinator: coordinator, container: container, signals: signals))
    }
}

// MARK: - Progress sheet

struct ImportProgressSheet: View {
    let statusText: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text("Importing statements")
                    .font(.headline)
                Text(statusText.isEmpty ? "Please wait…" : statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(28)
        .frame(minWidth: 360, minHeight: 160)
        .interactiveDismissDisabled()
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(20)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Release to import")
                    .font(.title3.weight(.semibold))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Summary sheet

struct ImportSummarySheet: View {
    let result: ImportRunResult
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Import complete")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }

            summary

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.files) { file in
                        fileRow(file)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)
        }
        .padding(22)
        .frame(minWidth: 460)
    }

    private var summary: some View {
        let inserted = result.totalInserted
        let skipped = result.totalSkipped
        let failed = result.failureCount
        return HStack(spacing: 20) {
            stat("New", value: "\(inserted)", color: .green)
            stat("Duplicates skipped", value: "\(skipped)", color: .secondary)
            if failed > 0 {
                stat("Failed files", value: "\(failed)", color: .red)
            }
        }
    }

    private func stat(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func fileRow(_ file: ImportFileResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: file.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(file.success ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.callout.weight(.medium))
                if let error = file.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("\(file.accountName ?? "Account") · +\(file.inserted) new · \(file.skipped) skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
