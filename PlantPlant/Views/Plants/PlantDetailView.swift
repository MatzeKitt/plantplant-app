import SwiftUI
import SwiftData

struct PlantDetailView: View {
    @Bindable var plant: Plant
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showingEdit = false
    @State private var showingJournal = false
    @State private var showingGallery = false
    @State private var showingCamera = false
    @State private var headerImage: UIImage?
    /// Number of photos in the plant's history, refreshed off the render path in `.task` so the
    /// header's stack-icon/tap checks don't decode every journal photo on every body pass.
    @State private var photoCount = 0

    var body: some View {
        // Compute the enabled schedules once; `plant.enabledSchedules` filters and sorts on every
        // access, and the care rows/list/empty-check all need it.
        let schedules = plant.enabledSchedules
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                photoHeader

                header
                careActions(schedules)
                careSchedules(schedules)
                if !plant.notes.isEmpty { notesSection }
                historyLink
            }
            .padding()
        }
        .navigationTitle(plant.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: plant.photoData) {
            photoCount = plant.photoHistory.count
            guard let data = plant.photoData else {
                headerImage = nil
                return
            }
            headerImage = await Task.detached(priority: .userInitiated) {
                PlantImage.thumbnail(from: data, maxPixel: 1600)
            }.value
        }
        .navigationDestination(isPresented: $showingJournal) {
            JournalView(plant: plant)
        }
        .fullScreenCover(isPresented: $showingGallery) {
            PhotoGalleryView(photos: plant.photoHistory)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in CareService.setPhoto(data, for: plant, context: context) }
                .ignoresSafeArea()
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-openHistory") { showingJournal = true }
            if args.contains("-openEdit") { showingEdit = true }
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingEdit = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            // Archive/restore and delete live at the bottom of the edit screen; when the plant
            // is removed from here, pop back out of the (now-stale) detail view too.
            PlantEditView(plant: plant, onRemoved: { dismiss() })
        }
    }

    // Shows the photo at its real aspect ratio (fit to width, no cropping);
    // falls back to a fixed-height placeholder when there is no photo. The image is
    // downsampled off the main thread so opening a plant stays instant. Tapping opens the
    // swipeable photo gallery; a stack icon (bottom-left) hints when older photos exist.
    @ViewBuilder
    private var photoHeader: some View {
        Group {
            if let image = headerImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                PlantPhotoView(data: nil, cornerRadius: 20)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if photoCount > 1 {
                Image(systemName: "photo.stack")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Take a new photo directly; it also counts toward the "Photo" reminder.
            Button {
                showingCamera = true
            } label: {
                Image(systemName: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(11)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(12)
            }
            .accessibilityLabel("Take Photo")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if photoCount > 0 { showingGallery = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !plant.scientificName.isEmpty {
                Text(plant.scientificName)
                    .font(.title3).italic()
                    .foregroundStyle(.secondary)
            }

            // Sunlight and "water when" as filled icons (matching the editor), each on its own
            // line: suns for light level, drops for how dry the soil should get.
            LevelIndicator(level: (SunlightLevel.allCases.firstIndex(of: plant.sunlight) ?? 0) + 1,
                           total: SunlightLevel.allCases.count,
                           filledSymbol: "sun.max.fill",
                           outlineSymbol: "sun.max",
                           tint: .yellow)
                .font(.subheadline)
                .accessibilityLabel(plant.sunlight.label)

            LevelIndicator(level: (SoilDryness.allCases.firstIndex(of: plant.soilDryness) ?? 0) + 1,
                           total: SoilDryness.allCases.count,
                           filledSymbol: "drop.fill",
                           outlineSymbol: "drop",
                           tint: CareType.water.tint)
                .font(.subheadline)
                .accessibilityLabel(plant.soilDryness.label)

            if let room = plant.room {
                Label(room.name, systemImage: "door.left.hand.open")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Label("Acquired \(plant.acquiredDate.formatted(date: .abbreviated, time: .omitted))",
                  systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // Liquid Glass cluster of quick "complete care" buttons. Laid out in balanced rows (e.g.
    // 5 buttons → 3 then 2) so every label fits on one line and no row is left with a lone item.
    private func careActions(_ schedules: [CareSchedule]) -> some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                ForEach(Array(careActionRows(schedules).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        ForEach(row) { schedule in
                            careButton(schedule)
                        }
                    }
                }
            }
        }
    }

    /// Splits the enabled schedules into rows of at most three, distributed as evenly as
    /// possible so the last row never holds a single orphan button. The photo schedule is
    /// excluded — a photo is "completed" by actually taking one (camera button / edit), not by
    /// a separate mark-done button.
    private func careActionRows(_ schedules: [CareSchedule]) -> [[CareSchedule]] {
        let items = schedules.filter { $0.type != .photo }
        guard !items.isEmpty else { return [] }
        let maxPerRow = 3
        let rowCount = Int((Double(items.count) / Double(maxPerRow)).rounded(.up))
        let base = items.count / rowCount
        let remainder = items.count % rowCount

        var rows: [[CareSchedule]] = []
        var index = 0
        for row in 0..<rowCount {
            let size = base + (row < remainder ? 1 : 0)
            rows.append(Array(items[index..<index + size]))
            index += size
        }
        return rows
    }

    private func careButton(_ schedule: CareSchedule) -> some View {
        Button {
            CareService.complete(schedule, context: context)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: schedule.type.symbol)
                    .font(.title3)
                Text(schedule.type.completionLog.label)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(schedule.type.tint)
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }

    private func careSchedules(_ schedules: [CareSchedule]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Care schedule").font(.headline)
            ForEach(schedules) { schedule in
                HStack {
                    Label(schedule.type.label, systemImage: schedule.type.symbol)
                        .foregroundStyle(schedule.type.tint)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(schedule.nextDue.relativeDueDescription)
                            .foregroundStyle(schedule.isOverdue ? schedule.type.tint : .primary)
                        // For watering this reflects the interval in effect this month, which a
                        // season may override.
                        Text("every \(schedule.effectiveInterval(on: .now)) days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if schedules.isEmpty {
                Text("No active care reminders. Tap Edit to add some.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historyLink: some View {
        Button {
            showingJournal = true
        } label: {
            HStack {
                Label("Journal", systemImage: "book.closed")
                Spacer()
                Text("\(plant.sortedLogs.count)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle()) // make the whole row (incl. the spacer) tappable
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline)
            Text(plant.notes)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        PlantDetailView(plant: SampleData.container.mainContext.previewFirstPlant())
    }
    .modelContainer(SampleData.container)
    .preferredColorScheme(.dark)
}
