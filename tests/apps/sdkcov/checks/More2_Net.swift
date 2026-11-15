// sdkcov round 2: networking on loopback (no internet needed): TLS with our own identity on both Network.framework
// and URLSession, HTTP semantics URLSession implements (redirects, cookies, gzip, auth challenges, chunked streaming,
// timeouts, cancellation) and Bonjour advertise -> browse -> connect through mDNSResponder.
import Foundation
import Synchronization
import Security
#if canImport(Network)
import Network
#endif

#if canImport(Network)
/// URLSession delegate: trusts the server whose leaf certificate is More2TLS.leafDER (pinning, as apps do), answers
/// HTTP Basic with user/pass, counts redirects
private final class More2SessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let redirects = Atomic<Int>(0), basic = Atomic<Int>(0), pinned = Atomic<Int>(0)
    let tls = Mutex<String>("")
    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = ch.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let chain = (SecTrustCopyCertificateChain(t) as? [SecCertificate]) ?? []
        guard let leaf = chain.first, SecCertificateCopyData(leaf) as Data == More2TLS.leafDER else { return (.cancelAuthenticationChallenge, nil) }
        pinned.add(1, ordering: .relaxed)
        return (.useCredential, URLCredential(trust: t))
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didReceive ch: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { return await urlSession(s, didReceive: ch) }
        if ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
            basic.add(1, ordering: .relaxed)
            return ch.previousFailureCount == 0 ? (.useCredential, URLCredential(user: "sdkcov", password: "x86 sim", persistence: .forSession)) : (.cancelAuthenticationChallenge, nil)
        }
        return (.performDefaultHandling, nil)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? {
        redirects.add(1, ordering: .relaxed); return newRequest
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didFinishCollecting m: URLSessionTaskMetrics) {
        if let t = m.transactionMetrics.last, let v = t.negotiatedTLSProtocolVersion { tls.withLock { $0 = "TLS 0x\(String(v.rawValue, radix: 16)), \(t.networkProtocolName ?? "?")" } }
    }
}
#endif

extension Registry {
    static var more2_net: [Check] {
        guard more2On else { return [] }
        var c: [Check] = []
        #if canImport(Network)
        c.append(check("Network", "tls-loopback-identity-echo", timeout: 40) {
            // server: NWListener with the PKCS#12 identity, echoes; client: TLS with a verify block that pins the leaf
            let (id, _) = try More2TLS.identity()
            let so = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(so.securityProtocolOptions, sec_identity_create(id)!)
            sec_protocol_options_add_tls_application_protocol(so.securityProtocolOptions, "sdkcov/1")
            let l = try NWListener(using: NWParameters(tls: so, tcp: .init()), on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                func loop() { c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, fin, err in
                    if let d, !d.isEmpty { c.send(content: d, completion: .contentProcessed { _ in loop() }) } else if fin || err != nil { c.cancel() } else { loop() }
                } }
                loop()
            }
            let port: UInt16 = try await withCheckedThrowingContinuation { k in
                let once = Mutex(false)
                l.stateUpdateHandler = { s in
                    switch s {
                    case .ready: if !once.withLock({ let o = $0; $0 = true; return o }) { k.resume(returning: l.port!.rawValue) }
                    case .failed(let e): if !once.withLock({ let o = $0; $0 = true; return o }) { k.resume(throwing: e) }
                    default: break
                    }
                }
                l.start(queue: .global())
            }
            defer { l.cancel() }
            let co = NWProtocolTLS.Options()
            let verified = Atomic<Int>(0)
            sec_protocol_options_add_tls_application_protocol(co.securityProtocolOptions, "sdkcov/1")
            sec_protocol_options_set_verify_block(co.securityProtocolOptions, { _, trust, done in
                let t = sec_trust_copy_ref(trust).takeRetainedValue()
                let leaf = (SecTrustCopyCertificateChain(t) as? [SecCertificate])?.first
                let ok = leaf.map { SecCertificateCopyData($0) as Data == More2TLS.leafDER } ?? false
                if ok { verified.add(1, ordering: .relaxed) }
                done(ok)
            }, .global())
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: co, tcp: .init()))
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let once = Mutex(false)
                conn.stateUpdateHandler = { s in
                    switch s {
                    case .ready: if !once.withLock({ let o = $0; $0 = true; return o }) { k.resume() }
                    case .failed(let e), .waiting(let e): if !once.withLock({ let o = $0; $0 = true; return o }) { k.resume(throwing: Fail("client \(e)")) }
                    default: break
                    }
                }
                conn.start(queue: .global())
            }
            defer { conn.cancel() }
            var meta = "?"
            if let m = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                let v = sec_protocol_metadata_get_negotiated_tls_protocol_version(m.securityProtocolMetadata)
                let alpn = sec_protocol_metadata_get_negotiated_protocol(m.securityProtocolMetadata).map { String(cString: $0) } ?? "-"
                meta = "TLS 0x\(String(v.rawValue, radix: 16)), ALPN \(alpn)"
                try expect(v == .TLSv13 && alpn == "sdkcov/1", "negotiated \(meta)")
            }
            // 200 KB through the TLS echo
            let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 11) })
            conn.send(content: payload, completion: .contentProcessed { _ in })
            var back = Data()
            while back.count < payload.count {
                let d: Data = try await more2Stage("echo receive at \(back.count)", 10) { try await withCheckedThrowingContinuation { k in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, e in if let e { k.resume(throwing: e) } else { k.resume(returning: d ?? Data()) } }
                } }
                if d.isEmpty { break }; back.append(d)
            }
            try expect(back == payload && verified.load(ordering: .relaxed) == 1, "echo \(back.count) B, verify block \(verified.load(ordering: .relaxed))")
            return "\(meta), pinned leaf, 200 KB echoed"
        })
        c.append(check("CFNetwork", "urlsession-https-pinned-loopback", timeout: 40) {
            let srv = try More2HTTP(tls: true) { r in
                r.method == "POST" ? More2Resp("200 OK", [("Content-Type", "application/octet-stream")], Data(r.body.reversed())) : .text("secure \(r.path)")
            }
            _ = try await srv.start(); defer { srv.stop() }
            let d = More2SessionDelegate()
            let s = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil); defer { s.invalidateAndCancel() }
            let (body, resp) = try await s.data(from: srv.url("/hello", tls: true))
            try expect((resp as? HTTPURLResponse)?.statusCode == 200 && String(decoding: body, as: UTF8.self) == "secure /hello", "GET \(String(decoding: body, as: UTF8.self))")
            var req = URLRequest(url: srv.url("/up", tls: true)); req.httpMethod = "POST"
            let up = Data((0..<500_000).map { UInt8(truncatingIfNeeded: $0 >> 3) })
            let (echo, _) = try await s.upload(for: req, from: up)
            try expect(echo == Data(up.reversed()), "POST 500 KB echo \(echo.count)")
            // the same over "localhost" (the certificate's DNS name)
            let (b2, _) = try await s.data(from: srv.url("/lh", tls: true, host: "localhost"))
            try expect(String(decoding: b2, as: UTF8.self) == "secure /lh", "localhost \(String(decoding: b2, as: UTF8.self))")
            // a session without the pinning delegate refuses the untrusted certificate
            let plain = URLSession(configuration: .ephemeral); defer { plain.invalidateAndCancel() }
            var refused = ""
            do { _ = try await plain.data(from: srv.url("/x", tls: true)) } catch { refused = "\((error as? URLError)?.code.rawValue ?? 0)" }
            try expect(!refused.isEmpty, "the default trust evaluation accepted our test CA")
            try expect(d.pinned.load(ordering: .relaxed) >= 1, "pinned \(d.pinned.load(ordering: .relaxed))")
            _ = await more2Wait(2) { !d.tls.withLock { $0 }.isEmpty }
            return "\(d.tls.withLock { $0 }), GET + 500 KB POST + localhost, untrusted refused (\(refused))"
        })
        c.append(check("CFNetwork", "urlsession-redirect-cookies-gzip-auth-chunked", timeout: 60) {
            let gz = Data(base64Encoded: "H4sIAAAAAAAC/6uwMCvOzFVIr8osUEjKT6lUqBgVGBUYFRgVIE4AALx8rzxABAAA")!
            let srv = try More2HTTP { r in
                switch r.path {
                case "/start": return More2Resp("302 Found", [("Location", "/setcookie")])
                case "/setcookie": return More2Resp("303 See Other", [("Location", "/home"), ("Set-Cookie", "sid=x86sim42; Path=/; HttpOnly"), ("Set-Cookie", "pref=dark; Path=/; Max-Age=3600")])
                case "/home": return .text("cookie=\(r.headers["cookie"] ?? "-")")
                case "/gzip": return More2Resp("200 OK", [("Content-Type", "text/plain"), ("Content-Encoding", "gzip")], gz)
                case "/auth":
                    let want = "Basic " + Data("sdkcov:x86 sim".utf8).base64EncodedString()
                    return r.headers["authorization"] == want ? .text("welcome") : More2Resp("401 Unauthorized", [("WWW-Authenticate", "Basic realm=\"sdkcov\"")], Data("no".utf8))
                case "/lines":
                    var x = More2Resp("200 OK", [("Content-Type", "text/plain")]); x.chunks = (0..<8).map { Data("line \($0) ".utf8) + Data(repeating: 0x2e, count: 40_000) + Data("\n".utf8) }; x.gap = 0.15; return x
                case "/slow":
                    Thread.sleep(forTimeInterval: 3); return .text("late")
                default: return More2Resp("404 Not Found")
                }
            }
            _ = try await srv.start(); defer { srv.stop() }
            let d = More2SessionDelegate()
            let cfg = URLSessionConfiguration.ephemeral
            let jar = cfg.httpCookieStorage!
            let s = URLSession(configuration: cfg, delegate: d, delegateQueue: nil); defer { s.invalidateAndCancel() }
            // two redirects (302 then 303); the cookies set on the way are sent to the final page
            let (b1, r1) = try await s.data(from: srv.url("/start"))
            let home = String(decoding: b1, as: UTF8.self)
            try expect((r1 as? HTTPURLResponse)?.url?.path == "/home" && d.redirects.load(ordering: .relaxed) == 2, "redirects \(d.redirects.load(ordering: .relaxed)) to \(String(describing: r1.url))")
            try expect(home.contains("sid=x86sim42") && home.contains("pref=dark"), "cookies sent: \(home)")
            let stored = jar.cookies(for: srv.url("/"))?.map { "\($0.name)=\($0.value)\($0.isHTTPOnly ? " httponly" : "")" }.sorted() ?? []
            try expect(stored == ["pref=dark", "sid=x86sim42 httponly"], "cookie jar \(stored)")
            // gzip decoded transparently
            let (b2, _) = try await s.data(from: srv.url("/gzip"))
            try expect(b2 == Data(String(repeating: "x86sim gzip body ", count: 64).utf8), "gzip body \(b2.count) B: \(String(decoding: b2.prefix(20), as: UTF8.self))")
            // HTTP Basic through the task delegate's challenge
            let (b3, r3) = try await s.data(from: srv.url("/auth"))
            try expect((r3 as? HTTPURLResponse)?.statusCode == 200 && String(decoding: b3, as: UTF8.self) == "welcome" && d.basic.load(ordering: .relaxed) == 1, "basic auth \((r3 as? HTTPURLResponse)?.statusCode ?? 0) challenges \(d.basic.load(ordering: .relaxed))")
            // chunked response read line by line as it arrives
            let (bytes, _) = try await s.bytes(from: srv.url("/lines"))
            var lines: [String] = [], times: [Date] = []
            for try await line in bytes.lines { lines.append(line); times.append(Date()) }
            try expect(lines.count == 8 && lines.enumerated().allSatisfy { $0.element.hasPrefix("line \($0.offset) ") && $0.element.count == 40_007 + ($0.offset >= 10 ? 1 : 0) }, "lines \(lines.map { $0.prefix(8) }) \(lines.map(\.count))")
            let spread = times.last!.timeIntervalSince(times.first!)
            try expect(spread > 0.3, "lines arrived together (\(spread) s): not streamed")
            // a 1 s request timeout against a 3 s answer; a cancelled task
            var req = URLRequest(url: srv.url("/slow")); req.timeoutInterval = 1
            let t0 = Date(); var code = 0
            do { _ = try await s.data(for: req) } catch { code = (error as? URLError)?.code.rawValue ?? -1 }
            let el = Date().timeIntervalSince(t0)
            try expect(code == URLError.timedOut.rawValue && el < 2.8, "timeout: code \(code) after \(el) s")
            let task = s.dataTask(with: srv.url("/slow")); let cancelled = Atomic<Int>(0)
            let cs = URLSession(configuration: .ephemeral); defer { cs.invalidateAndCancel() }
            let ct = cs.dataTask(with: srv.url("/slow")) { _, _, e in cancelled.store((e as? URLError)?.code.rawValue ?? -1, ordering: .relaxed) }
            ct.resume(); try await Task.sleep(for: .milliseconds(200)); ct.cancel(); _ = task
            try expect(await more2Wait(3) { cancelled.load(ordering: .relaxed) != 0 } && cancelled.load(ordering: .relaxed) == URLError.cancelled.rawValue, "cancel \(cancelled.load(ordering: .relaxed))")
            return "2 redirects, cookies \(stored), gzip, Basic auth, 8 streamed lines over \(String(format: "%.2f", spread)) s, timeout \(String(format: "%.2f", el)) s, cancel"
        })
        c.append(check("Network", "bonjour-advertise-browse-connect", timeout: 45) {
            // advertise _sdkcov._tcp (declared in NSBonjourServices) with a TXT record, find it with NWBrowser,
            // connect to the browse result's endpoint (mDNSResponder resolves it) and exchange a line
            let name = "sdkcov-\(getpid())"
            let l = try NWListener(using: .tcp)
            var txt = NWTXTRecord(); txt["ver"] = "2"; txt["sim"] = "x86"
            l.service = NWListener.Service(name: name, type: "_sdkcov._tcp", domain: "local.", txtRecord: txt)
            let regs = Mutex<[String]>([])
            l.serviceRegistrationUpdateHandler = { ch in if case .add(let ep) = ch { regs.withLock { $0.append("\(ep)") } } }
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                c.receive(minimumIncompleteLength: 1, maximumLength: 100) { d, _, _, _ in
                    c.send(content: Data("hello ".utf8) + (d ?? Data()), completion: .contentProcessed { _ in })
                }
            }
            l.start(queue: .global()); defer { l.cancel() }
            let found = Mutex<NWBrowser.Result?>(nil), bstate = Mutex("")
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_sdkcov._tcp", domain: "local."), using: .tcp)
            b.stateUpdateHandler = { s in bstate.withLock { $0 = "\(s)" } }
            b.browseResultsChangedHandler = { results, _ in
                if let r = results.first(where: { if case .service(let n, _, _, _) = $0.endpoint { return n == name }; return false }) { found.withLock { $0 = r } }
            }
            b.start(queue: .global()); defer { b.cancel() }
            guard await more2Wait(20, { found.withLock { $0 } != nil }) else {
                throw Fail("own service not found in 20 s (registered: \(regs.withLock { $0 }), browser \(bstate.withLock { $0 }))")
            }
            let r = found.withLock { $0 }!
            var txtOK = "no TXT"
            if case .bonjour(let t) = r.metadata { txtOK = "TXT ver=\(t["ver"] ?? "-") sim=\(t["sim"] ?? "-")"; try expect(t["ver"] == "2" && t["sim"] == "x86", txtOK) }
            let conn = NWConnection(to: r.endpoint, using: .tcp)
            let reply: String = try await more2Stage("connect to the browsed endpoint", 15) {
                try await withCheckedThrowingContinuation { k in
                    let once = Mutex(false)
                    func finish(_ v: Result<String, Error>) { if !once.withLock({ let o = $0; $0 = true; return o }) { k.resume(with: v) } }
                    conn.stateUpdateHandler = { s in
                        switch s {
                        case .ready:
                            conn.send(content: Data("x86sim".utf8), completion: .contentProcessed { _ in })
                            conn.receive(minimumIncompleteLength: 12, maximumLength: 100) { d, _, _, e in
                                if let e { finish(.failure(e)) } else { finish(.success(String(decoding: d ?? Data(), as: UTF8.self))) }
                            }
                        case .failed(let e): finish(.failure(e))
                        default: break
                        }
                    }
                    conn.start(queue: .global())
                }
            }
            conn.cancel()
            try expect(reply == "hello x86sim", "reply \(reply)")
            return "registered \(regs.withLock { $0.first ?? "?" }), found, \(txtOK), connected via endpoint"
        })
        #endif
        return c
    }
}
