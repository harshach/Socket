import Foundation

@MainActor
final class BrowserShellStore {
    typealias Observer = @MainActor (BrowserShellStore) -> Void

    private var observers: [UUID: Observer] = [:]
    private(set) var settings: BrowserSettings
    private(set) var faviconRecordsByHost: [String: FaviconRecord]
    private(set) var downloadsByID: [UUID: DownloadItem]
    private(set) var extensionsByID: [String: ExtensionDescriptor]
    private(set) var remindersByID: [UUID: ReminderItem]
    private var pageRuntimeByID: [UUID: PageRuntimeState] = [:]

    init(snapshot: ShellStateSnapshot = .default()) {
        self.settings = snapshot.settings
        self.faviconRecordsByHost = snapshot.faviconRecords
        self.downloadsByID = Dictionary(uniqueKeysWithValues: snapshot.downloads.map { ($0.id, $0) })
        self.extensionsByID = Dictionary(uniqueKeysWithValues: snapshot.extensions.map { ($0.id, $0) })
        self.remindersByID = Dictionary(uniqueKeysWithValues: snapshot.reminders.map { ($0.id, $0) })
    }

    @discardableResult
    func observe(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(self)
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    func snapshot() -> ShellStateSnapshot {
        ShellStateSnapshot(
            settings: settings,
            faviconRecords: faviconRecordsByHost,
            downloads: orderedDownloads(),
            extensions: orderedExtensions(),
            reminders: remindersByID.values.sorted { $0.createdAt > $1.createdAt }
        )
    }

    func orderedDownloads() -> [DownloadItem] {
        downloadsByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func orderedExtensions() -> [ExtensionDescriptor] {
        extensionsByID.values.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func favicon(for url: URL?) -> FaviconRecord? {
        guard let host = url?.host?.lowercased() else {
            return nil
        }
        return faviconRecordsByHost[host]
    }

    func updatePageRuntime(
        pageID: UUID,
        isLoading: Bool,
        estimatedProgress: Double,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        let clampedProgress = min(max(estimatedProgress, 0), 1)
        let nextState = PageRuntimeState(
            isLoading: isLoading,
            estimatedProgress: clampedProgress,
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )
        guard pageRuntimeByID[pageID] != nextState else {
            return
        }
        pageRuntimeByID[pageID] = nextState
        notifyObservers()
    }

    func pageRuntimeState(for pageID: UUID?) -> PageRuntimeState {
        guard let pageID else {
            return .idle
        }
        return pageRuntimeByID[pageID] ?? .idle
    }

    func removePageRuntime(for pageID: UUID) {
        guard pageRuntimeByID.removeValue(forKey: pageID) != nil else {
            return
        }
        notifyObservers()
    }

    func updateFavicon(for pageURL: URL, iconURL: URL?, pngData: Data?) {
        guard let host = pageURL.host?.lowercased(), !host.isEmpty else {
            return
        }

        let monogram = String(host.prefix(1)).uppercased()
        let accentHex = Self.accentHex(for: host)
        let nextRecord = FaviconRecord(
            host: host,
            iconURLString: iconURL?.absoluteString,
            pngData: pngData,
            monogram: monogram.isEmpty ? "•" : monogram,
            accentHex: accentHex,
            updatedAt: .now
        )

        guard faviconRecordsByHost[host] != nextRecord else {
            return
        }

        faviconRecordsByHost[host] = nextRecord
        notifyObservers()
    }

    func startDownload(sourceURL: URL, suggestedFilename: String) -> UUID {
        let item = DownloadItem(
            sourceURLString: sourceURL.absoluteString,
            suggestedFilename: suggestedFilename,
            progress: 0,
            state: .preparing
        )
        downloadsByID[item.id] = item
        notifyObservers()
        return item.id
    }

    func updateDownloadDestination(_ downloadID: UUID, destinationPath: String?) {
        guard var item = downloadsByID[downloadID] else {
            return
        }
        item.destinationPath = destinationPath
        item.state = .downloading
        downloadsByID[downloadID] = item
        notifyObservers()
    }

    func updateDownloadProgress(_ downloadID: UUID, progress: Double) {
        guard var item = downloadsByID[downloadID] else {
            return
        }
        item.state = .downloading
        item.progress = min(max(progress, 0), 1)
        downloadsByID[downloadID] = item
        notifyObservers()
    }

    func finishDownload(_ downloadID: UUID, finalPath: String?) {
        guard var item = downloadsByID[downloadID] else {
            return
        }
        item.destinationPath = finalPath ?? item.destinationPath
        item.progress = 1
        item.state = .finished
        item.finishedAt = .now
        item.errorDescription = nil
        item.resumeData = nil
        downloadsByID[downloadID] = item
        notifyObservers()
    }

    func failDownload(_ downloadID: UUID, errorDescription: String, resumeData: Data?) {
        guard var item = downloadsByID[downloadID] else {
            return
        }
        item.state = .failed
        item.errorDescription = errorDescription
        item.resumeData = resumeData
        downloadsByID[downloadID] = item
        notifyObservers()
    }

    func removeDownload(_ downloadID: UUID) {
        guard downloadsByID.removeValue(forKey: downloadID) != nil else {
            return
        }
        notifyObservers()
    }

    func setDownloadDirectoryPath(_ path: String) {
        guard settings.downloadDirectoryPath != path else {
            return
        }
        settings.downloadDirectoryPath = path
        notifyObservers()
    }

    func setDownloadClearPolicy(_ policy: DownloadClearPolicy) {
        guard settings.downloadClearPolicy != policy else {
            return
        }
        settings.downloadClearPolicy = policy
        notifyObservers()
    }

    func setOpenSafeFilesAutomatically(_ enabled: Bool) {
        guard settings.openSafeFilesAutomatically != enabled else {
            return
        }
        settings.openSafeFilesAutomatically = enabled
        notifyObservers()
    }

    func setShortcutOverride(actionID: String, binding: String?) {
        let trimmedBinding = binding?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedBinding.isEmpty {
            guard settings.shortcutOverrides.removeValue(forKey: actionID) != nil else {
                return
            }
        } else {
            guard settings.shortcutOverrides[actionID] != trimmedBinding else {
                return
            }
            settings.shortcutOverrides[actionID] = trimmedBinding
        }
        notifyObservers()
    }

    func replaceShortcutOverrides(_ overrides: [String: String]) {
        guard settings.shortcutOverrides != overrides else {
            return
        }
        settings.shortcutOverrides = overrides
        notifyObservers()
    }

    func upsertExtension(_ descriptor: ExtensionDescriptor) {
        guard extensionsByID[descriptor.id] != descriptor else {
            return
        }
        extensionsByID[descriptor.id] = descriptor
        notifyObservers()
    }

    func removeExtension(_ extensionID: String) {
        guard extensionsByID.removeValue(forKey: extensionID) != nil else {
            return
        }
        notifyObservers()
    }

    func setExtensionEnabled(_ extensionID: String, enabled: Bool) {
        guard var descriptor = extensionsByID[extensionID],
              descriptor.enabled != enabled else {
            return
        }
        descriptor.enabled = enabled
        extensionsByID[extensionID] = descriptor
        notifyObservers()
    }

    func setExtensionPinned(_ extensionID: String, pinned: Bool) {
        guard var descriptor = extensionsByID[extensionID],
              descriptor.pinned != pinned else {
            return
        }
        descriptor.pinned = pinned
        extensionsByID[extensionID] = descriptor
        notifyObservers()
    }

    @discardableResult
    func addReminder(title: String) -> UUID {
        let reminder = ReminderItem(title: title)
        remindersByID[reminder.id] = reminder
        notifyObservers()
        return reminder.id
    }

    func setReminderDone(_ reminderID: UUID, isDone: Bool) {
        guard var reminder = remindersByID[reminderID],
              reminder.isDone != isDone else {
            return
        }
        reminder.isDone = isDone
        remindersByID[reminderID] = reminder
        notifyObservers()
    }

    func removeReminder(_ reminderID: UUID) {
        guard remindersByID.removeValue(forKey: reminderID) != nil else {
            return
        }
        notifyObservers()
    }

    private func notifyObservers() {
        observers.values.forEach { $0(self) }
    }

    private static func accentHex(for host: String) -> String {
        let palette = [
            "#6E4A3A",
            "#384E77",
            "#4C6A5F",
            "#70543E",
            "#5A4C78",
            "#45615E",
        ]
        let hash = abs(host.hashValue)
        return palette[hash % palette.count]
    }
}
