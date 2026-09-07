import Foundation
import SwiftData

@Model
final class CareSchedule {
    var id: UUID = UUID()
    var typeRaw: String = CareType.water.rawValue
    var intervalDays: Int = 7
    var lastDone: Date?
    var nextDue: Date = Date()
    var isEnabled: Bool = true

    var plant: Plant?

    init(type: CareType, intervalDays: Int? = nil, isEnabled: Bool = true, startingFrom start: Date = Date()) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.intervalDays = intervalDays ?? type.defaultIntervalDays
        self.isEnabled = isEnabled
        self.lastDone = nil
        self.nextDue = start
    }

    var type: CareType {
        get { CareType(rawValue: typeRaw) ?? .water }
        set { typeRaw = newValue.rawValue }
    }

    var isOverdue: Bool {
        isEnabled && nextDue.isDueByToday
    }

    /// The interval to use for a completion happening on `reference`. For watering, a seasonal
    /// override whose months include `reference`'s month wins over the base `intervalDays`;
    /// every other care type always uses its base interval.
    ///
    /// Nothing stops two seasons from covering the same month, and the editor does not prevent
    /// it. `first(where:)` would then resolve the overlap to whatever order SwiftData
    /// materialized the relationship in — so the same plant could water every 21 days today and
    /// every 14 tomorrow, with no edit in between. Lowest id wins instead: arbitrary, but stable.
    func effectiveInterval(on reference: Date = Date()) -> Int {
        guard type == .water, let plant else { return intervalDays }
        let month = Calendar.current.component(.month, from: reference)
        let covering = (plant.wateringSeasons ?? [])
            .filter { $0.covers(month: month) }
            .min { $0.id.uuidString < $1.id.uuidString }
        return covering?.intervalDays ?? intervalDays
    }

    /// Advances `nextDue` by the effective interval from the given reference date.
    func reschedule(from reference: Date = Date()) {
        lastDone = reference
        let interval = effectiveInterval(on: reference)
        nextDue = Calendar.current.date(byAdding: .day, value: interval, to: reference) ?? reference
    }
}
