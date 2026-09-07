import SwiftUI
import SwiftData

/// A schedule paired with its plant, for display in the reminders list.
private struct ReminderItem: Identifiable {
    let plant: Plant
    let schedule: CareSchedule
    var id: String { "\(plant.id)|\(schedule.type.rawValue)" }
    var due: Date { schedule.nextDue }
}

private enum DueBucket: String, CaseIterable, Identifiable {
    case overdue = "Overdue"
    case today = "Today"
    case tomorrow = "Tomorrow"
    case thisWeek = "This Week"
    case later = "Later"
    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .thisWeek: return "This Week"
        case .later: return "Later"
        }
    }

    static func bucket(for date: Date) -> DueBucket {
        switch date.daysFromToday {
        case ..<0: return .overdue
        case 0: return .today
        case 1: return .tomorrow
        case 2...7: return .thisWeek
        default: return .later
        }
    }
}

struct RemindersView: View {
    @Query(filter: #Predicate<Plant> { !$0.isArchived })
    private var plants: [Plant]

    @Environment(\.modelContext) private var context
    @State private var snoozeTarget: ReminderItem?
    @State private var cameraTarget: ReminderItem?
    @State private var path: [Plant] = []
    @State private var dayToken = 0
    @State private var confirmingMarkAllDone = false

    private var items: [ReminderItem] {
        var result: [ReminderItem] = []
        for plant in plants {
            for schedule in plant.enabledSchedules {
                result.append(ReminderItem(plant: plant, schedule: schedule))
            }
        }
        // Ascending by deadline (next due day) first, then by room (no room last), then by
        // title. Deadlines are compared by calendar day so same-day items fall back to room/title.
        let cal = Calendar.current
        return result.sorted { lhs, rhs in
            let l = cal.startOfDay(for: lhs.due)
            let r = cal.startOfDay(for: rhs.due)
            if l != r { return l < r }

            switch (lhs.plant.room, rhs.plant.room) {
            case (nil, .some): return false
            case (.some, nil): return true
            case let (lr?, rr?):
                let cmp = lr.name.localizedCaseInsensitiveCompare(rr.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
            case (nil, nil):
                break
            }
            return lhs.plant.displayName.localizedCaseInsensitiveCompare(rhs.plant.displayName) == .orderedAscending
        }
    }

    /// Photo reminders open the camera; everything else opens the plant detail page.
    private func handleTap(_ item: ReminderItem) {
        if item.schedule.type == .photo {
            cameraTarget = item
        } else {
            path.append(item.plant)
        }
    }

    var body: some View {
        // Computed once per render and bucketed in a single pass, rather than recomputing and
        // re-sorting `items` for every bucket and again for the toolbar. `items` is already
        // sorted, so `Dictionary(grouping:)` preserves order within each bucket.
        let all = items
        // Overdue and today, which is exactly what `isOverdue` already means — a task due today
        // counts as due. Marking "today" done while leaving last week's watering untouched would
        // be a strange thing for a button to do.
        let dueNow = all.filter(\.schedule.isOverdue)

        return NavigationStack(path: $path) {
            Group {
                let grouped = Dictionary(grouping: all) { DueBucket.bucket(for: $0.due) }
                if all.isEmpty {
                    ContentUnavailableView(
                        "All caught up",
                        systemImage: "checkmark.circle",
                        description: Text("No upcoming care tasks. Nice work!")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(DueBucket.allCases) { bucket in
                            let bucketItems = grouped[bucket] ?? []
                            if !bucketItems.isEmpty {
                                Section(bucket.titleKey) {
                                    ForEach(bucketItems) { item in
                                        ReminderRowView(
                                            plant: item.plant,
                                            schedule: item.schedule,
                                            onComplete: { CareService.complete(item.schedule, context: context) },
                                            onSnooze: { snoozeTarget = item },
                                            onTap: { handleTap(item) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reminders")
            .toolbar {
                if !dueNow.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            confirmingMarkAllDone = true
                        } label: {
                            Image(systemName: "checklist.checked")
                        }
                        .accessibilityLabel("Mark everything due done")
                    }
                }
            }
            // The one confirmation on this screen, and the app's second overall. Completing a
            // single row is one tap to undo — you complete it again tomorrow. This is up to
            // dozens of schedules advanced at once with no way back, from a button that sits
            // where the eye lands, so it asks. The count is in the button so the dialog also
            // answers "how many is 'everything'?" before you commit.
            .confirmationDialog("Mark everything due done?",
                                isPresented: $confirmingMarkAllDone, titleVisibility: .visible) {
                Button("Mark \(dueNow.count) tasks done") {
                    CareService.completeAll(dueNow.map(\.schedule), context: context)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Completes everything overdue or due today. This can't be undone.")
            }
            .navigationDestination(for: Plant.self) { plant in
                PlantDetailView(plant: plant)
            }
            .refreshOnDayChange($dayToken)
            .sheet(item: $snoozeTarget) { item in
                SnoozeSheet(plantName: item.plant.displayName, careLabel: item.schedule.type.label) { days in
                    CareService.snooze(item.schedule, days: days, context: context)
                }
            }
            .fullScreenCover(item: $cameraTarget) { item in
                CameraPicker { data in CareService.setPhoto(data, for: item.plant, context: context) }
                    .ignoresSafeArea()
            }
        }
    }
}

/// Lets the user push a reminder out by a chosen number of days.
private struct SnoozeSheet: View {
    let plantName: String
    let careLabel: String
    let onSnooze: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days = 1

    /// Quick presets in days.
    private let presets = [1, 3, 7, 14]

    var body: some View {
        NavigationStack {
            Form {
                Section("Snooze for") {
                    Stepper(value: $days, in: 1...365) {
                        Text("\(days) days")
                    }
                }
                Section("Quick options") {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            onSnooze(preset)
                            dismiss()
                        } label: {
                            HStack {
                                Text("\(preset) days")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Snooze \(careLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Snooze") {
                        onSnooze(days)
                        dismiss()
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

#Preview {
    RemindersView()
        .modelContainer(SampleData.container)
        .preferredColorScheme(.dark)
}
