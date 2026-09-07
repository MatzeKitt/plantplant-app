import SwiftUI
import SwiftData
import UserNotifications

enum AppTab: Hashable {
    case plants, reminders, search, settings
}

#if DEBUG
extension AppTab {
    /// Resolves the `-startTab` launch argument, so a scripted simulator run can screenshot a tab
    /// other than the first without driving taps into the tab bar.
    init?(debugName: String) {
        switch debugName {
        case "plants": self = .plants
        case "reminders": self = .reminders
        case "search": self = .search
        case "settings": self = .settings
        default: return nil
        }
    }
}
#endif

/// Shared navigation state so non-view code (e.g. notification handling) can drive the UI —
/// tapping a reminder notification selects the Reminders tab.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var selectedTab: AppTab = .plants
}

struct RootTabView: View {
    @Query(filter: #Predicate<Plant> { !$0.isArchived })
    private var plants: [Plant]

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @ObservedObject private var router = AppRouter.shared
    @State private var dayToken = 0

    /// Number of care tasks that are due today or overdue across all active plants.
    /// Skips objects that are being deleted (a `@Query` can briefly surface a just-deleted
    /// plant whose `modelContext` is already nil) so the badge can't lag behind a deletion.
    private var dueCount: Int {
        plants
            .filter { $0.modelContext != nil }
            .reduce(0) { $0 + ($1.schedules ?? []).filter(\.isOverdue).count }
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            Tab("Plants", systemImage: "leaf.fill", value: AppTab.plants) {
                PlantsListView()
            }

            Tab("Reminders", systemImage: "checklist", value: AppTab.reminders) {
                RemindersView()
            }
            .badge(dueCount)

            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }

            // A dedicated search tab (Apple's "search as a tab" pattern): the system places it
            // at the trailing edge and turns the tab bar into a search field when selected.
            Tab(value: AppTab.search, role: .search) {
                PlantSearchView()
            }
        }
        // Re-evaluate the body on day rollover so `dueCount` (which depends on today's date
        // via `isOverdue`) recomputes — otherwise the tab/app-icon badge would keep yesterday's
        // count until the app is next backgrounded and foregrounded.
        .refreshOnDayChange($dayToken)
        // Keep the app-icon badge in sync with due tasks while the app is in the foreground.
        .onChange(of: dueCount, initial: true) { _, newValue in
            UNUserNotificationCenter.current().setBadgeCount(newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                CareService.refreshBadge(context: context)
            }
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let idx = args.firstIndex(of: "-startTab"), idx + 1 < args.count {
                switch args[idx + 1] {
                case "reminders": router.selectedTab = .reminders
                case "settings": router.selectedTab = .settings
                case "search": router.selectedTab = .search
                default: break
                }
            }
        }
        #endif
    }
}

#Preview {
    RootTabView()
        .modelContainer(SampleData.container)
        .preferredColorScheme(.dark)
}
