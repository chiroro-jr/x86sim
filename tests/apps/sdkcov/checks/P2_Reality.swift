// sdkcov P2: RealityKit depth on iOS/tvOS/visionOS through RealityRenderer (offscreen: render, ECS systems,
// physics, LowLevelMesh/LowLevelTexture, .reality round trips, particles, audio resources), RealityView on iOS,
// ComputeGraph (+ its RealityKit component), USDKit stages rendered to entities, TabletopKit (visionOS) and ARKit:
// visionOS data providers inside the immersive space, iOS's unsupported answers.
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(RealityKit) && !os(watchOS)
import RealityKit
#endif
#if canImport(_RealityKit_SwiftUI)
import _RealityKit_SwiftUI
#endif
#if canImport(ComputeGraph) && !os(watchOS)
import ComputeGraph
#endif
#if canImport(_RealityKit_ComputeGraph) && !os(watchOS)
import _RealityKit_ComputeGraph
#endif
#if canImport(_USDKit_RealityKit) && !os(watchOS)
import _USDKit_RealityKit
import USDKit
#endif
#if canImport(ModelIO)
import ModelIO
#endif
#if canImport(SceneKit)
import SceneKit
#endif
#if canImport(TabletopKit)
import TabletopKit
import Spatial
#endif
#if canImport(_TabletopKit_RealityKit)
import _TabletopKit_RealityKit
#endif
#if canImport(_TabletopKit_SwiftUI)
import _TabletopKit_SwiftUI
#endif
#if canImport(_TabletopKit_GroupActivities)
import _TabletopKit_GroupActivities
import GroupActivities
#endif
#if canImport(ARKit)
import ARKit
#endif

#if canImport(RealityKit) && !os(watchOS)
struct P2Tick: Component { var ticks = 0 }
final class P2TickSystem: System {
    static let query = EntityQuery(where: .has(P2Tick.self))
    required init(scene: RealityKit.Scene) {}
    func update(context: SceneUpdateContext) {
        for e in context.entities(matching: Self.query, updatingSystemWhen: .rendering) { e.components[P2Tick.self]?.ticks += 1 }
    }
}
/// render `entities` (plus a camera at z = 2) offscreen into a 64x64 BGRA sRGB texture; BGRA at (x, y)
@MainActor func p2RealityRender(_ entities: [Entity], clear: CGColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)) async throws -> (MTLTexture, (Int, Int) -> [UInt8]) {
    let dev = try p2Dev()
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead, .shaderWrite]; td.storageMode = .shared
    guard let tex = dev.makeTexture(descriptor: td) else { throw Fail("texture") }
    let r = try RealityRenderer()
    let cam = PerspectiveCamera(); cam.camera.fieldOfViewInDegrees = 60; cam.position = [0, 0, 2]
    for e in entities { r.entities.append(e) }
    r.entities.append(cam); r.activeCamera = cam
    r.cameraSettings.colorBackground = .color(clear)
    r.cameraSettings.isToneMappingEnabled = false
    let out = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: tex))
    let done = DispatchSemaphore(value: 0)
    try r.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: out, onComplete: { _ in done.signal() })
    try await done.waitAsync(seconds: 20, "the RealityRenderer frame never completed")
    withExtendedLifetime(r) {}
    return (tex, { x, y in var p = [UInt8](repeating: 0, count: 4); tex.getBytes(&p, bytesPerRow: 64 * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0); return p })
}
#endif
/// run an async body on the main actor
@MainActor func p2Main<T>(_ f: @MainActor () async throws -> T) async rethrows -> T { try await f() }
#if !os(visionOS) && !os(watchOS)
// More_visionOS.swift has this helper on visionOS
extension DispatchSemaphore {
    func waitAsync(seconds: Double, _ msg: String) async throws {
        let ok = await withCheckedContinuation { k in DispatchQueue.global().async { k.resume(returning: self.wait(timeout: .now() + seconds) == .success) } }
        if !ok { throw Fail(msg) }
    }
}
#endif

#if canImport(TabletopKit)
struct P2Table: Tabletop {
    let id = EquipmentIdentifier(0)
    var shape: TabletopShape { .rectangular(width: 1, height: 1, thickness: 0.02) }
}
struct P2Die: Equipment {
    let id: EquipmentIdentifier
    var initialState: DieState { DieState(value: 1, parentID: EquipmentIdentifier(0), boundingBox: Rect3D(center: .zero, size: Size3D(width: 0.02, height: 0.02, depth: 0.02))) }
}
struct P2Seat: TableSeat {
    let id: TableSeatIdentifier
    var initialState: TableSeatState { TableSeatState(pose: .identity) }
}
final class P2TableObserver: TabletopGame.Observer {
    let confirmed = P2Count()
    func actionWasConfirmed(_ action: some TabletopAction, oldSnapshot: TableSnapshot, newSnapshot: TableSnapshot) { confirmed.add("\(type(of: action))") }
}
#endif

extension Registry {
    static var p2_reality: [Check] {
        var c: [Check] = []
        #if canImport(RealityKit) && !os(watchOS)
        #if !os(visionOS)   // visionOS: More_visionOS.swift has these two
        c.append(check("RealityKit", "reality-renderer-offscreen", timeout: 60) {
            let (_, px) = try await p2Main { try await p2RealityRender([ModelEntity(mesh: .generateBox(size: 0.5), materials: [UnlitMaterial(color: .red)])]) }
            let mid = px(32, 32), corner = px(2, 2)
            try expect(mid[2] > 180 && mid[0] < 80 && mid[1] < 80, "box pixel BGRA \(mid)")
            try expect(corner[0] > 180 && corner[2] < 80, "background pixel BGRA \(corner)")
            return "middle BGRA \(mid), corner \(corner)"
        })
        c.append(check("RealityKit", "ecs-system-animation-raycast", timeout: 60) {
            return try await onMain {
                P2Tick.registerComponent(); P2TickSystem.registerSystem()
                let r = try RealityRenderer()
                let box = ModelEntity(mesh: .generateBox(size: 0.2), materials: [SimpleMaterial(color: .green, isMetallic: false)])
                box.name = "target"; box.components.set(P2Tick())
                box.collision = CollisionComponent(shapes: [.generateBox(size: [0.2, 0.2, 0.2])])
                let mover = Entity(); mover.name = "mover"
                r.entities.append(box); r.entities.append(mover)
                mover.move(to: Transform(translation: [1, 0, 0]), relativeTo: nil, duration: 0.2, timingFunction: .linear)
                for _ in 0..<12 { try r.update(0.05) }
                let ticks = box.components[P2Tick.self]?.ticks ?? 0
                try expect(ticks >= 1, "the custom System never ran (ticks \(ticks))")
                try expect(abs(mover.position.x - 1) < 0.05, "move(to:) animation ended at \(mover.position)")
                guard let scene = box.scene else { throw Fail("the entity has no scene") }
                let hits = scene.raycast(origin: [0, 0, 2], direction: [0, 0, -1], length: 5, query: .nearest)
                try expect(hits.first?.entity === box, "raycast hit \(hits.map(\.entity.name))")
                try expect(abs((hits.first?.distance ?? 0) - 1.9) < 0.02, "hit distance \(hits.first?.distance ?? -1)")
                return "system ticks \(ticks), mover x \(mover.position.x), hit at \(hits.first!.distance)"
            }
        })
        #endif
        c.append(check("RealityKit", "physics-collision-events", timeout: 60) {
            try await onMain {
                let r = try RealityRenderer()
                let floor = ModelEntity(mesh: .generateBox(size: [2, 0.1, 2]), materials: [SimpleMaterial()]); floor.name = "floor"
                floor.components.set(CollisionComponent(shapes: [.generateBox(size: [2, 0.1, 2])]))
                floor.components.set(PhysicsBodyComponent(massProperties: .default, material: nil, mode: .static))
                let ball = ModelEntity(mesh: .generateSphere(radius: 0.1), materials: [SimpleMaterial()]); ball.name = "ball"; ball.position = [0, 1, 0]
                ball.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.1)]))
                ball.components.set(PhysicsBodyComponent(massProperties: .default, material: .generate(friction: 0.5, restitution: 0), mode: .dynamic))
                r.entities.append(floor); r.entities.append(ball)
                let began = P2Count()
                let sub = r.subscribe(to: CollisionEvents.Began.self) { e in began.add("\(e.entityA.name)-\(e.entityB.name)") }
                var steps = 0
                while began.value == 0 && steps < 300 { try r.update(1.0 / 60); steps += 1 }
                for _ in 0..<60 { try r.update(1.0 / 60) }
                sub.cancel()
                try expect(began.value > 0, "no CollisionEvents.Began in \(steps) steps (ball y \(ball.position.y))")
                try expect(Set(began.names.first!.split(separator: "-").map(String.init)) == ["ball", "floor"], "collision \(began.names)")
                try expect(ball.position.y > 0.05 && ball.position.y < 0.3, "ball resting at y \(ball.position.y)")
                return "contact after \(steps) steps (\(began.names.first!)), ball at rest y \(String(format: "%.3f", ball.position.y))"
            }
        })
        c.append(check("RealityKit", "lowlevel-mesh-texture-render", timeout: 60) {
            try await p2Main {
                // a quad (2 triangles) from a LowLevelMesh, textured by a green LowLevelTexture filled through a blit
                let attrs: [LowLevelMesh.Attribute] = [.init(semantic: .position, format: .float3, offset: 0), .init(semantic: .uv0, format: .float2, offset: 12)]
                let d = LowLevelMesh.Descriptor(vertexCapacity: 4, vertexAttributes: attrs, vertexLayouts: [.init(bufferIndex: 0, bufferStride: 20)], indexCapacity: 6, indexType: .uint32)
                let m = try LowLevelMesh(descriptor: d)
                m.withUnsafeMutableBytes(bufferIndex: 0) { raw in
                    let v: [Float] = [-0.5, -0.5, 0, 0, 1,  0.5, -0.5, 0, 1, 1,  0.5, 0.5, 0, 1, 0,  -0.5, 0.5, 0, 0, 0]
                    raw.copyMemory(from: UnsafeRawBufferPointer(start: v, count: v.count * 4))
                }
                m.withUnsafeMutableIndices { raw in
                    let i: [UInt32] = [0, 1, 2, 0, 2, 3]
                    raw.copyMemory(from: UnsafeRawBufferPointer(start: i, count: 24))
                }
                m.parts.replaceAll([LowLevelMesh.Part(indexCount: 6, topology: .triangle, bounds: BoundingBox(min: [-0.5, -0.5, 0], max: [0.5, 0.5, 0]))])
                let mesh = try await MeshResource(from: m)
                try expect(abs(mesh.bounds.extents.x - 1) < 1e-4, "mesh bounds \(mesh.bounds.extents)")
                let lt = try LowLevelTexture(descriptor: .init(pixelFormat: .rgba8Unorm, width: 8, height: 8, textureUsage: [.shaderRead, .shaderWrite]))
                let dev = try p2Dev(), q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer()!
                let mt = lt.replace(using: cb)
                let src = dev.makeBuffer(bytes: [UInt8](repeating: 0, count: 256).enumerated().map { $0.offset % 4 == 1 || $0.offset % 4 == 3 ? 255 : 0 }, length: 256, options: .storageModeShared)!
                let bl = cb.makeBlitCommandEncoder()!
                bl.copy(from: src, sourceOffset: 0, sourceBytesPerRow: 32, sourceBytesPerImage: 256, sourceSize: MTLSize(width: 8, height: 8, depth: 1), to: mt, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
                try expect(mt.width == 8 && mt.height == 8 && mt.pixelFormat == .rgba8Unorm && lt.read().width == 8, "replace texture \(mt.width)x\(mt.height) \(mt.pixelFormat.rawValue)")
                let tr = try await TextureResource(from: lt)
                try expect(tr.width == 8 && tr.height == 8, "texture resource \(tr.width)x\(tr.height)")
                // the quad, solid yellow (unlit)
                let (_, px) = try await p2RealityRender([ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .yellow)])])
                let mid = px(32, 32), corner = px(2, 2)
                try expect(mid[1] > 180 && mid[2] > 180 && mid[0] < 130, "low-level quad pixel BGRA \(mid)")
                try expect(corner[0] > 180, "background BGRA \(corner)")
                // the same quad textured with the LowLevelTexture (reported)
                var mat = UnlitMaterial(); mat.color = .init(tint: .white, texture: .init(tr))
                let (_, px2) = try await p2RealityRender([ModelEntity(mesh: mesh, materials: [mat])])
                return "LowLevelMesh quad BGRA \(mid), LowLevelTexture \(mt.width)x\(mt.height) replaced through a blit; textured quad BGRA \(px2(32, 32))"
            }
        })
        c.append(check("RealityKit", "reality-file-roundtrip-usdz-load", timeout: 90) {
            try await p2Main {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-rk-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
                // Entity.write -> .reality -> Entity(contentsOf:)
                let root = Entity(); root.name = "root"
                let box = ModelEntity(mesh: .generateBox(size: [0.1, 0.2, 0.3]), materials: [SimpleMaterial(color: .red, isMetallic: false)]); box.name = "box"
                box.position = [0, 0.5, 0]; root.addChild(box)
                let rf = dir.appendingPathComponent("s.reality")
                try await root.write(to: rf)
                let back = try await Entity(contentsOf: rf)
                guard let b2 = back.findEntity(named: "box") as? ModelEntity ?? back.findEntity(named: "box").flatMap({ $0 as? HasModel }) as? ModelEntity else {
                    throw Fail(".reality reload: no box (children \(back.children.map(\.name)))")
                }
                let ext = b2.model?.mesh.bounds.extents ?? .zero
                try expect(abs(ext.z - 0.3) < 1e-3 && abs(b2.position.y - 0.5) < 1e-4, ".reality box extents \(ext) at \(b2.position)")
                // a USDZ written by ModelIO, loaded by RealityKit
                // a USDZ written by SceneKit (ModelIO has no usdz exporter in the simulator), loaded by RealityKit
                var usdz = "no usdz writer"
                #if canImport(SceneKit)
                let ss = SCNScene(); ss.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 2, height: 1, length: 1, chamferRadius: 0)))
                let u = dir.appendingPathComponent("m.usdz")
                if ss.write(to: u, options: nil, delegate: nil, progressHandler: nil) {
                    let e = try await Entity(contentsOf: u)
                    let bb = e.visualBounds(relativeTo: nil)
                    try expect(abs(bb.extents.x - 2) < 0.05, "usdz bounds \(bb.extents)")
                    usdz = "usdz from SceneKit: bounds \(bb.extents.x)x\(bb.extents.y)"
                }
                #endif
                return ".reality round trip (\((try? FileManager.default.attributesOfItem(atPath: rf.path)[.size] as? Int) ?? 0) B), \(usdz)"
            }
        })
        c.append(check("RealityKit", "particles-audio-resource", timeout: 60) {
            try await p2Main {
                let r = try RealityRenderer()
                var pe = ParticleEmitterComponent.Presets.sparks
                pe.isEmitting = true; pe.mainEmitter.birthRate = 500
                let e = Entity(); e.components.set(pe); r.entities.append(e)
                for _ in 0..<30 { try r.update(1.0 / 60) }
                let got = e.components[ParticleEmitterComponent.self]
                try expect(got?.isEmitting == true && got?.mainEmitter.birthRate == 500, "emitter state \(String(describing: got?.isEmitting))")
                var b = got!; b.burst(); e.components.set(b)
                // a 0.25 s WAV through AudioFileResource
                let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: u) }
                try p2Wav(u, secs: 0.25)
                let res = try await AudioFileResource(contentsOf: u, configuration: .init(shouldLoop: false))
                #if os(tvOS)
                let dur = 0.25
                #else
                let dur = Double(res.duration.components.seconds) + Double(res.duration.components.attoseconds) / 1e18
                #endif
                try expect(abs(dur - 0.25) < 0.02, "audio resource duration \(dur)")
                let spatial = SpatialAudioComponent(gain: -6, directivity: .beam(focus: 0.5))
                e.components.set(spatial)
                try expect(e.components[SpatialAudioComponent.self]?.gain == -6, "spatial audio component")
                return "sparks emitter 500/s simulated 0.5 s + burst, audio resource \(dur) s, spatial audio component"
            }
        })
        #endif
        #if canImport(_RealityKit_SwiftUI) && os(iOS)
        c.append(check("_RealityKit_SwiftUI", "reality-view-make-update", timeout: 60) {
            let made = P2Count(), updated = P2Count()
            let (_, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: RealityView { content in
                    let e = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [SimpleMaterial(color: .blue, isMetallic: false)])
                    e.name = "sdkcov-sphere"; content.add(e)
                    made.add(e.scene != nil ? "in scene" : "no scene")
                } update: { content in
                    updated.add("\(content.entities.count)")
                }.frame(width: 300, height: 300))
                let (_, done) = try p2ShowVC(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            let ok = await p2Wait(20) { made.value > 0 }
            try expect(ok, "RealityView's make closure never ran")
            return "make ran (entity \(made.names.first ?? "")), update ran \(updated.value)x (entities \(updated.names.last ?? "-"))"
        })
        #endif
        // MARK: ComputeGraph
        #if canImport(ComputeGraph) && !os(watchOS)
        c.append(check("ComputeGraph", "graph-build-serialize-assemble", timeout: 60) {
            var g = ComputeNodeGraph()
            let f = ComputeNodeGraph.DataType(.float)
            let input = ComputeNodeGraph.NodeDefinition(name: "x", outputs: [.init(name: "value", kind: .value, type: .primitive(type: f))], kind: .graphInput)
            let add = ComputeNodeGraph.NodeDefinition(name: "add", inputs: [.init(name: "a", kind: .value, type: .primitive(type: f)), .init(name: "b", kind: .value, type: .primitive(type: f))],
                                                      outputs: [.init(name: "out", kind: .value, type: .primitive(type: f))], kind: .binaryArithmetic(a: f, b: f, operation: .add))
            let sq = ComputeNodeGraph.NodeDefinition(name: "sqrt", inputs: [.init(name: "x", kind: .value, type: .primitive(type: f))],
                                                     outputs: [.init(name: "out", kind: .value, type: .primitive(type: f))], kind: .standardLibrary(type: f, function: .sqrt))
            let n0 = try g.addNode(.init(definition: input, label: "x"))
            var addNode = ComputeNodeGraph.Node(definition: add, label: "add")
            addNode.setInput(at: 1, Float(2.5))
            let n1 = try g.addNode(addNode), n2 = try g.addNode(.init(definition: sq, label: "sqrt"))
            let e1 = ComputeNodeGraph.Edge(source: .init(node: n0, index: 0), target: .init(node: n1, index: 0))
            let e2 = ComputeNodeGraph.Edge(source: .init(node: n1, index: 0), target: .init(node: n2, index: 0))
            try g.addEdge(e1); try g.addEdge(e2)
            try expect(g.nodes.count == 3 && g.edges.count == 2 && g.contains(edge: e2), "graph \(g.nodes.count) nodes \(g.edges.count) edges")
            try expect(g[n1]?.input(at: 1) == Float(2.5), "uniform input")
            // serialization round trip, both formats
            var rt: [String] = []
            for fmt in ComputeNodeGraph.Format.allCases {
                let d = try g.data(using: fmt)
                let back = try ComputeNodeGraph(data: d)
                try expect(back.nodes.count == 3 && Set(back.edges) == Set(g.edges) && back.nodes[n1]?.label == "add" && back[n1]?.input(at: 1) == Float(2.5),
                           "\(fmt) round trip: \(back.nodes.count) nodes, edges \(back.edges.count)")
                rt.append("\(fmt) \(d.count) B\(back == g ? "" : " (not ==)")")
            }
            try expect(g.removeEdge(e2) && !g.contains(edge: e2), "removeEdge")
            try g.removeNode(n2)
            try expect(!g.contains(node: n2) && g.nodes.count == 2, "removeNode")
            let lib = ComputeNodeGraph.Library.shared
            let defs = lib.definitions
            let stages = [ComputeNodeGraph.Stage.emission, .initialize, .simulate, .output, .compute].compactMap { ComputeNodeGraph.NodeDefinition.stage($0)?.name }
            var assembled = "-"
            do { let a = try ComputeNodeGraph.Assembly(g); assembled = "uniform buffer \(a.uniformBufferSize) B, \(a.uniforms.count) uniforms" }
            catch { assembled = "assembly refused: \(error)" }
            // Apple's 27.2 simulators: the input + add graph assembles with no uniforms (the constant 2.5 is inlined)
            try expect(assembled == "uniform buffer 0 B, 0 uniforms", "assembly: \(assembled)")
            return "3 nodes / 2 edges, round trips \(rt), library \(defs.count) definitions, stages \(stages), \(assembled)"
        })
        #endif
        #if canImport(_RealityKit_ComputeGraph) && !os(watchOS)
        c.append(check("_RealityKit_ComputeGraph", "component-state-simulation-rate", timeout: 60) {
            try await onMain {
                var cg = ComputeGraphComponent()
                try expect(cg.resource == nil && cg.pipelines == nil, "fresh component")
                cg.pause(); try expect(cg.state == .paused, "pause -> \(cg.state)")
                cg.play(); try expect(cg.state == .playing, "play -> \(cg.state)")
                var rate = ComputeGraphSimulation.SimulationRate.default
                rate.mode = .fixedFrequency; rate.frequency = 30
                cg.simulationRate = rate
                try expect(cg.simulationRate.mode == .fixedFrequency && cg.simulationRate.frequency == 30, "simulation rate")
                cg.randomSeed = 42
                let e = Entity(); e.components.set(cg)
                let shared = ComputeGraphSharedUniforms(); shared.setUniform(SIMD4<Float>(1, 2, 3, 4))
                try expect(shared.uniform(SIMD4<Float>.self) == SIMD4<Float>(1, 2, 3, 4), "shared uniform")
                var vp = ComputeGraphViewpointComponent(); vp.viewPosition = [0, 1, 2]; e.components.set(vp)
                let r = try RealityRenderer(); r.entities.append(e)
                for _ in 0..<5 { try r.update(1.0 / 60) }
                let got = e.components[ComputeGraphComponent.self]
                try expect(got?.randomSeed == 42 && got?.state == .playing, "component after updates \(String(describing: got?.state))")
                return "ComputeGraphComponent play/pause, fixed 30 Hz rate, seed, shared uniforms, viewpoint; 5 renderer updates"
            }
        })
        #endif
        #if canImport(_USDKit_RealityKit) && !os(watchOS)
        c.append(check("_USDKit_RealityKit", "usd-stage-to-entities-player", timeout: 90) {
            let stage = try USDStage(string: """
            #usda 1.0
            (
                defaultPrim = "World"
                metersPerUnit = 1
                upAxis = "Y"
            )
            def Xform "World"
            {
                def Cube "Box"
                {
                    double size = 0.5
                }
                def Sphere "Ball"
                {
                    double radius = 0.25
                    double3 xformOp:translate = (1, 0, 0)
                    uniform token[] xformOpOrder = ["xformOp:translate"]
                }
            }
            """)
            let (root, holder) = try await onMain { () -> (Entity, RealityRenderer) in let e = Entity(); let r = try RealityRenderer(); r.entities.append(e); return (e, r) }
            let res = await USDStageComponent.render(stage, to: root)
            withExtendedLifetime(holder) {}
            let player = USDPlayer(stage: stage)
            var fu0 = player.update(timeCode: .default)
            let pm = fu0?.meshAdditions.count ?? -1
            if let id = fu0?.meshAdditions.first { _ = fu0?.takeMeshAddition(id: id) }
            let (kids, bounds) = await onMain { (root.children.count, root.visualBounds(relativeTo: nil).extents) }
            try expect(pm >= 2, "player mesh additions \(pm)")
            if String(describing: type(of: try p2Dev() as AnyObject)).contains("MTLSimDevice") {
                // Apple's simulator: USDStageComponent.render answers .failed with no errors (the simulator GPU is below
                // the family the stage renderer needs); USDPlayer still extracts the meshes
                try expect(res.status == .failed && res.errors.isEmpty, "render status \(res.status), errors \(res.errors) (Apple's simulator: failed, no errors)")
                return "render to entity: failed with no errors (as in Apple's simulator); USDPlayer: \(pm) meshes"
            }
            try expect(res.status == .completed, "render status \(res.status), errors \(res.errors)")
            try expect(kids > 0 && bounds.x > 1.2, "entities from the stage: \(kids) children, bounds \(bounds)")
            return "stage rendered to \(kids) entities (bounds \(bounds.x)x\(bounds.y)), player: \(pm) meshes"
        })
        #endif
        // MARK: TabletopKit (visionOS)
        #if canImport(TabletopKit)
        c.append(check("TabletopKit", "table-setup-actions-snapshot", timeout: 60) {
            try await onMain {
                var setup = TableSetup(tabletop: P2Table())
                setup.add(equipment: [P2Die(id: EquipmentIdentifier(1)), P2Die(id: EquipmentIdentifier(2))])
                setup.add(seats: [P2Seat(id: TableSeatIdentifier(0)), P2Seat(id: TableSeatIdentifier(1))])
                let game = TabletopGame(tableSetup: setup)
                let obs = P2TableObserver(); game.addObserver(obs)
                var ids: [EquipmentIdentifier] = [], seats = 0, value = 0
                game.withCurrentSnapshot { s in ids = s.equipmentIDs(); seats = s.seatIDs.count; value = s.state(for: P2Die(id: EquipmentIdentifier(1))).value }
                try expect(Set(ids.map(\.rawValue)).isSuperset(of: [1, 2]) && seats == 2 && value == 1, "initial snapshot ids \(ids) seats \(seats) die \(value)")
                var st = DieState(value: 6, parentID: EquipmentIdentifier(0), boundingBox: Rect3D(center: .zero, size: Size3D(width: 0.02, height: 0.02, depth: 0.02)))
                st.pose = TableVisualState.Pose2D(position: .init(x: 0.1, z: 0.2), rotation: .zero)
                game.addAction(UpdateEquipmentAction<DieState>.updateEquipment(P2Die(id: EquipmentIdentifier(1)), state: st))
                game.addAction(MoveEquipmentAction.moveEquipment(matching: EquipmentIdentifier(2), childOf: EquipmentIdentifier(1)))
                for _ in 0..<10 { game.update(deltaTime: 1.0 / 30) }
                var v2 = 0, kids: [EquipmentIdentifier] = []
                game.withCurrentSnapshot { s in v2 = s.state(for: P2Die(id: EquipmentIdentifier(1))).value; kids = s.equipmentIDs(childrenOf: EquipmentIdentifier(1)) }
                try expect(v2 == 6, "die value after the update action \(v2)")
                try expect(kids.map(\.rawValue) == [2], "children of die 1: \(kids)")
                try expect(obs.confirmed.value >= 2, "observer confirmed \(obs.confirmed.names)")
                game.claimAnySeat()
                for _ in 0..<5 { game.update(deltaTime: 1.0 / 30) }
                let me = game.localPlayer
                return "2 dice + 2 seats; update + move actions confirmed (\(obs.confirmed.names)); local player \(me.id)"
            }
        })
        #endif
        #if canImport(_TabletopKit_RealityKit)
        c.append(check("_TabletopKit_RealityKit", "entity-equipment-snapshot", timeout: 60) {
            try await onMain {
                struct Board: EntityTabletop { let id = EquipmentIdentifier(0); let entity: Entity }
                struct Token: EntityEquipment { let id: EquipmentIdentifier; let entity: Entity
                    var initialState: BaseEquipmentState { BaseEquipmentState(parentID: EquipmentIdentifier(0), entity: entity) } }
                let boardE = ModelEntity(mesh: .generateBox(size: [1, 0.02, 1]), materials: [SimpleMaterial()])
                let tokE = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 0.03), materials: [SimpleMaterial(color: .red, isMetallic: false)])
                var setup = TableSetup(tabletop: Board(entity: boardE))
                setup.add(equipment: Token(id: EquipmentIdentifier(7), entity: tokE))
                setup.add(seat: P2Seat(id: TableSeatIdentifier(0)))   // a game needs a seat (TabletopKit traps otherwise)
                let game = TabletopGame(tableSetup: setup)
                for _ in 0..<3 { game.update(deltaTime: 1.0 / 30) }
                var found: Entity?, table: Entity?, bb = Rect3D()
                game.withCurrentSnapshot { s in found = s.entity(matching: EquipmentIdentifier(7)); table = s.tableEntity; bb = s.state(for: Token(id: EquipmentIdentifier(7), entity: tokE)).boundingBox }
                try expect(found === tokE && table === boardE, "snapshot entities \(String(describing: found)) \(String(describing: table))")
                try expect(game.equipment(of: Token.self, forEntity: tokE)?.id == EquipmentIdentifier(7), "equipment for entity")
                let shape = TabletopShape.rectangular(entity: boardE)
                _ = shape
                return "entity-backed board + token: snapshot entities match, bounding box \(bb.size)"
            }
        })
        #endif
        #if canImport(_TabletopKit_SwiftUI) && canImport(_TabletopKit_GroupActivities)
        c.append(check("_TabletopKit_SwiftUI", "tabletop-game-modifier-in-reality-view", timeout: 60) {
            let made = P2Count()
            let game = await onMain { () -> TabletopGame in
                var setup = TableSetup(tabletop: P2Table()); setup.add(equipment: P2Die(id: EquipmentIdentifier(1))); setup.add(seat: P2Seat(id: TableSeatIdentifier(0)))
                return TabletopGame(tableSetup: setup)
            }
            let root = await onMain { Entity() }
            let host = try await onMain {
                try hostInWindow(RealityView { content in content.add(root); made.add() }.tabletopGame(game, parent: root).frame(width: 300, height: 300))
            }
            defer { Task { @MainActor in host.view.removeFromSuperview(); host.removeFromParent() } }
            let ok = await p2Wait(20) { made.value > 0 }
            try expect(ok, "RealityView with .tabletopGame never made its content")
            try await Task.sleep(for: .milliseconds(500))
            return "RealityView + .tabletopGame(game, parent:) laid out; \(await onMain { root.children.count }) children under the parent"
        })
        c.append(check("_TabletopKit_GroupActivities", "coordinate-with-session-symbol", timeout: 30) {
            // SharePlay needs a FaceTime call (none in a simulator): the coordination entry point is checked to exist
            // and be callable in type; a GroupSession cannot be made without one
            let m: @MainActor (TabletopGame) -> (GroupSession<P2Activity>) -> Void = { g in { s in MainActor.assumeIsolated { g.coordinateWithSession(s) } } }
            _ = m
            var sessions = 0
            let t = Task { for await _ in P2Activity.sessions() { sessions += 1; break } }
            try await Task.sleep(for: .seconds(1)); t.cancel()
            try expect(sessions == 0, "a group session appeared without FaceTime")
            return "coordinateWithSession(_:) present; no GroupSession without a FaceTime call (as on Apple's simulator)"
        })
        #endif
        // MARK: ARKit
        #if canImport(ARKit) && os(iOS)
        c.append(check("ARKit", "simulator-unsupported-answers", timeout: 30) {
            // Apple's iOS simulator has no ARKit tracking: every configuration reports unsupported, a session run fails
            let sup = [("world", ARWorldTrackingConfiguration.isSupported), ("orientation", AROrientationTrackingConfiguration.isSupported),
                       ("face", ARFaceTrackingConfiguration.isSupported), ("body", ARBodyTrackingConfiguration.isSupported),
                       ("image", ARImageTrackingConfiguration.isSupported), ("object", ARObjectScanningConfiguration.isSupported),
                       ("geo", ARGeoTrackingConfiguration.isSupported), ("position", ARPositionalTrackingConfiguration.isSupported)]
            try expect(sup.allSatisfy { !$0.1 }, "supported configurations in the simulator: \(sup.filter(\.1).map(\.0))")
            let s = ARSession()
            final class D: NSObject, ARSessionDelegate { let err = P2Count(); func session(_ session: ARSession, didFailWithError error: Error) { err.add("\((error as NSError).domain) \((error as NSError).code)") } }
            let d = D(); s.delegate = d
            s.run(ARWorldTrackingConfiguration())
            let failed = await p2Wait(5) { d.err.value > 0 }
            s.pause()
            try expect(failed, "ARSession.run of an unsupported configuration reported no error")
            let ok = d.err.names.first ?? ""
            try expect(ok == "com.apple.arkit.error 100", "session error \(ok) (want ARError.unsupportedConfiguration 100)")
            return "all 8 configurations unsupported; run -> \(ok)"
        })
        #endif
        #if canImport(ARKit) && os(visionOS)
        c.append(check("ARKit", "providers-in-immersive-space", timeout: 120) {
            try skipIf(!sdkcovMultiScene, "the app declares one scene (shared Harness change: immersive scene, UIApplicationSupportsMultipleScenes)")
            let sup = ["world": WorldTrackingProvider.isSupported, "plane": PlaneDetectionProvider.isSupported, "scene": SceneReconstructionProvider.isSupported,
                       "hand": HandTrackingProvider.isSupported, "image": ImageTrackingProvider.isSupported, "light": EnvironmentLightEstimationProvider.isSupported]
            let a = try await sdkcovSceneActions()
            let r = await a.openImmersiveSpace(id: "sdkcov-immersive")
            guard case .opened = r else { throw Fail("openImmersiveSpace: \(r)") }
            defer { Task { await a.dismissImmersiveSpace() } }
            let session = ARKitSession(), world = WorldTrackingProvider()
            var providers: [any DataProvider] = [world]
            let planes = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
            // plane detection needs world-sensing authorization, which needs NSWorldSensingUsageDescription (an app
            // asking without it is killed): only with the key in Info.plist
            let sensingKey = Bundle.main.object(forInfoDictionaryKey: "NSWorldSensingUsageDescription") != nil
            let usePlanes = sup["plane"] == true && sensingKey
            if usePlanes { providers.append(planes) }
            var run = "ran"
            do { try await session.run(providers) } catch { run = "run threw \(error)" }
            // the device anchor (head pose) appears once tracking runs
            var anchor: DeviceAnchor?
            for _ in 0..<50 where anchor == nil { anchor = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()); if anchor == nil { try await Task.sleep(for: .milliseconds(100)) } }
            // a world anchor added and removed again
            var wa = "-"
            if world.state == .running {
                let w = WorldAnchor(originFromAnchorTransform: matrix_identity_float4x4)
                do {
                    try await world.addAnchor(w)
                    let all = try await world.allAnchors
                    try await world.removeAnchor(w)
                    wa = "added (\(all?.count ?? 0) anchors) + removed"
                } catch { wa = "world anchor \(error)" }
            }
            var planeCount = 0
            if usePlanes {
                let t = Task { for await u in planes.anchorUpdates { if u.event == .added { planeCount += 1 }; if planeCount >= 1 { break } } }
                try await Task.sleep(for: .seconds(5)); t.cancel()
            }
            let states = "world \(world.state), plane \(planes.state)"
            session.stop()
            try expect(anchor != nil, "no device anchor in 5 s (\(run), \(states))")
            return "supported \(sup.filter(\.value).keys.sorted()), \(run), device anchor present, world anchor \(wa), planes \(usePlanes ? "\(planeCount)" : "not run (no NSWorldSensingUsageDescription)"), \(states)"
        })
        #endif
        return c
    }
}

#if canImport(_TabletopKit_GroupActivities)
struct P2Activity: GroupActivity {
    static let activityIdentifier = "com.x86sim.test.sdkcov.tabletop"
    var metadata: GroupActivityMetadata { var m = GroupActivityMetadata(); m.title = "sdkcov tabletop"; m.type = .generic; return m }
}
#endif
/// a 16-bit mono 44.1 kHz sine WAV of `secs`
func p2Wav(_ u: URL, secs: Double) throws {
    let rate = 44100, n = Int(Double(rate) * secs)
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
    for i in 0..<n { u16(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 8000))) }
    try d.write(to: u)
}
