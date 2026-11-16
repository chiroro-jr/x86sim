// sdkcov P10: frameworks whose answer in the simulator needed more than the earlier checks asserted: SafetyKit's
// Objective-C exception (caught by objc/SDKCovCatch.m), TelephonyMessagingKit without a carrier, a storage-based Matter
// device controller started offline, ClassKitUI's views for a document that is not assigned, a game controller button
// reaching a SwiftUI view with .handlesGameControllerEvents.
import Foundation
import SwiftUI
import Synchronization
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SafetyKit) && (os(iOS) || os(watchOS))
import SafetyKit
#endif
#if canImport(TelephonyMessagingKit) && os(iOS)
import TelephonyMessagingKit
#endif
#if canImport(Matter)
import Matter
#endif
#if canImport(ClassKitUI) && (os(iOS) || os(visionOS))
import ClassKitUI
#endif
#if canImport(GameController) && os(iOS)
import GameController
import _GameController_SwiftUI
#endif
#if canImport(WidgetKit) && os(visionOS)
import WidgetKit
#endif

/// the fraction of an image's pixels that are not transparent
func p10Inked(_ img: CGImage) -> Double {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var n = 0
    for i in stride(from: 3, to: px.count, by: 4) where px[i] > 16 { n += 1 }
    return Double(n) / Double(w * h)
}

#if canImport(Matter)
/// MTRDeviceControllerStorageDelegate in memory
final class P10MatterStore: NSObject, MTRDeviceControllerStorageDelegate, @unchecked Sendable {
    private let lock = NSLock(); private var vals: [String: any NSSecureCoding] = [:]
    var keys: [String] { lock.withLock { vals.keys.sorted() } }
    func controller(_ c: MTRDeviceController, valueForKey key: String, securityLevel: MTRStorageSecurityLevel, sharingType: MTRStorageSharingType) -> (any NSSecureCoding)? {
        lock.withLock { vals[key] }
    }
    func controller(_ c: MTRDeviceController, storeValue value: any NSSecureCoding, forKey key: String, securityLevel: MTRStorageSecurityLevel, sharingType: MTRStorageSharingType) -> Bool {
        lock.withLock { vals[key] = value }; return true
    }
    func controller(_ c: MTRDeviceController, removeValueForKey key: String, securityLevel: MTRStorageSecurityLevel, sharingType: MTRStorageSharingType) -> Bool {
        lock.withLock { vals[key] = nil }; return true
    }
}
#endif

extension Registry {
    static var p10_answers: [Check] {
        var c: [Check] = []

        // MARK: SafetyKit: the exception every call raises without com.apple.developer.safety-kit
        #if canImport(SafetyKit) && (os(iOS) || os(watchOS))
        c.append(check("SafetyKit", "exception-without-entitlement", timeout: 20) {
            var avail = false
            let a = SDKCovCatch { avail = SACrashDetectionManager.isAvailable }
            var st = -1
            let b = SDKCovCatch { st = SACrashDetectionManager().authorizationStatus.rawValue }
            var ev = -1
            let e = SDKCovCatch { ev = SAEmergencyResponseManager().delegate == nil ? 0 : 1 }
            // Apple's simulator: the crash detection calls raise NSInternalInconsistencyException ("SafetyKit Crash Detection
            // entitlement is required for this API"); the emergency response manager is made without one
            let want = ["NSInternalInconsistencyException", "SafetyKit Crash Detection entitlement is required for this API"]
            try expect(a == want && b == want, "isAvailable \(a ?? ["no exception", "\(avail)"]), authorizationStatus \(b ?? ["no exception", "\(st)"]) (Apple's simulator: \(want))")
            try expect(e == nil && ev == 0, "emergency response manager: \(e ?? ["no exception", "\(ev)"])")
            return "isAvailable / authorizationStatus raise \(want[0]): \(want[1]); emergency response manager made, no delegate"
        })
        #endif

        // MARK: TelephonyMessagingKit: no carrier messaging in the simulator
        #if canImport(TelephonyMessagingKit) && os(iOS)
        c.append(check("TelephonyMessagingKit", "session-without-carrier", timeout: 30) {
            let s = TelephonyMessagingSession.shared
            let conf = s.isConfiguredForCarrierMessaging
            var svc = "-"
            do { svc = "\(try s.cellularServices.count) services" } catch { svc = "threw \(error)" }
            // the state stream: its first value (a cellular service), or none in 3 s
            let first = P3Box<String>()
            let t = Task { for await st in s.cellularServiceStateUpdates { first.set("\(st)"); break } }
            let upd = await first.wait(3) ?? "none in 3 s"; t.cancel()
            // Apple's simulator: no carrier messaging service to connect to (lookup error 3), no state
            try expect(!conf && svc.hasPrefix("threw") && svc.contains("lookup with error 3") && upd == "none in 3 s",
                       "configured \(conf); cellularServices \(svc); state updates \(upd) (Apple's simulator: false; lookup error 3; none)")
            return "configured \(conf); cellularServices \(svc); state updates \(upd)"
        })
        #endif

        // MARK: Matter: a storage-based device controller, started with no network and shut down
        #if canImport(Matter)
        c.append(check("Matter", "device-controller-start-shutdown", timeout: 40) {
            let root = P5MatterKey(), node = P5MatterKey()
            let validity = DateInterval(start: Date(timeIntervalSinceNow: -60), duration: 365 * 86400)
            let rootDER = try MTRCertificates.createRootCertificate(root, issuerID: 1, fabricID: 0xFAB1, validityPeriod: validity)
            let opDER = try MTRCertificates.createOperationalCertificate(root, signingCertificate: rootDER, operationalPublicKey: node.pub, fabricID: 0xFAB1, nodeID: 0x1234, caseAuthenticatedTags: nil, validityPeriod: validity)
            let store = P10MatterStore(), uid = UUID()
            let p = MTRDeviceControllerExternalCertificateParameters(storageDelegate: store, storageDelegateQueue: DispatchQueue(label: "sdkcov.matter.store"), uniqueIdentifier: uid,
                                                  ipk: Data(repeating: 7, count: 16), vendorID: 0xFFF1, operationalKeypair: node,
                                                  operationalCertificate: opDER, intermediateCertificate: nil, rootCertificate: rootDER)
            let ctl: MTRDeviceController
            do { ctl = try MTRDeviceController(parameters: p) } catch { throw Fail("MTRDeviceController(parameters:) threw \(p3Err(error)) \(error)") }
            let running = ctl.isRunning, nid = ctl.controllerNodeID, same = ctl.uniqueIdentifier == uid
            ctl.shutdown()
            let keys = store.keys
            // the node id comes from the operational certificate; the controller stores its NOC through the delegate
            try expect(running && nid == 0x1234 && same && !ctl.isRunning, "running \(running), node \(String(describing: nid)), id \(same), after shutdown running \(ctl.isRunning)")
            try expect(keys.contains("lastLocallyUsedControllerNOC"), "stored keys \(keys)")
            return "running, node 0x1234 from the certificate, shut down; stored keys \(keys)"
        })
        #endif

        // MARK: ClassKitUI: the assigned-document views for a document no class assigned
        #if canImport(ClassKitUI) && (os(iOS) || os(visionOS))
        c.append(check("ClassKitUI", "unassigned-document-views", timeout: 30) {
            let doc = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-unassigned.txt")
            try Data("x86".utf8).write(to: doc)
            // each view alone in a hosting controller: its fitting size and what it says to accessibility (its text)
            var out: [String] = []
            for (name, v) in [("status", AnyView(AssignedDocumentLabel(role: .status, documentURL: doc))), ("date", AnyView(AssignedDocumentLabel(role: .date, documentURL: doc))),
                              ("submit", AnyView(AssignedDocumentSubmissionButton(documentURL: doc)))] {
                let r = try await Task { @MainActor () async throws -> String in
                    let hc = UIHostingController(rootView: v)
                    let (_, done) = try p8Show(hc); defer { done() }
                    try await Task.sleep(for: .seconds(2))
                    hc.view.layoutIfNeeded()
                    let fit = hc.sizeThatFits(in: CGSize(width: 300, height: 1000))
                    var labels: [String] = []
                    func walk(_ o: NSObject, _ depth: Int) {
                        if depth > 6 { return }
                        if let l = o.accessibilityLabel, !l.isEmpty { labels.append(l) }
                        let n = o.accessibilityElementCount()
                        if n != NSNotFound && n > 0 { for i in 0..<min(n, 20) { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } } }
                        (o.accessibilityElements as? [NSObject])?.forEach { walk($0, depth + 1) }
                        if let v = o as? UIView { v.subviews.forEach { walk($0, depth + 1) } }
                    }
                    walk(hc.view, 0)
                    return "\(name): \(Int(fit.width))x\(Int(fit.height)) \(labels)"
                }.value
                out.append(r)
            }
            // Apple's simulator, a document no class assigned: status 31 pt, date 97 pt, submit button 62 pt wide (visionOS:
            // 95 pt, its button style); no accessibility text
            #if os(visionOS)
            let submitW = 95
            #else
            let submitW = 62
            #endif
            let w = out.map { Int($0.split(separator: " ")[1].split(separator: "x")[0]) ?? -1 }
            try expect(abs(w[0] - 31) <= 3 && w[1] > 10 && w[1] < 300 && abs(w[2] - submitW) <= 3, "\(out) (Apple's simulator: status 31, date 97, submit \(submitW) wide)")
            return out.joined(separator: "; ")
        })
        #endif

        // MARK: _GameController_SwiftUI: a virtual controller's button A reaching GameController under the modifier
        #if canImport(GameController) && os(iOS)
        c.append(check("_GameController_SwiftUI", "virtual-controller-button", timeout: 40) {
            let shown = P2Count()
            let (_, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: Text("sdkcov").padding().handlesGameControllerEvents(matching: .gamepad).onAppear { shown.add() })
                let (_, done) = try p2ShowVC(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            _ = await p2Wait(10) { shown.value > 0 }
            let cfg = GCVirtualController.Configuration(); cfg.elements = [GCInputButtonA]; cfg.isHidden = true
            let vc = GCVirtualController(configuration: cfg)
            try await vc.connect()
            defer { vc.disconnect() }
            _ = await p2Wait(10) { vc.controller != nil }
            guard let gc = vc.controller, let pad = gc.extendedGamepad else { throw Fail("connected, controller \(String(describing: vc.controller)), current \(String(describing: GCController.current))") }
            let presses = P2Count()
            pad.buttonA.pressedChangedHandler = { _, _, p in if p { presses.add() } }
            await onMain { vc.setValue(1, forButtonElement: GCInputButtonA) }
            _ = await p2Wait(5) { presses.value > 0 }
            await onMain { vc.setValue(0, forButtonElement: GCInputButtonA) }
            try expect(shown.value > 0 && presses.value >= 1 && !pad.buttonA.isPressed, "view shown \(shown.value), presses \(presses.value), A pressed after release \(pad.buttonA.isPressed)")
            return "view shown, \(gc.vendorName ?? "?"): A pressed \(presses.value)x and released"
        })
        #endif
        // MARK: WidgetKit on visionOS: widget views drawn in the app, no widget of the app placed
        #if canImport(WidgetKit) && os(visionOS)
        c.append(check("WidgetKit", "widget-views-render-xros", timeout: 30) {
            let (bg, plain) = try await onMain { () throws -> (Double, Double) in
                @MainActor func ink<V: View>(_ v: V) throws -> Double {
                    let r = ImageRenderer(content: v.frame(width: 80, height: 80)); r.scale = 2
                    guard let img = r.cgImage else { throw Fail("no image") }
                    return p10Inked(img)
                }
                return (try ink(ZStack { AccessoryWidgetBackground(); Text("42").font(.title) }.clipShape(Circle())), try ink(Text("42").font(.title)))
            }
            // outside a widget, visionOS draws no accessory background (Apple's simulator: the same ink as the text alone,
            // about 4%; watchOS fills the circle)
            try expect(plain > 0.01 && plain < 0.3 && abs(bg - plain) < 0.01, "accessory background inked \(bg), text alone \(plain) (Apple's simulator: equal, the background draws nothing)")
            WidgetCenter.shared.reloadTimelines(ofKind: "sdkcov.static")
            let cur = try await WidgetCenter.shared.currentConfigurations()
            // Apple's simulator: no widget of the app is placed on a fresh device
            try expect(cur.isEmpty, "\(cur.count) configured widgets \(cur.map(\.kind)) (Apple's simulator: 0)")
            return "accessory background + text \(String(format: "%.1f", bg * 100))% inked, text alone \(String(format: "%.1f", plain * 100))%; \(cur.count) configured widgets"
        })
        #endif
        return c
    }
}
