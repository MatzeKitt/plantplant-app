import Foundation
import SwiftData
import UserNotifications
import WidgetKit

/// Schedules and handles local notifications for care reminders.
///
/// Notifications fire at the configured reminder time — or at both of them, when a second one is
/// switched on — on a schedule's `nextDue` day, with all tasks that fall on the same day merged
/// into a single notification. A single-task reminder offers "mark done" / "snooze" actions;
/// tapping any reminder opens the Reminders tab.
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    static let categoryID = "CARE_REMINDER"
    static let markDoneAction = "MARK_DONE"
    static let snoozeAction = "SNOOZE"

    /// UserDefaults key holding the reminder time as minutes since midnight.
    static let reminderMinutesKey = "reminderMinutes"
    /// Default reminder time: 16:00.
    static let defaultReminderMinutes = 16 * 60

    /// UserDefaults key for whether a second daily reminder is switched on.
    static let secondReminderEnabledKey = "secondReminderEnabled"
    /// UserDefaults key holding the second reminder time as minutes since midnight.
    static let secondReminderMinutesKey = "secondReminderMinutes"
    /// Default second reminder time: 09:00 — a morning nudge before the afternoon one, which is
    /// the point of having two.
    static let defaultSecondReminderMinutes = 9 * 60

    /// iOS keeps at most 64 pending notification requests per app and silently drops whatever
    /// does not fit, with no promise about which. Everything scheduled by `refreshAll` shares
    /// that budget, so it is divided deliberately rather than left to whichever loop runs last —
    /// which is what a second reminder time would otherwise have quietly broken, since it doubles
    /// the number of reminder requests a library produces.
    static let pendingLimit = 64

    /// Reminders get first claim on the budget. A dropped alert is a plant that does not get
    /// watered; a dropped midnight badge rollover corrects itself the next time the app is
    /// opened. What gets dropped is the furthest-out reminders, and `refreshAll` runs on every
    /// launch and every care mutation, so the horizon rolls forward long before they come due.
    static let reminderLimit = 40

    /// The configured reminder times, as minutes since local midnight, in the order they are
    /// configured in.
    ///
    /// Deduplicated: both pickers can be set to the same clock time, and two identical
    /// notifications at one instant is not a feature. Clamped, because a value read back from
    /// storage is not guaranteed to be one this app wrote. Pure and static so both rules are
    /// testable without going through UserDefaults.
    static func reminderMinutes(first: Int, second: Int?) -> [Int] {
        func clamp(_ minutes: Int) -> Int { max(0, min(1439, minutes)) }

        let head = clamp(first)
        guard let second, clamp(second) != head else { return [head] }

        return [head, clamp(second)]
    }

    /// Configured times of day (local) at which reminders fire: one, or two when the second
    /// reminder is switched on.
    private var reminderTimes: [(hour: Int, minute: Int)] {
        let defaults = UserDefaults.standard
        let first = defaults.object(forKey: Self.reminderMinutesKey) as? Int ?? Self.defaultReminderMinutes
        let second = defaults.bool(forKey: Self.secondReminderEnabledKey)
            ? (defaults.object(forKey: Self.secondReminderMinutesKey) as? Int ?? Self.defaultSecondReminderMinutes)
            : nil

        return Self.reminderMinutes(first: first, second: second).map { ($0 / 60, $0 % 60) }
    }

    /// The notification-request identifier for a plan belonging to reminder slot `slot`.
    ///
    /// Two slots routinely produce a plan for the *same* day — that is precisely what a second
    /// reminder time is — and `UNUserNotificationCenter.add` treats a repeated identifier as a
    /// replacement, so without a per-slot namespace the second reminder would silently overwrite
    /// the first instead of joining it. Slot 0 keeps the bare `day.` id the app has always used.
    static func requestID(_ planID: String, slot: Int) -> String {
        slot == 0 ? planID : "s\(slot).\(planID)"
    }

    private var center: UNUserNotificationCenter { .current() }

    /// Pending coalesced rebuild, so a burst of care mutations collapses into one refresh.
    private var pendingRefresh: DispatchWorkItem?

    // MARK: Setup

    /// Registers actionable categories and becomes the notification delegate.
    /// Call once at launch.
    func configure() {
        center.delegate = self
        let markDone = UNNotificationAction(
            identifier: Self.markDoneAction,
            title: String(localized: "Mark done"),
            options: []
        )
        // A text-input action so the user can type how many days to snooze.
        let snooze = UNTextInputNotificationAction(
            identifier: Self.snoozeAction,
            title: String(localized: "Snooze…"),
            options: [],
            textInputButtonTitle: String(localized: "Snooze"),
            textInputPlaceholder: String(localized: "Number of days")
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [markDone, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Requests notification authorization and reports whether it was granted. Awaiting this
    /// before (re)scheduling ensures reminders are added *after* permission is resolved,
    /// otherwise the first launch schedules them before the user has said yes.
    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    // MARK: Scheduling

    /// A single reminder task, used when grouping same-day reminders into one notification.
    struct CareTask {
        let plantID: UUID
        let plantName: String
        let type: CareType
        let fireDate: Date
    }

    /// A resolved notification ready to schedule. `single` is non-nil only when the plan
    /// represents exactly one task (so it can carry the mark-done/snooze actions).
    struct NotificationPlan {
        struct Single { let plantID: UUID; let type: CareType }
        let id: String
        let title: String
        let body: String
        let fireDate: Date
        let single: Single?
    }

    /// Groups tasks that fire on the same calendar day into one plan: a lone task becomes an
    /// actionable single reminder ("<Plant>" / "<Care> reminder"); several become a summary
    /// ("N care tasks" / list of plant names). Pure and deterministic so it can be unit-tested.
    static func buildPlans(tasks: [CareTask], calendar: Calendar = .current) -> [NotificationPlan] {
        var byDay: [Date: [CareTask]] = [:]
        for task in tasks {
            byDay[calendar.startOfDay(for: task.fireDate), default: []].append(task)
        }

        var plans: [NotificationPlan] = []
        // Sorted, because `byDay` is a dictionary and the fetch that produced these tasks carries
        // no sort descriptor. Without it the summary body lists plants in whatever order the
        // store happened to return them — "Basil, Monstera" on one rebuild and "Monstera, Basil"
        // on the next, for an unchanged library. Harmless to read, but it makes the notification
        // text untestable and this function's "pure and deterministic" claim untrue.
        for day in byDay.keys.sorted() {
            let group = (byDay[day] ?? []).sorted {
                ($0.plantName, $0.type.rawValue, $0.plantID.uuidString)
                    < ($1.plantName, $1.type.rawValue, $1.plantID.uuidString)
            }
            guard let fire = group.first?.fireDate else { continue }
            let title: String
            let body: String
            var single: NotificationPlan.Single?

            if group.count == 1, let task = group.first {
                title = task.plantName.isEmpty ? String(localized: "Plant care") : task.plantName
                body = String(localized: "\(task.type.label) reminder")
                single = .init(plantID: task.plantID, type: task.type)
            } else {
                let names = group.map(\.plantName).filter { !$0.isEmpty }
                let distinct = (NSOrderedSet(array: names).array as? [String]) ?? names
                title = String(localized: "\(group.count) care tasks")
                body = distinct.isEmpty ? String(localized: "Plant care") : distinct.joined(separator: ", ")
            }

            let comps = calendar.dateComponents([.year, .month, .day], from: fire)
            let id = String(format: "day.%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
            plans.append(NotificationPlan(id: id, title: title, body: body, fireDate: fire, single: single))
        }
        return plans.sorted { $0.fireDate < $1.fireDate }
    }

    /// How many tasks are outstanding (due on or before `day`) given every enabled task's due
    /// day. Used to stamp each scheduled notification with the badge the app icon should show
    /// once that day's reminder fires — so the badge stays correct as days pass even if the app
    /// is never opened. Pure and deterministic so it can be unit-tested.
    static func outstandingCount(dueDays: [Date], asOf day: Date, calendar: Calendar = .current) -> Int {
        let ref = calendar.startOfDay(for: day)
        return dueDays.filter { calendar.startOfDay(for: $0) <= ref }.count
    }

    /// A badge value to apply at the start (midnight) of a specific upcoming day.
    struct BadgeUpdate: Equatable { let day: Date; let badge: Int }

    /// The midnight badge changes to schedule so the app-icon badge rolls over the instant a new
    /// day begins — even while the app is backgrounded or not running. The count only changes when
    /// a task becomes due, i.e. at the start of a distinct future due-day, so we emit one update
    /// per such day paired with the outstanding count from then on. `limit` is whatever the
    /// reminders left of `pendingLimit`; the default suits calling this in isolation.
    /// Pure/deterministic so it can be unit-tested.
    static func badgeUpdates(dueDays: [Date], now: Date = .now,
                             calendar: Calendar = .current, limit: Int = 30) -> [BadgeUpdate] {
        let today = calendar.startOfDay(for: now)
        let futureDays = Set(dueDays.map { calendar.startOfDay(for: $0) })
            .filter { $0 > today }
            .sorted()
            .prefix(limit)
        return futureDays.map { day in
            BadgeUpdate(day: day, badge: outstandingCount(dueDays: dueDays, asOf: day, calendar: calendar))
        }
    }

    /// The next moment a reminder should fire: the due day at the configured reminder time,
    /// rolled forward to the next reminder-time occurrence if that moment has already passed.
    /// Without this, an overdue plant (due date in the past) would schedule a trigger in the
    /// past — which never fires — so the plants that most need a reminder got none.
    static func fireDate(forDueDay dueDay: Date, hour: Int, minute: Int,
                         now: Date = .now, calendar: Calendar = .current) -> Date {
        func atReminderTime(on day: Date) -> Date {
            var c = calendar.dateComponents([.year, .month, .day], from: day)
            c.hour = hour
            c.minute = minute
            return calendar.date(from: c) ?? day
        }
        var fire = atReminderTime(on: dueDay)
        if fire <= now {
            fire = atReminderTime(on: now)
            while fire <= now {
                fire = calendar.date(byAdding: .day, value: 1, to: fire) ?? fire.addingTimeInterval(86_400)
            }
        }
        return fire
    }

    /// Rebuilds every reminder from the current store, grouping all tasks that fire on the
    /// same day into a single notification — so a day with several due plants produces one
    /// alert, not one per plant. Clears pending *and* delivered notifications first so nothing
    /// from archived/deleted/rescheduled plants lingers. Safe to call on launch.
    func refreshAll(context: ModelContext) {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()

        let descriptor = FetchDescriptor<Plant>(predicate: #Predicate { !$0.isArchived })
        let plants = (try? context.fetch(descriptor)) ?? []
        let times = reminderTimes
        let calendar = Calendar.current

        // Every enabled task's due day, for stamping each notification with the badge the icon
        // should show once that day's reminder fires (see `outstandingCount`). A due day is a
        // property of the schedule, not of the time of day it gets announced at, so it is
        // gathered once and shared by every slot.
        var dueDays: [Date] = []
        var requests: [(id: String, plan: NotificationPlan)] = []

        // Once per reminder time. Each pass re-derives its own fire dates rather than shifting
        // the first pass's, because `fireDate` rolls a moment that has already passed forward to
        // the next occurrence — so with 09:00 and 20:00 configured, an overdue plant at 17:00
        // correctly gets tonight's reminder from the second slot and tomorrow morning's from the
        // first, which a naive "same day, different clock time" shift would get wrong.
        for (slot, time) in times.enumerated() {
            var tasks: [CareTask] = []
            for plant in plants { // already filtered to non-archived by the fetch predicate above
                for schedule in plant.schedules ?? [] where schedule.isEnabled {
                    let fire = Self.fireDate(forDueDay: schedule.nextDue, hour: time.hour, minute: time.minute)
                    tasks.append(CareTask(plantID: plant.id, plantName: plant.name, type: schedule.type, fireDate: fire))
                    if slot == 0 { dueDays.append(schedule.nextDue) }
                }
            }
            for plan in Self.buildPlans(tasks: tasks, calendar: calendar) {
                requests.append((Self.requestID(plan.id, slot: slot), plan))
            }
        }

        // Soonest first, then trimmed to the budget, so what survives is the near future rather
        // than whichever slot happened to be enumerated first.
        let scheduled = requests.sorted { $0.plan.fireDate < $1.plan.fireDate }.prefix(Self.reminderLimit)

        for (id, plan) in scheduled {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            // Stamp the badge with the outstanding count as of this reminder's day, so the icon
            // badge updates to the new number when the day's reminder fires — without the app
            // being opened.
            content.badge = NSNumber(value: Self.outstandingCount(dueDays: dueDays, asOf: plan.fireDate, calendar: calendar))
            if let single = plan.single {
                content.categoryIdentifier = Self.categoryID
                content.userInfo = ["plantID": single.plantID.uuidString, "careType": single.type.rawValue]
            }
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: plan.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }

        // Silent, badge-only notifications at the start of each upcoming due-day, so the app-icon
        // badge rolls over to the new count the moment the day changes — even while the app is
        // backgrounded or not running — instead of only when that day's visible reminder fires.
        // iOS applies `content.badge` on delivery; with no title/body/sound nothing is shown.
        // Whatever the reminders left of the 64-request budget.
        for update in Self.badgeUpdates(dueDays: dueDays, calendar: calendar,
                                        limit: max(0, Self.pendingLimit - scheduled.count)) {
            let content = UNMutableNotificationContent()
            content.badge = NSNumber(value: update.badge)
            let comps = calendar.dateComponents([.year, .month, .day], from: update.day) // → 00:00
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = String(format: "badge.%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }

        CareService.refreshBadge(context: context)
    }

    /// Coalesces a burst of care mutations — e.g. checking several reminders off in quick
    /// succession — into a single reminder/widget/badge rebuild a moment after the last change.
    /// Rebuilding on every tap runs a full store fetch and reschedules every pending
    /// notification on the main thread, which stalls the UI mid-tap and makes rapid check-offs
    /// feel unresponsive. The caller saves the SwiftData change immediately, so the list still
    /// updates at once; only this heavier rebuild is debounced off the tap's critical path.
    func scheduleRefresh(context: ModelContext) {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            WidgetCenter.shared.reloadAllTimelines()
            self?.refreshAll(context: context)
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    #if DEBUG
    /// Writes the currently-scheduled notifications to Documents/pending_dump.txt so their
    /// content and day-grouping can be verified without notification authorization
    /// (triggered by the `-dumpNotifications` launch argument).
    func dumpPending() async {
        let reqs = await center.pendingNotificationRequests()
        var lines = ["=== PENDING: \(reqs.count) ==="]
        for r in reqs.sorted(by: { $0.identifier < $1.identifier }) {
            let fire = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            lines.append("[\(r.identifier)] title=«\(r.content.title)» body=«\(r.content.body)» fire=\(fire?.description ?? "n/a")")
        }
        lines.append("=== END ===")
        let text = lines.joined(separator: "\n")
        if let url = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? text.write(to: url.appending(path: "pending_dump.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Fires a notification a few seconds out so notification delivery can be verified on the
    /// simulator (triggered by the `-fireTestNotification` launch argument).
    func scheduleTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "PlantPlant"
        content.body = "Test reminder"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        center.add(UNNotificationRequest(identifier: "debug.test", content: content, trigger: trigger))
    }
    #endif
}

// MARK: - Handling foreground presentation & actions

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Silent badge-only updates (empty content) must not pop an empty banner if they happen
        // to fire while the app is foregrounded — just apply the badge.
        let content = notification.request.content
        if content.title.isEmpty && content.body.isEmpty {
            completionHandler([.badge])
        } else {
            completionHandler([.banner, .sound, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier

        // Tapping the notification body (rather than an action button) opens the Reminders tab.
        if action == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                AppRouter.shared.selectedTab = .reminders
                completionHandler()
            }
            return
        }

        // "Mark done" / "Snooze" only apply to a single-task reminder, which carries the ids.
        let info = response.notification.request.content.userInfo
        let typed = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        guard
            let plantIDString = info["plantID"] as? String,
            let plantID = UUID(uuidString: plantIDString),
            let careTypeRaw = info["careType"] as? String
        else {
            completionHandler()
            return
        }

        // Mutate the *main* context that the UI's @Query observes, otherwise the change lands
        // on a separate context and the overview/detail/reminders keep showing the old date.
        Task { @MainActor in
            defer { completionHandler() }
            let context = SharedModelContainer.shared.mainContext
            let descriptor = FetchDescriptor<Plant>(predicate: #Predicate { $0.id == plantID })
            guard
                let plant = try? context.fetch(descriptor).first,
                let careType = CareType(rawValue: careTypeRaw),
                // The same picker the notification was planned from, so the action acts on the
                // schedule the user was actually told about — not on whichever duplicate the
                // relationship happened to hand back first.
                let schedule = CareSchedules.pick(careType, from: plant.schedules)
            else { return }

            switch action {
            case Self.markDoneAction:
                CareService.complete(schedule, context: context)
            case Self.snoozeAction:
                let days = Int(typed.trimmingCharacters(in: .whitespaces)) ?? 1
                CareService.snooze(schedule, days: max(1, days), context: context)
            default:
                break
            }
        }
    }
}
