import Foundation
import SwiftData

/// Reads a `plantplant.export` file back into the library.
///
/// The counterpart to `DataExporter`, and a `@ModelActor` for the same reason:
/// `@Model` types are not `Sendable`, so the fetch, the writes and every
/// `photoData` assignment have to happen on one actor, off the main one.
///
/// Three decisions carry all the risk, and each is the one the web importer
/// already made — a file that means one thing on the server and another here
/// would be worse than no importer at all:
///
///  1. **The exported `nextDue` is trusted, never recomputed.** Recomputing from
///     `lastDone + interval` would silently un-snooze every deferred task,
///     because snooze patches `nextDue` on purpose and leaves `lastDone` alone.
///     Divergence is counted and reported instead.
///  2. **`nextWaterDue` is recomputed, never trusted.** It is a denormalised
///     cache, not user intent — which is why the export does not even carry it.
///  3. **Logs are inserted or skipped, never updated.** A journal entry is a
///     historical fact, and that is what makes re-importing the same file a
///     no-op rather than a duplicated journal.
///
/// All or nothing: everything happens in one `ModelContext` that is saved once
/// at the end, and any failure rolls the whole thing back. A half-imported
/// library is much worse than a failed import, because there is no way to tell
/// by looking which half arrived.
@ModelActor
actor DataImporter {

    /// Reads the file and works out what importing it would do, writing nothing.
    func preview(of url: URL) throws -> ImportPreview {
        let reader = try ExportReader(url: url)
        let document = reader.document
        var warnings: [String] = []

        // A file exported in another timezone is not wrong, but every "due
        // today" in it was decided against a different midnight, so dates can
        // land a day either side. Worth saying before rather than after.
        if document.envelope.timeZone != TimeZone.current.identifier {
            warnings.append(String(localized: "Exported in \(document.envelope.timeZone); this device is in \(TimeZone.current.identifier). Due dates may shift by a day."))
        }

        for warning in document.envelope.diagnostics.warnings {
            warnings.append(warning)
        }

        if document.envelope.diagnostics.photosSkipped > 0 {
            warnings.append(String(localized: "\(document.envelope.diagnostics.photosSkipped) photos could not be read when this file was written and are not in it."))
        }

        let knownRooms = Set(try modelContext.fetch(FetchDescriptor<Room>()).map(\.id))
        let localPlants = try modelContext.fetch(FetchDescriptor<Plant>())
        let knownPlants = Set(localPlants.map(\.id))

        let fileRooms = document.rooms.compactMap { UUID(uuidString: $0.id) }
        let filePlants = document.plants.compactMap { UUID(uuidString: $0.id) }

        let photos = try reader.photoCount()

        if photos < document.envelope.counts.photos {
            warnings.append(String(localized: "The file says it has \(document.envelope.counts.photos) photos but only \(photos) are in it."))
        }

        return ImportPreview(
            generator: document.envelope.generator,
            exportedAt: ExportFormat.date(parsing: document.envelope.exportedAt),
            timeZone: document.envelope.timeZone,
            reminderMinutes: document.envelope.preferences.reminderMinutes,
            rooms: document.rooms.count,
            plants: document.plants.count,
            schedules: document.plants.reduce(0) { $0 + $1.schedules.count },
            seasons: document.plants.reduce(0) { $0 + $1.wateringSeasons.count },
            logs: document.plants.reduce(0) { $0 + $1.logs.count },
            photos: photos,
            plantsAlreadyHere: filePlants.filter(knownPlants.contains).count,
            roomsAlreadyHere: fileRooms.filter(knownRooms.contains).count,
            plantsOnDevice: localPlants.count,
            warnings: warnings
        )
    }

    /// Imports the file. Throws — having changed nothing — if anything goes wrong.
    func run(
        _ url: URL,
        mode: ImportMode,
        progress: @Sendable (ImportProgress) -> Void = { _ in }
    ) throws -> ImportReport {
        do {
            return try write(url, mode: mode, progress: progress)
        } catch {
            // Discards every pending insert, update and delete. Without it a
            // failure halfway through the plants would leave the library in a
            // state nobody can reason about, and the file would look like the
            // thing that had already been applied.
            modelContext.rollback()

            throw error
        }
    }

    // MARK: - The write

    private func write(
        _ url: URL,
        mode: ImportMode,
        progress: @Sendable (ImportProgress) -> Void
    ) throws -> ImportReport {
        progress(ImportProgress(phase: .reading, done: 0, total: 0))

        let reader = try ExportReader(url: url)
        let document = reader.document
        var report = ImportReport()

        if mode == .replace {
            // Rooms go with them: a plant's room is a plain reference, not a
            // cascade, so deleting only plants would leave every room behind and
            // the file's rooms would merge into those by name.
            let existing = try modelContext.fetch(FetchDescriptor<Plant>())
            report.plantsDeleted = existing.count

            for plant in existing {
                // Release the external-storage files explicitly, exactly as
                // `CareService.delete` does — a cascade drops the rows but not
                // the blobs behind them.
                plant.photoData = nil
                for log in plant.logs ?? [] { log.photoData = nil }
                modelContext.delete(plant)
            }

            for room in try modelContext.fetch(FetchDescriptor<Room>()) {
                modelContext.delete(room)
            }
        }

        // ── Rooms ────────────────────────────────────────────────────────────
        var roomsByID: [UUID: Room] = [:]
        let existingRooms = mode == .replace ? [] : try modelContext.fetch(FetchDescriptor<Room>())
        var roomsByName: [String: Room] = [:]

        for room in existingRooms {
            roomsByID[room.id] = room
            roomsByName[Self.nameKey(room.name)] = room
        }

        for dto in document.rooms {
            guard let id = UUID(uuidString: dto.id) else {
                report.warnings.append(String(localized: "Skipped a room with an unreadable id."))
                continue
            }

            // By id, then by name. The name fallback is for rooms only, and it
            // exists because "Living room" typed into this app before the import
            // is the same room the file is talking about — whereas two plants
            // both called Monstera are simply two plants.
            if let existing = roomsByID[id] ?? roomsByName[Self.nameKey(dto.name)] {
                existing.name = dto.name
                existing.sortIndex = dto.sortIndex
                roomsByID[id] = existing
                report.roomsUpdated += 1
            } else {
                let room = Room(name: dto.name, sortIndex: dto.sortIndex)
                room.id = id
                modelContext.insert(room)
                roomsByID[id] = room
                roomsByName[Self.nameKey(dto.name)] = room
                report.roomsCreated += 1
            }
        }

        // ── Plants ───────────────────────────────────────────────────────────
        var existingPlants: [UUID: Plant] = [:]
        if mode != .replace {
            for plant in try modelContext.fetch(FetchDescriptor<Plant>()) {
                existingPlants[plant.id] = plant
            }
        }

        /// Which plant or log each photo hash belongs to. Built now so the photo
        /// pass is a lookup rather than a second walk of the document.
        var plantPhotos: [String: [Plant]] = [:]
        var logPhotos: [String: [CareLog]] = [:]
        var touched: [Plant] = []

        progress(ImportProgress(phase: .plants, done: 0, total: document.plants.count))

        for (index, dto) in document.plants.enumerated() {
            try Task.checkCancellation()

            guard let id = UUID(uuidString: dto.id) else {
                report.warnings.append(String(localized: "Skipped a plant with an unreadable id."))
                continue
            }

            let plant: Plant

            if let existing = existingPlants[id] {
                plant = existing
                report.plantsUpdated += 1
            } else {
                plant = Plant()
                plant.id = id
                modelContext.insert(plant)
                existingPlants[id] = plant
                report.plantsCreated += 1
            }

            plant.name = dto.name
            plant.scientificName = dto.scientificName
            plant.notes = dto.notes
            plant.isArchived = dto.isArchived
            plant.createdAt = ExportFormat.date(parsing: dto.createdAt) ?? plant.createdAt
            plant.acquiredDate = ExportFormat.date(parsing: dto.acquiredAt) ?? plant.acquiredDate

            // Unknown levels fall back to the same defaults the models use, so a
            // file from a future version that added a level loses that one field
            // rather than the plant.
            if let sunlight = SunlightLevel(rawValue: dto.sunlight) {
                plant.sunlight = sunlight
            } else if !dto.sunlight.isEmpty {
                report.warnings.append(String(localized: "\(dto.name): unknown sunlight level \"\(dto.sunlight)\"."))
            }

            if let soil = SoilDryness(rawValue: dto.soilDryness) {
                plant.soilDryness = soil
            } else if !dto.soilDryness.isEmpty {
                report.warnings.append(String(localized: "\(dto.name): unknown water-when level \"\(dto.soilDryness)\"."))
            }

            if let roomId = dto.roomId {
                if let room = UUID(uuidString: roomId).flatMap({ roomsByID[$0] }) {
                    plant.room = room
                } else {
                    plant.room = nil
                    report.warnings.append(String(localized: "\(dto.name): its room is not in the file, so it has no room."))
                }
            } else {
                plant.room = nil
            }

            if let hash = dto.photoSha256 {
                plantPhotos[hash, default: []].append(plant)
            }

            report.schedules += applySchedules(dto.schedules, to: plant, report: &report)
            report.seasons += applySeasons(dto.wateringSeasons, to: plant, report: &report)
            applyLogs(dto.logs, to: plant, photos: &logPhotos, report: &report)

            touched.append(plant)
            progress(ImportProgress(phase: .plants, done: index + 1, total: document.plants.count))
        }

        // ── Photos ───────────────────────────────────────────────────────────
        // Last, because they are last in the file — which is the point of the
        // ordering: every reference above is resolved before a byte of image
        // data is read, so a file that is wrong is rejected cheaply.
        let expected = plantPhotos.count + logPhotos.count
        var seen = 0
        progress(ImportProgress(phase: .photos, done: 0, total: max(expected, 1)))

        try reader.forEachPhoto { hash, jpeg in
            try Task.checkCancellation()
            seen += 1

            guard let jpeg else {
                report.photosSkipped += 1
                report.warnings.append(String(localized: "A photo could not be decoded and was left out."))

                return
            }

            // The reason the map is keyed by content hash rather than numbered:
            // it can be checked. Bytes that do not hash to their own key were
            // corrupted somewhere between the two devices, and writing them
            // would put a broken image in the journal permanently.
            guard ExportPhotoEncoder.sha256Hex(jpeg) == hash else {
                report.photosSkipped += 1
                report.warnings.append(String(localized: "A photo did not match its checksum and was left out."))

                return
            }

            for plant in plantPhotos[hash] ?? [] {
                plant.photoData = jpeg
                report.photosLinked += 1
            }

            for log in logPhotos[hash] ?? [] {
                log.photoData = jpeg
                report.photosLinked += 1
            }

            progress(ImportProgress(phase: .photos, done: min(seen, max(expected, 1)), total: max(expected, 1)))
        }

        // ── Finish ───────────────────────────────────────────────────────────
        progress(ImportProgress(phase: .finishing, done: 0, total: 0))

        // Recomputed, never imported. The export deliberately does not carry it:
        // it is this app's own denormalisation and it drifts the moment an
        // importer treats it as data.
        for plant in touched {
            CareService.syncWaterDue(plant)
        }

        try modelContext.save()

        return report
    }

    // MARK: - Children

    private func applySchedules(_ dtos: [ScheduleDTO], to plant: Plant, report: inout ImportReport) -> Int {
        var byID: [UUID: CareSchedule] = [:]
        for schedule in plant.schedules ?? [] { byID[schedule.id] = schedule }

        var written = 0

        for dto in dtos {
            guard let id = UUID(uuidString: dto.id) else { continue }

            guard let nextDue = ExportFormat.date(parsing: dto.nextDueAt) else {
                report.warnings.append(String(localized: "\(plant.name): a reminder had an unreadable due date and was skipped."))
                continue
            }

            let type = CareType(rawValue: dto.type) ?? .water

            if CareType(rawValue: dto.type) == nil {
                report.warnings.append(String(localized: "\(plant.name): unknown care type \"\(dto.type)\", imported as watering."))
            }

            let schedule = byID[id] ?? {
                let created = CareSchedule(type: type)
                created.id = id
                created.plant = plant
                modelContext.insert(created)

                return created
            }()

            schedule.type = type
            // Clamped to the range the editor's stepper allows, so an out-of-range
            // value cannot arrive by file and then be impossible to edit back.
            schedule.intervalDays = max(1, min(730, dto.intervalDays))
            schedule.isEnabled = dto.isEnabled
            schedule.lastDone = dto.lastDoneAt.flatMap { ExportFormat.date(parsing: $0) }
            schedule.nextDue = nextDue

            if !dto.matchesDerivedNextDue {
                report.divergentSchedules += 1
            }

            written += 1
        }

        return written
    }

    private func applySeasons(_ dtos: [SeasonDTO], to plant: Plant, report: inout ImportReport) -> Int {
        var byID: [UUID: WateringSeason] = [:]
        for season in plant.wateringSeasons ?? [] { byID[season.id] = season }

        var written = 0

        for dto in dtos {
            guard let id = UUID(uuidString: dto.id) else { continue }

            let months = dto.months.filter { (1...12).contains($0) }.sorted()

            // A season covering no months can never apply, and the editor cannot
            // produce one. Keeping it would put an uneditable row in the plant's
            // editor forever.
            guard !months.isEmpty else {
                report.warnings.append(String(localized: "\(plant.name): a seasonal interval covered no months and was dropped."))
                continue
            }

            let season = byID[id] ?? {
                let created = WateringSeason(months: months, intervalDays: dto.intervalDays)
                created.id = id
                created.plant = plant
                modelContext.insert(created)

                return created
            }()

            season.months = months
            season.intervalDays = max(1, min(730, dto.intervalDays))
            written += 1
        }

        return written
    }

    private func applyLogs(_ dtos: [LogDTO], to plant: Plant, photos: inout [String: [CareLog]], report: inout ImportReport) {
        let known = Set((plant.logs ?? []).map(\.id))

        for dto in dtos {
            guard let id = UUID(uuidString: dto.id) else { continue }

            guard !known.contains(id) else {
                report.logsSkipped += 1
                continue
            }

            guard let date = ExportFormat.date(parsing: dto.at) else {
                report.warnings.append(String(localized: "\(plant.name): a journal entry had an unreadable date and was skipped."))
                continue
            }

            let log = CareLog(type: LogType(rawValue: dto.type) ?? .note, date: date, note: dto.note)
            log.id = id
            log.sunlightFrom = dto.sunlightFrom
            log.sunlightTo = dto.sunlightTo
            log.soilFrom = dto.soilFrom
            log.soilTo = dto.soilTo
            log.plant = plant
            modelContext.insert(log)

            if let hash = dto.photoSha256 {
                photos[hash, default: []].append(log)
            }

            report.logsCreated += 1
        }
    }

    /// Rooms are matched on this, not on the raw name: "Living Room " and
    /// "living room" are the room the user means either way.
    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
