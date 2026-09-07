import Foundation
import SwiftData

/// Writes the whole library to one `plantplant.export` JSON file.
///
/// A `@ModelActor` because `@Model` types are not `Sendable`: the fetch, every
/// relationship traversal and every `photoData` access has to happen on one
/// actor, and doing it off the main one is the difference between a progress bar
/// that animates and an app that appears to hang for thirty seconds.
///
/// Two passes over the photos, which is what keeps peak memory at one image
/// rather than the whole library:
///
///  1. **Encode.** Every distinct image is downscaled, re-encoded and hashed,
///     and the JPEG is parked in a temporary directory. Only the hash is kept in
///     memory. This has to come first because plants and logs reference photos
///     by hash, and they are written before the photo map.
///  2. **Emit.** The JSON is written — envelope, rooms, plants — and then each
///     parked JPEG is read back, base64'd and appended to the `photos` map,
///     which the format requires to be last.
///
/// Peak memory is therefore one photo's decode plus its JPEG plus its base64,
/// around three or four megabytes, whatever the library size.
@ModelActor
actor DataExporter {
    enum ExportError: Error {
        case cannotCreateWorkspace
    }

    /// A photo that has been encoded and parked, waiting to be emitted.
    private struct ParkedPhoto {
        let sha256: String
        let url: URL
    }

    func export(
        to destination: URL,
        options: ExportOptions = ExportOptions(),
        reminderMinutes: Int,
        progress: @Sendable (ExportProgress) -> Void = { _ in }
    ) throws -> ExportResult {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("plantplant-export-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        } catch {
            throw ExportError.cannotCreateWorkspace
        }

        defer { try? FileManager.default.removeItem(at: workspace) }

        do {
            return try write(to: destination, workspace: workspace, options: options,
                             reminderMinutes: reminderMinutes, progress: progress)
        } catch {
            // A partial file must never survive to be shared. The workspace goes
            // with the `defer` above.
            JSONStreamWriter.discard(at: destination)

            throw error
        }
    }

    // MARK: - The two passes

    private func write(
        to destination: URL,
        workspace: URL,
        options: ExportOptions,
        reminderMinutes: Int,
        progress: @Sendable (ExportProgress) -> Void
    ) throws -> ExportResult {
        progress(ExportProgress(phase: .reading, done: 0, total: 0))

        let rooms = try modelContext.fetch(FetchDescriptor<Room>())
            .sorted { ($0.sortIndex, $0.name, $0.id.uuidString) < ($1.sortIndex, $1.name, $1.id.uuidString) }
        let plants = try modelContext.fetch(FetchDescriptor<Plant>())
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }

        try Task.checkCancellation()

        // ── Pass 1: encode and park every distinct photo ─────────────────────
        var parked: [String: ParkedPhoto] = [:]
        var photoHashes: [UUID: String] = [:]
        var summary = ExportSummary()
        var warnings: [String] = []

        if options.includePhotos {
            let subjects = photoSubjects(of: plants)
            progress(ExportProgress(phase: .photos, done: 0, total: subjects.count))

            for (index, subject) in subjects.enumerated() {
                try Task.checkCancellation()

                // One image in, one image out, per iteration. Without the pool
                // the decoded CGImages accumulate until the loop ends, which on
                // a large library is exactly the out-of-memory kill this whole
                // design exists to avoid.
                autoreleasepool {
                    if let hash = park(subject.data, into: workspace, options: options, cache: &parked) {
                        photoHashes[subject.owner] = hash
                    } else {
                        summary.photosSkipped += 1
                        warnings.append("A photo could not be read and was skipped.")
                    }
                }

                progress(ExportProgress(phase: .photos, done: index + 1, total: subjects.count))
            }
        }

        summary.photos = parked.count

        // ── Pass 2: write the document ───────────────────────────────────────
        let now = Date()
        let zone = TimeZone.current
        let roomDTOs = rooms.map(Self.roomDTO)
        var plantDTOs: [PlantDTO] = []

        for plant in plants {
            try Task.checkCancellation()
            plantDTOs.append(Self.plantDTO(plant, photoHashes: photoHashes))
        }

        summary.rooms = roomDTOs.count
        summary.plants = plantDTOs.count
        summary.schedules = plantDTOs.reduce(0) { $0 + $1.schedules.count }
        summary.wateringSeasons = plantDTOs.reduce(0) { $0 + $1.wateringSeasons.count }
        summary.logs = plantDTOs.reduce(0) { $0 + $1.logs.count }

        progress(ExportProgress(phase: .writing, done: 0, total: parked.count))

        let writer = try JSONStreamWriter(url: destination)
        writer.beginDocument()

        try writer.writeFlattened(ExportEnvelope(
            format: ExportFormat.name,
            formatVersion: ExportFormat.version,
            generator: ExportFormat.generator(),
            exportedAt: ExportFormat.instant(now, in: zone),
            timeZone: zone.identifier,
            utcOffsetSeconds: zone.secondsFromGMT(for: now),
            locale: Locale.current.identifier,
            photoEncoding: ExportFormat.photoEncoding,
            counts: ExportCounts(
                rooms: summary.rooms,
                plants: summary.plants,
                schedules: summary.schedules,
                wateringSeasons: summary.wateringSeasons,
                logs: summary.logs,
                photos: summary.photos
            ),
            diagnostics: ExportDiagnostics(photosSkipped: summary.photosSkipped, warnings: warnings),
            preferences: ExportPreferences(reminderMinutes: reminderMinutes)
        ))

        try writer.write(roomDTOs, forKey: "rooms")
        try writer.write(plantDTOs, forKey: "plants")

        // `photos` is last. Everything above can then be validated by the
        // importer before it touches a byte of image data.
        writer.beginObject(forKey: "photos")

        for (index, photo) in parked.values.sorted(by: { $0.sha256 < $1.sha256 }).enumerated() {
            try Task.checkCancellation()

            try autoreleasepool {
                let jpeg = try Data(contentsOf: photo.url, options: .mappedIfSafe)
                try writer.writeBase64(jpeg.base64EncodedString(), forKey: photo.sha256)
            }

            progress(ExportProgress(phase: .writing, done: index + 1, total: parked.count))
        }

        writer.endObject()
        try writer.endDocument()

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let byteSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        progress(ExportProgress(phase: .done, done: 1, total: 1))

        return ExportResult(url: destination, byteSize: byteSize, counts: summary)
    }

    // MARK: - Photos

    /// Every image in the library, paired with the id of the thing holding it.
    ///
    /// A plant and its newest `photoChanged` log normally hold the *same* bytes,
    /// which is the case content addressing exists to collapse: both subjects
    /// come back, both encode to the same hash, and only one image is written.
    private func photoSubjects(of plants: [Plant]) -> [(owner: UUID, data: Data)] {
        var subjects: [(owner: UUID, data: Data)] = []

        for plant in plants {
            if let data = plant.photoData {
                subjects.append((plant.id, data))
            }

            for log in (plant.logs ?? []).sorted(by: { $0.date < $1.date }) {
                if let data = log.photoData {
                    subjects.append((log.id, data))
                }
            }
        }

        return subjects
    }

    /// Encodes one image and parks it, returning its hash — or nil if it cannot
    /// be read.
    ///
    /// `cache` is keyed by a hash of the *source* bytes, so the duplicate that
    /// every photo reminder creates costs one cheap hash rather than a second
    /// decode-downscale-encode round trip.
    private func park(
        _ data: Data,
        into workspace: URL,
        options: ExportOptions,
        cache: inout [String: ParkedPhoto]
    ) -> String? {
        let key = ExportPhotoEncoder.sourceKey(data)

        if let existing = cache[key] {
            return existing.sha256
        }

        guard let encoded = ExportPhotoEncoder.encode(data, fullResolution: options.fullResolution) else {
            return nil
        }

        // Two different source images can downscale to identical bytes — two
        // shots of the same wall, say — so the parked map is keyed by the
        // *output* hash and the source key merely points at it.
        if let already = cache.values.first(where: { $0.sha256 == encoded.sha256 }) {
            cache[key] = already

            return already.sha256
        }

        let url = workspace.appendingPathComponent("\(encoded.sha256).jpg")

        guard (try? encoded.jpeg.write(to: url, options: .atomic)) != nil else {
            return nil
        }

        cache[key] = ParkedPhoto(sha256: encoded.sha256, url: url)

        return encoded.sha256
    }

    // MARK: - DTO construction

    private static func roomDTO(_ room: Room) -> RoomDTO {
        RoomDTO(id: room.id.uuidString.lowercased(), name: room.name, sortIndex: room.sortIndex)
    }

    private static func plantDTO(_ plant: Plant, photoHashes: [UUID: String]) -> PlantDTO {
        let schedules = (plant.schedules ?? [])
            .sorted { ($0.typeRaw, $0.id.uuidString) < ($1.typeRaw, $1.id.uuidString) }
            .map(scheduleDTO)

        let seasons = (plant.wateringSeasons ?? [])
            .sorted { ($0.months.first ?? 0, $0.id.uuidString) < ($1.months.first ?? 0, $1.id.uuidString) }
            .map { SeasonDTO(id: $0.id.uuidString.lowercased(), months: $0.months.sorted(), intervalDays: $0.intervalDays) }

        let logs = (plant.logs ?? [])
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            .map { logDTO($0, photoHashes: photoHashes) }

        return PlantDTO(
            id: plant.id.uuidString.lowercased(),
            name: plant.name,
            scientificName: plant.scientificName,
            roomId: plant.room?.id.uuidString.lowercased(),
            sunlight: plant.sunlight.rawValue,
            soilDryness: plant.soilDryness.rawValue,
            notes: plant.notes,
            isArchived: plant.isArchived,
            createdAt: ExportFormat.instant(plant.createdAt),
            createdLocalDay: ExportFormat.localDay(plant.createdAt),
            acquiredAt: ExportFormat.instant(plant.acquiredDate),
            acquiredLocalDay: ExportFormat.localDay(plant.acquiredDate),
            photoSha256: photoHashes[plant.id],
            schedules: schedules,
            wateringSeasons: seasons,
            logs: logs
        )
    }

    private static func scheduleDTO(_ schedule: CareSchedule) -> ScheduleDTO {
        ScheduleDTO(
            id: schedule.id.uuidString.lowercased(),
            type: schedule.type.rawValue,
            intervalDays: schedule.intervalDays,
            isEnabled: schedule.isEnabled,
            lastDoneAt: schedule.lastDone.map { ExportFormat.instant($0) },
            lastDoneLocalDay: schedule.lastDone.map { ExportFormat.localDay($0) },
            nextDueAt: ExportFormat.instant(schedule.nextDue),
            nextDueLocalDay: ExportFormat.localDay(schedule.nextDue),
            matchesDerivedNextDue: derivesCleanly(schedule)
        )
    }

    /// Whether `nextDue` is what rescheduling from `lastDone` would have produced.
    ///
    /// Compared by calendar day, not by instant, because that is what the
    /// importer's own check compares — and because every date decision in both
    /// apps is a whole-day decision. A schedule that was never completed has
    /// nothing to derive from and reports false.
    private static func derivesCleanly(_ schedule: CareSchedule) -> Bool {
        guard let lastDone = schedule.lastDone else { return false }

        let interval = schedule.effectiveInterval(on: lastDone)

        guard let derived = Calendar.current.date(byAdding: .day, value: interval, to: lastDone) else {
            return false
        }

        return ExportFormat.localDay(derived) == ExportFormat.localDay(schedule.nextDue)
    }

    private static func logDTO(_ log: CareLog, photoHashes: [UUID: String]) -> LogDTO {
        LogDTO(
            id: log.id.uuidString.lowercased(),
            type: log.type.rawValue,
            at: ExportFormat.instant(log.date),
            localDay: ExportFormat.localDay(log.date),
            note: log.note,
            photoSha256: photoHashes[log.id],
            sunlightFrom: log.sunlightFrom,
            sunlightTo: log.sunlightTo,
            soilFrom: log.soilFrom,
            soilTo: log.soilTo
        )
    }
}
