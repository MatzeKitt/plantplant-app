import Testing
import Foundation
import SwiftData
import UIKit
@testable import PlantPlant

/// The import side of the migration contract.
///
/// Most of these run a *real* export and read it back, because the thing worth
/// testing is the round trip: a field written under one name and looked for
/// under another produces a file that imports without complaint and is quietly
/// missing data, which is the failure nobody notices until the phone is wiped.
@MainActor
struct ImportTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)

        return try ModelContainer(for: SharedModelContainer.schema, configurations: [config])
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("import-test-\(UUID().uuidString).json")
    }

    /// Exports a context to a file, for importing back somewhere else.
    private func exportFile(from context: ModelContext, reminderMinutes: Int = 960) async throws -> URL {
        try context.save()
        let url = temporaryURL()
        _ = try await DataExporter(modelContainer: context.container)
            .export(to: url, reminderMinutes: reminderMinutes)

        return url
    }

    private func write(_ json: String) throws -> URL {
        let url = temporaryURL()
        try Data(json.utf8).write(to: url)

        return url
    }

    /// A syntactically complete export with whatever body the test needs.
    private func envelope(plants: String = "[]", rooms: String = "[]",
                          photos: String = "{}", formatVersion: Int = 1,
                          timeZone: String = "Europe/Berlin") -> String {
        """
        {"format":"plantplant.export","formatVersion":\(formatVersion),"generator":"test",\
        "exportedAt":"2026-09-18T12:00:00+02:00","timeZone":"\(timeZone)","utcOffsetSeconds":7200,\
        "locale":"en","photoEncoding":"base64/jpeg",\
        "counts":{"rooms":0,"plants":0,"schedules":0,"wateringSeasons":0,"logs":0,"photos":0},\
        "diagnostics":{"photosSkipped":0,"warnings":[]},"preferences":{"reminderMinutes":960},\
        "rooms":\(rooms),"plants":\(plants),"photos":\(photos)}
        """
    }

    private func plantJSON(id: String, name: String, note: String = "",
                           schedules: String = "[]", logs: String = "[]",
                           photoSha256: String = "null", roomId: String = "null",
                           sunlight: String = "brightIndirect") -> String {
        """
        {"id":"\(id)","name":"\(name)","scientificName":"","roomId":\(roomId),\
        "sunlight":"\(sunlight)","soilDryness":"topDry","notes":"\(note)","isArchived":false,\
        "createdAt":"2026-09-01T10:00:00+02:00","createdLocalDay":"2026-09-01",\
        "acquiredAt":"2026-09-01T10:00:00+02:00","acquiredLocalDay":"2026-09-01",\
        "photoSha256":\(photoSha256),"schedules":\(schedules),"wateringSeasons":[],"logs":\(logs)}
        """
    }

    private func pixels(width: Int = 60, height: Int = 40) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()!
    }

    // ── The round trip ───────────────────────────────────────────────────────

    @Test func aRoundTripReproducesTheLibrary() async throws {
        let source = ModelContext(try makeContainer())
        SampleData.populate(source)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let report = try await DataImporter(modelContainer: target).run(url, mode: .merge)
        let landed = ModelContext(target)

        let plants = try landed.fetch(FetchDescriptor<Plant>())
        let sourcePlants = try source.fetch(FetchDescriptor<Plant>())

        #expect(plants.count == sourcePlants.count)
        #expect(report.plantsCreated == sourcePlants.count)
        #expect(report.plantsUpdated == 0)
        #expect(try landed.fetch(FetchDescriptor<Room>()).count == source.fetch(FetchDescriptor<Room>()).count)

        // Not just the counts: one plant, compared field by field. A schema that
        // round-trips the right *number* of plants and loses their intervals is
        // the shape this test exists to catch.
        let original = try #require(sourcePlants.first { $0.name == "Monstera" })
        let copy = try #require(plants.first { $0.id == original.id })

        #expect(copy.name == original.name)
        #expect(copy.notes == original.notes)
        #expect(copy.sunlight == original.sunlight)
        #expect(copy.soilDryness == original.soilDryness)
        #expect(copy.room?.name == original.room?.name)
        #expect((copy.schedules ?? []).count == (original.schedules ?? []).count)
        #expect((copy.logs ?? []).count == (original.logs ?? []).count)
        #expect((copy.wateringSeasons ?? []).count == (original.wateringSeasons ?? []).count)

        let water = try #require(CareSchedules.pick(.water, from: copy.schedules))
        let sourceWater = try #require(CareSchedules.pick(.water, from: original.schedules))
        #expect(water.intervalDays == sourceWater.intervalDays)
        #expect(ExportFormat.localDay(water.nextDue) == ExportFormat.localDay(sourceWater.nextDue))
    }

    @Test func photosSurviveARoundTrip() async throws {
        let source = ModelContext(try makeContainer())
        let plant = Plant(name: "Basil")
        plant.photoData = pixels()
        source.insert(plant)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let report = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        #expect(report.photosLinked == 1)
        #expect(report.photosSkipped == 0)

        let landed = try #require(try ModelContext(target).fetch(FetchDescriptor<Plant>()).first)
        // Re-encoded on export, so not byte-identical to what went in — but it
        // has to be a real image, not a truncated or mis-decoded one.
        #expect(UIImage(data: try #require(landed.photoData)) != nil)
    }

    /// The property that makes "import, keep using the phone, import again"
    /// safe. Without it a second pass duplicates the journal, which is the one
    /// table that only ever grows.
    @Test func reimportingTheSameFileChangesNothing() async throws {
        let source = ModelContext(try makeContainer())
        SampleData.populate(source)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let importer = DataImporter(modelContainer: target)
        let first = try await importer.run(url, mode: .merge)
        let second = try await importer.run(url, mode: .merge)

        let landed = ModelContext(target)
        #expect(try landed.fetch(FetchDescriptor<Plant>()).count == first.plantsCreated)
        #expect(try landed.fetch(FetchDescriptor<Room>()).count == first.roomsCreated)

        #expect(second.plantsCreated == 0)
        #expect(second.plantsUpdated == first.plantsCreated)
        #expect(second.logsCreated == 0)
        #expect(second.logsSkipped == first.logsCreated)
        #expect(try landed.fetch(FetchDescriptor<CareLog>()).count == first.logsCreated)
    }

    // ── The two dates that must not be treated alike ──────────────────────────

    /// The single most expensive mistake available to an importer: recomputing
    /// `nextDue` from `lastDone + interval` would drag every snoozed task back to
    /// the date it was snoozed from.
    @Test func aSnoozedTaskKeepsTheDateItWasExportedWith() async throws {
        let source = ModelContext(try makeContainer())
        let plant = Plant(name: "Fiddle Leaf Fig")
        source.insert(plant)

        let schedule = CareSchedule(type: .water, intervalDays: 7)
        schedule.plant = plant
        schedule.lastDone = Calendar.current.date(byAdding: .day, value: -20, to: .now)!
        schedule.nextDue = Calendar.current.date(byAdding: .day, value: 5, to: .now)!
        source.insert(schedule)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let report = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        let landed = try #require(try ModelContext(target).fetch(FetchDescriptor<Plant>()).first)
        let copy = try #require(CareSchedules.pick(.water, from: landed.schedules))

        // Five days out, not thirteen days ago, which is where `lastDone + 7`
        // would have put it.
        #expect(copy.nextDue.daysFromToday == 5)
        // And it is reported, so the summary can say why the numbers look odd.
        #expect(report.divergentSchedules == 1)
    }

    /// The opposite call for the opposite reason: `nextWaterDue` is this app's
    /// own cache, not user intent, which is why the export does not carry it at
    /// all. If the importer ever started trusting a value from the file this
    /// would be the test that noticed.
    @Test func theWaterCacheIsRecomputedRatherThanImported() async throws {
        let source = ModelContext(try makeContainer())
        let plant = Plant(name: "Snake Plant")
        source.insert(plant)

        let schedule = CareSchedule(type: .water, intervalDays: 7)
        schedule.plant = plant
        schedule.nextDue = Calendar.current.date(byAdding: .day, value: 4, to: .now)!
        source.insert(schedule)
        CareService.syncWaterDue(plant)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        _ = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        let landed = try #require(try ModelContext(target).fetch(FetchDescriptor<Plant>()).first)
        let water = try #require(CareSchedules.pick(.water, from: landed.schedules))
        #expect(landed.nextWaterDue == water.nextDue)
    }

    @Test func aDisabledWaterScheduleLeavesTheCacheEmpty() async throws {
        let source = ModelContext(try makeContainer())
        let plant = Plant(name: "Cactus")
        source.insert(plant)

        let schedule = CareSchedule(type: .water, intervalDays: 30, isEnabled: false)
        schedule.plant = plant
        source.insert(schedule)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        _ = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        let landed = try #require(try ModelContext(target).fetch(FetchDescriptor<Plant>()).first)
        #expect(landed.nextWaterDue == nil)
    }

    // ── Modes ────────────────────────────────────────────────────────────────

    @Test func replaceDeletesWhatWasAlreadyThere() async throws {
        let source = ModelContext(try makeContainer())
        source.insert(Plant(name: "Basil"))

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let existing = ModelContext(target)
        existing.insert(Plant(name: "Something else"))
        existing.insert(Room(name: "Shed"))
        try existing.save()

        let report = try await DataImporter(modelContainer: target).run(url, mode: .replace)

        #expect(report.plantsDeleted == 1)

        let landed = ModelContext(target)
        let names = try landed.fetch(FetchDescriptor<Plant>()).map(\.name)
        #expect(names == ["Basil"])
        // Rooms go too, or the file's rooms would merge by name into leftovers
        // the user meant to be rid of.
        #expect(try landed.fetch(FetchDescriptor<Room>()).isEmpty)
    }

    @Test func mergeLeavesPlantsThatAreNotInTheFileAlone() async throws {
        let source = ModelContext(try makeContainer())
        source.insert(Plant(name: "Basil"))

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let existing = ModelContext(target)
        existing.insert(Plant(name: "Aloe"))
        try existing.save()

        _ = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        let names = try ModelContext(target).fetch(FetchDescriptor<Plant>()).map(\.name).sorted()
        #expect(names == ["Aloe", "Basil"])
    }

    /// Name matching is on for rooms and only for rooms. A "Living room" the
    /// user typed here before restoring is the room the file means; two plants
    /// both called Monstera are two plants.
    @Test func aRoomAlreadyTypedHereIsReusedRatherThanDuplicated() async throws {
        let source = ModelContext(try makeContainer())
        let room = Room(name: "Living room")
        source.insert(room)
        let plant = Plant(name: "Monstera")
        plant.room = room
        source.insert(plant)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let existing = ModelContext(target)
        // Same room, different id, and spelled the way a person would type it.
        existing.insert(Room(name: "  living Room "))
        try existing.save()

        let report = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        #expect(report.roomsCreated == 0)
        #expect(report.roomsUpdated == 1)

        let landed = ModelContext(target)
        #expect(try landed.fetch(FetchDescriptor<Room>()).count == 1)
        #expect(try landed.fetch(FetchDescriptor<Plant>()).first?.room?.name == "Living room")
    }

    // ── Leniency, and its limits ─────────────────────────────────────────────

    @Test func anUnknownCareTypeFallsBackAndSaysSo() async throws {
        let schedules = """
        [{"id":"11111111-1111-1111-1111-111111111111","type":"prune","intervalDays":14,\
        "isEnabled":true,"lastDoneAt":null,"lastDoneLocalDay":null,\
        "nextDueAt":"2026-09-20T09:00:00+02:00","nextDueLocalDay":"2026-09-20",\
        "matchesDerivedNextDue":false}]
        """
        let url = try write(envelope(plants: "[\(plantJSON(id: "22222222-2222-2222-2222-222222222222", name: "Herb", schedules: schedules))]"))
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let report = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        #expect(report.plantsCreated == 1)
        #expect(report.warnings.contains { $0.contains("prune") })

        let plant = try #require(try ModelContext(target).fetch(FetchDescriptor<Plant>()).first)
        #expect(plant.schedules?.first?.type == .water)
    }

    @Test func anOutOfRangeIntervalIsClampedToWhatTheEditorAllows() async throws {
        let schedules = """
        [{"id":"11111111-1111-1111-1111-111111111111","type":"water","intervalDays":9000,\
        "isEnabled":true,"lastDoneAt":null,"lastDoneLocalDay":null,\
        "nextDueAt":"2026-09-20T09:00:00+02:00","nextDueLocalDay":"2026-09-20",\
        "matchesDerivedNextDue":false}]
        """
        let url = try write(envelope(plants: "[\(plantJSON(id: "22222222-2222-2222-2222-222222222222", name: "Herb", schedules: schedules))]"))
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        _ = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        let plant = try #require(try ModelContext(target).fetch(FetchDescriptor<Plant>()).first)
        #expect(plant.schedules?.first?.intervalDays == 730)
    }

    /// Content addressing is only worth the trouble if someone checks it.
    @Test func aPhotoThatDoesNotMatchItsChecksumIsLeftOut() async throws {
        let hash = String(repeating: "0", count: 64)
        let bogus = Data("this is not the image you hashed".utf8).base64EncodedString()
        let plant = plantJSON(id: "33333333-3333-3333-3333-333333333333", name: "Fern",
                              photoSha256: "\"\(hash)\"")
        let url = try write(envelope(plants: "[\(plant)]", photos: "{\"\(hash)\":\"\(bogus)\"}"))
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let report = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        #expect(report.photosSkipped == 1)
        #expect(report.photosLinked == 0)
        // The plant still arrives. Losing a photo is not losing a plant.
        let landed = try #require(try ModelContext(target).fetch(FetchDescriptor<Plant>()).first)
        #expect(landed.name == "Fern")
        #expect(landed.photoData == nil)
    }

    @Test func aPlantPointingAtAMissingRoomArrivesWithoutOne() async throws {
        let plant = plantJSON(id: "44444444-4444-4444-4444-444444444444", name: "Ivy",
                              roomId: "\"55555555-5555-5555-5555-555555555555\"")
        let url = try write(envelope(plants: "[\(plant)]"))
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let report = try await DataImporter(modelContainer: target).run(url, mode: .merge)

        #expect(report.warnings.contains { $0.contains("Ivy") })
        #expect(try ModelContext(target).fetch(FetchDescriptor<Plant>()).first?.room == nil)
    }

    // ── Refusals ─────────────────────────────────────────────────────────────

    @Test func aFileFromANewerFormatIsRefusedRatherThanGuessedAt() async throws {
        let url = try write(envelope(formatVersion: 2))
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ExportReader.ReaderError.self) {
            _ = try await DataImporter(modelContainer: try makeContainer()).preview(of: url)
        }
    }

    @Test func somethingElseEntirelyIsRefused() async throws {
        let url = try write("{\"hello\":\"world\"}")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: ExportReader.ReaderError.self) {
            _ = try await DataImporter(modelContainer: try makeContainer()).preview(of: url)
        }
    }

    /// A transfer that stops early almost always stops inside the images,
    /// because everything before them is tiny. Importing "as much as arrived"
    /// would be worse than refusing: the result looks complete.
    @Test func aTruncatedFileIsRefusedAndWritesNothing() async throws {
        let source = ModelContext(try makeContainer())
        let plant = Plant(name: "Basil")
        plant.photoData = pixels()
        source.insert(plant)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let whole = try Data(contentsOf: url)
        let cut = temporaryURL()
        try whole.prefix(whole.count - 400).write(to: cut)
        defer { try? FileManager.default.removeItem(at: cut) }

        let target = try makeContainer()

        await #expect(throws: (any Error).self) {
            _ = try await DataImporter(modelContainer: target).run(cut, mode: .merge)
        }

        #expect(try ModelContext(target).fetch(FetchDescriptor<Plant>()).isEmpty)
    }

    /// The test above proves nothing was *persisted*, which is what the user
    /// sees. This proves the other half, which they do not: the importer is an
    /// actor with its own context and it is reused across attempts, so without
    /// the rollback the abandoned inserts would still be sitting there pending
    /// and would ride along on the next successful save — putting a plant from
    /// the file that failed into the library that imported cleanly.
    @Test func aFailedImportLeavesNothingBehindForTheNextOne() async throws {
        let ghostly = ModelContext(try makeContainer())
        let ghost = Plant(name: "Ghost")
        ghost.photoData = pixels()
        ghostly.insert(ghost)

        let whole = try Data(contentsOf: try await exportFile(from: ghostly))
        let cut = temporaryURL()
        try whole.prefix(whole.count - 400).write(to: cut)
        defer { try? FileManager.default.removeItem(at: cut) }

        let good = ModelContext(try makeContainer())
        good.insert(Plant(name: "Basil"))
        let url = try await exportFile(from: good)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let importer = DataImporter(modelContainer: target)

        await #expect(throws: (any Error).self) {
            _ = try await importer.run(cut, mode: .merge)
        }

        let report = try await importer.run(url, mode: .merge)

        #expect(report.plantsCreated == 1)
        #expect(try ModelContext(target).fetch(FetchDescriptor<Plant>()).map(\.name) == ["Basil"])
    }

    // ── The reader's one sharp edge ──────────────────────────────────────────

    /// A note full of quotes and braces, which is what makes the scanner's
    /// escape handling load-bearing: JSON writes the note's `"` as `\"`, and a
    /// walker that treated the backslashed quote as the end of the string would
    /// desync its depth count for the rest of the document and cut the file in
    /// the wrong place.
    ///
    /// Note what this does *not* prove. The note cannot forge the photo map
    /// marker, precisely because of that escaping — that is
    /// `aNestedPhotosKeyIsNotMistakenForTheMap`'s job.
    @Test func aNoteFullOfQuotesAndBracesIsReadBackIntact() async throws {
        let source = ModelContext(try makeContainer())
        let plant = Plant(name: "Trickster")
        plant.notes = #"watch out: ,"photos":{"deadbeef":"AAAA"} and }{ too"#
        plant.photoData = pixels()
        source.insert(plant)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try ExportReader(url: url)
        #expect(reader.document.plants.count == 1)
        #expect(reader.document.plants.first?.notes == plant.notes)
        #expect(try reader.photoCount() == 1)

        let target = try makeContainer()
        let report = try await DataImporter(modelContainer: target).run(url, mode: .merge)
        #expect(report.plantsCreated == 1)
        #expect(report.photosLinked == 1)
    }

    /// `photos` is already not a unique key in this format — the envelope's
    /// `counts` carries one — so the name cannot be what identifies the map.
    /// Here a second one is buried inside `diagnostics`, where the decoders
    /// ignore it, and a reader that searched forward for the first `"photos":{`
    /// would cut the document before the plants ever appeared. Leniency would
    /// then make that a silent import of nothing rather than an error, which is
    /// the worst available outcome.
    @Test func aNestedPhotosKeyIsNotMistakenForTheMap() async throws {
        let plant = plantJSON(id: "66666666-6666-6666-6666-666666666666", name: "Oregano")
        let decoy = #""diagnostics":{"photosSkipped":0,"warnings":[],"photos":{"nope":"AAAA"}}"#
        let json = envelope(plants: "[\(plant)]")
            .replacingOccurrences(of: #""diagnostics":{"photosSkipped":0,"warnings":[]}"#, with: decoy)

        // The decoy really is in there, or this test proves nothing at all.
        #expect(json.contains(decoy))

        let url = try write(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try ExportReader(url: url)
        #expect(reader.document.plants.count == 1)
        #expect(try reader.photoCount() == 0)
    }

    @Test func anExportWithNoPhotosStillReadsBack() async throws {
        let source = ModelContext(try makeContainer())
        source.insert(Plant(name: "Basil"))

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try ExportReader(url: url)
        #expect(try reader.photoCount() == 0)
        #expect(reader.document.plants.count == 1)
    }

    // ── The preview ──────────────────────────────────────────────────────────

    @Test func thePreviewCountsWhatIsAlreadyHereWithoutWritingAnything() async throws {
        let source = ModelContext(try makeContainer())
        SampleData.populate(source)

        let url = try await exportFile(from: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let target = try makeContainer()
        let importer = DataImporter(modelContainer: target)

        let fresh = try await importer.preview(of: url)
        #expect(fresh.plants > 0)
        #expect(fresh.plantsAlreadyHere == 0)
        #expect(fresh.plantsOnDevice == 0)
        // Previewing must not have written a thing.
        #expect(try ModelContext(target).fetch(FetchDescriptor<Plant>()).isEmpty)

        _ = try await importer.run(url, mode: .merge)
        let again = try await importer.preview(of: url)
        #expect(again.plantsAlreadyHere == again.plants)
        #expect(again.plantsOnDevice == again.plants)
    }

    @Test func anExportFromAnotherTimeZoneIsFlagged() async throws {
        let elsewhere = TimeZone.current.identifier == "Pacific/Auckland" ? "Europe/Berlin" : "Pacific/Auckland"
        let url = try write(envelope(timeZone: elsewhere))
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = try await DataImporter(modelContainer: try makeContainer()).preview(of: url)

        #expect(preview.warnings.contains { $0.contains(elsewhere) })
    }
}
