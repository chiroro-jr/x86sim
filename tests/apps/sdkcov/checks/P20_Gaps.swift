// SDK coverage, round 24: checks for [a] gaps of covered frameworks (COVERAGE-GAPS.md). Each asserts what Apple's
// simulator answers (ref-mac.sh).
import Foundation
import Synchronization
import Security
import CoreGraphics
import ImageIO
import CoreText
import UniformTypeIdentifiers
#if canImport(Network)
import Network
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(GameplayKit) && !os(watchOS)
import GameplayKit
import SpriteKit
#endif
#if canImport(MediaPlayer) && (os(iOS) || os(visionOS))
import MediaPlayer
#endif
#if canImport(WebKit) && (os(iOS) || os(visionOS))
import WebKit
import UIKit
#endif

#if canImport(Network)
/// a minimal HTTP/2 server over TLS (ALPN h2) on loopback: SETTINGS / PING answered, every request stream gets
/// ":status 200" (HPACK static index 8) and a body naming the stream; counts streams and checks the client preface
final class P20H2Server: @unchecked Sendable {
    let listener: NWListener
    let streams = Mutex<[UInt32]>([]), preface = Mutex<Bool>(false), alpn = Mutex<String>("")
    init() throws {
        let (id, _) = try More2TLS.identity()
        let so = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(so.securityProtocolOptions, sec_identity_create(id)!)
        sec_protocol_options_add_tls_application_protocol(so.securityProtocolOptions, "h2")
        listener = try NWListener(using: NWParameters(tls: so, tcp: .init()), on: .any)
        listener.newConnectionHandler = { [unowned self] c in self.serve(c) }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { k in
            let once = Mutex(false)
            listener.stateUpdateHandler = { [listener] s in
                switch s {
                case .ready: if !once.withLock({ let o = $0; $0 = true; return o }) { k.resume(returning: listener.port!.rawValue) }
                case .failed(let e): if !once.withLock({ let o = $0; $0 = true; return o }) { k.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.cancel() }
    static func frame(_ type: UInt8, _ flags: UInt8, _ stream: UInt32, _ payload: [UInt8]) -> Data {
        let n = payload.count
        return Data([UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff), type, flags,
                     UInt8(stream >> 24 & 0x7f), UInt8(stream >> 16 & 0xff), UInt8(stream >> 8 & 0xff), UInt8(stream & 0xff)] + payload)
    }
    private func serve(_ c: NWConnection) {
        let q = DispatchQueue(label: "p20.h2")
        var buf = Data(), gotPreface = false
        c.stateUpdateHandler = { [unowned self] s in
            if case .ready = s {
                if let m = c.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    let a = sec_protocol_metadata_get_negotiated_protocol(m.securityProtocolMetadata).map { String(cString: $0) } ?? "-"
                    self.alpn.withLock { $0 = a }
                }
                c.send(content: Self.frame(4, 0, 0, []), completion: .contentProcessed { _ in })   // server SETTINGS
            }
        }
        c.start(queue: q)
        func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] d, _, fin, err in
                if let d { buf.append(d) }
                if !gotPreface, buf.count >= 24 {
                    gotPreface = true
                    let ok = buf.prefix(24) == Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
                    self.preface.withLock { $0 = ok }
                    buf.removeFirst(24)
                    if !ok { c.cancel(); return }
                }
                var out = Data()
                while gotPreface, buf.count >= 9 {
                    let b = [UInt8](buf.prefix(9))
                    let len = Int(b[0]) << 16 | Int(b[1]) << 8 | Int(b[2])
                    guard buf.count >= 9 + len else { break }
                    let type = b[3], flags = b[4]
                    let sid = UInt32(b[5] & 0x7f) << 24 | UInt32(b[6]) << 16 | UInt32(b[7]) << 8 | UInt32(b[8])
                    let payload = [UInt8](buf.subdata(in: buf.startIndex + 9 ..< buf.startIndex + 9 + len))
                    buf.removeFirst(9 + len)
                    switch type {
                    case 4 where flags & 1 == 0: out += Self.frame(4, 1, 0, [])                  // SETTINGS -> ACK
                    case 6 where flags & 1 == 0: out += Self.frame(6, 1, 0, payload)             // PING -> ACK
                    case 1, 0:                                                                   // HEADERS / DATA
                        if flags & 1 != 0 {                                                      // END_STREAM: answer
                            self.streams.withLock { $0.append(sid) }
                            let body = [UInt8]("h2 stream \(sid)".utf8)
                            out += Self.frame(1, 4, sid, [0x88])                                 // :status 200, END_HEADERS
                            out += Self.frame(0, 1, sid, body)                                   // DATA, END_STREAM
                        }
                    case 7: c.cancel(); return                                                   // GOAWAY
                    default: break
                    }
                }
                if !out.isEmpty { c.send(content: out, completion: .contentProcessed { _ in }) }
                if fin || err != nil { c.cancel() } else { loop() }
            }
        }
        loop()
    }
}

/// trusts the server whose leaf is More2TLS.leafDER, records each transaction's protocol
final class P20PinDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let protocols = Mutex<[String]>([])
    func urlSession(_ s: URLSession, task: URLSessionTask, didReceive ch: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = ch.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(t) as? [SecCertificate])?.first, SecCertificateCopyData(leaf) as Data == More2TLS.leafDER
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: t))
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didFinishCollecting m: URLSessionTaskMetrics) {
        protocols.withLock { $0.append(m.transactionMetrics.map { $0.networkProtocolName ?? "?" }.joined(separator: "+")) }
    }
}
#endif

extension Registry {
    static var p20: [Check] {
        var c: [Check] = []

        // MARK: CFNetwork: HTTP/2 negotiated over TLS (ALPN h2) with a loopback server, two requests on one connection
        #if canImport(Network)
        c.append(check("CFNetwork", "urlsession-http2-loopback-tls", timeout: 60) {
            let srv = try P20H2Server()
            let port = try await srv.start(); defer { srv.stop() }
            let d = P20PinDelegate()
            let s = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil); defer { s.invalidateAndCancel() }
            var bodies: [String] = []
            for p in ["/a", "/b"] {
                let (b, r) = try await s.data(from: URL(string: "https://localhost:\(port)\(p)")!)
                try expect((r as? HTTPURLResponse)?.statusCode == 200, "status \(String(describing: (r as? HTTPURLResponse)?.statusCode))")
                bodies.append(String(decoding: b, as: UTF8.self))
            }
            _ = await more2Wait(3) { d.protocols.withLock { $0.count } >= 2 }
            let protos = d.protocols.withLock { $0 }, streams = srv.streams.withLock { $0 }
            try expect(srv.preface.withLock { $0 } && srv.alpn.withLock { $0 } == "h2", "preface \(srv.preface.withLock { $0 }), ALPN \(srv.alpn.withLock { $0 })")
            try expect(protos == ["h2", "h2"] && streams == [1, 3] && bodies == ["h2 stream 1", "h2 stream 3"],
                       "protocols \(protos), streams \(streams), bodies \(bodies)")
            return "ALPN h2, client preface, streams \(streams) on one connection, metrics \(protos)"
        })
        #endif

        // MARK: GameplayKit: a GKScene loaded from an .sks in the bundle (res/sdkcovGK.sks, Xcode's scene editor format)
        #if canImport(GameplayKit) && !os(watchOS)
        c.append(check("GameplayKit", "gkscene-from-sks", timeout: 30) {
            try await onMain {
                guard Bundle.main.path(forResource: "sdkcovGK", ofType: "sks") != nil else { throw Fail("sdkcovGK.sks not in the bundle") }
                guard let g = GKScene(fileNamed: "sdkcovGK") else { throw Fail("GKScene(fileNamed:) nil") }
                guard let sc = g.rootNode as? SKScene else { throw Fail("root node \(String(describing: g.rootNode))") }
                let kids = sc.children.compactMap(\.name).sorted()
                let e = g.entities.first
                let comps = e?.components.map { String(describing: type(of: $0)) }.sorted() ?? []
                let node = e?.component(ofType: GKSKNodeComponent.self)?.node
                try expect(sc.name == "sdkcovScene" && sc.size == CGSize(width: 320, height: 240) && kids == ["hero", "spawn"],
                           "scene \(String(describing: sc.name)) \(sc.size) children \(kids)")
                try expect(g.entities.count == 1 && comps == ["GKAgent2D", "GKSKNodeComponent"], "entities \(g.entities.count) components \(comps)")
                let hero = sc.childNode(withName: "hero")
                // the entity's node component as decoded (Apple's macOS: the scene itself); the agent steps
                let agent = e?.component(ofType: GKAgent2D.self)
                agent?.maxSpeed = 10; agent?.update(deltaTime: 0.1)
                return "scene \(sc.name ?? "-") \(Int(sc.size.width))x\(Int(sc.size.height)), children \(kids), hero at \(hero.map { "\($0.position)" } ?? "-"), 1 entity \(comps), node component -> \(node?.name ?? "nil")"
            }
        })
        #endif

        // MARK: CoreImage: HEIF written and read back, RAW (DNG through ImageIO when it writes one) through CIRAWFilter,
        // CIDetector text features on drawn text
        #if canImport(CoreImage) && !os(watchOS)
        c.append(check("CoreImage", "heif-raw-text-detector", timeout: 90) {
            let ctx = CIContext()
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            let src = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 0),
                                                                     "inputColor0": CIColor(red: 1, green: 0, blue: 0), "inputColor1": CIColor(red: 0, green: 0, blue: 1)])!
                .outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
            var out: [String] = []
            // HEIF
            var heif = "-"
            if let d = ctx.heifRepresentation(of: src, format: .RGBA8, colorSpace: srgb, options: [:]) {
                guard let back = CIImage(data: d) else { throw Fail("CIImage(data:) of \(d.count) B HEIF nil") }
                let cg = ctx.createCGImage(back, from: back.extent)!
                let bm = bitmap(cg.width, cg.height); bm.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                let l = pixel(bm, 1, 24), r = pixel(bm, 62, 24)
                try expect(back.extent.size == CGSize(width: 64, height: 48) && l[0] > 200 && l[2] < 60 && r[2] > 200 && r[0] < 60,
                           "HEIF back \(back.extent.size) left \(l) right \(r)")
                let type = CGImageSourceCreateWithData(d as CFData, nil).flatMap { CGImageSourceGetType($0) as String? } ?? "?"
                heif = "\(type) \(Int(back.extent.width))x\(Int(back.extent.height))"
            } else { heif = "no HEIF encoder" }
            out.append("HEIF \(heif)")
            // RAW: ImageIO's writable types; a DNG when it writes one
            let types = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
            let models = CIRAWFilter.supportedCameraModels.count
            var raw = "DNG not writable"
            if types.contains("com.adobe.raw-image") {
                let md = NSMutableData()
                let cg = ctx.createCGImage(src, from: src.extent)!
                if let dst = CGImageDestinationCreateWithData(md, "com.adobe.raw-image" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dst, cg, nil)
                    let ok = CGImageDestinationFinalize(dst)
                    let f = CIRAWFilter(imageData: md as Data, identifierHint: "com.adobe.raw-image")
                    raw = "DNG written \(ok) \(md.length) B, CIRAWFilter \(f.map { "native \(Int($0.nativeSize.width))x\(Int($0.nativeSize.height)) out \($0.outputImage.map { "\(Int($0.extent.width))x\(Int($0.extent.height))" } ?? "nil")" } ?? "nil")"
                }
            }
            // not RAW data: Apple's simulators still hand a filter (its output image is the answer)
            let junk = CIRAWFilter(imageData: Data("not raw".utf8), identifierHint: nil)
            let junkOut = junk.map { $0.outputImage == nil ? "no output" : "output" } ?? "no filter"
            out.append("\(raw); junk RAW: \(junkOut); \(models) camera models")
            // CIDetector text: "SDKCOV 24" drawn black on white
            let w = 360, h = 120
            let tc = bitmap(w, h); tc.setFillColor(CGColor(gray: 1, alpha: 1)); tc.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SDKCOV 24", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                                                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
            tc.textPosition = CGPoint(x: 20, y: 40); CTLineDraw(line, tc)
            let det = CIDetector(ofType: CIDetectorTypeText, context: ctx, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let feats = det?.features(in: CIImage(cgImage: tc.makeImage()!), options: [CIDetectorReturnSubFeatures: true]) ?? []
            let tf = feats.compactMap { $0 as? CITextFeature }
            out.append("text detector \(det != nil): \(tf.count) features, sub \(tf.first?.subFeatures?.count ?? -1), bounds \(tf.first.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "-")")
            #if os(tvOS)
            let modelsOK = models == 0   // Apple's tvOS simulator: no RAW camera models
            #else
            let modelsOK = models > 0
            #endif
            try expect(modelsOK && tf.count >= 1, out.joined(separator: "; "))
            return out.joined(separator: "; ")
        })
        #endif

        // MARK: MediaPlayer: the media library queried with access granted (run.sh / ref-mac.sh grant kTCCServiceMediaLibrary)
        #if canImport(MediaPlayer) && (os(iOS) || os(visionOS))
        c.append(check("MediaPlayer", "library-authorized-queries", timeout: 40) {
            let auth = MPMediaLibrary.authorizationStatus()
            try expect(auth == .authorized, "authorization \(auth.rawValue) (run.sh grants media library access)")
            let songs = MPMediaQuery.songs(), albums = MPMediaQuery.albums(), artists = MPMediaQuery.artists(), pl = MPMediaQuery.playlists()
            let counts = [songs.items?.count ?? -1, albums.collections?.count ?? -1, artists.collections?.count ?? -1, pl.collections?.count ?? -1]
            let pred = MPMediaPropertyPredicate(value: MPMediaType.music.rawValue, forProperty: MPMediaItemPropertyMediaType)
            let q = MPMediaQuery(filterPredicates: [pred]); q.groupingType = .genre
            let sections = q.collectionSections?.count ?? -1
            let lib = MPMediaLibrary.default()
            let mod = lib.lastModifiedDate
            lib.beginGeneratingLibraryChangeNotifications(); lib.endGeneratingLibraryChangeNotifications()
            // playlist creation (needs the media library service)
            let r = P8Box<String>()
            lib.getPlaylist(with: UUID(uuidString: "5DC0F00D-0000-4000-8000-00000000C0DE")!, creationMetadata: MPMediaPlaylistCreationMetadata(name: "sdkcov")) { p, e in
                r.set(e.map { p8Err($0) } ?? "playlist \(p?.name ?? "nil") items \(p?.count ?? -1)")
            }
            let pls = await r.wait(20) ?? "no answer in 20 s"
            return "authorized; songs/albums/artists/playlists \(counts), genre sections \(sections), modified \(mod.timeIntervalSince1970 > 0); getPlaylist: \(pls)"
        })
        #endif

        // MARK: WebKit: a service worker registered by a loopback page (http://localhost is a secure context), its
        // activation and a fetch it answers
        #if canImport(WebKit) && (os(iOS) || os(visionOS))
        c.append(check("WebKit", "service-worker-register-fetch", timeout: 60) {
            let srv = try More2HTTP { r in
                switch r.path {
                case "/": return .text("<html><body>sw</body></html>", type: "text/html")
                case "/sw.js": return .text("""
                    self.addEventListener('install', e => self.skipWaiting());
                    self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
                    self.addEventListener('fetch', e => { if (new URL(e.request.url).pathname === '/from-sw') e.respondWith(new Response('answered by the service worker')); });
                    """, type: "text/javascript")
                default: return More2Resp("404 Not Found")
                }
            }
            let port = try await srv.start(); defer { srv.stop() }
            let (wv, done) = try await onMain { () -> (WKWebView, () -> Void) in
                let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), configuration: WKWebViewConfiguration())
                let vc = UIViewController(); vc.view.addSubview(wv)
                let (_, done) = try p6Show(vc)
                wv.load(URLRequest(url: URL(string: "http://localhost:\(port)/")!))
                return (wv, done)
            }
            defer { Task { @MainActor in done() } }
            _ = await p6Wait(15) { !wv.isLoading && wv.url != nil }
            let js = """
            if (!('serviceWorker' in navigator)) return 'no navigator.serviceWorker (secure ' + window.isSecureContext + ')';
            try {
              const reg = await navigator.serviceWorker.register('/sw.js');
              await navigator.serviceWorker.ready;
              if (!navigator.serviceWorker.controller) await new Promise(ok => { navigator.serviceWorker.oncontrollerchange = ok; setTimeout(ok, 5000); });
              const t = await (await fetch('/from-sw')).text();
              return 'scope ' + new URL(reg.scope).pathname + ', active ' + (reg.active ? reg.active.state : 'none') + ', controlled ' + !!navigator.serviceWorker.controller + ', fetch: ' + t;
            } catch (e) { return 'error ' + e.name + ': ' + e.message; }
            """
            let v = try await p6A { try await wv.callAsyncJavaScript(js, contentWorld: .page) }
            let s = v as? String ?? "\(String(describing: v))"
            // Apple's iOS / visionOS 27.2 simulators: a WKWebView outside app-bound domains (WKAppBoundDomains) has no
            // service worker container at all, even in a secure context
            try expect(s == "no navigator.serviceWorker (secure true)", "service worker: \(s) (Apple's simulator: no navigator.serviceWorker (secure true))")
            return s
        })
        #endif

        return c
    }
}
