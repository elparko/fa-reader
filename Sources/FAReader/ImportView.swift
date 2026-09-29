import FACore
import SwiftUI

struct ImportView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var includedBursts: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import from Preview").font(.headline)
            if let preview = model.importPreview {
                content(preview)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scanning annotations")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { includedBursts = [] }
    }

    private func content(_ preview: ImportPreview) -> some View {
        let notes = preview.candidates.filter { $0.highlight.highlightColor == .noteOnly }.count
        let already = preview.candidates.filter(\.alreadyImported).count
        let highlights = preview.candidates.count - notes
        let selected = preview.selected(includingBursts: includedBursts)
        let selectedIDs = Set(selected.map(\.id))
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(highlights) highlights, \(notes) notes, \(already) already imported")
            if !preview.bursts.isEmpty {
                Text("Groups made within a few seconds of each other (excluded unless checked)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(preview.bursts) { b in
                    Toggle(isOn: Binding(
                        get: { includedBursts.contains(b.id) },
                        set: { if $0 { includedBursts.insert(b.id) } else { includedBursts.remove(b.id) } }
                    )) {
                        Text("\(b.start.formatted(date: .abbreviated, time: .standard)) to \(b.end.formatted(date: .omitted, time: .standard)), \(b.count) items on \(b.pages) pages")
                    }
                }
            }
            Table(preview.candidates) {
                TableColumn("Page") { c in Text(model.label(c.raw.page)) }.width(70)
                TableColumn("Type") { c in Text(c.raw.type) }.width(80)
                TableColumn("Color") { c in
                    Circle().fill(swatch(c.raw.color)).frame(width: 10, height: 10)
                }.width(46)
                TableColumn("Date") { c in
                    Text(c.raw.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                }.width(130)
                TableColumn("Status") { c in
                    Text(c.alreadyImported ? "Imported" : (selectedIDs.contains(c.id) ? "Will import" : "Excluded"))
                }.width(80)
                TableColumn("Text") { c in
                    Text(c.raw.contents.isEmpty ? c.raw.text : c.raw.contents).lineLimit(2)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selected.count) items") { model.runImport(preview, bursts: includedBursts) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
    }
}
