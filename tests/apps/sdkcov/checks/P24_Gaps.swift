// SDK coverage, round 28: checks for [a] gaps (COVERAGE-GAPS.md), mostly host input on the platforms the earlier input
// checks skipped. Each asserts what Apple's simulator answers (ref-mac.sh INPUT=, inputs.sh on x86Sim).
import Foundation
import Synchronization
import SwiftUI
#if canImport(GameController) && os(iOS)
import GameController
#endif
#if os(watchOS)
import CoreLocation
import CoreLocationUI
import _CoreLocationUI_SwiftUI
#endif

private var p24InputWait: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

#if os(watchOS)
/// a watch List row with trailing swipe actions filling the screen; the host swipes right to left across it
private struct P24WatchSwipeView: View {
    let log: P6Log
    var body: some View {
        List {
            Text("SDKCovSwipeRow").frame(maxWidth: .infinity, minHeight: 80)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("SDKCovArchive") { log.add("archive") }.tint(.blue)
                    Button("SDKCovDelete", role: .destructive) { log.add("delete") }
                }
        }
    }
}
#endif

extension Registry {
    static var p24: [Check] {
        var c: [Check] = []
        // MARK: GameController: the iPad's pointer-capture mouse (inputs.sh gcmouse: x86sim pointer; ref-mac.sh ipad
        // INPUT='pointer 30 20 5': Indigo relative pointer events): GCMouse connects and its moved handler sees deltas
        #if canImport(GameController) && os(iOS)
        c.append(check("GameController", "input-mouse-move", timeout: 120) {
            let wait = p24InputWait
            guard wait > 0 else { return "\(GCMouse.mice().count) mice (SDKCOV_INPUT_WAIT unset: no pointer awaited)" }
            let ev = Mutex<(n: Int, dx: Float, dy: Float)>((0, 0, 0))
            let hook = { (m: GCMouse) -> Void in
                m.mouseInput?.mouseMovedHandler = { _, dx, dy in ev.withLock { $0.n += 1; $0.dx += dx; $0.dy += dy } }
            }
            let ob = NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { n in
                if let m = n.object as? GCMouse { hook(m) }
            }
            defer { NotificationCenter.default.removeObserver(ob) }
            for m in GCMouse.mice() { hook(m) }
            let got = await p3Wait(wait) { ev.withLock { $0.n > 2 } }
            let e = ev.withLock { $0 }
            let d = "\(GCMouse.mice().count) mice (\(GCMouse.current?.vendorName ?? "none")); \(e.n) moves"
            try expect(got, "no mouse movement in \(Int(wait)) s: \(d)")
            return d
        })
        #endif
        // MARK: CoreLocationUI on watchOS: a LocationButton tapped by the host (inputs.sh locbutton: the middle of the
        // screen) runs its action, as func:CoreLocationUI.input-location-button-tap on iOS
        #if os(watchOS)
        c.append(check("CoreLocationUI", "input-location-button-tap", timeout: 120) {
            let wait = p24InputWait
            let log = P6Log()
            let done = try await onMain {
                try p6HostSwiftUI(GeometryReader { g in
                    LocationButton(.currentLocation) { log.add("action") }
                        .labelStyle(.iconOnly).frame(width: 80, height: 80)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                }.ignoresSafeArea())
            }
            defer { Task { @MainActor in done() } }
            guard wait > 0 else { return "location button on screen (SDKCOV_INPUT_WAIT unset: no tap awaited)" }
            let ok = await p6Wait(wait) { !log.all.isEmpty }
            try expect(ok, "the button's action never ran in \(Int(wait)) s")
            return "tap ran the action, authorization \(CLLocationManager().authorizationStatus.rawValue)"
        })
        // MARK: SwiftUI on watchOS: a right-to-left swipe on a List row reveals its trailing swipe actions as round
        // buttons (a full swipe runs none, both simulators); the host's tap on the outer one runs the first action
        // (inputs.sh swipe), as the full swipe does in func:SwiftUI.input-list-swipe-actions on iOS
        c.append(check("SwiftUI", "input-list-swipe-actions", timeout: 120) {
            let wait = p24InputWait
            let log = P6Log()
            let done = try await onMain { try p6HostSwiftUI(P24WatchSwipeView(log: log)) }
            defer { Task { @MainActor in done() } }
            guard wait > 0 else { return "list with swipe actions on screen (SDKCOV_INPUT_WAIT unset: no swipe awaited)" }
            let ok = await p6Wait(wait) { !log.all.isEmpty }
            try expect(ok, "no swipe action ran in \(Int(wait)) s")
            try expect(log.all.first == "archive", "actions run \(log.all) (the outer button is the first action: archive)")
            return "swipe + tap ran \(log.all.prefix(3))"
        })
        #endif
        return c
    }
}
