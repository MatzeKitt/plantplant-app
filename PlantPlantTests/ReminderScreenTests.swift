import Testing
import Foundation
import SwiftData
@testable import PlantPlant

/// The three reminders-screen features: marking everything due done in one action, and the
/// second daily reminder time — including the pending-notification budget that a second time
/// doubles the pressure on.
@MainActor
struct ReminderScreenTests {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: SharedModelContainer.schema, configurations: [config]))
    }

    @discardableResult
    private func plant(_ name: String, in context: ModelContext) -> Plant {
        let plant = Plant(name: name)
        context.insert(plant)
        return plant
    }

    @discardableResult
    private func schedule(_ type: CareType, on plant: Plant, dueInDays: Int, interval: Int = 7,
                          in context: ModelContext) -> CareSchedule {
        let due = Calendar.current.date(byAdding: .day, value: dueInDays, to: .now)!
        let schedule = CareSchedule(type: type, intervalDays: interval, startingFrom: due)
        schedule.plant = plant
        context.insert(schedule)
        return schedule
    }

    // ── Mark everything due done ─────────────────────────────────────────────

    @Test func completingEverythingDueAdvancesEveryOneOfThem() throws {
        let context = try makeContext()
        let monstera = plant("Monstera", in: context)
        let basil = plant("Basil", in: context)
        let overdue = schedule(.water, on: monstera, dueInDays: -5, interval: 7, in: context)
        let today = schedule(.mist, on: monstera, dueInDays: 0, interval: 3, in: context)
        let basilWater = schedule(.water, on: basil, dueInDays: 0, interval: 7, in: context)

        CareService.completeAll([overdue, today, basilWater], context: context)

        // Each lands at its own interval from now, not at a shared one.
        #expect(overdue.nextDue.daysFromToday == 7)
        #expect(today.nextDue.daysFromToday == 3)
        #expect(basilWater.nextDue.daysFromToday == 7)
        #expect(!overdue.isOverdue && !today.isOverdue && !basilWater.isOverdue)
    }

    /// The point of `completeAll` over a loop of `complete`: one instant for the batch. Two
    /// schedules ticked off by one tap must not drift apart by however long the loop took, or
    /// their due dates diverge a little further on every bulk completion.
    @Test func oneTapAnchorsEveryTaskToOneInstant() throws {
        let context = try makeContext()
        let monstera = plant("Monstera", in: context)
        let first = schedule(.water, on: monstera, dueInDays: -1, interval: 7, in: context)
        let second = schedule(.fertilize, on: monstera, dueInDays: -1, interval: 7, in: context)

        CareService.completeAll([first, second], context: context)

        #expect(first.lastDone == second.lastDone)
        #expect(first.nextDue == second.nextDue)
    }

    @Test func everyCompletedTaskGetsItsJournalEntry() throws {
        let context = try makeContext()
        let monstera = plant("Monstera", in: context)
        let water = schedule(.water, on: monstera, dueInDays: 0, in: context)
        let mist = schedule(.mist, on: monstera, dueInDays: 0, in: context)

        CareService.completeAll([water, mist], context: context)

        let logged = Set((monstera.logs ?? []).map(\.type))
        #expect(logged == [CareType.water.completionLog, CareType.mist.completionLog])
    }

    /// A plant can carry two water schedules, so the denormalized cache has to agree with the
    /// same picker every other caller uses — completing both in one action must not leave it
    /// holding whichever of them the batch happened to process last.
    @Test func theWaterCacheEndsOnTheScheduleThePickerChooses() throws {
        let context = try makeContext()
        let monstera = plant("Monstera", in: context)
        let soon = schedule(.water, on: monstera, dueInDays: -2, interval: 3, in: context)
        let later = schedule(.water, on: monstera, dueInDays: -1, interval: 30, in: context)

        CareService.completeAll([later, soon], context: context)

        #expect(monstera.nextWaterDue == CareSchedules.pick(.water, from: monstera.schedules)?.nextDue)
        #expect(monstera.nextWaterDue?.daysFromToday == 3)
    }

    @Test func anEmptyBatchIsANoOp() throws {
        let context = try makeContext()
        let monstera = plant("Monstera", in: context)
        schedule(.water, on: monstera, dueInDays: 0, in: context)

        CareService.completeAll([], context: context)

        #expect((monstera.logs ?? []).isEmpty)
    }

    // ── The second reminder time ─────────────────────────────────────────────

    @Test func withoutASecondTimeThereIsOneReminderTime() {
        #expect(NotificationManager.reminderMinutes(first: 16 * 60, second: nil) == [960])
    }

    @Test func aSecondTimeAddsASecondReminder() {
        #expect(NotificationManager.reminderMinutes(first: 16 * 60, second: 9 * 60) == [960, 540])
    }

    /// Both pickers can be set to the same clock time. Two identical notifications at one instant
    /// is not a second reminder, it is a bug that looks like a duplicate send.
    @Test func aSecondTimeEqualToTheFirstIsDropped() {
        #expect(NotificationManager.reminderMinutes(first: 8 * 60, second: 8 * 60) == [480])
    }

    @Test func storedTimesAreClampedToADay() {
        #expect(NotificationManager.reminderMinutes(first: -30, second: 5000) == [0, 1439])
    }

    /// Two reminder times routinely plan the same calendar day, and `UNUserNotificationCenter`
    /// treats a repeated identifier as a *replacement* — so identical ids would mean the evening
    /// reminder silently deleted the morning one instead of joining it.
    @Test func twoSlotsPlanningOneDayGetDistinctRequestIds() {
        let planID = "day.2026-08-28"

        #expect(NotificationManager.requestID(planID, slot: 0) == planID)
        #expect(NotificationManager.requestID(planID, slot: 1) != NotificationManager.requestID(planID, slot: 0))
    }

    /// A structural guard, not a behaviour test: the two limits are read from opposite ends of
    /// `refreshAll` and only ever meet at runtime. Raising one without the other would push the
    /// total past the point where iOS starts dropping requests without saying so.
    @Test func theBudgetLeavesRoomForBadgeUpdates() {
        #expect(NotificationManager.reminderLimit < NotificationManager.pendingLimit)
        #expect(NotificationManager.pendingLimit - NotificationManager.reminderLimit >= 8)
    }

    /// The trim is by fire date, so what survives a large library is the near future. A reminder
    /// dropped from the far end is re-added on the next launch, long before it comes due.
    @Test func theSoonestRemindersAreTheOnesThatSurviveTheBudget() {
        let calendar = Calendar.current
        let tasks = (1...(NotificationManager.reminderLimit + 10)).map { day in
            NotificationManager.CareTask(
                plantID: UUID(), plantName: "Plant \(day)", type: .water,
                fireDate: calendar.date(byAdding: .day, value: day, to: .now)!
            )
        }
        let kept = NotificationManager.buildPlans(tasks: tasks, calendar: calendar)
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(NotificationManager.reminderLimit)

        #expect(kept.count == NotificationManager.reminderLimit)
        #expect(kept.first?.fireDate.daysFromToday == 1)
        #expect(kept.last?.fireDate.daysFromToday == NotificationManager.reminderLimit)
    }
}
