// SDK coverage, round 16: [a] gaps of covered frameworks. BNNS Graph (builder, compile, execute), microphone capture
// (AVAudioRecorder, AVAudioEngine's input node, an AudioQueue input), a watchOS port (an AVAudioSourceNode rendered
// offline), @Query in a hosted view (iOS / watchOS /
// visionOS, was tvOS only), AccessoryWidgetBackground on iOS (was watchOS only), SwiftUI toolbar / Menu / menu Picker /
// compact DatePicker / popover through their UIKit counterparts.
import Foundation
import Synchronization
import CoreGraphics
import AVFoundation
import Accelerate
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(SwiftData)
import SwiftData
#endif
#if canImport(_SwiftData_SwiftUI)
import _SwiftData_SwiftUI
#endif
#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

/// the share of pixels with alpha > 0 (0...1)
func p12Inked(_ img: CGImage) -> Double {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var n = 0
    for i in stride(from: 3, to: px.count, by: 4) where px[i] > 0 { n += 1 }
    return Double(n) / Double(w * h)
}

#if canImport(SwiftData)
private struct P12QueryView: View {
    // what @Query(sort: \.title) expands to (the Linux toolchain has no SwiftDataMacros plugin)
    var _notes = Query<SDNote, [SDNote]>(FetchDescriptor<SDNote>(sortBy: [SortDescriptor(\.title)]))
    var notes: [SDNote] { _notes.wrappedValue }
    let seen: (Int) -> Void
    var body: some View { Text("\(notes.count) notes").onAppear { seen(notes.count) }.onChange(of: notes.count) { _, n in seen(n) } }
}
#endif

#if os(iOS) || os(visionOS)
@MainActor final class P12MenuModel: ObservableObject {
    @Published var pick = 1
    @Published var date = Date(timeIntervalSince1970: 1_800_000_000)
    @Published var pop = false
    @Published var tool = false
}
private struct P12MenuRoot: View {
    @ObservedObject var m: P12MenuModel
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Menu("SDKCovMenu") { Button("One") {}; Button("Two") {} }
                Picker("Flavor", selection: $m.pick) { Text("A").tag(0); Text("B").tag(1); Text("C").tag(2) }.pickerStyle(.menu)
                DatePicker("When", selection: $m.date, displayedComponents: .date).datePickerStyle(.compact)
                #if os(visionOS)   // popover's opaque type needs __isPlatformVersionAtLeast, which this toolchain doesn't link for visionOS
                Text("anchor").sheet(isPresented: $m.pop) { Text("SDKCovPopover").padding() }
                #else
                Text("anchor").popover(isPresented: $m.pop) { Text("SDKCovPopover").padding() }
                #endif
            }
            .navigationTitle("SDKCov")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("SDKCovTool") { m.tool = true } } }
        }
    }
}
#endif

extension Registry {
    static var p12: [Check] {
        var c: [Check] = []

        // MARK: Accelerate: a BNNS Graph built in Swift, compiled to a context and executed (y = 2x + 1, its sum)
        c.append(check("Accelerate", "bnns-graph-builder-execute", timeout: 60) {
            let ctx = try BNNSGraph.makeContext { b in
                let x = b.argument(name: "x", dataType: Float.self, shape: [4])
                let y = x * Float(2) + Float(1)
                let s = y.sum(axes: [0], keepDimensions: false)
                return [y, s]
            }
            let names = ctx.argumentNames()
            guard names.contains("x"), names.count == 3 else { throw Fail("arguments \(names)") }
            var args: [BNNSTensor] = []
            for n in names.sorted(by: { ctx.argumentPosition(argument: $0) < ctx.argumentPosition(argument: $1) }) {
                if n == "x" { args.append(BNNSTensor.allocate(initializingFrom: [Float(1), 2, 3, 4], shape: [4], stride: [1])) }
                else {
                    guard let t = ctx.allocateTensor(argument: n, fillKnownDynamicShapes: true) else { throw Fail("no tensor for \(n)") }
                    args.append(t)
                }
            }
            defer { args.forEach { $0.deallocate() } }
            try ctx.executeFunction(arguments: &args)
            let outs = args.enumerated().filter { names.sorted(by: { ctx.argumentPosition(argument: $0) < ctx.argumentPosition(argument: $1) })[$0.offset] != "x" }
                .map { $0.element.makeArray(of: Float.self) }
            try expect(outs.contains([3, 5, 7, 9]) && outs.contains([24]), "outputs \(outs) (arguments \(names))")
            return "arguments \(names), outputs \(outs)"
        })

        // MARK: AVFAudio / AudioToolbox: the simulator's microphone (granted ahead: run.sh / ref-mac.sh)
        c.append(check("AVFAudio", "microphone-recorder-engine-input", timeout: 40) {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [])
            try s.setActive(true)
            defer { try? s.setActive(false, options: .notifyOthersOnDeactivation) }
            let perm = AVAudioApplication.shared.recordPermission
            let route = s.currentRoute.inputs.map { "\($0.portType.rawValue)" }
            var out = "permission \(perm.rawValue), input available \(s.isInputAvailable), inputs \(route), rate \(Int(s.sampleRate)), input channels \(s.inputNumberOfChannels)"
            // AVAudioRecorder: 1 s of 16 kHz mono PCM
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-mic-\(UUID().uuidString.prefix(6)).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                                             AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            r.isMeteringEnabled = true
            let prepared = r.prepareToRecord(), started = r.record(forDuration: 1.0)
            try await Task.sleep(for: .milliseconds(1600))
            r.updateMeters()
            let peak = r.peakPower(forChannel: 0)
            r.stop()
            var frames: Int64 = -1
            if let f = try? AVAudioFile(forReading: url) { frames = f.length }
            out += "; recorder prepared \(prepared) started \(started) frames \(frames) peak \(String(format: "%.0f", peak)) dB"
            // AVAudioEngine's input node: a tap for 1 s
            let e = AVAudioEngine()
            let fmt = e.inputNode.outputFormat(forBus: 0)
            // a Mac with a microphone (x86Sim: simaudio's) records; Apple's reference Mac mini has none: the input node
            // is 0 Hz and the recorder doesn't start
            let hasMic = fmt.sampleRate > 0 && fmt.channelCount > 0
            if hasMic { try expect(prepared && started && frames >= 15000, "recorder with a microphone: prepared \(prepared) started \(started) frames \(frames)") }
            else { try expect(!started && frames <= 0, "no microphone, yet the recorder started \(started) frames \(frames)") }
            let got = Atomic<Int>(0)
            out += "; input node \(Int(fmt.sampleRate)) Hz \(fmt.channelCount) ch"
            if fmt.channelCount > 0 && fmt.sampleRate > 0 {
                e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { b, _ in got.add(Int(b.frameLength), ordering: .relaxed) }
                do {
                    try e.start()
                    try await Task.sleep(for: .milliseconds(1200))
                    e.stop()
                    out += ", tap \(got.load(ordering: .relaxed)) frames"
                    try expect(got.load(ordering: .relaxed) >= Int(fmt.sampleRate / 2), "input tap: \(got.load(ordering: .relaxed)) frames in 1.2 s")
                } catch { out += ", engine start: \((error as NSError).domain) \((error as NSError).code)" }
                e.inputNode.removeTap(onBus: 0)
            }
            return out
        })
        #if canImport(AudioToolbox) && !os(watchOS)
        c.append(check("AudioToolbox", "audioqueue-input-record", timeout: 30) {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord)
            try AVAudioSession.sharedInstance().setActive(true)
            defer { try? AVAudioSession.sharedInstance().setActive(false) }
            var asbd = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                   mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            final class Box: @unchecked Sendable { let lock = NSLock(); var packets = 0; var buffers = 0 }
            let box = Box()
            var q: AudioQueueRef?
            let st = AudioQueueNewInputWithDispatchQueue(&q, &asbd, 0, DispatchQueue(label: "sdkcov.aq")) { q, buf, _, n, _ in
                box.lock.withLock { box.packets += Int(n); box.buffers += 1 }
                AudioQueueEnqueueBuffer(q, buf, 0, nil)
            }
            guard st == noErr, let q else { return "AudioQueueNewInput \(st)" }
            defer { AudioQueueDispose(q, true) }
            for _ in 0..<3 { var b: AudioQueueBufferRef?; AudioQueueAllocateBuffer(q, 3200, &b); if let b { AudioQueueEnqueueBuffer(q, b, 0, nil) } }
            let s = AudioQueueStart(q, nil)
            try await Task.sleep(for: .milliseconds(1200))
            AudioQueueStop(q, true)
            var cur = AudioStreamBasicDescription(); var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioQueueGetProperty(q, kAudioQueueProperty_StreamDescription, &cur, &sz)
            let (p, n) = box.lock.withLock { (box.packets, box.buffers) }
            // a microphone (x86Sim: simaudio's) fills ~1.2 s of 16 kHz; Apple's reference Mac mini has none: start fails
            let probe = AVAudioEngine()   // kept alive while its input node is asked (a temporary engine's node dangles)
            let hasMic = probe.inputNode.outputFormat(forBus: 0).sampleRate > 0
            withExtendedLifetime(probe) {}
            if hasMic { try expect(s == noErr && p >= 12000, "with a microphone: start \(s), \(p) packets") }
            else { try expect(s != noErr && p == 0, "no microphone, yet start \(s), \(p) packets") }
            return "start \(s), \(n) buffers, \(p) packets, format \(Int(cur.mSampleRate)) Hz \(cur.mChannelsPerFrame) ch"
        })
        #endif

        // MARK: watchOS ports
        #if os(watchOS)
        c.append(check("AVFAudio", "source-node-mixer-offline", timeout: 30) {
            // watchOS has no time-pitch / varispeed / sampler units: an AVAudioSourceNode's 1 kHz tone through the main
            // mixer, rendered offline; the source is pulled for every rendered frame and the output carries it
            let e = AVAudioEngine()
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let pulled = Atomic<Int>(0)
            var phase = 0.0
            let src = AVAudioSourceNode(format: fmt) { _, _, n, abl in
                let p = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(n) { p[i] = Float(0.5 * sin(phase)); phase += 2 * .pi * 1000 / 44100 }
                pulled.add(Int(n), ordering: .relaxed)
                return noErr
            }
            e.attach(src); e.connect(src, to: e.mainMixerNode, format: fmt)
            let st = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            try e.enableManualRenderingMode(.offline, format: st, maximumFrameCount: 4096)
            try e.start()
            let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 4096)!
            var rendered = 0, energy: Float = 0
            for _ in 0..<10 { let r = try e.renderOffline(4096, to: out); try expect(r == .success, "render \(r.rawValue)"); rendered += Int(out.frameLength); energy += rms(out) }
            e.stop()
            let ratio = Double(pulled.load(ordering: .relaxed)) / Double(rendered)
            try expect(abs(ratio - 1) < 0.05, "source pulled \(pulled.load(ordering: .relaxed)) for \(rendered) rendered")
            try expect(energy / 10 > 0.1, "output rms \(energy / 10)")
            return "\(rendered) frames rendered, pull ratio \(String(format: "%.2f", ratio)), rms \(String(format: "%.3f", energy / 10))"
        })
        #endif

        // MARK: _SwiftData_SwiftUI: @Query in a hosted view (was tvOS only)
        #if canImport(SwiftData) && !os(tvOS)
        c.append(check("_SwiftData_SwiftUI", "query-in-hosted-view", timeout: 30) {
            let mc = try await onMain { () throws -> ModelContainer in
                let mc = try ModelContainer(for: SDNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                for i in 0..<7 { mc.mainContext.insert(SDNote(title: "q\(i)")) }
                try mc.mainContext.save()
                return mc
            }
            let seen = Atomic<Int>(-1)
            let close = try await onMain { try p6HostSwiftUI(P12QueryView(seen: { seen.store($0, ordering: .relaxed) }).modelContainer(mc)) }
            defer { Task { @MainActor in close() } }
            var ok = false
            for _ in 0..<40 { if seen.load(ordering: .relaxed) == 7 { ok = true; break }; try await Task.sleep(for: .milliseconds(100)) }
            try expect(ok, "@Query saw \(seen.load(ordering: .relaxed)) notes")
            // a later insert reaches the query
            try await onMain { mc.mainContext.insert(SDNote(title: "q7")); try mc.mainContext.save() }
            var ok2 = false
            for _ in 0..<40 { if seen.load(ordering: .relaxed) == 8 { ok2 = true; break }; try await Task.sleep(for: .milliseconds(100)) }
            try expect(ok2, "after an insert @Query saw \(seen.load(ordering: .relaxed)) notes")
            return "@Query: 7 notes, 8 after an insert"
        })
        #endif

        // MARK: WidgetKit: AccessoryWidgetBackground rendered on iOS (was watchOS only)
        #if canImport(WidgetKit) && os(iOS)
        c.append(check("WidgetKit", "accessory-background-render") {
            try await onMain {
                let v = ZStack { AccessoryWidgetBackground(); Text("42").font(.title) }.frame(width: 80, height: 80).clipShape(Circle())
                let r = ImageRenderer(content: v); r.scale = 2
                guard let img = r.cgImage else { throw Fail("no image") }
                let f = p12Inked(img)
                // Apple's iOS 27.2 simulator: outside a widget's accessory family the background draws nothing (only the
                // text inks, ~4%); watchOS draws it (More_watchOS.swift)
                try expect(f > 0.01 && f < 0.15, "accessory background inked \(f) (Apple: the text only, ~4%)")
                return "\(img.width)x\(img.height), \(Int(f * 100))% inked"
            }
        })
        #endif

        // MARK: SwiftUI: toolbar item, Menu, menu-style Picker, compact DatePicker and a popover through UIKit
        #if os(iOS) || os(visionOS)
        c.append(check("SwiftUI", "toolbar-menu-picker-datepicker-popover", timeout: 40) {
            let m = await onMain { P12MenuModel() }
            let close = try await onMain { try p6HostSwiftUI(P12MenuRoot(m: m)) }
            defer { Task { @MainActor in close() } }
            try await Task.sleep(for: .milliseconds(800))
            guard let w = await onMain({ p6LastWindow }) else { throw Fail("no window") }
            let info = await onMain { () -> ([String], [String], [String]) in
                let bars = p6Find(w, UINavigationBar.self)
                let items = bars.compactMap { $0.topItem }.map { "title \($0.title ?? "nil") right \($0.rightBarButtonItems?.count ?? 0) trailing \($0.trailingItemGroups.flatMap(\.barButtonItems).count)" }
                let menuButtons = p6Find(w, UIButton.self).filter { $0.menu != nil }
                let menus = menuButtons.map { "\($0.menu!.children.count) items\($0.showsMenuAsPrimaryAction ? " primary" : "")" }
                let dps = p6Find(w, UIDatePicker.self).map { "\($0.datePickerMode.rawValue)/\($0.preferredDatePickerStyle.rawValue)" }
                return (items, menus, dps)
            }
            let (items, menus, dps) = info
            // the popover: presented from the model, gone when the model says so
            await onMain { m.pop = true }
            let shown = await p6Wait(5) { !p6Presented(w).isEmpty }
            let pres = await onMain { p6Presented(w).map { "\(type(of: $0))/\($0.modalPresentationStyle.rawValue)" } }
            await onMain { m.pop = false }
            let gone = await p6Wait(5) { p6Presented(w).isEmpty }
            // Apple's iOS / visionOS 27.2 simulators: the toolbar button as a trailing bar item, the Menu and the menu Picker
            // as UIButtons whose menu is their primary action (the Picker's with its 3 choices), a compact date-mode
            // UIDatePicker; the popover (visionOS: a sheet) presented and dismissed from the model
            try expect(items.count == 1 && items[0].hasSuffix("trailing 1"), "navigation bars \(items)")
            try expect(menus.count == 2 && menus.contains("3 items primary") && menus.allSatisfy { $0.hasSuffix("primary") }, "menu buttons \(menus)")
            try expect(dps == ["1/2"], "date pickers (mode/style) \(dps)")
            try expect(shown && gone, "popover shown \(shown) \(pres) dismissed \(gone)")
            return "bars \(items), menu buttons \(menus), date pickers \(dps); popover shown \(pres) and dismissed"
        })
        #endif

        return c
    }
}
