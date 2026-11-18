// SDK coverage, round 18: touch-driven checks (iOS). With SDKCOV_INPUT_WAIT=<s> each check puts its views at fixed
// fractions of the screen and waits for the host's touches (tests/apps/sdkcov/inputs.sh ctxmenu / swipe / sdrag /
// ncontent: `x86sim raw "touch ..."` here; ref-mac.sh INPUT=... on the Mac: Indigo touches, mac/indigo.m), as a user
// would long-press, swipe or drag in Apple's simulator. Without it a check only reports what it set up.
import Foundation
import Synchronization
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

private var touchWait: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

#if os(iOS)
/// a full-screen SwiftUI stage: `content` gets the screen size and lays itself out in screen coordinates
@MainActor private func p14Stage<V: View>(_ content: @escaping (CGSize) -> V) throws -> () -> Void {
    try p6HostSwiftUI(GeometryReader { g in content(g.size) }.ignoresSafeArea().background(Color.white))
}

/// SwiftUI contextMenu target: the middle of the screen (0.1..0.9 x 0.3..0.7); the host long-presses (0.5, 0.5)
private struct P14MenuView: View {
    let size: CGSize
    var body: some View {
        Rectangle().fill(Color.orange)
            .frame(width: size.width * 0.8, height: size.height * 0.4)
            .contextMenu {
                Button("SDKCovSwiftCtxOne") {}
                Button("SDKCovSwiftCtxTwo", role: .destructive) {}
            }
            .position(x: size.width / 2, y: size.height / 2)
    }
}

/// a List whose one tall row (about 0.2..0.5 of the screen) has trailing swipe actions; the host swipes it from
/// (0.95, 0.35) to (0.05, 0.35): a full swipe runs the first action
private struct P14SwipeView: View {
    let size: CGSize
    let log: P6Log
    var body: some View {
        List {
            Text("SDKCovSwipeRow").frame(maxWidth: .infinity, minHeight: size.height * 0.3)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("SDKCovArchive") { log.add("archive") }.tint(.blue)
                    Button("SDKCovDelete", role: .destructive) { log.add("delete") }
                }
        }
        .listStyle(.plain)
        .frame(width: size.width, height: size.height * 0.5)
        .position(x: size.width / 2, y: size.height * 0.45)
    }
}

/// Transferable drag and drop: a draggable text at (0.5, 0.25), a drop destination at (0.5, 0.75)
private struct P14DragView: View {
    let size: CGSize
    let log: P6Log
    @State private var targeted = false
    var body: some View {
        ZStack {
            Text("SDKCovDrag").font(.title).frame(width: size.width * 0.6, height: size.height * 0.2)
                .background(Color.yellow)
                .draggable("sdkcov swiftui drag")
                .position(x: size.width / 2, y: size.height * 0.25)
            Rectangle().fill(targeted ? Color.green : Color.gray)
                .frame(width: size.width * 0.8, height: size.height * 0.2)
                .dropDestination(for: String.self) { items, _ in
                    log.add("drop:" + items.joined(separator: ","))
                    return true
                } isTargeted: { t in
                    targeted = t
                    if t { log.add("targeted") }
                }
                .position(x: size.width / 2, y: size.height * 0.75)
        }
    }
}
#endif

#if canImport(UserNotifications) && os(iOS)
private final class P14NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    let presented = Mutex(0)
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        presented.withLock { $0 += 1 }
        return [.list, .banner]
    }
}
#endif

extension Registry {
    static var p14: [Check] {
        var c: [Check] = []
        #if os(iOS)
        // MARK: SwiftUI contextMenu opened by a long press (SwiftUI's ContextMenuBridge gives UIKit a configuration only
        // inside the gesture, so no programmatic presentation works: P13's UIKit check presents its own interaction)
        c.append(check("SwiftUI", "input-context-menu-long-press", timeout: 120) {
            let wait = touchWait
            let done = try await onMain { try p14Stage { P14MenuView(size: $0) } }
            defer { Task { @MainActor in done() } }
            guard wait > 0 else { return "contextMenu view on screen (SDKCOV_INPUT_WAIT unset: no long press awaited)" }
            let shown = await p6Wait(wait) { p13Labels().contains("SDKCovSwiftCtxTwo") }
            let labels = await onMain { p13Labels().filter { $0.hasPrefix("SDKCov") } }
            try expect(shown, "no context menu in \(Int(wait)) s (labels \(labels))")
            try expect(labels.contains("SDKCovSwiftCtxOne"), "menu labels \(labels)")
            return "long press opened the menu: \(labels)"
        })

        // MARK: SwiftUI List swipeActions: a full swipe runs the first trailing action
        c.append(check("SwiftUI", "input-list-swipe-actions", timeout: 120) {
            let wait = touchWait
            let log = P6Log()
            let done = try await onMain { try p14Stage { P14SwipeView(size: $0, log: log) } }
            defer { Task { @MainActor in done() } }
            guard wait > 0 else { return "list with swipe actions on screen (SDKCOV_INPUT_WAIT unset: no swipe awaited)" }
            let ok = await p6Wait(wait) { !log.all.isEmpty }
            try expect(ok, "no swipe action ran in \(Int(wait)) s")
            try expect(log.all.first == "archive", "actions run \(log.all) (a full trailing swipe runs the first: archive)")
            return "full swipe ran \(log.all)"
        })

        // MARK: SwiftUI drag and drop with Transferable (draggable / dropDestination) inside the app
        c.append(check("SwiftUI", "input-transferable-drag-drop", timeout: 120) {
            let wait = touchWait
            let log = P6Log()
            let done = try await onMain { try p14Stage { P14DragView(size: $0, log: log) } }
            defer { Task { @MainActor in done() } }
            guard wait > 0 else { return "draggable / dropDestination on screen (SDKCOV_INPUT_WAIT unset: no drag awaited)" }
            let ok = await p6Wait(wait) { log.all.contains { $0.hasPrefix("drop:") } }
            try expect(ok, "no drop in \(Int(wait)) s (events \(log.all))")
            let drop = log.all.first { $0.hasPrefix("drop:") } ?? ""
            try expect(drop == "drop:sdkcov swiftui drag" && log.has("targeted"), "events \(log.all)")
            return "dragged onto the destination: \(drop), targeted first"
        })
        #endif

        #if canImport(UserNotifications) && os(iOS)
        // MARK: UserNotificationsUI: the content extension runs when the user expands a notification of its category.
        // Alert authorization is asked for (the host taps Allow on the prompt), a banner of category sdkcov.content is
        // shown while the app is in front, and the host long-presses the banner: SpringBoard would load the extension
        // (ext/NotifyContent.swift marks ncontent-load / ncontent-receive)
        c.append(check("UserNotificationsUI", "input-expand-content-extension", timeout: 200) {
            let wait = touchWait
            let nc = UNUserNotificationCenter.current()
            guard wait > 0 else { return "SDKCOV_INPUT_WAIT unset: no expansion awaited" }
            // with --only the check starts while the app launches; the prompt needs it active
            _ = await p6Wait(20) { UIApplication.shared.applicationState == .active }
            let t0 = Date(), end = t0.addingTimeInterval(wait)
            // alert authorization (provisional shows no banners): the prompt, answered by the host's tap on Allow
            // (notificationSettings() does not answer while the app's first request is pending: Apple's simulator too)
            let granted = Mutex<Bool?>(nil)
            Task { let g = (try? await nc.requestAuthorization(options: [.alert, .sound, .badge])) ?? false; granted.withLock { $0 = g } }
            while granted.withLock({ $0 }) == nil && Date() < end { try await Task.sleep(for: .milliseconds(300)) }
            // the prompt comes from SpringBoard's notification server, which Apple's simulator starts about 135 s after
            // the device boots (iPhone and iPad alike): a request made sooner stays unanswered until then (r22: the
            // iPad's "never" of r21 was this; ref-mac.sh runs right after a boot, so its run waits up to 150 s)
            try expect(granted.withLock { $0 } == true, "alert authorization \(String(describing: granted.withLock { $0 })) after \(Int(wait)) s (the host's Allow never came)")
            let cats = await nc.notificationCategories()
            nc.setNotificationCategories(cats.filter { $0.identifier != "sdkcov.content" }.union([UNNotificationCategory(identifier: "sdkcov.content", actions: [], intentIdentifiers: [])]))
            let d = P14NotifDelegate(); let old = nc.delegate; nc.delegate = d
            defer { nc.delegate = old }
            // a banner every 8 s (three after the grant); the host long-presses each. Apple's iOS 27.2 simulator expands
            // it (the long look, its extension area blank) but never launches the content extension: no marks
            var ids: [String] = []
            while ids.count < 3 && p3Marks("ncontent-receive", since: t0).isEmpty {
                let content = UNMutableNotificationContent()
                content.title = "sdkcov"; content.body = "expand me \(ids.count)"; content.categoryIdentifier = "sdkcov.content"
                let id = "sdkcov.p14.\(ids.count)"; ids.append(id)
                try await nc.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                let next = Date().addingTimeInterval(8)
                while Date() < next && p3Marks("ncontent-receive", since: t0).isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            }
            nc.removeDeliveredNotifications(withIdentifiers: ids)
            let load = p3Marks("ncontent-load", since: t0), recv = p3Marks("ncontent-receive", since: t0)
            let shown = d.presented.withLock { $0 }
            try expect(shown == ids.count, "\(shown) of \(ids.count) banners presented")
            try expect(load.isEmpty && recv.isEmpty, "the content extension ran (loads \(load), received \(recv)): Apple's simulator never launches it")
            return "authorized by the host's Allow, \(shown) banners presented and long-pressed, content extension not launched (as Apple's simulator)"
        })
        #endif
        return c
    }
}
