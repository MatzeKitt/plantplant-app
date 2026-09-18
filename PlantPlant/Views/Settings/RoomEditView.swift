import SwiftUI
import SwiftData

struct RoomEditView: View {
    @Bindable var room: Room
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Room name", text: $room.name)
                }
                if !room.activePlants.isEmpty {
                    Section("Plants") {
                        ForEach(room.activePlants) { plant in
                            Text(plant.name)
                        }
                    }
                }
            }
            .navigationTitle("Edit Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        CareService.save(context)
                        dismiss()
                    }
                    .disabled(room.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
