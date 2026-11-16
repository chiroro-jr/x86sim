// sdkcov P8 (Foundation, networking, security, identity & device management): Foundation depth. The four iOS-only
// Foundation checks (More_iOS.swift) ported to tvOS / watchOS / visionOS, plus background URLSession (nsurlsessiond),
// #Predicate / NSPredicate evaluation, FormatStyle breadth, NSUserActivity, URLSessionStreamTask and CFHTTPMessage on
// every platform. Each verified against Apple's simulator (ref-mac.sh).
import Foundation
import Synchronization
#if canImport(Network)
import Network
#endif
#if canImport(CFNetwork)
import CFNetwork
#endif

// MARK: helpers shared by the P8 files

/// a value set once from any thread, awaited with a deadline
final class P8Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T?
    func set(_ x: T) { lock.withLock { if v == nil { v = x } } }
    var value: T? { lock.withLock { v } }
    func wait(_ secs: Double) async -> T? {
        let end = Date().addingTimeInterval(secs)
        while Date() < end { if let v = value { return v }; try? await Task.sleep(for: .milliseconds(20)) }
        return value
    }
}
/// "domain code" of an error
func p8Err(_ e: Error?) -> String { e.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "nil" }

/// More2HTTP answering /data/N (N bytes, cacheable), POST /up (body reversed) and /redirect-cb (302 to a custom scheme)
#if canImport(Network)
func p8HTTP(tls: Bool = false) throws -> More2HTTP {
    try More2HTTP(tls: tls) { r in
        if r.method == "POST" { return More2Resp("200 OK", [("Content-Type", "application/octet-stream")], Data(r.body.reversed())) }
        if r.path.hasPrefix("/data/"), let n = Int(r.path.dropFirst(6)) {
            return More2Resp("200 OK", [("Content-Type", "application/octet-stream"), ("Cache-Control", "max-age=600"), ("ETag", "\"sdkcov\"")],
                             Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
        }
        if r.path.hasPrefix("/auth") { return More2Resp("302 Found", [("Location", "sdkcov-p8://callback?code=42&state=x86")]) }
        return More2Resp("404 Not Found")
    }
}
#endif

/// URLSession delegate of the background session: the downloaded file's bytes and the events seen
final class P8BGDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let done = P8Box<String>()
    let lock = NSLock(); var bytes = Data(); var progress = 0
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let d = (try? Data(contentsOf: location)) ?? Data()
        lock.withLock { bytes = d }
    }
    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData w: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.withLock { progress += 1 }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        done.set(e.map { "error \(p8Err($0))" } ?? "status \((task.response as? HTTPURLResponse)?.statusCode ?? -1)")
    }
}

final class P8ActivityDelegate: NSObject, NSUserActivityDelegate, @unchecked Sendable {
    let saved = P8Box<String>()
    func userActivityWillSave(_ a: NSUserActivity) { saved.set("willSave \(a.userInfo?.count ?? 0) keys") }
}

struct P8Item: Codable, Hashable { var name: String; var size: Int; var tags: [String] }
@objc(P8Obj) final class P8Obj: NSObject {
    @objc let name: String; @objc let size: Int; @objc let tags: [String]
    init(_ n: String, _ s: Int, _ t: [String]) { name = n; size = s; tags = t }
}

extension Registry {
    static var p8_foundation: [Check] {
        var c: [Check] = []

        // MARK: ports of the iOS-only Foundation checks (More_iOS.swift has the iOS versions)
        #if !os(iOS) && canImport(Network)
        c.append(check("Foundation", "urlsession-websocket-loopback", timeout: 30) {
            let p = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options(); ws.autoReplyPing = true
            p.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let l = try NWListener(using: p, on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                @Sendable func loop() {
                    c.receiveMessage { d, ctx, _, err in
                        guard err == nil, let d else { return }
                        let md = NWProtocolWebSocket.Metadata(opcode: .text)
                        let reply = Data(("echo:" + String(decoding: d, as: UTF8.self)).utf8)
                        c.send(content: reply, contentContext: NWConnection.ContentContext(identifier: "e", metadata: [md]), isComplete: true, completion: .contentProcessed { _ in loop() })
                    }
                }
                loop()
            }
            l.start(queue: .global())
            defer { l.cancel() }
            for _ in 0..<100 where (l.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(30)) }
            let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(l.port!.rawValue)/sdkcov")!)
            task.resume()
            defer { task.cancel(with: .normalClosure, reason: nil) }
            var got: [String] = []
            for m in ["one", "two", String(repeating: "z", count: 70000)] {
                try await task.send(.string(m))
                switch try await task.receive() { case .string(let s): got.append(s); case .data(let d): got.append("data \(d.count)"); @unknown default: break }
            }
            try expect(got.count == 3 && got[0] == "echo:one" && got[1] == "echo:two" && got[2].count == 70005, "replies \(got.map { String($0.prefix(12)) + " (\($0.count))" })")
            return "3 echoes (one of 70000 B)"
        })
        c.append(check("Foundation", "urlsession-download-upload-cache", timeout: 40) {
            let srv = try p8HTTP(); _ = try await srv.start(); defer { srv.stop() }
            let cfg = URLSessionConfiguration.default
            let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-urlcache")
            try? FileManager.default.removeItem(at: cacheDir)
            cfg.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 20 << 20, directory: cacheDir); cfg.requestCachePolicy = .useProtocolCachePolicy
            let s = URLSession(configuration: cfg); defer { s.invalidateAndCancel() }
            let (file, r1) = try await s.download(from: srv.url("/data/300000"))
            let dl = try Data(contentsOf: file)
            try expect((r1 as? HTTPURLResponse)?.statusCode == 200 && dl.count == 300000 && dl[1000] == UInt8(truncatingIfNeeded: 7000), "download \(dl.count) B")
            let body = Data("x86sim upload body".utf8)
            var req = URLRequest(url: srv.url("/up")); req.httpMethod = "POST"
            let (up, _) = try await s.upload(for: req, from: body)
            try expect(up == Data(body.reversed()), "upload echo \(String(decoding: up, as: UTF8.self))")
            let u = srv.url("/data/5000")
            _ = try await s.data(from: u)
            let before = srv.requests.withLock { $0.count }
            let (d2, _) = try await s.data(from: u)
            let after = srv.requests.withLock { $0.count }
            try expect(d2.count == 5000 && after == before, "cached GET reached the server (\(before) -> \(after))")
            try expect(cfg.urlCache!.cachedResponse(for: URLRequest(url: u)) != nil, "no cached response")
            return "download 300000 B, upload echoed, cached GET, \(after) requests served"
        })
        c.append(check("Foundation", "attributed-markdown-formatters") {
            let a = try AttributedString(markdown: "**Bold** and _it_ [link](https://example.com) `code`")
            let bold = a.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            let link = a.runs.compactMap(\.link).first
            try expect(String(a.characters) == "Bold and it link code" && bold && link?.host == "example.com", "markdown \(String(a.characters)) bold \(bold) link \(String(describing: link))")
            let en = Locale(identifier: "en_US")
            let lf = ListFormatter(); lf.locale = en
            try expect(lf.string(from: ["a", "b", "c"]) == "a, b, and c", "list \(String(describing: lf.string(from: ["a", "b", "c"])))")
            let rf = RelativeDateTimeFormatter(); rf.locale = en; rf.unitsStyle = .full
            try expect(rf.localizedString(fromTimeInterval: -3 * 86400) == "3 days ago", "relative \(rf.localizedString(fromTimeInterval: -3 * 86400))")
            let bc = ByteCountFormatter(); bc.countStyle = .decimal
            try expect(bc.string(fromByteCount: 1_500_000) == "1.5 MB", "bytes \(bc.string(fromByteCount: 1_500_000))")
            let mf = MeasurementFormatter(); mf.locale = en; mf.unitOptions = .providedUnit
            let km = Measurement(value: 5, unit: UnitLength.kilometers)
            try expect(mf.string(from: km.converted(to: .miles)).hasPrefix("3.107"), "measurement \(mf.string(from: km.converted(to: .miles)))")
            let pn = try PersonNameComponents("Ada Lovelace")
            try expect(pn.givenName == "Ada" && pn.familyName == "Lovelace", "name parse \(pn)")
            let d = Date(timeIntervalSince1970: 1_800_000_000)
            let fs = d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: en, timeZone: TimeZone(identifier: "UTC")!))
            let fsn = fs.replacingOccurrences(of: "\u{202F}", with: " ")
            try expect(fsn == "Jan 15, 2027 at 8:00 AM", "date style \(fs.unicodeScalars.map { String($0.value, radix: 16) })")
            let cur = 1234.5.formatted(.currency(code: "EUR").locale(Locale(identifier: "de_DE")))
            try expect(cur.replacingOccurrences(of: "\u{00A0}", with: " ") == "1.234,50 €", "currency \(cur.unicodeScalars.map { String($0.value, radix: 16) })")
            let re = try NSRegularExpression(pattern: "(\\w+)@(\\w+)\\.com")
            let s = "mail ada@example.com and bob@test.com"
            let ms = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
            try expect(ms.count == 2, "regex matches \(ms.count)")
            return "markdown, list, relative, bytes, measurement, name, date (\(fs)), currency, regex"
        })
        c.append(check("Foundation", "file-coordination-xattr-capacity") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("sdkcov-files"); try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("a.txt")
            var err: NSError?, wrote = false
            NSFileCoordinator().coordinate(writingItemAt: f, options: .forReplacing, error: &err) { u in wrote = (try? Data("one".utf8).write(to: u)) != nil }
            try expect(wrote && err == nil, "coordinated write \(String(describing: err))")
            var read = ""
            NSFileCoordinator().coordinate(readingItemAt: f, options: [], error: &err) { u in read = (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
            try expect(read == "one", "coordinated read \(read)")
            let tmp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: f, create: true).appendingPathComponent("a.txt")
            try Data("two".utf8).write(to: tmp)
            _ = try fm.replaceItemAt(f, withItemAt: tmp)
            try expect(try String(contentsOf: f, encoding: .utf8) == "two", "replaceItemAt")
            let rc = f.withUnsafeFileSystemRepresentation { p in setxattr(p!, "com.x86sim.sdkcov", "v1", 2, 0, 0) }
            var buf = [CChar](repeating: 0, count: 8)
            let n = f.withUnsafeFileSystemRepresentation { p in getxattr(p!, "com.x86sim.sdkcov", &buf, 8, 0, 0) }
            try expect(rc == 0 && n == 2 && String(cString: Array(buf.prefix(2)) + [0]) == "v1", "xattr set \(rc) get \(n) errno \(errno)")
            var u = f; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try u.setResourceValues(rv)
            let vals = try f.resourceValues(forKeys: [.isExcludedFromBackupKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .fileSizeKey, .contentModificationDateKey])
            try expect(vals.isExcludedFromBackup == true, "excluded from backup")
            let avail = vals.volumeAvailableCapacity ?? 0, tot = vals.volumeTotalCapacity ?? 0
            try expect(avail > 100_000_000 && tot > avail, "capacity available \(avail) total \(tot)")
            try expect(vals.fileSize == 3 && vals.contentModificationDate != nil, "size \(String(describing: vals.fileSize))")
            return "coordination, replace, xattr, \(avail / 1_000_000_000) GB free of \(tot / 1_000_000_000) GB"
        })
        #endif

        // MARK: new Foundation areas, every platform
        c.append(check("Foundation", "predicate-nspredicate-evaluation") {
            let items = [P8Item(name: "alpha", size: 3, tags: ["a", "x"]), P8Item(name: "beta", size: 10, tags: ["b"]),
                         P8Item(name: "Gamma", size: 7, tags: []), P8Item(name: "delta", size: 12, tags: ["x"])]
            // Swift #Predicate (Foundation macros): evaluate, compose, archive
            // #Predicate, expanded (the Linux toolchain's Foundation macros name the open-source FoundationEssentials module):
            // { $0.size > 5 && !$0.tags.isEmpty }
            let big = Predicate<P8Item> { i in
                PredicateExpressions.build_Conjunction(
                    lhs: PredicateExpressions.build_Comparison(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(i), keyPath: \.size), rhs: PredicateExpressions.build_Arg(5), op: .greaterThan),
                    rhs: PredicateExpressions.build_Negation(PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(i), keyPath: \.tags), keyPath: \.isEmpty)))
            }
            let r1 = try items.filter { try big.evaluate($0) }.map(\.name)
            try expect(r1 == ["beta", "delta"], "#Predicate size>5 && tags: \(r1)")
            // { $0.name.localizedStandardContains("ta") || $0.tags.contains("a") }
            let name = Predicate<P8Item> { i in
                PredicateExpressions.build_Disjunction(
                    lhs: PredicateExpressions.build_localizedStandardContains(PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(i), keyPath: \.name), PredicateExpressions.build_Arg("ta")),
                    rhs: PredicateExpressions.build_contains(PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(i), keyPath: \.tags), PredicateExpressions.build_Arg("a")))
            }
            let r2 = try items.filter { try name.evaluate($0) }.map(\.name)
            try expect(r2 == ["alpha", "beta", "delta"], "#Predicate contains: \(r2)")
            // { $0.size > 5 } through JSON with a codable configuration naming the type and key path
            let sizeP = Predicate<P8Item> { i in
                PredicateExpressions.build_Comparison(lhs: PredicateExpressions.build_KeyPath(root: PredicateExpressions.build_Arg(i), keyPath: \.size), rhs: PredicateExpressions.build_Arg(5), op: .greaterThan)
            }
            var pcfg = PredicateCodableConfiguration.standardConfiguration
            pcfg.allowType(P8Item.self, identifier: "P8Item"); pcfg.allowKeyPath(\P8Item.size, identifier: "P8Item.size")
            let pd = try JSONEncoder().encode(sizeP, configuration: pcfg)
            let back = try JSONDecoder().decode(Predicate<P8Item>.self, from: pd, configuration: pcfg)
            try expect(try items.filter { try back.evaluate($0) }.count == 3, "decoded predicate")
            let sorted = items.sorted(using: [SortDescriptor(\P8Item.size, order: .reverse)]).map(\.size)
            try expect(sorted == [12, 10, 7, 3], "SortDescriptor \(sorted)")
            // NSPredicate over KVC objects: format strings, substitution, aggregates, regex, compound
            let objs = items.map { P8Obj($0.name, $0.size, $0.tags) } as NSArray
            func f(_ fmt: String, _ args: [Any] = []) -> [String] { (objs.filtered(using: NSPredicate(format: fmt, argumentArray: args)) as! [P8Obj]).map(\.name) }
            // SIZE is a reserved word of the predicate grammar: the key is escaped as #size
            try expect(f("#size >= %d AND #size <= %d", [5, 11]) == ["beta", "Gamma"], "range \(f("#size >= %d AND #size <= %d", [5, 11]))")
            try expect(f("name BEGINSWITH[c] %@", ["g"]) == ["Gamma"], "BEGINSWITH[c]")
            try expect(f("name MATCHES %@", ["^[a-d].*a$"]) == ["alpha", "beta", "delta"], "MATCHES \(f("name MATCHES %@", ["^[a-d].*a$"]))")
            try expect(f("ANY tags == 'x'") == ["alpha", "delta"], "ANY \(f("ANY tags == 'x'"))")
            try expect(f("tags.@count == 0") == ["Gamma"], "@count")
            let tmpl = NSPredicate(format: "#size > $MIN AND name IN $NAMES")
            let sub = tmpl.withSubstitutionVariables(["MIN": 4, "NAMES": ["beta", "alpha", "delta"]])
            try expect((objs.filtered(using: sub) as! [P8Obj]).map(\.name) == ["beta", "delta"], "substitution \(sub)")
            let comp = NSCompoundPredicate(orPredicateWithSubpredicates: [NSPredicate(format: "#size < 4"), NSPredicate(format: "name ==[cd] 'GAMMA'")])
            try expect((objs.filtered(using: comp) as! [P8Obj]).map(\.name) == ["alpha", "Gamma"], "compound \(comp)")
            let sum = (objs.value(forKeyPath: "@sum.size") as? NSNumber)?.intValue, mx = (objs.value(forKeyPath: "@max.size") as? NSNumber)?.intValue
            try expect(sum == 32 && mx == 12, "aggregates sum \(String(describing: sum)) max \(String(describing: mx))")
            let ex = NSExpression(format: "2 * 3 + #size")
            try expect((ex.expressionValue(with: objs[0], context: nil) as? NSNumber)?.intValue == 9, "NSExpression")
            let nsSort = objs.sortedArray(using: [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))]) as! [P8Obj]
            try expect(nsSort.map(\.name) == ["alpha", "beta", "delta", "Gamma"], "NSSortDescriptor \(nsSort.map(\.name))")
            return "#Predicate (evaluate, Codable \(pd.count) B), SortDescriptor, NSPredicate range/BEGINSWITH/MATCHES/ANY/@count/substitution/compound, KVC aggregates, NSExpression"
        })
        c.append(check("Foundation", "formatstyle-parse-roundtrip") {
            let en = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE"), utc = TimeZone(identifier: "UTC")!
            var out: [String] = []
            func eq(_ a: String, _ b: String, _ what: String) throws {
                let n = a.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
                try expect(n == b, "\(what): '\(a)' \(a.unicodeScalars.filter { $0.value > 127 }.map { String($0.value, radix: 16) }) != '\(b)'"); out.append(what)
            }
            try eq(1234567.891.formatted(.number.locale(en).precision(.fractionLength(2))), "1,234,567.89", "number")
            try eq(1234567.891.formatted(.number.locale(de).precision(.fractionLength(1))), "1.234.567,9", "number de")
            try eq(0.256.formatted(.percent.locale(en)), "25.6%", "percent")
            try eq(1_234_000.formatted(.number.notation(.compactName).locale(en)), "1.2M", "compact")
            try eq(12345.formatted(.number.notation(.scientific).locale(en)), "1.2345E4", "scientific")
            try eq(Int64(2_500_000).formatted(.byteCount(style: .file).locale(en)), "2.5 MB", "byteCount")
            try eq(Measurement(value: 21.5, unit: UnitTemperature.celsius).formatted(.measurement(width: .abbreviated, usage: .asProvided).locale(en)), "21.5°C", "measurement")
            try eq(["x", "y"].formatted(.list(type: .or).locale(en)), "x or y", "list or")
            let d = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z
            try eq(d.formatted(.iso8601), "2027-01-15T08:00:00Z", "iso8601")
            try eq(d.formatted(Date.FormatStyle(locale: en, timeZone: utc).year().month(.wide).day()), "January 15, 2027", "date components")
            try eq(d.formatted(Date.VerbatimFormatStyle(format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))h", timeZone: utc, calendar: Calendar(identifier: .gregorian))), "2027-01-15 08h", "verbatim")
            let iv = d..<d.addingTimeInterval(5400)
            try eq(iv.formatted(.components(style: .wide, fields: [.hour, .minute]).locale(en)), "1 hour, 30 minutes", "interval components")
            try eq(Duration.seconds(3725).formatted(.time(pattern: .hourMinuteSecond)), "1:02:05", "duration")
            try eq(PersonNameComponents(givenName: "Ada", familyName: "Lovelace").formatted(.name(style: .abbreviated).locale(en)), "AL", "name")
            // parse strategies: string -> value
            let n = try Double("1.234,5", format: .number.locale(de))
            try expect(n == 1234.5, "parse number de \(n)"); out.append("parse number")
            let p = try Double("42%", format: .percent.locale(en))
            try expect(abs(p - 0.42) < 1e-9, "parse percent \(p)"); out.append("parse percent")
            let dp = try Date("2027-01-15T08:00:00Z", strategy: .iso8601)
            try expect(dp == d, "parse iso8601 \(dp)"); out.append("parse iso8601")
            let cur = try Decimal("$1,234.56", format: .currency(code: "USD").locale(en))
            try expect(cur == Decimal(string: "1234.56"), "parse currency \(cur)"); out.append("parse currency")
            let url = URL(string: "https://user@example.com:8443/a/b?q=1#f")!
            try eq(url.formatted(.url.scheme(.always).host(.always).port(.always).path(.always).query(.never).fragment(.never).user(.never).password(.never)), "https://example.com:8443/a/b", "url")
            return out.joined(separator: ", ")
        })
        #if canImport(Network)
        c.append(check("Foundation", "background-urlsession-download", timeout: 60) {
            // a background session hands the transfer to nsurlsessiond and gets the file back through the delegate
            let srv = try p8HTTP(); _ = try await srv.start(); defer { srv.stop() }
            let id = "com.x86sim.test.sdkcov.bg.\(UUID().uuidString.prefix(8))"
            let cfg = URLSessionConfiguration.background(withIdentifier: id)
            cfg.isDiscretionary = false; cfg.sessionSendsLaunchEvents = false
            try expect(cfg.identifier == id && cfg.sharedContainerIdentifier == nil, "configuration")
            let d = P8BGDelegate()
            let s = URLSession(configuration: cfg, delegate: d, delegateQueue: nil)
            defer { s.invalidateAndCancel() }
            let t = s.downloadTask(with: srv.url("/data/200000"))
            t.countOfBytesClientExpectsToReceive = 200_000
            t.resume()
            guard let r = await d.done.wait(50) else { throw Fail("no completion in 50 s (task state \(t.state.rawValue), served \(srv.requests.withLock { $0 }))") }
            let bytes = d.lock.withLock { d.bytes }
            try expect(r == "status 200" && bytes.count == 200_000 && bytes[999] == UInt8(truncatingIfNeeded: 999 &* 7), "\(r), \(bytes.count) B")
            let tasks = await s.allTasks
            return "\(r), \(bytes.count) B via nsurlsessiond, \(d.lock.withLock { d.progress }) progress callbacks, \(tasks.count) tasks left"
        })
        #endif
        c.append(check("Foundation", "user-activity-handoff", timeout: 20) {
            // the activity type is declared in Info.plist (NSUserActivityTypes)
            let type = "com.x86sim.test.sdkcov.activity"
            let declared = (Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String]) ?? []
            try expect(declared.contains(type), "NSUserActivityTypes \(declared)")
            let a = NSUserActivity(activityType: type)
            a.title = "sdkcov"; a.userInfo = ["page": 7, "doc": "x86"]; a.requiredUserInfoKeys = ["page"]
            a.isEligibleForHandoff = true; a.isEligibleForSearch = false
            a.targetContentIdentifier = "sdkcov-target"
            a.keywords = ["sdkcov", "x86"]
            a.addUserInfoEntries(from: ["extra": true])
            try expect(a.userInfo?.count == 3 && a.requiredUserInfoKeys == ["page"] && a.activityType == type, "userInfo \(String(describing: a.userInfo))")
            let del = P8ActivityDelegate(); a.delegate = del
            await onMain { a.becomeCurrent() }
            a.needsSave = true
            let saved = await del.saved.wait(5)
            await onMain { a.resignCurrent() }
            a.invalidate()
            #if !os(tvOS)   // tvOS: no saved-activity deletion
            // persistent identifiers: delete answers through its completion
            let delDone = P8Box<Bool>()
            NSUserActivity.deleteSavedUserActivities(withPersistentIdentifiers: ["sdkcov-pid"]) { delDone.set(true) }
            let deleted = await delDone.wait(10)
            #if os(visionOS)
            // Apple's visionOS 27.2 simulator never calls the completion (ref-mac.sh xros): reported, not asserted
            let delNote = deleted == true ? "delete completed" : "delete: no completion (as Apple's visionOS)"
            #else
            try expect(deleted == true, "deleteSavedUserActivities never completed")
            let delNote = "delete completed"
            #endif
            #else
            let delNote = "no saved-activity deletion on tvOS"
            #endif
            return "activity \(type) current/resigned, delegate \(saved ?? "no willSave in 5 s"), \(delNote)"
        })
        #if canImport(Network)
        c.append(check("CFNetwork", "stream-task-cfhttpmessage", timeout: 30) {
            // URLSessionStreamTask against a loopback TCP echo; CFHTTPMessage build / serialize / parse
            let l = try NWListener(using: .tcp, on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                @Sendable func loop() { c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, fin, e in
                    if let d, !d.isEmpty { c.send(content: Data(d.reversed()), completion: .contentProcessed { _ in loop() }) } else if !fin && e == nil { loop() } } }
                loop()
            }
            l.start(queue: .global()); defer { l.cancel() }
            for _ in 0..<100 where (l.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(30)) }
            let st = URLSession.shared.streamTask(withHostName: "127.0.0.1", port: Int(l.port!.rawValue))
            st.resume(); defer { st.cancel() }
            try await st.write(Data("abc123".utf8), timeout: 10)
            var got = Data()
            while got.count < 6 {
                let (d, eof) = try await st.readData(ofMinLength: 1, maxLength: 64, timeout: 10)
                if let d { got.append(d) }; if eof { break }
            }
            try expect(String(decoding: got, as: UTF8.self) == "321cba", "stream echo '\(String(decoding: got, as: UTF8.self))'")
            #if !os(watchOS)   // CFHTTPMessage is not in the watchOS SDK
            let msg = CFHTTPMessageCreateRequest(nil, "POST" as CFString, URL(string: "http://example.com/p?q=1")! as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
            CFHTTPMessageSetHeaderFieldValue(msg, "X-SDKCov" as CFString, "p8" as CFString)
            CFHTTPMessageSetBody(msg, Data("body".utf8) as CFData)
            let wire = CFHTTPMessageCopySerializedMessage(msg)!.takeRetainedValue() as Data
            let ws = String(decoding: wire, as: UTF8.self)
            try expect(ws.hasPrefix("POST /p?q=1 HTTP/1.1\r\n") && ws.contains("X-Sdkcov: p8") || ws.contains("X-SDKCov: p8"), "serialized \(ws)")
            let resp = CFHTTPMessageCreateEmpty(nil, false).takeRetainedValue()
            let raw = Data("HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok".utf8)
            let appended = raw.withUnsafeBytes { CFHTTPMessageAppendBytes(resp, $0.bindMemory(to: UInt8.self).baseAddress!, raw.count) }
            try expect(appended && CFHTTPMessageIsHeaderComplete(resp), "parse")
            let code = CFHTTPMessageGetResponseStatusCode(resp)
            let ct = CFHTTPMessageCopyHeaderFieldValue(resp, "content-type" as CFString)?.takeRetainedValue() as String?
            let body = CFHTTPMessageCopyBody(resp)?.takeRetainedValue() as Data?
            try expect(code == 201 && ct == "text/plain" && body == Data("ok".utf8), "response \(code) \(String(describing: ct))")
            return "stream task echo, CFHTTPMessage request \(wire.count) B, response 201 parsed"
            #else
            return "stream task echo"
            #endif
        })
        #endif
        return c
    }
}

extension Registry {
    /// every P8 group, in run order
    static var p8: [Check] { p8_foundation + p8_net + p8_security + p8_device + p8_last }
}
