import AppKit
import SwiftUI

@main
struct FAReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("FA Reader", id: "main") {
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
        if AppModel.shared.selfCheck != nil || AppModel.shared.measureOpen {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            Updater.checkDaily()
        }
        if CommandLine.arguments.contains("--print-update") {
            Task {
                let token = Updater.token()
                var latest: Release?
                if let token { latest = try? await Updater.latest(token: token) }
                print("current=\(Updater.currentBuild) token=\(token != nil) latest=\(latest.map { "\($0.build)" } ?? "none")")
                exit(0)
            }
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
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.check(interactive: true) } }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.openPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentBooks, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { model.openRecent(path) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecent() }
            }
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
    }
}
