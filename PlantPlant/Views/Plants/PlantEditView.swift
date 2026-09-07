import SwiftUI
import SwiftData
import PhotosUI

/// Add or edit a plant. Pass `nil` to create a new one.
struct PlantEditView: View {
    let plant: Plant?
    /// Called after the plant is archived or deleted from this screen, so a presenting detail
    /// view can pop itself.
    var onRemoved: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Room.name) private var rooms: [Room]

    @State private var name = ""
    @State private var scientificName = ""
    @State private var notes = ""
    @State private var sunlight: SunlightLevel = .brightIndirect
    @State private var soilDryness: SoilDryness = .topDry
    @State private var acquiredDate = Date()
    @State private var selectedRoom: Room?
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingLibrary = false
    @State private var drafts: [ScheduleDraft] = ScheduleDraft.defaults
    @State private var seasons: [SeasonDraft] = []
    @State private var showingAddRoom = false
    @State private var newRoomName = ""
    @State private var showingDeleteConfirm = false

    private var isNew: Bool { plant == nil }

    /// The base watering interval, used to pre-fill a newly added season.
    private var waterInterval: Int {
        drafts.first { $0.type == .water }?.intervalDays ?? CareType.water.defaultIntervalDays
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    HStack {
                        PlantPhotoView(data: photoData, cornerRadius: 12)
                            .frame(width: 80, height: 80)
                        Menu {
                            Button {
                                showingCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                            Button {
                                showingLibrary = true
                            } label: {
                                Label("Choose from Library", systemImage: "photo.on.rectangle")
                            }
                        } label: {
                            Text(photoData == nil ? "Add Photo" : "Change Photo")
                        }
                        if photoData != nil {
                            Spacer()
                            Button(role: .destructive) {
                                photoData = nil
                                photoItem = nil
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                    .photosPicker(isPresented: $showingLibrary, selection: $photoItem, matching: .images)
                    .fullScreenCover(isPresented: $showingCamera) {
                        CameraPicker { data in photoData = data }
                            .ignoresSafeArea()
                    }
                }

                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Scientific name", text: $scientificName)
                        .italic()
                    DatePicker("Acquired", selection: $acquiredDate, in: ...Date(), displayedComponents: .date)
                }

                Section("Sunlight") {
                    LevelSelector(options: SunlightLevel.allCases,
                                  selection: $sunlight,
                                  filledSymbol: "sun.max.fill",
                                  outlineSymbol: "sun.max",
                                  tint: .yellow)
                }

                Section("Water when") {
                    LevelSelector(options: SoilDryness.allCases,
                                  selection: $soilDryness,
                                  filledSymbol: "drop.fill",
                                  outlineSymbol: "drop",
                                  tint: CareType.water.tint)
                }

                Section("Room") {
                    Picker("Room", selection: $selectedRoom) {
                        Text("None").tag(Room?.none)
                        ForEach(rooms) { room in
                            Text(room.name).tag(Room?.some(room))
                        }
                    }
                    Button {
                        showingAddRoom = true
                    } label: {
                        Label("Add Room", systemImage: "plus")
                    }
                }

                Section("Care reminders") {
                    ForEach($drafts) { $draft in
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $draft.isEnabled) {
                                Label(draft.type.label, systemImage: draft.type.symbol)
                                    .foregroundStyle(draft.type.tint)
                            }
                            if draft.isEnabled {
                                VStack(alignment: .leading, spacing: 12) {
                                    Stepper("Every \(draft.intervalDays) days",
                                            value: $draft.intervalDays, in: 1...730)
                                    DatePicker(draft.type.lastDoneLabel,
                                               selection: $draft.lastDone,
                                               in: ...Date(),
                                               displayedComponents: .date)
                                }
                                .padding(.top, 16)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section {
                    ForEach($seasons) { $season in
                        VStack(alignment: .leading, spacing: 12) {
                            MonthSelector(selection: $season.months)
                            Stepper("Every \(season.intervalDays) days",
                                    value: $season.intervalDays, in: 1...730)
                        }
                        .padding(.vertical, 6)
                    }
                    .onDelete { seasons.remove(atOffsets: $0) }

                    Button {
                        seasons.append(SeasonDraft(months: [], intervalDays: waterInterval))
                    } label: {
                        Label("Add season", systemImage: "plus")
                    }
                } header: {
                    Text("Seasonal watering")
                } footer: {
                    Text("Water less or more often in certain months. The base interval is used for any month without a season.")
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let plant {
                    Section {
                        Button {
                            CareService.setArchived(plant, !plant.isArchived, context: context)
                            finishRemoval()
                        } label: {
                            plant.isArchived
                                ? Label("Restore plant", systemImage: "arrow.uturn.backward")
                                : Label("Archive plant", systemImage: "archivebox")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete plant", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? Text("New Plant") : Text("Edit Plant"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task(id: photoItem) {
                if let photoItem, let data = try? await photoItem.loadTransferable(type: Data.self) {
                    photoData = data
                }
            }
            .alert("New Room", isPresented: $showingAddRoom) {
                TextField("Room name", text: $newRoomName)
                Button("Add") { addRoom() }
                Button("Cancel", role: .cancel) { newRoomName = "" }
            }
            .confirmationDialog("Delete this plant?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let plant { CareService.delete(plant, context: context) }
                    finishRemoval()
                }
            } message: {
                Text("This permanently removes the plant and its history.")
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    private func loadIfNeeded() {
        guard let plant else { return }
        name = plant.name
        scientificName = plant.scientificName
        notes = plant.notes
        sunlight = plant.sunlight
        soilDryness = plant.soilDryness
        selectedRoom = plant.room
        photoData = plant.photoData
        acquiredDate = plant.acquiredDate
        drafts = ScheduleDraft.from(plant: plant)
        seasons = SeasonDraft.from(plant: plant)
    }

    /// Closes the edit sheet and asks the presenter (detail view) to pop as well.
    private func finishRemoval() {
        dismiss()
        onRemoved?()
    }

    private func addRoom() {
        let trimmed = newRoomName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let room = Room(name: trimmed, sortIndex: rooms.count)
        context.insert(room)
        selectedRoom = room
        newRoomName = ""
    }

    private func save() {
        let target: Plant
        if let plant {
            target = plant
        } else {
            target = Plant()
            context.insert(target)
        }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedSci = scientificName.trimmingCharacters(in: .whitespaces)

        // Compute a human-readable diff *before* mutating the plant.
        let diff = isNew ? EditDiff() : editChanges(for: target, newName: trimmedName, newSci: trimmedSci)
        let photoChanged = target.photoData != photoData

        target.name = trimmedName
        target.scientificName = trimmedSci
        target.notes = notes
        target.sunlight = sunlight
        target.soilDryness = soilDryness
        target.room = selectedRoom
        target.photoData = photoData
        target.acquiredDate = acquiredDate

        applySeasons(to: target)
        applySchedules(to: target)

        if isNew {
            CareService.addLog(.created, to: target, photoData: target.photoData, context: context)
        } else {
            if diff.hasChanges {
                let log = CareService.addLog(.edited, to: target, note: diff.lines.joined(separator: "\n"), context: context)
                log.sunlightFrom = diff.sunlightFrom
                log.sunlightTo = diff.sunlightTo
                log.soilFrom = diff.soilFrom
                log.soilTo = diff.soilTo
            }
            if photoChanged {
                CareService.addLog(.photoChanged, to: target, photoData: target.photoData, context: context)
                // A new photo counts toward the "Photo" reminder: reset its next-due date.
                if let photo = CareSchedules.pickEnabled(.photo, from: target.schedules) {
                    photo.reschedule(from: Date())
                }
            }
        }

        CareService.plantDidChange(target, context: context)
        dismiss()
    }

    /// What an edit changed: text lines for most fields, plus structured before/after levels for
    /// sunlight and "water when" so the journal can render those as icons instead of text.
    private struct EditDiff {
        var lines: [String] = []
        var sunlightFrom: Int?
        var sunlightTo: Int?
        var soilFrom: Int?
        var soilTo: Int?

        var hasChanges: Bool { !lines.isEmpty || sunlightTo != nil || soilTo != nil }
    }

    /// Builds the diff describing what the edit changed.
    private func editChanges(for plant: Plant, newName: String, newSci: String) -> EditDiff {
        var diff = EditDiff()

        if plant.name != newName {
            diff.lines.append(String(localized: "Name: \(quoted(plant.name)) → \(quoted(newName))"))
        }
        if plant.scientificName != newSci {
            diff.lines.append(String(localized: "Scientific name: \(quoted(plant.scientificName)) → \(quoted(newSci))"))
        }
        // Sunlight and "water when" are recorded as before/after levels (rendered as icons).
        if plant.sunlight != sunlight {
            diff.sunlightFrom = (SunlightLevel.allCases.firstIndex(of: plant.sunlight) ?? 0) + 1
            diff.sunlightTo = (SunlightLevel.allCases.firstIndex(of: sunlight) ?? 0) + 1
        }
        if plant.soilDryness != soilDryness {
            diff.soilFrom = (SoilDryness.allCases.firstIndex(of: plant.soilDryness) ?? 0) + 1
            diff.soilTo = (SoilDryness.allCases.firstIndex(of: soilDryness) ?? 0) + 1
        }
        let oldRoom = plant.room?.name ?? String(localized: "None")
        let newRoom = selectedRoom?.name ?? String(localized: "None")
        if oldRoom != newRoom {
            diff.lines.append(String(localized: "Room: \(oldRoom) → \(newRoom)"))
        }
        if plant.notes != notes {
            diff.lines.append(String(localized: "Notes updated"))
        }
        if !Calendar.current.isDate(plant.acquiredDate, inSameDayAs: acquiredDate) {
            let oldDate = plant.acquiredDate.formatted(date: .abbreviated, time: .omitted)
            let newDate = acquiredDate.formatted(date: .abbreviated, time: .omitted)
            diff.lines.append(String(localized: "Acquired: \(oldDate) → \(newDate)"))
        }

        let old = ScheduleDraft.from(plant: plant)
        for newDraft in drafts {
            guard let oldDraft = old.first(where: { $0.type == newDraft.type }) else { continue }
            if oldDraft.isEnabled != newDraft.isEnabled {
                diff.lines.append(newDraft.isEnabled
                    ? String(localized: "Enabled \(newDraft.type.label) (every \(newDraft.intervalDays) days)")
                    : String(localized: "Disabled \(newDraft.type.label)"))
            } else if newDraft.isEnabled {
                if oldDraft.intervalDays != newDraft.intervalDays {
                    diff.lines.append(String(localized: "\(newDraft.type.intervalLabel): \(oldDraft.intervalDays) → \(newDraft.intervalDays) days"))
                }
                if !Calendar.current.isDate(oldDraft.lastDone, inSameDayAs: newDraft.lastDone) {
                    let doneDate = newDraft.lastDone.formatted(date: .abbreviated, time: .omitted)
                    diff.lines.append(String(localized: "\(newDraft.type.label) last done: \(doneDate)"))
                }
            }
        }
        return diff
    }

    private func quoted(_ value: String) -> String {
        value.isEmpty ? String(localized: "empty") : "\"\(value)\""
    }

    /// Replaces the plant's watering seasons with the current drafts (empty months are dropped).
    /// Delete-and-recreate keeps the reconciliation simple; the collection is tiny.
    private func applySeasons(to plant: Plant) {
        for existing in plant.wateringSeasons ?? [] {
            // Detached *before* deleting. `context.delete` leaves the object sitting in the
            // inverse relationship array until the next save, and `applySchedules` — which runs
            // immediately after this — reads that array to resolve the seasonal watering
            // interval. Without the detach, a plant's next watering date can be recomputed from
            // a season the user just deleted, on the very save that deletes it.
            existing.plant = nil
            context.delete(existing)
        }
        for draft in seasons where !draft.months.isEmpty {
            let season = WateringSeason(months: Array(draft.months), intervalDays: draft.intervalDays)
            season.plant = plant
            context.insert(season)
        }
    }

    /// Creates, updates or disables schedules to match the drafts. The next-due date is always
    /// recomputed from the "last done" date and the (possibly changed) interval, so editing an
    /// interval re-evaluates whether the task is still due — increasing it can clear an overdue
    /// reminder. Watering honors any seasonal override. `applySeasons` must run first.
    private func applySchedules(to plant: Plant) {
        for draft in drafts {
            if let existing = CareSchedules.pick(draft.type, from: plant.schedules) {
                existing.isEnabled = draft.isEnabled
                existing.intervalDays = draft.intervalDays
                CareService.recomputeNextDue(existing, lastDone: draft.lastDone,
                                             recordingCompletion: draft.recordsCompletion)
            } else if draft.isEnabled {
                let schedule = CareSchedule(type: draft.type, intervalDays: draft.intervalDays)
                schedule.plant = plant
                context.insert(schedule)
                CareService.recomputeNextDue(schedule, lastDone: draft.lastDone)
            }
        }
    }
}

/// Lightweight editable representation of a care schedule used by the form.
struct ScheduleDraft: Identifiable {
    let type: CareType
    var isEnabled: Bool
    var intervalDays: Int
    /// The last time this care was performed; the next due date is this plus the interval.
    var lastDone: Date
    /// The date `lastDone` was *invented* with, for a schedule that has never been completed.
    /// Nil when the schedule really does have a last-done date, or when there is no schedule yet.
    ///
    /// The picker cannot show "never", so it has to show something, and that something has to
    /// keep `nextDue` stable across a save that changed nothing else. But a value the app made
    /// up must not be written back as though the user had entered it — see `recordsCompletion`.
    var derivedLastDone: Date?
    var id: String { type.rawValue }

    /// Whether saving should store `lastDone` as a real completion date.
    ///
    /// False in exactly one case: the schedule has never been completed and the user left the
    /// invented date alone. Writing it then would make a schedule that was never completed claim
    /// it was — silently, on any save, including one that only renamed the plant. The claim also
    /// leaves the device: the export ships it as `lastDoneAt`, and nothing downstream can tell a
    /// fabricated date from a real one.
    var recordsCompletion: Bool {
        guard let derived = derivedLastDone else { return true }

        return !Calendar.current.isDate(lastDone, inSameDayAs: derived)
    }

    static var defaults: [ScheduleDraft] {
        CareType.allCases.map {
            ScheduleDraft(type: $0, isEnabled: $0 == .water || $0 == .photo,
                          intervalDays: $0.defaultIntervalDays, lastDone: Date(), derivedLastDone: nil)
        }
    }

    static func from(plant: Plant) -> [ScheduleDraft] {
        CareType.allCases.map { type in
            if let existing = CareSchedules.pick(type, from: plant.schedules) {
                // Derive last-done so an unchanged save keeps nextDue stable:
                // (nextDue - interval) when the schedule has never been completed.
                let derived = Calendar.current.date(byAdding: .day, value: -existing.intervalDays, to: existing.nextDue)
                    ?? Date()
                return ScheduleDraft(type: type, isEnabled: existing.isEnabled,
                                     intervalDays: existing.intervalDays,
                                     lastDone: existing.lastDone ?? derived,
                                     derivedLastDone: existing.lastDone == nil ? derived : nil)
            }
            return ScheduleDraft(type: type, isEnabled: false,
                                 intervalDays: type.defaultIntervalDays, lastDone: Date(), derivedLastDone: nil)
        }
    }
}

/// Editable representation of a `WateringSeason` used by the form.
struct SeasonDraft: Identifiable {
    let id = UUID()
    var months: Set<Int>
    var intervalDays: Int

    static func from(plant: Plant) -> [SeasonDraft] {
        (plant.wateringSeasons ?? [])
            .sorted { ($0.months.min() ?? 0) < ($1.months.min() ?? 0) }
            .map { SeasonDraft(months: Set($0.months), intervalDays: $0.intervalDays) }
    }
}

#Preview {
    PlantEditView(plant: nil)
        .modelContainer(SampleData.container)
        .preferredColorScheme(.dark)
}
