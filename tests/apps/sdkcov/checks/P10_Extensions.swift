// sdkcov P10: the app extensions build.sh adds for P10 (iOS; sources in ext/) and what Apple's simulator does with each.
// - NSExtension points (PlugIns/): notification content + service, File Provider UI action, SMS message filter, call /
//   message reporting UI. LaunchServices registers each on its point (LSApplicationExtensionRecord); the service
//   extension runs for a mutable remote notification (simctl push / x86sim push, sent by inputs.sh push while the check
//   waits: SDKCOV_INPUT_WAIT). The others run only from system UI (an expanded notification, the Files app's action
//   menu, Messages / Phone).
// - ExtensionKit points (Extensions/): translation provider, app migration, Home, accessory transport, accessory data
//   provider (AccessoryNotifications forwarding), device discovery. Registered as well; the app may not watch Apple's
//   points (AppExtensionPoint.Monitor: "Host is not entitled", com.apple.extensionKit.errorDomain 16 on Apple's
//   simulator) and AppMigrationTester cannot start the migration extension from an app (RunningBoard refuses the launch).
import Foundation
import ObjectiveC
import Synchronization
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ExtensionFoundation)
import ExtensionFoundation
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(AppMigrationKit) && os(iOS)
import AppMigrationKit
#endif
#if canImport(AccessoryNotifications) && os(iOS)
import AccessoryNotifications
#endif

/// LaunchServices' record of one of the app's extensions (LSApplicationExtensionRecord; no PlugInKit discovery, no launch):
/// its extension point and its Info.plist NSExtension dictionary
struct P10Record { let point: String; let nsExtension: [String: Any]; let raw: NSObject }
func p10Record(_ id: String) throws -> P10Record {
    guard let cls = NSClassFromString("LSApplicationExtensionRecord") else { throw Fail("no LSApplicationExtensionRecord") }
    let sel = NSSelectorFromString("initWithBundleIdentifier:error:")
    typealias F = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    guard let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let imp = class_getMethodImplementation(cls, sel) else { throw Fail("no LSApplicationExtensionRecord initializer") }
    var err: NSError?
    guard let r = unsafeBitCast(imp, to: F.self)(alloc, sel, id as NSString, &err) as? NSObject else {
        throw Fail("\(id) is not registered: \(err.map(p3Err) ?? "no record")")
    }
    var point = "", ns: [String: Any] = [:]
    if let ex = SDKCovCatch({
        point = r.value(forKeyPath: "extensionPointRecord.identifier") as? String ?? ""
        // (LSPropertyList: objectForKey:ofClass:, else its whole dictionary)
        if let info = r.value(forKey: "infoDictionary") as? NSObject {
            let s1 = NSSelectorFromString("objectForKey:ofClass:"), s2 = NSSelectorFromString("_expensiveDictionaryRepresentation")
            if info.responds(to: s1) {
                ns = info.perform(s1, with: "NSExtension", with: NSDictionary.self)?.takeUnretainedValue() as? [String: Any] ?? [:]
            }
            if ns.isEmpty, info.responds(to: s2) {
                ns = (info.perform(s2)?.takeUnretainedValue() as? [String: Any])?["NSExtension"] as? [String: Any] ?? [:]
            }
        }
    }) { throw Fail("\(id) record raised \(ex[0]): \(ex[1])") }
    return P10Record(point: point, nsExtension: ns, raw: r)
}
#if canImport(ExtensionFoundation)
/// a monitor on one of Apple's extension points: what the app gets (Apple's simulator: extensionKit 16, not entitled)
func p10MonitorAnswer(_ point: StaticString) async -> String {
    do {
        let mon = try await AppExtensionPoint.Monitor(appExtensionPoint: try AppExtensionPoint(identifier: point))
        return "monitor, identities \(mon.identities.map(\.bundleIdentifier))"
    } catch { return p3Err(error) }
}
/// an ExtensionKit extension on one of Apple's points: registered there; the app's monitor is refused
func p10AppleExtensionPoint(_ id: String, _ point: StaticString) async throws -> String {
    let r = try p10Record("com.x86sim.test.sdkcov.\(id)")
    try expect(r.point == "\(point)", "\(id) registered on \(r.point) (want \(point))")
    let mon = await p10MonitorAnswer(point)
    // Apple's simulator: "Host is not entitled observe" (the point's host entitlement is Apple-private)
    try expect(mon == "com.apple.extensionKit.errorDomain 16", "monitor on \(point): \(mon) (Apple's simulator: com.apple.extensionKit.errorDomain 16, host not entitled)")
    return "registered on \(r.point); monitor refused (\(mon))"
}
#endif
#if canImport(UserNotifications) && (os(iOS) || os(watchOS) || os(visionOS))
private final class P10NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    let presented = Mutex<[UNNotification]>([])
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        presented.withLock { $0.append(n) }
        return [.list, .banner]
    }
}
#endif

extension Registry {
    static var p10_extensions: [Check] {
        var c: [Check] = []
        #if os(iOS) || os(visionOS)
        // MARK: notification content / service extensions (the content extension, the action and the reporting UI
        // are on visionOS too)
        c.append(check("UserNotificationsUI", "content-extension-registered", timeout: 20) {
            let r = try p10Record("com.x86sim.test.sdkcov.ncontent")
            try expect(r.point == "com.apple.usernotifications.content-extension", "point \(r.point)")
            let a = r.nsExtension["NSExtensionAttributes"] as? [String: Any] ?? [:]
            try expect(a["UNNotificationExtensionCategory"] as? String == "sdkcov.content" && (a["UNNotificationExtensionInitialContentSizeRatio"] as? Double) == 0.5, "attributes \(a)")
            try expect(r.nsExtension["NSExtensionPrincipalClass"] as? String == "SDKCovNotificationContent", "principal \(String(describing: r.nsExtension["NSExtensionPrincipalClass"]))")
            // PlugInKit's view (what SpringBoard looks the extension up with) has the category too
            let (attrs, err) = p3Extension("com.x86sim.test.sdkcov.ncontent")
            try expect(attrs?["UNNotificationExtensionCategory"] as? String == "sdkcov.content", "NSExtension attributes \(String(describing: attrs)) \(err ?? "")")
            return "registered on \(r.point), category sdkcov.content, size ratio 0.5"
        })
        #endif
        #if os(iOS) || os(watchOS) || os(visionOS)
        c.append(check("UserNotifications", "service-extension-push", timeout: 150) {
            let r = try p10Record("com.x86sim.test.sdkcov.nservice")
            try expect(r.point == "com.apple.usernotifications.service" && r.nsExtension["NSExtensionPrincipalClass"] as? String == "SDKCovNotificationService", "point \(r.point), \(r.nsExtension)")
            let wait = Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0
            guard wait > 0 else { return "registered on \(r.point) (SDKCOV_INPUT_WAIT unset: no push awaited)" }
            // a remote notification with "mutable-content": 1 (the host sends one every few seconds while this waits:
            // inputs.sh push = x86sim push here, simctl push on the Mac). Apple's simulator delivers it as sent: its
            // SpringBoard does not hand a simulated push to the service extension (the extension never launches)
            let since = Date()
            let nc = UNUserNotificationCenter.current()
            let granted = try await nc.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
            let d = P10NotifDelegate(); let old = nc.delegate; nc.delegate = d
            defer { nc.delegate = old }
            func pushed() async -> [UNNotification] {
                (await nc.deliveredNotifications() + d.presented.withLock { $0 }).filter { $0.request.trigger is UNPushNotificationTrigger && $0.date >= since.addingTimeInterval(-1) }
            }
            var got: [UNNotification] = []
            let end = Date().addingTimeInterval(wait)
            while Date() < end {
                got = await pushed()
                if !got.isEmpty { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let first = got.first else { throw Fail("no remote notification delivered in \(Int(wait)) s (granted \(granted))") }
            // a few more pushes: the extension would have had its chance
            try await Task.sleep(for: .seconds(8))
            got = await pushed()
            nc.removeAllDeliveredNotifications()
            let titles = Set(got.map(\.request.content.title)), marks = p3Marks("nservice-receive", since: since)
            let trig = first.request.trigger as? UNPushNotificationTrigger
            try expect(titles == ["sdkcov push"] && got.allSatisfy { $0.request.content.userInfo["sdkcov-service"] == nil } && marks.isEmpty,
                       "\(got.count) pushes, titles \(titles), extension marks \(marks) (Apple's simulator: delivered as sent, the service extension never runs)")
            return "registered on \(r.point); \(got.count) pushes delivered as sent (mutable \(trig?.description.contains("mutableContent: YES") ?? false)), service extension not run"
        })

        #endif
        // MARK: File Provider UI action, IdentityLookup message filter + reporting UI
        #if os(iOS) || os(visionOS)
        c.append(check("FileProviderUI", "action-extension-registered", timeout: 20) {
            let r = try p10Record("com.x86sim.test.sdkcov.fpaction")
            try expect(r.point == "com.apple.fileprovider-actionsui", "point \(r.point)")
            let (attrs, err) = p3Extension("com.x86sim.test.sdkcov.fpaction")
            let acts = attrs?["NSExtensionFileProviderActions"] as? [[String: Any]] ?? []
            try expect(acts.count == 1 && acts[0]["NSExtensionFileProviderActionIdentifier"] as? String == "com.x86sim.test.sdkcov.action"
                       && acts[0]["NSExtensionFileProviderActionActivationRule"] as? String == "TRUEPREDICATE", "actions \(acts) \(err ?? "")")
            return "registered on \(r.point), action \(acts[0]["NSExtensionFileProviderActionName"] ?? "?")"
        })
        #endif
        #if os(iOS)
        c.append(check("IdentityLookup", "message-filter-extension-registered", timeout: 20) {
            let r = try p10Record("com.x86sim.test.sdkcov.msgfilter")
            try expect(r.point == "com.apple.identitylookup.message-filter" && r.nsExtension["NSExtensionPrincipalClass"] as? String == "SDKCovMessageFilter", "point \(r.point), \(r.nsExtension)")
            // PlugInKit hides the point from other hosts: Apple's simulator answers no extension and no error
            let (attrs, err) = p3Extension("com.x86sim.test.sdkcov.msgfilter")
            try expect(attrs == nil && err == "nil", "NSExtension lookup: \(String(describing: attrs)) \(err ?? "") (Apple's simulator: nil, no error)")
            return "registered on \(r.point); NSExtension lookup from the app: none"
        })
        #endif
        #if os(iOS) || os(visionOS)
        c.append(check("IdentityLookupUI", "classification-extension-registered", timeout: 20) {
            let r = try p10Record("com.x86sim.test.sdkcov.classify")
            try expect(r.point == "com.apple.identitylookup.classification-ui", "point \(r.point)")
            let a = r.nsExtension["NSExtensionAttributes"] as? [String: Any] ?? [:]
            try expect(a["ILClassificationExtensionSMSReportDestination"] as? String == "12345" && r.nsExtension["NSExtensionPrincipalClass"] as? String == "SDKCovClassification", "\(r.nsExtension)")
            let (attrs, err) = p3Extension("com.x86sim.test.sdkcov.classify")
            try expect(attrs == nil && err == "nil", "NSExtension lookup: \(String(describing: attrs)) \(err ?? "") (Apple's simulator: nil, no error)")
            return "registered on \(r.point), SMS report destination 12345; NSExtension lookup from the app: none"
        })

        #endif
        // MARK: App Clip: AppClips/sdkcovClip.app, installed after the app (run.sh / ref-mac.sh, as Xcode installs one)
        #if os(iOS)
        c.append(check("AppClip", "clip-installed-with-parent", timeout: 20) {
            guard let cls = NSClassFromString("LSApplicationRecord") else { throw Fail("no LSApplicationRecord") }
            let sel = NSSelectorFromString("initWithBundleIdentifier:allowPlaceholder:error:")
            typealias F = @convention(c) (AnyObject, Selector, NSString, Bool, UnsafeMutablePointer<NSError?>?) -> AnyObject?
            guard let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
                  let imp = class_getMethodImplementation(cls, sel) else { throw Fail("no LSApplicationRecord initializer") }
            let clip = Bundle.main.bundleURL.appendingPathComponent("AppClips/sdkcovClip.app")
            try expect(FileManager.default.fileExists(atPath: clip.path), "no AppClips/sdkcovClip.app in the app")
            var err: NSError?
            // (installing the full app removes an installed clip of it: the runner installs the clip after the app)
            guard let r = unsafeBitCast(imp, to: F.self)(alloc, sel, "com.x86sim.test.sdkcov.Clip" as NSString, false, &err) as? NSObject else {
                throw Fail("the App Clip is not installed: \(err.map(p3Err) ?? "no record") (run.sh / ref-mac.sh install AppClips/*.app after the app)")
            }
            var parents: [String] = [], meta = false
            if let ex = SDKCovCatch({
                meta = r.value(forKey: "appClipMetadata") != nil
                parents = r.value(forKeyPath: "appClipMetadata.parentApplicationIdentifiers") as? [String] ?? []
            }) { throw Fail("record raised \(ex[0]): \(ex[1])") }
            // Apple's simulator: an App Clip record whose parent is the app
            try expect(meta && parents == ["com.x86sim.test.sdkcov"], "App Clip metadata \(meta), parents \(parents)")
            return "com.x86sim.test.sdkcov.Clip installed as an App Clip, parent \(parents)"
        })
        #endif
        // MARK: ExtensionKit extensions on Apple's points (iOS)
        #if os(iOS)
        #if canImport(ExtensionFoundation)
        c.append(check("TranslationUIProvider", "extension-registered", timeout: 30) {
            try await p10AppleExtensionPoint("translator", "com.apple.public.translation-ui-provider")
        })
        c.append(check("HomeExtensions", "extension-registered", timeout: 30) {
            try await p10AppleExtensionPoint("home", "com.apple.Home.HomeExtension")
        })
        c.append(check("AccessoryTransportExtension", "extension-registered", timeout: 30) {
            try await p10AppleExtensionPoint("transport", "com.apple.accessory-transport-extension")
        })
        c.append(check("DeviceDiscoveryExtension", "extension-registered", timeout: 30) {
            try await p10AppleExtensionPoint("discovery", "com.apple.discovery-extension")
        })
        #if canImport(AccessoryNotifications)
        // AccessoryNotifications' notification forwarding: an accessory data provider extension with the
        // NotificationsForwarding capability (ext/DataProvider.swift). It runs only for an accessory paired through
        // AccessorySetupKit whose forwarding the user allowed: none in a simulator
        c.append(check("AccessoryNotifications", "forwarding-extension-registered", timeout: 30) {
            let since = Date()
            let r = try p10Record("com.x86sim.test.sdkcov.dataprovider")
            var caps: [String] = []
            if let ex = SDKCovCatch({
                if let info = r.raw.value(forKey: "infoDictionary") as? NSObject {
                    let s1 = NSSelectorFromString("objectForKey:ofClass:")
                    let a = info.responds(to: s1) ? info.perform(s1, with: "EXAppExtensionAttributes", with: NSDictionary.self)?.takeUnretainedValue() as? [String: Any] : nil
                    caps = a?["EXCapabilities"] as? [String] ?? []
                }
            }) { throw Fail("record raised \(ex[0]): \(ex[1])") }
            try expect(caps == ["AccessoryNotifications.NotificationsForwarding"] && NotificationsForwarding.featureID == "AccessoryNotifications.NotificationsForwarding",
                       "capabilities \(caps), featureID \(NotificationsForwarding.featureID)")
            let ans = try await p10AppleExtensionPoint("dataprovider", "com.apple.accessory-data-provider")
            try await Task.sleep(for: .seconds(2))
            let marks = p3Marks("dataprovider-launch", since: since)
            try expect(marks.isEmpty, "the data provider ran: \(marks)")
            return "\(ans); capability \(caps[0]); not launched (no paired accessory)"
        })
        #endif
        #endif
        #if canImport(AppMigrationKit)
        c.append(check("AppMigrationKit", "extension-tester", timeout: 60) {
            let since = Date()
            let r = try p10Record("com.x86sim.test.sdkcov.migration")
            try expect(r.point == "com.apple.app-migration", "point \(r.point)")
            // AppMigrationTester runs the app's migration extension (export, then import); from the app itself Apple's
            // simulator refuses to start it: extensionKit error 2 over RunningBoard's RBSServiceErrorDomain 1
            let t = try await AppMigrationTester(platform: .android)
            var ans = "exported"
            do { _ = try await t.exportController } catch {
                let n = error as NSError, u = n.userInfo[NSUnderlyingErrorKey] as? NSError
                ans = "\(n.domain) \(n.code) / \(u.map { "\($0.domain) \($0.code)" } ?? "-")"
            }
            try expect(ans == "com.apple.extensionKit.errorDomain 2 / RBSServiceErrorDomain 1", "exportController: \(ans) (Apple's simulator: com.apple.extensionKit.errorDomain 2 / RBSServiceErrorDomain 1)")
            let marks = p3Marks("migration-launch", since: since)
            try expect(marks.isEmpty, "the migration extension ran: \(marks)")
            return "registered on \(r.point); tester made, exportController \(ans)"
        })
        #endif
        #endif
        return c
    }
}
