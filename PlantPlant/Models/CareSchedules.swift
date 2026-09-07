import Foundation

/// Picks *the* schedule of a care type when a plant has more than one.
///
/// Nothing in the store constrains a plant to one schedule per care type, so
/// "the water schedule" is not a well-defined thing to ask for. Three callers
/// ask anyway, because they each need exactly one answer: the denormalized
/// `nextWaterDue`, completing a photo task, and acting on a notification.
///
/// Left to `first(where:)` each of them gets whatever order SwiftData happened
/// to materialize the relationship in — which is not defined and not stable
/// across launches. A plant could sync its water date from the enabled schedule
/// today and the disabled one tomorrow, and nothing in the app would look wrong
/// until the reminder failed to appear.
///
/// One picker, one answer, in this order:
///
///   1. enabled before disabled — a disabled schedule is not what anyone means
///   2. then the soonest `nextDue` — the one the user is about to be reminded of
///   3. then the lowest id — arbitrary, but the *same* arbitrary every time
enum CareSchedules {
    /// The schedule of `type` that every caller should agree on, enabled or not.
    static func pick(_ type: CareType, from schedules: [CareSchedule]?) -> CareSchedule? {
        (schedules ?? [])
            .filter { $0.type == type }
            .min(by: preferred)
    }

    /// As `pick`, but nil unless the winner is enabled.
    ///
    /// Not the same as picking among only the enabled ones: if the preferred
    /// schedule is disabled, the care type is off for this plant, and quietly
    /// falling through to a disabled duplicate's forgotten sibling would turn a
    /// switch the user set into a suggestion.
    static func pickEnabled(_ type: CareType, from schedules: [CareSchedule]?) -> CareSchedule? {
        guard let picked = pick(type, from: schedules), picked.isEnabled else { return nil }

        return picked
    }

    /// A strict ordering, so `min(by:)` is well defined even for equal candidates.
    private static func preferred(_ lhs: CareSchedule, _ rhs: CareSchedule) -> Bool {
        if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
        if lhs.nextDue != rhs.nextDue { return lhs.nextDue < rhs.nextDue }

        return lhs.id.uuidString < rhs.id.uuidString
    }
}
