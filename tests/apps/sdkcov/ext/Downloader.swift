// sdkcov Background Assets downloader extension (iOS, tvOS, visionOS: <app>/Extensions/sdkcovDownloader.appex,
// com.apple.background-asset-downloader-extension): AssetPackManager traps in an app with BAAppGroupID that has none
// ("The app lacks a Background Assets downloader extension", Apple's simulator too). Apple-hosted (managed) asset packs:
// the protocol's defaults do the work; it only marks its launches (Marks.swift).
import Foundation
import BackgroundAssets
import ExtensionFoundation

@main
struct SDKCovDownloader: ManagedDownloaderExtension {
    init() { sdkcovMark("downloader-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        sdkcovMark("downloader-should", assetPack.id)
        return true
    }
}
