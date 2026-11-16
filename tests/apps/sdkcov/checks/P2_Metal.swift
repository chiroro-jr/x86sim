// sdkcov P2: Metal depth beyond the More2 set. What Apple's simulator GPU offers is narrower than hardware (its
// MTLSimDriver device answers its own feature set; Metal 4, MTLIO and tensors are not in the simulator SDK at all), so
// each check first asserts the device's answer Apple's simulator gives (ref-mac.sh) and then runs the feature where
// that answer says it exists: function pointers / visible function tables, dynamic libraries, binary archives, ray
// tracing, mesh and tile shaders, indirect command buffers, residency sets, counters and timestamps, capture to a
// file, shader logging, rasterization rate maps; MetalPerformancePrimitives (a shader-only header library).
import Foundation
#if canImport(Metal)
import Metal
#endif

#if canImport(Metal)
func p2Lib(_ dev: MTLDevice, _ src: String, _ opts: MTLCompileOptions? = nil) async throws -> MTLLibrary {
    try await dev.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n" + src, options: opts)
}
func p2Fn(_ lib: MTLLibrary, _ n: String) throws -> MTLFunction {
    guard let f = lib.makeFunction(name: n) else { throw Fail("no function \(n) in the library") }
    return f
}
func p2Run(_ cb: MTLCommandBuffer) async throws {
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        cb.addCompletedHandler { _ in k.resume() }
        cb.commit()
    }
    try expect(cb.status == .completed, "command buffer status \(cb.status.rawValue): \(String(describing: cb.error))")
}
func p2Dev() throws -> MTLDevice {
    guard let d = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
    return d
}
func p2Buf(_ dev: MTLDevice, _ v: [Float]) -> MTLBuffer { dev.makeBuffer(bytes: v, length: max(v.count, 1) * 4, options: .storageModeShared)! }
func p2Floats(_ b: MTLBuffer, _ n: Int) -> [Float] { Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: Float.self), count: n)) }
func p2Tex(_ dev: MTLDevice, _ w: Int, _ h: Int, _ fmt: MTLPixelFormat = .rgba8Unorm, _ usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
    d.usage = usage; d.storageMode = .shared
    return dev.makeTexture(descriptor: d)!
}
func p2Px(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 4)
    t.getBytes(&p, bytesPerRow: t.width * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return p
}
/// the device's feature answers, one string (compared with Apple's simulator)
func p2Features(_ d: MTLDevice) -> [String: String] {
    var r: [String: String] = [:]
    let fams: [(String, MTLGPUFamily)] = [("apple1", .apple1), ("apple2", .apple2), ("apple3", .apple3), ("apple4", .apple4), ("apple5", .apple5),
        ("apple6", .apple6), ("apple7", .apple7), ("apple8", .apple8), ("apple9", .apple9), ("mac2", .mac2), ("common1", .common1),
        ("common2", .common2), ("common3", .common3), ("metal3", .metal3)]
    r["families"] = fams.filter { d.supportsFamily($0.1) }.map(\.0).joined(separator: ",")
    r["raytracing"] = "\(d.supportsRaytracing)"
    r["raytracingFromRender"] = "\(d.supportsRaytracingFromRender)"
    r["functionPointers"] = "\(d.supportsFunctionPointers)"
    r["functionPointersFromRender"] = "\(d.supportsFunctionPointersFromRender)"
    r["dynamicLibraries"] = "\(d.supportsDynamicLibraries)"
    r["renderDynamicLibraries"] = "\(d.supportsRenderDynamicLibraries)"
    r["barycentrics"] = "\(d.supportsShaderBarycentricCoordinates)"
    r["rasterizationRateMap1"] = "\(d.supportsRasterizationRateMap(layerCount: 1))"
    r["vertexAmplification2"] = "\(d.supportsVertexAmplificationCount(2))"
    r["counterSampling"] = [("stage", MTLCounterSamplingPoint.atStageBoundary), ("draw", .atDrawBoundary), ("dispatch", .atDispatchBoundary),
        ("blit", .atBlitBoundary), ("tile", .atTileDispatchBoundary)].filter { d.supportsCounterSampling($0.1) }.map(\.0).joined(separator: ",")
    r["counterSets"] = (d.counterSets ?? []).map(\.name).sorted().joined(separator: ",")
    r["argumentBuffersTier"] = "\(d.argumentBuffersSupport.rawValue)"
    r["readWriteTextureTier"] = "\(d.readWriteTextureSupport.rawValue)"
    r["unifiedMemory"] = "\(d.hasUnifiedMemory)"
    r["bc"] = "\(d.supportsBCTextureCompression)"
    r["floatFiltering32"] = "\(d.supports32BitFloatFiltering)"
    r["msaa32"] = "\(d.supports32BitMSAA)"
    r["pullModel"] = "\(d.supportsPullModelInterpolation)"
    r["queryLOD"] = "\(d.supportsQueryTextureLOD)"
    r["rog"] = "\(d.areRasterOrderGroupsSupported)"
    r["samplePositions"] = "\(d.areProgrammableSamplePositionsSupported)"
    r["maxThreadgroupMemory"] = "\(d.maxThreadgroupMemoryLength)"
    r["maxThreadsPerThreadgroup"] = "\(d.maxThreadsPerThreadgroup.width)"
    return r
}
final class P2Lines: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}
#endif

extension Registry {
    /// sdkcov P2 (graphics, 3D, AR & games): P2_Metal / P2_MPS / P2_Scene / P2_Reality / P2_Games.swift
    static var p2: [Check] { p2_metal + p2_mps + p2_scene + p2_reality + p2_games }

    static var p2_metal: [Check] {
        var c: [Check] = []
        #if canImport(Metal)
        c.append(check("Metal", "simulator-feature-answers", timeout: 30) {
            let d = try p2Dev()
            let f = p2Features(d)
            let s = f.keys.sorted().map { "\($0)=\(f[$0]!)" }.joined(separator: " ")
            // Metal 4, MTLIO and MTLTensor are not in the simulator SDKs (the headers are empty there): the runtime's
            // Metal answers for them as Apple's simulator does
            let m4 = ["MTL4CommandQueueDescriptor", "MTL4CompilerDescriptor", "MTL4ArgumentTableDescriptor", "MTLIOCommandQueueDescriptor",
                      "MTLTensorDescriptor", "MTLResidencySetDescriptor"].map { "\($0):\(NSClassFromString($0) != nil)" }.joined(separator: ",")
            let sels = ["newMTL4CommandQueue", "newCommandAllocator", "newCompilerWithDescriptor:error:", "newIOCommandQueueWithDescriptor:error:",
                        "newResidencySetWithDescriptor:error:", "newLogStateWithDescriptor:error:"]
                .map { "\($0):\((d as AnyObject).responds(to: NSSelectorFromString($0)))" }.joined(separator: ",")
            // Apple's iOS / tvOS / visionOS 27.2 simulators (ref-mac.sh): the simulator GPU's fixed feature set
            let want = "argumentBuffersTier=0 barycentrics=false bc=false counterSampling=draw,dispatch,blit counterSets= dynamicLibraries=false families=apple1,apple2,common1 floatFiltering32=false functionPointers=false functionPointersFromRender=false maxThreadgroupMemory=16384 maxThreadsPerThreadgroup=512 msaa32=false pullModel=false queryLOD=false rasterizationRateMap1=false raytracing=false raytracingFromRender=false readWriteTextureTier=0 renderDynamicLibraries=false rog=false samplePositions=false unifiedMemory=false vertexAmplification2=false"
            try expect(s == want, "feature answers differ from Apple's simulator: \(s)")
            try expect(m4 == "MTL4CommandQueueDescriptor:false,MTL4CompilerDescriptor:false,MTL4ArgumentTableDescriptor:false,MTLIOCommandQueueDescriptor:false,MTLTensorDescriptor:false,MTLResidencySetDescriptor:true", "classes \(m4)")
            try expect(sels == "newMTL4CommandQueue:false,newCommandAllocator:false,newCompilerWithDescriptor:error::false,newIOCommandQueueWithDescriptor:error::false,newResidencySetWithDescriptor:error::true,newLogStateWithDescriptor:error::true", "selectors \(sels)")
            return "\(d.name) | \(s) | classes \(m4) | selectors \(sels)"
        })
        c.append(check("Metal", "binary-archive-serialize-reload", timeout: 90) {
            let dev = try p2Dev()
            let lib = try await p2Lib(dev, "kernel void sq(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] = b[i] * b[i] + 0.5f; }")
            let cd = MTLComputePipelineDescriptor(); cd.computeFunction = try p2Fn(lib, "sq")
            let ar = try dev.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
            ar.label = "sdkcov"
            var added = "added"
            do { try ar.addComputePipelineFunctions(descriptor: cd) } catch { added = "add refused: \((error as NSError).domain) \((error as NSError).code)" }
            var ser = "-", reload = "-", miss = "-", size = -1
            if String(describing: type(of: dev as AnyObject)).contains("MTLSimDevice") {
                // Apple's simulator Metal client asserts in +[MTLLoader sliceIDForDevice:...] ("Target device architecture
                // is nil") when an archive is serialized: no file is written on a simulator device
                ser = "not serialized (the simulator has no GPU architecture slice)"
                cd.binaryArchives = [ar]
            } else {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p2-\(UUID().uuidString).metallib")
                defer { try? FileManager.default.removeItem(at: url) }
                do { try ar.serialize(to: url); ser = "serialized" } catch { ser = "serialize refused: \((error as NSError).domain) \((error as NSError).code)" }
                size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1
                if size > 0 {
                    let d2 = MTLBinaryArchiveDescriptor(); d2.url = url
                    let ar2 = try dev.makeBinaryArchive(descriptor: d2)
                    cd.binaryArchives = [ar2]
                    do { _ = try await dev.makeComputePipelineState(descriptor: cd, options: .failOnBinaryArchiveMiss); reload = "pipeline from archive" }
                    catch { reload = "archive miss \((error as NSError).code)" }
                    // a function the archive does not hold: failOnBinaryArchiveMiss refuses it (nothing is compiled)
                    let other = try await p2Lib(dev, "kernel void other(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] = 7; }")
                    let cd2 = MTLComputePipelineDescriptor(); cd2.computeFunction = try p2Fn(other, "other"); cd2.binaryArchives = cd.binaryArchives
                    do { _ = try await dev.makeComputePipelineState(descriptor: cd2, options: .failOnBinaryArchiveMiss); miss = "compiled anyway" }
                    catch { miss = "refused \((error as NSError).code)" }
                }
            }
            // the pipeline runs either way
            let pso = try await dev.makeComputePipelineState(descriptor: cd, options: []).0
            let b = p2Buf(dev, [1, 2, 3, 4])
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(pso); e.setBuffer(b, offset: 0, index: 0)
            e.dispatchThreads(MTLSize(width: 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1)); e.endEncoding()
            try await p2Run(cb)
            try expect(p2Floats(b, 4) == [1.5, 4.5, 9.5, 16.5], "kernel \(p2Floats(b, 4))")
            return "\(added), \(ser) (\(size) B), reload: \(reload), uncached function: \(miss)"
        })
        c.append(check("Metal", "dynamic-library-link", timeout: 90) {
            let dev = try p2Dev()
            let o = MTLCompileOptions(); o.libraryType = .dynamic; o.installName = "@executable_path/sdkcov-sq.metallib"
            let dsrc = "float sdkcov_sq(float x) { return x * x + 1.0f; }"
            var dyn: MTLDynamicLibrary?
            var how = ""
            do {
                let dl = try await p2Lib(dev, dsrc, o)
                dyn = try dev.makeDynamicLibrary(library: dl)
            } catch { how = "refused: \((error as NSError).domain) \((error as NSError).code) \((error as NSError).localizedDescription.prefix(80))" }
            if !dev.supportsDynamicLibraries {
                try expect(dyn == nil, "supportsDynamicLibraries false but a dynamic library was made")
                return "supportsDynamicLibraries false; newDynamicLibrary \(how)"
            }
            guard let dyn else { throw Fail("supportsDynamicLibraries but \(how)") }
            try expect(dyn.installName == "@executable_path/sdkcov-sq.metallib", "installName \(dyn.installName)")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-sq.metallib")
            try? FileManager.default.removeItem(at: url); defer { try? FileManager.default.removeItem(at: url) }
            try dyn.serialize(to: url)
            let back = try dev.makeDynamicLibrary(url: url)
            let lo = MTLCompileOptions(); lo.libraries = [back]
            let lib = try await p2Lib(dev, "extern float sdkcov_sq(float x);\nkernel void k(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] = sdkcov_sq(b[i]); }", lo)
            let pso = try await dev.makeComputePipelineState(function: try p2Fn(lib, "k"))
            let b = p2Buf(dev, [1, 2, 3])
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(pso); e.setBuffer(b, offset: 0, index: 0)
            e.dispatchThreads(MTLSize(width: 3, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 3, height: 1, depth: 1)); e.endEncoding()
            try await p2Run(cb)
            try expect(p2Floats(b, 3) == [2, 5, 10], "linked call \(p2Floats(b, 3))")
            return "dynamic library serialized, reloaded and linked: \(p2Floats(b, 3))"
        })
        c.append(check("Metal", "function-pointers-visible-table", timeout: 90) {
            let dev = try p2Dev()
            let src = """
            [[visible]] float addOne(float x) { return x + 1.0f; }
            [[visible]] float twice(float x) { return x * 2.0f; }
            kernel void k(device float *b [[buffer(0)]], visible_function_table<float(float)> t [[buffer(1)]], uint i [[thread_position_in_grid]]) { b[i] = t[i % 2](b[i]); }
            """
            var lib: MTLLibrary?
            var why = ""
            do { lib = try await p2Lib(dev, src) } catch { why = "compile: \((error as NSError).code) \((error as NSError).localizedDescription.prefix(100))" }
            guard dev.supportsFunctionPointers else {
                // Apple's simulator: no function pointers; a pipeline linking visible functions is refused
                var pipe = "no library"
                if let lib, let k = lib.makeFunction(name: "k"), let f1 = lib.makeFunction(name: "addOne") {
                    let cd = MTLComputePipelineDescriptor(); cd.computeFunction = k
                    let lf = MTLLinkedFunctions(); lf.functions = [f1]; cd.linkedFunctions = lf
                    do { _ = try await dev.makeComputePipelineState(descriptor: cd, options: []); pipe = "pipeline made" }
                    catch { pipe = "pipeline refused \((error as NSError).code)" }
                }
                return "supportsFunctionPointers false: \(lib == nil ? why : "library compiled"), \(pipe)"
            }
            guard let lib else { throw Fail(why) }
            let f1 = try p2Fn(lib, "addOne"), f2 = try p2Fn(lib, "twice")
            let cd = MTLComputePipelineDescriptor(); cd.computeFunction = try p2Fn(lib, "k")
            let lf = MTLLinkedFunctions(); lf.functions = [f1, f2]; cd.linkedFunctions = lf
            let pso = try await dev.makeComputePipelineState(descriptor: cd, options: []).0
            let vd = MTLVisibleFunctionTableDescriptor(); vd.functionCount = 2
            guard let vft = pso.makeVisibleFunctionTable(descriptor: vd), let h1 = pso.functionHandle(function: f1), let h2 = pso.functionHandle(function: f2) else { throw Fail("no table / handles") }
            vft.setFunction(h1, index: 0); vft.setFunction(h2, index: 1)
            let b = p2Buf(dev, [1, 2, 3, 4])
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(pso); e.setBuffer(b, offset: 0, index: 0); e.setVisibleFunctionTable(vft, bufferIndex: 1)
            e.dispatchThreads(MTLSize(width: 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1)); e.endEncoding()
            try await p2Run(cb)
            try expect(p2Floats(b, 4) == [2, 4, 4, 8], "table calls \(p2Floats(b, 4))")
            return "visible function table calls \(p2Floats(b, 4))"
        })
        c.append(check("Metal", "raytracing-acceleration-structure", timeout: 90) {
            let dev = try p2Dev()
            guard dev.supportsRaytracing else {
                // no ray tracing in this simulator: the sizes query answers zero and nothing is built
                let g = MTLAccelerationStructureTriangleGeometryDescriptor(); g.triangleCount = 1; g.vertexStride = 12
                g.vertexBuffer = p2Buf(dev, [0, 0, 0, 1, 0, 0, 0, 1, 0])
                let pd = MTLPrimitiveAccelerationStructureDescriptor(); pd.geometryDescriptors = [g]
                let s = dev.accelerationStructureSizes(descriptor: pd)
                return "supportsRaytracing false; sizes \(s.accelerationStructureSize)/\(s.buildScratchBufferSize)"
            }
            let vb = p2Buf(dev, [0, 0, 0, 1, 0, 0, 0, 1, 0])   // a triangle in z = 0
            let g = MTLAccelerationStructureTriangleGeometryDescriptor(); g.vertexBuffer = vb; g.vertexStride = 12; g.triangleCount = 1
            let pd = MTLPrimitiveAccelerationStructureDescriptor(); pd.geometryDescriptors = [g]
            let sz = dev.accelerationStructureSizes(descriptor: pd)
            guard let accel = dev.makeAccelerationStructure(size: sz.accelerationStructureSize),
                  let scratch = dev.makeBuffer(length: max(sz.buildScratchBufferSize, 16), options: .storageModePrivate) else { throw Fail("allocation") }
            let lib = try await p2Lib(dev, """
            #include <metal_raytracing>
            using namespace raytracing;
            kernel void rt(primitive_acceleration_structure as [[buffer(0)]], device float *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
                ray r; r.origin = float3(i == 0 ? 0.25f : 5.0f, 0.25f, -1.0f); r.direction = float3(0, 0, 1); r.min_distance = 0; r.max_distance = 100;
                intersector<triangle_data> isect;
                auto res = isect.intersect(r, as);
                out[i] = res.type == intersection_type::triangle ? res.distance : -1.0f;
            }
            """)
            let pso = try await dev.makeComputePipelineState(function: try p2Fn(lib, "rt"))
            let out = p2Buf(dev, [9, 9])
            let q = dev.makeCommandQueue()!
            let cb = q.makeCommandBuffer()!
            let ae = cb.makeAccelerationStructureCommandEncoder()!
            ae.build(accelerationStructure: accel, descriptor: pd, scratchBuffer: scratch, scratchBufferOffset: 0); ae.endEncoding()
            let e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(pso); e.setAccelerationStructure(accel, bufferIndex: 0); e.setBuffer(out, offset: 0, index: 1)
            e.useResource(accel, usage: .read)
            e.dispatchThreads(MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1)); e.endEncoding()
            try await p2Run(cb)
            let r = p2Floats(out, 2)
            try expect(abs(r[0] - 1) < 1e-4 && r[1] == -1, "hit distances \(r) (want 1, miss)")
            return "acceleration structure \(sz.accelerationStructureSize) B; hit at \(r[0]), miss"
        })
        c.append(check("Metal", "mesh-shader-pipeline", timeout: 90) {
            let dev = try p2Dev()
            let src = """
            struct VOut { float4 p [[position]]; };
            using TriMesh = metal::mesh<VOut, void, 3, 1, metal::topology::triangle>;
            [[mesh]] void msh(TriMesh m, uint t [[thread_index_in_threadgroup]]) {
                if (t == 0) { m.set_primitive_count(1); }
                if (t < 3) {
                    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
                    VOut v; v.p = float4(p[t], 0, 1); m.set_vertex(t, v); m.set_index(t, t);
                }
            }
            fragment float4 mfs(VOut v [[stage_in]]) { return float4(0, 1, 0, 1); }
            """
            let lib: MTLLibrary
            do { lib = try await p2Lib(dev, src) } catch { return "mesh shader source refused: \((error as NSError).code) \((error as NSError).localizedDescription.prefix(120))" }
            // mesh shaders need the Apple7 / Mac2 family; Apple's simulator GPU has neither and its MTLSimDevice asserts
            // ("not supported in the simulator") on a mesh pipeline, so none is made there
            guard dev.supportsFamily(.apple7) || dev.supportsFamily(.mac2) else {
                return "mesh shader source compiled; no Apple7/Mac2 family (families \(p2Features(dev)["families"]!)): no mesh pipeline in the simulator"
            }
            let md = MTLMeshRenderPipelineDescriptor(); md.meshFunction = try p2Fn(lib, "msh"); md.fragmentFunction = try p2Fn(lib, "mfs")
            md.colorAttachments[0].pixelFormat = .rgba8Unorm
            let pso: MTLRenderPipelineState
            do { pso = try await dev.makeRenderPipelineState(descriptor: md, options: []).0 }
            catch { return "mesh pipeline refused (families \(p2Features(dev)["families"]!)): \((error as NSError).code) \((error as NSError).localizedDescription.prefix(120))" }
            let t = p2Tex(dev, 16, 16)
            let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeRenderCommandEncoder(descriptor: rp)!
            e.setRenderPipelineState(pso)
            e.drawMeshThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1), threadsPerMeshThreadgroup: MTLSize(width: 3, height: 1, depth: 1))
            e.endEncoding()
            try await p2Run(cb)
            let px = p2Px(t, 8, 8)
            try expect(px == [0, 255, 0, 255], "mesh-shaded pixel \(px)")
            return "mesh shader drew \(px)"
        })
        c.append(check("Metal", "tile-shader-imageblock", timeout: 90) {
            let dev = try p2Dev()
            let src = """
            struct FragData { half4 color [[color(0)]]; };
            kernel void tinv(imageblock<FragData, imageblock_layout_implicit> ib, ushort2 tid [[thread_position_in_threadgroup]]) {
                FragData d = ib.read(tid); d.color = half4(1.0h - d.color.rgb, 1.0h); ib.write(d, tid);
            }
            """
            let apple4 = dev.supportsFamily(.apple4)
            let lib: MTLLibrary
            do { lib = try await p2Lib(dev, src) } catch { return "apple4 \(apple4); tile kernel source refused: \((error as NSError).code)" }
            // tile shaders / imageblocks need Apple4; Apple's simulator GPU (Apple2) has no tile pipelines
            guard apple4 else { return "tile kernel source compiled; no Apple4 family: no tile pipeline in the simulator" }
            let td = MTLTileRenderPipelineDescriptor(); td.tileFunction = try p2Fn(lib, "tinv"); td.colorAttachments[0].pixelFormat = .rgba8Unorm
            td.threadgroupSizeMatchesTileSize = true
            let pso: MTLRenderPipelineState
            do { pso = try await dev.makeRenderPipelineState(tileDescriptor: td, options: []).0 }
            catch {
                try expect(!apple4, "Apple4 family but the tile pipeline was refused: \(error)")
                return "no Apple4 family: tile pipeline refused \((error as NSError).code)"
            }
            let t = p2Tex(dev, 32, 32)
            let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1); rp.tileWidth = 16; rp.tileHeight = 16
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeRenderCommandEncoder(descriptor: rp)!
            e.setRenderPipelineState(pso); e.dispatchThreadsPerTile(MTLSize(width: 16, height: 16, depth: 1)); e.endEncoding()
            try await p2Run(cb)
            let px = p2Px(t, 20, 5)
            try expect(px == [0, 255, 255, 255], "tile-inverted red \(px)")
            return "tile shader inverted the clear: \(px)"
        })
        c.append(check("Metal", "indirect-command-buffer-render-compute", timeout: 90) {
            let dev = try p2Dev()
            // Apple's simulator Metal client (MTLSimDevice) asserts "not supported in the simulator" on
            // newIndirectCommandBuffer: no ICB is made on a simulator device
            let cls = String(describing: type(of: dev as AnyObject))
            if cls.contains("MTLSimDevice") { return "\(cls): indirect command buffers are not supported in the simulator (no ICB made)" }
            let lib = try await p2Lib(dev, """
            struct V { float4 p [[position]]; float4 c; };
            vertex V vs(uint i [[vertex_id]], constant float4 *col [[buffer(0)]]) {
                float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) }; V v; v.p = float4(p[i], 0, 1); v.c = col[0]; return v; }
            fragment float4 fs(V v [[stage_in]]) { return v.c; }
            kernel void inc(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] += 10.0f; }
            """)
            let d = MTLRenderPipelineDescriptor(); d.vertexFunction = try p2Fn(lib, "vs"); d.fragmentFunction = try p2Fn(lib, "fs")
            d.colorAttachments[0].pixelFormat = .rgba8Unorm; d.supportIndirectCommandBuffers = true
            let rpso = try await dev.makeRenderPipelineState(descriptor: d)
            let id = MTLIndirectCommandBufferDescriptor(); id.commandTypes = .draw; id.inheritPipelineState = true; id.inheritBuffers = false
            id.maxVertexBufferBindCount = 1; id.maxFragmentBufferBindCount = 0
            guard let icb = dev.makeIndirectCommandBuffer(descriptor: id, maxCommandCount: 2, options: []) else { throw Fail("no render ICB") }
            let col = p2Buf(dev, [1, 0, 1, 1])
            let rc = icb.indirectRenderCommandAt(0)
            rc.setVertexBuffer(col, offset: 0, at: 0)
            rc.drawPrimitives(.triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1, baseInstance: 0)
            let t = p2Tex(dev, 16, 16)
            let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            let q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer()!, e = cb.makeRenderCommandEncoder(descriptor: rp)!
            e.setRenderPipelineState(rpso); e.useResource(col, usage: .read, stages: .vertex)
            e.executeCommandsInBuffer(icb, range: 0..<1); e.endEncoding()
            // a compute ICB: two dispatches recorded once, executed twice
            let cd = MTLComputePipelineDescriptor(); cd.computeFunction = try p2Fn(lib, "inc"); cd.supportIndirectCommandBuffers = true
            let cpso = try await dev.makeComputePipelineState(descriptor: cd, options: []).0
            let cid = MTLIndirectCommandBufferDescriptor(); cid.commandTypes = .concurrentDispatch; cid.inheritPipelineState = false; cid.inheritBuffers = false
            cid.maxKernelBufferBindCount = 1
            guard let cicb = dev.makeIndirectCommandBuffer(descriptor: cid, maxCommandCount: 1, options: []) else { throw Fail("no compute ICB") }
            let b = p2Buf(dev, [1, 2, 3, 4])
            let cc = cicb.indirectComputeCommandAt(0)
            cc.setComputePipelineState(cpso); cc.setKernelBuffer(b, offset: 0, at: 0)
            cc.concurrentDispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1))
            let ce = cb.makeComputeCommandEncoder()!
            ce.useResource(b, usage: [.read, .write])
            ce.executeCommandsInBuffer(cicb, range: 0..<1)
            ce.memoryBarrier(scope: .buffers)
            ce.executeCommandsInBuffer(cicb, range: 0..<1); ce.endEncoding()
            try await p2Run(cb)
            let px = p2Px(t, 8, 8)
            try expect(px == [255, 0, 255, 255], "ICB draw pixel \(px)")
            try expect(p2Floats(b, 4) == [21, 22, 23, 24], "ICB dispatch x2 \(p2Floats(b, 4))")
            return "render ICB drew \(px), compute ICB ran twice"
        })
        c.append(check("Metal", "residency-set", timeout: 60) {
            let dev = try p2Dev()
            let rd = MTLResidencySetDescriptor(); rd.label = "sdkcov"; rd.initialCapacity = 4
            let sim = String(describing: type(of: dev as AnyObject)).contains("MTLSimDevice")
            let rs: MTLResidencySet
            do { rs = try dev.makeResidencySet(descriptor: rd) } catch {
                // Apple's simulator Metal client answers newResidencySetWithDescriptor with a nil set and no error
                try expect(sim, "newResidencySet refused on a non-simulator device: \(error)")
                return "newResidencySet refused in the simulator (\(error)), as on Apple's"
            }
            try expect(!sim, "a residency set from the simulator device (Apple's simulator refuses with nilError)")
            let data = p2Buf(dev, [3, 4, 5, 6]), out = p2Buf(dev, [0, 0, 0, 0])
            rs.addAllocation(data); rs.addAllocation(out)
            try expect(rs.allocationCount == 2 && rs.containsAllocation(data), "allocations \(rs.allocationCount)")
            rs.commit(); rs.requestResidency()
            let committedSize = rs.allocatedSize
            // a kernel reading through GPU addresses in an argument buffer: the residency set makes them resident
            let lib = try await p2Lib(dev, """
            struct A { device const float *in; device float *out; };
            kernel void k(constant A &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a.out[i] = a.in[i] * 10.0f; }
            """)
            let pso = try await dev.makeComputePipelineState(function: try p2Fn(lib, "k"))
            let ab = dev.makeBuffer(length: 16, options: .storageModeShared)!
            ab.contents().storeBytes(of: data.gpuAddress, toByteOffset: 0, as: UInt64.self)
            ab.contents().storeBytes(of: out.gpuAddress, toByteOffset: 8, as: UInt64.self)
            let q = dev.makeCommandQueue()!
            q.addResidencySet(rs)
            let cb = q.makeCommandBuffer()!
            cb.useResidencySet(rs)
            let e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(pso); e.setBuffer(ab, offset: 0, index: 0)
            e.dispatchThreads(MTLSize(width: 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1)); e.endEncoding()
            try await p2Run(cb)
            try expect(p2Floats(out, 4) == [30, 40, 50, 60], "through the residency set \(p2Floats(out, 4))")
            rs.removeAllocation(out); rs.commit()
            try expect(rs.allocationCount == 1 && !rs.containsAllocation(out), "after remove \(rs.allocationCount)")
            rs.removeAllAllocations(); rs.commit(); rs.endResidency()
            q.removeResidencySet(rs)
            try expect(rs.allocationCount == 0, "after removeAll \(rs.allocationCount)")
            return "residency set \(rs.label ?? "-"): 2 allocations (\(committedSize) B committed), kernel through GPU addresses, removed"
        })
        c.append(check("Metal", "counters-timestamps", timeout: 60) {
            let dev = try p2Dev()
            var cpu0: MTLTimestamp = 0, gpu0: MTLTimestamp = 0
            (cpu0, gpu0) = dev.sampleTimestamps()
            let lib = try await p2Lib(dev, "kernel void k(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { float x = b[i]; for (int j = 0; j < 256; j++) x = x * 1.0001f + 0.5f; b[i] = x; }")
            let pso = try await dev.makeComputePipelineState(function: try p2Fn(lib, "k"))
            let b = dev.makeBuffer(length: 4096 * 4, options: .storageModeShared)!
            let q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer()!
            // a timestamp counter sample buffer at the encoder's start and end where the device can sample there
            var sampled = "no stage-boundary sampling"
            var sb: MTLCounterSampleBuffer?
            let ts = (dev.counterSets ?? []).first { $0.name == MTLCommonCounterSet.timestamp.rawValue }
            let cpd = MTLComputePassDescriptor()
            if let ts, dev.supportsCounterSampling(.atStageBoundary) {
                let sd = MTLCounterSampleBufferDescriptor(); sd.counterSet = ts; sd.sampleCount = 2; sd.storageMode = .shared
                sb = try dev.makeCounterSampleBuffer(descriptor: sd)
                cpd.sampleBufferAttachments[0].sampleBuffer = sb
                cpd.sampleBufferAttachments[0].startOfEncoderSampleIndex = 0
                cpd.sampleBufferAttachments[0].endOfEncoderSampleIndex = 1
            }
            let e = cb.makeComputeCommandEncoder(descriptor: cpd)!
            e.setComputePipelineState(pso); e.setBuffer(b, offset: 0, index: 0)
            e.dispatchThreads(MTLSize(width: 4096, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)); e.endEncoding()
            try await p2Run(cb)
            try expect(cb.gpuEndTime >= cb.gpuStartTime && cb.gpuStartTime > 0, "GPU times \(cb.gpuStartTime) \(cb.gpuEndTime)")
            try expect(cb.kernelEndTime >= cb.kernelStartTime, "kernel times \(cb.kernelStartTime) \(cb.kernelEndTime)")
            var cpu1: MTLTimestamp = 0, gpu1: MTLTimestamp = 0
            (cpu1, gpu1) = dev.sampleTimestamps()
            // Apple's simulator device answers sampleTimestamps with zeros
            let simDev = String(describing: type(of: dev as AnyObject)).contains("MTLSimDevice")
            try expect(simDev ? (cpu0 == 0 && gpu0 == 0 && cpu1 == 0 && gpu1 == 0) : cpu1 > cpu0, "sampleTimestamps \(cpu0)/\(gpu0) -> \(cpu1)/\(gpu1) (simulator: 0)")
            if let sb {
                let d = try sb.resolveCounterRange(0..<2)
                let v = d.map { $0.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)) } } ?? []
                try expect(v.count == 2 && v[1].timestamp >= v[0].timestamp, "sampled timestamps \(v.map(\.timestamp))")
                sampled = "stage-boundary timestamps \(v.map(\.timestamp))"
            }
            return "GPU \(Int((cb.gpuEndTime - cb.gpuStartTime) * 1e6)) us, gpu ts \(gpu0) -> \(gpu1), \(sampled), counter sets [\((dev.counterSets ?? []).map(\.name).joined(separator: ","))]"
        })
        c.append(check("Metal", "capture-manager-gputrace", timeout: 60) {
            let dev = try p2Dev()
            let cm = MTLCaptureManager.shared()
            let file = cm.supportsDestination(.gpuTraceDocument), tools = cm.supportsDestination(.developerTools)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-\(UUID().uuidString).gputrace")
            defer { try? FileManager.default.removeItem(at: url) }
            let d = MTLCaptureDescriptor(); d.captureObject = dev; d.destination = .gpuTraceDocument; d.outputURL = url
            var started = "started"
            do { try cm.startCapture(with: d) } catch { started = "refused \((error as NSError).domain) \((error as NSError).code)" }
            let q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer()!
            cb.makeBlitCommandEncoder()!.endEncoding()
            try await p2Run(cb)
            let capturing = cm.isCapturing
            if capturing { cm.stopCapture() }
            let wrote = FileManager.default.fileExists(atPath: url.path)
            // a scope: begin/end must work whether or not a capture is running
            let scope = cm.makeCaptureScope(device: dev); scope.label = "sdkcov"; scope.begin(); scope.end()
            // Apple's simulator: no capture destinations, startCapture refused with MTLCaptureError.notSupported (1)
            try expect(!file && !tools && started == "refused \(MTLCaptureErrorDomain) 1" && !capturing && !wrote, "gpuTraceDocument \(file), developerTools \(tools), start \(started), capturing \(capturing), file \(wrote)")
            return "gpuTraceDocument \(file), developerTools \(tools), start \(started), capturing \(capturing), file \(wrote)"
        })
        c.append(check("Metal", "shader-logging-logstate", timeout: 90) {
            let dev = try p2Dev()
            let ld = MTLLogStateDescriptor(); ld.level = .debug; ld.bufferSize = 64 * 1024
            let ls: MTLLogState
            do { ls = try dev.makeLogState(descriptor: ld) } catch {
                // Apple's simulator: newLogState refused with MTLLogStateError.invalid (2)
                try expect((error as NSError).domain == MTLLogStateErrorDomain && (error as NSError).code == 2, "log state refused with \(error)")
                return "log state refused: \((error as NSError).domain) \((error as NSError).code), as in Apple's simulator"
            }
            let got = P2Lines()
            ls.addLogHandler { _, _, _, msg in got.add(msg) }
            let o = MTLCompileOptions(); o.enableLogging = true; o.languageVersion = .version3_2
            let lib: MTLLibrary
            do {
                lib = try await p2Lib(dev, "#include <metal_logging>\nkernel void k(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i == 3) os_log_default.log(\"sdkcov shader %d\", int(b[i])); b[i] += 1; }", o)
            } catch { return "logging source refused: \((error as NSError).code) \((error as NSError).localizedDescription.prefix(100))" }
            let pso = try await dev.makeComputePipelineState(function: try p2Fn(lib, "k"))
            let b = p2Buf(dev, [0, 1, 2, 42])
            let cbd = MTLCommandBufferDescriptor(); cbd.logState = ls
            let q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer(descriptor: cbd)!, e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(pso); e.setBuffer(b, offset: 0, index: 0)
            e.dispatchThreads(MTLSize(width: 4, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1)); e.endEncoding()
            try await p2Run(cb)
            try await Task.sleep(for: .milliseconds(300))
            try expect(p2Floats(b, 4) == [1, 2, 3, 43], "kernel \(p2Floats(b, 4))")
            return "shader log lines: \(got.all)"
        })
        c.append(check("Metal", "rasterization-rate-map", timeout: 60) {
            let dev = try p2Dev()
            let ok = dev.supportsRasterizationRateMap(layerCount: 1)
            guard ok else { return "supportsRasterizationRateMap(1) false: no rate map is made (Apple's simulator GPU)" }
            let layer = MTLRasterizationRateLayerDescriptor(horizontal: [1, 0.5], vertical: [1, 0.25])
            let d = MTLRasterizationRateMapDescriptor(screenSize: MTLSize(width: 256, height: 256, depth: 0), layer: layer)
            let m = dev.makeRasterizationRateMap(descriptor: d)
            guard ok else {
                try expect(m == nil, "supportsRasterizationRateMap false but a map was made")
                return "supportsRasterizationRateMap(1) false, newRasterizationRateMap nil"
            }
            guard let m else { throw Fail("no rate map") }
            let ps = m.physicalSize(layer: 0)
            try expect(ps.width < 256 && ps.height < 256 && ps.width > 0, "physical size \(ps)")
            let sp = m.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: 200, y: 200), layer: 0)
            try expect(sp.x < 200 && sp.y < 200, "mapped \(sp)")
            return "physical \(ps.width)x\(ps.height) for 256x256, (200,200) -> (\(sp.x),\(sp.y))"
        })
        c.append(check("MetalPerformancePrimitives", "tensor-matmul-shader", timeout: 90) {
            let dev = try p2Dev()
            // MetalPerformancePrimitives is a Metal-shading-language header library (Metal 4 tensors); the simulator
            // SDK has no MTLTensor, so the runtime compiler answers for the include as Apple's simulator does
            let o = MTLCompileOptions(); o.languageVersion = MTLLanguageVersion(rawValue: (4 << 16)) ?? .version3_2
            let src = """
            #include <metal_tensor>
            #include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
            using namespace mpp::tensor_ops;
            kernel void mm(device half *a [[buffer(0)]], device half *b [[buffer(1)]], device float *c [[buffer(2)]]) {
                auto A = tensor<device half, dextents<int32_t, 2>, tensor_inline>(a, dextents<int32_t, 2>(16, 16));
                auto B = tensor<device half, dextents<int32_t, 2>, tensor_inline>(b, dextents<int32_t, 2>(16, 16));
                auto C = tensor<device float, dextents<int32_t, 2>, tensor_inline>(c, dextents<int32_t, 2>(16, 16));
                constexpr auto d = matmul2d_descriptor(16, 16, 16, false, false, false);
                matmul2d<d, execution_simdgroups<1>> op; op.run(A, B, C);
            }
            """
            do {
                let lib = try await p2Lib(dev, src, o)
                let pso = try await dev.makeComputePipelineState(function: try p2Fn(lib, "mm"))
                let n = 256
                let a = dev.makeBuffer(bytes: (0..<n).map { Float16($0 / 16 == $0 % 16 ? 1 : 0) }, length: n * 2, options: .storageModeShared)!  // identity
                let b = dev.makeBuffer(bytes: (0..<n).map { Float16($0 % 7) }, length: n * 2, options: .storageModeShared)!
                let cbuf = dev.makeBuffer(length: n * 4, options: .storageModeShared)!; memset(cbuf.contents(), 0, n * 4)
                let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
                e.setComputePipelineState(pso); e.setBuffer(a, offset: 0, index: 0); e.setBuffer(b, offset: 0, index: 1); e.setBuffer(cbuf, offset: 0, index: 2)
                e.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pso.threadExecutionWidth, height: 1, depth: 1)); e.endEncoding()
                try await p2Run(cb)
                let r = p2Floats(cbuf, n)
                try expect((0..<n).allSatisfy { r[$0] == Float($0 % 7) }, "I x B: \(Array(r.prefix(8)))")
                throw Fail("tensor matmul2d compiled and ran (I x B exact) but Apple's simulator compiler has no MetalPerformancePrimitives headers")
            } catch let e as NSError where e.domain == MTLLibraryErrorDomain {
                // Apple's simulator: "'MetalPerformancePrimitives/MetalPerformancePrimitives.h' file not found"
                try expect(e.localizedDescription.contains("MetalPerformancePrimitives") && e.localizedDescription.contains("not found"), "compile error \(e.localizedDescription.prefix(200))")
                return "compile refused (\(e.code)): \(e.localizedDescription.split(separator: "\n").first.map(String.init)?.prefix(140) ?? "")"
            }
        })
        #endif
        return c
    }
}
