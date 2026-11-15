// sdkcov round 2: the system layers x86Sim emulates itself (the arm64 JIT's integer / FP / SIMD / atomics, Darling's
// BSD and Mach syscalls: threads, signals, kqueue, sockets, mmap, mach_msg, XPC) and file-system APIs apps lean on.
// Every check asserts exact values (bit patterns, byte contents, counts), not only that a call returns.
import Foundation
import Synchronization
import Darwin
import simd
#if canImport(XPC)
import XPC
#endif
import Security
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: helpers

private final class More2Box { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }
/// start a pthread running `body` (stack size `stack` when > 0)
private func more2Thread(stack: Int = 0, _ body: @escaping () -> Void) throws -> pthread_t {
    var attr = pthread_attr_t(); pthread_attr_init(&attr); defer { pthread_attr_destroy(&attr) }
    if stack > 0 { pthread_attr_setstacksize(&attr, stack) }
    var t: pthread_t?
    let ctx = Unmanaged.passRetained(More2Box(body)).toOpaque()
    let rc = pthread_create(&t, &attr, { p in Unmanaged<More2Box>.fromOpaque(p).takeRetainedValue().f(); return nil }, ctx)
    guard rc == 0, let t else { throw Fail("pthread_create \(rc)") }
    return t
}

/// recurse until `want` bytes of stack below `top` are in use; returns the depth reached in bytes
private func more2Dive(_ top: UInt, _ want: UInt) -> UInt {
    var x = top
    let here = withUnsafeMutablePointer(to: &x) { UInt(bitPattern: $0) }
    if top &- here >= want { return top &- here }
    return more2Dive(top, want) &+ (x & 0)
}

private let more2KeyDtors = Atomic<Int>(0)
private let more2Sig = Atomic<Int>(0)          // SIGUSR1 handler runs
private let more2SigAlrm = Atomic<Int>(0)      // SIGALRM handler runs
private let more2SigThread = Atomic<UInt>(0)   // pthread_self of the last SIGUSR1 handler run

@objc protocol More2XPCProto {
    func reverse(_ d: Data, reply: @escaping (Data, Int) -> Void)
    func sum(_ a: [NSNumber], label: String, reply: @escaping (Int, String) -> Void)
}
private final class More2XPCServer: NSObject, More2XPCProto, NSXPCListenerDelegate {
    let accepted = Atomic<Int>(0)
    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        accepted.add(1, ordering: .relaxed)
        c.exportedInterface = NSXPCInterface(with: More2XPCProto.self); c.exportedObject = self; c.resume(); return true
    }
    func reverse(_ d: Data, reply: @escaping (Data, Int) -> Void) { reply(Data(d.reversed()), d.count) }
    func sum(_ a: [NSNumber], label: String, reply: @escaping (Int, String) -> Void) { reply(a.reduce(0) { $0 + $1.intValue }, label.uppercased()) }
}

private final class More2Presenter: NSObject, NSFilePresenter {
    var presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let events = Mutex<[String]>([])
    init(_ u: URL) { presentedItemURL = u }
    func presentedItemDidChange() { events.withLock { $0.append("change") } }
    func presentedItemDidMove(to u: URL) { events.withLock { $0.append("move:\(u.lastPathComponent)") }; presentedItemURL = u }
    func relinquishPresentedItem(toWriter writer: @escaping ((() -> Void)?) -> Void) { events.withLock { $0.append("relinquish") }; writer(nil) }
}

private func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ s: String) -> Data { var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }; return d }

extension Registry {
    static var more2_system: [Check] {
        guard more2On else { return [] }
        var c: [Check] = []

        // MARK: JIT: integer, floating point, SIMD, atomics
        c.append(check("Swift", "atomics-wordpair-int128") {
            // 128-bit compare-and-swap (CASP / LDXP-STXP) from 8 threads
            let a = Atomic<WordPair>(WordPair(first: 0, second: 0))
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                for _ in 0..<20000 {
                    var cur = a.load(ordering: .relaxed)
                    while true {
                        let (ok, orig) = a.compareExchange(expected: cur, desired: WordPair(first: cur.first &+ 1, second: cur.second &+ 3), ordering: .acquiringAndReleasing)
                        if ok { break }; cur = orig
                    }
                }
            }
            let v = a.load(ordering: .relaxed)
            try expect(v.first == 160_000 && v.second == 480_000, "WordPair CAS \(v.first) \(v.second)")
            let n = Atomic<Int>(0), u8 = Atomic<UInt8>(250), mx = Atomic<Int>(0)
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                for j in 0..<50000 { n.wrappingAdd(1, ordering: .relaxed) }
                mx.max(i * 1000, ordering: .relaxed)
            }
            try expect(n.load(ordering: .relaxed) == 400_000, "wrappingAdd \(n.load(ordering: .relaxed))")
            let (o8, n8) = u8.wrappingAdd(10, ordering: .relaxed)
            try expect(o8 == 250 && n8 == 4, "UInt8 wrap \(o8) \(n8)")
            try expect(mx.load(ordering: .relaxed) == 7000, "max \(mx.load(ordering: .relaxed))")
            let bits = Atomic<UInt64>(0b1010)
            _ = bits.bitwiseOr(0b0101, ordering: .relaxed); _ = bits.bitwiseXor(0b1000, ordering: .relaxed)
            try expect(bits.load(ordering: .relaxed) == 0b0111, "bitwise \(bits.load(ordering: .relaxed))")
            // 128-bit integer arithmetic
            let p = UInt128(UInt64.max) * UInt128(UInt64.max)
            try expect(String(p) == "340282366920938463426481119284349108225", "UInt128 mul \(p)")
            let d: UInt128 = 12_345_678_901_234_567
            let (q, r) = p.quotientAndRemainder(dividingBy: d)
            try expect(q * d + r == p && r < d && String(q) == "27562871968661865267591", "UInt128 div \(q) r \(r)")
            try expect(Int128(-7) / 2 == -3 && Int128(-7) % 2 == -1 && (Int128(-7) >> 1) == -4, "Int128 signed")
            try expect(String(Int128.min) == "-170141183460469231731687303715884105728", "Int128.min \(Int128.min)")
            try expect(Int128("-98765432109876543210987654321") == Int128(-98765432109876543210987654321 as Int128), "Int128 parse")
            let fw = UInt64.max.multipliedFullWidth(by: UInt64.max)
            try expect(fw.high == UInt64.max - 1 && fw.low == 1, "multipliedFullWidth \(fw)")
            let dw = UInt64(1000).dividingFullWidth((high: 1, low: 0))
            try expect(dw.quotient == 18_446_744_073_709_551 && dw.remainder == 616, "dividingFullWidth \(dw)")
            let x: UInt64 = 0x0123_4567_89ab_cdef
            try expect(x.byteSwapped == 0xefcd_ab89_6745_2301 && x.nonzeroBitCount == 32 && x.leadingZeroBitCount == 7 && x.trailingZeroBitCount == 0, "bit ops")
            try expect(Int32.min.multipliedReportingOverflow(by: -1).overflow && Int8(-128).addingReportingOverflow(-1) == (127, true), "overflow reporting")
            return "WordPair CAS 8x20000, atomics, (2^64-1)^2 = \(p)"
        })
        c.append(check("Swift", "float-simd-exactness") {
            // fused multiply-add rounds once: (1+2^-30)(1-2^-30) - 1 = -2^-60 exactly, the separate product rounds to 1
            let a = 1.0 + 0x1p-30, b = 1.0 - 0x1p-30
            let prod = a * b
            try expect(prod - 1 == 0, "unfused \(prod - 1)")
            try expect((-1.0).addingProduct(a, b) == -0x1p-60, "fma \((-1.0).addingProduct(a, b))")
            let af: Float = 1 + 0x1p-12, bf: Float = 1 - 0x1p-12
            try expect((-1 as Float).addingProduct(af, bf) == -0x1p-24, "fmaf")
            // subnormals are kept (no flush-to-zero), round-to-nearest-even
            let sub = Double.leastNormalMagnitude / 4
            try expect(sub > 0 && sub.isSubnormal && sub * 4 == .leastNormalMagnitude, "subnormal \(sub)")
            try expect(Float.leastNormalMagnitude * 0.5 > 0 && (Float.leastNonzeroMagnitude / 2) == 0, "float subnormal")
            try expect((2.5).rounded() == 3 && (2.5).rounded(.toNearestOrEven) == 2 && (-2.5).rounded(.towardZero) == -2 && (-2.5).rounded(.down) == -3, "rounding")
            try expect(1 / (-0.0) == -.infinity && (-0.0).sign == .minus && (0.0 * -1).sign == .minus, "signed zero")
            try expect((Double.infinity - .infinity).isNaN && (Double.nan + 1).isNaN && !(Double.nan == .nan), "NaN")
            try expect(Int(exactly: 2.5) == nil && Int(exactly: 3.0) == 3 && Int64(-3.99) == -3 && UInt8(255.9) == 255, "conversions")
            try expect(Double(Int64.max) == 0x1p63 && Float(16_777_217) == 16_777_216, "int -> fp rounding")
            // bit-exact libm and parsing / printing
            try expect((2.0).squareRoot().bitPattern == 0x3FF6_A09E_667F_3BCD, "sqrt(2) \(String((2.0).squareRoot().bitPattern, radix: 16))")
            try expect(Darwin.sin(1.0).bitPattern == 0x3FEA_ED54_8F09_0CEE, "sin(1) \(String(Darwin.sin(1.0).bitPattern, radix: 16))")
            try expect(Darwin.exp(1.0) == M_E && Darwin.log(M_E) == 1 && Darwin.atan2(1.0, 1.0) == .pi / 4, "exp/log/atan2")
            try expect(fmod(10.5, 3) == 1.5 && remainder(10.5, 3) == -1.5 && Darwin.pow(2.0, 0.5) == (2.0).squareRoot(), "fmod/remainder/pow")
            try expect(Double("0x1.8p1") == 3 && Double("1e-310")!.isSubnormal && String(0.1) == "0.1" && String(format: "%.17g", 0.1) == "0.10000000000000001", "parse/print")
            try expect(String(1.0 / 3.0) == "0.3333333333333333" && String(Float(1) / 3) == "0.33333334", "shortest repr")
            // Float16 (FCVT half): 0.1 -> 0x2E66, overflow -> inf, round trip
            try expect(Float16(0.1).bitPattern == 0x2E66 && Float16(Float(65520) + Float(0)).isInfinite && Float(Float16(1.5)) == 1.5 && Float16(bitPattern: 0x0001).isSubnormal, "Float16 \(String(Float16(0.1).bitPattern, radix: 16))")
            // SIMD
            let m = simd_float4x4(rows: [SIMD4(2, 0, 0, 1), SIMD4(0, 3, 0, 2), SIMD4(0, 0, 4, 3), SIMD4(0, 0, 0, 1)])
            let id = m * m.inverse
            try expect((0..<4).allSatisfy { i in (0..<4).allSatisfy { j in abs(id[i][j] - (i == j ? 1 : 0)) < 1e-6 } }, "inverse \(id)")
            let r = simd_quatf(angle: .pi / 2, axis: [0, 0, 1]).act([1, 0, 0])
            try expect(simd_distance(r, [0, 1, 0]) < 1e-6, "quaternion \(r)")
            try expect(simd_dot(SIMD4<Float>(1, 2, 3, 4), SIMD4(5, 6, 7, 8)) == 70 && simd_cross(SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0)) == SIMD3(0, 0, 1), "dot/cross")
            let v8 = SIMD16<UInt8>(repeating: 250) &+ SIMD16<UInt8>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
            try expect(v8[5] == 255 && v8[6] == 0 && v8[15] == 9 && v8.min() == 0 && v8.max() == 255, "SIMD16 wrap \(v8)")
            let mask = SIMD8<Int32>(1, -2, 3, -4, 5, -6, 7, -8) .< 0
            try expect(SIMD8<Int32>(repeating: 0).replacing(with: 1, where: mask).wrappedSum() == 4, "SIMD mask")
            try expect(SIMD4<Double>(4, 9, 16, 2).squareRoot() == SIMD4(2, 3, 4, (2.0).squareRoot()), "SIMD sqrt")
            return "fma, subnormals, rounding, bit-exact sqrt/sin, Float16, simd"
        })

        // MARK: Dispatch, pthreads, locks
        c.append(check("Dispatch", "timer-read-vnode-io-sources", timeout: 30) {
            // a repeating timer: 10 fires at 20 ms
            let fires = Mutex<[Date]>([]); let s = DispatchSemaphore(value: 0)
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(2))
            t.setEventHandler { if fires.withLock({ $0.append(Date()); return $0.count }) == 10 { s.signal() } }
            t.resume()
            try expect(s.wait(timeout: .now() + 5) == .success, "timer: \(fires.withLock { $0.count }) fires in 5 s")
            t.cancel()
            let span = fires.withLock { $0[9].timeIntervalSince($0[0]) }
            try expect(span > 0.15 && span < 1.0, "9 periods of 20 ms took \(span) s")
            // a read source on a pipe, three writes
            var fds: [Int32] = [0, 0]; try expect(pipe(&fds) == 0, "pipe")
            let got = Mutex(Data()), rs = DispatchSemaphore(value: 0)
            let r = DispatchSource.makeReadSource(fileDescriptor: fds[0], queue: .global())
            r.setEventHandler {
                var b = [UInt8](repeating: 0, count: 4096); let n = read(fds[0], &b, 4096)
                if n > 0 { if got.withLock({ $0.append(contentsOf: b[0..<n]); return $0.count }) >= 3000 { rs.signal() } }
            }
            r.setCancelHandler { close(fds[0]) }
            r.resume()
            for i in 0..<3 { let chunk = [UInt8](repeating: UInt8(65 + i), count: 1000); _ = chunk.withUnsafeBytes { write(fds[1], $0.baseAddress, 1000) }; usleep(20000) }
            try expect(rs.wait(timeout: .now() + 5) == .success, "read source got \(got.withLock { $0.count }) of 3000")
            r.cancel(); close(fds[1])
            try expect(got.withLock { $0[0] == 65 && $0[1500] == 66 && $0[2999] == 67 }, "read source bytes")
            // vnode source on a directory: a file created in it is a .write event
            let dir = try more2Dir("vnode")
            let dfd = open(dir.path, O_EVTONLY); try expect(dfd >= 0, "open O_EVTONLY errno \(errno)")
            let vs = DispatchSemaphore(value: 0), ev = Mutex<DispatchSource.FileSystemEvent>([])
            let v = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dfd, eventMask: [.write, .rename, .delete], queue: .global())
            v.setEventHandler { ev.withLock { $0.formUnion(v.data) }; vs.signal() }
            v.setCancelHandler { close(dfd) }
            v.resume()
            try Data("x".utf8).write(to: dir.appendingPathComponent("new.txt"))
            let vok = vs.wait(timeout: .now() + 5) == .success
            v.cancel()
            try expect(vok && ev.withLock { $0.contains(.write) }, "vnode event on file creation: \(vok) \(ev.withLock { $0.rawValue })")
            // DispatchIO: a 256 KB file in pieces
            let f = dir.appendingPathComponent("io.bin")
            let src = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0 &* 31) }); try src.write(to: f)
            let io = DispatchIO(type: .stream, path: f.path, oflag: O_RDONLY, mode: 0, queue: .global()) { _ in }
            guard let io else { throw Fail("DispatchIO") }
            io.setLimit(highWater: 16384)
            let ios = DispatchSemaphore(value: 0), acc = Mutex(Data()), pieces = Atomic<Int>(0), ioerr = Atomic<Int32>(0)
            io.read(offset: 0, length: Int.max, queue: .global()) { done, data, e in
                if let data, !data.isEmpty { acc.withLock { $0.append(contentsOf: data) }; pieces.add(1, ordering: .relaxed) }
                if done { ioerr.store(e, ordering: .relaxed); ios.signal() }
            }
            try expect(ios.wait(timeout: .now() + 10) == .success, "DispatchIO read did not finish")
            io.close()
            try expect(ioerr.load(ordering: .relaxed) == 0 && acc.withLock { $0 == src }, "DispatchIO bytes (\(acc.withLock { $0.count }), error \(ioerr.load(ordering: .relaxed)))")
            // a serial queue targeting a concurrent one keeps FIFO order
            let order = Mutex<[Int]>([]), sq = DispatchQueue(label: "sdkcov.serial", target: .global(qos: .utility)), g = DispatchGroup()
            for i in 0..<500 { sq.async(group: g) { order.withLock { $0.append(i) } } }
            try expect(g.wait(timeout: .now() + 5) == .success && order.withLock { $0 == Array(0..<500) }, "serial order")
            return "timer 10 x 20 ms in \(String(format: "%.3f", span)) s, pipe 3000 B, vnode \(ev.withLock { $0.rawValue }), DispatchIO \(pieces.load(ordering: .relaxed)) pieces"
        })
        c.append(check("libSystem.B", "pthread-cond-rwlock-tls-qos", timeout: 40) {
            // a bounded queue (4) with a mutex and two condition variables: 2 producers x 5000, 2 consumers
            final class Q: @unchecked Sendable {
                var m = pthread_mutex_t(), notEmpty = pthread_cond_t(), notFull = pthread_cond_t()
                var items: [Int] = [], sum = 0, taken = 0
                init() { pthread_mutex_init(&m, nil); pthread_cond_init(&notEmpty, nil); pthread_cond_init(&notFull, nil) }
            }
            let q = Q()
            var ts: [pthread_t] = []
            for p in 0..<2 { ts.append(try more2Thread {
                for i in 1...5000 {
                    pthread_mutex_lock(&q.m)
                    while q.items.count >= 4 { pthread_cond_wait(&q.notFull, &q.m) }
                    q.items.append(i + p * 5000); pthread_cond_signal(&q.notEmpty); pthread_mutex_unlock(&q.m)
                }
            }) }
            for _ in 0..<2 { ts.append(try more2Thread {
                while true {
                    pthread_mutex_lock(&q.m)
                    while q.items.isEmpty && q.taken < 10000 { pthread_cond_wait(&q.notEmpty, &q.m) }
                    if q.taken >= 10000 { pthread_cond_broadcast(&q.notEmpty); pthread_mutex_unlock(&q.m); return }
                    q.sum += q.items.removeFirst(); q.taken += 1
                    if q.taken == 10000 { pthread_cond_broadcast(&q.notEmpty) }
                    pthread_cond_signal(&q.notFull); pthread_mutex_unlock(&q.m)
                }
            }) }
            for t in ts { pthread_join(t, nil) }
            try expect(q.taken == 10000 && q.sum == 50_005_000, "producer/consumer took \(q.taken), sum \(q.sum)")
            // a timed wait times out after ~100 ms; wakeups before the deadline are legal (spurious), so like correct code
            // the wait loops on its predicate (nothing is ever queued here) until ETIMEDOUT
            pthread_mutex_lock(&q.m)
            var tv = timeval(); gettimeofday(&tv, nil)
            let dl = Int(tv.tv_usec) * 1000 + 100_000_000
            var abs = timespec(tv_sec: tv.tv_sec + dl / 1_000_000_000, tv_nsec: dl % 1_000_000_000)
            let t0 = Date(); var rc: Int32 = 0, wakeups = 0
            while q.items.isEmpty && rc == 0 { rc = pthread_cond_timedwait(&q.notEmpty, &q.m, &abs); if rc == 0 { wakeups += 1 } }
            let el = Date().timeIntervalSince(t0)
            pthread_mutex_unlock(&q.m)
            try expect(rc == ETIMEDOUT && el > 0.08 && el < 0.8 && wakeups < 1000, "timedwait rc \(rc) after \(el) s, \(wakeups) early wakeups")
            // rwlock: readers share, a writer is alone
            var rw = pthread_rwlock_t(); pthread_rwlock_init(&rw, nil)
            let inside = Atomic<Int>(0), maxReaders = Atomic<Int>(0), writerSaw = Atomic<Int>(-1)
            var rts: [pthread_t] = []
            for _ in 0..<4 { rts.append(try more2Thread {
                pthread_rwlock_rdlock(&rw); let n = inside.add(1, ordering: .sequentiallyConsistent).newValue
                maxReaders.max(n, ordering: .relaxed); usleep(50000); inside.subtract(1, ordering: .sequentiallyConsistent); pthread_rwlock_unlock(&rw)
            }) }
            usleep(10000)
            rts.append(try more2Thread { pthread_rwlock_wrlock(&rw); writerSaw.store(inside.load(ordering: .sequentiallyConsistent), ordering: .relaxed); pthread_rwlock_unlock(&rw) })
            for t in rts { pthread_join(t, nil) }
            try expect(maxReaders.load(ordering: .relaxed) >= 2 && writerSaw.load(ordering: .relaxed) == 0, "rwlock readers \(maxReaders.load(ordering: .relaxed)), writer saw \(writerSaw.load(ordering: .relaxed)) inside")
            // os_unfair_lock under contention guards a plain counter
            final class Ctr: @unchecked Sendable { var l = os_unfair_lock(); var n = 0 }
            let ctr = Ctr()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in for _ in 0..<100_000 { os_unfair_lock_lock(&ctr.l); ctr.n += 1; os_unfair_lock_unlock(&ctr.l) } }
            try expect(ctr.n == 800_000, "os_unfair_lock counter \(ctr.n)")
            // thread-specific data destructors run at thread exit; name, QoS and stack size read back
            var key = pthread_key_t(); pthread_key_create(&key) { _ in more2KeyDtors.add(1, ordering: .relaxed) }
            let before = more2KeyDtors.load(ordering: .relaxed)
            let name = Mutex(""), qos = Atomic<UInt32>(0), stack = Atomic<Int>(0), deep = Atomic<Int>(0)
            var kts: [pthread_t] = []
            for i in 0..<3 { kts.append(try more2Thread(stack: 2 << 20) {
                pthread_setspecific(key, UnsafeRawPointer(bitPattern: i + 1))
                if i == 0 {
                    pthread_setname_np("sdkcov-worker")
                    var b = [CChar](repeating: 0, count: 64); pthread_getname_np(pthread_self(), &b, 64); name.withLock { $0 = String(cString: b) }
                    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0); qos.store(qos_class_self().rawValue, ordering: .relaxed)
                    stack.store(pthread_get_stacksize_np(pthread_self()), ordering: .relaxed)
                    // ~1.2 MB of stack in use
                    func rec(_ n: Int) -> Int { var pad = (n, n, n, n, n, n, n, n, n, n, n, n, n, n, n, n); pad.0 &+= 1; return n == 0 ? pad.0 : rec(n - 1) &+ pad.15 }
                    deep.store(rec(3000), ordering: .relaxed)
                }
            }) }
            for t in kts { pthread_join(t, nil) }
            // a thread asking for a 16 MB stack can use 12 MB of it (an app's interpreter / parser thread)
            let dove = Atomic<UInt>(0)
            let big = try more2Thread(stack: 16 << 20) {
                var top: UInt = 0
                let t = withUnsafeMutablePointer(to: &top) { UInt(bitPattern: $0) }
                dove.store(more2Dive(t, 12 << 20), ordering: .relaxed)
            }
            pthread_join(big, nil)
            try expect(dove.load(ordering: .relaxed) >= 12 << 20, "16 MB stack thread reached \(dove.load(ordering: .relaxed)) B")
            try expect(await more2Wait(2) { more2KeyDtors.load(ordering: .relaxed) - before == 3 }, "TSD destructors ran \(more2KeyDtors.load(ordering: .relaxed) - before) times")
            pthread_key_delete(key)
            try expect(name.withLock { $0 } == "sdkcov-worker", "thread name \(name.withLock { $0 })")
            try expect(qos.load(ordering: .relaxed) == QOS_CLASS_UTILITY.rawValue, "qos \(qos.load(ordering: .relaxed))")
            try expect((2 << 20)...((2 << 20) + 65536) ~= stack.load(ordering: .relaxed) && deep.load(ordering: .relaxed) > 3000, "stack \(stack.load(ordering: .relaxed)) deep \(deep.load(ordering: .relaxed))")
            return "cond queue 10000, timedwait \(String(format: "%.3f", el)) s, rwlock \(maxReaders.load(ordering: .relaxed)) readers, unfair lock 800000, TSD dtors 3, QoS utility"
        })

        // MARK: BSD: kqueue, sockets, fd passing, mmap, signals
        c.append(check("libSystem.B", "kqueue-socketpair-fd-passing", timeout: 30) {
            let kq = kqueue(); try expect(kq >= 0, "kqueue errno \(errno)"); defer { close(kq) }
            var fds: [Int32] = [0, 0]; try expect(pipe(&fds) == 0, "pipe"); defer { close(fds[0]); close(fds[1]) }
            func ev(_ id: UInt64, _ f: Int32, _ fl: Int32, ff: UInt32 = 0, _ d: Int64 = 0) -> kevent64_s {
                kevent64_s(ident: id, filter: Int16(f), flags: UInt16(fl), fflags: ff, data: d, udata: 0, ext: (0, 0))
            }
            var chg = [ev(UInt64(fds[0]), EVFILT_READ, EV_ADD | EV_ENABLE), ev(7, EVFILT_TIMER, EV_ADD | EV_ONESHOT, 30), ev(9, EVFILT_USER, EV_ADD | EV_CLEAR)]
            try expect(kevent64(kq, &chg, 3, nil, 0, 0, nil) == 0, "kevent register errno \(errno)")
            _ = "hello".withCString { write(fds[1], $0, 5) }
            let th = try more2Thread { usleep(10000); var u = ev(9, EVFILT_USER, 0, ff: UInt32(NOTE_TRIGGER)); _ = kevent64(kq, &u, 1, nil, 0, 0, nil) }
            var seen: [String: Int] = [:]; let t0 = Date()
            while seen.count < 3 && Date().timeIntervalSince(t0) < 3 {
                var out = [kevent64_s](repeating: kevent64_s(), count: 8); var to = timespec(tv_sec: 1, tv_nsec: 0)
                let n = kevent64(kq, nil, 0, &out, 8, 0, &to)
                for e in out.prefix(max(0, Int(n))) {
                    switch Int32(e.filter) {
                    case EVFILT_READ: seen["read"] = Int(e.data); var b = [UInt8](repeating: 0, count: 8); _ = read(fds[0], &b, 8)
                    case EVFILT_TIMER: seen["timer"] = Int(e.ident)
                    case EVFILT_USER: seen["user"] = Int(e.ident)
                    default: break
                    }
                }
            }
            pthread_join(th, nil)
            try expect(seen["read"] == 5 && seen["timer"] == 7 && seen["user"] == 9, "kevents \(seen)")
            // pass an open file's descriptor over a unix socket (SCM_RIGHTS) and read the file through it
            let f = try more2Dir("fdpass").appendingPathComponent("f.txt"); try Data("x86sim fd".utf8).write(to: f)
            let ffd = open(f.path, O_RDONLY); try expect(ffd >= 0, "open"); defer { close(ffd) }
            var sv: [Int32] = [0, 0]; try expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0, "socketpair errno \(errno)")
            defer { close(sv[0]); close(sv[1]) }
            var byte: UInt8 = 0x2a
            var ctl = [UInt8](repeating: 0, count: 16)   // CMSG_SPACE(sizeof(int)) on Darwin: 12-byte cmsghdr + the fd
            ctl.withUnsafeMutableBytes { p in
                p.storeBytes(of: UInt32(16), toByteOffset: 0, as: UInt32.self); p.storeBytes(of: SOL_SOCKET, toByteOffset: 4, as: Int32.self)
                p.storeBytes(of: SCM_RIGHTS, toByteOffset: 8, as: Int32.self); p.storeBytes(of: ffd, toByteOffset: 12, as: Int32.self)
            }
            let sent = withUnsafeMutablePointer(to: &byte) { bp in ctl.withUnsafeMutableBytes { cp -> Int in
                var iov = iovec(iov_base: bp, iov_len: 1)
                return withUnsafeMutablePointer(to: &iov) { ip in
                    var m = msghdr(); m.msg_iov = ip; m.msg_iovlen = 1; m.msg_control = cp.baseAddress; m.msg_controllen = 16
                    return sendmsg(sv[0], &m, 0)
                }
            } }
            try expect(sent == 1, "sendmsg \(sent) errno \(errno)")
            var rbyte: UInt8 = 0; var rctl = [UInt8](repeating: 0, count: 64); var rlen: socklen_t = 0
            let got = withUnsafeMutablePointer(to: &rbyte) { bp in rctl.withUnsafeMutableBytes { cp -> Int in
                var iov = iovec(iov_base: bp, iov_len: 1)
                return withUnsafeMutablePointer(to: &iov) { ip in
                    var m = msghdr(); m.msg_iov = ip; m.msg_iovlen = 1; m.msg_control = cp.baseAddress; m.msg_controllen = 64
                    let n = recvmsg(sv[1], &m, 0); rlen = m.msg_controllen; return n
                }
            } }
            let (clen, lvl, typ, nfd) = rctl.withUnsafeBytes { ($0.load(fromByteOffset: 0, as: UInt32.self), $0.load(fromByteOffset: 4, as: Int32.self), $0.load(fromByteOffset: 8, as: Int32.self), $0.load(fromByteOffset: 12, as: Int32.self)) }
            try expect(got == 1 && rbyte == 0x2a && rlen >= 16 && clen == 16 && lvl == SOL_SOCKET && typ == SCM_RIGHTS && nfd >= 0 && nfd != ffd, "recvmsg \(got) byte \(rbyte) ctl \(rlen)/\(clen) level \(lvl) type \(typ) fd \(nfd)")
            defer { close(nfd) }
            var st1 = stat(), st2 = stat(); fstat(ffd, &st1); fstat(nfd, &st2)
            var b = [UInt8](repeating: 0, count: 32); let n = pread(nfd, &b, 32, 0)
            try expect(st1.st_ino == st2.st_ino && String(decoding: b.prefix(max(0, n)), as: UTF8.self) == "x86sim fd", "passed fd reads \(n) ino \(st1.st_ino)/\(st2.st_ino)")
            // datagram socketpair keeps message boundaries; poll sees it readable
            var dv: [Int32] = [0, 0]; try expect(socketpair(AF_UNIX, SOCK_DGRAM, 0, &dv) == 0, "dgram socketpair"); defer { close(dv[0]); close(dv[1]) }
            for len in [3, 700, 20] { let d = [UInt8](repeating: 1, count: len); _ = d.withUnsafeBytes { send(dv[0], $0.baseAddress, len, 0) } }
            var pfd = pollfd(fd: dv[1], events: Int16(POLLIN), revents: 0)
            try expect(poll(&pfd, 1, 1000) == 1 && pfd.revents & Int16(POLLIN) != 0, "poll")
            var sizes: [Int] = []
            for _ in 0..<3 { var rb = [UInt8](repeating: 0, count: 2048); sizes.append(recv(dv[1], &rb, 2048, 0)) }
            try expect(sizes == [3, 700, 20], "datagram sizes \(sizes)")
            return "kqueue read/timer/user, SCM_RIGHTS fd \(nfd), dgram \(sizes)"
        })
        c.append(check("libSystem.B", "mmap-mprotect-mach-vm-remap", timeout: 30) {
            let f = try more2Dir("mmap").appendingPathComponent("m.bin")
            try Data(count: 65536).write(to: f)
            let fd = open(f.path, O_RDWR); try expect(fd >= 0, "open"); defer { close(fd) }
            guard let p = mmap(nil, 65536, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), p != MAP_FAILED else { throw Fail("mmap errno \(errno)") }
            defer { munmap(p, 65536) }
            let bytes = p.assumingMemoryBound(to: UInt8.self)
            for i in 0..<100 { bytes[40000 + i] = UInt8(i) }
            try expect(msync(p, 65536, MS_SYNC) == 0, "msync errno \(errno)")
            var rb = [UInt8](repeating: 0, count: 100); _ = pread(fd, &rb, 100, 40000)
            try expect(rb == (0..<100).map { UInt8($0) }, "mapping -> file \(rb.prefix(4))")
            let w: [UInt8] = [9, 8, 7]; _ = w.withUnsafeBytes { pwrite(fd, $0.baseAddress, 3, 100) }
            try expect(bytes[100] == 9 && bytes[102] == 7, "file -> mapping \(bytes[100])")
            // reserve 256 MB PROT_NONE, open one page, touch it
            guard let big = mmap(nil, 256 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0), big != MAP_FAILED else { throw Fail("reserve errno \(errno)") }
            defer { munmap(big, 256 << 20) }
            let page = Int(getpagesize())
            try expect(mprotect(big + (128 << 20), page, PROT_READ | PROT_WRITE) == 0, "mprotect errno \(errno)")
            (big + (128 << 20)).storeBytes(of: 0xfeed_face_cafe_beef as UInt64, as: UInt64.self)
            try expect(mprotect(big + (128 << 20), page, PROT_READ) == 0 && (big + (128 << 20)).load(as: UInt64.self) == 0xfeed_face_cafe_beef, "read-only page")
            // vm_allocate + vm_remap (shared, not copied): a write through either address shows in the other
            var src: vm_address_t = 0
            try expect(vm_allocate(mach_task_self_, &src, vm_size_t(page * 4), VM_FLAGS_ANYWHERE) == KERN_SUCCESS, "vm_allocate")
            defer { vm_deallocate(mach_task_self_, src, vm_size_t(page * 4)) }
            var dst: vm_address_t = 0; var cur: vm_prot_t = 0, mx: vm_prot_t = 0
            let kr = vm_remap(mach_task_self_, &dst, vm_size_t(page * 4), 0, VM_FLAGS_ANYWHERE, mach_task_self_, src, 0, &cur, &mx, vm_inherit_t(VM_INHERIT_NONE))
            try expect(kr == KERN_SUCCESS && dst != 0 && dst != src, "vm_remap \(kr)")
            defer { vm_deallocate(mach_task_self_, dst, vm_size_t(page * 4)) }
            let sp = UnsafeMutablePointer<UInt64>(bitPattern: UInt(src))!, dp = UnsafeMutablePointer<UInt64>(bitPattern: UInt(dst))!
            sp[page / 8 * 3] = 0xabad_cafe; dp[5] = 77
            try expect(dp[page / 8 * 3] == 0xabad_cafe && sp[5] == 77, "remap alias \(dp[page / 8 * 3]) \(sp[5])")
            // vm_copy: a copy, not an alias
            var cpy: vm_address_t = 0; _ = vm_allocate(mach_task_self_, &cpy, vm_size_t(page), VM_FLAGS_ANYWHERE)
            defer { vm_deallocate(mach_task_self_, cpy, vm_size_t(page)) }
            try expect(vm_copy(mach_task_self_, src, vm_size_t(page), cpy) == KERN_SUCCESS, "vm_copy")
            let cp = UnsafeMutablePointer<UInt64>(bitPattern: UInt(cpy))!; sp[5] = 78
            try expect(cp[5] == 77, "vm_copy copied \(cp[5])")
            return "file mapping both ways, 256 MB reserve + mprotect, vm_remap alias, vm_copy"
        })
        c.append(check("libSystem.B", "signals-sigaction-mask-itimer", timeout: 30) {
            var sa = sigaction(), oldU1 = sigaction(), oldAl = sigaction(), oldU2 = sigaction()
            sa.__sigaction_u.__sa_handler = { _ in more2Sig.add(1, ordering: .relaxed); more2SigThread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed) }
            sa.sa_mask = 0; sa.sa_flags = 0
            try expect(sigaction(SIGUSR1, &sa, &oldU1) == 0, "sigaction")
            defer { sigaction(SIGUSR1, &oldU1, nil) }
            // Swift concurrency / dispatch worker threads block signals: the parts that need delivery run on a pthread
            // with an empty mask (as an app's own thread would)
            func unmasked(_ body: @escaping () -> Void) throws { let t = try more2Thread { var none: sigset_t = 0; pthread_sigmask(SIG_SETMASK, &none, nil); body() }; pthread_join(t, nil) }
            let n0 = more2Sig.load(ordering: .relaxed)
            try unmasked { raise(SIGUSR1) }
            try expect(more2Sig.load(ordering: .relaxed) == n0 + 1, "raise: handler ran \(more2Sig.load(ordering: .relaxed) - n0) times")
            // blocked on a thread: pending until unblocked
            let pend = Atomic<Int>(-1), after = Atomic<Int>(-1)
            let th = try more2Thread {
                var none: sigset_t = 0; pthread_sigmask(SIG_SETMASK, &none, nil)
                var set: sigset_t = 1 << (UInt32(SIGUSR1) - 1), old: sigset_t = 0
                pthread_sigmask(SIG_BLOCK, &set, &old)
                let base = more2Sig.load(ordering: .relaxed)
                pthread_kill(pthread_self(), SIGUSR1)
                var p: sigset_t = 0; sigpending(&p)
                pend.store((p & set) != 0 && more2Sig.load(ordering: .relaxed) == base ? 1 : 0, ordering: .relaxed)
                pthread_sigmask(SIG_SETMASK, &old, nil)
                after.store(more2Sig.load(ordering: .relaxed) - base, ordering: .relaxed)
            }
            pthread_join(th, nil)
            try expect(pend.load(ordering: .relaxed) == 1 && after.load(ordering: .relaxed) == 1, "masked signal pending \(pend.load(ordering: .relaxed)), delivered on unblock \(after.load(ordering: .relaxed))")
            // pthread_kill to another thread: the handler runs on that thread
            let target = Atomic<UInt>(0), stop = Atomic<Bool>(false)
            let t2 = try more2Thread { var none: sigset_t = 0; pthread_sigmask(SIG_SETMASK, &none, nil); target.store(UInt(bitPattern: pthread_self()), ordering: .relaxed); while !stop.load(ordering: .relaxed) { usleep(1000) } }
            _ = await more2Wait(2) { target.load(ordering: .relaxed) != 0 }
            let base2 = more2Sig.load(ordering: .relaxed)
            pthread_kill(t2, SIGUSR1)
            let hit = await more2Wait(2) { more2Sig.load(ordering: .relaxed) > base2 }
            stop.store(true, ordering: .relaxed); pthread_join(t2, nil)
            try expect(hit && more2SigThread.load(ordering: .relaxed) == target.load(ordering: .relaxed), "pthread_kill: ran \(hit) on the target thread \(more2SigThread.load(ordering: .relaxed) == target.load(ordering: .relaxed))")
            // ITIMER_REAL -> SIGALRM after 50 ms
            var al = sigaction(); al.__sigaction_u.__sa_handler = { _ in more2SigAlrm.add(1, ordering: .relaxed) }; al.sa_mask = 0; al.sa_flags = 0
            sigaction(SIGALRM, &al, &oldAl); defer { sigaction(SIGALRM, &oldAl, nil) }
            // (process-directed: the kernel picks any thread that does not block it, so the timer is armed and waited
            // for on a thread with an empty mask; the app's other threads may all block SIGALRM, as seen on Apple's tvOS)
            let a0 = more2SigAlrm.load(ordering: .relaxed), t0 = Date(), itErr = Atomic<Int32>(0)
            let at = try more2Thread {
                var none: sigset_t = 0; pthread_sigmask(SIG_SETMASK, &none, nil)
                var it = itimerval(it_interval: timeval(), it_value: timeval(tv_sec: 0, tv_usec: 50000))
                if setitimer(ITIMER_REAL, &it, nil) != 0 { itErr.store(errno, ordering: .relaxed); return }
                let end = Date().addingTimeInterval(3)
                while more2SigAlrm.load(ordering: .relaxed) == a0 && Date() < end { usleep(5000) }
            }
            pthread_join(at, nil)
            try expect(itErr.load(ordering: .relaxed) == 0, "setitimer errno \(itErr.load(ordering: .relaxed))")
            let fired = more2SigAlrm.load(ordering: .relaxed) > a0
            let el = Date().timeIntervalSince(t0)
            try expect(fired && el > 0.04, "SIGALRM fired \(fired) after \(el) s")
            // a dispatch signal source (EVFILT_SIGNAL) counts SIGUSR2 sent with kill() while the signal is ignored
            var ign = sigaction(); ign.__sigaction_u.__sa_handler = SIG_IGN; ign.sa_mask = 0; ign.sa_flags = 0
            sigaction(SIGUSR2, &ign, &oldU2); defer { sigaction(SIGUSR2, &oldU2, nil) }
            let cnt = Atomic<Int>(0)
            let ds = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .global())
            ds.setEventHandler { cnt.add(Int(ds.data), ordering: .relaxed) }; ds.resume()
            usleep(20000)
            for _ in 0..<3 { kill(getpid(), SIGUSR2); usleep(30000) }
            let got = await more2Wait(3) { cnt.load(ordering: .relaxed) >= 3 }
            ds.cancel()
            try expect(got, "signal source counted \(cnt.load(ordering: .relaxed)) of 3")
            return "raise, masked+pending, pthread_kill to thread, SIGALRM after \(String(format: "%.3f", el)) s, signal source 3"
        })
        #if os(iOS) || os(visionOS)   // mach_msg is unavailable to tvOS / watchOS apps
        c.append(check("libSystem.B", "mach-msg-ool-port-rights", timeout: 30) {
            let task = mach_task_self_
            var rcv: mach_port_t = 0, aux: mach_port_t = 0
            try expect(mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &rcv) == KERN_SUCCESS && mach_port_insert_right(task, rcv, rcv, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS, "port")
            try expect(mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &aux) == KERN_SUCCESS, "aux port")
            defer { mach_port_mod_refs(task, rcv, MACH_PORT_RIGHT_RECEIVE, -1); mach_port_deallocate(task, rcv); mach_port_mod_refs(task, aux, MACH_PORT_RIGHT_RECEIVE, -1) }
            // a complex message: header, body, an out-of-line 256 KB region, a port (make-send of aux), 8 inline bytes
            let oolSize = 262_144
            let ool = UnsafeMutableRawPointer.allocate(byteCount: oolSize, alignment: 16384); defer { ool.deallocate() }
            for i in 0..<oolSize / 4 { ool.storeBytes(of: UInt32(truncatingIfNeeded: i &* 2_654_435_761), toByteOffset: i * 4, as: UInt32.self) }
            let msg = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8); defer { msg.deallocate() }
            memset(msg, 0, 64)
            msg.storeBytes(of: UInt32(MACH_MSG_TYPE_COPY_SEND) | 0x8000_0000, toByteOffset: 0, as: UInt32.self)   // bits: remote COPY_SEND | COMPLEX
            msg.storeBytes(of: UInt32(64), toByteOffset: 4, as: UInt32.self)
            msg.storeBytes(of: rcv, toByteOffset: 8, as: UInt32.self)
            msg.storeBytes(of: Int32(4242), toByteOffset: 20, as: Int32.self)
            msg.storeBytes(of: UInt32(2), toByteOffset: 24, as: UInt32.self)                     // 2 descriptors
            msg.storeBytes(of: UInt64(UInt(bitPattern: ool)), toByteOffset: 28, as: UInt64.self)  // ool address
            msg.storeBytes(of: UInt32(0) | (UInt32(MACH_MSG_VIRTUAL_COPY) << 8) | (UInt32(MACH_MSG_OOL_DESCRIPTOR) << 24), toByteOffset: 36, as: UInt32.self)
            msg.storeBytes(of: UInt32(oolSize), toByteOffset: 40, as: UInt32.self)
            msg.storeBytes(of: aux, toByteOffset: 44, as: UInt32.self)
            msg.storeBytes(of: (UInt32(MACH_MSG_TYPE_MAKE_SEND) << 16) | (UInt32(MACH_MSG_PORT_DESCRIPTOR) << 24), toByteOffset: 52, as: UInt32.self)
            msg.storeBytes(of: 0x0123_4567_89ab_cdef as UInt64, toByteOffset: 56, as: UInt64.self)
            let sr = mach_msg(msg.assumingMemoryBound(to: mach_msg_header_t.self), MACH_SEND_MSG, 64, 0, mach_port_name_t(MACH_PORT_NULL), 0, mach_port_name_t(MACH_PORT_NULL))
            try expect(sr == MACH_MSG_SUCCESS, "send \(String(sr, radix: 16))")
            // queued: one message on the port
            var status = mach_port_status_t(); var cnt = mach_msg_type_number_t(MemoryLayout<mach_port_status_t>.size / MemoryLayout<natural_t>.size)
            let ar = withUnsafeMutablePointer(to: &status) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { mach_port_get_attributes(task, rcv, MACH_PORT_RECEIVE_STATUS, $0, &cnt) } }
            try expect(ar == KERN_SUCCESS && status.mps_msgcount == 1, "queued \(status.mps_msgcount) (\(ar))")
            let rbuf = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8); defer { rbuf.deallocate() }
            memset(rbuf, 0, 512)
            let rr = mach_msg(rbuf.assumingMemoryBound(to: mach_msg_header_t.self), MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 512, rcv, 3000, mach_port_name_t(MACH_PORT_NULL))
            try expect(rr == MACH_MSG_SUCCESS, "receive \(String(rr, radix: 16))")
            let rid = rbuf.loadUnaligned(fromByteOffset: 20, as: Int32.self), ndesc = rbuf.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
            let raddr = rbuf.loadUnaligned(fromByteOffset: 28, as: UInt64.self), rsize = rbuf.loadUnaligned(fromByteOffset: 40, as: UInt32.self)
            let rtype = rbuf.loadUnaligned(fromByteOffset: 36, as: UInt32.self) >> 24
            let rport = rbuf.loadUnaligned(fromByteOffset: 44, as: UInt32.self), pword = rbuf.loadUnaligned(fromByteOffset: 52, as: UInt32.self)
            let inline = rbuf.loadUnaligned(fromByteOffset: 56, as: UInt64.self)
            try expect(rid == 4242 && ndesc == 2 && rtype == UInt32(MACH_MSG_OOL_DESCRIPTOR) && rsize == UInt32(oolSize) && raddr != 0 && raddr != UInt64(UInt(bitPattern: ool)), "received id \(rid) desc \(ndesc) type \(rtype) size \(rsize) addr \(String(raddr, radix: 16))")
            try expect(inline == 0x0123_4567_89ab_cdef, "inline \(String(inline, radix: 16))")
            let rp = UnsafeRawPointer(bitPattern: UInt(raddr))!
            try expect(memcmp(rp, ool, oolSize) == 0, "OOL contents differ")
            vm_deallocate(task, vm_address_t(raddr), vm_size_t(oolSize))
            // the port: a send right (disposition MOVE_SEND on arrival) for aux, which we hold the receive right of -> same name
            var ptype: mach_port_type_t = 0; mach_port_type(task, rport, &ptype)
            try expect(rport == aux && (pword >> 16) & 0xff == UInt32(MACH_MSG_TYPE_MOVE_SEND) && ptype & 0x10000 != 0 && ptype & 0x20000 != 0, "port \(rport) vs \(aux), disposition \((pword >> 16) & 0xff), type \(String(ptype, radix: 16))")
            // use the received send right: a simple message to aux comes back on aux
            memset(msg, 0, 64)
            msg.storeBytes(of: UInt32(MACH_MSG_TYPE_MOVE_SEND), toByteOffset: 0, as: UInt32.self)
            msg.storeBytes(of: UInt32(24), toByteOffset: 4, as: UInt32.self); msg.storeBytes(of: rport, toByteOffset: 8, as: UInt32.self)
            msg.storeBytes(of: Int32(77), toByteOffset: 20, as: Int32.self)
            try expect(mach_msg(msg.assumingMemoryBound(to: mach_msg_header_t.self), MACH_SEND_MSG, 24, 0, 0, 0, 0) == MACH_MSG_SUCCESS, "send via received right")
            memset(rbuf, 0, 512)
            let r2 = mach_msg(rbuf.assumingMemoryBound(to: mach_msg_header_t.self), MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 512, aux, 3000, 0)
            try expect(r2 == MACH_MSG_SUCCESS && rbuf.loadUnaligned(fromByteOffset: 20, as: Int32.self) == 77, "aux receive \(String(r2, radix: 16))")
            // a receive with nothing queued times out
            let t0 = Date(); let r3 = mach_msg(rbuf.assumingMemoryBound(to: mach_msg_header_t.self), MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 512, rcv, 100, 0)
            try expect(r3 == MACH_RCV_TIMED_OUT && Date().timeIntervalSince(t0) > 0.08, "empty receive \(String(r3, radix: 16))")
            return "complex message: 256 KB OOL at a new address, port right moved, inline bytes; reply via the received right; timeout"
        })
        #endif

        // MARK: IPC: NSXPC, libxpc
        c.append(check("Foundation", "nsxpc-anonymous-listener-roundtrip", timeout: 40) {
            let server = More2XPCServer()
            let l = NSXPCListener.anonymous(); l.delegate = server; l.resume()
            defer { l.invalidate() }
            let conn = NSXPCConnection(listenerEndpoint: l.endpoint)
            conn.remoteObjectInterface = NSXPCInterface(with: More2XPCProto.self)
            let invalidated = Atomic<Bool>(false)
            conn.invalidationHandler = { invalidated.store(true, ordering: .relaxed) }
            conn.resume()
            let errs = Mutex<[String]>([])
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ e in errs.withLock { $0.append("\(e)") } }) as? More2XPCProto else { throw Fail("proxy") }
            // 2 MB of data (XPC moves it out of line) both ways
            let big = Data((0..<2_097_152).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 9)) })
            let (back, n): (Data, Int) = try await more2Stage("reverse", 20) { await withCheckedContinuation { k in proxy.reverse(big) { d, n in k.resume(returning: (d, n)) } } }
            try expect(n == big.count && back == Data(big.reversed()), "reverse: \(n) bytes, equal \(back == Data(big.reversed()))")
            let (s, lbl): (Int, String) = try await more2Stage("sum", 10) { await withCheckedContinuation { k in proxy.sum((1...100).map { NSNumber(value: $0) }, label: "x86sim") { a, b in k.resume(returning: (a, b)) } } }
            try expect(s == 5050 && lbl == "X86SIM", "sum \(s) \(lbl)")
            // a synchronous proxy, 50 calls in a row
            guard let sync = conn.synchronousRemoteObjectProxyWithErrorHandler({ e in errs.withLock { $0.append("\(e)") } }) as? More2XPCProto else { throw Fail("sync proxy") }
            var total = 0
            for i in 0..<50 { sync.sum([NSNumber(value: i)], label: "") { v, _ in total += v } }
            try expect(total == 1225, "sync calls total \(total)")
            try expect(errs.withLock { $0.isEmpty } && server.accepted.load(ordering: .relaxed) == 1, "errors \(errs.withLock { $0 }), accepted \(server.accepted.load(ordering: .relaxed))")
            conn.invalidate()
            try expect(await more2Wait(5) { invalidated.load(ordering: .relaxed) }, "invalidation handler")
            return "anonymous listener: 2 MB round trip, 50 sync calls, invalidation"
        })
        c.append(check("libSystem.B", "xpc-anonymous-dictionary-shmem-fd", timeout: 40) {
            // libxpc: an anonymous listener, a peer connected through its endpoint; a dictionary with scalars, an
            // array, 1 MB of shared memory and a file descriptor goes over and its reply comes back
            let q = DispatchQueue(label: "sdkcov.xpc")
            let listener = xpc_connection_create(nil, q)
            let peers = Mutex<[xpc_connection_t]>([])
            xpc_connection_set_event_handler(listener) { peer in
                guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
                peers.withLock { $0.append(peer) }
                xpc_connection_set_event_handler(peer) { m in
                    guard xpc_get_type(m) == XPC_TYPE_DICTIONARY else { return }
                    let r = xpc_dictionary_create_reply(m)!
                    var region: UnsafeMutableRawPointer?
                    let shm = xpc_dictionary_get_value(m, "shm")
                    let sz = shm.map { xpc_shmem_map($0, &region) } ?? 0
                    var sum: UInt64 = 0
                    if let region { for i in stride(from: 0, to: sz, by: 4096) { sum &+= UInt64(region.load(fromByteOffset: i, as: UInt8.self)) }; munmap(region, sz) }
                    let fd = xpc_dictionary_dup_fd(m, "fd")
                    var fb = [UInt8](repeating: 0, count: 16); let fn = fd >= 0 ? pread(fd, &fb, 16, 0) : -1; if fd >= 0 { close(fd) }
                    xpc_dictionary_set_int64(r, "n", xpc_dictionary_get_int64(m, "n") * 2)
                    xpc_dictionary_set_string(r, "s", String(cString: xpc_dictionary_get_string(m, "s")!).uppercased())
                    xpc_dictionary_set_uint64(r, "shmsum", sum); xpc_dictionary_set_uint64(r, "shmsize", UInt64(sz))
                    xpc_dictionary_set_string(r, "file", String(decoding: fb.prefix(max(0, fn)), as: UTF8.self))
                    xpc_dictionary_set_uint64(r, "arr", UInt64(xpc_array_get_count(xpc_dictionary_get_value(m, "arr")!)))
                    xpc_connection_send_message(peer, r)
                }
                xpc_connection_resume(peer)
            }
            xpc_connection_resume(listener)
            defer { xpc_connection_cancel(listener); peers.withLock { $0.forEach { xpc_connection_cancel($0) } } }
            let client = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
            xpc_connection_set_event_handler(client) { _ in }
            xpc_connection_resume(client)
            defer { xpc_connection_cancel(client) }
            let m = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_int64(m, "n", 21); xpc_dictionary_set_string(m, "s", "x86sim")
            let arr = xpc_array_create(nil, 0); for i in 0..<10 { xpc_array_append_value(arr, xpc_int64_create(Int64(i))) }
            xpc_dictionary_set_value(m, "arr", arr)
            let sz = 1 << 20
            guard let reg = mmap(nil, sz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0), reg != MAP_FAILED else { throw Fail("mmap") }
            defer { munmap(reg, sz) }
            for i in stride(from: 0, to: sz, by: 4096) { reg.storeBytes(of: UInt8(truncatingIfNeeded: i >> 12), toByteOffset: i, as: UInt8.self) }
            xpc_dictionary_set_value(m, "shm", xpc_shmem_create(reg, sz))
            let f = try more2Dir("xpcfd").appendingPathComponent("f"); try Data("xpc fd ok".utf8).write(to: f)
            let fd = open(f.path, O_RDONLY); defer { close(fd) }
            xpc_dictionary_set_fd(m, "fd", fd)
            let reply: xpc_object_t = try await more2Stage("xpc reply", 20) {
                await withCheckedContinuation { k in xpc_connection_send_message_with_reply(client, m, q) { r in k.resume(returning: r) } }
            }
            guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { throw Fail("reply is \(String(cString: xpc_copy_description(reply)))") }
            let expectSum = (0..<256).reduce(UInt64(0)) { $0 + UInt64($1) }
            let n = xpc_dictionary_get_int64(reply, "n"), s = String(cString: xpc_dictionary_get_string(reply, "s")!)
            let ss = xpc_dictionary_get_uint64(reply, "shmsum"), ssz = xpc_dictionary_get_uint64(reply, "shmsize")
            let file = String(cString: xpc_dictionary_get_string(reply, "file")!), ac = xpc_dictionary_get_uint64(reply, "arr")
            try expect(n == 42 && s == "X86SIM" && ac == 10, "scalars \(n) \(s) \(ac)")
            try expect(ssz >= UInt64(sz) && ss == expectSum, "shmem size \(ssz) sum \(ss) (want \(expectSum))")
            try expect(file == "xpc fd ok", "fd read \(file)")
            return "anonymous libxpc: scalars, array, 1 MB shmem, fd"
        })

        // MARK: files
        c.append(check("Foundation", "filemanager-links-attrs-copy-enumerate") {
            let fm = FileManager.default, d = try more2Dir("fm")
            try fm.createDirectory(at: d.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
            for i in 0..<12 { try Data("f\(i)".utf8).write(to: d.appendingPathComponent(["a", "a/b", "a/b/c"][i % 3] + "/f\(i).txt")) }
            try Data("h".utf8).write(to: d.appendingPathComponent("a/.hidden"))
            let all = fm.enumerator(at: d, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects.count
            let vis = fm.enumerator(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!.allObjects.count
            let shallow = try fm.contentsOfDirectory(at: d.appendingPathComponent("a"), includingPropertiesForKeys: nil).count
            try expect(all == 16 && vis == 15 && shallow == 6, "enumerate all \(all) visible \(vis) shallow \(shallow)")
            // symbolic and hard links
            let f0 = d.appendingPathComponent("a/f0.txt"), sl = d.appendingPathComponent("link"), hl = d.appendingPathComponent("hard")
            try fm.createSymbolicLink(at: sl, withDestinationURL: f0)
            try expect(try fm.destinationOfSymbolicLink(atPath: sl.path) == f0.path && (try fm.attributesOfItem(atPath: sl.path)[.type] as? FileAttributeType) == .typeSymbolicLink, "symlink")
            try expect(try String(contentsOf: sl, encoding: .utf8) == "f0" && sl.resolvingSymlinksInPath().lastPathComponent == "f0.txt", "read via symlink")
            try fm.linkItem(at: f0, to: hl)
            var st = stat(); stat(f0.path, &st)
            let id1 = try f0.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            let id2 = try hl.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            try expect(st.st_nlink == 2 && id1 != nil && id1 == id2, "hard link nlink \(st.st_nlink) ids \(String(describing: id1)) \(String(describing: id2))")
            // permissions and dates round trip
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try fm.setAttributes([.posixPermissions: 0o640, .modificationDate: date], ofItemAtPath: f0.path)
            let at = try fm.attributesOfItem(atPath: f0.path)
            try expect((at[.posixPermissions] as? Int) == 0o640 && (at[.modificationDate] as? Date) == date, "attrs \(String(describing: at[.posixPermissions])) \(String(describing: at[.modificationDate]))")
            // copy (APFS clones on Apple) of 3 MB, then move and remove a tree
            let big = d.appendingPathComponent("big.bin"), cp = d.appendingPathComponent("big2.bin")
            try Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }).write(to: big)
            try fm.copyItem(at: big, to: cp)
            try expect(fm.contentsEqual(atPath: big.path, andPath: cp.path), "copy differs")
            let rv = try cp.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey])
            try expect(rv.fileSize == 3_000_000 && rv.isRegularFile == true && (rv.totalFileAllocatedSize ?? 0) >= 3_000_000, "copy values \(String(describing: rv.fileSize)) alloc \(String(describing: rv.totalFileAllocatedSize))")
            try fm.moveItem(at: d.appendingPathComponent("a/b"), to: d.appendingPathComponent("moved"))
            try expect(fm.fileExists(atPath: d.appendingPathComponent("moved/c/f2.txt").path) && !fm.fileExists(atPath: d.appendingPathComponent("a/b").path), "move tree")
            try fm.removeItem(at: d.appendingPathComponent("moved"))
            // a bookmark follows its file through a rename
            let bm = try f0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let renamed = d.appendingPathComponent("a/renamed.txt"); try fm.moveItem(at: f0, to: renamed)
            var stale = false
            let res = try URL(resolvingBookmarkData: bm, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            try expect(res.lastPathComponent == "renamed.txt", "bookmark resolved to \(res.path) stale \(stale)")
            var sfs = statfs(); statfs(d.path, &sfs)
            let fsname = withUnsafeBytes(of: sfs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return "enumerate 16/15, symlink, hard link, attrs, 3 MB copy, move, bookmark (stale \(stale)), fs \(fsname)"
        })
        c.append(check("Foundation", "filehandle-locks-streams-presenter", timeout: 40) {
            let d = try more2Dir("fh"), f = d.appendingPathComponent("h.bin")
            try Data(count: 0).write(to: f)
            let h = try FileHandle(forUpdating: f)
            try h.write(contentsOf: Data("0123456789".utf8)); try h.seek(toOffset: 4); try h.write(contentsOf: Data("ab".utf8))
            try h.truncate(atOffset: 8); try h.synchronize(); try h.seek(toOffset: 0)
            let all = try h.readToEnd().map { String(decoding: $0, as: UTF8.self) }
            try expect(all == "0123ab67" && (try h.offset()) == 8, "FileHandle \(String(describing: all))")
            try h.close()
            // flock is per open file: a second open cannot take the exclusive lock; fcntl byte-range lock info
            let fd1 = open(f.path, O_RDWR), fd2 = open(f.path, O_RDWR); defer { close(fd1); close(fd2) }
            try expect(flock(fd1, LOCK_EX | LOCK_NB) == 0, "flock 1")
            let r2 = flock(fd2, LOCK_EX | LOCK_NB), e2 = errno
            flock(fd1, LOCK_UN)
            try expect(r2 == -1 && e2 == EWOULDBLOCK && flock(fd2, LOCK_EX | LOCK_NB) == 0, "flock 2 \(r2) errno \(e2)")
            flock(fd2, LOCK_UN)
            var fl = flock(); fl.l_type = Int16(F_WRLCK); fl.l_whence = Int16(SEEK_SET); fl.l_start = 0; fl.l_len = 4
            try expect(fcntl(fd1, F_SETLK, &fl) == 0, "fcntl F_SETLK errno \(errno)")
            fl.l_type = Int16(F_UNLCK); _ = fcntl(fd1, F_SETLK, &fl)
            // a pipe's readabilityHandler
            let p = Pipe(), got = Mutex(Data())
            p.fileHandleForReading.readabilityHandler = { fh in let d = fh.availableData; got.withLock { $0.append(d) } }
            for i in 0..<5 { p.fileHandleForWriting.write(Data("chunk\(i);".utf8)); usleep(5000) }
            let ok = await more2Wait(5) { got.withLock { $0.count } >= 35 }
            p.fileHandleForReading.readabilityHandler = nil
            try expect(ok && got.withLock { String(decoding: $0, as: UTF8.self) } == "chunk0;chunk1;chunk2;chunk3;chunk4;", "readabilityHandler \(got.withLock { String(decoding: $0, as: UTF8.self) })")
            // bound stream pair: 1 MB through a 4 KB buffer, writer on its own thread
            var ins: InputStream?, outs: OutputStream?
            Stream.getBoundStreams(withBufferSize: 4096, inputStream: &ins, outputStream: &outs)
            guard let ins, let outs else { throw Fail("bound streams") }
            ins.open(); outs.open()
            let payload = (0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
            let wt = Thread { var off = 0; payload.withUnsafeBufferPointer { b in while off < b.count { let n = outs.write(b.baseAddress! + off, maxLength: min(8192, b.count - off)); if n <= 0 { break }; off += n } }; outs.close() }
            wt.start()
            var rx = [UInt8](); rx.reserveCapacity(payload.count); var buf = [UInt8](repeating: 0, count: 16384)
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 20 { let n = ins.read(&buf, maxLength: buf.count); if n <= 0 { break }; rx.append(contentsOf: buf[0..<n]) }
            ins.close()
            try expect(rx == payload, "bound streams moved \(rx.count) of \(payload.count)")
            // NSFilePresenter: another coordinator's write and move reach the presenter
            let pf = d.appendingPathComponent("presented.txt"); try Data("v1".utf8).write(to: pf)
            let pres = More2Presenter(pf); NSFileCoordinator.addFilePresenter(pres); defer { NSFileCoordinator.removeFilePresenter(pres) }
            var err: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: pf, options: [], error: &err) { u in try? Data("v2".utf8).write(to: u) }
            try expect(err == nil, "coordinated write \(String(describing: err))")
            let changed = await more2Wait(10) { pres.events.withLock { $0.contains("change") } }
            let dst = d.appendingPathComponent("moved.txt")
            let mc = NSFileCoordinator(filePresenter: nil)
            mc.coordinate(writingItemAt: pf, options: .forMoving, writingItemAt: dst, options: .forReplacing, error: &err) { s, t in
                try? FileManager.default.moveItem(at: s, to: t); mc.item(at: s, didMoveTo: t)
            }
            let moved = await more2Wait(10) { pres.events.withLock { $0.contains("move:moved.txt") } }
            try expect(changed && moved, "presenter events \(pres.events.withLock { $0 }) (change \(changed), move \(moved))")
            return "FileHandle, flock/fcntl, readabilityHandler, 1 MB bound streams, presenter \(pres.events.withLock { $0 })"
        })

        // MARK: Security, CryptoKit
        c.append(check("Security", "keychain-update-query-persistent-keys") {
            let svc = "com.x86sim.test.sdkcov.more2"
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc] as CFDictionary)
            for i in 0..<3 {
                let st = SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc, kSecAttrAccount as String: "acct\(i)",
                                     kSecAttrLabel as String: "label \(i)", kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                     kSecValueData as String: Data("pw\(i)".utf8)] as CFDictionary, nil)
                try expect(st == errSecSuccess, "add \(i): \(st)")
            }
            let dup = SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc, kSecAttrAccount as String: "acct0", kSecValueData as String: Data()] as CFDictionary, nil)
            try expect(dup == errSecDuplicateItem, "duplicate add \(dup)")
            var r: CFTypeRef?
            let qs = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc, kSecMatchLimit as String: kSecMatchLimitAll,
                                          kSecReturnAttributes as String: true] as CFDictionary, &r)
            let rows = (r as? [[String: Any]]) ?? []
            try expect(qs == errSecSuccess && rows.count == 3 && Set(rows.compactMap { $0[kSecAttrAccount as String] as? String }) == ["acct0", "acct1", "acct2"], "query all \(qs) \(rows.count)")
            try expect(rows.allSatisfy { ($0[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleAfterFirstUnlock as String) }, "accessible \(rows.map { $0[kSecAttrAccessible as String] ?? "-" })")
            let us = SecItemUpdate([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc, kSecAttrAccount as String: "acct1"] as CFDictionary,
                                   [kSecValueData as String: Data("changed".utf8), kSecAttrComment as String: "x86sim"] as CFDictionary)
            try expect(us == errSecSuccess, "update \(us)")
            var pr: CFTypeRef?
            _ = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc, kSecAttrAccount as String: "acct1", kSecReturnPersistentRef as String: true] as CFDictionary, &pr)
            guard let pref = pr as? Data else { throw Fail("persistent ref") }
            var v: CFTypeRef?
            let ps = SecItemCopyMatching([kSecValuePersistentRef as String: pref, kSecReturnData as String: true, kSecReturnAttributes as String: true] as CFDictionary, &v)
            let vd = v as? [String: Any]
            try expect(ps == errSecSuccess && (vd?[kSecValueData as String] as? Data) == Data("changed".utf8) && (vd?[kSecAttrComment as String] as? String) == "x86sim", "by persistent ref \(ps)")
            let ds = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc] as CFDictionary)
            var none: CFTypeRef?
            try expect(ds == errSecSuccess && SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc] as CFDictionary, &none) == errSecItemNotFound, "delete all \(ds)")
            // internet password with server/port/protocol attributes
            let ip: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: "sdkcov.example", kSecAttrPort as String: 8443,
                                     kSecAttrProtocol as String: kSecAttrProtocolHTTPS, kSecAttrAccount as String: "u"]
            SecItemDelete(ip as CFDictionary)
            var ipa = ip; ipa[kSecValueData as String] = Data("ipw".utf8)
            try expect(SecItemAdd(ipa as CFDictionary, nil) == errSecSuccess, "internet password add")
            var iq = ip; iq[kSecReturnData as String] = true; var ir: CFTypeRef?
            try expect(SecItemCopyMatching(iq as CFDictionary, &ir) == errSecSuccess && (ir as? Data) == Data("ipw".utf8), "internet password read")
            SecItemDelete(ip as CFDictionary)
            // a permanent P-256 key, found again by its tag, signs; RSA-2048 encrypts/decrypts
            let tag = Data("com.x86sim.sdkcov.more2.key".utf8)
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
            var e: Unmanaged<CFError>?
            guard SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
                                         kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag]] as CFDictionary, &e) != nil else { throw Fail("permanent key \(String(describing: e?.takeRetainedValue()))") }
            var kr: CFTypeRef?
            let ks = SecItemCopyMatching([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecReturnRef as String: true] as CFDictionary, &kr)
            guard ks == errSecSuccess, let kref = kr else { throw Fail("key by tag \(ks)") }
            let key = kref as! SecKey
            let msg = Data("x86sim keychain key".utf8) as CFData
            guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, msg, &e), let pub = SecKeyCopyPublicKey(key),
                  SecKeyVerifySignature(pub, .ecdsaSignatureMessageX962SHA256, msg, sig, &e) else { throw Fail("stored key sign/verify") }
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
            guard let rsa = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048] as CFDictionary, &e),
                  let rpub = SecKeyCopyPublicKey(rsa),
                  let ct = SecKeyCreateEncryptedData(rpub, .rsaEncryptionOAEPSHA256, Data("secret".utf8) as CFData, &e),
                  let pt = SecKeyCreateDecryptedData(rsa, .rsaEncryptionOAEPSHA256, ct, &e) else { throw Fail("RSA \(String(describing: e?.takeRetainedValue()))") }
            try expect(pt as Data == Data("secret".utf8) && (ct as Data).count == 256, "RSA-OAEP")
            let ext = SecKeyCopyExternalRepresentation(rpub, &e) as Data?
            try expect(ext != nil && SecKeyCreateWithData(ext! as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary, &e) != nil, "RSA public key import")
            return "3 items query/update/persistent ref/delete, internet password, permanent EC key by tag, RSA-2048 OAEP"
        })
        c.append(check("Security", "pkcs12-certificates-trust-evaluation") {
            let (id, chain) = try More2TLS.identity()
            var cert: SecCertificate?; SecIdentityCopyCertificate(id, &cert)
            var pk: SecKey?; SecIdentityCopyPrivateKey(id, &pk)
            guard let cert, let pk else { throw Fail("identity parts") }
            try expect(SecCertificateCopySubjectSummary(cert) as String? == "localhost" && SecCertificateCopyData(cert) as Data == More2TLS.leafDER, "leaf \(String(describing: SecCertificateCopySubjectSummary(cert)))")
            try expect(chain.count == 2, "chain \(chain.count)")
            // the identity's private key signs, the certificate's public key verifies
            var e: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(pk, .ecdsaSignatureMessageX962SHA256, Data("p12".utf8) as CFData, &e), let pub = SecCertificateCopyKey(cert),
                  SecKeyVerifySignature(pub, .ecdsaSignatureMessageX962SHA256, Data("p12".utf8) as CFData, sig, &e) else { throw Fail("p12 key sign/verify") }
            guard let ca = SecCertificateCreateWithData(nil, More2TLS.caDER as CFData), let leaf = SecCertificateCreateWithData(nil, More2TLS.leafDER as CFData) else { throw Fail("DER parse") }
            var cn: CFString?; SecCertificateCopyCommonName(ca, &cn)
            try expect(cn as String? == "x86sim sdkcov CA", "CA CN \(String(describing: cn))")
            let serial = SecCertificateCopySerialNumberData(leaf, nil) as Data?
            try expect((serial?.count ?? 0) >= 16, "serial \(String(describing: serial))")
            func evaluate(_ policy: SecPolicy, anchors: [SecCertificate]?) -> (Bool, String) {
                var t: SecTrust?; SecTrustCreateWithCertificates([leaf, ca] as CFArray, policy, &t)
                guard let t else { return (false, "no trust") }
                if let anchors { SecTrustSetAnchorCertificates(t, anchors as CFArray); SecTrustSetAnchorCertificatesOnly(t, true) }
                SecTrustSetVerifyDate(t, Date().addingTimeInterval(86400 * 365) as CFDate)
                SecTrustSetNetworkFetchAllowed(t, false)
                var err: CFError?; let ok = SecTrustEvaluateWithError(t, &err)
                return (ok, err.map { "\(CFErrorGetCode($0))" } ?? "")
            }
            let (okBasic, eb) = evaluate(SecPolicyCreateBasicX509(), anchors: [ca])
            let (okSSL, es) = evaluate(SecPolicyCreateSSL(true, "localhost" as CFString), anchors: [ca])
            let (okWrongHost, _) = evaluate(SecPolicyCreateSSL(true, "example.com" as CFString), anchors: [ca])
            let (okNoAnchor, _) = evaluate(SecPolicyCreateBasicX509(), anchors: nil)
            try expect(okBasic, "basic X.509 with the CA as anchor failed: \(eb)")
            try expect(!okWrongHost && !okNoAnchor, "wrong host \(okWrongHost), no anchor \(okNoAnchor) should fail")
            return "PKCS#12 identity + chain, sign/verify, trust: basic \(okBasic), SSL localhost \(okSSL)\(es.isEmpty ? "" : " (\(es))"), wrong host refused, unanchored refused"
        })
        #if canImport(CryptoKit)
        c.append(check("CryptoKit", "vectors-hpke-keyformats-security-interop") {
            // RFC 5869 test case 1 (HKDF-SHA256)
            let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: unhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")), salt: unhex("000102030405060708090a0b0c"),
                                             info: unhex("f0f1f2f3f4f5f6f7f8f9"), outputByteCount: 42).withUnsafeBytes { Data($0) }
            try expect(hex(okm) == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", "HKDF \(hex(okm))")
            // RFC 4231 test case 2 (HMAC-SHA256), SHA-384/512 of "abc", Insecure.MD5
            let mac = HMAC<SHA256>.authenticationCode(for: Data("what do ya want for nothing?".utf8), using: SymmetricKey(data: Data("Jefe".utf8)))
            try expect(hex(mac) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC \(hex(mac))")
            try expect(hex(SHA384.hash(data: Data("abc".utf8))).hasPrefix("cb00753f45a35e8bb5a03d699ac65007") && hex(SHA512.hash(data: Data("abc".utf8))).hasPrefix("ddaf35a193617aba") && hex(Insecure.MD5.hash(data: Data("abc".utf8))) == "900150983cd24fb0d6963f7d28e17f72", "SHA-2/MD5")
            // AES-GCM with a fixed key/nonce (NIST GCM test case 3 prefix check: deterministic ciphertext)
            let k = SymmetricKey(data: unhex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"))
            let box = try AES.GCM.seal(unhex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"), using: k, nonce: try AES.GCM.Nonce(data: unhex("cafebabefacedbaddecaf888")))
            try expect(hex(box.ciphertext).hasPrefix("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa") && hex(box.tag) == "b094dac5d93471bdec1a502270e3cc6c", "AES-256-GCM vector \(hex(box.ciphertext).prefix(16)) tag \(hex(box.tag))")
            // AES key wrap (RFC 3394 4.1)
            let wrapped = try AES.KeyWrap.wrap(SymmetricKey(data: unhex("00112233445566778899AABBCCDDEEFF")), using: SymmetricKey(data: unhex("000102030405060708090A0B0C0D0E0F")))
            try expect(hex(wrapped) == "1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5", "key wrap \(hex(wrapped))")
            // HPKE (P-256, SHA-256, AES-GCM-128) seal / open with associated data
            let rk = P256.KeyAgreement.PrivateKey()
            var sender = try HPKE.Sender(recipientKey: rk.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: Data("sdkcov".utf8))
            let ct = try sender.seal(Data("hpke message".utf8), authenticating: Data("aad".utf8))
            var recipient = try HPKE.Recipient(privateKey: rk, ciphersuite: .P256_SHA256_AES_GCM_256, info: Data("sdkcov".utf8), encapsulatedKey: sender.encapsulatedKey)
            try expect(try recipient.open(ct, authenticating: Data("aad".utf8)) == Data("hpke message".utf8), "HPKE")
            // key formats: PEM / DER / x963 / raw round trips; Ed25519 deterministic signature length
            let sk = P256.Signing.PrivateKey()
            try expect(try P256.Signing.PrivateKey(pemRepresentation: sk.pemRepresentation).rawRepresentation == sk.rawRepresentation
                       && (try P256.Signing.PublicKey(derRepresentation: sk.publicKey.derRepresentation)) .rawRepresentation == sk.publicKey.rawRepresentation, "PEM/DER")
            let ed = Curve25519.Signing.PrivateKey(); let es = try ed.signature(for: Data("m".utf8))
            try expect(es.count == 64 && ed.publicKey.isValidSignature(es, for: Data("m".utf8)), "Ed25519")
            // CryptoKit key -> Security: SecKey from x963 verifies a CryptoKit DER signature
            var e: Unmanaged<CFError>?
            guard let sec = SecKeyCreateWithData(sk.publicKey.x963Representation as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary, &e) else { throw Fail("SecKeyCreateWithData") }
            let sig = try sk.signature(for: Data("interop".utf8))
            try expect(SecKeyVerifySignature(sec, .ecdsaSignatureMessageX962SHA256, Data("interop".utf8) as CFData, sig.derRepresentation as CFData, &e), "Security verifies CryptoKit signature")
            let se = SecureEnclave.isAvailable
            return "HKDF/HMAC/SHA/AES-GCM/KeyWrap vectors, HPKE, PEM/DER, Ed25519, Security interop, Secure Enclave available \(se)"
        })
        #endif
        return c
    }
}
