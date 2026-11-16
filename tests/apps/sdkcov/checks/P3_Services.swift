// sdkcov P3: system services. TipKit rules / events / parameters evaluated by the datastore and the tip views; CallKit
// incoming + outgoing calls through callservicesd; PushKit / PushToTalk without their entitlements; MetricKit log
// handles, signposts and launch tasks; BackgroundTasks' continued processing; BackgroundAssets' asset packs;
// UserNotifications on tvOS (badge) and UserNotificationsUI; StateReporting, RelevanceKit, LinkSecurity,
// DeclaredAgeRange ports; AppClip, AppMigrationKit, SystemExtensions, TelephonyMessagingKit, BusinessChat,
// AccessoryLiveActivities, AlarmKit. Where Apple's simulator cannot do the job (no entitlement, no carrier, no
// family), the check asserts the answer Apple's simulator gives (ref-mac.sh), so x86Sim has to give the same one.
import Foundation
import Synchronization
import SwiftUI
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(TipKit)
import TipKit
#endif
#if canImport(CallKit) && !os(tvOS)
import CallKit
#endif
#if canImport(PushKit) && !os(tvOS)
import PushKit
#endif
#if canImport(PushToTalk) && os(iOS)
import PushToTalk
import AVFAudio
#endif
#if canImport(MetricKit) && (os(iOS) || os(visionOS))
import MetricKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(BackgroundAssets) && !os(watchOS)
import BackgroundAssets
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UserNotificationsUI) && (os(iOS) || os(visionOS))
import UserNotificationsUI
#endif
#if canImport(StateReporting)
import StateReporting
#endif
#if canImport(RelevanceKit)
import RelevanceKit
import CoreLocation
#endif
#if canImport(LinkSecurity)
import LinkSecurity
#endif
#if canImport(DeclaredAgeRange) && os(iOS)
import DeclaredAgeRange
#endif
#if canImport(AppClip) && os(iOS)
import AppClip
import CoreLocation
#endif
#if canImport(AppMigrationKit) && os(iOS)
import AppMigrationKit
#endif
#if canImport(SystemExtensions) && os(iOS)
import SystemExtensions
#endif
#if canImport(TelephonyMessagingKit) && os(iOS)
import TelephonyMessagingKit
#endif
#if canImport(BusinessChat) && os(iOS)
import BusinessChat
#endif
#if canImport(AccessoryLiveActivities) && os(iOS)
import AccessoryLiveActivities
#endif
#if canImport(AlarmKit) && os(iOS)
import AlarmKit
import ActivityKit
#endif

#if canImport(TipKit)
/// a tip shown once its parameter is true and its event was donated twice (#Rule spelled out: the Linux toolchain has
/// no TipKit macros). Per run ids: the datastore keeps donations between runs.
struct P3RuleTip: Tip {
    static let run = UUID().uuidString.prefix(8)
    static var flag = Tips.Parameter<Bool>(P3RuleTip.self, "p3flag-\(run)", false)
    static let opened = Tips.Event(id: "p3opened-\(run)")
    var id: String { "p3rule-\(P3RuleTip.run)" }
    var title: Text { Text("sdkcov rule tip") }
    var message: Text? { Text("shown after two donations") }
    var rules: [Tips.Rule] {
        Tips.Rule(P3RuleTip.flag) { PredicateExpressions.build_Equal(lhs: $0, rhs: PredicateExpressions.build_Arg(true)) }
        Tips.Rule(P3RuleTip.opened) {
            PredicateExpressions.build_Comparison(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_KeyPath(root: $0, keyPath: \.donations), keyPath: \.count),
                                                  rhs: PredicateExpressions.build_Arg(2), op: .greaterThanOrEqual)
        }
    }
}
struct P3PlainTip: Tip {
    var id: String { "p3plain" }
    var title: Text { Text("sdkcov plain tip") }
    var message: Text? { Text("no rules") }
}
#endif

#if canImport(CallKit) && !os(tvOS)
/// a CXProvider delegate that fulfils every action and records it
final class P3CallDelegate: NSObject, CXProviderDelegate, @unchecked Sendable {
    let lock = NSLock(); var actions: [String] = []
    func note(_ s: String) { lock.withLock { actions.append(s) } }
    var seen: [String] { lock.withLock { actions } }
    func providerDidReset(_ provider: CXProvider) { note("reset") }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        note("start"); provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil); action.fulfill()
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { note("answer"); action.fulfill() }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) { note("end"); action.fulfill() }
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { note("hold \(action.isOnHold)"); action.fulfill() }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) { note("mute \(action.isMuted)"); action.fulfill() }
}
#endif

extension Registry {
    static var p3_services: [Check] {
        var c: [Check] = []

        // MARK: TipKit
        #if canImport(TipKit)
        c.append(check("TipKit", "rules-events-parameters", timeout: 60) {
            // the datastore may be configured already (func:TipKit.configure): then this is a no-op
            do { try Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)]) }
            catch { _ = error }
            let tip = P3RuleTip()
            func st() -> String { "\(tip.status)" }
            _ = await p3Wait(5) { tip.status == .pending }
            let s0 = st()
            try expect(!tip.shouldDisplay, "shown before its rules hold: \(s0)")
            // the parameter alone is not enough
            P3RuleTip.flag.wrappedValue = true
            try await Task.sleep(for: .milliseconds(500))
            try expect(!tip.shouldDisplay, "shown with the parameter only: \(st())")
            await P3RuleTip.opened.donate()
            try await Task.sleep(for: .milliseconds(300))
            let one = tip.shouldDisplay
            await P3RuleTip.opened.donate()
            let shown = await p3Wait(10) { tip.shouldDisplay }
            let donations = P3RuleTip.opened.donations.count
            try expect(!one && shown, "after 1 donation shown \(one), after 2 \(shown) (status \(st()), \(donations) donations)")
            tip.invalidate(reason: .actionPerformed)
            let inval = await p3Wait(10) { tip.status == .invalidated(.actionPerformed) }
            try expect(inval && !tip.shouldDisplay, "after invalidate: \(st())")
            // a tip without rules is available at once
            let plain = P3PlainTip()
            let plainOK = await p3Wait(10) { plain.shouldDisplay }
            return "\(s0) -> available after flag + 2 donations (\(donations)) -> \(st()); plain tip available \(plainOK)"
        })
        #if canImport(UIKit) && (os(iOS) || os(visionOS))
        c.append(check("TipKit", "tip-ui-view-render", timeout: 40) {
            do { try Tips.configure() } catch { _ = error }
            return try await onMain { () throws -> String in
                let v = TipUIView(P3PlainTip(), arrowEdge: .top)
                let vc = UIViewController(); vc.view.backgroundColor = .white
                vc.view.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 20), v.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -20), v.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 40)])
                let close = p3Show(vc); defer { close() }
                vc.view.layoutIfNeeded()
                let size = v.systemLayoutSizeFitting(CGSize(width: vc.view.bounds.width - 40, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                try expect(size.height > 20 && v.bounds.width > 100, "tip view \(v.bounds), fitting \(size)")
                let popover = TipUIPopoverViewController(P3PlainTip(), sourceItem: v)
                return "TipUIView \(Int(v.bounds.width))x\(Int(v.bounds.height)), fitting height \(Int(size.height)); popover \(type(of: popover))"
            }
        })
        #endif
        #endif

        // MARK: CallKit: an incoming call reported to the system, answered and ended; an outgoing call
        #if canImport(CallKit) && !os(tvOS)
        c.append(check("CallKit", "incoming-outgoing-calls", timeout: 60) {
            let cfg = CXProviderConfiguration()
            cfg.supportsVideo = false; cfg.maximumCallsPerCallGroup = 1; cfg.supportedHandleTypes = [.generic]
            let d = P3CallDelegate()
            let provider = CXProvider(configuration: cfg)
            provider.setDelegate(d, queue: nil)
            defer { provider.invalidate() }
            let ctl = CXCallController(queue: .main)
            let incoming = UUID()
            let up = CXCallUpdate(); up.remoteHandle = CXHandle(type: .generic, value: "sdkcov"); up.localizedCallerName = "sdkcov"; up.hasVideo = false
            var steps: [String] = []
            do { try await provider.reportNewIncomingCall(with: incoming, update: up); steps.append("incoming reported") }
            catch { steps.append("incoming \(p3Err(error))") }
            if steps.last == "incoming reported" {
                let listed = await p3Wait(5) { ctl.callObserver.calls.contains { $0.uuid == incoming } }
                steps.append("observer \(listed)")
                do { try await ctl.request(CXTransaction(action: CXEndCallAction(call: incoming))); steps.append("end requested") }
                catch { steps.append("end \(p3Err(error))") }
                _ = await p3Wait(5) { d.seen.contains("end") }
            }
            let outgoing = UUID()
            do {
                try await ctl.request(CXTransaction(action: CXStartCallAction(call: outgoing, handle: CXHandle(type: .generic, value: "sdkcov-out"))))
                steps.append("start requested")
                _ = await p3Wait(5) { d.seen.contains("start") }
                try await ctl.request(CXTransaction(action: CXSetMutedCallAction(call: outgoing, muted: true)))
                try await ctl.request(CXTransaction(action: CXEndCallAction(call: outgoing)))
                steps.append("muted + ended")
            } catch { steps.append("outgoing \(p3Err(error))") }
            _ = await p3Wait(5) { ctl.callObserver.calls.isEmpty }
            steps.append("delegate \(d.seen), calls left \(ctl.callObserver.calls.count)")
            #if os(watchOS) || os(visionOS)
            // Apple's watchOS / visionOS 27.2 simulators: callservicesd refuses both (incoming CXErrorCodeIncomingCallError 0,
            // the transaction CXErrorCodeRequestTransactionError 1 unentitled)
            try expect(steps.first == "incoming com.apple.CallKit.error 0" && steps.contains("outgoing com.apple.CallKit.error.requesttransaction 1"), steps.joined(separator: "; ") + " (Apple's watchOS / visionOS simulator: incoming error 0, outgoing requesttransaction 1)")
            return steps.joined(separator: "; ")
            #endif
            // Apple's simulator: callservicesd takes both calls; the provider performs start / mute / end
            try expect(steps.contains("incoming reported") && steps.contains("observer true") && steps.contains("muted + ended") && d.seen.contains("start") && d.seen.contains("end"), steps.joined(separator: "; "))
            return steps.joined(separator: "; ")
        })
        #endif

        // MARK: PushKit / PushToTalk
        #if canImport(PushKit) && !os(tvOS)
        c.append(check("PushKit", "voip-credentials", timeout: 30) {
            final class D: NSObject, PKPushRegistryDelegate {
                let token = P3Box<String>(), invalid = P3Box<String>()
                func pushRegistry(_ r: PKPushRegistry, didUpdate cred: PKPushCredentials, for type: PKPushType) { token.set("\(type.rawValue) \(cred.token.count) B") }
                func pushRegistry(_ r: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) { invalid.set(type.rawValue) }
                func pushRegistry(_ r: PKPushRegistry, didReceiveIncomingPushWith p: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) { completion() }
            }
            let d = D()
            let reg = await onMain { () -> PKPushRegistry in let r = PKPushRegistry(queue: .main); r.delegate = d; r.desiredPushTypes = [.voIP]; return r }
            let tok = await d.token.wait(10)
            let cached = await onMain { reg.pushToken(for: .voIP)?.count }
            await onMain { reg.desiredPushTypes = [] }
            // Apple's simulator gets its 80-byte VoIP token from the real APNs sandbox (its apsd keeps a connection to
            // *-courier.sandbox.push.apple.com): none on a fresh device whose apsd is not connected yet
            try skipIf(tok == nil, "no VoIP token in 10 s (apsd without an APNs sandbox connection; Apple's fresh simulator device the same)")
            try expect(cached != nil, "credentials delivered but pushToken(for:) nil")
            return "VoIP token \(tok ?? "none in 10 s"), cached \(cached.map { "\($0) B" } ?? "nil"), invalidated \(d.invalid.value ?? "-")"
        })
        #endif
        #if canImport(PushToTalk) && os(iOS)
        c.append(check("PushToTalk", "channel-manager", timeout: 30) {
            final class D: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate {
                func channelDescriptor(restoredChannelUUID: UUID) -> PTChannelDescriptor { PTChannelDescriptor(name: "sdkcov", image: nil) }
                func channelManager(_ m: PTChannelManager, didJoinChannel u: UUID, reason: PTChannelJoinReason) {}
                func channelManager(_ m: PTChannelManager, didLeaveChannel u: UUID, reason: PTChannelLeaveReason) {}
                func channelManager(_ m: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {}
                func channelManager(_ m: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource) {}
                func channelManager(_ m: PTChannelManager, receivedEphemeralPushToken t: Data) {}
                func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult { .leaveChannel }
                func channelManager(_ m: PTChannelManager, didActivate s: AVAudioSession) {}
                func channelManager(_ m: PTChannelManager, didDeactivate s: AVAudioSession) {}
            }
            let d = D()
            let desc = PTChannelDescriptor(name: "sdkcov", image: nil)
            try expect(desc.name == "sdkcov", "descriptor")
            let r = P3Box<String>()
            Task { do { let m = try await PTChannelManager.channelManager(delegate: d, restorationDelegate: d); r.set("manager, active channel \(String(describing: m.activeChannelUUID))") } catch { r.set("error \(p3Err(error))") } }
            let got = await r.wait(15) ?? "no answer in 15 s"
            // "Push-to-Talk API is not available in the simulator": instantiation error 1, on Apple's too
            try expect(got.hasPrefix("error com.apple.pushtotalk.instantiation"), "channelManager: \(got) (Apple's simulator: com.apple.pushtotalk.instantiation 1)")
            return got
        })
        #endif

        // MARK: FSEvents (CoreServices): a stream on a temporary directory. A simulator's FSEvents is the Mac's fseventsd
        // (com.apple.FSEvents); x86Sim's host/fseventsd stands in for it. No FSEvents header in the device SDKs: dlsym.
        c.append(check("CoreServices", "fsevents-stream-file-events", timeout: 90) {
            try await p3FSEvents()
        })

        // MARK: MetricKit
        #if canImport(MetricKit) && (os(iOS) || os(visionOS))
        c.append(check("MetricKit", "log-handles-signposts-launch-task", timeout: 30) {
            let legacy = MXMetricManager.makeLogHandle(category: "sdkcov-legacy")
            mxSignpost(.event, log: legacy, name: "sdkcov-event")
            mxSignpost(.begin, log: legacy, name: "sdkcov-interval"); mxSignpost(.end, log: legacy, name: "sdkcov-interval")
            // a launch task can only be extended while the app launches: long after launch it is refused
            var ext = "extended", fin = "finished"
            do { try MXMetricManager.extendLaunchMeasurement(forTaskID: MXLaunchTaskID(rawValue: "sdkcov")) } catch { ext = p3Err(error) }
            do { try MXMetricManager.finishExtendedLaunchMeasurement(forTaskID: MXLaunchTaskID(rawValue: "sdkcov")) } catch { fin = p3Err(error) }
            #if os(iOS)
            // iOS 27's MetricManager (Swift): a log handle and a launch task tracked after launch (past its deadline)
            let h = MetricManager.logHandle(category: "sdkcov")
            os_signpost(.begin, log: h, name: "sdkcov-interval"); os_signpost(.end, log: h, name: "sdkcov-interval")
            let mm = MetricManager()
            let tracked = P3Box<String>()
            let v = await onMain { mm.trackLaunchTask(id: "sdkcov-task", onTrackingError: { tracked.set("tracking error \($0.reason)") }) { 42 } }
            try expect(v == 42, "trackLaunchTask result \(v)")
            let track = "trackLaunchTask \(tracked.value ?? "no error"), state domains \(mm.enabledStateReportingDomains.count)"
            #else
            let track = "no MetricManager on visionOS"
            #endif
            let past = MXMetricManager.shared.pastPayloads.count
            // Apple's simulator: extending after launch is past the deadline (2), finishing a task never extended is unknown (4)
            try expect(ext == "MXErrorDomain 2" && fin == "MXErrorDomain 4", "extend \(ext), finish \(fin) (Apple's simulator: MXErrorDomain 2, 4)")
            return "extend \(ext), finish \(fin), \(track), \(past) past payloads"
        })
        #endif

        // MARK: BackgroundTasks: continued processing (iOS 26)
        #if canImport(BackgroundTasks) && os(iOS)
        c.append(check("BackgroundTasks", "continued-processing-request", timeout: 20) {
            let id = "com.x86sim.test.sdkcov.continued"
            let r = BGContinuedProcessingTaskRequest(identifier: id, title: "sdkcov", subtitle: "continued processing")
            r.strategy = .fail
            try expect(r.identifier == id && r.title == "sdkcov", "request")
            // an identifier not in BGTaskSchedulerPermittedIdentifiers / no handler registered: submit refuses it
            var e = "submitted"
            do { try BGTaskScheduler.shared.submit(r) } catch { e = p3Err(error) }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
            let pending = await BGTaskScheduler.shared.pendingTaskRequests().count
            return "submit \(e); supported resources \(BGTaskScheduler.supportedResources.rawValue); \(pending) pending"
        })
        #endif

        // MARK: BackgroundAssets: asset packs (needs BAAppGroupID, build.sh)
        #if canImport(BackgroundAssets) && (os(iOS) || os(visionOS) || os(tvOS))
        c.append(check("BackgroundAssets", "asset-pack-status-download", timeout: 40) {
            try skipIf(Bundle.main.object(forInfoDictionaryKey: "BAAppGroupID") == nil, "no BAAppGroupID in Info.plist (AssetPackManager traps without it)")
            let m = AssetPackManager.shared
            try expect(!m.assetPackIsAvailableLocally(withID: "sdkcov-none"), "unknown pack available locally")
            var all = "-"
            do { all = "\(try await m.allAssetPacks.count) packs" } catch { all = p3Err(error) }
            var one = "-"
            do { let p = try await m.assetPack(withID: "sdkcov-none"); one = "pack \(p.id)" } catch { one = p3Err(error) }
            var st = "-"
            do { st = "status \(try await m.status(ofAssetPackWithID: "sdkcov-none"))" } catch { st = p3Err(error) }
            // Apple's simulator: the managed asset pack service answers each with its error (no App Store hosting)
            try expect(!all.hasSuffix("packs") && !one.hasPrefix("pack ") && !st.hasPrefix("status "), "all \(all), unknown pack \(one), \(st): an answer without App Store hosting")
            return "all \(all); unknown pack \(one); \(st)"
        })
        #endif

        // MARK: UserNotifications on tvOS: badge-only notifications
        #if canImport(UserNotifications) && os(tvOS)
        c.append(check("UserNotifications", "tv-badge-request-model", timeout: 30) {
            // tvOS notifications are badges only. requestAuthorization would show an alert that never goes away
            // unattended (Apple's simulator too): the request model, and an add while not authorized
            let c = UNUserNotificationCenter.current()
            let st = await c.notificationSettings()
            let ct = UNMutableNotificationContent(); ct.badge = 3
            let trig = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
            try expect(trig.nextTriggerDate().map { $0.timeIntervalSinceNow > 3500 } == true && ct.badge == 3, "trigger / content")
            let req = UNNotificationRequest(identifier: "sdkcov-tv-badge", content: ct, trigger: trig)
            var add = "added"
            do { try await c.add(req) } catch { add = p3Err(error) }
            c.removePendingNotificationRequests(withIdentifiers: [req.identifier])
            if st.authorizationStatus == .notDetermined || st.authorizationStatus == .denied {
                try expect(add != "added", "add while not authorized succeeded (Apple's simulator refuses it)")
            }
            return "authorization \(st.authorizationStatus.rawValue), badge setting \(st.badgeSetting.rawValue), add \(add)"
        })
        #endif
        #if canImport(UserNotificationsUI) && (os(iOS) || os(visionOS))
        c.append(check("UserNotificationsUI", "content-extension-controller", timeout: 20) {
            final class VC: UIViewController, UNNotificationContentExtension {
                var got: [String] = []
                func didReceive(_ notification: UNNotification) { got.append(notification.request.identifier) }
                var mediaPlayPauseButtonType: UNNotificationContentExtensionMediaPlayPauseButtonType { .overlay }
                var mediaPlayPauseButtonFrame: CGRect { CGRect(x: 0, y: 0, width: 44, height: 44) }
            }
            return await onMain { () -> String in
                let vc = VC(); vc.loadViewIfNeeded()
                let types: [UNNotificationContentExtensionMediaPlayPauseButtonType] = [.none, .default, .overlay]
                return "content extension controller \(vc.isViewLoaded), button \(vc.mediaPlayPauseButtonType.rawValue) \(vc.mediaPlayPauseButtonFrame.size), types \(types.map(\.rawValue)), extension context \(vc.extensionContext == nil ? "nil (not in an extension)" : "set")"
            }
        })
        #endif

        // MARK: StateReporting / RelevanceKit / LinkSecurity / DeclaredAgeRange ports
        #if canImport(StateReporting) && os(iOS)
        c.append(check("StateReporting", "reporter-metadata-ios") {
            let vals: [ReportableMetadataValue] = [.init("s"), .init(42), .init(true), .init(1.5)]
            let back = try JSONDecoder().decode([ReportableMetadataValue].self, from: JSONEncoder().encode(vals))
            try expect(back == vals, "codable round trip")
            let rep = StateReporter<Never, Never>.reporter(for: "com.x86sim.test.sdkcov")
            try expect(rep.domain == "com.x86sim.test.sdkcov", "domain \(rep.domain)")
            rep.reportTransition(to: "checking"); rep.reportTransition(to: nil)
            return "\(vals.count) values, 2 transitions"
        })
        #endif
        #if canImport(RelevanceKit)
        c.append(check("RelevanceKit", "contexts-port", timeout: 20) {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let a = RelevantContext.date(now)
            #if os(visionOS)
            let cs: [RelevantContext] = [a, .date(from: now, to: now.addingTimeInterval(3600))]
            #else
            let r = CLCircularRegion(center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.0), radius: 100, identifier: "sdkcov")
            let cs: [RelevantContext] = [a, .date(from: now, to: now.addingTimeInterval(3600)), .location(r)]
            #endif
            #if !os(tvOS)
            let extra: [RelevantContext] = [.date(interval: DateInterval(start: now, duration: 60), kind: .default), .location(inferred: .home), .hardware(headphones: .connected)]
            #else
            let extra: [RelevantContext] = []
            #endif
            return "\(cs.count + extra.count) contexts (\(String(describing: a).prefix(60)))"
        })
        #endif
        #if canImport(LinkSecurity) && !os(tvOS)
        c.append(check("LinkSecurity", "flag-urls-port", timeout: 30) {
            // as func:LinkSecurity.flag-urls on tvOS: the flagged-URL store is imagent's, absent from the simulator runtimes
            let u = URL(string: "https://example.com/sdkcov-\(UUID().uuidString)")!
            let r = P3Box<Bool>()
            Thread.detachNewThread { LSLinkSecurityManager.shared.checkIsFlaggedURL(u) { r.set($0) } }
            guard let f = await r.wait(10) else { throw Skip("no answer from imagent's EnhancedLinkSecurityStore in 10 s (no imagent in the simulator runtime; Apple's simulator the same)") }
            try expect(!f, "a fresh URL is flagged")
            return "flagged \(f)"
        })
        #endif
        #if canImport(DeclaredAgeRange) && os(iOS)
        c.append(check("DeclaredAgeRange", "request-age-range", timeout: 30) {
            // the age range comes from the account's family settings: Apple's simulator has none
            let r = P3Box<String>()
            let vc = await onMain { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first }
            guard let vc else { throw Fail("no view controller") }
            Task { @MainActor in
                do { let resp = try await AgeRangeService.shared.requestAgeRange(ageGates: 13, 16, in: vc); r.set("\(resp)") }
                catch { r.set("error \(p3Err(error))") }
            }
            guard let got = await r.wait(10) else { throw Skip("requestAgeRange does not answer in 10 s (as isEligibleForAgeFeatures: Apple's simulator never answers)") }
            return got
        })
        #endif

        // MARK: small iOS frameworks: their answer outside their real setting
        #if canImport(AppClip) && os(iOS)
        c.append(check("AppClip", "activation-payload", timeout: 20) {
            // a full app's user activity carries no App Clip activation payload
            let ua = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            ua.webpageURL = URL(string: "https://example.com/sdkcov")
            try expect(ua.appClipActivationPayload == nil, "a payload on a plain user activity")
            return "no activation payload outside an App Clip invocation; \(String(describing: APActivationPayloadError.Code.disallowed.rawValue)) = disallowed"
        })
        #endif
        #if canImport(AppMigrationKit) && os(iOS)
        c.append(check("AppMigrationKit", "status-identifiers", timeout: 20) {
            let st = MigrationStatus.importStatus
            let id = MigrationAppIdentifier(storeIdentifier: .googlePlay, bundleIdentifier: "com.example.sdkcov", platform: .android)
            let plat = try JSONDecoder().decode(MigrationPlatform.self, from: JSONEncoder().encode(MigrationPlatform.android))
            try expect(plat == .android, "platform codable")
            let req = ResourcesImportRequest(sourceAppIdentifier: id, sourceVersion: "1.0")
            _ = req
            return "import status \(String(describing: st)), platform \(MigrationPlatform.android.rawValue), store \(MigrationAppIdentifier.StoreIdentifier.googlePlay.rawValue)"
        })
        #endif
        #if canImport(SystemExtensions) && os(iOS)
        c.append(check("SystemExtensions", "workspace", timeout: 20) {
            let w = OSSystemExtensionsWorkspace.shared
            var r = "-"
            do { r = "\(try w.systemExtensions(forApplicationWithBundleID: "com.x86sim.test.sdkcov").count) extensions" } catch { r = p3Err(error) }
            return "workspace: \(r)"
        })
        #endif
        #if canImport(TelephonyMessagingKit) && os(iOS)
        c.append(check("TelephonyMessagingKit", "handles-content-codable", timeout: 20) {
            let h = RCSHandle.phoneNumber("+14085551234")
            try expect(h != nil, "phone handle")
            let back = try JSONDecoder().decode(RCSHandle.self, from: JSONEncoder().encode(h!))
            try expect(back == h!, "handle round trip")
            let mms = MMSHandle(phoneNumber: "+14085551234")
            let part = MMSPartContent(data: Data("hi".utf8), contentType: .plainText, contentID: "1", disposition: .inline, fileName: "a.txt")
            let d = try JSONEncoder().encode(part)
            try expect(try JSONDecoder().decode(MMSPartContent.self, from: d).data == Data("hi".utf8), "part round trip")
            return "\(h!), MMS \(mms.phoneNumber), part \(d.count) B"
        })
        #endif
        #if canImport(BusinessChat) && os(iOS)
        c.append(check("BusinessChat", "chat-button", timeout: 20) {
            try await onMain { () throws -> String in
                let b = BCChatButton(style: .light), d = BCChatButton(style: .dark)
                let s = b.intrinsicContentSize
                b.frame = CGRect(origin: .zero, size: CGSize(width: max(s.width, 200), height: max(s.height, 44))); b.layoutIfNeeded()
                try expect(b.bounds.width > 0 && d.isEnabled, "button \(b.frame)")
                let params: [BCChatAction.Parameter: String] = [.intent: "sdkcov", .group: "g", .body: "hello"]
                return "button intrinsic \(s), \(params.count) intent parameters"
            }
        })
        #endif
        #if canImport(AccessoryLiveActivities) && os(iOS)
        c.append(check("AccessoryLiveActivities", "feature-results", timeout: 20) {
            let all = AccessoryAuthorizationResult.allCases.map(\.description)
            let fid = LiveActivityForwarding.featureID
            try expect(!all.isEmpty && !fid.isEmpty, "results \(all), feature \(fid)")
            return "feature \(fid), results \(all)"
        })
        #endif
        #if canImport(AlarmKit) && os(iOS)
        c.append(check("AlarmKit", "authorization-alarms-updates", timeout: 20) {
            // scheduling asks for authorization (a system prompt) when not determined: only the state and the lists
            let m = AlarmManager.shared
            let st = m.authorizationState
            let alarms = try m.alarms
            let first = P3Box<Int>()
            let t = Task { for await a in m.alarmUpdates { first.set(a.count); break } }
            let n = await first.wait(5); t.cancel()
            let cd = Alarm.CountdownDuration(preAlert: 10, postAlert: 5)
            try expect(cd.preAlert == 10 && cd.postAlert == 5, "countdown duration")
            return "authorization \(st), \(alarms.count) alarms, first update \(n.map { "\($0) alarms" } ?? "none in 5 s")"
        })
        #endif
        return c
    }
}

// MARK: - FSEvents (looked up in CoreServices: the device SDKs have no FSEvents header)
private typealias P3FSECallback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?,
    UnsafePointer<UInt32>?, UnsafePointer<UInt64>?) -> Void
/// what a stream delivered: (path, flags, id)
private final class P3FSEEvents: @unchecked Sendable {
    private let lock = NSLock(); private var evs: [(String, UInt32, UInt64)] = []
    func add(_ e: (String, UInt32, UInt64)) { lock.withLock { evs.append(e) } }
    var all: [(String, UInt32, UInt64)] { lock.withLock { evs } }
    /// the flags a path got, all events together
    func flags(_ path: String) -> UInt32 { all.filter { $0.0 == path }.reduce(0) { $0 | $1.1 } }
}
private func p3FSEFlagNames(_ f: UInt32) -> String {
    let n: [(UInt32, String)] = [(0x1, "mustScan"), (0x2, "userDropped"), (0x4, "kernelDropped"), (0x10, "historyDone"),
        (0x20, "rootChanged"), (0x100, "created"), (0x200, "removed"), (0x400, "inodeMeta"), (0x800, "renamed"),
        (0x1000, "modified"), (0x2000, "finderInfo"), (0x4000, "changeOwner"), (0x8000, "xattr"), (0x10000, "file"),
        (0x20000, "dir"), (0x40000, "symlink"), (0x80000, "ownEvent")]
    let s = n.filter { f & $0.0 != 0 }.map(\.1)
    return s.isEmpty ? "none" : s.joined(separator: "|")
}
private func p3FSEvents() async throws -> String {
    guard let cs = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW) else { throw Fail("no CoreServices") }
    func fn<T>(_ name: String, _: T.Type) throws -> T {
        guard let p = dlsym(cs, name) else { throw Fail("CoreServices has no \(name)") }
        return unsafeBitCast(p, to: T.self)
    }
    let currentId = try fn("FSEventsGetCurrentEventId", (@convention(c) () -> UInt64).self)
    let copyUUID = try fn("FSEventsCopyUUIDForDevice", (@convention(c) (Int32) -> Unmanaged<CFUUID>?).self)
    let create = try fn("FSEventStreamCreate", (@convention(c) (CFAllocator?, P3FSECallback, UnsafeMutableRawPointer?,
        CFArray, UInt64, Double, UInt32) -> OpaquePointer?).self)
    let setQueue = try fn("FSEventStreamSetDispatchQueue", (@convention(c) (OpaquePointer, DispatchQueue?) -> Void).self)
    let start = try fn("FSEventStreamStart", (@convention(c) (OpaquePointer) -> Bool).self)
    let flush = try fn("FSEventStreamFlushSync", (@convention(c) (OpaquePointer) -> Void).self)
    let stop = try fn("FSEventStreamStop", (@convention(c) (OpaquePointer) -> Void).self)
    let invalidate = try fn("FSEventStreamInvalidate", (@convention(c) (OpaquePointer) -> Void).self)
    let release = try fn("FSEventStreamRelease", (@convention(c) (OpaquePointer) -> Void).self)
    let latest = try fn("FSEventStreamGetLatestEventId", (@convention(c) (OpaquePointer) -> UInt64).self)
    let callback: P3FSECallback = { _, info, n, paths, flags, ids in
        guard let info, let paths, let flags, let ids else { return }
        let box = Unmanaged<P3FSEEvents>.fromOpaque(info).takeUnretainedValue()
        let arr = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]   // kFSEventStreamCreateFlagUseCFTypes
        for i in 0..<n { box.add((arr[i], flags[i], ids[i])) }
    }
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sdkcov-fse-\(UUID().uuidString.prefix(8))")
        .resolvingSymlinksInPath()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let real = dir.path
    var st = stat()
    try expect(stat(real, &st) == 0, "stat \(real)")
    let uuid = copyUUID(st.st_dev)?.takeRetainedValue()
    try expect(uuid != nil, "FSEventsCopyUUIDForDevice(\(st.st_dev)) is NULL")
    let id0 = currentId()
    try expect(id0 > 0, "FSEventsGetCurrentEventId 0")
    let queue = DispatchQueue(label: "sdkcov.fsevents")
    // a stream: kFSEventStreamCreateFlagUseCFTypes | FileEvents (| NoDefer for the directory-level one)
    func openStream(_ box: P3FSEEvents, since: UInt64, flags: UInt32) throws -> OpaquePointer {
        // FSEventStreamContext {version, info, retain, release, copyDescription}
        var ctx: [Int] = [0, Int(bitPattern: Unmanaged.passUnretained(box).toOpaque()), 0, 0, 0]
        guard let s = ctx.withUnsafeMutableBytes({ create(nil, callback, $0.baseAddress, [real] as CFArray, since, 0.05, flags) })
        else { throw Fail("FSEventStreamCreate nil") }
        setQueue(s, queue)
        guard start(s) else { release(s); throw Fail("FSEventStreamStart failed") }
        return s
    }
    func closeStream(_ s: OpaquePointer) { stop(s); invalidate(s); release(s) }
    let rel = { (p: String) -> String in p.hasPrefix(real + "/") ? String(p.dropFirst(real.count + 1)) : p }

    // 1. live file events
    let live = P3FSEEvents()
    let s1 = try openStream(live, since: 0xFFFF_FFFF_FFFF_FFFF, flags: 0x11)
    let f1 = dir.appendingPathComponent("f1"), f2 = dir.appendingPathComponent("f2"), sub = dir.appendingPathComponent("sub")
    try Data("one".utf8).write(to: f1)
    try await Task.sleep(for: .milliseconds(300))
    let h = try FileHandle(forWritingTo: f1); try h.seekToEnd(); try h.write(contentsOf: Data(" two".utf8)); try h.close()
    try await Task.sleep(for: .milliseconds(300))
    try fm.moveItem(at: f1, to: f2)
    try fm.createDirectory(at: sub, withIntermediateDirectories: false)
    try Data("in".utf8).write(to: sub.appendingPathComponent("inner"))
    try await Task.sleep(for: .milliseconds(300))
    try fm.removeItem(at: f2)
    flush(s1)
    // expected (each path's flags, all its events together)
    let want: [(String, UInt32)] = [("f1", 0x100 | 0x1000 | 0x800 | 0x10000), ("f2", 0x800 | 0x200 | 0x10000),
        ("sub", 0x100 | 0x20000), ("sub/inner", 0x100 | 0x10000)]
    let ok = await p3Wait(15) { want.allSatisfy { live.flags(real + "/" + $0.0) & $0.1 == $0.1 } }
    let got = want.map { "\($0.0) \(p3FSEFlagNames(live.flags(real + "/" + $0.0)))" }.joined(separator: ", ")
    let ids = live.all.map(\.2)
    let last = latest(s1)
    closeStream(s1)
    try expect(ok, "live events: \(got); all \(live.all.map { "\(rel($0.0)) \(String($0.1, radix: 16)) \($0.2)" })")
    try expect(ids.allSatisfy { $0 > id0 } && ids == ids.sorted(), "event ids \(ids) (current before: \(id0))")
    try expect(last >= (ids.max() ?? 0), "latest event id \(last) < \(ids.max() ?? 0)")

    // 2. the same changes again from the history (sinceWhen), then history-done
    let hist = P3FSEEvents()
    let s2 = try openStream(hist, since: id0, flags: 0x11)
    let done = await p3Wait(15) { hist.all.contains { $0.1 & 0x10 != 0 } }
    closeStream(s2)
    try expect(done, "no history-done event replaying since \(id0): \(hist.all.map { "\(rel($0.0)) \(String($0.1, radix: 16))" })")
    let replayed = want.filter { hist.flags(real + "/" + $0.0) & $0.1 == $0.1 }.map(\.0)
    try expect(replayed.count == want.count, "history replayed \(replayed) of \(want.map(\.0)): \(hist.all.map { "\(rel($0.0)) \(String($0.1, radix: 16))" })")

    // 3. a directory-level stream (no file events): the changed item's directory, no item flags
    let dirs = P3FSEEvents()
    let s3 = try openStream(dirs, since: 0xFFFF_FFFF_FFFF_FFFF, flags: 0x3)
    try Data("again".utf8).write(to: sub.appendingPathComponent("inner2"))
    flush(s3)
    let dirOk = await p3Wait(15) { dirs.all.contains { $0.0.hasSuffix("/sub/") || $0.0.hasSuffix("/sub") } }
    closeStream(s3)
    try expect(dirOk, "directory stream: \(dirs.all.map { "\($0.0) \(String($0.1, radix: 16))" })")
    let d = dirs.all.first { $0.0.hasSuffix("/sub/") || $0.0.hasSuffix("/sub") }!
    return "uuid set, \(got); history \(hist.all.count) events + done; directory stream \(rel(d.0)) \(p3FSEFlagNames(d.1))"
}
