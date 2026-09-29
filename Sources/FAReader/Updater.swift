import AppKit

struct Release {
    var build: Int
    var notes: String
    var assetURL: URL
}

@MainActor
enum Updater {
    static var repo: String { Bundle.main.infoDictionary?["FAUpdateRepo"] as? String ?? "elparko/fa-reader" }
    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    static func token() -> String? {
        if let t = ProcessInfo.processInfo.environment["GH_TOKEN"], !t.isEmpty { return t }
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "token"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !token.isEmpty { return token }
        }
        return nil
    }

    static func latest(token: String?) async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let build = Int(tag.replacingOccurrences(of: "build-", with: "")),
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let url = (asset["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(build: build, notes: json["body"] as? String ?? "", assetURL: url)
    }

    static func checkDaily() {
        let key = "lastUpdateCheck"
        let last = UserDefaults.standard.double(forKey: key)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        Task { await check(interactive: false) }
    }

    static func check(interactive: Bool) async {
        let token = token()
        let release: Release?
        do {
            release = try await latest(token: token)
        } catch {
            if interactive { alert("Could not check for updates", "\(error.localizedDescription)") }
            return
        }
        guard let release else {
            if interactive { alert("No builds published yet", "No release was found in \(repo).") }
            return
        }
        guard release.build > currentBuild else {
            if interactive { alert("FA Reader is up to date", "You have build \(currentBuild), the newest.") }
            return
        }
        let a = NSAlert()
        a.messageText = "Build \(release.build) is available"
        a.informativeText = "You have build \(currentBuild).\n\n\(release.notes.prefix(600))"
        a.addButton(withTitle: "Install and Restart")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await install(release, token: token)
        } catch {
            alert("Update failed", "\(error.localizedDescription)")
        }
    }

    static func install(_ release: Release, token: String?) async throws {
        var req = URLRequest(url: release.assetURL)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (zip, response) = try await URLSession.shared.download(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fa-reader-update-\(release.build)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        let fresh = dir.appendingPathComponent("FA Reader.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: fresh.path) else { throw URLError(.cannotDecodeContentData) }

        AppModel.shared.flushNote()
        let target = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target)"
        /usr/bin/ditto "\(fresh.path)" "\(target)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target)"
        /usr/bin/open "\(target)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    private static func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.runModal()
    }
}
