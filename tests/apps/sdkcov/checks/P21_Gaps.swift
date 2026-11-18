// SDK coverage, round 25: checks for [a] gaps of covered frameworks (COVERAGE-GAPS.md). Each asserts what Apple's
// simulator answers (ref-mac.sh).
import Foundation
import Synchronization
import CoreMedia
import CoreGraphics
import UniformTypeIdentifiers
#if canImport(AVFoundation) && !os(watchOS)
import AVFoundation
#endif
#if canImport(BackgroundAssets) && (os(iOS) || os(visionOS))
import BackgroundAssets
#endif
#if canImport(AppIntents)
import AppIntents
#endif

/// the strings in a value's reflection (Mirror), depth first, at most `depth` levels down
func p21Strings(_ v: Any, depth: Int = 8) -> [String] {
    if let s = v as? String { return [s] }
    if depth == 0 { return [] }
    return Mirror(reflecting: v).children.flatMap { p21Strings($0.value, depth: depth - 1) }
}

#if canImport(AVFoundation) && !os(watchOS)
/// a movie written as QuickTime: video + a QuickTime text track holding `titles` (one second each), associated with
/// the video as its chapter list (how QuickTime / Final Cut store chapters)
func p21ChapterMovie(_ url: URL, titles: [String]) async throws {
    try? FileManager.default.removeItem(at: url)
    let w = try AVAssetWriter(outputURL: url, fileType: .mov)
    let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: nil)
    w.add(vin)
    var fd: CMFormatDescription?
    // a QuickTime text sample description: display flags, justification, colors, text box, default style, font table
    // the keys a QuickTime ('text') sample description has (the 3GPP ones, alpha / end char / font table, left out)
    func color(_ v: Int) -> [String: Int] { [kCMTextFormatDescriptionColor_Red as String: v, kCMTextFormatDescriptionColor_Green as String: v,
                                             kCMTextFormatDescriptionColor_Blue as String: v] }
    let ext: [String: Any] = [
        kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
        kCMTextFormatDescriptionExtension_TextJustification as String: 0,
        kCMTextFormatDescriptionExtension_BackgroundColor as String: color(0),
        kCMTextFormatDescriptionExtension_DefaultTextBox as String: [kCMTextFormatDescriptionRect_Top as String: 0, kCMTextFormatDescriptionRect_Left as String: 0,
                                                                     kCMTextFormatDescriptionRect_Bottom as String: 0, kCMTextFormatDescriptionRect_Right as String: 0],
        kCMTextFormatDescriptionExtension_DefaultStyle as String: [kCMTextFormatDescriptionStyle_StartChar as String: 0, kCMTextFormatDescriptionStyle_Font as String: 0,
                                                                   kCMTextFormatDescriptionStyle_FontFace as String: 0, kCMTextFormatDescriptionStyle_ForegroundColor as String: color(65535),
                                                                   kCMTextFormatDescriptionStyle_FontSize as String: 12, kCMTextFormatDescriptionStyle_Height as String: 14,
                                                                   kCMTextFormatDescriptionStyle_Ascent as String: 11],
        kCMTextFormatDescriptionExtension_DefaultFontName as String: "Helvetica",
    ]
    try expect(CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text, mediaSubType: kCMTextFormatType_QTText,
                                         extensions: ext as CFDictionary, formatDescriptionOut: &fd) == noErr, "text format description")
    let tin = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: fd)
    tin.marksOutputTrackAsEnabled = false
    tin.mediaDataLocation = .beforeMainMediaDataNotInterleaved   // the header's advice for chapter name tracks
    try expect(w.canAdd(tin), "writer refuses a text input")
    w.add(tin)
    vin.addTrackAssociation(withTrackOf: tin, type: AVAssetTrack.AssociationType.chapterList.rawValue)
    try expect(w.startWriting(), "startWriting: \(String(describing: w.error))")
    w.startSession(atSourceTime: .zero)
    for (n, t) in titles.enumerated() {
        // a QuickTime text sample: 16-bit big-endian length, then the UTF-8 text
        // + an 'encd' atom: UTF-8 (0x100)
        let u = Array(t.utf8), bytes = [UInt8(u.count >> 8), UInt8(u.count & 0xff)] + u + [0, 0, 0, 12, 0x65, 0x6e, 0x63, 0x64, 0, 0, 1, 0]
        var bb: CMBlockBuffer?
        try expect(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
                                                      offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb) == noErr, "block buffer")
        _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1), presentationTimeStamp: CMTime(value: CMTimeValue(n), timescale: 1), decodeTimeStamp: .invalid)
        var size = bytes.count, sb: CMSampleBuffer?
        try expect(CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                             sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, "text sample buffer")
        while !tin.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        try expect(tin.append(sb!), "append text sample \(n): \(String(describing: w.error))")
    }
    tin.markAsFinished()
    let frames = 30 * titles.count
    for i in 0..<frames {
        while !vin.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        try expect(ad.append(p1Solid(64, 64, [UInt8(i * 7 % 256), 80, 160]), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)),
                   "append frame \(i): \(String(describing: w.error))")
    }
    vin.markAsFinished()
    await w.finishWriting()
    try expect(w.status == .completed, "finishWriting: \(String(describing: w.error))")
}


/// serves a movie file through AVAssetResourceLoader (scheme sdkcovrl:) up to `cutoff` bytes; beyond it a request is
/// left pending (stall) or finished with an error (fail)
final class P21Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let data: Data, cutoff: Int, holeEnd: Int, fail: Bool
    let pending = Mutex<[AVAssetResourceLoadingRequest]>([]), served = Atomic<Int>(0)
    init(_ d: Data, fail: Bool) {
        data = d; self.fail = fail
        // the top-level atoms: the hole is the last two thirds of mdat
        var off = 0, mdat = (0, d.count)
        while off + 8 <= d.count {
            var size = Int(d[off]) << 24 | Int(d[off + 1]) << 16 | Int(d[off + 2]) << 8 | Int(d[off + 3])
            if size == 1, off + 16 <= d.count { size = d[off + 8 ..< off + 16].reduce(0) { $0 << 8 | Int($1) } }
            if String(decoding: d[off + 4 ..< off + 8], as: UTF8.self) == "mdat" { mdat = (off, off + size) }
            if size < 8 { break }; off += size
        }
        cutoff = mdat.0 + (mdat.1 - mdat.0) / 3; holeEnd = mdat.1
    }
    func resourceLoader(_ l: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource r: AVAssetResourceLoadingRequest) -> Bool {
        if let ci = r.contentInformationRequest {
            ci.contentType = UTType.quickTimeMovie.identifier; ci.contentLength = Int64(data.count); ci.isByteRangeAccessSupported = true
        }
        guard let dr = r.dataRequest else { r.finishLoading(); return true }
        let start = Int(dr.currentOffset)
        let end = dr.requestsAllDataToEndOfResource ? data.count : min(data.count, Int(dr.requestedOffset) + dr.requestedLength)
        // bytes [cutoff, holeEnd) (the later part of the media data) are never served; the rest (the movie header
        // wherever it is) is
        let blocked = start < holeEnd && end > cutoff
        let upTo = blocked ? max(start, cutoff) : end
        if upTo > start { dr.respond(with: data.subdata(in: start..<upTo)); served.add(upTo - start, ordering: .relaxed) }
        if !blocked { r.finishLoading() }
        else if fail { r.finishLoading(with: NSError(domain: "sdkcov.loader", code: 21, userInfo: [NSLocalizedDescriptionKey: "cut off"])) }
        else { pending.withLock { $0.append(r) } }
        return true
    }
    func resourceLoader(_ l: AVAssetResourceLoader, didCancel r: AVAssetResourceLoadingRequest) { pending.withLock { $0.removeAll { $0 === r } } }
}

/// a 6 s movie (video 30 fps + AAC audio) with its header first, the two tracks appended a second at a time (the
/// writer interleaves: all video before any audio blocks it)
func p21AVMovie(_ url: URL) async throws {
    try? FileManager.default.removeItem(at: url)
    let w = try AVAssetWriter(outputURL: url, fileType: .mov)
    w.shouldOptimizeForNetworkUse = true
    let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 160])
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: nil)
    let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: p1AAC)
    w.add(vin); w.add(ain)
    try expect(w.startWriting(), "startWriting: \(String(describing: w.error))")
    w.startSession(atSourceTime: .zero)
    let tone = p1Tones([440], secs: 6)
    // whichever input is ready takes its next piece (the AAC encoder's delay keeps video waiting for audio ahead of it)
    var i = 0, off = 0
    while i < 180 || off < 180 * 1470 {
        if i < 180, vin.isReadyForMoreMediaData {
            try expect(ad.append(p1Solid(160, 160, [UInt8(i * 37 % 256), UInt8(i * 11 % 256), UInt8(255 - i % 256)]), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)),
                       "append frame \(i): \(String(describing: w.error))")
            i += 1
        } else if off < 180 * 1470, ain.isReadyForMoreMediaData {
            let part = AVAudioPCMBuffer(pcmFormat: tone.format, frameCapacity: 1470)!; part.frameLength = 1470
            memcpy(part.floatChannelData![0], tone.floatChannelData![0] + off, 1470 * 4)
            try expect(ain.append(try p1AudioSampleBuffer(part, pts: CMTime(value: CMTimeValue(off), timescale: 44100))), "append audio: \(String(describing: w.error))")
            off += 1470
            if off >= 180 * 1470 { ain.markAsFinished() }   // the video encoder's last frames wait for this
        } else { try await Task.sleep(for: .milliseconds(5)) }
    }
    vin.markAsFinished()
    await w.finishWriting()
    try expect(w.status == .completed, "finishWriting: \(String(describing: w.error))")
}

/// play the movie through a P21Loader; the notifications seen in `secs` s
func p21PlayCutoff(fail: Bool, secs: Double) async throws -> (notes: [String], detail: String) {
    let u = p1Tmp(fail ? "cut-fail.mov" : "cut-stall.mov")
    try await p21AVMovie(u)
    let d = try Data(contentsOf: u)
    let loader = P21Loader(d, fail: fail)
    let asset = AVURLAsset(url: URL(string: "sdkcovrl://movie/\(fail ? "fail" : "stall").mov")!)
    asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "p21.loader"))
    let item = AVPlayerItem(asset: asset)
    let notes = Mutex<[String]>([])
    let nc = NotificationCenter.default
    var obs: [NSObjectProtocol] = []
    for (n, tag) in [(AVPlayerItem.playbackStalledNotification, "stalled"), (AVPlayerItem.failedToPlayToEndTimeNotification, "failedToPlayToEnd"),
                     (AVPlayerItem.didPlayToEndTimeNotification, "playedToEnd")] {
        obs.append(nc.addObserver(forName: n, object: item, queue: nil) { note in
            var s = tag
            if let e = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError { s += "(\(e.domain) \(e.code))" }
            notes.withLock { if !$0.contains(s) { $0.append(s) } }
        })
    }
    defer { obs.forEach { nc.removeObserver($0) } }
    let p = AVPlayer(playerItem: item)
    p.isMuted = true
    p.automaticallyWaitsToMinimizeStalling = false   // play what is there at once (waiting, the player never starts on a third of the data)
    p.play()
    let end = Date().addingTimeInterval(secs)
    while Date() < end {
        if !notes.withLock({ $0.isEmpty }) && Date() > end.addingTimeInterval(-secs + 3) { try await Task.sleep(for: .seconds(1)); break }
        try await Task.sleep(for: .milliseconds(200))
    }
    let t = p.currentTime().seconds, st = item.status.rawValue, tcs = p.timeControlStatus.rawValue
    let err = item.error.map { p8Err($0) } ?? "nil"
    p.pause(); p.replaceCurrentItem(with: nil)
    // finished outside the lock (finishing may call didCancel, which takes it)
    let left = loader.pending.withLock { let l = $0; $0.removeAll(); return l }
    left.forEach { $0.finishLoading(with: NSError(domain: "sdkcov.loader", code: 0)) }
    let ns = notes.withLock { $0 }
    return (ns, "\(d.count) B, hole \(loader.cutoff)..<\(loader.holeEnd), served \(loader.served.load(ordering: .relaxed)), played to \(String(format: "%.1f", t)) s of 6, item status \(st), timeControl \(tcs), error \(err)")
}
#endif

extension Registry {
    static var p21: [Check] {
        var c: [Check] = []

        // MARK: AVFoundation: QuickTime chapters (a text track as the video's chapter list) read back
        #if canImport(AVFoundation) && !os(watchOS)
        c.append(check("AVFoundation", "chapters-text-track", timeout: 90) {
            let u = p1Tmp("chapters.mov")
            try await p21ChapterMovie(u, titles: ["Opening", "Middle", "Credits"])
            let asset = AVURLAsset(url: u)
            let text = try await asset.loadTracks(withMediaType: .text)
            let locales = try await asset.load(.availableChapterLocales)
            let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en", "und"])
            var ch: [String] = []
            for g in groups {
                let title = try await AVMetadataItem.metadataItems(from: g.items, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
                ch.append("\(String(format: "%.0f", g.timeRange.start.seconds))+\(String(format: "%.0f", g.timeRange.duration.seconds)):\(title ?? "nil")")
            }
            try expect(ch == ["0+1:Opening", "1+1:Middle", "2+1:Credits"], "\(text.count) text tracks, locales \(locales.map(\.identifier)), chapters \(ch)")
            return "\(text.count) text track, locales \(locales.map(\.identifier)), chapters \(ch)"
        })

        // MARK: AVFoundation: AVPlayerItem playback stalled notification, from a movie served through
        // AVAssetResourceLoader that stops a third of the way into its media data
        c.append(check("AVFoundation", "player-stalled-notification", timeout: 90) {
            let (n, d) = try await p21PlayCutoff(fail: false, secs: 30)
            try expect(n.contains("stalled"), "notifications \(n); \(d)")
            return "notifications \(n); \(d)"
        })
        // a loading error part way: Apple's simulator reports the stall only (no failed-to-play-to-end, the item stays
        // ready, no item error); a movie whose later samples are junk plays to its end there
        c.append(check("AVFoundation", "player-loader-error-mid-play", timeout: 90) {
            let (n, d) = try await p21PlayCutoff(fail: true, secs: 30)
            try expect(n == ["stalled"] && d.contains("item status 1") && d.contains("error nil"), "notifications \(n); \(d)")
            return "notifications \(n) (no failedToPlayToEnd); \(d)"
        })
        #endif

        // MARK: BackgroundAssets: BADownloadManager current downloads, a download scheduled and cancelled (the per-user
        // daemon backgroundassets.user answers; tvOS: More_tvOS.swift asset-pack-manager-downloads)
        #if canImport(BackgroundAssets) && (os(iOS) || os(visionOS))
        c.append(check("BackgroundAssets", "download-manager-schedule-cancel", timeout: 60) {
            func e(_ x: Error) -> String { "\((x as NSError).domain) \((x as NSError).code)" }
            let m = BADownloadManager.shared
            var out: [String] = []
            do { out.append("current \(try await m.fetchCurrentDownloads().count)") } catch { out.append("current: \(e(error))") }
            let dl = BAURLDownload(identifier: "sdkcov-p21", request: URLRequest(url: URL(string: "https://example.com/p21.bin")!), essential: false,
                                   fileSize: 1024, applicationGroupIdentifier: "group.com.x86sim.test.sdkcov", priority: .default)
            do { try m.scheduleDownload(dl); out.append("scheduled") } catch { out.append("schedule: \(e(error))") }
            do { out.append("then \(try await m.fetchCurrentDownloads().map(\.identifier))") } catch { out.append("then: \(e(error))") }
            do { try m.cancel(dl); out.append("cancelled") } catch { out.append("cancel: \(e(error))") }
            let r = out.joined(separator: "; ")
            try expect(out.first?.hasPrefix("current ") == true, r)
            return r
        })
        #endif

        // MARK: AppIntents: the App Shortcuts' phrases and titles as the provider declares them (Mirror: AppShortcut keeps
        // them private), the application name placeholder in the phrase text
        #if canImport(AppIntents)
        c.append(check("AppIntents", "app-shortcut-phrases-titles") {
            let all = P7Shortcuts.appShortcuts.map { p21Strings($0) }
            try expect(all.count == 2, "\(all.count) shortcuts")
            let flat = all.flatMap { $0 }
            let phrases = Set(flat.filter { $0.contains("${applicationName}") })
            let want: Set = ["Count books in ${applicationName}", "How many books in ${applicationName}", "Open a book in ${applicationName}"]
            try expect(phrases == want && ["Count books", "Open book", "books.vertical", "book"].allSatisfy(flat.contains), "strings \(all)")
            return "phrases \(phrases.sorted()), titles Count books / Open book, images books.vertical / book, \(flat.count) strings in all"
        })
        #endif
        return c
    }
}
