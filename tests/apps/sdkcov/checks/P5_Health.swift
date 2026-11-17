// sdkcov P5: health & fitness. HealthKit through healthd without the user's Health authorization (an unattended run cannot
// answer the Health sheet, and simctl has no Health grant): every query kind (sample, statistics, statistics collection,
// anchored, observer), saving, deleting, background delivery and characteristics answer with healthd's authorization
// errors, Apple's codes pinned; with authorization granted on the device (answer sdkcov's Health sheet once) the same
// checks take the full path (save -> query back -> statistics -> delete). Workout sessions on iPhone (iOS 26), HealthKitUI's
// SwiftUI access request on watchOS, WorkoutKit plans / scheduler and its SwiftUI preview modifier.
import Foundation
import SwiftUI
import Synchronization
#if canImport(UIKit)
import UIKit
#endif
#if canImport(HealthKit)
import HealthKit
#endif
#if canImport(HealthKitUI)
import HealthKitUI
#endif
#if canImport(WorkoutKit)
import WorkoutKit
#endif
#if canImport(_WorkoutKit_SwiftUI)
import _WorkoutKit_SwiftUI
#endif

#if canImport(HealthKit)
/// HKErrorDomain code of an error (nil for another domain)
func p5HK(_ e: Error) -> Int? { let n = e as NSError; return n.domain == HKErrorDomain ? n.code : nil }
/// "ok <value>" or "HK <code>" (or the foreign error) of a HealthKit call
func p5HKTry(_ body: () async throws -> String) async -> String {
    do { return "ok " + (try await body()) } catch { return p5HK(error).map { "HK \($0)" } ?? "\(p5Err(error))" }
}
#if os(iOS) || os(watchOS)
final class P5WorkoutDelegate: NSObject, HKWorkoutSessionDelegate, @unchecked Sendable {
    let states = Mutex<[Int]>([]), error = Mutex<String?>(nil)
    func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) { states.withLock { $0.append(to.rawValue) } }
    func workoutSession(_ s: HKWorkoutSession, didFailWithError e: Error) { error.withLock { $0 = p5Err(e) } }
}
#endif
#endif

extension Registry {
    static var p5_health: [Check] {
        var c: [Check] = []
        #if canImport(HealthKit) && !os(tvOS)
        // MARK: HealthKit
        c.append(check("HealthKit", "save-query-statistics-delete", timeout: 60) {
            try expect(HKHealthStore.isHealthDataAvailable(), "health data not available (Apple's simulator: available)")
            let st = HKHealthStore()
            let steps = HKQuantityType(.stepCount), hr = HKQuantityType(.heartRate)
            let req = try await st.statusForAuthorizationRequest(toShare: [steps], read: [steps, hr])
            let shared = st.authorizationStatus(for: steps)
            let t0 = Date().addingTimeInterval(-600)
            let s = HKQuantitySample(type: steps, quantity: HKQuantity(unit: .count(), doubleValue: 123), start: t0, end: t0.addingTimeInterval(60),
                                     metadata: [HKMetadataKeyExternalUUID: "sdkcov-\(UUID().uuidString)"])
            let save = await p5HKTry { try await st.save(s); return "saved" }
            let pred = HKQuery.predicateForSamples(withStart: t0.addingTimeInterval(-1), end: .now)
            let q = await p5HKTry { "\(try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: steps, predicate: pred)], sortDescriptors: [SortDescriptor(\.endDate)]).result(for: st).count) samples" }
            let sum = await p5HKTry { "\(try await HKStatisticsQueryDescriptor(predicate: .quantitySample(type: steps, predicate: pred), options: .cumulativeSum).result(for: st)?.sumQuantity()?.doubleValue(for: .count()) ?? 0)" }
            let col = await p5HKTry {
                let d = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: steps, predicate: pred), options: .cumulativeSum,
                                                              anchorDate: Calendar.current.startOfDay(for: .now), intervalComponents: DateComponents(hour: 1))
                return "\(try await d.result(for: st).statistics().count) buckets"
            }
            let del = await p5HKTry { try await st.deleteObjects(of: steps, predicate: HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [s.metadata![HKMetadataKeyExternalUUID]!])); return "deleted" }
            let summary = "request status \(req.rawValue), share \(shared.rawValue); save \(save), query \(q), sum \(sum), collection \(col), delete \(del)"
            if shared == .sharingAuthorized {
                // authorized on this device (the Health sheet answered once): the whole round trip
                try expect(save == "ok saved" && q.hasPrefix("ok ") && !q.hasPrefix("ok 0 ") && sum.hasPrefix("ok ") && del == "ok deleted", summary)
                return "authorized: \(summary)"
            }
            // never authorized: Apple's healthd refuses writes (HKError 4 not authorized / 5 not determined) and reads of
            // types never asked for (5 authorization not determined)
            try expect(req == .shouldRequest, "authorization request status \(req.rawValue) (never asked: shouldRequest 1)")
            for (n, r) in [("save", save), ("query", q), ("sum", sum), ("collection", col), ("delete", del)] {
                try expect(r == "HK 4" || r == "HK 5", "\(n): \(r) (\(summary))")
            }
            return summary
        })
        c.append(check("HealthKit", "anchored-observer-background-delivery", timeout: 60) {
            let st = HKHealthStore()
            let steps = HKQuantityType(.stepCount)
            let anchored = await p5HKTry {
                let r = try await HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: steps)], anchor: nil).result(for: st)
                return "\(r.addedSamples.count) added, \(r.deletedObjects.count) deleted, anchor \(r.newAnchor != nil)"
            }
            // an observer query on a type never authorized: its handler gets the error (or fires once)
            let obs = P5Box<String>()
            let oq = HKObserverQuery(sampleType: steps, predicate: nil) { _, done, e in obs.set(e.map { p5HK($0).map { "HK \($0)" } ?? p5Err($0) } ?? "fired"); done() }
            st.execute(oq)
            let o = await obs.wait(10) ?? "no callback in 10 s"
            st.stop(oq)
            // background delivery needs com.apple.developer.healthkit.background-delivery (sdkcov's entitlements lack it)
            #if os(watchOS) || os(iOS) || os(visionOS)
            let bg = await p5HKTry { try await st.enableBackgroundDelivery(for: steps, frequency: .hourly); return "enabled" }
            let bgOff = await p5HKTry { try await st.disableAllBackgroundDelivery(); return "disabled" }
            #else
            let bg = "n/a", bgOff = "n/a"
            #endif
            let summary = "anchored \(anchored), observer \(o), background delivery \(bg), disable all \(bgOff)"
            if st.authorizationStatus(for: steps) != .sharingAuthorized {
                try expect(anchored == "HK 5" || anchored == "HK 4", "anchored: \(summary)")
                try expect(o != "no callback in 10 s", "observer: \(summary)")
            }
            try expect(bg.hasPrefix("HK ") || bg == "ok enabled", "background delivery: \(summary)")
            return summary
        })
        c.append(check("HealthKit", "characteristics-requests-model", timeout: 40) {
            let st = HKHealthStore()
            // characteristics are read-only, readable only after authorization: HKError 5 / 4
            let dob = await p5HKTry { "\(try st.dateOfBirthComponents())" }
            let sex = await p5HKTry { "\(try st.biologicalSex().biologicalSex.rawValue)" }
            // (requestAuthorization for no types raises NSInvalidArgumentException on Apple's: not called)
            var records = "n/a"
            #if os(iOS)
            records = "health records supported \(st.supportsHealthRecords())"
            #endif
            // the local model: units, quantities, predicates, workout configuration
            let gl = HKUnit(from: "mg/dL")
            let mmol = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
            let g = HKQuantity(unit: gl, doubleValue: 100)
            try expect(abs(g.doubleValue(for: mmol) - 5.55) < 0.02, "glucose \(g.doubleValue(for: mmol)) mmol/L")
            let f = HKQuantity(unit: .degreeCelsius(), doubleValue: 37).doubleValue(for: .degreeFahrenheit())
            try expect(abs(f - 98.6) < 1e-9, "temperature \(f) F")
            try expect(HKQuantity(unit: .meter(), doubleValue: 1).compare(HKQuantity(unit: .foot(), doubleValue: 3)) == .orderedDescending, "compare")
            let cfg = HKWorkoutConfiguration(); cfg.activityType = .swimming; cfg.swimmingLocationType = .pool; cfg.lapLength = HKQuantity(unit: .meter(), doubleValue: 25)
            try expect(cfg.lapLength?.doubleValue(for: .meter()) == 25, "workout configuration")
            let types = [HKObjectType.workoutType(), HKCategoryType(.sleepAnalysis), HKQuantityType(.vo2Max)].map(\.identifier)
            return "dateOfBirth \(dob), biologicalSex \(sex), \(records); \(types.count) types"
        })
        #if os(iOS)
        c.append(check("HealthKit", "workout-session-iphone", timeout: 50) {
            // iOS 26 runs HKWorkoutSession on iPhone; without workout authorization the session still runs (as on the watch)
            let st = HKHealthStore()
            if let old = try? await st.recoverActiveWorkoutSession() { old.end() }
            let cfg = HKWorkoutConfiguration(); cfg.activityType = .cycling; cfg.locationType = .indoor
            let s = try HKWorkoutSession(healthStore: st, configuration: cfg)
            let d = P5WorkoutDelegate(); s.delegate = d
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: st, workoutConfiguration: cfg)
            let start = Date()
            s.prepare(); s.startActivity(with: start)
            var begin = "began"
            do { try await b.beginCollection(at: start) } catch { begin = p5HK(error).map { "HK \($0)" } ?? p5Err(error) }
            let running = await p5Wait(15) { d.states.withLock { $0.contains(HKWorkoutSessionState.running.rawValue) } || d.error.withLock { $0 } != nil }
            let (states, err) = (d.states.withLock { $0 }, d.error.withLock { $0 })
            s.pause()
            _ = await p5Wait(5) { d.states.withLock { $0.contains(HKWorkoutSessionState.paused.rawValue) } }
            s.end()
            _ = await p5Wait(5) { d.states.withLock { $0.contains(HKWorkoutSessionState.ended.rawValue) } }
            let all = d.states.withLock { $0 }
            try expect(running && err == nil && states.contains(HKWorkoutSessionState.running.rawValue), "session states \(all), error \(err ?? "none")")
            try expect(all.contains(HKWorkoutSessionState.ended.rawValue), "never ended: \(all)")
            return "states \(all), builder \(begin), share \(st.authorizationStatus(for: .workoutType()).rawValue)"
        })
        #endif
        #endif

        // MARK: HealthKitUI on watchOS: the SwiftUI access-request modifier
        #if canImport(HealthKitUI) && os(watchOS)
        c.append(check("HealthKitUI", "access-request-modifier", timeout: 30) {
            // the request (Health's sheet) runs only when the trigger changes: hosted with a steady trigger the view shows
            // and nothing is asked (an unattended run cannot answer the sheet; a request for no types raises, as on Apple's)
            struct V: View {
                let st: HKHealthStore; let out: P5Box<String>; let shown: P5Box<String>
                var body: some View {
                    Text("sdkcov health").healthDataAccessRequest(store: st, readTypes: [HKQuantityType(.heartRate)], trigger: 0) { r in
                        switch r { case .success(let ok): out.set("success \(ok)"); case .failure(let e): out.set(p5HK(e).map { "HK \($0)" } ?? p5Err(e)) }
                    }.onAppear { shown.set("appeared") }
                }
            }
            let out = P5Box<String>(), shown = P5Box<String>()
            await onMain { Runner.shared.overlay = AnyView(V(st: HKHealthStore(), out: out, shown: shown)) }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            try expect(await shown.wait(10) == "appeared", "view never appeared")
            try await Task.sleep(for: .seconds(2))
            try expect(out.value == nil, "request completed without a trigger change: \(out.value!)")
            return "hosted, no request while the trigger is unchanged"
        })
        #endif

        // MARK: WorkoutKit
        #if canImport(WorkoutKit) && (os(iOS) || os(watchOS))
        c.append(check("WorkoutKit", "plans-composition-roundtrip") {
            let single = SingleGoalWorkout(activity: .running, location: .outdoor, goal: .distance(5, .kilometers))
            let pacer = PacerWorkout(activity: .running, location: .outdoor, distance: Measurement(value: 5, unit: .kilometers), time: Measurement(value: 25, unit: .minutes))
            let tri = SwimBikeRunWorkout(activities: [.swimming(.openWater), .cycling(.outdoor), .running(.outdoor)], displayName: "sdkcov tri")
            try expect(SwimBikeRunWorkout.supportsActivityOrdering(tri.activities), "triathlon ordering")
            for (n, p) in [("single", WorkoutPlan(.goal(single))), ("pacer", WorkoutPlan(.pacer(pacer))), ("triathlon", WorkoutPlan(.swimBikeRun(tri)))] {
                let back = try WorkoutPlan(from: try p.dataRepresentation)
                try expect(back.workout == p.workout, "\(n) round trip \(back.workout)")
            }
            try expect(SingleGoalWorkout.supportsGoal(.distance(5, .kilometers), activity: .running, location: .outdoor), "distance goal")
            return "single goal, pacer and triathlon plans round trip; custom yoga supported \(CustomWorkout.supportsActivity(.yoga))"
        })
        #endif
        #if canImport(WorkoutKit) && os(iOS)
        c.append(check("WorkoutKit", "scheduler-iphone", timeout: 30) {
            // the iPhone side of scheduled workouts (they sync to a paired watch): without authorization nothing is scheduled
            // (WorkoutScheduler.shared's authorizationState / scheduledWorkouts never answered on Apple's iPhone simulator:
            // the app stopped running; only the static answers are asserted)
            let sup = WorkoutScheduler.isSupported
            try expect(sup && WorkoutScheduler.maxAllowedScheduledWorkoutCount == 50, "supported \(sup), max \(WorkoutScheduler.maxAllowedScheduledWorkoutCount)")
            return "supported \(sup), max \(WorkoutScheduler.maxAllowedScheduledWorkoutCount)"
        })
        #endif
        #if canImport(_WorkoutKit_SwiftUI) && os(iOS)
        c.append(check("_WorkoutKit_SwiftUI", "workout-preview-modifier", timeout: 40) {
            // .workoutPreview presents WorkoutKit's plan preview while isPresented is true
            final class M: ObservableObject { @Published var on = false }
            let m = M()
            struct V: View { @ObservedObject var m: M; let plan: WorkoutPlan
                var body: some View { Text("sdkcov workout").workoutPreview(plan, isPresented: $m.on) } }
            let plan = WorkoutPlan(.goal(SingleGoalWorkout(activity: .running, goal: .time(20, .minutes))))
            let (hc, done) = try await onMain { () throws -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: V(m: m, plan: plan)); let (_, d) = try p5Show(hc); return (hc, d)
            }
            defer { Task { @MainActor in done() } }
            try await Task.sleep(for: .seconds(1))
            let before = await onMain { hc.presentedViewController.map { "\(type(of: $0))" } ?? "none" }
            try expect(before == "none", "presented \(before) while false")
            await onMain { m.on = true }
            let shown = await p5Wait(10) { await onMain { hc.presentedViewController != nil } }
            let what = await onMain { hc.presentedViewController.map { "\(type(of: $0))" } ?? "none" }
            await onMain { m.on = false }
            _ = await p5Wait(5) { await onMain { hc.presentedViewController == nil } }
            try expect(shown, "nothing presented with isPresented true")
            return "presented \(what)"
        })
        #endif
        #if canImport(_WorkoutKit_SwiftUI) && os(watchOS)
        c.append(check("_WorkoutKit_SwiftUI", "workout-preview-modifier-watch", timeout: 30) {
            final class M: ObservableObject { @Published var on = false }
            struct V: View { @ObservedObject var m: M; let plan: WorkoutPlan; let shown: P5Box<String>
                var body: some View { Text("sdkcov workout").workoutPreview(plan, isPresented: $m.on).onAppear { shown.set("appeared") } } }
            let shown = P5Box<String>(), m = await onMain { M() }
            let plan = WorkoutPlan(.goal(SingleGoalWorkout(activity: .running, goal: .time(20, .minutes))))
            await onMain { Runner.shared.overlay = AnyView(V(m: m, plan: plan, shown: shown)) }
            defer { Task { @MainActor in m.on = false; Runner.shared.overlay = nil } }
            try expect(await shown.wait(10) == "appeared", "view with the modifier never appeared")
            // the windows' presented controllers (watchOS has UIKit's classes underneath SwiftUI; through the runtime)
            @MainActor func presented() -> String {
                guard let app = (NSClassFromString("UIApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
                      let ws = app.value(forKey: "windows") as? [NSObject] else { return "no windows" }
                var out: [String] = []
                for w in ws { var vc = w.value(forKey: "rootViewController") as? NSObject
                    while let p = vc?.value(forKey: "presentedViewController") as? NSObject { out.append("\(type(of: p))"); vc = p } }
                return out.isEmpty ? "none" : out.joined(separator: ">")
            }
            let before = await onMain { presented() }
            await onMain { m.on = true }
            try await Task.sleep(for: .seconds(4))
            let during = await onMain { "\(presented()), isPresented \(m.on)" }
            await onMain { m.on = false }
            try await Task.sleep(for: .seconds(2))
            let after = await onMain { presented() }
            // Apple's watchOS 27.2 simulator: WorkoutKit's remote preview controller while true, gone after
            try expect(before == "none" && during == "WorkoutHostingRemoteViewController, isPresented true" && after == "none",
                       "before \(before); during \(during); after \(after) (Apple's simulator: none / WorkoutHostingRemoteViewController, isPresented true / none)")
            return "preview presented (\(during)), dismissed when false"
        })
        #endif
        return c
    }
}
