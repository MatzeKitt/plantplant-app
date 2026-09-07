import SwiftUI
import SwiftData

enum PlantSort: String, CaseIterable, Identifiable {
    case deadline = "Deadline"
    case name = "Name"
    var id: String { rawValue }
    var symbol: String { self == .name ? "textformat" : "bell" }
    var titleKey: LocalizedStringKey {
        switch self {
        case .deadline: return "Deadline"
        case .name: return "Name"
        }
    }

    /// Applies this ordering to `plants`. Shared by the Plants tab and the Search tab so both
    /// show the same active sort. The deadline sort precomputes each plant's sort keys once
    /// (decorate–sort–undecorate) so comparisons don't recompute `startOfDay` repeatedly.
    func sorted(_ plants: [Plant]) -> [Plant] {
        switch self {
        case .name:
            return plants.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .deadline:
            let cal = Calendar.current
            let decorated = plants.map { plant in
                SortKey(plant: plant,
                        day: plant.nextReminder.map { cal.startOfDay(for: $0.nextDue) },
                        room: plant.room?.name,
                        title: plant.displayName)
            }
            return decorated.sorted(by: Self.deadlineOrder).map(\.plant)
        }
    }

    /// A plant with its precomputed deadline-sort keys.
    private struct SortKey {
        let plant: Plant
        let day: Date?
        let room: String?
        let title: String
    }

    /// Soonest reminder deadline first (plants with no reminder last), then ascending by room
    /// (no room last), then ascending by title.
    private static func deadlineOrder(_ lhs: SortKey, _ rhs: SortKey) -> Bool {
        switch (lhs.day, rhs.day) {
        case let (l?, r?) where l != r: return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }

        switch (lhs.room, rhs.room) {
        case (nil, .some): return false
        case (.some, nil): return true
        case let (l?, r?):
            let cmp = l.localizedCaseInsensitiveCompare(r)
            if cmp != .orderedSame { return cmp == .orderedAscending }
        default: break
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

struct PlantsListView: View {
    @Query(filter: #Predicate<Plant> { !$0.isArchived })
    private var plants: [Plant]

    @AppStorage("plantSort") private var sort: PlantSort = .deadline
    @State private var showingAdd = false
    @State private var dayToken = 0

    private var visiblePlants: [Plant] {
        sort.sorted(plants)
    }

    @State private var path: [Plant] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if plants.isEmpty {
                    ContentUnavailableView {
                        Label("No Plants Yet", systemImage: "leaf")
                    } description: {
                        Text("Add your first plant to start tracking watering and care.")
                    } actions: {
                        Button("Add Plant") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(visiblePlants) { plant in
                            NavigationLink(value: plant) {
                                PlantRowView(plant: plant)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Plants")
            .navigationDestination(for: Plant.self) { PlantDetailView(plant: $0) }
            // Search lives in its own dedicated search tab (see `RootTabView`).
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("Sort", selection: $sort) {
                        ForEach(PlantSort.allCases) { option in
                            Label(option.titleKey, systemImage: option.symbol).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Plant", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                PlantEditView(plant: nil)
            }
            .refreshOnDayChange($dayToken)
            #if DEBUG
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-openFirstPlant"), path.isEmpty {
                    let target: Plant?
                    if args.contains("-openHistory") {
                        target = visiblePlants.max(by: { $0.sortedLogs.count < $1.sortedLogs.count })
                    } else if args.contains("-mostCare") {
                        target = visiblePlants.max(by: { $0.enabledSchedules.count < $1.enabledSchedules.count })
                    } else {
                        target = visiblePlants.first
                    }
                    if let target { path = [target] }
                }
                if args.contains("-openAddPlant") { showingAdd = true }
            }
            #endif
        }
    }
}

#Preview {
    PlantsListView()
        .modelContainer(SampleData.container)
        .preferredColorScheme(.dark)
}
