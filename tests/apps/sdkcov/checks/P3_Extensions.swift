// sdkcov P3: app extensions. build.sh embeds three in the app (sources in ext/): sdkcovWidget.appex (WidgetKit: static
// + App Intent widgets, iOS Live Activity views and a control), sdkcovFileProvider.appex (an
// NSFileProviderReplicatedExtension) and sdkcovExt.appex (ExtensionKit, bound to the app's own extension point
// com.x86sim.test.sdkcov.sdkcov-ext from Extensions/sdkcov.appexpt). The checks find them registered (pkd /
// LaunchServices), launch them through their system services (chronod, liveactivitiesd, fileproviderd,
// extensionkitservice) and read back what they did: each extension appends to <App Group>/p3marks/<event> (ext/Marks.swift).
import Foundation
import Synchronization
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ExtensionFoundation)
import ExtensionFoundation
#endif
#if canImport(ExtensionKit)
import ExtensionKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(FileProvider) && (os(iOS) || os(visionOS))
/// fileproviderd's FPItem for a URL in a domain (FileProvider's FPItemManager, as Files fetches it): its
/// contentModificationDate (seconds since 1970) / creationDate, or what went wrong
func p3FPItemDate(_ url: URL) async -> String {
    guard let cls = NSClassFromString("FPItemManager") as? NSObject.Type,
          let mgr = cls.perform(NSSelectorFromString("defaultManager"))?.takeUnretainedValue() as? NSObject else { return "no FPItemManager" }
    let sel = NSSelectorFromString("fetchItemForURL:completionHandler:")
    guard mgr.responds(to: sel) else { return "no fetchItemForURL" }
    typealias F = @convention(c) (NSObject, Selector, NSURL, @escaping @convention(block) (NSObject?, NSError?) -> Void) -> Void
    let f = unsafeBitCast(mgr.method(for: sel), to: F.self)
    let box = P3Box<String>()
    f(mgr, sel, url as NSURL) { item, err in
        guard let item else { box.put("error \(err.map { "\($0.domain) \($0.code)" } ?? "nil")"); return }
        let d = item.value(forKey: "contentModificationDate") as? Date, c = item.value(forKey: "creationDate") as? Date
        box.put("mod \(d.map { Int($0.timeIntervalSince1970) } ?? -1) created \(c.map { Int($0.timeIntervalSince1970) } ?? -1)")
    }
    _ = await p3Wait(10) { box.value != nil }
    return box.value ?? "no answer in 10 s"
}
#endif

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif
#if canImport(FileProvider) && (os(iOS) || os(visionOS))
import FileProvider
#endif

// MARK: helpers (P3_*.swift)

/// a value set from any thread, waited for
final class P3Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T?
    func set(_ x: T) { lock.withLock { if v == nil { v = x } } }
    func put(_ x: T) { lock.withLock { v = x } }
    var value: T? { lock.withLock { v } }
    func wait(_ secs: Double) async -> T? {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { if let x = value { return x }; try? await Task.sleep(for: .milliseconds(50)) }
        return value
    }
}
/// poll until cond holds (or secs pass); its last answer
func p3Wait(_ secs: Double, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
    return await cond()
}
func p3Err(_ e: Error) -> String { let n = e as NSError; return "\(n.domain) \(n.code)" }
let p3Group = "group.com.x86sim.test.sdkcov"
/// the lines an extension wrote for an event (ext/Marks.swift), newest last; only those after `since`
func p3Marks(_ name: String, since: Date = .distantPast) -> [String] {
    guard let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: p3Group),
          let s = try? String(contentsOf: g.appendingPathComponent("p3marks/\(name)"), encoding: .utf8) else { return [] }
    return s.split(separator: "\n").compactMap { l -> String? in
        let f = l.split(separator: " ", maxSplits: 1)
        guard f.count == 2, let t = Double(f[0]), t >= since.timeIntervalSince1970 - 1 else { return nil }
        return String(f[1])
    }
}
/// every event an extension has marked so far (file names)
func p3MarkNames() -> [String] {
    guard let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: p3Group) else { return [] }
    return ((try? FileManager.default.contentsOfDirectory(atPath: g.appendingPathComponent("p3marks").path)) ?? []).sorted()
}
/// LaunchServices / pkd's record of one of our extensions (+[NSExtension extensionWithIdentifier:error:], the lookup
/// NSExtension-based hosts make): its attributes (NSExtension dictionary), or the error
func p3Extension(_ id: String) -> (attrs: [String: Any]?, error: String?) {
    guard let cls = NSClassFromString("NSExtension") else { return (nil, "no NSExtension class") }
    typealias F = @convention(c) (AnyClass, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    let sel = NSSelectorFromString("extensionWithIdentifier:error:")
    guard let imp = class_getMethodImplementation(object_getClass(cls), sel) else { return (nil, "no extensionWithIdentifier:error:") }
    var err: NSError?
    guard let ext = unsafeBitCast(imp, to: F.self)(cls, sel, id as NSString, &err) as? NSObject else { return (nil, err.map(p3Err) ?? "nil") }
    return (ext.value(forKey: "attributes") as? [String: Any] ?? [:], nil)
}
#if canImport(UIKit) && !os(watchOS)
/// show a view controller in a window of the app's scene; returns the close action
@MainActor func p3Show(_ vc: UIViewController) -> () -> Void {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    let prev = scene.windows.first { $0.isKeyWindow }
    let w = UIWindow(windowScene: scene)
    w.rootViewController = vc; w.makeKeyAndVisible(); w.layoutIfNeeded()
    return { w.isHidden = true; w.rootViewController = nil; prev?.makeKeyAndVisible() }
}
#endif

#if canImport(ExtensionFoundation)
/// the XPC interface of ext/ExtKit.swift (same Objective-C name)
@objc(SDKCovExtService) protocol SDKCovExtService {
    func echo(_ text: String, reply: @escaping (String) -> Void)
}
let p3PointID = "com.x86sim.test.sdkcov.sdkcov-ext", p3ExtBID = "com.x86sim.test.sdkcov.ext"
/// our ExtensionKit extension's identity, found by an AppExtensionPoint.Monitor on the app's extension point
func p3ExtIdentity(_ secs: Double = 15) async throws -> (AppExtensionIdentity, AppExtensionPoint.Monitor) {
    let point = try AppExtensionPoint(identifier: StaticString(stringLiteral: "com.x86sim.test.sdkcov.sdkcov-ext"))
    let mon = try await AppExtensionPoint.Monitor(appExtensionPoint: point)
    _ = await p3Wait(secs) { mon.identities.contains { $0.bundleIdentifier == p3ExtBID } }
    guard let id = mon.identities.first(where: { $0.bundleIdentifier == p3ExtBID }) else {
        let st = mon.state
        throw Fail("no \(p3ExtBID) in the monitor after \(Int(secs)) s: identities \(mon.identities.map(\.bundleIdentifier)), unapproved \(st.unapprovedCount), disabled \(st.disabledCount)")
    }
    return (id, mon)
}
/// one echo over an extension's XPC connection
func p3Echo(_ c: NSXPCConnection, _ text: String) async -> String {
    c.remoteObjectInterface = NSXPCInterface(with: SDKCovExtService.self)
    c.resume()
    let r = P3Box<String>()
    let proxy = c.remoteObjectProxyWithErrorHandler { e in r.set("error \(p3Err(e))") } as? SDKCovExtService
    proxy?.echo(text) { r.set($0) }
    return await r.wait(15) ?? "no reply in 15 s"
}
#endif

extension Registry {
    static var p3_extensions: [Check] {
        var c: [Check] = []

        // MARK: ExtensionKit / ExtensionFoundation: the app's own extension point and its extension
        #if canImport(ExtensionFoundation)
        #if os(iOS)
        c.append(check("ExtensionFoundation", "app-extension-point-monitor", timeout: 40) {
            // the extension point the app defines (Extensions/sdkcov.appexpt) resolves; an unknown one throws
            var unknown = "no error"
            do { _ = try AppExtensionPoint(identifier: "com.x86sim.test.sdkcov.no-such-point") } catch { unknown = "\(error)" }
            try expect(unknown != "no error", "an unknown extension point resolved")
            let (id, mon) = try await p3ExtIdentity()
            try expect(id.extensionPointIdentifier == p3PointID, "extension point \(id.extensionPointIdentifier)")
            try expect(!id.localizedName.isEmpty, "no localized name")
            let st = mon.state
            return "\(id.bundleIdentifier) (\(id.localizedName)) on \(id.extensionPointIdentifier); \(mon.identities.count) identities, unapproved \(st.unapprovedCount), disabled \(st.disabledCount); unknown point: \(unknown.prefix(60))"
        })
        #else
        c.append(check("ExtensionFoundation", "apple-extension-point-monitor", timeout: 40) {
            // tvOS / watchOS / visionOS install no app-defined extension point (installd: "does not specify an Apple
            // extension point"); a monitor on an Apple point finds the app's own extension there: the Background Assets
            // downloader (tvOS, visionOS)
            var unknown = "no error"
            do { _ = try AppExtensionPoint(identifier: "com.x86sim.test.sdkcov.no-such-point") } catch { unknown = "\(error)" }
            try expect(unknown != "no error", "an unknown extension point resolved")
            #if os(watchOS)
            // watchOS installs no app extension on these points: a monitor on one of Apple's public points that supports
            // watchOS (App Intents extensions; its host entitlement is Apple-private)
            var mon = "monitor"
            do {
                let m = try await AppExtensionPoint.Monitor(appExtensionPoint: try AppExtensionPoint(identifier: "com.apple.appintents-extension"))
                mon = "monitor, identities \(m.identities.map(\.bundleIdentifier))"
            } catch { mon = p3Err(error) }
            // Apple's watchOS 27.2 simulator: refused, host not entitled (com.apple.extensionKit.errorDomain 16)
            try expect(mon == "com.apple.extensionKit.errorDomain 16", "monitor on com.apple.appintents-extension: \(mon) (Apple's simulator: com.apple.extensionKit.errorDomain 16)")
            return "Apple point monitor: \(mon); unknown point: \(unknown.prefix(80))"
            #else
            let point = try AppExtensionPoint(identifier: "com.apple.background-asset-downloader-extension")
            let mon = try await AppExtensionPoint.Monitor(appExtensionPoint: point)
            _ = await p3Wait(15) { mon.identities.contains { $0.bundleIdentifier == "com.x86sim.test.sdkcov.downloader" } }
            let ids = mon.identities.map(\.bundleIdentifier)
            try expect(ids.contains("com.x86sim.test.sdkcov.downloader"), "downloader not in the monitor: \(ids), unapproved \(mon.state.unapprovedCount)")
            return "\(ids) on \(point.id); unknown point: \(unknown.prefix(60))"
            #endif
        })
        #endif
        #if os(iOS)
        c.append(check("ExtensionKit", "app-extension-process-xpc", timeout: 60) {
            // AppExtensionProcess launches the extension (its AppExtension.main from ExtensionKit) and hands out an XPC
            // connection to its configuration's accept(connection:)
            let since = Date()
            let (id, _) = try await p3ExtIdentity()
            let interrupted = P3Box<Bool>()
            let proc = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: id, onInterruption: { interrupted.set(true) }))
            defer { proc.invalidate() }
            let conn = try proc.makeXPCConnection()
            defer { conn.invalidate() }
            let reply = await p3Echo(conn, "ping")
            try expect(reply.hasPrefix("ext \(p3ExtBID) pid ") && reply.hasSuffix(": ping"), "echo reply: \(reply)")
            let launched = p3Marks("ext-launch", since: since), accepted = p3Marks("ext-connection", since: since)
            try expect(!accepted.isEmpty, "the extension marked no connection (marks: \(p3MarkNames()))")
            return "\(reply); launches \(launched.count), connections \(accepted.count), interrupted \(interrupted.value ?? false)"
        })
        #endif
        #endif
        #if canImport(ExtensionKit) && os(iOS)
        c.append(check("ExtensionKit", "host-view-controller-scene", timeout: 60) {
            // EXHostViewController shows the extension's SwiftUI scene ("sdkcov-scene") in the app: it activates, the
            // scene's body runs in the extension, and the host hands out an XPC connection to the same process
            let since = Date()
            let (id, _) = try await p3ExtIdentity()
            final class D: NSObject, EXHostViewControllerDelegate {
                let active = P3Box<Bool>(), deact = P3Box<String>()
                func hostViewControllerDidActivate(_ vc: EXHostViewController) { active.set(true) }
                func hostViewControllerWillDeactivate(_ vc: EXHostViewController, error: Error?) { deact.set(error.map(p3Err) ?? "no error") }
            }
            let d = D()
            let (host, close) = await onMain { () -> (EXHostViewController, () -> Void) in
                let h = EXHostViewController(); h.delegate = d
                h.configuration = .init(appExtension: id, sceneID: "sdkcov-scene")
                return (h, p3Show(h))
            }
            defer { Task { @MainActor in close() } }
            let act = await d.active.wait(20)
            try expect(act == true, "hostViewControllerDidActivate never called (deactivated: \(d.deact.value ?? "no"))")
            let conn = try await onMain { try host.makeXPCConnection() }
            defer { conn.invalidate() }
            let reply = await p3Echo(conn, "host")
            _ = await p3Wait(10) { !p3Marks("ext-scene", since: since).isEmpty }
            let scene = p3Marks("ext-scene", since: since).count
            try expect(reply.hasSuffix(": host"), "echo through the host's connection: \(reply)")
            try expect(scene > 0, "the extension's scene body never ran (marks \(p3MarkNames()))")
            return "activated, scene body ran \(scene)x, \(reply)"
        })
        #endif

        // MARK: WidgetKit: the widget extension is registered and chronod asks it for its widgets
        #if canImport(WidgetKit) && !os(tvOS)
        c.append(check("WidgetKit", "widget-extension-descriptors", timeout: 90) {
            let (attrs, err) = p3Extension("com.x86sim.test.sdkcov.widget")
            guard let attrs else { throw Fail("the widget extension is not registered: \(err ?? "?")") }
            try expect((attrs["NSExtensionPointName"] ?? attrs["NSExtensionPointIdentifier"]) as? String == "com.apple.widgetkit-extension", "attributes \(attrs)")
            // a reload makes chronod (re)load the app's widget descriptors from the extension: WidgetBundle runs there
            WidgetCenter.shared.reloadAllTimelines()
            WidgetCenter.shared.reloadTimelines(ofKind: "sdkcov.static")
            WidgetCenter.shared.invalidateConfigurationRecommendations()
            let ran = await p3Wait(60) { !p3Marks("widget-launch").isEmpty }
            let cfg: String
            do { let c = try await WidgetCenter.shared.currentConfigurations(); cfg = "\(c.count) configured (\(c.map(\.kind)))" } catch { cfg = "currentConfigurations \(p3Err(error))" }
            #if os(visionOS)
            // a fresh visionOS device's chronod may not load the descriptors within the minute (Apple's simulator too)
            try skipIf(!ran, "registered; chronod did not run the widget extension in 60 s (\(cfg)); Apple's fresh visionOS simulator the same")
            #endif
            try expect(ran, "the widget extension never ran (marks \(p3MarkNames())); \(cfg)")
            return "registered; extension ran \(p3Marks("widget-launch").count)x; events \(p3MarkNames().filter { $0.hasPrefix("widget") }); \(cfg)"
        })
        #endif
        #if canImport(WidgetKit) && os(iOS)
        c.append(check("WidgetKit", "control-center-controls", timeout: 40) {
            // the app's control (ControlWidget kind sdkcov.control): none is placed in Control Center, so the list is empty
            ControlCenter.shared.reloadControls(ofKind: "sdkcov.control")
            ControlCenter.shared.reloadAllControls()
            let cur = try await ControlCenter.shared.currentControls()
            return "\(cur.count) controls placed (\(cur.map(\.kind)))"
        })
        #endif

        // MARK: ActivityKit: a Live Activity drawn by the widget extension's ActivityConfiguration
        #if canImport(ActivityKit) && os(iOS)
        c.append(check("ActivityKit", "live-activity-widget-views", timeout: 90) {
            let info = ActivityAuthorizationInfo()
            try expect(info.areActivitiesEnabled, "areActivitiesEnabled false")
            let since = Date()
            let a = try Activity.request(attributes: SDKCovLiveAttributes(name: "sdkcov"), content: ActivityContent(state: .init(step: 1), staleDate: Date().addingTimeInterval(600), relevanceScore: 50), pushType: nil)
            let states = P3Box<[String]>(); states.put([])
            let t = Task { for await s in a.activityStateUpdates { states.put((states.value ?? []) + ["\(s)"]) } }
            defer { t.cancel() }
            try expect(Activity<SDKCovLiveAttributes>.activities.contains { $0.id == a.id }, "not listed")
            try expect(a.activityState == .active, "state \(a.activityState)")
            // the system renders the activity's views in the widget extension (lock screen / Dynamic Island)
            let drawn = await p3Wait(45) { !p3Marks("live-view", since: since).isEmpty || !p3Marks("live-island", since: since).isEmpty }
            await a.update(ActivityContent(state: .init(step: 2), staleDate: nil), alertConfiguration: nil)
            // the update reaches the activity's content through liveactivitiesd, a moment later
            _ = await p3Wait(10) { a.content.state.step == 2 }
            try expect(a.content.state.step == 2, "state 10 s after the update \(a.content.state.step)")
            await a.end(ActivityContent(state: .init(step: 3), staleDate: nil), dismissalPolicy: .immediate)
            _ = await p3Wait(5) { a.activityState != .active }
            let views = p3Marks("live-view", since: since), island = p3Marks("live-island", since: since)
            try expect(drawn, "the widget extension drew no Live Activity view in 45 s (marks \(p3MarkNames()))")
            return "\(a.id.prefix(8)): \(a.activityState), states \(states.value ?? []), views \(views.count) (\(views.last ?? "")), island \(island.count)"
        })
        #endif

        // MARK: FileProvider: a replicated extension serving a domain
        #if canImport(FileProvider) && (os(iOS) || os(visionOS))
        c.append(check("FileProvider", "replicated-extension-domain", timeout: 150) {
            let since = Date()
            let dom = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("sdkcov-p3"), displayName: "sdkcov P3")
            // a leftover domain from an earlier run goes first
            try? await NSFileProviderManager.remove(dom)
            try await NSFileProviderManager.add(dom)
            var steps: [String] = []
            defer { Task { try? await NSFileProviderManager.remove(dom) } }
            let doms = try await NSFileProviderManager.domains()
            try expect(doms.contains { $0.identifier == dom.identifier }, "domains after add: \(doms.map(\.identifier.rawValue))")
            guard let m = NSFileProviderManager(for: dom) else { throw Fail("no manager for the domain") }
            let root = try await m.getUserVisibleURL(for: .rootContainer)
            steps.append("root \(root.lastPathComponent)")
            // listing the root makes fileproviderd enumerate it in the extension
            var names: [String] = []
            // (a fresh device's fileproviderd takes a while to start the domain's extension)
            for _ in 0..<120 {
                names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                if names.contains("hello.txt") { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #if os(visionOS)
            // Apple's visionOS 27.2 simulator adds the domain but never enumerates it (getDomains answers -2001 there)
            try skipIf(names.isEmpty, "domain added, root lists nothing in 60 s (Apple's visionOS simulator the same)")
            #endif
            try expect(names.contains("hello.txt") && names.contains("docs"), "root lists \(names) (marks \(p3MarkNames()))")
            steps.append("lists \(names)")
            // reading a dataless file materializes it: fetchContents in the extension
            let hello = root.appendingPathComponent("hello.txt")
            let text = try String(contentsOf: hello, encoding: .utf8)
            try expect(text == "hello from the sdkcov file provider", "hello.txt reads \(text.debugDescription)")
            try expect(!p3Marks("fp-fetch", since: since).isEmpty, "no fetchContents mark")
            let sub = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("docs").path)) ?? []).sorted()
            steps.append("docs \(sub)")
            // a file written into the domain is imported: createItem in the extension
            try Data("from the app".utf8).write(to: root.appendingPathComponent("new.txt"))
            let created = await p3Wait(30) { !p3Marks("fp-create", since: since).isEmpty }
            steps.append("create \(p3Marks("fp-create", since: since).last ?? "none")")
            try await m.signalEnumerator(for: .workingSet)
            // a downloaded file keeps the date it had (the items give no contentModificationDate: the time fileproviderd
            // made them) and is fetched once: Files shows that date. Apple's simulator: note.txt (read once the domain
            // is settled) always; hello.txt, read during the domain's first start, came back 1970 in some fresh-device
            // runs there too (reported). fileproviderd's FPItem as Files gets it (FPItemManager)
            let note = root.appendingPathComponent("docs/note.txt")
            _ = try String(contentsOf: note, encoding: .utf8)
            try await Task.sleep(for: .seconds(8))
            let noteDate = await p3FPItemDate(note), helloDate = await p3FPItemDate(hello)
            let fetches = p3Marks("fp-fetch", since: since)
            steps.append("downloaded: note \(noteDate), hello \(helloDate), fetches \(fetches)")
            try expect(noteDate.hasPrefix("mod 1") && !noteDate.hasPrefix("mod 1 "), "docs/note.txt after its download: \(noteDate) (fetches \(fetches))")
            try expect(fetches.filter { $0 == "note" }.count == 1, "note.txt fetched \(fetches.filter { $0 == "note" }.count) times (once on Apple's simulator; fetches \(fetches))")
            try expect(created, "new.txt never reached createItem: \(steps)")
            return steps.joined(separator: "; ")
        })
        #endif
        return c
    }
}

#if canImport(ActivityKit) && os(iOS)
/// the same type as ext/Widget.swift's (ActivityKit matches attributes by type name; both are module sdkcov)
struct SDKCovLiveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var step: Int }
    var name: String
}
#endif
