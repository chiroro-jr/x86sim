// SDK coverage, round 20: checks for [a] gaps of covered frameworks (COVERAGE-GAPS.md): PHASE occluders / materials
// and the ambient mixer, Charts marks placed by pixels with a selection set, TipKit's SwiftUI TipView on
// tvOS / watchOS. Each asserts what Apple's simulator answers (ref-mac.sh).
import Foundation
import Synchronization
import SwiftUI
import CoreGraphics
#if canImport(PHASE) && !os(watchOS)
import PHASE
import AVFAudio
import ModelIO
#endif
#if canImport(Charts)
import Charts
#endif
#if canImport(RealityKit) && !os(watchOS)
import RealityKit
import AVFoundation
#endif
#if canImport(TipKit)
import TipKit
#endif
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
private struct P16LiveAttributes: ActivityAttributes { struct ContentState: Codable, Hashable { var step: Int }; var name: String }
#endif

#if canImport(Charts)
/// a line over x 0...10 with a red rule at x = 7.5, no axes: the plot fills the frame, so the rule's column is at 75%
private struct P16Chart: View {
    var body: some View {
        Chart {
            ForEach(0..<11) { i in LineMark(x: .value("x", Double(i)), y: .value("y", Double(i % 3))).foregroundStyle(.blue) }
            RuleMark(x: .value("sel", 7.5)).foregroundStyle(Color(red: 1, green: 0, blue: 0)).lineStyle(StrokeStyle(lineWidth: 4))
        }
        .chartXScale(domain: 0...10).chartYScale(domain: 0...2)
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartXSelection(value: .constant(Double?(7.5)))
        .frame(width: 400, height: 200).background(Color.white)
    }
}
/// the columns (x) whose pixels are mostly red
private func p16RedColumns(_ img: CGImage) -> [Int] {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (0..<w).filter { x in
        var n = 0
        for y in 0..<h { let i = (y * w + x) * 4; if px[i] > 200 && px[i + 1] < 60 && px[i + 2] < 60 { n += 1 } }
        return n > h / 2
    }
}
#endif

extension Registry {
    static var p16: [Check] {
        var c: [Check] = []

        // MARK: PHASE: a material on an occluder between source and listener; a sound played through the ambient mixer
        #if canImport(PHASE) && !os(watchOS)
        c.append(check("PHASE", "occluder-material-ambient-mixer", timeout: 60) {
            let e = PHASEEngine(updateMode: .automatic)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let tone = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 14400)!
            tone.frameLength = 14400
            for i in 0..<14400 { tone.floatChannelData![0][i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / 48000) }
            let data = Data(bytes: tone.floatChannelData![0], count: 14400 * 4)
            _ = try e.assetRegistry.registerSoundAsset(data: data, identifier: "sdkcov-p16-tone", format: fmt, normalizationMode: .dynamic)
            // an occluder of cardboard (a box between the origin and a source at z -2)
            let mat = PHASEMaterial(engine: e, preset: .cardboard)
            let box = PHASEShape(engine: e, mesh: MDLMesh.newBox(withDimensions: [1, 1, 0.1], segments: [1, 1, 1], geometryType: .triangles, inwardNormals: false, allocator: nil))
            try expect(!box.elements.isEmpty, "shape without elements")
            box.elements[0].material = mat
            let occ = PHASEOccluder(engine: e, shapes: [box])
            var t = matrix_identity_float4x4; t.columns.3 = [0, 0, -1, 1]; occ.transform = t
            try e.rootObject.addChild(occ)
            try expect(occ.parent === e.rootObject && box.elements[0].material === mat, "occluder in the scene with its material")
            // the ambient mixer: mono as the tone (a stereo mixer refuses it: channel layout mismatch, Apple too), facing forward, bound to the listener
            guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono) else { throw Fail("mono layout") }
            let amb = PHASEAmbientMixerDefinition(channelLayout: layout, orientation: simd_quatf(angle: 0, axis: [0, 1, 0]))
            let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: "sdkcov-p16-tone", mixerDefinition: amb)
            sampler.playbackMode = .oneShot; sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
            _ = try e.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: "sdkcov-p16-event")
            let listener = PHASEListener(engine: e); listener.transform = matrix_identity_float4x4
            try e.rootObject.addChild(listener)
            let params = PHASEMixerParameters(); params.addAmbientMixerParameters(identifier: amb.identifier, listener: listener)
            let ev = try PHASESoundEvent(engine: e, assetIdentifier: "sdkcov-p16-event", mixerParameters: params)
            do { try e.start() } catch { throw Fail("engine start: \(error)") }
            defer { e.stop(); e.assetRegistry.unregisterAsset(identifier: "sdkcov-p16-event"); e.assetRegistry.unregisterAsset(identifier: "sdkcov-p16-tone") }
            let done = P11Flag()
            ev.start { reason in done.set("\(reason.rawValue)") }
            guard let reason = await done.wait(seconds: 15) else { throw Fail("the ambient event never finished (state \(ev.renderingState.rawValue))") }
            try expect(reason == "\(PHASESoundEvent.StartHandlerReason.finishedPlaying.rawValue)", "event ended with reason \(reason)")
            return "cardboard occluder at z -1 in the scene; ambient (mono) one-shot finished playing"
        })
        #endif

        // MARK: Charts: a rule mark at x 7.5 of 0...10 drawn at 75% of the plot, with a selection set (a scrollable chart is a ScrollView: ImageRenderer draws nothing of it, Apple's simulators too)
        #if canImport(Charts)
        c.append(check("Charts", "rule-mark-pixel-position-selection", timeout: 40) {
            try await onMain {
                let r = ImageRenderer(content: P16Chart()); r.scale = 1
                guard let img = r.cgImage else { throw Fail("no image") }
                let cols = p16RedColumns(img)
                try expect(!cols.isEmpty, "no red rule in \(img.width)x\(img.height)")
                let mid = Double(cols.reduce(0, +)) / Double(cols.count) / Double(img.width)
                try expect(abs(mid - 0.75) < 0.03, "rule at \(mid) of the width (columns \(cols.first!)...\(cols.last!)), want 0.75")
                return "\(img.width)x\(img.height): rule columns \(cols.first!)...\(cols.last!) (\(String(format: "%.3f", mid)) of the width)"
            }
        })
        #endif

        // MARK: RealityKit: a VideoMaterial bound to an AVPlayer on a model entity
        #if canImport(RealityKit) && !os(watchOS)
        c.append(check("RealityKit", "video-material-entity", timeout: 30) {
            try await onMain {
                let player = AVPlayer()
                let m = VideoMaterial(avPlayer: player)
                try expect(m.avPlayer === player, "avPlayer \(String(describing: m.avPlayer))")
                let e = ModelEntity(mesh: .generatePlane(width: 1.6, height: 0.9), materials: [m])
                let back = e.model?.materials.first as? VideoMaterial
                try expect(back?.avPlayer === player, "entity material \(String(describing: e.model?.materials.first))")
                return "VideoMaterial on a plane, player kept (rate \(player.rate))"
            }
        })
        #endif

        // MARK: ActivityKit: a Live Activity requested with pushType .token; what pushTokenUpdates hands out
        #if canImport(ActivityKit) && os(iOS)
        c.append(check("ActivityKit", "push-token-updates", timeout: 40) {
            let a = try Activity.request(attributes: P16LiveAttributes(name: "sdkcov-p16"), content: ActivityContent(state: P16LiveAttributes.ContentState(step: 1), staleDate: nil), pushType: .token)
            defer { Task { await a.end(nil, dismissalPolicy: .immediate) } }
            let tok = P7Box<Data>()
            let t = Task { for await d in a.pushTokenUpdates { tok.set(d); break } }
            defer { t.cancel() }
            let d = await tok.wait(15)
            let now = a.pushToken
            // Apple's iOS 27.2 simulator: no APNs, so no push token for the activity (the request itself succeeds)
            try expect(d == nil && now == nil, "push token \(String(describing: d)) / \(String(describing: now)) (Apple's simulator: none)")
            return "pushTokenUpdates \(d.map { "\($0.count) B" } ?? "none in 15 s"), pushToken \(now.map { "\($0.count) B" } ?? "nil")"
        })
        #endif

        // MARK: TipKit: the SwiftUI TipView rendered (tvOS / watchOS: no TipUIView)
        #if canImport(TipKit) && (os(tvOS) || os(watchOS))
        c.append(check("TipKit", "tip-view-swiftui-render", timeout: 40) {
            do { try Tips.configure() } catch { _ = error }
            // hosted (ImageRenderer gives no image of a TipView: nil on Apple's simulators too); its laid-out size
            // the last size it was laid out at (tvOS lays it out at height 0 first)
            let size = Mutex<CGSize?>(nil)
            let v = TipView(P3PlainTip()).frame(width: 150).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { s in size.withLock { $0 = s } }
            let close = try await onMain { try p6HostSwiftUI(v) }
            defer { Task { @MainActor in close() } }
            var s: CGSize?
            for _ in 0..<50 { s = size.withLock { $0 }; if let s, s.height > 0 { break }; try await Task.sleep(for: .milliseconds(200)) }
            try await Task.sleep(for: .milliseconds(500)); s = size.withLock { $0 }
            guard let s else { throw Fail("the TipView never appeared") }
            try expect(s.width == 150 && s.height > 20, "TipView laid out \(s)")
            return "TipView laid out \(Int(s.width))x\(Int(s.height))"
        })
        #endif
        return c
    }
}
