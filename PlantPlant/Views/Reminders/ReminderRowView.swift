import SwiftUI

struct ReminderRowView: View {
    let plant: Plant
    let schedule: CareSchedule
    let onComplete: () -> Void
    let onSnooze: () -> Void
    /// Tapping the row body: opens the camera for a photo reminder, else the plant detail.
    let onTap: () -> Void

    /// Shows the filled checkmark briefly before the row actually completes and leaves the list.
    @State private var isCompleting = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: markDone) {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(schedule.type.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(schedule.type.label.lowercased()) done for \(plant.name)")

            HStack(spacing: 12) {
                PlantPhotoView(data: plant.photoData, cornerRadius: 8)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(plant.displayName)
                        .font(.headline)
                    HStack(spacing: 6) {
                        // Care type in its own colour, exactly as the plants overview shows it.
                        // Grey here and coloured there meant the same five care types read as two
                        // different vocabularies depending on which tab you were standing in.
                        // Only the care carries the tint; the room stays secondary so the colour
                        // still means "this is the care type" rather than "this whole line".
                        HStack(spacing: 3) {
                            Image(systemName: schedule.type.symbol)
                            Text(schedule.type.label)
                        }
                        .foregroundStyle(schedule.type.tint)
                        // Never compressed: German care labels are long enough that SwiftUI
                        // otherwise hyphenates them mid-word ("Besprü-hen") to make room for the
                        // room name. The care type is what the row is about; the room truncates.
                        .fixedSize()

                        if let room = plant.room {
                            Text("·").foregroundStyle(.tertiary)
                            Text(room.name)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                }

                Spacer()

                Text(schedule.nextDue.relativeDueDescription)
                    .font(.caption)
                    .foregroundStyle(schedule.isOverdue ? schedule.type.tint : .secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
        .padding(.vertical, 4)
        // Swipe right → done; swipe left → reschedule.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: markDone) {
                Label("Mark done", systemImage: "checkmark.circle")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onSnooze) {
                Label("Snooze", systemImage: "clock.badge")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button(action: markDone) {
                Label("Mark done", systemImage: "checkmark.circle")
            }
            Button(action: onSnooze) {
                Label("Snooze…", systemImage: "clock.badge")
            }
        }
    }

    /// Fills the circle with a checkmark, then completes the task a quarter second later so the
    /// user sees it being checked off. Completing pushes the task's next-due date into the future,
    /// so the row doesn't leave the list — it moves to a later section; reset the checkmark
    /// afterwards so it shows as unchecked there (and can be completed again) rather than staying
    /// filled forever.
    private func markDone() {
        guard !isCompleting else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isCompleting = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.25))
            withAnimation { onComplete() }
            isCompleting = false
        }
    }
}
