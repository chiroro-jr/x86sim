// sdkcov round 2: graphics and media paths x86Sim translates (Metal -> Vulkan through metalhostd/mtlvk, CoreImage on
// Metal, VideoToolbox/AVFoundation codecs) checked by pixel and value readback, plus CoreText, ImageIO, PDFKit, Vision.
import Foundation
import Synchronization
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(Metal)
import Metal
#endif
#if canImport(CoreText)
import CoreText
#endif
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(Metal)
private func more2Lib(_ dev: MTLDevice, _ src: String, _ consts: MTLFunctionConstantValues? = nil, _ names: [String]) async throws -> [MTLFunction] {
    let lib = try await dev.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + src, options: nil)
    return try names.map { n in
        if let consts { return try lib.makeFunction(name: n, constantValues: consts) }
        guard let f = lib.makeFunction(name: n) else { throw Fail("no function \(n)") }
        return f
    }
}
private func more2Run(_ cb: MTLCommandBuffer) async throws {
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        cb.addCompletedHandler { _ in k.resume() }
        cb.commit()
    }
    try expect(cb.status == .completed, "command buffer status \(cb.status.rawValue): \(String(describing: cb.error))")
}
private func more2Px(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 4)
    t.getBytes(&p, bytesPerRow: t.width * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return p
}
private func more2Near(_ p: [UInt8], _ q: [Int], _ tol: Int = 3) -> Bool { zip(p, q).allSatisfy { abs(Int($0) - $1) <= tol } }
#endif

/// RGBA8 pixels of a CGImage (sRGB)
private func more2RGBA(_ img: CGImage) -> (w: Int, h: Int, px: [UInt8]) {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, px)
}

extension Registry {
    static var more2_graphics: [Check] {
        guard more2On else { return [] }
        var c: [Check] = []
        #if canImport(Metal)
        c.append(check("Metal", "msaa-depth-test-resolve", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            try skipIf(!dev.supportsTextureSampleCount(4), "no 4x MSAA")
            let f = try await more2Lib(dev, """
            struct V { float4 p [[position]]; };
            struct U { float4 rect; float z; float pad[3]; float4 color; };
            vertex V vs(uint vid [[vertex_id]], constant U &u [[buffer(0)]], constant float2 *tri [[buffer(1)]]) {
                V v; float2 p = tri[vid]; v.p = float4(mix(u.rect.xy, u.rect.zw, p), u.z, 1); return v; }
            fragment float4 fs(V v [[stage_in]], constant U &u [[buffer(0)]]) { return u.color; }
            """, nil, ["vs", "fs"])
            let pd = MTLRenderPipelineDescriptor(); pd.vertexFunction = f[0]; pd.fragmentFunction = f[1]
            pd.colorAttachments[0].pixelFormat = .rgba8Unorm; pd.depthAttachmentPixelFormat = .depth32Float; pd.rasterSampleCount = 4
            let pso = try await dev.makeRenderPipelineState(descriptor: pd)
            let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .less; dd.isDepthWriteEnabled = true
            let ds = dev.makeDepthStencilState(descriptor: dd)!
            func tex(_ fmt: MTLPixelFormat, ms: Bool) -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: 64, height: 64, mipmapped: false)
                if ms { d.textureType = .type2DMultisample; d.sampleCount = 4; d.storageMode = .private; d.usage = .renderTarget }
                else { d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead] }
                return dev.makeTexture(descriptor: d)!
            }
            let msc = tex(.rgba8Unorm, ms: true), msd = tex(.depth32Float, ms: true), out = tex(.rgba8Unorm, ms: false)
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = msc; rp.colorAttachments[0].resolveTexture = out
            rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .multisampleResolve
            rp.depthAttachment.texture = msd; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = .dontCare
            let q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer()!, e = cb.makeRenderCommandEncoder(descriptor: rp)!
            e.setRenderPipelineState(pso); e.setDepthStencilState(ds)
            let quad: [SIMD2<Float>] = [[0, 0], [1, 0], [0, 1], [1, 0], [1, 1], [0, 1]]
            let tri: [SIMD2<Float>] = [[0, 0], [1, 0], [0, 1]]
            func draw(_ rect: SIMD4<Float>, _ z: Float, _ col: SIMD4<Float>, _ verts: [SIMD2<Float>]) {
                var u = (rect, z, Float(0), Float(0), Float(0), col)
                e.setVertexBytes(&u, length: 48, index: 0); e.setFragmentBytes(&u, length: 48, index: 0)
                e.setVertexBytes(verts, length: verts.count * 8, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
            }
            draw([-1, -1, 0, 1], 0.3, [0, 1, 0, 1], quad)      // green, left half, near
            draw([-1, -1, 1, 1], 0.7, [1, 0, 0, 1], quad)      // red, everything, far: hidden where green is
            draw([-1, -1, 1, 1], 0.1, [0, 0, 1, 1], tri)       // blue triangle, nearest: its diagonal edge is antialiased
            e.endEncoding()
            try await more2Run(cb)
            // Metal's y points up in NDC, the texture's row 0 is the top
            let tl = more2Px(out, 8, 60), right = more2Px(out, 56, 8), topRight = more2Px(out, 60, 2)
            try expect(more2Near(tl, [0, 0, 255, 255]), "blue (lower-left triangle) at (8,60): \(tl)")
            try expect(more2Near(topRight, [255, 0, 0, 255]), "red beyond the triangle at (60,2): \(topRight)")
            let left = more2Px(out, 8, 4)
            try expect(more2Near(left, [0, 255, 0, 255]), "green (near) over red (far) at (8,4): \(left)")
            _ = right
            // the triangle's diagonal: resolved pixels between blue and the background behind it
            var mixed = 0
            for x in 0..<64 { let y = x; let p = more2Px(out, x, y); if p[2] > 20 && p[2] < 235 { mixed += 1 } }
            try expect(mixed >= 8, "only \(mixed) partially covered pixels on the edge: no multisample resolve")
            return "depth test near-over-far, 4x MSAA resolve: \(mixed) blended edge pixels"
        })
        c.append(check("Metal", "instancing-vertex-descriptor-indexed", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let f = try await more2Lib(dev, """
            struct In { float2 pos [[attribute(0)]]; float2 off [[attribute(1)]]; uchar4 col [[attribute(2)]]; };
            struct V { float4 p [[position]]; float4 c; };
            vertex V vs(In in [[stage_in]]) { V v; v.p = float4(in.pos * 0.4 + in.off, 0, 1); v.c = float4(in.col) / 255.0; return v; }
            fragment float4 fs(V v [[stage_in]]) { return v.c; }
            """, nil, ["vs", "fs"])
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float2; vd.attributes[1].offset = 0; vd.attributes[1].bufferIndex = 1
            vd.attributes[2].format = .uchar4; vd.attributes[2].offset = 8; vd.attributes[2].bufferIndex = 1
            vd.layouts[0].stride = 8; vd.layouts[1].stride = 12; vd.layouts[1].stepFunction = .perInstance; vd.layouts[1].stepRate = 1
            let pd = MTLRenderPipelineDescriptor(); pd.vertexFunction = f[0]; pd.fragmentFunction = f[1]; pd.vertexDescriptor = vd
            pd.colorAttachments[0].pixelFormat = .rgba8Unorm
            let pso = try await dev.makeRenderPipelineState(descriptor: pd)
            // a unit quad (-1..1) through 4 vertices + 6 uint16 indices; 4 instances: offset + colour each
            let verts: [Float] = [-1, -1, 1, -1, 1, 1, -1, 1]
            let idx: [UInt16] = [0, 1, 2, 0, 2, 3]
            var inst = Data()
            let offs: [(Float, Float)] = [(-0.5, 0.5), (0.5, 0.5), (-0.5, -0.5), (0.5, -0.5)]
            let cols: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
            for i in 0..<4 { withUnsafeBytes(of: offs[i].0) { inst.append(contentsOf: $0) }; withUnsafeBytes(of: offs[i].1) { inst.append(contentsOf: $0) }; inst.append(contentsOf: cols[i]) }
            let vb = dev.makeBuffer(bytes: verts, length: 32)!, ib = dev.makeBuffer(bytes: idx, length: 12)!
            let instb = inst.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: inst.count)! }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false); td.usage = [.renderTarget]; td.storageMode = .shared
            let out = dev.makeTexture(descriptor: td)!
            let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1); rp.colorAttachments[0].storeAction = .store
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeRenderCommandEncoder(descriptor: rp)!
            e.setRenderPipelineState(pso); e.setVertexBuffer(vb, offset: 0, index: 0); e.setVertexBuffer(instb, offset: 0, index: 1)
            e.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0, instanceCount: 4)
            e.endEncoding()
            try await more2Run(cb)
            let got = [more2Px(out, 16, 16), more2Px(out, 48, 16), more2Px(out, 16, 48), more2Px(out, 48, 48)]
            let want = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
            for i in 0..<4 { try expect(more2Near(got[i], want[i]), "instance \(i) quadrant pixel \(got[i]), want \(want[i])") }
            let center = more2Px(out, 32, 2)
            try expect(more2Near(center, [255, 255, 255, 255]), "gap between quads not background: \(center)")
            return "4 instances, per-instance offsets/colours (uchar4 normalized), uint16 indices"
        })
        c.append(check("Metal", "textures-mipmaps-blit-formats-srgb", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let q = dev.makeCommandQueue()!
            // a 64x64 1-pixel checkerboard (black / white) -> generateMipmaps -> level 3 (8x8) is mid grey
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: true)
            td.usage = [.shaderRead]; td.storageMode = .shared
            let t = dev.makeTexture(descriptor: td)!
            try expect(t.mipmapLevelCount == 7, "mip levels \(t.mipmapLevelCount)")
            var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
            for y in 0..<64 { for x in 0..<64 { let v: UInt8 = (x + y) % 2 == 0 ? 255 : 0; for k in 0..<3 { px[(y * 64 + x) * 4 + k] = v }; px[(y * 64 + x) * 4 + 3] = 255 } }
            t.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: px, bytesPerRow: 256)
            let cb = q.makeCommandBuffer()!, b = cb.makeBlitCommandEncoder()!
            b.generateMipmaps(for: t)
            let copy = dev.makeBuffer(length: 8 * 8 * 4, options: .storageModeShared)!
            b.copy(from: t, sourceSlice: 0, sourceLevel: 3, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: 8, height: 8, depth: 1), to: copy, destinationOffset: 0, destinationBytesPerRow: 32, destinationBytesPerImage: 256)
            b.endEncoding()
            try await more2Run(cb)
            let l3 = Array(UnsafeBufferPointer(start: copy.contents().assumingMemoryBound(to: UInt8.self), count: 256))
            let greys = stride(from: 0, to: 256, by: 4).map { Int(l3[$0]) }
            try expect(greys.allSatisfy { abs($0 - 127) <= 4 }, "mip level 3 not mid grey: \(greys.prefix(8))")
            // sampling in a compute kernel: bilinear between texels, explicit mip level, write to r32Float / rgba16Float
            let f = try await more2Lib(dev, """
            kernel void k(texture2d<float> src [[texture(0)]], texture2d<float, access::write> o32 [[texture(1)]], texture2d<half, access::write> o16 [[texture(2)]],
                          device float4 *res [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
                constexpr sampler lin(filter::linear, mip_filter::nearest, address::clamp_to_edge);
                if (g.x == 0 && g.y == 0) {
                    res[0] = src.sample(lin, float2(0.5, 0.5), level(3));           // a mip-3 texel
                    res[1] = src.sample(lin, float2(1.0 / 64.0, 0.5 / 64.0), level(0)); // between texel (0,0) white and (1,0) black
                    res[2] = src.read(uint2(3, 5), 0);
                }
                o32.write(float4(float(g.x) * 0.25 + float(g.y) * 1000.0), g);
                o16.write(half4(half(g.x) / 4.0h, -half(g.y), 0.5h, 1.0h), g);
            }
            """, nil, ["k"])
            let pso = try await dev.makeComputePipelineState(function: f[0])
            func tex(_ fmt: MTLPixelFormat) -> MTLTexture { let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: 8, height: 8, mipmapped: false); d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .shared; return dev.makeTexture(descriptor: d)! }
            let o32 = tex(.r32Float), o16 = tex(.rgba16Float), res = dev.makeBuffer(length: 48, options: .storageModeShared)!
            let cb2 = q.makeCommandBuffer()!, ce = cb2.makeComputeCommandEncoder()!
            ce.setComputePipelineState(pso); ce.setTexture(t, index: 0); ce.setTexture(o32, index: 1); ce.setTexture(o16, index: 2); ce.setBuffer(res, offset: 0, index: 0)
            ce.dispatchThreads(MTLSize(width: 8, height: 8, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            ce.endEncoding()
            try await more2Run(cb2)
            let r = res.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            try expect(abs(r[0].x - 0.5) < 0.03, "sampled mip 3 \(r[0])")
            try expect(abs(r[1].x - 0.5) < 0.03, "bilinear between white and black \(r[1])")
            try expect(r[2].x == 1 && r[2].w == 1, "read (3,5) (even sum: white) \(r[2])")
            var f32 = [Float](repeating: 0, count: 64); o32.getBytes(&f32, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            try expect(f32[7 * 8 + 5] == 7001.25 && f32[1] == 0.25, "r32Float \(f32[7 * 8 + 5]) \(f32[1])")
            var h16 = [UInt16](repeating: 0, count: 256); o16.getBytes(&h16, bytesPerRow: 64, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            let h = (0..<4).map { Float(Float16(bitPattern: h16[(3 * 8 + 6) * 4 + $0])) }
            try expect(h == [1.5, -3, 0.5, 1], "rgba16Float at (6,3) \(h)")
            // sRGB render target: a linear 0.5 clear is stored as 188
            let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 4, height: 4, mipmapped: false); sd.usage = [.renderTarget]; sd.storageMode = .shared
            let st = dev.makeTexture(descriptor: sd)!
            let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = st; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.2, blue: 1, alpha: 1)
            let cb3 = q.makeCommandBuffer()!; cb3.makeRenderCommandEncoder(descriptor: rp)!.endEncoding()
            try await more2Run(cb3)
            let s = more2Px(st, 1, 1)   // BGRA
            try expect(abs(Int(s[2]) - 188) <= 1 && abs(Int(s[1]) - 124) <= 1 && s[0] == 255, "sRGB stored BGRA \(s) (want R 188, G 124)")
            return "mips 7, level-3 grey \(greys[0]), bilinear, r32Float/rgba16Float writes, sRGB encode \(s[2])"
        })
        c.append(check("Metal", "argument-buffer-function-constants-indirect", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let src = """
            struct Args { device const float *in; device float *out; float scale; };
            constant int kMode [[function_constant(0)]];
            kernel void k(constant Args &a [[buffer(0)]], uint i [[thread_position_in_grid]]) {
                a.out[i] = kMode == 1 ? a.in[i] * a.scale : a.in[i] + a.scale;
            }
            """
            func pipe(_ mode: Int32) async throws -> MTLComputePipelineState {
                let cv = MTLFunctionConstantValues(); var m = mode; cv.setConstantValue(&m, type: .int, index: 0)
                return try await dev.makeComputePipelineState(function: try await more2Lib(dev, src, cv, ["k"])[0])
            }
            let mul = try await pipe(1), add = try await pipe(2)
            let n = 256
            let inb = dev.makeBuffer(bytes: (0..<n).map { Float($0) }, length: n * 4, options: .storageModeShared)!
            let o1 = dev.makeBuffer(length: n * 4, options: .storageModeShared)!, o2 = dev.makeBuffer(length: n * 4, options: .storageModeShared)!
            // the argument buffers: GPU addresses of in / out and the scale, as an app writes them (Tier 2 layout)
            func args(_ out: MTLBuffer, _ scale: Float) -> MTLBuffer {
                let b = dev.makeBuffer(length: 24, options: .storageModeShared)!
                b.contents().storeBytes(of: inb.gpuAddress, toByteOffset: 0, as: UInt64.self)
                b.contents().storeBytes(of: out.gpuAddress, toByteOffset: 8, as: UInt64.self)
                b.contents().storeBytes(of: scale, toByteOffset: 16, as: Float.self)
                return b
            }
            let a1 = args(o1, 3), a2 = args(o2, 100)
            // indirect dispatch: 4 threadgroups of 64 from a buffer
            let ind = dev.makeBuffer(bytes: [UInt32(4), 1, 1], length: 12, options: .storageModeShared)!
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            e.useResource(inb, usage: .read); e.useResource(o1, usage: .write); e.useResource(o2, usage: .write)
            e.setComputePipelineState(mul); e.setBuffer(a1, offset: 0, index: 0)
            e.dispatchThreadgroups(indirectBuffer: ind, indirectBufferOffset: 0, threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            e.setComputePipelineState(add); e.setBuffer(a2, offset: 0, index: 0)
            e.dispatchThreadgroups(MTLSize(width: 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            e.endEncoding()
            try await more2Run(cb)
            let r1 = o1.contents().assumingMemoryBound(to: Float.self), r2 = o2.contents().assumingMemoryBound(to: Float.self)
            try expect(r1[0] == 0 && r1[7] == 21 && r1[255] == 765, "multiply (constant 1, indirect): \(r1[7]) \(r1[255])")
            try expect(r2[0] == 100 && r2[255] == 355, "add (constant 2): \(r2[0]) \(r2[255])")
            return "argument tier \(dev.argumentBuffersSupport.rawValue), GPU-address argument buffers, 2 specialisations, indirect dispatch"
        })
        c.append(check("Metal", "threadgroup-atomics-simdgroup", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let f = try await more2Lib(dev, """
            kernel void red(device const uint *in [[buffer(0)]], device atomic_uint *total [[buffer(1)]], device uint *partial [[buffer(2)]],
                            uint tid [[thread_index_in_threadgroup]], uint gid [[threadgroup_position_in_grid]], uint i [[thread_position_in_grid]]) {
                threadgroup uint sh[256];
                sh[tid] = in[i];
                threadgroup_barrier(mem_flags::mem_threadgroup);
                for (uint s = 128; s > 0; s >>= 1) { if (tid < s) sh[tid] += sh[tid + s]; threadgroup_barrier(mem_flags::mem_threadgroup); }
                if (tid == 0) { partial[gid] = sh[0]; atomic_fetch_add_explicit(total, sh[0], memory_order_relaxed); }
            }
            kernel void simdk(device const float *in [[buffer(0)]], device float *sum [[buffer(1)]], device float *pre [[buffer(2)]], device float *shuf [[buffer(3)]],
                             device uint *width [[buffer(4)]], uint i [[thread_position_in_grid]], uint lane [[thread_index_in_simdgroup]], uint w [[threads_per_simdgroup]]) {
                float v = in[i];
                sum[i] = simd_sum(v);
                pre[i] = simd_prefix_exclusive_sum(v);
                shuf[i] = simd_shuffle_down(v, 1);
                if (i == 0) width[0] = w;
            }
            """, nil, ["red", "simdk"])
            let red = try await dev.makeComputePipelineState(function: f[0]), simd = try await dev.makeComputePipelineState(function: f[1])
            let n = 65536
            let vals = (0..<n).map { UInt32(($0 &* 2_654_435_761) >> 20) }
            let inb = dev.makeBuffer(bytes: vals, length: n * 4, options: .storageModeShared)!
            let tot = dev.makeBuffer(length: 4, options: .storageModeShared)!; memset(tot.contents(), 0, 4)
            let part = dev.makeBuffer(length: n / 256 * 4, options: .storageModeShared)!
            let m = 256
            let fin = dev.makeBuffer(bytes: (0..<m).map { Float($0 % 7) + 0.5 }, length: m * 4, options: .storageModeShared)!
            let sum = dev.makeBuffer(length: m * 4, options: .storageModeShared)!, pre = dev.makeBuffer(length: m * 4, options: .storageModeShared)!
            let shuf = dev.makeBuffer(length: m * 4, options: .storageModeShared)!, wid = dev.makeBuffer(length: 4, options: .storageModeShared)!
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(red); e.setBuffer(inb, offset: 0, index: 0); e.setBuffer(tot, offset: 0, index: 1); e.setBuffer(part, offset: 0, index: 2)
            e.dispatchThreadgroups(MTLSize(width: n / 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            e.setComputePipelineState(simd)
            for (k, b) in [fin, sum, pre, shuf, wid].enumerated() { e.setBuffer(b, offset: 0, index: k) }
            e.dispatchThreads(MTLSize(width: m, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            e.endEncoding()
            try await more2Run(cb)
            let want = vals.reduce(UInt32(0), &+)
            let got = tot.contents().load(as: UInt32.self)
            let p = part.contents().assumingMemoryBound(to: UInt32.self)
            try expect(got == want, "atomic total \(got), want \(want)")
            try expect(p[0] == vals[0..<256].reduce(UInt32(0), &+) && p[255] == vals[65280..<65536].reduce(UInt32(0), &+), "threadgroup reduction partials")
            let w = Int(wid.contents().load(as: UInt32.self))
            try expect([4, 8, 16, 32, 64].contains(w), "simd width \(w)")
            let fs = fin.contents().assumingMemoryBound(to: Float.self), ss = sum.contents().assumingMemoryBound(to: Float.self)
            let ps = pre.contents().assumingMemoryBound(to: Float.self), sh = shuf.contents().assumingMemoryBound(to: Float.self)
            for g in stride(from: 0, to: m, by: w) {
                let s = (g..<g + w).reduce(Float(0)) { $0 + fs[$1] }
                var acc: Float = 0
                for i in g..<g + w {
                    try expect(ss[i] == s, "simd_sum lane \(i): \(ss[i]) want \(s)")
                    try expect(ps[i] == acc, "prefix sum lane \(i): \(ps[i]) want \(acc)"); acc += fs[i]
                    if i < g + w - 1 { try expect(sh[i] == fs[i + 1], "shuffle_down lane \(i): \(sh[i])") }
                }
            }
            return "65536-element reduction (threadgroup + atomics) = \(got), SIMD width \(w): sum / prefix / shuffle_down exact"
        })
        c.append(check("Metal", "shared-event-heap-completion-order", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let q = dev.makeCommandQueue()!
            // the GPU signals a shared event; a listener on the CPU hears the value
            guard let ev = dev.makeSharedEvent() else { throw Fail("makeSharedEvent") }
            let heard = Atomic<UInt64>(0)
            let listener = MTLSharedEventListener(dispatchQueue: DispatchQueue(label: "sdkcov.ev"))
            ev.notify(listener, atValue: 5) { _, v in heard.store(v, ordering: .relaxed) }
            let cb1 = q.makeCommandBuffer()!; cb1.encodeSignalEvent(ev, value: 5)
            try await more2Run(cb1)
            try expect(await more2Wait(5) { heard.load(ordering: .relaxed) >= 5 } && ev.signaledValue >= 5, "event listener heard \(heard.load(ordering: .relaxed)), signaled \(ev.signaledValue)")
            // a command buffer waits on the event until the CPU signals 7
            let marker = dev.makeBuffer(length: 4, options: .storageModeShared)!; memset(marker.contents(), 0, 4)
            let cb2 = q.makeCommandBuffer()!; cb2.encodeWaitForEvent(ev, value: 7)
            let bl = cb2.makeBlitCommandEncoder()!; bl.fill(buffer: marker, range: 0..<4, value: 0xab); bl.endEncoding()
            cb2.commit()
            try await Task.sleep(for: .milliseconds(300))
            let early = marker.contents().load(as: UInt32.self)
            ev.signaledValue = 7
            cb2.waitUntilCompleted()
            try expect(early == 0 && marker.contents().load(as: UInt32.self) == 0xabababab, "GPU wait: before signal \(String(early, radix: 16)), after \(String(marker.contents().load(as: UInt32.self), radix: 16))")
            // a heap: two buffers sub-allocated, filled by blits, read back
            let hd = MTLHeapDescriptor(); hd.size = 1 << 20; hd.storageMode = .private   // Apple's simulator: heaps are private
            guard let heap = dev.makeHeap(descriptor: hd), let h1 = heap.makeBuffer(length: 4096, options: .storageModePrivate), let h2 = heap.makeBuffer(length: 4096, options: .storageModePrivate) else { throw Fail("heap") }
            let rb = dev.makeBuffer(length: 4096, options: .storageModeShared)!
            let cb3 = q.makeCommandBuffer()!, b3 = cb3.makeBlitCommandEncoder()!
            b3.fill(buffer: h1, range: 0..<4096, value: 0x11); b3.copy(from: h1, sourceOffset: 0, to: h2, destinationOffset: 0, size: 2048)
            b3.copy(from: h2, sourceOffset: 0, to: rb, destinationOffset: 0, size: 4096); b3.endEncoding()
            try await more2Run(cb3)
            let hp = rb.contents().assumingMemoryBound(to: UInt8.self)
            try expect(hp[0] == 0x11 && hp[2047] == 0x11 && heap.usedSize >= 8192, "heap buffers \(hp[0]) \(hp[2047]) used \(heap.usedSize)")
            // 20 command buffers: completion handlers run in commit order, GPU times are sane
            let order = Mutex<[Int]>([]); let times = Mutex<[(Double, Double)]>([])
            var last: MTLCommandBuffer?
            for i in 0..<20 {
                let cb = q.makeCommandBuffer()!; let b = cb.makeBlitCommandEncoder()!; b.fill(buffer: rb, range: 0..<4096, value: UInt8(i)); b.endEncoding()
                cb.addCompletedHandler { c in order.withLock { $0.append(i) }; times.withLock { $0.append((c.gpuStartTime, c.gpuEndTime)) } }
                cb.commit(); last = cb
            }
            last?.waitUntilCompleted()
            _ = await more2Wait(3) { order.withLock { $0.count } == 20 }
            try expect(order.withLock { $0 } == Array(0..<20), "completion order \(order.withLock { $0 })")
            try expect(times.withLock { $0.allSatisfy { $0.1 >= $0.0 && $0.0 > 0 } }, "gpu times \(times.withLock { $0.prefix(3) })")
            try expect(rb.contents().load(as: UInt8.self) == 19, "last fill \(rb.contents().load(as: UInt8.self))")
            return "shared event GPU->CPU listener and CPU->GPU wait, heap sub-allocation, 20 completions in order"
        })
        #endif
        #if canImport(CoreText) && canImport(UIKit)
        c.append(check("CoreText", "framesetter-fallback-emoji-font-data") {
            // a paragraph laid out in a 200 pt frame: lines, every line within the width, string ranges cover the text
            let text = "x86Sim lays out text with Core Text: the quick brown fox jumps over the lazy dog, 漢字とかな, عربي, and 🦊🚀 emoji."
            let font = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let fs = CTFramesetterCreateWithAttributedString(attr)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: 200, height: 1000), transform: nil), nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var covered = 0
            for l in lines { let w = CTLineGetTypographicBounds(l, nil, nil, nil); try expect(w <= 200.5, "line wider than the frame: \(w)"); covered += CTLineGetStringRange(l).length }
            try expect(lines.count >= 5 && lines.count <= 9 && covered == (text as NSString).length, "lines \(lines.count), covered \(covered)/\((text as NSString).length)")
            // font fallback: the runs' fonts for Han, Arabic and emoji are not Helvetica
            var runFonts: [String: String] = [:]
            for l in lines { for r in CTLineGetGlyphRuns(l) as! [CTRun] {
                let rg = CTRunGetStringRange(r); let s = (text as NSString).substring(with: NSRange(location: rg.location, length: rg.length))
                let f = (CTRunGetAttributes(r) as NSDictionary)[kCTFontAttributeName] as! CTFont
                let name = CTFontCopyPostScriptName(f) as String
                if s.contains("漢") { runFonts["han"] = name }; if s.contains("ع") { runFonts["arabic"] = name }; if s.contains("🦊") { runFonts["emoji"] = name }
            } }
            try expect(runFonts["emoji"] == "AppleColorEmoji" && runFonts["han"].map { !$0.hasPrefix("Helvetica") } == true && runFonts["arabic"].map { !$0.hasPrefix("Helvetica") } == true, "fallback fonts \(runFonts)")
            // a colour emoji glyph renders in colour (sbix bitmaps)
            let ctx = bitmap(64, 64); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "🍎", attributes: [.font: CTFontCreateWithName("AppleColorEmoji" as CFString, 40, nil)]))
            ctx.textPosition = CGPoint(x: 6, y: 12); CTLineDraw(line, ctx)
            var reds = 0
            for y in 0..<64 { for x in 0..<64 { let p = pixel(ctx, x, y); if Int(p[0]) > 150 && Int(p[1]) < 90 && Int(p[2]) < 90 { reds += 1 } } }
            try expect(reds > 150, "emoji drew \(reds) red pixels")
            // a font from its file's data: descriptor from data, same PostScript name; registered for the process
            guard let url = CTFontCopyAttribute(CTFontCreateWithName("Courier" as CFString, 12, nil), kCTFontURLAttribute) as? URL else { throw Fail("font URL") }
            let data = try Data(contentsOf: url)
            guard let d = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { throw Fail("descriptor from \(data.count) B") }
            let f2 = CTFontCreateWithFontDescriptor(d, 20, nil)
            let ps = CTFontCopyPostScriptName(f2) as String
            guard let cgf = CGFont(CGDataProvider(data: data as CFData)!) else { throw Fail("CGFont") }
            var err: Unmanaged<CFError>?
            let reg = CTFontManagerRegisterGraphicsFont(cgf, &err)
            let regMsg = reg ? "registered" : "register: \(String(describing: err?.takeRetainedValue()))"
            if reg { CTFontManagerUnregisterGraphicsFont(cgf, nil) }
            try expect(ps.hasPrefix("Courier") && CTFontGetGlyphCount(f2) > 100, "font from data: \(ps), \(CTFontGetGlyphCount(f2)) glyphs")
            return "\(lines.count) lines in 200 pt, fallback \(runFonts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")), emoji \(reds) red px, \(ps) from \(data.count) B (\(regMsg))"
        })
        #endif
        #if canImport(CoreImage) && canImport(Metal)
        c.append(check("CoreImage", "metal-vs-software-filter-chain") {
            // a gradient + text image through blur, colour matrix, affine scale and a blend: the Metal-backed context
            // and the software renderer agree within a few levels
            let base = textImage("x86Sim CI", 256, 128, size: 40)
            let img = CIImage(cgImage: base)
            let grad = CIFilter.linearGradient(); grad.point0 = .zero; grad.point1 = CGPoint(x: 256, y: 128)
            grad.color0 = CIColor(red: 1, green: 0, blue: 0); grad.color1 = CIColor(red: 0, green: 0, blue: 1)
            let blur = CIFilter.gaussianBlur(); blur.inputImage = img; blur.radius = 3
            let cm = CIFilter.colorMatrix(); cm.inputImage = blur.outputImage!.cropped(to: img.extent)
            cm.rVector = CIVector(x: 0.5, y: 0.3, z: 0.2, w: 0); cm.biasVector = CIVector(x: 0.05, y: 0, z: 0, w: 0)
            let blend = CIFilter.multiplyBlendMode(); blend.inputImage = cm.outputImage!; blend.backgroundImage = grad.outputImage!.cropped(to: img.extent)
            let out = blend.outputImage!.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            let rect = out.extent.integral
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let gpu = CIContext(mtlDevice: dev, options: [.workingColorSpace: cs, .outputColorSpace: cs])
            let cpu = CIContext(options: [.useSoftwareRenderer: true, .workingColorSpace: cs, .outputColorSpace: cs])
            func render(_ c: CIContext) -> [UInt8] {
                var b = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
                c.render(out, toBitmap: &b, rowBytes: Int(rect.width) * 4, bounds: rect, format: .RGBA8, colorSpace: cs)
                return b
            }
            let g = render(gpu), s = render(cpu)
            var maxd = 0, sumd = 0
            for i in 0..<g.count { let d = abs(Int(g[i]) - Int(s[i])); maxd = max(maxd, d); sumd += d }
            let nonzero = g.enumerated().filter { $0.offset % 4 != 3 && $0.element > 10 }.count
            try expect(nonzero > g.count / 8, "GPU output mostly black (\(nonzero) lit channels)")
            try expect(maxd <= 6, "GPU vs software differ by up to \(maxd) (mean \(Double(sumd) / Double(g.count)))")
            // CIAreaAverage reduces on the GPU to the same mean as computed on the CPU
            let avg = CIFilter.areaAverage(); avg.inputImage = out; avg.extent = rect
            var a = [UInt8](repeating: 0, count: 4)
            gpu.render(avg.outputImage!, toBitmap: &a, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: cs)
            let cpuAvg = (0..<3).map { k in stride(from: k, to: g.count, by: 4).reduce(0) { $0 + Int(g[$1]) } / (g.count / 4) }
            try expect((0..<3).allSatisfy { abs(Int(a[$0]) - cpuAvg[$0]) <= 4 }, "area average \(a.prefix(3)) vs CPU mean \(cpuAvg)")
            return "\(Int(rect.width))x\(Int(rect.height)) chain: GPU vs software max diff \(maxd), area average \(a.prefix(3))"
        })
        #endif
        #if canImport(Vision) && canImport(CoreImage)
        c.append(check("Vision", "barcodes-from-coreimage-generators", timeout: 60) {
            // QR, Aztec and Code 128 generated by Core Image, read back by Vision with their payloads
            let ctx = CIContext()
            func code(_ f: CIFilter, _ scale: CGFloat) throws -> CGImage {
                let img = f.outputImage!.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let padded = img.composited(over: CIImage(color: .white).cropped(to: img.extent.insetBy(dx: -40, dy: -40)))
                guard let cg = ctx.createCGImage(padded, from: padded.extent) else { throw Fail("render") }
                return cg
            }
            let qr = CIFilter.qrCodeGenerator(); qr.message = Data("https://x86sim.example/qr?n=42".utf8); qr.correctionLevel = "M"
            let az = CIFilter.aztecCodeGenerator(); az.message = Data("x86sim aztec".utf8)
            let c128 = CIFilter.code128BarcodeGenerator(); c128.message = Data("X86SIM-128".utf8); c128.quietSpace = 10
            var found: [String: String] = [:]
            for (name, f, s) in [("qr", qr as CIFilter, CGFloat(8)), ("aztec", az, 8), ("code128", c128, 3)] {
                let req = VNDetectBarcodesRequest()
                do { try VNImageRequestHandler(cgImage: try code(f, s)).perform([req]) }
                catch let e as NSError where e.domain == "com.apple.Vision" && e.code == 9 {
                    throw Skip("Vision: \(e.localizedDescription) (code 9): Apple's simulator fails the same way (no inference context for the barcode model)")
                }
                let r = req.results ?? []
                found[name] = r.first.map { "\($0.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")):\($0.payloadStringValue ?? "-")" } ?? "none"
            }
            try expect(found["qr"]?.hasSuffix(":https://x86sim.example/qr?n=42") == true, "QR \(found["qr"] ?? "")")
            try expect(found["aztec"]?.hasSuffix(":x86sim aztec") == true, "Aztec \(found["aztec"] ?? "")")
            try expect(found["code128"]?.hasSuffix(":X86SIM-128") == true, "Code 128 \(found["code128"] ?? "")")
            return found.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "; ")
        })
        #endif
        #if canImport(PDFKit) && canImport(UIKit)
        c.append(check("PDFKit", "create-annotate-search-roundtrip") {
            // 3 pages drawn with UIGraphicsPDFRenderer (text + a filled rectangle), opened in PDFKit
            let r = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: { let f = UIGraphicsPDFRendererFormat(); f.documentInfo = [kCGPDFContextTitle as String: "sdkcov more2", kCGPDFContextAuthor as String: "x86Sim"]; return f }())
            let data = r.pdfData { ctx in
                for p in 1...3 {
                    ctx.beginPage()
                    ("Page \(p): x86Sim renders PDF. Needle\(p == 2 ? " needle twice needle" : "")." as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
                    UIColor(red: 0, green: 0.6, blue: 0, alpha: 1).setFill(); UIRectFill(CGRect(x: 72, y: 200, width: 200, height: 100))
                }
            }
            guard let doc = PDFDocument(data: data) else { throw Fail("PDFDocument from \(data.count) B") }
            try expect(doc.pageCount == 3 && (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) == "sdkcov more2", "pages \(doc.pageCount), attrs \(String(describing: doc.documentAttributes))")
            let hits = doc.findString("needle", withOptions: [.caseInsensitive])
            let perPage = hits.map { doc.index(for: $0.pages.first!) }
            try expect(hits.count == 5 && perPage.filter { $0 == 1 }.count == 3, "needle hits \(hits.count) on pages \(perPage)")
            try expect(doc.page(at: 2)?.string?.contains("Page 3: x86Sim renders PDF.") == true, "page 3 text \(String(describing: doc.page(at: 2)?.string))")
            // annotations: a highlight on the first hit, a free-text note, a link; written out and read back
            let page = doc.page(at: 0)!
            let hl = PDFAnnotation(bounds: hits[0].bounds(for: page), forType: .highlight, withProperties: nil); hl.color = .yellow; page.addAnnotation(hl)
            let note = PDFAnnotation(bounds: CGRect(x: 300, y: 600, width: 200, height: 40), forType: .freeText, withProperties: nil); note.contents = "sdkcov note"; page.addAnnotation(note)
            let link = PDFAnnotation(bounds: CGRect(x: 72, y: 400, width: 100, height: 20), forType: .link, withProperties: nil); link.url = URL(string: "https://x86sim.example"); page.addAnnotation(link)
            guard let out = doc.dataRepresentation(), let back = PDFDocument(data: out) else { throw Fail("write/read back") }
            let anns = back.page(at: 0)!.annotations
            let types = Set(anns.compactMap { $0.type })
            try expect(anns.count == 3 && types == ["Highlight", "FreeText", "Link"] && anns.contains { $0.contents == "sdkcov note" } && anns.contains { $0.url?.host == "x86sim.example" }, "annotations back: \(anns.map { "\($0.type ?? "?") \($0.contents ?? "")" })")
            // a thumbnail shows the green rectangle
            let th = back.page(at: 1)!.thumbnail(of: CGSize(width: 306, height: 396), for: .mediaBox)
            guard let cg = th.cgImage else { throw Fail("thumbnail") }
            let (w, h, px) = more2RGBA(cg)
            let sx = Int(Double(w) * 172 / 612), sy = Int(Double(h) * 250 / 792)
            let p = Array(px[(sy * w + sx) * 4..<(sy * w + sx) * 4 + 3])
            try expect(Int(p[1]) > 120 && Int(p[0]) < 60 && Int(p[2]) < 60, "thumbnail \(w)x\(h) pixel at the rectangle \(p)")
            // page manipulation: remove, insert, exchange
            back.removePage(at: 2); back.exchangePage(at: 0, withPageAt: 1)
            try expect(back.pageCount == 2 && back.page(at: 0)?.string?.hasPrefix("Page 2") == true, "page edits \(back.pageCount) \(String(describing: back.page(at: 0)?.string?.prefix(6)))")
            return "3 pages \(data.count) B, 5 hits, highlight/freeText/link round trip \(out.count) B, thumbnail, page edits"
        })
        #endif
        c.append(check("ImageIO", "animated-gif-exif-gps-thumbnail-orientation") {
            let d = try more2Dir("imageio")
            // a 6-frame animated GIF with per-frame delays and a loop count
            let gif = d.appendingPathComponent("a.gif")
            guard let dst = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 6, nil) else { throw Fail("GIF destination") }
            CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary)
            for i in 0..<6 {
                let ctx = bitmap(32, 32); ctx.setFillColor(CGColor(red: CGFloat(i) / 5, green: 0, blue: 1 - CGFloat(i) / 5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                CGImageDestinationAddImage(dst, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05 * Double(i + 1)]] as CFDictionary)
            }
            try expect(CGImageDestinationFinalize(dst), "GIF finalize")
            guard let src = CGImageSourceCreateWithURL(gif as CFURL, nil) else { throw Fail("GIF source") }
            let delays = (0..<CGImageSourceGetCount(src)).map { i -> Double in
                let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                return ((p?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double) ?? -1
            }
            let loop = ((CGImageSourceCopyProperties(src, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
            try expect(delays.count == 6 && zip(delays, [0.05, 0.1, 0.15, 0.2, 0.25, 0.3]).allSatisfy { abs($0 - $1) < 0.011 } && loop == 3, "GIF delays \(delays) loop \(String(describing: loop))")
            let last = more2RGBA(CGImageSourceCreateImageAtIndex(src, 5, nil)!)
            try expect(last.px[0] > 240 && last.px[2] < 15, "frame 5 colour \(last.px.prefix(4))")
            // CGAnimateImageAtURLWithBlock plays the frames
            let frames = Mutex<Set<Int>>([])
            let st = CGAnimateImageAtURLWithBlock(gif as CFURL, nil) { i, _, stop in frames.withLock { _ = $0.insert(i) }; if i >= 5 { stop.pointee = true } }
            _ = await more2Wait(5) { frames.withLock { $0.count } >= 6 }
            try expect(st == noErr && frames.withLock { $0.count } == 6, "animation frames \(frames.withLock { $0.sorted() }) status \(st)")
            // JPEG with EXIF orientation 6 (rotated 90 cw), GPS and a user comment; a transformed thumbnail is upright
            let jpg = d.appendingPathComponent("o.jpg")
            let ctx = bitmap(200, 100); ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))   // blue left edge
            guard let jd = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Fail("JPEG destination") }
            CGImageDestinationAddImage(jd, ctx.makeImage()!, [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.9,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "sdkcov more2", kCGImagePropertyExifLensModel: "x86 lens"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W"]] as CFDictionary)
            try expect(CGImageDestinationFinalize(jd), "JPEG finalize")
            guard let js = CGImageSourceCreateWithURL(jpg as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(js, 0, nil) as? [CFString: Any] else { throw Fail("JPEG source") }
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any], gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            try expect((p[kCGImagePropertyOrientation] as? Int) == 6 && (exif?[kCGImagePropertyExifUserComment] as? String) == "sdkcov more2" && (exif?[kCGImagePropertyExifLensModel] as? String) == "x86 lens", "EXIF \(String(describing: p[kCGImagePropertyOrientation])) \(String(describing: exif?[kCGImagePropertyExifUserComment]))")
            try expect(abs(((gps?[kCGImagePropertyGPSLatitude] as? Double) ?? 0) - 37.3349) < 0.001 && (gps?[kCGImagePropertyGPSLongitudeRef] as? String) == "W", "GPS \(String(describing: gps))")
            guard let th = CGImageSourceCreateThumbnailAtIndex(js, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 80, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw Fail("thumbnail") }
            let t = more2RGBA(th)
            // upright: 40 wide, 80 tall, the blue edge on top (rows are top-down in our bitmap? CGContext rows: bottom-up drawing, buffer top row first)
            let top = Array(t.px[(2 * t.w + t.w / 2) * 4..<(2 * t.w + t.w / 2) * 4 + 3]), bottom = Array(t.px[((t.h - 3) * t.w + t.w / 2) * 4..<((t.h - 3) * t.w + t.w / 2) * 4 + 3])
            try expect(t.w == 40 && t.h == 80 && top[2] > 180 && top[0] < 80 && bottom[0] > 180 && bottom[2] < 80, "thumbnail \(t.w)x\(t.h) top \(top) bottom \(bottom)")
            // metadata edit without recompression: change the comment in place
            let edited = d.appendingPathComponent("e.jpg")
            let md = CGImageMetadataCreateMutable()
            CGImageMetadataSetValueMatchingImageProperty(md, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, "edited" as CFString)
            guard let ed = CGImageDestinationCreateWithURL(edited as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Fail("edit destination") }
            var e: Unmanaged<CFError>?
            let ok = CGImageDestinationCopyImageSource(ed, js, [kCGImageDestinationMetadata: md, kCGImageDestinationMergeMetadata: true] as CFDictionary, &e)
            let ep = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(edited as CFURL, nil)!, 0, nil) as? [CFString: Any]
            try expect(ok && ((ep?[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String) == "edited", "lossless metadata edit \(ok) \(String(describing: e?.takeRetainedValue()))")
            return "GIF 6 frames delays+loop, animation callback, EXIF/GPS, oriented thumbnail \(t.w)x\(t.h), lossless metadata edit"
        })
        #if canImport(VideoToolbox) && canImport(AVFoundation) && !os(watchOS)
        c.append(check("AVFoundation", "assetreader-decoded-pixels-pixel-transfer", timeout: 90) {
            // a movie of 30 solid frames (grey level 8 * i) decoded back: frame count, timing and grey levels survive H.264
            let u = try more2Dir("reader").appendingPathComponent("m.mov")
            try await writeMovie(u, frames: 30, size: 128)
            let asset = AVURLAsset(url: u)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let dur = try await asset.load(.duration)
            try expect(abs(dur.seconds - 1.0) < 0.05, "duration \(dur.seconds)")
            let r = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            r.add(out)
            try expect(r.startReading(), "startReading \(String(describing: r.error))")
            var levels: [Int] = [], times: [Double] = []
            var sample10: CVPixelBuffer?
            while let sb = out.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
                levels.append(Int(p[64 * bpr + 64 * 4 + 1]))
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                if levels.count == 11 { sample10 = pb }
            }
            try expect(r.status == .completed && levels.count == 30, "decoded \(levels.count) frames, status \(r.status.rawValue) \(String(describing: r.error))")
            let bad = levels.enumerated().filter { abs($0.element - $0.offset * 8) > 8 }
            try expect(bad.isEmpty, "grey levels off: \(bad.prefix(5)) of \(levels)")
            try expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 } && abs(times[29] - 29.0 / 30) < 0.01, "timestamps \(times.prefix(3))...\(times.last ?? -1)")
            // VTPixelTransferSession: BGRA 128 -> 420v 64 (scale + convert) -> back to BGRA: level and size kept
            guard let src = sample10 else { throw Fail("no frame 10") }
            var vt: VTPixelTransferSession?
            try expect(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &vt) == noErr, "VTPixelTransferSessionCreate")
            guard let vt else { throw Fail("session") }
            defer { VTPixelTransferSessionInvalidate(vt) }
            var yuv: CVPixelBuffer?, back: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &yuv)
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &back)
            try expect(VTPixelTransferSessionTransferImage(vt, from: src, to: yuv!) == noErr && VTPixelTransferSessionTransferImage(vt, from: yuv!, to: back!) == noErr, "transfers")
            CVPixelBufferLockBaseAddress(yuv!, .readOnly); CVPixelBufferLockBaseAddress(back!, .readOnly)
            let yv = Int(CVPixelBufferGetBaseAddressOfPlane(yuv!, 0)!.load(fromByteOffset: 32 * CVPixelBufferGetBytesPerRowOfPlane(yuv!, 0) + 32, as: UInt8.self))
            let bv = Int(CVPixelBufferGetBaseAddress(back!)!.load(fromByteOffset: 32 * CVPixelBufferGetBytesPerRow(back!) + 32 * 4 + 1, as: UInt8.self))
            CVPixelBufferUnlockBaseAddress(yuv!, .readOnly); CVPixelBufferUnlockBaseAddress(back!, .readOnly)
            // video range: Y = 16 + 219 * level / 255
            let wantY = 16 + 219 * levels[10] / 255
            try expect(abs(yv - wantY) <= 4 && abs(bv - levels[10]) <= 5, "420v Y \(yv) (want \(wantY)), back to BGRA \(bv) (want \(levels[10]))")
            return "30 frames decoded, levels \(levels[1]),\(levels[10]),\(levels[29]); pixel transfer Y \(yv), BGRA \(bv)"
        })
        #endif
        return c
    }
}
