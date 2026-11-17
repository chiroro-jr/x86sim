// sdkcov P11: [a] gaps of frameworks already covered (coverage-gaps.json): CoreGraphics PDF scanning / gradients /
// JPEG data providers, layer rendering, JavaScriptCore exports, GameplayKit obstacle paths, HomeKit event predicates,
// AVFAudio session preferences, CoreImage kernels, OSLog signposts, SceneKit shadows + particles, Metal
// texture swizzle + fences, ModelIO materials + ambient occlusion, QuickLook thumbnails of PDF / text, ShazamKit's
// library, Vision registration / optical flow, Transferable data import / export, MPS threshold + Cholesky,
// AVPlayerItem failure, PHASE spatial playback (was visionOS only).
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import os
import simd
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
#if canImport(GameplayKit)
import GameplayKit
#endif
#if canImport(HomeKit)
import HomeKit
#endif
#if canImport(CoreImage) && !os(watchOS)
import CoreImage
#endif
#if canImport(OSLog)
import OSLog
#endif
#if canImport(SceneKit) && !os(watchOS)
import SceneKit
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(ModelIO)
import ModelIO
#endif
#if canImport(QuickLookThumbnailing) && (os(iOS) || os(visionOS))
import QuickLookThumbnailing
#endif
#if canImport(ShazamKit)
import ShazamKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreTransferable)
import CoreTransferable
#endif
#if canImport(MetalPerformanceShaders) && !os(watchOS)
import MetalPerformanceShaders
#endif
#if canImport(PHASE) && !os(watchOS)
import PHASE
#endif

/// a one-shot value set from any thread, awaited with a timeout
final class P11Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v: String?
    func set(_ s: String) { lock.withLock { if v == nil { v = s } } }
    func wait(seconds: Double) async -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if let v = lock.withLock({ v }) { return v }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return lock.withLock { v }
    }
}
final class P11Count: @unchecked Sendable { var ops: [String] = [] }

#if canImport(JavaScriptCore)
@objc protocol SDKCovJSPointExports: JSExport {
    var x: Double { get set }
    var y: Double { get set }
    func length() -> Double
}
final class SDKCovJSPoint: NSObject, SDKCovJSPointExports {
    dynamic var x: Double = 0, y: Double = 0
    func length() -> Double { (x * x + y * y).squareRoot() }
}
#endif

#if canImport(CoreImage) && !os(watchOS)
/// inverts BGRA8 on the CPU (CIImageProcessorKernel's buffer path)
final class SDKCovInvertKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .BGRA8 }
    override class func formatForInput(at input: Int32) -> CIFormat { .BGRA8 }
    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let i = inputs?.first else { return }
        let h = Int(output.region.height), w = Int(output.region.width)
        for r in 0..<h {
            let s = i.baseAddress.advanced(by: r * i.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let d = output.baseAddress.advanced(by: r * output.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for p in 0..<w { for k in 0..<3 { d[p * 4 + k] = 255 - s[p * 4 + k] }; d[p * 4 + 3] = s[p * 4 + 3] }
        }
    }
}
#endif

#if canImport(CoreTransferable)
struct SDKCovNote: Transferable, Equatable {
    var text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .utf8PlainText) { n in Data("note:\(n.text)".utf8) } importing: { d in
            let s = String(decoding: d, as: UTF8.self)
            guard s.hasPrefix("note:") else { throw Fail("not a note: \(s)") }
            return SDKCovNote(text: String(s.dropFirst(5)))
        }
        FileRepresentation(contentType: .plainText) { n in
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-note-\(UUID().uuidString).txt")
            try Data(n.text.utf8).write(to: u)
            return SentTransferredFile(u)
        } importing: { f in SDKCovNote(text: try String(contentsOf: f.file, encoding: .utf8)) }
    }
}
#endif

/// the mean of R+G+B over an image (0...765)
func p11Brightness(_ img: CGImage) -> Double {
    let c = bitmap(img.width, img.height); c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self); var s = 0
    for i in 0..<(img.width * img.height) { s += Int(p[i * 4]) + Int(p[i * 4 + 1]) + Int(p[i * 4 + 2]) }
    return Double(s) / Double(img.width * img.height)
}

extension Registry {
    static var p11: [Check] {
        var c: [Check] = []

        // MARK: CoreGraphics: a PDF's content stream through CGPDFScanner, a linear gradient, a JPEG decoded from a data provider
        c.append(check("CoreGraphics", "pdf-scanner-gradient-jpeg-provider") {
            let pdf = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 200, height: 100)
            guard let cons = CGDataConsumer(data: pdf as CFMutableData), let pc = CGContext(consumer: cons, mediaBox: &box, nil) else { throw Fail("PDF context") }
            pc.beginPDFPage(nil)
            pc.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); pc.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
            pc.fill(CGRect(x: 100, y: 10, width: 50, height: 50))
            pc.endPDFPage(); pc.closePDF()
            guard let prov = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(prov), let page = doc.page(at: 1) else { throw Fail("PDF reopen") }
            let ops = P11Count()
            guard let table = CGPDFOperatorTableCreate() else { throw Fail("operator table") }
            CGPDFOperatorTableSetCallback(table, "re") { _, info in Unmanaged<P11Count>.fromOpaque(info!).takeUnretainedValue().ops.append("re") }
            CGPDFOperatorTableSetCallback(table, "f") { _, info in Unmanaged<P11Count>.fromOpaque(info!).takeUnretainedValue().ops.append("f") }
            let stream = CGPDFContentStreamCreateWithPage(page)
            let sc = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(ops).toOpaque())
            try expect(CGPDFScannerScan(sc), "scan failed")
            CGPDFScannerRelease(sc); CGPDFContentStreamRelease(stream)
            try expect(ops.ops.filter { $0 == "re" }.count == 2 && ops.ops.contains("f"), "operators \(ops.ops)")
            // gradient red -> blue left to right
            let g = bitmap(100, 10)
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 5), end: CGPoint(x: 100, y: 5), options: [])
            let l = pixel(g, 1, 5), r = pixel(g, 98, 5), m = pixel(g, 50, 5)
            try expect(l[0] > 240 && l[2] < 15 && r[2] > 240 && r[0] < 15 && abs(Int(m[0]) - Int(m[2])) < 30, "gradient L \(l) M \(m) R \(r)")
            // JPEG through CGImage(jpegDataProviderSource:)
            let src = bitmap(32, 16); src.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); src.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            let jpg = try encode(src.makeImage()!, .jpeg)
            guard let jp = CGDataProvider(data: jpg as CFData), let ji = CGImage(jpegDataProviderSource: jp, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Fail("JPEG provider decode") }
            let jc = bitmap(32, 16); jc.draw(ji, in: CGRect(x: 0, y: 0, width: 32, height: 16)); let jpx = pixel(jc, 16, 8)
            try expect(ji.width == 32 && ji.height == 16 && jpx[1] > 200 && jpx[0] < 60, "JPEG \(ji.width)x\(ji.height) pixel \(jpx)")
            return "PDF ops \(ops.ops.joined(separator: " ")), gradient L \(l) R \(r), JPEG \(ji.width)x\(ji.height) \(jpx)"
        })

        // MARK: QuartzCore
        #if canImport(QuartzCore) && !os(watchOS)
        c.append(check("QuartzCore", "gradient-text-layer-render") {
            try await onMain {
                let g = CAGradientLayer(); g.frame = CGRect(x: 0, y: 0, width: 100, height: 20)
                g.colors = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)]
                g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
                let ctx = bitmap(100, 20); g.render(in: ctx)
                let l = pixel(ctx, 1, 10), r = pixel(ctx, 98, 10)
                try expect(l[0] > 230 && l[2] < 25 && r[2] > 230 && r[0] < 25, "gradient layer L \(l) R \(r)")
                let t = CATextLayer(); t.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
                t.string = "WWW"; t.fontSize = 30; t.foregroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                t.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                let tc = bitmap(120, 40); t.render(in: tc)
                var dark = 0
                for y in 0..<40 { for x in 0..<120 where pixel(tc, x, y)[0] < 100 { dark += 1 } }
                try expect(dark > 100 && dark < 120 * 40 / 2, "text layer dark pixels \(dark)")
                return "gradient L \(l) R \(r), text \(dark) dark px"
            }
        })
        #endif

        // MARK: JavaScriptCore
        #if canImport(JavaScriptCore)
        c.append(check("JavaScriptCore", "jsexport-virtual-machine") {
            let vm = JSVirtualMachine()!
            let c1 = JSContext(virtualMachine: vm)!, c2 = JSContext(virtualMachine: vm)!
            let p = SDKCovJSPoint()
            c1.setObject(p, forKeyedSubscript: "pt" as NSString)
            let len = c1.evaluateScript("pt.x = 3; pt.y = 4; pt.length()")?.toDouble() ?? -1
            try expect(c1.exception == nil, "exception \(String(describing: c1.exception))")
            try expect(len == 5 && p.x == 3 && p.y == 4, "length \(len), native point \(p.x),\(p.y)")
            // a value made in one context used from another context of the same virtual machine
            let obj = c1.evaluateScript("({a: 41, f: function(v) { return this.a + v }})")!
            c2.setObject(obj, forKeyedSubscript: "o" as NSString)
            let r = c2.evaluateScript("o.f(1)")?.toInt32() ?? -1
            try expect(r == 42 && c2.exception == nil, "cross-context call \(r), \(String(describing: c2.exception))")
            // a native block as a JS function
            let mul: @convention(block) (Double, Double) -> Double = { $0 * $1 }
            c2.setObject(mul, forKeyedSubscript: "mul" as NSString)
            let m = c2.evaluateScript("mul(6, 7)")?.toDouble() ?? -1
            try expect(m == 42, "block \(m)")
            return "JSExport length \(len), cross-context \(r), block \(m)"
        })
        #endif

        // MARK: GameplayKit
        #if canImport(GameplayKit)
        c.append(check("GameplayKit", "obstacle-graph-pathfinding") {
            // a square obstacle between start and goal: the path goes around its (buffered) corners
            let sq = [SIMD2<Float>(4, -3), SIMD2<Float>(6, -3), SIMD2<Float>(6, 3), SIMD2<Float>(4, 3)]
            let ob = GKPolygonObstacle(points: sq)
            let g = GKObstacleGraph(obstacles: [ob], bufferRadius: 0.5)
            let a = GKGraphNode2D(point: SIMD2(0, 0)), b = GKGraphNode2D(point: SIMD2(10, 0))
            g.connectUsingObstacles(node: a); g.connectUsingObstacles(node: b)
            let path = g.findPath(from: a, to: b) as? [GKGraphNode2D] ?? []
            try expect(path.count >= 3 && path.first === a && path.last === b, "path of \(path.count) nodes")
            try expect(path.dropFirst().dropLast().allSatisfy { abs($0.position.y) >= 3 }, "path through the obstacle: \(path.map { $0.position })")
            try expect(!a.connectedNodes.contains { $0 === b }, "start sees the goal through the obstacle")
            return "\(path.count) nodes: \(path.map { "(\(Int($0.position.x.rounded())),\(String(format: "%.1f", $0.position.y)))" }.joined(separator: " "))"
        })
        #endif

        // MARK: HomeKit: events and trigger predicates without a home
        #if canImport(HomeKit)
        c.append(check("HomeKit", "event-trigger-predicates") {
            var off = DateComponents(); off.minute = -10
            let sunrise = HMSignificantTimeEvent(significantEvent: .sunrise, offset: off)
            try expect(sunrise.significantEvent == .sunrise && sunrise.offset?.minute == -10, "significant event \(sunrise.significantEvent.rawValue) \(String(describing: sunrise.offset))")
            var fire = DateComponents(); fire.hour = 7; fire.minute = 30
            let cal = HMCalendarEvent(fire: fire)
            try expect(cal.fireDateComponents.hour == 7 && cal.fireDateComponents.minute == 30, "calendar event \(cal.fireDateComponents)")
            let before = HMEventTrigger.predicateForEvaluatingTriggerOccurring(beforeSignificantEvent: sunrise)
            var t1 = DateComponents(); t1.hour = 9; var t2 = DateComponents(); t2.hour = 17
            let between = HMEventTrigger.predicateForEvaluatingTriggerOccurringBetweenDate(with: t1, secondDateWith: t2)
            try expect(!before.predicateFormat.isEmpty && !between.predicateFormat.isEmpty, "empty predicates")
            #if os(iOS) || os(visionOS)
            let trig = HMEventTrigger(name: "sdkcov", events: [cal], end: nil, recurrences: nil, predicate: between)
            try expect(trig.events.count == 1 && trig.predicate != nil && !trig.isEnabled, "trigger events \(trig.events.count) enabled \(trig.isEnabled)")
            #endif
            return "before sunrise: \(before.predicateFormat.prefix(80)); between: \(between.predicateFormat.prefix(80))"
        })
        #endif

        // MARK: AVFAudio
        #if !os(watchOS)
        c.append(check("AVFAudio", "session-preferred-rate-io-duration") {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback)
            try s.setPreferredSampleRate(48000)
            try s.setPreferredIOBufferDuration(0.02)
            try expect(s.preferredSampleRate == 48000 && abs(s.preferredIOBufferDuration - 0.02) < 1e-6,
                       "preferred \(s.preferredSampleRate) Hz / \(s.preferredIOBufferDuration) s")
            try s.setActive(true)
            defer { try? s.setActive(false) }
            try expect(s.sampleRate > 0 && s.ioBufferDuration > 0 && s.outputNumberOfChannels > 0, "active \(s.sampleRate) Hz, io \(s.ioBufferDuration) s, \(s.outputNumberOfChannels) ch")
            return String(format: "preferred 48000 / 0.020 -> %.0f Hz, io %.4f s, %d out ch, route %@", s.sampleRate, s.ioBufferDuration, s.outputNumberOfChannels,
                          s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))
        })
        #endif

        // MARK: CoreImage: a color kernel from source and a CPU image processor kernel
        #if canImport(CoreImage) && !os(watchOS)
        c.append(check("CoreImage", "color-kernel-processor-kernel") {
            let ctx = CIContext()
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            func px(_ i: CIImage) -> [UInt8] {
                var b = [UInt8](repeating: 0, count: 4)
                ctx.render(i, toBitmap: &b, rowBytes: 4, bounds: CGRect(x: 2, y: 2, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return b
            }
            guard let k = CIColorKernel(source: "kernel vec4 swapRG(__sample s) { return vec4(s.g, s.r, s.b, s.a); }") else { throw Fail("color kernel did not compile") }
            guard let sw = k.apply(extent: red.extent, arguments: [red]) else { throw Fail("kernel apply nil") }
            let a = px(sw)
            try expect(a[1] > 240 && a[0] < 15, "swapped pixel \(a)")
            let inv = try SDKCovInvertKernel.apply(withExtent: red.extent, inputs: [red], arguments: nil)
            let b = px(inv)
            try expect(b[0] < 15 && b[1] > 240 && b[2] > 240 && b[3] > 240, "inverted pixel \(b)")
            return "color kernel red -> \(a), processor kernel invert -> \(b)"
        })
        #endif

        // MARK: OSLog: signposts and position filtering in the process's own store
        #if canImport(OSLog)
        c.append(check("OSLog", "store-signposts-position", timeout: 40) {
            let t0 = Date().addingTimeInterval(-1)
            let tag = "p11-\(UUID().uuidString.prefix(8))"
            let sp = OSSignposter(subsystem: "com.x86sim.test.sdkcov", category: "p11")
            let st = sp.beginInterval("sdkcov-interval", id: sp.makeSignpostID(), "\(tag, privacy: .public)")
            Logger(subsystem: "com.x86sim.test.sdkcov", category: "p11").notice("sdkcov marker \(tag, privacy: .public)")
            sp.endInterval("sdkcov-interval", st)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let pos = store.position(date: t0)
            let pred = NSPredicate(format: "subsystem == %@", "com.x86sim.test.sdkcov")
            let entries = try store.getEntries(at: pos, matching: pred)
            var marker = false, begin = 0, end = 0
            for e in entries {
                if let s = e as? OSLogEntrySignpost {
                    if s.signpostName == "sdkcov-interval" { if s.signpostType == .intervalBegin { begin += 1 } else if s.signpostType == .intervalEnd { end += 1 } }
                } else if let l = e as? OSLogEntryLog, l.composedMessage.contains(tag) { marker = true }
            }
            try expect(marker, "the marker message is not in the store")
            // newest first: the reverse enumeration's dates never increase
            let rev = try store.getEntries(with: [.reverse], at: store.position(date: t0), matching: pred).prefix(50).map(\.date)
            try expect(!rev.isEmpty && zip(rev, rev.dropFirst()).allSatisfy { $0 >= $1 }, "reverse order: \(rev.count) entries not newest first")
            return "marker found, signposts begin \(begin) end \(end), reverse enumeration newest first"
        })
        #endif

        // MARK: SceneKit: shadows and a particle system rendered offscreen
        #if canImport(SceneKit) && !os(watchOS)
        c.append(check("SceneKit", "renderer-shadows-particles", timeout: 60) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Skip("no Metal device") }
            func scene(shadows: Bool, particles: Bool) -> SCNScene {
                let s = SCNScene(); s.background.contents = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 10, 0); cam.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
                s.rootNode.addChildNode(cam)
                if particles {
                    let ps = SCNParticleSystem(); ps.birthRate = 2000; ps.particleLifeSpan = 5; ps.particleSize = 0.3
                    ps.particleColor = .white; ps.emitterShape = SCNBox(width: 6, height: 0.1, length: 6, chamferRadius: 0)
                    ps.warmupDuration = 1; ps.particleVelocity = 0
                    let n = SCNNode(); n.addParticleSystem(ps); s.rootNode.addChildNode(n)
                    return s
                }
                let floor = SCNNode(geometry: SCNPlane(width: 20, height: 20)); floor.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
                floor.geometry?.firstMaterial?.diffuse.contents = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                s.rootNode.addChildNode(floor)
                let box = SCNNode(geometry: SCNBox(width: 2, height: 4, length: 2, chamferRadius: 0)); box.position = SCNVector3(0, 2, 0)
                s.rootNode.addChildNode(box)
                let l = SCNNode(); l.light = SCNLight(); l.light!.type = .directional; l.light!.castsShadow = shadows
                l.light!.shadowMode = .forward; l.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
                s.rootNode.addChildNode(l)
                return s
            }
            func shot(_ s: SCNScene) -> CGImage? {
                let r = SCNRenderer(device: dev, options: nil); r.scene = s
                #if os(iOS) || os(tvOS) || os(visionOS)
                return r.snapshot(atTime: 1, with: CGSize(width: 96, height: 96), antialiasingMode: .none).cgImage
                #else
                return nil
                #endif
            }
            guard let lit = shot(scene(shadows: false, particles: false)), let sh = shot(scene(shadows: true, particles: false)),
                  let pt = shot(scene(shadows: false, particles: true)) else { throw Fail("no snapshot") }
            let bl = p11Brightness(lit), bs = p11Brightness(sh), bp = p11Brightness(pt)
            try expect(bl > 100, "lit scene too dark (\(bl))")
            try expect(bs < bl - 5, "shadow does not darken the scene: \(bs) vs \(bl)")
            try expect(bp > 20, "particles invisible (\(bp))")
            return String(format: "brightness lit %.0f, with shadow %.0f, particles %.0f", bl, bs, bp)
        })
        #endif

        // MARK: Metal: a swizzled texture view read by a kernel; a fence between two compute encoders
        #if canImport(Metal)
        c.append(check("Metal", "texture-view-swizzle-fence", timeout: 60) {
            guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw Skip("no Metal device") }
            let src = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void readpx(texture2d<float, access::read> t [[texture(0)]], device float4 *o [[buffer(0)]]) { o[0] = t.read(uint2(0, 0)); }
            kernel void fill(device uint *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] = i * 3; }
            kernel void sum(device const uint *b [[buffer(0)]], device atomic_uint *s [[buffer(1)]], uint i [[thread_position_in_grid]]) { atomic_fetch_add_explicit(s, b[i], memory_order_relaxed); }
            """
            let lib = try await d.makeLibrary(source: src, options: nil)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            td.usage = [.shaderRead, .pixelFormatView]
            guard let tex = d.makeTexture(descriptor: td) else { throw Fail("texture") }
            var px: [UInt8] = [51, 102, 153, 204]
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
            guard let view = tex.makeTextureView(pixelFormat: .rgba8Unorm, textureType: .type2D, levels: 0..<1, slices: 0..<1,
                                                 swizzle: MTLTextureSwizzleChannels(red: .blue, green: .alpha, blue: .red, alpha: .one)) else { throw Fail("swizzled view") }
            let out = d.makeBuffer(length: 16, options: .storageModeShared)!
            let p1 = try await d.makeComputePipelineState(function: lib.makeFunction(name: "readpx")!)
            let cb = q.makeCommandBuffer()!, en = cb.makeComputeCommandEncoder()!
            en.setComputePipelineState(p1); en.setTexture(view, index: 0); en.setBuffer(out, offset: 0, index: 0)
            en.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)); en.endEncoding()
            // fence: the second encoder sums what the first wrote
            let n = 256
            let buf = d.makeBuffer(length: n * 4, options: .storageModeShared)!, tot = d.makeBuffer(length: 4, options: .storageModeShared)!
            memset(tot.contents(), 0, 4)
            let fence = d.makeFence()!
            let pf = try await d.makeComputePipelineState(function: lib.makeFunction(name: "fill")!), ps = try await d.makeComputePipelineState(function: lib.makeFunction(name: "sum")!)
            let e1 = cb.makeComputeCommandEncoder()!
            e1.setComputePipelineState(pf); e1.setBuffer(buf, offset: 0, index: 0)
            e1.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            e1.updateFence(fence); e1.endEncoding()
            let e2 = cb.makeComputeCommandEncoder()!
            e2.waitForFence(fence); e2.setComputePipelineState(ps); e2.setBuffer(buf, offset: 0, index: 0); e2.setBuffer(tot, offset: 0, index: 1)
            e2.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)); e2.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            try expect(cb.status == .completed, "command buffer \(cb.status.rawValue) \(String(describing: cb.error))")
            let f = out.contents().assumingMemoryBound(to: Float.self)
            let got = (0..<4).map { Int((f[$0] * 255).rounded()) }
            try expect(got == [153, 204, 51, 255], "swizzled read \(got) (want 153, 204, 51, 255)")
            let s = tot.contents().load(as: UInt32.self)
            try expect(s == UInt32(3 * n * (n - 1) / 2), "fenced sum \(s)")
            return "swizzle (b,a,r,1) -> \(got), fenced sum \(s)"
        })
        #endif

        // MARK: ModelIO: material properties and ambient occlusion baked into vertex colors
        #if canImport(ModelIO)
        c.append(check("ModelIO", "material-ambient-occlusion", timeout: 60) {
            let sf = MDLPhysicallyPlausibleScatteringFunction()
            sf.baseColor.float3Value = SIMD3(0.8, 0.2, 0.1); sf.roughness.floatValue = 0.3; sf.metallic.floatValue = 1
            let mat = MDLMaterial(name: "sdkcov", scatteringFunction: sf)
            let bc = mat.property(with: .baseColor)?.float3Value ?? .zero
            try expect(abs(bc.x - 0.8) < 1e-6 && mat.property(with: .metallic)?.floatValue == 1 && mat.property(with: .roughness)?.floatValue == 0.3, "material base \(bc)")
            let light = MDLPhysicallyPlausibleLight(); light.lightType = .point; light.setColorByTemperature(6500)
            try expect(light.color != nil, "light color from temperature")
            // a box resting on a plane: the faces against the plane get occlusion
            let box = MDLMesh(boxWithExtent: SIMD3(1, 1, 1), segments: SIMD3(2, 2, 2), inwardNormals: false, geometryType: .triangles, allocator: nil)
            let plane = MDLMesh(planeWithExtent: SIMD3(4, 0, 4), segments: SIMD2(4, 4), geometryType: .triangles, allocator: nil)
            let pt = MDLTransform(); pt.translation = SIMD3(0, -0.5, 0); plane.transform = pt
            let ok = box.generateAmbientOcclusionVertexColors(withQuality: 0.5, attenuationFactor: 0.5, objectsToConsider: [box, plane], vertexAttributeNamed: MDLVertexAttributeOcclusionValue)
            try expect(ok, "ambient occlusion failed")
            guard let occ = box.vertexAttributeData(forAttributeNamed: MDLVertexAttributeOcclusionValue, as: .float) else { throw Fail("no occlusion attribute") }
            var vals: [Float] = []
            for i in 0..<box.vertexCount { vals.append(occ.dataStart.advanced(by: i * occ.stride).assumingMemoryBound(to: Float.self).pointee) }
            let lo = vals.min() ?? 0, hi = vals.max() ?? 0
            try expect(hi > lo, "occlusion uniform \(lo)")
            return String(format: "material ok, %d vertices occlusion %.2f...%.2f", box.vertexCount, lo, hi)
        })
        #endif

        // MARK: QuickLookThumbnailing: PDF and plain text
        #if canImport(QuickLookThumbnailing) && (os(iOS) || os(visionOS))
        c.append(check("QuickLookThumbnailing", "thumbnails-pdf-text", timeout: 60) {
            let dir = FileManager.default.temporaryDirectory
            let txt = dir.appendingPathComponent("sdkcov-thumb.txt"); try Data(String(repeating: "sdkcov thumbnail text\n", count: 40).utf8).write(to: txt)
            let pdfURL = dir.appendingPathComponent("sdkcov-thumb.pdf")
            var box = CGRect(x: 0, y: 0, width: 300, height: 400)
            guard let pc = CGContext(pdfURL as CFURL, mediaBox: &box, nil) else { throw Fail("PDF") }
            pc.beginPDFPage(nil); pc.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); pc.fill(CGRect(x: 0, y: 0, width: 300, height: 200)); pc.endPDFPage(); pc.closePDF()
            var parts: [String] = []
            for u in [pdfURL, txt] {
                let rq = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 120, height: 120), scale: 1, representationTypes: .thumbnail)
                let r = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: rq)
                let img = r.cgImage
                try expect(r.type == .thumbnail && img.width > 20 && img.height > 20, "\(u.pathExtension): type \(r.type.rawValue) \(img.width)x\(img.height)")
                parts.append("\(u.pathExtension) \(img.width)x\(img.height)")
            }
            return parts.joined(separator: ", ")
        })
        #endif

        // MARK: ShazamKit: the user's Shazam library
        #if canImport(ShazamKit)
        c.append(check("ShazamKit", "library-add-read", timeout: 30) {
            let item = SHMediaItem(properties: [.title: "sdkcov p11", .artist: "x86Sim", .shazamID: "999999999"])
            // Apple's simulator (27.2): addItems never answers (no Shazam library service for a simctl-installed app)
            let ans = P11Flag()
            Task { do { try await SHLibrary.default.addItems([item]); ans.set("added") } catch { ans.set("error \((error as NSError).domain) \((error as NSError).code)") } }
            let a = await ans.wait(seconds: 10)
            if a == "added" {
                let items = await SHLibrary.default.items
                try expect(items.contains { $0.title == "sdkcov p11" }, "added item not read back (\(items.count) items)")
                return "added + read back (\(items.count) items)"
            }
            #if os(tvOS)
            // no shazamd in the tvOS runtime: Apple's tvOS simulator refuses at once
            try expect(a == "error com.apple.ShazamKit.ShazamLibrary 301", "addItems answered \(a ?? "nothing") (Apple's tvOS simulator: ShazamLibrary 301)")
            return "addItems refused: ShazamLibrary 301, as on Apple's tvOS simulator"
            #else
            try expect(a == nil, "addItems answered \(a!) (Apple's simulator: no answer)")
            return "addItems: no answer in 10 s, as on Apple's simulator"
            #endif
        })
        #endif

        // MARK: Vision
        #if canImport(Vision) && os(watchOS)
        c.append(check("Vision", "translational-registration-horizon", timeout: 60) {
            // watchOS has only the tracking (sequence) form: the second frame is the first shifted 12 px right / 8 px down
            let a = p7Square(200, 160, x: 50, y: 50), b = p7Square(200, 160, x: 62, y: 42)
            let rq = TrackTranslationalImageRegistrationRequest()
            _ = try await rq.perform(on: a)
            let o = try await rq.perform(on: b)
            let t = o.alignmentTransform
            try expect(abs(abs(t.tx) - 12) <= 2 && abs(abs(t.ty) - 8) <= 2, "alignment \(t.tx), \(t.ty)")
            let hz = try await DetectHorizonRequest().perform(on: a)
            return "shift (\(String(format: "%.1f", t.tx)), \(String(format: "%.1f", t.ty))), horizon \(hz.map { String(format: "%.2f", $0.angle.value) } ?? "none")"
        })
        #endif
        #if canImport(Vision) && !os(watchOS)
        c.append(check("Vision", "optical-flow-homographic", timeout: 90) {
            let a = p7Square(200, 160, x: 50, y: 50), b = p7Square(200, 160, x: 62, y: 42)
            let h = VNHomographicImageRegistrationRequest(targetedCGImage: b)
            try VNImageRequestHandler(cgImage: a).perform([h])
            guard let ho = h.results?.first else { throw Fail("no homographic observation") }
            let m = ho.warpTransform
            let hm = [m.columns.0, m.columns.1, m.columns.2].map { "(\(String(format: "%.2f, %.2f, %.2f", $0.x, $0.y, $0.z)))" }.joined(separator: " ")
            let of = VNGenerateOpticalFlowRequest(targetedCGImage: b)
            of.computationAccuracy = .low
            var flow = "error"
            do {
                try VNImageRequestHandler(cgImage: a).perform([of])
                if let pb = of.results?.first?.pixelBuffer {
                    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
                    var sx: Float = 0, sy: Float = 0, n: Float = 0
                    if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_TwoComponent32Float, let base = CVPixelBufferGetBaseAddress(pb) {
                        for y in 0..<h { let r = (base + y * bpr).assumingMemoryBound(to: Float.self); for x in 0..<w where abs(r[2 * x]) + abs(r[2 * x + 1]) > 1 { sx += r[2 * x]; sy += r[2 * x + 1]; n += 1 } }
                    }
                    let ft = CVPixelBufferGetPixelFormatType(pb), fourcc = String((0..<4).map { Character(UnicodeScalar(UInt8((ft >> (24 - 8 * $0)) & 0xff))) })
                    var mx: Float = 0
                    if let base = CVPixelBufferGetBaseAddress(pb) { for y in 0..<h { let r = (base + y * bpr).assumingMemoryBound(to: Float.self); for x in 0..<(2 * w) { mx = max(mx, abs(r[x])) } } }
                    flow = "\(w)x\(h) moving \(Int(n)) mean (\(String(format: "%.1f, %.1f", n > 0 ? sx / n : 0, n > 0 ? sy / n : 0))) \(fourcc) max \(String(format: "%.2f", mx))"
                } else { flow = "no result" }
            } catch { flow = "\((error as NSError).domain) \((error as NSError).code)" }
            // Apple's 27.2 simulators: an identity homography for this pair; optical flow runs on visionOS (the square moves
            // right / down) and fails com.apple.Vision 9 on iOS / tvOS
            try expect(abs(m.columns.0.x - 1) < 0.01 && abs(m.columns.1.y - 1) < 0.01 && abs(m.columns.2.z - 1) < 0.01, "homography \(hm)")
            #if os(visionOS)
            try expect(flow.hasPrefix("200x160 moving") && !flow.contains("moving 0 "), "optical flow \(flow)")
            #else
            try expect(flow == "com.apple.Vision 9", "optical flow \(flow) (Apple's simulator: com.apple.Vision 9)")
            #endif
            return "homography \(hm), optical flow \(flow)"
        })
        #endif

        // MARK: CoreTransferable
        #if canImport(CoreTransferable)
        c.append(check("CoreTransferable", "data-file-representation-roundtrip") {
            let n = SDKCovNote(text: "hello p11")
            let types = n.exportedContentTypes()
            try expect(types.contains(.utf8PlainText) && types.contains(.plainText), "exported types \(types)")
            let d = try await n.exported(as: .utf8PlainText)
            try expect(String(decoding: d, as: UTF8.self) == "note:hello p11", "exported \(String(decoding: d, as: UTF8.self))")
            let back = try await SDKCovNote(importing: d, contentType: .utf8PlainText)
            try expect(back == n, "imported \(back.text)")
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-note-in.txt"); try Data("from file".utf8).write(to: u)
            let f = try await SDKCovNote(importing: u, contentType: .plainText)
            try expect(f.text == "from file", "file import \(f.text)")
            var bad = "accepted"
            do { _ = try await SDKCovNote(importing: Data("junk".utf8), contentType: .utf8PlainText) } catch { bad = "refused" }
            try expect(bad == "refused", "a malformed note was imported")
            return "types \(types.map(\.identifier)), data + file round trip, malformed refused"
        })
        #endif

        // MARK: MetalPerformanceShaders: binary threshold + median on a texture, Cholesky factorization
        #if canImport(MetalPerformanceShaders) && !os(watchOS)
        c.append(check("MetalPerformanceShaders", "threshold-median-cholesky", timeout: 60) {
            guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw Skip("no Metal device") }
            try skipIf(!MPSSupportsMTLDevice(d), "MPS does not support the device")
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 8, height: 8, mipmapped: false)
            td.usage = [.shaderRead, .shaderWrite]
            let src = d.makeTexture(descriptor: td)!, mid = d.makeTexture(descriptor: td)!, dst = d.makeTexture(descriptor: td)!
            // a horizontal ramp 0..224 with one bright speck at (1, 1)
            var px = [UInt8](repeating: 0, count: 64)
            for y in 0..<8 { for x in 0..<8 { px[y * 8 + x] = UInt8(x * 32) } }
            px[9] = 255
            src.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: &px, bytesPerRow: 8)
            let cb = q.makeCommandBuffer()!
            MPSImageMedian(device: d, kernelDiameter: 3).encode(commandBuffer: cb, sourceTexture: src, destinationTexture: mid)
            MPSImageThresholdBinary(device: d, thresholdValue: 0.5, maximumValue: 1, linearGrayColorTransform: nil).encode(commandBuffer: cb, sourceTexture: mid, destinationTexture: dst)
            // Cholesky of the SPD matrix [[4, 2], [2, 3]]: L = [[2, 0], [1, sqrt 2]]
            let md = MPSMatrixDescriptor(rows: 2, columns: 2, rowBytes: 8, dataType: .float32)
            let a = d.makeBuffer(bytes: [Float(4), 2, 2, 3], length: 16, options: .storageModeShared)!
            let r = d.makeBuffer(length: 16, options: .storageModeShared)!
            let ch = MPSMatrixDecompositionCholesky(device: d, lower: true, order: 2)
            ch.encode(commandBuffer: cb, sourceMatrix: MPSMatrix(buffer: a, descriptor: md), resultMatrix: MPSMatrix(buffer: r, descriptor: md), status: nil)
            cb.commit(); cb.waitUntilCompleted()
            try expect(cb.status == .completed, "command buffer \(cb.status.rawValue) \(String(describing: cb.error))")
            var med = [UInt8](repeating: 0, count: 64), out = [UInt8](repeating: 0, count: 64)
            mid.getBytes(&med, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            dst.getBytes(&out, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            try expect(med[9] < 100, "median kept the speck (\(med[9]))")
            let row = Array(out[32..<40])
            try expect(row == [0, 0, 0, 0, 255, 255, 255, 255], "threshold row \(row)")
            let l = r.contents().assumingMemoryBound(to: Float.self)
            try expect(abs(l[0] - 2) < 1e-4 && abs(l[2] - 1) < 1e-4 && abs(l[3] - Float(2).squareRoot()) < 1e-4, "L \(l[0]) \(l[1]) \(l[2]) \(l[3])")
            return String(format: "median speck %d, threshold row %@, L = [[%.3f, _], [%.3f, %.3f]]", med[9], row.description, l[0], l[2], l[3])
        })
        #endif

        // MARK: AVFoundation: an item that cannot play fails with an error
        c.append(check("AVFoundation", "player-item-failed-status", timeout: 30) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-broken.mp4")
            try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 * 7) }).write(to: u)
            let item = AVPlayerItem(url: u)
            let player = AVPlayer(playerItem: item)
            let end = Date().addingTimeInterval(20)
            while item.status == .unknown && Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
            _ = player
            try expect(item.status == .failed, "status \(item.status.rawValue)")
            let e = item.error as NSError?
            try expect(e?.domain == AVFoundationErrorDomain, "error \(String(describing: e))")
            return "failed: \(e!.domain) \(e!.code)"
        })

        // MARK: PHASE: a spatial sound event plays to the end (was a visionOS-only check)
        #if canImport(PHASE) && !os(watchOS)
        c.append(check("PHASE", "spatial-sound-event-playback", timeout: 60) {
            let e = PHASEEngine(updateMode: .automatic)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let tone = sine(440, secs: 0.3, rate: 48000)
            let data = Data(bytes: tone.floatChannelData![0], count: Int(tone.frameLength) * 4)
            _ = try e.assetRegistry.registerSoundAsset(data: data, identifier: "sdkcov-tone", format: fmt, normalizationMode: .dynamic)
            guard let pipe = PHASESpatialPipeline(flags: [.directPathTransmission]) else { throw Fail("spatial pipeline") }
            let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipe)
            let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: "sdkcov-tone", mixerDefinition: mixer)
            sampler.playbackMode = .oneShot; sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
            _ = try e.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: "sdkcov-event")
            let listener = PHASEListener(engine: e); listener.transform = matrix_identity_float4x4
            try e.rootObject.addChild(listener)
            let shape = PHASEShape(engine: e, mesh: MDLMesh.newIcosahedron(withRadius: 0.1, inwardNormals: false, allocator: nil))
            let source = PHASESource(engine: e, shapes: [shape])
            var t = matrix_identity_float4x4; t.columns.3 = [1, 0, -1, 1]; source.transform = t
            try e.rootObject.addChild(source)
            let params = PHASEMixerParameters(); params.addSpatialMixerParameters(identifier: mixer.identifier, source: source, listener: listener)
            let ev = try PHASESoundEvent(engine: e, assetIdentifier: "sdkcov-event", mixerParameters: params)
            do { try e.start() } catch { throw Fail("engine start: \(error)") }
            defer { e.stop(); e.assetRegistry.unregisterAsset(identifier: "sdkcov-event"); e.assetRegistry.unregisterAsset(identifier: "sdkcov-tone") }
            let done = P11Flag()
            ev.start { reason in done.set("\(reason.rawValue)") }
            guard let reason = await done.wait(seconds: 15) else { throw Fail("the sound event never finished (state \(ev.renderingState.rawValue))") }
            try expect(reason == "\(PHASESoundEvent.StartHandlerReason.finishedPlaying.rawValue)", "event ended with reason \(reason)")
            return "finished playing (spatial mixer, source at 1,0,-1)"
        })
        #endif
        return c
    }
}
