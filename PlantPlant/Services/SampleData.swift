import Foundation
import SwiftData

/// Seed data used for SwiftUI previews and (in DEBUG) the `-seedSampleData` launch argument.
@MainActor
enum SampleData {
    /// In-memory container seeded with example data for SwiftUI previews.
    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: SharedModelContainer.schema, configurations: [config])
        populate(container.mainContext)
        return container
    }()

    /// Inserts example rooms, plants, schedules and history into the given context.
    static func populate(_ context: ModelContext) {
        let living = Room(name: "Living room", sortIndex: 0)
        let bedroom = Room(name: "Bedroom", sortIndex: 1)
        let kitchen = Room(name: "Kitchen", sortIndex: 2)
        [living, bedroom, kitchen].forEach { context.insert($0) }

        @discardableResult
        func makePlant(
            _ name: String,
            _ scientific: String,
            room: Room,
            sunlight: SunlightLevel,
            waterInDays: Int,
            interval: Int
        ) -> Plant {
            let plant = Plant(name: name, scientificName: scientific, room: room, sunlight: sunlight)
            context.insert(plant)

            let water = CareSchedule(
                type: .water,
                intervalDays: interval,
                startingFrom: Calendar.current.date(byAdding: .day, value: waterInDays, to: .now)!
            )
            water.plant = plant
            context.insert(water)

            let mistStart = Calendar.current.date(byAdding: .day, value: CareType.mist.defaultIntervalDays, to: .now)!
            let mist = CareSchedule(type: .mist, isEnabled: sunlight == .brightIndirect, startingFrom: mistStart)
            mist.plant = plant
            context.insert(mist)

            plant.nextWaterDue = water.nextDue

            let created = CareLog(type: .created, date: Calendar.current.date(byAdding: .day, value: -14, to: .now)!)
            created.plant = plant
            context.insert(created)
            return plant
        }

        let monstera = makePlant("Monstera", "Monstera deliciosa", room: living, sunlight: .brightIndirect, waterInDays: -1, interval: 7)
        // Neglected on purpose: several overdue care types, so the overview shows multiple
        // due indicators plus the "+N" overflow.
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
        for schedule in monstera.schedules ?? [] {
            schedule.isEnabled = true
            schedule.nextDue = twoDaysAgo
        }
        let fertilize = CareSchedule(type: .fertilize, intervalDays: 30, startingFrom: twoDaysAgo)
        fertilize.plant = monstera
        context.insert(fertilize)
        // Also enable repot + photo (not yet due) so the Monstera exercises all five care types.
        let future = Calendar.current.date(byAdding: .day, value: 20, to: .now)!
        for type in [CareType.repot, .photo] {
            let schedule = CareSchedule(type: type, intervalDays: type.defaultIntervalDays, startingFrom: future)
            schedule.plant = monstera
            context.insert(schedule)
        }
        CareService.syncWaterDue(monstera)

        makePlant("Snake Plant", "Dracaena trifasciata", room: bedroom, sunlight: .low, waterInDays: 4, interval: 14)
        makePlant("Basil", "Ocimum basilicum", room: kitchen, sunlight: .directSun, waterInDays: 0, interval: 2)
        makePlant("Fiddle Leaf Fig", "Ficus lyrata", room: living, sunlight: .brightIndirect, waterInDays: 3, interval: 7)

        // A couple of richer history entries on the Monstera.
        let watered = CareLog(type: .watered, date: Calendar.current.date(byAdding: .day, value: -7, to: .now)!)
        watered.plant = monstera
        context.insert(watered)

        let editNote = String(localized: "Room: \("Bedroom") → \("Living room")")
            + "\n"
            + String(localized: "\(CareType.water.intervalLabel): \(10) → \(7) days")
        let edited = CareLog(
            type: .edited,
            date: Calendar.current.date(byAdding: .day, value: -3, to: .now)!,
            note: editNote
        )
        // Also demonstrate the icon-based sunlight / "water when" change entries.
        edited.sunlightFrom = 2
        edited.sunlightTo = 3
        edited.soilFrom = 1
        edited.soilTo = 2
        edited.plant = monstera
        context.insert(edited)

        // Water the Monstera less often over winter (Nov–Feb).
        let winter = WateringSeason(months: [11, 12, 1, 2], intervalDays: 14)
        winter.plant = monstera
        context.insert(winter)

        try? context.save()
    }

    #if DEBUG
    /// Populates the given store with sample data if it is empty. Triggered by the
    /// `-seedSampleData` launch argument (see `PlantPlantApp`).
    static func seedIfEmpty(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Plant>())) ?? 0
        guard count == 0 else { return }
        populate(context)
    }
    #endif
}

extension ModelContext {
    /// Convenience for previews: returns any one plant from the store.
    func previewFirstPlant() -> Plant {
        let plants = (try? fetch(FetchDescriptor<Plant>())) ?? []
        return plants.first ?? Plant(name: "Preview Plant")
    }
}
