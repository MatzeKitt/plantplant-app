import SwiftUI
import SwiftData

/// Per-plant journal (activity log plus free-text entries), grouped by day.
/// Pushed from `PlantDetailView`.
struct JournalView: View {
    let plant: Plant
    @Environment(\.modelContext) private var context

    @State private var showingAddEntry = false
    @State private var entryText = ""
    @State private var preview: PhotoPreview?

    /// Identifiable wrapper so a tapped photo can drive a `fullScreenCover(item:)`.
    private struct PhotoPreview: Identifiable {
        let id = UUID()
        let data: Data
    }

    /// This plant's logs grouped by calendar day, newest day first.
    private var sections: [(day: Date, logs: [CareLog])] {
        let groups = Dictionary(grouping: plant.sortedLogs) { $0.date.startOfDay }
        return groups
            .map { (day: $0.key, logs: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        // Group/sort the logs once per render, rather than sorting again for the empty check.
        let sections = self.sections
        return Group {
            if sections.isEmpty {
                ContentUnavailableView(
                    "No Journal Entries Yet",
                    systemImage: "book.closed",
                    description: Text("Watering, care, edits and your own notes for \(plant.name) will show up here.")
                )
            } else {
                List {
                    ForEach(sections, id: \.day) { section in
                        Section(sectionTitle(section.day)) {
                            ForEach(section.logs) { log in
                                JournalRowView(log: log) { data in
                                    preview = PhotoPreview(data: data)
                                }
                            }
                            .onDelete { offsets in
                                delete(section.logs, at: offsets)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddEntry = true
                } label: {
                    Label("Add Entry", systemImage: "square.and.pencil")
                }
            }
        }
        .alert("New Journal Entry", isPresented: $showingAddEntry) {
            TextField("Note", text: $entryText)
            Button("Add") { addEntry() }
            Button("Cancel", role: .cancel) { entryText = "" }
        }
        .fullScreenCover(item: $preview) { preview in
            PhotoGalleryView(photos: [preview.data])
        }
    }

    /// Deletes the given journal entries; any photo they carry is removed with them. If a
    /// deleted entry holds the plant's *current* photo, that photo is cleared from the plant too.
    private func delete(_ logs: [CareLog], at offsets: IndexSet) {
        for index in offsets {
            let log = logs[index]
            if let data = log.photoData, data == plant.photoData {
                plant.photoData = nil
            }
            log.photoData = nil
            context.delete(log)
        }
        CareService.save(context)
    }

    private func addEntry() {
        let trimmed = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        entryText = ""
        guard !trimmed.isEmpty else { return }
        CareService.addLog(.note, to: plant, note: trimmed, context: context)
        CareService.save(context)
    }

    private func sectionTitle(_ day: Date) -> String {
        switch day.daysFromToday {
        case 0: return String(localized: "Today")
        case -1: return String(localized: "Yesterday")
        default: return day.formatted(date: .complete, time: .omitted)
        }
    }
}

struct JournalRowView: View {
    let log: CareLog
    /// Called when the entry's photo is tapped, to open it full-screen.
    var onTapPhoto: ((Data) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: log.type.symbol)
                .frame(width: 24)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(log.type.label)
                        .font(.headline)
                    Spacer()
                    Text(log.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !log.note.isEmpty {
                    Text(log.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Sunlight / "water when" changes are shown as icons rather than text.
                if let to = log.sunlightTo {
                    levelChange(from: log.sunlightFrom, to: to,
                                total: SunlightLevel.allCases.count,
                                filled: "sun.max.fill", outline: "sun.max", tint: .yellow)
                }
                if let to = log.soilTo {
                    levelChange(from: log.soilFrom, to: to,
                                total: SoilDryness.allCases.count,
                                filled: "drop.fill", outline: "drop", tint: CareType.water.tint)
                }
                if let photo = log.photoData {
                    PlantPhotoView(data: photo, cornerRadius: 8)
                        .frame(width: 72, height: 72)
                        .padding(.top, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapPhoto?(photo) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// A "before → after" level change rendered purely as icons (e.g. suns or drops).
    @ViewBuilder
    private func levelChange(from: Int?, to: Int, total: Int,
                             filled: String, outline: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            if let from {
                LevelIndicator(level: from, total: total, filledSymbol: filled, outlineSymbol: outline, tint: tint)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LevelIndicator(level: to, total: total, filledSymbol: filled, outlineSymbol: outline, tint: tint)
        }
        .font(.subheadline)
        .padding(.top, 2)
    }

    /// Care completions use their care-type color; everything else stays neutral.
    private var tint: Color {
        switch log.type {
        case .watered: return CareType.water.tint
        case .fertilized: return CareType.fertilize.tint
        case .misted: return CareType.mist.tint
        case .repotted: return CareType.repot.tint
        case .photoChanged: return CareType.photo.tint
        default: return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        JournalView(plant: SampleData.container.mainContext.previewFirstPlant())
    }
    .modelContainer(SampleData.container)
    .preferredColorScheme(.dark)
}
