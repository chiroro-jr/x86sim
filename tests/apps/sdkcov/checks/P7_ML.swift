// sdkcov P7: machine learning, vision, speech and language depth. Core ML (MLModelAsset from spec data, batch / async
// predictions, MLComputePlan, an updatable k-nearest-neighbours classifier trained on the device with MLUpdateTask, the
// precompiled .mlmodelc embedded below for watchOS which cannot compile), CreateMLComponents classifier -> Core ML export,
// NaturalLanguage (gazetteers, hypotheses, embeddings / contextual embedding assets), SoundAnalysis on a file, Speech
// (recognition of synthesized speech, SpeechAnalyzer), Vision (image registration, horizon, saliency, faces / poses /
// classification as Apple's simulator answers them), VisionKit Live Text, MediaIntelligence, SuggestedActions and
// SensitiveContentAnalysis.
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(CoreML)
import CoreML
#endif
#if canImport(CreateMLComponents)
import CreateMLComponents
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if canImport(SoundAnalysis)
import SoundAnalysis
#endif
#if canImport(Speech)
import Speech
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(VisionKit) && (os(iOS) || os(visionOS))
import VisionKit
#endif
#if canImport(MediaIntelligence) && (os(iOS) || os(visionOS))
import MediaIntelligence
#endif
#if canImport(SuggestedActions) && os(iOS)
import SuggestedActions
#endif
#if canImport(SensitiveContentAnalysis) && (os(iOS) || os(visionOS))
import SensitiveContentAnalysis
#endif

#if canImport(CoreML)
/// an updatable k-nearest-neighbours classifier (Core ML 3 spec): input x float32[2], output label (string), samples
/// (0,0) -> "a", (10,10) -> "b", k = 1 (allowed 1...5), uniform weighting, linear index, squared euclidean distance
func p7KNNSpec() -> Data {
    func floats(_ f: Int, _ xs: [Float]) -> PB { var p = PB(); p.tag(f, 2); p.varint(UInt64(xs.count * 4)); for x in xs { withUnsafeBytes(of: x.bitPattern.littleEndian) { p.d.append(contentsOf: $0) } }; return p }
    var arr = PB(); arr.int64s(1, [2]); arr.int(2, 65568)              // ArrayFeatureType [2] FLOAT32
    var tIn = PB(); tIn.msg(5, arr)
    var tStr = PB(); tStr.msg(3, PB())                                  // StringFeatureType
    var fIn = PB(); fIn.str(1, "x"); fIn.msg(3, tIn)
    var fLab = PB(); fLab.str(1, "label"); fLab.msg(3, tStr)
    var desc = PB(); desc.msg(1, fIn); desc.msg(10, fLab); desc.str(11, "label"); desc.msg(50, fIn); desc.msg(50, fLab)
    var idx = PB(); idx.int(1, 2); idx.msg(2, floats(1, [0, 0])); idx.msg(2, floats(1, [10, 10])); idx.msg(100, PB()); idx.msg(200, PB())
    var range = PB(); range.int(1, 1); range.int(2, 5)
    var k = PB(); k.int(1, 1); k.msg(10, range)
    var labels = PB(); labels.str(1, "a"); labels.str(1, "b")
    var knn = PB(); knn.msg(1, idx); knn.msg(3, k); knn.msg(100, labels); knn.msg(200, PB())
    var m = PB(); m.int(1, 4); m.msg(2, desc); m.int(10, 1); m.msg(404, knn)
    return m.d
}
/// Model { specificationVersion 4, x float32[2] -> y float32[1], neuralNetwork { innerProduct "dense" W [2 3] b 0.5 } }
func p7NNSpec() -> Data {
    func floats(_ xs: [Float]) -> PB { var p = PB(); p.tag(1, 2); p.varint(UInt64(xs.count * 4)); for x in xs { withUnsafeBytes(of: x.bitPattern.littleEndian) { p.d.append(contentsOf: $0) } }; return p }
    var ain = PB(); ain.int64s(1, [2]); ain.int(2, 65568)
    var aout = PB(); aout.int64s(1, [1]); aout.int(2, 65568)
    var tIn = PB(); tIn.msg(5, ain); var tOut = PB(); tOut.msg(5, aout)
    var fIn = PB(); fIn.str(1, "x"); fIn.msg(3, tIn)
    var fOut = PB(); fOut.str(1, "y"); fOut.msg(3, tOut)
    var desc = PB(); desc.msg(1, fIn); desc.msg(10, fOut)
    var ip = PB(); ip.int(1, 2); ip.int(2, 1); ip.int(10, 1); ip.msg(20, floats([2, 3])); ip.msg(21, floats([0.5]))
    var layer = PB(); layer.str(1, "dense"); layer.str(2, "x"); layer.str(3, "y"); layer.msg(140, ip)
    var net = PB(); net.msg(1, layer)
    var m = PB(); m.int(1, 4); m.msg(2, desc); m.msg(500, net)
    return m.d
}
/// the same model compiled by Xcode's coremlcompiler (watchOS has no on-device compiler): path -> base64
let p7KNNCompiled: [String: String] = [
    "analytics/coremldata.bin": "FAAAAAAAAABTcGVjaWZpY2F0aW9uRGV0YWlscwIAAAAAAAAACQAAAAAAAABtb2RlbEhhc2gsAAAAAAAAAFFGUE16YTlYTEVpcHV4WjUwTEUyRXpTckZLWjBibFpzQm9DU1BnTkZjRzQ9CQAAAAAAAABtb2RlbE5hbWUDAAAAAAAAAGtubg==",
    "coremldata.bin": "lAEAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAAAAAAAAbm90cmVlc3lldAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAARgAAAAAAAAAKDgoBeBoJKgcKAQIQoIAEUgsKBWxhYmVsGgIaAFoFbGFiZWySAw4KAXgaCSoHCgECEKCABJIDCwoFbGFiZWwaAhoAogYAAgAAAAQAAAAAAAAAAAAAAAAAAAAAACBBAAAgQWQAAAAAAAAAAgAAAAAAAAABAAAAAAAAAGEBAAAAAAAAAGIAAAAAAAAAAAAAAAAAAAAA",
    "metadata.json": "WwogIHsKICAgICJtZXRhZGF0YU91dHB1dFZlcnNpb24iIDogIjMuMCIsCiAgICAib3V0cHV0U2NoZW1hIiA6IFsKICAgICAgewogICAgICAgICJpc09wdGlvbmFsIiA6ICIwIiwKICAgICAgICAiZm9ybWF0dGVkVHlwZSIgOiAiU3RyaW5nIiwKICAgICAgICAidHlwZSIgOiAiU3RyaW5nIiwKICAgICAgICAibmFtZSIgOiAibGFiZWwiLAogICAgICAgICJzaG9ydERlc2NyaXB0aW9uIiA6ICIiCiAgICAgIH0KICAgIF0sCiAgICAibW9kZWxQYXJhbWV0ZXJzIiA6IFsKICAgICAgewogICAgICAgICJkZWZhdWx0VmFsdWUiIDogIjEiLAogICAgICAgICJzY29wZSIgOiAiIiwKICAgICAgICAiYWxsb3dlZFJhbmdlIiA6ICJbMSwgNV0iLAogICAgICAgICJuYW1lIiA6ICJudW1iZXJPZk5laWdoYm9ycyIsCiAgICAgICAgImRhdGFUeXBlIiA6ICJJbnQ2NCIsCiAgICAgICAgInNob3J0RGVzY3JpcHRpb24iIDogIk51bWJlciBvZiBuZWlnaGJvcnMgdG8gdXNlIGZvciBwcmVkaWN0aW9uIgogICAgICB9CiAgICBdLAogICAgInNwZWNpZmljYXRpb25WZXJzaW9uIiA6IDQsCiAgICAidXBkYXRlUGFyYW1ldGVycyIgOiBbCgogICAgXSwKICAgICJpc1VwZGF0YWJsZSIgOiAiMSIsCiAgICAic3RhdGVTY2hlbWEiIDogWwoKICAgIF0sCiAgICAiYXZhaWxhYmlsaXR5IiA6IHsKICAgICAgIm1hY09TIiA6ICIxMC4xNSIsCiAgICAgICJ0dk9TIiA6ICIxMy4wIiwKICAgICAgInZpc2lvbk9TIiA6ICIxLjAiLAogICAgICAid2F0Y2hPUyIgOiAiNi4wIiwKICAgICAgImlPUyIgOiAiMTMuMCIsCiAgICAgICJtYWNDYXRhbHlzdCIgOiAiMTMuMCIKICAgIH0sCiAgICAibW9kZWxUeXBlIiA6IHsKICAgICAgIm5hbWUiIDogIk1MTW9kZWxUeXBlX2tOZWFyZXN0TmVpZ2hib3JzQ2xhc3NpZmllciIKICAgIH0sCiAgICAiaW5wdXRTY2hlbWEiIDogWwogICAgICB7CiAgICAgICAgImhhc1NoYXBlRmxleGliaWxpdHkiIDogIjAiLAogICAgICAgICJpc09wdGlvbmFsIiA6ICIwIiwKICAgICAgICAiZGF0YVR5cGUiIDogIkZsb2F0MzIiLAogICAgICAgICJmb3JtYXR0ZWRUeXBlIiA6ICJNdWx0aUFycmF5IChGbG9hdDMyIDIpIiwKICAgICAgICAic2hvcnREZXNjcmlwdGlvbiIgOiAiIiwKICAgICAgICAic2hhcGUiIDogIlsyXSIsCiAgICAgICAgIm5hbWUiIDogIngiLAogICAgICAgICJ0eXBlIiA6ICJNdWx0aUFycmF5IgogICAgICB9CiAgICBdLAogICAgImNsYXNzTGFiZWxzIiA6IFsKICAgICAgImEiLAogICAgICAiYiIKICAgIF0sCiAgICAiZ2VuZXJhdGVkQ2xhc3NOYW1lIiA6ICJrbm4iLAogICAgInVzZXJEZWZpbmVkTWV0YWRhdGEiIDogewoKICAgIH0sCiAgICAidHJhaW5pbmdJbnB1dFNjaGVtYSIgOiBbCiAgICAgIHsKICAgICAgICAiaGFzU2hhcGVGbGV4aWJpbGl0eSIgOiAiMCIsCiAgICAgICAgImlzT3B0aW9uYWwiIDogIjAiLAogICAgICAgICJkYXRhVHlwZSIgOiAiRmxvYXQzMiIsCiAgICAgICAgImZvcm1hdHRlZFR5cGUiIDogIk11bHRpQXJyYXkgKEZsb2F0MzIgMikiLAogICAgICAgICJzaG9ydERlc2NyaXB0aW9uIiA6ICIiLAogICAgICAgICJzaGFwZSIgOiAiWzJdIiwKICAgICAgICAibmFtZSIgOiAieCIsCiAgICAgICAgInR5cGUiIDogIk11bHRpQXJyYXkiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiaXNPcHRpb25hbCIgOiAiMCIsCiAgICAgICAgImZvcm1hdHRlZFR5cGUiIDogIlN0cmluZyIsCiAgICAgICAgInR5cGUiIDogIlN0cmluZyIsCiAgICAgICAgIm5hbWUiIDogImxhYmVsIiwKICAgICAgICAic2hvcnREZXNjcmlwdGlvbiIgOiAiIgogICAgICB9CiAgICBdLAogICAgIm1ldGhvZCIgOiAicHJlZGljdCIKICB9Cl0=",
    "modelParameters/coremldata.bin": "AAAAAAAAAAA=",
    "modelParameters/numberOfNeighbors/coremldata.bin": "CAFSBAgBEAU=",
    "updateParameters/coremldata.bin": "AAAAAAAAAAA=",
]
#endif

/// float32 [2] input
#if canImport(CoreML)
func p7X(_ a: Float, _ b: Float) throws -> MLDictionaryFeatureProvider {
    let x = try MLMultiArray(shape: [2], dataType: .float32); x[0] = NSNumber(value: a); x[1] = NSNumber(value: b)
    return try MLDictionaryFeatureProvider(dictionary: ["x": x])
}
func p7Dir(_ name: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: d); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
/// the updatable KNN model as a compiled .mlmodelc: compiled here, or (watchOS) written from the embedded files
func p7KNNModelC() async throws -> URL {
    let dir = try p7Dir("sdkcov-p7-knn")
    #if os(watchOS)
    let mc = dir.appendingPathComponent("knn.mlmodelc", isDirectory: true)
    for (p, b64) in p7KNNCompiled {
        let u = mc.appendingPathComponent(p)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = Data(base64Encoded: b64) else { throw Fail("bad embedded \(p)") }
        try d.write(to: u)
    }
    return mc
    #else
    let src = dir.appendingPathComponent("knn.mlmodel"); try p7KNNSpec().write(to: src)
    let tmp = try await MLModel.compileModel(at: src)
    let mc = dir.appendingPathComponent("knn.mlmodelc", isDirectory: true)
    try FileManager.default.moveItem(at: tmp, to: mc)
    return mc
    #endif
}
#endif

/// speech synthesized to a 16 kHz mono file (AVSpeechSynthesizer.write)
func p7SpeechFile(_ text: String, _ url: URL) async throws -> Double {
    let syn = AVSpeechSynthesizer()
    let u = AVSpeechUtterance(string: text); u.voice = AVSpeechSynthesisVoice(language: "en-US")
    try? FileManager.default.removeItem(at: url)
    let box = P7Box<Result<Double, Error>>()
    var file: AVAudioFile?
    var frames = 0
    syn.write(u) { b in
        guard let p = b as? AVAudioPCMBuffer else { return }
        if p.frameLength == 0 { box.set(.success(Double(frames) / p.format.sampleRate)); return }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: p.format.settings, commonFormat: p.format.commonFormat, interleaved: p.format.isInterleaved) }
            try file!.write(from: p); frames += Int(p.frameLength)
        } catch { box.set(.failure(error)) }
    }
    guard let r = await box.wait(60) else { throw Fail("speech synthesis did not finish in 60 s") }
    file = nil
    return try r.get()
}

/// a white image with a black square at (x, y)
func p7Square(_ w: Int, _ h: Int, x: Int, y: Int, side: Int = 40) -> CGImage {
    let c = bitmap(w, h)
    c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: x, y: y, width: side, height: side))
    c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: x + side + 10, y: y + 5, width: side / 2, height: side / 2))
    return c.makeImage()!
}

extension Registry {
    static var p7_ml: [Check] {
        var c: [Check] = []
        // MARK: Core ML
        #if canImport(CoreML) && !os(watchOS)
        c.append(check("CoreML", "model-asset-batch-async-compute-plan", timeout: 90) {
            // MLModelAsset straight from spec bytes (no compile step), batch and async predictions, the compute plan
            let asset = try MLModelAsset(specification: linearModelSpec())
            let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuOnly; cfg.modelDisplayName = "sdkcov linear"
            let m = try await MLModel.load(asset: asset, configuration: cfg)
            try expect(m.modelDescription.inputDescriptionsByName["x"]?.multiArrayConstraint?.shape == [2], "input description")
            let xs: [(Double, Double)] = [(0, 0), (1, 1), (2, -1)]
            let batch = try MLArrayBatchProvider(array: xs.map { p in
                let a = try MLMultiArray(shape: [2], dataType: .double); a[0] = NSNumber(value: p.0); a[1] = NSNumber(value: p.1)
                return try MLDictionaryFeatureProvider(dictionary: ["x": a]) as MLFeatureProvider
            })
            let out = try await m.predictions(from: batch, options: MLPredictionOptions())
            let ys = (0..<out.count).map { out.features(at: $0).featureValue(for: "y")?.doubleValue ?? .nan }
            try expect(ys == [0.5, 5.5, 1.5], "batch \(ys)")
            // concurrent async predictions
            let par = try await withThrowingTaskGroup(of: Double.self) { g in
                for i in 0..<8 { g.addTask {
                    let a = try MLMultiArray(shape: [2], dataType: .double); a[0] = NSNumber(value: i); a[1] = 0
                    return try await m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": a])).featureValue(for: "y")!.doubleValue
                } }
                var s = 0.0; for try await y in g { s += y }; return s
            }
            try expect(par == 2 * 28 + 8 * 0.5, "async sum \(par)")
            // a GLM has no compute plan (Apple: "model is not supported"); a one-layer neural network has one
            var glmPlan = "?"
            do { _ = try await MLComputePlan.load(asset: asset, configuration: cfg); glmPlan = "made" } catch { glmPlan = "\(p7Err(error))" }
            let dir = try p7Dir("sdkcov-p7-plan")
            let src = dir.appendingPathComponent("nn.mlmodel"); try p7NNSpec().write(to: src)
            let compiled = try await MLModel.compileModel(at: src)
            defer { try? FileManager.default.removeItem(at: compiled) }
            let nn = try await MLModel.load(contentsOf: compiled, configuration: cfg)
            let x = try MLMultiArray(shape: [2], dataType: .float32); x[0] = 1; x[1] = 2
            let y = try await nn.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": x])).featureValue(for: "y")?.multiArrayValue?[0].floatValue
            try expect(y.map { abs($0 - 8.5) < 0.01 } == true, "neural network (1, 2) -> \(String(describing: y))")
            let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: cfg)
            guard case .neuralNetwork(let net) = plan.modelStructure else { throw Fail("structure \(plan.modelStructure)") }
            try expect(net.layers.map(\.name) == ["dense"] && net.layers[0].inputNames == ["x"], "layers \(net.layers.map(\.name))")
            let use = plan.deviceUsage(for: net.layers[0])
            try expect(use != nil && !use!.supported.isEmpty, "device usage \(String(describing: use))")
            let structure = "layer \(net.layers[0].type) on \(String(describing: use!.preferred).prefix(30))"
            let devs = MLModel.availableComputeDevices.count
            return "batch \(ys), async sum \(par), compute plan structure \(structure), \(devs) devices; GLM compute plan \(glmPlan); NN predicts 8.5"
        })
        #endif
        #if canImport(CoreML)
        c.append(check("CoreML", "updatable-knn-update-task", timeout: 90) {
            let mc = try await p7KNNModelC()
            defer { try? FileManager.default.removeItem(at: mc.deletingLastPathComponent()) }
            let m = try MLModel(contentsOf: mc)
            try expect(m.modelDescription.isUpdatable, "model not updatable")
            let before = try await m.prediction(from: p7X(9, 8)).featureValue(for: "label")?.stringValue
            try expect(before == "b", "before update (9,8) -> \(String(describing: before))")
            // train: a new class "c" at (8, 9) ... (9, 8)
            let train = try MLArrayBatchProvider(array: [(8, 9), (9, 8), (9, 9)].map { p in
                let x = try MLMultiArray(shape: [2], dataType: .float32); x[0] = NSNumber(value: p.0); x[1] = NSNumber(value: p.1)
                return try MLDictionaryFeatureProvider(dictionary: ["x": x, "label": "c"]) as MLFeatureProvider
            })
            let done = P7Box<Result<MLModel, Error>>()
            let out = mc.deletingLastPathComponent().appendingPathComponent("knn-updated.mlmodelc", isDirectory: true)
            let task = try MLUpdateTask(forModelAt: mc, trainingData: train, configuration: nil) { ctx in
                if let e = ctx.task.error { done.set(.failure(e)); return }
                do { try ctx.model.write(to: out); done.set(.success(ctx.model)) } catch { done.set(.failure(error)) }
            }
            task.resume()
            guard let r = await done.wait(60) else { throw Fail("MLUpdateTask did not complete in 60 s (state \(task.state.rawValue))") }
            let updated = try r.get()
            let after = try await updated.prediction(from: p7X(9, 8)).featureValue(for: "label")?.stringValue
            let far = try await updated.prediction(from: p7X(1, 0)).featureValue(for: "label")?.stringValue
            try expect(after == "c" && far == "a", "after update (9,8) -> \(String(describing: after)), (1,0) -> \(String(describing: far))")
            let reloaded = try MLModel(contentsOf: out)
            let again = try await reloaded.prediction(from: p7X(9, 9)).featureValue(for: "label")?.stringValue
            try expect(again == "c", "written model (9,9) -> \(String(describing: again))")
            return "b -> c after training 3 samples; written model agrees"
        })
        #endif
        #if canImport(CreateMLComponents) && canImport(CoreML)
        c.append(check("CreateMLComponents", "logistic-classifier-export-coreml", timeout: 120) {
            // two well-separated classes in 2-D; fit, classify, export to a Core ML model and (where the device can
            // compile) run the exported model through Core ML
            var samples: [AnnotatedFeature<MLShapedArray<Float>, String>] = []
            for i in 0..<40 {
                let t = Float(i % 10) / 10
                samples.append(AnnotatedFeature(feature: MLShapedArray(scalars: [t, 1 + t], shape: [2]), annotation: "up"))
                samples.append(AnnotatedFeature(feature: MLShapedArray(scalars: [1 + t, t], shape: [2]), annotation: "down"))
            }
            let model = try await LogisticRegressionClassifier<Float, String>(labels: ["up", "down"]).fitted(to: samples)
            let d1 = try await model.applied(to: MLShapedArray(scalars: [0.2, 1.5], shape: [2]))
            let d2 = try await model.applied(to: MLShapedArray(scalars: [1.5, 0.2], shape: [2]))
            try expect(d1.mostLikelyLabel == "up" && d2.mostLikelyLabel == "down", "labels \(String(describing: d1.mostLikelyLabel)) \(String(describing: d2.mostLikelyLabel))")
            let dir = try p7Dir("sdkcov-p7-cmlc")
            let url = dir.appendingPathComponent("clf.mlmodel")
            #if os(watchOS)
            let size = 0
            return "fitted: up/down (no Core ML export or compiler on watchOS)"
            #else
            try model.export(to: url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            try expect(size > 50, "exported \(size) B")
            let compiled = try await MLModel.compileModel(at: url)
            let cm = try MLModel(contentsOf: compiled)
            let inName = cm.modelDescription.inputDescriptionsByName.keys.sorted().first ?? "?"
            let arr = try MLMultiArray(shape: [2], dataType: .float32); arr[0] = 0.2; arr[1] = 1.5
            let o = try await cm.prediction(from: MLDictionaryFeatureProvider(dictionary: [inName: arr]))
            let label = cm.modelDescription.predictedFeatureName.flatMap { o.featureValue(for: $0)?.stringValue }
            try expect(label == "up", "Core ML says \(String(describing: label)) (input \(inName))")
            return "fitted; exported \(size) B; Core ML predicts 'up'"
            #endif
        })
        #endif
        // MARK: NaturalLanguage
        #if canImport(NaturalLanguage)
        c.append(check("NaturalLanguage", "gazetteer-hypotheses-sentences") {
            let text = "x86Sim runs on Linux. It boots iPhone runtimes! Does it run on Fedora?"
            let st = NLTokenizer(unit: .sentence); st.string = text
            let sentences = st.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
            try expect(sentences.count == 3, "sentences \(sentences)")
            // a custom gazetteer needs no model assets
            let gz = try NLGazetteer(dictionary: ["OS": ["Linux", "Fedora"], "Product": ["x86Sim"]], language: .english)
            try expect(gz.label(for: "Fedora") == "OS" && gz.label(for: "x86Sim") == "Product" && gz.label(for: "Windows") == nil, "gazetteer")
            let r = NLLanguageRecognizer()
            r.languageConstraints = [.german, .dutch, .english]
            r.languageHints = [.german: 0.5, .dutch: 0.3, .english: 0.2]
            r.processString("Der Simulator läuft unter Linux und startet die Apps schnell.")
            let hyp = r.languageHypotheses(withMaximum: 2)
            try expect(r.dominantLanguage == .german && (hyp[.german] ?? 0) > 0.5, "hypotheses \(hyp)")
            // tagging with the gazetteer: a name-type scheme answered from our own dictionary
            let tg = NLTagger(tagSchemes: [.nameType, .tokenType, .script])
            tg.string = text
            tg.setGazetteers([gz], for: .nameType)
            var found: [String] = []
            tg.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { t, r in
                if let t, t.rawValue == "OS" || t.rawValue == "Product" { found.append("\(text[r])=\(t.rawValue)") }; return true
            }
            let script = tg.tag(at: text.startIndex, unit: .word, scheme: .script).0?.rawValue ?? "nil"
            return "3 sentences; gazetteer tags \(found); script \(script); \(hyp.count) hypotheses"
        })
        c.append(check("NaturalLanguage", "embeddings-assets", timeout: 60) {
            // word / sentence embeddings and the contextual embedding model are downloadable assets
            var parts: [String] = []
            if let e = NLEmbedding.wordEmbedding(for: .english) {
                let d = e.distance(between: "king", and: "queen"), far = e.distance(between: "king", and: "carburetor")
                try expect(d < far, "king-queen \(d) vs king-carburetor \(far)")
                parts.append("word embedding dim \(e.dimension), neighbours of dog \(e.neighbors(for: "dog", maximumCount: 3).map(\.0))")
            } else { parts.append("no word embedding") }
            parts.append(NLEmbedding.sentenceEmbedding(for: .english).map { "sentence embedding dim \($0.dimension)" } ?? "no sentence embedding")
            if let ce = NLContextualEmbedding(language: .english) {
                parts.append("contextual \(ce.modelIdentifier.prefix(40)) dim \(ce.dimension), assets \(ce.hasAvailableAssets)")
                if ce.hasAvailableAssets {
                    // Apple's visionOS simulator: assets present but load() answers NLNaturalLanguageErrorDomain 7
                    // ("Embedding model requires compilation")
                    do { try ce.load() } catch let e as NSError where e.domain == "NLNaturalLanguageErrorDomain" && e.code == 7 {
                        parts.append("load: NL error 7 (requires compilation)"); return parts.joined(separator: "; ")
                    }
                    let r = try ce.embeddingResult(for: "The simulator runs apps.", language: .english)
                    var n = 0; r.enumerateTokenVectors(in: r.string.startIndex..<r.string.endIndex) { v, _ in n += 1; return v.count == ce.dimension }
                    try expect(n > 2, "\(n) token vectors")
                    parts.append("\(n) token vectors")
                }
            } else { parts.append("no contextual embedding for English") }
            return parts.joined(separator: "; ")
        })
        #endif
        // MARK: SoundAnalysis
        #if canImport(SoundAnalysis)
        c.append(check("SoundAnalysis", "file-analyzer-windows", timeout: 120) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p7-tone.caf")
            try? FileManager.default.removeItem(at: url)
            let tone = sine(880, secs: 4, rate: 16000)
            do { let f = try AVAudioFile(forWriting: url, settings: tone.format.settings); try f.write(from: tone) }
            let req = try SNClassifySoundRequest(classifierIdentifier: .version1)
            req.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 1000)
            req.overlapFactor = 0.5
            let wd = req.windowDurationConstraint
            var allowed = "?"
            switch wd { case .enumeratedDurations(let ds): allowed = "\(ds.count) durations"; case .durationRange(let r): allowed = "\(r.start.seconds)...\(r.end.seconds) s"; @unknown default: allowed = "other" }
            final class O: NSObject, SNResultsObserving, @unchecked Sendable {
                var windows: [Double] = []; var top: String?; var done = false; var err: Error?
                func request(_ r: SNRequest, didProduce res: SNResult) { if let c = res as? SNClassificationResult { windows.append(c.timeRange.start.seconds); if top == nil { top = c.classifications.first?.identifier } } }
                func request(_ r: SNRequest, didFailWithError e: Error) { err = e; done = true }
                func requestDidComplete(_ r: SNRequest) { done = true }
            }
            let o = O()
            let an = try SNAudioFileAnalyzer(url: url)
            try an.add(req, withObserver: o)
            let ok = await an.analyze()
            try expect(ok && o.err == nil && o.done, "analyze \(ok), error \(String(describing: o.err))")
            // 4 s, 1.5 s windows overlapping by half: starts every 0.75 s
            try expect(o.windows.count >= 3, "\(o.windows.count) windows at \(o.windows)")
            return "\(o.windows.count) windows (allowed \(allowed)), first class '\(o.top ?? "-")'"
        })
        #endif
        // MARK: Speech
        #if canImport(Speech) && !os(tvOS) && !os(watchOS)
        c.append(check("Speech", "recognize-synthesized-file", timeout: 150) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p7-speech.caf")
            let secs = try await p7SpeechFile("The quick brown fox jumps over the lazy dog", url)
            try expect(secs > 1, "synthesized \(secs) s")
            let auth = SFSpeechRecognizer.authorizationStatus()
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { throw Fail("no en-US recognizer") }
            let req = SFSpeechURLRecognitionRequest(url: url)
            req.shouldReportPartialResults = false
            req.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
            req.addsPunctuation = true
            let box = P7Box<String>()
            let task = r.recognitionTask(with: req) { res, e in
                if let e { box.set("error \(p7Err(e)): \(e.localizedDescription.prefix(80))"); return }
                if let res, res.isFinal { box.set("text '\(res.bestTranscription.formattedString)'") }
            }
            let got = await box.wait(90) ?? "no result in 90 s (task state \(task.state.rawValue))"
            task.cancel()
            // Apple's simulator has no on-device ASR asset: kLSRErrorDomain 300 "Failed to initialize recognizer"
            try expect(got.lowercased().contains("fox") || got.hasPrefix("error kLSRErrorDomain 300"), got)
            return "auth \(auth.rawValue), on-device \(r.supportsOnDeviceRecognition), \(String(format: "%.1f", secs)) s audio: \(got)"
        })
        #endif
        #if canImport(Speech) && !os(watchOS)
        c.append(check("Speech", "speech-analyzer-transcribe-file", timeout: 150) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p7-speech2.caf")
            _ = try await p7SpeechFile("Hello from the speech analyzer", url)
            let loc = Locale(identifier: "en-US")
            let t = SpeechTranscriber(locale: loc, preset: .transcription)
            let st = await AssetInventory.status(forModules: [t])
            let det = SpeechDetector()
            try expect(st != .installed || SpeechTranscriber.isAvailable, "assets installed but transcriber unavailable")
            guard st == .installed else {
                return "SpeechTranscriber assets \(st) (available \(SpeechTranscriber.isAvailable)); detector format \(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [det]).map { "\($0.sampleRate)" } ?? "nil")"
            }
            let analyzer = SpeechAnalyzer(modules: [t])
            let file = try AVAudioFile(forReading: url)
            let collect = Task { var s = ""; for try await r in t.results { s += String(r.text.characters) }; return s }
            if let end = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: end) } else { await analyzer.cancelAndFinishNow() }
            let text = try await collect.value
            try expect(text.lowercased().contains("speech"), "transcript '\(text)'")
            return "transcript '\(text)'"
        })
        #endif
        // MARK: Vision
        #if canImport(Vision) && !os(watchOS)
        c.append(check("Vision", "translational-registration-horizon", timeout: 60) {
            // the second image is the first shifted 12 px right / 8 px down: registration recovers the shift
            let a = p7Square(200, 160, x: 50, y: 50), b = p7Square(200, 160, x: 62, y: 42)
            let reg = VNTranslationalImageRegistrationRequest(targetedCGImage: b)
            try VNImageRequestHandler(cgImage: a).perform([reg])
            guard let o = reg.results?.first else { throw Fail("no alignment observation") }
            let t = o.alignmentTransform
            try expect(abs(abs(t.tx) - 12) <= 2 && abs(abs(t.ty) - 8) <= 2, "alignment \(t.tx), \(t.ty)")
            let hz = VNDetectHorizonRequest()
            try VNImageRequestHandler(cgImage: a).perform([hz])
            let ang = hz.results?.first.map { String(format: "%.2f", $0.angle) } ?? "none"
            return "shift (\(String(format: "%.1f", t.tx)), \(String(format: "%.1f", t.ty))), horizon \(ang)"
        })
        #endif
        #if canImport(Vision)
        c.append(check("Vision", "saliency-faces-poses-classify", timeout: 120) {
            // Swift requests on a synthetic picture: what Apple's simulator answers (many models need espresso
            // contexts the simulator lacks) - each must complete or fail cleanly; which one does is reported
            let img = p7Square(320, 240, x: 120, y: 80, side: 80)
            func run<R: ImageProcessingRequest>(_ name: String, _ r: R, _ count: (R.Result) -> Int) async -> String {
                do { return "\(name) \(count(try await r.perform(on: img)))" } catch { return "\(name) err \(p7Err(error))" }
            }
            var parts: [String] = []
            // these complete in Apple's simulator (no neural network): the rest answer errors there
            for (n, r) in [("horizon", await run("horizon", DetectHorizonRequest()) { $0 == nil ? 0 : 1 })] { try expect(!r.contains(" err "), "\(n): \(r)") }
            parts.append(await run("attention", GenerateAttentionBasedSaliencyImageRequest()) { $0.salientObjects.count })
            parts.append(await run("objectness", GenerateObjectnessBasedSaliencyImageRequest()) { $0.salientObjects.count })
            parts.append(await run("horizon", DetectHorizonRequest()) { $0 == nil ? 0 : 1 })
            parts.append(await run("faces", DetectFaceRectanglesRequest()) { $0.count })
            parts.append(await run("landmarks", DetectFaceLandmarksRequest()) { $0.count })
            parts.append(await run("humans", DetectHumanRectanglesRequest()) { $0.count })
            parts.append(await run("classify", ClassifyImageRequest()) { $0.count })
            parts.append(await run("animals", RecognizeAnimalsRequest()) { $0.count })
            parts.append(await run("aesthetics", CalculateImageAestheticsScoresRequest()) { _ in 1 })
            #if !os(watchOS)
            parts.append(await run("body", DetectHumanBodyPoseRequest()) { $0.count })
            parts.append(await run("hand", DetectHumanHandPoseRequest()) { $0.count })
            let tr = await run("text-rects", DetectTextRectanglesRequest()) { $0.count }
            try expect(!tr.contains(" err "), tr)
            parts.append(tr)
            #endif
            return parts.joined(separator: ", ")
        })
        #endif
        // MARK: VisionKit
        #if canImport(VisionKit) && (os(iOS) || os(visionOS))
        c.append(check("VisionKit", "image-analyzer-live-text", timeout: 90) {
            let langs = ImageAnalyzer.supportedTextRecognitionLanguages
            let scan = await onMain { (DataScannerViewController.isSupported, DataScannerViewController.isAvailable) }
            #if os(iOS)
            let doc = VNDocumentCameraViewController.isSupported
            #else
            let doc = false
            #endif
            // Apple's simulator: no camera scanners (isSupported false), although DataScannerViewController.isAvailable is true
            try expect(!scan.0 && !doc, "camera scanners supported in the Simulator: scanner \(scan), document camera \(doc)")
            guard ImageAnalyzer.isSupported else { return "ImageAnalyzer not supported; \(langs.count) text languages, scanner available \(scan.1)" }
            let analyzer = ImageAnalyzer()
            let img = textImage("SDKCOV LIVE TEXT", 900, 200, size: 72)
            let a = try await analyzer.analyze(img, orientation: .up, configuration: ImageAnalyzer.Configuration([.text, .machineReadableCode]))
            let t = a.transcript
            #if os(iOS)
            try expect(t.uppercased().contains("LIVE TEXT"), "transcript '\(t)'")
            #else
            // Apple's visionOS 27.2 simulator analyzes without error but reads no text ('')
            try expect(t.isEmpty || t.uppercased().contains("LIVE TEXT"), "transcript '\(t)'")
            #endif
            let hasText = a.hasResults(for: .text)
            let inter = await onMain { () -> String in
                let iv = UIImageView(image: UIImage(cgImage: img)); let ia = ImageAnalysisInteraction(); iv.addInteraction(ia)
                ia.analysis = a; ia.preferredInteractionTypes = .textSelection
                return "interaction text \(ia.hasActiveTextSelection), types \(ia.preferredInteractionTypes.rawValue)"
            }
            return "transcript '\(t)', has text \(hasText), \(inter), \(langs.count) languages, scanner available \(scan.1)"
        })
        #endif
        // MARK: MediaIntelligence (tvOS: More_tvOS.swift)
        #if canImport(MediaIntelligence) && (os(iOS) || os(visionOS))
        c.append(check("MediaIntelligence", "face-group-analyzer", timeout: 90) {
            let dir = try p7Dir("sdkcov-p7-mi")
            let work = dir.appendingPathComponent("work", isDirectory: true)
            let fa = try FaceGroupAnalyzer(workingDirectory: work)
            var faces = 0, ids = 0
            for try await _ in fa.allFaces { faces += 1 }
            for try await _ in fa.allAssetIDs { ids += 1 }
            try expect(faces == 0 && ids == 0, "\(faces) faces, \(ids) assets in a new analyzer")
            try await fa.deleteAllAssets()
            let st = await fa.state
            // Apple's simulator: the empty store is ready
            try expect("\(st)" == "ready", "state \(st) (Apple's simulator: ready)")
            try await FaceGroupAnalyzer.purge(workingDirectory: work)
            return "empty analyzer, state \(st)"
        })
        #endif
        // MARK: SuggestedActions (visionOS: More_visionOS.swift)
        #if canImport(SuggestedActions) && os(iOS)
        c.append(check("SuggestedActions", "message-view-generate", timeout: 60) {
            let me = SuggestedActionsMessage.Participant(name: "sdkcov", handle: "sdkcov@example.com", isUser: true)
            let ada = SuggestedActionsMessage.Participant(name: "Ada", handle: "ada@example.com", isUser: false)
            let prev = SuggestedActionsMessage(id: 1, date: Date().addingTimeInterval(-60), subject: AttributedString("Lunch"), body: AttributedString("Lunch at noon tomorrow?"), sender: ada, recipients: [me])
            let msg = SuggestedActionsMessage(id: 2, date: Date(), subject: nil, body: AttributedString("Call me at +1 408 555 0100 tomorrow at 3pm"), sender: ada, recipients: [me])
            let limit = SuggestedActionsMessage.previousMessagesLimit
            try expect(limit > 0, "previous messages limit \(limit)")
            let gen = try await p7Within(30) { await SuggestedActionsView.generate(message: msg, previousMessages: [prev]); return "generated" } ?? "generate did not return in 30 s"
            let views = try await p7Main { () async throws -> Int in
                let hc = UIHostingController(rootView: SuggestedActionsView(message: msg, previousMessages: [prev]).frame(width: 360, height: 200))
                let done = try p7Show(hc); defer { done() }
                try await Task.sleep(for: .seconds(1))
                return p7Subviews(hc.view).count
            }
            // its content through accessibility, next to a label that shows the element tree is read: Apple's 27.2
            // simulator offers no action (no Apple Intelligence suggestions), only the label is there
            let ax = try await Task { @MainActor in try await p8AXLabels(VStack { Text("sdkcov actions"); SuggestedActionsView(message: msg, previousMessages: [prev]) }.frame(width: 360, height: 200), secs: 4) { $0.count > 1 } }.value
            try expect(ax == ["sdkcov actions"], "accessibility elements \(ax) (Apple's simulator: only the label, no action)")
            return "limit \(limit), \(gen), view \(views) subviews; no suggested action on screen"
        })
        #endif
        // MARK: SensitiveContentAnalysis
        #if canImport(SensitiveContentAnalysis) && (os(iOS) || os(visionOS))
        c.append(check("SensitiveContentAnalysis", "analyze-image-policy", timeout: 40) {
            // without the client entitlement / with the user setting off the policy is .disabled: analysis answers an error
            let an = SCSensitivityAnalyzer()
            let pol = an.analysisPolicy
            let img = p7Square(64, 64, x: 10, y: 10)
            var r = "?"
            do { let a = try await an.analyzeImage(img); r = "isSensitive \(a.isSensitive)" } catch { r = "error \(p7Err(error))" }
            // Apple's simulator: policy disabled (no entitlement, setting off) -> SensitiveContentAnalysis error 100
            if pol == .disabled { try expect(r == "error com.apple.SensitiveContentAnalysis 100", "disabled policy but \(r)") }
            return "policy \(pol.rawValue), analyzeImage: \(r)"
        })
        #endif
        return c
    }
}
