import AppKit
import FACore
import SwiftUI

struct NotesPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.notesTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Picker("Mode", selection: $model.notesMode) {
                    Image(systemName: "eye").help("Preview").tag(MarkyView.Mode.preview.rawValue)
                    Image(systemName: "rectangle.split.2x1").help("Edit and preview").tag(MarkyView.Mode.split.rawValue)
                    Image(systemName: "pencil").help("Edit").tag(MarkyView.Mode.editor.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { model.revealNotes() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Show this file in Finder")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            MarkyHost(view: model.marky)
        }
    }
}

struct MarkyHost: NSViewRepresentable {
    let view: MarkyView

    func makeNSView(context: Context) -> MarkyView { view }
    func updateNSView(_ nsView: MarkyView, context: Context) {}
}
