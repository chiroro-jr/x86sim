// SDK coverage, round 17: [a] gaps of covered frameworks. Braille tables / translation (Accessibility), Metal's
// parallel render encoder with a stencil test, MPS image conversion and LU solve, MTKMesh from an MDLAsset with a
// custom vertex descriptor, ModelIO light probe spherical harmonics, the window scene's display link cadence,
// CIDetector rectangles / faces, secure text fields, UIContextMenuInteraction and SwiftUI's contextMenu presented,
// shared web credentials, captive network info, WebKit IndexedDB, VideoToolbox ProRes, SpriteKit's model on watchOS.
import Foundation
import Synchronization
import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Accessibility)
import Accessibility
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(ModelIO)
import ModelIO
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(Security)
import Security
#endif
#if os(iOS)
import SystemConfiguration.CaptiveNetwork
#endif
#if canImport(WebKit) && !os(tvOS) && !os(watchOS)
import WebKit
#endif
#if canImport(VideoToolbox)
import VideoToolbox
import CoreMedia
import CoreVideo
#endif
#if canImport(SpriteKit)
import SpriteKit
#endif
#if canImport(MessageUI)
import MessageUI
#endif
#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif
#if canImport(SceneKit)
import SceneKit
#endif
#if canImport(GLKit)
import GLKit
import OpenGLES
#endif
#if canImport(IOSurface)
import IOSurface
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(ReplayKit)
import ReplayKit
#endif
#if canImport(GameKit)
import GameKit
#endif
#if canImport(MediaAccessibility)
import MediaAccessibility
#endif
#if canImport(Network)
import Network
#endif
#if canImport(MapKit)
import MapKit
#endif
#if canImport(SafariServices) && os(iOS)
import SafariServices
#endif
#if canImport(PushKit)
import PushKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(LinkPresentation)
import LinkPresentation
#endif
import AVFoundation
#if canImport(AVKit) && !os(watchOS)
import AVKit
#endif

#if canImport(UIKit) && !os(watchOS)
/// a context-menu delegate logging what UIKit asks it
final class P13MenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    let log = P6Log()
    func contextMenuInteraction(_ i: UIContextMenuInteraction, configurationForMenuAtLocation p: CGPoint) -> UIContextMenuConfiguration? {
        log.add("config")
        return UIContextMenuConfiguration(identifier: "sdkcov" as NSString, previewProvider: nil) { _ in
            self.log.add("actions")
            return UIMenu(title: "SDKCovMenu", children: [UIAction(title: "SDKCovCtxOne") { _ in }, UIAction(title: "SDKCovCtxTwo") { _ in }])
        }
    }
    func contextMenuInteraction(_ i: UIContextMenuInteraction, willDisplayMenuFor c: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) { log.add("willDisplay") }
    func contextMenuInteraction(_ i: UIContextMenuInteraction, willEndFor c: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) { log.add("willEnd") }
}
/// present a context menu interaction's menu at a point (UIKit's private entry, the one a long press ends in)
@MainActor func p13PresentMenu(_ i: UIContextMenuInteraction, _ at: CGPoint) -> Bool {
    let sel = NSSelectorFromString("_presentMenuAtLocation:")
    guard i.responds(to: sel) else { return false }
    typealias F = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    unsafeBitCast(i.method(for: sel), to: F.self)(i, sel, at)
    return true
}
/// every label text in the scene's windows (menus live in their own window)
@MainActor func p13Labels() -> [String] {
    guard let ws = try? p6Scene() else { return [] }
    return ws.windows.flatMap { p6Find($0, UILabel.self) }.compactMap(\.text)
}
#endif


#if canImport(UIKit) && !os(watchOS)
final class P13Tick: NSObject {
    var stamps: [(Double, Double)] = []
    @objc func tick(_ l: CADisplayLink) { stamps.append((l.timestamp, l.targetTimestamp)) }
}
#endif

/// a one-shot HTTP proxy on loopback: answers every request with its request line in the body
final class P13Proxy: @unchecked Sendable {
    let l: NWListener; let seen = P6Log()
    init() throws {
        l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { [seen] c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in
                let req = String(decoding: d ?? Data(), as: UTF8.self)
                let line = req.components(separatedBy: "\r\n").first ?? ""
                seen.add(line)
                let body = "proxied " + line
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }
    func start() async -> UInt16? {
        let ready = P6Log()
        l.stateUpdateHandler = { if case .ready = $0 { ready.add("ready") } }
        l.start(queue: .global())
        for _ in 0..<100 where !ready.has("ready") { try? await Task.sleep(for: .milliseconds(50)) }
        return l.port?.rawValue
    }
}
#if canImport(CoreLocation) && os(iOS)
final class P13Beacons: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    let log = P6Log()
    func locationManager(_ m: CLLocationManager, didRange b: [CLBeacon], satisfying c: CLBeaconIdentityConstraint) { log.add("ranged \(b.count)") }
    func locationManager(_ m: CLLocationManager, didFailRangingFor c: CLBeaconIdentityConstraint, error: Error) { log.add("failed \((error as NSError).domain) \((error as NSError).code)") }
}
#endif

#if canImport(PushKit) && !os(tvOS) && !os(watchOS)
final class P13Push: NSObject, PKPushRegistryDelegate, @unchecked Sendable {
    let log = P6Log()
    func pushRegistry(_ r: PKPushRegistry, didUpdate cred: PKPushCredentials, for type: PKPushType) { log.add("token \(type.rawValue) \(cred.token.count)") }
    func pushRegistry(_ r: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) { log.add("invalidated \(type.rawValue)") }
    func pushRegistry(_ r: PKPushRegistry, didReceiveIncomingPushWith p: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) { completion() }
}
#endif
#if canImport(MapKit) && !os(watchOS)
final class P13MapDelegate: NSObject, MKMapViewDelegate, @unchecked Sendable {
    func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
        let v = MKMarkerAnnotationView(annotation: a, reuseIdentifier: "sdkcov"); v.markerTintColor = .red; v.glyphText = "S"; v.displayPriority = .required
        return v
    }
}
#endif

#if os(visionOS)
final class P13TextDoc: UIDocument {
    var text = ""
    override func contents(forType t: String) throws -> Any { Data(text.utf8) }
    override func load(fromContents c: Any, ofType t: String?) throws {
        guard let d = c as? Data else { throw Fail("contents \(type(of: c))") }
        text = String(decoding: d, as: UTF8.self)
    }
}
#endif

extension Registry {
    static var p13: [Check] {
        var c: [Check] = []

        // MARK: Accessibility: braille tables and the print <-> braille translator (iOS / tvOS / watchOS / visionOS 26)
        #if canImport(Accessibility)
        c.append(check("Accessibility", "braille-table-translate") {
            let locales = AXBrailleTable.supportedLocales()
            let agnostic = AXBrailleTable.languageAgnosticTables()
            guard let t = AXBrailleTable.defaultTable(for: Locale(identifier: "en_US")) else {
                throw Fail("no default braille table for en_US (\(locales.count) supported locales, \(agnostic.count) language-agnostic tables)")
            }
            let enTables = AXBrailleTable.tables(for: Locale(identifier: "en_US"))
            let tr = AXBrailleTranslator(brailleTable: t)
            let r = tr.translatePrintText("hello world")
            let cells = r.resultString.unicodeScalars.filter { (0x2800...0x28FF).contains($0.value) }.count
            let back = tr.backTranslateBraille(r.resultString).resultString
            let same = AXBrailleTable(identifier: t.identifier)
            // Apple's iOS 27.2 simulator: 19 en_US tables (system / liblouis / rtfc providers), the default UEB grade 1; the
            // translator answers an empty string there (no braille translation service in the simulator): a non-empty answer must round-trip
            let ids = Set(enTables.map(\.identifier))
            try expect(t.identifier == "system.eng-xueb_g1" && ids.contains(t.identifier) && ids.count >= 10 && ids.contains { $0.hasPrefix("liblouis.") },
                       "default \(t.identifier), en_US tables \(ids.sorted())")
            try expect(same?.identifier == t.identifier && agnostic.contains { $0.identifier == "system.ipa" }, "table by identifier \(String(describing: same?.identifier)), agnostic \(agnostic.map(\.identifier))")
            try expect(r.resultString.isEmpty || (cells >= 5 && back.lowercased() == "hello world"), "braille '\(r.resultString)' (\(cells) cells) back '\(back)'")
            return "\(locales.count) locales, \(agnostic.count) agnostic tables, en_US default \(t.identifier) (\(t.localizedName), eight-dot \(t.isEightDot), \(enTables.count) en_US tables): 'hello world' -> '\(r.resultString)' -> '\(back)'"
        })
        #endif

        // MARK: Metal: a parallel render command encoder (two sub-encoders in order) with a stencil test
        #if canImport(Metal) && !os(watchOS)
        c.append(check("Metal", "parallel-encoder-stencil", timeout: 40) {
            let dev = try p2Dev()
            let lib = try await p2Lib(dev, """
            struct VO { float4 p [[position]]; };
            vertex VO vq(uint vid [[vertex_id]], constant float2 &xr [[buffer(0)]]) {
                float2 c[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1) };
                float2 u = c[vid]; VO o; o.p = float4(mix(xr.x, xr.y, u.x), u.y * 2 - 1, 0, 1); return o;
            }
            fragment float4 fr() { return float4(1, 0, 0, 1); }
            """)
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = try p2Fn(lib, "vq"); pd.fragmentFunction = try p2Fn(lib, "fr")
            pd.colorAttachments[0].pixelFormat = .rgba8Unorm; pd.stencilAttachmentPixelFormat = .stencil8
            let pso = try await dev.makeRenderPipelineState(descriptor: pd)
            let mark = MTLDepthStencilDescriptor(), test = MTLDepthStencilDescriptor()
            let ms = MTLStencilDescriptor(); ms.stencilCompareFunction = .always; ms.depthStencilPassOperation = .replace
            mark.frontFaceStencil = ms; mark.backFaceStencil = ms
            let ts = MTLStencilDescriptor(); ts.stencilCompareFunction = .equal; ts.depthStencilPassOperation = .keep
            test.frontFaceStencil = ts; test.backFaceStencil = ts
            guard let markS = dev.makeDepthStencilState(descriptor: mark), let testS = dev.makeDepthStencilState(descriptor: test) else { throw Fail("no depth stencil states") }
            let color = p2Tex(dev, 64, 64)
            let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: 64, height: 64, mipmapped: false)
            sd.usage = .renderTarget; sd.storageMode = .private
            guard let stencil = dev.makeTexture(descriptor: sd) else { throw Fail("no stencil8 texture") }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = color; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)
            rp.stencilAttachment.texture = stencil; rp.stencilAttachment.loadAction = .clear; rp.stencilAttachment.clearStencil = 0
            rp.stencilAttachment.storeAction = .dontCare
            guard let q = dev.makeCommandQueue(), let cb = q.makeCommandBuffer(), let par = cb.makeParallelRenderCommandEncoder(descriptor: rp),
                  let e1 = par.makeRenderCommandEncoder(), let e2 = par.makeRenderCommandEncoder() else { throw Fail("no parallel render encoder") }
            // e1 (first in order): stencil 1 on the left half, color writes off; e2: red everywhere where stencil == 1
            var left = SIMD2<Float>(-1, 0), all = SIMD2<Float>(-1, 1)
            e2.setRenderPipelineState(pso); e2.setDepthStencilState(testS); e2.setStencilReferenceValue(1)
            e2.setVertexBytes(&all, length: 8, index: 0); e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6); e2.endEncoding()
            let pd2 = pd.copy() as! MTLRenderPipelineDescriptor; pd2.colorAttachments[0].writeMask = []
            let psoMask = try await dev.makeRenderPipelineState(descriptor: pd2)
            e1.setRenderPipelineState(psoMask); e1.setDepthStencilState(markS); e1.setStencilReferenceValue(1)
            e1.setVertexBytes(&left, length: 8, index: 0); e1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6); e1.endEncoding()
            par.endEncoding()
            try await p2Run(cb)
            let l = p2Px(color, 10, 32), r = p2Px(color, 54, 32)
            try expect(l[0] > 200 && l[2] < 50 && r[2] > 200 && r[0] < 50, "left \(l) (want red: stencil marked by the first sub-encoder) right \(r) (want blue)")
            return "parallel encoder: left \(l), right \(r)"
        })
        #endif

        // MARK: MetalPerformanceShaders: MPSImageConversion (rgba8 -> rgba32Float), LU decomposition + solve
        #if canImport(MetalPerformanceShaders)
        c.append(check("MetalPerformanceShaders", "image-conversion-lu-solve", timeout: 40) {
            let dev = try p2Dev()
            guard MPSSupportsMTLDevice(dev), let q = dev.makeCommandQueue(), let cb = q.makeCommandBuffer() else { throw Fail("MPS unsupported on the device") }
            let src = p2RGBA(dev, 4, 4) { _, _ in [255, 128, 0, 255] }
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 4, height: 4, mipmapped: false)
            dd.usage = [.shaderRead, .shaderWrite]; dd.storageMode = .shared
            let dst = dev.makeTexture(descriptor: dd)!
            MPSImageConversion(device: dev, srcAlpha: .alphaIsOne, destAlpha: .alphaIsOne, backgroundColor: nil, conversionInfo: nil)
                .encode(commandBuffer: cb, sourceTexture: src, destinationTexture: dst)
            // A x = b with A = [[4, 3], [6, 3]], b = [10, 12]: x = [1, 2]
            let md = MPSMatrixDescriptor(rows: 2, columns: 2, rowBytes: 8, dataType: .float32)
            let a = MPSMatrix(buffer: p2Buf(dev, [4, 3, 6, 3]), descriptor: md)
            let lu = MPSMatrix(buffer: p2Buf(dev, [0, 0, 0, 0]), descriptor: md)
            let piv = MPSMatrix(buffer: dev.makeBuffer(length: 8, options: .storageModeShared)!, descriptor: MPSMatrixDescriptor(rows: 1, columns: 2, rowBytes: 8, dataType: .uInt32))
            let st = dev.makeBuffer(length: 4, options: .storageModeShared)!
            MPSMatrixDecompositionLU(device: dev, rows: 2, columns: 2).encode(commandBuffer: cb, sourceMatrix: a, resultMatrix: lu, pivotIndices: piv, info: st)
            let vd = MPSMatrixDescriptor(rows: 2, columns: 1, rowBytes: 4, dataType: .float32)
            let b = MPSMatrix(buffer: p2Buf(dev, [10, 12]), descriptor: vd), x = MPSMatrix(buffer: p2Buf(dev, [0, 0]), descriptor: vd)
            MPSMatrixSolveLU(device: dev, transpose: false, order: 2, numberOfRightHandSides: 1)
                .encode(commandBuffer: cb, sourceMatrix: lu, rightHandSideMatrix: b, pivotIndices: piv, solutionMatrix: x)
            try await p2Run(cb)
            var px = [Float](repeating: 0, count: 4)
            dst.getBytes(&px, bytesPerRow: 4 * 16, from: MTLRegionMake2D(1, 1, 1, 1), mipmapLevel: 0)
            let sol = p2Floats(x.data, 2), status = st.contents().load(as: Int32.self)
            let pivots = Array(UnsafeBufferPointer(start: piv.data.contents().assumingMemoryBound(to: UInt32.self), count: 2))
            try expect(abs(px[0] - 1) < 0.01 && abs(px[1] - 0.502) < 0.01 && px[2] < 0.01 && abs(px[3] - 1) < 0.01, "converted pixel \(px)")
            try expect(status == 0 && abs(sol[0] - 1) < 1e-4 && abs(sol[1] - 2) < 1e-4, "LU status \(status) pivots \(pivots), solution \(sol)")
            return "conversion \(px); LU pivots \(pivots) status \(status), solution \(sol)"
        })
        #endif

        // MARK: MetalKit / ModelIO: MTKMesh from an MDLAsset with a custom (position + normal, 24-byte) vertex descriptor
        #if canImport(MetalKit) && canImport(ModelIO)
        c.append(check("MetalKit", "mesh-asset-custom-vertex-descriptor") {
            let dev = try p2Dev()
            let alloc = MTKMeshBufferAllocator(device: dev)
            let box = MDLMesh(boxWithExtent: SIMD3<Float>(1, 2, 3), segments: SIMD3<UInt32>(1, 1, 1), inwardNormals: false, geometryType: .triangles, allocator: alloc)
            let vd = MDLVertexDescriptor()
            vd.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
            vd.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
            vd.layouts[0] = MDLVertexBufferLayout(stride: 24)
            box.vertexDescriptor = vd
            let asset = MDLAsset(bufferAllocator: alloc); asset.add(box)
            let (mdl, mtk) = try MTKMesh.newMeshes(asset: asset, device: dev)
            guard let m = mtk.first else { throw Fail("no MTKMesh from the asset (\(mdl.count) ModelIO meshes)") }
            guard let mvd = try MTKMetalVertexDescriptorFromModelIOWithError(vd) else { throw Fail("no Metal vertex descriptor") }
            let sub = m.submeshes.map { "\($0.indexCount) \($0.indexType == .uint16 ? "u16" : "u32")" }
            let bb = mdl.first!.boundingBox
            // the positions in the Metal buffer: every vertex at +-0.5 / +-1 / +-1.5
            let vb = m.vertexBuffers[0], p = (vb.buffer.contents() + vb.offset).assumingMemoryBound(to: Float.self)
            var onBox = 0
            for i in 0..<m.vertexCount where abs(abs(p[i * 6]) - 0.5) < 1e-4 && abs(abs(p[i * 6 + 1]) - 1) < 1e-4 && abs(abs(p[i * 6 + 2]) - 1.5) < 1e-4 { onBox += 1 }
            try expect(m.vertexBuffers.count == 1 && m.vertexCount == 24 && (sub == ["36 u16"] || sub == ["36 u32"]), "buffers \(m.vertexBuffers.count) vertices \(m.vertexCount) submeshes \(sub)")
            try expect((m.vertexDescriptor.layouts[0] as! MDLVertexBufferLayout).stride == 24 && mvd.layouts[0].stride == 24 && mvd.attributes[1].offset == 12 && mvd.attributes[1].format == .float3,
                       "descriptor stride \(mvd.layouts[0].stride) normal offset \(mvd.attributes[1].offset)")
            try expect(onBox == 24 && abs(bb.maxBounds.y - 1) < 1e-4, "\(onBox) of \(m.vertexCount) vertices on the box, bounds \(bb.minBounds) \(bb.maxBounds)")
            return "MTKMesh \(m.vertexCount) vertices stride 24, submeshes \(sub), \(onBox) on the box"
        })
        #endif

        // MARK: ModelIO: a light probe from a sky cube's irradiance, spherical harmonics
        #if canImport(ModelIO) && !os(watchOS)
        c.append(check("ModelIO", "light-probe-irradiance-sh", timeout: 60) {
            let sky = MDLSkyCubeTexture(name: "sky", channelEncoding: .uInt8, textureDimensions: SIMD2<Int32>(32, 32), turbidity: 0.3, sunElevation: 0.6,
                                        upperAtmosphereScattering: 0.3, groundAlbedo: 0.4)
            guard let irr = MDLTexture.irradianceTextureCube(with: sky, name: "irr", dimensions: SIMD2<Int32>(8, 8)) as MDLTexture? else { throw Fail("no irradiance cube") }
            let probe = MDLLightProbe(reflectiveTexture: sky, irradianceTexture: irr)
            probe.generateSphericalHarmonics(fromIrradiance: 2)
            let data = probe.sphericalHarmonicsCoefficients ?? Data()
            let f = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let texel = irr.texelDataWithTopLeftOrigin()?.count ?? 0
            try expect(probe.sphericalHarmonicsLevel == 2 && f.count >= 27, "level \(probe.sphericalHarmonicsLevel), \(data.count) bytes of coefficients")
            try expect(f.prefix(3).allSatisfy { $0 > 0 && $0.isFinite } && f.allSatisfy(\.isFinite), "DC terms \(Array(f.prefix(3)))")
            try expect(irr.isCube && irr.dimensions.x == 8 && texel > 0, "irradiance cube \(irr.dimensions) cube \(irr.isCube) texels \(texel)")
            return "irradiance cube \(irr.dimensions) (\(texel) bytes), SH level 2: \(f.count) coefficients, DC \(f.prefix(3).map { String(format: "%.3f", $0) })"
        })
        #endif

        // MARK: QuartzCore: the window scene's display link (iOS / tvOS / visionOS 27) and its frame cadence
        #if canImport(UIKit) && !os(watchOS)
        c.append(check("QuartzCore", "scene-displaylink-cadence", timeout: 30) {
            let (t, link) = try await onMain { () -> (P13Tick, CADisplayLink) in
                let t = P13Tick()
                guard let l = try p6Scene().displayLink(target: t, selector: #selector(P13Tick.tick(_:))) else { throw Fail("UIWindowScene.displayLink nil") }
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                l.add(to: .main, forMode: .common)
                return (t, l)
            }
            try await Task.sleep(for: .seconds(1.5))
            let s = await onMain { () -> [(Double, Double)] in link.invalidate(); return t.stamps }
            let ds = zip(s.dropFirst(), s).map { $0.0 - $1.0 }.sorted()
            let med = ds.isEmpty ? 0 : ds[ds.count / 2]
            let mono = zip(s.dropFirst(), s).allSatisfy { $0.0 > $1.0 } && s.allSatisfy { $0.1 > $0.0 }
            try expect(s.count >= 30 && s.count <= 200, "\(s.count) frames in 1.5 s")
            try expect(mono && med > 1.0 / 130 && med < 1.0 / 25, "timestamps increasing \(mono), median interval \(med)")
            return "\(s.count) frames in 1.5 s, median interval \(String(format: "%.4f", med)) s"
        })
        #endif

        // MARK: CoreImage: CIDetector rectangles on a drawn rectangle, no face in it
        #if canImport(CoreImage) && !os(watchOS)
        c.append(check("CoreImage", "detector-rectangle-face", timeout: 40) {
            let ctx = bitmap(300, 300)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 60, y: 90, width: 180, height: 110))
            let img = CIImage(cgImage: ctx.makeImage()!)
            guard let rd = CIDetector(ofType: CIDetectorTypeRectangle, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
                  let fd = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyLow]) else { throw Fail("no rectangle / face detector") }
            let rects = rd.features(in: img).compactMap { $0 as? CIRectangleFeature }
            let faces = fd.features(in: img)
            let b = rects.first?.bounds ?? .null
            try expect(rects.count == 1 && abs(b.minX - 60) < 6 && abs(b.minY - 90) < 6 && abs(b.width - 180) < 10 && abs(b.height - 110) < 10, "rectangles \(rects.map(\.bounds))")
            try expect(faces.isEmpty, "faces \(faces.map(\.bounds))")
            return "rectangle \(b.integral), 0 faces"
        })
        #endif

        // MARK: UIKit: a secure text field (password content type): no copy / cut, text kept
        #if os(iOS) || os(visionOS) || os(tvOS)
        c.append(check("UIKit", "textfield-secure-content-type", timeout: 30) {
            let (sec, plain, done) = try await onMain { () -> (UITextField, UITextField, () -> Void) in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let s = UITextField(frame: CGRect(x: 20, y: 120, width: 280, height: 40)); s.isSecureTextEntry = true; s.textContentType = .password
                let p = UITextField(frame: CGRect(x: 20, y: 180, width: 280, height: 40)); p.textContentType = .username
                vc.view.addSubview(s); vc.view.addSubview(p)
                let (_, done) = try p6Show(vc)
                return (s, p, done)
            }
            defer { Task { @MainActor in done() } }
            let r = try await onMain { () -> String in
                plain.text = "sdkcov-user"; plain.becomeFirstResponder(); plain.selectAll(nil)
                let pc = plain.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil)
                sec.becomeFirstResponder(); sec.insertText("s3cret")
                let first = sec.isFirstResponder
                sec.selectAll(nil)
                let sc = sec.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil)
                let sx = sec.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil)
                let kb = sec.keyboardType.rawValue, ac = sec.autocorrectionType.rawValue
                sec.resignFirstResponder()
                try expect(first && sec.text == "s3cret" && sec.textContentType == .password, "secure field first responder \(first) text \(String(describing: sec.text))")
                try expect(pc && !sc && !sx, "copy on plain \(pc), copy / cut on secure \(sc) / \(sx)")
                return "secure field kept 's3cret', copy/cut refused (plain field copies), keyboard \(kb) autocorrection \(ac)"
            }
            try expect(!r.hasPrefix("FAIL"), r)
            return r
        })
        #endif

        // MARK: UIKit: a UIContextMenuInteraction's menu presented (as a long press ends) and dismissed
        #if os(iOS) || os(visionOS) || os(tvOS)
        c.append(check("UIKit", "context-menu-interaction-present", timeout: 30) {
            let d = P13MenuDelegate()
            let (i, v, done) = try await onMain { () -> (UIContextMenuInteraction, UIView, () -> Void) in
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let v = UIView(frame: CGRect(x: 60, y: 160, width: 160, height: 100)); v.backgroundColor = .orange
                let i = UIContextMenuInteraction(delegate: d); v.addInteraction(i); vc.view.addSubview(v)
                let (_, done) = try p6Show(vc)
                return (i, v, done)
            }
            defer { Task { @MainActor in done() } }
            try await Task.sleep(for: .milliseconds(500))
            let ok = await onMain { v.interactions.contains { $0 === i } && p13PresentMenu(i, CGPoint(x: 80, y: 50)) }
            try expect(ok, "interaction not installed or no menu entry")
            #if os(visionOS)   // the menu is not in the app scene's windows there (Apple's simulator too): the delegate's events
            let shown = await p6Wait(6) { d.log.has("willDisplay") }
            #else
            let shown = await p6Wait(6) { d.log.has("willDisplay") && p13Labels().contains("SDKCovCtxTwo") }
            #endif
            let labels = await onMain { p13Labels().filter { $0.hasPrefix("SDKCov") } }
            await onMain { i.dismissMenu() }
            let ended = await p6Wait(6) { d.log.has("willEnd") }
            try expect(shown && ended, "events \(d.log.all), labels \(labels), ended \(ended)")
            return "events \(d.log.all), menu labels \(labels)"
        })
        #endif


        // MARK: Security: shared web credentials (deprecated): the simulator's answer without an associated domain
        #if os(iOS)
        c.append(check("Security", "shared-web-credential-add", timeout: 40) {
            let err: String = await withCheckedContinuation { k in
                SecAddSharedWebCredential("sdkcov.example.com" as CFString, "sdkcov" as CFString, "pw" as CFString) { e in
                    k.resume(returning: e.map { let n = $0 as Error as NSError; return "\(n.domain) \(n.code)" } ?? "nil")
                }
            }
            try expect(err != "nil", "added without an associated domain")
            return "SecAddSharedWebCredential: \(err)"
        })
        // MARK: SystemConfiguration: captive network info needs the Wi-Fi info entitlement: nil
        c.append(check("SystemConfiguration", "captive-network-info") {
            let ifs = (CNCopySupportedInterfaces() as? [String]) ?? []
            let info = CNCopyCurrentNetworkInfo("en0" as CFString)
            try expect(info == nil, "CNCopyCurrentNetworkInfo(en0) answered \(String(describing: info))")
            return "supported interfaces \(ifs), en0 info nil"
        })
        #endif

        // MARK: WebKit: IndexedDB in a page with an https origin (put, get, count)
        #if canImport(WebKit) && (os(iOS) || os(visionOS))
        c.append(check("WebKit", "indexeddb-put-get", timeout: 60) {
            let (wv, done) = try await onMain { () -> (WKWebView, () -> Void) in
                let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), configuration: WKWebViewConfiguration())
                let vc = UIViewController(); vc.view.addSubview(wv)
                let (_, done) = try p6Show(vc)
                wv.loadHTMLString("<html><body>sdkcov</body></html>", baseURL: URL(string: "https://sdkcov.example/"))
                return (wv, done)
            }
            defer { Task { @MainActor in done() } }
            _ = await p6Wait(15) { !wv.isLoading && wv.url != nil }
            let js = """
            return await new Promise((ok, no) => {
              const r = indexedDB.open('sdkcov', 1);
              r.onupgradeneeded = () => r.result.createObjectStore('s');
              r.onerror = () => no(String(r.error));
              r.onsuccess = () => {
                const db = r.result, tx = db.transaction('s', 'readwrite'), st = tx.objectStore('s');
                st.put({ n: 42, t: 'x86' }, 'k1'); st.put({ n: 7 }, 'k2');
                tx.oncomplete = () => {
                  const t2 = db.transaction('s'), s2 = t2.objectStore('s'), g = s2.get('k1'), c = s2.count();
                  t2.oncomplete = () => ok(JSON.stringify([g.result, c.result]));
                  t2.onerror = () => no(String(t2.error));
                };
                tx.onerror = () => no(String(tx.error));
              };
            });
            """
            let v = try await p6A { try await wv.callAsyncJavaScript(js, contentWorld: .page) }
            let s = v as? String ?? "\(String(describing: v))"
            try expect(s == #"[{"n":42,"t":"x86"},2]"#, "IndexedDB answered \(s)")
            return "IndexedDB get/count: \(s)"
        })
        #endif

        // MARK: VideoToolbox: ProRes 422 compression session (encode 3 frames) and an H.264 multi-pass session's answer
        #if canImport(VideoToolbox) && !os(watchOS)
        c.append(check("VideoToolbox", "prores-encode-multipass", timeout: 60) {
            func encode(_ codec: CMVideoCodecType, multipass: Bool) -> String {
                var s: VTCompressionSession?
                let frames = Mutex<[String]>([])
                let st = VTCompressionSessionCreate(allocator: nil, width: 64, height: 64, codecType: codec, encoderSpecification: nil, imageBufferAttributes: nil,
                                                    compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
                guard st == noErr, let s else { return "create \(st)" }
                defer { VTCompressionSessionInvalidate(s) }
                var mp = "-"
                if multipass {
                    var storage: VTMultiPassStorage?
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-mp-\(UUID().uuidString.prefix(6))")
                    let ms = VTMultiPassStorageCreate(allocator: nil, fileURL: url as CFURL, timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 30)), options: nil, multiPassStorageOut: &storage)
                    mp = "storage \(ms)"
                    if let storage { mp += " set \(VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MultiPassStorage, value: storage))" }
                    try? FileManager.default.removeItem(at: url)
                }
                for i in 0..<3 {
                    var pb: CVPixelBuffer?
                    CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
                    guard let pb else { return "no pixel buffer" }
                    CVPixelBufferLockBaseAddress(pb, []); memset(CVPixelBufferGetBaseAddress(pb), Int32(i * 60), CVPixelBufferGetDataSize(pb)); CVPixelBufferUnlockBaseAddress(pb, [])
                    let e = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: CMTime(value: Int64(i), timescale: 30), duration: CMTime(value: 1, timescale: 30),
                                                            frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
                        frames.withLock { $0.append(sb.map { "\(CMSampleBufferGetTotalSampleSize($0) > 0 ? "ok" : "empty") \(CMFormatDescriptionGetMediaSubType(CMSampleBufferGetFormatDescription($0)!) == codec ? "" : "subtype?")" } ?? "status \(status)") }
                    }
                    if e != noErr { return "encode \(e)" }
                }
                let c = VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                return "complete \(c) frames \(frames.withLock { $0 }) multipass \(mp)"
            }
            let prores = encode(kCMVideoCodecType_AppleProRes422, multipass: false)
            let multi = encode(kCMVideoCodecType_H264, multipass: true)
            // Apple's simulators: no ProRes encoder (kVTCouldNotFindVideoEncoderErr); H.264 takes multi-pass storage and encodes
            try expect(prores == "create -12908", "ProRes 422: \(prores)")
            try expect(multi == #"complete 0 frames ["ok ", "ok ", "ok "] multipass storage 0 set 0"#, "H.264 multi-pass: \(multi)")
            return "ProRes 422: \(prores); H.264 multi-pass: \(multi)"
        })
        #endif

        // MARK: SpriteKit on watchOS: shader / atlas / tile map / emitter as objects (no SKView there)
        #if canImport(SpriteKit) && os(watchOS)
        c.append(check("SpriteKit", "shader-tilemap-atlas-emitter-model") {
            let sh = SKShader(source: "void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }", uniforms: [SKUniform(name: "u_k", float: 2)])
            try expect(sh.uniforms.count == 1 && sh.uniformNamed("u_k")?.floatValue == 2, "shader uniforms \(sh.uniforms.map(\.name))")
            let img = { (c: CGColor) -> UIImage in let x = bitmap(8, 8); x.setFillColor(c); x.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); return UIImage(cgImage: x.makeImage()!) }
            let atlas = SKTextureAtlas(dictionary: ["red": img(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), "blue": img(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))])
            try expect(Set(atlas.textureNames.map { ($0 as NSString).deletingPathExtension }) == ["red", "blue"], "atlas names \(atlas.textureNames)")
            let redG = SKTileGroup(tileDefinition: SKTileDefinition(texture: atlas.textureNamed("red")))
            let blueG = SKTileGroup(tileDefinition: SKTileDefinition(texture: atlas.textureNamed("blue")))
            let map = SKTileMapNode(tileSet: SKTileSet(tileGroups: [redG, blueG]), columns: 4, rows: 4, tileSize: CGSize(width: 8, height: 8), fillWith: blueG)
            map.setTileGroup(redG, forColumn: 2, row: 1)
            let pos = map.centerOfTile(atColumn: 2, row: 1)
            try expect(map.tileGroup(atColumn: 2, row: 1) === redG && map.tileGroup(atColumn: 0, row: 0) === blueG
                       && map.tileColumnIndex(fromPosition: pos) == 2 && map.tileRowIndex(fromPosition: pos) == 1 && map.mapSize == CGSize(width: 32, height: 32), "tile map \(pos) \(map.mapSize)")
            let scene = SKScene(size: CGSize(width: 100, height: 100))
            let em = SKEmitterNode(); em.particleTexture = atlas.textureNamed("red"); em.particleBirthRate = 200; em.particleLifetime = 2
            em.particleSpeed = 20; em.emissionAngleRange = .pi * 2; scene.addChild(em); em.advanceSimulationTime(1)
            let sp = SKSpriteNode(color: .red, size: CGSize(width: 10, height: 10)); sp.shader = sh; scene.addChild(sp)
            try expect(scene.children.count == 2 && sp.shader === sh && em.particleBirthRate == 200, "scene children \(scene.children.count)")
            return "shader uniform u_k 2, atlas 2 textures, tile map 32x32 with red at (2,1), emitter advanced 1 s"
        })
        #endif

        // MARK: round 17, batch 2
        // MARK: CFNetwork: URLSessionConfiguration.connectionProxyDictionary through a loopback HTTP proxy
        #if canImport(Network)
        c.append(check("CFNetwork", "session-loopback-http-proxy", timeout: 40) {
            let px = try P13Proxy()
            guard let port = await px.start() else { throw Fail("proxy listener not ready") }
            defer { px.l.cancel() }
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int(port)]   // kCFNetworkProxiesHTTP* (not in the watchOS SDK)
            cfg.timeoutIntervalForRequest = 15
            let (d, r) = try await URLSession(configuration: cfg).data(from: URL(string: "http://sdkcov-proxy.invalid/path?q=1")!)
            let body = String(decoding: d, as: UTF8.self), code = (r as? HTTPURLResponse)?.statusCode ?? -1
            try expect(code == 200 && body == "proxied GET http://sdkcov-proxy.invalid/path?q=1 HTTP/1.1", "status \(code) body '\(body)' proxy saw \(px.seen.all)")
            return "proxy on \(port) saw \(px.seen.all)"
        })
        #endif


        // MARK: QuickLookThumbnailing: a movie's thumbnail (an H.264 .mov written with AVAssetWriter)
        #if canImport(QuickLookThumbnailing) && (os(iOS) || os(visionOS))
        c.append(check("QuickLookThumbnailing", "movie-thumbnail", timeout: 60) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-qlt-\(UUID().uuidString.prefix(6)).mov")
            defer { try? FileManager.default.removeItem(at: u) }
            try await writeMovie(u, frames: 30, size: 128)
            let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 64, height: 64), scale: 1, representationTypes: .thumbnail)
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
            let img = rep.cgImage
            try expect(rep.type == .thumbnail && img.width > 0 && img.width <= 64 && img.height <= 64, "representation \(rep.type.rawValue) \(img.width)x\(img.height)")
            return "thumbnail \(img.width)x\(img.height), type \(rep.type.rawValue)"
        })
        #endif

        // MARK: SceneKit: SCNAudioSource from a WAV, attached to a node through SCNAudioPlayer
        #if canImport(SceneKit)
        c.append(check("SceneKit", "audio-source-player", timeout: 30) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-scna-\(UUID().uuidString.prefix(6)).wav")
            defer { try? FileManager.default.removeItem(at: u) }
            try p2Wav(u, secs: 0.5)
            guard let src = SCNAudioSource(url: u) else { throw Fail("SCNAudioSource(url:) nil") }
            src.isPositional = true; src.volume = 0.5; src.loops = false; src.shouldStream = false
            src.load()
            let scene = SCNScene(), node = SCNNode(); scene.rootNode.addChildNode(node)
            let player = SCNAudioPlayer(source: src)
            node.addAudioPlayer(player)
            let n = node.audioPlayers.count
            node.removeAllAudioPlayers()
            try expect(player.audioSource === src && src.volume == 0.5 && src.isPositional && node.audioPlayers.isEmpty, "source / players after removeAll \(node.audioPlayers.count)")
            return "SCNAudioSource loaded (positional, volume 0.5), \(n) players on a node outside a renderer, audio node \(player.audioNode.map { "\(type(of: $0))" } ?? "nil")"
        })
        #endif

        // MARK: GLKit: a GLKView with an OpenGL ES 3 context, cleared red in its draw callback, snapshot
        #if canImport(GLKit) && !os(watchOS)
        c.append(check("GLKit", "glkview-draw-snapshot", timeout: 30) {
            final class D: NSObject, GLKViewDelegate {
                var draws = 0
                func glkView(_ v: GLKView, drawIn r: CGRect) { draws += 1; glClearColor(1, 0, 0, 1); glClear(GLbitfield(GL_COLOR_BUFFER_BIT)) }
            }
            return try await onMain { () -> String in
                guard let ctx = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) else { throw Fail("no EAGLContext") }
                let d = D()
                let v = GLKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), context: ctx); v.delegate = d
                v.drawableColorFormat = .RGBA8888; v.drawableDepthFormat = .format24
                let (_, done) = try p2Show(v); defer { done() }
                let img = v.snapshot
                let px = img.cgImage.map { p2Pixel($0, 32, 32) } ?? []
                let effect = GLKBaseEffect(); effect.constantColor = GLKVector4Make(0, 1, 0, 1); effect.useConstantColor = GLboolean(GL_TRUE)
                effect.prepareToDraw()
                let err = glGetError()
                try expect(d.draws >= 1 && px.count == 4 && p2Near(px, 255, 0, 0), "draws \(d.draws), snapshot \(img.size) pixel \(px)")
                try expect(err == GLenum(GL_NO_ERROR), "GLKBaseEffect prepareToDraw error \(err)")
                return "api \(ctx.api.rawValue), \(d.draws) draws, snapshot pixel \(px), drawable \(v.drawableWidth)x\(v.drawableHeight)"
            }
        })
        #endif

        // MARK: IOSurface: one surface as a Metal render target and a CVPixelBuffer (same pixels)
        #if canImport(IOSurface) && canImport(Metal) && !os(watchOS)
        c.append(check("IOSurface", "metal-texture-pixelbuffer-share", timeout: 30) {
            let dev = try p2Dev()
            guard let surf = IOSurface(properties: [.width: 32, .height: 32, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]) else { throw Fail("no IOSurface") }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false); td.usage = [.renderTarget, .shaderRead]
            guard let tex = dev.makeTexture(descriptor: td, iosurface: unsafeBitCast(surf, to: IOSurfaceRef.self), plane: 0) else { throw Fail("no texture over the surface") }
            let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            guard let cb = dev.makeCommandQueue()?.makeCommandBuffer(), let e = cb.makeRenderCommandEncoder(descriptor: rp) else { throw Fail("no encoder") }
            e.endEncoding(); try await p2Run(cb)
            surf.lock(options: .readOnly, seed: nil)
            let b = surf.baseAddress.assumingMemoryBound(to: UInt8.self) + 5 * surf.bytesPerRow + 5 * 4
            let viaSurf = [Int(b[0]), Int(b[1]), Int(b[2])]
            surf.unlock(options: .readOnly, seed: nil)
            var pbu: Unmanaged<CVPixelBuffer>?
            let st = CVPixelBufferCreateWithIOSurface(nil, unsafeBitCast(surf, to: IOSurfaceRef.self), nil, &pbu)
            guard st == kCVReturnSuccess, let pb = pbu?.takeRetainedValue() else { throw Fail("CVPixelBufferCreateWithIOSurface \(st)") }
            let viaPB = p1BGRA(pb, 5, 5)
            let same = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() === unsafeBitCast(surf, to: IOSurfaceRef.self)
            try expect(p1Near(viaSurf, [204, 102, 51], 3) && p1Near(Array(viaPB.prefix(3)), [204, 102, 51], 3) && same, "surface BGR \(viaSurf), pixel buffer \(viaPB), same surface \(same)")
            return "surface id \(surf.surfaceID > 0), BGRA via surface \(viaSurf), via CVPixelBuffer \(viaPB)"
        })
        #endif

        // MARK: WebKit: the find interaction's navigator (find bar) on a page
        #if canImport(WebKit) && (os(iOS) || os(visionOS))
        c.append(check("WebKit", "find-interaction-navigator", timeout: 40) {
            let (wv, done) = try await onMain { () -> (WKWebView, () -> Void) in
                let wv = WKWebView(frame: CGRect(x: 0, y: 80, width: 320, height: 400)); wv.isFindInteractionEnabled = true
                let vc = UIViewController(); vc.view.backgroundColor = .white; vc.view.addSubview(wv)
                let (_, done) = try p6Show(vc)
                wv.loadHTMLString("<html><body><p>alpha sdkcov beta sdkcov gamma sdkcov</p></body></html>", baseURL: nil)
                return (wv, done)
            }
            defer { Task { @MainActor in done() } }
            _ = await p6Wait(15) { !wv.isLoading }
            try await Task.sleep(for: .milliseconds(300))
            await onMain { wv.findInteraction?.searchText = "sdkcov"; wv.findInteraction?.presentFindNavigator(showingReplace: false) }
            let shown = await p6Wait(8) { wv.findInteraction?.isFindNavigatorVisible == true && (wv.findInteraction?.activeFindSession?.resultCount ?? 0) > 0 }
            let (vis, count, hl) = await onMain { (wv.findInteraction?.isFindNavigatorVisible == true, wv.findInteraction?.activeFindSession?.resultCount ?? -1,
                                                   wv.findInteraction?.activeFindSession?.highlightedResultIndex ?? -2) }
            await onMain { wv.findInteraction?.findNext() }
            _ = await p6Wait(3) { (wv.findInteraction?.activeFindSession?.highlightedResultIndex ?? -2) != hl }
            let hl2 = await onMain { wv.findInteraction?.activeFindSession?.highlightedResultIndex ?? -2 }
            await onMain { wv.findInteraction?.dismissFindNavigator() }
            let gone = await p6Wait(5) { wv.findInteraction?.isFindNavigatorVisible == false }
            try expect(shown && vis && count == 3 && hl2 != hl && gone, "navigator visible \(vis), results \(count), highlighted \(hl) -> \(hl2), dismissed \(gone)")
            return "find navigator: 3 results, highlighted \(hl) -> \(hl2), dismissed"
        })
        #endif

        // MARK: PDFKit: PDFView selection (findString -> currentSelection), highlighted selections on screen
        #if canImport(PDFKit) && (os(iOS) || os(visionOS))   // tvOS: PDFView(frame:) raises (Apple's simulator too)
        c.append(check("PDFKit", "pdfview-selection-find-highlight", timeout: 40) {
            let d = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 400, height: 200)
            let pdf = CGContext(consumer: CGDataConsumer(data: d)!, mediaBox: &box, nil)!
            pdf.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "alpha sdkcov beta sdkcov", attributes: [.init(kCTFontAttributeName as String): font]))
            pdf.textPosition = CGPoint(x: 20, y: 100); CTLineDraw(line, pdf)
            pdf.endPDFPage(); pdf.closePDF()
            guard let doc = PDFDocument(data: d as Data) else { throw Fail("no PDFDocument") }
            return try await onMain { () -> String in
                let v = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)); v.document = doc; v.autoScales = true
                let (_, done) = try p2Show(v); defer { done() }
                let found = doc.findString("sdkcov", withOptions: .caseInsensitive)
                guard let first = found.first else { throw Fail("findString found nothing") }
                v.setCurrentSelection(first, animate: false)
                let cur = v.currentSelection?.string
                v.highlightedSelections = found
                let hl = v.highlightedSelections?.count ?? 0
                let page = doc.page(at: 0)!
                let sel = page.selection(for: CGRect(x: 0, y: 80, width: 400, height: 40))?.string ?? ""
                let word = page.selectionForWord(at: CGPoint(x: 30, y: 108))?.string ?? ""
                v.clearSelection()
                try expect(found.count == 2 && cur == "sdkcov" && hl == 2, "found \(found.count), current '\(String(describing: cur))', highlighted \(hl)")
                try expect(sel.contains("alpha sdkcov") && word == "alpha" && v.currentSelection == nil, "rect selection '\(sel)', word '\(word)', cleared \(v.currentSelection == nil)")
                return "found 2, current selection 'sdkcov', 2 highlighted, rect selection '\(sel)', word '\(word)'"
            }
        })
        #endif

        // MARK: CoreLocation: beacon ranging for a constraint (no beacons in the simulator: the answer)
        #if canImport(CoreLocation) && os(iOS)
        c.append(check("CoreLocation", "beacon-ranging-answer", timeout: 30) {
            let d = P13Beacons()
            let (m, avail) = await onMain { () -> (CLLocationManager, Bool) in
                let m = CLLocationManager(); m.delegate = d
                return (m, CLLocationManager.isRangingAvailable())
            }
            let c = CLBeaconIdentityConstraint(uuid: UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!, major: 1)
            await onMain { m.startRangingBeacons(satisfying: c) }
            _ = await p6Wait(8) { !d.log.all.isEmpty }
            try await Task.sleep(for: .seconds(1))
            await onMain { m.stopRangingBeacons(satisfying: c) }
            let ev = Array(Set(d.log.all)).sorted()
            // Apple's simulator: ranging unavailable, the constraint fails with kCLErrorRangingUnavailable (17)
            try expect(!avail && ev == ["failed kCLErrorDomain 17"], "ranging available \(avail), events \(ev)")
            return "ranging available \(avail), events \(ev)"
        })
        #endif

        // MARK: Photos: PHCachingImageManager caching + a request for the library's first image asset
        #if canImport(Photos) && !os(watchOS)
        c.append(check("Photos", "caching-image-manager", timeout: 60) {
            let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            try skipIf(st != .authorized, "photos access \(st.rawValue)")
            var assets = PHAsset.fetchAssets(with: .image, options: nil)
            if assets.count == 0 {   // a library without images (a --only run): add one
                let x = bitmap(120, 80); x.setFillColor(CGColor(srgbRed: 0, green: 0.6, blue: 1, alpha: 1)); x.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
                let img = UIImage(cgImage: x.makeImage()!)
                try await PHPhotoLibrary.shared().performChanges { _ = PHAssetChangeRequest.creationRequestForAsset(from: img) }
                assets = PHAsset.fetchAssets(with: .image, options: nil)
            }
            try expect(assets.count > 0, "no image assets in the library after adding one")
            let a = assets.object(at: 0)
            let cm = PHCachingImageManager(); cm.allowsCachingHighQualityImages = false
            let opts = PHImageRequestOptions(); opts.deliveryMode = .highQualityFormat; opts.isSynchronous = false; opts.isNetworkAccessAllowed = false
            cm.startCachingImages(for: [a], targetSize: CGSize(width: 80, height: 80), contentMode: .aspectFill, options: opts)
            let got = P1Box<String?>(nil)
            cm.requestImage(for: a, targetSize: CGSize(width: 80, height: 80), contentMode: .aspectFill, options: opts) { img, info in
                got.value = img.map { "\(Int($0.size.width * $0.scale))x\(Int($0.size.height * $0.scale)) degraded \(info?[PHImageResultIsDegradedKey] as? Bool ?? false)" } ?? "nil \(String(describing: info?[PHImageErrorKey]))"
            }
            _ = await p6Wait(20) { got.value != nil }
            cm.stopCachingImages(for: [a], targetSize: CGSize(width: 80, height: 80), contentMode: .aspectFill, options: opts)
            cm.stopCachingImagesForAllAssets()
            guard let g = got.value else { throw Fail("requestImage never answered") }
            try expect(!g.hasPrefix("nil"), "image \(g)")
            return "\(assets.count) image assets; cached request answered \(g)"
        })
        #endif

        // MARK: ReplayKit: startRecording / stopRecording -> the preview controller (or the simulator's error)
        #if canImport(ReplayKit) && !os(watchOS)
        c.append(check("ReplayKit", "start-stop-recording-preview", timeout: 40) {
            let r = RPScreenRecorder.shared()
            let started = P1Box<String?>(nil)
            r.startRecording { e in started.value = e.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "started" }
            _ = await more2Wait(10) { started.value != nil }
            let stopped = P1Box<String?>(nil)
            r.stopRecording { vc, e in stopped.value = e.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? (vc.map { "preview \(type(of: $0))" } ?? "no preview") }
            _ = await more2Wait(10) { stopped.value != nil }
            // Apple's iOS 27.2 simulator: startRecording answers started, stopRecording never calls back, isRecording stays false
            try expect(started.value == "started" && stopped.value == nil && !r.isRecording, "startRecording \(String(describing: started.value)), stopRecording \(String(describing: stopped.value)), recording \(r.isRecording)")
            return "startRecording started, stopRecording no answer in 10 s, not recording"
        })
        #endif

        // MARK: GameKit: turn-based matches and leaderboard entries without an account: the error answers
        #if canImport(GameKit)
        c.append(check("GameKit", "load-matches-entries-unauthenticated", timeout: 60) {
            func err(_ e: Error?) -> String { e.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "nil" }
            let m: String = await withCheckedContinuation { k in GKTurnBasedMatch.loadMatches { ms, e in k.resume(returning: "\(ms?.count ?? -1) \(err(e))") } }
            let lb: String = await withCheckedContinuation { k in
                GKLeaderboard.loadLeaderboards(IDs: ["sdkcov.board"]) { bs, e in k.resume(returning: "\(bs?.count ?? -1) \(err(e))") }
            }
            let a: String = await withCheckedContinuation { k in GKAchievement.loadAchievements { as_, e in k.resume(returning: "\(as_?.count ?? -1) \(err(e))") } }
            // no Game Center account: every call answers notAuthenticated (GKErrorDomain 6), as on Apple's simulators
            try expect([m, lb, a].allSatisfy { $0 == "-1 GKErrorDomain 6" }, "loadMatches \(m); loadLeaderboards \(lb); loadAchievements \(a)")
            return "loadMatches \(m); loadLeaderboards \(lb); loadAchievements \(a)"
        })
        #endif

        // MARK: MediaAccessibility: changing the caption display type posts the settings-changed notification
        #if canImport(MediaAccessibility) && !os(watchOS)
        c.append(check("MediaAccessibility", "caption-settings-changed-notification", timeout: 20) {
            let seen = P6Log()
            let name = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)
            let o = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in seen.add("changed") }
            defer { NotificationCenter.default.removeObserver(o) }
            let was = MACaptionAppearanceGetDisplayType(.user)
            let to: MACaptionAppearanceDisplayType = was == .alwaysOn ? .automatic : .alwaysOn
            MACaptionAppearanceSetDisplayType(.user, to)
            _ = await p6Wait(5) { seen.has("changed") }
            let now = MACaptionAppearanceGetDisplayType(.user)
            MACaptionAppearanceSetDisplayType(.user, was)
            try expect(now == to && seen.has("changed"), "notifications \(seen.all.count), display type \(was.rawValue) -> \(now.rawValue) (set \(to.rawValue))")
            return "display type \(was.rawValue) -> \(now.rawValue), notifications \(seen.all.count)"
        })
        #endif

        // MARK: round 17, batch 3
        // MARK: AVFoundation: an export with metadata (title written through) and a file length limit
        #if !os(watchOS)
        c.append(check("AVFoundation", "export-metadata-file-length-limit", timeout: 90) {
            let src = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-exs-\(UUID().uuidString.prefix(6)).mov")
            let dst = src.deletingPathExtension().appendingPathExtension("out.mov"), dst2 = src.deletingPathExtension().appendingPathExtension("lim.mov")
            defer { [src, dst, dst2].forEach { try? FileManager.default.removeItem(at: $0) } }
            try await writeMovie(src, frames: 60, size: 128)
            let asset = AVURLAsset(url: src)
            guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw Fail("no export session") }
            let title = AVMutableMetadataItem(); title.identifier = .commonIdentifierTitle; title.value = "SDKCov Title" as NSString; title.extendedLanguageTag = "und"
            ex.metadata = [title]
            try await ex.export(to: dst, as: .mov)
            let md = try await AVURLAsset(url: dst).load(.commonMetadata)
            let t = try await AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
            // a limit below the movie's size: the export stops at the limit, shorter than the source
            let full = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
            guard let ex2 = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw Fail("no export session 2") }
            ex2.fileLengthLimit = Int64(full / 2)
            var lim = "ok"
            do { try await ex2.export(to: dst2, as: .mov) } catch { lim = "\((error as NSError).domain) \((error as NSError).code)" }
            let size2 = (try? FileManager.default.attributesOfItem(atPath: dst2.path)[.size] as? Int) ?? -1
            let d1 = try await asset.load(.duration).seconds
            let d2 = (try? await AVURLAsset(url: dst2).load(.duration).seconds) ?? -1
            try expect(t == "SDKCov Title", "title written through: \(String(describing: t))")
            // Apple's simulator: a passthrough export with a file length limit is refused (AVErrorOperationNotSupportedForPreset, -11838)
            try expect(lim == "AVFoundationErrorDomain -11838" && size2 == -1, "limited export \(lim), \(size2) B of \(full), duration \(d2) of \(d1)")
            return "title '\(t ?? "")'; limit \(full / 2) B: \(size2) B, \(String(format: "%.2f", d2)) of \(String(format: "%.2f", d1)) s"
        })
        #endif

        // MARK: AudioToolbox: RemoteIO with a render callback pulled in real time (simaudio's output on x86Sim)
        #if canImport(AudioToolbox) && !os(watchOS)
        c.append(check("AudioToolbox", "remoteio-render-callback", timeout: 30) {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback); try s.setActive(true)
            defer { try? s.setActive(false, options: .notifyOthersOnDeactivation) }
            var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_RemoteIO,
                                                 componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let comp = AudioComponentFindNext(nil, &desc) else { throw Fail("no RemoteIO component") }
            var u: AudioUnit?
            try expect(AudioComponentInstanceNew(comp, &u) == noErr && u != nil, "AudioComponentInstanceNew")
            let unit = u!
            defer { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
            var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                  mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            let fs = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout.size(ofValue: fmt)))
            final class Counter { var calls = 0, frames = 0 }
            let ctr = Counter()
            var cb = AURenderCallbackStruct(inputProc: { ref, _, _, _, n, abl in
                let c = Unmanaged<Counter>.fromOpaque(ref).takeUnretainedValue(); c.calls += 1; c.frames += Int(n)
                for b in UnsafeMutableAudioBufferListPointer(abl!) { memset(b.mData, 0, Int(b.mDataByteSize)) }
                return noErr
            }, inputProcRefCon: Unmanaged.passUnretained(ctr).toOpaque())
            let cs = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            let ini = AudioUnitInitialize(unit), st = AudioOutputUnitStart(unit)
            try await Task.sleep(for: .seconds(1))
            var running: UInt32 = 0, sz = UInt32(4)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &sz)
            AudioOutputUnitStop(unit)
            let calls = ctr.calls, frames = ctr.frames
            try expect(fs == noErr && cs == noErr && ini == noErr && st == noErr && running == 1, "format \(fs) callback \(cs) initialize \(ini) start \(st) running \(running)")
            try expect(calls > 10 && frames > 20000, "\(calls) render calls, \(frames) frames in 1 s")
            return "\(calls) render calls, \(frames) frames in 1 s (session rate \(Int(s.sampleRate)))"
        })
        #endif

        // MARK: MapKit: marker annotation views on a map view on screen
        #if canImport(MapKit) && !os(watchOS)
        c.append(check("MapKit", "marker-annotation-views-on-screen", timeout: 40) {
            let d = P13MapDelegate()
            let (mv, done) = try await onMain { () -> (MKMapView, () -> Void) in
                let mv = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320)); mv.delegate = d
                let here = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
                mv.setRegion(MKCoordinateRegion(center: here, latitudinalMeters: 3000, longitudinalMeters: 3000), animated: false)
                let a = MKPointAnnotation(); a.coordinate = here; a.title = "SDKCovPin"
                let b = MKPointAnnotation(); b.coordinate = CLLocationCoordinate2D(latitude: 37.3399, longitude: -122.0090); b.title = "SDKCovPin2"
                mv.addAnnotations([a, b])
                let (_, done) = try p2Show(mv); return (mv, done)
            }
            defer { Task { @MainActor in done() } }
            let ok = await p6Wait(10) { mv.annotations.compactMap { mv.view(for: $0) }.count == 2 }
            let info = await onMain { () -> [String] in
                mv.annotations.compactMap { a -> String? in
                    guard let v = mv.view(for: a) as? MKMarkerAnnotationView else { return nil }
                    let pt = mv.convert(a.coordinate, toPointTo: mv)
                    return "\(a.title! ?? "") at \(Int(pt.x)),\(Int(pt.y)) view \(Int(v.frame.width))x\(Int(v.frame.height)) in map \(v.isDescendant(of: mv)) glyph \(v.glyphText ?? "")"
                }.sorted()
            }
            try expect(ok && info.count == 2 && info.allSatisfy { $0.contains("in map true") }, "annotation views \(info)")
            await onMain { mv.selectAnnotation(mv.annotations.first { $0.title == "SDKCovPin" }!, animated: false) }
            let sel = await onMain { mv.selectedAnnotations.compactMap { $0.title ?? nil } }
            try expect(sel == ["SDKCovPin"], "selected \(sel)")
            return "marker views \(info), selected \(sel)"
        })
        #endif

        // MARK: SafariServices: adding to the Reading List (iOS)
        #if canImport(SafariServices) && os(iOS)
        c.append(check("SafariServices", "reading-list-add", timeout: 20) {
            let u = URL(string: "https://example.com/sdkcov")!
            let ok = SSReadingList.supportsURL(u), bad = SSReadingList.supportsURL(URL(string: "file:///tmp/x")!)
            guard let rl = SSReadingList.default() else { return "no default reading list (supports https \(ok))" }
            var res = "added"
            do { try rl.addItem(with: u, title: "SDKCov", previewText: "sdkcov") } catch { res = "error \((error as NSError).domain) \((error as NSError).code)" }
            try expect(ok && !bad, "supportsURL https \(ok) file \(bad)")
            return "supports https \(ok), file \(bad); addItem \(res)"
        })
        #endif

        // MARK: PushKit: the File Provider push type (no token without an APNs connection)
        #if canImport(PushKit) && !os(tvOS) && !os(watchOS)
        c.append(check("PushKit", "file-provider-push-type", timeout: 30) {
            let d = P13Push()
            let reg = await onMain { () -> PKPushRegistry in let r = PKPushRegistry(queue: .main); r.delegate = d; r.desiredPushTypes = [.fileProvider]; return r }
            _ = await p6Wait(8) { !d.log.all.isEmpty }
            let (cached, types) = await onMain { (reg.pushToken(for: .fileProvider)?.count, reg.desiredPushTypes?.map(\.rawValue) ?? []) }
            await onMain { reg.desiredPushTypes = [] }
            // as func:PushKit.voip-credentials: a fresh device whose apsd has no APNs sandbox connection yet gets no token and caches
            // none; once apsd reached the sandbox (Apple's simulator after a while) an 80-byte token is delivered and cached
            let ev = d.log.all
            try expect(types == ["PKPushTypeFileProvider"] && ((ev.isEmpty && cached == nil) || (ev == ["token PKPushTypeFileProvider 80"] && cached == 80)), "desired \(types), events \(d.log.all), cached \(String(describing: cached))")
            return "desired \(types), events \(d.log.all), cached token \(cached.map { "\($0) B" } ?? "nil")"
        })
        #endif

        // MARK: StoreKit: a review request in the app's scene (development builds show the prompt on Apple's simulator)
        #if canImport(StoreKit) && (os(iOS) || os(visionOS))
        c.append(check("StoreKit", "request-review-in-scene", timeout: 30) {
            let before = await onMain { (try? p6Scene())?.windows.count ?? 0 }
            try await onMain { AppStore.requestReview(in: try p6Scene()) }
            try await Task.sleep(for: .seconds(3))
            let after = await onMain { ((try? p6Scene())?.windows ?? []).map { "\(type(of: $0))" } }
            // the review prompt is out of process (no window of the app's own appears), the request is accepted without an error
            try expect(after.count == before, "windows \(before) -> \(after)")
            return "windows \(before) -> \(after)"
        })
        #endif

        // MARK: LinkPresentation: cancel() of a metadata fetch to a loopback server that never answers
        #if canImport(LinkPresentation) && canImport(Network)
        c.append(check("LinkPresentation", "metadata-fetch-cancel", timeout: 40) {
            let l = try NWListener(using: .tcp, on: .any)
            let ready = P6Log()
            l.newConnectionHandler = { c in ready.add("conn"); c.start(queue: .global()) }   // accepts, never answers
 l.stateUpdateHandler = { if case .ready = $0 { ready.add("r") } }
            l.start(queue: .global()); defer { l.cancel() }
            _ = await p6Wait(5) { ready.has("r") }
            guard let port = l.port?.rawValue else { throw Fail("listener") }
            let p = await onMain { LPMetadataProvider() }
            let got = P1Box<String?>(nil)
            await onMain {
                p.startFetchingMetadata(for: URL(string: "http://127.0.0.1:\(port)/page")!) { md, e in
                    got.value = e.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "metadata \(md?.title ?? "")"
                }
            }
            let connected = await p6Wait(15) { ready.has("conn") }   // the fetch reached the server: cancel it mid-request
            await onMain { p.cancel() }
            _ = await p6Wait(10) { got.value != nil }
            // Apple's iOS simulator answers metadataFetchCancelled (LPErrorDomain 3) or, with LinkPresentation already warm, nothing at
            // all after cancel(); never metadata or another error
            try expect(connected && (got.value == nil || got.value == "error LPErrorDomain 3"), "connected \(connected), after cancel: \(got.value ?? "no answer")")
            return "cancel() mid-request answered \(got.value ?? "nothing in 10 s")"
        })
        #endif

        // MARK: round 17, batch 4 (tvOS / visionOS ports)
        // MARK: MetalKit: an MTKView's draw loop on screen (port of the iOS check)
        #if canImport(MetalKit) && (os(tvOS) || os(visionOS))
        c.append(check("MetalKit", "mtkview-draw-loop-on-screen", timeout: 30) {
            final class R: NSObject, MTKViewDelegate { let q: MTLCommandQueue; var frames = 0
                init(_ d: MTLDevice) { q = d.makeCommandQueue()! }
                func mtkView(_ v: MTKView, drawableSizeWillChange s: CGSize) {}
                func draw(in v: MTKView) {
                    guard let rp = v.currentRenderPassDescriptor, let dr = v.currentDrawable, let cb = q.makeCommandBuffer() else { return }
                    rp.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1); rp.colorAttachments[0].loadAction = .clear
                    cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding(); cb.present(dr); cb.commit(); frames += 1
                } }
            let (v, r, done) = try await onMain { () -> (MTKView, R, () -> Void) in
                let dev = try p2Dev()
                let vc = UIViewController(); vc.view.backgroundColor = .blue
                let v = MTKView(frame: CGRect(x: 0, y: 100, width: 300, height: 300), device: dev)
                v.colorPixelFormat = .bgra8Unorm; v.preferredFramesPerSecond = 60
                let r = R(dev); v.delegate = r; vc.view.addSubview(v)
                let (_, done) = try p6Show(vc); return (v, r, done)
            }
            defer { Task { @MainActor in v.isPaused = true; done() } }
            try await Task.sleep(for: .milliseconds(300))
            let f0 = await onMain { r.frames }; let t0 = Date()
            try await Task.sleep(for: .seconds(1))
            let fps = Double(await onMain { r.frames } - f0) / Date().timeIntervalSince(t0)
            try expect(fps > 20, "MTKView drew \(String(format: "%.1f", fps)) frames/s")
            let px = try await onMain { () -> [Int] in guard let img = p6Snap(v.window!) else { throw Fail("no snapshot") }; return p6Px(img, 150, 250) }
            try expect(p6Near(px, [255, 0, 0], 30), "on-screen pixel \(px) (expected the cleared red)")
            return "\(String(format: "%.0f", fps)) frames/s, drawable \(await onMain { v.drawableSize }), screen pixel red"
        })
        #endif

        // MARK: AVKit: picture in picture support and a sample-buffer content source (tvOS)
        #if canImport(AVKit) && os(tvOS)
        c.append(check("AVKit", "pip-sample-buffer-source", timeout: 30) {
            let r = await onMain { () -> String in
                final class D: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
                    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying p: Bool) {}
                    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)) }
                    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
                    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize s: CMVideoDimensions) {}
                    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval i: CMTime) async {}
                }
                let sup = AVPictureInPictureController.isPictureInPictureSupported()
                let pc = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(), playbackDelegate: D()))
                // Apple's tvOS 27.2 simulator: no picture in picture (unsupported, not possible)
                guard !sup && !pc.isPictureInPicturePossible && !pc.isPictureInPictureActive else { return "FAIL supported \(sup), possible \(pc.isPictureInPicturePossible)" }
                return "supported \(sup), possible \(pc.isPictureInPicturePossible), active \(pc.isPictureInPictureActive)"
            }
            try expect(!r.hasPrefix("FAIL"), r)
            return r
        })
        #endif

        // MARK: UIKit on visionOS: ports of the iOS alert / scroll view / document / text input checks (More_iOS.swift)
        #if os(visionOS)
        c.append(check("UIKit", "alert-actionsheet-present", timeout: 30) {
            let (root, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let r = UIViewController(); r.view.backgroundColor = .white
                let (_, done) = try p6Show(r); return (r, done)
            }
            defer { Task { @MainActor in done() } }
            try await expect(p6Wait(3) { root.view.window != nil }, "root not in a window")
            var out: [String] = []
            for style in [UIAlertController.Style.alert, .actionSheet] {
                let shown = Mutex(false)
                let ac = await onMain { () -> UIAlertController in
                    let ac = UIAlertController(title: "sdkcov", message: "x86sim", preferredStyle: style)
                    ac.addAction(UIAlertAction(title: "OK", style: .default)); ac.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    if style == .alert { ac.addTextField { $0.placeholder = "name" } }
                    ac.popoverPresentationController?.sourceView = root.view
                    root.present(ac, animated: true) { shown.withLock { $0 = true } }
                    return ac
                }
                try await expect(p6Wait(5) { shown.withLock { $0 } && ac.viewIfLoaded?.window != nil }, "\(style.rawValue): not shown")
                let size = await onMain { ac.view.bounds.size }
                try expect(size.width > 100 && size.height > 50, "\(style.rawValue) size \(size)")
                let gone = Mutex(false)
                await onMain { ac.dismiss(animated: true) { gone.withLock { $0 = true } } }
                try await expect(p6Wait(5) { gone.withLock { $0 } && root.presentedViewController == nil }, "\(style.rawValue): not dismissed")
                out.append("\(style == .alert ? "alert" : "sheet") \(Int(size.width))x\(Int(size.height))")
            }
            return out.joined(separator: ", ")
        })
        c.append(check("UIKit", "scrollview-zoom-offset") {
            try await onMain {
                final class D: NSObject, UIScrollViewDelegate { var scrolls = 0, zooms = 0; let content: UIView
                    init(_ c: UIView) { content = c }
                    func scrollViewDidScroll(_ s: UIScrollView) { scrolls += 1 }
                    func scrollViewDidZoom(_ s: UIScrollView) { zooms += 1 }
                    func viewForZooming(in s: UIScrollView) -> UIView? { content } }
                let vc = UIViewController()
                let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
                let content = UIView(frame: CGRect(x: 0, y: 0, width: 1000, height: 3000)); content.backgroundColor = .yellow
                sv.addSubview(content); sv.contentSize = content.bounds.size; sv.minimumZoomScale = 0.25; sv.maximumZoomScale = 4
                let d = D(content); sv.delegate = d; vc.view.addSubview(sv)
                let (w, done) = try p6Show(vc); defer { done() }
                w.layoutIfNeeded()
                sv.setContentOffset(CGPoint(x: 100, y: 2000), animated: false)
                try expect(sv.contentOffset == CGPoint(x: 100, y: 2000) && d.scrolls > 0, "offset \(sv.contentOffset), scrolls \(d.scrolls)")
                sv.setZoomScale(2, animated: false)
                try expect(sv.zoomScale == 2 && d.zooms > 0 && abs(sv.contentSize.width - 2000) < 1, "zoom \(sv.zoomScale), content \(sv.contentSize)")
                sv.zoom(to: CGRect(x: 0, y: 0, width: 600, height: 600), animated: false)
                try expect(abs(sv.zoomScale - 0.5) < 0.01, "zoom to rect \(sv.zoomScale)")
                let hit = vc.view.hitTest(vc.view.convert(CGPoint(x: 150, y: 150), from: sv), with: nil)
                try expect(hit === content, "hit test \(String(describing: hit))")
                return "\(d.scrolls) scroll / \(d.zooms) zoom callbacks"
            }
        })
        c.append(check("UIKit", "document-save-open", timeout: 30) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-doc.txt")
            try? FileManager.default.removeItem(at: url)
            let doc = await onMain { P13TextDoc(fileURL: url) }
            await onMain { doc.text = "x86sim document" }
            let saved = await doc.save(to: url, for: .forCreating)
            try expect(saved, "save forCreating")
            _ = await doc.close()
            let d2 = await onMain { P13TextDoc(fileURL: url) }
            let opened = await d2.open()
            let st = await onMain { d2.documentState.rawValue }; try expect(opened, "open (state \(st))")
            let text = await onMain { d2.text }
            try expect(text == "x86sim document", "read back \(text)")
            await onMain { d2.text += " edited"; d2.updateChangeCount(.done) }
            _ = await d2.close()   // autosaves the change
            let disk = try String(contentsOf: url, encoding: .utf8)
            try expect(disk == "x86sim document edited", "on disk after close: \(disk)")
            return "saved, reopened, autosaved on close"
        })
        c.append(check("UIKit", "first-responder-text-input", timeout: 20) {
            final class K: NSObject { var shown: CGRect?
                @objc func show(_ n: Notification) { shown = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue } }
            let k = K()
            let (tf, done) = try await onMain { () -> (UITextField, () -> Void) in
                NotificationCenter.default.addObserver(k, selector: #selector(K.show(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let tf = UITextField(frame: CGRect(x: 20, y: 100, width: 250, height: 40)); tf.borderStyle = .roundedRect
                vc.view.addSubview(tf)
                let (w, done) = try p6Show(vc); w.makeKey()
                return (tf, done)
            }
            defer { Task { @MainActor in tf.resignFirstResponder(); NotificationCenter.default.removeObserver(k); done() } }
            try await onMain { try expect(tf.becomeFirstResponder() && tf.isFirstResponder, "becomeFirstResponder") }
            let kb = await p6Wait(3) { k.shown != nil }
            return try await onMain {
                tf.insertText("x86"); tf.insertText("sim"); tf.deleteBackward()
                try expect(tf.text == "x86si", "typed \(String(describing: tf.text))")
                tf.selectedTextRange = tf.textRange(from: tf.beginningOfDocument, to: tf.position(from: tf.beginningOfDocument, offset: 3)!)
                tf.replace(tf.selectedTextRange!, withText: "ARM")
                try expect(tf.text == "ARMsi", "replace selection \(String(describing: tf.text))")
                tf.undoManager?.undo()
                return "text input ok, undo -> \(tf.text ?? "nil"), software keyboard \(kb ? "shown \(k.shown!.size)" : "not shown (hardware keyboard)")"
            }
        })

        // MARK: SwiftUI hosted in a window
        #endif

        return c
    }
}
