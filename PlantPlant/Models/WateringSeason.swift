import Foundation
import SwiftData

/// A per-month override for a plant's watering interval. Plants often need water more or less
/// frequently across the year (e.g. more in summer, less in winter), so the user can attach one
/// or more seasons — each a set of months plus its own interval — that take precedence over the
/// base watering interval whenever the current month is covered.
@Model
final class WateringSeason {
    var id: UUID = UUID()

    /// The months this override applies to, as 1...12 (January = 1).
    var months: [Int] = []

    /// Watering interval in days to use during the selected months.
    var intervalDays: Int = 7

    var plant: Plant?

    init(months: [Int], intervalDays: Int) {
        self.id = UUID()
        self.months = months.sorted()
        self.intervalDays = intervalDays
    }

    /// True when this season covers the given calendar month (1...12).
    func covers(month: Int) -> Bool {
        months.contains(month)
    }
}
