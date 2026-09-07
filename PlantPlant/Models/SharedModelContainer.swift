import Foundation
import SwiftData

/// Central place for the App Group identifier and the shared SwiftData container.
/// Both the app and the widget extension open the *same* on-disk store via the App Group
/// so the widget always reflects the latest data.
enum AppGroup {
    static let identifier = "group.com.kittmedia.plantplant"
}

enum SharedModelContainer {
    static let schema = Schema([
        Plant.self,
        Room.self,
        CareSchedule.self,
        CareLog.self,
        WateringSeason.self,
    ])

    /// The one production container for the whole app. Everything — the UI and the
    /// notification-action handler — must go through this single instance; a second container
    /// over the same store would not see the first's in-memory changes, so completing a task
    /// from a notification would look stale in the UI until relaunch.
    static let shared = makeContainer()

    /// The production container, backed by a store inside the shared App Group container.
    /// Falls back to a local store if the App Group is unavailable (e.g. missing entitlement
    /// during early development), so the app still runs.
    static func makeContainer() -> ModelContainer {
        let config: ModelConfiguration
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
            let storeURL = groupURL.appendingPathComponent("PlantPlant.store")
            config = ModelConfiguration(schema: schema, url: storeURL)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
}
