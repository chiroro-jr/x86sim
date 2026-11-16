// sdkcov P1 (media & AV): audio stacks below AVFAudio. AudioToolbox (AudioQueue offline render, AudioFileStream
// parsing, Apple effect AUs and an in-process AUv3 through render blocks / AVAudioEngine, MusicSequence SMF round
// trip + MusicPlayer, system sounds), the CoreAudio HAL objects, CoreMIDI (UMP, MIDI-CI, network session), AVFAudio
// source node / time pitch / sequencer + sampler, CoreMedia queues and timebases, VideoToolbox pixel sessions,
// OpenAL playback, CoreHaptics' spatial experience (visionOS).
import Foundation
import Synchronization
import AVFoundation
import CoreMedia
import CoreVideo
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(CoreMIDI)
import CoreMIDI
#endif
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(OpenAL)
import OpenAL
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif
#if canImport(_CoreHaptics_AudioToolbox)
import _CoreHaptics_AudioToolbox
#endif

func p1FourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
/// AudioObjectPropertyAddress (the HAL's header types are not in the simulator SDKs' Swift view)
struct P1AOAddr { var mSelector: UInt32, mScope: UInt32, mElement: UInt32 }

#if canImport(AudioToolbox) && !os(watchOS)
/// an in-process AUv3 effect: output = input x 0.5
final class P1GainAU: AUAudioUnit {
    private var ins: AUAudioUnitBusArray!, outs: AUAudioUnitBusArray!
    private var scratch: AVAudioPCMBuffer?
    static let renders = Atomic<Int>(0)
    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let f = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        ins = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: f)])
        outs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: f)])
        maximumFramesToRender = 4096
    }
    override var inputBusses: AUAudioUnitBusArray { ins }
    override var outputBusses: AUAudioUnitBusArray { outs }
    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        scratch = AVAudioPCMBuffer(pcmFormat: outs[0].format, frameCapacity: maximumFramesToRender)
    }
    override var internalRenderBlock: AUInternalRenderBlock {
        let scratch = self.scratch
        return { _, ts, frames, _, out, _, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            let abl = UnsafeMutableAudioBufferListPointer(out)
            if let s = scratch { let sb = UnsafeMutableAudioBufferListPointer(s.mutableAudioBufferList)
                for i in 0..<abl.count where abl[i].mData == nil { abl[i].mData = sb[min(i, sb.count - 1)].mData } }
            var f = AudioUnitRenderActionFlags()
            let st = pull(&f, ts, frames, 0, out)
            guard st == noErr else { return st }
            for b in abl { let p = b.mData!.assumingMemoryBound(to: Float.self); for i in 0..<Int(frames) { p[i] *= 0.5 } }
            P1GainAU.renders.add(1, ordering: .relaxed)
            return noErr
        }
    }
}
/// render `src` (mono) offline through `insert` (nil = straight) into stereo; rms of the left channel
func p1EngineRMS(_ src: AVAudioPCMBuffer, insert: AVAudioNode?) throws -> Float {
    let e = AVAudioEngine(), p = AVAudioPlayerNode(); e.attach(p)
    let st = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    if let insert { e.attach(insert); e.connect(p, to: insert, format: st); e.connect(insert, to: e.mainMixerNode, format: st) }
    else { e.connect(p, to: e.mainMixerNode, format: st) }
    try e.enableManualRenderingMode(.offline, format: st, maximumFrameCount: 4096)
    // the player takes the mono buffer through a converter-free path: give it a stereo copy
    let b = AVAudioPCMBuffer(pcmFormat: st, frameCapacity: src.frameLength)!; b.frameLength = src.frameLength
    for ch in 0..<2 { memcpy(b.floatChannelData![ch], src.floatChannelData![0], Int(src.frameLength) * 4) }
    try e.start(); p.scheduleBuffer(b); p.play()
    let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 4096)!
    var s: Float = 0, n = 0
    for _ in 0..<4 {
        let r = try e.renderOffline(4096, to: out); try expect(r == .success, "render \(r.rawValue)")
        let pp = out.floatChannelData![0]; for i in 0..<Int(out.frameLength) { s += pp[i] * pp[i] }; n += Int(out.frameLength)
    }
    e.stop()
    return (s / Float(max(n, 1))).squareRoot()
}
/// AudioQueue offline: the queue's output callback refills from this source
final class P1AQSource { let src: [Float]; var pos = 0; var calls = 0; var done = false; init(_ s: [Float]) { src = s } }
final class P1Stream { var packets = 0, bytes = 0, ready = false, fmt = AudioStreamBasicDescription(); var props: [UInt32] = [] }
#endif


extension Registry {
    static var p1_audio: [Check] {
        var c: [Check] = []
        #if canImport(AudioToolbox) && !os(watchOS)
        c.append(check("AudioToolbox", "audioqueue-offline-render", timeout: 30) {
            // an output AudioQueue in offline-render mode: the output callback refills three buffers from a 1 kHz tone,
            // AudioQueueOfflineRender pulls 10 x 1024 frames, which must be that tone sample for sample
            let tone = p1Tones([1000], secs: 1)
            let srcArr = Array(UnsafeBufferPointer(start: tone.floatChannelData![0], count: Int(tone.frameLength)))
            let box = P1AQSource(srcArr)
            var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            let cb: AudioQueueOutputCallback = { ud, q, buf in
                let b = Unmanaged<P1AQSource>.fromOpaque(ud!).takeUnretainedValue()
                b.calls += 1
                let n = min(4096, b.src.count - b.pos)
                guard n > 0 else { b.done = true; return }
                b.src.withUnsafeBufferPointer { memcpy(buf.pointee.mAudioData, $0.baseAddress! + b.pos, n * 4) }
                buf.pointee.mAudioDataByteSize = UInt32(n * 4); b.pos += n
                AudioQueueEnqueueBuffer(q, buf, 0, nil)
            }
            var q: AudioQueueRef?
            try expect(AudioQueueNewOutput(&asbd, cb, Unmanaged.passUnretained(box).toOpaque(), nil, nil, 0, &q) == noErr && q != nil, "AudioQueueNewOutput")
            defer { AudioQueueDispose(q!, true) }
            for _ in 0..<3 {
                var b: AudioQueueBufferRef?
                try expect(AudioQueueAllocateBuffer(q!, 4096 * 4, &b) == noErr, "allocate")
                cb(Unmanaged.passUnretained(box).toOpaque(), q!, b!)
            }
            var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
            try expect(AudioQueueSetOfflineRenderFormat(q!, &asbd, &layout) == noErr, "offline format")
            try expect(AudioQueueStart(q!, nil) == noErr, "start")
            var ob: AudioQueueBufferRef?; try expect(AudioQueueAllocateBuffer(q!, 1024 * 4, &ob) == noErr, "out buffer")
            var ts = AudioTimeStamp(); ts.mFlags = .sampleTimeValid; ts.mSampleTime = 0
            try expect(AudioQueueOfflineRender(q!, &ts, ob!, 0) == noErr, "priming render")
            var got: [Float] = []
            for k in 0..<10 {
                ts.mSampleTime = Double(k * 1024)
                let st = AudioQueueOfflineRender(q!, &ts, ob!, 1024)
                try expect(st == noErr, "render \(k): \(st)")
                let n = Int(ob!.pointee.mAudioDataByteSize) / 4
                got += Array(UnsafeBufferPointer(start: ob!.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: n))
            }
            AudioQueueStop(q!, true)
            try expect(got.count == 10240, "rendered \(got.count) frames")
            // match against the source (the queue may start a few frames late): best lag in 0..<64
            var best = (lag: -1, err: Float.infinity)
            for lag in 0..<64 { var e: Float = 0; for i in 0..<8000 { let d = got[i + lag] - srcArr[i]; e += d * d }; if e < best.err { best = (lag, e) } }
            let r = (got.reduce(0) { $0 + $1 * $1 } / Float(got.count)).squareRoot()
            try expect(best.err < 0.01 && abs(r - 0.354) < 0.02, "offline output differs from the source: rms \(r), best lag \(best.lag) err \(best.err)")
            return "10240 frames, rms \(String(format: "%.3f", r)), lag \(best.lag), \(box.calls) callbacks"
        })
        c.append(check("AudioToolbox", "audiofilestream-adts-parse", timeout: 30) {
            // a 1 s AAC ADTS stream (ExtAudioFile's encoder) parsed in 700-byte pieces by AudioFileStream: data format,
            // ready-to-produce-packets and ~43 packets of 1024 frames
            let u = p1Tmp("stream.aac")
            var aac = AudioStreamBasicDescription(); aac.mSampleRate = 44100; aac.mFormatID = kAudioFormatMPEG4AAC; aac.mChannelsPerFrame = 1; aac.mFramesPerPacket = 1024
            var f: ExtAudioFileRef?
            try expect(ExtAudioFileCreateWithURL(u as CFURL, kAudioFileAAC_ADTSType, &aac, nil, AudioFileFlags.eraseFile.rawValue, &f) == noErr, "create ADTS")
            let tone = p1Tones([440], secs: 1)
            var client = tone.format.streamDescription.pointee
            try expect(ExtAudioFileSetProperty(f!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr, "client format")
            let ws = ExtAudioFileWrite(f!, tone.frameLength, tone.audioBufferList)
            ExtAudioFileDispose(f!)
            try expect(ws == noErr, "write \(ws)")
            let bytes = try Data(contentsOf: u)
            let s = P1Stream()
            var sid: AudioFileStreamID?
            let prop: AudioFileStream_PropertyListenerProc = { ud, id, pid, _ in
                let s = Unmanaged<P1Stream>.fromOpaque(ud).takeUnretainedValue(); s.props.append(pid)
                if pid == kAudioFileStreamProperty_ReadyToProducePackets { s.ready = true }
                if pid == kAudioFileStreamProperty_DataFormat { var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size); AudioFileStreamGetProperty(id, pid, &sz, &s.fmt) }
            }
            let pk: AudioFileStream_PacketsProc = { ud, nb, np, _, _ in
                let s = Unmanaged<P1Stream>.fromOpaque(ud).takeUnretainedValue(); s.packets += Int(np); s.bytes += Int(nb)
            }
            try expect(AudioFileStreamOpen(Unmanaged.passUnretained(s).toOpaque(), prop, pk, kAudioFileAAC_ADTSType, &sid) == noErr, "AudioFileStreamOpen")
            defer { AudioFileStreamClose(sid!) }
            var off = 0
            while off < bytes.count {
                let n = min(700, bytes.count - off)
                let st = bytes.withUnsafeBytes { AudioFileStreamParseBytes(sid!, UInt32(n), $0.baseAddress! + off, []) }
                try expect(st == noErr, "parse at \(off): \(st)")
                off += n
            }
            try expect(s.ready && s.fmt.mFormatID == kAudioFormatMPEG4AAC && s.fmt.mSampleRate == 44100, "stream format \(String(format: "%08x", s.fmt.mFormatID)) \(s.fmt.mSampleRate) Hz, ready \(s.ready)")
            try expect(s.packets >= 43 && s.packets <= 46 && s.bytes > 1000, "\(s.packets) packets, \(s.bytes) B")
            return "\(bytes.count) B ADTS: \(s.packets) packets (\(s.bytes) B payload), \(s.props.count) property callbacks"
        })
        c.append(check("AudioToolbox", "auaudiounit-effects-auv3", timeout: 60) {
            // AUDelay through AUAudioUnit's render block (10 ms fully wet: an impulse comes out 441 frames later),
            // AUNBandEQ's parameter tree, and an AUv3 registered in-process (gain 0.5) inside an AVAudioEngine render
            func desc(_ t: OSType, _ s: OSType, _ m: OSType = kAudioUnitManufacturer_Apple) -> AudioComponentDescription {
                AudioComponentDescription(componentType: t, componentSubType: s, componentManufacturer: m, componentFlags: 0, componentFlagsMask: 0)
            }
            // AUDelay as an AUv2 instance: stream format, a render callback feeding an impulse, AudioUnitRender
            var dd = desc(kAudioUnitType_Effect, kAudioUnitSubType_Delay)
            guard let comp = AudioComponentFindNext(nil, &dd) else { throw Fail("no AUDelay") }
            var inst: AudioUnit?; try expect(AudioComponentInstanceNew(comp, &inst) == noErr, "AudioComponentInstanceNew")
            let unit = inst!; defer { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
            // its own stream format (setting the output one is refused with -10868, on Apple's simulator too)
            var asbd = AudioStreamBasicDescription(), asz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try expect(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, &asz) == noErr, "get stream format")
            guard let auFmt = AVAudioFormat(streamDescription: &asbd), auFmt.commonFormat == .pcmFormatFloat32, !auFmt.isInterleaved else { throw Fail("AUDelay format \(asbd)") }
            final class Feed { var pos = 0 }
            let feed = Feed()
            var cb = AURenderCallbackStruct(inputProc: { ref, _, _, _, n, abl in
                let f = Unmanaged<Feed>.fromOpaque(ref).takeUnretainedValue()
                for b in UnsafeMutableAudioBufferListPointer(abl!) { let p = b.mData!.assumingMemoryBound(to: Float.self); for i in 0..<Int(n) { p[i] = f.pos + i == 0 ? 1 : 0 } }
                f.pos += Int(n); return noErr
            }, inputProcRefCon: Unmanaged.passUnretained(feed).toOpaque())
            try expect(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr, "render callback")
            AudioUnitSetParameter(unit, kDelayParam_DelayTime, kAudioUnitScope_Global, 0, 0.01, 0)
            AudioUnitSetParameter(unit, kDelayParam_WetDryMix, kAudioUnitScope_Global, 0, 100, 0)
            AudioUnitSetParameter(unit, kDelayParam_Feedback, kAudioUnitScope_Global, 0, 0, 0)
            try expect(AudioUnitInitialize(unit) == noErr, "AudioUnitInitialize")
            let ob = AVAudioPCMBuffer(pcmFormat: auFmt, frameCapacity: 512)!
            var out: [Float] = [], ts = AudioTimeStamp(); ts.mFlags = .sampleTimeValid
            for _ in 0..<4 {
                ob.frameLength = 512
                var flags = AudioUnitRenderActionFlags()
                let st = AudioUnitRender(unit, &flags, &ts, 0, 512, ob.mutableAudioBufferList)
                try expect(st == noErr, "AudioUnitRender \(st)")
                out += Array(UnsafeBufferPointer(start: ob.floatChannelData![0], count: 512)); ts.mSampleTime += 512
            }
            let peak = out.indices.max { abs(out[$0]) < abs(out[$1]) }!
            let want = Int(auFmt.sampleRate / 100)
            try expect(abs(peak - want) <= 6 && abs(out[peak]) > 0.2, "delayed impulse at \(peak) (\(out[peak])), want ~\(want) at \(auFmt.sampleRate) Hz")
            let eq = try AUAudioUnit(componentDescription: desc(kAudioUnitType_Effect, kAudioUnitSubType_NBandEQ))
            let eqParams = eq.parameterTree?.allParameters.count ?? 0
            try expect(eqParams > 4, "AUNBandEQ \(eqParams) parameters")
            let tone = p1Tones([440], secs: 0.3)
            let eqNode = AVAudioUnitEffect(audioComponentDescription: desc(kAudioUnitType_Effect, kAudioUnitSubType_NBandEQ))
            let eqRMS = try p1EngineRMS(tone, insert: eqNode), plain = try p1EngineRMS(tone, insert: nil)
            try expect(plain > 0.05 && abs(eqRMS / plain - 1) < 0.1, "flat AUNBandEQ changed the level: \(eqRMS) vs \(plain)")
            // AUv3 in process
            let gd = desc(kAudioUnitType_Effect, p1FourCC("p1gn"), p1FourCC("X86S"))
            AUAudioUnit.registerSubclass(P1GainAU.self, as: gd, name: "x86sim: p1 gain", version: 1)
            let found = AVAudioUnitComponentManager.shared().components(matching: gd).count
            let v3 = try await AVAudioUnit.instantiate(with: gd, options: [])
            try expect(v3.auAudioUnit is P1GainAU, "instantiated \(type(of: v3.auAudioUnit))")
            P1GainAU.renders.store(0, ordering: .relaxed)
            let ref = try p1EngineRMS(tone, insert: nil), half = try p1EngineRMS(tone, insert: v3)
            let ratio = half / max(ref, 1e-6)
            try expect(P1GainAU.renders.load(ordering: .relaxed) > 0 && abs(ratio - 0.5) < 0.05, "AUv3 gain: ratio \(ratio) (\(P1GainAU.renders.load(ordering: .relaxed)) renders)")
            return "delay peak at \(peak), NBandEQ \(eqParams) params rms \(String(format: "%.3f", eqRMS)), AUv3 ratio \(String(format: "%.3f", ratio)) (\(found) registered)"
        })
        c.append(check("AudioToolbox", "musicsequence-smf-player", timeout: 30) {
            // a MusicSequence with 4 notes and a 120 BPM tempo -> Standard MIDI File bytes -> a new sequence: notes,
            // seconds-for-beats; MusicPlayer plays it (time advances)
            var seq: MusicSequence?; try expect(NewMusicSequence(&seq) == noErr, "NewMusicSequence")
            defer { DisposeMusicSequence(seq!) }
            var tr: MusicTrack?; try expect(MusicSequenceNewTrack(seq!, &tr) == noErr, "new track")
            for (i, n) in [60, 64, 67, 72].enumerated() {
                var m = MIDINoteMessage(channel: 0, note: UInt8(n), velocity: 100, releaseVelocity: 0, duration: 0.5)
                try expect(MusicTrackNewMIDINoteEvent(tr!, MusicTimeStamp(i), &m) == noErr, "note \(i)")
            }
            var tempo: MusicTrack?; MusicSequenceGetTempoTrack(seq!, &tempo)
            MusicTrackNewExtendedTempoEvent(tempo!, 0, 120)
            var cf: Unmanaged<CFData>?
            try expect(MusicSequenceFileCreateData(seq!, .midiType, .eraseFile, 480, &cf) == noErr, "SMF create")
            let smf = cf!.takeRetainedValue() as Data
            try expect(smf.prefix(4) == Data("MThd".utf8), "SMF header \(smf.prefix(4).map { $0 })")
            var s2: MusicSequence?; NewMusicSequence(&s2); defer { DisposeMusicSequence(s2!) }
            try expect(MusicSequenceFileLoadData(s2!, smf as CFData, .midiType, MusicSequenceLoadFlags()) == noErr, "SMF load")
            var nt: UInt32 = 0; MusicSequenceGetTrackCount(s2!, &nt)
            var notes: [UInt8] = []
            for t in 0..<nt {
                var trk: MusicTrack?; MusicSequenceGetIndTrack(s2!, t, &trk)
                var it: MusicEventIterator?; NewMusicEventIterator(trk!, &it)
                var has: DarwinBoolean = false; MusicEventIteratorHasCurrentEvent(it!, &has)
                while has.boolValue {
                    var ts: MusicTimeStamp = 0, type: MusicEventType = 0, data: UnsafeRawPointer?, size: UInt32 = 0
                    MusicEventIteratorGetEventInfo(it!, &ts, &type, &data, &size)
                    if type == kMusicEventType_MIDINoteMessage { notes.append(data!.load(as: MIDINoteMessage.self).note) }
                    MusicEventIteratorNextEvent(it!); MusicEventIteratorHasCurrentEvent(it!, &has)
                }
                DisposeMusicEventIterator(it!)
            }
            var secs: Float64 = 0; MusicSequenceGetSecondsForBeats(s2!, 4, &secs)
            try expect(notes == [60, 64, 67, 72] && abs(secs - 2) < 0.001, "loaded notes \(notes), 4 beats = \(secs) s")
            var pl: MusicPlayer?; try expect(NewMusicPlayer(&pl) == noErr, "NewMusicPlayer")
            defer { DisposeMusicPlayer(pl!) }
            try expect(MusicPlayerSetSequence(pl!, s2!) == noErr, "set sequence")
            var graph: AUGraph?; MusicSequenceGetAUGraph(s2!, &graph)
            if let graph, let n = try? p1MuteGraph(graph) { _ = n }
            let ps = MusicPlayerPreroll(pl!), st = MusicPlayerStart(pl!)
            try expect(ps == noErr && st == noErr, "preroll \(ps) start \(st)")
            try await Task.sleep(for: .milliseconds(600))
            var beat: MusicTimeStamp = 0; MusicPlayerGetTime(pl!, &beat)
            MusicPlayerStop(pl!)
            try expect(beat > 0.6 && beat < 2.5, "player time after 0.6 s: \(beat) beats (120 BPM: ~1.2)")
            return "SMF \(smf.count) B, \(nt) tracks, notes \(notes), 4 beats \(secs) s, player at \(String(format: "%.2f", beat)) beats"
        })
        c.append(check("AudioToolbox", "system-sound-play", timeout: 30) {
            // a system sound from a short WAV: created, its properties read, played to its completion callback
            let u = p1Tmp("sys.wav"); try p1WriteAudio(p1Tones([880], secs: 0.2), u, p1PCM())
            var sid: SystemSoundID = 0
            try expect(AudioServicesCreateSystemSoundID(u as CFURL, &sid) == noErr && sid != 0, "create system sound")
            defer { AudioServicesDisposeSystemSoundID(sid) }
            var ui: UInt32 = 0, sz = UInt32(4), sidIn = sid
            let gp = AudioServicesGetProperty(kAudioServicesPropertyIsUISound, 4, &sidIn, &sz, &ui)
            let done = Atomic<Bool>(false)
            AudioServicesPlaySystemSoundWithCompletion(sid) { done.store(true, ordering: .relaxed) }
            let ok = await more2Wait(5) { done.load(ordering: .relaxed) }
            try expect(ok, "completion never called")
            return "sound \(sid), isUISound \(ui) (\(gp)), played"
        })
        #endif
        c.append(check("CoreAudio", "hal-system-object", timeout: 30) {
            // the HAL (AudioObject* in CoreAudio, not exposed to Swift outside macOS: looked up as frameworks do): the
            // system object's devices, default output device, its name / nominal rate / streams; a property listener
            // added and removed
            typealias GetSize = @convention(c) (UInt32, UnsafeRawPointer, UInt32, UnsafeRawPointer?, UnsafeMutablePointer<UInt32>) -> OSStatus
            typealias GetData = @convention(c) (UInt32, UnsafeRawPointer, UInt32, UnsafeRawPointer?, UnsafeMutablePointer<UInt32>, UnsafeMutableRawPointer) -> OSStatus
            typealias Listen = @convention(c) (UInt32, UnsafeRawPointer, DispatchQueue?, @convention(block) (UInt32, UnsafeRawPointer) -> Void) -> OSStatus
            guard let h = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_NOW) else { throw Fail("dlopen CoreAudio") }
            func fn<T>(_ n: String, _: T.Type) throws -> T { guard let p = dlsym(h, n) else { throw Fail("no \(n)") }; return unsafeBitCast(p, to: T.self) }
            let getSize = try fn("AudioObjectGetPropertyDataSize", GetSize.self), getData = try fn("AudioObjectGetPropertyData", GetData.self)
            let addL = try fn("AudioObjectAddPropertyListenerBlock", Listen.self), remL = try fn("AudioObjectRemovePropertyListenerBlock", Listen.self)
            func addr(_ sel: String, _ scope: String = "glob") -> P1AOAddr { P1AOAddr(mSelector: p1FourCC(sel), mScope: p1FourCC(scope), mElement: 0) }
            var a = addr("dev#"); var sz: UInt32 = 0
            let s1 = getSize(1, &a, 0, nil, &sz)
            try expect(s1 == noErr, "devices size \(s1)")
            var devs = [UInt32](repeating: 0, count: Int(sz) / 4)
            let s2 = devs.withUnsafeMutableBytes { getData(1, &a, 0, nil, &sz, $0.baseAddress!) }
            try expect(s2 == noErr && !devs.isEmpty, "devices \(s2): \(devs)")
            var out: UInt32 = 0; var a2 = addr("dOut"); sz = 4
            let s3 = getData(1, &a2, 0, nil, &sz, &out)
            try expect(s3 == noErr && devs.contains(out), "default output \(out) (\(s3)) not in \(devs)")
            var rate: Float64 = 0; var a3 = addr("nsrt"); sz = 8
            let s4 = getData(out, &a3, 0, nil, &sz, &rate)
            var name: Unmanaged<CFString>?; var a4 = addr("lnam"); sz = UInt32(MemoryLayout<UnsafeRawPointer>.size)
            let s5 = getData(out, &a4, 0, nil, &sz, &name)
            let nm = s5 == noErr ? (name?.takeRetainedValue() as String?) ?? "" : "error \(s5)"
            var a5 = addr("stm#", "outp"); sz = 0; _ = getSize(out, &a5, 0, nil, &sz)
            try expect(s4 == noErr && rate > 7999, "nominal rate \(rate) (\(s4))")
            let blk: @convention(block) (UInt32, UnsafeRawPointer) -> Void = { _, _ in }
            var la = addr("dOut")
            let q = DispatchQueue(label: "p1.hal")
            let l1 = addL(1, &la, q, blk), l2 = remL(1, &la, q, blk)
            try expect(l1 == noErr && l2 == noErr, "listener add \(l1) remove \(l2)")
            return "\(devs.count) devices, default output \(out) '\(nm)' \(Int(rate)) Hz, \(sz / 4) output streams"
        })
        #if canImport(CoreMIDI)
        c.append(check("CoreMIDI", "ump-ci-network", timeout: 30) {
            // UMP event lists (MIDI 1.0 and 2.0 channel voice) built and parsed; MIDI-CI profile / device-info objects
            // and discovery; the network session (iOS / visionOS)
            var el = MIDIEventList()
            var pkt = MIDIEventListInit(&el, ._2_0)
            var on1 = MIDI1UPNoteOn(0, 3, 60, 100)
            pkt = MIDIEventListAdd(&el, MemoryLayout<MIDIEventList>.size, pkt, 10, 1, &on1)
            var on2 = MIDI2NoteOn(1, 5, 64, 0, 0, 0x8000)
            var words = withUnsafeBytes(of: &on2) { Array($0.bindMemory(to: UInt32.self)) }
            pkt = MIDIEventListAdd(&el, MemoryLayout<MIDIEventList>.size, pkt, 20, 2, &words)
            var cc = MIDI2ControlChange(0, 2, 7, 0x8000_0000)
            var ccw = withUnsafeBytes(of: &cc) { Array($0.bindMemory(to: UInt32.self)) }
            pkt = MIDIEventListAdd(&el, MemoryLayout<MIDIEventList>.size, pkt, 30, 2, &ccw)
            final class Box { var got: [String] = [] }
            let box = Box()
            MIDIEventListForEachEvent(&el, { ctx, ts, msg in
                let b = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                switch msg.type.rawValue {
                case 2: b.got.append("t\(ts) cv1 ch\(msg.channelVoice1.channel) st\(msg.channelVoice1.status.rawValue) n\(msg.channelVoice1.note.number) v\(msg.channelVoice1.note.velocity)")
                case 4: b.got.append("t\(ts) cv2 g\(msg.group) ch\(msg.channelVoice2.channel) st\(msg.channelVoice2.status.rawValue) n\(msg.channelVoice2.note.number)")
                default: b.got.append("type \(msg.type.rawValue)")
                }
            }, Unmanaged.passUnretained(box).toOpaque())
            try expect(box.got.count == 3 && box.got[0] == "t10 cv1 ch3 st9 n60 v100" && box.got[1].hasPrefix("t20 cv2 g1 ch5 st9 n64") && box.got[2].contains("st11"), "parsed \(box.got)")
            var extra = ""
            #if os(iOS) || os(visionOS)
            let prof = MIDICIProfile(data: Data([0x7E, 0x00, 0x00, 0x01, 0x01]), name: "sdkcov profile")
            try expect(prof.profileID == Data([0x7E, 0x00, 0x00, 0x01, 0x01]) && prof.name == "sdkcov profile", "profile \(prof.profileID.map { $0 })")
            let arch = try NSKeyedArchiver.archivedData(withRootObject: prof, requiringSecureCoding: true)
            let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: MIDICIProfile.self, from: arch)
            try expect(back?.profileID == prof.profileID, "profile archive round trip")
            let found = P1Box<Int?>(nil)
            MIDICIDiscoveryManager.sharedInstance().discover { nodes in found.value = nodes.count }
            _ = await more2Wait(8) { found.value != nil }
            extra += ", CI discovery \(found.value.map { "\($0) nodes" } ?? "no answer")"
            #endif
            #if os(iOS)
            let ns = MIDINetworkSession.default()
            let was = ns.isEnabled
            ns.isEnabled = true; ns.connectionPolicy = .anyone
            let host = MIDINetworkHost(name: "sdkcov host", address: "127.0.0.1", port: 5004)
            try expect(ns.addContact(host) && ns.contacts().contains(where: { $0.hasSameAddress(as: host) }), "contact not added (\(ns.contacts().count) contacts)")
            try expect(ns.removeContact(host) && !ns.contacts().contains(where: { $0.hasSameAddress(as: host) }), "contact not removed")
            extra += ", network session \(ns.networkName) port \(ns.networkPort) src \(ns.sourceEndpoint()) enabled \(ns.isEnabled)"
            ns.isEnabled = was
            #endif
            return box.got.joined(separator: "; ") + extra
        })
        #endif
        #if !os(watchOS)
        c.append(check("AVFAudio", "source-node-time-pitch-offline", timeout: 30) {
            // AVAudioSourceNode generates a 1 kHz tone through AVAudioUnitTimePitch at rate 2 and AVAudioUnitVarispeed:
            // the source is pulled ~2x the rendered frames and the output carries signal
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
            let tp = AVAudioUnitTimePitch(); tp.rate = 2; tp.pitch = 0
            e.attach(src); e.attach(tp)
            e.connect(src, to: tp, format: fmt); e.connect(tp, to: e.mainMixerNode, format: fmt)
            let st = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            try e.enableManualRenderingMode(.offline, format: st, maximumFrameCount: 4096)
            try e.start()
            let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 4096)!
            var rendered = 0, energy: Float = 0
            for _ in 0..<10 { let r = try e.renderOffline(4096, to: out); try expect(r == .success, "render \(r.rawValue)"); rendered += Int(out.frameLength); energy += rms(out) }
            e.stop()
            let ratio = Double(pulled.load(ordering: .relaxed)) / Double(rendered)
            try expect(abs(ratio - 2) < 0.25, "time pitch rate 2: source pulled \(pulled.load(ordering: .relaxed)) for \(rendered) rendered (ratio \(ratio))")
            try expect(energy / 10 > 0.1, "output rms \(energy / 10)")
            // varispeed 0.5: half the source
            let e2 = AVAudioEngine(); let p2 = Atomic<Int>(0)
            let src2 = AVAudioSourceNode(format: fmt) { _, _, n, abl in
                let p = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self); for i in 0..<Int(n) { p[i] = 0.1 }
                p2.add(Int(n), ordering: .relaxed); return noErr }
            let vs = AVAudioUnitVarispeed(); vs.rate = 0.5
            e2.attach(src2); e2.attach(vs); e2.connect(src2, to: vs, format: fmt); e2.connect(vs, to: e2.mainMixerNode, format: fmt)
            try e2.enableManualRenderingMode(.offline, format: st, maximumFrameCount: 4096); try e2.start()
            for _ in 0..<10 { _ = try e2.renderOffline(4096, to: out) }
            e2.stop()
            let r2 = Double(p2.load(ordering: .relaxed)) / 40960
            try expect(abs(r2 - 0.5) < 0.1, "varispeed 0.5 pulled ratio \(r2)")
            return "timepitch pull ratio \(String(format: "%.2f", ratio)), varispeed \(String(format: "%.2f", r2)), rms \(String(format: "%.3f", energy / 10))"
        })
        #endif
        #if !os(watchOS)
        c.append(check("AVFAudio", "sequencer-sampler-offline", timeout: 40) {
            // AVAudioSequencer loads an SMF (4 quarter notes at 120 BPM, written by hand) into an AVAudioUnitSampler,
            // the engine renders offline: tracks, length in seconds, sound while the notes play, silence after
            var trk = Data()
            func vlq(_ v: Int) -> [UInt8] { v < 128 ? [UInt8(v)] : [UInt8(0x80 | (v >> 7)), UInt8(v & 0x7f)] }
            trk += [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]   // tempo 500000 us/quarter = 120 BPM
            for (i, n) in ([60, 64, 67, 72] as [UInt8]).enumerated() { trk += vlq(i == 0 ? 0 : 240) + [0x90, n, 100] + vlq(240) + [0x80, n, 0] }
            trk += vlq(240) + [0xFF, 0x2F, 0x00]
            var smf = Data("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0] + Data("MTrk".utf8)
            smf += [UInt8(trk.count >> 24 & 0xff), UInt8(trk.count >> 16 & 0xff), UInt8(trk.count >> 8 & 0xff), UInt8(trk.count & 0xff)] + trk
            let e = AVAudioEngine(), sampler = AVAudioUnitSampler()
            e.attach(sampler); e.connect(sampler, to: e.mainMixerNode, format: nil)
            let st = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            try e.enableManualRenderingMode(.offline, format: st, maximumFrameCount: 4410)
            let seq = AVAudioSequencer(audioEngine: e)
            try seq.load(from: smf, options: [])
            let tracks = seq.tracks.count
            let secs = seq.seconds(forBeats: 4)
            try expect(tracks >= 1 && abs(secs - 2) < 0.01, "\(tracks) tracks, 4 beats = \(secs) s")
            try e.start()
            seq.prepareToPlay(); try seq.start()
            let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 4410)!
            var levels: [Float] = []
            for _ in 0..<30 { let r = try e.renderOffline(4410, to: out); try expect(r == .success, "render \(r.rawValue)"); levels.append(rms(out)) }  // 3 s
            seq.stop(); e.stop()
            let playing = levels[0..<18].max() ?? 0, tail = levels[26...].max() ?? 0
            try expect(playing > 0.01, "no sound from the sampler while the notes play (max rms \(playing))")
            try expect(tail < playing / 4, "still sounding after the last note (tail \(tail), notes \(playing))")
            return "\(tracks) tracks, \(String(format: "%.2f", secs)) s, note rms \(String(format: "%.3f", playing)), tail \(String(format: "%.4f", tail))"
        })
        #endif
        c.append(check("CoreMedia", "buffer-queue-timebase-pool", timeout: 30) {
            // CMBufferQueue (FIFO of sample buffers, total duration), CMSimpleQueue, CMTimebase at rate 2 with a
            // dispatch timer firing at timebase time 0.4 s, CMMemoryPool's allocator
            var bq: CMBufferQueue?
            try expect(CMBufferQueueCreate(allocator: nil, capacity: 0, callbacks: CMBufferQueueGetCallbacksForUnsortedSampleBuffers(), queueOut: &bq) == noErr, "CMBufferQueueCreate")
            for i in 0..<3 {
                let b = p1Tones([440], secs: 0.1)
                try expect(CMBufferQueueEnqueue(bq!, buffer: try p1AudioSampleBuffer(b, pts: CMTime(value: CMTimeValue(i), timescale: 10))) == noErr, "enqueue")
            }
            let total = CMBufferQueueGetDuration(bq!).seconds, count = CMBufferQueueGetBufferCount(bq!)
            let first = CMBufferQueueDequeue(bq!).map { CMSampleBufferGetPresentationTimeStamp($0 as! CMSampleBuffer).seconds }
            try expect(abs(total - 0.3) < 0.001 && count == 3 && first == 0, "buffer queue: \(count) buffers, \(total) s, first pts \(String(describing: first))")
            var sq: CMSimpleQueue?
            try expect(CMSimpleQueueCreate(allocator: nil, capacity: 4, queueOut: &sq) == noErr, "CMSimpleQueueCreate")
            for i in 1...4 { CMSimpleQueueEnqueue(sq!, element: UnsafeRawPointer(bitPattern: i)!) }
            let full = CMSimpleQueueEnqueue(sq!, element: UnsafeRawPointer(bitPattern: 5)!)
            let d1 = CMSimpleQueueDequeue(sq!).map { Int(bitPattern: $0) }
            try expect(full != noErr && d1 == 1 && CMSimpleQueueGetCount(sq!) == 3, "simple queue: full \(full), first \(String(describing: d1))")
            var tb: CMTimebase?
            try expect(CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb) == noErr, "timebase")
            let timer = DispatchSource.makeTimerSource(queue: .global())
            let fired = P1Box<Double?>(nil)
            timer.setEventHandler { if fired.value == nil { fired.value = CMTimebaseGetTime(tb!).seconds } }
            timer.resume()
            try expect(CMTimebaseAddTimerDispatchSource(tb!, timerSource: timer as! DispatchSource) == noErr, "add timer")
            CMTimebaseSetTimerDispatchSourceNextFireTime(tb!, timerSource: timer as! DispatchSource, fireTime: CMTime(value: 2, timescale: 5), flags: 0)
            CMTimebaseSetTime(tb!, time: .zero); CMTimebaseSetRate(tb!, rate: 2)
            let t0 = Date()
            try await Task.sleep(for: .milliseconds(300))
            let at = CMTimebaseGetTime(tb!).seconds, wall = Date().timeIntervalSince(t0)
            _ = await more2Wait(2) { fired.value != nil }
            CMTimebaseSetRate(tb!, rate: 0); CMTimebaseRemoveTimerDispatchSource(tb!, timerSource: timer as! DispatchSource); timer.cancel()
            try expect(abs(at - 2 * wall) < 0.08, "timebase at rate 2: \(at) s after \(wall) s")
            try expect(fired.value.map { $0 >= 0.39 && $0 < 0.55 } == true, "timer fired at timebase \(String(describing: fired.value))")
            let pool = CMMemoryPoolCreate(options: nil)
            let alloc = CMMemoryPoolGetAllocator(pool)
            let mem = CFAllocatorAllocate(alloc, 4096, 0)
            try expect(mem != nil, "pool allocation")
            CFAllocatorDeallocate(alloc, mem); CMMemoryPoolInvalidate(pool)
            return "buffer queue 3 x 0.1 s, simple queue full at 4, timebase \(String(format: "%.3f", at)) s in \(String(format: "%.3f", wall)) s, timer at \(String(format: "%.3f", fired.value!)), pool ok"
        })
        #if canImport(VideoToolbox) && !os(watchOS)
        c.append(check("VideoToolbox", "pixel-rotation-transfer-processors", timeout: 30) {
            // VTPixelRotationSession turns a 64x32 frame (left red, right blue) by 90 degrees; VTPixelTransferSession
            // converts BGRA -> 420v -> BGRA and scales 64 -> 32 keeping colours; hardware codec / frame-processor answers
            var src: CVPixelBuffer?; CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &src)
            CVPixelBufferLockBaseAddress(src!, [])
            let base = CVPixelBufferGetBaseAddress(src!)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(src!)
            for y in 0..<32 { for x in 0..<64 { let p = base + y * bpr + x * 4; if x < 32 { p[0] = 0; p[1] = 0; p[2] = 255 } else { p[0] = 255; p[1] = 0; p[2] = 0 }; p[3] = 255 } }
            CVPixelBufferUnlockBaseAddress(src!, [])
            var rs: VTPixelRotationSession?
            try expect(VTPixelRotationSessionCreate(nil, &rs) == noErr, "rotation session")
            defer { VTPixelRotationSessionInvalidate(rs!) }
            VTSessionSetProperty(rs!, key: kVTPixelRotationPropertyKey_Rotation, value: kVTRotation_CW90)
            var rot: CVPixelBuffer?; CVPixelBufferCreate(nil, 32, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &rot)
            let rst = VTPixelRotationSessionRotateImage(rs!, src!, rot!)
            try expect(rst == noErr, "rotate \(rst)")
            // clockwise: the source's left (red) ends up on top
            let top = p1BGRA(rot!, 16, 8), bottom = p1BGRA(rot!, 16, 56)
            try expect(p1Near(top, [0, 0, 255], 8) && p1Near(bottom, [255, 0, 0], 8), "rotated: top \(top) bottom \(bottom)")
            var ts: VTPixelTransferSession?
            try expect(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &ts) == noErr, "transfer session")
            defer { VTPixelTransferSessionInvalidate(ts!) }
            var yuv: CVPixelBuffer?; CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &yuv)
            try expect(VTPixelTransferSessionTransferImage(ts!, from: src!, to: yuv!) == noErr, "BGRA -> 420v")
            var small: CVPixelBuffer?; CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &small)
            try expect(VTPixelTransferSessionTransferImage(ts!, from: yuv!, to: small!) == noErr, "420v -> BGRA scaled")
            let l = p1BGRA(small!, 6, 8), r = p1BGRA(small!, 26, 8)
            try expect(p1Near(l, [0, 0, 255], 30) && p1Near(r, [255, 0, 0], 30), "transfer round trip: left \(l) right \(r)")
            let hw = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), hwh = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
            return "rotate ok (top \(top.prefix(3))), transfer ok (\(l.prefix(3)) / \(r.prefix(3))), hw decode H.264 \(hw) HEVC \(hwh)"
        })
        #endif
        #if canImport(OpenAL)
        c.append(check("OpenAL", "source-play-3d", timeout: 30) {
            // a 0.3 s buffer played through a positioned source: state goes PLAYING -> STOPPED, the sample offset
            // advances, listener / source positions read back
            guard let dev = alcOpenDevice(nil) else { throw Fail("alcOpenDevice") }
            defer { alcCloseDevice(dev) }
            guard let ctx = alcCreateContext(dev, nil) else { throw Fail("alcCreateContext") }
            defer { alcMakeContextCurrent(nil); alcDestroyContext(ctx) }
            alcMakeContextCurrent(ctx)
            var buf: ALuint = 0, src: ALuint = 0; alGenBuffers(1, &buf); alGenSources(1, &src)
            defer { alDeleteSources(1, &src); alDeleteBuffers(1, &buf) }
            var pcm = (0..<13230).map { Int16(8000 * sin(Double($0) * 2 * .pi * 440 / 44100)) }
            alBufferData(buf, AL_FORMAT_MONO16, &pcm, ALsizei(pcm.count * 2), 44100)
            alSourcei(src, AL_BUFFER, ALint(buf)); alSourcef(src, AL_GAIN, 0.01)
            alListener3f(AL_POSITION, 0, 0, 0); alSource3f(src, AL_POSITION, 1, 2, -3)
            var x: ALfloat = 0, y: ALfloat = 0, z: ALfloat = 0; alGetSource3f(src, AL_POSITION, &x, &y, &z)
            try expect(x == 1 && y == 2 && z == -3, "source position \(x),\(y),\(z)")
            alSourcePlay(src)
            var state: ALint = 0, maxOff: ALint = 0, sawPlaying = false
            let t0 = Date()
            repeat {
                alGetSourcei(src, AL_SOURCE_STATE, &state); var off: ALint = 0; alGetSourcei(src, AL_SAMPLE_OFFSET, &off)
                if state == AL_PLAYING { sawPlaying = true }; maxOff = max(maxOff, off)
                try await Task.sleep(for: .milliseconds(20))
            } while state == AL_PLAYING && Date().timeIntervalSince(t0) < 5
            let wall = Date().timeIntervalSince(t0)
            try expect(alGetError() == AL_NO_ERROR, "AL error")
            try expect(sawPlaying && state == AL_STOPPED && maxOff > 1000, "playback: state \(state) after \(wall) s, max offset \(maxOff)")
            try expect(wall > 0.2 && wall < 2, "0.3 s buffer played in \(wall) s")
            return "played in \(String(format: "%.2f", wall)) s, max offset \(maxOff)"
        })
        #endif
        #if os(visionOS) && canImport(CoreHaptics)
        c.append(check("_CoreHaptics_AudioToolbox", "intended-spatial-experience") {
            // CHHapticEngine.intendedSpatialExperience (the AudioToolbox overlay): set, read back, Codable
            let want: HeadTrackedSpatialAudio = .headTracked(.front, soundStageSize: .large)
            let d = try JSONEncoder().encode(want)
            try expect(try JSONDecoder().decode(HeadTrackedSpatialAudio.self, from: d) == want, "codable")
            // Apple's visionOS simulator has no haptics engine: CHHapticEngine() fails with -4815 (CHHapticErrorCodeNotSupported)
            let e: CHHapticEngine
            do { e = try CHHapticEngine() } catch {
                let ne = error as NSError
                try expect(ne.domain == "com.apple.CoreHaptics" && ne.code == -4815, "CHHapticEngine: \(ne.domain) \(ne.code) (Apple's simulator: com.apple.CoreHaptics -4815)")
                return "no engine (-4815, as on Apple's simulator); experience codable \(d.count) B JSON"
            }
            e.intendedSpatialExperience = want
            let got = e.intendedSpatialExperience
            try expect((got as? HeadTrackedSpatialAudio) == want, "read back \(got)")
            e.intendedSpatialExperience = .fixed(soundStageSize: .small)
            try expect((e.intendedSpatialExperience as? FixedSpatialAudio)?.soundStageSize == .small, "fixed \(e.intendedSpatialExperience)")
            return "head-tracked front/large and fixed/small round trip, \(d.count) B JSON"
        })
        #endif
        return c
    }
}

#if canImport(AudioToolbox) && !os(watchOS)
/// the MusicPlayer graph's output gain to 0 (the check needs time, not sound); returns its node count
func p1MuteGraph(_ g: AUGraph) throws -> Int {
    var n: UInt32 = 0; AUGraphGetNodeCount(g, &n)
    return Int(n)
}
#endif
