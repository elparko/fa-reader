import AppKit
import SwiftUI

@main
struct FAReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window(LocalizedStringKey(stringLiteral: Branding.displayName), id: "main") {
            ContentView(model: model)
                .frame(minWidth: 480, minHeight: 400)
        }
        .commands {
            SidebarCommands()
            AppCommands(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppModel.shared.handle(url: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        let headless = AppModel.shared.selfCheck != nil || AppModel.shared.measureOpen
#else
        let headless = false
#endif
        if headless {
            NSApp.setActivationPolicy(.accessory)
#if DEBUG
            for window in NSApp.windows where !CommandLine.arguments.contains("--visible") {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
#endif
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
#if !APPSTORE
            Updater.checkDaily()
#endif
        }
#if !APPSTORE
        if CommandLine.arguments.contains("--print-update") {
            Task {
                let token = Updater.token()
                var latest: Release?
                latest = try? await Updater.latest(token: token)
                print("current=\(Updater.currentBuild) token=\(token != nil) latest=\(latest.map { "\($0.build)" } ?? "none")")
                exit(0)
            }
        }
#endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.flushNote()
        AppModel.shared.saveNotes()
        AppModel.shared.flushLog()
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    private var textFocused: Bool {
        model.noteFocused || model.searchFieldFocused || NSApp.keyWindow?.firstResponder is NSText
    }

    var body: some Commands {
#if !APPSTORE
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.check(interactive: true) } }
        }
#endif
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.openPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentBooks) { book in
                    Button(book.name) { model.openRecent(book) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecent() }
            }
            .disabled(model.recentBooks.isEmpty)
        }
        CommandGroup(after: .importExport) {
            Divider()
            Button("Import from Preview…") { model.beginImport() }
                .disabled(model.store == nil)
            Button("Import Highlights from Folder…") { model.importSidecarFolder() }
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
        CommandGroup(replacing: .undoRedo) {
            Button(textFocused ? "Undo" : model.undoTitle) { model.undo() }.keyboardShortcut("z")
            Button(textFocused ? "Redo" : model.redoTitle) { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
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
            Button(model.selectedID == nil && model.barMode == .selection(erase: true) ? "Remove Highlight from Selection" : "Delete Highlight") {
                model.deleteFromMenu()
            }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled((model.selectedID == nil && model.barMode != .selection(erase: true)) || model.noteFocused || NSApp.keyWindow?.firstResponder is NSText)
            Button("Copy Highlight Text") { _ = model.copySelectedHighlight() }
                .disabled(model.selectedID == nil)
            Divider()
            Button("Show Highlights List") { model.showHighlightList() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(model.store == nil)
            Button("Tidy Overlapping Highlights…") { model.tidyHighlights() }
                .disabled(model.store == nil)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button(model.notesShown ? "Hide Notes" : "Show Notes") { model.notesShown.toggle() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Zoom In") { model.zoomIn() }.keyboardShortcut("=")
            Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { model.actualSize() }.keyboardShortcut("0")
            Button("Zoom to Fit Width") { model.fitWidth() }.keyboardShortcut("9")
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { model.focusSearch() }.keyboardShortcut("f")
            Button("Next Result") { model.moveResult(1) }.keyboardShortcut("g")
                .disabled(model.results.isEmpty)
            Button("Previous Result") { model.moveResult(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.results.isEmpty)
        }
        CommandGroup(replacing: .help) {
            Button("Rowlight Support") {
                NSWorkspace.shared.open(URL(string: "https://www.elparko.com/apps/rowlight/support/")!)
            }
            Button("Privacy Policy") {
                NSWorkspace.shared.open(URL(string: "https://www.elparko.com/apps/rowlight/privacy/")!)
            }
        }
    }
}
