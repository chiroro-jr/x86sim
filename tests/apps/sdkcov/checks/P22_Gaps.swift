// SDK coverage, round 26: checks for [a] gaps (COVERAGE-GAPS.md). Each asserts what Apple's simulator answers
// (ref-mac.sh).
import Foundation
import Synchronization
import CoreMedia
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(iOS)
import UIKit
import CryptoTokenKit
#endif

/// sdkcov's movies made on a Mac (res/sdkcovMovies.swift; build.sh copies res/*.mov into the bundle): sdkcovChapters.mov
/// (p21ChapterMovie's chapters "Opening" / "Middle" / "Credits") and sdkcovStall.mov (p21AVMovie's 6 s video + AAC)
func p22Movie(_ name: String) throws -> URL {
    guard let u = Bundle.main.url(forResource: name, withExtension: "mov") else { throw Fail("\(name).mov not in the bundle") }
    return u
}

/// the [start, end) byte range of the top-level atom `type` in a QuickTime file
func p22Atom(_ d: Data, _ type: String) -> (Int, Int)? {
    var off = 0
    while off + 8 <= d.count {
        var size = Int(d[off]) << 24 | Int(d[off + 1]) << 16 | Int(d[off + 2]) << 8 | Int(d[off + 3])
        if size == 1, off + 16 <= d.count { size = d[off + 8 ..< off + 16].reduce(0) { $0 << 8 | Int($1) } }
        if String(decoding: d[off + 4 ..< off + 8], as: UTF8.self) == type { return (off, off + size) }
        if size < 8 { break }; off += size
    }
    return nil
}

#if os(iOS)
/// an NSUserActivity delegate noting UIKit's save of the scene's activity
final class P22ActivityDelegate: NSObject, NSUserActivityDelegate, @unchecked Sendable {
    let saves = Atomic<Int>(0)
    func userActivityWillSave(_ a: NSUserActivity) { saves.add(1, ordering: .relaxed) }
}
/// a mark from the app (ext/Marks.swift's format), read by the companion app sdkcovDoc
func p22Mark(_ name: String, _ text: String) {
    guard let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: p3Group) else { return }
    let dir = g.appendingPathComponent("p3marks", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent(name)
    let line = Data("\(Date().timeIntervalSince1970) \(text)\n".utf8)
    if let h = try? FileHandle(forWritingTo: f) { _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close() } else { try? line.write(to: f) }
}
#endif

extension Registry {
    static var p22: [Check] {
        var c: [Check] = []

        // MARK: AVFoundation: QuickTime chapters read from a bundled movie (watchOS has no AVAssetWriter: the iOS check
        // P21 chapters-text-track writes its own; run on iOS and watchOS)
        #if canImport(AVFoundation) && (os(iOS) || os(watchOS))
        c.append(check("AVFoundation", "chapters-bundled-movie", timeout: 60) {
            let asset = AVURLAsset(url: try p22Movie("sdkcovChapters"))
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

        // MARK: AVFoundation: AVPlayerItem playback stalled over HTTP: a loopback server (More2HTTP) answers byte ranges
        // of a bundled movie but holds back everything past a third of its media data (the rest of the chunked body
        // would come 10 minutes later) (watchOS has no AVAssetResourceLoader: P21 player-stalled-notification uses one)
        #if canImport(Network)
        c.append(check("AVFoundation", "player-stalled-http-loopback", timeout: 90) {
            let d = try Data(contentsOf: try p22Movie("sdkcovStall"))
            guard let mdat = p22Atom(d, "mdat") else { throw Fail("no mdat in sdkcovStall.mov") }
            let cutoff = mdat.0 + (mdat.1 - mdat.0) / 3
            let held = Atomic<Int>(0)
            let srv = try More2HTTP { req in
                var a = 0, b = d.count - 1
                let ranged = req.headers["range"].map { r -> Bool in
                    let p = r.replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
                    if let x = Int(p.first ?? "") { a = x }
                    if p.count > 1, let y = Int(p[1]) { b = min(y, d.count - 1) }
                    return true
                } ?? false
                var r = More2Resp(ranged ? "206 Partial Content" : "200 OK", [("Content-Type", "video/quicktime"), ("Accept-Ranges", "bytes")])
                if ranged { r.headers.append(("Content-Range", "bytes \(a)-\(b)/\(d.count)")) }
                let body = d.subdata(in: a ..< b + 1)
                if a < mdat.1 && b + 1 > cutoff {
                    // the held-back media data: what is before the cutoff now (at least one byte: chunk 0 goes at
                    // once, an empty one would end the body), the rest 10 minutes later
                    let now = max(1, cutoff - a)
                    r.chunks = [Data(body.prefix(now)), Data(body.dropFirst(now))].filter { !$0.isEmpty }
                    r.gap = 600
                    held.add(1, ordering: .relaxed)
                } else { r.body = body }
                return r
            }
            let port = try await srv.start()
            defer { srv.stop() }
            let item = AVPlayerItem(url: srv.url("/stall.mov"))
            let notes = Mutex<[String]>([])
            let nc = NotificationCenter.default
            var obs: [NSObjectProtocol] = []
            for (n, tag) in [(AVPlayerItem.playbackStalledNotification, "stalled"), (AVPlayerItem.failedToPlayToEndTimeNotification, "failedToPlayToEnd"),
                             (AVPlayerItem.didPlayToEndTimeNotification, "playedToEnd")] {
                obs.append(nc.addObserver(forName: n, object: item, queue: nil) { _ in notes.withLock { if !$0.contains(tag) { $0.append(tag) } } })
            }
            defer { obs.forEach { nc.removeObserver($0) } }
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = false
            p.play()
            let end = Date().addingTimeInterval(40)
            while Date() < end && notes.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(200)) }
            try await Task.sleep(for: .seconds(1))
            let t = p.currentTime().seconds, st = item.status.rawValue, err = p8Err(item.error)
            p.pause(); p.replaceCurrentItem(with: nil)
            let n = notes.withLock { $0 }
            let detail = "notifications \(n); played to \(String(format: "%.1f", t)) s of 6, item status \(st), error \(err); port \(port), \(srv.requests.withLock { $0.count }) requests, \(held.load(ordering: .relaxed)) held back"
            try expect(n.contains("stalled") && !n.contains("playedToEnd"), detail)
            return detail
        })
        #endif
        #endif

        // MARK: CryptoTokenKit: a persistent token (the app's token extension, ext/Token.swift) configured from the app
        // (TKTokenDriver.Configuration) with a certificate: TKTokenWatcher sees the token, the keychain lists the
        // certificate under its token id (TKTokenKeychainContents), and removing the configuration takes both away
        #if os(iOS)
        c.append(check("CryptoTokenKit", "persistent-token-keychain", timeout: 90) {
            let cls = "com.x86sim.test.sdkcov.token", inst = "sdkcov-p22", tid = "\(cls):\(inst)"
            let t0 = Date()
            var dcs: [String: TKTokenDriver.Configuration] = [:]
            for _ in 0..<20 { dcs = TKTokenDriver.Configuration.driverConfigurations; if dcs[cls] != nil { break }; try await Task.sleep(for: .milliseconds(500)) }
            guard let dc = dcs[cls] else { throw Fail("driver configurations \(dcs.keys.sorted())") }
            dc.removeTokenConfiguration(for: inst)
            let tc = dc.addTokenConfiguration(for: inst)
            guard let cert = SecCertificateCreateWithData(nil, More2TLS.leafDER as CFData),
                  let item = TKTokenKeychainCertificate(certificate: cert, objectID: "sdkcov-cert") else { throw Fail("certificate item") }
            item.label = "sdkcov token cert"
            // a signing key next to it (the certificate's public key): a signature through it goes to the extension's
            // token session (which supports no operation)
            guard let key = TKTokenKeychainKey(certificate: cert, objectID: "sdkcov-key") else { throw Fail("key item") }
            key.label = "sdkcov token key"; key.canSign = true; key.isSuitableForLogin = false
            tc.keychainItems = [item, key]
            tc.configurationData = Data("sdkcov".utf8)
            let w = TKTokenWatcher()
            let seen = await more2Wait(20) { w.tokenIDs.contains(tid) }
            func certs() -> (OSStatus, [String]) {
                var out: CFTypeRef?
                let st = SecItemCopyMatching([kSecClass as String: kSecClassCertificate, kSecAttrTokenID as String: tid, kSecReturnAttributes as String: true,
                                              kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &out)
                return (st, ((out as? [[String: Any]]) ?? []).map { "\($0[kSecAttrLabel as String] ?? "-")" })
            }
            var kc = certs()
            for _ in 0..<20 where kc.0 != errSecSuccess { try await Task.sleep(for: .milliseconds(500)); kc = certs() }
            let info = w.tokenInfo(forTokenID: tid)
            var kref: CFTypeRef?
            let kst = SecItemCopyMatching([kSecClass as String: kSecClassKey, kSecAttrTokenID as String: tid, kSecReturnRef as String: true] as CFDictionary, &kref)
            var sign = "no key"
            if kst == errSecSuccess, let k = kref, CFGetTypeID(k) == SecKeyGetTypeID() {
                var e: Unmanaged<CFError>?
                let sig = SecKeyCreateSignature(k as! SecKey, .ecdsaSignatureMessageX962SHA256, Data("sdkcov".utf8) as CFData, &e)
                sign = sig != nil ? "signed" : "error \(p8Err(e?.takeRetainedValue()))"
            }
            dc.removeTokenConfiguration(for: inst)
            let gone = await more2Wait(20) { !w.tokenIDs.contains(tid) }
            let after = certs()
            let d = "configs \(dc.tokenConfigurations.keys.sorted()); watcher \(seen) (driver \(info?.driverName ?? "-")); keychain \(kc.0) \(kc.1); key \(kst), sign: \(sign); removed: watcher gone \(gone), keychain \(after.0) \(after.1); extension \(p3Marks("token-create", since: t0)) sessions \(p3Marks("token-session", since: t0).count)"
            try expect(seen && kc.0 == errSecSuccess && kc.1 == ["sdkcov token cert"], d)
            try expect(gone && after.0 == errSecItemNotFound, d)
            // the key's reference needs the extension's token: Apple's simulator never gets one from it (-26276, the
            // extension not launched; no session)
            try expect(kst == -26276, d)
            return d
        })
        #endif

        // MARK: UIKit: the scene lifecycle when the app goes to the background and comes back: sdkcov opens the companion
        // app sdkcovDoc (ext/DocApp.swift) by URL after marking a lifecycle request; sdkcovDoc opens sdkcov: again at once.
        // The window scene's and the application's notifications in order, the activation states, and UIKit saving the
        // scene's NSUserActivity (needsSave) when it leaves the foreground. Last in the run (Registry.all ends with p22).
        #if os(iOS)
        c.append(check("UIKit", "scene-lifecycle-round-trip", timeout: 120) {
            let t0 = Date()
            let bg = await onMain { UIApplication.shared.beginBackgroundTask(withName: "sdkcov-lifecycle") {} }
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
            guard let scene = await onMain({ UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene }) else {
                throw Fail("no foreground-active window scene")
            }
            let ev = Mutex<[String]>([])
            let nc = NotificationCenter.default
            var obs: [NSObjectProtocol] = []
            let state = { @MainActor in "\(scene.activationState.rawValue)/\(UIApplication.shared.applicationState.rawValue)" }
            for (n, tag) in [(UIScene.willDeactivateNotification, "scene.willDeactivate"), (UIScene.didEnterBackgroundNotification, "scene.didEnterBackground"),
                             (UIScene.willEnterForegroundNotification, "scene.willEnterForeground"), (UIScene.didActivateNotification, "scene.didActivate")] {
                obs.append(nc.addObserver(forName: n, object: scene, queue: .main) { _ in
                    let s = MainActor.assumeIsolated { state() }
                    ev.withLock { $0.append("\(tag)[\(s)]") }
                })
            }
            for (n, tag) in [(UIApplication.willResignActiveNotification, "app.willResignActive"), (UIApplication.didEnterBackgroundNotification, "app.didEnterBackground"),
                             (UIApplication.willEnterForegroundNotification, "app.willEnterForeground"), (UIApplication.didBecomeActiveNotification, "app.didBecomeActive")] {
                obs.append(nc.addObserver(forName: n, object: nil, queue: .main) { _ in ev.withLock { $0.append(tag) } })
            }
            defer { obs.forEach { nc.removeObserver($0) } }
            let ad = P22ActivityDelegate()
            let act = NSUserActivity(activityType: "com.x86sim.test.sdkcov.lifecycle")
            act.title = "sdkcov lifecycle"; act.userInfo = ["step": 1]; act.delegate = ad
            let session = await onMain { () -> String in scene.userActivity = act; act.needsSave = true; return scene.session.persistentIdentifier }
            let token = "\(Int(t0.timeIntervalSince1970 * 1000))"
            p22Mark("lifecycle-request", token)
            let ob = P7Box<Bool>()
            await onMain { UIApplication.shared.open(URL(string: "sdkcovdoc://lifecycle")!) { ob.set($0) } }
            let opened = await ob.wait(20) ?? false
            try expect(opened, "sdkcovdoc: not opened (sdkcovDoc-ios.app installed?)")
            let names = { ev.withLock { $0.map { String($0.prefix { $0 != "[" }) } } }
            let back = await more2Wait(60) { names().contains("scene.didEnterBackground") && names().last == "scene.didActivate" || names().last == "app.didBecomeActive" && names().contains("app.didEnterBackground") }
            try await Task.sleep(for: .milliseconds(500))
            let e = ev.withLock { $0 }, nm = names()
            let same = await onMain { scene.session.persistentIdentifier == session && scene.activationState == .foregroundActive }
            let docMark = p3Marks("docapp-lifecycle", since: t0).last ?? "-"
            let detail = "\(e); saves \(ad.saves.load(ordering: .relaxed)), same session + active \(same), sdkcovDoc \(docMark)"
            try expect(back, "not back in front in 60 s: \(detail)")
            // Apple's order: each scene notification before the application's, the activation states as below; UIKit
            // does not save the scene's activity on the way out (userActivityWillSave never called)
            try expect(e == ["scene.willDeactivate[0/0]", "app.willResignActive", "scene.didEnterBackground[2/2]", "app.didEnterBackground",
                             "scene.willEnterForeground[2/2]", "app.willEnterForeground", "scene.didActivate[0/1]", "app.didBecomeActive"], "sequence: \(detail)")
            try expect(ad.saves.load(ordering: .relaxed) == 0, "activity saved: \(detail)")
            try expect(same, detail)
            return detail
        })
        #endif
        return c
    }
}
