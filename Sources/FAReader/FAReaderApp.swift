import AppKit
import SwiftUI

@main
struct FAReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("FA Reader", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands { AppCommands(model: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppModel.shared.selfCheck != nil || AppModel.shared.measureOpen {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.flushNote()
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.openPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .importExport) {
            Divider()
            Button("Import from Preview…") { model.beginImport() }
                .disabled(model.store == nil)
            Button("Export Markdown") { model.exportMarkdown() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.store == nil)
            Button("Choose Export Folder…") { model.chooseExportFolder() }
                .disabled(model.store == nil)
            Divider()
            Button("History…") { model.showHistory = true }
                .keyboardShortcut("y")
                .disabled(model.store == nil)
        }
        CommandMenu("Highlight") {
            Button("Yellow") { model.applyColor(.yellow) }.keyboardShortcut("1")
            Button("Green") { model.applyColor(.green) }.keyboardShortcut("2")
            Button("Pink") { model.applyColor(.pink) }.keyboardShortcut("3")
            Button("Blue") { model.applyColor(.blue) }.keyboardShortcut("4")
            Divider()
            Button("Edit Note") { model.focusNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.selectedID == nil)
            Button("Delete Highlight") { model.deleteFromMenu() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedID == nil || model.noteFocused)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { model.zoomIn() }.keyboardShortcut("=")
            Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { model.actualSize() }.keyboardShortcut("0")
            Button("Zoom to Fit Width") { model.fitWidth() }.keyboardShortcut("9")
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { model.focusSearchTick += 1 }.keyboardShortcut("f")
            Button("Next Result") { model.moveResult(1) }.keyboardShortcut("g")
                .disabled(model.results.isEmpty)
            Button("Previous Result") { model.moveResult(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.results.isEmpty)
        }
    }
}
