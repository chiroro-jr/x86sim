// sdkcov P8: Network depth (WebSocket / custom framer / QUIC / multicast group / the Swift NetworkConnection API on
// loopback), NetworkExtension managers, MultipeerConnectivity two-peer session, SystemConfiguration reachability.
import Foundation
import Synchronization
#if canImport(Network)
import Network
#endif
#if canImport(NetworkExtension)
import NetworkExtension
#endif
#if canImport(MultipeerConnectivity) && !os(watchOS)
import MultipeerConnectivity
#endif
#if canImport(SystemConfiguration) && !os(watchOS)
import SystemConfiguration
#endif

#if canImport(Network)
/// start `l` and wait for its port
func p8Port(_ l: NWListener) async throws -> UInt16 {
    let st = P8Box<String>()
    l.stateUpdateHandler = { s in switch s { case .ready: st.set("ready"); case .failed(let e): st.set("failed \(e)"); default: break } }
    l.start(queue: .global())
    let r = await st.wait(10)
    guard r == "ready", let p = l.port?.rawValue else { throw Fail("listener \(r ?? "no state in 10 s")") }
    return p
}
/// start `c` and wait for .ready
func p8Ready(_ c: NWConnection, _ secs: Double = 10) async throws {
    let st = P8Box<String>()
    c.stateUpdateHandler = { s in switch s { case .ready: st.set("ready"); case .failed(let e): st.set("failed \(e)"); case .waiting(let e): st.set("waiting \(e)"); default: break } }
    c.start(queue: .global())
    let r = await st.wait(secs)
    guard r == "ready" else { throw Fail("connection \(r ?? "no state in \(Int(secs)) s")") }
}
/// one message (complete) from `c`
func p8Receive(_ c: NWConnection, _ secs: Double = 10) async throws -> (Data, NWConnection.ContentContext?) {
    let b = P8Box<Result<(Data, NWConnection.ContentContext?), Error>>()
    c.receiveMessage { d, ctx, _, e in if let e { b.set(.failure(e)) } else { b.set(.success((d ?? Data(), ctx))) } }
    guard let r = await b.wait(secs) else { throw Fail("no message in \(Int(secs)) s") }
    return try r.get()
}
func p8Send(_ c: NWConnection, _ d: Data?, _ ctx: NWConnection.ContentContext = .defaultMessage) async throws {
    let b = P8Box<String>()
    c.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { e in b.set(e.map { "\($0)" } ?? "ok") })
    let r = await b.wait(10)
    try expect(r == "ok", "send: \(r ?? "no completion")")
}

/// a framer: 1-byte type + 4-byte big-endian length + payload
final class P8Framer: NWProtocolFramerImplementation {
    static let label = "SDKCovTL"
    static let definition = NWProtocolFramer.Definition(implementation: P8Framer.self)
    init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        let t = (message["type"] as? UInt8) ?? 0
        var h = Data([t]); var n = UInt32(messageLength).bigEndian; h.append(Data(bytes: &n, count: 4))
        framer.writeOutput(data: h)
        try? framer.writeOutputNoCopy(length: messageLength)
    }
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var t: UInt8 = 0, len: UInt32 = 0
            let ok = framer.parseInput(minimumIncompleteLength: 5, maximumLength: 5) { buf, _ in
                guard let buf, buf.count >= 5 else { return 0 }
                t = buf[0]; len = UInt32(buf[1]) << 24 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 8 | UInt32(buf[4]); return 5
            }
            guard ok else { return 5 }
            let m = NWProtocolFramer.Message(definition: P8Framer.definition); m["type"] = t
            if !framer.deliverInputNoCopy(length: Int(len), message: m, isComplete: true) { return 0 }
        }
    }
}

struct P8Msg: Codable, Sendable, Equatable { var n: Int; var s: String }
#endif

#if canImport(MultipeerConnectivity) && !os(watchOS)
/// both ends of a one-process Multipeer session: A advertises and accepts, B browses and invites
final class P8MC: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, StreamDelegate, @unchecked Sendable {
    let a = MCPeerID(displayName: "sdkcov-A"), b = MCPeerID(displayName: "sdkcov-B")
    lazy var sa = MCSession(peer: a, securityIdentity: nil, encryptionPreference: .none)
    lazy var sb = MCSession(peer: b, securityIdentity: nil, encryptionPreference: .none)
    lazy var adv = MCNearbyServiceAdvertiser(peer: a, discoveryInfo: ["v": "8"], serviceType: "sdkcov")
    lazy var br = MCNearbyServiceBrowser(peer: b, serviceType: "sdkcov")
    let lock = NSLock()
    var log: [String] = [], found: [String: String] = [:], invited = "", connected = Set<String>()
    var dataA = Data(), streamA = Data(), resourceA: URL?, errors: [String] = []
    var inStream: InputStream?
    func note(_ s: String) { lock.withLock { log.append(s) } }
    func start() {
        sa.delegate = self; sb.delegate = self; adv.delegate = self; br.delegate = self
        adv.startAdvertisingPeer(); br.startBrowsingForPeers()
    }
    func stop() { adv.stopAdvertisingPeer(); br.stopBrowsingForPeers(); sa.disconnect(); sb.disconnect() }
    func session(_ s: MCSession, peer p: MCPeerID, didChange st: MCSessionState) {
        note("\(s === sa ? "A" : "B") \(p.displayName) \(st.rawValue)")
        if st == .connected { lock.withLock { _ = connected.insert(s === sa ? "A" : "B") } }
    }
    func session(_ s: MCSession, didReceive d: Data, fromPeer p: MCPeerID) { if s === sa { lock.withLock { dataA.append(d) } } }
    func session(_ s: MCSession, didReceive st: InputStream, withName n: String, fromPeer p: MCPeerID) {
        note("stream \(n)")
        DispatchQueue.main.async { self.inStream = st; st.delegate = self; st.schedule(in: .main, forMode: .default); st.open() }
    }
    func stream(_ s: Stream, handle e: Stream.Event) {
        guard let i = s as? InputStream, e == .hasBytesAvailable else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = i.read(&buf, maxLength: buf.count)
        if n > 0 { lock.withLock { streamA.append(contentsOf: buf[0..<n]) } }
    }
    func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with pr: Progress) { note("resource start \(n)") }
    func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at url: URL?, withError e: Error?) {
        if let url, let d = try? Data(contentsOf: url) {
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-mc-\(n)")
            try? d.write(to: keep); lock.withLock { resourceA = keep }
        } else { lock.withLock { errors.append("resource \(p8Err(e))") } }
    }
    func session(_ s: MCSession, didReceiveCertificate c: [Any]?, fromPeer p: MCPeerID, certificateHandler h: @escaping (Bool) -> Void) { h(true) }
    func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer p: MCPeerID, withContext ctx: Data?, invitationHandler h: @escaping (Bool, MCSession?) -> Void) {
        lock.withLock { invited = "\(p.displayName) ctx \(ctx.map { String(decoding: $0, as: UTF8.self) } ?? "-")" }
        h(true, sa)
    }
    func advertiser(_ a: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer e: Error) { lock.withLock { errors.append("advertise \(p8Err(e))") } }
    func browser(_ br: MCNearbyServiceBrowser, foundPeer p: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        lock.withLock { found[p.displayName] = info?["v"] ?? "-" }
        if p.displayName == "sdkcov-A" { br.invitePeer(p, to: sb, withContext: Data("hello".utf8), timeout: 20) }
    }
    func browser(_ b: MCNearbyServiceBrowser, lostPeer p: MCPeerID) { note("lost \(p.displayName)") }
    func browser(_ b: MCNearbyServiceBrowser, didNotStartBrowsingForPeers e: Error) { lock.withLock { errors.append("browse \(p8Err(e))") } }
}
#endif

extension Registry {
    static var p8_net: [Check] {
        var c: [Check] = []
        #if canImport(Network)
        c.append(check("Network", "websocket-nwconnection-ping-close", timeout: 30) {
            // NWProtocolWebSocket on both ends: text and binary echo, a ping answered with a pong, a close code
            let sp = NWParameters.tcp
            let so = NWProtocolWebSocket.Options(); so.autoReplyPing = true
            sp.defaultProtocolStack.applicationProtocols.insert(so, at: 0)
            let l = try NWListener(using: sp, on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                @Sendable func loop() {
                    c.receiveMessage { d, ctx, _, e in
                        guard e == nil, let md = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else { return }
                        if md.opcode == .close { return }
                        // a ping is answered by autoReplyPing but still delivered: not echoed
                        if md.opcode == .ping || md.opcode == .pong { loop(); return }
                        let out = NWProtocolWebSocket.Metadata(opcode: md.opcode == .binary ? .binary : .text)
                        var reply = d ?? Data(); if md.opcode == .text { reply = Data("echo:".utf8) + reply } else { reply.reverse() }
                        let last = String(decoding: d ?? Data(), as: UTF8.self) == "bye"
                        if last {
                            let cm = NWProtocolWebSocket.Metadata(opcode: .close); cm.closeCode = .protocolCode(.goingAway)
                            c.send(content: nil, contentContext: NWConnection.ContentContext(identifier: "close", metadata: [cm]), isComplete: true, completion: .contentProcessed { _ in })
                            return
                        }
                        c.send(content: reply, contentContext: NWConnection.ContentContext(identifier: "r", metadata: [out]), isComplete: true, completion: .contentProcessed { _ in loop() })
                    }
                }
                loop()
            }
            let port = try await p8Port(l); defer { l.cancel() }
            let cp = NWParameters.tcp
            let co = NWProtocolWebSocket.Options(); co.setAdditionalHeaders([("X-SDKCov", "p8")])
            cp.defaultProtocolStack.applicationProtocols.insert(co, at: 0)
            let conn = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/p8")!), using: cp)
            try await p8Ready(conn); defer { conn.cancel() }
            func ctx(_ op: NWProtocolWebSocket.Opcode) -> NWConnection.ContentContext { NWConnection.ContentContext(identifier: "m", metadata: [NWProtocolWebSocket.Metadata(opcode: op)]) }
            try await p8Send(conn, Data("hi".utf8), ctx(.text))
            let (t, _) = try await p8Receive(conn)
            try expect(String(decoding: t, as: UTF8.self) == "echo:hi", "text echo \(String(decoding: t, as: UTF8.self))")
            try await p8Send(conn, Data([1, 2, 3, 250]), ctx(.binary))
            let (bn, bctx) = try await p8Receive(conn)
            let bop = (bctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            try expect(bn == Data([250, 3, 2, 1]) && bop == .binary, "binary echo \(Array(bn)) \(String(describing: bop))")
            // ping: the server's autoReplyPing answers; the pong handler runs
            let pong = P8Box<String>()
            let pm = NWProtocolWebSocket.Metadata(opcode: .ping)
            pm.setPongHandler(.global()) { e in pong.set(e.map { "\($0)" } ?? "pong") }
            conn.send(content: Data("p".utf8), contentContext: NWConnection.ContentContext(identifier: "ping", metadata: [pm]), isComplete: true, completion: .contentProcessed { _ in })
            let pr = await pong.wait(5)
            try expect(pr == "pong", "ping: \(pr ?? "no pong in 5 s")")
            try await p8Send(conn, Data("bye".utf8), ctx(.text))
            // the next frame is the close (a pong that was not consumed by the handler may come first)
            var cmd: NWProtocolWebSocket.Metadata?, seen: [String] = []
            for _ in 0..<4 {
                let (_, cctx) = try await p8Receive(conn)
                cmd = cctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                seen.append("\(String(describing: cmd?.opcode))")
                if cmd?.opcode != .pong { break }
            }
            try expect(cmd?.opcode == .close, "close frame: frames \(seen)")
            let code: String; if case .protocolCode(let pc)? = cmd?.closeCode { code = "\(pc)" } else { code = "\(String(describing: cmd?.closeCode))" }
            try expect(code == "goingAway", "close code \(code)")
            return "text + binary echo, ping/pong, close goingAway"
        })
        c.append(check("Network", "framer-custom-protocol", timeout: 30) {
            // the same NWProtocolFramer (type + length header) on both ends of a loopback TCP connection
            func params() -> NWParameters { let p = NWParameters.tcp; p.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: P8Framer.definition), at: 0); return p }
            let l = try NWListener(using: params(), on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                @Sendable func loop() {
                    c.receiveMessage { d, ctx, _, e in
                        // an empty message arrives with nil content
                        guard e == nil, let m = ctx?.protocolMetadata(definition: P8Framer.definition) as? NWProtocolFramer.Message else { return }
                        let d = d ?? Data()
                        let t = (m["type"] as? UInt8) ?? 0
                        let out = NWProtocolFramer.Message(definition: P8Framer.definition); out["type"] = t &+ 100
                        c.send(content: Data(d.reversed()), contentContext: NWConnection.ContentContext(identifier: "r", metadata: [out]), isComplete: true, completion: .contentProcessed { _ in loop() })
                    }
                }
                loop()
            }
            let port = try await p8Port(l); defer { l.cancel() }
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: params())
            try await p8Ready(conn); defer { conn.cancel() }
            var got: [String] = []
            for (t, body) in [(UInt8(1), Data("abc".utf8)), (2, Data(repeating: 9, count: 100_000)), (3, Data())] {
                let m = NWProtocolFramer.Message(definition: P8Framer.definition); m["type"] = t
                try await p8Send(conn, body, NWConnection.ContentContext(identifier: "m\(t)", metadata: [m]))
                let r: (Data, NWConnection.ContentContext?)
                do { r = try await p8Receive(conn) } catch { throw Fail("message \(t): \(error)") }
                let (d, ctx) = r
                let rt = ((ctx?.protocolMetadata(definition: P8Framer.definition) as? NWProtocolFramer.Message)?["type"] as? UInt8) ?? 0
                try expect(rt == t + 100 && d == Data(body.reversed()), "message \(t): type \(rt), \(d.count) B")
                got.append("\(rt):\(d.count)")
            }
            return "framed messages \(got.joined(separator: " "))"
        })
        c.append(check("Network", "quic-loopback-streams", timeout: 30) {
            // QUIC with the test TLS identity (ALPN sdkcov); the client trusts it through a verify block
            let (id, _) = try More2TLS.identity()
            let so = NWProtocolQUIC.Options(alpn: ["sdkcov"])
            guard let sid = sec_identity_create(id) else { throw Fail("sec_identity_create") }
            sec_protocol_options_set_local_identity(so.securityProtocolOptions, sid)
            let l = try NWListener(using: NWParameters(quic: so), on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in
                    c.send(content: Data("quic:".utf8) + (d ?? Data()), isComplete: true, completion: .contentProcessed { _ in })
                }
            }
            let port = try await p8Port(l); defer { l.cancel() }
            let co = NWProtocolQUIC.Options(alpn: ["sdkcov"])
            let verified = P8Box<Bool>()
            sec_protocol_options_set_verify_block(co.securityProtocolOptions, { _, trust, done in verified.set(true); done(true) }, .global())
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(quic: co))
            try await p8Ready(conn, 15); defer { conn.cancel() }
            let md = conn.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
            try await p8Send(conn, Data("ping".utf8))
            let b = P8Box<Data>()
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in b.set(d ?? Data()) }
            let r = await b.wait(10)
            try expect(r == Data("quic:ping".utf8), "reply \(r.map { String(decoding: $0, as: UTF8.self) } ?? "none")")
            try expect(verified.value == true, "verify block not called")
            return "QUIC stream \(md.map { "id \($0.streamIdentifier)" } ?? "-") echoed, server identity verified"
        })
        c.append(check("Network", "networkconnection-tlv-coder", timeout: 30) {
            // the Swift NetworkConnection / NetworkListener API (iOS 26): TLV framing and a JSON Coder over TCP
            let port = P8Box<UInt16>()
            let l = try NetworkListener { TLV { TCP() } }
            l.onStateUpdate { l, s in if s == .ready, let p = l.port?.rawValue { port.set(p) } }
            let srv = Task { try await l.run { conn in
                while true {
                    let m = try await conn.receive()
                    try await conn.send(Data(m.content.reversed()), type: m.metadata.type + 1)
                }
            } }
            defer { srv.cancel() }
            guard let p = await port.wait(10) else { throw Fail("listener not ready in 10 s") }
            let conn = NetworkConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!)) { TLV { TCP() } }
            try await conn.send(Data("tlv".utf8), type: 7)
            let r = try await conn.receive()
            try expect(r.content == Data("vlt".utf8) && r.metadata.type == 8, "TLV reply \(String(decoding: r.content, as: UTF8.self)) type \(r.metadata.type)")
            // Coder: Codable values, JSON on the wire
            let port2 = P8Box<UInt16>()
            let l2 = try NetworkListener { Coder(P8Msg.self, using: .json) { TCP() } }
            l2.onStateUpdate { l, s in if s == .ready, let p = l.port?.rawValue { port2.set(p) } }
            let srv2 = Task { try await l2.run { conn in
                while true { let m = try await conn.receive(); try await conn.send(P8Msg(n: m.content.n * 2, s: m.content.s.uppercased())) }
            } }
            defer { srv2.cancel() }
            guard let p2 = await port2.wait(10) else { throw Fail("coder listener not ready") }
            let c2 = NetworkConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p2)!)) { Coder(P8Msg.self, using: .json) { TCP() } }
            try await c2.send(P8Msg(n: 21, s: "x86"))
            let r2 = try await c2.receive()
            try expect(r2.content == P8Msg(n: 42, s: "X86"), "coder reply \(r2.content)")
            return "TLV type 7 -> 8 reversed, JSON Coder {21, x86} -> {42, X86}"
        })
        c.append(check("Network", "connection-group-multicast", timeout: 20) {
            // NWConnectionGroup on an administratively scoped multicast group: without the multicast entitlement
            // (com.apple.developer.networking.multicast) the group should not become ready (Apple's answer pinned by ref-mac.sh)
            let g = try NWMulticastGroup(for: [.hostPort(host: "239.255.86.8", port: 58686)])
            let grp = NWConnectionGroup(with: g, using: .udp)
            let st = P8Box<String>()
            let got = P8Box<Data>()
            grp.setReceiveHandler(maximumMessageSize: 1500, rejectOversizedMessages: true) { _, d, _ in if let d { got.set(d) } }
            grp.stateUpdateHandler = { s in switch s { case .ready: st.set("ready"); case .failed(let e): st.set("failed \(e)"); case .waiting(let e): st.set("waiting \(e)"); default: break } }
            grp.start(queue: .global()); defer { grp.cancel() }
            let s = await st.wait(8) ?? "no state in 8 s"
            var echo = "-"
            if s == "ready" {
                let sendErr = P8Box<String>()
                grp.send(content: Data("mc".utf8)) { e in sendErr.set(e.map { "\($0)" } ?? "ok") }
                echo = (await got.wait(3)).map { "looped back \($0.count) B" } ?? "no loopback (send \(sendErr.value ?? "pending"))"
            }
            // Apple's 27.2 simulators (all four): ready, and the group's own datagram loops back. The loopback is reported, not
            // asserted: it crosses the host's real interface, where a host firewall may drop inbound multicast (on the
            // x86Sim build host ufw does, for Linux's own sockets too)
            try expect(s == "ready", "group \(s), \(echo) (Apple's: ready, looped back 2 B)")
            return "group \(s), \(echo)"
        })
        #endif

        // MARK: NetworkExtension
        #if canImport(NetworkExtension) && (os(iOS) || os(visionOS))   // tvOS: More_tvOS.swift's; watchOS: hotspot API only
        c.append(check("NetworkExtension", "vpn-relay-managers-settings", timeout: 40) {
            func load(_ f: (@escaping (Error?) -> Void) -> Void) async -> String {
                await withCheckedContinuation { k in f { e in k.resume(returning: e.map { p8Err($0) } ?? "ok") } }
            }
            let vpn = await load { NEVPNManager.shared().loadFromPreferences(completionHandler: $0) }
            let all: String = await withCheckedContinuation { k in
                NETunnelProviderManager.loadAllFromPreferences { ms, e in k.resume(returning: e.map { p8Err($0) } ?? "\(ms?.count ?? 0) managers") }
            }
            let relay = await load { NERelayManager.shared().loadFromPreferences(completionHandler: $0) }
            let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")
            s.ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
            s.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
            s.ipv6Settings = NEIPv6Settings(addresses: ["fd00::2"], networkPrefixLengths: [64])
            s.dnsSettings = NEDNSSettings(servers: ["192.0.2.53"]); s.dnsSettings?.matchDomains = [""]
            s.mtu = 1400
            try expect(s.ipv4Settings?.addresses == ["10.0.0.2"] && s.dnsSettings?.servers.first == "192.0.2.53" && s.mtu == 1400, "settings")
            let rule = NEOnDemandRuleConnect(); rule.interfaceTypeMatch = .wiFi; rule.ssidMatch = ["sdkcov"]
            try expect(rule.action == .connect && rule.ssidMatch == ["sdkcov"], "on-demand rule")
            let relayCfg = NERelay(); relayCfg.http3RelayURL = URL(string: "https://relay.example.com/"); relayCfg.additionalHTTPHeaderFields = ["x": "1"]
            try expect(relayCfg.http3RelayURL?.host == "relay.example.com", "relay")
            return "vpn \(vpn), relay \(relay), tunnels \(all)"
        })
        #endif
        #if canImport(NetworkExtension) && !os(tvOS)   // tvOS: neither DNS settings, filters nor hotspots
        c.append(check("NetworkExtension", "filter-dns-hotspot-push-managers", timeout: 40) {
            // managers an app without the Network Extension entitlements loads: answers, not hangs (pinned to Apple's)
            func load(_ f: (@escaping (Error?) -> Void) -> Void) async -> String {
                await withCheckedContinuation { k in f { e in k.resume(returning: e.map { p8Err($0) } ?? "ok") } }
            }
            var out: [String] = []
            #if !os(watchOS) && !os(tvOS)
            out.append("filter \(await load { NEFilterManager.shared().loadFromPreferences(completionHandler: $0) })")
            #endif
            #if !os(watchOS) && !os(tvOS)
            out.append("dns \(await load { NEDNSSettingsManager.shared().loadFromPreferences(completionHandler: $0) })")
            #endif
            #if os(iOS)
            let pushAll: String = await withCheckedContinuation { k in NEAppPushManager.loadAllFromPreferences { ms, e in k.resume(returning: e.map { p8Err($0) } ?? "\(ms?.count ?? 0)") } }
            out.append("app push \(pushAll)")
            #endif
            #if os(iOS) || os(watchOS)
            let hs = NEHotspotConfiguration(ssid: "sdkcov-none", passphrase: "password123", isWEP: false); hs.joinOnce = true
            let apply: String = await withCheckedContinuation { k in NEHotspotConfigurationManager.shared.apply(hs) { e in k.resume(returning: p8Err(e)) } }
            out.append("hotspot apply \(apply)")
            try expect(apply == "NEHotspotConfigurationErrorDomain 8", "hotspot apply \(apply) (Apple's: NEHotspotConfigurationErrorDomain 8, internal)")
            let ssids: [String] = await withCheckedContinuation { k in NEHotspotConfigurationManager.shared.getConfiguredSSIDs { k.resume(returning: $0) } }
            out.append("configured \(ssids.count)")
            let cur: String = await withCheckedContinuation { k in NEHotspotNetwork.fetchCurrent { n in k.resume(returning: n?.ssid ?? "none") } }
            out.append("current \(cur)")
            #endif
            #if !os(tvOS)
            let hc = NEHotspotConfiguration(ssid: "sdkcov"); hc.hidden = true
            try expect(hc.ssid == "sdkcov" && hc.hidden, "hotspot configuration")
            #endif
            return out.joined(separator: ", ")
        })
        #endif

        // MARK: MultipeerConnectivity
        #if canImport(MultipeerConnectivity) && !os(watchOS)
        c.append(check("MultipeerConnectivity", "two-peer-data-stream-resource", timeout: 60) {
            // advertiser + browser in one process (service "sdkcov" = _sdkcov._tcp, in NSBonjourServices): find,
            // invite with a context, accept, then data, a stream and a resource from B to A
            let mc = P8MC()
            await onMain { mc.start() }
            defer { Task { @MainActor in mc.stop() } }
            let t0 = Date()
            // (visionOS too: Apple's visionOS 27.2 simulator once found no peer in 30 s, but connects both ways on a fresh
            // device, ref-mac.sh xros 2026-11-16)
            while Date().timeIntervalSince(t0) < 30 && mc.lock.withLock({ mc.connected.count < 2 && mc.errors.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
            let (found, invited, conn, errs, log) = mc.lock.withLock { (mc.found, mc.invited, mc.connected, mc.errors, mc.log) }
            #if os(visionOS)
            // Apple's visionOS 27.2 simulator: on some devices / runs the browser finds no peer in 30 s and nothing fails
            // (ref-mac.sh xros), on others both connect: either answer, but nothing half-way and no error
            if found.isEmpty && conn.isEmpty && errs.isEmpty && invited.isEmpty { return "no peer found in 30 s, no error (as Apple's visionOS simulator on some runs)" }
            #endif
            try expect(conn.count == 2, "not connected in 30 s: found \(found), invited '\(invited)', connected \(conn.sorted()), errors \(errs), events \(log.suffix(6))")
            try expect(found["sdkcov-A"] == "8" && invited == "sdkcov-B ctx hello", "discovery info \(found), invitation '\(invited)'")
            try mc.sb.send(Data("mc-data".utf8), toPeers: [mc.a], with: .reliable)
            let os = try mc.sb.startStream(withName: "s1", toPeer: mc.a)
            await onMain { os.schedule(in: .main, forMode: .default); os.open() }
            let payload = Array("stream-bytes".utf8)
            let rf = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-mc-src.bin")
            try Data(repeating: 0x5a, count: 50_000).write(to: rf)
            let sent = P8Box<String>()
            _ = mc.sb.sendResource(at: rf, withName: "res.bin", toPeer: mc.a) { e in sent.set(p8Err(e)) }
            var wrote = false
            let t1 = Date()
            while Date().timeIntervalSince(t1) < 20 {
                if !wrote, os.hasSpaceAvailable { wrote = os.write(payload, maxLength: payload.count) == payload.count }
                let (d, s, r) = mc.lock.withLock { (mc.dataA, mc.streamA, mc.resourceA) }
                if d.count >= 7 && s.count >= payload.count && r != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            os.close()
            let (d, s, r) = mc.lock.withLock { (mc.dataA, mc.streamA, mc.resourceA) }
            let rsize = r.flatMap { try? Data(contentsOf: $0).count } ?? -1
            try expect(String(decoding: d, as: UTF8.self) == "mc-data", "data '\(String(decoding: d, as: UTF8.self))'")
            try expect(Array(s) == payload, "stream \(s.count) B (wrote \(wrote))")
            try expect(rsize == 50_000, "resource \(rsize) B (send completion \(sent.value ?? "-"))")
            return "connected both ways, data, stream \(s.count) B, resource \(rsize) B"
        })
        #endif

        // MARK: SystemConfiguration
        #if canImport(SystemConfiguration) && !os(watchOS)
        c.append(check("SystemConfiguration", "reachability-callbacks", timeout: 20) {
            // a name target resolves asynchronously and reports through its callback (scheduled on a queue)
            guard let r = SCNetworkReachabilityCreateWithName(nil, "localhost") else { throw Fail("create") }
            final class Box: @unchecked Sendable { let b = P8Box<UInt32>() }
            let box = Box()
            var ctx = SCNetworkReachabilityContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let ok = SCNetworkReachabilitySetCallback(r, { _, flags, info in
                Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().b.set(flags.rawValue)
            }, &ctx)
            try expect(ok && SCNetworkReachabilitySetDispatchQueue(r, .global()), "set callback / queue")
            defer { SCNetworkReachabilitySetDispatchQueue(r, nil) }
            let cb = await box.b.wait(10)
            var f = SCNetworkReachabilityFlags()
            let got = SCNetworkReachabilityGetFlags(r, &f)
            try expect(got && f.contains(.reachable), "localhost flags \(f.rawValue) (got \(got))")
            // the default route (0.0.0.0)
            var zero = sockaddr_in(); zero.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); zero.sin_family = sa_family_t(AF_INET)
            let dr = withUnsafePointer(to: &zero) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SCNetworkReachabilityCreateWithAddress(nil, $0) } }
            var df = SCNetworkReachabilityFlags()
            try expect(dr != nil && SCNetworkReachabilityGetFlags(dr!, &df) && df.contains(.reachable), "default route flags \(df.rawValue)")
            let extra = ""
            return "localhost callback \(cb.map { "flags \($0)" } ?? "none in 10 s"), flags \(f.rawValue), default route \(df.rawValue)\(extra)"
        })
        #endif
        return c
    }
}
