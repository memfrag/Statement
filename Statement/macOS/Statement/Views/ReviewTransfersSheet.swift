//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData

/// Identifiable wrapper for sheet presentation. `.sheet(item:)` needs an
/// Identifiable payload; a bare array of IDs isn't enough.
struct TransferReviewRequest: Identifiable, Equatable {
    let id = UUID()
    /// When non-empty, only show these specific outgoing IDs. When empty,
    /// fetch every `.ambiguous` / `.unmatched` row in the store (on-demand
    /// mode triggered by the menu command).
    let outgoingIDs: [PersistentIdentifier]
}

// MARK: - Per-card local selection state

private enum CardSelection: Equatable {
    case unset
    case candidate(PersistentIdentifier)
    case noneOfThese         // ambiguous → flip to unmatched
    case leaveUnresolved     // unmatched → stay unmatched
    case markAsExternal      // unmatched → clear flag permanently
}

// MARK: - Sheet

struct ReviewTransfersSheet: View {
    let request: TransferReviewRequest
    var onDismiss: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppSignals.self) private var signals

    @State private var outgoing: [Transaction] = []
    @State private var candidatesByOutgoing: [PersistentIdentifier: [Transaction]] = [:]
    @State private var destinationNameByOutgoing: [PersistentIdentifier: String] = [:]
    @State private var selection: [PersistentIdentifier: CardSelection] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review Transfers")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Skip All", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }

            if outgoing.isEmpty {
                Text("No transfers need review.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                Text("\(outgoing.count) outgoing transfer\(outgoing.count == 1 ? "" : "s") need\(outgoing.count == 1 ? "s" : "") your attention.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(outgoing) { tx in
                            card(for: tx)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 260, idealHeight: 360, maxHeight: 520)

                HStack {
                    Spacer()
                    Button("Apply") {
                        apply()
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasAnySelection)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 620)
        .onAppear(perform: load)
    }

    // MARK: Card

    @ViewBuilder
    private func card(for tx: Transaction) -> some View {
        let destination = destinationNameByOutgoing[tx.persistentModelID]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(tx.transferStatus == .ambiguous ? Color.orange : Color.red)
                Text(tx.transferStatus == .ambiguous ? "Ambiguous" : "No match found")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(tx.account?.displayName ?? "—") → \(destination ?? "—")")
                    .font(.callout.weight(.semibold))
                Text("\(DateFormatters.shortDay.string(from: tx.bookingDate)) · \(MoneyFormatter.signedString(tx.amount)) kr")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("Source text: \(tx.text)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Divider()

            switch tx.transferStatus {
            case .ambiguous:
                ambiguousChoices(for: tx, destination: destination)
            case .unmatched:
                unmatchedChoices(for: tx, destination: destination)
            default:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func ambiguousChoices(for tx: Transaction, destination: String?) -> some View {
        let id = tx.persistentModelID
        let candidates = candidatesByOutgoing[id] ?? []
        let current = selection[id] ?? .unset

        Text("Which deposit in \(destination ?? "the destination") matches?")
            .font(.caption)
            .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 6) {
            ForEach(candidates) { candidate in
                choiceRow(
                    isSelected: current == .candidate(candidate.persistentModelID),
                    label: "+\(MoneyFormatter.string(candidate.amount)) · \(candidate.text)"
                ) {
                    selection[id] = .candidate(candidate.persistentModelID)
                }
            }
            choiceRow(
                isSelected: current == .noneOfThese,
                label: "None of these (leave as unmatched)"
            ) {
                selection[id] = .noneOfThese
            }
        }
    }

    @ViewBuilder
    private func unmatchedChoices(for tx: Transaction, destination: String?) -> some View {
        let id = tx.persistentModelID
        let current = selection[id] ?? .leaveUnresolved

        Text("No positive of \(MoneyFormatter.string(abs(tx.amount))) kr in \(destination ?? "the destination") on \(DateFormatters.shortDay.string(from: tx.bookingDate)). Possible causes:")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("• destination statement not imported yet")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("• not actually an internal transfer")
            .font(.caption)
            .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 6) {
            choiceRow(
                isSelected: current == .leaveUnresolved,
                label: "Leave unresolved (will retry on next import)"
            ) {
                selection[id] = .leaveUnresolved
            }
            choiceRow(
                isSelected: current == .markAsExternal,
                label: "Mark as external (not a transfer)"
            ) {
                selection[id] = .markAsExternal
            }
        }
    }

    @ViewBuilder
    private func choiceRow(isSelected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

    private func load() {
        let targets: [Transaction]
        if request.outgoingIDs.isEmpty {
            targets = TransferPairingService.fetchUnresolved(in: context)
        } else {
            let ids = request.outgoingIDs
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { ids.contains($0.persistentModelID) },
                sortBy: [SortDescriptor(\Transaction.bookingDate)]
            )
            targets = (try? context.fetch(descriptor)) ?? []
        }
        outgoing = targets.filter { $0.transferStatus.isUnresolved }

        let known = InternalTransferDetector.knownAccounts(in: context)
        var candidates: [PersistentIdentifier: [Transaction]] = [:]
        var destinations: [PersistentIdentifier: String] = [:]
        for tx in outgoing {
            candidates[tx.persistentModelID] = TransferPairingService.candidates(
                for: tx, in: context
            )
            if let destinationAccount = InternalTransferDetector.matchedDestination(
                for: tx.text, known: known
            ) {
                destinations[tx.persistentModelID] = destinationAccount.displayName
            }
        }
        candidatesByOutgoing = candidates
        destinationNameByOutgoing = destinations

        var initial: [PersistentIdentifier: CardSelection] = [:]
        for tx in outgoing where tx.transferStatus == .unmatched {
            initial[tx.persistentModelID] = .leaveUnresolved
        }
        selection = initial
    }

    private var hasAnySelection: Bool {
        !selection.isEmpty
    }

    private func apply() {
        for tx in outgoing {
            let id = tx.persistentModelID
            guard let choice = selection[id] else {
                continue
            }
            switch choice {
            case .unset:
                continue
            case .candidate(let candidateID):
                if let picked = candidatesByOutgoing[id]?.first(where: { $0.persistentModelID == candidateID }) {
                    TransferPairingService.applyUserPair(outgoing: tx, picked: picked, in: context)
                }
            case .noneOfThese:
                TransferPairingService.demoteToUnmatched(tx)
            case .leaveUnresolved:
                break
            case .markAsExternal:
                TransferPairingService.markAsExternal(tx, in: context)
            }
        }
        try? context.save()
        signals.bump()
    }
}

