// sdkcov P1 (media & AV): media libraries and players. Photos library writes / fetches / image + video requests /
// change observer, MediaPlayer queue player + library + now-playing session, MusicKit objects and the simulator's
// account answers, ShazamKit custom-catalog matching, MediaAccessibility caption / audible media / image captions,
// ReplayKit, VideoSubscriberAccount, AVKit player UI + PiP + route picker, and the simulator answers of
// LockedCameraCapture and AVKit's group-activities overlay.
import Foundation
import Synchronization
import SwiftUI
import AVFoundation
import CoreMedia
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(MusicKit)
import MusicKit
#endif
#if canImport(ShazamKit)
import ShazamKit
#endif
#if canImport(MediaAccessibility)
import MediaAccessibility
#endif
#if canImport(ReplayKit)
import ReplayKit
#endif
#if canImport(VideoSubscriberAccount)
import VideoSubscriberAccount
#endif
#if canImport(AVKit)
import AVKit
#endif
#if canImport(LockedCameraCapture)
import LockedCameraCapture
#endif
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

// MARK: helpers

/// show a SwiftUI view on screen for `secs` (a window over the app's on iOS / tvOS / visionOS, Runner.overlay on
/// watchOS), then `inspect` it (the hosting controller, nil on watchOS)
@MainActor func p1Host<V: View, T>(_ v: V, secs: Double = 1, _ inspect: @MainActor (AnyObject?) async throws -> T) async throws -> T {
    #if os(watchOS)
    Runner.shared.overlay = AnyView(v)
    defer { Runner.shared.overlay = nil }
    try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    return try await inspect(nil)
    #else
    let hc = UIHostingController(rootView: v)
    let close = try p1Show(hc)
    defer { close() }
    hc.view.layoutIfNeeded()
    try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    return try await inspect(hc)
    #endif
}
#if !os(watchOS)
/// `vc` in a window above the app's; the closure takes it down
@MainActor func p1Show(_ vc: UIViewController) throws -> () -> Void {
    guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Fail("no window scene") }
    let prev = ws.windows.first(where: \.isKeyWindow)
    let w = UIWindow(windowScene: ws); w.frame = ws.coordinateSpace.bounds; w.windowLevel = .normal + 1
    w.rootViewController = vc; w.makeKeyAndVisible(); w.layoutIfNeeded()
    return { w.isHidden = true; w.rootViewController = nil; prev?.makeKeyAndVisible() }
}
@MainActor func p1Subviews(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap { p1Subviews($0) } }
#endif
/// the app declares NSAppleMusicUsageDescription: without it, touching the media library / Apple Music (MediaPlayer
/// queue player and queries, MusicKit's account calls) makes Apple's simulator kill the app (TCC usage string check)
let p1HasMusicUsage = Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") != nil
/// run an async body on the main actor
@MainActor func p1Main<T>(_ f: @MainActor () async throws -> T) async throws -> T { try await f() }
/// poll on the main actor
func p1WaitMain(_ secs: Double, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if await MainActor.run(body: { cond() }) { return true }; try? await Task.sleep(for: .milliseconds(30)) }
    return await MainActor.run(body: { cond() })
}
/// a PNG of a solid colour (CoreGraphics)
func p1PNG(_ w: Int, _ h: Int, rgb: [UInt8]) throws -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let d = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(d, UTType.png.identifier as CFString, 1, nil) else { throw Fail("PNG destination") }
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
    try expect(CGImageDestinationFinalize(dst), "PNG finalize")
    return d as Data
}
/// centre pixel (r, g, b) of encoded image data
func p1CenterRGB(_ d: Data) -> [Int]? {
    guard let src = CGImageSourceCreateWithData(d as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return p1CenterRGB(img)
}
func p1CenterRGB(_ img: CGImage) -> [Int] {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: -CGFloat(img.width / 2), y: -CGFloat(img.height / 2), width: CGFloat(img.width), height: CGFloat(img.height)))
    return px.prefix(3).map(Int.init)
}

#if canImport(Photos) && !os(watchOS)
final class P1PhotoObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let changes = Atomic<Int>(0)
    func photoLibraryDidChange(_ c: PHChange) { changes.add(1, ordering: .relaxed) }
}
#endif

#if canImport(ShazamKit)
/// a deterministic "song": a melody of tones over pseudo-random noise bursts (ShazamKit needs spectral peaks that move)
func p1Song(secs: Double, rate: Double = 48000) -> AVAudioPCMBuffer {
    let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let n = AVAudioFrameCount(secs * rate)
    let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n)!; b.frameLength = n
    let p = b.floatChannelData![0]
    let notes: [Double] = [262, 330, 392, 523, 440, 349, 294, 494, 587, 370, 415, 659]
    var seed: UInt32 = 12345
    for i in 0..<Int(n) {
        let t = Double(i) / rate, k = Int(t * 4)   // 4 notes per second
        let hz = notes[(k * 7) % notes.count], hz2 = notes[(k * 5 + 3) % notes.count] * 2
        seed = seed &* 1103515245 &+ 12345
        let noise = (Double(seed >> 16 & 0x7fff) / 16384 - 1) * (t.truncatingRemainder(dividingBy: 0.25) < 0.02 ? 0.3 : 0.0)
        p[i] = Float(0.35 * sin(2 * .pi * hz * t) + 0.2 * sin(2 * .pi * hz2 * t) + noise)
    }
    return b
}
#endif

extension Registry {
    static var p1_library: [Check] {
        var c: [Check] = []
        #if canImport(Photos) && !os(watchOS)
        c.append(check("Photos", "library-create-fetch-request", timeout: 90) {
            // with read-write access (run.sh / ref-mac.sh grant it): an image asset (PNG) and a video asset are created,
            // put in an album and the image marked favourite in performChanges; fetched back by identifier, the album's
            // contents, PHImageManager (pixels), PHAssetResourceManager (bytes), requestAVAsset (duration); the change
            // observer hears it. Nothing is deleted: deletion asks the user (an alert), on Apple's simulator too
            let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            try skipIf(st != .authorized, "Photos access \(st.rawValue) (run.sh / ref-mac.sh grant kTCCServicePhotos)")
            let obs = P1PhotoObserver(); PHPhotoLibrary.shared().register(obs)
            defer { PHPhotoLibrary.shared().unregisterChangeObserver(obs) }
            let before = PHAsset.fetchAssets(with: nil).count
            let png = try p1PNG(64, 48, rgb: [20, 200, 40])
            let mov = p1Tmp("photos.mov")
            try await p1Movie(mov, frames: 30, color: { _ in [0, 0, 255] })
            let ids = P1Box<(String?, String?, String?)>((nil, nil, nil))
            let title = "sdkcov-p1"
            try await PHPhotoLibrary.shared().performChanges {
                let img = PHAssetCreationRequest.forAsset()
                img.addResource(with: .photo, data: png, options: nil)
                img.isFavorite = true; img.creationDate = Date(timeIntervalSince1970: 1_800_000_000)
                let vid = PHAssetCreationRequest.forAsset()
                let o = PHAssetResourceCreationOptions(); o.shouldMoveFile = false
                vid.addResource(with: .video, fileURL: mov, options: o)
                let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
                var album: PHAssetCollectionChangeRequest?
                existing.enumerateObjects { col, _, stop in if col.localizedTitle == title { album = PHAssetCollectionChangeRequest(for: col); stop.pointee = true } }
                let req = album ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                req.addAssets([img.placeholderForCreatedAsset!, vid.placeholderForCreatedAsset!] as NSArray)
                ids.value = (img.placeholderForCreatedAsset?.localIdentifier, vid.placeholderForCreatedAsset?.localIdentifier, req.placeholderForCreatedAssetCollection.localIdentifier)
            }
            guard let iid = ids.value.0, let vid = ids.value.1 else { throw Fail("no placeholders") }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [iid, vid], options: nil)
            try expect(fetched.count == 2, "fetched \(fetched.count) of the 2 created assets")
            let img = fetched.objects(at: IndexSet(0..<2)).first { $0.mediaType == .image }!, video = fetched.objects(at: IndexSet(0..<2)).first { $0.mediaType == .video }!
            try expect(img.pixelWidth == 64 && img.pixelHeight == 48 && img.isFavorite, "image asset \(img.pixelWidth)x\(img.pixelHeight) favorite \(img.isFavorite)")
            try expect(abs(video.duration - 1) < 0.1, "video asset duration \(video.duration)")
            let favs = PHAsset.fetchAssets(with: { let o = PHFetchOptions(); o.predicate = NSPredicate(format: "favorite == YES"); return o }())
            var favHas = false; favs.enumerateObjects { a, _, _ in if a.localIdentifier == iid { favHas = true } }
            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            var inAlbum = 0
            albums.enumerateObjects { col, _, _ in if col.localizedTitle == title { let a = PHAsset.fetchAssets(in: col, options: nil); a.enumerateObjects { x, _, _ in if x.localIdentifier == iid || x.localIdentifier == vid { inAlbum += 1 } } } }
            try expect(favHas && inAlbum == 2, "favorites contain it \(favHas), album holds \(inAlbum)/2")
            // image request: pixels
            let io = PHImageRequestOptions(); io.isSynchronous = false; io.deliveryMode = .highQualityFormat; io.isNetworkAccessAllowed = false
            let got: CGImage? = await withCheckedContinuation { cont in
                PHImageManager.default().requestImage(for: img, targetSize: CGSize(width: 32, height: 24), contentMode: .aspectFit, options: io) { im, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    cont.resume(returning: im?.cgImage)
                }
            }
            guard let got else { throw Fail("requestImage returned nil") }
            let px = p1CenterRGB(got)
            try expect(abs(px[0] - 20) < 25 && abs(px[1] - 200) < 25 && abs(px[2] - 40) < 25, "requested image pixel \(px)")
            // resource bytes
            let res = PHAssetResource.assetResources(for: img)
            let data = P1Box(Data())
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().requestData(for: res[0], options: nil, dataReceivedHandler: { d in data.mutate { $0.append(d) } }) { e in
                    if let e { cont.resume(throwing: e) } else { cont.resume() } }
            }
            try expect(p1CenterRGB(data.value).map { abs($0[1] - 200) < 25 } == true, "resource \(res[0].originalFilename) \(data.value.count) B")
            // video request
            let av: AVAsset? = await withCheckedContinuation { cont in
                let vo = PHVideoRequestOptions(); vo.isNetworkAccessAllowed = false; vo.deliveryMode = .highQualityFormat
                PHImageManager.default().requestAVAsset(forVideo: video, options: vo) { a, _, _ in cont.resume(returning: a) }
            }
            let vd = try await av?.load(.duration).seconds ?? -1
            try expect(abs(vd - 1) < 0.1, "requestAVAsset duration \(vd)")
            let heard = await more2Wait(5) { obs.changes.load(ordering: .relaxed) > 0 }
            try expect(heard, "PHPhotoLibraryChangeObserver heard nothing")
            return "\(before) -> \(PHAsset.fetchAssets(with: nil).count) assets; image \(px), \(data.value.count) B resource; video \(String(format: "%.2f", vd)) s; \(obs.changes.load(ordering: .relaxed)) change notes"
        })
        #endif
        #if canImport(MediaPlayer)
        #if os(iOS) || os(visionOS)
        c.append(check("MediaPlayer", "queue-player-library-commands", timeout: 40) {
            // the application queue player with a store-ID queue (no account on the simulator): state stays stopped and
            // no item plays; library authorization + queries (empty library); remote command configuration;
            // MPNowPlayingSession over an AVPlayer; MPVolumeView builds its slider
            var lib = "media library not touched (no NSAppleMusicUsageDescription in the app: Apple's simulator kills it)"
            if p1HasMusicUsage {
                let qp = MPMusicPlayerController.applicationQueuePlayer
                qp.beginGeneratingPlaybackNotifications(); defer { qp.endGeneratingPlaybackNotifications() }
                qp.setQueue(with: ["1440818839"])
                qp.repeatMode = .all; qp.shuffleMode = .songs
                try expect(qp.repeatMode == .all && qp.shuffleMode == .songs, "modes \(qp.repeatMode.rawValue) \(qp.shuffleMode.rawValue)")
                let qst = qp.playbackState
                try expect(qst == .stopped || qst == .paused, "queue player state \(qst.rawValue)")
                let auth = MPMediaLibrary.authorizationStatus()
                var songs = -1, albums = -1
                if auth == .authorized {   // a query before access is granted would ask for it (a prompt)
                    songs = MPMediaQuery.songs().items?.count ?? -1; albums = MPMediaQuery.albums().collections?.count ?? -1
                    let pred = MPMediaPropertyPredicate(value: "sdkcov", forProperty: MPMediaItemPropertyTitle, comparisonType: .contains)
                    let q = MPMediaQuery(filterPredicates: [pred]); q.groupingType = .album
                    try expect((q.items?.count ?? 0) == 0 && q.filterPredicates?.count == 1, "filtered query \(String(describing: q.items?.count))")
                }
                lib = "queue player \(qst.rawValue), library auth \(auth.rawValue) songs \(songs) albums \(albums)"
            }
            let cc = MPRemoteCommandCenter.shared()
            cc.skipForwardCommand.preferredIntervals = [30]; cc.skipForwardCommand.isEnabled = true
            let t1 = cc.skipForwardCommand.addTarget { _ in .success }
            let t2 = cc.changePlaybackPositionCommand.addTarget { e in (e as? MPChangePlaybackPositionCommandEvent).map { _ in .success } ?? .commandFailed }
            cc.likeCommand.localizedTitle = "sdkcov like"
            try expect(cc.skipForwardCommand.preferredIntervals == [30] && cc.likeCommand.localizedTitle == "sdkcov like", "command config")
            cc.skipForwardCommand.removeTarget(t1); cc.changePlaybackPositionCommand.removeTarget(t2)
            let p = AVPlayer(); p.isMuted = true
            let s = MPNowPlayingSession(players: [p])
            s.automaticallyPublishesNowPlayingInfo = true
            let active = await s.becomeActiveIfPossible()
            try expect(s.players.first === p && s.automaticallyPublishesNowPlayingInfo, "now playing session")
            let vol = try await onMain { () -> String in
                let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 300, height: 40)); v.layoutIfNeeded()
                // Apple's simulator shows no volume slider (no hardware volume): 0 sliders there too
                let sliders = p1Subviews(v).filter { $0 is UISlider }.count
                try expect(sliders == 0, "MPVolumeView has \(sliders) sliders (Apple's simulator: 0)")
                return "volume view without slider (as on Apple's simulator)"
            }
            return "\(lib), session active \(active), \(vol)"
        })
        #elseif os(tvOS)
        c.append(check("MediaPlayer", "now-playing-session-commands", timeout: 30) {
            let p = AVPlayer(); p.isMuted = true
            let s = MPNowPlayingSession(players: [p]); s.automaticallyPublishesNowPlayingInfo = true
            let active = await s.becomeActiveIfPossible()
            s.nowPlayingInfoCenter.nowPlayingInfo = [MPMediaItemPropertyTitle: "sdkcov tv", MPNowPlayingInfoPropertyPlaybackRate: 0.0]
            try expect(s.nowPlayingInfoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "sdkcov tv", "session info center")
            let cc = s.remoteCommandCenter
            cc.skipBackwardCommand.preferredIntervals = [10]
            let t = cc.togglePlayPauseCommand.addTarget { _ in .success }; cc.togglePlayPauseCommand.removeTarget(t)
            try expect(cc.skipBackwardCommand.preferredIntervals == [10], "session command center")
            return "session active \(active), \(s.players.count) player"
        })
        #endif
        #endif
        #if canImport(MusicKit)
        c.append(check("MusicKit", "objects-subscription-catalog-answers", timeout: 60) {
            // MusicKit's value types decode from Apple Music API JSON (Song: title, artist, duration, artwork URL
            // template); MusicItemID codable; the account parts answer the simulator's way (no Apple Music account,
            // no developer token): subscription, catalog search -> an error, never a hang; the app player's queue
            let json = """
            {"id":"1440818839","type":"songs","attributes":{"name":"sdkcov song","artistName":"x86sim","albumName":"P1","durationInMillis":201000,
             "artwork":{"width":1000,"height":1000,"url":"https://example.com/a/{w}x{h}bb.jpg","bgColor":"112233"},"genreNames":["Test"],"playParams":{"id":"1440818839","kind":"song"}}}
            """
            let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
            try expect(song.title == "sdkcov song" && song.artistName == "x86sim" && song.duration == 201 && song.id == "1440818839", "decoded \(song.title) / \(song.artistName) / \(String(describing: song.duration))")
            let art = song.artwork?.url(width: 100, height: 100)?.absoluteString
            try expect(art == "https://example.com/a/100x100bb.jpg", "artwork url \(String(describing: art))")
            let idData = try JSONEncoder().encode(MusicItemID("42"))
            try expect(try JSONDecoder().decode(MusicItemID.self, from: idData) == "42", "MusicItemID codable")
            let auth = MusicAuthorization.currentStatus
            guard p1HasMusicUsage else { return "objects ok, auth \(auth); account calls not made (no NSAppleMusicUsageDescription in the app: Apple's simulator kills it)" }
            let sub: String = await { do { let s = try await more2Stage("MusicSubscription.current", 20) { try await MusicSubscription.current }
                return "canPlay \(s.canPlayCatalogContent) canBecome \(s.canBecomeSubscriber)" } catch { return "error \(error)" } }()
            let search: String = await { do { var r = MusicCatalogSearchRequest(term: "sdkcov", types: [Song.self]); r.limit = 1
                let res = try await more2Stage("catalog search", 25) { try await r.response() }; return "\(res.songs.count) songs" } catch { return "\(type(of: error)): \(String(describing: error).prefix(80))" } }()
            try expect(!sub.contains("no answer") && !search.contains("no answer"), "account calls hung: subscription \(sub), search \(search)")
            var player = "no app player"
            #if !os(watchOS)
            let ap = ApplicationMusicPlayer.shared
            ap.queue = ApplicationMusicPlayer.Queue(for: [song])
            ap.state.repeatMode = MusicPlayer.RepeatMode.none
            player = "app player \(ap.state.playbackStatus), queue \(ap.queue.entries.count) entries"
            #endif
            return "auth \(auth); subscription \(sub); search \(search); \(player)"
        })
        #endif
        #if canImport(ShazamKit)
        c.append(check("ShazamKit", "custom-catalog-match", timeout: 90) {
            // a reference signature of 12 s of a synthetic song in an SHCustomCatalog with one media item; a query
            // signature of seconds 4-10 matches it through SHSession (title, offset ~4 s); a different song doesn't;
            // the catalog's data round-trips; SHManagedSession starts idle
            let song = p1Song(secs: 12)
            let g = SHSignatureGenerator(); try g.append(song, at: nil)
            let ref = g.signature()
            let item = SHMediaItem(properties: [.title: "sdkcov p1 song", .artist: "x86sim", .shazamID: "p1-1"])
            let cat = SHCustomCatalog()
            try cat.addReferenceSignature(ref, representing: [item])
            let qb = AVAudioPCMBuffer(pcmFormat: song.format, frameCapacity: 6 * 48000)!; qb.frameLength = 6 * 48000
            memcpy(qb.floatChannelData![0], song.floatChannelData![0] + 4 * 48000, 6 * 48000 * 4)
            let qg = SHSignatureGenerator(); try qg.append(qb, at: nil)
            let session = SHSession(catalog: cat)
            let r = await session.result(from: qg.signature())
            guard case .match(let m) = r else { throw Fail("no match: \(r)") }
            let mi = m.mediaItems.first
            try expect(mi?.title == "sdkcov p1 song" && mi?.artist == "x86sim", "matched \(String(describing: mi?.title))")
            let off = mi?.matchOffset ?? -1
            try expect(abs(off - 4) < 1.0, "match offset \(off) (want ~4 s)")
            // a different signal
            let other = p1Tones([300, 1200], secs: 6, rate: 48000)
            let og = SHSignatureGenerator(); try og.append(other, at: nil)
            let r2 = await SHSession(catalog: cat).result(from: og.signature())
            if case .match = r2 { throw Fail("a sine pair matched the song") }
            let back = try SHCustomCatalog(dataRepresentation: cat.dataRepresentation)
            let r3 = await SHSession(catalog: back).result(from: qg.signature())
            guard case .match = r3 else { throw Fail("the round-tripped catalog does not match: \(r3)") }
            let ms = SHManagedSession(catalog: cat)
            let st = await onMain { ms.state }
            try expect(st == .idle, "managed session state \(st)")
            ms.cancel()
            return "matched at \(String(format: "%.2f", off)) s, other signal \(r2), catalog \(cat.dataRepresentation.count) B"
        })
        #endif
        #if canImport(MediaAccessibility)
        c.append(check("MediaAccessibility", "caption-style-audible-image-caption", timeout: 30) {
            // caption style (font descriptor, colours, sizes, edge style for the user's style), the preferred audible
            // characteristics, and an image's accessibility caption written into and read back from a JPEG
            let fd = MACaptionAppearanceCopyFontDescriptorForStyle(.user, nil, .default).takeRetainedValue()
            let fname = CTFontDescriptorCopyAttribute(fd, kCTFontNameAttribute) as? String ?? "-"
            var beh = MACaptionAppearanceBehavior.useValue
            let fg = MACaptionAppearanceCopyForegroundColor(.user, &beh).takeRetainedValue()
            let bgOp = MACaptionAppearanceGetBackgroundOpacity(.user, nil)
            let size = MACaptionAppearanceGetRelativeCharacterSize(.user, nil)
            let edge = MACaptionAppearanceGetTextEdgeStyle(.user, nil)
            try expect(fg.numberOfComponents >= 2 && size > 0 && bgOp >= 0 && bgOp <= 1, "style: fg \(fg), size \(size), bg opacity \(bgOp)")
            let chars = MAAudibleMediaCopyPreferredCharacteristics().takeRetainedValue() as? [String] ?? []
            let langs = MACaptionAppearanceCopySelectedLanguages(.user).takeRetainedValue() as? [String] ?? []
            #if !os(visionOS)
            let jpg = p1Tmp("cap.jpg")
            let png = try p1PNG(32, 32, rgb: [200, 10, 10])
            let src = CGImageSourceCreateWithData(png as CFData, nil)!
            let dst = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImageFromSource(dst, src, 0, nil); try expect(CGImageDestinationFinalize(dst), "jpeg")
            var err: CFError?
            try expect(MAImageCaptioningSetCaption(jpg as CFURL, "sdkcov red square" as CFString, &err), "set caption: \(String(describing: err))")
            let back = MAImageCaptioningCopyCaption(jpg as CFURL, &err) as String?
            try expect(back == "sdkcov red square", "caption read back \(String(describing: back)) \(String(describing: err))")
            let tag = MAImageCaptioningCopyMetadataTagPath() as String
            let capInfo = "caption in \(tag)"
            #else
            let capInfo = "no image captioning on visionOS"
            #endif
            return "font \(fname), size \(size), edge \(edge.rawValue), \(chars.count) audible characteristics, \(langs.count) languages, \(capInfo)"
        })
        #endif
        #if canImport(ReplayKit) && !os(watchOS)
        c.append(check("ReplayKit", "capture-answer-picker", timeout: 40) {
            // in-app capture: Apple's simulator answers startCapture (sample buffers or an error) without a hang;
            // the recorder's flags; the broadcast picker view (iOS)
            let r = RPScreenRecorder.shared()
            #if !os(tvOS)
            r.isMicrophoneEnabled = false
            try expect(!r.isMicrophoneEnabled, "microphone flag")
            #endif
            try expect(!r.isRecording, "recorder flags")
            let video = Atomic<Int>(0), started = P1Box<String?>(nil)
            r.startCapture(handler: { _, type, err in if type == .video && err == nil { video.add(1, ordering: .relaxed) } }) { e in started.value = e.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "started" }
            _ = await more2Wait(15) { started.value != nil }
            if started.value == "started" { _ = await more2Wait(5) { video.load(ordering: .relaxed) > 0 } }
            let stopped = P1Box<Bool>(false)
            r.stopCapture { _ in stopped.value = true }
            _ = await more2Wait(5) { stopped.value }
            guard let s = started.value else { throw Fail("startCapture never completed (available \(r.isAvailable))") }
            // Apple's simulator (iOS and tvOS 27.2): capture starts, but no sample buffers arrive in 5 s
            if s != "started" { try expect(s.hasPrefix("error"), "startCapture answer \(s)") }
            var picker = ""
            #if os(iOS)
            picker = try await onMain { () -> String in
                let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60)); v.showsMicrophoneButton = false; v.layoutIfNeeded()
                let buttons = p1Subviews(v).filter { $0 is UIButton }.count
                try expect(buttons >= 1, "broadcast picker has \(buttons) buttons")
                return ", picker \(buttons) button"
            }
            #endif
            return "available \(r.isAvailable), startCapture \(s), \(video.load(ordering: .relaxed)) video buffers\(picker)"
        })
        #endif
        #if canImport(VideoSubscriberAccount) && !os(watchOS)
        c.append(check("VideoSubscriberAccount", "access-status-user-accounts", timeout: 40) {
            // the TV-provider access check answers without prompting; a user account (subscription) is registered and
            // queried back through VSUserAccountManager
            // without NSVideoSubscriberAccountUsageDescription, checkAccessStatus raises (VSRequireUsageInfoPlistKey), as on
            // Apple's simulator
            try skipIf(Bundle.main.object(forInfoDictionaryKey: "NSVideoSubscriberAccountUsageDescription") == nil, "no NSVideoSubscriberAccountUsageDescription in the app (checkAccessStatus would raise)")
            let m = VSAccountManager()
            let access = P1Box<String?>(nil)
            m.checkAccessStatus(options: [.prompt: false]) { st, e in access.value = "status \(st.rawValue)\(e.map { " error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "")" }
            _ = await more2Wait(15) { access.value != nil }
            guard let a = access.value else { throw Fail("checkAccessStatus never answered") }
            var ua = VSUserAccount(accountType: .paid, updateURL: URL(string: "https://example.com/sdkcov/update")!)
            ua.identifier = "sdkcov-user"; ua.tierIdentifiers = ["gold"]; ua.isSignedOut = false
            let upd: String = await { do { try await more2Stage("update", 20) { try await VSUserAccountManager.shared.update(ua) }; return "ok" } catch { return "error \(error)" } }()
            let q: String = await { do { let l = try await more2Stage("userAccounts", 20) { try await VSUserAccountManager.shared.userAccounts() }
                return "\(l.count) accounts\(l.contains { $0.identifier == "sdkcov-user" } ? " incl. ours" : "")" } catch { return "error \(error)" } }()
            try expect(!upd.contains("no answer") && !q.contains("no answer"), "user account manager hung: update \(upd), query \(q)")
            if upd == "ok" { try expect(q.contains("incl. ours"), "registered account not returned: \(q)") }
            return "access \(a); update \(upd); query \(q)"
        })
        #endif
        #if canImport(AVKit) && (os(iOS) || os(visionOS))
        c.append(check("AVKit", "player-vc-playback-pip-route-picker", timeout: 60) {
            // AVPlayerViewController on screen plays a movie (time advances, video bounds), PiP support and a
            // sample-buffer PiP controller, AVRoutePickerView's button
            let url = p1Tmp("avkit.mov"); try await p1Movie(url, frames: 60, color: { _ in [0, 255, 255] })
            let player = AVPlayer(url: url); player.isMuted = true
            let (vc, close) = try await onMain { () -> (AVPlayerViewController, () -> Void) in
                let vc = AVPlayerViewController(); vc.player = player; vc.allowsPictureInPicturePlayback = true
                return (vc, try p1Show(vc))
            }
            defer { Task { @MainActor in player.pause(); close() } }
            await onMain { player.play() }
            let moved = await p1WaitMain(10) { player.currentTime().seconds > 0.5 }
            let vb = await onMain { vc.videoBounds }
            try expect(moved, "playback did not advance: \(player.currentTime().seconds) s, rate \(player.rate), \(String(describing: player.currentItem?.error))")
            #if os(iOS)
            try expect(vb.width > 10 && abs(vb.width - vb.height) < 2, "video bounds \(vb)")
            #endif   // visionOS: videoBounds is (inf, inf, 0, 0), on Apple's simulator too
            let pip = AVPictureInPictureController.isPictureInPictureSupported()
            let pipInfo = try await onMain { () -> String in
                final class D: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
                    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying p: Bool) {}
                    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)) }
                    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }
                    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize s: CMVideoDimensions) {}
                    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval i: CMTime) async {}
                }
                let layer = AVSampleBufferDisplayLayer()
                let src = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: D())
                let pc = AVPictureInPictureController(contentSource: src)
                #if os(iOS)
                let rp = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44)); rp.layoutIfNeeded()
                let btn = p1Subviews(rp).filter { $0 is UIButton }.count
                try expect(btn >= 1, "route picker has \(btn) buttons")
                return "sample-buffer PiP possible \(pc.isPictureInPicturePossible), route picker \(btn) button"
                #else
                return "sample-buffer PiP possible \(pc.isPictureInPicturePossible)"
                #endif
            }
            return "played to \(String(format: "%.2f", player.currentTime().seconds)) s, video \(Int(vb.width))x\(Int(vb.height)), PiP supported \(pip), \(pipInfo)"
        })
        #endif
        #if canImport(LockedCameraCapture) && os(iOS)
        c.append(check("LockedCameraCapture", "manager-simulator-answers", timeout: 30) {
            // no capture extension, no cameras: the manager lists no session content and refuses to invalidate a URL
            // that isn't one
            let m = LockedCameraCaptureManager.shared
            let urls = m.sessionContentURLs
            try expect(urls.isEmpty, "session content URLs \(urls)")
            var e = "no error"
            do { try await m.invalidateSessionContent(at: FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-not-session")) } catch { e = "\(type(of: error)) \((error as NSError).domain) \((error as NSError).code)" }
            // Apple's simulator: invalidating any URL succeeds (nothing to invalidate)
            try expect(e == "no error", "invalidate: \(e) (Apple's simulator: no error)")
            m.beginDelayingAppearance(); m.endDelayingAppearance()
            return "0 session URLs, invalidate: \(e)"
        })
        #endif
        #if os(visionOS) && canImport(AVKit)
        c.append(check("_AVKit_GroupActivities", "playback-coordinator-no-session", timeout: 30) {
            // no FaceTime in the simulator, so no GroupSession: the player's playback coordinator exists with no other
            // participants and takes its policy settings; the group-experience coordinator starts inactive
            let p = AVPlayer()
            let co = p.playbackCoordinator
            co.pauseSnapsToMediaTimeOfOriginator = true
            co.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
            try expect(co.otherParticipants.isEmpty && co.pauseSnapsToMediaTimeOfOriginator && co.suspensionReasonsThatTriggerWaiting == [.stallRecovery], "coordinator \(co.otherParticipants.count) participants")
            let s = co.beginSuspension(for: .userActionRequired); s.end()
            return "playback coordinator: 0 participants, suspension begun/ended"
        })
        #endif
        return c
    }
}
