import AppKit
import Foundation
import WebKit

@MainActor
final class DownloadManager: NSObject {
    private let shellStore: BrowserShellStore
    private let fileManager: FileManager

    private var downloadIDsByObjectID: [ObjectIdentifier: UUID] = [:]
    private var progressObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    init(shellStore: BrowserShellStore, fileManager: FileManager = .default) {
        self.shellStore = shellStore
        self.fileManager = fileManager
        super.init()
    }

    func adopt(_ download: WKDownload, sourceURL: URL?) {
        let source = sourceURL ?? download.originalRequest?.url ?? URL(string: "about:blank")!
        let filename = download.originalRequest?.url?.lastPathComponent.isEmpty == false
            ? (download.originalRequest?.url?.lastPathComponent ?? "Download")
            : "Download"

        let downloadID = shellStore.startDownload(sourceURL: source, suggestedFilename: filename)
        let objectID = ObjectIdentifier(download)
        downloadIDsByObjectID[objectID] = downloadID
        download.delegate = self
        progressObservers[objectID] = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, change in
            guard let self, let value = change.newValue else {
                return
            }
            Task { @MainActor in
                self.shellStore.updateDownloadProgress(downloadID, progress: value)
            }
        }
    }

    func revealDownload(_ downloadID: UUID) {
        guard let item = shellStore.orderedDownloads().first(where: { $0.id == downloadID }),
              let path = item.destinationPath else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func cleanup(_ download: WKDownload) {
        let objectID = ObjectIdentifier(download)
        progressObservers[objectID] = nil
        downloadIDsByObjectID[objectID] = nil
    }

    private func uniqueDestinationURL(for suggestedFilename: String) -> URL {
        let directoryURL = URL(fileURLWithPath: shellStore.settings.downloadDirectoryPath, isDirectory: true)
        let baseName = URL(fileURLWithPath: suggestedFilename).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: suggestedFilename).pathExtension

        var candidateURL = directoryURL.appendingPathComponent(suggestedFilename)
        var counter = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            let numberedName = ext.isEmpty
                ? "\(baseName) \(counter)"
                : "\(baseName) \(counter).\(ext)"
            candidateURL = directoryURL.appendingPathComponent(numberedName)
            counter += 1
        }

        return candidateURL
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let destinationURL = uniqueDestinationURL(for: suggestedFilename)
        let objectID = ObjectIdentifier(download)
        if let downloadID = downloadIDsByObjectID[objectID] {
            shellStore.updateDownloadDestination(downloadID, destinationPath: destinationURL.path)
        }
        return destinationURL
    }

    func downloadDidFinish(_ download: WKDownload) {
        let objectID = ObjectIdentifier(download)
        guard let downloadID = downloadIDsByObjectID[objectID] else {
            return
        }

        let finalPath = shellStore.orderedDownloads().first(where: { $0.id == downloadID })?.destinationPath
        shellStore.finishDownload(downloadID, finalPath: finalPath)
        if shellStore.settings.openSafeFilesAutomatically, let finalPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: finalPath))
        }
        cleanup(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let objectID = ObjectIdentifier(download)
        guard let downloadID = downloadIDsByObjectID[objectID] else {
            return
        }

        shellStore.failDownload(downloadID, errorDescription: error.localizedDescription, resumeData: resumeData)
        cleanup(download)
    }
}
