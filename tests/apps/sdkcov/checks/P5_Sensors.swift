// sdkcov P5: sensors & accessories. Most of these need hardware a simulator does not have (Bluetooth, NFC, UWB, motion
// sensors, cellular, Wi-Fi Aware, Tap to Pay, LiDAR, MFi accessories, car keys) or an entitlement only Apple grants: each
// check asserts the answer Apple's simulator gives (ref-mac.sh), so x86Sim has to give the same one, and exercises the
// local object model (payloads, descriptors, Codable types) that works without the hardware.
import Foundation
import SwiftUI
import Synchronization
import UniformTypeIdentifiers
import Network
#if canImport(ExtensionFoundation)
import ExtensionFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
#if canImport(CoreMotion)
import CoreMotion
#endif
#if canImport(CoreNFC) && os(iOS)
import CoreNFC
#endif
#if canImport(_CoreNFC_UIKit) && os(iOS)
import _CoreNFC_UIKit
#endif
#if canImport(NearbyInteraction)
import NearbyInteraction
#endif
#if canImport(SensorKit) && os(iOS)
import SensorKit
#endif
#if canImport(ExternalAccessory)
import ExternalAccessory
#endif
#if canImport(AccessorySetupKit) && os(iOS)
import AccessorySetupKit
#endif
#if canImport(AccessoryNotifications) && os(iOS)
import AccessoryNotifications
#endif
#if canImport(AccessoryTransportExtension) && os(iOS)
import AccessoryTransportExtension
#endif
#if canImport(CarKey)
import CarKey
#endif
#if canImport(CoreTelephony) && os(iOS)
import CoreTelephony
#endif
#if canImport(ImageCaptureCore) && (os(iOS) || os(visionOS))
import ImageCaptureCore
#endif
#if canImport(ProximityReader) && os(iOS)
import ProximityReader
#endif
#if canImport(RoomPlan) && os(iOS)
import RoomPlan
#endif
#if canImport(WiFiAware)
import WiFiAware
#endif
#if canImport(ExposureNotification) && os(iOS)
import ExposureNotification
#endif
#if canImport(DeviceDiscoveryExtension)
import DeviceDiscoveryExtension
#endif
#if canImport(DeviceDiscoveryUI) && os(iOS)
import DeviceDiscoveryUI
import Network
#endif
#if canImport(_DeviceDiscoveryUI_SwiftUI) && os(iOS)
import _DeviceDiscoveryUI_SwiftUI
#endif
#if canImport(VisionEntitlementServices)
import VisionEntitlementServices
#endif
#if canImport(SafetyKit)
import SafetyKit
#endif

// MARK: helpers (P5_*.swift)

/// a value set once from any thread, awaited with a deadline
final class P5Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T?
    func set(_ x: T) { lock.withLock { if v == nil { v = x } } }
    var value: T? { lock.withLock { v } }
    func wait(_ secs: Double) async -> T? {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { if let v = value { return v }; try? await Task.sleep(for: .milliseconds(20)) }
        return value
    }
}
/// "domain code" of an error
func p5Err(_ e: Error?) -> String { e.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "nil" }
/// the result of an async throwing call within `secs`: "ok: <value>", "threw <error>" or nil (no answer)
func p5Within(_ secs: Double, _ body: @escaping @Sendable () async throws -> String) async -> String? {
    let b = P5Box<String>()
    let t = Task { do { b.set("ok: " + (try await body())) } catch { b.set("threw \(String(describing: error).prefix(200))") } }
    let r = await b.wait(secs); t.cancel()
    return r
}
/// poll `cond` every 30 ms for up to `secs`
func p5Wait(_ secs: Double, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(30)) }
    return await cond()
}
#if !os(watchOS)
@MainActor func p5Scene() throws -> UIWindowScene {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let ws = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { throw Fail("no window scene") }
    return ws
}
/// a window above the app's own showing `vc`; the closure takes it down
@MainActor func p5Show(_ vc: UIViewController) throws -> (UIWindow, () -> Void) {
    let ws = try p5Scene()
    let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.isHidden = false; w.makeKey(); w.layoutIfNeeded()
    return (w, { w.isHidden = true; w.rootViewController = nil })
}
@MainActor func p5Subviews(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap { p5Subviews($0) } }
#endif

#if canImport(CoreBluetooth)
final class P5BTDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    let central = P5Box<CBManagerState>(), peripheral = P5Box<CBManagerState>()
    func centralManagerDidUpdateState(_ c: CBCentralManager) { if c.state != .unknown { central.set(c.state) } }
}
#if !os(tvOS) && !os(watchOS) && !os(visionOS)
extension P5BTDelegate: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) { if p.state != .unknown { peripheral.set(p.state) } }
}
#endif
#endif
#if canImport(NearbyInteraction)
final class P5NIDelegate: NSObject, NISessionDelegate, @unchecked Sendable {
    let invalidated = P5Box<String>()
    let updated = P5Box<Int>()
    func session(_ s: NISession, didInvalidateWith error: Error) { invalidated.set(p5Err(error)) }
    func session(_ s: NISession, didUpdate nearbyObjects: [NINearbyObject]) { updated.set(nearbyObjects.count) }
}
#endif
#if canImport(CoreNFC) && os(iOS)
final class P5NFCDelegate: NSObject, NFCNDEFReaderSessionDelegate, @unchecked Sendable {
    let invalidated = P5Box<String>()
    func readerSession(_ s: NFCNDEFReaderSession, didInvalidateWithError error: Error) { invalidated.set(p5Err(error)) }
    func readerSession(_ s: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {}
}
#endif
#if canImport(CarKey)
final class P5CarKeyDelegate: CarKeyRemoteControlSessionDelegate, @unchecked Sendable {
    func remoteControlSession(_ session: CarKeyRemoteControlSession, didInvalidateWithError: CarKeyErrorCode) {}
    func remoteControlSession(_ session: CarKeyRemoteControlSession, vehicleDidUpdateReport: VehicleReport) {}
    func remoteControlSession(_ session: CarKeyRemoteControlSession, didReceivePassthroughData: Data, fromVehicle vehicleID: String) {}
}
#endif
#if canImport(ExternalAccessory) && os(iOS)
final class P5EADelegate: NSObject, EAWiFiUnconfiguredAccessoryBrowserDelegate, @unchecked Sendable {
    let states = Mutex<[Int]>([]), found = Mutex(0)
    func accessoryBrowser(_ b: EAWiFiUnconfiguredAccessoryBrowser, didUpdate state: EAWiFiUnconfiguredAccessoryBrowserState) { states.withLock { $0.append(state.rawValue) } }
    func accessoryBrowser(_ b: EAWiFiUnconfiguredAccessoryBrowser, didFindUnconfiguredAccessories a: Set<EAWiFiUnconfiguredAccessory>) { found.withLock { $0 += a.count } }
    func accessoryBrowser(_ b: EAWiFiUnconfiguredAccessoryBrowser, didRemoveUnconfiguredAccessories a: Set<EAWiFiUnconfiguredAccessory>) {}
    func accessoryBrowser(_ b: EAWiFiUnconfiguredAccessoryBrowser, didFinishConfiguringAccessory a: EAWiFiUnconfiguredAccessory, with status: EAWiFiUnconfiguredAccessoryConfigurationStatus) {}
}
#endif
#if canImport(ImageCaptureCore) && (os(iOS) || os(visionOS))
final class P5ICDelegate: NSObject, ICDeviceBrowserDelegate, @unchecked Sendable {
    let added = Mutex(0)
    func deviceBrowser(_ b: ICDeviceBrowser, didAdd d: ICDevice, moreComing: Bool) { added.withLock { $0 += 1 } }
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove d: ICDevice, moreGoing: Bool) {}
}
#endif

extension Registry {
    static var p5_sensors: [Check] {
        var c: [Check] = []

        // MARK: Core Bluetooth: no radio in a simulator
        #if canImport(CoreBluetooth)
        c.append(check("CoreBluetooth", "managers-unsupported-objects", timeout: 30) {
            let d = P5BTDelegate()
            let cm = CBCentralManager(delegate: d, queue: .global(), options: [CBCentralManagerOptionShowPowerAlertKey: false])
            var pmState = "n/a"
            #if !os(tvOS) && !os(watchOS) && !os(visionOS)
            let pm = CBPeripheralManager(delegate: d, queue: .global())
            #endif
            guard let cs = await d.central.wait(10) else { throw Fail("central manager state stayed unknown for 10 s") }
            #if !os(tvOS) && !os(watchOS) && !os(visionOS)
            if let ps = await d.peripheral.wait(10) { pmState = "\(ps.rawValue)" } else { pmState = "unknown" }
            _ = pm
            #endif
            // Apple's simulator has no Bluetooth: .unsupported (4) for both managers
            try expect(cs == .unsupported, "central state \(cs.rawValue) (Apple's simulator: 2 unsupported)")
            #if !os(tvOS) && !os(watchOS) && !os(visionOS)
            try expect(pmState == "2", "peripheral manager state \(pmState) (Apple's simulator: 2 unsupported)")
            #endif
            // scanning an unsupported radio is a no-op, not a crash
            cm.scanForPeripherals(withServices: [CBUUID(string: "180D")]); cm.stopScan()
            try expect(cm.retrieveConnectedPeripherals(withServices: [CBUUID(string: "180D")]).isEmpty, "connected peripherals")
            // the GATT object model
            let hr = CBUUID(string: "180D"), long = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
            try expect(hr.uuidString == "180D" && hr.data == Data([0x18, 0x0D]) && long.data.count == 16 && CBUUID(data: hr.data) == hr, "CBUUID \(hr) \(long)")
            #if !os(tvOS) && !os(watchOS) && !os(visionOS)
            let ch = CBMutableCharacteristic(type: CBUUID(string: "2A37"), properties: [.notify, .read], value: nil, permissions: [.readable])
            let svc = CBMutableService(type: hr, primary: true); svc.characteristics = [ch]
            try expect(svc.characteristics?.first?.uuid == CBUUID(string: "2A37") && ch.properties.contains(.notify), "mutable service")
            #endif
            return "central \(cs.rawValue), peripheral manager \(pmState), authorization \(CBManager.authorization.rawValue)"
        })
        #endif

        // MARK: Core Motion: no motion sensors in a simulator
        #if canImport(CoreMotion) && !os(tvOS)
        c.append(check("CoreMotion", "unavailable-sensors-queries", timeout: 30) {
            let m = CMMotionManager()
            var avail: [String: Bool] = ["accelerometer": m.isAccelerometerAvailable, "gyro": m.isGyroAvailable, "deviceMotion": m.isDeviceMotionAvailable]
            #if !os(visionOS)
            avail["magnetometer"] = m.isMagnetometerAvailable
            avail["activity"] = CMMotionActivityManager.isActivityAvailable()
            avail["steps"] = CMPedometer.isStepCountingAvailable()
            avail["distance"] = CMPedometer.isDistanceAvailable()
            avail["altimeter"] = CMAltimeter.isRelativeAltitudeAvailable()
            #endif
            let on = avail.filter(\.value).keys.sorted()
            try expect(on.isEmpty, "available in a simulator: \(on) (Apple's: none)")
            // updates of an unavailable sensor never come
            let got = Mutex(0)
            m.accelerometerUpdateInterval = 0.05
            m.startAccelerometerUpdates(to: OperationQueue()) { d, _ in if d != nil { got.withLock { $0 += 1 } } }
            try await Task.sleep(for: .milliseconds(500))
            m.stopAccelerometerUpdates()
            try expect(got.withLock { $0 } == 0 && m.accelerometerData == nil, "accelerometer delivered \(got.withLock { $0 }) samples")
            var q = "n/a"
            #if !os(visionOS)
            // a pedometer query on no pedometer: CMErrorDomain error
            let ped = P5Box<String>()
            CMPedometer().queryPedometerData(from: Date().addingTimeInterval(-3600), to: .now) { d, e in ped.set(e.map { p5Err($0) } ?? "data \(d?.numberOfSteps ?? -1)") }
            q = await ped.wait(10) ?? "no answer in 10 s"
            let auth = CMMotionActivityManager.authorizationStatus()
            q += ", activity authorization \(auth.rawValue)"
            #endif
            var hp = "n/a"
            #if os(iOS) || os(watchOS)
            let h = CMHeadphoneMotionManager()
            hp = "headphone motion available \(h.isDeviceMotionAvailable), authorization \(CMHeadphoneMotionManager.authorizationStatus().rawValue)"
            #endif
            return "pedometer query: \(q); \(hp)"
        })
        #endif

        // MARK: Core NFC (iOS): no NFC reader
        #if canImport(CoreNFC) && os(iOS)
        c.append(check("CoreNFC", "unavailable-ndef-model", timeout: 30) {
            try expect(!NFCNDEFReaderSession.readingAvailable && !NFCTagReaderSession.readingAvailable && !NFCVASReaderSession.readingAvailable,
                       "reading available on a simulator: ndef \(NFCNDEFReaderSession.readingAvailable) tag \(NFCTagReaderSession.readingAvailable)")
            // NDEF messages are plain data: build, serialize, parse back
            guard let uri = NFCNDEFPayload.wellKnownTypeURIPayload(string: "https://x86sim.test/nfc") else { throw Fail("URI payload") }
            guard let text = NFCNDEFPayload.wellKnownTypeTextPayload(string: "sdkcov", locale: Locale(identifier: "en")) else { throw Fail("text payload") }
            let msg = NFCNDEFMessage(records: [uri, text])
            try expect(uri.wellKnownTypeURIPayload()?.absoluteString == "https://x86sim.test/nfc", "URI back \(String(describing: uri.wellKnownTypeURIPayload()))")
            let (t, loc) = text.wellKnownTypeTextPayload()
            try expect(t == "sdkcov" && loc?.identifier == "en", "text back \(String(describing: t)) \(String(describing: loc))")
            try expect(uri.typeNameFormat == .nfcWellKnown && uri.type == Data("U".utf8) && msg.length > 20, "record type \(uri.typeNameFormat.rawValue), length \(msg.length)")
            let arch = try NSKeyedArchiver.archivedData(withRootObject: msg, requiringSecureCoding: true)
            let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: NFCNDEFMessage.self, from: arch)
            try expect(back?.records.count == 2 && back?.records.first?.payload == uri.payload, "archive round trip")
            // a session on a device without NFC: Apple's simulator neither starts nor invalidates it (no delegate call)
            let d = P5NFCDelegate()
            let s = NFCNDEFReaderSession(delegate: d, queue: nil, invalidateAfterFirstRead: true)
            s.begin()
            let inv = await d.invalidated.wait(3) ?? "no callback"
            s.invalidate()
            try expect(inv == "no callback" && !s.isReady, "session: \(inv), ready \(s.isReady) (Apple's simulator: no callback in 3 s)")
            return "\(msg.length) B message; session \(inv)"
        })
        #endif
        #if canImport(_CoreNFC_UIKit) && os(iOS)
        c.append(check("_CoreNFC_UIKit", "window-scene-events") {
            // the scene-delegate hook for NFC reader detection: values only (a simulator never detects a reader)
            let evs: [NFCWindowSceneEvent] = [.readerDetected, .presentation]
            let enc = try JSONEncoder().encode(evs)
            let back = try JSONDecoder().decode([NFCWindowSceneEvent].self, from: enc)
            try expect(back == evs && Set(evs).count == 2 && !evs[0].description.isEmpty, "events \(back)")
            let ws = await onMain { UIApplication.shared.connectedScenes.first.map { "\(type(of: $0.delegate.map { $0 } as Any))" } ?? "none" }
            return "\(evs.map(\.description)), scene delegate \(ws)"
        })
        #endif

        // MARK: NearbyInteraction: no UWB
        #if canImport(NearbyInteraction) && (os(iOS) || os(watchOS))
        c.append(check("NearbyInteraction", "unsupported-session-invalidated", timeout: 30) {
            let caps = NISession.deviceCapabilities
            let flags = [caps.supportsPreciseDistanceMeasurement, caps.supportsDirectionMeasurement, caps.supportsCameraAssistance, caps.supportsExtendedDistanceMeasurement]
            // Apple's simulator reports precise distance, camera assistance and extended distance, not direction
            #if os(watchOS)
            let want = [true, false, false, true]   // no camera assistance on the watch
            #else
            let want = [true, false, true, true]
            #endif
            try expect(flags == want, "capabilities \(flags) (Apple's simulator: \(want))")
            // garbage accessory configuration data is refused
            var bad = "accepted"
            do { _ = try NINearbyAccessoryConfiguration(data: Data([1, 2, 3])) } catch { bad = p5Err(error) }
            try expect(bad != "accepted", "accessory configuration from 3 bytes accepted")
            // a session on a device without UWB: no discovery token; running is answered by an invalidation
            let s = NISession(); let d = P5NIDelegate(); s.delegate = d; s.delegateQueue = DispatchQueue(label: "p5.ni")
            let tok = s.discoveryToken
            // Apple's simulator gets a discovery token from the host's com.apple.CoreSimulator.NearbyInteraction service
            // (NIServerConnection's simulator connection; Simulator.app simulates distance between simulator windows)
            try expect(tok != nil, "no discovery token (Apple's simulator: one, from com.apple.CoreSimulator.NearbyInteraction)")
            if let tok { s.run(NINearbyPeerConfiguration(peerToken: tok)) }
            let inv = await d.invalidated.wait(tok == nil ? 3 : 10) ?? "no invalidation"
            let upd = d.updated.value
            s.invalidate()
            // a session run with its own token: Apple's simulator keeps it running (no invalidation in 10 s) and its
            // NearbyInteraction service reports nearby objects (2 on the iOS and watchOS 27.2 simulators)
            do {
            try expect(inv == "no invalidation" && (upd ?? 0) >= 1, "own-token run: \(inv), updates \(String(describing: upd)) (Apple's simulator: no invalidation, nearby objects)")
            }
            return "capabilities \(flags), discovery token \(tok == nil ? "nil" : "set"), accessory data refused (\(bad)), session: \(inv), first update \(upd.map { "\($0) objects" } ?? "none")"
        })
        #endif

        // MARK: SensorKit (iOS): research-only entitlement
        #if canImport(SensorKit) && os(iOS)
        c.append(check("SensorKit", "authorization-request-answer", timeout: 30) {
            let r = SRSensorReader(sensor: .ambientLightSensor)
            try expect(r.authorizationStatus == .notDetermined, "status \(r.authorizationStatus.rawValue)")
            let b = P5Box<String>()
            SRSensorReader.requestAuthorization(sensors: [.ambientLightSensor, .keyboardMetrics]) { e in b.set(p5Err(e)) }
            let ans = await b.wait(15) ?? "no answer in 15 s"
            // without the com.apple.developer.sensorkit.reader.allow entitlement: SRErrorDomain (Apple's code pinned)
            try expect(ans.hasPrefix("SRErrorDomain"), "requestAuthorization: \(ans)")
            let dev = P5Box<String>()
            final class D: NSObject, SRSensorReaderDelegate, @unchecked Sendable {
                let b: P5Box<String>; init(_ b: P5Box<String>) { self.b = b }
                func sensorReader(_ r: SRSensorReader, didFetch devices: [SRDevice]) { b.set("\(devices.count) devices") }
                func sensorReader(_ r: SRSensorReader, fetchDevicesDidFailWithError e: Error) { b.set("fetch failed \(p5Err(e))") }
            }
            let del = D(dev); r.delegate = del
            r.fetchDevices()
            let fd = await dev.wait(10) ?? "no answer in 10 s"
            return "request: \(ans); fetchDevices: \(fd); current device \(SRDevice.current.model)"
        })
        #endif

        // MARK: External Accessory: no MFi accessories
        #if canImport(ExternalAccessory) && !os(watchOS)
        c.append(check("ExternalAccessory", "no-accessories-wifi-browser", timeout: 30) {
            let m = EAAccessoryManager.shared()
            m.registerForLocalNotifications()
            defer { m.unregisterForLocalNotifications() }
            try expect(m.connectedAccessories.isEmpty, "\(m.connectedAccessories.count) accessories connected to a simulator")
            var wifi = "n/a"
            #if os(iOS)
            let d = P5EADelegate()
            let b = await onMain { EAWiFiUnconfiguredAccessoryBrowser(delegate: d, queue: .main) }
            await onMain { b.startSearchingForUnconfiguredAccessories(matching: nil) }
            try await Task.sleep(for: .seconds(2))
            await onMain { b.stopSearchingForUnconfiguredAccessories() }
            try expect(d.found.withLock { $0 } == 0, "found unconfigured accessories")
            wifi = "Wi-Fi browser states \(d.states.withLock { $0 }), \(b.unconfiguredAccessories.count) accessories"
            #endif
            return "0 accessories; \(wifi)"
        })
        #endif

        // MARK: AccessorySetupKit (iOS): the picker's object model (the session needs NSAccessorySetupKitSupports)
        #if canImport(AccessorySetupKit) && os(iOS)
        c.append(check("AccessorySetupKit", "descriptors-display-items") {
            let d = ASDiscoveryDescriptor()
            d.bluetoothServiceUUID = CBUUID(string: "180D")
            d.bluetoothNameSubstring = "sdkcov"
            d.bluetoothRange = .immediate
            d.supportedOptions = [.bluetoothPairingLE]
            try expect(d.bluetoothServiceUUID == CBUUID(string: "180D") && d.supportedOptions.contains(.bluetoothPairingLE), "descriptor")
            let img = await onMain { UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { $0.fill(CGRect(x: 0, y: 0, width: 32, height: 32)) } }
            let item = ASPickerDisplayItem(name: "sdkcov sensor", productImage: img, descriptor: d)
            item.setupOptions = [.rename]
            try expect(item.name == "sdkcov sensor" && item.descriptor.bluetoothNameSubstring == "sdkcov" && item.setupOptions.contains(.rename), "display item")
            let settings = ASAccessorySettings.default
            settings.ssid = "sdkcov-ap"
            try expect(settings.ssid == "sdkcov-ap", "settings")
            let plist = Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") != nil
            return "descriptor + display item; NSAccessorySetupKitSupports in Info.plist \(plist)"
        })
        #endif
        #if canImport(AccessoryNotifications) && os(iOS)
        c.append(check("AccessoryNotifications", "notification-model-codable") {
            let id = AccessoryNotification.Identifier(notificationIdentifier: "n1", sourceIdentifier: "com.x86sim.test.sdkcov")
            let act = AccessoryNotification.Action(identifier: "open", title: "Open", type: .background)
            let n = AccessoryNotification(identifier: id, sourceName: "sdkcov", deliveryDate: Date(timeIntervalSince1970: 1_800_000_000), displayDate: .deliveryDate,
                                          title: "sdkcov", subtitle: nil, body: NSAttributedString(string: "body"), threadIdentifier: "t",
                                          attributes: [.timeSensitive], summary: nil, actions: [act], sourceIcon: nil, contextIcon: nil, attachments: [])
            let back = try JSONDecoder().decode(AccessoryNotification.self, from: JSONEncoder().encode(n))
            try expect(back == n && back.attributes.contains(.timeSensitive) && back.actions.first?.identifier == "open", "Codable round trip \(back)")
            let ctx = AlertingContext(notificationCanAlert: true, suppressedByFocus: false)
            try expect(ctx.notificationCanAlert && !ctx.isSuppressedByFocus, "alerting context")
            return "notification + action round trip, featureID \(NotificationsForwarding.featureID)"
        })
        #endif
        #if canImport(AccessoryTransportExtension) && os(iOS)
        c.append(check("AccessoryTransportExtension", "message-builder") {
            let m = AccessoryMessage {
                AccessoryMessage.Payload(data: Data([1, 2, 3]))
                AccessoryMessage.Payload(transport: .bluetooth, data: Data("sdkcov".utf8))
            }
            // Apple's answer: the builder keeps the first payload only
            try expect(m.payloads.count == 1 && m.payloads[0].data == Data([1, 2, 3]) && m.payloads[0].transport == .bluetooth, "payloads \(m.payloads.map(\.data))")
            let e = AccessoryTransportSession.Error.unsupported
            return "\(m.payloads.count) payloads, id \(m.id), error \(e.description)"
        })
        #endif

        // MARK: CarKey: needs Wallet car keys (NFC / UWB) and Apple's entitlement
        #if canImport(CarKey) && (os(iOS) || os(watchOS))
        c.append(check("CarKey", "remote-control-start-refused", timeout: 30) {
            let r = await p5Within(15) { () async throws -> String in
                let s = try await CarKeyRemoteControl.start(delegate: P5CarKeyDelegate())
                let n = try s.vehicleReports.count; try? s.end()
                return "session, \(n) vehicles"
            }
            let ans = r ?? "no answer in 15 s"
            try expect(ans.hasPrefix("threw"), "start: \(ans) (a simulator has no car keys)")
            let a = RemoteKeylessEntryAction(functionID: FunctionIdentifier(1), actionID: ActionIdentifier(2), vehicleID: "v")
            try expect(a.functionID.rawValue == 1 && a.actionID.rawValue == 2, "action")
            return "start: \(ans)"
        })
        #endif

        // MARK: Core Telephony (iOS): no cellular radio
        #if canImport(CoreTelephony) && os(iOS)
        c.append(check("CoreTelephony", "no-radio-answers", timeout: 20) {
            let ni = CTTelephonyNetworkInfo()
            let radios = ni.serviceCurrentRadioAccessTechnology ?? [:]
            let carriers = ni.serviceSubscriberCellularProviders ?? [:]
            try expect(radios.isEmpty, "radios \(radios)")
            let prov = CTCellularPlanProvisioning()
            let esim = prov.supportsEmbeddedSIM
            try expect(!esim, "supportsEmbeddedSIM on a simulator")
            let cd = CTCellularData()
            let restricted = P5Box<Int>()
            cd.cellularDataRestrictionDidUpdateNotifier = { restricted.set(Int($0.rawValue)) }
            let r = await restricted.wait(3).map { "\($0)" } ?? "no notification"
            return "0 radios, \(carriers.count) carrier entries, eSIM false, cellular plan \(prov.supportsCellularPlan()), data restriction \(cd.restrictedState.rawValue) (notified \(r))"
        })
        #endif

        // MARK: Image Capture: no cameras / scanners attached
        #if canImport(ImageCaptureCore) && (os(iOS) || os(visionOS))
        c.append(check("ImageCaptureCore", "browser-no-devices", timeout: 30) {
            let d = P5ICDelegate()
            let b = await onMain { () -> ICDeviceBrowser in let b = ICDeviceBrowser(); b.delegate = d; return b }
            await onMain { b.start() }
            try await Task.sleep(for: .seconds(2))
            let (browsing, n) = await onMain { () -> (Bool, Int) in let r = (b.isBrowsing, b.devices?.count ?? 0); b.stop(); return r }
            try expect(browsing, "the browser did not start")
            try expect(n == 0 && d.added.withLock { $0 } == 0, "\(n) devices on a simulator")
            let stopped = await p5Wait(5) { await onMain { !b.isBrowsing } }
            try expect(stopped, "still browsing after stop")
            return "browsed, 0 devices"
        })
        #endif

        // MARK: ProximityReader (iOS): Tap to Pay needs NFC hardware
        #if canImport(ProximityReader) && os(iOS)
        c.append(check("ProximityReader", "readers-answers", timeout: 30) {
            // Apple's iPhone simulator answers PaymentCardReader supported (preparing it needs the entitlement and a token)
            try expect(PaymentCardReader.isSupported, "PaymentCardReader unsupported (Apple's simulator: supported)")
            let md = MobileDocumentReader.isSupported
            let r = PaymentCardReader()
            let prep = await p5Within(8) { () async throws -> String in _ = try await r.prepare(using: PaymentCardReader.Token(rawValue: "sdkcov")); return "prepared" }
            // Apple's simulator: no answer (no Tap to Pay service); an answer must be an error (no entitlement / token)
            let ans = prep ?? "no answer in 8 s"
            try expect(!ans.hasPrefix("ok"), "prepare: \(ans)")
            return "payment card reader supported, mobile document reader \(md); prepare: \(ans)"
        })
        #endif

        // MARK: RoomPlan (iOS): needs LiDAR
        #if canImport(RoomPlan) && os(iOS)
        c.append(check("RoomPlan", "unsupported-model", timeout: 20) {
            try expect(!RoomCaptureSession.isSupported, "RoomCaptureSession supported on a simulator (no LiDAR)")
            var cfg = RoomCaptureSession.Configuration(); cfg.isCoachingEnabled = false
            try expect(!cfg.isCoachingEnabled, "configuration")
            let cats = CapturedRoom.Object.Category.allCases.map { "\($0)" }
            try expect(cats.contains("bed") && cats.contains("table"), "object categories \(cats)")
            return "unsupported; \(cats.count) object categories"
        })
        #endif

        // MARK: Wi-Fi Aware: no radio
        #if canImport(WiFiAware) && os(iOS)   // visionOS: every WiFiAware type is unavailable (load check only)
        c.append(check("WiFiAware", "unsupported-capabilities", timeout: 30) {
            let f = WACapabilities.supportedFeatures
            try expect(f.isEmpty, "supported features \(f) on a simulator")
            let pub = WAPublishableService.allServices.count, sub = WASubscribableService.allServices.count
            let dev = await p5Within(10) { () async throws -> String in "\(String(describing: try await WAPairedDevice.allDevices.current()?.count))" } ?? "no answer in 10 s"
            return "no features, max devices \(WACapabilities.maximumConnectableDevices), \(pub)/\(sub) declared services; paired devices: \(dev)"
        })
        #endif

        // MARK: Exposure Notification (iOS, deprecated)
        #if canImport(ExposureNotification) && os(iOS)
        c.append(check("ExposureNotification", "manager-activate-answer", timeout: 30) {
            let m = ENManager()
            defer { m.invalidate() }
            let b = P5Box<String>()
            m.activate { e in b.set(p5Err(e)) }
            let ans = await b.wait(15) ?? "no answer in 15 s"
            // Apple's simulator: no Exposure Notification entitlement / service, activate fails NSOSStatusErrorDomain -71148
            try expect(ans == "NSOSStatusErrorDomain -71148" && m.exposureNotificationStatus == .unknown && ENManager.authorizationStatus == .unknown,
                       "activate \(ans), status \(m.exposureNotificationStatus.rawValue), authorization \(ENManager.authorizationStatus.rawValue) (Apple's simulator: NSOSStatusErrorDomain -71148, 0, 0)")
            return "activate: \(ans), status \(m.exposureNotificationStatus.rawValue), authorization \(ENManager.authorizationStatus.rawValue)"
        })
        #endif

        // MARK: DeviceDiscoveryExtension: the extension's data types (iOS / visionOS)
        #if canImport(DeviceDiscoveryExtension) && (os(iOS) || os(visionOS))
        c.append(check("DeviceDiscoveryExtension", "device-event-types") {
            let ep = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
            let d = DDDevice(displayName: "sdkcov", category: .hifiSpeaker, protocolType: UTType("com.apple.dial") ?? .data, identifier: "sdkcov-1")
            d.networkEndpoint = ep
            d.state = .activated
            try expect(d.displayName == "sdkcov" && d.identifier == "sdkcov-1" && d.category == .hifiSpeaker && d.state == .activated, "device \(d)")
            let ev = DDDeviceEvent(eventType: .deviceFound, device: d)
            try expect(ev.eventType == .deviceFound && ev.device.identifier == "sdkcov-1", "event")
            _ = ep
            return "\(d.description.prefix(80))"
        })
        #endif

        #if canImport(DeviceDiscoveryExtension) && canImport(ExtensionFoundation) && os(visionOS)
        c.append(check("DeviceDiscoveryExtension", "discovery-point-xros", timeout: 30) {
            // DDDiscoverySession lives in a com.apple.discovery-extension ExtensionKit extension: visionOS installs no app
            // extension there (installd: ExtensionKit appex only on iOS). What an app sees of the point on Apple's simulator
            var ans = "resolved"
            do {
                let m = try await AppExtensionPoint.Monitor(appExtensionPoint: try AppExtensionPoint(identifier: "com.apple.discovery-extension"))
                ans = "monitor, identities \(m.identities.map(\.bundleIdentifier))"
            } catch { ans = p5Err(error) }
            // Apple's visionOS 27.2 simulator: the monitor is refused, host not entitled (as on iOS, p10AppleExtensionPoint)
            try expect(ans == "com.apple.extensionKit.errorDomain 16", "com.apple.discovery-extension: \(ans) (Apple's simulator: com.apple.extensionKit.errorDomain 16)")
            return "com.apple.discovery-extension: \(ans)"
        })
        #endif

        // MARK: DeviceDiscoveryUI on iOS (ported from tvOS)
        #if canImport(DeviceDiscoveryUI) && os(iOS)
        c.append(check("DeviceDiscoveryUI", "device-picker-ios", timeout: 30) {
            // the picker's view needs NSApplicationServices in Info.plist (build.sh: Browses sdkcov; DeviceDiscoveryUI
            // aborts the app without it): the picker is shown in a window of its own
            try await p7Main { () async throws -> String in
                try expect(Bundle.main.object(forInfoDictionaryKey: "NSApplicationServices") != nil, "no NSApplicationServices in Info.plist")
                let desc = NWBrowser.Descriptor.applicationService(name: "sdkcov")
                let ok = DDDevicePickerViewController.isSupported(desc, using: .applicationService)
                try expect(ok, "isSupported false (Apple's iOS simulator: true)")
                guard let p = DDDevicePickerViewController(browseDescriptor: desc, parameters: .applicationService) else { throw Fail("no picker") }
                let (w, close) = try p5Show(p); defer { close() }
                try await Task.sleep(for: .seconds(1))
                let views = p5Subviews(p.view).count
                try expect(p.view.window === w && views > 1, "picker view: window \(p.view.window != nil), \(views) views")
                return "supported, picker on screen with \(views) views"
            }
        })
        #endif
        #if canImport(_DeviceDiscoveryUI_SwiftUI) && os(iOS)
        c.append(check("_DeviceDiscoveryUI_SwiftUI", "device-picker-bonjour-ios", timeout: 30) {
            // iOS 26 DevicePicker over a Network.framework browser provider: label when the device can show the picker,
            // fallback otherwise (which one Apple's simulator shows is pinned)
            let shown = P5Box<String>()
            let v = DevicePicker(.bonjour("_sdkcov._tcp"), onSelect: { _ in }, label: { Text("pick").onAppear { shown.set("label") } },
                                 fallback: { Text("no picker").onAppear { shown.set("fallback") } })
            let done = try await onMain { () throws -> () -> Void in try p5Show(UIHostingController(rootView: v)).1 }
            defer { Task { @MainActor in done() } }
            let r = await shown.wait(10) ?? "nothing appeared in 10 s"
            try expect(r == "label" || r == "fallback", r)
            return "DevicePicker showed its \(r)"
        })
        #endif

        // MARK: VisionEntitlementServices (visionOS): enterprise license answers without a license file
        #if canImport(VisionEntitlementServices) && os(visionOS)
        c.append(check("VisionEntitlementServices", "enterprise-license-answers") {
            let l = EnterpriseLicenseDetails.shared
            let approved = l.approvedEntitlements
            let any = EnterpriseLicenseDetails.EnterpriseEntitlement.allCases.filter { l.isApproved(for: $0) }
            try expect(approved.isEmpty && any.isEmpty, "approved \(approved) without a license")
            // (Apple's visionOS simulator reports the license status valid with nothing approved)
            return "license \(l.licenseStatus), compute category \(AppComputeCategory.shared.status)"
        })
        #endif

        // MARK: SafetyKit: every call raises without Apple's entitlement (iOS port of the watch SKIP)
        #if canImport(SafetyKit) && os(iOS)
        c.append(check("SafetyKit", "entitlement-gated") {
            // SACrashDetectionManager / SAEmergencyResponseManager raise an Objective-C exception without
            // com.apple.developer.safety-kit (Apple grants it): the classes load, nothing is called
            let h = dlopen("/System/Library/Frameworks/SafetyKit.framework/SafetyKit", RTLD_NOW)
            try expect(h != nil, "dlopen SafetyKit: \(String(cString: dlerror()))")
            let cls = ["SACrashDetectionManager", "SAEmergencyResponseManager", "SACrashDetectionEvent"].map { "\($0) \(NSClassFromString($0) != nil || dlsym(h, "OBJC_CLASS_$_\($0)") != nil)" }
            try expect(!cls.contains { $0.hasSuffix("false") }, "classes \(cls)")
            return cls.joined(separator: ", ")
        })
        #endif
        return c
    }
}

extension Registry {
    /// every P5 check (health, home, location, sensors & accessories), in run order
    static var p5: [Check] { [p5_health, p5_location, p5_home, p5_sensors].joined().map { $0 } }
}
