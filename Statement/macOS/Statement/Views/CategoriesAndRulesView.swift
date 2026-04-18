//
//  Copyright © 2026 Apparata AB. All rights reserved.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct CategoriesAndRulesView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSignals.self) private var signals
    @Query(sort: [SortDescriptor(\Category.sortIndex)]) private var categories: [Category]
    @Query(sort: [SortDescriptor(\Subcategory.sortIndex)]) private var allSubcategories: [Subcategory]
    @Query(sort: [SortDescriptor(\CategoryRule.priority)]) private var rules: [CategoryRule]
    @Query(sort: [SortDescriptor(\RenameRule.priority)]) private var renameRules: [RenameRule]
    @Query private var allTransactions: [Transaction]

    enum RuleTab: String, CaseIterable, Identifiable {
        case category = "Category"
        case rename = "Rename"
        var id: String { rawValue }
    }
    @State private var ruleTab: RuleTab = .category

    @State private var selectedCategoryID: PersistentIdentifier?
    @State private var showNewCategorySheet: Bool = false
    @State private var newCategoryName: String = ""
    @State private var showNewSubcategorySheet: Bool = false
    @State private var newSubcategoryName: String = ""
    @State private var editingRule: CategoryRule?
    @State private var selectedRuleIDs: Set<PersistentIdentifier> = []
    @State private var showNewRuleSheet: Bool = false
    @State private var showReapplyConfirm: Bool = false

    @State private var editingRenameRule: RenameRule?
    @State private var selectedRenameRuleIDs: Set<PersistentIdentifier> = []
    @State private var showNewRenameRuleSheet: Bool = false
    @State private var showRenameReapplyConfirm: Bool = false

    var body: some View {
        // Compute hit counts once per body evaluation.
        let hits = computeHitCounts()

        return HStack(spacing: 0) {
            categoryColumn
                .frame(width: 280)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
            VStack(spacing: 0) {
                Picker("", selection: $ruleTab) {
                    ForEach(RuleTab.allCases) { tab in
                        Text("\(tab.rawValue) rules").tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 22)
                .padding(.top, 14)

                switch ruleTab {
                case .category:
                    rulesColumn(hits: hits)
                case .rename:
                    renameRulesColumn
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Categories & Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if ruleTab == .category {
                        showReapplyConfirm = true
                    } else {
                        showRenameReapplyConfirm = true
                    }
                } label: {
                    Label("Re-apply rules", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if ruleTab == .category {
                        editingRule = nil
                        showNewRuleSheet = true
                    } else {
                        editingRenameRule = nil
                        showNewRenameRuleSheet = true
                    }
                } label: {
                    Label("New rule", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export categories & rules…") { runExportRules() }
                    Button("Import categories & rules…") { runImportRules() }
                    Divider()
                    Button(ruleTab == .category ? "Delete all category rules…" : "Delete all rename rules…",
                           role: .destructive) {
                        runDeleteAllRules()
                    }
                } label: {
                    Label("Import / Export", systemImage: "square.and.arrow.up.on.square")
                }
            }
        }
        .sheet(isPresented: $showNewCategorySheet) {
            NewCategorySheet(name: $newCategoryName) {
                addCategory(newCategoryName)
                newCategoryName = ""
                showNewCategorySheet = false
            } onCancel: {
                newCategoryName = ""
                showNewCategorySheet = false
            }
        }
        .sheet(isPresented: $showNewSubcategorySheet) {
            NewCategorySheet(name: $newSubcategoryName, title: "New subcategory") {
                addSubcategory(newSubcategoryName)
                newSubcategoryName = ""
                showNewSubcategorySheet = false
            } onCancel: {
                newSubcategoryName = ""
                showNewSubcategorySheet = false
            }
        }
        .sheet(isPresented: $showNewRuleSheet) {
            RuleEditorSheet(existing: nil,
                            categories: categories,
                            subcategories: allSubcategories) { rule in
                context.insert(rule)
                try? context.save()
                signals.bump()
                showNewRuleSheet = false
            } onCancel: {
                showNewRuleSheet = false
            }
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(existing: rule,
                            categories: categories,
                            subcategories: allSubcategories) { _ in
                try? context.save()
                signals.bump()
                editingRule = nil
            } onCancel: {
                editingRule = nil
            }
        }
        .confirmationDialog("Re-apply all rules?",
                            isPresented: $showReapplyConfirm,
                            titleVisibility: .visible) {
            Button("Re-apply (keep manual)") {
                try? CategoryRuleEngine.applyToAll(in: context, preserveManual: true)
                try? context.save()
                signals.bump()
            }
            Button("Also overwrite manual", role: .destructive) {
                try? CategoryRuleEngine.applyToAll(in: context, preserveManual: false)
                try? context.save()
                signals.bump()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Rules will be re-evaluated against every transaction. Choosing to overwrite manual categorizations cannot be undone.")
        }
        .sheet(isPresented: $showNewRenameRuleSheet) {
            RenameRuleEditorSheet(existing: nil) { rule in
                context.insert(rule)
                try? context.save()
                signals.bump()
                showNewRenameRuleSheet = false
            } onCancel: {
                showNewRenameRuleSheet = false
            }
        }
        .sheet(item: $editingRenameRule) { rule in
            RenameRuleEditorSheet(existing: rule) { _ in
                try? context.save()
                signals.bump()
                editingRenameRule = nil
            } onCancel: {
                editingRenameRule = nil
            }
        }
        .confirmationDialog("Re-apply all rename rules?",
                            isPresented: $showRenameReapplyConfirm,
                            titleVisibility: .visible) {
            Button("Re-apply (keep manual renames)") {
                try? RenameRuleEngine.applyToAll(in: context, preserveManual: true)
                try? context.save()
                signals.bump()
            }
            Button("Also overwrite manual renames", role: .destructive) {
                try? RenameRuleEngine.applyToAll(in: context, preserveManual: false)
                try? context.save()
                signals.bump()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Rename rules will be re-evaluated against every transaction's raw bank text. Choosing to overwrite manual renames cannot be undone.")
        }
    }

    // MARK: Category list

    private var selectedCategory: Category? {
        guard let id = selectedCategoryID else {
            return nil
        }
        return categories.first { $0.persistentModelID == id }
    }

    private var categoryColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Categories")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if selectedCategory != nil {
                    Button {
                        showNewSubcategorySheet = true
                    } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Add subcategory to selected category")
                }
                Button {
                    showNewCategorySheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add category")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)

            List(selection: $selectedCategoryID) {
                ForEach(categories) { category in
                    categoryRow(category)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: Category) -> some View {
        DisclosureGroup {
            ForEach(category.subcategories.sorted(by: { $0.sortIndex < $1.sortIndex })) { sub in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    Text(sub.name)
                        .font(.callout)
                    Spacer()
                    Text("\(sub.transactions.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.leading, 8)
                .contextMenu {
                    Button("Delete subcategory", role: .destructive) {
                        context.delete(sub)
                        try? context.save()
                signals.bump()
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AccountPalette.color(for: category.colorIndex))
                    .frame(width: 10, height: 10)
                Text(category.name).font(.callout.weight(.medium))
                Spacer()
                Text("\(category.transactions.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .tag(category.persistentModelID)
        .contextMenu {
            Menu("Color") {
                ForEach(0..<AccountPalette.all.count, id: \.self) { i in
                    Button {
                        category.colorIndex = i
                        try? context.save()
                signals.bump()
                    } label: {
                        Label {
                            Text("Color \(i + 1)")
                        } icon: {
                            Circle().fill(AccountPalette.color(for: i))
                        }
                    }
                }
            }
            Button("Delete category", role: .destructive) {
                context.delete(category)
                try? context.save()
                signals.bump()
            }
        }
    }

    // MARK: Rules list

    private func rulesColumn(hits: [PersistentIdentifier: Int]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rules")
                    .font(.title2.weight(.bold))
                Text("First match wins · click a row to edit · applied automatically on import")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Table(rules, selection: $selectedRuleIDs) {
                TableColumn("#") { rule in
                    Text("\(rule.priority)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(36)

                TableColumn("Rule") { rule in
                    Text(rule.name).fontWeight(.semibold)
                }

                TableColumn("Match") { rule in
                    HStack(spacing: 4) {
                        Text("\(rule.matchField.label) \(rule.matchKind.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("“\(rule.pattern)”")
                            .font(.system(.caption, design: .monospaced))
                        if rule.signConstraint != .any {
                            Text("· \(rule.signConstraint.label)")
                                .font(.caption)
                                .foregroundStyle(rule.signConstraint == .positive ? Color.green : Color.red)
                        }
                    }
                }

                TableColumn("Category") { rule in
                    CategoryChip(category: rule.category, subcategory: rule.subcategory)
                }

                TableColumn("Hits") { rule in
                    Text("\(hits[rule.persistentModelID] ?? 0)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(60)
            }
            .contextMenu(forSelectionType: CategoryRule.ID.self) { ids in
                Button("Edit…") {
                    if let id = ids.first, let rule = rules.first(where: { $0.persistentModelID == id }) {
                        editingRule = rule
                    }
                }
                .disabled(ids.count != 1)

                Button("Delete", role: .destructive) {
                    for id in ids {
                        if let rule = rules.first(where: { $0.persistentModelID == id }) {
                            context.delete(rule)
                        }
                    }
                    try? context.save()
                signals.bump()
                    selectedRuleIDs.removeAll()
                }
                .disabled(ids.isEmpty)
            } primaryAction: { ids in
                if let id = ids.first, let rule = rules.first(where: { $0.persistentModelID == id }) {
                    editingRule = rule
                }
            }
        }
    }

    // MARK: Hit counts (memoized)

    /// Single-pass O(N·R) computation of hit counts per rule under first-match semantics.
    private func computeHitCounts() -> [PersistentIdentifier: Int] {
        var counts: [PersistentIdentifier: Int] = [:]
        for rule in rules {
            counts[rule.persistentModelID] = 0
        }
        for tx in allTransactions {
            if let first = CategoryRuleEngine.firstMatch(for: tx, rules: rules) {
                counts[first.persistentModelID, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: Actions

    private func addCategory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let nextIndex = categories.count
        let c = Category(name: trimmed, colorIndex: nextIndex, sortIndex: nextIndex)
        context.insert(c)
        try? context.save()
    }

    // MARK: Rename rules column

    private var renameRulesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename rules")
                    .font(.title2.weight(.bold))
                Text("Rewrite raw bank text · first match wins · applied automatically on import")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Table(renameRules, selection: $selectedRenameRuleIDs) {
                TableColumn("#") { rule in
                    Text("\(rule.priority)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(36)

                TableColumn("Rule") { rule in
                    Text(rule.name).fontWeight(.semibold)
                }

                TableColumn("Match") { rule in
                    HStack(spacing: 4) {
                        Text("Text \(rule.matchKind.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("“\(rule.pattern)”")
                            .font(.system(.caption, design: .monospaced))
                    }
                }

                TableColumn("→ Replacement") { rule in
                    Text("“\(rule.replacement)”")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .contextMenu(forSelectionType: RenameRule.ID.self) { ids in
                Button("Edit…") {
                    if let id = ids.first, let rule = renameRules.first(where: { $0.persistentModelID == id }) {
                        editingRenameRule = rule
                    }
                }
                .disabled(ids.count != 1)

                Button("Delete", role: .destructive) {
                    for id in ids {
                        if let rule = renameRules.first(where: { $0.persistentModelID == id }) {
                            context.delete(rule)
                        }
                    }
                    try? context.save()
                    signals.bump()
                    selectedRenameRuleIDs.removeAll()
                }
                .disabled(ids.isEmpty)
            } primaryAction: { ids in
                if let id = ids.first, let rule = renameRules.first(where: { $0.persistentModelID == id }) {
                    editingRenameRule = rule
                }
            }
        }
    }

    private func addSubcategory(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parent = selectedCategory else {
            return
        }
        let sub = Subcategory(name: trimmed, sortIndex: parent.subcategories.count, parent: parent)
        context.insert(sub)
        try? context.save()
    }

    // MARK: Rule set I/O

    @MainActor
    private func runExportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Statement-categories-and-rules.json"
        panel.prompt = "Export"
        panel.message = "Export all categories, subcategories, category rules, and rename rules to a JSON file."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor in
                do {
                    try RuleSetExporter.export(to: url, context: context)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Export failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @MainActor
    private func runDeleteAllRules() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch ruleTab {
        case .category:
            alert.messageText = "Delete all category rules?"
            alert.informativeText = "Every category rule will be removed. Categories themselves stay. Manually assigned categories on transactions are unaffected. This can't be undone — export them first if you might want them back."
        case .rename:
            alert.messageText = "Delete all rename rules?"
            alert.informativeText = "Every rename rule will be removed. Rule-applied renames on existing transactions stay until you re-apply rules. Manual renames are unaffected. This can't be undone — export them first if you might want them back."
        }
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        if alert.buttons.count >= 1 {
            alert.buttons[0].hasDestructiveAction = true
        }
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            switch ruleTab {
            case .category:
                for r in try context.fetch(FetchDescriptor<CategoryRule>()) {
                    context.delete(r)
                }
            case .rename:
                for r in try context.fetch(FetchDescriptor<RenameRule>()) {
                    context.delete(r)
                }
            }
            try context.save()
            signals.bump()
        } catch {
            let err = NSAlert()
            err.messageText = "Delete failed"
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }

    @MainActor
    private func runImportRules() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Pick a categories and rules JSON file to import."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor in
                let confirm = NSAlert()
                confirm.alertStyle = .warning
                confirm.messageText = "Replace all categories and rules?"
                confirm.informativeText = "This will delete every existing category, subcategory, category rule, and rename rule, then insert the contents of the file. Transactions whose current category exists in the new file are kept; transactions whose category is missing become uncategorized. This can't be undone."
                confirm.addButton(withTitle: "Replace")
                confirm.addButton(withTitle: "Cancel")
                if confirm.buttons.count >= 1 {
                    confirm.buttons[0].hasDestructiveAction = true
                }
                guard confirm.runModal() == .alertFirstButtonReturn else {
                    return
                }

                do {
                    let summary = try RuleSetImporter.importRules(from: url, context: context)
                    signals.bump()
                    let alert = NSAlert()
                    alert.messageText = "Categories & rules replaced"
                    alert.informativeText = """
                        \(summary.categoriesInserted) categories · \
                        \(summary.subcategoriesInserted) subcategories
                        \(summary.categoryRulesInserted) category rules · \
                        \(summary.renameRulesInserted) rename rules
                        \(summary.transactionsRelinked) transactions re-linked · \
                        \(summary.transactionsOrphaned) orphaned
                        """
                    alert.runModal()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Import failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - New category / subcategory sheet

private struct NewCategorySheet: View {
    @Binding var name: String
    var title: String = "New category"
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Add", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Rule editor sheet (create or edit)

private struct RuleEditorSheet: View {
    let existing: CategoryRule?
    let categories: [Category]
    let subcategories: [Subcategory]
    var onCommit: (CategoryRule) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""
    @State private var field: RuleField = .text
    @State private var kind: RuleMatchKind = .contains
    @State private var pattern: String = ""
    @State private var categoryID: PersistentIdentifier?
    @State private var subcategoryID: PersistentIdentifier?
    @State private var priority: Int = 0
    @State private var signConstraint: RuleSignConstraint = .any

    private var title: String { existing == nil ? "New rule" : "Edit rule" }
    private var actionLabel: String { existing == nil ? "Add" : "Save" }

    private var subcategoriesForSelected: [Subcategory] {
        guard let id = categoryID else {
            return []
        }
        return subcategories
            .filter { $0.parent?.persistentModelID == id }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)

            Form {
                TextField("Name", text: $name)
                Picker("Match field", selection: $field) {
                    ForEach(RuleField.allCases, id: \.self) { f in Text(f.label).tag(f) }
                }
                Picker("Match kind", selection: $kind) {
                    ForEach(RuleMatchKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
                }
                TextField("Pattern", text: $pattern)
                Picker("Amount sign", selection: $signConstraint) {
                    ForEach(RuleSignConstraint.allCases, id: \.self) { sign in
                        Text(sign.label).tag(sign)
                    }
                }
                Picker("Category", selection: $categoryID) {
                    Text("None").tag(Optional<PersistentIdentifier>.none)
                    ForEach(categories) { c in
                        Text(c.name).tag(Optional(c.persistentModelID))
                    }
                }
                if !subcategoriesForSelected.isEmpty {
                    Picker("Subcategory", selection: $subcategoryID) {
                        Text("None").tag(Optional<PersistentIdentifier>.none)
                        ForEach(subcategoriesForSelected) { sub in
                            Text(sub.name).tag(Optional(sub.persistentModelID))
                        }
                    }
                }
                TextField("Priority", value: $priority, format: .number)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(actionLabel) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear(perform: loadFromExisting)
        .onChange(of: categoryID) { _, _ in
            // Clear subcategory when parent changes
            if !subcategoriesForSelected.contains(where: { $0.persistentModelID == subcategoryID }) {
                subcategoryID = nil
            }
        }
    }

    private func loadFromExisting() {
        guard let rule = existing else {
            priority = Int(Date().timeIntervalSince1970)
            return
        }
        name = rule.name
        field = rule.matchField
        kind = rule.matchKind
        pattern = rule.pattern
        categoryID = rule.category?.persistentModelID
        subcategoryID = rule.subcategory?.persistentModelID
        priority = rule.priority
        signConstraint = rule.signConstraint
    }

    private func commit() {
        let cat = categories.first { $0.persistentModelID == categoryID }
        let sub = subcategories.first { $0.persistentModelID == subcategoryID }
        if let existing {
            existing.name = name.isEmpty ? pattern : name
            existing.matchField = field
            existing.matchKind = kind
            existing.pattern = pattern
            existing.category = cat
            existing.subcategory = sub
            existing.priority = priority
            existing.signConstraint = signConstraint
            onCommit(existing)
        } else {
            let rule = CategoryRule(
                name: name.isEmpty ? pattern : name,
                priority: priority,
                matchField: field,
                matchKind: kind,
                pattern: pattern,
                category: cat,
                subcategory: sub,
                signConstraint: signConstraint
            )
            onCommit(rule)
        }
    }
}

// MARK: - Rename rule editor sheet

private struct RenameRuleEditorSheet: View {
    let existing: RenameRule?
    var onCommit: (RenameRule) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""
    @State private var kind: RuleMatchKind = .contains
    @State private var pattern: String = ""
    @State private var replacement: String = ""
    @State private var priority: Int = 0

    private var title: String { existing == nil ? "New rename rule" : "Edit rename rule" }
    private var actionLabel: String { existing == nil ? "Add" : "Save" }

    /// Only string-matching kinds are valid for renames; amount comparisons
    /// don't make sense here.
    private static let allowedKinds: [RuleMatchKind] = [.contains, .equals, .startsWith, .endsWith, .regex]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)

            Form {
                TextField("Name", text: $name)
                Picker("Match kind", selection: $kind) {
                    ForEach(Self.allowedKinds, id: \.self) { k in Text(k.label).tag(k) }
                }
                TextField("Pattern", text: $pattern)
                    .help("Matches against the raw bank text (not the cleaned display text).")
                TextField("Replacement", text: $replacement)
                    .help("For contains/equals: replaces the whole text. For regex: supports $1 backrefs.")
                TextField("Priority", value: $priority, format: .number)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(actionLabel) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear(perform: loadFromExisting)
    }

    private func loadFromExisting() {
        guard let rule = existing else {
            priority = Int(Date().timeIntervalSince1970)
            return
        }
        name = rule.name
        kind = rule.matchKind
        pattern = rule.pattern
        replacement = rule.replacement
        priority = rule.priority
    }

    private func commit() {
        if let existing {
            existing.name = name.isEmpty ? pattern : name
            existing.matchKind = kind
            existing.pattern = pattern
            existing.replacement = replacement
            existing.priority = priority
            onCommit(existing)
        } else {
            let rule = RenameRule(
                name: name.isEmpty ? pattern : name,
                priority: priority,
                matchKind: kind,
                pattern: pattern,
                replacement: replacement
            )
            onCommit(rule)
        }
    }
}
