// sdkcov P9: ports of existing checks to the platforms that lacked them (SwiftData's @Query in a hosted view,
// SuggestedActions' view on visionOS, _Contacts_AppIntents (tvOS ships it only in its runtime), ASWebAuthenticationSession
// on tvOS / watchOS / visionOS, SceneKit's scene files, morpher and skinner on watchOS). Values asserted are Apple's
// simulator's (ref-mac.sh).
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftData) && !os(tvOS)
import SwiftData
import _SwiftData_SwiftUI
#endif
#if canImport(SuggestedActions) && os(visionOS)
import SuggestedActions
#endif
#if canImport(AppIntents) && os(tvOS)
import AppIntents
#endif
#if canImport(AuthenticationServices) && !os(iOS)
import AuthenticationServices
#endif
#if canImport(SceneKit) && os(watchOS)
import SceneKit
#endif

#if canImport(SwiftData) && !os(tvOS)
/// what @Query(sort: \.title) expands to (no SwiftDataMacros plugin on Linux), as More_tvOS.swift's TVQueryView
private struct P9QueryView: View {
    var _notes = Query<SDNote, [SDNote]>(FetchDescriptor<SDNote>(sortBy: [SortDescriptor(\.title)]))
    var notes: [SDNote] { _notes.wrappedValue }
    let seen: P9Box<Int>
    var body: some View { Text("\(notes.count) notes, first \(notes.first?.title ?? "-")").onAppear { if !notes.isEmpty { seen.set(notes.count) } }.onChange(of: notes.count) { _, n in seen.set(n) } }
}
#endif

#if canImport(AuthenticationServices) && os(visionOS)
final class P9WebAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    let w: UIWindow
    init(_ w: UIWindow) { self.w = w }
    func presentationAnchor(for s: ASWebAuthenticationSession) -> ASPresentationAnchor { w }
}
#endif

extension Registry {
    static var p9_ports: [Check] {
        var c: [Check] = []

        // MARK: _SwiftData_SwiftUI (tvOS: More_tvOS.swift): @Query in a view on screen
        #if canImport(SwiftData) && !os(tvOS)
        c.append(check("_SwiftData_SwiftUI", "query-hosted-port", timeout: 30) {
            let mc = try await onMain { () throws -> ModelContainer in
                let mc = try ModelContainer(for: SDNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                for i in 0..<7 { mc.mainContext.insert(SDNote(title: "p9-\(i)")) }
                try mc.mainContext.save()
                return mc
            }
            let seen = P9Box<Int>()
            let shown = try await p4OnScreen(P9QueryView(seen: seen).modelContainer(mc), secs: 1)
            let n = await seen.wait(5)
            try expect(n == 7, "@Query saw \(String(describing: n)) notes (\(shown))")
            return "@Query: 7 notes (\(shown))"
        })
        #endif

        // MARK: SuggestedActions on visionOS (iOS: P7_ML.swift)
        #if canImport(SuggestedActions) && os(visionOS)
        c.append(check("SuggestedActions", "message-view-generate-port", timeout: 60) {
            let me = SuggestedActionsMessage.Participant(name: "sdkcov", handle: "sdkcov@example.com", isUser: true)
            let ada = SuggestedActionsMessage.Participant(name: "Ada", handle: "ada@example.com", isUser: false)
            let prev = SuggestedActionsMessage(id: 1, date: Date().addingTimeInterval(-60), subject: AttributedString("Lunch"), body: AttributedString("Lunch at noon tomorrow?"), sender: ada, recipients: [me])
            let msg = SuggestedActionsMessage(id: 2, date: Date(), subject: nil, body: AttributedString("Call me at +1 408 555 0100 tomorrow at 3pm"), sender: ada, recipients: [me])
            let limit = SuggestedActionsMessage.previousMessagesLimit
            let gen = P9Box<String>()
            Task { await SuggestedActionsView.generate(message: msg, previousMessages: [prev]); gen.set("generated") }
            let g = await gen.wait(30) ?? "generate did not return in 30 s"
            let shown = try await p4OnScreen(SuggestedActionsView(message: msg, previousMessages: [prev]).frame(width: 360, height: 200), secs: 1)
            // Apple's iOS simulator: limit 25, generate returns, the view is hosted
            try expect(limit == 25 && g == "generated", "limit \(limit), \(g) (Apple's simulator: 25, generated)")
            return "limit \(limit), \(g), view \(shown)"
        })
        #endif

        // MARK: AppIntents overlays tvOS ships without their SDK frameworks (no Contacts in the tvOS SDK)
        #if os(tvOS)
        // (_AppIntents_HealthKit is not checked this way: dlopen of it, which loads the runtime's HealthKit, wedges the whole
        // app in Apple's tvOS 27.2 simulator - no further output, no crash report, ref-mac.sh tvos)
        c.append(check("_Contacts_AppIntents", "tv-runtime-postal-address-entity") {
            guard dlopen("/System/Library/Frameworks/_Contacts_AppIntents.framework/_Contacts_AppIntents", RTLD_NOW) != nil else { throw Fail("dlopen: \(String(cString: dlerror()))") }
            guard let t = _typeByName("20_Contacts_AppIntents21CNPostalAddressEntityV") else { throw Fail("no CNPostalAddressEntity type") }
            guard let e = t as? any AppEntity.Type else { throw Fail("\(t) is not an AppEntity") }
            let n = String(localized: e.typeDisplayRepresentation.name)
            // Apple's iOS / watchOS / visionOS simulators: 'Contacts Postal Address Entity'
            try expect(n == "Contacts Postal Address Entity", "name '\(n)'")
            return "\(t): '\(n)'"
        })
        #endif

        // MARK: AuthenticationServices: ASWebAuthenticationSession on a loopback page (iOS: P8_Security.swift)
        #if canImport(AuthenticationServices) && !os(iOS)
        c.append(check("AuthenticationServices", "web-auth-loopback-port", timeout: 60) {
            let srv = try p8HTTP(); let port = try await srv.start(); defer { srv.stop() }
            let url = URL(string: "http://127.0.0.1:\(port)/auth?client=sdkcov")!
            let r = P9Box<String>()
            #if os(watchOS)
            let s = await onMain { () -> ASWebAuthenticationSession in
                let s = ASWebAuthenticationSession(url: url, callback: .customScheme("sdkcov-p8")) { cb, e in r.set(cb?.absoluteString ?? "error \(e.map(p9Err) ?? "nil")") }
                s.prefersEphemeralWebBrowserSession = true
                return s
            }
            let done: () -> Void = {}
            #else
            let (s, done) = try await onMain { () -> (ASWebAuthenticationSession, () -> Void) in
                let (w, done) = try p8Show(UIViewController())
                let s = ASWebAuthenticationSession(url: url, callback: .customScheme("sdkcov-p8")) { cb, e in r.set(cb?.absoluteString ?? "error \(e.map(p9Err) ?? "nil")") }
                #if os(visionOS)
                // (tvOS: no ephemeral sessions, no presentation context provider in the SDK)
                s.prefersEphemeralWebBrowserSession = true
                let a = P9WebAnchor(w); s.presentationContextProvider = a
                objc_setAssociatedObject(s, "p9anchor", a, .OBJC_ASSOCIATION_RETAIN)
                #else
                _ = w
                #endif
                return (s, done)
            }
            #endif
            defer { Task { @MainActor in done() } }
            let can = await onMain { s.canStart }
            let started = await onMain { s.start() }
            let res = await r.wait(started ? 30 : 3)
            #if !os(tvOS)
            if res == nil { await onMain { s.cancel() } }
            #endif
            let after = await r.wait(5)
            let reqs = srv.requests.withLock { $0.count }
            #if os(tvOS)
            // Apple's tvOS simulator: the session cannot start (canStart false, start() false), nothing is loaded
            try expect(!can && !started && res == nil && reqs == 0, "canStart \(can), start \(started), callback \(res ?? "none"), \(reqs) requests (Apple's tvOS simulator: false, false, none, 0)")
            #else
            // Apple's watchOS / visionOS simulators: the session starts and the loopback page's redirect is the callback
            try expect(can && started && res == "sdkcov-p8://callback?code=42&state=x86", "canStart \(can), start \(started), callback \(res ?? "none in 30 s") (\(reqs) requests)")
            #endif
            return "canStart \(can), start \(started), answer \(res ?? "none in 30 s"), after cancel \(after ?? "none"), \(reqs) request(s)"
        })
        #endif

        // MARK: SceneKit on watchOS: scene files, morpher, skinner, animation player (no SCNView / SCNRenderer needed)
        #if canImport(SceneKit) && os(watchOS)
        c.append(check("SceneKit", "watch-scene-file-morpher-skinner", timeout: 60) {
            let s = SCNScene()
            let box = SCNNode(geometry: SCNBox(width: 1, height: 2, length: 3, chamferRadius: 0)); box.name = "box"
            box.geometry?.firstMaterial?.diffuse.contents = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            let child = SCNNode(geometry: SCNSphere(radius: 0.5)); child.name = "ball"; child.position = SCNVector3(0, 3, 0); box.addChildNode(child)
            s.rootNode.addChildNode(box)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p9-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
            let scn = dir.appendingPathComponent("s.scn")
            // (no SCNScene.write on watchOS: a .scn file is the scene's keyed archive)
            try NSKeyedArchiver.archivedData(withRootObject: s, requiringSecureCoding: false).write(to: scn)
            guard let src = SCNSceneSource(url: scn, options: nil) else { throw Fail("SCNSceneSource") }
            let ids = src.identifiersOfEntries(withClass: SCNNode.self)
            let loaded = try src.scene(options: nil)
            let lb = loaded.rootNode.childNode(withName: "box", recursively: true)
            try expect((lb?.geometry as? SCNBox)?.length == 3, "box from .scn: \(String(describing: lb?.geometry))")
            try expect(lb?.childNode(withName: "ball", recursively: false)?.position.y == 3, "child position")
            // morpher: one target, weight 0.5
            let base = SCNPlane(width: 1, height: 1), target = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(-0.5, 1.5, 0), SCNVector3(0.5, 1.5, 0), SCNVector3(-0.5, 2.5, 0), SCNVector3(0.5, 2.5, 0)])], elements: [])
            let m = SCNMorpher(); m.targets = [target]; m.calculationMode = .additive; m.setWeight(0.5, forTargetAt: 0)
            let mn = SCNNode(geometry: base); mn.morpher = m; s.rootNode.addChildNode(mn)
            try expect(m.weight(forTargetAt: 0) == 0.5 && m.targets.count == 1 && m.calculationMode == .additive, "morpher")
            // skinner: two bones
            let bone0 = SCNNode(), bone1 = SCNNode(); bone1.position = SCNVector3(0, 1, 0); bone0.addChildNode(bone1); s.rootNode.addChildNode(bone0)
            let sg = SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0)
            let vc = sg.sources(for: .vertex).first!.vectorCount
            let weights = SCNGeometrySource(data: Data(bytes: [Float](repeating: 1, count: vc), count: vc * 4), semantic: .boneWeights, vectorCount: vc, usesFloatComponents: true, componentsPerVector: 1, bytesPerComponent: 4, dataOffset: 0, dataStride: 4)
            let idx = SCNGeometrySource(data: Data(bytes: [UInt16](repeating: 1, count: vc), count: vc * 2), semantic: .boneIndices, vectorCount: vc, usesFloatComponents: false, componentsPerVector: 1, bytesPerComponent: 2, dataOffset: 0, dataStride: 2)
            let sk = SCNSkinner(baseGeometry: sg, bones: [bone0, bone1], boneInverseBindTransforms: [NSValue(scnMatrix4: SCNMatrix4Identity), NSValue(scnMatrix4: SCNMatrix4Identity)], boneWeights: weights, boneIndices: idx)
            let skNode = SCNNode(geometry: sg); skNode.skinner = sk; s.rootNode.addChildNode(skNode)
            try expect(sk.bones.count == 2 && sk.boneWeights.vectorCount == vc && sk.boneIndices.vectorCount == vc, "skinner")
            // an action attached (no Core Animation on watchOS: SCNAction; run by a SceneView on screen, here attached and removed)
            let n = SCNNode(); s.rootNode.addChildNode(n)
            n.runAction(.sequence([.moveBy(x: 10, y: 0, z: 0, duration: 1), .fadeOut(duration: 0.5)]), forKey: "move")
            try expect(n.hasActions && n.actionKeys == ["move"] && abs((n.action(forKey: "move")?.duration ?? 0) - 1.5) < 0.001, "action keys \(n.actionKeys), duration \(String(describing: n.action(forKey: "move")?.duration))")
            n.removeAllActions()
            // the scene with all of it written and read back
            let all = dir.appendingPathComponent("all.scn")
            try NSKeyedArchiver.archivedData(withRootObject: s, requiringSecureCoding: false).write(to: all)
            let back = try SCNScene(url: all, options: nil)
            let morphed = back.rootNode.childNodes(passingTest: { n, _ in n.morpher != nil }).count, skinned = back.rootNode.childNodes(passingTest: { n, _ in n.skinner != nil }).count
            try expect(morphed == 1 && skinned == 1, "read back: \(morphed) morphed, \(skinned) skinned nodes")
            return ".scn \(ids.count) node entries; morpher 1 target @0.5, skinner 2 bones (\(vc) vertices), both kept through a .scn round trip"
        })
        #endif
        return c
    }
}
