// sdkcov P2: MetalPerformanceShaders depth (CNN inference layers, image kernels, NDArray / matrix kernels) and an
// MPSGraph built and compiled without a device (running one aborts in Apple's simulator: MPSGraphDevice).
import Foundation
#if canImport(MetalPerformanceShaders)
import Metal
import MetalPerformanceShaders
#endif
#if canImport(MetalPerformanceShadersGraph)
import MetalPerformanceShadersGraph
#endif

#if canImport(MetalPerformanceShaders)
/// float32 weights for an MPSCNNConvolution / FullyConnected layer
final class P2ConvData: NSObject, MPSCNNConvolutionDataSource {
    let desc: MPSCNNConvolutionDescriptor
    var w: [Float], b: [Float]
    init(_ kw: Int, _ kh: Int, _ inC: Int, _ outC: Int, weights: [Float], bias: [Float]) {
        desc = MPSCNNConvolutionDescriptor(kernelWidth: kw, kernelHeight: kh, inputFeatureChannels: inC, outputFeatureChannels: outC)
        w = weights; b = bias
    }
    func dataType() -> MPSDataType { .float32 }
    func descriptor() -> MPSCNNConvolutionDescriptor { desc }
    func weights() -> UnsafeMutableRawPointer { w.withUnsafeMutableBytes { $0.baseAddress! } }
    func biasTerms() -> UnsafeMutablePointer<Float>? { b.withUnsafeMutableBufferPointer { $0.baseAddress } }
    func load() -> Bool { true }
    func purge() {}
    func label() -> String? { "sdkcov" }
    func copy(with zone: NSZone? = nil) -> Any { P2ConvData(desc.kernelWidth, desc.kernelHeight, desc.inputFeatureChannels, desc.outputFeatureChannels, weights: w, bias: b) }
}
func p2MPSImage(_ dev: MTLDevice, _ w: Int, _ h: Int, _ ch: Int, _ v: [Float]?) -> MPSImage {
    let d = MPSImageDescriptor(channelFormat: .float32, width: w, height: h, featureChannels: ch)
    d.storageMode = .shared
    let img = MPSImage(device: dev, imageDescriptor: d)
    if var v { v.withUnsafeMutableBytes { img.writeBytes($0.baseAddress!, dataLayout: .featureChannelsxHeightxWidth, imageIndex: 0) } }
    return img
}
func p2Read(_ img: MPSImage) -> [Float] {
    var out = [Float](repeating: -1, count: img.width * img.height * img.featureChannels)
    out.withUnsafeMutableBytes { img.readBytes($0.baseAddress!, dataLayout: .featureChannelsxHeightxWidth, imageIndex: 0) }
    return out
}
func p2RGBA(_ dev: MTLDevice, _ w: Int, _ h: Int, _ px: (Int, Int) -> [UInt8], usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    d.usage = usage; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    var b = [UInt8](); for y in 0..<h { for x in 0..<w { b += px(x, y) } }
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: b, bytesPerRow: w * 4)
    return t
}
func p2RGBAPx(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 4)
    t.getBytes(&p, bytesPerRow: t.width * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return p
}
#endif

extension Registry {
    static var p2_mps: [Check] {
        var c: [Check] = []
        #if canImport(MetalPerformanceShaders)
        c.append(check("MetalPerformanceShaders", "cnn-conv-pool-fullyconnected", timeout: 90) {
            let dev = try p2Dev()
            try skipIf(!MPSSupportsMTLDevice(dev), "MPS does not support this MTLDevice")
            // 4x4x1 input 0..15 -> 1x1 conv (2x + 1) -> ReLU -> 2x2 max pool, stride 2 -> fully connected (sum of the 4)
            let input = p2MPSImage(dev, 4, 4, 1, (0..<16).map(Float.init))
            let conv = MPSCNNConvolution(device: dev, weights: P2ConvData(1, 1, 1, 1, weights: [2], bias: [1]))
            let relu = MPSCNNNeuronReLU(device: dev, a: 0)
            let pool = MPSCNNPoolingMax(device: dev, kernelWidth: 2, kernelHeight: 2, strideInPixelsX: 2, strideInPixelsY: 2)
            pool.offset = MPSOffset(x: 1, y: 1, z: 0)
            let fc = MPSCNNFullyConnected(device: dev, weights: P2ConvData(2, 2, 1, 2, weights: [1, 1, 1, 1, 1, 0, 0, 0], bias: [0, 100]))
            let a = p2MPSImage(dev, 4, 4, 1, nil), r = p2MPSImage(dev, 4, 4, 1, nil), p = p2MPSImage(dev, 2, 2, 1, nil), f = p2MPSImage(dev, 1, 1, 2, nil)
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!
            conv.encode(commandBuffer: cb, sourceImage: input, destinationImage: a)
            relu.encode(commandBuffer: cb, sourceImage: a, destinationImage: r)
            pool.encode(commandBuffer: cb, sourceImage: r, destinationImage: p)
            fc.encode(commandBuffer: cb, sourceImage: p, destinationImage: f)
            try await p2Run(cb)
            let av = p2Read(a), pv = p2Read(p), fv = p2Read(f)
            try expect(av == (0..<16).map { Float($0 * 2 + 1) }, "conv \(av)")
            try expect(pv == [11, 15, 27, 31], "max pool \(pv)")
            try expect(fv == [84, 111], "fully connected \(fv)")
            return "conv \(av.prefix(4))..., pool \(pv), fc \(fv)"
        })
        c.append(check("MetalPerformanceShaders", "image-histogram-sobel-lanczos-morphology", timeout: 90) {
            let dev = try p2Dev()
            try skipIf(!MPSSupportsMTLDevice(dev), "MPS does not support this MTLDevice")
            // left half black, right half white (8x8)
            let src = p2RGBA(dev, 8, 8) { x, _ in x < 4 ? [0, 0, 0, 255] : [255, 255, 255, 255] }
            var info = MPSImageHistogramInfo(numberOfHistogramEntries: 256, histogramForAlpha: false,
                                             minPixelValue: SIMD4<Float>(0, 0, 0, 0), maxPixelValue: SIMD4<Float>(1, 1, 1, 1))
            let hist = MPSImageHistogram(device: dev, histogramInfo: &info)
            let hb = dev.makeBuffer(length: hist.histogramSize(forSourceFormat: .rgba8Unorm), options: .storageModeShared)!
            let sob = MPSImageSobel(device: dev)
            let sobOut = p2RGBA(dev, 8, 8) { _, _ in [9, 9, 9, 9] }
            let scaled = p2RGBA(dev, 4, 4) { _, _ in [0, 0, 0, 0] }
            let lan = MPSImageLanczosScale(device: dev)
            let dot = p2RGBA(dev, 8, 8) { x, y in x == 4 && y == 4 ? [255, 255, 255, 255] : [0, 0, 0, 255] }
            let dil = p2RGBA(dev, 8, 8) { _, _ in [0, 0, 0, 0] }
            let amax = MPSImageAreaMax(device: dev, kernelWidth: 3, kernelHeight: 3)
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!
            hist.encode(to: cb, sourceTexture: src, histogram: hb, histogramOffset: 0)
            sob.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: sobOut)
            lan.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: scaled)
            amax.encode(commandBuffer: cb, sourceTexture: dot, destinationTexture: dil)
            try await p2Run(cb)
            let h = hb.contents().assumingMemoryBound(to: UInt32.self)
            try expect(h[0] == 32 && h[255] == 32 && h[256] == 32 && h[511] == 32 && h[128] == 0, "histogram R[0] \(h[0]) R[255] \(h[255]) G[0] \(h[256])")
            let flat = p2RGBAPx(sobOut, 1, 4), edge = p2RGBAPx(sobOut, 4, 4)
            try expect(flat[0] == 0 && edge[0] > 100, "sobel flat \(flat) edge \(edge)")
            let l0 = p2RGBAPx(scaled, 0, 2), l3 = p2RGBAPx(scaled, 3, 2)
            try expect(l0[0] < 20 && l3[0] > 235, "lanczos 8->4 \(l0) \(l3)")
            let d1 = p2RGBAPx(dil, 3, 5), d2 = p2RGBAPx(dil, 6, 4)
            try expect(d1[0] == 255 && d2[0] == 0, "3x3 dilation \(d1) \(d2)")
            return "histogram 32/32, sobel edge \(edge[0]), lanczos \(l0[0])/\(l3[0]), dilation ok"
        })
        c.append(check("MetalPerformanceShaders", "ndarray-matmul-topk-softmax", timeout: 90) {
            let dev = try p2Dev()
            try skipIf(!MPSSupportsMTLDevice(dev), "MPS does not support this MTLDevice")
            let q = dev.makeCommandQueue()!
            // NDArray: 2x3 * 3x2 (shape slowest dimension first: [rows, columns])
            func nd(_ cols: Int, _ rows: Int, _ v: [Float]?) -> MPSNDArray {
                let d = MPSNDArrayDescriptor(dataType: .float32, shape: [NSNumber(value: rows), NSNumber(value: cols)])
                let a = MPSNDArray(device: dev, descriptor: d)
                if var v { v.withUnsafeMutableBytes { a.writeBytes($0.baseAddress!, strideBytes: nil) } }
                return a
            }
            let a = nd(3, 2, [1, 2, 3, 4, 5, 6]), b = nd(2, 3, [7, 8, 9, 10, 11, 12]), r = nd(2, 2, nil)
            let mm = MPSNDArrayMatrixMultiplication(device: dev, sourceCount: 2)
            let cb = q.makeCommandBuffer()!
            mm.encode(to: cb, sourceArrays: [a, b], destinationArray: r)
            // softmax and top-2 of one row
            let rowD = MPSMatrixDescriptor(rows: 1, columns: 4, rowBytes: 16, dataType: .float32)
            let inM = MPSMatrix(buffer: p2Buf(dev, [1, 4, 2, 3]), descriptor: rowD), smM = MPSMatrix(buffer: p2Buf(dev, [0, 0, 0, 0]), descriptor: rowD)
            MPSMatrixSoftMax(device: dev).encode(commandBuffer: cb, inputMatrix: inM, resultMatrix: smM)
            let idxB = dev.makeBuffer(length: 16, options: .storageModeShared)!, valB = p2Buf(dev, [0, 0, 0, 0])
            let idxM = MPSMatrix(buffer: idxB, descriptor: MPSMatrixDescriptor(rows: 1, columns: 2, rowBytes: 16, dataType: .uInt32))
            let valM = MPSMatrix(buffer: valB, descriptor: MPSMatrixDescriptor(rows: 1, columns: 2, rowBytes: 16, dataType: .float32))
            MPSMatrixFindTopK(device: dev, numberOfTopKValues: 2).encode(commandBuffer: cb, inputMatrix: inM, resultIndexMatrix: idxM, resultValueMatrix: valM)
            try await p2Run(cb)
            var out = [Float](repeating: 0, count: 4)
            out.withUnsafeMutableBytes { r.readBytes($0.baseAddress!, strideBytes: nil) }
            try expect(out == [58, 64, 139, 154], "NDArray matmul \(out)")
            let sm = p2Floats(smM.data, 4)
            let e = [1, 4, 2, 3].map { exp(Float($0)) }, s = e.reduce(0, +)
            try expect(zip(sm, e).allSatisfy { abs($0 - $1 / s) < 1e-4 }, "softmax \(sm)")
            let idx = Array(UnsafeBufferPointer(start: idxB.contents().assumingMemoryBound(to: UInt32.self), count: 2)), vals = p2Floats(valB, 2)
            try expect(idx == [1, 3] && vals == [4, 3], "top-2 \(idx) \(vals)")
            return "NDArray matmul \(out), softmax max \(sm[1]), top-2 \(idx)"
        })
        #endif
        #if canImport(MetalPerformanceShadersGraph)
        c.append(check("MetalPerformanceShadersGraph", "build-compile-no-device", timeout: 90) {
            // building and compiling a graph needs no MPSGraphDevice (whose init aborts in Apple's simulator)
            let g = MPSGraph()
            let x = g.placeholder(shape: [2, 2], dataType: .float32, name: "x")
            let w = g.constant(Data(bytes: [Float](arrayLiteral: 1, 2, 3, 4), count: 16), shape: [2, 2], dataType: .float32)
            let y = g.reLU(with: g.addition(g.matrixMultiplication(primary: x, secondary: w, name: "mm"), g.constant(-5, dataType: .float32), name: nil), name: "relu")
            let sm = g.softMax(with: y, axis: 1, name: "sm")
            try expect(y.shape == [2, 2] && sm.dataType == .float32, "shapes \(String(describing: y.shape))")
            let ops = [x, w, y, sm].compactMap { $0.operation.name }
            let gd = MPSGraphCompilationDescriptor(); gd.optimizationLevel = .level0
            let exe = g.compile(with: nil, feeds: [x: MPSGraphShapedType(shape: [2, 2], dataType: .float32)], targetTensors: [sm], targetOperations: nil, compilationDescriptor: gd)
            try expect((exe.feedTensors ?? []).count == 1 && (exe.targetTensors ?? []).count == 1, "executable feeds \(String(describing: exe.feedTensors)) targets \(String(describing: exe.targetTensors))")
            return "graph ops \(ops), compiled executable (1 feed, 1 target)"
        })
        #endif
        return c
    }
}
