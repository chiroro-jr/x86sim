// sdkcov P3: parental controls and browser engines. Screen Time's API family (FamilyControls, ManagedSettings(+UI),
// DeviceActivity(+ _DeviceActivity_SwiftUI), ScreenTime, PermissionKit + its SwiftUI / UIKit overlays) needs a
// Family Sharing child / the Family Controls entitlement, which Apple's simulator has neither of; BrowserEngineKit /
// BrowserEngineCore / BrowserKit need the browser entitlements and their extensions. Each check exercises the API as far
// as an ordinary app gets and asserts the answer Apple's simulator gives (ref-mac.sh); FileProviderUI's action
// controller without an extension context.
import Foundation
import AVFAudio
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FamilyControls) && os(iOS)
import FamilyControls
#endif
#if canImport(ManagedSettings) && (os(iOS) || os(tvOS))
import ManagedSettings
#endif
#if canImport(ManagedSettingsUI) && os(iOS)
import ManagedSettingsUI
#endif
#if canImport(DeviceActivity) && os(iOS)
import DeviceActivity
#endif
#if canImport(_DeviceActivity_SwiftUI) && os(iOS)
import _DeviceActivity_SwiftUI
#endif
#if canImport(ScreenTime) && os(iOS)
import ScreenTime
#endif
#if canImport(PermissionKit) && (os(iOS) || os(visionOS))
import PermissionKit
import _PermissionKit_SwiftUI
import _PermissionKit_UIKit
#endif
#if canImport(BrowserEngineKit) && os(iOS)
import BrowserEngineKit
#endif
#if canImport(BrowserEngineCore)
import BrowserEngineCore
#endif
#if canImport(BrowserKit) && os(iOS)
import BrowserKit
#endif
#if canImport(FileProviderUI) && (os(iOS) || os(visionOS))
import FileProviderUI
#endif

extension Registry {
    static var p3_family: [Check] {
        var c: [Check] = []

        // MARK: FamilyControls / DeviceActivity / ManagedSettings
        #if canImport(FamilyControls) && os(iOS)
        c.append(check("FamilyControls", "authorization-selection", timeout: 40) {
            let st = await onMain { AuthorizationCenter.shared.authorizationStatus }
            try expect(st == .notDetermined, "status \(st) (Apple's simulator: notDetermined)")
            #if os(iOS)
            let sel = FamilyActivitySelection(includeEntireCategory: true)
            let back = try JSONDecoder().decode(FamilyActivitySelection.self, from: JSONEncoder().encode(sel))
            try expect(back == sel && back.applicationTokens.isEmpty && back.includeEntireCategory, "selection round trip")
            // .individual authorization needs the com.apple.developer.family-controls entitlement: refused at once
            let r = P3Box<String>()
            Task { do { try await AuthorizationCenter.shared.requestAuthorization(for: .individual); r.set("authorized") } catch { r.set("\(error)") } }
            let ans = await r.wait(15) ?? "no answer in 15 s"
            #else
            let ans = "watchOS: requestAuthorization(for:) not used"
            #endif
            #if os(iOS)
            // Apple's simulator: FamilyControlsAgent does not answer (NSCocoaErrorDomain 4099)
            try expect(ans.contains("4099") || ans.contains("FamilyControls"), "individual request: \(ans) (Apple's simulator: 4099, no FamilyControlsAgent)")
            #endif
            return "status \(st), selection codable, individual request: \(ans.prefix(120))"
        })
        #endif
        #if canImport(DeviceActivity) && os(iOS)
        c.append(check("DeviceActivity", "start-monitoring-schedule", timeout: 30) {
            let center = DeviceActivityCenter()
            let name = DeviceActivityName("sdkcov")
            let sched = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0), intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true, warningTime: DateComponents(minute: 5))
            try expect(sched.repeats && sched.nextInterval != nil, "schedule next interval \(String(describing: sched.nextInterval))")
            let ev = DeviceActivityEvent(threshold: DateComponents(minute: 30))
            var r = "monitoring"
            #if os(iOS)
            do { try center.startMonitoring(name, during: sched, events: [DeviceActivityEvent.Name("sdkcov-30"): ev]) } catch { r = "\(error)" }
            #else
            _ = ev
            do { try center.startMonitoring(name, during: sched) } catch { r = "\(error)" }
            #endif
            let listed = center.activities.contains(name)
            // Apple's simulator: UsageTrackingAgent refuses an app without Family Controls authorization
            try expect(r.contains("unauthorized"), "startMonitoring: \(r) (Apple's simulator: unauthorized)")
            center.stopMonitoring([name])
            return "startMonitoring: \(r.prefix(100)); listed \(listed); after stop \(center.activities.count) activities"
        })
        #endif
        #if canImport(_DeviceActivity_SwiftUI) && os(iOS)
        c.append(check("_DeviceActivity_SwiftUI", "report-view-hosted", timeout: 30) {
            try await onMain { () throws -> String in
                let ctx = DeviceActivityReport.Context("sdkcov")
                let v = DeviceActivityReport(ctx, filter: DeviceActivityFilter(segment: .daily(during: DateInterval(start: Date().addingTimeInterval(-86400), end: Date()))))
                let host = UIHostingController(rootView: v.frame(width: 300, height: 200))
                let close = p3Show(host); defer { close() }
                host.view.layoutIfNeeded()
                try expect(host.view.bounds.width > 0, "hosted view \(host.view.bounds)")
                // the report's content comes from the app's DeviceActivityReport extension with Family Controls
                // authorization: neither here, so the hosted report shows nothing (what Apple's simulator gives)
                let kids = p8Subviews(host.view).map { "\(type(of: $0))" }
                // Apple's simulator: the ExtensionKit host view with its placeholder (no report extension runs)
                try expect(kids.contains("_EXHostView") && kids.last == "EXPlaceholderView", "report subviews \(kids) (Apple's simulator: _EXHostView with an EXPlaceholderView)")
                return "report \(ctx.rawValue) hosted \(Int(host.view.bounds.width))x\(Int(host.view.bounds.height)), subviews \(kids)"
            }
        })
        #endif
        #if canImport(ManagedSettings) && os(iOS)
        c.append(check("ManagedSettings", "store-write-read-clear", timeout: 30) {
            let st = ManagedSettingsStore(named: .init("sdkcov"))
            st.clearAllSettings()
            st.application.denyAppRemoval = true
            st.media.denyExplicitContent = true
            let after = (st.application.denyAppRemoval, st.media.denyExplicitContent)
            // Apple's simulator: no Family Controls authorization, so the store ignores the writes (read back nil)
            try expect(after.0 == nil && after.1 == nil, "written values read back \(String(describing: after)) (Apple's simulator: nil / nil)")
            st.clearAllSettings()
            let cleared = (st.application.denyAppRemoval, st.media.denyExplicitContent)
            try expect(cleared.0 == nil && cleared.1 == nil, "after clearAllSettings: \(cleared)")
            return "written read back \(String(describing: after.0)) / \(String(describing: after.1)); cleared nil"
        })
        #endif
        #if canImport(ManagedSettings) && os(tvOS)
        c.append(check("ManagedSettings", "tv-default-store-effective", timeout: 20) {
            // tvOS: only the default store's effective values, all unset on a device without Screen Time restrictions
            let st = ManagedSettingsStore()
            try expect(st.effectiveDenyExplicitContent == nil || st.effectiveDenyExplicitContent == false, "effectiveDenyExplicitContent \(String(describing: st.effectiveDenyExplicitContent))")
            return "effectiveDenyExplicitContent \(String(describing: st.effectiveDenyExplicitContent))"
        })
        #endif
        #if canImport(ManagedSettingsUI) && os(iOS)
        c.append(check("ManagedSettingsUI", "shield-configuration", timeout: 20) {
            let cfg = ShieldConfiguration(backgroundBlurStyle: .systemMaterial, backgroundColor: .systemBackground, icon: UIImage(systemName: "hourglass"),
                                          title: .init(text: "sdkcov", color: .label), subtitle: .init(text: "limited", color: .secondaryLabel),
                                          primaryButtonLabel: .init(text: "OK", color: .white), primaryButtonBackgroundColor: .systemBlue, secondaryButtonLabel: nil)
            try expect(cfg.title?.text == "sdkcov" && cfg.primaryButtonLabel?.text == "OK" && cfg.secondaryButtonLabel == nil, "configuration")
            // the data source's default answers (what a ShieldConfiguration extension that overrides nothing shows); the
            // shield itself is drawn only for an app a Family Controls-authorized store shields, none in the simulator
            let ds = ShieldConfigurationDataSource()
            let d = ds.configuration(shielding: Application(bundleIdentifier: "com.apple.mobilesafari"))
            let auth = await onMain { AuthorizationCenter.shared.authorizationStatus }
            try expect(d.title == nil && d.primaryButtonLabel == nil && d.icon == nil && auth == .notDetermined,
                       "default configuration title \(String(describing: d.title?.text)), button \(String(describing: d.primaryButtonLabel?.text)), authorization \(auth) (Apple's simulator: nil, nil, notDetermined)")
            return "configuration built; data source default: no title / button / icon; Family Controls \(auth)"
        })
        #endif
        #if canImport(ScreenTime) && os(iOS)
        c.append(check("ScreenTime", "web-history-webpage-controller", timeout: 30) {
            var h = "-"
            do {
                let hist = try STWebHistory(bundleIdentifier: "com.x86sim.test.sdkcov")
                let r = P3Box<String>()
                hist.fetchAllHistory { urls, e in r.set(e.map { "fetch \(p3Err($0))" } ?? "\(urls?.count ?? 0) URLs") }
                h = await r.wait(10) ?? "fetch: no answer in 10 s"
                hist.deleteAllHistory()
            } catch { h = "init \(p3Err(error))" }
            let w = try await onMain { () throws -> String in
                let vc = STWebpageController()
                vc.url = URL(string: "https://example.com/sdkcov"); vc.suppressUsageRecording = true
                try vc.setBundleIdentifier("com.x86sim.test.sdkcov")
                vc.loadViewIfNeeded()
                return "controller url \(vc.url?.host ?? "nil"), blocked \(vc.urlIsBlocked)"
            }
            try expect(h == "0 URLs", "STWebHistory fetchAllHistory: \(h) (Apple's simulator: 0 URLs)")
            return "history: \(h); \(w)"
        })
        #endif

        // MARK: PermissionKit (+ SwiftUI / UIKit overlays)
        #if canImport(PermissionKit) && (os(iOS) || os(visionOS))
        c.append(check("PermissionKit", "communication-question-ask", timeout: 40) {
            let h = CommunicationHandle(value: "sdkcov@example.com", kind: .emailAddress)
            let back = try JSONDecoder().decode(CommunicationHandle.self, from: JSONEncoder().encode(h))
            try expect(back == h, "handle round trip")
            let topic = CommunicationTopic(personInformation: [.init(handle: h, nameComponents: PersonNameComponents(givenName: "Ada"))], actions: [.message])
            let q = PermissionQuestion<CommunicationTopic>(communicationTopic: topic)
            let known = await CommunicationLimits.current.isKnownHandle(h)
            let vc = await onMain { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first }
            guard let vc else { throw Fail("no view controller") }
            let r = P3Box<String>()
            Task { @MainActor in do { try await AskCenter.shared.ask(q, in: vc); r.set("asked") } catch { r.set("\(error)") } }
            let ans = await r.wait(15) ?? "no answer in 15 s"
            try expect(ans == "asked" && !known, "known \(known), ask \(ans) (Apple's simulator: unknown handle, ask returns)")
            return "known handle \(known); ask: \(ans.prefix(120))"
        })
        c.append(check("_PermissionKit_SwiftUI", "communication-limits-button", timeout: 30) {
            try await onMain { () throws -> String in
                let q = PermissionQuestion<CommunicationTopic>(handle: CommunicationHandle(value: "+14085551234", kind: .phoneNumber))
                let v = CommunicationLimitsButton(question: q) { Text("Ask to talk") }.padding()
                let host = UIHostingController(rootView: v)
                let close = p3Show(host); defer { close() }
                let size = host.sizeThatFits(in: CGSize(width: 320, height: 200))
                try expect(size.width > 20 && size.height > 10, "button size \(size)")
                return "CommunicationLimitsButton \(Int(size.width))x\(Int(size.height))"
            }
        })
        c.append(check("_PermissionKit_UIKit", "ask-significant-update", timeout: 40) {
            let q = PermissionQuestion<SignificantAppUpdateTopic>(significantAppUpdateTopic: SignificantAppUpdateTopic(description: "sdkcov update"))
            let vc = await onMain { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first }
            guard let vc else { throw Fail("no view controller") }
            let r = P3Box<String>()
            Task { @MainActor in do { try await AskCenter.shared.ask(q, in: vc); r.set("asked") } catch { r.set("\(error)") } }
            let ans = await r.wait(15) ?? "no answer in 15 s"
            try expect(ans == "asked", "ask: \(ans) (Apple's simulator: returns)")
            return "ask (significant app update): \(ans.prefix(120))"
        })
        #endif

        // MARK: BrowserEngineKit / BrowserEngineCore / BrowserKit
        #if canImport(BrowserEngineKit) && os(iOS)
        c.append(check("BrowserEngineKit", "processes-without-entitlement", timeout: 60) {
            // an app without the web-browser-engine entitlements and extensions: each process launch fails
            func launch(_ f: @escaping () async throws -> Void) async -> String {
                let r = P3Box<String>()
                Task { do { try await f(); r.set("launched") } catch { r.set(p3Err(error)) } }
                return await r.wait(15) ?? "no answer in 15 s"
            }
            let web = await launch { let p = try await WebContentProcess(bundleIdentifier: nil, onInterruption: {}); p.invalidate() }
            let net = await launch { let p = try await NetworkingProcess(bundleIdentifier: nil, onInterruption: {}); p.invalidate() }
            let ren = await launch { let p = try await RenderingProcess(bundleIdentifier: nil, onInterruption: {}); p.invalidate() }
            // (LayerHierarchy() traps without the entitlement, on Apple's simulator too: not called)
            let scroll = await onMain { () -> String in let s = BEScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100)); return "scroll view \(s.frame.size)" }
            try expect(web != "launched" && net != "launched" && ren != "launched", "a browser process launched without the entitlement / extension: web \(web), networking \(net), rendering \(ren)")
            return "web \(web), networking \(net), rendering \(ren), \(scroll)"
        })
        #endif
        #if canImport(BrowserEngineCore) && os(iOS)
        c.append(check("BrowserEngineCore", "kevent-jit-restrict", timeout: 20) {
            // be_kevent is kevent for browser processes. JIT witness support is a CPU feature: 1 on Apple silicon (Apple's
            // simulator), not asserted
            let kq = kqueue()
            defer { close(kq) }
            var ch = kevent(ident: 1, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: 0, data: 10, udata: nil)
            var out = kevent()
            let n = be_kevent(kq, &ch, 1, &out, 1, 0)
            // be_memory_inline_jit_restrict_with_witness_supported is C-only (unavailable in Swift): through dlsym
            typealias F = @convention(c) () -> Int32
            let supported = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "be_memory_inline_jit_restrict_with_witness_supported").map { unsafeBitCast($0, to: F.self)() }.map(String.init) ?? "no symbol"
            // Apple's simulator: one event, the 10 ms one-shot timer (ident 1)
            try expect(n == 1 && out.ident == 1 && out.filter == Int16(EVFILT_TIMER), "be_kevent -> \(n) (errno \(errno)), ident \(out.ident), filter \(out.filter) (Apple's simulator: 1 timer event, ident 1)")
            return "be_kevent -> \(n) (errno \(n < 0 ? errno : 0)), timer event \(n == 1 ? "fired, ident \(out.ident)" : "-"), JIT witness supported \(supported)"
        })
        #endif
        #if canImport(BrowserEngineCore) && os(iOS)
        c.append(check("BrowserEngineCore", "audio-session-preferred-output", timeout: 20) {
            // BEAudioSession (iOS 26): a browser engine's output routing over an AVAudioSession
            let av = AVAudioSession.sharedInstance()
            try av.setCategory(.playback)
            try av.setActive(true)
            defer { try? av.setActive(false, options: .notifyOthersOnDeactivation) }
            let be = BEAudioSession(audioSession: av)
            let outs = be.availableOutputs
            let route = av.currentRoute.outputs.map(\.portType.rawValue)
            // Apple's iOS 27.2 simulator: the route is the speaker, but no output is offered for routing and none preferred
            try expect(route == ["Speaker"] && outs.isEmpty && be.preferredOutput == nil, "outputs \(outs.map(\.portType.rawValue)), route \(route), preferred \(String(describing: be.preferredOutput)) (Apple's simulator: none offered, route Speaker)")
            // clearing the preferred output calls AVAudioSession's setPreferredPersistentInputUIDs:outputUIDs:error:, which
            // the simulator's AVAudioSession lacks: NSInvalidArgumentException (unrecognized selector) on Apple's too
            var err = "none"
            let x = SDKCovCatch { do { try be.setPreferredOutput(nil) } catch { err = "\((error as NSError).domain) \((error as NSError).code)" } }
            try expect(x?.first == "NSInvalidArgumentException" && (x?.last ?? "").contains("setPreferredPersistentInputUIDs:outputUIDs:error:"), "setPreferredOutput(nil): \(x ?? ["no exception", err]) (Apple's simulator: unrecognized selector setPreferredPersistentInputUIDs:outputUIDs:error:)")
            return "no output offered, route \(route); setPreferredOutput(nil): \(x?.first ?? "no exception, error \(err)")"
        })
        #endif
        #if canImport(BrowserKit) && os(iOS)
        c.append(check("BrowserKit", "data-exchange-types", timeout: 20) {
            // BEAvailability.isEligible(for:) raises in the simulator (Apple's too: its XPC proxy lacks
            // isEligibleForContext:completionHandler:, NSInvalidArgumentException): the data exchange types instead
            let ex = BEBrowserDataExportManager.userActivityType, im = BEBrowserDataImportManager.userActivityType
            try expect(!ex.isEmpty && !im.isEmpty && ex != im, "activity types \(ex) / \(im)")
            return "export \(ex) (\(BEBrowserDataExportManager.exportTokenUserInfoKey)), import \(im) (\(BEBrowserDataImportManager.importTokenUserInfoKey))"
        })
        #endif

        // MARK: FileProviderUI
        #if canImport(FileProviderUI) && (os(iOS) || os(visionOS))
        c.append(check("FileProviderUI", "action-extension-controller", timeout: 20) {
            await onMain { () -> String in
                final class VC: FPUIActionExtensionViewController {
                    var prepared: [String] = []
                    override func prepare(forError error: Error) { prepared.append("error") }
                    override func prepare(forAction id: String, itemIdentifiers: [NSFileProviderItemIdentifier]) { prepared.append(id) }
                }
                let vc = VC(); vc.loadViewIfNeeded()
                vc.prepare(forAction: "com.x86sim.sdkcov.action", itemIdentifiers: [.rootContainer])
                return "action controller loaded \(vc.isViewLoaded), prepared \(vc.prepared)"
            }
        })
        #endif
        return c
    }
}
