import Foundation

/// What an import does about data that is already on the device.
///
/// Two modes, not the three the web app offers. `skip_existing` exists there
/// because a shared home can have several people importing into it and one of
/// them may want to add only what is missing. A phone has one owner, and the two
/// questions they actually have are "top this up" and "make it look like the
/// file" — a third option here would be a third thing to read before restoring a
/// backup.
enum ImportMode: String, CaseIterable, Identifiable, Sendable {
    /// Upsert by id. Re-importing the same file changes nothing.
    case merge
    /// Delete the library first, then insert the file.
    case replace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .merge: return String(localized: "Merge")
        case .replace: return String(localized: "Replace everything")
        }
    }

    var explanation: String {
        switch self {
        case .merge:
            return String(localized: "Plants already here are updated from the file and new ones are added. Nothing is deleted — a plant you removed elsewhere will come back.")
        case .replace:
            return String(localized: "Everything on this device is deleted first, then the file is imported. Use this to make this device match the file exactly.")
        }
    }
}

/// What the file contains and what importing it would touch, worked out without
/// writing anything.
///
/// The web app has this as its own screen and it earns the extra step there too:
/// it is the only moment at which the choice between the modes can be made with
/// the actual numbers in front of you rather than from memory.
struct ImportPreview: Sendable {
    let generator: String
    let exportedAt: Date?
    let timeZone: String
    let reminderMinutes: Int

    let rooms: Int
    let plants: Int
    let schedules: Int
    let seasons: Int
    let logs: Int
    let photos: Int

    /// How many of the file's plants and rooms are already on this device, by id.
    /// The difference between "this will add 12 plants" and "this will update 12
    /// plants", which is the whole reason to look before running.
    let plantsAlreadyHere: Int
    let roomsAlreadyHere: Int

    /// What is on the device now — what `replace` would delete.
    let plantsOnDevice: Int

    let warnings: [String]
}

/// Where an import has got to, for the progress view.
struct ImportProgress: Sendable {
    enum Phase: Sendable {
        case reading
        case plants
        case photos
        case finishing
    }

    let phase: Phase
    let done: Int
    let total: Int

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }
}

/// What an import actually did.
struct ImportReport: Sendable {
    var roomsCreated = 0
    var roomsUpdated = 0
    var plantsCreated = 0
    var plantsUpdated = 0
    var plantsDeleted = 0
    var schedules = 0
    var seasons = 0
    var logsCreated = 0

    /// Logs whose id was already here.
    ///
    /// Always skipped, never updated. A journal entry is a historical fact —
    /// "watered on the 3rd" either happened or it didn't — so an update path for
    /// one is code that can only ever do harm. It is also what makes re-importing
    /// the same file a genuine no-op instead of a slowly growing journal.
    var logsSkipped = 0

    var photosLinked = 0
    var photosSkipped = 0

    /// Schedules whose `nextDue` is not what their interval would derive.
    ///
    /// Reported, never corrected. Snooze patches `nextDue` and deliberately
    /// leaves `lastDone` alone, so "fixing" these would drag every snoozed task
    /// back to the date it was snoozed from.
    var divergentSchedules = 0

    var warnings: [String] = []

    var plantsTouched: Int { plantsCreated + plantsUpdated }
}
