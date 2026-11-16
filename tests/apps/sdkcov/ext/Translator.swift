// sdkcov translation provider extension (iOS: <app>/Extensions/sdkcovTranslator.appex,
// com.apple.public.translation-ui-provider): a third-party translation UI for selected text (the system's "Translate"
// menu when the user picks it as the default translator). checks/P10_Extensions.swift finds it on the extension point.
import SwiftUI
import ExtensionFoundation
import ExtensionKit
import TranslationUIProvider

struct SDKCovTranslatorView: View {
    let context: any TranslationUIProviderContext
    var body: some View {
        let text = context.inputText.map { String($0.characters) } ?? ""
        let _ = sdkcovMark("translator-view", "\(text.count) characters, replacement \(context.allowsReplacement)")
        VStack {
            Text("sdkcov: \(text)")
            Button("Done") { context.finish(translation: AttributedString(text.uppercased())) }
        }
    }
}

@main
struct SDKCovTranslator: TranslationUIProviderExtension {
    init() { sdkcovMark("translator-launch", "pid \(ProcessInfo.processInfo.processIdentifier)") }
    var body: some TranslationUIProviderExtensionScene {
        TranslationUIProviderSelectedTextScene { context in SDKCovTranslatorView(context: context) }
    }
}
