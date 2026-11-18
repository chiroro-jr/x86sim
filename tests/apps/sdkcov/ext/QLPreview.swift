// sdkcov Quick Look preview extension (iOS, visionOS: <app>/PlugIns/sdkcovQLPreview.appex, com.apple.quicklook.preview):
// previews the app's own document type com.x86sim.test.sdkcov.qlsample (*.sdkcovql, declared by the app) as a label
// with the file's text. checks/P19_Gaps.swift opens such a file in a QLPreviewController and reads the marks.
import UIKit
import QuickLook

@objc(SDKCovQLPreview)
final class SDKCovQLPreview: UIViewController, QLPreviewingController {
    private let label = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        label.frame = view.bounds; label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; label.textAlignment = .center
        view.addSubview(label)
        sdkcovMark("qlpreview-load", "view loaded")
    }
    func preparePreviewOfFile(at url: URL) async throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
        sdkcovMark("qlpreview-prepare", "\(url.lastPathComponent) \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        label.text = text
    }
}
