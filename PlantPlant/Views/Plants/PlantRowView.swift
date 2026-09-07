import SwiftUI

struct PlantRowView: View {
    let plant: Plant

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PlantPhotoView(data: plant.photoData, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(plant.displayName)
                    .font(.headline)
                if let room = plant.room {
                    Text(room.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Up to two upcoming reminders (soonest first), each in its care-type color.
                // Wraps to a new line if needed.
                let reminders = plant.enabledSchedules
                if !reminders.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(reminders.prefix(2))) { schedule in
                            HStack(spacing: 3) {
                                Image(systemName: schedule.type.symbol)
                                Text(schedule.nextDue.relativeDueDescription)
                            }
                            .font(.caption)
                            .foregroundStyle(schedule.type.tint)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        // Extend the row separator across the full width instead of insetting to the text.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}
