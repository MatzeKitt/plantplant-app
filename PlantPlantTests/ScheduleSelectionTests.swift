import Testing
import Foundation
import SwiftData
@testable import PlantPlant

/// Regressions for the places where "the schedule of this type" or "the season for this month"
/// used to be whatever `first(where:)` happened to return, and for the two edit-time bugs that
/// nondeterminism was hiding.
@MainActor
struct ScheduleSelectionTests {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: SharedModelContainer.schema, configurations: [config]))
    }

    private func plant(in context: ModelContext) -> Plant {
        let plant = Plant(name: "Monstera")
        context.insert(plant)
        return plant
    }

    @discardableResult
    private func schedule(_ type: CareType, on plant: Plant, dueInDays: Int, interval: Int = 7,
                          enabled: Bool = true, in context: ModelContext) -> CareSchedule {
        let due = Calendar.current.date(byAdding: .day, value: dueInDays, to: .now)!
        let schedule = CareSchedule(type: type, intervalDays: interval, isEnabled: enabled, startingFrom: due)
        schedule.plant = plant
        context.insert(schedule)
        return schedule
    }

    // ── The picker ───────────────────────────────────────────────────────────

    @Test func anEnabledScheduleBeatsADisabledOne() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        // The disabled one is due sooner, so only the enabled-first rule can pick correctly.
        schedule(.water, on: plant, dueInDays: -5, enabled: false, in: context)
        let live = schedule(.water, on: plant, dueInDays: 3, enabled: true, in: context)

        #expect(CareSchedules.pick(.water, from: plant.schedules)?.id == live.id)
    }

    @Test func amongEqualsTheSoonestDueWins() throws {
        func make(_ dueInDays: Int) -> CareSchedule {
            CareSchedule(type: .mist, startingFrom: Calendar.current.date(byAdding: .day, value: dueInDays, to: .now)!)
        }
        let soon = make(1)
        let later = make(9)

        // Both orders, so the assertion cannot be satisfied by the array order alone.
        #expect(CareSchedules.pick(.mist, from: [later, soon])?.id == soon.id)
        #expect(CareSchedules.pick(.mist, from: [soon, later])?.id == soon.id)
    }

    /// Ids are pinned rather than left random: with random ids a naive `first(where:)` agrees
    /// with the correct answer about half the time, so the test would pass against the very bug
    /// it exists to catch. Pinned ids plus both array orders make it exact.
    @Test func aTieIsBrokenByIdSoTheAnswerIsStable() throws {
        let due = Calendar.current.date(byAdding: .day, value: 2, to: .now)!
        let low = CareSchedule(type: .fertilize, startingFrom: due)
        let high = CareSchedule(type: .fertilize, startingFrom: due)
        low.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        high.id = UUID(uuidString: "ffffffff-0000-0000-0000-000000000002")!

        #expect(CareSchedules.pick(.fertilize, from: [low, high])?.id == low.id)
        #expect(CareSchedules.pick(.fertilize, from: [high, low])?.id == low.id)
    }

    @Test func pickEnabledIsNilWhenThePreferredScheduleIsOff() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        schedule(.photo, on: plant, dueInDays: 4, enabled: false, in: context)

        #expect(CareSchedules.pick(.photo, from: plant.schedules) != nil)
        #expect(CareSchedules.pickEnabled(.photo, from: plant.schedules) == nil)
    }

    /// The bug the picker exists for: `syncWaterDue` asks for "the" water schedule and clears
    /// `nextWaterDue` when it is disabled. Picking the disabled duplicate made a plant whose
    /// watering is switched on drop out of the list, the widget and the deadline sort.
    @Test func aDisabledDuplicateDoesNotClearTheWaterDate() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        schedule(.water, on: plant, dueInDays: -2, enabled: false, in: context)
        let live = schedule(.water, on: plant, dueInDays: 3, enabled: true, in: context)

        CareService.syncWaterDue(plant)

        #expect(plant.nextWaterDue == live.nextDue)
    }

    // ── Overlapping seasons ──────────────────────────────────────────────────

    @Test func twoSeasonsCoveringOneMonthResolveToTheLowestId() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        let water = schedule(.water, on: plant, dueInDays: 1, interval: 7, in: context)

        // Pinned ids, and inserted highest-first, so the expected answer is never simply the
        // one that happens to come back first.
        let month = Calendar.current.component(.month, from: .now)
        let low = WateringSeason(months: [month], intervalDays: 21)
        let high = WateringSeason(months: [month], intervalDays: 14)
        low.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        high.id = UUID(uuidString: "ffffffff-0000-0000-0000-000000000002")!
        for season in [high, low] { season.plant = plant; context.insert(season) }

        #expect(water.effectiveInterval(on: .now) == low.intervalDays)
    }

    /// The edit-time bug: `context.delete` leaves a season in the relationship until the next
    /// save, so the interval recomputation that runs immediately afterwards could read the
    /// season the user had just removed.
    @Test func aDeletedSeasonStopsAffectingTheIntervalAtOnce() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        let water = schedule(.water, on: plant, dueInDays: 1, interval: 7, in: context)

        let month = Calendar.current.component(.month, from: .now)
        let season = WateringSeason(months: [month], intervalDays: 21)
        season.plant = plant
        context.insert(season)
        try context.save()

        #expect(water.effectiveInterval(on: .now) == 21)

        // Exactly what `PlantEditView.applySeasons` now does.
        season.plant = nil
        context.delete(season)

        #expect(water.effectiveInterval(on: .now) == 7)
    }

    // ── A never-completed schedule stays never-completed ─────────────────────

    @Test func anUnchangedSaveDoesNotInventALastDoneDate() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        let water = schedule(.water, on: plant, dueInDays: 3, interval: 7, in: context)
        #expect(water.lastDone == nil)

        let draft = ScheduleDraft.from(plant: plant).first { $0.type == .water }!
        #expect(draft.recordsCompletion == false)

        let dueBefore = water.nextDue
        CareService.recomputeNextDue(water, lastDone: draft.lastDone,
                                     recordingCompletion: draft.recordsCompletion)

        #expect(water.lastDone == nil)
        // Still stable: the derived anchor is chosen so an unchanged save leaves the date alone.
        #expect(Calendar.current.isDate(water.nextDue, inSameDayAs: dueBefore))
    }

    /// The reason the derived anchor is kept rather than skipped: widening an interval must
    /// still clear an overdue reminder, even for a schedule that was never completed.
    @Test func wideningAnIntervalStillClearsOverdueWithoutALastDone() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        let water = schedule(.water, on: plant, dueInDays: -1, interval: 7, in: context)

        var draft = ScheduleDraft.from(plant: plant).first { $0.type == .water }!
        draft.intervalDays = 20
        water.intervalDays = 20
        CareService.recomputeNextDue(water, lastDone: draft.lastDone,
                                     recordingCompletion: draft.recordsCompletion)

        #expect(water.lastDone == nil)
        #expect(water.isOverdue == false)
        #expect(water.nextDue.daysFromToday == 12)
    }

    @Test func editingTheDateRecordsItAsARealCompletion() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        let water = schedule(.water, on: plant, dueInDays: 3, interval: 7, in: context)

        var draft = ScheduleDraft.from(plant: plant).first { $0.type == .water }!
        draft.lastDone = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
        #expect(draft.recordsCompletion)

        CareService.recomputeNextDue(water, lastDone: draft.lastDone,
                                     recordingCompletion: draft.recordsCompletion)

        #expect(water.lastDone != nil)
    }

    @Test func aScheduleWithARealLastDoneKeepsRecordingIt() throws {
        let context = try makeContext()
        let plant = plant(in: context)
        let water = schedule(.water, on: plant, dueInDays: 3, interval: 7, in: context)
        water.lastDone = Calendar.current.date(byAdding: .day, value: -4, to: .now)!

        let draft = ScheduleDraft.from(plant: plant).first { $0.type == .water }!
        #expect(draft.derivedLastDone == nil)
        #expect(draft.recordsCompletion)
    }

    // ── Notification text is stable ──────────────────────────────────────────

    @Test func aSummaryListsPlantsInTheSameOrderWhateverTheStoreReturns() throws {
        let day = Calendar.current.date(byAdding: .day, value: 2, to: .now)!
        func task(_ name: String) -> NotificationManager.CareTask {
            NotificationManager.CareTask(plantID: UUID(), plantName: name, type: .water, fireDate: day)
        }
        let forward = NotificationManager.buildPlans(tasks: [task("Monstera"), task("Basil")])
        let reversed = NotificationManager.buildPlans(tasks: [task("Basil"), task("Monstera")])

        #expect(forward.first?.body == "Basil, Monstera")
        #expect(forward.first?.body == reversed.first?.body)
    }
}
