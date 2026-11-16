// sdkcov extensions (build.sh embeds them in the app): what an extension did, written where the app can read it back.
// Each event appends a line "<time> <text>" to <App Group container>/p3marks/<name> (the app and every extension
// carry the group.com.x86sim.test.sdkcov App Group); checks/P3_Extensions.swift reads them (p3Marks).
import Foundation

let sdkcovGroup = "group.com.x86sim.test.sdkcov"

func sdkcovMark(_ name: String, _ text: String) {
    guard let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sdkcovGroup) else { return }
    let dir = g.appendingPathComponent("p3marks", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent(name)
    let line = Data("\(Date().timeIntervalSince1970) \(text)\n".utf8)
    if let h = try? FileHandle(forWritingTo: f) { _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close() }
    else { try? line.write(to: f) }
}
