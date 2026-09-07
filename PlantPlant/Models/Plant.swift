import Foundation
import SwiftData

@Model
final class Plant {
    var id: UUID = UUID()
    var name: String = ""
    var scientificName: String = ""

    @Attribute(.externalStorage)
    var photoData: Data?

    var room: Room?
    var sunlightRaw: String = SunlightLevel.brightIndirect.rawValue
    var soilDrynessRaw: String = SoilDryness.topDry.rawValue
    var notes: String = ""
    var isArchived: Bool = false
    var createdAt: Date = Date()
    /// When the user acquired the plant (editable; defaults to the day it was added).
    var acquiredDate: Date = Date()

    /// Denormalized copy of the water schedule's `nextDue`, kept in sync by `CareService`
    /// so the plant list and widget can sort/filter without traversing schedules.
    var nextWaterDue: Date?

    @Relationship(deleteRule: .cascade, inverse: \CareSchedule.plant)
    var schedules: [CareSchedule]? = []

    @Relationship(deleteRule: .cascade, inverse: \CareLog.plant)
    var logs: [CareLog]? = []

    /// Per-month watering-interval overrides. Empty when the plant just uses its base interval.
    @Relationship(deleteRule: .cascade, inverse: \WateringSeason.plant)
    var wateringSeasons: [WateringSeason]? = []

    init(
        name: String = "",
        scientificName: String = "",
        room: Room? = nil,
        sunlight: SunlightLevel = .brightIndirect,
        soilDryness: SoilDryness = .topDry,
        notes: String = "",
        acquiredDate: Date = Date()
    ) {
        self.id = UUID()
        self.name = name
        self.scientificName = scientificName
        self.room = room
        self.sunlightRaw = sunlight.rawValue
        self.soilDrynessRaw = soilDryness.rawValue
        self.notes = notes
        self.createdAt = Date()
        self.acquiredDate = acquiredDate
    }

    var sunlight: SunlightLevel {
        get { SunlightLevel(rawValue: sunlightRaw) ?? .brightIndirect }
        set { sunlightRaw = newValue.rawValue }
    }

    var soilDryness: SoilDryness {
        get { SoilDryness(rawValue: soilDrynessRaw) ?? .topDry }
        set { soilDrynessRaw = newValue.rawValue }
    }

    /// Name for display, with a localized fallback when unset.
    var displayName: String {
        name.isEmpty ? String(localized: "Untitled") : name
    }

    /// The watering schedule, chosen deterministically when there is more than one.
    /// See `CareSchedules` for why that is not just `first(where:)`.
    var waterSchedule: CareSchedule? {
        CareSchedules.pick(.water, from: schedules)
    }

    var enabledSchedules: [CareSchedule] {
        (schedules ?? []).filter { $0.isEnabled }.sorted { $0.nextDue < $1.nextDue }
    }

    /// The soonest upcoming (or most overdue) enabled care reminder, across every care type.
    var nextReminder: CareSchedule? {
        enabledSchedules.first
    }

    /// True when any enabled care reminder is due today or overdue.
    var hasDueReminder: Bool {
        // `isOverdue` already requires `isEnabled`, so iterate raw schedules and skip
        // `enabledSchedules`' needless filter-and-sort.
        (schedules ?? []).contains { $0.isOverdue }
    }

    /// Distinct care types that are due today or overdue, ordered soonest first.
    var dueCareTypes: [CareType] {
        var seen = Set<CareType>()
        var result: [CareType] = []
        for schedule in enabledSchedules where schedule.isOverdue {
            if seen.insert(schedule.type).inserted { result.append(schedule.type) }
        }
        return result
    }

    var sortedLogs: [CareLog] {
        (logs ?? []).sorted { $0.date > $1.date }
    }

    /// Every photo the plant has had, newest first — the current photo plus any older ones
    /// preserved in the journal. Used by the detail-view gallery. The current photo is kept
    /// first even for legacy plants whose photo predates photo-carrying journal entries.
    var photoHistory: [Data] {
        var result = sortedLogs.compactMap { $0.photoData }
        if let current = photoData, result.first != current {
            result.insert(current, at: 0)
        }
        return result
    }

    /// True when the (enabled) water schedule is due today or overdue.
    var needsWater: Bool {
        guard let due = nextWaterDue else { return false }
        return due.isDueByToday
    }
}
