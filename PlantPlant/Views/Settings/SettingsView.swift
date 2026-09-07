import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Query(filter: #Predicate<Plant> { $0.isArchived })
    private var archivedPlants: [Plant]

    @Query private var rooms: [Room]

    @Environment(\.modelContext) private var context
    @AppStorage(NotificationManager.reminderMinutesKey) private var reminderMinutes = NotificationManager.defaultReminderMinutes
    @AppStorage(NotificationManager.secondReminderEnabledKey) private var secondReminderEnabled = false
    @AppStorage(NotificationManager.secondReminderMinutesKey)
    private var secondReminderMinutes = NotificationManager.defaultSecondReminderMinutes
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    /// Bridges a stored minutes-since-midnight value to a `Date` for a time picker.
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60,
                                  minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
        } set: { newValue in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            minutes.wrappedValue = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        RoomsSettingsView()
                    } label: {
                        Label("Rooms", systemImage: "door.left.hand.open")
                            .badge(rooms.count)
                    }
                    NavigationLink {
                        ArchiveView()
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                            .badge(archivedPlants.count)
                    }
                }

                Section {
                    LabeledContent("Reminders") {
                        Text(notificationStatusText)
                            .foregroundStyle(.secondary)
                    }
                    DatePicker("Reminder time", selection: timeBinding($reminderMinutes),
                               displayedComponents: .hourAndMinute)
                    Toggle("Second reminder", isOn: $secondReminderEnabled)
                    if secondReminderEnabled {
                        DatePicker("Second time", selection: timeBinding($secondReminderMinutes),
                                   displayedComponents: .hourAndMinute)
                    }
                    if notificationStatus == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } else if notificationStatus == .notDetermined {
                        Button("Enable Reminders") {
                            Task {
                                _ = await NotificationManager.shared.requestAuthorization()
                                NotificationManager.shared.refreshAll(context: context)
                                await refreshStatus()
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("A second reminder repeats the same day's tasks at another time, for the days you are not looking at your phone at the first one.")
                }

                Section {
                    NavigationLink {
                        ExportDataView()
                    } label: {
                        Label("Export Data", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Save everything to one file — to move to PlantPlant on the web, or just to keep a copy.")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("PlantPlant keeps your house plants happy with watering and care reminders.")
                }
            }
            .navigationTitle("Settings")
            .task { await refreshStatus() }
            // Every one of these changes which moments the pending notifications occupy, and
            // there is no cheaper way to move them than rebuilding — `refreshAll` clears and
            // re-adds the lot, so it is also what removes the second reminder's requests when
            // the toggle goes off.
            .onChange(of: reminderMinutes) { rescheduleReminders() }
            .onChange(of: secondReminderEnabled) { rescheduleReminders() }
            .onChange(of: secondReminderMinutes) { rescheduleReminders() }
        }
    }

    private func rescheduleReminders() {
        NotificationManager.shared.refreshAll(context: context)
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return String(localized: "On")
        case .denied: return String(localized: "Off")
        case .notDetermined: return String(localized: "Not set")
        @unknown default: return String(localized: "Unknown")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return version
    }

    private func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }
}

#Preview {
    SettingsView()
        .modelContainer(SampleData.container)
        .preferredColorScheme(.dark)
}
