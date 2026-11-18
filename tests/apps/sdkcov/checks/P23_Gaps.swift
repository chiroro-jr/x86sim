// SDK coverage, round 27: checks for [a] gaps (COVERAGE-GAPS.md). Each asserts what Apple's simulator answers
// (ref-mac.sh).
import Foundation
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif
#if canImport(GameController) && os(iOS)
import GameController
import Synchronization
#endif
#if os(watchOS)
import WatchKit
import Synchronization
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
        // MARK: WatchKit: the app's lifecycle when it leaves the screen and comes back (watchOS has no app-to-app URL
        // opening): inputs.sh lifecycle / ref-mac.sh INPUT presses the Digital Crown (home: the watch face),
        // then launches sdkcov again from the host. WKApplication's notifications in order with its state
        #if os(watchOS)
        c.append(check("WatchKit", "input-lifecycle-round-trip", timeout: 120) {
            let wait = p23InputWait
            guard wait > 0 else { return "state \(await onMain { WKApplication.shared().applicationState.rawValue }) (SDKCOV_INPUT_WAIT unset: no round trip awaited)" }
            _ = await p3Wait(20) { await onMain { WKApplication.shared().applicationState == .active } }
            let ev = Mutex<[String]>([])
            let nc = NotificationCenter.default
            var obs: [NSObjectProtocol] = []
            for (n, tag) in [(WKApplication.willResignActiveNotification, "willResignActive"), (WKApplication.didEnterBackgroundNotification, "didEnterBackground"),
                             (WKApplication.willEnterForegroundNotification, "willEnterForeground"), (WKApplication.didBecomeActiveNotification, "didBecomeActive")] {
                obs.append(nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                    let st = MainActor.assumeIsolated { WKApplication.shared().applicationState.rawValue }
                    ev.withLock { $0.append("\(tag)[\(st)]") }
                })
            }
            defer { obs.forEach { nc.removeObserver($0) } }
            let back = await p3Wait(wait) { ev.withLock { $0.contains { $0.hasPrefix("didEnterBackground") } && ($0.last?.hasPrefix("didBecomeActive") ?? false) } }
            try await Task.sleep(for: .milliseconds(500))
            let e = ev.withLock { $0 }
            let st = await onMain { WKApplication.shared().applicationState.rawValue }
            let d = "\(e); state now \(st)"
            try expect(back, "no round trip in \(Int(wait)) s: \(d)")
            // Apple's order and states (the host's launch that brings the app back adds a resign / become active pair)
            try expect(Array(e.prefix(4)) == ["willResignActive[0]", "didEnterBackground[2]", "willEnterForeground[2]", "didBecomeActive[0]"] && st == 0, d)
            return d
        })
        #endif
        // MARK: GameController: a hardware keyboard key through GCKeyboard (inputs.sh gckey / ref-mac.sh INPUT='key 14':
        // the host's K key, HID usage 14, as Simulator sends it): the coalesced keyboard appears and its key handler sees
        // K pressed and released
        #if canImport(GameController) && os(iOS)
        c.append(check("GameController", "input-keyboard-key", timeout: 120) {
            let wait = p23InputWait
            guard wait > 0 else { return "keyboard \(GCKeyboard.coalesced != nil) (SDKCOV_INPUT_WAIT unset: no key awaited)" }
            let ev = Mutex<[String]>([])
            let hook = { (kb: GCKeyboard) in
                kb.keyboardInput?.keyChangedHandler = { _, _, code, pressed in ev.withLock { $0.append("\(code.rawValue)\(pressed ? "+" : "-")") } }
            }
            let ob = NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { n in
                if let kb = n.object as? GCKeyboard { hook(kb) }
            }
            defer { NotificationCenter.default.removeObserver(ob) }
            if let kb = GCKeyboard.coalesced { hook(kb) }
            let got = await p3Wait(wait) { ev.withLock { $0.contains("14-") } }
            let e = ev.withLock { $0 }
            let d = "keyboard \(GCKeyboard.coalesced?.vendorName ?? "none"); keys \(e.prefix(12))"
            try expect(got, "no K press / release in \(Int(wait)) s: \(d)")
            return d
        })
        #endif
        return c
    }
}
