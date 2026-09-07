import Testing
import Foundation
import SwiftData
import UIKit
@testable import PlantPlant

/// The export side of the migration contract.
///
/// These test the parts a wrong answer would be *silent* about: a date written
/// without an offset, a snoozed task reported as derivable, a duplicate photo
/// counted twice. Every one of them would produce a file that imports without
/// complaint and is quietly wrong.
///
/// The end-to-end check lives outside the test suite, because it needs the other
/// codebase: `-seedSampleData -seedSamplePhotos -exportSampleData <path>` in the
/// simulator, then `bin/console import:file <path>` in plantplant-web.
@MainActor
struct ExportTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SharedModelContainer.schema, configurations: [config])

        return ModelContext(container)
    }

    // MARK: Dates

    @Test func instantsCarryAnExplicitOffset() {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let date = Date(timeIntervalSince1970: 1_787_846_400)

        // Not epoch seconds, and not a bare local time. The offset is the
        // load-bearing detail: it is what lets the importer place the instant,
        // and the `…LocalDay` beside it is what decides the calendar day.
        #expect(ExportFormat.instant(date, in: zone) == "2026-08-27T18:00:00+02:00")
    }

    @Test func aUTCInstantIsWrittenWithZ(){
        let date = Date(timeIntervalSince1970: 1_787_846_400)

        #expect(ExportFormat.instant(date, in: TimeZone(identifier: "UTC")!) == "2026-08-27T16:00:00Z")
    }

    @Test func theLocalDayFollowsTheCalendarNotUTC() {
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!

        // A New Zealand morning is still the previous day in UTC: 09:00 on the
        // 22nd in Auckland is 21:00 on the 21st in London. The device's answer is
        // the 22nd, and the importer stores that rather than recomputing —
        // otherwise a task due "today" would arrive on the server due yesterday.
        //
        // (The tempting fixture, 23:30 local, does *not* straddle: Auckland is
        // ahead of UTC, so a late evening there is still the same UTC day. A test
        // written on that instant passes without proving anything.)
        let morning = ISO8601DateFormatter().date(from: "2026-08-22T09:00:00+12:00")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        #expect(ExportFormat.localDay(morning, calendar: auckland) == "2026-08-22")
        #expect(ExportFormat.localDay(morning, calendar: utc) == "2026-08-21")
    }

    // MARK: The derivation flag

    @Test func aFreshlyRescheduledTaskDerivesCleanly() async throws {
        let context = try makeContext()
        let plant = Plant(name: "Monstera")
        context.insert(plant)

        let schedule = CareSchedule(type: .water, intervalDays: 7)
        schedule.plant = plant
        context.insert(schedule)
        schedule.reschedule(from: .now)

        let dto = try #require(await export(plant, in: context).schedules.first)
        #expect(dto.matchesDerivedNextDue == true)
    }

    @Test func aSnoozedTaskIsReportedAsDiverging() async throws {
        let context = try makeContext()
        let plant = Plant(name: "Monstera")
        context.insert(plant)

        let schedule = CareSchedule(type: .water, intervalDays: 7)
        schedule.plant = plant
        context.insert(schedule)
        schedule.reschedule(from: .now)
        // Snooze patches nextDue and deliberately leaves lastDone alone, so the
        // arithmetic can no longer explain the date. Saying so is what stops the
        // importer from "correcting" it back into the past.
        schedule.nextDue = Calendar.current.date(byAdding: .day, value: 4, to: schedule.nextDue)!

        let dto = try #require(await export(plant, in: context).schedules.first)
        #expect(dto.matchesDerivedNextDue == false)
    }

    @Test func aNeverCompletedTaskIsNotClaimedToDerive() async throws {
        let context = try makeContext()
        let plant = Plant(name: "Basil")
        context.insert(plant)

        let schedule = CareSchedule(type: .mist, startingFrom: .now)
        schedule.plant = plant
        context.insert(schedule)

        let dto = try #require(await export(plant, in: context).schedules.first)
        #expect(schedule.lastDone == nil)
        #expect(dto.lastDoneAt == nil)
        // Both null together — inventing a day would make it look completed.
        #expect(dto.lastDoneLocalDay == nil)
        #expect(dto.matchesDerivedNextDue == false)
    }

    @Test func aSeasonalIntervalIsUsedForTheMonthOfTheCompletion() async throws {
        let context = try makeContext()
        let plant = Plant(name: "Monstera")
        context.insert(plant)

        let season = WateringSeason(months: [11, 12, 1, 2], intervalDays: 14)
        season.plant = plant
        context.insert(season)

        let schedule = CareSchedule(type: .water, intervalDays: 7)
        schedule.plant = plant
        context.insert(schedule)

        // Completed in December, so the winter season governs — and the month
        // comes from the completion, not from today.
        var components = DateComponents()
        components.year = 2025
        components.month = 12
        components.day = 1
        components.hour = 9
        let december = Calendar.current.date(from: components)!
        schedule.reschedule(from: december)

        let dto = try #require(await export(plant, in: context).schedules.first)
        #expect(dto.intervalDays == 7, "The base interval is exported, not the seasonal one.")
        #expect(dto.nextDueLocalDay == "2025-12-15", "But the due date used the season's 14 days.")
        #expect(dto.matchesDerivedNextDue == true)
    }

    // MARK: Photos

    @Test func aPlantAndItsJournalSnapshotShareOneHash() {
        let bytes = Data(repeating: 0xAB, count: 512)

        // Content addressing is what collapses the duplication every photo
        // reminder creates: the plant's current photo and the log that captured
        // it are the same bytes, so the export writes one image.
        #expect(ExportPhotoEncoder.sourceKey(bytes) == ExportPhotoEncoder.sourceKey(Data(bytes)))
        #expect(ExportPhotoEncoder.sourceKey(bytes) != ExportPhotoEncoder.sourceKey(Data(repeating: 0xAC, count: 512)))
    }

    @Test func unreadableBytesAreSkippedRatherThanFatal() {
        // One bad image must cost that image, not the migration.
        #expect(ExportPhotoEncoder.encode(Data("not an image".utf8)) == nil)
    }

    @Test func encodingProducesJpegWhoseHashMatchesItsBytes() throws {
        let source = try #require(pixels(width: 40, height: 30))
        let encoded = try #require(ExportPhotoEncoder.encode(source))

        // The importer checks exactly this, photo by photo, which is why the
        // hash is taken over the *exported* bytes rather than the source.
        #expect(encoded.sha256.count == 64)
        #expect(encoded.sha256 == ExportPhotoEncoder.sourceKey(encoded.jpeg))
        #expect(encoded.jpeg.starts(with: [0xFF, 0xD8]), "JPEG SOI marker")
    }

    // MARK: The document

    @Test func theDocumentIsValidJsonWithPhotosLast() async throws {
        let context = try makeContext()
        SampleData.populate(context)
        try context.save()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let exporter = DataExporter(modelContainer: context.container)
        let result = try await exporter.export(to: url, reminderMinutes: 960)

        let raw = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ReadDocument.self, from: raw)

        #expect(decoded.format == ExportFormat.name)
        #expect(decoded.formatVersion == ExportFormat.version)
        #expect(decoded.plants.count == result.counts.plants)
        #expect(result.counts.plants > 0)

        // Key order is contractual in exactly one respect, and this is it: the
        // importer validates every reference before touching a byte of image
        // data, which only works if the bytes come last.
        let text = try #require(String(data: raw, encoding: .utf8))
        // `"photos":{` and not `"photos":` — the envelope's `counts` object has a
        // `photos` key too, and it is a number. Searching for the bare key finds
        // the count first and the assertion passes or fails for the wrong reason.
        let photosAt = try #require(text.range(of: "\"photos\":{"))
        let plantsAt = try #require(text.range(of: "\"plants\":["))
        #expect(plantsAt.lowerBound < photosAt.lowerBound)
    }

    @Test func optionalFieldsAreWrittenAsExplicitNull() async throws {
        let context = try makeContext()
        let plant = Plant(name: "Basil")
        context.insert(plant)

        let log = CareLog(type: .note, note: "hello")
        log.plant = plant
        context.insert(log)
        try context.save()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nulls-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await DataExporter(modelContainer: context.container).export(to: url, reminderMinutes: 960)
        let json = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))

        // Omitting nil would be valid JSON that any reader handles, but the
        // format document lists these fields and the shared fixture spells them
        // out. A contract between two codebases is worth keeping literal.
        #expect(json.contains("\"photoSha256\":null"))
        #expect(json.contains("\"sunlightFrom\":null"))
    }

    // MARK: Helpers

    /// Runs a real export into a temporary file and hands back one plant's DTO.
    ///
    /// Deliberately the whole exporter rather than the DTO builder in isolation:
    /// what these tests are checking is what lands in the file the other
    /// codebase reads, and every layer between here and there can get it wrong.
    private func export(_ plant: Plant, in context: ModelContext) async throws -> ReadPlant {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dto-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try context.save()
        let exporter = DataExporter(modelContainer: context.container)
        _ = try await exporter.export(to: url, reminderMinutes: 960)

        let document = try JSONDecoder().decode(ReadDocument.self, from: try Data(contentsOf: url))

        return try #require(document.plants.first { $0.id == plant.id.uuidString.lowercased() })
    }

    private func pixels(width: Int, height: Int) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))

        return renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()
    }
}

// MARK: - Reading the export back

/// Test-only mirrors of the export shape.
///
/// Deliberately *not* `Decodable` conformances on the shipping DTOs. Those are
/// `Encodable` and nothing else, because the app never reads an export — only
/// the server does. Declaring independent readers here also means these tests
/// check the JSON that was actually written rather than round-tripping through
/// the same type that wrote it, which would pass even if the field names were
/// wrong on both sides.
private struct ReadDocument: Decodable {
    let format: String
    let formatVersion: Int
    let plants: [ReadPlant]
}

private struct ReadPlant: Decodable {
    let id: String
    let name: String
    let photoSha256: String?
    let acquiredLocalDay: String
    let schedules: [ReadSchedule]
    let wateringSeasons: [ReadSeason]
    let logs: [ReadLog]
}

private struct ReadSchedule: Decodable {
    let id: String
    let type: String
    let intervalDays: Int
    let isEnabled: Bool
    let lastDoneAt: String?
    let lastDoneLocalDay: String?
    let nextDueAt: String
    let nextDueLocalDay: String
    let matchesDerivedNextDue: Bool
}

private struct ReadSeason: Decodable {
    let id: String
    let months: [Int]
    let intervalDays: Int
}

private struct ReadLog: Decodable {
    let id: String
    let type: String
    let at: String
    let localDay: String
    let note: String
    let photoSha256: String?
    let sunlightFrom: Int?
    let sunlightTo: Int?
    let soilFrom: Int?
    let soilTo: Int?
}
