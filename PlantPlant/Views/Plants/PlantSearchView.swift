import SwiftUI
import SwiftData

/// The search tab's content. Selecting the search tab turns the tab bar into a search field
/// (see `RootTabView`); results are filtered live by name and scientific name and open the
/// same detail view as the Plants tab.
struct PlantSearchView: View {
    @Query(filter: #Predicate<Plant> { !$0.isArchived })
    private var plants: [Plant]

    /// The active Plants-tab sort, so search results match the main list's ordering.
    @AppStorage("plantSort") private var sort: PlantSort = .deadline

    /// `searchText` is bound to the field (updates instantly); `query` is the debounced value
    /// that actually drives filtering, so a burst of keystrokes only triggers one filter+sort.
    @State private var searchText = ""
    @State private var query = ""
    @State private var path: [Plant] = []

    /// All plants until a query is entered, then those matching it — always in the active sort.
    private func makeResults() -> [Plant] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matched = trimmed.isEmpty
            ? plants
            : plants.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.scientificName.localizedCaseInsensitiveContains(trimmed)
            }
        return sort.sorted(matched)
    }

    var body: some View {
        // Compute once per render rather than re-filtering/-sorting for each branch below.
        let results = makeResults()
        let hasQuery = !query.trimmingCharacters(in: .whitespaces).isEmpty

        NavigationStack(path: $path) {
            Group {
                if results.isEmpty {
                    if hasQuery {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ContentUnavailableView {
                            Label("No Plants Yet", systemImage: "leaf")
                        } description: {
                            Text("Add your first plant to start tracking watering and care.")
                        }
                    }
                } else {
                    List {
                        ForEach(results) { plant in
                            NavigationLink(value: plant) {
                                PlantRowView(plant: plant)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: Plant.self) { PlantDetailView(plant: $0) }
            .searchable(text: $searchText, prompt: "Search plants")
            // Debounce: `.task(id:)` cancels the prior task on each keystroke, so `query` only
            // catches up once typing pauses — keeping the field responsive while typing fast.
            .task(id: searchText) {
                if (try? await Task.sleep(for: .milliseconds(200))) != nil {
                    query = searchText
                }
            }
        }
    }
}

#Preview {
    PlantSearchView()
        .modelContainer(SampleData.container)
        .preferredColorScheme(.dark)
}
