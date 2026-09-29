import FACore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if model.history.isEmpty {
                Text("No changes yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.history) { s in row(s) }
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear {
            model.pendingUndo = nil
            model.refreshHistory()
        }
    }

    private func kind(_ k: SessionKind) -> String {
        switch k {
        case .edit: "Edit"
        case .import: "Import"
        case .undo: "Undo"
        }
    }

    private func timeRange(_ s: SessionSummary) -> String {
        let start = Date(timeIntervalSince1970: s.started)
        let end = Date(timeIntervalSince1970: s.ended)
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(date: .abbreviated, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "\(start.formatted(date: .abbreviated, time: .shortened)) to \(end.formatted(date: .abbreviated, time: .shortened))"
    }

    private func undoneText(_ s: SessionSummary) -> String? {
        guard !s.undoneBy.isEmpty else { return nil }
        let parts = s.undoneBy.map { id -> String in
            guard let u = model.history.first(where: { $0.id == id }) else { return "another session" }
            return "\(u.deviceName), \(Date(timeIntervalSince1970: u.ended).formatted(date: .abbreviated, time: .shortened))"
        }
        return "Undone by " + parts.joined(separator: "; ")
    }

    private func row(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kind(s.kind)).fontWeight(.semibold)
                Text(s.deviceName).foregroundStyle(.secondary)
                Spacer()
                Text(timeRange(s)).font(.caption).foregroundStyle(.secondary)
            }
            let first = s.pages.prefix(5).map { model.label($0) }.joined(separator: ", ")
            Text("\(s.opCount) changes on \(s.pages.count) pages: \(first)\(s.pages.count > 5 ? ", …" : "")")
                .font(.callout)
            if let undone = undoneText(s) {
                Text(undone).font(.caption).foregroundStyle(.orange)
            }
            if let p = model.pendingUndo, p.sessionID == s.id {
                HStack {
                    Text("\(p.revert) changes will be reverted. \(p.skipped) skipped because later work changed them.")
                        .font(.caption)
                    Spacer()
                    Button("Cancel") { model.pendingUndo = nil }
                    if p.revert > 0 {
                        Button("Undo now") { model.confirmUndo() }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Button("Undo this session") { model.prepareUndo(s) }.controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
