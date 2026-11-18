// sdkcov: the simulator's host-driven inputs (Inputs 2): what Apple's simulator lets the host do to a device besides
// touches and keys (Device > Shake, Rotate, Face ID / Touch ID / Optic ID, the simulated game controller), seen from an
// app. With SDKCOV_INPUT_WAIT=<s> (launch environment: SIMCTL_CHILD_SDKCOV_INPUT_WAIT) a check waits that long for the
// input and fails without it; the host sends it meanwhile (tests/apps/sdkcov/inputs.sh: `x86sim shake` ... here,
// notifyutil / Indigo messages on the Mac). Without it a check only reports the state it would wait on.
import Foundation
import notify
import Synchronization
import Security
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GameController)
import GameController
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
#endif

private var inputWait: Double { Double(ProcessInfo.processInfo.environment["SDKCOV_INPUT_WAIT"] ?? "") ?? 0 }

/// poll `cond` on the main actor every 50 ms until it holds or `secs` pass
@MainActor private func inUntil(_ secs: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while !cond() {
        if Date() > end { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}

#if os(iOS) || os(visionOS)
/// a first responder that counts shake motion events (UIKit sends them to the first responder of the key window)
private final class ShakeView: UIView {
    var shakes = 0
    override var canBecomeFirstResponder: Bool { true }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { shakes += 1 }
        super.motionEnded(motion, with: event)
    }
}
#endif

extension Registry {
    static var inputs: [Check] {
        var c: [Check] = []
        #if os(iOS) || os(visionOS)
        c.append(check("UIKit", "input-shake", timeout: 120) {
            let wait = inputWait
            let edit = await onMain { UIApplication.shared.applicationSupportsShakeToEdit }
            guard wait > 0 else { return "shake to edit \(edit) (SDKCOV_INPUT_WAIT unset: no shake awaited)" }
            // with --only the check starts as the app does, before its scene may be connected (it failed "no window" at
            // once): wait for a key window first
            _ = await inUntil(20) { UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.keyWindow != nil } }
            let (v, w) = try await onMain { () -> (ShakeView, UIWindow) in
                guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                      let key = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first else { throw Fail("no window") }
                let v = ShakeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
                key.addSubview(v)
                _ = v.becomeFirstResponder()
                return (v, key)
            }
            defer { Task { @MainActor in v.resignFirstResponder(); v.removeFromSuperview() } }
            let first = await onMain { v.isFirstResponder }
            // on failure, tell a lost darwin notification from UIKit dropping it: UIKit's own handler sends the motion
            // event only while -[UIMotionEvent _isDetectingMotionEvents] (accelerometer events on: app did become active)
            let posted = Mutex(0)
            var tok: Int32 = 0
            notify_register_dispatch("com.apple.UIKit.SimulatorShake", &tok, .global()) { _ in posted.withLock { $0 += 1 } }
            defer { notify_cancel(tok) }
            let ok = await inUntil(wait) { v.shakes > 0 }
            let n = await onMain { v.shakes }
            let detecting = await onMain { () -> String in
                let sel = NSSelectorFromString("_isDetectingMotionEvents")
                guard let me = UIApplication.shared.perform(NSSelectorFromString("_motionEvent"))?.takeUnretainedValue() as? NSObject,
                      me.responds(to: sel) else { return "?" }
                typealias B = @convention(c) (AnyObject, Selector) -> Bool
                return "\(unsafeBitCast(me.method(for: sel), to: B.self)(me, sel))"
            }
            let state = await onMain { UIApplication.shared.applicationState.rawValue }
            try expect(ok, "no shake in \(Int(wait)) s (first responder \(first), window key \(w.isKeyWindow), \(posted.withLock { $0 }) SimulatorShake notifications, UIKit detecting motion \(detecting), app state \(state))")
            return "\(n) shake motion events at the first responder"
        })
        #endif
        #if os(iOS) || os(visionOS) || os(tvOS)
        c.append(check("UIKit", "input-memory-warning", timeout: 120) {
            let wait = inputWait
            guard wait > 0 else { return "SDKCOV_INPUT_WAIT unset: no memory warning awaited" }
            // the host simulates a memory warning (x86sim memwarn / SimDevice simulateMemoryWarning)
            let n = Mutex(0)
            let obs = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                                             queue: nil) { _ in n.withLock { $0 += 1 } }
            defer { NotificationCenter.default.removeObserver(obs) }
            // the process's memory-pressure event itself (libdispatch), to tell a missing event from UIKit not passing it on
            let p = Mutex(0)
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
            src.setEventHandler { p.withLock { $0 += 1 } }
            src.resume()
            defer { src.cancel() }
            let ok = await inUntil(wait) { n.withLock { $0 } > 0 }
            let f = ProcessInfo.processInfo.environment["SIMULATOR_MEMORY_WARNINGS"] ?? "(unset)"
            try expect(ok, "no memory warning in \(Int(wait)) s (\(p.withLock { $0 }) memory-pressure events; SIMULATOR_MEMORY_WARNINGS \(f), exists \(FileManager.default.fileExists(atPath: f)))")
            return "\(n.withLock { $0 }) didReceiveMemoryWarning notifications, \(p.withLock { $0 }) memory-pressure events"
        })
        #endif
        #if os(iOS)
        c.append(check("UIKit", "input-orientation", timeout: 120) {
            let wait = inputWait
            await onMain { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
            defer { Task { @MainActor in UIDevice.current.endGeneratingDeviceOrientationNotifications() } }
            let o0 = await onMain { UIDevice.current.orientation.rawValue }
            guard wait > 0 else { return "device orientation \(o0) (SDKCOV_INPUT_WAIT unset: no rotation awaited)" }
            // the host rotates the device to landscape (x86sim rotate left / devicectl device orientation set)
            var notes = 0
            let obs = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in notes += 1 }
            defer { NotificationCenter.default.removeObserver(obs) }
            let ok = await inUntil(wait) { UIDevice.current.orientation.isLandscape }
            let (o, io) = await onMain { (UIDevice.current.orientation.rawValue,
                (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.effectiveGeometry.interfaceOrientation.rawValue ?? -1) }
            try expect(ok, "device orientation stayed \(o) in \(Int(wait)) s (was \(o0))")
            return "device orientation \(o0) -> \(o) (\(notes) notifications), interface orientation \(io)"
        })
        #endif
        #if canImport(LocalAuthentication) && (os(iOS) || os(visionOS))
        c.append(check("LocalAuthentication", "input-biometric", timeout: 150) {
            let wait = inputWait
            func can() -> (Bool, Int, Int) {
                let ctx = LAContext(); var e: NSError?
                let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
                return (ok, e?.code ?? 0, ctx.biometryType.rawValue)
            }
            let (ok0, code0, type0) = can()
            guard wait > 0 else { return "biometrics \(ok0) (\(code0)), type \(type0) (SDKCOV_INPUT_WAIT unset: no enrollment awaited)" }
            // the host enrolls (x86sim biometric enroll / the enrollmentChanged state), then presents a matching face / finger
            let end = Date().addingTimeInterval(wait)
            var st = can()
            while !st.0 && Date() < end { try? await Task.sleep(nanoseconds: 200_000_000); st = can() }
            try expect(st.0, "not enrolled after \(Int(wait)) s: error \(st.1), type \(st.2)")
            // Apple's fresh simulator can take longer than LocalAuthentication's 5 s to bring its biometric UI service up
            // the first time ("UI activation timed out after 5 seconds", -1000): asked again then, as a user would retry
            var r: Result<Bool, Error> = .success(false), tries = 0
            repeat {
            tries += 1
            let ctx = LAContext()
            let left = max(5, end.timeIntervalSinceNow)
            r = await withCheckedContinuation { k in
                let once = Mutex(false)
                func finish(_ v: Result<Bool, Error>) { if once.withLock({ let d = $0; $0 = true; return !d }) { k.resume(returning: v) } }
                ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "sdkcov checks biometrics") { ok, e in
                    finish(e.map { .failure($0) } ?? .success(ok))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + left) { finish(.failure(Fail("no match in \(Int(left)) s"))) }
            }
            if case .failure(let e) = r, (e as NSError).code == LAError.Code.systemCancel.rawValue || (e as NSError).code == -1000, tries < 3 { continue }
            break
            } while true
            switch r {
            case .success(let ok): try expect(ok, "evaluatePolicy false")
            case .failure(let e): throw Fail("evaluatePolicy: \(e)")
            }
            return "enrolled (was \(ok0), \(code0)), type \(st.2), evaluatePolicy matched\(tries > 1 ? " (try \(tries))" : "")"
        })
        // a keychain item protected by .biometryAny: read without interaction, read with a context the host's match
        // authenticated (inputs.sh bioitem; ref-mac.sh BIOMETRIC=1)
        c.append(check("Security", "input-biometry-item", timeout: 150) {
            let wait = inputWait
            guard wait > 0 else { return "SDKCOV_INPUT_WAIT unset: no enrollment awaited" }
            let end = Date().addingTimeInterval(wait)
            func enrolled() -> Bool { var e: NSError?; return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e) }
            while !enrolled() && Date() < end { try? await Task.sleep(nanoseconds: 200_000_000) }
            try expect(enrolled(), "not enrolled after \(Int(wait)) s")
            let acct = "sdkcov-bio-\(UUID().uuidString.prefix(6))"
            var ae: Unmanaged<CFError>?
            guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryAny, &ae) else { throw Fail("access control \(String(describing: ae?.takeRetainedValue()))") }
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "sdkcov.bio", kSecAttrAccount as String: acct]
            var add = base; add[kSecAttrAccessControl as String] = ac; add[kSecValueData as String] = Data("bio secret".utf8)
            let st = SecItemAdd(add as CFDictionary, nil)
            try expect(st == errSecSuccess, "SecItemAdd \(st)")
            defer { SecItemDelete(base as CFDictionary) }
            // no UI allowed: refused
            let noUI = LAContext(); noUI.interactionNotAllowed = true
            var q = base; q[kSecReturnData as String] = true; q[kSecUseAuthenticationContext as String] = noUI
            var out: CFTypeRef?
            let st0 = SecItemCopyMatching(q as CFDictionary, &out)
            // authenticated by the host's match (retried when the UI service is slow to come up, as input-biometric)
            var tries = 0, err = "-"
            var ctx = LAContext()
            while tries < 3 {
                tries += 1; ctx = LAContext()
                let left = max(5, end.timeIntervalSinceNow)
                let r: String = await withCheckedContinuation { k in
                    let once = Mutex(false)
                    func finish(_ v: String) { if once.withLock({ let d = $0; $0 = true; return !d }) { k.resume(returning: v) } }
                    // (evaluateAccessControl(_:operation:) answers -1020 on both simulators: the policy, then the context reused)
                    ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "sdkcov reads a keychain item") { ok, e in finish(ok ? "ok" : "\((e as NSError?)?.code ?? 0)") }
                    DispatchQueue.global().asyncAfter(deadline: .now() + left) { finish("no match in \(Int(left)) s") }
                }
                err = r
                if r == "ok" || !(r == "-4" || r == "-1000") { break }
            }
            try expect(err == "ok", "evaluatePolicy: \(err)")
            q[kSecUseAuthenticationContext as String] = ctx
            let st1 = SecItemCopyMatching(q as CFDictionary, &out)
            let v = (out as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "nil"
            // Apple's iOS 27.2 simulator: its keychain does not enforce the biometry constraint, the no-UI read succeeds too
            try expect(st0 == errSecSuccess && st1 == errSecSuccess && v == "bio secret", "no-UI read \(st0), authenticated read \(st1) \(v) (Apple's simulator: 0, 0)")
            return "no-UI read \(st0), matched\(tries > 1 ? " (try \(tries))" : ""), authenticated read: \(v)"
        })
        #endif
        #if canImport(GameController) && !os(watchOS)
        c.append(check("GameController", "input-gamepad", timeout: 120) {
            let wait = inputWait
            let names = { GCController.controllers().map { $0.vendorName ?? "?" } }
            _ = await inUntil(min(5, max(wait, 2))) { !GCController.controllers().isEmpty }
            let list = names()
            guard wait > 0 else { return "controllers \(list) (SDKCOV_INPUT_WAIT unset: no press awaited)" }
            #if os(visionOS)
            // Apple's visionOS 27.2 simulator lists the controller but never delivers its buttons to the app either
            // (an Indigo game controller message, checked 2026-11-15)
            try skipIf(true, "Apple's visionOS simulator delivers no simulated game controller input to apps (controllers \(list))")
            #endif
            guard let pad = GCController.controllers().first(where: { $0.extendedGamepad != nil })?.extendedGamepad else {
                throw Fail("no extended gamepad: \(list)")
            }
            // the host presses A (x86sim gamepad press a)
            let presses = Mutex(0)
            await onMain { pad.buttonA.pressedChangedHandler = { _, _, p in if p { presses.withLock { $0 += 1 } } } }
            defer { Task { @MainActor in pad.buttonA.pressedChangedHandler = nil } }
            let ok = await inUntil(wait) { presses.withLock { $0 } > 0 }
            try expect(ok, "button A never pressed in \(Int(wait)) s (controllers \(list))")
            return "controllers \(list), button A pressed \(presses.withLock { $0 })x"
        })
        #endif
        #if canImport(AppTrackingTransparency) && !os(watchOS)
        c.append(check("AppTrackingTransparency", "input-tracking-granted", timeout: 120) {
            // the request flow with the answer given ahead: the host writes the app's kTCCServiceUserTracking row
            // (inputs.sh tracking here, ref-mac.sh TRACKING=1 on the Mac) and removes it afterwards, so
            // not-determined-on-fresh-install stays true for the normal run. requestTrackingAuthorization then answers
            // from the row without a prompt
            let wait = inputWait
            let st0 = ATTrackingManager.trackingAuthorizationStatus
            guard wait > 0 else { return "status \(st0.rawValue) (SDKCOV_INPUT_WAIT unset: no tracking grant awaited)" }
            let granted = await inUntil(wait) { ATTrackingManager.trackingAuthorizationStatus == .authorized }
            try expect(granted, "tracking status \(ATTrackingManager.trackingAuthorizationStatus.rawValue) after \(Int(wait)) s (the host grant never arrived)")
            // the app must be active for the request to answer (it returns notDetermined at once otherwise)
            _ = await inUntil(20) { UIApplication.shared.applicationState == .active }
            let st = await ATTrackingManager.requestTrackingAuthorization()
            #if canImport(AdSupport)
            let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            #else
            let idfa = "-"
            #endif
            // Apple's iOS 27.2 simulator: authorized, and still the all-zero IDFA (no advertising identifier in a simulator)
            try expect(st == .authorized && (idfa == "-" || idfa == "00000000-0000-0000-0000-000000000000"),
                       "requestTrackingAuthorization answered \(st.rawValue), IDFA \(idfa) with tracking granted (Apple's simulator: 3, authorized; all-zero IDFA)")
            return "granted by the host; requestTrackingAuthorization answered authorized, IDFA \(idfa)"
        })
        #endif
        #if os(iOS)
        c.append(check("AppClip", "input-clip-launch", timeout: 120) {
            // the App Clip launched by the host (inputs.sh clip: x86sim launch, simctl launch on the Mac) with
            // _XCAppClipURL in its environment, as Xcode's Run of a clip target sets it. The runtime reads no such
            // variable (Xcode itself turns it into the invocation): the clip launches, its scene gets no browsing-web
            // user activity and so no activation payload (Apple's iOS 27.2 simulator)
            let wait = inputWait
            guard wait > 0 else { return "SDKCOV_INPUT_WAIT unset: no clip launch awaited" }
            let t0 = Date()
            // the clip takes the foreground: keep running in the background meanwhile
            let bg = await onMain { UIApplication.shared.beginBackgroundTask(withName: "sdkcov clip") }
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
            let launched = await inUntil(wait) { !p3Marks("clip-launch", since: t0).isEmpty }
            try expect(launched, "no clip launch in \(Int(wait)) s (the host launch never came)")
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            let acts = p3Marks("clip-activity", since: t0)
            try expect(acts.isEmpty, "clip got user activities \(acts) (Apple's simulator: none for a launch with _XCAppClipURL)")
            return "clip launched by the host (\(p3Marks("clip-launch", since: t0).last ?? "-")), no invocation activity"
        })
        #endif
        return c
    }
}
