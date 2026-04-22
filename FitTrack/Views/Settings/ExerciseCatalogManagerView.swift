import SwiftUI
import CoreData

/// Settings → Manage Exercises. Lists every `ExerciseCatalog` row, lets the
/// user edit metadata, merge variants, and delete user-created entries that
/// have no references.
struct ExerciseCatalogManagerView: View {
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ExerciseCatalog.isUnreviewed, ascending: false),
            NSSortDescriptor(keyPath: \ExerciseCatalog.canonicalName, ascending: true)
        ]
    ) private var entries: FetchedResults<ExerciseCatalog>

    @State private var search = ""
    @State private var mergeSource: ExerciseCatalog?

    private var filtered: [ExerciseCatalog] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(entries) }
        return entries.filter { e in
            if (e.canonicalName ?? "").lowercased().contains(q) { return true }
            if (e.aliases ?? "").lowercased().contains(q) { return true }
            return false
        }
    }

    var body: some View {
        List {
            ForEach(filtered, id: \.objectID) { entry in
                NavigationLink {
                    ExerciseCatalogEditView(entry: entry)
                } label: {
                    row(for: entry)
                }
                .listRowBackground(Theme.Colors.surface)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        mergeSource = entry
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                    }
                    .tint(Theme.Colors.blue)

                    if canDelete(entry) {
                        Button(role: .destructive) {
                            delete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background.ignoresSafeArea())
        .searchable(text: $search, prompt: "Search exercises")
        .navigationTitle("Manage Exercises")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(item: $mergeSource) { source in
            MergeTargetPicker(source: source) { target in
                performMerge(source: source, target: target)
                mergeSource = nil
            } cancel: {
                mergeSource = nil
            }
        }
        .onAppear {
            AppLogger.shared.log("ExerciseCatalogManagerView appeared (\(entries.count) entries)", category: "ui")
        }
    }

    private func row(for entry: ExerciseCatalog) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(entry.isUnreviewed ? Theme.Colors.orange : Color.clear)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.canonicalName ?? "(unnamed)")
                    .foregroundStyle(Theme.Colors.textPrimary)
                let aliases = ExerciseCatalogService.shared.aliasList(for: entry)
                if !aliases.isEmpty {
                    Text(aliases.prefix(2).joined(separator: ", "))
                        .font(Theme.Fonts.body(11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text((entry.equipment ?? "").capitalized)
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func canDelete(_ entry: ExerciseCatalog) -> Bool {
        guard entry.isUserCreated, let id = entry.id else { return false }
        let ex = NSFetchRequest<NSFetchRequestResult>(entityName: "Exercise")
        ex.predicate = NSPredicate(format: "canonicalExerciseID == %@", id as CVarArg)
        let exCount = (try? context.count(for: ex)) ?? 0
        let lg = NSFetchRequest<NSFetchRequestResult>(entityName: "LoggedSet")
        lg.predicate = NSPredicate(format: "canonicalExerciseID == %@", id as CVarArg)
        let lgCount = (try? context.count(for: lg)) ?? 0
        return exCount == 0 && lgCount == 0
    }

    private func delete(_ entry: ExerciseCatalog) {
        let name = entry.canonicalName ?? "?"
        context.delete(entry)
        do {
            try context.save()
            AppLogger.shared.log("deleted catalog entry '\(name)'", category: "catalog")
        } catch {
            AppLogger.shared.log("delete catalog FAILED: \(error)", category: "catalog")
        }
    }

    private func performMerge(source: ExerciseCatalog, target: ExerciseCatalog) {
        guard let sid = source.id, let tid = target.id else { return }
        do {
            try ExerciseCatalogService.shared.merge(source: sid, into: tid, context: context)
        } catch {
            AppLogger.shared.log("merge FAILED: \(error)", category: "catalog")
        }
    }
}

// MARK: - Edit screen

private struct ExerciseCatalogEditView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var entry: ExerciseCatalog

    @State private var canonicalName = ""
    @State private var aliases = ""
    @State private var movement: MovementPattern = .conditioning
    @State private var equipment: Equipment = .body
    @State private var primaryMuscle = ""
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Canonical name", text: $canonicalName)
                    .textInputAutocapitalization(.words)
            }
            Section {
                TextField("Aliases (comma-separated)", text: $aliases, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Aliases")
            } footer: {
                Text("Variants the importer should auto-bind to this exercise.")
                    .font(Theme.Fonts.body(11))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Section("Classification") {
                Picker("Movement", selection: $movement) {
                    ForEach(MovementPattern.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                Picker("Equipment", selection: $equipment) {
                    ForEach(Equipment.allCases, id: \.self) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                TextField("Primary muscle (optional)", text: $primaryMuscle)
            }
            if entry.isUnreviewed {
                Section {
                    Button("Mark as reviewed") {
                        entry.isUnreviewed = false
                        save()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.background.ignoresSafeArea())
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Colors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    apply()
                    save()
                    dismiss()
                }
            }
        }
        .onAppear { loadFields() }
    }

    private func loadFields() {
        guard !didLoad else { return }
        didLoad = true
        canonicalName = entry.canonicalName ?? ""
        aliases = entry.aliases ?? ""
        movement = MovementPattern(rawValue: entry.movementPattern ?? "") ?? .conditioning
        equipment = Equipment(rawValue: entry.equipment ?? "") ?? .body
        primaryMuscle = entry.primaryMuscle ?? ""
    }

    private func apply() {
        entry.canonicalName = canonicalName.trimmingCharacters(in: .whitespaces)
        entry.aliases = aliases.trimmingCharacters(in: .whitespaces)
        entry.movementPattern = movement.rawValue
        entry.equipment = equipment.rawValue
        let trimmedMuscle = primaryMuscle.trimmingCharacters(in: .whitespaces)
        entry.primaryMuscle = trimmedMuscle.isEmpty ? nil : trimmedMuscle
    }

    private func save() {
        do {
            try context.save()
            AppLogger.shared.log("saved catalog entry '\(entry.canonicalName ?? "?")'", category: "catalog")
        } catch {
            AppLogger.shared.log("save catalog FAILED: \(error)", category: "catalog")
        }
    }
}

// MARK: - Merge target picker

private struct MergeTargetPicker: View {
    let source: ExerciseCatalog
    let pick: (ExerciseCatalog) -> Void
    let cancel: () -> Void

    @Environment(\.managedObjectContext) private var context
    @State private var search = ""

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ExerciseCatalog.canonicalName, ascending: true)]
    ) private var entries: FetchedResults<ExerciseCatalog>

    private var candidates: [ExerciseCatalog] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { e in
            guard e.id != source.id else { return false }
            if q.isEmpty { return true }
            if (e.canonicalName ?? "").lowercased().contains(q) { return true }
            if (e.aliases ?? "").lowercased().contains(q) { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Merging '\(source.canonicalName ?? "?")' into…")
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .listRowBackground(Theme.Colors.surface)
                }
                ForEach(candidates, id: \.objectID) { target in
                    Button {
                        pick(target)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.canonicalName ?? "(unnamed)")
                                .foregroundStyle(Theme.Colors.textPrimary)
                            let aliases = ExerciseCatalogService.shared.aliasList(for: target)
                            if !aliases.isEmpty {
                                Text(aliases.prefix(2).joined(separator: ", "))
                                    .font(Theme.Fonts.body(11))
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }
                        }
                    }
                    .listRowBackground(Theme.Colors.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.background.ignoresSafeArea())
            .searchable(text: $search, prompt: "Search target")
            .navigationTitle("Merge into…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Colors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { cancel() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
