// sdkcov P2: games. GameKit without a Game Center account (the answers Apple's simulator gives), GameplayKit
// (steering agents, minmax / Monte Carlo strategists, rule systems, entity-component systems, spatial trees, noise),
// GameController (snapshot controllers, the on-screen virtual controller, event interactions, the SwiftUI modifier),
// GameSave without iCloud and TouchController's unsupported answer.
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(GameKit)
import GameKit
#endif
#if canImport(GameplayKit)
import GameplayKit
import simd
#endif
#if canImport(GameController)
import GameController
#endif
#if canImport(_GameController_SwiftUI)
import _GameController_SwiftUI
#endif
#if canImport(GameSave)
import GameSave
#endif
#if canImport(TouchController)
import TouchController
import Metal
#endif

#if canImport(GameplayKit)
/// Nim: a pile of stones, take 1 or 2, whoever takes the last one wins
final class P2NimPlayer: NSObject, GKGameModelPlayer { let playerId: Int; init(_ i: Int) { playerId = i } }
final class P2NimMove: NSObject, GKGameModelUpdate { var value = 0; let take: Int; init(_ t: Int) { take = t } }
final class P2Nim: NSObject, GKGameModel {
    static let all = [P2NimPlayer(0), P2NimPlayer(1)]
    var pile = 5, current = 0
    var players: [GKGameModelPlayer]? { Self.all }
    var activePlayer: GKGameModelPlayer? { Self.all[current] }
    func setGameModel(_ m: GKGameModel) { let o = m as! P2Nim; pile = o.pile; current = o.current }
    func gameModelUpdates(for p: GKGameModelPlayer) -> [GKGameModelUpdate]? { pile == 0 ? nil : (1...min(2, pile)).map { P2NimMove($0) } }
    func apply(_ u: GKGameModelUpdate) { pile -= (u as! P2NimMove).take; current = 1 - current }
    func score(for p: GKGameModelPlayer) -> Int { 0 }
    func isWin(for p: GKGameModelPlayer) -> Bool { pile == 0 && current != p.playerId }
    func isLoss(for p: GKGameModelPlayer) -> Bool { pile == 0 && current == p.playerId }
    func copy(with zone: NSZone? = nil) -> Any { let c = P2Nim(); c.setGameModel(self); return c }
}
final class P2Counter: GKComponent {
    var ticks = 0, time: TimeInterval = 0
    override func update(deltaTime seconds: TimeInterval) { ticks += 1; time += seconds }
}
final class P2Element: NSObject { let name: String; init(_ n: String) { name = n } }
#endif

extension Registry {
    static var p2_games: [Check] {
        var c: [Check] = []
        // MARK: GameKit
        #if canImport(GameKit)
        c.append(check("GameKit", "unauthenticated-player-leaderboards-matchmaking", timeout: 60) {
            // no Game Center account in a fresh simulator: authentication answers, then the server calls fail with
            // notAuthenticated, as on Apple's simulator
            let p = GKLocalPlayer.local
            let auth = P2Count()
            await onMain {
                #if os(watchOS)
                p.authenticateHandler = { err in
                    if let err { auth.add("error \((err as NSError).domain) \((err as NSError).code)") }
                    else { auth.add(p.isAuthenticated ? "authenticated" : "no error") }
                }
                #else
                p.authenticateHandler = { vc, err in
                    if let err { auth.add("error \((err as NSError).domain) \((err as NSError).code)") }
                    else if vc != nil { auth.add("sign-in view controller") }
                    else { auth.add(p.isAuthenticated ? "authenticated" : "no error, no view controller") }
                }
                #endif
            }
            _ = await p2Wait(20) { auth.value > 0 }
            let how = auth.names.first ?? "handler not called in 20 s"
            try expect(!p.isAuthenticated, "authenticated without an account")
            func err(_ f: (@escaping (Error?) -> Void) -> Void) async -> String {
                await withCheckedContinuation { k in f { e in k.resume(returning: e.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "no error") } }
            }
            let lb = await err { done in GKLeaderboard.loadLeaderboards(IDs: ["sdkcov"]) { _, e in done(e) } }
            let ach = await err { done in GKAchievement.loadAchievements { _, e in done(e) } }
            let sub = await err { done in GKLeaderboard.submitScore(1, context: 0, player: p, leaderboardIDs: ["sdkcov"]) { e in done(e) } }
            // Apple's simulator: loads fail with GKError.notAuthenticated (6); a score submit returns no error
            try expect(lb == "\(GKErrorDomain) 6" && ach == "\(GKErrorDomain) 6", "server calls without an account: leaderboards \(lb), achievements \(ach), submit \(sub) (authenticate: \(how))")
            let mr = GKMatchRequest(); mr.minPlayers = 2; mr.maxPlayers = 4; mr.inviteMessage = "sdkcov"
            try expect(mr.minPlayers == 2 && mr.maxPlayers == 4 && GKMatchRequest.maxPlayersAllowedForMatch(of: .peerToPeer) >= 4, "match request")
            let a = GKAchievement(identifier: "sdkcov.first"); a.percentComplete = 50
            try expect(!a.isCompleted && a.percentComplete == 50, "achievement object")
            var ui = ""
            #if os(iOS) || os(tvOS) || os(visionOS)
            ui = try await onMain {
                let ap = GKAccessPoint.shared
                ap.location = .topLeading; ap.isActive = true
                let active = ap.isActive; ap.isActive = false
                let mm = GKMatchmakerViewController(matchRequest: mr)
                let gc = GKGameCenterViewController(state: .leaderboards)
                return ", access point active \(active), matchmaker VC \(mm != nil), Game Center VC \(gc.viewState.rawValue)"
            }
            #endif
            return "authenticate: \(how); leaderboards \(lb), achievements \(ach), submit \(sub)\(ui)"
        })
        #endif
        // MARK: GameplayKit
        #if canImport(GameplayKit)
        c.append(check("GameplayKit", "agents-strategists-rules-ecs-trees-noise", timeout: 60) {
            // steering: an agent seeks a target 100 pt away
            let target = GKAgent2D(); target.position = SIMD2<Float>(100, 0)
            let a = GKAgent2D(); a.maxSpeed = 50; a.maxAcceleration = 100; a.mass = 1
            a.behavior = GKBehavior(goal: GKGoal(toSeekAgent: target), weight: 1)
            for _ in 0..<60 { a.update(deltaTime: 1.0 / 30) }
            let dist = simd_distance(a.position, target.position)
            try expect(dist < 60 && a.position.x > 20, "seeking agent at \(a.position) (distance \(dist))")
            // strategists on Nim (5 stones, take 1-2): the winning move leaves a multiple of 3
            let mm = GKMinmaxStrategist(); mm.gameModel = P2Nim(); mm.maxLookAheadDepth = 6
            let best = (mm.bestMoveForActivePlayer() as? P2NimMove)?.take
            try expect(best == 2, "minmax move \(String(describing: best))")
            let mc = GKMonteCarloStrategist(); mc.gameModel = P2Nim(); mc.budget = 400; mc.explorationParameter = 1
            mc.randomSource = GKMersenneTwisterRandomSource(seed: 7)
            let mcMove = (mc.bestMoveForActivePlayer() as? P2NimMove)?.take
            try expect(mcMove == 1 || mcMove == 2, "Monte Carlo move \(String(describing: mcMove))")
            // rules
            let rs = GKRuleSystem()
            rs.add(GKRule(predicate: NSPredicate(format: "state.speed > 10"), assertingFact: "fast" as NSString, grade: 1))
            rs.add(GKRule(predicate: NSPredicate(format: "state.speed > 100"), assertingFact: "racing" as NSString, grade: 0.7))
            rs.state["speed"] = 12; rs.evaluate()
            try expect(rs.grade(forFact: "fast" as NSString) == 1 && rs.grade(forFact: "racing" as NSString) == 0, "rule grades \(rs.facts)")
            // entity-component system
            let sys = GKComponentSystem(componentClass: P2Counter.self)
            let ent = GKEntity(); ent.addComponent(P2Counter()); sys.addComponent(foundIn: ent)
            for _ in 0..<3 { sys.update(deltaTime: 0.5) }
            let cnt = ent.component(ofType: P2Counter.self)
            try expect(cnt?.ticks == 3 && cnt?.time == 1.5, "component updates \(String(describing: cnt?.ticks))")
            // spatial trees
            let qt = GKQuadtree<P2Element>(boundingQuad: GKQuad(quadMin: SIMD2<Float>(0, 0), quadMax: SIMD2<Float>(100, 100)), minimumCellSize: 1)
            for (n, p) in [("a", SIMD2<Float>(10, 10)), ("b", SIMD2<Float>(90, 90)), ("c", SIMD2<Float>(12, 14))] { qt.add(P2Element(n), at: p) }
            let near = qt.elements(in: GKQuad(quadMin: SIMD2<Float>(0, 0), quadMax: SIMD2<Float>(20, 20))).map(\.name).sorted()
            try expect(near == ["a", "c"], "quadtree query \(near)")
            let rt = GKRTree<P2Element>(maxNumberOfChildren: 4)
            for i in 0..<20 { rt.addElement(P2Element("r\(i)"), boundingRectMin: SIMD2<Float>(Float(i * 10), 0), boundingRectMax: SIMD2<Float>(Float(i * 10 + 5), 5), splitStrategy: .linear) }
            let hits = rt.elements(inBoundingRectMin: SIMD2<Float>(0, 0), rectMax: SIMD2<Float>(32, 5)).map(\.name).sorted()
            try expect(hits == ["r0", "r1", "r2"], "R-tree query \(hits) (rects inside 0...32: r3 spans 30...35)")
            // noise
            let noise = GKNoise(GKPerlinNoiseSource(frequency: 2, octaveCount: 3, persistence: 0.5, lacunarity: 2, seed: 42))
            let map = GKNoiseMap(noise, size: SIMD2<Double>(1, 1), origin: SIMD2<Double>(0, 0), sampleCount: SIMD2<Int32>(16, 16), seamless: false)
            let vals = (0..<16).map { map.value(at: SIMD2<Int32>(Int32($0), 7)) }
            try expect(vals.allSatisfy { $0 >= -1.01 && $0 <= 1.01 } && Set(vals).count > 8, "noise values \(vals.prefix(4))")
            let r1 = GKARC4RandomSource(seed: Data([1, 2, 3])), r2 = GKARC4RandomSource(seed: Data([1, 2, 3]))
            try expect((0..<5).map { _ in r1.nextInt() } == (0..<5).map { _ in r2.nextInt() }, "seeded random sources")
            return "agent at x \(Int(a.position.x)), minmax takes \(best!), Monte Carlo \(mcMove!), rules, ECS, quadtree \(near), R-tree \(hits.count), noise"
        })
        #endif
        // MARK: GameController
        #if canImport(GameController) && !os(watchOS)
        c.append(check("GameController", "snapshot-controller-profile-input", timeout: 30) {
            // a snapshot controller (no hardware): element values set and read back through the extended profile
            let ctl = GCController.withExtendedGamepad()
            guard let pad = ctl.extendedGamepad else { throw Fail("no extended gamepad on the snapshot controller") }
            try expect(ctl.isSnapshot, "isSnapshot")
            pad.buttonA.setValue(1); pad.leftThumbstick.setValueForXAxis(0.5, yAxis: -0.25); pad.rightTrigger.setValue(0.75)
            try expect(pad.buttonA.isPressed && pad.buttonA.value == 1, "button A \(pad.buttonA.value)")
            try expect(pad.leftThumbstick.xAxis.value == 0.5 && pad.leftThumbstick.yAxis.value == -0.25, "thumbstick \(pad.leftThumbstick.xAxis.value),\(pad.leftThumbstick.yAxis.value)")
            try expect(abs(pad.rightTrigger.value - 0.75) < 1e-4, "trigger \(pad.rightTrigger.value)")
            let prof = ctl.physicalInputProfile
            let names = Set(prof.buttons.keys)
            try expect(names.contains(GCInputButtonA) && names.contains(GCInputRightTrigger), "profile buttons \(names.count)")
            let cap = ctl.capture()
            try expect(cap.isSnapshot && cap.extendedGamepad?.buttonA.value == 1, "captured snapshot")
            let micro = GCController.withMicroGamepad()
            try expect(micro.microGamepad != nil && micro.extendedGamepad == nil, "micro gamepad snapshot")
            return "extended snapshot: A 1, stick (0.5,-0.25), trigger 0.75; \(names.count) profile buttons; micro snapshot; \(GCController.controllers().count) connected controllers"
        })
        #endif
        #if canImport(GameController) && os(iOS)
        c.append(check("GameController", "virtual-controller-connect", timeout: 60) {
            let cfg = GCVirtualController.Configuration()
            cfg.elements = [GCInputLeftThumbstick, GCInputButtonA, GCInputButtonB]
            let vc = await onMain { GCVirtualController(configuration: cfg) }
            let before = GCController.controllers().count
            do { try await vc.connect() } catch { throw Fail("connect: \(error)") }
            let got = await p2Wait(10) { vc.controller != nil && GCController.controllers().contains { $0 === vc.controller } }
            let n = GCController.controllers().count
            let elems = await onMain { vc.controller?.physicalInputProfile.buttons.keys.sorted() ?? [] }
            await onMain { vc.disconnect() }
            let gone = await p2Wait(10) { !GCController.controllers().contains { $0 === vc.controller } || vc.controller == nil }
            try expect(got, "the virtual controller never appeared in GCController.controllers() (\(before) -> \(n))")
            try expect(gone, "still connected after disconnect")
            return "virtual controller connected (\(before) -> \(n) controllers), buttons \(elems), disconnected"
        })
        #endif
        #if canImport(GameController) && (os(iOS) || os(visionOS))
        c.append(check("GameController", "event-interaction", timeout: 30) {
            try await onMain {
                let v = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
                let gi = GCEventInteraction(); gi.handledEventTypes = .gamepad
                v.addInteraction(gi)
                try expect(v.interactions.contains { $0 === gi } && gi.view === v, "interaction attached")
                try expect(gi.handledEventTypes == .gamepad, "handled types")
                v.removeInteraction(gi)
                try expect(gi.view == nil, "detached")
                return "GCEventInteraction attached / detached (gamepad events)"
            }
        })
        #endif
        #if canImport(_GameController_SwiftUI) && (os(iOS) || os(visionOS))
        c.append(check("_GameController_SwiftUI", "handles-game-controller-events-modifier", timeout: 30) {
            let shown = P2Count()
            let (_, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: Text("sdkcov").padding().handlesGameControllerEvents(matching: .gamepad).onAppear { shown.add() })
                let (_, done) = try p2ShowVC(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            let ok = await p2Wait(10) { shown.value > 0 }
            try expect(ok, "the view with .handlesGameControllerEvents never appeared")
            return "view with .handlesGameControllerEvents(matching: .gamepad) on screen"
        })
        #endif
        // MARK: GameSave
        #if canImport(GameSave)
        c.append(check("GameSave", "synced-directory-without-icloud", timeout: 60) {
            let d = GameSaveSyncedDirectory.openDirectory()
            var states: [String] = []
            for _ in 0..<40 {
                let s = "\(d.state)"; if states.last != s { states.append(s) }
                if case .syncing = d.state { try await Task.sleep(for: .milliseconds(250)); continue }
                break
            }
            await d.finishSyncing()
            let after = "\(d.state)"
            var wrote = "-"
            switch d.state {
            case .ready(let u), .offline(let u), .local(let u):
                let f = u.appendingPathComponent("sdkcov-save.json")
                try Data("{\"level\":3}".utf8).write(to: f)
                wrote = (try? Data(contentsOf: f)).map { "\($0.count) B written in \(u.lastPathComponent)" } ?? "write failed"
                try? FileManager.default.removeItem(at: f)
            default: break
            }
            d.close()
            let closed = "\(d.state)"
            try expect(closed == "closed" || closed.contains("closed"), "after close: \(closed)")
            return "states \(states) -> after finishSyncing \(after); \(wrote); closed"
        })
        #endif
        // MARK: TouchController
        #if canImport(TouchController) && os(visionOS)
        c.append(check("TouchController", "visionos-runtime-unsupported", timeout: 30) {
            // the visionOS SDK marks TouchController unavailable; the runtime ships it and answers isSupported false
            _ = dlopen("/System/Library/Frameworks/TouchController.framework/TouchController", RTLD_NOW)
            guard let cls = NSClassFromString("TCTouchController") else { throw Fail("no TCTouchController class in the runtime (dlopen: \(String(cString: dlerror())))") }
            let sup = (cls as AnyObject).value(forKey: "isSupported") as? Bool
            try expect(sup == false, "TCTouchController.isSupported \(String(describing: sup))")
            return "TCTouchController class present, isSupported false"
        })
        #endif
        #if canImport(TouchController) && os(iOS)
        c.append(check("TouchController", "simulator-unsupported-descriptor", timeout: 30) {
            try await onMain {
                // TCTouchController.isSupported is false in Apple's simulators (no touch-screen game controller there)
                let sup = TCTouchController.isSupported
                try expect(!sup, "TCTouchController.isSupported true in a simulator")
                let dev = try p2Dev()
                let desc = TCTouchControllerDescriptor(); desc.device = dev
                desc.size = CGSize(width: 400, height: 200); desc.drawableSize = CGSize(width: 400, height: 200); desc.colorPixelFormat = .bgra8Unorm
                try expect(desc.size.width == 400 && desc.device === dev, "descriptor")
                let bd = TCButtonDescriptor(); bd.label = TCControlLabel.buttonA
                try expect(bd.label.name == TCControlLabel.buttonA.name, "button descriptor label")
                return "isSupported false; descriptor + button descriptor built (no controller made where unsupported)"
            }
        })
        #endif
        return c
    }
}
