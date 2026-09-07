import Foundation
import SwiftData
import WidgetKit
import UserNotifications

/// Centralizes all mutations that affect care schedules, logs and reminders so behavior
/// stays consistent whether a change comes from the UI or a notification action.
enum CareService {

    // MARK: Logging

    @discardableResult
    static func addLog(_ type: LogType, to plant: Plant, note: String = "", photoData: Data? = nil, context: ModelContext) -> CareLog {
        let log = CareLog(type: type, note: note, photoData: photoData)
        log.plant = plant
        context.insert(log)
        return log
    }

    // MARK: Rescheduling after an interval change

    /// Recomputes a schedule's next-due date from its last-done anchor and the interval in effect
    /// for that date (seasonal watering overrides included). Called after an interval — base or
    /// seasonal — is edited, so a task that is no longer actually due drops off the reminders
    /// list. Increasing the interval pushes an overdue task back into the future; the schedule
    /// must already carry its new `intervalDays` and be attached to the plant (with its seasons
    /// applied) before calling.
    /// - Parameter recordingCompletion: whether `reference` should also be stored as the
    ///   schedule's `lastDone`. False when the reference was *derived* rather than entered — a
    ///   schedule that has never been completed must not start claiming it has, just because the
    ///   plant was opened in the editor and saved. That fabricated date is not cosmetic: it ships
    ///   in the export as `lastDoneAt`, where the importer has no way to tell it from a real one.
    static func recomputeNextDue(_ schedule: CareSchedule, lastDone: Date, recordingCompletion: Bool = true) {
        // Identical to advancing the schedule from `lastDone`; share the one implementation so
        // the interval arithmetic can't drift between here and `CareSchedule.reschedule`.
        schedule.reschedule(from: lastDone)

        if !recordingCompletion {
            // `reschedule` writes it; the arithmetic is what we wanted, the claim is not.
            schedule.lastDone = nil
        }
    }

    // MARK: Completing / snoozing care

    /// Marks a care task as done now: advances the schedule, writes a log, keeps the
    /// denormalized water date in sync, then rebuilds reminders/badge and refreshes the widget.
    static func complete(_ schedule: CareSchedule, context: ModelContext) {
        schedule.reschedule(from: Date())
        if let plant = schedule.plant {
            // Completing a photo task snapshots the plant's current photo into its journal entry.
            let photo = schedule.type == .photo ? plant.photoData : nil
            addLog(schedule.type.completionLog, to: plant, photoData: photo, context: context)
            syncWaterDue(plant)
        }
        save(context)
        // Debounced: checking several reminders off in a row shouldn't rebuild all
        // notifications/widget on every tap and stall the UI (see `scheduleRefresh`).
        NotificationManager.shared.scheduleRefresh(context: context)
    }

    /// Marks several care tasks done as one action.
    ///
    /// Not a loop over `complete` at the call site. That would save the context and rebuild every
    /// pending notification once per task, so checking a dozen reminders off in one tap would run
    /// a dozen full store fetches on the main thread. One save, one rebuild.
    ///
    /// All of them anchor to the *same* instant rather than to `Date()` per schedule, so two tasks
    /// completed by one tap stay on the same interval boundary forever instead of drifting apart
    /// by however long the loop took.
    static func completeAll(_ schedules: [CareSchedule], context: ModelContext) {
        guard !schedules.isEmpty else { return }
        let now = Date()
        // The water-date cache is per plant, and a batch routinely holds several tasks of the
        // same one; collecting them here writes it once per plant rather than once per task.
        var touched: [UUID: Plant] = [:]

        for schedule in schedules {
            schedule.reschedule(from: now)
            guard let plant = schedule.plant else { continue }
            let photo = schedule.type == .photo ? plant.photoData : nil
            addLog(schedule.type.completionLog, to: plant, photoData: photo, context: context)
            touched[plant.id] = plant
        }

        for plant in touched.values { syncWaterDue(plant) }
        save(context)
        NotificationManager.shared.scheduleRefresh(context: context)
    }

    /// Pushes a schedule's next due date out by `days`, recording a journal entry (but not a
    /// completion).
    static func snooze(_ schedule: CareSchedule, days: Int, context: ModelContext) {
        // Anchor the offset to today when the task is already overdue, so "snooze N days" always
        // lands in the future — pushing off `nextDue` directly would leave an overdue task still
        // overdue (e.g. 5 days late, snoozed 3 → still 2 days late).
        let base = max(schedule.nextDue, Date())
        schedule.nextDue = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        if let plant = schedule.plant {
            addLog(.snoozed, to: plant, note: String(localized: "\(schedule.type.label) snoozed \(days) days"), context: context)
            syncWaterDue(plant)
        }
        save(context)
        NotificationManager.shared.scheduleRefresh(context: context)
    }

    // MARK: Archive

    static func setArchived(_ plant: Plant, _ archived: Bool, context: ModelContext) {
        plant.isArchived = archived
        addLog(archived ? .archived : .restored, to: plant, context: context)
        save(context)
        reloadWidget()
        NotificationManager.shared.refreshAll(context: context)
    }

    static func delete(_ plant: Plant, context: ModelContext) {
        // Release every stored photo (the current one and each journal photo) so their
        // external-storage files are removed along with the plant.
        plant.photoData = nil
        for log in plant.logs ?? [] { log.photoData = nil }
        context.delete(plant)
        save(context)
        reloadWidget()
        NotificationManager.shared.refreshAll(context: context)
    }

    // MARK: Photos

    /// Sets the plant's photo and counts it toward the "Photo" reminder: if a photo schedule is
    /// enabled it's completed (rescheduled + a photo journal entry recorded); otherwise a photo
    /// entry is still logged. Used by the detail-view camera button and the reminders camera flow.
    static func setPhoto(_ data: Data, for plant: Plant, context: ModelContext) {
        plant.photoData = data
        if let photo = CareSchedules.pickEnabled(.photo, from: plant.schedules) {
            complete(photo, context: context) // snapshots the new photo into its log + reschedules + refreshes
        } else {
            addLog(.photoChanged, to: plant, photoData: data, context: context)
            save(context)
            reloadWidget()
            NotificationManager.shared.refreshAll(context: context)
        }
    }

    // MARK: Sync helpers

    /// Copies the (enabled) water schedule's next-due date onto the plant for cheap
    /// sorting/filtering, or clears it when watering is disabled.
    static func syncWaterDue(_ plant: Plant) {
        if let water = plant.waterSchedule, water.isEnabled {
            plant.nextWaterDue = water.nextDue
        } else {
            plant.nextWaterDue = nil
        }
    }

    /// Called after edits so reminders and widget reflect the latest schedules.
    static func plantDidChange(_ plant: Plant, context: ModelContext) {
        syncWaterDue(plant)
        save(context)
        reloadWidget()
        NotificationManager.shared.refreshAll(context: context)
    }

    // MARK: Badges

    /// Number of care tasks that are due today or overdue across all active plants.
    static func dueCount(context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Plant>(predicate: #Predicate { !$0.isArchived })
        let plants = (try? context.fetch(descriptor)) ?? []
        // `isOverdue` already implies `isEnabled`; iterate raw schedules to avoid
        // `enabledSchedules`' per-plant filter-and-sort when we only need a count.
        return plants.reduce(0) { $0 + ($1.schedules ?? []).filter(\.isOverdue).count }
    }

    /// Updates the app-icon badge to the current due-task count.
    static func refreshBadge(context: ModelContext) {
        UNUserNotificationCenter.current().setBadgeCount(dueCount(context: context))
    }

    // MARK: Plumbing

    static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            assertionFailure("SwiftData save failed: \(error)")
        }
    }

    static func reloadWidget() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
