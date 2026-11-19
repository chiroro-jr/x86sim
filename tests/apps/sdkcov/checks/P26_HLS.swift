// SDK coverage, round 30: remote HLS playback through AVPlayer (the user's report: YouTube streams don't play on tvOS).
// Apple's sample streams (fMP4 and MPEG-2 TS) and, when the build carries one (res/sdkcovHLS.url: a YouTube master
// playlist, signed for a few hours and for the host's address, e.g. yt-dlp -j's formats[].manifest_url; not in git),
// a YouTube one. Each: the item gets ready, time advances, AVPlayerItemVideoOutput hands out non-empty pixel buffers,
// the player rate is > 0 with an enabled audio track. Needs the network (as on Apple's simulator).
import Foundation
import AVFoundation
import CoreVideo
#if canImport(UIKit) && !os(watchOS)
import UIKit
import AVKit
#endif

private func p26Wait(_ secs: Double, _ cond: @escaping () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
    return cond()
}

private func p26Play(_ url: URL, secs: Double = 6, audio wantAudio: Bool = true) async throws -> String {
    let item = AVPlayerItem(url: url)
    #if !os(watchOS)
    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(out)
    #endif
    let player = AVPlayer(playerItem: item); player.volume = 0
    defer { player.pause(); player.replaceCurrentItem(with: nil) }
    func logs() -> String {
        let e = item.errorLog()?.events.map { "\($0.errorStatusCode) \($0.errorDomain) \($0.errorComment ?? "") \($0.uri ?? "")".prefix(200) } ?? []
        let a = item.accessLog()?.events.last
        return "error \(String(describing: item.error)); errorLog \(e.suffix(3)); access requests \(a?.numberOfMediaRequests ?? -1) bytes \(a?.numberOfBytesTransferred ?? -1) uri \(a?.uri?.prefix(60) ?? "-")"
    }
    guard await p26Wait(45, { item.status != .unknown }) else { throw Fail("status stayed unknown; \(logs())") }
    try expect(item.status == .readyToPlay, "item failed; \(logs())")
    player.play()
    var frames = 0, w = 0, h = 0
    let t0 = player.currentTime().seconds
    let end = Date().addingTimeInterval(40)
    while Date() < end && (player.currentTime().seconds - t0 < secs || frames < 3) {
        #if os(watchOS)
        // no AVPlayerItemVideoOutput on watchOS: the decoded size stands in for frames
        if item.presentationSize.width > 0 { frames += 1; w = Int(item.presentationSize.width); h = Int(item.presentationSize.height) }
        #else
        let t = item.currentTime()
        if out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb)
            if w > 0 && h > 0 { frames += 1 }
        }
        #endif
        try? await Task.sleep(nanoseconds: 33_000_000)
    }
    let played = player.currentTime().seconds - t0
    let audio = item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }.count
    let video = item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .video }.count
    let d = String(format: "played %.1f s, %d frames %dx%d, rate %.1f, tracks a%d v%d, presentationSize %.0fx%.0f",
                   played, frames, w, h, player.rate, audio, video, item.presentationSize.width, item.presentationSize.height)
    try expect(played >= secs - 0.5, "\(d); \(logs())")
    try expect(frames >= 3, "\(d); \(logs())")
    try expect(player.rate > 0 && (audio > 0) == wantAudio, "\(d); \(logs())")
    return d
}

extension Registry {
    static var p26: [Check] {
        var c: [Check] = []
        c.append(check("AVFoundation", "hls-remote-fmp4", timeout: 100) {
            try await p26Play(URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!)
        })
        c.append(check("AVFoundation", "hls-remote-ts", timeout: 100) {
            try await p26Play(URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8")!)
        })
        c.append(check("AVFoundation", "hls-remote-youtube", timeout: 400) {
            // one stream per line: "LABEL URL". Apple's simulator (tvOS / iOS 27.2): the master playlist and a live
            // stream play (avc1 + mp4a picked); a single variant's playlist (LABEL starts "video-") is video only (the
            // audio is a separate rendition the master names) and plays without audio; VP9 (LABEL contains "vp09") is
            // refused: -11833 Cannot Decode / -12906, no VP9 decoder in the simulator
            guard let f = Bundle.main.url(forResource: "sdkcovHLS", withExtension: "url"),
                  let s = try? String(contentsOf: f, encoding: .utf8)
            else { throw Skip("no res/sdkcovHLS.url in this build") }
            var res: [String] = [], bad = false
            for l in s.split(separator: "\n") {
                let p = l.split(separator: " ", maxSplits: 1); guard p.count == 2, let u = URL(string: String(p[1])) else { continue }
                let label = String(p[0])
                #if os(watchOS)
                // Apple's watchOS simulator: a video-only playlist (VP9 too) gets ready with its size but time stays at 0
                if label.hasPrefix("video-") { res.append("\(label): not on watchOS"); continue }
                #endif
                do {
                    let r = try await p26Play(u, secs: 4, audio: !label.hasPrefix("video-"))
                    if label.contains("vp09") { bad = true; res.append("\(label): played, Apple refuses VP9: \(r)") } else { res.append("\(label): \(r)") }
                } catch {
                    if label.contains("vp09") && "\(error)".contains("Code=-11833") { res.append("\(label): -11833 Cannot Decode (as Apple)") }
                    else { bad = true; res.append("\(label): FAIL \(error)") }
                }
            }
            try expect(!res.isEmpty && !bad, res.joined(separator: " | "))
            return res.joined(separator: " | ")
        })
        #if canImport(UIKit) && !os(watchOS)
        c.append(check("AVKit", "hls-remote-onscreen", timeout: 60) {
            // AVPlayerViewController full screen playing the first stream of res/sdkcovHLS.url (else Apple's fMP4
            // sample) for 20 s: time advances (ref-mac.sh / x86sim screenshot SHOTS to see the picture)
            var u = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!
            if let f = Bundle.main.url(forResource: "sdkcovHLS", withExtension: "url"), let s = try? String(contentsOf: f, encoding: .utf8),
               let l = s.split(separator: "\n").first, let p = l.split(separator: " ", maxSplits: 1).last, let y = URL(string: String(p)) { u = y }
            let player = AVPlayer(url: u); player.volume = 0
            let close = try await onMain { () throws -> () -> Void in
                guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Fail("no window scene") }
                let prev = ws.windows.first(where: \.isKeyWindow)
                let vc = AVPlayerViewController(); vc.player = player
                let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
                w.rootViewController = vc; w.makeKeyAndVisible(); w.layoutIfNeeded()
                return { w.isHidden = true; w.rootViewController = nil; prev?.makeKeyAndVisible() }
            }
            defer { Task { @MainActor in player.pause(); close() } }
            await onMain { player.play() }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            let t = player.currentTime().seconds, it = player.currentItem
            try expect(t > 10, "played \(t) s, rate \(player.rate), \(String(describing: it?.error))")
            return String(format: "played %.1f s, presentationSize %.0fx%.0f", t, it?.presentationSize.width ?? 0, it?.presentationSize.height ?? 0)
        })
        #endif
        return c
    }
}
