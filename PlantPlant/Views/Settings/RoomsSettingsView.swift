import SwiftUI
import SwiftData

struct RoomsSettingsView: View {
    @Query(sort: \Room.name) private var rooms: [Room]
    @Environment(\.modelContext) private var context

    @State private var showingAdd = false
    @State private var newRoomName = ""
    @State private var editingRoom: Room?
    @State private var deleteError: String?

    var body: some View {
        List {
            ForEach(rooms) { room in
                Button {
                    editingRoom = room
                } label: {
                    HStack {
                        Text(room.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(room.activePlants.count) plants")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Rooms")
        .overlay {
            if rooms.isEmpty {
                ContentUnavailableView(
                    "No Rooms",
                    systemImage: "door.left.hand.closed",
                    description: Text("Add rooms to organize your plants.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Room", systemImage: "plus")
                }
            }
        }
        .alert("New Room", isPresented: $showingAdd) {
            TextField("Room name", text: $newRoomName)
            Button("Add") { add() }
            Button("Cancel", role: .cancel) { newRoomName = "" }
        }
        .sheet(item: $editingRoom) { room in
            RoomEditView(room: room)
        }
        .alert("Can't Delete Room", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func add() {
        let trimmed = newRoomName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        context.insert(Room(name: trimmed, sortIndex: rooms.count))
        newRoomName = ""
        CareService.save(context)
    }

    private func delete(_ offsets: IndexSet) {
        // Validate every target before deleting any, so a non-empty room in the selection can't
        // leave earlier rooms deleted-but-unsaved (they'd vanish from the list yet reappear on
        // relaunch).
        let targets = offsets.map { rooms[$0] }
        if let occupied = targets.first(where: { !$0.activePlants.isEmpty }) {
            deleteError = String(localized: "\"\(occupied.name)\" still has plants. Move them to another room first.")
            return
        }
        targets.forEach(context.delete)
        CareService.save(context)
    }
}

#Preview {
    NavigationStack { RoomsSettingsView() }
        .modelContainer(SampleData.container)
        .preferredColorScheme(.dark)
}
