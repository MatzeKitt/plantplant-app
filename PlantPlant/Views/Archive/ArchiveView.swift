import SwiftUI
import SwiftData

struct ArchiveView: View {
    @Query(filter: #Predicate<Plant> { $0.isArchived }, sort: \Plant.name)
    private var plants: [Plant]

    @Environment(\.modelContext) private var context
    @State private var pendingDelete: Plant?

    var body: some View {
        List {
            ForEach(plants) { plant in
                NavigationLink {
                    PlantDetailView(plant: plant)
                } label: {
                    HStack(spacing: 12) {
                        PlantPhotoView(data: plant.photoData, cornerRadius: 8)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(plant.displayName)
                            if !plant.scientificName.isEmpty {
                                Text(plant.scientificName)
                                    .font(.caption).italic()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        CareService.setArchived(plant, false, context: context)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = plant
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Archive")
        .overlay {
            if plants.isEmpty {
                ContentUnavailableView(
                    "No Archived Plants",
                    systemImage: "archivebox",
                    description: Text("Plants you archive appear here. Swipe to restore or delete.")
                )
            }
        }
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let plant = pendingDelete {
                    CareService.delete(plant, context: context)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }
}

#Preview {
    NavigationStack { ArchiveView() }
        .modelContainer(SampleData.container)
        .preferredColorScheme(.dark)
}
