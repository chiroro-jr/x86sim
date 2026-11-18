// SDK coverage, round 27: checks for [a] gaps (COVERAGE-GAPS.md). Each asserts what Apple's simulator answers
// (ref-mac.sh).
import Foundation
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

private var p23InputWait: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

extension Registry {
    static var p23: [Check] {
        var c: [Check] = []
        // MARK: WidgetKit: a widget the user placed on the home screen (inputs.sh widget / ref-mac.sh PRE=: long press on
        // the home screen, Edit, Add Widget, search "sdkcov", Add Widget, Done, before the app starts): it is among the
        // current configurations, and a reload of its kind asks the widget extension for a new timeline
        #if canImport(WidgetKit) && os(iOS)
        c.append(check("WidgetKit", "input-placed-widget-timeline", timeout: 120) {
            let wait = p23InputWait
            let desc = { (cs: [WidgetInfo]) in cs.map { "\($0.kind)/\($0.family)" } }
            guard wait > 0 else {
                let cs = try await WidgetCenter.shared.currentConfigurations()
                return "\(desc(cs)) (SDKCOV_INPUT_WAIT unset: no placed widget awaited)"
            }
            var cs: [WidgetInfo] = []
            _ = await p3Wait(wait) { cs = (try? await WidgetCenter.shared.currentConfigurations()) ?? []; return cs.contains { $0.kind == "sdkcov.static" } }
            try expect(cs.contains { $0.kind == "sdkcov.static" && $0.family == .systemSmall }, "no placed sdkcov.static widget: \(desc(cs))")
            // the placed widget's timeline: asked for when it was added (any time before), and again after a reload of its kind
            let before = p3Marks("widget-timeline").count
            let t0 = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: "sdkcov.static")
            let reloaded = await p3Wait(45) { !p3Marks("widget-timeline", since: t0).isEmpty }
            let after = p3Marks("widget-timeline", since: t0), views = p3Marks("widget-view", since: t0)
            let r = "configured \(desc(cs)); timelines before \(before), after the reload \(after) (views \(views.count): \(Set(views).sorted()))"
            try expect(before > 0, "the placed widget's timeline was never asked for: \(r)")
            try expect(reloaded, "no timeline asked for in 45 s after reloadTimelines(ofKind:): \(r)")
            return r
        })
        #endif
        return c
    }
}
