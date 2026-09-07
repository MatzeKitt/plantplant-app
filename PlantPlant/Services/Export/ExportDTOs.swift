import Foundation

/// The wire types for `plantplant.export`, version 1.
///
/// Everything except the photo map goes through `JSONEncoder`, because everything
/// except the photo map is small — a real library is about 250 KB of JSON once
/// the images are excluded. The photos are written by hand, one at a time, so
/// peak memory stays at one image regardless of how many there are.
///
/// Note what is *not* here: `nextWaterDue`. It is a denormalised cache of the
/// enabled water schedule's `nextDue`, not user intent, and the importing server
/// must own its own denormalisation or it drifts the first time an edit forgets
/// to update it.
struct ExportEnvelope: Encodable {
    let format: String
    let formatVersion: Int
    let generator: String
    let exportedAt: String
    let timeZone: String
    let utcOffsetSeconds: Int
    let locale: String
    let photoEncoding: String
    let counts: ExportCounts
    let diagnostics: ExportDiagnostics
    let preferences: ExportPreferences
}

struct ExportCounts: Encodable {
    var rooms = 0
    var plants = 0
    var schedules = 0
    var wateringSeasons = 0
    var logs = 0
    var photos = 0
}

struct ExportDiagnostics: Encodable {
    var photosSkipped = 0
    var warnings: [String] = []
}

struct ExportPreferences: Encodable {
    let reminderMinutes: Int
}

struct RoomDTO: Encodable {
    let id: String
    let name: String
    let sortIndex: Int
}

/// Optional fields are written as explicit `null`, not omitted.
///
/// Swift's synthesised `encode(to:)` uses `encodeIfPresent` and drops nil, which
/// produces valid JSON that any reader handles — but the format document lists
/// these fields as present, and `tiny.json` (which both sides' tests code
/// against) spells them out. A format frozen between two codebases that cannot
/// share types is worth keeping literally identical, so the few structs with
/// optionals encode by hand.
struct PlantDTO: Encodable {
    let id: String
    let name: String
    let scientificName: String
    let roomId: String?
    let sunlight: String
    let soilDryness: String
    let notes: String
    let isArchived: Bool
    let createdAt: String
    let createdLocalDay: String
    let acquiredAt: String
    let acquiredLocalDay: String
    let photoSha256: String?
    let schedules: [ScheduleDTO]
    let wateringSeasons: [SeasonDTO]
    let logs: [LogDTO]

    enum CodingKeys: String, CodingKey {
        case id, name, scientificName, roomId, sunlight, soilDryness, notes, isArchived
        case createdAt, createdLocalDay, acquiredAt, acquiredLocalDay, photoSha256
        case schedules, wateringSeasons, logs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scientificName, forKey: .scientificName)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(sunlight, forKey: .sunlight)
        try container.encode(soilDryness, forKey: .soilDryness)
        try container.encode(notes, forKey: .notes)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(createdLocalDay, forKey: .createdLocalDay)
        try container.encode(acquiredAt, forKey: .acquiredAt)
        try container.encode(acquiredLocalDay, forKey: .acquiredLocalDay)
        try container.encode(photoSha256, forKey: .photoSha256)
        try container.encode(schedules, forKey: .schedules)
        try container.encode(wateringSeasons, forKey: .wateringSeasons)
        try container.encode(logs, forKey: .logs)
    }
}

struct ScheduleDTO: Encodable {
    let id: String
    let type: String
    let intervalDays: Int
    let isEnabled: Bool
    let lastDoneAt: String?
    let lastDoneLocalDay: String?
    let nextDueAt: String
    let nextDueLocalDay: String

    /// Whether `nextDue` equals `lastDone + effectiveInterval`.
    ///
    /// Reported, never enforced. The importer recomputes this as a *check* and
    /// preserves what was exported either way, because a snoozed task diverges
    /// by design: snooze patches `nextDue` and deliberately leaves `lastDone`
    /// alone, so "correcting" it would drag the date back into the past and
    /// silently un-snooze every deferred task in the library.
    let matchesDerivedNextDue: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, intervalDays, isEnabled, lastDoneAt, lastDoneLocalDay
        case nextDueAt, nextDueLocalDay, matchesDerivedNextDue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(intervalDays, forKey: .intervalDays)
        try container.encode(isEnabled, forKey: .isEnabled)
        // Both null together: a schedule that was never completed has no day
        // either, and inventing one would make it look completed.
        try container.encode(lastDoneAt, forKey: .lastDoneAt)
        try container.encode(lastDoneLocalDay, forKey: .lastDoneLocalDay)
        try container.encode(nextDueAt, forKey: .nextDueAt)
        try container.encode(nextDueLocalDay, forKey: .nextDueLocalDay)
        try container.encode(matchesDerivedNextDue, forKey: .matchesDerivedNextDue)
    }
}

struct SeasonDTO: Encodable {
    let id: String
    let months: [Int]
    let intervalDays: Int
}

struct LogDTO: Encodable {
    let id: String
    let type: String
    let at: String
    let localDay: String
    let note: String
    let photoSha256: String?
    /// Level changes ship as integers with an empty `note`, so the importing app
    /// renders them as icons in its own language rather than inheriting whatever
    /// language this device happened to be set to.
    let sunlightFrom: Int?
    let sunlightTo: Int?
    let soilFrom: Int?
    let soilTo: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, at, localDay, note, photoSha256
        case sunlightFrom, sunlightTo, soilFrom, soilTo
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(at, forKey: .at)
        try container.encode(localDay, forKey: .localDay)
        try container.encode(note, forKey: .note)
        try container.encode(photoSha256, forKey: .photoSha256)
        try container.encode(sunlightFrom, forKey: .sunlightFrom)
        try container.encode(sunlightTo, forKey: .sunlightTo)
        try container.encode(soilFrom, forKey: .soilFrom)
        try container.encode(soilTo, forKey: .soilTo)
    }
}
