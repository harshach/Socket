import Foundation

enum DownloadClearPolicy: String, Codable, CaseIterable {
    case manually
    case oneDay
    case oneWeek
    case oneMonth

    var displayTitle: String {
        switch self {
        case .manually:
            return "Manually"
        case .oneDay:
            return "After one day"
        case .oneWeek:
            return "After one week"
        case .oneMonth:
            return "After one month"
        }
    }
}

struct BrowserSettings: Codable, Equatable {
    var downloadDirectoryPath: String
    var downloadClearPolicy: DownloadClearPolicy
    var openSafeFilesAutomatically: Bool
    var shortcutOverrides: [String: String]

    static func `default`(fileManager: FileManager = .default) -> BrowserSettings {
        let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

        return BrowserSettings(
            downloadDirectoryPath: downloadsURL.path,
            downloadClearPolicy: .oneDay,
            openSafeFilesAutomatically: false,
            shortcutOverrides: [:]
        )
    }
}

struct FaviconRecord: Codable, Equatable {
    var host: String
    var iconURLString: String?
    var pngData: Data?
    var monogram: String
    var accentHex: String
    var updatedAt: Date
}

enum DownloadState: String, Codable, Equatable {
    case preparing
    case downloading
    case finished
    case failed
    case cancelled
}

struct DownloadItem: Codable, Equatable, Identifiable {
    let id: UUID
    var sourceURLString: String
    var suggestedFilename: String
    var destinationPath: String?
    var progress: Double
    var state: DownloadState
    var createdAt: Date
    var finishedAt: Date?
    var errorDescription: String?
    var resumeData: Data?

    init(
        id: UUID = UUID(),
        sourceURLString: String,
        suggestedFilename: String,
        destinationPath: String? = nil,
        progress: Double = 0,
        state: DownloadState = .preparing,
        createdAt: Date = .now,
        finishedAt: Date? = nil,
        errorDescription: String? = nil,
        resumeData: Data? = nil
    ) {
        self.id = id
        self.sourceURLString = sourceURLString
        self.suggestedFilename = suggestedFilename
        self.destinationPath = destinationPath
        self.progress = progress
        self.state = state
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.errorDescription = errorDescription
        self.resumeData = resumeData
    }
}

struct ExtensionDescriptor: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var version: String
    var resourceURLString: String
    var enabled: Bool
    var pinned: Bool
    var requestedPermissions: [String]
    var requestedMatches: [String]
    var lastError: String?

    var resourceURL: URL? {
        URL(string: resourceURLString)
    }
}

struct ReminderItem: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var createdAt: Date
    var isDone: Bool

    init(id: UUID = UUID(), title: String, createdAt: Date = .now, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.isDone = isDone
    }
}

struct ShellStateSnapshot: Codable, Equatable {
    var settings: BrowserSettings
    var faviconRecords: [String: FaviconRecord]
    var downloads: [DownloadItem]
    var extensions: [ExtensionDescriptor]
    var reminders: [ReminderItem]

    static func `default`() -> ShellStateSnapshot {
        ShellStateSnapshot(
            settings: .default(),
            faviconRecords: [:],
            downloads: [],
            extensions: [],
            reminders: []
        )
    }
}

struct PageRuntimeState: Equatable {
    var isLoading: Bool
    var estimatedProgress: Double
    var canGoBack: Bool
    var canGoForward: Bool

    static let idle = PageRuntimeState(isLoading: false, estimatedProgress: 0, canGoBack: false, canGoForward: false)
}
