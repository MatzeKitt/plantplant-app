import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The one screen that brings a library back into this app.
///
/// Deliberately the same shape as `ExportDataView`, and with the same
/// unhurriedness: pick the file, read what is actually in it, choose what should
/// happen to what is already here, and only then run. The extra step is the
/// point — the choice between merging and replacing is the only irreversible
/// decision in the app, and it is much easier to make with the file's real
/// numbers on screen than from memory.
struct ImportDataView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(NotificationManager.reminderMinutesKey)
    private var reminderMinutes = NotificationManager.defaultReminderMinutes

    @State private var isPicking = false
    @State private var source: URL?
    @State private var preview: ImportPreview?
    @State private var mode: ImportMode = .merge
    @State private var progress: ImportProgress?
    @State private var report: ImportReport?
    @State private var failure: String?
    @State private var confirmingReplace = false
    @State private var task: Task<Void, Never>?

    private var isRunning: Bool { task != nil }

    var body: some View {
        Form {
            if report == nil {
                Section {
                    Button("Choose File…") { isPicking = true }
                        .disabled(isRunning)
                } footer: {
                    Text("Pick a PlantPlant export — the file the Export screen produces, on this device or another one.")
                }
            }

            if let preview, report == nil {
                fileSection(preview)
                modeSection(preview)

                if !preview.warnings.isEmpty {
                    Section("Before you start") {
                        ForEach(preview.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                        }
                    }
                }
            }

            if let progress, isRunning {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress.fraction)
                        Text(label(for: progress))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let report {
                summarySection(report)
            }

            if let failure {
                Section {
                    Text(failure).foregroundStyle(.red)
                }
            }

            if preview != nil, report == nil, !isRunning {
                Section {
                    Button(mode == .replace ? "Replace Everything" : "Import", role: mode == .replace ? .destructive : nil) {
                        if mode == .replace {
                            confirmingReplace = true
                        } else {
                            start()
                        }
                    }
                }
            }
        }
        .navigationTitle("Import Data")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isRunning)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.json, .data]) { result in
            load(result)
        }
        // The only typed-out consequence in the app, because it is the only
        // action that destroys data the user cannot get back by repeating
        // themselves. The count is in the button so "everything" has a number.
        .confirmationDialog("Delete everything on this device?",
                            isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Delete \(preview?.plantsOnDevice ?? 0) plants and import", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every plant, room and journal entry here is deleted first. This can't be undone.")
        }
        .onDisappear { cleanUp() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func fileSection(_ preview: ImportPreview) -> some View {
        Section {
            LabeledContent("Plants", value: "\(preview.plants)")
            LabeledContent("Rooms", value: "\(preview.rooms)")
            LabeledContent("Reminders", value: "\(preview.schedules)")
            LabeledContent("Journal entries", value: "\(preview.logs)")
            LabeledContent("Photos", value: "\(preview.photos)")
        } header: {
            Text("In this file")
        } footer: {
            if let exported = preview.exportedAt {
                Text("Exported \(exported.formatted(date: .abbreviated, time: .shortened)) by \(preview.generator).")
            } else {
                Text(preview.generator)
            }
        }
    }

    @ViewBuilder
    private func modeSection(_ preview: ImportPreview) -> some View {
        Section {
            Picker("Mode", selection: $mode) {
                ForEach(ImportMode.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if mode == .merge, preview.plantsAlreadyHere > 0 {
                LabeledContent("Already here", value: "\(preview.plantsAlreadyHere) plants")
            }
            if mode == .replace {
                LabeledContent("Will be deleted", value: "\(preview.plantsOnDevice) plants")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("What happens to what's here")
        } footer: {
            Text(mode.explanation)
        }
    }

    @ViewBuilder
    private func summarySection(_ report: ImportReport) -> some View {
        Section {
            LabeledContent("Plants added", value: "\(report.plantsCreated)")
            LabeledContent("Plants updated", value: "\(report.plantsUpdated)")
            if report.plantsDeleted > 0 {
                LabeledContent("Plants deleted", value: "\(report.plantsDeleted)")
            }
            LabeledContent("Journal entries added", value: "\(report.logsCreated)")
            if report.logsSkipped > 0 {
                LabeledContent("Already in the journal", value: "\(report.logsSkipped)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Photos", value: "\(report.photosLinked)")
            if report.photosSkipped > 0 {
                LabeledContent("Photos skipped", value: "\(report.photosSkipped)")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Imported")
        } footer: {
            // Named rather than hidden, because it looks like a bug otherwise:
            // a snoozed task's next date genuinely is not its interval, and
            // "correcting" it on import is what would actually be wrong.
            if report.divergentSchedules > 0 {
                Text("\(report.divergentSchedules) reminders have a due date that doesn't match their interval — that's normal for snoozed tasks, and they were kept exactly as exported.")
            } else {
                Text("Reminders were rebuilt from the imported dates.")
            }
        }

        if !report.warnings.isEmpty {
            Section("Warnings") {
                ForEach(report.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func label(for progress: ImportProgress) -> String {
        switch progress.phase {
        case .reading: return String(localized: "Reading the file…")
        case .plants: return String(localized: "Importing plant \(progress.done) of \(progress.total)")
        case .photos: return String(localized: "Importing photo \(progress.done) of \(progress.total)")
        case .finishing: return String(localized: "Finishing…")
        }
    }

    // MARK: - Actions

    /// Copies the picked file somewhere this app owns, then previews it.
    ///
    /// The copy is not paranoia. A file picked out of Files or iCloud Drive is
    /// reachable only while its security scope is held, and the import runs on
    /// another actor for as long as the photos take — quite long enough for the
    /// document to be relinquished underneath it, which surfaces as half an
    /// import and no explanation.
    private func load(_ result: Result<URL, Error>) {
        cleanUp()
        failure = nil
        preview = nil
        report = nil

        do {
            let picked = try result.get()
            let scoped = picked.startAccessingSecurityScopedResource()

            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("plantplant-import-\(UUID().uuidString).json")

            try FileManager.default.copyItem(at: picked, to: copy)
            source = copy

            let importer = DataImporter(modelContainer: context.container)

            Task {
                do {
                    let read = try await importer.preview(of: copy)
                    await MainActor.run { self.preview = read }
                } catch {
                    await MainActor.run {
                        self.failure = error.localizedDescription
                        self.cleanUp()
                    }
                }
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func start() {
        guard let source else { return }

        failure = nil
        progress = ImportProgress(phase: .reading, done: 0, total: 0)

        let container = context.container
        let mode = mode
        let minutes = preview?.reminderMinutes

        task = Task {
            let importer = DataImporter(modelContainer: container)

            do {
                let finished = try await importer.run(
                    source,
                    mode: mode,
                    progress: { update in Task { @MainActor in self.progress = update } }
                )

                await MainActor.run {
                    // Only when replacing. Merge is a top-up and has no business
                    // moving a setting the user may have changed on this device
                    // since; replace is "make this device match the file", and a
                    // reminder time is part of what the file says.
                    if mode == .replace, let minutes {
                        self.reminderMinutes = minutes
                    }

                    self.report = finished
                    self.preview = nil
                    self.progress = nil
                    self.task = nil

                    // Everything the import touched feeds these: due dates moved,
                    // plants appeared or vanished, so every pending notification
                    // and the badge are stale until rebuilt.
                    CareService.reloadWidget()
                    NotificationManager.shared.refreshAll(context: context)
                    cleanUp()
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

    private func cleanUp() {
        if let source {
            try? FileManager.default.removeItem(at: source)
        }

        source = nil
    }
}

#Preview {
    NavigationStack {
        ImportDataView()
    }
    .modelContainer(SampleData.container)
    .preferredColorScheme(.dark)
}
