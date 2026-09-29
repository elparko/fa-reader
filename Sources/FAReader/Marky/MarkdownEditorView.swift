import SwiftUI

/// SwiftUI wrapper around MarkyView.
///
///     @State var markdown = "# Hello"
///     MarkdownEditorView(text: $markdown, mode: .split, baseURL: folderURL)
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var mode: MarkyView.Mode = .preview
    var baseURL: URL? = nil
    var fontSize: CGFloat = Theme.defaultFontSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkyView {
        let view = MarkyView()
        view.fontSize = fontSize
        view.baseURL = baseURL
        view.text = text
        view.mode = mode
        context.coordinator.lastText = text
        view.onTextChange = { [weak view, coordinator = context.coordinator] in
            guard let view else { return }
            coordinator.lastText = view.text
            coordinator.parent.text = coordinator.lastText
        }
        return view
    }

    func updateNSView(_ view: MarkyView, context: Context) {
        context.coordinator.parent = self
        if view.fontSize != fontSize { view.fontSize = fontSize }
        if view.baseURL != baseURL { view.baseURL = baseURL }
        if view.mode != mode { view.mode = mode }
        // Only push text that came from outside (e.g. a new file was loaded),
        // not the echo of the user's own typing.
        if text != context.coordinator.lastText {
            context.coordinator.lastText = text
            view.text = text
        }
    }

    final class Coordinator {
        var parent: MarkdownEditorView
        var lastText = ""
        init(_ parent: MarkdownEditorView) { self.parent = parent }
    }
}
