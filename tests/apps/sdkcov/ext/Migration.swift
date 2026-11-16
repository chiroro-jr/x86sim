// sdkcov app migration extension (iOS: <app>/Extensions/sdkcovMigration.appex, com.apple.app-migration): exports one
// file (sdkcov-migration.txt) and imports what it is given. checks/P10_Extensions.swift drives it with
// AppMigrationTester (export, then import of the exported resources) and reads its marks.
import Foundation
import ExtensionFoundation
import AppMigrationKit

@main
struct SDKCovMigration: ResourcesExporting, ResourcesImporting {
    init() { sdkcovMark("migration-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    func exportResources(to archiver: sending ResourcesArchiver, request: MigrationRequest) async throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-migration.txt")
        try Data("sdkcov migration".utf8).write(to: f)
        try await archiver.appendItem(at: f, pathInArchive: "sdkcov-migration.txt")
        sdkcovMark("migration-export", "\(request.destinationPlatform.rawValue)")
    }
    var resourcesSizeEstimate: Int { get async { 16 } }
    var resourcesVersion: String { "1" }
    var resourcesCompressible: Bool { false }
    func importResources(at url: URL, request: ResourcesImportRequest) async throws {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        sdkcovMark("migration-import", "\(request.sourceAppIdentifier.bundleIdentifier) \(request.sourceVersion) \(names)")
    }
    var resourcesImportProgress: Progress { Progress(totalUnitCount: 1) }
}
