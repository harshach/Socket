import BrowserCore
import Foundation

@MainActor
final class BrowserPersistenceController {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let saveURL: URL

    init(fileManager: FileManager = .default) {
        let appSupportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupportRoot.appendingPathComponent("SigmaBrowserShell", isDirectory: true)
        self.saveURL = directory.appendingPathComponent("BrowserState.json")
    }

    func load() -> BrowserStateSnapshot? {
        guard let data = try? Data(contentsOf: saveURL) else {
            return nil
        }
        return try? decoder.decode(BrowserStateSnapshot.self, from: data)
    }

    func save(snapshot: BrowserStateSnapshot) {
        do {
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: saveURL, options: [.atomic])
        } catch {
            NSLog("Failed to persist browser state: \(error.localizedDescription)")
        }
    }
}
