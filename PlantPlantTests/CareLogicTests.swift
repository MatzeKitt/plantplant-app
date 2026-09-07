import Testing
import Foundation
import SwiftData
@testable import PlantPlant

@MainActor
struct CareLogicTests {

    /// Fresh in-memory container per test.
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SharedModelContainer.schema, configurations: [config])
        return ModelContext(container)
    }

    private func makePlant(waterInDays: Int, interval: Int = 7, in context: ModelContext) -> Plant {
        let plant = Plant(name: "Test")
        context.insert(plant)
        let start = Calendar.current.date(byAdding: .day, value: waterInDays, to: .now)!
        let water = CareSchedule(type: .water, intervalDays: interval, startingFrom: start)
        water.plant = plant
        context.insert(water)
        CareService.syncWaterDue(plant)
        return plant
    }

    // MARK: Date helpers

    @Test func daysFromTodayAndBuckets() {
        #expect(Date.now.daysFromToday == 0)
        #expect(Calendar.current.date(byAdding: .day, value: 1, to: .now)!.daysFromToday == 1)
        #expect(Calendar.current.date(byAdding: .day, value: -2, to: .now)!.daysFromToday == -2)

        // Locale-independent: compare against the localized "Today" string.
        #expect(Date.now.relativeDueDescription == String(localized: "Today"))
    }

    // MARK: needsWater

    @Test func needsWaterReflectsDueDate() throws {
        let context = try makeContext()
        let overdue = makePlant(waterInDays: -1, in: context)
        let dueToday = makePlant(waterInDays: 0, in: context)
        let future = makePlant(waterInDays: 5, in: context)

        #expect(overdue.needsWater == true)
        #expect(dueToday.needsWater == true)
        #expect(future.needsWater == false)
    }

    @Test func nextWaterDueSyncsFromSchedule() throws {
        let context = try makeContext()
        let plant = makePlant(waterInDays: 3, in: context)
        #expect(plant.nextWaterDue == plant.waterSchedule?.nextDue)
    }

    // MARK: Completing care

    @Test func completeAdvancesScheduleAndLogs() throws {
        let context = try makeContext()
        let plant = makePlant(waterInDays: -1, interval: 7, in: context)
        let water = try #require(plant.waterSchedule)

        CareService.complete(water, context: context)

        // lastDone set to ~now, nextDue moved ~7 days out.
        let daysUntilNext = water.nextDue.daysFromToday
        #expect(daysUntilNext == 7)
        #expect(water.lastDone != nil)
        #expect(plant.needsWater == false)
        #expect(plant.nextWaterDue == water.nextDue)

        // A "watered" log was recorded.
        #expect(plant.sortedLogs.contains { $0.type == .watered })
    }

    @Test func snoozePushesDueDateOut() throws {
        let context = try makeContext()
        let plant = makePlant(waterInDays: 0, in: context)
        let water = try #require(plant.waterSchedule)
        let before = water.nextDue

        CareService.snooze(water, days: 2, context: context)

        let expected = Calendar.current.date(byAdding: .day, value: 2, to: before)!
        #expect(abs(water.nextDue.timeIntervalSince(expected)) < 1)
        // Snoozing does not log a completion, but does record a snooze journal entry.
        #expect(plant.sortedLogs.contains { $0.type == .watered } == false)
        #expect(plant.sortedLogs.contains { $0.type == .snoozed })
    }

    @Test func snoozeOnOverdueTaskLandsInTheFuture() throws {
        let context = try makeContext()
        let plant = makePlant(waterInDays: -5, in: context) // 5 days overdue
        let water = try #require(plant.waterSchedule)

        CareService.snooze(water, days: 2, context: context)

        // Anchored to today, so "snooze 2 days" is due in 2 days — not still overdue (which is
        // what pushing off the already-past nextDue by 2 would have produced).
        #expect(water.nextDue.daysFromToday == 2)
        #expect(water.isOverdue == false)
        #expect(plant.needsWater == false)
    }

    // MARK: Archive

    @Test func archiveAndRestoreLogAndFlag() throws {
        let context = try makeContext()
        let plant = makePlant(waterInDays: 0, in: context)

        CareService.setArchived(plant, true, context: context)
        #expect(plant.isArchived == true)
        #expect(plant.sortedLogs.contains { $0.type == .archived })

        CareService.setArchived(plant, false, context: context)
        #expect(plant.isArchived == false)
        #expect(plant.sortedLogs.contains { $0.type == .restored })
    }

    // MARK: Deletion

    @Test func deletingPlantClearsItsDueCount() throws {
        let context = try makeContext()
        _ = makePlant(waterInDays: -1, in: context)      // overdue
        let doomed = makePlant(waterInDays: -1, in: context) // overdue, will be deleted
        try context.save()

        #expect(CareService.dueCount(context: context) == 2)

        CareService.delete(doomed, context: context)

        #expect(CareService.dueCount(context: context) == 1)
    }

    // MARK: Notification fire dates

    @Test func fireDateRollsOverdueIntoFuture() {
        let cal = Calendar.current
        let now = Date.now

        // Overdue (due 5 days ago) → next reminder-time occurrence, in the future, within a day.
        let overdue = cal.date(byAdding: .day, value: -5, to: now)!
        let fire = NotificationManager.fireDate(forDueDay: overdue, hour: 16, minute: 0, now: now)
        #expect(fire > now)
        #expect(fire <= cal.date(byAdding: .day, value: 1, to: now)!)

        // A future due date is preserved at the reminder time on its own day.
        let future = cal.date(byAdding: .day, value: 3, to: now)!
        let fireFuture = NotificationManager.fireDate(forDueDay: future, hour: 16, minute: 0, now: now)
        let comps = cal.dateComponents([.hour, .minute], from: fireFuture)
        #expect(comps.hour == 16 && comps.minute == 0)
        #expect(cal.isDate(fireFuture, inSameDayAs: future))
        #expect(fireFuture > now)
    }

    @Test func outstandingCountGrowsAsDaysPass() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

        // One task already overdue, one due today, one due in three days.
        let dueDays = [day(-2), day(0), day(3)]

        // Only the overdue + today tasks count as of today; the future one is not yet due.
        #expect(NotificationManager.outstandingCount(dueDays: dueDays, asOf: day(0)) == 2)
        // The next day nothing new becomes due, so the count is unchanged.
        #expect(NotificationManager.outstandingCount(dueDays: dueDays, asOf: day(1)) == 2)
        // On the third day the future task becomes due and the badge grows to all three.
        #expect(NotificationManager.outstandingCount(dueDays: dueDays, asOf: day(3)) == 3)
    }

    @Test func badgeUpdatesScheduleMidnightRollovers() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

        // Overdue, due today, two due in 2 days, one due in 5 days.
        let dueDays = [day(-2), day(0), day(2), day(2), day(5)]
        let updates = NotificationManager.badgeUpdates(dueDays: dueDays, now: today, calendar: cal)

        // Only distinct *future* due-days get a midnight update — past/today are already reflected
        // in the live badge, and same-day duplicates collapse to one.
        #expect(updates.map(\.day) == [day(2), day(5)])
        // As of day+2, four tasks are due (−2, 0, 2, 2); by day+5 all five are.
        #expect(updates.map(\.badge) == [4, 5])
    }

    // MARK: Due indicators

    @Test func dueCareTypesAreDistinctOverdueSoonestFirst() throws {
        let context = try makeContext()
        let plant = Plant(name: "Test")
        context.insert(plant)
        func add(_ type: CareType, dayOffset: Int) {
            let start = Calendar.current.date(byAdding: .day, value: dayOffset, to: .now)!
            let s = CareSchedule(type: type, startingFrom: start)
            s.plant = plant
            context.insert(s)
        }
        add(.water, dayOffset: -1)     // overdue (soonest)
        add(.fertilize, dayOffset: 0)  // due today
        add(.mist, dayOffset: 3)       // future — excluded

        #expect(plant.dueCareTypes == [.water, .fertilize])
    }

    // MARK: Notification grouping

    @Test func sameDayTasksMergeIntoOneNotification() {
        let cal = Calendar.current
        let today = NotificationManager.fireDate(forDueDay: .now, hour: 16, minute: 0)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        let a = NotificationManager.CareTask(plantID: UUID(), plantName: "Monstera", type: .water, fireDate: today)
        let b = NotificationManager.CareTask(plantID: UUID(), plantName: "Basil", type: .mist, fireDate: today)
        let c = NotificationManager.CareTask(plantID: UUID(), plantName: "Fern", type: .water, fireDate: tomorrow)

        // Two tasks on the same day collapse into a single summary notification.
        let merged = NotificationManager.buildPlans(tasks: [a, b])
        #expect(merged.count == 1)
        #expect(merged[0].single == nil)
        #expect(merged[0].title == String(localized: "\(2) care tasks"))

        // Different days stay separate; a lone task keeps its actionable single reminder.
        let split = NotificationManager.buildPlans(tasks: [a, c])
        #expect(split.count == 2)
        let single = split.first { $0.single != nil }
        #expect(single?.body == String(localized: "\(CareType.water.label) reminder"))
    }

    // MARK: Photo history

    @Test func photoHistoryIsNewestFirstAndIgnoresNonPhotoLogs() throws {
        let context = try makeContext()
        let plant = Plant(name: "Test")
        context.insert(plant)

        let older = CareLog(type: .photoChanged,
                            date: Calendar.current.date(byAdding: .day, value: -5, to: .now)!,
                            photoData: Data([1]))
        older.plant = plant
        context.insert(older)
        let newer = CareLog(type: .photoChanged,
                            date: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                            photoData: Data([2]))
        newer.plant = plant
        context.insert(newer)
        let note = CareLog(type: .note, note: "no photo here")
        note.plant = plant
        context.insert(note)

        plant.photoData = Data([2]) // current matches the newest log — not duplicated

        #expect(plant.photoHistory == [Data([2]), Data([1])])
    }

    @Test func photoHistoryPrependsCurrentWhenNotYetLogged() throws {
        let context = try makeContext()
        let plant = Plant(name: "Legacy")
        context.insert(plant)
        plant.photoData = Data([9]) // e.g. a photo predating photo-carrying journal entries

        #expect(plant.photoHistory == [Data([9])])
    }

    @Test func completingPhotoTaskSnapshotsPhotoIntoJournal() throws {
        let context = try makeContext()
        let plant = Plant(name: "Test")
        context.insert(plant)
        let start = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let photo = CareSchedule(type: .photo, startingFrom: start)
        photo.plant = plant
        context.insert(photo)
        plant.photoData = Data([7])

        CareService.complete(photo, context: context)

        let photoLog = plant.sortedLogs.first { $0.type == .photoChanged }
        #expect(photoLog?.photoData == Data([7]))
        #expect(plant.photoHistory.contains(Data([7])))
    }

    // MARK: Schedule math

    @Test func rescheduleUsesInterval() {
        let schedule = CareSchedule(type: .fertilize, intervalDays: 30)
        let ref = Date.now
        schedule.reschedule(from: ref)
        let expected = Calendar.current.date(byAdding: .day, value: 30, to: ref)!
        #expect(abs(schedule.nextDue.timeIntervalSince(expected)) < 1)
        #expect(schedule.lastDone == ref)
    }

    @Test func defaultIntervalsPerCareType() {
        #expect(CareType.water.defaultIntervalDays == 7)
        #expect(CareType.fertilize.defaultIntervalDays == 30)
        #expect(CareType.mist.defaultIntervalDays == 3)
        #expect(CareType.repot.defaultIntervalDays == 365)
    }

    // MARK: Seasonal watering

    /// A date on the 15th of the given month in the current year.
    private func date(inMonth month: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year], from: .now)
        comps.month = month
        comps.day = 15
        return Calendar.current.date(from: comps)!
    }

    @Test func effectiveIntervalUsesSeasonForCoveredMonthOnly() throws {
        let context = try makeContext()
        let plant = makePlant(waterInDays: 3, interval: 7, in: context)
        let water = try #require(plant.waterSchedule)

        let covered = 3   // March
        let uncovered = 8 // August
        let season = WateringSeason(months: [covered], intervalDays: 21)
        season.plant = plant
        context.insert(season)

        #expect(water.effectiveInterval(on: date(inMonth: covered)) == 21)
        #expect(water.effectiveInterval(on: date(inMonth: uncovered)) == 7)
    }

    @Test func rescheduleUsesSeasonalIntervalForWater() throws {
        let context = try makeContext()
        let plant = makePlant(waterInDays: 0, interval: 7, in: context)
        let water = try #require(plant.waterSchedule)

        let currentMonth = Calendar.current.component(.month, from: .now)
        let season = WateringSeason(months: [currentMonth], intervalDays: 21)
        season.plant = plant
        context.insert(season)

        water.reschedule(from: .now)
        #expect(water.nextDue.daysFromToday == 21)
    }

    @Test func seasonsOnlyAffectWatering() throws {
        let context = try makeContext()
        let plant = Plant(name: "Test")
        context.insert(plant)
        let fertilize = CareSchedule(type: .fertilize, intervalDays: 30)
        fertilize.plant = plant
        context.insert(fertilize)

        let currentMonth = Calendar.current.component(.month, from: .now)
        let season = WateringSeason(months: [currentMonth], intervalDays: 5)
        season.plant = plant
        context.insert(season)

        // A season never changes a non-water schedule's interval.
        #expect(fertilize.effectiveInterval(on: .now) == 30)
    }

    // MARK: Recomputing after an interval change

    @Test func increasingIntervalClearsOverdueReminder() throws {
        let context = try makeContext()
        let plant = Plant(name: "Test")
        context.insert(plant)
        let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: .now)!
        let water = CareSchedule(type: .water, intervalDays: 7)
        water.plant = plant
        context.insert(water)

        // Last watered 8 days ago on a 7-day interval → due yesterday → overdue.
        CareService.recomputeNextDue(water, lastDone: eightDaysAgo)
        #expect(water.isOverdue)

        // Stretch the interval to 20 days: next due 12 days out, no longer overdue.
        water.intervalDays = 20
        CareService.recomputeNextDue(water, lastDone: eightDaysAgo)
        #expect(water.isOverdue == false)
        #expect(water.nextDue.daysFromToday == 12)
    }

    @Test func increasingSeasonalIntervalClearsOverdueReminder() throws {
        let context = try makeContext()
        let plant = Plant(name: "Test")
        context.insert(plant)
        let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: .now)!
        let water = CareSchedule(type: .water, intervalDays: 7)
        water.plant = plant
        context.insert(water)
        CareService.recomputeNextDue(water, lastDone: eightDaysAgo)
        #expect(water.isOverdue)

        // A seasonal override for the last-watered month stretches watering to 20 days.
        let month = Calendar.current.component(.month, from: eightDaysAgo)
        let season = WateringSeason(months: [month], intervalDays: 20)
        season.plant = plant
        context.insert(season)

        // Base interval untouched, but the seasonal interval now governs the recompute.
        CareService.recomputeNextDue(water, lastDone: eightDaysAgo)
        #expect(water.isOverdue == false)
        #expect(water.nextDue.daysFromToday == 12)
    }

    // MARK: Journal level changes

    @Test func editingSunlightRecordsLevelsNotText() throws {
        let context = try makeContext()
        let plant = makePlant(waterInDays: 3, in: context)
        plant.sunlight = .low
        let log = CareService.addLog(.edited, to: plant, context: context)
        log.sunlightFrom = 1
        log.sunlightTo = 4

        let edited = try #require(plant.sortedLogs.first { $0.type == .edited })
        #expect(edited.sunlightFrom == 1)
        #expect(edited.sunlightTo == 4)
        // The change is carried as structured levels, not baked into the note text.
        #expect(edited.note.isEmpty)
    }
}
