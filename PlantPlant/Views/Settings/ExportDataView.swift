import SwiftUI
import SwiftData

/// The one screen that migrates a library out of this app.
///
/// It is deliberately unhurried: options, an estimate, a warning where one is
/// due, a progress bar with a cancel button, and only then a share sheet. The
/// export is the rollback artifact for the whole migration, so the thing to
/// optimise for is the user understanding what they got — not the fewest taps.
struct ExportDataView: View {
    @Query private var plants: [Plant]
    @Environment(\.modelContext) private var context
    @AppStorage(NotificationManager.reminderMinutesKey)
    private var reminderMinutes = NotificationManager.defaultReminderMinutes

    @State private var options = ExportOptions()
    @State private var progress: ExportProgress?
    @State private var result: ExportResult?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    private var isRunning: Bool { task != nil }

    var body: some View {
        Form {
            Section {
                LabeledContent("Plants", value: "\(plants.count)")
                LabeledContent("Photos", value: "\(photoCount)")
                LabeledContent("Estimated size", value: estimatedSize)
            } header: {
                Text("What will be exported")
            } footer: {
                Text("Everything: plants, rooms, care schedules, seasonal watering, the full journal and every photo. One file.")
            }

            Section {
                Toggle("Include photos", isOn: $options.includePhotos)
                Toggle("Full resolution", isOn: $options.fullResolution)
                    .disabled(!options.includePhotos)
            } header: {
                Text("Options")
            } footer: {
                // The honest version of "leave this off": 2000px is not a
                // compromise, it is exactly what both apps render.
                Text(options.fullResolution
                     ? "Full resolution can produce a file too large to upload. Photos are normally scaled to 2000 pixels, which is the largest size either app ever displays — nothing visible is lost."
                     : "Photos are scaled to 2000 pixels on their long edge, which is the largest size either app displays.")
            }

            if let progress, isRunning {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress.fraction)
                        Text(label(for: progress))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel", role: .destructive) { cancel() }
                }
            }

            if let result {
                Section {
                    LabeledContent("File size", value: result.readableSize)
                    LabeledContent("Photos", value: "\(result.counts.photos)")
                    if result.counts.photosSkipped > 0 {
                        LabeledContent("Skipped", value: "\(result.counts.photosSkipped)")
                            .foregroundStyle(.orange)
                    }
                    ShareLink(item: result.url) {
                        Label("Share export", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Ready")
                } footer: {
                    // The thing that will otherwise annoy them daily, said at
                    // the moment it becomes relevant — and never done for them,
                    // because the phone is the rollback.
                    Text("After importing on the web, turn reminders off here so you don't get them twice. Keep this file until you're sure.")
                }
            }

            if let failure {
                Section {
                    Text(failure).foregroundStyle(.red)
                }
            }

            if !isRunning {
                Section {
                    Button(result == nil ? "Export Data" : "Export Again") { start() }
                }
            }
        }
        .navigationTitle("Export Data")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isRunning)
        .onDisappear { cancel() }
    }

    /// Distinct photos, not photo *references*.
    ///
    /// Counting references would say 12 where the export writes 8, because a
    /// plant's current photo and the journal entry that captured it are normally
    /// the same bytes — the duplication content addressing exists to collapse.
    /// `photoHistory` is the model's own answer to "which photos does this plant
    /// actually have", so the count here and the gallery agree.
    private var photoCount: Int {
        plants.reduce(0) { $0 + $1.photoHistory.count }
    }

    /// Bytes on the device, and a rough guess at what comes out.
    ///
    /// Rough on purpose and labelled as such: the real number depends on how
    /// each photo compresses. What the user needs from this is "megabytes or
    /// hundreds of megabytes", which is enough to decide about full resolution.
    private var estimatedSize: String {
        guard options.includePhotos else { return "< 1 MB" }

        let onDevice = plants.reduce(0) { total, plant in
            total + plant.photoHistory.reduce(0) { $0 + $1.count }
        }

        // Base64 costs a third. Downscaling to 2000px typically takes a camera
        // original to about a sixth of its size.
        let estimate = options.fullResolution
            ? Double(onDevice) * 1.37
            : Double(photoCount) * 500_000 * 1.37

        return "≈ " + ByteCountFormatter.string(fromByteCount: Int64(max(estimate, 300_000)), countStyle: .file)
    }

    private func label(for progress: ExportProgress) -> String {
        switch progress.phase {
        case .reading: return String(localized: "Reading your plants…")
        case .photos: return String(localized: "Preparing photo \(progress.done) of \(progress.total)")
        case .writing: return String(localized: "Writing photo \(progress.done) of \(progress.total)")
        case .done: return String(localized: "Finishing…")
        }
    }

    private func start() {
        result = nil
        failure = nil
        progress = ExportProgress(phase: .reading, done: 0, total: 0)

        let container = context.container
        let options = options
        let minutes = reminderMinutes
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.filename(), isDirectory: false)

        task = Task {
            // A @ModelActor, so the fetch, the photo access and the DTO building
            // all happen off the main actor. Doing this on the main one is the
            // difference between a progress bar that animates and an app that
            // looks frozen for half a minute.
            let exporter = DataExporter(modelContainer: container)

            do {
                let finished = try await exporter.export(
                    to: destination,
                    options: options,
                    reminderMinutes: minutes,
                    progress: { update in Task { @MainActor in self.progress = update } }
                )
                await MainActor.run {
                    self.result = finished
                    self.progress = nil
                    self.task = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.progress = nil
                    self.task = nil
                }
            } catch {
                await MainActor.run {
                    self.failure = error.localizedDescription
                    self.progress = nil
                    self.task = nil
                }
            }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    /// `PlantPlant-2026-08-27.json` — dated, because the whole point of keeping
    /// the file is being able to tell two of them apart later.
    private static func filename() -> String {
        "PlantPlant-\(ExportFormat.localDay(.now)).json"
    }
}

#Preview {
    NavigationStack {
        ExportDataView()
    }
    .modelContainer(SampleData.container)
    .preferredColorScheme(.dark)
}
