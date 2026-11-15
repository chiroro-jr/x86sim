// sdkcov round 2 (More2_*.swift): shared fixtures. A TLS identity (P-256 leaf "localhost" / 127.0.0.1 signed by a test CA,
// both valid to 2126; PKCS#12 password "sdkcov", 3DES/SHA1 so every SecPKCS12Import accepts it) and a small loopback
// HTTP/1.1 server on NWListener (plain or TLS) whose answers come from a handler closure.
// The More2 groups run on the platforms listed in more2Platforms (widened as each platform is verified against Apple).
import Foundation
import Synchronization
#if canImport(Network)
import Network
#endif
import Security

/// the More2 groups run on every platform (iOS/iPadOS, tvOS, watchOS, visionOS: each verified against Apple's simulator);
/// checks whose APIs a platform lacks are compiled out per check
let more2On = true

enum More2TLS {
    static let p12 = Data(base64Encoded: "MIIFmgIBAzCCBVgGCSqGSIb3DQEHAaCCBUkEggVFMIIFQTCCBDcGCSqGSIb3DQEHBqCCBCgwggQkAgEAMIIEHQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQMwDgQIg8A1DNmUL7ECAggAgIID8Hf0c90/AICukfqEGjwK6I26hP4POPzsrwanzIcGItXTl/1E6FXRLo1cFCaIZ7L7KYYOHDp47dotYBSvb8SipOzN3K1eOoLHCxLreeG9/P6wgQRF+8iGRteqvQz/+7FIiUb45dpJgtY5+wR/BxTSRvTkXZzA7FfTcV2mRNfwTM9v4zr2vrxJCVjwbCxqVldrxKRCrVElB6Sho+O/5mQAmHaLcCiuAeusj7Y3EGyfJQwN6dOPQtWnwJ2sznYQFCMzOORhbAYB5WCecb4VqxVjAl/rEcDPHUqJThHS0XK6l5HFHIHtX9kj6vJEGy0KYuDiq7IqXfj01Vb4Kiv+IWM0yWnMdQNiJ3rtCPB7T/MyrPkWU/5Lok72vrTZQaSLhzzVQWSkkExakr4GhDGLsZ5Wo3PnqUnb7wyQpeJx8QLQQAS2tGL3A9etijbcfzaDgAGM4ghX8GLWyXjD8s7QnC636pDOhnQWSuFYWUuYZmJItlSg7IMqyH7VVm4+8odI77XRz+yFS0rfquffSQaT15VUOnxuj4+OwtDQDZuylHo3h7SGCOMaxzvxC4u/LitarqLTkG8W/l5VBN8F3iKSBvIOwBmd99H7c8EbRPt5TrlI6tekCPgmniwVwYTtCwOuSQE3O9Wn47KS4Q53FrVqhX5IeTqBeN6Sth52VQpcw1Vr0OTdqhv6oepqx2fo4tgSfdBTDuzCCbTNB/ifaqJLOoVKb5vDTOGhz+QAkEPLaA5KTx4H1Er9+PU6OkWrDf2i1d8jZxCqizW8QCB9CMf+qSnvK7kId7s1vZeYYXhKh5lfK/zk+Px5k+MHUrXb8GoW7IKgXiuD+jpMrLusKjXoH64dXvssfBRg5ywjaaP0GyAu1W/Gv9XvGSJnV0FN9dOrvTSYUZoGkcYUp+1oP28MENTtrovAJCeZx/0+1D1itEnMK3lSihbYPLOO4xCmYSQIDRqCbyqtBa+UBfiuSCh9Zug9hjaCYDaGLUOyaLUbVpYZEVt+5LrLhZ9x2l4VH9AfHqowoA9ArjB8rDQZlhwkOvHjDVwOj/DiN+VWv1S9p7dvG6Tb7LnLYpqCt7BII9AHJ7yY/M/hxScXEpmhiZ88/rADipqeWhte1pJx5AtoWjciehnkKxjPZo5jeSUjswL9gwRNotFMyLTQV4obdCwXrWS9Fi1hSwKT+fbNjz78hxa1G6jHUGUEhJb9jTn+CzHYVbrMt2rn9HsURKx9f3n3sbmNs+r28MqNcdYfVNQzV/up6Q9NSJxYOpeGshZOIJ528aO3LrY0tQEx7eaTaNP2tTl9DwXIDm4eiyeFVlrzqrRGLHh9VwxLYcHMaq+nSVfOAbp6YzCCAQIGCSqGSIb3DQEHAaCB9ASB8TCB7jCB6wYLKoZIhvcNAQwKAQKggbQwgbEwHAYKKoZIhvcNAQwBAzAOBAhT4MQUklYvMQICCAAEgZB6nSsW0C5zRUqIne2QiOuVU5smHAv+g+ghnpXKO1Vmw0688eXxFB4Nm45HWSsXUMMxa1TEr0qVLrkrZhRJpa3HGTEipDCdX0f1HIIvSbJBXe1JcmUm81E6gnoIEk3bkJpXCo8v6Odn0yjN8p72sPLkN+gj685QTNNAD9tgH+8Kc/GqrYFsZoqfTSZYv26OTpwxJTAjBgkqhkiG9w0BCRUxFgQUjOt4vHjAnqXcR1hAS9DZXaRLp0YwOTAhMAkGBSsOAwIaBQAEFCR1zXiCgcE0UNMbO8jaO/t7/ztwBBBtY5CPKQT+nDZzJ55RAoXNAgIIAA==")!
    static let caDER = Data(base64Encoded: "MIIBnDCCAUOgAwIBAgIUeRH63FfXI/ukc91UjzgjIZAN20IwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQeDg2c2ltIHNka2NvdiBDQTAgFw0yNjExMTUxNTQxMTRaGA8yMTI2MTAyMjE1NDExNFowGzEZMBcGA1UEAwwQeDg2c2ltIHNka2NvdiBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABK7c85LrL5DswGd6OWhGtqj6Am+j6og0cFZ7DHUiCemIjRWUKh8ljS8TJPcBhn4D/LUWdIDlxYLg/k5eGFB6XamjYzBhMB0GA1UdDgQWBBSBeNtxMb2FTEdidBIQjKCS7w6jtjAfBgNVHSMEGDAWgBSBeNtxMb2FTEdidBIQjKCS7w6jtjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAgNHADBEAiAfNr1Yw7sPhxqkXRChXP1MgGkF1nsbbzhuefFl/sWZvQIgRrD8/e2+b2oQD4K34kgL9hxzyo6u3+v9u1k6KZh6v9o=")!
    static let leafDER = Data(base64Encoded: "MIIBxjCCAWygAwIBAgIUTMtffiL4LY5VYvKSwWPXg+9LQjcwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQeDg2c2ltIHNka2NvdiBDQTAgFw0yNjExMTUxNTQxMTRaGA8yMTI2MTAyMjE1NDExNFowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE2OhsQWp5IGy4UHALSEMGDd1alzWvkeVdPL2oxhRtjdClHRCkdQkGLIuwYuRIkAxC39I/NBM2ywEbM4p2oeJ6QaOBkjCBjzAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwHQYDVR0OBBYEFIrqZITTE9CAI5ii0Up5Eaqs/i7aMB8GA1UdIwQYMBaAFIF423ExvYVMR2J0EhCMoJLvDqO2MAoGCCqGSM49BAMCA0gAMEUCIQC7mnYgBRi0/nsNIv6Xs39H6uujWLvOBeUwMh2Qv8/04QIgMvqOZh7iQj0XA81iwJ97YgWHRtIysvmrZCvY/gcEA2I=")!
    /// the identity and its chain from the PKCS#12
    static func identity() throws -> (SecIdentity, [SecCertificate]) {
        var items: CFArray?
        let st = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase as String: "sdkcov"] as CFDictionary, &items)
        guard st == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first,
              let idAny = first[kSecImportItemIdentity as String] else { throw Fail("SecPKCS12Import \(st)") }
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return (idAny as! SecIdentity, chain)
    }
}

/// one parsed request of More2HTTP
struct More2Req { let method: String, path: String, headers: [String: String], body: Data }
/// an answer: status line text, extra headers, body; `chunks` (when set) is sent with Transfer-Encoding: chunked, one
/// chunk per element, `gap` seconds apart
struct More2Resp {
    var status = "200 OK", headers: [(String, String)] = [], body = Data()
    var chunks: [Data]? = nil, gap = 0.0
    init(_ status: String = "200 OK", _ headers: [(String, String)] = [], _ body: Data = Data()) { self.status = status; self.headers = headers; self.body = body }
    static func text(_ s: String, type: String = "text/plain; charset=utf-8") -> More2Resp { More2Resp("200 OK", [("Content-Type", type)], Data(s.utf8)) }
}

#if canImport(Network)
/// a loopback HTTP/1.1 server (keep-alive) on NWListener, TLS with More2TLS's identity when `tls`
final class More2HTTP: @unchecked Sendable {
    let listener: NWListener
    let handler: @Sendable (More2Req) -> More2Resp
    let requests = Mutex<[String]>([])
    var port: UInt16 = 0
    init(tls: Bool = false, _ handler: @escaping @Sendable (More2Req) -> More2Resp) throws {
        self.handler = handler
        if tls {
            let o = NWProtocolTLS.Options()
            let (id, _) = try More2TLS.identity()
            guard let sid = sec_identity_create(id) else { throw Fail("sec_identity_create") }
            sec_protocol_options_set_local_identity(o.securityProtocolOptions, sid)
            listener = try NWListener(using: NWParameters(tls: o, tcp: .init()), on: .any)
        } else {
            listener = try NWListener(using: .tcp, on: .any)
        }
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in c.start(queue: .global()); self?.read(c, Data()) }
        port = try await withCheckedThrowingContinuation { cont in
            let once = Mutex(false)
            listener.stateUpdateHandler = { [listener] s in
                switch s {
                case .ready: if !once.withLock({ let o = $0; $0 = true; return o }) { cont.resume(returning: listener.port!.rawValue) }
                case .failed(let e): if !once.withLock({ let o = $0; $0 = true; return o }) { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return port
    }
    func url(_ path: String, tls: Bool = false, host: String = "127.0.0.1") -> URL { URL(string: "\(tls ? "https" : "http")://\(host):\(port)\(path)")! }
    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, fin, err in
            guard let self else { return }
            var b = buf; if let d { b.append(d) }
            if let r = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<r.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let first = lines.removeFirst().split(separator: " ").map(String.init)
                var h: [String: String] = [:]
                for l in lines { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                let len = Int(h["content-length"] ?? "0") ?? 0
                let body = b[r.upperBound...]
                if body.count >= len {
                    let req = More2Req(method: first.first ?? "", path: first.count > 1 ? first[1] : "/", headers: h, body: Data(body.prefix(len)))
                    self.requests.withLock { $0.append("\(req.method) \(req.path)") }
                    self.answer(c, self.handler(req), rest: Data(body.dropFirst(len)))
                    return
                }
            }
            if err != nil || fin { c.cancel(); return }
            self.read(c, b)
        }
    }
    private func answer(_ c: NWConnection, _ r: More2Resp, rest: Data) {
        var head = "HTTP/1.1 \(r.status)\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        if r.chunks == nil { head += "Content-Length: \(r.body.count)\r\n" } else { head += "Transfer-Encoding: chunked\r\n" }
        head += "Connection: keep-alive\r\n\r\n"
        guard let chunks = r.chunks else {
            c.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { [weak self] _ in self?.read(c, rest) })
            return
        }
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let q = DispatchQueue.global()
        for (i, ch) in (chunks + [Data()]).enumerated() {
            q.asyncAfter(deadline: .now() + r.gap * Double(i)) { [weak self] in
                let piece = Data(String(ch.count, radix: 16).utf8) + Data("\r\n".utf8) + ch + Data("\r\n".utf8)
                c.send(content: piece, completion: .contentProcessed { _ in if ch.isEmpty { self?.read(c, rest) } })
            }
        }
    }
    func stop() { listener.cancel() }
    deinit { listener.cancel() }
}
#endif

/// wait up to `secs` for `cond` (any thread), polling every 20 ms
func more2Wait(_ secs: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return cond()
}

/// run `body` detached and wait up to `secs`; Fail naming `stage` if it does not finish (it may stay blocked)
func more2Stage<T: Sendable>(_ stage: String, _ secs: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let r = Mutex<Result<T, Error>?>(nil)
    Task.detached { do { let v = try await body(); r.withLock { $0 = .success(v) } } catch { r.withLock { $0 = .failure(error) } } }
    let t0 = Date()
    while Date().timeIntervalSince(t0) < secs {
        if let v = r.withLock({ $0 }) { return try v.get() }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw Fail("\(stage): no answer in \(Int(secs)) s")
}

/// a fresh empty directory under tmp
func more2Dir(_ name: String) throws -> URL {
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("sdkcov2-\(name)")
    try? fm.removeItem(at: d)
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
