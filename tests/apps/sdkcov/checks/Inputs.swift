// sdkcov: the simulator's host-driven inputs (Inputs 2): what Apple's simulator lets the host do to a device besides
// touches and keys (Device > Shake, Rotate, Face ID / Touch ID / Optic ID, the simulated game controller), seen from an
// app. With SDKCOV_INPUT_WAIT=<s> (launch environment: SIMCTL_CHILD_SDKCOV_INPUT_WAIT) a check waits that long for the
// input and fails without it; the host sends it meanwhile (tests/apps/sdkcov/inputs.sh: `x86sim shake` ... here,
// notifyutil / Indigo messages on the Mac). Without it a check only reports the state it would wait on.
import Foundation
import Synchronization
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GameController)
import GameController
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
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
            let ok = await inUntil(wait) { v.shakes > 0 }
            let n = await onMain { v.shakes }
            try expect(ok, "no shake in \(Int(wait)) s (first responder \(first), window key \(w.isKeyWindow))")
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
            let ctx = LAContext()
            let left = max(5, end.timeIntervalSinceNow)
            let r: Result<Bool, Error> = await withCheckedContinuation { k in
                let once = Mutex(false)
                func finish(_ v: Result<Bool, Error>) { if once.withLock({ let d = $0; $0 = true; return !d }) { k.resume(returning: v) } }
                ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "sdkcov checks biometrics") { ok, e in
                    finish(e.map { .failure($0) } ?? .success(ok))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + left) { finish(.failure(Fail("no match in \(Int(left)) s"))) }
            }
            switch r {
            case .success(let ok): try expect(ok, "evaluatePolicy false")
            case .failure(let e): throw Fail("evaluatePolicy: \(e)")
            }
            return "enrolled (was \(ok0), \(code0)), type \(st.2), evaluatePolicy matched"
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
        return c
    }
}
