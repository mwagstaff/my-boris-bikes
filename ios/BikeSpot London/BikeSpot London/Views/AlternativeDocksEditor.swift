import CoreLocation
import SwiftUI

struct AlternativeDocksEditor: View {
    let dock: ScheduledJourneyDock
    var availabilityMode: DockPickerView.AvailabilityMode = .start
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preferences = DockPreferencesService.shared
    @State private var docks: [ScheduledJourneyDock]
    @State private var usesCustomList: Bool
    @State private var editedAliases: [String: String] = [:]
    @State private var presentedSheet: EditorSheet?

    private enum EditorSheet: Identifiable {
        case picker
        case alias(ScheduledJourneyDock)

        var id: String {
            switch self {
            case .picker: "picker"
            case .alias(let dock): "alias-\(dock.id)"
            }
        }
    }

    init(dock: ScheduledJourneyDock, availabilityMode: DockPickerView.AvailabilityMode = .start) {
        self.dock = dock
        self.availabilityMode = availabilityMode
        let saved = DockPreferencesService.shared.customDocks(for: dock.id)
        _docks = State(initialValue: saved ?? [])
        _usesCustomList = State(initialValue: saved != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(preferences.alias(for: dock.id) ?? dock.name)
                        .font(.headline)
                    if preferences.alias(for: dock.id) != nil {
                        Text(dock.name).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Alternatives and custom names apply wherever you use these docks. Saving here updates dock settings separately from your journey.")
                }

                Section {
                    if usesCustomList {
                        if docks.isEmpty {
                            Text("No alternatives selected. Add a dock, or use automatic alternatives.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(docks) { alternative in
                            alternativeRow(alternative)
                        }
                        .onMove { offsets, destination in
                            docks.move(fromOffsets: offsets, toOffset: destination)
                        }
                        .onDelete { offsets in docks.remove(atOffsets: offsets) }
                    } else {
                        Text("Nearby alternatives are chosen automatically.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(usesCustomList ? "Custom alternatives" : "Automatic alternatives")
                } footer: {
                    if usesCustomList {
                        Text("Drag the handles to set your preferred order. Favourites keeps every chosen dock in this order, with its availability shown alongside.")
                    }
                }

                Section {
                    Button { presentedSheet = .picker } label: {
                        Label("Add alternative", systemImage: "plus.circle")
                    }
                    if usesCustomList {
                        Button("Use automatic alternatives") {
                            usesCustomList = false
                            docks = []
                        }
                    }
                }

                if !preferences.snapshot.settings.enabled {
                    Section {
                        Text("Nearby alternatives are switched off in Preferences. You can still save your choices here.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Nearby alternatives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        preferences.saveAlternatives(for: dock, docks: usesCustomList ? docks : nil, aliases: editedAliases)
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled()
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .picker:
                    DockPickerView(
                        title: "Add alternative",
                        availabilityMode: availabilityMode,
                        referenceDock: dock,
                        excludedDockIDs: Set(docks.map(\.id))
                    ) { selected in
                        guard selected.id != dock.id, !docks.contains(where: { $0.id == selected.id }) else { return }
                        docks.append(selected)
                        usesCustomList = true
                        presentedSheet = nil
                    }
                case .alias(let alternative):
                    FavoriteAliasEditor(
                        bikePoint: BikePoint(id: alternative.id, commonName: alternative.name, lat: alternative.latitude, lon: alternative.longitude),
                        initialAlias: alias(for: alternative.id) ?? "",
                        onSave: { alias in
                            editedAliases[alternative.id] = alias ?? ""
                            presentedSheet = nil
                        },
                        onRemove: {
                            editedAliases[alternative.id] = ""
                            presentedSheet = nil
                        },
                        onCancel: { presentedSheet = nil }
                    )
                }
            }
        }
    }

    private func alternativeRow(_ alternative: ScheduledJourneyDock) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(alias(for: alternative.id) ?? alternative.name)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if alias(for: alternative.id) != nil {
                    Text(alternative.name).font(.caption).foregroundStyle(.secondary)
                }
                if alternative.latitude != 0 || alternative.longitude != 0 {
                    let distance = CLLocation(latitude: dock.latitude, longitude: dock.longitude)
                        .distance(from: CLLocation(latitude: alternative.latitude, longitude: alternative.longitude))
                    Text(distance < 1000 ? String(format: "%.0fm from this dock", distance) : String(format: "%.1f miles from this dock", distance / 1609.344))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { presentedSheet = .alias(alternative) } label: {
                Image(systemName: "pencil").frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit name for \(alias(for: alternative.id) ?? alternative.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("Position \((docks.firstIndex(where: { $0.id == alternative.id }) ?? 0) + 1) of \(docks.count)")
        .accessibilityAction(named: "Move up") { move(alternative, by: -1) }
        .accessibilityAction(named: "Move down") { move(alternative, by: 1) }
        .accessibilityAction(named: "Remove") { docks.removeAll { $0.id == alternative.id } }
    }

    private func alias(for id: String) -> String? {
        if let edited = editedAliases[id] {
            let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return preferences.alias(for: id)
    }

    private func move(_ dock: ScheduledJourneyDock, by offset: Int) {
        guard let index = docks.firstIndex(where: { $0.id == dock.id }), docks.indices.contains(index + offset) else { return }
        docks.swapAt(index, index + offset)
    }
}

struct AlternativeDocksEditButton: View {
    let dock: ScheduledJourneyDock
    var title = "Edit alternatives"
    var availabilityMode: DockPickerView.AvailabilityMode = .start
    @ObservedObject private var preferences = DockPreferencesService.shared
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack {
                Label(title, systemImage: "list.bullet")
                Spacer(minLength: 8)
                Text(preferences.customDockIDs(for: dock.id).map { "Custom · \($0.count)" } ?? "Automatic")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $isPresented) {
            AlternativeDocksEditor(dock: dock, availabilityMode: availabilityMode)
        }
    }
}
