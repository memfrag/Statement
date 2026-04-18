//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData

struct ImportHistoryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSignals.self) private var signals
    @Query(sort: [SortDescriptor(\ImportBatch.importedAt, order: .reverse)])
    private var batches: [ImportBatch]

    @State private var confirmUndo: ImportBatch?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if batches.isEmpty {
                    Text("No imports yet.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(batches) { batch in
                        batchCard(batch)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Import History")
        .confirmationDialog("Undo this import?",
                            isPresented: Binding(get: { confirmUndo != nil },
                                                 set: { if !$0 { confirmUndo = nil } }),
                            titleVisibility: .visible) {
            Button("Delete \(confirmUndo?.rowCountInserted ?? 0) transactions", role: .destructive) {
                if let batch = confirmUndo {
                    undo(batch)
                }
                confirmUndo = nil
            }
            Button("Cancel", role: .cancel) { confirmUndo = nil }
        } message: {
            Text("This will remove every transaction that was inserted by this batch. It cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import History")
                .font(.system(size: 22, weight: .bold))
            Text("\(batches.count) atomic batches")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func batchCard(_ batch: ImportBatch) -> some View {
        HStack(alignment: .center, spacing: 16) {
            stamp(for: batch.importedAt)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(batch.account?.displayName ?? "—").fontWeight(.semibold)
                    Text(batch.sourceFilename)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text("+ \(batch.rowCountInserted) new")
                        .foregroundStyle(Color.green)
                        .fontWeight(.semibold)
                    Text("\(batch.rowCountSkipped) skipped")
                        .foregroundStyle(.secondary)
                    Text("imported \(batch.importedAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }

            Spacer()

            Button {
                confirmUndo = batch
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .foregroundStyle(Color.red)
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .contextMenu {
            Button("Delete \(batch.rowCountInserted) transactions…", role: .destructive) {
                confirmUndo = batch
            }
        }
    }

    private func stamp(for date: Date) -> some View {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        let month = DateFormatter().monthSymbols.map { $0.prefix(3) } // unused
        _ = month
        let mFormatter = DateFormatter()
        mFormatter.dateFormat = "MMM"
        let monthName = mFormatter.string(from: date).uppercased()

        return VStack(spacing: 0) {
            Text("\(day)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(monthName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 44, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
        .foregroundStyle(Color.accentColor)
    }

    private func undo(_ batch: ImportBatch) {
        for tx in batch.transactions {
            context.delete(tx)
        }
        context.delete(batch)
        try? context.save()

        // The batch may have supplied the outgoing or incoming legs of
        // transfers in other batches. Rescan to repair paired/ambiguous/
        // unmatched flags now that those transactions are gone.
        _ = TransferPairingService.rescanAll(in: context)
        try? context.save()

        signals.bump()
    }
}
