import FACore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: AppModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        if let h = model.selected {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.label(h.page)).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(h.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                if h.highlightColor != .noteOnly {
                    HStack(spacing: 10) {
                        ForEach(HighlightColor.highlightColors, id: \.self) { c in
                            Button { model.applyColor(c) } label: {
                                Circle()
                                    .fill(swatch(c))
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if h.highlightColor == c { Image(systemName: "checkmark").font(.caption.bold()) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(c.name.capitalized)
                        }
                    }
                }
                Text("Note").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.noteDraft)
                    .focused($noteFocused)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 120)
                    .border(Color.secondary.opacity(0.3))
                    .onChange(of: noteFocused) {
                        model.noteFocused = noteFocused
                        if !noteFocused { model.flushNote() }
                    }
                    .onChange(of: model.noteFocusTick) { noteFocused = true }
                Button("Save note") { model.flushNote() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .controlSize(.small)
                let tags = Tags.parse(model.noteDraft)
                if !tags.isEmpty {
                    Text(tags.map { "#\($0)" }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                    Spacer()
                    Button("Done") { model.select(nil) }
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }
}
