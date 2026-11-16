// sdkcov P5: home. HomeKit's home manager (homes, adding / removing a home: Apple's simulator answer pinned), the accessory
// browser and setup payloads, the SwiftUI CameraView, Matter's certificate authority and TLV certificates (a fabric's
// root / operational certificates from a Secure Enclave-less P-256 key), MatterSupport's add-device request answer and the
// iOS 27 HomeExtensions settings model. Home access is granted up front by run.sh / ref-mac.sh (kTCCServiceWillow).
import Foundation
import SwiftUI
import Synchronization
import Security
#if canImport(UIKit)
import UIKit
#endif
#if canImport(HomeKit)
import HomeKit
#endif
#if canImport(_HomeKit_SwiftUI)
import _HomeKit_SwiftUI
#endif
#if canImport(Matter)
import Matter
#endif
#if canImport(MatterSupport)
import MatterSupport
#endif
#if canImport(HomeExtensions) && os(iOS)
import HomeExtensions
#endif

#if canImport(HomeKit)
final class P5HomeDelegate: NSObject, HMHomeManagerDelegate, @unchecked Sendable {
    let homes = P5Box<Int>(), auth = Mutex<[Int]>([])
    func homeManagerDidUpdateHomes(_ m: HMHomeManager) { homes.set(m.homes.count) }
    func homeManager(_ m: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) { auth.withLock { $0.append(Int(status.rawValue)) } }
}
#if os(iOS)
final class P5AccBrowserDelegate: NSObject, HMAccessoryBrowserDelegate, @unchecked Sendable {
    let found = Mutex(0)
    func accessoryBrowser(_ b: HMAccessoryBrowser, didFindNewAccessory a: HMAccessory) { found.withLock { $0 += 1 } }
}
#endif
#endif
#if canImport(Matter)
/// a Matter keypair over a software P-256 SecKey (signatures in DER, as Matter's certificate code asks)
final class P5MatterKey: NSObject, MTRKeypair, @unchecked Sendable {
    let priv: SecKey, pub: SecKey
    override init() {
        priv = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256] as CFDictionary, nil)!
        pub = SecKeyCopyPublicKey(priv)!
    }
    func copyPublicKey() -> Unmanaged<SecKey> { Unmanaged.passRetained(pub) }
    /// the pre-18.4 accessor, which Matter still calls in places
    func publicKey() -> Unmanaged<SecKey> { Unmanaged.passUnretained(pub) }
    func signMessageECDSA_DER(_ message: Data) -> Data {
        (SecKeyCreateSignature(priv, .ecdsaSignatureMessageX962SHA256, message as CFData, nil) as Data?) ?? Data()
    }
}
#endif

extension Registry {
    static var p5_home: [Check] {
        var c: [Check] = []

        // MARK: HomeKit
        #if canImport(HomeKit)
        c.append(check("HomeKit", "home-manager-add-remove-home", timeout: 60) {
            let d = P5HomeDelegate()
            let m = await onMain { () -> HMHomeManager in let m = HMHomeManager(); m.delegate = d; return m }
            // homeManagerDidUpdateHomes: within 20 s on Apple's tvOS simulator; on its iPhone simulator only sometimes
            // (a first HMHomeManager of the run may get no callback) and on its watch: required on tvOS, reported elsewhere
            let cb = await d.homes.wait(20)
            let st = await onMain { m.authorizationStatus }
            try expect(st.contains(.authorized), "authorization \(st.rawValue) (run.sh / ref-mac.sh grant kTCCServiceWillow)")
            let n = await onMain { m.homes.count }
            #if os(iOS) || os(visionOS)
            // adding a home: Apple's iOS / visionOS simulators have no iCloud home store and refuse it
            let name = "sdkcov \(Int(Date().timeIntervalSince1970) % 100000)"
            let b = P5Box<String>()
            m.addHome(withName: name) { h, e in b.set(h != nil ? "added" : p5Err(e)) }
            let add = await b.wait(20) ?? "no answer in 20 s"
            if add == "added", let h = await onMain({ m.homes.first { $0.name == name } }) { m.removeHome(h) { _ in } }
            // (Apple's runs: mostly HMErrorDomain 2040 within a second; also HMFErrorDomain 2 after 4 s, or no answer in
            // 20 s): never a home
            try expect(n == 0 && add != "added", "\(n) homes, addHome \(add) (Apple's: 0 homes, HMErrorDomain 2040)")
            #elseif os(tvOS)
            let add = "read-only on this platform"
            try expect(cb != nil, "homeManagerDidUpdateHomes never called")
            #else
            let add = "read-only on this platform"   // watchOS: the callback came in some of Apple's runs, not in others
            try expect(cb == nil || n == 0, "\(n) homes")
            #endif
            return "\(n) homes, update callback \(cb != nil), authorization \(st.rawValue), addHome: \(add)"
        })
        c.append(check("HomeKit", "characteristic-service-types") {
            // the type catalogue accessories are described with (constants of the runtime's HomeKit)
            let ch = [HMCharacteristicTypePowerState, HMCharacteristicTypeCurrentTemperature, HMCharacteristicTypeBrightness, HMCharacteristicTypeTargetLockMechanismState]
            let sv = [HMServiceTypeLightbulb, HMServiceTypeThermostat, HMServiceTypeLockMechanism, HMServiceTypeOutlet]
            try expect(Set(ch).count == 4 && Set(sv).count == 4 && ch.allSatisfy { UUID(uuidString: $0) != nil } && sv.allSatisfy { UUID(uuidString: $0) != nil }, "type UUIDs \(ch) \(sv)")
            try expect(HMCharacteristicTypePowerState == "00000025-0000-1000-8000-0026BB765291" && HMServiceTypeLightbulb == "00000043-0000-1000-8000-0026BB765291", "HAP UUIDs \(HMCharacteristicTypePowerState) \(HMServiceTypeLightbulb)")
            return "\(ch.count) characteristic + \(sv.count) service types"
        })
        #if os(iOS)
        c.append(check("HomeKit", "accessory-browser-setup-payload", timeout: 30) {
            let d = P5AccBrowserDelegate()
            let b = await onMain { () -> HMAccessoryBrowser in let b = HMAccessoryBrowser(); b.delegate = d; b.startSearchingForNewAccessories(); return b }
            try await Task.sleep(for: .seconds(3))
            let n = await onMain { () -> Int in b.stopSearchingForNewAccessories(); return b.discoveredAccessories.count }
            // what the browser finds depends on the network (Apple's simulator found a HomeKit accessory on the Mac's LAN): reported
            // a HomeKit setup code URL (X-HM://) parses into a payload
            let p = HMAccessorySetupPayload(url: URL(string: "X-HM://0023ISYWY1W2E")!)
            let ok = p != nil
            try expect(ok, "setup payload from X-HM:// URL")
            return "browsed 3 s: \(n) accessories (\(d.found.withLock { $0 }) callbacks); setup payload from URL"
        })
        #endif
        #endif
        #if canImport(_HomeKit_SwiftUI) && !os(watchOS)
        c.append(check("_HomeKit_SwiftUI", "camera-view-hosted", timeout: 30) {
            // CameraView wraps HMCameraView; a camera source only comes from a camera accessory (none here), so the
            // view shows an empty source made through the runtime
            guard let cls = NSClassFromString("HMCameraSource") as? NSObject.Type, let src = cls.init() as? HMCameraSource else { throw Fail("no HMCameraSource") }
            let names = try await onMain { () throws -> [String] in
                let hc = UIHostingController(rootView: CameraView(source: src).frame(width: 320, height: 180))
                let (_, done) = try p5Show(hc); defer { done() }
                hc.view.layoutIfNeeded()
                return p5Subviews(hc.view).map { "\(type(of: $0))" }
            }
            try expect(names.contains { $0.contains("HMCameraView") }, "no HMCameraView in \(names.count) views")
            return "HMCameraView hosted (\(names.count) views)"
        })
        #endif
        #if canImport(_HomeKit_SwiftUI) && os(watchOS)
        c.append(check("_HomeKit_SwiftUI", "camera-view-watch", timeout: 30) {
            guard let cls = NSClassFromString("HMCameraSource") as? NSObject.Type, let src = cls.init() as? HMCameraSource else { throw Fail("no HMCameraSource") }
            let shown = P5Box<String>()
            await onMain { Runner.shared.overlay = AnyView(CameraView(source: src).frame(width: 120, height: 80).onAppear { shown.set("appeared") }) }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            try expect(await shown.wait(10) == "appeared", "CameraView never appeared")
            return "CameraView on screen"
        })
        #endif

        // MARK: Matter
        #if canImport(Matter)
        c.append(check("Matter", "certificates-fabric-tlv", timeout: 30) {
            // a fabric's certificate authority: root certificate, an operational certificate for node 0x1234 signed by it,
            // conversion X.509 DER <-> Matter TLV, and the certificate info parsed from the TLV
            let root = P5MatterKey(), node = P5MatterKey()
            let validity = DateInterval(start: Date(timeIntervalSinceNow: -60), duration: 365 * 86400)
            let rootDER = try MTRCertificates.createRootCertificate(root, issuerID: 1, fabricID: 0xFAB1, validityPeriod: validity)
            try expect(MTRCertificates.keypair(root, matchesCertificate: rootDER) && !MTRCertificates.keypair(node, matchesCertificate: rootDER), "root keypair match")
            let opDER = try MTRCertificates.createOperationalCertificate(root, signingCertificate: rootDER, operationalPublicKey: node.pub, fabricID: 0xFAB1, nodeID: 0x1234,
                                                                          caseAuthenticatedTags: [0x0001_0001], validityPeriod: validity)
            guard let rootTLV = MTRCertificates.convertX509Certificate(rootDER), let opTLV = MTRCertificates.convertX509Certificate(opDER) else { throw Fail("X.509 -> TLV") }
            try expect(rootTLV.count < rootDER.count, "TLV \(rootTLV.count) B vs DER \(rootDER.count) B")
            guard let back = MTRCertificates.convertMatterCertificate(rootTLV) else { throw Fail("TLV -> X.509") }
            try expect(MTRCertificates.isCertificate(back, equalTo: rootDER), "TLV -> X.509 round trip differs")
            guard let ri = MTRCertificateInfo(tlvBytes: rootTLV), let oi = MTRCertificateInfo(tlvBytes: opTLV) else { throw Fail("certificate info") }
            try expect(ri.subject.rootCACertificateID == 1 && ri.subject.fabricID == 0xFAB1, "root subject \(ri.subject)")
            try expect(oi.subject.nodeID == 0x1234 && oi.subject.fabricID == 0xFAB1 && oi.issuer.rootCACertificateID == 1 && oi.subject.caseAuthenticatedTags.contains(0x0001_0001), "operational subject \(oi.subject), issuer \(oi.issuer)")
            try expect(abs(oi.notBefore.timeIntervalSince(validity.start)) < 2, "notBefore \(oi.notBefore)")
            // a CSR for the node key carries its public key
            let csr = try MTRCertificates.createCertificateSigningRequest(node)
            let pk = try MTRCertificates.publicKey(fromCSR: csr)
            let pubData = SecKeyCopyExternalRepresentation(node.pub, nil)! as Data
            try expect(pk == pubData, "CSR public key \(pk.count) B")
            // attribute / command paths of the cluster model
            let path = MTRAttributePath(endpointID: 1, clusterID: NSNumber(value: MTRClusterIDType.onOffID.rawValue), attributeID: NSNumber(value: MTRAttributeIDType.clusterOnOffAttributeOnOffID.rawValue))
            try expect(path.cluster == 6 && path.attribute == 0 && path.endpoint == 1, "path \(path)")
            return "root \(rootDER.count) B DER / \(rootTLV.count) B TLV, node 0x1234 operational cert, CSR \(csr.count) B"
        })
        #endif
        #if canImport(MatterSupport) && (os(iOS) || os(visionOS))   // tvOS / watchOS: MatterAddDeviceRequest unavailable
        c.append(check("MatterSupport", "add-device-request-answer", timeout: 40) {
            let topo = MatterAddDeviceRequest.Topology(ecosystemName: "sdkcov", homes: [MatterAddDeviceRequest.Home(displayName: "Lab")])
            let req = MatterAddDeviceRequest(topology: topo, setupPayload: MTRSetupPayload(setupPasscode: 20202021, discriminator: 3840), showing: .allDevices)
            let enc = try JSONEncoder().encode(topo)
            try expect(try JSONDecoder().decode(MatterAddDeviceRequest.Topology.self, from: enc) == topo, "topology Codable")
            let crit: [MatterAddDeviceRequest.DeviceCriteria] = [.allDevices, .vendorID(0xFFF1), .productID(0x8000)]
            try expect(Set(crit).count == 3, "criteria")
            let sup = MatterAddDeviceRequest.isSupported
            // perform: the system Matter setup flow; on a simulator it answers with an error (Apple's pinned) or not at all
            let r = await p5Within(20) { () async throws -> String in try await req.perform(); return "performed" } ?? "no answer in 20 s"
            try expect(r.hasPrefix("threw"), "perform: \(r) (supported \(sup))")
            return "supported \(sup); perform \(r)"
        })
        #endif

        // MARK: HomeExtensions (iOS 27): an accessory extension's settings model
        #if canImport(HomeExtensions) && os(iOS)
        c.append(check("HomeExtensions", "settings-model", timeout: 20) {
            try await onMain { () throws -> String in
                let id: HomeContentID = "sdkcov.settings"
                try expect(id.rawValue == "sdkcov.settings" && HomeContentID("x") != id, "content id")
                let label = HomeAccessorySettingLabel("Night mode", detailedLabel: "Dims the light", systemImage: "moon")
                let back = try JSONDecoder().decode(HomeAccessorySettingLabel.self, from: JSONEncoder().encode(label))
                try expect(back == label, "label Codable")
                let t = HomeAccessoryToggleSetting(id: "night", label: label, defaultValue: false, currentValue: true)
                let i = HomeAccessoryInformationSetting(id: "fw", label: "Firmware", value: "1.0")
                let tb = try JSONDecoder().decode(HomeAccessoryToggleSetting.self, from: JSONEncoder().encode(t))
                try expect(t.id == "night" && i.id == "fw" && tb.id == "night", "settings \(t.id) \(i.id) \(tb.id)")
                return "toggle + information settings, label round trip"
            }
        })
        #endif
        return c
    }
}
