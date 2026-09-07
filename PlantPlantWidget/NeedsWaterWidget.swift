import WidgetKit
import SwiftUI
import SwiftData

struct NeedsWaterEntry: TimelineEntry {
    let date: Date
    let dueCount: Int
    let plantNames: [String]
}

struct NeedsWaterProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsWaterEntry {
        NeedsWaterEntry(date: .now, dueCount: 3, plantNames: ["Monstera", "Basil", "Fern"])
    }

    func getSnapshot(in context: Context, completion: @escaping (NeedsWaterEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsWaterEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh at the start of tomorrow so counts roll over daily; app writes also reload.
        let tomorrow = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
        completion(Timeline(entries: [entry], policy: .after(tomorrow)))
    }

    private func loadEntry() -> NeedsWaterEntry {
        let context = ModelContext(SharedModelContainer.makeContainer())
        let descriptor = FetchDescriptor<Plant>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.nextWaterDue)]
        )
        let plants = ((try? context.fetch(descriptor)) ?? []).filter { plant in
            guard let due = plant.nextWaterDue else { return false }
            return due.isDueByToday
        }
        return NeedsWaterEntry(
            date: .now,
            dueCount: plants.count,
            plantNames: plants.prefix(4).map(\.displayName)
        )
    }
}

struct NeedsWaterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NeedsWaterEntry

    var body: some View {
        if entry.dueCount == 0 {
            allCaughtUp
        } else {
            switch family {
            case .systemSmall: smallView
            default: mediumView
            }
        }
    }

    private var allCaughtUp: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
            Text("All watered")
                .font(.headline)
            Text("Nothing due today")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "drop.fill")
                .foregroundStyle(CareType.water.tint)
            Text("\(entry.dueCount) need\(entry.dueCount == 1 ? "s" : "") water")
                .font(.headline)
                .minimumScaleFactor(0.8)
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "drop.fill")
                .font(.title)
                .foregroundStyle(CareType.water.tint)
            Text("\(entry.dueCount)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("need water")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // Index-keyed: plant names aren't unique (duplicates or repeated "Untitled" would
            // collide as `id: \.self`).
            ForEach(Array(entry.plantNames.enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "leaf.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if entry.dueCount > entry.plantNames.count {
                Text("+\(entry.dueCount - entry.plantNames.count) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NeedsWaterWidget: Widget {
    let kind = "NeedsWaterWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NeedsWaterProvider()) { entry in
            NeedsWaterWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Needs Water")
        .description("See which plants need watering today.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemMedium) {
    NeedsWaterWidget()
} timeline: {
    NeedsWaterEntry(date: .now, dueCount: 3, plantNames: ["Monstera", "Basil", "Fiddle Leaf Fig"])
    NeedsWaterEntry(date: .now, dueCount: 0, plantNames: [])
}
