import SwiftUI
import SwiftData
import UIKit

/// App delegate used solely to gate the allowed interface orientations at the window level.
/// The app supports all orientations, but while the camera is open we pin it to portrait
/// (otherwise `UIImagePickerController`'s shutter can be hidden in landscape).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

@main
struct PlantPlantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container = SharedModelContainer.shared

    init() {
        NotificationManager.shared.configure()
    }

    /// DEBUG: `-showScreen ExportData` / `-showScreen ImportData` opens one
    /// screen directly, so a scripted simulator run can screenshot it without
    /// driving taps through three levels of navigation.
    private var screenOverride: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments

        if let index = args.firstIndex(of: "-showScreen"), index + 1 < args.count {
            return args[index + 1]
        }
        #endif

        return nil
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if screenOverride == "ExportData" {
                    NavigationStack { ExportDataView() }
                } else if screenOverride == "ImportData" {
                    NavigationStack { ImportDataView() }
                } else {
                    RootTabView()
                }
                #else
                RootTabView()
                #endif
            }
                .preferredColorScheme(.dark) // Dark for now; remove to support light mode.
                .task {
                    var seeding = false
                    #if DEBUG
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("-seedSampleData") {
                        SampleData.seedIfEmpty(container.mainContext)
                        seeding = true
                    }
                    if let index = args.firstIndex(of: "-startTab"), index + 1 < args.count,
                       let tab = AppTab(debugName: args[index + 1]) {
                        AppRouter.shared.selectedTab = tab
                    }
                    if args.contains("-seedSamplePhotos") {
                        ExportTestHarness.seedPhotos(container.mainContext)
                        seeding = true
                    }
                    if let index = args.firstIndex(of: "-exportSampleData"), index + 1 < args.count {
                        // Runs the real exporter and exits. Everything below —
                        // notification authorization, scheduling — would only get
                        // in the way of a scripted run.
                        let minutes = UserDefaults.standard.object(forKey: NotificationManager.reminderMinutesKey)
                            as? Int ?? NotificationManager.defaultReminderMinutes
                        await ExportTestHarness.runHeadlessExport(
                            to: args[index + 1],
                            container: container,
                            reminderMinutes: minutes
                        )
                    }
                    if args.contains("-fireTestNotification") {
                        _ = await NotificationManager.shared.requestAuthorization()
                        NotificationManager.shared.scheduleTestNotification()
                    }
                    #endif
                    // Resolve authorization *before* scheduling so reminders are added only
                    // once permission is granted.
                    if !seeding {
                        _ = await NotificationManager.shared.requestAuthorization()
                    }
                    NotificationManager.shared.refreshAll(context: container.mainContext)
                    #if DEBUG
                    if args.contains("-dumpNotifications") {
                        await NotificationManager.shared.dumpPending()
                    }
                    #endif
                }
        }
        .modelContainer(container)
    }
}
