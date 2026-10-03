import FACore
import SwiftUI

/// The note editor that opens under a highlight.
struct InspectorView: View {
    @ObservedObject var model: AppModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        if let h = model.selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(swatch(h.highlightColor)).frame(width: 10, height: 10)
                    Text(model.label(h.page)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { model.select(nil) }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                }
                Text(h.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextEditor(text: $model.noteDraft)
                    .focused($noteFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                    .frame(minHeight: 70, maxHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if model.noteDraft.isEmpty {
                            Text("Note. Use #tags to group highlights.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: noteFocused) {
                        model.noteFocused = noteFocused
                        if !noteFocused { model.flushNote() }
                    }
                    .onChange(of: model.noteFocusTick) { noteFocused = true }
                HStack {
                    let tags = Tags.parse(model.noteDraft)
                    if !tags.isEmpty {
                        Text(tags.map { "#\($0)" }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Note") { model.flushNote() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .controlSize(.small)
                        .disabled(model.noteDraft == h.note)
                }
            }
            .padding(12)
        }
    }
}
