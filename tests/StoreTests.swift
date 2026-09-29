import Foundation
import Testing
@testable import FACore

func tempFolder() -> SyncFolder {
    SyncFolder(root: FileManager.default.temporaryDirectory.appendingPathComponent("fa-\(UUID().uuidString)", isDirectory: true))
}

@Test func addAndReadBack() throws {
    let store = try Store(folder: tempFolder(), device: "mac-a", deviceName: "Mac A")
    let h = Highlight(page: 3, rects: [Rect(x: 1, y: 2, w: 3, h: 4)], text: "Graves disease", color: .pink)
    try store.add([h])
    #expect(try store.highlights(page: 3) == [h])
}
