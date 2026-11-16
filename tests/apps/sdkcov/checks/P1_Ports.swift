// sdkcov P1 (media & AV): checks that existed for one platform, ported to the others where the framework ships
// (MusicUnderstanding, NowPlaying, MediaIntents, ImmersiveMediaSupport, AVRouting, VideoPlayer / AVKit on watchOS and
// visionOS) plus the SwiftUI overlays of MusicKit and PhotosUI and PhotosUI's WidgetKit overlay.
import Foundation
import Synchronization
import SwiftUI
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif
#if canImport(NowPlaying)
import NowPlaying
#endif
#if canImport(MediaIntents)
import MediaIntents
#endif
#if canImport(ImmersiveMediaSupport)
import ImmersiveMediaSupport
#endif
#if canImport(AVRouting)
import AVRouting
#endif
#if canImport(AVKit)
import AVKit
#endif
#if canImport(MusicKit)
import MusicKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(_PhotosUI_SwiftUI)
import _PhotosUI_SwiftUI
#endif
#if canImport(_AVKit_SwiftUI)
import _AVKit_SwiftUI
#endif
#if canImport(_MusicKit_SwiftUI)
import _MusicKit_SwiftUI
#endif
#if canImport(Photos)
import Photos
#endif

/// a mono 44.1 kHz CAF of `secs` seconds: 20 ms 1 kHz clicks every `period` seconds (120 BPM at 0.5)
func p1ClickTrack(_ secs: Double, period: Double = 0.5) throws -> URL {
    let url = p1Tmp("clicks-\(Int(secs)).caf")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let n = AVAudioFrameCount(secs * 44100)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { throw Fail("PCM buffer") }
    buf.frameLength = n
    let p = buf.floatChannelData![0], per = Int(period * 44100), click = 882
    for i in 0..<Int(n) {
        let k = i % per
        p[i] = k < click ? Float(sin(Double(k) * 2 * .pi * 1000 / 44100) * 0.8 * (1 - Double(k) / Double(click))) : 0
    }
    let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
    try f.write(from: buf)
    return url
}

#if canImport(NowPlaying) && !os(tvOS)
@MainActor final class P1NowPlayingRep: MediaSessionRepresentable {
    let id = "sdkcov-p1-session"
    var played = 0
    var content: (any MediaContentRepresentable)? { MovieContent(id: "sdkcov-p1-movie", title: "sdkcov p1 movie", duration: .finite(42), artwork: nil) }
    var playbackSnapshot: MediaPlaybackSnapshot? { MediaPlaybackSnapshot(state: .playing(rate: 1), elapsedTime: 3, timestamp: Date()) }
    var commands: [MediaCommand] { [.play { self.played += 1 }, .pause {}, .skipForward(preferredIntervals: [15]) { _ in }] }
}
#endif

#if canImport(AVRouting) && !os(tvOS) && !os(watchOS)
final class P1RoutingDelegate: NSObject, AVCustomRoutingControllerDelegate {
    let events = Atomic<Int>(0)
    func customRoutingController(_ c: AVCustomRoutingController, handle e: AVCustomRoutingEvent, completionHandler: @escaping (Bool) -> Void) { events.add(1, ordering: .relaxed); completionHandler(false) }
}
#endif

extension Registry {
    static var p1_ports: [Check] {
        var c: [Check] = []
        #if canImport(MusicUnderstanding) && !os(tvOS)
        c.append(check("MusicUnderstanding", "click-track-loudness-rhythm", timeout: 240) {
            // as on tvOS: a 120 BPM click track; integrated loudness, then the rhythm network's beats
            let url = try p1ClickTrack(4)
            let t0 = Date()
            let s = try await MusicUnderstandingSession(asset: AVURLAsset(url: url))
            let r = try await s.analyze(for: [.loudness])
            guard let lo = r.loudness else { throw Fail("no loudness result") }
            try expect(lo.integrated.value.isFinite && lo.integrated.value < 0 && lo.integrated.value > -60, "integrated loudness \(lo.integrated.value)")
            let t1 = Date()
            let s2 = try await MusicUnderstandingSession(asset: AVURLAsset(url: url))
            let rr = try await s2.analyze(for: [.rhythm])
            let beats = rr.rhythm?.beats ?? []
            let gaps = zip(beats.dropFirst(), beats).map { ($0.0 - $0.1).seconds }
            return "loudness \(String(format: "%.1f", lo.integrated.value)) LUFS (\(Int(t1.timeIntervalSince(t0) * 1000)) ms); \(beats.count) beats, gaps \(gaps.map { String(format: "%.2f", $0) }.joined(separator: ",")), bpm \(rr.rhythm?.beatsPerMinute.map { String(format: "%.1f", $0) } ?? "nil")"
        })
        #endif
        #if canImport(NowPlaying) && !os(tvOS)
        c.append(check("NowPlaying", "media-session-primary", timeout: 30) {
            try await p1Main { () async throws -> String in
                let rep = P1NowPlayingRep()
                let s = MediaSession(rep)
                try expect(!s.id.isEmpty, "session id")
                var err = ""
                do { try await s.requestToBecomeApplicationPrimary() } catch { err = " (request: \(error))" }
                _ = await p1WaitMain(3) { s.isApplicationPrimary }
                // Apple's iOS / watchOS / visionOS simulators grant it (mediaremoted answers)
                try expect(err.isEmpty && s.isApplicationPrimary, "primary \(s.isApplicationPrimary)\(err)")
                try expect(rep.content?.id == "sdkcov-p1-movie" && rep.commands.count == 3, "representable")
                return "primary \(s.isApplicationPrimary), canBecome \(s.canBecomeApplicationPrimary)\(err)"
            }
        })
        #endif
        #if canImport(MediaIntents) && (os(iOS) || os(watchOS))
        c.append(check("MediaIntents", "audio-search-codable") {
            let s = AudioSearch(criteria: .searchQuery("x86sim"))
            let d = try JSONEncoder().encode(s), back = try JSONDecoder().decode(AudioSearch.self, from: d)
            try expect(back == s, "round trip")
            let u = AudioSearch(criteria: .url([URL(string: "https://example.com/a.m4a")!]))
            try expect(u != s, "criteria")
            return "\(d.count) B JSON"
        })
        #endif
        #if canImport(ImmersiveMediaSupport) && (os(iOS) || os(visionOS))
        c.append(check("ImmersiveMediaSupport", "presentation-commands-reader") {
            // a presentation track: set-camera at 0 s, colour fade out at 1 s, shot flop at 2 s; Codable round trip;
            // PresentationDescriptorReader applies them at given times (camera, fade opacity, flop)
            let cmds: [PresentationCommand] = [
                .setCamera(SetCameraCommand(id: 1, time: .zero, cameraID: "cam-a")),
                .fade(FadeCommand(id: 2, time: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 2), direction: .out, color: [0, 0, 0])),
                .shotFlop(ShotFlopCommand(id: 3, time: CMTime(value: 2, timescale: 1), duration: CMTime(value: 1, timescale: 1)))]
            let d = try JSONEncoder().encode(cmds)
            let back = try JSONDecoder().decode([PresentationCommand].self, from: d)
            try expect(back.map(\.id) == [1, 2, 3] && back.map { $0.time.seconds } == [0, 1, 2], "codable \(back.map(\.id))")
            let r = PresentationDescriptorReader(presentationDescriptor: PresentationDescriptor(duration: CMTime(value: 4, timescale: 1), commands: cmds))
            r.processPresentationCommands(for: CMTime(value: 1, timescale: 2))
            let cam = r.cameraID, op0 = r.colorFadeOpacity, flop0 = r.isShotFlopped
            r.processPresentationCommands(for: CMTime(value: 5, timescale: 2))
            let op1 = r.colorFadeOpacity, flop1 = r.isShotFlopped
            try expect(cam == "cam-a", "camera at 0.5 s \(String(describing: cam))")
            // the shot flop applies; the colour fade's opacity stays 1.0 in Apple's simulator too (reported)
            try expect(!flop0 && flop1, "after 2.5 s: flopped \(flop0) -> \(flop1)")
            #if os(visionOS)
            var pb: CVPixelBuffer?
            try expect(CVPixelBufferCreate(nil, 128, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb) == kCVReturnSuccess, "pixel buffer")
            let f = ImmersiveVideoFrame(pixelBuffer: pb!, presentationTime: CMTime(value: 1, timescale: 30))
            try expect(f == ImmersiveVideoFrame(pixelBuffer: pb!, presentationTime: CMTime(value: 1, timescale: 30)), "frame equality")
            #endif
            return "\(d.count) B JSON, camera \(cam!), fade \(op0) -> \(op1), flop \(flop0) -> \(flop1)"
        })
        #endif
        #if canImport(AVRouting) && !os(tvOS) && !os(watchOS)
        c.append(check("AVRouting", "custom-routing-controller-arbiter") {
            // no DeviceDiscoveryExtension in the app: the custom routing controller has no routes and sends no events;
            // known route IPs and custom action items stick; the playback arbiter takes a preferred participant
            let rc = AVCustomRoutingController()
            let d = P1RoutingDelegate(); rc.delegate = d
            rc.knownRouteIPs = [AVCustomRoutingPartialIP(address: Data([192, 0, 2, 10]), mask: Data([255, 255, 255, 255]))]
            let item = AVCustomRoutingActionItem(); item.type = .item; item.overrideTitle = "sdkcov"
            rc.customActionItems = [item]
            try await Task.sleep(for: .milliseconds(300))
            try expect(rc.authorizedRoutes.isEmpty && d.events.load(ordering: .relaxed) == 0, "routes \(rc.authorizedRoutes.count), events \(d.events.load(ordering: .relaxed))")
            let items = rc.customActionItems.count   // Apple's simulator keeps none: reported
            #if os(iOS)
            let a = AVRoutingPlaybackArbiter.shared(); let p = AVPlayer()
            a.preferredParticipantForExternalPlayback = p; a.preferredParticipantForNonMixableAudioRoutes = p
            try expect(a.preferredParticipantForExternalPlayback === p, "arbiter")
            a.preferredParticipantForExternalPlayback = nil; a.preferredParticipantForNonMixableAudioRoutes = nil
            #endif
            return "0 routes, \(rc.knownRouteIPs.count) known IPs, \(items) action items"
        })
        #endif
        #if os(tvOS) && canImport(AVRouting)
        c.append(check("AVRouting", "tv-playback-arbiter-participants") {
            // tvOS has only the playback arbiter: each preference holds its own participant, nil clears it
            let a = AVRoutingPlaybackArbiter.shared(), p1 = AVPlayer(), p2 = AVPlayer()
            a.preferredParticipantForExternalPlayback = p1; a.preferredParticipantForNonMixableAudioRoutes = p2
            try expect(a.preferredParticipantForExternalPlayback === p1 && a.preferredParticipantForNonMixableAudioRoutes === p2, "participants")
            a.preferredParticipantForExternalPlayback = nil; a.preferredParticipantForNonMixableAudioRoutes = nil
            try expect(a.preferredParticipantForExternalPlayback == nil && a.preferredParticipantForNonMixableAudioRoutes == nil, "cleared")
            return "ok"
        })
        #endif
        #if canImport(AVKit) && os(watchOS)
        c.append(check("AVKit", "watch-video-player-playback", timeout: 40) {
            // watchOS AVKit is SwiftUI's VideoPlayer: on screen with an AVPlayer on a 2 s click track, time advances
            let url = try p1ClickTrack(2)
            let p = AVPlayer(url: url); p.isMuted = true
            return try await p1Main { () async throws -> String in
                try await p1Host(VideoPlayer(player: p), secs: 0.5) { _ in
                    p.play()
                    let moved = await p1WaitMain(10) { p.currentTime().seconds > 0.5 }
                    p.pause()
                    try expect(moved, "time \(p.currentTime().seconds), rate \(p.rate), \(String(describing: p.currentItem?.error))")
                    return "played to \(String(format: "%.2f", p.currentTime().seconds)) s"
                }
            }
        })
        #endif
        #if canImport(AVKit) && (os(watchOS) || os(visionOS))
        c.append(check("_AVKit_SwiftUI", "video-player-overlay-playback", timeout: 40) {
            // VideoPlayer with an overlay view: the overlay appears, the player plays (a movie on visionOS, audio on watchOS)
            #if os(visionOS)
            let url = p1Tmp("vp.mov"); try await p1Movie(url, frames: 60)
            #else
            let url = try p1ClickTrack(2)
            #endif
            let p = AVPlayer(url: url); p.isMuted = true
            let seen = Atomic<Bool>(false)
            return try await p1Main { () async throws -> String in
                try await p1Host(VideoPlayer(player: p) { Text("sdkcov overlay").onAppear { seen.store(true, ordering: .relaxed) } }, secs: 0.5) { hc in
                    p.play()
                    let moved = await p1WaitMain(10) { p.currentTime().seconds > 0.5 }
                    p.pause()
                    try expect(seen.load(ordering: .relaxed), "overlay never appeared")
                    try expect(moved, "time \(p.currentTime().seconds), rate \(p.rate), \(String(describing: p.currentItem?.error))")
                    #if os(visionOS)
                    let vcs = (hc as? UIViewController).map { func all(_ v: UIViewController) -> [UIViewController] { [v] + v.children.flatMap(all) }; return all($0) } ?? []
                    let pvc = vcs.contains { $0 is AVPlayerViewController }
                    return "overlay shown, played to \(String(format: "%.2f", p.currentTime().seconds)) s, AVPlayerViewController child \(pvc)"
                    #else
                    return "overlay shown, played to \(String(format: "%.2f", p.currentTime().seconds)) s"
                    #endif
                }
            }
        })
        #endif
        #if canImport(MusicKit)
        c.append(check("_MusicKit_SwiftUI", "artwork-image-subscription-offer", timeout: 30) {
            // ArtworkImage for an artwork decoded from API JSON (URL template on a loopback server): the view lays out at
            // the requested size; musicSubscriptionOffer (iOS / visionOS) attaches without presenting
            let png = try p1PNG(8, 8, rgb: [250, 0, 0])
            let srv = try More2HTTP { r in r.path.hasPrefix("/art/") ? More2Resp("200 OK", [("Content-Type", "image/png")], png) : More2Resp("404 Not Found") }
            let port = try await srv.start(); defer { srv.listener.cancel() }
            let json = "{\"width\":512,\"height\":512,\"url\":\"http://127.0.0.1:\(port)/art/{w}x{h}.png\",\"bgColor\":\"ff0000\"}"
            let art = try JSONDecoder().decode(MusicKit.Artwork.self, from: Data(json.utf8))
            try expect(art.maximumWidth == 512 && art.url(width: 64, height: 64)?.path == "/art/64x64.png", "artwork \(art.maximumWidth) \(String(describing: art.url(width: 64, height: 64)))")
            let size = P1Box<CGSize>(.zero)
            struct V: View {
                let art: MusicKit.Artwork; let size: P1Box<CGSize>
                @State var offer = false
                var body: some View {
                    let a = ArtworkImage(art, width: 64, height: 64)
                        .background(GeometryReader { g in Color.clear.onAppear { size.value = g.size } })
                    #if os(iOS)
                    a.musicSubscriptionOffer(isPresented: $offer)
                    #else
                    a
                    #endif
                }
            }
            return try await p1Main { () async throws -> String in
                try await p1Host(V(art: art, size: size), secs: 2) { _ in
                    try expect(size.value == CGSize(width: 64, height: 64), "ArtworkImage laid out \(size.value)")
                    let reqs = srv.requests.withLock { $0 }
                    return "64x64, bg \(art.backgroundColor.map { "\($0)" } ?? "nil"), \(reqs.count) artwork requests"
                }
            }
        })
        #endif
        #if canImport(PhotosUI) && (os(iOS) || os(watchOS) || os(visionOS))
        c.append(check("_PhotosUI_SwiftUI", "photos-picker-binding-transferable", timeout: 60) {
            // PhotosPicker on screen with a selection binding; a PhotosPickerItem for a library asset (iOS / visionOS,
            // with Photos access) loads its image data through Transferable
            let appeared = P1Box(false)
            struct V: View {
                @Binding var sel: [PhotosPickerItem]; let appeared: P1Box<Bool>
                var body: some View { PhotosPicker(selection: $sel, maxSelectionCount: 2, matching: .images) { Text("Pick photos") }.onAppear { appeared.value = true } }
            }
            let selection = P1Box<[PhotosPickerItem]>([])
            let binding = Binding<[PhotosPickerItem]>(get: { selection.value }, set: { selection.value = $0 })
            try await p1Main { () async throws -> Void in try await p1Host(V(sel: binding, appeared: appeared), secs: 1) { _ in } }
            try expect(appeared.value, "PhotosPicker never appeared")
            #if canImport(Photos) && !os(watchOS)
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return "picker shown (no Photos access: no transferable load)" }
            let opts = PHFetchOptions(); opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; opts.fetchLimit = 1
            guard let a = PHAsset.fetchAssets(with: opts).firstObject else { throw Fail("no image in the library") }
            let item = PhotosPickerItem(itemIdentifier: a.localIdentifier)
            binding.wrappedValue = [item]
            try expect(selection.value.first?.itemIdentifier == a.localIdentifier, "binding")
            // an item made from an identifier (not handed out by the picker) loads nothing: nil, on Apple's simulator too
            let data = try await item.loadTransferable(type: Data.self)
            try expect(data == nil, "loadTransferable gave \(data?.count ?? 0) bytes (Apple's simulator: nil)")
            return "picker shown; binding holds \(a.localIdentifier.prefix(8))..., transferable nil as on Apple"
            #else
            // watchOS: no PhotosPickerItem(itemIdentifier:); the binding holds what the picker sets (nothing yet)
            try expect(selection.value.isEmpty, "selection \(selection.value.count)")
            return "picker shown, empty selection binding"
            #endif
        })
        #endif
        return c
    }
}
