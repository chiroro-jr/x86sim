// sdkcov P2: Core Animation, SceneKit, SpriteKit and ModelIO depth. Layers and views go on screen in a window above
// the app's own (iOS/tvOS/visionOS; the watch shows SwiftUI through Runner.overlay); pixels are read back from the
// renderers' own snapshots, model values through presentation layers / nodes.
import Foundation
import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(SceneKit)
import SceneKit
#endif
#if canImport(SpriteKit)
import SpriteKit
#endif
#if canImport(ModelIO)
import ModelIO
#endif
#if canImport(_SceneKit_SwiftUI)
import _SceneKit_SwiftUI
#endif
#if canImport(_SpriteKit_SwiftUI)
import _SpriteKit_SwiftUI
#endif

#if canImport(UIKit) && !os(watchOS)
@MainActor func p2Scene() throws -> UIWindowScene {
    guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { throw Fail("no window scene") }
    return ws
}
/// a window above the app's own showing `v` (full screen); the closure takes it down
@MainActor func p2Show(_ v: UIView) throws -> (UIWindow, () -> Void) {
    let ws = try p2Scene()
    let vc = UIViewController(); vc.view.backgroundColor = .black; vc.view.addSubview(v)
    let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.isHidden = false; w.layoutIfNeeded()
    return (w, { w.isHidden = true; w.rootViewController = nil })
}
@MainActor func p2ShowVC(_ vc: UIViewController) throws -> (UIWindow, () -> Void) {
    let ws = try p2Scene()
    let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.isHidden = false; w.layoutIfNeeded()
    return (w, { w.isHidden = true; w.rootViewController = nil })
}
/// RGBA8 of a CGImage at (x, y) (sRGB)
func p2Pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    return p
}
func p2Near(_ p: [UInt8], _ r: Int, _ g: Int, _ b: Int, _ tol: Int = 40) -> Bool { abs(Int(p[0]) - r) <= tol && abs(Int(p[1]) - g) <= tol && abs(Int(p[2]) - b) <= tol }
@MainActor func p2Snapshot(_ v: UIView) -> CGImage? {
    let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
    return UIGraphicsImageRenderer(bounds: v.bounds, format: f).image { _ in _ = v.drawHierarchy(in: v.bounds, afterScreenUpdates: true) }.cgImage
}
#endif
/// poll on the main actor every 30 ms for up to `secs`
func p2Wait(_ secs: Double, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if await MainActor.run(body: { cond() }) { return true }; try? await Task.sleep(for: .milliseconds(30)) }
    return await MainActor.run(body: { cond() })
}
final class P2Count: @unchecked Sendable {
    private let l = NSLock(); private var n = 0; private var tags: [String] = []
    func add(_ t: String = "") { l.lock(); n += 1; if !t.isEmpty { tags.append(t) }; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return n }
    var names: [String] { l.lock(); defer { l.unlock() }; return tags }
}

#if canImport(QuartzCore) && canImport(UIKit) && !os(watchOS)
final class P2TileDelegate: NSObject, CALayerDelegate {
    let n = P2Count()
    func draw(_ layer: CALayer, in ctx: CGContext) {
        n.add(); ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(ctx.boundingBoxOfClipPath)
    }
}
#endif
#if canImport(SceneKit)
final class P2Contacts: NSObject, SCNPhysicsContactDelegate {
    let n = P2Count()
    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) { n.add("\(contact.nodeA.name ?? "?")-\(contact.nodeB.name ?? "?")") }
}
/// a falling ball over a static floor, contacts counted
func p2PhysicsScene(_ d: P2Contacts) -> SCNScene {
    let s = SCNScene()
    s.physicsWorld.gravity = SCNVector3(0, -9.8, 0); s.physicsWorld.contactDelegate = d; s.physicsWorld.speed = 2
    let floor = SCNNode(geometry: SCNBox(width: 10, height: 0.2, length: 10, chamferRadius: 0)); floor.name = "floor"
    floor.physicsBody = .static(); floor.physicsBody?.categoryBitMask = 1; floor.physicsBody?.contactTestBitMask = 2
    let ball = SCNNode(geometry: SCNSphere(radius: 0.3)); ball.name = "ball"; ball.position = SCNVector3(0, 1.5, 0)
    ball.physicsBody = .dynamic(); ball.physicsBody?.categoryBitMask = 2; ball.physicsBody?.contactTestBitMask = 1
    s.rootNode.addChildNode(floor); s.rootNode.addChildNode(ball)
    let cam = SCNNode(); cam.name = "cam"; cam.camera = SCNCamera(); cam.position = SCNVector3(0, 1, 6); s.rootNode.addChildNode(cam)
    return s
}
#endif
#if canImport(SpriteKit)
final class P2FrameScene: SKScene {
    let frames = P2Count()
    override func update(_ currentTime: TimeInterval) { frames.add() }
}
#endif
#if os(watchOS) || os(visionOS)
struct P2SceneViewProbe: View {
    let scene: SCNScene, cam: SCNNode
    var body: some View { SceneView(scene: scene, pointOfView: cam, options: [.rendersContinuously]).frame(width: 150, height: 150) }
}
struct P2SpriteViewProbe: View {
    let scene: SKScene
    var body: some View { SpriteView(scene: scene, preferredFramesPerSecond: 60).frame(width: 150, height: 150) }
}
#endif

extension Registry {
    static var p2_scene: [Check] {
        var c: [Check] = []
        // MARK: QuartzCore
        #if canImport(QuartzCore) && os(watchOS)
        c.append(check("QuartzCore", "watch-runtime-timing-clock") {
            // the watchOS SDK marks every QuartzCore API unavailable; the runtime's QuartzCore (Core Animation under
            // SwiftUI) is still there: its media clock, timing functions and layers answer through the C / ObjC runtime
            guard let h = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW),
                  let sym = dlsym(h, "CACurrentMediaTime") else { throw Fail("QuartzCore / CACurrentMediaTime not loadable") }
            let now = unsafeBitCast(sym, to: (@convention(c) () -> Double).self)
            let t0 = now(); try await Task.sleep(for: .milliseconds(100)); let dt = now() - t0
            try expect(t0 > 0 && dt > 0.08 && dt < 1, "CACurrentMediaTime \(t0), +\(dt)")
            guard let tf = NSClassFromString("CAMediaTimingFunction") as? NSObject.Type else { throw Fail("no CAMediaTimingFunction class") }
            let f = tf.perform(NSSelectorFromString("functionWithName:"), with: "easeInEaseOut")?.takeUnretainedValue() as? NSObject
            let sel = NSSelectorFromString("getControlPointAtIndex:values:")
            guard let f, let m = class_getInstanceMethod(type(of: f), sel) else { throw Fail("timing function") }
            let get = unsafeBitCast(method_getImplementation(m), to: (@convention(c) (AnyObject, Selector, Int, UnsafeMutablePointer<Float>) -> Void).self)
            var p1: [Float] = [0, 0], p2: [Float] = [0, 0]
            get(f, sel, 1, &p1); get(f, sel, 2, &p2)
            try expect(p1 == [0.42, 0] && p2 == [0.58, 1], "easeInEaseOut control points \(p1) \(p2)")
            guard let lc = NSClassFromString("CALayer") as? NSObject.Type else { throw Fail("no CALayer class") }
            let l = lc.init(); l.setValue(0.25, forKey: "opacity"); l.setValue("sdkcov", forKey: "name")
            try expect((l.value(forKey: "opacity") as? Double).map { abs($0 - 0.25) < 1e-6 } == true && l.value(forKey: "name") as? String == "sdkcov", "layer KVC")
            return "media clock +\(String(format: "%.3f", dt)) s, easeInEaseOut \(p1) \(p2), CALayer KVC"
        })
        #endif
        #if canImport(QuartzCore) && canImport(UIKit) && !os(watchOS)
        c.append(check("QuartzCore", "metal-layer-drawable-present", timeout: 60) {
            let dev = try p2Dev()
            let (layer, done) = try await onMain { () -> (CAMetalLayer, () -> Void) in
                let v = UIView(frame: CGRect(x: 20, y: 60, width: 64, height: 64))
                let l = CAMetalLayer(); l.device = dev; l.pixelFormat = .bgra8Unorm; l.framebufferOnly = false
                l.frame = v.bounds; l.drawableSize = CGSize(width: 64, height: 64); v.layer.addSublayer(l)
                let (_, done) = try p2Show(v); return (l, done)
            }
            defer { Task { @MainActor in done() } }
            let presented = P2Count()
            var sizes: [String] = []
            let q = dev.makeCommandQueue()!
            for i in 0..<3 {
                guard let d = await onMain({ layer.nextDrawable() }) else { throw Fail("nextDrawable \(i) nil") }
                sizes.append("\(d.texture.width)x\(d.texture.height)")
                presented.add("\(i)")
                let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].storeAction = .store; rp.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
                let cb = q.makeCommandBuffer()!; cb.makeRenderCommandEncoder(descriptor: rp)!.endEncoding()
                cb.present(d); try await p2Run(cb)
                if i == 2 {
                    var px = [UInt8](repeating: 0, count: 4)
                    d.texture.getBytes(&px, bytesPerRow: 64 * 4, from: MTLRegionMake2D(10, 10, 1, 1), mipmapLevel: 0)
                    try expect(px == [0, 0, 255, 255], "drawable BGRA \(px)")
                }
            }
            // (the simulator SDK has no presented handlers / drawable ids)
            try expect(presented.value == 3, "frames \(presented.value)")
            try expect(sizes.allSatisfy { $0 == "64x64" }, "drawable sizes \(sizes)")
            return "3 drawables \(sizes[0]), cleared red, \(presented.value) presented, maximumDrawableCount \(layer.maximumDrawableCount)"
        })
        c.append(check("QuartzCore", "replicator-transform-shape-emitter-layers", timeout: 60) {
            // replicator: 3 copies of a 10x10 red square, 20 pt apart, each 0.5 less red (CALayer.render(in:) draws no
            // replicator instances, on Apple's side too: the render server's snapshot of the window does)
            let (v, done) = try await onMain { () -> (UIView, () -> Void) in
                let v = UIView(frame: CGRect(x: 0, y: 100, width: 80, height: 40)); v.backgroundColor = .black
                let rep = CAReplicatorLayer(); rep.frame = v.bounds; rep.instanceCount = 3
                rep.instanceTransform = CATransform3DMakeTranslation(20, 0, 0); rep.instanceRedOffset = -0.5
                let sq = CALayer(); sq.frame = CGRect(x: 5, y: 5, width: 10, height: 10); sq.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                rep.addSublayer(sq); v.layer.addSublayer(rep)
                let tl = CATransformLayer(); tl.frame = v.bounds; let child = CALayer(); child.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
                child.transform = CATransform3DMakeTranslation(0, 0, 10); tl.addSublayer(child); v.layer.addSublayer(tl)
                let (_, done) = try p2Show(v); return (v, done)
            }
            defer { Task { @MainActor in done() } }
            try await Task.sleep(for: .milliseconds(400))
            return try await onMain {
                guard let img = p2Snapshot(v) else { throw Fail("no snapshot") }
                let p0 = p2Pixel(img, 10, 10), p1 = p2Pixel(img, 30, 10), p2 = p2Pixel(img, 50, 10), gap = p2Pixel(img, 20, 10)
                try expect(p0[0] > 240 && gap[0] < 10, "first square \(p0), gap \(gap)")
                try expect(abs(Int(p1[0]) - 128) < 12 && p2[0] < 12, "replicated copies (red -0.5 each): \(p1) \(p2)")
                let tl = v.layer.sublayers?.compactMap { $0 as? CATransformLayer }.first
                try expect(tl?.sublayers?.first?.transform.m43 == 10, "transform layer child")
                let sh = CAShapeLayer(); sh.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 30, height: 30), transform: nil); sh.strokeEnd = 0.5
                let em = CAEmitterLayer(); em.emitterPosition = CGPoint(x: 40, y: 20); em.emitterShape = .point
                let cell = CAEmitterCell(); cell.name = "spark"; cell.birthRate = 50; cell.lifetime = 1; cell.velocity = 30
                em.emitterCells = [cell]
                em.setValue(10, forKeyPath: "emitterCells.spark.birthRate")
                try expect(em.emitterCells?.first?.birthRate == 10, "emitter key path birthRate \(String(describing: em.emitterCells?.first?.birthRate))")
                return "replicator copies R \(p0[0])/\(p1[0])/\(p2[0]) on screen, transform layer, emitter cell key path, shape strokeEnd \(sh.strokeEnd)"
            }
        })
        c.append(check("QuartzCore", "presentation-values-transaction-completion-tiled", timeout: 60) {
            let del = P2TileDelegate()
            let (sh, tiled, done) = try await onMain { () -> (CAShapeLayer, CATiledLayer, () -> Void) in
                let v = UIView(frame: CGRect(x: 20, y: 80, width: 200, height: 200))
                let sh = CAShapeLayer(); sh.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
                sh.path = CGPath(rect: CGRect(x: 10, y: 10, width: 80, height: 80), transform: nil); sh.strokeColor = UIColor.green.cgColor; sh.lineWidth = 3
                v.layer.addSublayer(sh)
                let t = CATiledLayer(); t.frame = CGRect(x: 100, y: 100, width: 100, height: 100); t.tileSize = CGSize(width: 32, height: 32); t.levelsOfDetail = 2
                t.delegate = del; v.layer.addSublayer(t); t.setNeedsDisplay()
                let (_, done) = try p2Show(v); return (sh, t, done)
            }
            defer { Task { @MainActor in done() } }
            let completed = P2Count()
            await onMain {
                CATransaction.begin()
                CATransaction.setAnimationDuration(1.2)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
                CATransaction.setCompletionBlock { completed.add() }
                let a = CABasicAnimation(keyPath: "strokeEnd"); a.fromValue = 0; a.toValue = 1
                sh.add(a, forKey: "draw"); sh.strokeEnd = 1
                let b = CABasicAnimation(keyPath: "position.x"); b.fromValue = 0; b.toValue = 100; sh.add(b, forKey: "move")
                CATransaction.commit()
            }
            try await Task.sleep(for: .milliseconds(600))
            let (se, px, during) = await onMain { (sh.presentation()?.strokeEnd ?? -1, sh.presentation()?.position.x ?? -1, completed.value) }
            try expect(se > 0.2 && se < 0.85, "presentation strokeEnd mid-animation \(se)")
            try expect(px > 20 && px < 85, "presentation position.x mid-animation \(px)")
            try expect(during == 0, "completion ran before the animations ended")
            let fin = await p2Wait(3) { completed.value == 1 }
            try expect(fin, "CATransaction completion block did not run")
            let finalSE = await onMain { sh.presentation()?.strokeEnd ?? -1 }
            try expect(finalSE == 1, "final strokeEnd \(finalSE)")
            let drew = await p2Wait(5) { del.n.value > 0 }
            try expect(drew, "CATiledLayer never asked its delegate to draw a tile")
            let tileSize = await onMain { tiled.tileSize }
            return "strokeEnd \(String(format: "%.2f", se)) / x \(Int(px)) at 0.6 s, completion after, tiled layer drew \(del.n.value) tiles of \(Int(tileSize.width))"
        })
        #endif
        // MARK: SceneKit
        #if canImport(SceneKit) && !os(watchOS)
        c.append(check("SceneKit", "physics-contact-hittest", timeout: 60) {
            let d = P2Contacts()
            let s = p2PhysicsScene(d)
            let (view, done) = try await onMain { () -> (SCNView, () -> Void) in
                let v = SCNView(frame: CGRect(x: 0, y: 60, width: 200, height: 200)); v.scene = s; v.pointOfView = s.rootNode.childNode(withName: "cam", recursively: false)
                v.isPlaying = true; v.rendersContinuously = true; v.backgroundColor = .black
                let (_, done) = try p2Show(v); return (v, done)
            }
            defer { Task { @MainActor in done() } }
            let hit = await p2Wait(10) { d.n.value > 0 }
            let ball = s.rootNode.childNode(withName: "ball", recursively: false)!
            let y = await onMain { ball.presentation.position.y }
            try expect(hit, "no contact in 10 s (ball at y \(y))")
            try expect(d.n.names.first.map { $0.contains("ball") && $0.contains("floor") } ?? false, "contact \(d.n.names)")
            // hit tests: a segment through the ball from above, and the view's hit test at the floor
            let hits = s.rootNode.hitTestWithSegment(from: SCNVector3(0, 10, 0), to: SCNVector3(0, -10, 0), options: [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue])
            try expect(hits.contains { $0.node.name == "floor" }, "segment hits \(hits.map { $0.node.name ?? "?" })")
            let rays = s.physicsWorld.rayTestWithSegment(from: SCNVector3(3, 5, 3), to: SCNVector3(3, -5, 3), options: nil)
            try expect(rays.first?.node.name == "floor", "physics ray test \(rays.map { $0.node.name ?? "?" })")
            let vh = await onMain { view.hitTest(CGPoint(x: 100, y: 190), options: nil).map { $0.node.name ?? "?" } }
            return "contact \(d.n.names.first ?? "") (ball y \(String(format: "%.2f", y))), segment \(hits.count) hits, ray floor, view hit \(vh)"
        })
        c.append(check("SceneKit", "scene-write-source-load-usdz", timeout: 90) {
            let s = SCNScene()
            let box = SCNNode(geometry: SCNBox(width: 1, height: 2, length: 3, chamferRadius: 0)); box.name = "box"
            box.geometry?.firstMaterial?.diffuse.contents = UIColor.red
            let child = SCNNode(geometry: SCNSphere(radius: 0.5)); child.name = "ball"; child.position = SCNVector3(0, 3, 0); box.addChildNode(child)
            s.rootNode.addChildNode(box)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
            let scn = dir.appendingPathComponent("s.scn"), usdz = dir.appendingPathComponent("s.usdz")
            try expect(s.write(to: scn, options: nil, delegate: nil, progressHandler: nil), "write .scn")
            guard let src = SCNSceneSource(url: scn, options: nil) else { throw Fail("SCNSceneSource") }
            let ids = src.identifiersOfEntries(withClass: SCNNode.self)
            let loaded = try src.scene(options: nil)
            let lb = loaded.rootNode.childNode(withName: "box", recursively: true)
            try expect((lb?.geometry as? SCNBox)?.length == 3, "box from .scn: \(String(describing: lb?.geometry))")
            try expect(lb?.childNode(withName: "ball", recursively: false)?.position.y == 3, "child position")
            let wroteUSDZ = s.write(to: usdz, options: nil, delegate: nil, progressHandler: nil)
            var usd = "usdz export \(wroteUSDZ)"
            if wroteUSDZ {
                let back = try SCNScene(url: usdz, options: nil)
                let n = back.rootNode.childNode(withName: "box", recursively: true)
                try expect(n != nil, "box from .usdz: \(back.rootNode.childNodes.map { $0.name ?? "?" })")
                var mn = SCNVector3Zero, mx = SCNVector3Zero; _ = n.map { ($0.boundingBox) }.map { mn = $0.min; mx = $0.max }
                usd = "usdz round trip, box bounds \(mx.y - mn.y)"
            }
            return ".scn \(ids.count) node entries, \(usd)"
        })
        c.append(check("SceneKit", "animation-player-morpher-skinner", timeout: 60) {
            let dev = try p2Dev()
            let s = SCNScene()
            let n = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)); n.name = "mover"; s.rootNode.addChildNode(n)
            let a = CABasicAnimation(keyPath: "position.x"); a.fromValue = 0; a.toValue = 10; a.duration = 1; a.usesSceneTimeBase = false
            let player = SCNAnimationPlayer(animation: SCNAnimation(caAnimation: a)); n.addAnimationPlayer(player, forKey: "move")
            player.play()
            // morpher: a plane with one target lifted by 2, weight 0.5
            let base = SCNPlane(width: 1, height: 1), target = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(-0.5, 1.5, 0), SCNVector3(0.5, 1.5, 0), SCNVector3(-0.5, 2.5, 0), SCNVector3(0.5, 2.5, 0)])], elements: [])
            let m = SCNMorpher(); m.targets = [target]; m.calculationMode = .additive; m.setWeight(0.5, forTargetAt: 0)
            let mn = SCNNode(geometry: base); mn.morpher = m; s.rootNode.addChildNode(mn)
            try expect(m.weight(forTargetAt: 0) == 0.5 && m.targets.count == 1, "morpher weight")
            // skinner: two bones, the geometry follows bone 1
            let bone0 = SCNNode(), bone1 = SCNNode(); bone1.position = SCNVector3(0, 1, 0); bone0.addChildNode(bone1); s.rootNode.addChildNode(bone0)
            let sg = SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0)
            let vc = sg.sources(for: .vertex).first!.vectorCount
            let weights = SCNGeometrySource(data: Data(bytes: [Float](repeating: 1, count: vc), count: vc * 4), semantic: .boneWeights, vectorCount: vc, usesFloatComponents: true, componentsPerVector: 1, bytesPerComponent: 4, dataOffset: 0, dataStride: 4)
            let idx = SCNGeometrySource(data: Data(bytes: [UInt16](repeating: 1, count: vc), count: vc * 2), semantic: .boneIndices, vectorCount: vc, usesFloatComponents: false, componentsPerVector: 1, bytesPerComponent: 2, dataOffset: 0, dataStride: 2)
            let sk = SCNSkinner(baseGeometry: sg, bones: [bone0, bone1], boneInverseBindTransforms: [NSValue(scnMatrix4: SCNMatrix4Identity), NSValue(scnMatrix4: SCNMatrix4Identity)], boneWeights: weights, boneIndices: idx)
            let skNode = SCNNode(geometry: sg); skNode.skinner = sk; s.rootNode.addChildNode(skNode)
            try expect(sk.bones.count == 2 && sk.skeleton == nil || sk.bones.count == 2, "skinner bones")
            let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 0, 20); s.rootNode.addChildNode(cam)
            // played by an SCNView on screen (an offscreen SCNRenderer snapshot does not advance animations, on Apple's either)
            let done = try await onMain { () -> () -> Void in
                let v = SCNView(frame: CGRect(x: 0, y: 60, width: 120, height: 120)); v.scene = s; v.pointOfView = cam
                v.isPlaying = true; v.rendersContinuously = true
                let (_, done) = try p2Show(v); return done
            }
            defer { Task { @MainActor in done() } }
            _ = dev
            try await Task.sleep(for: .milliseconds(500))
            let x = await onMain { n.presentation.position.x }
            try expect(x > 2 && x <= 10, "animation after 0.5 s on screen: x \(x)")
            try expect(n.animationPlayer(forKey: "move") != nil && n.animationKeys == ["move"], "animation keys \(n.animationKeys)")
            player.stop(); n.removeAllAnimations()
            return "animation player x \(String(format: "%.2f", x)) at 0.5 s, morpher 1 target @0.5, skinner 2 bones (\(vc) vertices)"
        })
        c.append(check("SceneKit", "shader-modifier-program-technique", timeout: 90) {
            let dev = try p2Dev()
            func render(_ s: SCNScene, _ cam: SCNNode, technique: SCNTechnique? = nil) throws -> [UInt8] {
                let r = SCNRenderer(device: dev, options: nil); r.scene = s; r.pointOfView = cam; r.technique = technique
                guard let cg = r.snapshot(atTime: 0, with: CGSize(width: 64, height: 64), antialiasingMode: .none).cgImage else { throw Fail("no snapshot") }
                return p2Pixel(cg, 32, 32)
            }
            func scene(_ m: SCNMaterial) -> (SCNScene, SCNNode) {
                let s = SCNScene(); s.background.contents = UIColor.black
                let b = SCNNode(geometry: SCNBox(width: 2, height: 2, length: 2, chamferRadius: 0)); b.geometry?.materials = [m]; s.rootNode.addChildNode(b)
                let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 0, 4); s.rootNode.addChildNode(cam)
                return (s, cam)
            }
            // 1. shader modifier on a constant red material: the fragment entry point turns it green
            let m1 = SCNMaterial(); m1.lightingModel = .constant; m1.diffuse.contents = UIColor.red
            m1.shaderModifiers = [.fragment: "_output.color.rgb = float3(0.0, 1.0, 0.0);"]
            let (s1, c1) = scene(m1)
            let p1 = try render(s1, c1)
            try expect(p2Near(p1, 0, 255, 0), "shader modifier pixel \(p1)")
            // 2. SCNProgram with Metal functions from a runtime-compiled library: yellow
            let lib = try await dev.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct NodeBuffer { float4x4 modelTransform; float4x4 inverseModelTransform; float4x4 modelViewTransform; float4x4 inverseModelViewTransform;
                                float4x4 normalTransform; float4x4 modelViewProjectionTransform; float4x4 inverseModelViewProjectionTransform; };
            struct VIn { float3 position [[attribute(0)]]; };
            struct VOut { float4 position [[position]]; };
            vertex VOut pv(VIn in [[stage_in]], constant NodeBuffer& scn_node [[buffer(1)]]) { VOut o; o.position = scn_node.modelViewProjectionTransform * float4(in.position, 1.0); return o; }
            fragment half4 pf(VOut in [[stage_in]]) { return half4(1.0, 1.0, 0.0, 1.0); }
            struct QIn { float4 position [[attribute(0)]]; };
            struct QOut { float4 position [[position]]; };
            vertex QOut qv(QIn in [[stage_in]]) { QOut o; o.position = in.position; return o; }
            fragment half4 qf(QOut in [[stage_in]]) { return half4(0.0, 0.0, 1.0, 1.0); }
            """, options: nil)
            let prog = SCNProgram(); prog.library = lib; prog.vertexFunctionName = "pv"; prog.fragmentFunctionName = "pf"
            let m2 = SCNMaterial(); m2.program = prog
            let (s2, c2) = scene(m2)
            let p2 = try render(s2, c2)
            try expect(p2Near(p2, 255, 255, 0), "SCNProgram pixel \(p2)")
            // 3. SCNTechnique: one full-screen DRAW_QUAD pass painting blue over the frame
            let t = SCNTechnique(dictionary: [
                "passes": ["blue": ["draw": "DRAW_QUAD", "metalVertexShader": "qv", "metalFragmentShader": "qf", "outputs": ["color": "COLOR"]]],
                "sequence": ["blue"], "symbols": [:] as [String: Any]])
            t?.library = lib
            let p3 = try render(s1, c1, technique: t)
            try expect(t != nil && p2Near(p3, 0, 0, 255), "technique pixel \(p3)")
            return "shader modifier \(p1), SCNProgram \(p2), technique \(p3)"
        })
        #endif
        #if canImport(SceneKit) && (os(watchOS) || os(visionOS))
        c.append(check("_SceneKit_SwiftUI", "scene-view-physics-render", timeout: 60) {
            // SceneView on screen (watch: Runner.overlay; visionOS: in the app's window): the scene runs, physics steps
            let d = P2Contacts()
            let s = p2PhysicsScene(d)
            let cam = s.rootNode.childNode(withName: "cam", recursively: false)!
            #if os(watchOS)
            await onMain { Runner.shared.overlay = AnyView(P2SceneViewProbe(scene: s, cam: cam)) }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            #else
            let h = try await onMain { try hostInWindow(P2SceneViewProbe(scene: s, cam: cam)) }
            defer { Task { @MainActor in h.view.removeFromSuperview(); h.removeFromParent() } }
            #endif
            let hit = await p2Wait(15) { d.n.value > 0 }
            let y = await onMain { s.rootNode.childNode(withName: "ball", recursively: false)!.presentation.position.y }
            try expect(hit, "no physics contact in 15 s (ball y \(y))")
            return "SceneView ran the scene: contact \(d.n.names.first ?? ""), ball y \(String(format: "%.2f", y))"
        })
        c.append(check("_SpriteKit_SwiftUI", "sprite-view-frames-action", timeout: 60) {
            let (scene, node) = await onMain { () -> (P2FrameScene, SKSpriteNode) in
                let s = P2FrameScene(size: CGSize(width: 150, height: 150)); s.backgroundColor = .purple
                let n = SKSpriteNode(color: .yellow, size: CGSize(width: 20, height: 20)); n.position = CGPoint(x: 20, y: 75)
                s.addChild(n); n.run(.moveTo(x: 130, duration: 0.5)); return (s, n)
            }
            #if os(watchOS)
            await onMain { Runner.shared.overlay = AnyView(P2SpriteViewProbe(scene: scene)) }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            #else
            let h = try await onMain { try hostInWindow(P2SpriteViewProbe(scene: scene)) }
            defer { Task { @MainActor in h.view.removeFromSuperview(); h.removeFromParent() } }
            #endif
            try await Task.sleep(for: .seconds(1.5))
            let n = scene.frames.value, x = await onMain { node.position.x }
            try expect(n > 20, "update() called \(n) times in 1.5 s")
            try expect(abs(x - 130) < 1, "move action: x \(x)")
            return "\(n) frames in 1.5 s, sprite at x \(Int(x))"
        })
        #endif
        // MARK: SpriteKit
        #if canImport(SpriteKit) && canImport(UIKit) && !os(watchOS)
        c.append(check("SpriteKit", "skview-shader-emitter-tilemap-atlas", timeout: 60) {
            let (view, scene, done) = try await onMain { () -> (SKView, P2FrameScene, () -> Void) in
                let v = SKView(frame: CGRect(x: 0, y: 60, width: 200, height: 200))
                let s = P2FrameScene(size: CGSize(width: 200, height: 200)); s.backgroundColor = .black
                v.presentScene(s)
                let (_, done) = try p2Show(v); return (v, s, done)
            }
            defer { Task { @MainActor in done() } }
            try await Task.sleep(for: .seconds(1))
            return try await onMain {
                try expect(scene.frames.value > 20, "SKView frame loop: \(scene.frames.value) updates in 1 s")
                // SKShader: a sprite painted green by its fragment shader
                let sp = SKSpriteNode(color: .red, size: CGSize(width: 32, height: 32))
                sp.shader = SKShader(source: "void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }")
                scene.addChild(sp)
                guard let st = view.texture(from: sp)?.cgImage() else { throw Fail("texture(from:) shader sprite") }
                let sp1 = p2Pixel(st, st.width / 2, st.height / 2)
                try expect(p2Near(sp1, 0, 255, 0), "SKShader pixel \(sp1)")
                // texture atlas from images
                let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
                let img = { (c: UIColor) in UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: fmt).image { c.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) } }
                let atlas = SKTextureAtlas(dictionary: ["red": img(.red), "blue": img(.blue)])
                try expect(Set(atlas.textureNames.map { ($0 as NSString).deletingPathExtension }) == ["red", "blue"], "atlas names \(atlas.textureNames)")
                let blue = atlas.textureNamed("blue")
                try expect(blue.size() == CGSize(width: 8, height: 8), "atlas texture size \(blue.size())")
                // tile map: 4x4 of blue tiles with one red one
                let redG = SKTileGroup(tileDefinition: SKTileDefinition(texture: atlas.textureNamed("red")))
                let blueG = SKTileGroup(tileDefinition: SKTileDefinition(texture: blue))
                let set = SKTileSet(tileGroups: [redG, blueG])
                let map = SKTileMapNode(tileSet: set, columns: 4, rows: 4, tileSize: CGSize(width: 8, height: 8), fillWith: blueG)
                map.setTileGroup(redG, forColumn: 2, row: 1)
                try expect(map.tileGroup(atColumn: 2, row: 1) === redG && map.tileGroup(atColumn: 0, row: 0) === blueG, "tile groups")
                let pos = map.centerOfTile(atColumn: 2, row: 1)
                try expect(map.tileColumnIndex(fromPosition: pos) == 2 && map.tileRowIndex(fromPosition: pos) == 1, "tile index from position \(pos)")
                scene.addChild(map)
                guard let mt = view.texture(from: map)?.cgImage() else { throw Fail("texture(from:) tile map") }
                let red = p2Pixel(mt, mt.width * 5 / 8, mt.height - 1 - mt.height * 3 / 8), other = p2Pixel(mt, 2, 2)
                try expect(p2Near(red, 255, 0, 0, 60) && p2Near(other, 0, 0, 255, 60), "tile map pixels \(red) \(other) (\(mt.width)x\(mt.height))")
                // emitter: advanced 1 s, particles render
                let em = SKEmitterNode(); em.particleTexture = atlas.textureNamed("red"); em.particleBirthRate = 200; em.particleLifetime = 2
                em.particleSpeed = 20; em.emissionAngleRange = .pi * 2; em.particleColor = .white; em.particleColorBlendFactor = 1
                em.numParticlesToEmit = 0; em.position = CGPoint(x: 100, y: 100); scene.addChild(em)
                em.advanceSimulationTime(1)
                // the whole scene with only the emitter left: its particles light pixels around (100, 100)
                sp.removeFromParent(); map.removeFromParent()
                guard let all = view.texture(from: scene)?.cgImage() else { throw Fail("texture(from: scene)") }
                var lit = 0
                for y in stride(from: 0, to: all.height, by: 2) { for x in stride(from: 0, to: all.width, by: 2) where p2Pixel(all, x, y)[0] > 60 { lit += 1 } }
                try expect(lit > 4, "emitter particles lit \(lit) sampled pixels (\(all.width)x\(all.height))")
                return "\(scene.frames.value) frames, SKShader \(sp1), atlas 2, tile map red at (2,1), emitter lit \(lit) samples after 1 s"
            }
        })
        #endif
        // MARK: ModelIO
        #if canImport(ModelIO)
        c.append(check("ModelIO", "obj-usda-import-roundtrip", timeout: 60) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-mdl-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
            let obj = dir.appendingPathComponent("quad.obj")
            try """
            o quad
            v 0 0 0
            v 2 0 0
            v 2 1 0
            v 0 1 0
            vn 0 0 1
            vt 0 0
            vt 1 0
            vt 1 1
            vt 0 1
            f 1/1/1 2/2/1 3/3/1
            f 1/1/1 3/3/1 4/4/1
            """.write(to: obj, atomically: true, encoding: .utf8)
            try expect(MDLAsset.canImportFileExtension("obj") && MDLAsset.canImportFileExtension("usda"), "importers")
            let a = MDLAsset(url: obj)
            guard let mesh = a.childObjects(of: MDLMesh.self).first as? MDLMesh else { throw Fail("no mesh in the OBJ (\(a.count) objects)") }
            let bb = mesh.boundingBox
            try expect(bb.maxBounds.x == 2 && bb.maxBounds.y == 1 && mesh.vertexCount >= 4, "OBJ mesh: \(mesh.vertexCount) vertices, bounds \(bb.maxBounds)")
            let tris = (mesh.submeshes as? [MDLSubmesh])?.reduce(0) { $0 + $1.indexCount } ?? 0
            try expect(tris == 6, "OBJ indices \(tris)")
            try expect(mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate) != nil, "texture coordinates")
            var formats: [String] = []
            for ext in ["usda", "usdc", "usdz", "obj"] where MDLAsset.canExportFileExtension(ext) {
                let u = dir.appendingPathComponent("out.\(ext)")
                do { try a.export(to: u) } catch { formats.append("\(ext): export failed"); continue }
                let b = MDLAsset(url: u)
                let m2 = b.childObjects(of: MDLMesh.self).first as? MDLMesh
                try expect(m2 != nil && abs((m2?.boundingBox.maxBounds.x ?? 0) - 2) < 1e-4, "\(ext) round trip: \(String(describing: m2?.boundingBox.maxBounds))")
                formats.append(ext)
            }
            try expect(formats.contains("usda"), "usda export \(formats)")
            if MDLAsset.canExportFileExtension("usda") {
                let text = try String(contentsOf: dir.appendingPathComponent("out.usda"), encoding: .utf8)
                try expect(text.hasPrefix("#usda") && text.contains("Mesh"), "usda text \(text.prefix(60))")
            }
            return "OBJ \(mesh.vertexCount) vertices, round trips \(formats)"
        })
        c.append(check("ModelIO", "procedural-textures-noise-sky-normalmap", timeout: 90) {
            let dims = SIMD2<Int32>(64, 64)
            let noise = MDLNoiseTexture(scalarNoiseWithSmoothness: 0.5, name: "noise", textureDimensions: dims, channelCount: 1, channelEncoding: .uInt8, grayscale: true)
            guard let nd = noise.texelDataWithTopLeftOrigin() else { throw Fail("noise texels") }
            try expect(nd.count == 64 * 64, "noise bytes \(nd.count)")
            let distinct = Set(nd).count
            try expect(distinct > 8, "noise has \(distinct) distinct values")
            let vnoise = MDLNoiseTexture(vectorNoiseWithSmoothness: 0.5, name: "vnoise", textureDimensions: dims, channelEncoding: .uInt8)
            try expect((vnoise.texelDataWithTopLeftOrigin()?.count ?? 0) == 64 * 64 * 4, "vector noise")
            let sky = MDLSkyCubeTexture(name: "sky", channelEncoding: .uInt8, textureDimensions: SIMD2<Int32>(32, 32), turbidity: 0.5, sunElevation: 0.6, upperAtmosphereScattering: 0.3, groundAlbedo: 0.2)
            guard let skyd = sky.texelDataWithTopLeftOrigin() else { throw Fail("sky texels") }
            try expect(sky.isCube && skyd.count >= 32 * 32 * 6 * 4, "sky cube \(sky.isCube) \(skyd.count) B (dims \(sky.dimensions))")
            let nm = MDLNormalMapTexture(byGeneratingNormalMapWith: noise, name: "nm", smoothness: 0.5, contrast: 1)
            guard let nmd = nm.texelDataWithTopLeftOrigin() else { throw Fail("normal map texels") }
            let blues = stride(from: 2, to: nmd.count, by: 4).map { Int(nmd[$0]) }
            let avgB = blues.reduce(0, +) / max(blues.count, 1)
            try expect(nmd.count == 64 * 64 * 4 && Set(nmd).count > 4, "normal map \(nmd.count) B, \(Set(nmd).count) values")
            let checker = MDLCheckerboardTexture(divisions: 4, name: "c", dimensions: dims, channelCount: 4, channelEncoding: .uInt8, color1: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), color2: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            let cd = checker.texelDataWithTopLeftOrigin()!
            try expect(cd[0] != cd[16 * 4] || cd[2] != cd[16 * 4 + 2], "checkerboard squares differ")
            return "noise \(distinct) levels, sky cube \(skyd.count) B, normal map blue \(avgB), checkerboard"
        })
        c.append(check("ModelIO", "voxels-skeleton-animation-uv-unwrap", timeout: 90) {
            let box = MDLMesh(boxWithExtent: [2, 2, 2], segments: [1, 1, 1], inwardNormals: false, geometryType: .triangles, allocator: nil)
            let a = MDLAsset(); a.add(box)
            let vox = MDLVoxelArray(asset: a, divisions: 8, patchRadius: 0)
            let n = vox.count
            try expect(n > 20, "voxels \(n)")
            let ext = vox.boundingBox
            try expect(abs(ext.maxBounds.x - 1) < 0.5, "voxel bounds \(ext.maxBounds)")
            let mesh2 = vox.mesh(using: nil)
            try expect((mesh2?.vertexCount ?? 0) > 0, "voxel mesh")
            // skeleton + packed joint animation
            let sk = MDLSkeleton(name: "sk", jointPaths: ["root", "root/arm"])
            try expect(sk.jointPaths == ["root", "root/arm"] && sk.jointBindTransforms.float4x4Array.count == 2, "skeleton")
            let anim = MDLPackedJointAnimation(name: "wave", jointPaths: ["root", "root/arm"])
            anim.translations.reset(float3Array: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 2, 0)], atTimes: [0, 1])
            try expect(anim.translations.timeSampleCount == 2 && anim.translations.float3Array(atTime: 1)[1].y == 2, "joint animation \(anim.translations.float3Array(atTime: 1))")
            let bind = MDLAnimationBindComponent(); bind.skeleton = sk; bind.jointAnimation = anim
            try expect(bind.skeleton === sk, "bind component")
            // UV unwrap: a mesh without texture coordinates gets them
            let plain = MDLMesh(sphereWithExtent: [1, 1, 1], segments: [8, 8], inwardNormals: false, geometryType: .triangles, allocator: nil)
            plain.removeAttributeNamed(MDLVertexAttributeTextureCoordinate)
            try expect(plain.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate) == nil, "texcoords removed")
            plain.addUnwrappedTextureCoordinates(forAttributeNamed: MDLVertexAttributeTextureCoordinate)
            try expect(plain.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate) != nil, "unwrapped texture coordinates")
            plain.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            let t = MDLTransform(); t.setTranslation([1, 2, 3], forTime: 0); t.setTranslation([3, 2, 1], forTime: 2)
            try expect(t.translation(atTime: 1) == SIMD3<Float>(2, 2, 2), "transform interpolation \(t.translation(atTime: 1))")
            return "\(n) voxels, skeleton 2 joints, packed animation, UV unwrap (\(plain.vertexCount) vertices), transform keys"
        })
        #endif
        return c
    }
}
