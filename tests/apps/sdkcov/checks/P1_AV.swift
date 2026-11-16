// sdkcov P1 (media & AV): AVFoundation depth. Editing (custom compositor + Core Image video compositions, export
// sessions on every platform that has them, AVMutableMovie), playback (queue player, looper, seeks, rate, HLS from a
// loopback server with WebVTT subtitles, a custom-scheme resource loader), timed metadata and chapters, the sample-buffer
// renderers under a render synchronizer, asset loading across file formats and the simulator's capture answers.
import Foundation
import Synchronization
import AVFoundation
import CoreMedia
import CoreVideo
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: helpers (shared by the P1 files)

/// a fresh file URL in tmp (any previous file removed)
func p1Tmp(_ name: String) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-p1-\(name)")
    try? FileManager.default.removeItem(at: u)
    return u
}
/// mono float buffer of a sum of sine tones (amplitude 0.5 / tones)
func p1Tones(_ hz: [Double], secs: Double, rate: Double = 44100) -> AVAudioPCMBuffer {
    let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let n = AVAudioFrameCount(secs * rate)
    let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n)!; b.frameLength = n
    let p = b.floatChannelData![0]
    for i in 0..<Int(n) { var s = 0.0; for h in hz { s += sin(2 * .pi * h * Double(i) / rate) }; p[i] = Float(0.5 * s / Double(hz.count)) }
    return b
}
/// write `b` with AVAudioFile `settings` (format by extension)
func p1WriteAudio(_ b: AVAudioPCMBuffer, _ u: URL, _ settings: [String: Any]) throws {
    try? FileManager.default.removeItem(at: u)
    let f = try AVAudioFile(forWriting: u, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try f.write(from: b)
}
/// AAC .m4a settings
let p1AAC: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
/// 16-bit LPCM settings (wav / aiff / caf)
func p1PCM(bigEndian: Bool = false) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
     AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian, AVLinearPCMIsNonInterleaved: false]
}
/// a one-shot / counting box usable from any thread
final class P1Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}
/// BGRA pixel (b, g, r, a) of a pixel buffer
func p1BGRA(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return [Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3])]
}
func p1Near(_ p: [Int], _ q: [Int], _ tol: Int = 40) -> Bool { zip(p, q).allSatisfy { abs($0 - $1) <= tol } }
/// an LPCM float mono CMSampleBuffer of `b`'s frames starting at `pts`
func p1AudioSampleBuffer(_ b: AVAudioPCMBuffer, pts: CMTime) throws -> CMSampleBuffer {
    var fd: CMAudioFormatDescription?
    try expect(CMAudioFormatDescriptionCreate(allocator: nil, asbd: b.format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd) == noErr, "audio format description")
    var sb: CMSampleBuffer?
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(b.format.sampleRate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    try expect(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: CMItemCount(b.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr, "CMSampleBufferCreate")
    try expect(CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: b.audioBufferList) == noErr, "set audio data")
    return sb!
}

#if !os(watchOS)
/// a BGRA pixel buffer filled with (b, g, r)
func p1Solid(_ w: Int, _ h: Int, _ bgr: [UInt8]) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb!)
    for y in 0..<h { for x in 0..<w { let p = base + y * bpr + x * 4; p[0] = bgr[0]; p[1] = bgr[1]; p[2] = bgr[2]; p[3] = 255 } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}
/// write an H.264 movie of `frames` frames at 30 fps, frame i filled with color(i) (b, g, r); optional AAC audio track,
/// asset metadata and a timed-metadata track (`timed`: (start s, duration s, title) groups), with a chapter list track
/// associated to the video when `chapters`
func p1Movie(_ url: URL, frames: Int = 30, size: Int = 128, type: AVFileType = .mov, audio: Bool = false,
             metadata: [AVMetadataItem] = [], timed: [(Double, Double, String)] = [], chapters: Bool = false,
             color: (Int) -> [UInt8] = { _ in [255, 0, 0] }) async throws {
    try? FileManager.default.removeItem(at: url)
    let w = try AVAssetWriter(outputURL: url, fileType: type)
    w.metadata = metadata
    let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: nil)
    w.add(vin)
    var ain: AVAssetWriterInput?
    if audio {
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: p1AAC); a.expectsMediaDataInRealTime = false
        w.add(a); ain = a
    }
    var metaIn: AVAssetWriterInput?, mad: AVAssetWriterInputMetadataAdaptor?
    if !timed.isEmpty {
        // a metadata track: one item per group (title), format description from the item's identifier
        let spec: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: AVMetadataIdentifier.quickTimeMetadataTitle.rawValue,
                                   kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_UTF8 as String]
        var fd: CMFormatDescription?
        try expect(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: nil, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &fd) == noErr, "metadata format description")
        let m = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: fd)
        w.add(m); metaIn = m; mad = AVAssetWriterInputMetadataAdaptor(assetWriterInput: m)
        if chapters { vin.addTrackAssociation(withTrackOf: m, type: AVAssetTrack.AssociationType.chapterList.rawValue) }
    }
    try expect(w.startWriting(), "startWriting: \(String(describing: w.error))")
    w.startSession(atSourceTime: .zero)
    for i in 0..<frames {
        while !vin.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        try expect(ad.append(p1Solid(size, size, color(i)), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)), "append frame \(i): \(String(describing: w.error))")
    }
    vin.markAsFinished()
    if let ain {
        let secs = Double(frames) / 30, b = p1Tones([440], secs: secs)
        // AAC input wants 1024-frame chunks or more: give it the whole buffer in 4096-frame sample buffers
        var off = 0
        while off < Int(b.frameLength) {
            let n = min(4096, Int(b.frameLength) - off)
            let part = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(n))!; part.frameLength = AVAudioFrameCount(n)
            memcpy(part.floatChannelData![0], b.floatChannelData![0] + off, n * 4)
            while !ain.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            try expect(ain.append(try p1AudioSampleBuffer(part, pts: CMTime(value: CMTimeValue(off), timescale: 44100))), "append audio: \(String(describing: w.error))")
            off += n
        }
        ain.markAsFinished()
    }
    if let metaIn, let mad {
        for (s, d, title) in timed {
            let it = AVMutableMetadataItem(); it.identifier = .quickTimeMetadataTitle; it.value = title as NSString; it.dataType = kCMMetadataBaseDataType_UTF8 as String
            let g = AVTimedMetadataGroup(items: [it], timeRange: CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), duration: CMTime(seconds: d, preferredTimescale: 600)))
            while !metaIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            try expect(mad.append(g), "append metadata group: \(String(describing: w.error))")
        }
        metaIn.markAsFinished()
    }
    await w.finishWriting()
    try expect(w.status == .completed, "finishWriting: \(String(describing: w.error))")
}
/// decode the frame nearest `t` of `asset` (through `vc` when given) as BGRA
func p1Frame(_ asset: AVAsset, at t: Double, composition vc: AVVideoComposition? = nil) async throws -> CVPixelBuffer {
    let r = try AVAssetReader(asset: asset)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let out: AVAssetReaderOutput
    if let vc { let o = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: attrs); o.videoComposition = vc; out = o }
    else { out = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: attrs) }
    r.add(out)
    try expect(r.startReading(), "reader: \(String(describing: r.error))")
    var best: CVPixelBuffer?
    while let sb = out.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        best = pb
        if CMSampleBufferGetPresentationTimeStamp(sb).seconds >= t { break }
    }
    r.cancelReading()
    guard let best else { throw Fail("no frame decoded (\(r.status.rawValue) \(String(describing: r.error)))") }
    return best
}

/// a custom compositor: the left half of each frame is the source, the right half solid green
final class P1Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let requests = Atomic<Int>(0)
    var sourcePixelBufferAttributes: [String: any Sendable]? { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        P1Compositor.requests.add(1, ordering: .relaxed)
        guard let id = req.sourceTrackIDs.first?.int32Value, let src = req.sourceFrame(byTrackID: id), let dst = req.renderContext.newPixelBuffer() else {
            req.finish(with: NSError(domain: "sdkcov", code: 1)); return
        }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        let w = CVPixelBufferGetWidth(dst), h = CVPixelBufferGetHeight(dst)
        let sb = CVPixelBufferGetBaseAddress(src)!.assumingMemoryBound(to: UInt8.self), db = CVPixelBufferGetBaseAddress(dst)!.assumingMemoryBound(to: UInt8.self)
        let sr = CVPixelBufferGetBytesPerRow(src), dr = CVPixelBufferGetBytesPerRow(dst)
        for y in 0..<h { for x in 0..<w {
            let d = db + y * dr + x * 4
            if x < w / 2 { let s = sb + y * sr + x * 4; d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255 }
            else { d[0] = 0; d[1] = 255; d[2] = 0; d[3] = 255 }
        } }
        CVPixelBufferUnlockBaseAddress(dst, []); CVPixelBufferUnlockBaseAddress(src, .readOnly)
        req.finish(withComposedVideoFrame: dst)
    }
}

/// the HLS fixture: a 2 s 128x128 H.264 video cut into 1 s fMP4 segments by AVAssetWriter (Apple HLS profile), a
/// WebVTT subtitle rendition, served from a loopback More2HTTP
final class P1HLS: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    var initSeg = Data(), segs: [(Data, Double)] = []
    func assetWriter(_ w: AVAssetWriter, didOutputSegmentData d: Data, segmentType t: AVAssetSegmentType, segmentReport r: AVAssetSegmentReport?) {
        if t == .initialization { initSeg = d }
        else { segs.append((d, r?.trackReports.first?.duration.seconds ?? 1)) }
    }
    func make() async throws {
        let w = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(value: 1, timescale: 1)
        w.initialSegmentStartTime = .zero
        w.delegate = self
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 15, AVVideoAllowFrameReorderingKey: false]])
        vin.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: nil)
        w.add(vin)
        try expect(w.startWriting(), "HLS writer: \(String(describing: w.error))")
        w.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !vin.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            try expect(ad.append(p1Solid(128, 128, i < 30 ? [255, 0, 0] : [0, 0, 255]), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)), "HLS frame \(i): \(String(describing: w.error))")
        }
        vin.markAsFinished()
        await w.finishWriting()
        try expect(w.status == .completed && !initSeg.isEmpty && segs.count >= 2, "HLS writer: status \(w.status.rawValue), init \(initSeg.count) B, \(segs.count) segments, \(String(describing: w.error))")
    }
    var video: String {
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(segs.map(\.1).max() ?? 1)))\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for (i, (_, d)) in segs.enumerated() { s += "#EXTINF:\(String(format: "%.5f", d)),\nseg\(i).m4s\n" }
        return s + "#EXT-X-ENDLIST\n"
    }
    static let master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=YES,AUTOSELECT=YES,URI=\"subs.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=128x128,SUBTITLES=\"subs\"\nvideo.m3u8\n"
    static let subs = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2.0,\nsubs.vtt\n#EXT-X-ENDLIST\n"
    static let vtt = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n00:00:00.000 --> 00:00:01.900\nsdkcov caption one\n"
    func respond(_ r: More2Req) -> More2Resp {
        switch r.path {
        case "/master.m3u8": return .text(P1HLS.master, type: "application/vnd.apple.mpegurl")
        case "/video.m3u8": return .text(video, type: "application/vnd.apple.mpegurl")
        case "/subs.m3u8": return .text(P1HLS.subs, type: "application/vnd.apple.mpegurl")
        case "/subs.vtt": return .text(P1HLS.vtt, type: "text/vtt")
        case "/init.mp4": return More2Resp("200 OK", [("Content-Type", "video/mp4")], initSeg)
        default:
            if r.path.hasPrefix("/seg"), let i = Int(r.path.dropFirst(4).dropLast(4)), i < segs.count {
                return More2Resp("200 OK", [("Content-Type", "video/iso.segment")], segs[i].0)
            }
            return More2Resp("404 Not Found")
        }
    }
}
final class P1Legible: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    let texts = P1Box<[String]>([])
    func legibleOutput(_ o: AVPlayerItemLegibleOutput, didOutputAttributedStrings s: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime t: CMTime) {
        texts.mutate { $0 += s.map(\.string) }
    }
}
/// serves a file's bytes for a custom URL scheme
final class P1Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let data: Data, type: String
    let infoRequests = Atomic<Int>(0), dataRequests = Atomic<Int>(0)
    init(_ d: Data, type: String) { data = d; self.type = type }
    func resourceLoader(_ l: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource r: AVAssetResourceLoadingRequest) -> Bool {
        if let ci = r.contentInformationRequest {
            infoRequests.add(1, ordering: .relaxed)
            ci.contentType = type; ci.contentLength = Int64(data.count); ci.isByteRangeAccessSupported = true
        }
        if let dr = r.dataRequest {
            dataRequests.add(1, ordering: .relaxed)
            let start = Int(dr.currentOffset != 0 ? dr.currentOffset : dr.requestedOffset)
            let end = dr.requestsAllDataToEndOfResource ? data.count : min(data.count, Int(dr.requestedOffset) + dr.requestedLength)
            if start < end { dr.respond(with: data.subdata(in: start..<end)) }
        }
        r.finishLoading()
        return true
    }
}
final class P1MetaOut: NSObject, AVPlayerItemMetadataOutputPushDelegate, @unchecked Sendable {
    let titles = P1Box<[String]>([])
    func metadataOutput(_ o: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        titles.mutate { for g in groups { for it in g.items { if let s = it.stringValue { $0.append(s) } } } }
    }
}
#endif

extension Registry {
    static var p1: [Check] { p1_av + p1_audio + p1_library + p1_ports }

    static var p1_av: [Check] {
        var c: [Check] = []
        #if !os(watchOS)
        c.append(check("AVFoundation", "video-composition-compositor-ci-export", timeout: 360) {
            // a blue 1 s movie through (1) a custom AVVideoCompositing (left half source, right half green) exported by
            // AVAssetExportSession with asset metadata, and (2) a Core Image filter composition (colour invert: blue ->
            // yellow) read back through AVAssetReaderVideoCompositionOutput; pixels checked in both outputs
            let src = p1Tmp("vc-src.mov")
            try await p1Movie(src, frames: 30, color: { _ in [255, 0, 0] })
            let asset = AVURLAsset(url: src)
            let (dur, vts) = try await asset.load(.duration, .tracks)
            let vt = vts[0]
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = P1Compositor.self
            vc.frameDuration = CMTime(value: 1, timescale: 30); vc.renderSize = CGSize(width: 128, height: 128)
            let ins = AVMutableVideoCompositionInstruction(); ins.timeRange = CMTimeRange(start: .zero, duration: dur)
            ins.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: vt)]
            vc.instructions = [ins]
            #if os(visionOS)
            let presets = AVAssetExportSession.allExportPresets()
            #else
            let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
            #endif
            try expect(presets.contains(AVAssetExportPresetHighestQuality), "presets \(presets)")
            // the custom compositor through AVAssetReaderVideoCompositionOutput (an export with a custom compositor never
            // finished in Apple's tvOS simulator and took minutes in its iOS one)
            P1Compositor.requests.store(0, ordering: .relaxed)
            let pb = try await more2Stage("custom compositor read", 120) { try await p1Frame(asset, at: 0.5, composition: vc) }
            let l = p1BGRA(pb, 20, 64), r = p1BGRA(pb, 108, 64)
            try expect(p1Near(l, [255, 0, 0]) && p1Near(r, [0, 255, 0]), "composited frame left \(l) (blue) right \(r) (green)")
            // a passthrough export with asset metadata
            guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw Fail("no export session") }
            try expect(ex.supportedFileTypes.contains(.mov), "file types \(ex.supportedFileTypes)")
            let title = AVMutableMetadataItem(); title.identifier = .commonIdentifierTitle; title.value = "sdkcov p1 export" as NSString; title.extendedLanguageTag = "und"
            ex.metadata = [title]
            let out = p1Tmp("vc-out.mov")
            try await more2Stage("passthrough export", 60) { try await ex.export(to: out, as: .mov) }
            let back = AVURLAsset(url: out)
            let (d2, meta) = try await back.load(.duration, .commonMetadata)
            try expect(abs(d2.seconds - dur.seconds) < 0.1, "exported \(d2.seconds) s of \(dur.seconds)")
            let t = try await AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
            try expect(t == "sdkcov p1 export", "exported title \(String(describing: t)) in \(meta.count) items")
            let nreq = P1Compositor.requests.load(ordering: .relaxed)
            try expect(nreq >= 10, "compositor saw \(nreq) requests (frames up to 0.5 s)")
            // Core Image
            #if canImport(CoreImage)
            let ci = try await more2Stage("Core Image composition", 20) { try await AVMutableVideoComposition.videoComposition(with: asset) { req in
                let f = CIFilter(name: "CIColorInvert")!; f.setValue(req.sourceImage, forKey: kCIInputImageKey)
                req.finish(with: f.outputImage!, context: nil)
            } }
            let pb2 = try await more2Stage("Core Image composition read", 120) { try await p1Frame(asset, at: 0.5, composition: ci) }
            let px = p1BGRA(pb2, 64, 64)
            // CIColorInvert works on linear values in Core Image's working space: blue (255, 0, 0 BGR) becomes (76, 254, 254),
            // the value Apple's simulator gives too
            try expect(p1Near(px, [76, 254, 254], 12), "CIColorInvert frame \(px) (Apple: 76, 254, 254 BGR)")
            #endif
            return "export \(String(format: "%.2f", d2.seconds)) s, \(nreq) compositor requests, left \(l.prefix(3)) right \(r.prefix(3)), CI \(px.prefix(3)); \(presets.count) presets"
        })
        c.append(check("AVFoundation", "hls-loopback-subtitles", timeout: 90) {
            // HLS: master playlist + fMP4 video (2 x 1 s segments written by AVAssetWriter's HLS profile) + a WebVTT
            // subtitle rendition from a loopback HTTP server; the item gets ready with 2 s, the subtitle option is
            // selectable, playback advances, a legible output receives the cue, the access log lists the segments
            let h = P1HLS(); try await h.make()
            let srv = try More2HTTP { h.respond($0) }; _ = try await srv.start()
            defer { srv.listener.cancel() }
            let item = AVPlayerItem(url: srv.url("/master.m3u8"))
            let leg = AVPlayerItemLegibleOutput(); let ld = P1Legible(); leg.setDelegate(ld, queue: .main); leg.suppressesPlayerRendering = true
            item.add(leg)
            let player = AVPlayer(playerItem: item); player.isMuted = true
            guard await more2Wait(20, { item.status != .unknown }) else { throw Fail("item status stayed unknown; requests \(srv.requests.withLock { $0 })") }
            try expect(item.status == .readyToPlay, "item failed: \(String(describing: item.error)); requests \(srv.requests.withLock { $0 })")
            try expect(abs(item.duration.seconds - 2) < 0.2, "duration \(item.duration.seconds)")
            let asset = item.asset
            let group = try await asset.loadMediaSelectionGroup(for: .legible)
            let en = group?.options.first(where: { $0.extendedLanguageTag == "en" })
            try expect(en != nil, "no English subtitle option in \(group?.options.map(\.displayName) ?? [])")
            item.select(en, in: group!)
            player.play()
            let moved = await more2Wait(10) { player.currentTime().seconds > 1.2 }
            let gotCue = await more2Wait(5) { ld.texts.value.contains { $0.contains("sdkcov caption one") } }
            player.pause()
            try expect(moved, "playback did not advance: \(player.currentTime().seconds) s, rate \(player.rate), \(String(describing: item.error))")
            let reqs = srv.requests.withLock { $0 }
            try expect(reqs.contains { $0.contains("seg1.m4s") } && reqs.contains { $0.contains("init.mp4") }, "segments not fetched: \(reqs)")
            try expect(gotCue, "legible output got \(ld.texts.value) (subtitles requested: \(reqs.contains { $0.contains("subs.vtt") }))")
            let ev = item.accessLog()?.events.count ?? 0
            return "\(h.segs.count) segments, \(reqs.count) requests, played to \(String(format: "%.2f", player.currentTime().seconds)) s, cue \(ld.texts.value.first ?? "-"), \(ev) access-log events"
        })
        c.append(check("AVFoundation", "resource-loader-custom-scheme", timeout: 60) {
            // an AVURLAsset on a custom scheme: AVAssetResourceLoaderDelegate answers the content-information and byte
            // range requests from memory; the asset loads (duration, track), a frame decodes, a player item plays
            let src = p1Tmp("rl.mp4")
            try await p1Movie(src, frames: 30, type: .mp4, color: { _ in [0, 0, 255] })
            let ld = P1Loader(try Data(contentsOf: src), type: UTType.mpeg4Movie.identifier)
            let asset = AVURLAsset(url: URL(string: "sdkcovp1://media/movie.mp4")!)
            asset.resourceLoader.setDelegate(ld, queue: DispatchQueue(label: "p1.loader"))
            let (dur, tracks) = try await asset.load(.duration, .tracks)
            try expect(abs(dur.seconds - 1) < 0.1 && tracks.count == 1, "asset \(dur.seconds) s, \(tracks.count) tracks")
            let g = AVAssetImageGenerator(asset: asset); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            let (img, _) = try await g.image(at: CMTime(value: 10, timescale: 30))
            try expect(img.width == 128 && img.height == 128, "frame \(img.width)x\(img.height)")
            let item = AVPlayerItem(asset: asset); let p = AVPlayer(playerItem: item); p.isMuted = true
            guard await more2Wait(15, { item.status != .unknown }) else { throw Fail("player item stayed unknown") }
            try expect(item.status == .readyToPlay, "player item \(String(describing: item.error))")
            let ir = ld.infoRequests.load(ordering: .relaxed), dr = ld.dataRequests.load(ordering: .relaxed)
            try expect(ir >= 1 && dr >= 1, "loader saw \(ir) info / \(dr) data requests")
            return "\(String(format: "%.2f", dur.seconds)) s via \(ir) info + \(dr) data requests, frame \(img.width)x\(img.height)"
        })
        c.append(check("AVFoundation", "timed-metadata-chapters", timeout: 90) {
            // asset metadata (title, artist) and a timed-metadata track written by AVAssetWriter; read back with load
            // (.commonMetadata / .availableChapterLocales / chapters), AVAssetReaderOutputMetadataAdaptor and during
            // playback through AVPlayerItemMetadataOutput
            let u = p1Tmp("meta.mov")
            let t = AVMutableMetadataItem(); t.identifier = .commonIdentifierTitle; t.value = "sdkcov p1 title" as NSString; t.extendedLanguageTag = "und"
            let a = AVMutableMetadataItem(); a.identifier = .commonIdentifierArtist; a.value = "x86sim" as NSString; a.extendedLanguageTag = "und"
            try await p1Movie(u, frames: 60, metadata: [t, a], timed: [(0, 1, "part one"), (1, 1, "part two")], chapters: true)
            let asset = AVURLAsset(url: u)
            let (common, formats) = try await asset.load(.commonMetadata, .availableMetadataFormats)
            let title = try await AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
            let artist = try await AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtist).first?.load(.stringValue)
            try expect(title == "sdkcov p1 title" && artist == "x86sim", "metadata title \(String(describing: title)) artist \(String(describing: artist)) formats \(formats)")
            let mtracks = try await asset.loadTracks(withMediaType: .metadata)
            try expect(mtracks.count == 1, "\(mtracks.count) metadata tracks")
            let r = try AVAssetReader(asset: asset)
            let o = AVAssetReaderTrackOutput(track: mtracks[0], outputSettings: nil); r.add(o)
            let ma = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: o)
            try expect(r.startReading(), "reader \(String(describing: r.error))")
            var groups: [String] = []
            while let g = ma.nextTimedMetadataGroup() { for it in g.items { if let s = it.stringValue { groups.append("\(String(format: "%.1f", g.timeRange.start.seconds)):\(s)") } } }
            try expect(groups == ["0.0:part one", "1.0:part two"], "timed groups \(groups)")
            let locales = try await asset.load(.availableChapterLocales)
            let chapters = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en", "und"])
            // a metadata track associated as a chapter list is not a chapter track (QuickTime chapters are text
            // tracks): Apple's simulator lists no chapters for it; reported, not asserted
            let chTitles = chapters.flatMap { $0.items.compactMap(\.stringValue) }
            // during playback
            let item = AVPlayerItem(asset: asset)
            let mo = AVPlayerItemMetadataOutput(identifiers: nil); let md = P1MetaOut(); mo.setDelegate(md, queue: .main); item.add(mo)
            let p = AVPlayer(playerItem: item); p.isMuted = true
            guard await more2Wait(15, { item.status != .unknown }) else { throw Fail("item status unknown") }
            p.play()
            let got = await more2Wait(6) { md.titles.value.contains("part two") }
            p.pause()
            try expect(got, "metadata output delivered \(md.titles.value) (time \(p.currentTime().seconds))")
            return "title/artist ok, groups \(groups), chapters \(chTitles), output \(md.titles.value)"
        })
        #endif
        #if !os(tvOS)
        c.append(check("AVFoundation", "mutable-movie-edit-header", timeout: 60) {
            // AVMutableMovie: a 1 s AAC file inserted twice by reference, the first copy scaled to twice its length, half
            // a second removed; the header is written to a .mov referencing the source and re-opened as an asset with the
            // edited duration (d = the movie's duration after one insert: AAC priming makes it a little over 1 s)
            let srcU = p1Tmp("mv-src.m4a")
            try p1WriteAudio(p1Tones([440], secs: 1), srcU, p1AAC)
            let src = AVMovie(url: srcU)
            let st = try await src.loadTracks(withMediaType: .audio)
            let sd = try await src.load(.duration)
            try expect(st.count == 1 && abs(sd.seconds - 1) < 0.1, "AVMovie \(st.count) tracks \(sd.seconds) s")
            let m = try AVMutableMovie(settingsFrom: nil, options: nil)
            m.timescale = 44100
            let one = CMTimeRange(start: .zero, duration: sd)
            try m.insertTimeRange(one, of: src, at: .zero, copySampleData: false)
            let d = m.duration
            try expect(abs(d.seconds - sd.seconds) < 0.1 && m.tracks.count == 1, "after 1 insert: \(d.seconds) s, \(m.tracks.count) tracks")
            try m.insertTimeRange(one, of: src, at: d, copySampleData: false)
            let d2 = m.duration   // Apple's simulator: 2.0883 s after 1.0202 s (the second copy keeps the AAC priming)
            try expect(d2.seconds > 1.9 && d2.seconds < 2.2, "after 2 inserts: \(d2.seconds) s")
            guard let tr = m.tracks.first else { throw Fail("no track") }
            tr.scaleTimeRange(CMTimeRange(start: .zero, duration: d), toDuration: CMTimeMultiply(d, multiplier: 2))
            let s3 = m.duration.seconds   // the scaled edit lands on whole samples of the track: within ~50 ms of d2 + d
            try expect(abs(s3 - (d2.seconds + d.seconds)) < 0.06, "after scale: \(s3) s (\(d2.seconds) + \(d.seconds))")
            tr.removeTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 2)))
            let want = s3 - 0.5
            try expect(abs(m.duration.seconds - want) < 0.01, "after remove: \(m.duration.seconds) s (want \(want))")
            let segs = tr.segments.count
            let out = p1Tmp("mv-out.mov")
            try m.writeHeader(to: out, fileType: .mov, options: .addMovieHeaderToDestination)
            let back = AVURLAsset(url: out)
            let (bd, bt) = try await back.load(.duration, .tracks)
            try expect(abs(bd.seconds - want) < 0.01 && bt.count == 1, "re-opened header: \(bd.seconds) s, \(bt.count) tracks (want \(want))")
            let playable = try await back.load(.isPlayable)
            return "\(String(format: "%.3f", bd.seconds)) s, \(segs) edit segments, header \((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0) B, playable \(playable)"
        })
        #endif
        c.append(check("AVFoundation", "queue-player-seek-rate-looper", timeout: 60) {
            // AVQueuePlayer through three short items (end-of-item notifications), an exact seek (time-jumped
            // notification), a rate change (rate notification); AVPlayerLooper repeats an item (not on watchOS)
            var urls: [URL] = []
            for (i, hz) in [440.0, 550, 660].enumerated() { let u = p1Tmp("q\(i).caf"); try p1WriteAudio(p1Tones([hz], secs: 0.5), u, p1PCM()); urls.append(u) }
            let q = AVQueuePlayer(items: urls.map { AVPlayerItem(url: $0) }); q.volume = 0
            let ends = Atomic<Int>(0)
            let o1 = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: nil) { n in
                if let it = n.object as? AVPlayerItem, let u = (it.asset as? AVURLAsset)?.url, urls.contains(u) { ends.add(1, ordering: .relaxed) } }
            defer { NotificationCenter.default.removeObserver(o1) }
            q.play()
            let allEnded = await more2Wait(10) { ends.load(ordering: .relaxed) >= 3 }
            try expect(allEnded, "queue: \(ends.load(ordering: .relaxed))/3 items ended, \(q.items().count) left, rate \(q.rate)")
            // seek + rate on a 2 s item
            let long = p1Tmp("q-long.caf"); try p1WriteAudio(p1Tones([330], secs: 2), long, p1PCM())
            let item = AVPlayerItem(url: long)
            let p = AVPlayer(playerItem: item); p.volume = 0
            guard await more2Wait(10, { item.status == .readyToPlay }) else { throw Fail("item \(item.status.rawValue) \(String(describing: item.error))") }
            let jumps = Atomic<Int>(0), rates = P1Box<[Float]>([])
            let o2 = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: nil) { _ in jumps.add(1, ordering: .relaxed) }
            let o3 = NotificationCenter.default.addObserver(forName: AVPlayer.rateDidChangeNotification, object: p, queue: nil) { _ in rates.mutate { $0.append(p.rate) } }
            defer { NotificationCenter.default.removeObserver(o2); NotificationCenter.default.removeObserver(o3) }
            let ok = await p.seek(to: CMTime(value: 3, timescale: 4), toleranceBefore: .zero, toleranceAfter: .zero)
            try expect(ok && abs(p.currentTime().seconds - 0.75) < 0.01, "seek to 0.75: \(ok) at \(p.currentTime().seconds)")
            _ = await more2Wait(2) { jumps.load(ordering: .relaxed) > 0 }
            p.rate = 2
            let fast = await more2Wait(5) { p.currentTime().seconds > 1.4 }
            let r2 = p.rate
            p.pause()
            try expect(fast && r2 == 2, "rate 2 playback: at \(p.currentTime().seconds) s, rate \(r2)")
            _ = await more2Wait(2) { rates.value.contains(0) }
            try expect(jumps.load(ordering: .relaxed) >= 1 && rates.value.contains(2), "notifications: \(jumps.load(ordering: .relaxed)) time jumps, rates \(rates.value)")
            var loops = "no looper (watchOS)"
            #if !os(watchOS)
            let lq = AVQueuePlayer(); lq.volume = 0
            let looper = AVPlayerLooper(player: lq, templateItem: AVPlayerItem(url: urls[0]))
            lq.play()
            let looped = await more2Wait(8) { looper.loopCount >= 2 }
            lq.pause()
            try expect(looped && looper.status != .failed, "looper: \(looper.loopCount) loops, status \(looper.status.rawValue) \(String(describing: looper.error))")
            loops = "looper \(looper.loopCount) loops"
            looper.disableLooping()
            #endif
            return "3 queued items ended, seek exact, \(jumps.load(ordering: .relaxed)) jumps, rates \(rates.value), \(loops)"
        })
        c.append(check("AVFoundation", "sample-buffer-renderers-synchronizer", timeout: 40) {
            // LPCM sample buffers into AVSampleBufferAudioRenderer and BGRA frames into AVSampleBufferVideoRenderer, both
            // driven by one AVSampleBufferRenderSynchronizer: time advances at rate 1, a boundary observer fires, the
            // renderer shows the frame for the current time (copyDisplayedPixelBuffer, not on watchOS)
            let sync = AVSampleBufferRenderSynchronizer()
            let ar = AVSampleBufferAudioRenderer(); ar.volume = 0
            sync.addRenderer(ar)
            let tone = p1Tones([440], secs: 2)
            var off = 0
            while off < Int(tone.frameLength) {
                let n = min(4410, Int(tone.frameLength) - off)
                let part = AVAudioPCMBuffer(pcmFormat: tone.format, frameCapacity: AVAudioFrameCount(n))!; part.frameLength = AVAudioFrameCount(n)
                memcpy(part.floatChannelData![0], tone.floatChannelData![0] + off, n * 4)
                ar.enqueue(try p1AudioSampleBuffer(part, pts: CMTime(value: CMTimeValue(off), timescale: 44100)))
                off += n
            }
            #if !os(watchOS)
            // a video renderer only takes frames once it has a target: the display layer's
            let dl = AVSampleBufferDisplayLayer()
            let close = try await onMain { () -> () -> Void in
                let vc = UIViewController(); dl.frame = CGRect(x: 0, y: 0, width: 64, height: 64); vc.view.layer.addSublayer(dl)
                return try p1Show(vc)
            }
            defer { Task { @MainActor in close() } }
            let vr = dl.sampleBufferRenderer
            sync.addRenderer(vr)
            for i in 0..<60 {
                let pb = p1Solid(64, 64, i < 30 ? [255, 0, 0] : [0, 255, 0])
                var fd: CMVideoFormatDescription?; CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30), decodeTimeStamp: .invalid)
                var sb: CMSampleBuffer?
                try expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd!, sampleTiming: &timing, sampleBufferOut: &sb) == noErr, "video sample buffer")
                vr.enqueue(sb!)
            }
            #endif
            let hit = Atomic<Int>(0)
            let bo = sync.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(value: 1, timescale: 2))], queue: .main) { hit.add(1, ordering: .relaxed) }
            defer { sync.removeTimeObserver(bo) }
            let t0 = Date()
            sync.setRate(1, time: .zero)
            let fired = await more2Wait(5) { hit.load(ordering: .relaxed) > 0 }
            _ = await more2Wait(5) { sync.currentTime().seconds > 1.3 }
            let now = sync.currentTime().seconds, wall = Date().timeIntervalSince(t0)
            #if !os(watchOS)
            let shown = vr.displayedPixelBuffer().map { p1BGRA($0, 32, 32) }
            #endif
            sync.setRate(0, time: sync.currentTime())
            try expect(ar.status != .failed, "audio renderer failed: \(String(describing: ar.error))")
            try expect(fired, "boundary observer at 0.5 s never fired (time \(now))")
            try expect(now > 1.0 && abs(now - wall) < 0.6, "synchronizer time \(now) s after \(wall) s wall")
            #if !os(watchOS)
            try expect(vr.status != .failed, "video renderer failed: \(String(describing: vr.error))")
            try expect(shown.map { p1Near($0, [0, 255, 0], 30) } == true, "displayed pixel buffer \(String(describing: shown)) (want the green second half)")
            return "time \(String(format: "%.2f", now)) s in \(String(format: "%.2f", wall)) s wall, boundary fired, displayed \(shown!.prefix(3))"
            #else
            return "time \(String(format: "%.2f", now)) s in \(String(format: "%.2f", wall)) s wall, boundary fired"
            #endif
        })
        c.append(check("AVFoundation", "asset-load-formats", timeout: 90) {
            // the same 0.75 s tone as CAF (LPCM), WAV, AIFF, M4A (AAC) and, where AVAssetWriter exists, MP4 / MOV movies:
            // each loads with the right duration, track media type and codec, and is playable
            let tone = p1Tones([523], secs: 0.75)
            var files: [(String, URL, FourCharCode, AVMediaType)] = [
                ("caf", p1Tmp("fmt.caf"), kAudioFormatLinearPCM, .audio), ("wav", p1Tmp("fmt.wav"), kAudioFormatLinearPCM, .audio),
                ("aiff", p1Tmp("fmt.aiff"), kAudioFormatLinearPCM, .audio), ("m4a", p1Tmp("fmt.m4a"), kAudioFormatMPEG4AAC, .audio)]
            try p1WriteAudio(tone, files[0].1, p1PCM()); try p1WriteAudio(tone, files[1].1, p1PCM())
            try p1WriteAudio(tone, files[2].1, p1PCM(bigEndian: true)); try p1WriteAudio(tone, files[3].1, p1AAC)
            #if !os(watchOS)
            let mp4 = p1Tmp("fmt.mp4"), mov = p1Tmp("fmt.mov")
            try await p1Movie(mp4, frames: 23, type: .mp4); try await p1Movie(mov, frames: 23, type: .mov, audio: true)
            files += [("mp4", mp4, kCMVideoCodecType_H264, .video), ("mov", mov, kCMVideoCodecType_H264, .video)]
            #endif
            var res: [String] = []
            for (name, u, codec, mt) in files {
                let a = AVURLAsset(url: u)
                let (dur, tracks, playable) = try await a.load(.duration, .tracks, .isPlayable)
                let t = tracks.first { $0.mediaType == mt }
                guard let t else { throw Fail("\(name): no \(mt.rawValue) track in \(tracks.map(\.mediaType.rawValue))") }
                let fd = try await t.load(.formatDescriptions).first
                let sub = fd.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                try expect(abs(dur.seconds - 0.75) < 0.06, "\(name): duration \(dur.seconds)")
                try expect(sub == codec, "\(name): codec \(String(format: "%08x", sub)) want \(String(format: "%08x", codec))")
                try expect(playable, "\(name): not playable")
                res.append("\(name) \(String(format: "%.3f", dur.seconds))s\(tracks.count > 1 ? " \(tracks.count)tr" : "")")
            }
            let types = AVURLAsset.audiovisualTypes()
            try expect(types.contains(.mp4) && types.contains(.caf) && types.contains(.wav), "audiovisualTypes \(types.count)")
            return res.joined(separator: ", ")
        })
        #if !os(watchOS)
        c.append(check("AVFoundation", "capture-simulator-answers", timeout: 30) {
            // Apple's simulator has no cameras: discovery finds none, a session without inputs runs no capture; the
            // authorization status and the audio device list are what the simulator reports
            let types: [AVCaptureDevice.DeviceType] = {
                #if os(iOS)
                return [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInDualCamera, .builtInTrueDepthCamera, .builtInLiDARDepthCamera, .external, .microphone]
                #elseif os(visionOS)
                return [.builtInWideAngleCamera, .external]
                #else
                return [.builtInWideAngleCamera, .external, .microphone]
                #endif
            }()
            let video = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
            let audio = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
            try expect(video.isEmpty && AVCaptureDevice.default(for: .video) == nil, "cameras in the simulator: \(video.map(\.localizedName))")
            let s = AVCaptureSession()
            var startErr = "none"
            let o = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: s, queue: nil) { n in startErr = "\((n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0)" }
            defer { NotificationCenter.default.removeObserver(o) }
            s.beginConfiguration()
            #if os(iOS)
            s.sessionPreset = .high
            #endif
            s.commitConfiguration()
            s.startRunning()
            try await Task.sleep(for: .milliseconds(500))
            let running = s.isRunning
            s.stopRunning()
            let auth = AVCaptureDevice.authorizationStatus(for: .video).rawValue
            return "0 cameras, \(audio.count) audio devices (\(audio.map(\.localizedName).joined(separator: ","))), input-less session running \(running) error \(startErr), video auth \(auth)"
        })
        #endif
        return c
    }
}
